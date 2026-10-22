package wlroots

import wl "../wayland_server"

wlr_cursor_shape_manager_v1 :: struct #align(8) {
    _opaque_0: [8]u8,
    events: struct { request_set_shape, destroy: wl.wl_signal },
    _opaque_40: [32]u8,
}
wlr_cursor_shape_manager_v1_request_set_shape_event :: struct #align(8) {
    seat_client: ^wlr_seat_client,
    device_type: i32,
    _opaque_12: [16]u8,
    shape: i32,
}
foreign import shape_lib "system:wlroots-0.20"
foreign shape_lib {
    wlr_cursor_shape_manager_v1_create :: proc(display: ^wl.wl_display,version: u32) -> ^wlr_cursor_shape_manager_v1 ---
    wlr_cursor_shape_v1_name :: proc(shape: i32) -> cstring ---
}
cursor_shape_create :: proc(display: ^wl.wl_display) -> ^wlr_cursor_shape_manager_v1 { return wlr_cursor_shape_manager_v1_create(display,1) }
cursor_shape_name :: proc(shape: i32) -> cstring { return wlr_cursor_shape_v1_name(shape) }
#assert(size_of(wlr_cursor_shape_manager_v1)==72 && align_of(wlr_cursor_shape_manager_v1)==8)
#assert(offset_of(wlr_cursor_shape_manager_v1,events)==8)
#assert(size_of(type_of(wlr_cursor_shape_manager_v1{}.events))==32 && align_of(type_of(wlr_cursor_shape_manager_v1{}.events))==8)
#assert(offset_of(type_of(wlr_cursor_shape_manager_v1{}.events),request_set_shape)==0)
#assert(offset_of(type_of(wlr_cursor_shape_manager_v1{}.events),destroy)==16)
#assert(size_of(wlr_cursor_shape_manager_v1_request_set_shape_event)==32 && align_of(wlr_cursor_shape_manager_v1_request_set_shape_event)==8)
#assert(offset_of(wlr_cursor_shape_manager_v1_request_set_shape_event,seat_client)==0)
#assert(offset_of(wlr_cursor_shape_manager_v1_request_set_shape_event,device_type)==8)
#assert(offset_of(wlr_cursor_shape_manager_v1_request_set_shape_event,shape)==28)
