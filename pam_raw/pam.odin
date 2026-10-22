package pam_raw

import "core:c"

pam_handle_t :: struct {}
pam_message :: struct { msg_style:c.int, msg:cstring }
pam_response :: struct { resp:cstring, resp_retcode:c.int }
pam_conv :: struct {
    conv:proc "c" (c.int,[^]^pam_message,^[^]pam_response,rawptr)->c.int,
    appdata_ptr:rawptr,
}
PAM_SUCCESS :: 0
PAM_BUF_ERR :: 5
PAM_CONV_ERR :: 19
PAM_PROMPT_ECHO_OFF :: 1
PAM_PROMPT_ECHO_ON :: 2
PAM_ERROR_MSG :: 3
PAM_TEXT_INFO :: 4
PAM_MAX_NUM_MSG :: 32
PAM_MAX_RESP_SIZE :: 512
foreign import lib "system:pam"
foreign lib {
    pam_start :: proc(service,user:cstring,conversation:^pam_conv,handle:^^pam_handle_t)->c.int ---
    pam_authenticate :: proc(handle:^pam_handle_t,flags:c.int)->c.int ---
    pam_end :: proc(handle:^pam_handle_t,status:c.int)->c.int ---
}
#assert(size_of(pam_message)==16 && align_of(pam_message)==8)
#assert(offset_of(pam_message,msg_style)==0 && offset_of(pam_message,msg)==8)
#assert(size_of(pam_response)==16 && align_of(pam_response)==8)
#assert(offset_of(pam_response,resp)==0 && offset_of(pam_response,resp_retcode)==8)
#assert(size_of(pam_conv)==16 && align_of(pam_conv)==8)
#assert(offset_of(pam_conv,conv)==0 && offset_of(pam_conv,appdata_ptr)==8)
