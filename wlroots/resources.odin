package wlroots

import wl "../wayland"

foreign import lib "system:wlroots-0.20"
foreign lib {
	wlr_output_from_resource :: proc(resource: ^wl.Resource) -> ^wlr_output ---
	wlr_surface_from_resource :: proc(resource: ^wl.Resource) -> ^wlr_surface ---
	wlr_buffer_try_from_resource :: proc(resource: ^wl.Resource) -> ^wlr_buffer ---
}
