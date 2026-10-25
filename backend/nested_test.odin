package backend

import "../gles"
import out "../outputs"
import wl "../wayland"
import "core:testing"

Nested_Probe :: struct {
	request, axis, frame, motion, key: wl.Listener,
	buffer: gles.Buffer,
	mode: out.Mode,
	requests, frames, keys: int,
	last_axis: Axis_Event,
	last_motion: Motion_Event,
	last_key: Key_Event,
}
nested_test_resize :: proc(l: ^wl.Listener, data: rawptr) {
	p := wl.owner(l,Nested_Probe,"request")
	e := cast(^out.Request_State_Event)data
	p.mode = e.state.custom_mode; p.requests += 1
	out.set_buffer(e.state,&p.buffer)
}
@(test)
nested_refresh_follows_last_entered_parent_and_finishes_resize_state :: proc(t: ^testing.T) {
	o := Nested_Output{width=32,height=24}
	out.init(&o.output,nil,nil,"test")
	defer out.finish(&o.output)
	p: Nested_Probe
	wl.listen(&o.output.events.request_state,&p.request,nested_test_resize)
	defer wl.unlisten(&p.request)
	nested_resize(&o)
	testing.expect_value(t,o.output.refresh,i32(60000))
	o.announced = true
	parent := Parent_Output{refresh=120000,scale=2}
	o.parent = &parent
	nested_resize(&o)
	testing.expect_value(t,p.mode,(out.Mode{32,24,120000,false}))
	testing.expect_value(t,p.buffer.locks,0)
	o.parent = nil; o.width = 48
	nested_resize(&o)
	testing.expect_value(t,p.mode,(out.Mode{48,24,60000,false}))
	testing.expect_value(t,p.requests,2)
}
@(test)
nested_buffer_retirement_waits_for_release_and_teardown_unlocks_busy_buffers :: proc(t: ^testing.T) {
	n: Nested
	defer delete(n.buffers)
	for release_first in ([]bool{true,false}) {
		b: gles.Buffer
		wl.signal_init(&b.events.retire); wl.signal_init(&b.events.destroy)
		v := new(Nested_Buffer); v.backend, v.buffer, v.busy = &n,gles.buffer_retain(&b),true
		append(&n.buffers,v)
		wl.listen(&b.events.retire,&v.retire,nested_buffer_retired)
		wl.signal_emit_final(&b.events.retire,&b)
		testing.expect(t,v.retired && b.locks == 1 && len(n.buffers) == 1)
		if release_first { proxy := wl.Proxy{data=v}; nested_buffer_release(&proxy,0,nil) } else { nested_buffer_destroy(v) }
		testing.expect_value(t,b.locks,0)
		testing.expect_value(t,len(n.buffers),0)
	}
}
@(test)
nested_pointer_batches_axis_metadata_and_uses_unaccelerated_relative_motion :: proc(t: ^testing.T) {
	s: Nested_Seat
	o := Nested_Output{width=640,height=480}
	s.entered = &o
	wl.signal_init(&s.pointer.events.axis); wl.signal_init(&s.pointer.events.frame); wl.signal_init(&s.pointer.events.motion)
	p: Nested_Probe
	wl.listen(&s.pointer.events.axis,&p.axis,proc(l: ^wl.Listener,data: rawptr) { wl.owner(l,Nested_Probe,"axis").last_axis = (cast(^Axis_Event)data)^ })
	defer wl.unlisten(&p.axis)
	wl.listen(&s.pointer.events.frame,&p.frame,proc(l: ^wl.Listener,data: rawptr) { wl.owner(l,Nested_Probe,"frame").frames += 1 })
	defer wl.unlisten(&p.frame)
	wl.listen(&s.pointer.events.motion,&p.motion,proc(l: ^wl.Listener,data: rawptr) { wl.owner(l,Nested_Probe,"motion").last_motion = (cast(^Motion_Event)data)^ })
	defer wl.unlisten(&p.motion)
	proxy := wl.Proxy{data=&s}
	nested_pointer(&proxy,4,[]wl.Argument{wl.Uint(10),wl.Uint(1),wl.Fixed(512)})
	nested_pointer(&proxy,4,[]wl.Argument{wl.Uint(10),wl.Uint(1),wl.Fixed(256)})
	nested_pointer(&proxy,6,[]wl.Argument{wl.Uint(0)})
	nested_pointer(&proxy,9,[]wl.Argument{wl.Uint(1),wl.Int(60)})
	nested_pointer(&proxy,10,[]wl.Argument{wl.Uint(1),wl.Uint(1)})
	nested_pointer(&proxy,5,nil)
	testing.expect(t,p.last_axis.delta == 3 && p.last_axis.delta_discrete == 60 && p.last_axis.orientation == 1 && p.last_axis.relative_direction == 1 && p.frames == 1)
	nested_pointer(&proxy,7,[]wl.Argument{wl.Uint(11),wl.Uint(1)})
	nested_pointer(&proxy,5,nil)
	testing.expect(t,p.last_axis.delta == 0 && p.last_axis.delta_discrete == 0 && p.last_axis.time_msec == 11)
	nested_relative(&proxy,0,[]wl.Argument{wl.Uint(0),wl.Uint(12000),wl.Fixed(2560),wl.Fixed(5120),wl.Fixed(128),wl.Fixed(-256)})
	testing.expect(t,p.last_motion.time_msec == 12 && p.last_motion.delta_x == .5 && p.last_motion.delta_y == -1 && p.last_motion.unaccel_dx == .5)
}
@(test)
nested_keyboard_leave_releases_held_keys_without_parent_modifiers :: proc(t: ^testing.T) {
	s: Nested_Seat
	defer delete(s.keys)
	wl.signal_init(&s.keyboard.events.key)
	p: Nested_Probe
	wl.listen(&s.keyboard.events.key,&p.key,proc(l: ^wl.Listener,data: rawptr) { v := wl.owner(l,Nested_Probe,"key"); v.keys += 1; v.last_key = (cast(^Key_Event)data)^ })
	defer wl.unlisten(&p.key)
	proxy := wl.Proxy{data=&s}
	nested_keyboard(&proxy,3,[]wl.Argument{wl.Uint(1),wl.Uint(42),wl.Uint(58),wl.Uint(1)})
	nested_keyboard(&proxy,4,[]wl.Argument{wl.Uint(1),wl.Uint(0),wl.Uint(0),wl.Uint(2),wl.Uint(0)})
	testing.expect(t,p.keys == 1 && p.last_key.keycode == 58 && p.last_key.state == 1)
	nested_keyboard(&proxy,2,nil)
	testing.expect(t,p.keys == 2 && p.last_key.state == 0 && len(s.keys) == 0)
}
