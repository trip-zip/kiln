package wlroots

import "core:c"
import wl "../wayland_server"

wlr_xdg_decoration_manager_v1 :: struct #align(8) {
    _opaque_0: [24]u8,
    events: struct { new_toplevel_decoration, destroy: wl.wl_signal },
    _opaque_56: [32]u8,
}
wlr_xdg_toplevel_decoration_v1 :: struct #align(8) {
    _opaque_0: [8]u8,
    toplevel: ^wlr_xdg_toplevel,
    _opaque_16: [32]u8,
    scheduled_mode, requested_mode: c.int,
    _opaque_56: [16]u8,
    events: struct { destroy, request_mode: wl.wl_signal },
    _opaque_104: [120]u8,
}
wlr_server_decoration_manager :: struct {}
foreign import decoration_lib "system:wlroots-0.20"
foreign decoration_lib {
    wlr_xdg_decoration_manager_v1_create :: proc(display: ^wl.wl_display) -> ^wlr_xdg_decoration_manager_v1 ---
    wlr_xdg_toplevel_decoration_v1_set_mode :: proc(decoration: ^wlr_xdg_toplevel_decoration_v1, mode: c.int) -> u32 ---
    wlr_server_decoration_manager_create :: proc(display: ^wl.wl_display) -> ^wlr_server_decoration_manager ---
    wlr_server_decoration_manager_set_default_mode :: proc(manager: ^wlr_server_decoration_manager, mode: u32) ---
}
decoration_server_mode :: proc(d: ^wlr_xdg_toplevel_decoration_v1) {
    if d!=nil && d.toplevel.base.initialized && d.scheduled_mode!=2 {
        wlr_xdg_toplevel_decoration_v1_set_mode(d,2)
    }
}
decoration_legacy_create :: proc(display: ^wl.wl_display) -> bool {
    manager:=wlr_server_decoration_manager_create(display)
    if manager==nil { return false }
    wlr_server_decoration_manager_set_default_mode(manager,2)
    return true
}
#assert(size_of(wlr_xdg_decoration_manager_v1)==88)
#assert(align_of(wlr_xdg_decoration_manager_v1)==8)
#assert(offset_of(wlr_xdg_decoration_manager_v1,events)==24)
#assert(size_of(wlr_xdg_toplevel_decoration_v1)==224)
#assert(align_of(wlr_xdg_toplevel_decoration_v1)==8)
#assert(offset_of(wlr_xdg_toplevel_decoration_v1,toplevel)==8)
#assert(offset_of(wlr_xdg_toplevel_decoration_v1,scheduled_mode)==48)
#assert(offset_of(wlr_xdg_toplevel_decoration_v1,requested_mode)==52)
#assert(offset_of(wlr_xdg_toplevel_decoration_v1,events)==72)

decoration_create :: proc(display: ^wl.wl_display) -> ^wlr_xdg_decoration_manager_v1 {
    return wlr_xdg_decoration_manager_v1_create(display)
}
#assert(size_of(type_of(wlr_xdg_decoration_manager_v1{}.events))==32)
#assert(align_of(type_of(wlr_xdg_decoration_manager_v1{}.events))==8)
#assert(offset_of(type_of(wlr_xdg_decoration_manager_v1{}.events),new_toplevel_decoration)==0)
#assert(offset_of(type_of(wlr_xdg_decoration_manager_v1{}.events),destroy)==16)
#assert(size_of(type_of(wlr_xdg_toplevel_decoration_v1{}.events))==32)
#assert(align_of(type_of(wlr_xdg_toplevel_decoration_v1{}.events))==8)
#assert(offset_of(type_of(wlr_xdg_toplevel_decoration_v1{}.events),destroy)==0)
#assert(offset_of(type_of(wlr_xdg_toplevel_decoration_v1{}.events),request_mode)==16)
