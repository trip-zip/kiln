package wlroots

import "core:sys/posix"
import wl "../wayland"

foreign import surface_lib "system:wlroots-0.20"
surface_iterator :: #type proc "c" (surface: ^wlr_surface, x, y: i32, data: rawptr)
foreign surface_lib {
	wlr_surface_get_root_surface :: proc(surface: ^wlr_surface) -> ^wlr_surface ---
	wlr_output_schedule_done :: proc(output: ^wlr_output) ---
	wlr_surface_for_each_surface :: proc(surface: ^wlr_surface, iterator: surface_iterator, data: rawptr) ---
	wlr_surface_surface_at :: proc(surface: ^wlr_surface, x, y: f64, sx, sy: ^f64) -> ^wlr_surface ---
	wlr_output_state_set_buffer :: proc(state:^wlr_output_state,buffer:^wlr_buffer) ---
	wlr_surface_send_frame_done :: proc(surface:^wlr_surface,now:^posix.timespec) ---
	wlr_surface_get_buffer_source_box :: proc(surface:^wlr_surface,box:^wlr_fbox) ---
	wlr_surface_set_preferred_buffer_scale :: proc(surface:^wlr_surface,scale:i32) ---
	wlr_surface_set_preferred_buffer_transform :: proc(surface:^wlr_surface,transform:i32) ---
	wlr_fractional_scale_v1_notify_scale :: proc(surface:^wlr_surface,scale:f64) ---
	wlr_surface_send_enter :: proc(surface:^wlr_surface,output:^wlr_output) ---
	wlr_surface_send_leave :: proc(surface:^wlr_surface,output:^wlr_output) ---
}
#assert(offset_of(wlr_surface_state,dx)==16 && offset_of(wlr_surface_state,dy)==20 && offset_of(wlr_surface_state,transform)==120 && offset_of(wlr_surface_state,subsurfaces_below)==160 && offset_of(wlr_surface_state,subsurfaces_above)==176)
#assert(offset_of(wlr_output,needs_frame)==185 && offset_of(wlr_output,swapchain)==456 && offset_of(wlr_output_events,needs_frame)==32 && offset_of(wlr_surface_events,destroy)==80)

// Only the current relationship is read; wlroots owns both state and lifetime.
wlr_subsurface_parent_state :: struct {
	x, y: i32,
	link: wl.List,
	_opaque_24: [8]u8,
}
wlr_subsurface :: struct {
	_opaque_0: [8]u8,
	surface: ^wlr_surface,
	_opaque_16: [8]u8,
	current: wlr_subsurface_parent_state,
	_opaque_56: [152]u8,
}
#assert(size_of(wlr_subsurface_parent_state)==32 && align_of(wlr_subsurface_parent_state)==8 && offset_of(wlr_subsurface_parent_state,x)==0 && offset_of(wlr_subsurface_parent_state,y)==4 && offset_of(wlr_subsurface_parent_state,link)==8)
#assert(size_of(wlr_subsurface)==208 && align_of(wlr_subsurface)==8 && offset_of(wlr_subsurface,surface)==8 && offset_of(wlr_subsurface,current)==24 && offset_of(wlr_surface,input_region)==72)
