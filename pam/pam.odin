package pam

import "base:runtime"
import "base:intrinsics"
import "core:c"
import "core:c/libc"
import "core:sys/posix"
import raw "../pam_raw"

MAX_PASSWORD :: raw.PAM_MAX_RESP_SIZE-1
clear_secret :: proc(bytes: []u8) {
    for &b in bytes { intrinsics.volatile_store(&b,u8(0)) }
}
valid_password :: proc(password: string) -> bool {
    if len(password)>MAX_PASSWORD { return false }
    for b in transmute([]u8)password { if b==0 { return false } }
    return true
}
Conversation :: struct { password:[]u8, allocations_left:int }
allocate :: proc(c: ^Conversation,n:int) -> rawptr {
    if c.allocations_left==0 { return nil }
    if c.allocations_left>0 { c.allocations_left-=1 }
    return libc.calloc(1,cast(libc.size_t)n)
}
retire_responses :: proc(responses:[^]raw.pam_response,n:int) {
    if responses==nil { return }
    for &r in responses[:n] {
        if r.resp!=nil {
            clear_secret(([^]u8)(r.resp)[:len(r.resp)+1])
            libc.free(rawptr(r.resp))
        }
    }
    libc.free(responses)
}
conversation :: proc "c" (count:c.int,messages:[^]^raw.pam_message,result:^[^]raw.pam_response,data:rawptr)->c.int {
    context=runtime.default_context()
    if result==nil { return raw.PAM_CONV_ERR }
    result^=nil
    if count<=0 || count>raw.PAM_MAX_NUM_MSG || messages==nil || data==nil { return raw.PAM_CONV_ERR }
    c:=(^Conversation)(data)
    responses:=([^]raw.pam_response)(allocate(c,int(count)*size_of(raw.pam_response)))
    if responses==nil { return raw.PAM_BUF_ERR }
    success:=false
    defer { if !success { retire_responses(responses,int(count)) } }
    for message,i in messages[:count] {
        if message==nil { return raw.PAM_CONV_ERR }
        switch message.msg_style {
        case raw.PAM_PROMPT_ECHO_OFF,raw.PAM_PROMPT_ECHO_ON:
            n:=0
            if message.msg_style==raw.PAM_PROMPT_ECHO_OFF { n=len(c.password) }
            p:=([^]u8)(allocate(c,n+1))
            if p==nil { return raw.PAM_BUF_ERR }
            copy(p[:n],c.password[:n]);responses[i].resp=cast(cstring)p
        case raw.PAM_ERROR_MSG,raw.PAM_TEXT_INFO:
        case: return raw.PAM_CONV_ERR
        }
    }
    result^=responses;success=true
    // PAM frees successful response allocations with libc free.
    return raw.PAM_SUCCESS
}
check :: proc(password: []u8) -> bool {
    if !valid_password(string(password)) { return false }
    user:=posix.getpwuid(posix.getuid())
    if user==nil || user.pw_name==nil { return false }
    c:=Conversation{password=password,allocations_left=-1}
    conv:=raw.pam_conv{conversation,&c}
    handle:^raw.pam_handle_t
    status:=raw.pam_start("login",user.pw_name,&conv,&handle)
    if handle!=nil { defer raw.pam_end(handle,status)
        if status!=raw.PAM_SUCCESS { return false }
        status=raw.pam_authenticate(handle,0)
        return status==raw.PAM_SUCCESS
    }
    return false
}
