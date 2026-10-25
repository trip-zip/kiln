package compositor


import st "../seat"

import ext "../extensions"

import "base:runtime"
import wl "../wayland"
import vm "../lua_runtime"

Constraint :: struct {
	server:    ^Server,
	handle:    ^st.Constraint,
	allocator: runtime.Allocator,
	destroy, region: wl.Listener,
}

constraint_hint :: proc(s: ^Server, c: ^st.Constraint) {
	if s.shutting_down || locked(s) || s.pointer_grabbed ||
	   s.seat.pointer_state.focused_surface != c.surface || !c.current.cursor_hint.enabled {return}
	// Picking the published scene verifies the seat mapping still names a live leaf.
	surface, _, _, _ := hit_test(s, s.cursor_x, s.cursor_y)
	if surface != c.surface {return}
	cursor_hint(s, c.current.cursor_hint.x, c.current.cursor_hint.y)
	cursor_sync(s)
}

init_constraints :: proc(s: ^Server) -> bool {
	s.constraints = st.constraints_create(s.display)
	if s.constraints == nil { return false }
	wl.listen(&s.constraints.events.new_constraint, &s.new_constraint, constraint_added)
	wl.listen(&s.seat.events.pointer_focus_change, &s.pointer_focus_change, pointer_focus_changed)
	return true
}
constraint_sync :: proc(s: ^Server) {
	if s.constraints == nil { return }
	next: ^st.Constraint
	state := &s.seat.pointer_state
	if !s.shutting_down && !locked(s) && !s.pointer_grabbed && s.seat.drag == nil {
		next = st.constraint_for(s.constraints, state.focused_surface, s.seat)
		if next != nil && !st.constraint_contains(next, state.sx, state.sy) { next = nil }
	}
	if next == s.active_constraint { return }
	old := s.active_constraint
	s.active_constraint = nil
	if old != nil { constraint_hint(s, old); st.constraint_deactivate(old) }
	s.active_constraint = next
	if next != nil { st.constraint_activate(next) }
}

pointer_focus_changed :: proc (listener: ^wl.Listener, data: rawptr) {
	constraint_sync(wl.owner(listener, Server, "pointer_focus_change"))
}

constraint_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	c := wl.owner(listener, Constraint, "destroy")
	s := c.server
	if s.active_constraint == c.handle {
		s.active_constraint = nil
		constraint_hint(s, c.handle)
	}
	wl.unlisten(listener)
	wl.unlisten(&c.region)
	for p, i in s.constraint_owners {
		if p == c {
			unordered_remove(&s.constraint_owners, i)
			break
		}
	}
	free(c, c.allocator)
}

constraint_added :: proc (listener: ^wl.Listener, data: rawptr) {
	s := wl.owner(listener, Server, "new_constraint")
	c := new(Constraint)
	c^ = {
		server    = s,
		handle    = (^st.Constraint)(data),
		allocator = context.allocator,
	}
	append(&s.constraint_owners, c)
	wl.listen(&c.handle.events.destroy, &c.destroy, constraint_destroyed)
	wl.listen(&c.handle.events.set_region, &c.region, constraint_region_changed)
	constraint_sync(s)
}
constraint_region_changed :: proc(l: ^wl.Listener, data: rawptr) { constraint_sync(wl.owner(l, Constraint, "region").server) }
// Native deltas wait behind earlier Lua input decisions, then use actual seat focus.
device_motion :: proc(s: ^Server, e: ^vm.Event) {
	dx, dy, ux, uy := e.dx, e.dy, e.ux, e.uy
	if e.absolute {
		dx, dy = e.px - s.cursor_x, e.py - s.cursor_y
		ux, uy = dx, dy
	}
	constraint_sync(s)
	if !s.pointer_grabbed {ext.relative_motion(s.relative, s.seat, e.time, dx, dy, ux, uy)}
	c := s.active_constraint
	if c != nil {
		if c.type == 0 {return}
		dx, dy = st.constraint_confine(c, s.seat.pointer_state.sx, s.seat.pointer_state.sy, dx, dy)
	}
	x,y := cursor_mapped_position(s, e.motion_output, s.cursor_x+dx, s.cursor_y+dy)
	cursor_position(s, x, y)
	cursor_sync(s)
	drag_position(s)
	fact := vm.Event {
		class           = "input",
		name            = "motion",
		native          = .Motion,
		time            = e.time,
		routing_epoch   = s.pointer_epoch,
		lock_generation = s.lock_generation,
		claimed         = s.pointer_grabbed,
		blocked         = s.pointer_grabbed,
	}
	pointer_fact(s, &fact)
	dispatch_input(s, &fact)
}
