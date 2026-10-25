package backend

import p "../protocols"
import wl "../wayland"
import "core:strings"
import "core:sys/linux"

Nested_Seat :: struct {
	backend: ^Nested,
	proxy, keyboard_proxy, pointer_proxy, relative: ^wl.Proxy,
	name, capabilities: u32,
	keyboard: Keyboard,
	pointer: Pointer,
	entered: ^Nested_Output,
	keys: [dynamic]u32,
	axes: [2]Axis_Event,
	axis_pending: [2]bool,
	axis_source: i32,
}

nested_seat_event :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	s := cast(^Nested_Seat)proxy.data
	if opcode == 0 { s.capabilities = u32(args[0].(wl.Uint)); nested_capabilities(s) }
}
nested_capabilities :: proc(s: ^Nested_Seat) {
	if !s.backend.base.started { return }
	if s.capabilities&2 != 0 && s.keyboard_proxy == nil {
		s.keyboard.base = {kind=.Keyboard,name="Nested keyboard"}
		wl.signal_init(&s.keyboard.base.events.destroy); wl.signal_init(&s.keyboard.events.key)
		s.keyboard_proxy = wl.proxy_new(s.backend.remote,&p.wl_keyboard,s.proxy.version,nested_keyboard,s)
		wl.proxy_request(s.proxy,1,wl.Proxy_Object(s.keyboard_proxy))
		wl.signal_emit_mutable(&s.backend.base.events.new_input,&s.keyboard.base)
	} else if s.capabilities&2 == 0 && s.keyboard_proxy != nil { nested_keyboard_destroy(s) }
	if s.capabilities&1 != 0 && s.pointer_proxy == nil {
		s.pointer.base = {kind=.Pointer,name="Nested pointer"}
		for signal in ([]^wl.Signal{&s.pointer.base.events.destroy,&s.pointer.events.motion,&s.pointer.events.motion_absolute,&s.pointer.events.button,&s.pointer.events.axis,&s.pointer.events.frame}) { wl.signal_init(signal) }
		s.pointer_proxy = wl.proxy_new(s.backend.remote,&p.wl_pointer,s.proxy.version,nested_pointer,s)
		wl.proxy_request(s.proxy,0,wl.Proxy_Object(s.pointer_proxy))
		if s.backend.relative != nil {
			s.relative = wl.proxy_new(s.backend.remote,&p.zwp_relative_pointer_v1,1,nested_relative,s)
			wl.proxy_request(s.backend.relative,1,wl.Proxy_Object(s.relative),wl.Proxy_Object(s.pointer_proxy))
		}
		wl.signal_emit_mutable(&s.backend.base.events.new_input,&s.pointer.base)
	} else if s.capabilities&1 == 0 && s.pointer_proxy != nil { nested_pointer_destroy(s) }
}
nested_keys_release :: proc(s: ^Nested_Seat) {
	// A leave cannot strand a pressed modifier in kiln's independent keyboard state.
	for key in s.keys {
		e := Key_Event{keycode=key,state=0}
		wl.signal_emit_mutable(&s.keyboard.events.key,&e)
	}
	clear(&s.keys)
}
nested_keyboard_destroy :: proc(s: ^Nested_Seat) {
	nested_keys_release(s)
	wl.signal_emit_final(&s.keyboard.base.events.destroy,&s.keyboard.base)
	wl.proxy_release(s.keyboard_proxy,0); s.keyboard_proxy = nil
}
nested_pointer_destroy :: proc(s: ^Nested_Seat) {
	wl.signal_emit_final(&s.pointer.base.events.destroy,&s.pointer.base)
	wl.proxy_release(s.relative,0); s.relative = nil
	wl.proxy_release(s.pointer_proxy,1); s.pointer_proxy = nil
	delete(s.pointer.output_name); s.pointer.output_name = ""; s.entered = nil
	s.axis_pending = {}; s.axes = {}; s.axis_source = 0
}
nested_seat_destroy :: proc(s: ^Nested_Seat) {
	if s.keyboard_proxy != nil { nested_keyboard_destroy(s) }
	if s.pointer_proxy != nil { nested_pointer_destroy(s) }
	wl.proxy_release(s.proxy,3)
	for other,i in s.backend.seats { if other == s { ordered_remove(&s.backend.seats,i); break } }
	delete(s.keys); free(s)
}
nested_keyboard :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	s := cast(^Nested_Seat)proxy.data
	switch opcode {
	case 0: linux.close(linux.Fd(args[1].(wl.Fd)))
	case 2: nested_keys_release(s)
	case 3:
		e := Key_Event{time_msec=u32(args[1].(wl.Uint)),keycode=u32(args[2].(wl.Uint)),state=i32(args[3].(wl.Uint))}
		if e.state == 1 { append(&s.keys,e.keycode) } else {
			for key,i in s.keys { if key == e.keycode { ordered_remove(&s.keys,i); break } }
		}
		wl.signal_emit_mutable(&s.keyboard.events.key,&e)
	}
}
nested_absolute :: proc(s: ^Nested_Seat, time: u32, x,y: wl.Fixed) {
	if s.entered == nil { return }
	e := Motion_Absolute_Event{pointer=&s.pointer,time_msec=time,x=f64(x)/256/f64(s.entered.width),y=f64(y)/256/f64(s.entered.height)}
	wl.signal_emit_mutable(&s.pointer.events.motion_absolute,&e)
}
nested_pointer :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	s := cast(^Nested_Seat)proxy.data
	if opcode != 0 && s.entered == nil { return }
	switch opcode {
	case 0:
		s.entered = cast(^Nested_Output)args[1].(wl.Proxy_Object).data
		delete(s.pointer.output_name); s.pointer.output_name = ""
		if s.entered != nil { s.pointer.output_name = strings.clone(s.entered.output.name) }
		wl.proxy_request(proxy,0,args[0],wl.Proxy_Object(nil),wl.Int(0),wl.Int(0))
		nested_absolute(s,0,args[2].(wl.Fixed),args[3].(wl.Fixed))
	case 1: s.entered = nil
	case 2: nested_absolute(s,u32(args[0].(wl.Uint)),args[1].(wl.Fixed),args[2].(wl.Fixed))
	case 3:
		e := Button_Event{pointer=&s.pointer,time_msec=u32(args[1].(wl.Uint)),button=u32(args[2].(wl.Uint)),state=i32(args[3].(wl.Uint))}
		wl.signal_emit_mutable(&s.pointer.events.button,&e)
	case 4,7:
		axis := u32(args[1].(wl.Uint)); if axis > 1 { return }
		s.axis_pending[axis] = true
		s.axes[axis].time_msec = u32(args[0].(wl.Uint))
		if opcode == 4 { s.axes[axis].delta += f64(args[2].(wl.Fixed))/256 } else { s.axes[axis].delta = 0 }
	case 5:
		for pending,i in s.axis_pending { if pending {
			e := s.axes[i]; e.pointer, e.orientation, e.source = &s.pointer,i32(i),s.axis_source
			wl.signal_emit_mutable(&s.pointer.events.axis,&e)
		} }
		s.axes = {}; s.axis_pending = {}; s.axis_source = 0
		wl.signal_emit_mutable(&s.pointer.events.frame,&s.pointer)
	case 6: s.axis_source = i32(args[0].(wl.Uint))
	case 8,9,10:
		axis := u32(args[0].(wl.Uint)); if axis > 1 { return }
		if opcode == 10 { s.axes[axis].relative_direction = i32(args[1].(wl.Uint)) } else {
			s.axes[axis].delta_discrete = i32(args[1].(wl.Int))*(120 if opcode == 8 else 1)
		}
	}
}
nested_relative :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	s := cast(^Nested_Seat)proxy.data
	if s.entered == nil { return }
	dx,dy := f64(args[4].(wl.Fixed))/256,f64(args[5].(wl.Fixed))/256
	e := Motion_Event{pointer=&s.pointer,time_msec=u32((u64(args[0].(wl.Uint))<<32|u64(args[1].(wl.Uint)))/1000),delta_x=dx,delta_y=dy,unaccel_dx=dx,unaccel_dy=dy}
	wl.signal_emit_mutable(&s.pointer.events.motion,&e)
}
