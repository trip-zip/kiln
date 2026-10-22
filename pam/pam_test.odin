package pam

import "core:testing"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import raw "../pam_raw"

@(test)
conversation_records :: proc(t:^testing.T) {
    secret:=[4]u8{'t','e','s','t'}
    defer clear_secret(secret[:])
    c:=Conversation{secret[:],-1}
    messages:=[4]raw.pam_message{{raw.PAM_PROMPT_ECHO_OFF,"password"},{raw.PAM_PROMPT_ECHO_ON,"user"},{raw.PAM_ERROR_MSG,"error"},{raw.PAM_TEXT_INFO,"info"}}
    pointers:=[4]^raw.pam_message{&messages[0],&messages[1],&messages[2],&messages[3]}
    response:[^]raw.pam_response
    testing.expect(t,conversation(4,raw_data(pointers[:]),&response,&c)==raw.PAM_SUCCESS)
    testing.expect(t,string(response[0].resp)=="test" && string(response[1].resp)=="" && response[2].resp==nil && response[3].resp==nil)
    for r in response[:4] { testing.expect(t,r.resp_retcode==0) }
    retire_responses(response,4)
    for limit in 0..<3 {
        c.allocations_left=limit;response=nil
        testing.expect(t,conversation(4,raw_data(pointers[:]),&response,&c)==raw.PAM_BUF_ERR && response==nil)
    }
    c.allocations_left=-1
    messages[2].msg_style=7
    testing.expect(t,conversation(4,raw_data(pointers[:]),&response,&c)==raw.PAM_CONV_ERR && response==nil)
    testing.expect(t,conversation(0,raw_data(pointers[:]),&response,&c)==raw.PAM_CONV_ERR)
    testing.expect(t,!valid_password("a\x00b"))
    oversized:[512]u8
    testing.expect(t,!valid_password(string(oversized[:])))
    clear_secret(secret[:]);testing.expect(t,secret==[4]u8{})
}

// A private policy exercises libpam without querying any account credential.
foreign import test_pam "system:pam"
foreign test_pam {
    pam_start_confdir :: proc(service,user:cstring,conv:^raw.pam_conv,dir:cstring,handle:^^raw.pam_handle_t)->c.int ---
}
@(test)
private_pam_policy :: proc(t:^testing.T) {
    dir,err:=os.make_directory_temp("/tmp","kiln-pam-",context.allocator)
    testing.expect(t,err==nil);if err!=nil { return };defer delete(dir);defer os.remove(dir)
    path:=fmt.aprintf("%s/fixture",dir);defer delete(path);defer os.remove(path)
    cdir:=strings.clone_to_cstring(dir);defer delete(cdir)
    c:=Conversation{allocations_left=-1};conv:=raw.pam_conv{conversation,&c}
    for module in ([]string{"pam_permit.so","pam_deny.so"}) {
        policy:=fmt.aprintf("auth required %s\n",module)
        write_err:=os.write_entire_file(path,policy);delete(policy)
        testing.expect(t,write_err==nil)
        handle:^raw.pam_handle_t
        status:=pam_start_confdir("fixture","kiln-private-fixture",&conv,cdir,&handle)
        testing.expect(t,status==raw.PAM_SUCCESS)
        if handle==nil { continue }
        status=raw.pam_authenticate(handle,0)
        testing.expect(t,(status==raw.PAM_SUCCESS)==(module=="pam_permit.so"))
        testing.expect(t,raw.pam_end(handle,status)==raw.PAM_SUCCESS)
    }
}
