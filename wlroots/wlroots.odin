package wlroots

import "core:c"
import li "../libinput"
import "core:sys/posix"
import wl "../wayland_server"
import xkb "../xkbcommon"

foreign import lib "system:wlroots-0.20"

wlr_renderer :: struct {}
wlr_allocator :: struct {}
wlr_output_mode :: struct {
	width, height, refresh: i32,
	preferred: bool,
	picture_aspect_ratio: c.int,
	link: wl.wl_list,
}
#assert(size_of(wlr_output_mode) == 40)
#assert(offset_of(wlr_output_mode, width) == 0)
#assert(offset_of(wlr_output_mode, height) == 4)
#assert(offset_of(wlr_output_mode, refresh) == 8)
#assert(offset_of(wlr_output_mode, preferred) == 12)
#assert(offset_of(wlr_output_mode, picture_aspect_ratio) == 16)
#assert(offset_of(wlr_output_mode, link) == 24)
wlr_xdg_output_manager_v1 :: struct {}
wlr_output_layout_output :: struct {}
wlr_scene_output_layout :: struct {}

wlr_compositor :: struct {}
wlr_subcompositor :: struct {}
wlr_data_device_manager :: struct {}
wlr_screencopy_manager_v1 :: struct {}
wlr_xcursor_manager :: struct {}
wlr_xcursor :: struct #align(8) { image_count: u32, _pad: [4]u8, images: [^]^wlr_xcursor_image, name: cstring, _opaque: [8]u8 }
wlr_xcursor_image :: struct #align(8) { width,height: u32, _opaque: [32]u8 }
#assert(size_of(wlr_xcursor)==32 && align_of(wlr_xcursor)==8)
#assert(offset_of(wlr_xcursor,image_count)==0 && offset_of(wlr_xcursor,images)==8 && offset_of(wlr_xcursor,name)==16)
#assert(size_of(wlr_xcursor_image)==40 && align_of(wlr_xcursor_image)==8)
#assert(offset_of(wlr_xcursor_image,width)==0 && offset_of(wlr_xcursor_image,height)==4)
wlr_seat_client :: struct {}
wlr_data_source :: struct {}

WLR_INPUT_DEVICE_KEYBOARD :: 0
WLR_INPUT_DEVICE_POINTER :: 1
WLR_MODIFIER_ALT :: 1 << 3
WLR_SCENE_NODE_BUFFER :: 2

foreign lib {
	wlr_seat_pointer_clear_focus :: proc(seat: ^wlr_seat) ---
	wlr_input_device_is_libinput :: proc(device: ^wlr_input_device) -> bool ---
	wlr_libinput_get_device_handle :: proc(device: ^wlr_input_device) -> ^li.libinput_device ---
	wlr_keyboard_notify_modifiers :: proc(keyboard: ^wlr_keyboard, depressed, latched, locked, group: u32) ---
	wlr_xcursor_manager_get_xcursor :: proc(manager: ^wlr_xcursor_manager, name: cstring, scale: f32) -> ^wlr_xcursor ---
	wlr_xcursor_manager_load :: proc(manager: ^wlr_xcursor_manager, scale: f32) -> bool ---
	wlr_xdg_toplevel_send_close :: proc(toplevel: ^wlr_xdg_toplevel) ---
	wlr_scene_node_coords :: proc(node: ^wlr_scene_node, x, y: ^i32) -> bool ---
	wlr_output_schedule_frame :: proc(output: ^wlr_output) ---
	wlr_output_layout_get_box :: proc(layout: ^wlr_output_layout, output: ^wlr_output, box: ^wlr_box) ---
	wlr_output_layout_output_at :: proc(layout: ^wlr_output_layout, x, y: f64) -> ^wlr_output ---
	wlr_scene_tree_create :: proc(parent: ^wlr_scene_tree) -> ^wlr_scene_tree ---
	wlr_scene_node_set_position :: proc(node: ^wlr_scene_node, x, y: i32) ---
	wlr_scene_node_set_enabled :: proc(node: ^wlr_scene_node, enabled: bool) ---
	wlr_scene_node_reparent :: proc(node: ^wlr_scene_node, parent: ^wlr_scene_tree) ---
	wlr_scene_rect_create :: proc(parent: ^wlr_scene_tree, width, height: i32, color: [^]f32) -> ^wlr_scene_rect ---
	wlr_scene_rect_set_size :: proc(rect: ^wlr_scene_rect, width, height: i32) ---
	wlr_scene_rect_set_color :: proc(rect: ^wlr_scene_rect, color: [^]f32) ---
	wlr_xdg_toplevel_set_tiled :: proc(toplevel: ^wlr_xdg_toplevel, edges: u32) -> u32 ---

	wlr_xdg_output_manager_v1_create :: proc(display: ^wl.wl_display, layout: ^wlr_output_layout) -> ^wlr_xdg_output_manager_v1 ---
	wlr_backend_autocreate :: proc(loop: ^wl.wl_event_loop, session_ptr: ^^wlr_session) -> ^wlr_backend ---
	wlr_backend_start :: proc(backend: ^wlr_backend) -> bool ---
	wlr_backend_destroy :: proc(backend: ^wlr_backend) ---
	wlr_renderer_autocreate :: proc(backend: ^wlr_backend) -> ^wlr_renderer ---
	wlr_renderer_init_wl_display :: proc(renderer: ^wlr_renderer, display: ^wl.wl_display) -> bool ---
	wlr_renderer_destroy :: proc(renderer: ^wlr_renderer) ---
	wlr_allocator_autocreate :: proc(backend: ^wlr_backend, renderer: ^wlr_renderer) -> ^wlr_allocator ---
	wlr_allocator_destroy :: proc(allocator: ^wlr_allocator) ---
	wlr_compositor_create :: proc(display: ^wl.wl_display, version: u32, renderer: ^wlr_renderer) -> ^wlr_compositor ---
	wlr_subcompositor_create :: proc(display: ^wl.wl_display) -> ^wlr_subcompositor ---
	wlr_data_device_manager_create :: proc(display: ^wl.wl_display) -> ^wlr_data_device_manager ---
	wlr_screencopy_manager_v1_create :: proc(display: ^wl.wl_display) -> ^wlr_screencopy_manager_v1 ---

	wlr_output_layout_create :: proc(display: ^wl.wl_display) -> ^wlr_output_layout ---
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

	wlr_scene_create :: proc() -> ^wlr_scene ---
	wlr_scene_node_destroy :: proc(node: ^wlr_scene_node) ---
	wlr_scene_node_raise_to_top :: proc(node: ^wlr_scene_node) ---
	wlr_scene_node_at :: proc(node: ^wlr_scene_node, lx, ly: f64, nx, ny: ^f64) -> ^wlr_scene_node ---
	wlr_scene_buffer_from_node :: proc(node: ^wlr_scene_node) -> ^wlr_scene_buffer ---
	wlr_scene_surface_try_from_buffer :: proc(buffer: ^wlr_scene_buffer) -> ^wlr_scene_surface ---
	wlr_scene_attach_output_layout :: proc(scene: ^wlr_scene, layout: ^wlr_output_layout) -> ^wlr_scene_output_layout ---
	wlr_scene_output_create :: proc(scene: ^wlr_scene, output: ^wlr_output) -> ^wlr_scene_output ---
	wlr_scene_output_layout_add_output :: proc(layout: ^wlr_scene_output_layout, layout_output: ^wlr_output_layout_output, scene_output: ^wlr_scene_output) ---
	wlr_scene_get_scene_output :: proc(scene: ^wlr_scene, output: ^wlr_output) -> ^wlr_scene_output ---
	wlr_scene_output_commit :: proc(output: ^wlr_scene_output, options: ^wlr_scene_output_state_options) -> bool ---
	wlr_scene_output_send_frame_done :: proc(output: ^wlr_scene_output, now: ^posix.timespec) ---
	wlr_scene_xdg_surface_create :: proc(parent: ^wlr_scene_tree, surface: ^wlr_xdg_surface) -> ^wlr_scene_tree ---

	wlr_xdg_shell_create :: proc(display: ^wl.wl_display, version: u32) -> ^wlr_xdg_shell ---
	wlr_xdg_toplevel_set_size :: proc(toplevel: ^wlr_xdg_toplevel, width, height: i32) -> u32 ---
	wlr_xdg_toplevel_set_fullscreen :: proc(toplevel: ^wlr_xdg_toplevel, fullscreen: bool) -> u32 ---
	wlr_xdg_toplevel_set_maximized :: proc(toplevel: ^wlr_xdg_toplevel, maximized: bool) -> u32 ---
	wlr_xdg_toplevel_set_suspended :: proc(toplevel: ^wlr_xdg_toplevel, suspended: bool) -> u32 ---
	wlr_xdg_toplevel_set_activated :: proc(toplevel: ^wlr_xdg_toplevel, activated: bool) -> u32 ---
	wlr_xdg_surface_schedule_configure :: proc(surface: ^wlr_xdg_surface) -> u32 ---
	wlr_xdg_surface_try_from_wlr_surface :: proc(surface: ^wlr_surface) -> ^wlr_xdg_surface ---

	wlr_seat_create :: proc(display: ^wl.wl_display, name: cstring) -> ^wlr_seat ---
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
	wlr_cursor_warp_absolute :: proc(cursor: ^wlr_cursor, device: ^wlr_input_device, x, y: f64) ---
	wlr_cursor_set_xcursor :: proc(cursor: ^wlr_cursor, manager: ^wlr_xcursor_manager, name: cstring) ---
	wlr_cursor_set_surface :: proc(cursor: ^wlr_cursor, surface: ^wlr_surface, hotspot_x, hotspot_y: i32) ---
	wlr_xcursor_manager_create :: proc(name: cstring, size: u32) -> ^wlr_xcursor_manager ---
	wlr_xcursor_manager_destroy :: proc(manager: ^wlr_xcursor_manager) ---
}
