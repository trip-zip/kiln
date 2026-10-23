package wlroots

import wl "../wayland_server"

wlr_xdg_activation_v1 :: struct #align(8) {
    _opaque_0: [8]u8,
    token_timeout_msec: u32,
    _opaque_12: [20]u8,
    events: struct { destroy, request_activate, new_token: wl.wl_signal },
    _opaque_80: [32]u8,
}
wlr_xdg_activation_token_v1 :: struct #align(8) {
    _opaque_0: [16]u8,
    seat: ^wlr_seat,
    _opaque_24: [8]u8,
    app_id: cstring,
    _opaque_40: [24]u8,
    events: struct { destroy: wl.wl_signal },
    _opaque_80: [72]u8,
}
wlr_xdg_activation_v1_request_activate_event :: struct {
    activation: ^wlr_xdg_activation_v1,
    token: ^wlr_xdg_activation_token_v1,
    surface: ^wlr_surface,
}
foreign import activation_lib "system:wlroots-0.20"
foreign activation_lib {
    wlr_xdg_activation_v1_create :: proc(display: ^wl.wl_display) -> ^wlr_xdg_activation_v1 ---
    wlr_xdg_activation_token_v1_create :: proc(manager: ^wlr_xdg_activation_v1) -> ^wlr_xdg_activation_token_v1 ---
    wlr_xdg_activation_token_v1_destroy :: proc(token: ^wlr_xdg_activation_token_v1) ---
    wlr_xdg_activation_token_v1_get_name :: proc(token: ^wlr_xdg_activation_token_v1) -> cstring ---
}
activation_create :: proc(display: ^wl.wl_display) -> ^wlr_xdg_activation_v1 {
    return wlr_xdg_activation_v1_create(display)
}
activation_mint :: proc(manager: ^wlr_xdg_activation_v1) -> (^wlr_xdg_activation_token_v1, cstring) {
    token := wlr_xdg_activation_token_v1_create(manager)
    if token == nil { return nil, nil }
    return token, wlr_xdg_activation_token_v1_get_name(token)
}
activation_retire :: proc(token: ^wlr_xdg_activation_token_v1) {
    wlr_xdg_activation_token_v1_destroy(token)
}
#assert(size_of(wlr_xdg_activation_v1)==112 && align_of(wlr_xdg_activation_v1)==8)
#assert(offset_of(wlr_xdg_activation_v1,token_timeout_msec)==8 && offset_of(wlr_xdg_activation_v1,events)==32)
#assert(size_of(type_of(wlr_xdg_activation_v1{}.events))==48)
#assert(align_of(type_of(wlr_xdg_activation_v1{}.events))==8)
#assert(offset_of(type_of(wlr_xdg_activation_v1{}.events),destroy)==0)
#assert(offset_of(type_of(wlr_xdg_activation_v1{}.events),request_activate)==16)
#assert(offset_of(type_of(wlr_xdg_activation_v1{}.events),new_token)==32)
#assert(size_of(wlr_xdg_activation_token_v1)==152 && align_of(wlr_xdg_activation_token_v1)==8)
#assert(offset_of(wlr_xdg_activation_token_v1,seat)==16 && offset_of(wlr_xdg_activation_token_v1,app_id)==32)
#assert(offset_of(wlr_xdg_activation_token_v1,events)==64)
#assert(size_of(type_of(wlr_xdg_activation_token_v1{}.events))==16)
#assert(align_of(type_of(wlr_xdg_activation_token_v1{}.events))==8)
#assert(offset_of(type_of(wlr_xdg_activation_token_v1{}.events),destroy)==0)
#assert(size_of(wlr_xdg_activation_v1_request_activate_event)==24 && align_of(wlr_xdg_activation_v1_request_activate_event)==8)
#assert(offset_of(wlr_xdg_activation_v1_request_activate_event,activation)==0)
#assert(offset_of(wlr_xdg_activation_v1_request_activate_event,token)==8)
#assert(offset_of(wlr_xdg_activation_v1_request_activate_event,surface)==16)
