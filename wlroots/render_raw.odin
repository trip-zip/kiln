package wlroots

import "core:sys/posix"
import wl "../wayland_server"

wlr_xdg_popup_state :: struct { geometry: wlr_box, reactive: bool,
}
wlr_gamma_control_manager_v1_set_gamma_event :: struct { output: ^wlr_output, control: ^wlr_gamma_control_v1 }

foreign import render_lib "system:wlroots-0.20"
surface_iterator :: #type proc "c" (surface: ^wlr_surface, x, y: i32, data: rawptr)
foreign render_lib {
	wlr_xdg_surface_for_each_popup_surface :: proc(surface: ^wlr_xdg_surface, iterator: surface_iterator, data: rawptr) ---
	wlr_surface_for_each_surface :: proc(surface: ^wlr_surface, iterator: surface_iterator, data: rawptr) ---
	wlr_layer_surface_v1_for_each_popup_surface :: proc(surface: ^wlr_layer_surface_v1, iterator: surface_iterator,
	data: rawptr) ---
	wlr_surface_surface_at :: proc(surface: ^wlr_surface, x, y: f64, sx, sy: ^f64) -> ^wlr_surface ---
	wlr_output_state_set_buffer :: proc(state:^wlr_output_state,buffer:^wlr_buffer) ---
	wlr_surface_send_frame_done :: proc(surface:^wlr_surface,now:^posix.timespec) ---
	wlr_surface_get_buffer_source_box :: proc(surface:^wlr_surface,box:^wlr_fbox) ---
	wlr_surface_set_preferred_buffer_scale :: proc(surface:^wlr_surface,scale:i32) ---
	wlr_surface_set_preferred_buffer_transform :: proc(surface:^wlr_surface,transform:i32) ---
	wlr_fractional_scale_v1_notify_scale :: proc(surface:^wlr_surface,scale:f64) ---
	wlr_surface_send_enter :: proc(surface:^wlr_surface,output:^wlr_output) ---
	wlr_surface_send_leave :: proc(surface:^wlr_surface,output:^wlr_output) ---
	wlr_gamma_control_manager_v1_get_control :: proc(manager:^wlr_gamma_control_manager_v1,
	output:^wlr_output)->^wlr_gamma_control_v1 ---
}
#assert(offset_of(wlr_surface_state,dx)==16 && offset_of(wlr_surface_state,dy)==20)
#assert(offset_of(wlr_surface_state,transform)==120 && offset_of(wlr_surface_state,scale)==124)
#assert(offset_of(wlr_surface_state,subsurfaces_below)==160 && offset_of(wlr_surface_state,subsurfaces_above)==176)
#assert(size_of(wlr_xdg_popup_state)==20 && align_of(wlr_xdg_popup_state)==4)
#assert(offset_of(wlr_xdg_popup_state,geometry)==0 && offset_of(wlr_xdg_popup_state,reactive)==16)
#assert(offset_of(wlr_xdg_popup,current)==132)
#assert(size_of(wlr_drag_icon)==64 && align_of(wlr_drag_icon)==8)
#assert(offset_of(wlr_drag_icon,surface)==8 && offset_of(wlr_drag_icon,events)==16)
#assert(offset_of(wlr_output,needs_frame)==185 && offset_of(wlr_output,swapchain)==456)
#assert(offset_of(wlr_gamma_control_manager_v1,events)==32)
#assert(size_of(wlr_gamma_control_manager_v1_set_gamma_event)==16 &&
	align_of(wlr_gamma_control_manager_v1_set_gamma_event)==8)
#assert(offset_of(wlr_gamma_control_manager_v1_set_gamma_event,output)==0)
#assert(offset_of(wlr_gamma_control_manager_v1_set_gamma_event,control)==8)
#assert(offset_of(wlr_output_events,damage)==16 && offset_of(wlr_output_events,needs_frame)==32)
#assert(offset_of(wlr_surface_events,destroy)==80)
#assert(size_of(type_of(wlr_drag_icon{}.events))==16 && offset_of(type_of(wlr_drag_icon{}.events),destroy)==0)
#assert(size_of(type_of(wlr_gamma_control_manager_v1{}.events))==32)
#assert(offset_of(type_of(wlr_gamma_control_manager_v1{}.events),destroy)==0 &&
	offset_of(type_of(wlr_gamma_control_manager_v1{}.events),set_gamma)==16)

// Only the current relationship is read; wlroots owns both state and lifetime.
wlr_subsurface_parent_state :: struct {
	x, y: i32,
	link: wl.wl_list,
	_opaque_24: [8]u8,
}
wlr_subsurface :: struct {
	_opaque_0: [8]u8,
	surface: ^wlr_surface,
	_opaque_16: [8]u8,
	current: wlr_subsurface_parent_state,
	_opaque_56: [152]u8,
}
#assert(size_of(wlr_subsurface_parent_state)==32 && align_of(wlr_subsurface_parent_state)==8)
#assert(offset_of(wlr_subsurface_parent_state,x)==0 && offset_of(wlr_subsurface_parent_state,y)==4)
#assert(offset_of(wlr_subsurface_parent_state,link)==8)
#assert(size_of(wlr_subsurface)==208 && align_of(wlr_subsurface)==8)
#assert(offset_of(wlr_subsurface,surface)==8 && offset_of(wlr_subsurface,current)==24)
#assert(offset_of(wlr_surface,input_region)==72)
#assert(offset_of(wlr_xdg_surface,popups)==64 && offset_of(wlr_xdg_popup,link)==8)
#assert(offset_of(wlr_layer_surface_v1,popups)==32)
