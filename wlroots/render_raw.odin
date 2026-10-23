package wlroots

import "core:sys/posix"
import wl "../wayland_server"

wlr_render_pass :: struct {}
wlr_buffer_pass_options :: struct {
	timer, color_transform, signal_timeline: rawptr,
	signal_point: u64,
}
wlr_render_color :: struct { r,g,b,a: f32 }
wlr_render_rect_options :: struct {
	box: wlr_box,
	color: wlr_render_color,
	clip: ^pixman_region32_t,
	blend_mode: i32,
}
wlr_render_texture_options :: struct {
	texture: ^wlr_texture,
	src_box: wlr_fbox,
	dst_box: wlr_box,
	alpha: ^f32,
	clip: ^pixman_region32_t,
	transform, filter_mode, blend_mode, transfer_function: i32,
	primaries: rawptr,
	color_encoding, color_range: i32,
	luminance_multiplier: ^f32,
	wait_timeline: rawptr,
	wait_point: u64,
}
wlr_xdg_popup_state :: struct { geometry: wlr_box, reactive: bool }
wlr_gamma_control_v1 :: struct {}
wlr_gamma_control_manager_v1_set_gamma_event :: struct { output: ^wlr_output, control: ^wlr_gamma_control_v1 }

foreign import render_lib "system:wlroots-0.20"
surface_iterator :: #type proc "c" (surface: ^wlr_surface, x, y: i32, data: rawptr)
foreign render_lib {
	wlr_xdg_surface_for_each_popup_surface :: proc(surface: ^wlr_xdg_surface, iterator: surface_iterator, data: rawptr) ---
	wlr_surface_for_each_surface :: proc(surface: ^wlr_surface, iterator: surface_iterator, data: rawptr) ---
	wlr_layer_surface_v1_for_each_popup_surface :: proc(surface: ^wlr_layer_surface_v1, iterator: surface_iterator,
	data: rawptr) ---
	wlr_surface_surface_at :: proc(surface: ^wlr_surface, x, y: f64, sx, sy: ^f64) -> ^wlr_surface ---
	wlr_renderer_begin_buffer_pass :: proc(renderer:^wlr_renderer,buffer:^wlr_buffer,
	options:^wlr_buffer_pass_options)->^wlr_render_pass ---
	wlr_render_pass_add_rect :: proc(pass:^wlr_render_pass,options:^wlr_render_rect_options) ---
	wlr_render_pass_add_texture :: proc(pass:^wlr_render_pass,options:^wlr_render_texture_options) ---
	wlr_render_pass_submit :: proc(pass:^wlr_render_pass)->bool ---
	wlr_output_state_set_buffer :: proc(state:^wlr_output_state,buffer:^wlr_buffer) ---
	wlr_output_state_set_damage :: proc(state:^wlr_output_state,damage:^pixman_region32_t) ---
	wlr_output_configure_primary_swapchain :: proc(output:^wlr_output,state:^wlr_output_state,
	swapchain:^^wlr_swapchain)->bool ---
	wlr_swapchain_has_buffer :: proc(swapchain: ^wlr_swapchain, buffer: ^wlr_buffer) -> bool ---
	wlr_swapchain_acquire :: proc(swapchain:^wlr_swapchain)->^wlr_buffer ---
	wlr_output_add_software_cursors_to_render_pass :: proc(output:^wlr_output,pass:^wlr_render_pass,
	damage:^pixman_region32_t) ---
	wlr_surface_send_frame_done :: proc(surface:^wlr_surface,now:^posix.timespec) ---
	wlr_surface_get_texture :: proc(surface:^wlr_surface)->^wlr_texture ---
	wlr_surface_get_buffer_source_box :: proc(surface:^wlr_surface,box:^wlr_fbox) ---
	wlr_surface_set_preferred_buffer_scale :: proc(surface:^wlr_surface,scale:i32) ---
	wlr_surface_set_preferred_buffer_transform :: proc(surface:^wlr_surface,transform:i32) ---
	wlr_fractional_scale_v1_notify_scale :: proc(surface:^wlr_surface,scale:f64) ---
	wlr_surface_send_enter :: proc(surface:^wlr_surface,output:^wlr_output) ---
	wlr_surface_send_leave :: proc(surface:^wlr_surface,output:^wlr_output) ---
	wlr_box_transform :: proc(dest,source:^wlr_box,transform,width,height:i32) ---
	wlr_output_transform_invert :: proc(transform:i32)->i32 ---
	wlr_output_transform_compose :: proc(a,b:i32)->i32 ---
	wlr_gamma_control_manager_v1_get_control :: proc(manager:^wlr_gamma_control_manager_v1,
	output:^wlr_output)->^wlr_gamma_control_v1 ---
	wlr_gamma_control_v1_get_color_transform :: proc(control:^wlr_gamma_control_v1)->rawptr ---
	wlr_color_transform_unref :: proc(transform:rawptr) ---
}
foreign import pixman_lib "system:pixman-1"
pixman_box32_t :: struct { x1, y1, x2, y2: i32 }
#assert(size_of(pixman_box32_t) == 16 && align_of(pixman_box32_t) == 4)
#assert(offset_of(pixman_box32_t, x1) == 0 && offset_of(pixman_box32_t, y1) == 4)
#assert(offset_of(pixman_box32_t, x2) == 8 && offset_of(pixman_box32_t, y2) == 12)
foreign pixman_lib {
	pixman_region32_init_rects :: proc(region: ^pixman_region32_t, boxes: [^]pixman_box32_t, count: i32) -> i32 ---
	pixman_region32_fini :: proc(region:^pixman_region32_t) ---
}

// Pins measured from the installed wlroots 0.20.2 headers.
#assert(size_of(wlr_buffer_pass_options)==32 && align_of(wlr_buffer_pass_options)==8)
#assert(offset_of(wlr_buffer_pass_options,timer)==0 && offset_of(wlr_buffer_pass_options,color_transform)==8)
#assert(offset_of(wlr_buffer_pass_options,signal_timeline)==16 && offset_of(wlr_buffer_pass_options,signal_point)==24)
#assert(size_of(wlr_render_color)==16 && align_of(wlr_render_color)==4)
#assert(offset_of(wlr_render_color,r)==0 && offset_of(wlr_render_color,g)==4 && offset_of(wlr_render_color,b)==8)
#assert(offset_of(wlr_render_color,a)==12)
#assert(size_of(wlr_render_rect_options)==48 && align_of(wlr_render_rect_options)==8)
#assert(offset_of(wlr_render_rect_options,box)==0 && offset_of(wlr_render_rect_options,color)==16)
#assert(offset_of(wlr_render_rect_options,clip)==32 && offset_of(wlr_render_rect_options,blend_mode)==40)
#assert(size_of(wlr_render_texture_options)==128 && align_of(wlr_render_texture_options)==8)
#assert(offset_of(wlr_render_texture_options,texture)==0 && offset_of(wlr_render_texture_options,src_box)==8)
#assert(offset_of(wlr_render_texture_options,dst_box)==40 && offset_of(wlr_render_texture_options,alpha)==56)
#assert(offset_of(wlr_render_texture_options,clip)==64 && offset_of(wlr_render_texture_options,transform)==72)
#assert(offset_of(wlr_render_texture_options,filter_mode)==76 && offset_of(wlr_render_texture_options,blend_mode)==80)
#assert(offset_of(wlr_render_texture_options,transfer_function)==84)
#assert(offset_of(wlr_render_texture_options,primaries)==88 && offset_of(wlr_render_texture_options,color_encoding)==96)
#assert(offset_of(wlr_render_texture_options,color_range)==100)
#assert(offset_of(wlr_render_texture_options,luminance_multiplier)==104)
#assert(offset_of(wlr_render_texture_options,wait_timeline)==112)
#assert(offset_of(wlr_render_texture_options,wait_point)==120)
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
