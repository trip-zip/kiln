package wlroots

import wl "../wayland"
import "base:runtime"
import "core:math"


Box :: wlr_box
Render_Buffer :: wlr_buffer
Surface :: wlr_surface
surface_each :: wlr_surface_for_each_surface
xdg_popups :: wlr_xdg_surface_for_each_popup_surface
layer_popups :: wlr_layer_surface_v1_for_each_popup_surface
surface_at :: wlr_surface_surface_at
buffer_retain :: wlr_buffer_lock
buffer_release :: wlr_buffer_unlock
surface_enter :: wlr_surface_send_enter
surface_leave :: wlr_surface_send_leave
surface_frame_done :: wlr_surface_send_frame_done
surface_source :: proc(surface: ^Surface) -> wlr_fbox {
	box: wlr_fbox
	wlr_surface_get_buffer_source_box(surface, &box)
	return box
}
output_buffer :: wlr_output_state_set_buffer

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
	for head in ([]^wl.List{&surface.current.subsurfaces_below, &surface.current.subsurfaces_above}) {
		if head.next == nil {continue}
		for link := head.next; link != head; link = link.next {
			state := runtime.container_of(link, wlr_subsurface_parent_state, "link")
			sub := runtime.container_of(state, wlr_subsurface, "current")
			surface_known(sub.surface, iterator, data)
		}
	}
}
