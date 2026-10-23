package wlroots

import "core:c"
import li "../libinput"
import wl "../wayland"
import xkb "../xkbcommon"

foreign import lib "system:wlroots-0.20"

wlr_renderer :: struct {}
wlr_allocator :: struct {}
wlr_output_mode :: struct {
	width, height, refresh: i32,
	preferred: bool,
	picture_aspect_ratio: c.int,
	link: wl.List,
}
#assert(size_of(wlr_output_mode) == 40)
#assert(offset_of(wlr_output_mode, width) == 0 && offset_of(wlr_output_mode, height) == 4)
#assert(offset_of(wlr_output_mode, refresh) == 8 && offset_of(wlr_output_mode, preferred) == 12)
#assert(offset_of(wlr_output_mode, picture_aspect_ratio) == 16 && offset_of(wlr_output_mode, link) == 24)
wlr_xdg_output_manager_v1 :: struct {}
wlr_output_layout_output :: struct {}

wlr_compositor :: struct {
	_opaque_0:  [16]u8,
	events:     struct {
		new_surface, destroy: wl.Signal,
	},
	_opaque_48: [48]u8,
}
#assert(size_of(wlr_compositor) == 96 && align_of(wlr_compositor) == 8 && offset_of(wlr_compositor, events) == 16)
wlr_subcompositor :: struct {}
wlr_data_device_manager :: struct {}
wlr_screencopy_manager_v1 :: struct {}
wlr_xcursor_manager :: struct {}
wlr_xcursor :: struct #align(8) { image_count: u32, _pad: [4]u8, images: [^]^wlr_xcursor_image, name: cstring, _opaque: [8]u8 }
wlr_xcursor_image :: struct #align(8) { width,height, hotspot_x, hotspot_y, delay: u32,
	buffer:                                     [^]u8, _opaque: [8]u8 }
#assert(size_of(wlr_xcursor)==32 && align_of(wlr_xcursor)==8)
#assert(offset_of(wlr_xcursor,image_count)==0 && offset_of(wlr_xcursor,images)==8 && offset_of(wlr_xcursor,name)==16)
#assert(size_of(wlr_xcursor_image)==40 && align_of(wlr_xcursor_image)==8)
#assert(offset_of(wlr_xcursor_image,width)==0 && offset_of(wlr_xcursor_image,height)==4)
wlr_seat_client :: struct {}
wlr_data_source :: struct {}

WLR_INPUT_DEVICE_KEYBOARD :: 0
WLR_INPUT_DEVICE_POINTER :: 1
WLR_MODIFIER_ALT :: 1 << 3

foreign lib {
	wlr_seat_pointer_clear_focus :: proc(seat: ^wlr_seat) ---
	wlr_input_device_is_libinput :: proc(device: ^wlr_input_device) -> bool ---
	wlr_libinput_get_device_handle :: proc(device: ^wlr_input_device) -> ^li.libinput_device ---
	wlr_keyboard_notify_modifiers :: proc(keyboard: ^wlr_keyboard, depressed, latched, locked, group: u32) ---
	wlr_xcursor_manager_get_xcursor :: proc(manager: ^wlr_xcursor_manager, name: cstring, scale: f32) -> ^wlr_xcursor ---
	wlr_xcursor_manager_load :: proc(manager: ^wlr_xcursor_manager, scale: f32) -> bool ---
	wlr_xdg_toplevel_send_close :: proc(toplevel: ^wlr_xdg_toplevel) ---
	wlr_output_schedule_frame :: proc(output: ^wlr_output) ---
	wlr_output_layout_get_box :: proc(layout: ^wlr_output_layout, output: ^wlr_output, box: ^wlr_box) ---
	wlr_output_layout_output_at :: proc(layout: ^wlr_output_layout, x, y: f64) -> ^wlr_output ---
	wlr_xdg_toplevel_set_tiled :: proc(toplevel: ^wlr_xdg_toplevel, edges: u32) -> u32 ---

	wlr_xdg_output_manager_v1_create :: proc(display: ^wl.Display, layout: ^wlr_output_layout) -> ^wlr_xdg_output_manager_v1 ---
	wlr_backend_autocreate :: proc(loop: ^wl.Loop, session_ptr: ^^wlr_session) -> ^wlr_backend ---
	wlr_backend_start :: proc(backend: ^wlr_backend) -> bool ---
	wlr_backend_destroy :: proc(backend: ^wlr_backend) ---
	wlr_renderer_autocreate :: proc(backend: ^wlr_backend) -> ^wlr_renderer ---
	wlr_renderer_init_wl_display :: proc(renderer: ^wlr_renderer, display: ^wl.Display) -> bool ---
	wlr_renderer_destroy :: proc(renderer: ^wlr_renderer) ---
	wlr_allocator_autocreate :: proc(backend: ^wlr_backend, renderer: ^wlr_renderer) -> ^wlr_allocator ---
	wlr_allocator_destroy :: proc(allocator: ^wlr_allocator) ---
	wlr_compositor_create :: proc(display: ^wl.Display, version: u32, renderer: ^wlr_renderer) -> ^wlr_compositor ---
	wlr_subcompositor_create :: proc(display: ^wl.Display) -> ^wlr_subcompositor ---
	wlr_data_device_manager_create :: proc(display: ^wl.Display) -> ^wlr_data_device_manager ---
	wlr_screencopy_manager_v1_create :: proc(display: ^wl.Display) -> ^wlr_screencopy_manager_v1 ---

	wlr_output_layout_create :: proc(display: ^wl.Display) -> ^wlr_output_layout ---
	wlr_output_layout_destroy :: proc(layout: ^wlr_output_layout) ---
	wlr_output_layout_add_auto :: proc(layout: ^wlr_output_layout, output: ^wlr_output) -> ^wlr_output_layout_output ---
	wlr_output_init_render :: proc(output: ^wlr_output, allocator: ^wlr_allocator, renderer: ^wlr_renderer) -> bool ---
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


	wlr_xdg_shell_create :: proc(display: ^wl.Display, version: u32) -> ^wlr_xdg_shell ---
	wlr_xdg_toplevel_set_size :: proc(toplevel: ^wlr_xdg_toplevel, width, height: i32) -> u32 ---
	wlr_xdg_toplevel_set_fullscreen :: proc(toplevel: ^wlr_xdg_toplevel, fullscreen: bool) -> u32 ---
	wlr_xdg_toplevel_set_maximized :: proc(toplevel: ^wlr_xdg_toplevel, maximized: bool) -> u32 ---
	wlr_xdg_toplevel_set_suspended :: proc(toplevel: ^wlr_xdg_toplevel, suspended: bool) -> u32 ---
	wlr_xdg_toplevel_set_activated :: proc(toplevel: ^wlr_xdg_toplevel, activated: bool) -> u32 ---
	wlr_xdg_surface_schedule_configure :: proc(surface: ^wlr_xdg_surface) -> u32 ---

	wlr_seat_create :: proc(display: ^wl.Display, name: cstring) -> ^wlr_seat ---
	wlr_seat_set_capabilities :: proc(seat: ^wlr_seat, capabilities: u32) ---
	wlr_seat_set_keyboard :: proc(seat: ^wlr_seat, keyboard: ^wlr_keyboard) ---
	wlr_seat_get_keyboard :: proc(seat: ^wlr_seat) -> ^wlr_keyboard ---
	wlr_seat_keyboard_notify_enter :: proc(seat: ^wlr_seat, surface: ^wlr_surface, keys: [^]u32, count: c.size_t, modifiers: ^wlr_keyboard_modifiers) ---
	wlr_seat_keyboard_notify_clear_focus :: proc(seat: ^wlr_seat) ---
	wlr_seat_keyboard_notify_modifiers :: proc(seat: ^wlr_seat, modifiers: ^wlr_keyboard_modifiers) ---
	wlr_seat_keyboard_notify_key :: proc(seat: ^wlr_seat, time_msec, key, state: u32) ---
	wlr_seat_pointer_notify_enter :: proc(seat: ^wlr_seat, surface: ^wlr_surface, sx, sy: f64) ---
	wlr_seat_pointer_notify_clear_focus :: proc(seat: ^wlr_seat) ---
	wlr_seat_pointer_notify_motion :: proc(seat: ^wlr_seat, time_msec: u32, sx, sy: f64) ---
	wlr_seat_pointer_notify_button :: proc(seat: ^wlr_seat, time_msec, button: u32, state: c.int) -> u32 ---
	wlr_seat_pointer_notify_axis :: proc(seat: ^wlr_seat, time_msec: u32, orientation: c.int, value: f64, discrete: i32, source, relative_direction: c.int) ---
	wlr_seat_pointer_notify_frame :: proc(seat: ^wlr_seat) ---
	wlr_seat_set_selection :: proc(seat: ^wlr_seat, source: ^wlr_data_source, serial: u32) ---

	wlr_keyboard_from_input_device :: proc(device: ^wlr_input_device) -> ^wlr_keyboard ---
	wlr_keyboard_set_keymap :: proc(keyboard: ^wlr_keyboard, keymap: ^xkb.xkb_keymap) -> bool ---
	wlr_keyboard_set_repeat_info :: proc(keyboard: ^wlr_keyboard, rate_hz, delay_ms: i32) ---
	wlr_keyboard_get_modifiers :: proc(keyboard: ^wlr_keyboard) -> u32 ---

	wlr_cursor_create :: proc() -> ^wlr_cursor ---
	wlr_cursor_destroy :: proc(cursor: ^wlr_cursor) ---
	wlr_cursor_attach_output_layout :: proc(cursor: ^wlr_cursor, layout: ^wlr_output_layout) ---
	wlr_cursor_map_input_to_output :: proc(cursor: ^wlr_cursor, device: ^wlr_input_device, output: ^wlr_output) ---
	wlr_pointer_from_input_device :: proc(device: ^wlr_input_device) -> ^wlr_pointer ---
	wlr_cursor_attach_input_device :: proc(cursor: ^wlr_cursor, device: ^wlr_input_device) ---
	wlr_cursor_move :: proc(cursor: ^wlr_cursor, device: ^wlr_input_device, dx, dy: f64) ---
	wlr_xcursor_manager_create :: proc(name: cstring, size: u32) -> ^wlr_xcursor_manager ---
	wlr_xcursor_manager_destroy :: proc(manager: ^wlr_xcursor_manager) ---
}

#assert(offset_of(wlr_xcursor_image, hotspot_x) == 8 && offset_of(wlr_xcursor_image, hotspot_y) == 12 && offset_of(wlr_xcursor_image, buffer) == 24)
