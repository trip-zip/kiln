package wlroots

import wl "../wayland"

foreign import lib "system:wlroots-0.20"
foreign lib {
	wlr_output_from_resource :: proc(resource: ^wl.Resource) -> ^wlr_output ---
}
