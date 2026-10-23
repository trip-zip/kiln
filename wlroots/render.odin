package wlroots

import wl "../wayland_server"
import "base:runtime"
import "core:math"


Pass :: wlr_render_pass
Region :: pixman_region32_t
Box :: wlr_box
Texture :: wlr_texture
Render_Buffer :: wlr_buffer
Surface :: wlr_surface

// The only pixman ownership is the clip required by the render-pass ABI.
clip_begin :: proc(region: ^Region, boxes: []Box) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	rects := make([]pixman_box32_t, len(boxes), context.temp_allocator)
	for box, i in boxes {rects[i] = {box.x, box.y, box.x + box.width, box.y + box.height}}
	return pixman_region32_init_rects(region, raw_data(rects), i32(len(rects))) != 0
}
clip_finish :: pixman_region32_fini
surface_each :: wlr_surface_for_each_surface
xdg_popups :: wlr_xdg_surface_for_each_popup_surface
layer_popups :: wlr_layer_surface_v1_for_each_popup_surface
surface_at :: wlr_surface_surface_at
swapchain_contains :: wlr_swapchain_has_buffer
buffer_retain :: wlr_buffer_lock
buffer_release :: wlr_buffer_unlock
texture_create :: wlr_texture_from_buffer
texture_destroy :: wlr_texture_destroy
surface_texture :: wlr_surface_get_texture
surface_enter :: wlr_surface_send_enter
surface_leave :: wlr_surface_send_leave
surface_frame_done :: wlr_surface_send_frame_done
surface_source :: proc(surface: ^Surface) -> wlr_fbox {
	box: wlr_fbox
	wlr_surface_get_buffer_source_box(surface, &box)
	return box
}
transform_invert :: wlr_output_transform_invert
transform_compose :: wlr_output_transform_compose
transform_box :: proc(box: Box, transform, width, height: i32) -> Box {
	box := box
	out: Box
	wlr_box_transform(&out, &box, transform, width, height)
	return out
}
output_acquire :: proc(output: ^wlr_output, state: ^wlr_output_state) -> (^Render_Buffer, bool) {
	if !wlr_output_configure_primary_swapchain(output, state, &output.swapchain) { return nil, false }
	buffer := wlr_swapchain_acquire(output.swapchain)
	return buffer, buffer != nil
}
pass_begin :: proc(renderer: ^wlr_renderer, buffer: ^Render_Buffer, color_transform: rawptr = nil) -> (^Pass, bool) {
	options := wlr_buffer_pass_options{color_transform=color_transform}
	pass := wlr_renderer_begin_buffer_pass(renderer, buffer, &options)
	return pass, pass != nil
}
pass_rect :: proc(pass: ^Pass, box: Box, color: [4]f32, clip: ^Region, clear: bool = false) {
	options := wlr_render_rect_options{box=box, color={color[0],color[1],color[2],color[3]}, clip=clip}
	if clear {options.blend_mode = 1}
	wlr_render_pass_add_rect(pass, &options)
}
pass_texture :: proc(pass: ^Pass, texture: ^Texture, source: wlr_fbox, dest: Box, clip: ^Region, transform: i32 = 0) {
	options := wlr_render_texture_options{texture=texture, src_box=source, dst_box=dest, clip=clip, transform=transform}
	wlr_render_pass_add_texture(pass, &options)
}
pass_submit :: wlr_render_pass_submit
pass_cursors :: wlr_output_add_software_cursors_to_render_pass
output_buffer :: wlr_output_state_set_buffer
output_damage :: wlr_output_state_set_damage
color_release :: proc(transform: rawptr) {
	if transform != nil { wlr_color_transform_unref(transform) }
}
gamma_transform :: proc(manager: ^wlr_gamma_control_manager_v1, output: ^wlr_output) -> rawptr {
	if manager == nil {return nil}
	control := wlr_gamma_control_manager_v1_get_control(manager, output)
	if control == nil {return nil}
	return wlr_gamma_control_v1_get_color_transform(control)
}
read_pixels :: proc(texture: ^Texture, data: rawptr, stride: u32) -> bool {
	options := wlr_texture_read_pixels_options{data=data, format=0x34325241, stride=stride}
	return wlr_texture_read_pixels(texture, &options)
}

surface_density :: proc(surface: ^Surface, outputs: []^wlr_output) {
	scale: f32 = 1
	transform: i32
	for output in outputs {
		if output.scale >= scale { scale, transform = output.scale, output.transform }
	}
	wlr_surface_set_preferred_buffer_scale(surface, i32(math.ceil(scale)))
	wlr_surface_set_preferred_buffer_transform(surface, transform)
	wlr_fractional_scale_v1_notify_scale(surface, f64(scale))
}

// Include unmapped children so their first desynchronized map can wake the output.
surface_known :: proc(surface: ^Surface, iterator: surface_iterator, data: rawptr) {
	iterator(surface, 0, 0, data)
	for head in ([]^wl.wl_list{&surface.current.subsurfaces_below, &surface.current.subsurfaces_above}) {
		if head.next == nil {continue}
		for link := head.next; link != head; link = link.next {
			state := runtime.container_of(link, wlr_subsurface_parent_state, "link")
			sub := runtime.container_of(state, wlr_subsurface, "current")
			surface_known(sub.surface, iterator, data)
		}
	}
}
