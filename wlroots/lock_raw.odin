package wlroots

import wl "../wayland"


wlr_session_lock_manager_v1 :: struct #align(8) {
    _opaque_0: [8]u8,
    events: struct { new_lock: wl.Signal, _opaque_16: [16]u8 },
    _opaque_40: [32]u8,
}
wlr_session_lock_v1 :: struct #align(8) {
    _opaque_0: [24]u8,
    events: struct { new_surface, unlock, destroy: wl.Signal },
    _opaque_72: [16]u8,
}
wlr_session_lock_surface_v1 :: struct #align(8) {
    _opaque_0: [24]u8,
    output: ^wlr_output,
    surface: ^wlr_surface,
    _opaque_40: [48]u8,
    events: struct { destroy: wl.Signal },
    _opaque_104: [72]u8,
}
wlr_output_event_present :: struct #align(8) {
    _opaque_0: [8]u8,
    commit_seq: u32,
    presented: bool,
    _opaque_13: [35]u8,
}
foreign import lock_lib "system:wlroots-0.20"
foreign lock_lib {
    wlr_output_is_x11 :: proc(output: ^wlr_output) -> bool ---
    wlr_output_effective_resolution :: proc(output: ^wlr_output, width,height:^i32) ---
    wlr_output_transformed_resolution :: proc(output: ^wlr_output, width,height:^i32) ---
    wlr_session_lock_manager_v1_create :: proc(display: ^wl.Display) -> ^wlr_session_lock_manager_v1 ---
    wlr_session_lock_v1_send_locked :: proc(lock: ^wlr_session_lock_v1) ---
    wlr_session_lock_v1_destroy :: proc(lock: ^wlr_session_lock_v1) ---
    wlr_session_lock_surface_v1_configure :: proc(surface: ^wlr_session_lock_surface_v1, width,height: u32) -> u32 ---
    wlr_seat_keyboard_end_grab :: proc(seat: ^wlr_seat) ---
    wlr_seat_pointer_end_grab :: proc(seat: ^wlr_seat) ---
}
#assert(size_of(wlr_session_lock_manager_v1)==72 && align_of(wlr_session_lock_manager_v1)==8)
#assert(offset_of(wlr_session_lock_manager_v1,events)==8)
#assert(size_of(type_of(wlr_session_lock_manager_v1{}.events))==32 && align_of(type_of(wlr_session_lock_manager_v1{}.events))==8)
#assert(offset_of(type_of(wlr_session_lock_manager_v1{}.events),new_lock)==0)
#assert(size_of(wlr_session_lock_v1)==88 && align_of(wlr_session_lock_v1)==8)
#assert(offset_of(wlr_session_lock_v1,events)==24)
#assert(size_of(type_of(wlr_session_lock_v1{}.events))==48 && align_of(type_of(wlr_session_lock_v1{}.events))==8)
#assert(offset_of(type_of(wlr_session_lock_v1{}.events),new_surface)==0 && offset_of(type_of(wlr_session_lock_v1{}.events),unlock)==16 && offset_of(type_of(wlr_session_lock_v1{}.events),destroy)==32)
#assert(size_of(wlr_session_lock_surface_v1)==176 && align_of(wlr_session_lock_surface_v1)==8)
#assert(offset_of(wlr_session_lock_surface_v1,output)==24 && offset_of(wlr_session_lock_surface_v1,surface)==32 && offset_of(wlr_session_lock_surface_v1,events)==88)
#assert(size_of(type_of(wlr_session_lock_surface_v1{}.events))==16 && align_of(type_of(wlr_session_lock_surface_v1{}.events))==8)
#assert(offset_of(type_of(wlr_session_lock_surface_v1{}.events),destroy)==0)
#assert(size_of(wlr_output_event_present)==48 && align_of(wlr_output_event_present)==8)
#assert(offset_of(wlr_output_event_present,commit_seq)==8 && offset_of(wlr_output_event_present,presented)==12)
