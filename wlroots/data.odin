package wlroots

import wl "../wayland"

wlr_primary_selection_source :: struct {}
wlr_primary_selection_v1_device_manager :: struct {}
wlr_drag_icon :: struct {
    _opaque_0: [8]u8,
    surface: ^wlr_surface,
    events: struct { destroy: wl.Signal },
    _opaque_32: [32]u8,
}
wlr_drag :: struct #align(8) {
    _opaque_0: [104]u8,
    icon: ^wlr_drag_icon,
    _opaque_112: [8]u8,
    source: ^wlr_data_source,
    _opaque_128: [16]u8,
    events: struct { _opaque_0: [48]u8, destroy: wl.Signal },
    _opaque_208: [104]u8,
}
wlr_seat_request_start_drag_event :: struct {
    drag: ^wlr_drag,
    origin: ^wlr_surface,
    serial: u32,
}
wlr_seat_request_set_primary_selection_event :: struct {
    source: ^wlr_primary_selection_source,
    serial: u32,
}
foreign import data_lib "system:wlroots-0.20"
foreign data_lib {
    wlr_primary_selection_v1_device_manager_create :: proc(display: ^wl.Display) -> ^wlr_primary_selection_v1_device_manager ---
    wlr_seat_set_primary_selection :: proc(seat: ^wlr_seat, source: ^wlr_primary_selection_source, serial: u32) ---
    wlr_seat_validate_pointer_grab_serial :: proc(seat: ^wlr_seat, origin: ^wlr_surface, serial: u32) -> bool ---
    wlr_seat_start_pointer_drag :: proc(seat: ^wlr_seat, drag: ^wlr_drag, serial: u32) ---
    wlr_data_source_destroy :: proc(source: ^wlr_data_source) ---
}
primary_selection_create :: proc(display: ^wl.Display) -> bool { return wlr_primary_selection_v1_device_manager_create(display)!=nil }
primary_selection_set :: proc(seat: ^wlr_seat, event: ^wlr_seat_request_set_primary_selection_event) { wlr_seat_set_primary_selection(seat,event.source,event.serial) }
pointer_drag_request :: proc(seat: ^wlr_seat, event: ^wlr_seat_request_start_drag_event) {
    if wlr_seat_validate_pointer_grab_serial(seat,event.origin,event.serial) {
        wlr_seat_start_pointer_drag(seat,event.drag,event.serial)
    } else if event.drag.source!=nil { wlr_data_source_destroy(event.drag.source) }
}
#assert(size_of(wlr_drag)==312 && align_of(wlr_drag)==8)
#assert(offset_of(wlr_drag,icon)==104 && offset_of(wlr_drag,source)==120 && offset_of(wlr_drag,events)==144)
#assert(size_of(type_of(wlr_drag{}.events))==64 && align_of(type_of(wlr_drag{}.events))==8)
#assert(offset_of(type_of(wlr_drag{}.events),destroy)==48)
#assert(size_of(wlr_seat_request_start_drag_event)==24 && align_of(wlr_seat_request_start_drag_event)==8)
#assert(offset_of(wlr_seat_request_start_drag_event,drag)==0 && offset_of(wlr_seat_request_start_drag_event,origin)==8)
#assert(offset_of(wlr_seat_request_start_drag_event,serial)==16)
#assert(size_of(wlr_seat_request_set_primary_selection_event)==16 && align_of(wlr_seat_request_set_primary_selection_event)==8)
#assert(offset_of(wlr_seat_request_set_primary_selection_event,source)==0)
#assert(offset_of(wlr_seat_request_set_primary_selection_event,serial)==8)
