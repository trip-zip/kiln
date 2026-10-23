package wlroots

import "core:c"
import wl "../wayland"

wlr_layer_shell_v1 :: struct #align(8) {
    _opaque_0: [8]u8,
    events: struct { new_surface, destroy: wl.Signal },
    _opaque_40: [32]u8,
}
wlr_layer_surface_v1_state :: struct {
    committed, anchor: u32,
    exclusive_zone: i32,
    margin: struct { top, right, bottom, left: i32 },
    keyboard_interactive: c.int,
    desired_width, desired_height: u32,
    layer: c.int,
    exclusive_edge, configure_serial, actual_width, actual_height: u32,
}
wlr_layer_surface_v1 :: struct #align(8) {
    surface: ^wlr_surface,
    output: ^wlr_output,
	_opaque_16: [16]u8,
	popups: wl.List,
    namespace: cstring,
    _opaque_56: [24]u8,
    current, pending: wlr_layer_surface_v1_state,
    initialized, initial_commit: bool,
    _opaque_202: [6]u8,
    events: struct { destroy, new_popup: wl.Signal },
    data: rawptr,
    _opaque_248: [40]u8,
}
foreign import layer_lib "system:wlroots-0.20"
foreign layer_lib {
    wlr_layer_shell_v1_create :: proc(display: ^wl.Display, version: u32) -> ^wlr_layer_shell_v1 ---
    wlr_layer_surface_v1_configure :: proc(surface: ^wlr_layer_surface_v1, width, height: u32) -> u32 ---
    wlr_layer_surface_v1_destroy :: proc(surface: ^wlr_layer_surface_v1) ---
}

// Protocol version four deliberately excludes exclusive-edge requests.
layer_shell_create :: proc(display: ^wl.Display) -> ^wlr_layer_shell_v1 {
    return wlr_layer_shell_v1_create(display, 4)
}
layer_configure :: proc(surface: ^wlr_layer_surface_v1, width, height: u32) {
    wlr_layer_surface_v1_configure(surface, width, height)
}
#assert(size_of(wlr_layer_shell_v1) == 72 && align_of(wlr_layer_shell_v1) == 8)
#assert(offset_of(wlr_layer_shell_v1, events) == 8)
#assert(size_of(wlr_layer_surface_v1_state) == 60 && align_of(wlr_layer_surface_v1_state) == 4)
#assert(offset_of(wlr_layer_surface_v1_state, committed) == 0 && offset_of(wlr_layer_surface_v1_state, anchor) == 4)
#assert(offset_of(wlr_layer_surface_v1_state, exclusive_zone) == 8)
#assert(offset_of(wlr_layer_surface_v1_state, margin) == 12)
#assert(offset_of(wlr_layer_surface_v1_state, keyboard_interactive) == 28)
#assert(offset_of(wlr_layer_surface_v1_state, desired_width) == 32)
#assert(offset_of(wlr_layer_surface_v1_state, desired_height) == 36)
#assert(offset_of(wlr_layer_surface_v1_state, layer) == 40)
#assert(offset_of(wlr_layer_surface_v1_state, exclusive_edge) == 44)
#assert(offset_of(wlr_layer_surface_v1_state, configure_serial) == 48)
#assert(offset_of(wlr_layer_surface_v1_state, actual_width) == 52)
#assert(offset_of(wlr_layer_surface_v1_state, actual_height) == 56)
#assert(size_of(wlr_layer_surface_v1) == 288 && align_of(wlr_layer_surface_v1) == 8)
#assert(offset_of(wlr_layer_surface_v1, surface) == 0 && offset_of(wlr_layer_surface_v1, output) == 8)
#assert(offset_of(wlr_layer_surface_v1, namespace) == 48 && offset_of(wlr_layer_surface_v1, current) == 80)
#assert(offset_of(wlr_layer_surface_v1, pending) == 140 && offset_of(wlr_layer_surface_v1, initialized) == 200)
#assert(offset_of(wlr_layer_surface_v1, initial_commit) == 201 && offset_of(wlr_layer_surface_v1, events) == 208)
#assert(offset_of(wlr_layer_surface_v1, data) == 240)

layer_close :: proc(surface: ^wlr_layer_surface_v1) { wlr_layer_surface_v1_destroy(surface) }
#assert(size_of(type_of(wlr_layer_shell_v1{}.events))==32)
#assert(align_of(type_of(wlr_layer_shell_v1{}.events))==8)
#assert(offset_of(type_of(wlr_layer_shell_v1{}.events),new_surface)==0)
#assert(offset_of(type_of(wlr_layer_shell_v1{}.events),destroy)==16)
#assert(size_of(type_of(wlr_layer_surface_v1{}.events))==32)
#assert(align_of(type_of(wlr_layer_surface_v1{}.events))==8)
#assert(offset_of(type_of(wlr_layer_surface_v1{}.events),destroy)==0)
#assert(offset_of(type_of(wlr_layer_surface_v1{}.events),new_popup)==16)
#assert(size_of(type_of(wlr_layer_surface_v1_state{}.margin))==16)
#assert(align_of(type_of(wlr_layer_surface_v1_state{}.margin))==4)
#assert(offset_of(type_of(wlr_layer_surface_v1_state{}.margin),top)==0)
#assert(offset_of(type_of(wlr_layer_surface_v1_state{}.margin),right)==4)
#assert(offset_of(type_of(wlr_layer_surface_v1_state{}.margin),bottom)==8)
#assert(offset_of(type_of(wlr_layer_surface_v1_state{}.margin),left)==12)
