package wlroots

import "core:c"
import "core:sys/posix"
import wl "../wayland"

// Layouts measured against the installed wlroots 0.20.2 headers on Linux amd64.
// map_ denotes the C field map, an Odin keyword.
// Opaque spans preserve unused fields without exposing them as API.

wlr_backend_events :: struct #align(8) {
	destroy: wl.Signal,
	new_input: wl.Signal,
	new_output: wl.Signal,
}
#assert(size_of(wlr_backend_events) == 48 && align_of(wlr_backend_events) == 8 && offset_of(wlr_backend_events, new_input) == 16 && offset_of(wlr_backend_events, new_output) == 32 && offset_of(wlr_backend_events, destroy) == 0)

wlr_backend :: struct #align(8) {
	_opaque_0: [16]u8,
	events: wlr_backend_events,
}
#assert(size_of(wlr_backend) == 64 && align_of(wlr_backend) == 8 && offset_of(wlr_backend, events) == 16)

wlr_output_events :: struct #align(8) {
	frame: wl.Signal,
	_opaque_16: [16]u8,
	needs_frame: wl.Signal,
	_opaque_48: [16]u8,
	commit: wl.Signal,
	present: wl.Signal,
    bind: wl.Signal,
	description: wl.Signal,
	request_state: wl.Signal,
	destroy: wl.Signal,
}
#assert(size_of(wlr_output_events) == 160 && align_of(wlr_output_events) == 8 && offset_of(wlr_output_events, frame) == 0 && offset_of(wlr_output_events, commit) == 64)
#assert(offset_of(wlr_output_events, request_state) == 128 && offset_of(wlr_output_events, destroy) == 144)

wlr_output :: struct #align(8) {
	_opaque_0: [32]u8,
	resources: wl.List,
	name, description: cstring,
	_opaque_64: [40]u8,
	modes: wl.List,
	_opaque_120: [8]u8,
	width, height, refresh: i32,
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
#assert(size_of(wlr_output) == 624 && align_of(wlr_output) == 8 && offset_of(wlr_output, resources) == 32 && offset_of(wlr_output, name) == 48 && offset_of(wlr_output, width) == 128)
#assert(offset_of(wlr_output, height) == 132 && offset_of(wlr_output, events) == 192 && offset_of(wlr_output, modes) == 104 && offset_of(wlr_output, refresh) == 136)
#assert(offset_of(wlr_output, enabled) == 148 && offset_of(wlr_output, scale) == 152 && offset_of(wlr_output, transform) == 160 && offset_of(wlr_output, adaptive_sync_status) == 164)

WLR_OUTPUT_STATE_MODE :: u32(1 << 2)
WLR_OUTPUT_STATE_BUFFER :: u32(1 << 0)
WLR_OUTPUT_STATE_ENABLED :: u32(1 << 3)
wlr_output_state_mode_type :: enum c.int {
 WLR_OUTPUT_STATE_MODE_FIXED,
}
WLR_OUTPUT_STATE_MODE_FIXED :: wlr_output_state_mode_type.WLR_OUTPUT_STATE_MODE_FIXED
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
		width, height: i32,
		_opaque_8: [4]u8,
	},
	_opaque_140: [68]u8,
}
#assert(size_of(wlr_output_state) == 208 && align_of(wlr_output_state) == 8)

wlr_output_event_request_state :: struct #align(8) {
	_opaque_0: [8]u8,
	state: ^wlr_output_state,
}

wlr_output_event_commit :: struct { output: ^wlr_output, when_: posix.timespec, state: ^wlr_output_state }
#assert(size_of(wlr_output_event_commit) == 32 && align_of(wlr_output_event_commit) == 8 && offset_of(wlr_output_event_commit, output) == 0 && offset_of(wlr_output_event_commit, when_) == 8)
#assert(offset_of(wlr_output_event_commit, state) == 24)

#assert(size_of(wlr_output_event_request_state) == 16 && align_of(wlr_output_event_request_state) == 8 && offset_of(wlr_output_event_request_state, state) == 8)
wlr_surface_events :: struct #align(8) {
	_opaque_0: [16]u8,
	commit: wl.Signal,
	map_: wl.Signal,
	unmap: wl.Signal,
	_opaque_64: [16]u8,
	destroy: wl.Signal,
}
#assert(size_of(wlr_surface_events) == 96 && align_of(wlr_surface_events) == 8 && offset_of(wlr_surface_events, commit) == 16 && offset_of(wlr_surface_events, map_) == 32 && offset_of(wlr_surface_events, unmap) == 48)

wlr_surface :: struct #align(8) {
	resource: ^wl.Resource,
	_opaque_8: [16]u8,
	buffer_damage: pixman_region32_t,
	_opaque_48:    [24]u8,
	input_region: pixman_region32_t,
	current: wlr_surface_state,
	pending: wlr_surface_state,
	_opaque_672: [16]u8,
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
    transform: i32,
    _opaque_124: [20]u8,
	width,height: i32,
	buffer_width, buffer_height: i32,
    subsurfaces_below, subsurfaces_above: wl.List,
    _opaque_192: [96]u8,
}
#assert(size_of(wlr_surface_state)==288 && align_of(wlr_surface_state)==8 && offset_of(wlr_surface_state,width)==144 && offset_of(wlr_surface_state,height)==148)
#assert(offset_of(wlr_surface_state,buffer_width)==152 && offset_of(wlr_surface_state,buffer_height)==156 && offset_of(wlr_surface,current)==96 && offset_of(wlr_surface, resource) == 0)
#assert(size_of(wlr_surface) == 968 && align_of(wlr_surface) == 8 && offset_of(wlr_surface, events) == 712 && offset_of(wlr_surface,mapped)==688)

wlr_input_device_events :: struct #align(8) {
	destroy: wl.Signal,
}
#assert(size_of(wlr_input_device_events) == 16 && align_of(wlr_input_device_events) == 8 && offset_of(wlr_input_device_events, destroy) == 0)

wlr_input_device :: struct #align(8) {
	type: c.int,
	_opaque_4: [12]u8,
	events: wlr_input_device_events,
	_opaque_32: [8]u8,
}
#assert(size_of(wlr_input_device) == 40 && align_of(wlr_input_device) == 8 && offset_of(wlr_input_device, type) == 0 && offset_of(wlr_input_device, events) == 16)

wlr_keyboard_events :: struct #align(8) {
	key: wl.Signal,
	_opaque_16: [48]u8,
}
#assert(size_of(wlr_keyboard_events) == 64 && align_of(wlr_keyboard_events) == 8 && offset_of(wlr_keyboard_events, key) == 0)

wlr_keyboard :: struct #align(8) {
	base: wlr_input_device,
	_opaque_40: [272]u8,
	events: wlr_keyboard_events,
	_opaque_376: [8]u8,
}
#assert(size_of(wlr_keyboard) == 384 && align_of(wlr_keyboard) == 8 && offset_of(wlr_keyboard, base) == 0)

wlr_keyboard_key_event :: struct #align(4) {
	time_msec: u32,
	keycode: u32,
	_opaque_8: [4]u8,
	state: c.int,
}
#assert(size_of(wlr_keyboard_key_event) == 16 && align_of(wlr_keyboard_key_event) == 4 && offset_of(wlr_keyboard_key_event, time_msec) == 0 && offset_of(wlr_keyboard_key_event, keycode) == 4)
#assert(offset_of(wlr_keyboard_key_event, state) == 12)

wlr_pointer :: struct #align(8) {
	base: wlr_input_device,
	_opaque_40: [8]u8,
	output_name: cstring,
	_opaque_56: [72]u8,
	events: struct { motion, motion_absolute, button, axis, frame: wl.Signal, _opaque_80: [128]u8 },
	_opaque_336: [8]u8,
}
#assert(size_of(wlr_pointer) == 344 && align_of(wlr_pointer) == 8 && offset_of(wlr_pointer, base) == 0 && offset_of(wlr_pointer, output_name) == 48)

wlr_pointer_motion_event :: struct #align(8) {
	pointer: ^wlr_pointer,
	time_msec: u32,
	_opaque_12: [4]u8,
	delta_x, delta_y: f64,
	unaccel_dx, unaccel_dy: f64,
}
#assert(size_of(wlr_pointer_motion_event) == 48 && align_of(wlr_pointer_motion_event) == 8 && offset_of(wlr_pointer_motion_event, pointer) == 0 && offset_of(wlr_pointer_motion_event, time_msec) == 8)
#assert(offset_of(wlr_pointer_motion_event, delta_x) == 16 && offset_of(wlr_pointer_motion_event, delta_y) == 24)

wlr_pointer_motion_absolute_event :: struct #align(8) {
	pointer: ^wlr_pointer,
	time_msec: u32,
	_opaque_12: [4]u8,
	x: f64,
	y: f64,
}
#assert(size_of(wlr_pointer_motion_absolute_event) == 32 && align_of(wlr_pointer_motion_absolute_event) == 8 && offset_of(wlr_pointer_motion_absolute_event, pointer) == 0 && offset_of(wlr_pointer_motion_absolute_event, time_msec) == 8)
#assert(offset_of(wlr_pointer_motion_absolute_event, x) == 16 && offset_of(wlr_pointer_motion_absolute_event, y) == 24)

wlr_pointer_button_event :: struct #align(8) {
	_opaque_0: [8]u8,
	time_msec: u32,
	button: u32,
	state: c.int,
	_opaque_20: [4]u8,
}
#assert(size_of(wlr_pointer_button_event) == 24 && align_of(wlr_pointer_button_event) == 8 && offset_of(wlr_pointer_button_event, time_msec) == 8 && offset_of(wlr_pointer_button_event, button) == 12)
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
#assert(size_of(wlr_pointer_axis_event) == 40 && align_of(wlr_pointer_axis_event) == 8 && offset_of(wlr_pointer_axis_event, time_msec) == 8 && offset_of(wlr_pointer_axis_event, source) == 12)
#assert(offset_of(wlr_pointer_axis_event, orientation) == 16 && offset_of(wlr_pointer_axis_event, relative_direction) == 20 && offset_of(wlr_pointer_axis_event, delta) == 24 && offset_of(wlr_pointer_axis_event, delta_discrete) == 32)

wlr_box :: struct { x, y, width, height: i32 }
#assert(size_of(wlr_box) == 16 && offset_of(wlr_box, x) == 0 && offset_of(wlr_box, y) == 4 && offset_of(wlr_box, width) == 8 && offset_of(wlr_box, height) == 12)

wlr_output_layout_events :: struct { _opaque_0: [16]u8, change, destroy: wl.Signal }
#assert(size_of(wlr_output_layout_events) == 48 && offset_of(wlr_output_layout_events, change) == 16)
wlr_output_layout :: struct #align(8) {
	_opaque_0: [24]u8,
	events: wlr_output_layout_events,
	_opaque_72: [32]u8,
}
#assert(size_of(wlr_output_layout) == 104 && offset_of(wlr_output_layout, events) == 24)

#assert(offset_of(wlr_pointer_motion_event,unaccel_dx)==32 && offset_of(wlr_pointer_motion_event,unaccel_dy)==40)

#assert(offset_of(wlr_output,commit_seq)==188 && offset_of(wlr_output_events,present)==80)

#assert(offset_of(wlr_surface, buffer_damage) == 24 && offset_of(wlr_surface_state, buffer) == 8)

#assert(offset_of(wlr_output_state, committed) == 0 && offset_of(wlr_output_state, enabled) == 32 && offset_of(wlr_output_state, buffer) == 56)
#assert(offset_of(wlr_output_state, mode_type) == 116 && offset_of(wlr_output_state, mode) == 120 && offset_of(wlr_output_state, custom_mode) == 128)

#assert(offset_of(wlr_output, description) == 56 && offset_of(wlr_output_events, description) == 112)

#assert(offset_of(wlr_output_events, bind) == 96)

#assert(offset_of(wlr_surface, pending) == 384)

#assert(offset_of(wlr_pointer, events) == 128 && size_of(type_of(wlr_pointer{}.events)) == 208 && offset_of(type_of(wlr_pointer{}.events), motion) == 0 && offset_of(type_of(wlr_pointer{}.events), motion_absolute) == 16)
#assert(offset_of(type_of(wlr_pointer{}.events), button) == 32 && offset_of(type_of(wlr_pointer{}.events), axis) == 48 && offset_of(type_of(wlr_pointer{}.events), frame) == 64 && offset_of(wlr_keyboard, events)==312)
