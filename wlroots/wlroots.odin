package wlroots

import "core:c"
import li "../libinput"
import wl "../wayland"

foreign import lib "system:wlroots-0.20"

wlr_output_mode :: struct {
	width, height, refresh: i32,
	_opaque_12: [12]u8,
	link: wl.List,
}
#assert(size_of(wlr_output_mode) == 40 && offset_of(wlr_output_mode, width) == 0 && offset_of(wlr_output_mode, height) == 4 && offset_of(wlr_output_mode, refresh) == 8 && offset_of(wlr_output_mode, link) == 24)
wlr_output_layout_output :: struct {}

wlr_compositor :: struct {
	_opaque_0:  [16]u8,
	events:     struct {
		new_surface: wl.Signal,
		_opaque_16: [16]u8,
	},
	_opaque_48: [48]u8,
}
#assert(size_of(wlr_compositor) == 96 && align_of(wlr_compositor) == 8 && offset_of(wlr_compositor, events) == 16)
wlr_subcompositor :: struct {}
WLR_INPUT_DEVICE_KEYBOARD :: 0
WLR_INPUT_DEVICE_POINTER :: 1

foreign lib {
	wlr_keyboard_led_update :: proc(keyboard: ^wlr_keyboard, leds: u32) ---
	wlr_output_layout_closest_point :: proc(layout: ^wlr_output_layout, output: ^wlr_output, x, y: f64, lx, ly: ^f64) ---
	wlr_output_layout_contains_point :: proc(layout: ^wlr_output_layout, output: ^wlr_output, x, y: i32) -> bool ---
	wlr_input_device_is_libinput :: proc(device: ^wlr_input_device) -> bool ---
	wlr_libinput_get_device_handle :: proc(device: ^wlr_input_device) -> ^li.libinput_device ---
	wlr_output_schedule_frame :: proc(output: ^wlr_output) ---
	wlr_output_update_needs_frame :: proc(output: ^wlr_output) ---
	wlr_output_layout_get_box :: proc(layout: ^wlr_output_layout, output: ^wlr_output, box: ^wlr_box) ---
	wlr_output_layout_output_at :: proc(layout: ^wlr_output_layout, x, y: f64) -> ^wlr_output ---

	wlr_backend_autocreate :: proc(loop: ^wl.Loop, session_ptr: ^^wlr_session) -> ^wlr_backend ---
	wlr_backend_start :: proc(backend: ^wlr_backend) -> bool ---
	wlr_backend_destroy :: proc(backend: ^wlr_backend) ---
	wlr_compositor_create :: proc(display: ^wl.Display, version: u32, renderer: rawptr) -> ^wlr_compositor ---
	wlr_subcompositor_create :: proc(display: ^wl.Display) -> ^wlr_subcompositor ---

	wlr_output_layout_create :: proc(display: ^wl.Display) -> ^wlr_output_layout ---
	wlr_output_layout_destroy :: proc(layout: ^wlr_output_layout) ---
	wlr_output_layout_add_auto :: proc(layout: ^wlr_output_layout, output: ^wlr_output) -> ^wlr_output_layout_output ---
	wlr_output_preferred_mode :: proc(output: ^wlr_output) -> ^wlr_output_mode ---
	wlr_output_commit_state :: proc(output: ^wlr_output, state: ^wlr_output_state) -> bool ---
	wlr_output_state_init :: proc(state: ^wlr_output_state) ---
	wlr_output_state_finish :: proc(state: ^wlr_output_state) ---
	wlr_output_state_set_enabled :: proc(state: ^wlr_output_state, enabled: bool) ---
	wlr_output_state_set_mode :: proc(state: ^wlr_output_state, mode: ^wlr_output_mode) ---
	wlr_output_state_set_custom_mode :: proc(state: ^wlr_output_state, width, height, refresh: i32) ---
	wlr_output_state_set_scale :: proc(state: ^wlr_output_state, scale: f32) ---
	wlr_output_state_set_adaptive_sync_enabled :: proc(state: ^wlr_output_state, enabled: bool) ---
	wlr_output_layout_add :: proc(layout: ^wlr_output_layout, output: ^wlr_output, x, y: c.int) -> ^wlr_output_layout_output ---

	wlr_keyboard_from_input_device :: proc(device: ^wlr_input_device) -> ^wlr_keyboard ---

	wlr_pointer_from_input_device :: proc(device: ^wlr_input_device) -> ^wlr_pointer ---
}
