package seat

import sf "../surfaces"

import wl "../wayland"
import p "../protocols"
import "base:runtime"
import "core:math"

Pointer_State :: struct {
	focused_surface: ^sf.Surface,
	focused_client: ^Client,
	sx, sy: f64,
	buttons: [dynamic]struct { code: u32, count: int },
	grab_serial, grab_button: u32,
	sent_axis_source: bool,
	destroy: wl.Listener,
}
Cursor_Event :: struct { seat_client: ^Client, surface: ^sf.Surface, serial: u32, hotspot_x, hotspot_y: i32 }
fixed :: proc(value: f64) -> wl.Fixed { return wl.Fixed(math.round(value*256)) }
pointer_frame :: proc(r: ^wl.Resource) { if r.version >= 5 { wl.post(r, u32(p.Wl_Pointer_Event.frame)) } }
pointer_entered :: proc(c: ^Client, serial: u32) {
	c.enter_serial, c.pointer_entered = serial, serial != 0
	if cursor_shape_entered != nil { cursor_shape_entered(c, serial) }
}
pointer_bind :: proc(c: ^Client, version: i32, id: u32) {
	r := wl.resource_create_typed(c.client, &p.wl_pointer, version, id, c, pointer_request, pointer_destroy)
	if r == nil { return }
	if c.seat.capabilities&1 == 0 { r.data = nil; return }
	append(&c.pointers, r)
	state := &c.seat.pointer_state
	if state.focused_surface != nil && state.focused_client == c {
		serial := next_serial(c)
		pointer_entered(c, serial)
		wl.post(r, u32(p.Wl_Pointer_Event.enter), wl.Uint(serial), wl.Object(surface_resource(state.focused_surface)), fixed(state.sx), fixed(state.sy))
		pointer_frame(r)
	}
}
pointer_destroy :: proc(r: ^wl.Resource) { if c := pointer_client_of(r); c != nil { remove_resource(&c.pointers, r) } }
pointer_request :: proc(r: ^wl.Resource, request: p.Wl_Pointer_Request, args: []wl.Argument) {
	if request == .release { wl.resource_destroy(r); return }
	c := pointer_client_of(r)
	if c == nil || !c.pointer_entered || u32(args[0].(wl.Uint)) != c.enter_serial { return }
	surface := surface_of(wl.object(args[1]))
	if surface != nil && !cursor_role_assign(surface, r) { return }
	event := Cursor_Event{c, surface, c.enter_serial, i32(args[2].(wl.Int)), i32(args[3].(wl.Int))}
	wl.signal_emit_mutable(&c.seat.events.request_set_cursor, &event)
}
pointer_surface_gone :: proc (listener: ^wl.Listener, data: rawptr) {
	state := wl.owner(listener, Pointer_State, "destroy")
	s := runtime.container_of(state, Seat, "pointer_state")
	context = s.display.loop.ctx
	pointer_notify_clear_focus(s)
}
pointer_notify_enter :: proc(s: ^Seat, surface: ^sf.Surface, sx, sy: f64) {
	if s.drag != nil { drag_enter(s.drag, surface, sx, sy); return }
	state := &s.pointer_state
	if state.focused_surface == surface { return }
	if c := state.focused_client; c != nil {
		serial := next_serial(c)
		for r in c.pointers { wl.post(r, u32(p.Wl_Pointer_Event.leave), wl.Uint(serial), wl.Object(surface_resource(state.focused_surface))); pointer_frame(r) }
		pointer_entered(c, 0)
	}
	wl.unlisten(&state.destroy)
	state.focused_surface, state.focused_client = surface, nil
	state.sx, state.sy, state.sent_axis_source = sx, sy, false
	clear(&state.buttons)
	if surface != nil {
		surface_watch(surface, &state.destroy, pointer_surface_gone)
		state.focused_client = client_for(s, surface_resource(surface).client)
		if c := state.focused_client; c != nil {
			serial := next_serial(c)
			pointer_entered(c, serial)
			for r in c.pointers { wl.post(r, u32(p.Wl_Pointer_Event.enter), wl.Uint(serial), wl.Object(surface_resource(surface)), fixed(sx), fixed(sy)); pointer_frame(r) }
		}
	}
	wl.signal_emit_mutable(&s.events.pointer_focus_change, s)
}
pointer_notify_clear_focus :: proc(s: ^Seat) { pointer_notify_enter(s, nil, 0, 0); clear(&s.pointer_state.buttons) }
pointer_clear_focus :: pointer_notify_clear_focus
pointer_warp :: proc(s: ^Seat, sx, sy: f64) { s.pointer_state.sx, s.pointer_state.sy = sx, sy }
pointer_notify_motion :: proc(s: ^Seat, time: u32, sx, sy: f64) {
	if s.drag != nil { drag_motion(s.drag, time, sx, sy); return }
	state := &s.pointer_state
	if state.sx == sx && state.sy == sy { return }
	pointer_warp(s, sx, sy)
	if c := state.focused_client; c != nil { for r in c.pointers { wl.post(r, u32(p.Wl_Pointer_Event.motion), wl.Uint(time), fixed(sx), fixed(sy)) } }
}
pointer_notify_button :: proc(s: ^Seat, time, button: u32, pressed: i32) -> u32 {
	if s.drag != nil { if pressed == 0 && button == s.drag.button { drag_drop(s.drag) }; return 0 }
	state := &s.pointer_state
	found := false
	for &b, i in state.buttons {
		if b.code != button { continue }
		found = true
		if pressed != 0 { b.count += 1; return 0 }
		b.count -= 1
		if b.count > 0 { return 0 }
		ordered_remove(&state.buttons, i); break
	}
	if pressed != 0 { append(&state.buttons, {button,1}) } else if !found { return 0 }
	c := state.focused_client
	if c == nil { return 0 }
	serial := next_serial(c)
	for r in c.pointers { wl.post(r, u32(p.Wl_Pointer_Event.button), wl.Uint(serial), wl.Uint(time), wl.Uint(button), wl.Uint(pressed)) }
	if pressed != 0 && len(state.buttons) == 1 { state.grab_serial, state.grab_button = serial, button }
	return serial
}
pointer_notify_axis :: proc(s: ^Seat, time: u32, orientation: i32, value: f64, value120, source, direction: i32) {
	c := s.pointer_state.focused_client
	if c == nil || orientation < 0 || orientation > 1 { return }
	low, discrete := value, value120/120
	if value120 != 0 {
		if (c.axis_discrete[orientation] < 0 && value120 > 0) || (c.axis_discrete[orientation] > 0 && value120 < 0) { c.axis_discrete[orientation], c.axis_value[orientation] = 0, 0 }
		c.axis_discrete[orientation] += value120; c.axis_value[orientation] += value
		discrete = c.axis_discrete[orientation]/120
		low = 0
		if discrete != 0 { low = c.axis_value[orientation]; c.axis_discrete[orientation] -= discrete*120; c.axis_value[orientation] = 0 }
	}
	for r in c.pointers {
		if r.version >= 5 && !s.pointer_state.sent_axis_source { wl.post(r, u32(p.Wl_Pointer_Event.axis_source), wl.Uint(0 if source == 3 && r.version < 6 else source)) }
		if value != 0 {
			if r.version >= 9 { wl.post(r, u32(p.Wl_Pointer_Event.axis_relative_direction), wl.Uint(orientation), wl.Uint(direction)) }
			if value120 != 0 && r.version >= 8 { wl.post(r, u32(p.Wl_Pointer_Event.axis_value120), wl.Uint(orientation), wl.Int(value120)) }
			if value120 != 0 && r.version < 8 {
				if discrete == 0 { continue }
				if r.version >= 5 { wl.post(r, u32(p.Wl_Pointer_Event.axis_discrete), wl.Uint(orientation), wl.Int(discrete)) }
			}
			wl.post(r, u32(p.Wl_Pointer_Event.axis), wl.Uint(time), wl.Uint(orientation), fixed(low if r.version < 8 else value))
		} else if r.version >= 5 { wl.post(r, u32(p.Wl_Pointer_Event.axis_stop), wl.Uint(time), wl.Uint(orientation)) }
	}
	s.pointer_state.sent_axis_source = true
}
pointer_notify_frame :: proc(s: ^Seat) {
	if c := s.pointer_state.focused_client; c != nil { for r in c.pointers { pointer_frame(r) } }
	s.pointer_state.sent_axis_source = false
}
