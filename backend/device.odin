package backend

import li "../libinput"
import wl "../wayland"

Device_Kind :: enum {
	Keyboard,
	Pointer,
}

Device :: struct {
	kind:     Device_Kind,
	name:     string,
	libinput: ^li.libinput_device,
	events:   struct {
		destroy: wl.Signal,
	},
}

Keyboard :: struct {
	base:   Device,
	events: struct {
		key: wl.Signal,
	},
	leds:   proc(_: ^Keyboard, _: u32),
	data:   rawptr,
}

Pointer :: struct {
	base:        Device,
	output_name: string,
	events:      struct {
		motion, motion_absolute, button, axis, frame: wl.Signal,
	},
}

Key_Event :: struct {
	time_msec, keycode: u32,
	state:              i32,
}

Motion_Event :: struct {
	pointer:                                  ^Pointer,
	time_msec:                                u32,
	delta_x, delta_y, unaccel_dx, unaccel_dy: f64,
}

Motion_Absolute_Event :: struct {
	pointer:   ^Pointer,
	time_msec: u32,
	x, y:      f64,
}

Button_Event :: struct {
	pointer:           ^Pointer,
	time_msec, button: u32,
	state:             i32,
}

Axis_Event :: struct {
	pointer:                                 ^Pointer,
	time_msec:                               u32,
	source, orientation, relative_direction: i32,
	delta:                                   f64,
	delta_discrete:                          i32,
}

keyboard_of :: proc(d: ^Device) -> ^Keyboard {
	return cast(^Keyboard)d if d.kind == .Keyboard else nil
}

pointer_of :: proc(d: ^Device) -> ^Pointer {return cast(^Pointer)d if d.kind == .Pointer else nil}
keyboard_leds :: proc(k: ^Keyboard, leds: u32) {if k != nil && k.leds != nil {k.leds(k, leds)}}
