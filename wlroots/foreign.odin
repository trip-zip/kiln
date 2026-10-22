package wlroots

import wl "../wayland_server"

wlr_foreign_toplevel_manager_v1 :: struct {}
wlr_foreign_toplevel_handle_v1 :: struct #align(8) {
    _opaque_0: [96]u8,
    events: struct { request_maximize, request_minimize, request_activate, request_fullscreen, request_close, set_rectangle, destroy: wl.wl_signal },
    _opaque_208: [8]u8,
}
wlr_foreign_toplevel_handle_v1_maximized_event :: struct {
    toplevel: ^wlr_foreign_toplevel_handle_v1,
    maximized: bool,
}
#assert(size_of(wlr_foreign_toplevel_handle_v1_maximized_event)==16 && align_of(wlr_foreign_toplevel_handle_v1_maximized_event)==8)
#assert(offset_of(wlr_foreign_toplevel_handle_v1_maximized_event,toplevel)==0)
#assert(offset_of(wlr_foreign_toplevel_handle_v1_maximized_event,maximized)==8)
wlr_foreign_toplevel_handle_v1_minimized_event :: struct {
    toplevel: ^wlr_foreign_toplevel_handle_v1,
    minimized: bool,
}
#assert(size_of(wlr_foreign_toplevel_handle_v1_minimized_event)==16 && align_of(wlr_foreign_toplevel_handle_v1_minimized_event)==8)
#assert(offset_of(wlr_foreign_toplevel_handle_v1_minimized_event,toplevel)==0)
#assert(offset_of(wlr_foreign_toplevel_handle_v1_minimized_event,minimized)==8)
wlr_foreign_toplevel_handle_v1_activated_event :: struct {
    toplevel: ^wlr_foreign_toplevel_handle_v1,
    seat: ^wlr_seat,
}
#assert(size_of(wlr_foreign_toplevel_handle_v1_activated_event)==16 && align_of(wlr_foreign_toplevel_handle_v1_activated_event)==8)
#assert(offset_of(wlr_foreign_toplevel_handle_v1_activated_event,toplevel)==0)
#assert(offset_of(wlr_foreign_toplevel_handle_v1_activated_event,seat)==8)
wlr_foreign_toplevel_handle_v1_fullscreen_event :: struct {
    toplevel: ^wlr_foreign_toplevel_handle_v1,
    fullscreen: bool,
    output: ^wlr_output,
}
#assert(size_of(wlr_foreign_toplevel_handle_v1_fullscreen_event)==24 && align_of(wlr_foreign_toplevel_handle_v1_fullscreen_event)==8)
#assert(offset_of(wlr_foreign_toplevel_handle_v1_fullscreen_event,toplevel)==0)
#assert(offset_of(wlr_foreign_toplevel_handle_v1_fullscreen_event,fullscreen)==8)
#assert(offset_of(wlr_foreign_toplevel_handle_v1_fullscreen_event,output)==16)
foreign import foreign_lib "system:wlroots-0.20"
foreign foreign_lib {
    wlr_foreign_toplevel_manager_v1_create :: proc(display: ^wl.wl_display) -> ^wlr_foreign_toplevel_manager_v1 ---
    wlr_foreign_toplevel_handle_v1_create :: proc(manager: ^wlr_foreign_toplevel_manager_v1) -> ^wlr_foreign_toplevel_handle_v1 ---
    wlr_foreign_toplevel_handle_v1_destroy :: proc(handle: ^wlr_foreign_toplevel_handle_v1) ---
    wlr_foreign_toplevel_handle_v1_set_title :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: cstring) ---
    wlr_foreign_toplevel_handle_v1_set_app_id :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: cstring) ---
    wlr_foreign_toplevel_handle_v1_set_maximized :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: bool) ---
    wlr_foreign_toplevel_handle_v1_set_minimized :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: bool) ---
    wlr_foreign_toplevel_handle_v1_set_activated :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: bool) ---
    wlr_foreign_toplevel_handle_v1_set_fullscreen :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: bool) ---
    wlr_foreign_toplevel_handle_v1_output_enter :: proc(handle: ^wlr_foreign_toplevel_handle_v1, output: ^wlr_output) ---
    wlr_foreign_toplevel_handle_v1_output_leave :: proc(handle: ^wlr_foreign_toplevel_handle_v1, output: ^wlr_output) ---
}
foreign_manager_create :: proc(display: ^wl.wl_display) -> ^wlr_foreign_toplevel_manager_v1 { return wlr_foreign_toplevel_manager_v1_create(display) }
foreign_handle_create :: proc(manager: ^wlr_foreign_toplevel_manager_v1) -> ^wlr_foreign_toplevel_handle_v1 { return wlr_foreign_toplevel_handle_v1_create(manager) }
foreign_handle_destroy :: proc(handle: ^wlr_foreign_toplevel_handle_v1) { wlr_foreign_toplevel_handle_v1_destroy(handle) }
foreign_output :: proc(handle: ^wlr_foreign_toplevel_handle_v1, old, next: ^wlr_output) {
    if handle==nil || old==next { return }
    if old!=nil { wlr_foreign_toplevel_handle_v1_output_leave(handle,old) }
    if next!=nil { wlr_foreign_toplevel_handle_v1_output_enter(handle,next) }
}
foreign_title :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: cstring) { if handle!=nil { wlr_foreign_toplevel_handle_v1_set_title(handle,value) } }
foreign_app_id :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: cstring) { if handle!=nil { wlr_foreign_toplevel_handle_v1_set_app_id(handle,value) } }
foreign_maximized :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: bool) { if handle!=nil { wlr_foreign_toplevel_handle_v1_set_maximized(handle,value) } }
foreign_minimized :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: bool) { if handle!=nil { wlr_foreign_toplevel_handle_v1_set_minimized(handle,value) } }
foreign_activated :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: bool) { if handle!=nil { wlr_foreign_toplevel_handle_v1_set_activated(handle,value) } }
foreign_fullscreen :: proc(handle: ^wlr_foreign_toplevel_handle_v1, value: bool) { if handle!=nil { wlr_foreign_toplevel_handle_v1_set_fullscreen(handle,value) } }
#assert(size_of(wlr_foreign_toplevel_handle_v1)==216 && align_of(wlr_foreign_toplevel_handle_v1)==8)
#assert(offset_of(wlr_foreign_toplevel_handle_v1,events)==96)
#assert(size_of(type_of(wlr_foreign_toplevel_handle_v1{}.events))==112)
#assert(align_of(type_of(wlr_foreign_toplevel_handle_v1{}.events))==8)
#assert(offset_of(type_of(wlr_foreign_toplevel_handle_v1{}.events),request_maximize)==0)
#assert(offset_of(type_of(wlr_foreign_toplevel_handle_v1{}.events),request_minimize)==16)
#assert(offset_of(type_of(wlr_foreign_toplevel_handle_v1{}.events),request_activate)==32)
#assert(offset_of(type_of(wlr_foreign_toplevel_handle_v1{}.events),request_fullscreen)==48)
#assert(offset_of(type_of(wlr_foreign_toplevel_handle_v1{}.events),request_close)==64)

#assert(offset_of(type_of(wlr_foreign_toplevel_handle_v1{}.events),set_rectangle)==80)
#assert(offset_of(type_of(wlr_foreign_toplevel_handle_v1{}.events),destroy)==96)
