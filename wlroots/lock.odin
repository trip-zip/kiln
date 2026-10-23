package wlroots

import wl "../wayland_server"
import "core:math"

lock_manager_create :: proc(display: ^wl.wl_display) -> ^wlr_session_lock_manager_v1 { return wlr_session_lock_manager_v1_create(display) }
lock_reject :: proc(lock: ^wlr_session_lock_v1) { wlr_session_lock_v1_destroy(lock) }
lock_acknowledge :: proc(lock: ^wlr_session_lock_v1) { wlr_session_lock_v1_send_locked(lock) }
lock_configure :: proc(surface: ^wlr_session_lock_surface_v1, width,height: i32) { wlr_session_lock_surface_v1_configure(surface,u32(max(1,width)),u32(max(1,height))) }
seat_end_grabs :: proc(seat: ^wlr_seat) {
    wlr_seat_keyboard_end_grab(seat)
    wlr_seat_pointer_end_grab(seat)
}

output_logical_size :: proc(output: ^wlr_output) -> (width,height:i32) { wlr_output_effective_resolution(output,&width,&height);return }

output_cover_size :: proc(output: ^wlr_output) -> (width,height:i32) {
    wlr_output_transformed_resolution(output,&width,&height)
    // Effective layout dimensions truncate; opaque coverage must include edge pixels.
    return i32(math.ceil(f64(width)/f64(output.scale))),i32(math.ceil(f64(height)/f64(output.scale)))
}

lock_next_sequence :: proc(output: ^wlr_output) -> u32 {
    // X11 submits its Present serial before the common commit counter advances.
    if wlr_output_is_x11(output) { return output.commit_seq }
    return output.commit_seq+1
}
