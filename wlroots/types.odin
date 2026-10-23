package wlroots

import "core:c"
import wl "../wayland"
import xkb "../xkbcommon"

// Layouts measured against the installed wlroots 0.20.2 headers on Linux amd64.
// map_ denotes the C field map, an Odin keyword.
// Opaque spans preserve unused fields without exposing them as API.

wlr_backend_events :: struct #align(8) {
	destroy: wl.Signal,
	new_input: wl.Signal,
	new_output: wl.Signal,
}
#assert(size_of(wlr_backend_events) == 48 && align_of(wlr_backend_events) == 8)
#assert(offset_of(wlr_backend_events, new_input) == 16 && offset_of(wlr_backend_events, new_output) == 32)
#assert(offset_of(wlr_backend_events, destroy) == 0)

wlr_backend :: struct #align(8) {
	_opaque_0: [16]u8,
	events: wlr_backend_events,
}
#assert(size_of(wlr_backend) == 64 && align_of(wlr_backend) == 8)
#assert(offset_of(wlr_backend, events) == 16)

wlr_output_events :: struct #align(8) {
	frame: wl.Signal,
	damage, needs_frame: wl.Signal,
	_opaque_48: [16]u8,
	commit: wl.Signal,
	present: wl.Signal,
    _opaque_96: [32]u8,
	request_state: wl.Signal,
	destroy: wl.Signal,
}
#assert(size_of(wlr_output_events) == 160 && align_of(wlr_output_events) == 8)
#assert(offset_of(wlr_output_events, frame) == 0 && offset_of(wlr_output_events, commit) == 64)
#assert(offset_of(wlr_output_events, request_state) == 128 && offset_of(wlr_output_events, destroy) == 144)

wlr_output :: struct #align(8) {
	_opaque_0: [48]u8,
	name: cstring,
	_opaque_56: [48]u8,
	modes: wl.List,
	_opaque_120: [8]u8,
	width: i32,
	height: i32,
	refresh: i32,
	_opaque_140: [8]u8,
	enabled: bool,
	_opaque_149: [3]u8,
	scale: f32,
	_opaque_156: [4]u8,
	transform: i32,
	adaptive_sync_status: i32,
	_opaque_168: [17]u8,
    needs_frame: bool,
    _opaque_186: [2]u8,
    commit_seq: u32,
	events: wlr_output_events,
	_opaque_352: [104]u8,
    swapchain:            rawptr,
    _opaque_464: [160]u8,
}
#assert(size_of(wlr_output) == 624 && align_of(wlr_output) == 8)
#assert(offset_of(wlr_output, name) == 48 && offset_of(wlr_output, width) == 128)
#assert(offset_of(wlr_output, height) == 132 && offset_of(wlr_output, events) == 192)
#assert(offset_of(wlr_output, modes) == 104 && offset_of(wlr_output, refresh) == 136)
#assert(offset_of(wlr_output, enabled) == 148 && offset_of(wlr_output, scale) == 152)
#assert(offset_of(wlr_output, transform) == 160 && offset_of(wlr_output, adaptive_sync_status) == 164)

WLR_OUTPUT_STATE_MODE :: u32(1 << 2)
WLR_OUTPUT_STATE_ENABLED :: u32(1 << 3)
wlr_output_state_mode_type :: enum c.int {
 WLR_OUTPUT_STATE_MODE_FIXED,
 WLR_OUTPUT_STATE_MODE_CUSTOM,
}
WLR_OUTPUT_STATE_MODE_FIXED :: wlr_output_state_mode_type.WLR_OUTPUT_STATE_MODE_FIXED
WLR_OUTPUT_STATE_MODE_CUSTOM :: wlr_output_state_mode_type.WLR_OUTPUT_STATE_MODE_CUSTOM
#assert(size_of(wlr_output_state_mode_type) == 4)

wlr_output_state :: struct #align(8) {
	committed:   u32,
	_opaque_4:   [28]u8,
	enabled:     bool,
	_opaque_33:  [23]u8,
    buffer: ^wlr_buffer,
    _opaque_64: [52]u8,
	mode_type:   wlr_output_state_mode_type,
	mode:        ^wlr_output_mode,
	custom_mode: struct {
		width, height, refresh: i32,
	},
	_opaque_140: [68]u8,
}
#assert(size_of(wlr_output_state) == 208 && align_of(wlr_output_state) == 8)

wlr_output_event_request_state :: struct #align(8) {
	_opaque_0: [8]u8,
	state: ^wlr_output_state,
}
#assert(size_of(wlr_output_event_request_state) == 16 && align_of(wlr_output_event_request_state) == 8)
#assert(offset_of(wlr_output_event_request_state, state) == 8)





wlr_xdg_shell_events :: struct #align(8) {
	_opaque_0: [16]u8,
	new_toplevel: wl.Signal,
	new_popup: wl.Signal,
	_opaque_48: [16]u8,
}
#assert(size_of(wlr_xdg_shell_events) == 64 && align_of(wlr_xdg_shell_events) == 8)
#assert(offset_of(wlr_xdg_shell_events, new_toplevel) == 16 && offset_of(wlr_xdg_shell_events, new_popup) == 32)

wlr_xdg_shell :: struct #align(8) {
	_opaque_0: [56]u8,
	events: wlr_xdg_shell_events,
	_opaque_120: [32]u8,
}
#assert(size_of(wlr_xdg_shell) == 152 && align_of(wlr_xdg_shell) == 8)
#assert(offset_of(wlr_xdg_shell, events) == 56)

wlr_xdg_surface :: struct #align(8) {
	_opaque_0: [16]u8,
	surface: ^wlr_surface,
	_opaque_24: [40]u8,
	popups: wl.List,
	_opaque_80: [88]u8,
	initialized: bool,
	initial_commit: bool,
	_opaque_170: [2]u8,
	geometry: wlr_box,
	_opaque_188: [84]u8,
	data: rawptr,
	_opaque_280: [64]u8,
}
#assert(size_of(wlr_xdg_surface) == 344 && align_of(wlr_xdg_surface) == 8)
#assert(offset_of(wlr_xdg_surface, surface) == 16 && offset_of(wlr_xdg_surface, initialized) == 168)
#assert(offset_of(wlr_xdg_surface, initial_commit) == 169 && offset_of(wlr_xdg_surface, data) == 272)
#assert(offset_of(wlr_xdg_surface, geometry) == 172)

wlr_xdg_toplevel_events :: struct #align(8) {
	destroy: wl.Signal,
	request_maximize: wl.Signal,
	request_fullscreen: wl.Signal,
	request_minimize: wl.Signal,
	_opaque_64: [64]u8,
	set_title, set_app_id: wl.Signal,
}
#assert(size_of(wlr_xdg_toplevel_events) == 160 && align_of(wlr_xdg_toplevel_events) == 8)
#assert(offset_of(wlr_xdg_toplevel_events, destroy) == 0 && offset_of(wlr_xdg_toplevel_events, request_maximize) == 16)
#assert(offset_of(wlr_xdg_toplevel_events, request_fullscreen) == 32)
#assert(offset_of(wlr_xdg_toplevel_events, request_minimize) == 48)
#assert(offset_of(wlr_xdg_toplevel_events, set_title) == 128 && offset_of(wlr_xdg_toplevel_events, set_app_id) == 144)

wlr_xdg_toplevel_requested :: struct #align(8) {
	maximized, minimized, fullscreen: bool,
	_opaque_3: [37]u8,
}
#assert(size_of(wlr_xdg_toplevel_requested) == 40)
#assert(offset_of(wlr_xdg_toplevel_requested, maximized) == 0 && offset_of(wlr_xdg_toplevel_requested, minimized) == 1)
#assert(offset_of(wlr_xdg_toplevel_requested, fullscreen) == 2)

wlr_xdg_toplevel_state :: struct {
	maximized, fullscreen, resizing, activated, suspended: bool,
	tiled, constrained: u32,
	width, height, max_width, max_height, min_width, min_height: i32,
}
#assert(size_of(wlr_xdg_toplevel_state) == 40)
#assert(offset_of(wlr_xdg_toplevel_state, maximized) == 0 && offset_of(wlr_xdg_toplevel_state, fullscreen) == 1)
#assert(offset_of(wlr_xdg_toplevel_state, tiled) == 8 && offset_of(wlr_xdg_toplevel_state, constrained) == 12)
#assert(offset_of(wlr_xdg_toplevel_state, width) == 16 && offset_of(wlr_xdg_toplevel_state, min_height) == 36)

wlr_xdg_toplevel :: struct #align(8) {
	resource: ^wl.Resource,
	base: ^wlr_xdg_surface,
	parent: ^wlr_xdg_toplevel,
	current: wlr_xdg_toplevel_state,
	_opaque_64: [80]u8,
	requested: wlr_xdg_toplevel_requested,
	title: cstring,
	app_id: cstring,
	events: wlr_xdg_toplevel_events,
	_opaque_360: [64]u8,
}
#assert(size_of(wlr_xdg_toplevel) == 424 && align_of(wlr_xdg_toplevel) == 8)
#assert(offset_of(wlr_xdg_toplevel, resource) == 0 && offset_of(wlr_xdg_toplevel, base) == 8)
#assert(offset_of(wlr_xdg_toplevel, parent) == 16 && offset_of(wlr_xdg_toplevel, current) == 24)
#assert(offset_of(wlr_xdg_toplevel, title) == 184 && offset_of(wlr_xdg_toplevel, requested) == 144)
#assert(offset_of(wlr_xdg_toplevel, app_id) == 192 && offset_of(wlr_xdg_toplevel, events) == 200)

wlr_xdg_popup_events :: struct #align(8) {
	destroy, reposition: wl.Signal,
}
#assert(size_of(wlr_xdg_popup_events) == 32 && align_of(wlr_xdg_popup_events) == 8)
#assert(offset_of(wlr_xdg_popup_events, destroy) == 0 && offset_of(wlr_xdg_popup_events, reposition) == 16)

wlr_xdg_popup :: struct #align(8) {
	base: ^wlr_xdg_surface,
	link: wl.List,
	_opaque_24: [8]u8,
	parent: ^wlr_surface,
	_opaque_40: [8]u8,
	scheduled: wlr_xdg_popup_configure,
	current: wlr_xdg_popup_state,
    _opaque_152: [24]u8,
	events: wlr_xdg_popup_events,
	_opaque_208: [56]u8,
}
#assert(size_of(wlr_xdg_popup) == 264 && align_of(wlr_xdg_popup) == 8)
#assert(offset_of(wlr_xdg_popup, base) == 0 && offset_of(wlr_xdg_popup, parent) == 32)
#assert(offset_of(wlr_xdg_popup, events) == 176 && offset_of(wlr_xdg_popup, scheduled) == 48)

wlr_surface_events :: struct #align(8) {
	_opaque_0: [16]u8,
	commit: wl.Signal,
	map_: wl.Signal,
	unmap: wl.Signal,
	_opaque_64: [16]u8,
	destroy: wl.Signal,
}
#assert(size_of(wlr_surface_events) == 96 && align_of(wlr_surface_events) == 8)
#assert(offset_of(wlr_surface_events, commit) == 16 && offset_of(wlr_surface_events, map_) == 32)
#assert(offset_of(wlr_surface_events, unmap) == 48)

wlr_surface :: struct #align(8) {
	resource: ^wl.Resource,
	_opaque_8: [16]u8,
	buffer_damage: pixman_region32_t,
	_opaque_48:    [24]u8,
	input_region: pixman_region32_t,
	current: wlr_surface_state,
	_opaque_384: [304]u8,
    mapped: bool,
    _opaque_689: [23]u8,
	events: wlr_surface_events,
	_opaque_808: [160]u8,
}
wlr_surface_state :: struct #align(8) {
	_opaque_0: [8]u8,
	buffer:                               ^wlr_buffer,
    dx,dy: i32,
    _opaque_24: [96]u8,
    transform, scale: i32,
    _opaque_128: [16]u8,
	width,height: i32,
	_opaque_152: [8]u8,
    subsurfaces_below, subsurfaces_above: wl.List,
    _opaque_192: [96]u8,
}
#assert(size_of(wlr_surface_state)==288 && align_of(wlr_surface_state)==8)
#assert(offset_of(wlr_surface_state,width)==144 && offset_of(wlr_surface_state,height)==148)
#assert(offset_of(wlr_surface,current)==96 && offset_of(wlr_surface, resource) == 0)
#assert(size_of(wlr_surface) == 968 && align_of(wlr_surface) == 8)
#assert(offset_of(wlr_surface, events) == 712 && offset_of(wlr_surface,mapped)==688)

wlr_input_device_events :: struct #align(8) {
	destroy: wl.Signal,
}
#assert(size_of(wlr_input_device_events) == 16 && align_of(wlr_input_device_events) == 8)
#assert(offset_of(wlr_input_device_events, destroy) == 0)

wlr_input_device :: struct #align(8) {
	type: c.int,
	_opaque_4: [12]u8,
	events: wlr_input_device_events,
	_opaque_32: [8]u8,
}
#assert(size_of(wlr_input_device) == 40 && align_of(wlr_input_device) == 8)
#assert(offset_of(wlr_input_device, type) == 0 && offset_of(wlr_input_device, events) == 16)

wlr_keyboard_modifiers :: struct #align(4) {
	depressed: u32,
	latched: u32,
	locked: u32,
	group: u32,
}
#assert(size_of(wlr_keyboard_modifiers) == 16 && align_of(wlr_keyboard_modifiers) == 4)
#assert(offset_of(wlr_keyboard_modifiers, depressed) == 0 && offset_of(wlr_keyboard_modifiers, latched) == 4)
#assert(offset_of(wlr_keyboard_modifiers, locked) == 8 && offset_of(wlr_keyboard_modifiers, group) == 12)

wlr_keyboard_events :: struct #align(8) {
	key: wl.Signal,
	modifiers: wl.Signal,
	_opaque_32: [32]u8,
}
#assert(size_of(wlr_keyboard_events) == 64 && align_of(wlr_keyboard_events) == 8)
#assert(offset_of(wlr_keyboard_events, key) == 0 && offset_of(wlr_keyboard_events, modifiers) == 16)

wlr_keyboard :: struct #align(8) {
	base: wlr_input_device,
	_opaque_40: [48]u8,
	xkb_state: ^xkb.xkb_state,
	_opaque_96: [56]u8,
	keycodes: [32]u32,
	num_keycodes: c.size_t,
	modifiers: wlr_keyboard_modifiers,
	_opaque_304: [8]u8,
	events: wlr_keyboard_events,
	_opaque_376: [8]u8,
}
#assert(size_of(wlr_keyboard) == 384 && align_of(wlr_keyboard) == 8)
#assert(offset_of(wlr_keyboard, base) == 0 && offset_of(wlr_keyboard, xkb_state) == 88)
#assert(offset_of(wlr_keyboard, keycodes) == 152 && offset_of(wlr_keyboard, num_keycodes) == 280)
#assert(offset_of(wlr_keyboard, modifiers) == 288 && offset_of(wlr_keyboard, events) == 312)

wlr_keyboard_key_event :: struct #align(4) {
	time_msec: u32,
	keycode: u32,
	_opaque_8: [4]u8,
	state: c.int,
}
#assert(size_of(wlr_keyboard_key_event) == 16 && align_of(wlr_keyboard_key_event) == 4)
#assert(offset_of(wlr_keyboard_key_event, time_msec) == 0 && offset_of(wlr_keyboard_key_event, keycode) == 4)
#assert(offset_of(wlr_keyboard_key_event, state) == 12)

wlr_cursor_events :: struct #align(8) {
	motion: wl.Signal,
	motion_absolute: wl.Signal,
	button: wl.Signal,
	axis: wl.Signal,
	frame: wl.Signal,
	_opaque_80: [272]u8,
}
#assert(size_of(wlr_cursor_events) == 352 && align_of(wlr_cursor_events) == 8)
#assert(offset_of(wlr_cursor_events, motion) == 0 && offset_of(wlr_cursor_events, motion_absolute) == 16)
#assert(offset_of(wlr_cursor_events, button) == 32 && offset_of(wlr_cursor_events, axis) == 48)
#assert(offset_of(wlr_cursor_events, frame) == 64)

wlr_cursor :: struct #align(8) {
	_opaque_0: [8]u8,
	x: f64,
	y: f64,
	events: wlr_cursor_events,
	_opaque_376: [8]u8,
}
#assert(size_of(wlr_cursor) == 384 && align_of(wlr_cursor) == 8)
#assert(offset_of(wlr_cursor, x) == 8 && offset_of(wlr_cursor, y) == 16 && offset_of(wlr_cursor, events) == 24)

wlr_pointer :: struct #align(8) {
	base: wlr_input_device,
	_opaque_40: [8]u8,
	output_name: cstring,
	_opaque_56: [288]u8,
}
#assert(size_of(wlr_pointer) == 344 && align_of(wlr_pointer) == 8)
#assert(offset_of(wlr_pointer, base) == 0 && offset_of(wlr_pointer, output_name) == 48)

wlr_pointer_motion_event :: struct #align(8) {
	pointer: ^wlr_pointer,
	time_msec: u32,
	_opaque_12: [4]u8,
	delta_x: f64,
	delta_y: f64,
	unaccel_dx, unaccel_dy: f64,
}
#assert(size_of(wlr_pointer_motion_event) == 48 && align_of(wlr_pointer_motion_event) == 8)
#assert(offset_of(wlr_pointer_motion_event, pointer) == 0 && offset_of(wlr_pointer_motion_event, time_msec) == 8)
#assert(offset_of(wlr_pointer_motion_event, delta_x) == 16 && offset_of(wlr_pointer_motion_event, delta_y) == 24)

wlr_pointer_motion_absolute_event :: struct #align(8) {
	pointer: ^wlr_pointer,
	time_msec: u32,
	_opaque_12: [4]u8,
	x: f64,
	y: f64,
}
#assert(size_of(wlr_pointer_motion_absolute_event) == 32 && align_of(wlr_pointer_motion_absolute_event) == 8)
#assert(offset_of(wlr_pointer_motion_absolute_event, pointer) == 0)
#assert(offset_of(wlr_pointer_motion_absolute_event, time_msec) == 8)
#assert(offset_of(wlr_pointer_motion_absolute_event, x) == 16 && offset_of(wlr_pointer_motion_absolute_event, y) == 24)

wlr_pointer_button_event :: struct #align(8) {
	_opaque_0: [8]u8,
	time_msec: u32,
	button: u32,
	state: c.int,
	_opaque_20: [4]u8,
}
#assert(size_of(wlr_pointer_button_event) == 24 && align_of(wlr_pointer_button_event) == 8)
#assert(offset_of(wlr_pointer_button_event, time_msec) == 8 && offset_of(wlr_pointer_button_event, button) == 12)
#assert(offset_of(wlr_pointer_button_event, state) == 16)

wlr_pointer_axis_event :: struct #align(8) {
	_opaque_0: [8]u8,
	time_msec: u32,
	source: c.int,
	orientation: c.int,
	relative_direction: c.int,
	delta: f64,
	delta_discrete: i32,
	_opaque_36: [4]u8,
}
#assert(size_of(wlr_pointer_axis_event) == 40 && align_of(wlr_pointer_axis_event) == 8)
#assert(offset_of(wlr_pointer_axis_event, time_msec) == 8 && offset_of(wlr_pointer_axis_event, source) == 12)
#assert(offset_of(wlr_pointer_axis_event, orientation) == 16)
#assert(offset_of(wlr_pointer_axis_event, relative_direction) == 20 && offset_of(wlr_pointer_axis_event, delta) == 24)
#assert(offset_of(wlr_pointer_axis_event, delta_discrete) == 32)

wlr_seat_pointer_state :: struct #align(8) {
	_opaque_0: [8]u8,
	focused_client: ^wlr_seat_client,
	focused_surface: ^wlr_surface,
	sx,sy:f64,
	_opaque_40: [304]u8,
	events: struct { focus_change: wl.Signal },
	_opaque_360: [24]u8,
}
#assert(size_of(wlr_seat_pointer_state) == 384 && align_of(wlr_seat_pointer_state) == 8)
#assert(offset_of(wlr_seat_pointer_state, focused_client) == 8)

wlr_seat_events :: struct #align(8) {
	_opaque_0: [96]u8,
	request_set_cursor: wl.Signal,
	request_set_selection: wl.Signal,
	_opaque_128: [16]u8,
	request_set_primary_selection: wl.Signal,
	_opaque_160: [16]u8,
	request_start_drag, start_drag: wl.Signal,
	destroy: wl.Signal,
}
#assert(size_of(wlr_seat_events) == 224 && align_of(wlr_seat_events) == 8)
#assert(offset_of(wlr_seat_events, request_set_cursor) == 96)
#assert(offset_of(wlr_seat_events, request_set_selection) == 112)

wlr_seat_keyboard_state :: struct #align(8) {
	_opaque_0: [24]u8,
	focused_surface: ^wlr_surface,
	_opaque_32: [128]u8,
}
#assert(size_of(wlr_seat_keyboard_state) == 160)
#assert(offset_of(wlr_seat_keyboard_state, focused_surface) == 24)

wlr_seat :: struct #align(8) {
	_opaque_0: [136]u8,
	pointer_state: wlr_seat_pointer_state,
	keyboard_state: wlr_seat_keyboard_state,
	_opaque_680: [48]u8,
	events: wlr_seat_events,
	_opaque_952: [104]u8,
}
#assert(size_of(wlr_seat) == 1056 && align_of(wlr_seat) == 8)
#assert(offset_of(wlr_seat, pointer_state) == 136 && offset_of(wlr_seat, events) == 728)
#assert(offset_of(wlr_seat, keyboard_state) == 520)

wlr_seat_pointer_request_set_cursor_event :: struct #align(8) {
	seat_client: ^wlr_seat_client,
	surface: ^wlr_surface,
	_opaque_16: [4]u8,
	hotspot_x: i32,
	hotspot_y: i32,
	_opaque_28: [4]u8,
}
#assert(size_of(wlr_seat_pointer_request_set_cursor_event) == 32 && align_of(wlr_seat_pointer_request_set_cursor_event) == 8)
#assert(offset_of(wlr_seat_pointer_request_set_cursor_event, seat_client) == 0)
#assert(offset_of(wlr_seat_pointer_request_set_cursor_event, surface) == 8)
#assert(offset_of(wlr_seat_pointer_request_set_cursor_event, hotspot_x) == 20)
#assert(offset_of(wlr_seat_pointer_request_set_cursor_event, hotspot_y) == 24)

wlr_seat_request_set_selection_event :: struct #align(8) {
	source: ^wlr_data_source,
	serial: u32,
	_opaque_12: [4]u8,
}
#assert(size_of(wlr_seat_request_set_selection_event) == 16 && align_of(wlr_seat_request_set_selection_event) == 8)
#assert(offset_of(wlr_seat_request_set_selection_event, source) == 0)
#assert(offset_of(wlr_seat_request_set_selection_event, serial) == 8)

wlr_box :: struct { x, y, width, height: i32 }
#assert(size_of(wlr_box) == 16)
#assert(offset_of(wlr_box, x) == 0 && offset_of(wlr_box, y) == 4 && offset_of(wlr_box, width) == 8)
#assert(offset_of(wlr_box, height) == 12)

wlr_output_layout_events :: struct { add, change, destroy: wl.Signal }
#assert(size_of(wlr_output_layout_events) == 48)
#assert(offset_of(wlr_output_layout_events, change) == 16)
wlr_output_layout :: struct #align(8) {
	_opaque_0: [24]u8,
	events: wlr_output_layout_events,
	_opaque_72: [32]u8,
}
#assert(size_of(wlr_output_layout) == 104)
#assert(offset_of(wlr_output_layout, events) == 24)

#assert(offset_of(wlr_seat_events,destroy)==208)

#assert(offset_of(wlr_seat_events,request_set_primary_selection)==144)
#assert(offset_of(wlr_seat_events,request_start_drag)==176 && offset_of(wlr_seat_events,start_drag)==192)

#assert(offset_of(wlr_seat_pointer_state,focused_surface)==16 && offset_of(wlr_seat_pointer_state,sx)==24)
#assert(offset_of(wlr_seat_pointer_state,sy)==32 && offset_of(wlr_seat_pointer_state,events)==344)
#assert(size_of(type_of(wlr_seat_pointer_state{}.events))==16 && align_of(type_of(wlr_seat_pointer_state{}.events))==8)
#assert(offset_of(type_of(wlr_seat_pointer_state{}.events),focus_change)==0)
#assert(offset_of(wlr_pointer_motion_event,unaccel_dx)==32 && offset_of(wlr_pointer_motion_event,unaccel_dy)==40)

#assert(offset_of(wlr_output,commit_seq)==188)
#assert(offset_of(wlr_output_events,present)==80)

#assert(offset_of(wlr_surface, buffer_damage) == 24 && offset_of(wlr_surface_state, buffer) == 8)

#assert(offset_of(wlr_output_state, committed) == 0 && offset_of(wlr_output_state, enabled) == 32 && offset_of(wlr_output_state, buffer) == 56)
#assert(offset_of(wlr_output_state, mode_type) == 116 && offset_of(wlr_output_state, mode) == 120 && offset_of(wlr_output_state, custom_mode) == 128)
