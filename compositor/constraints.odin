package compositor

import ext "../extensions"

import "base:runtime"
import wl "../wayland"
import wlr "../wlroots"
import vm "../lua_runtime"

Constraint :: struct {
	server:    ^Server,
	handle:    ^wlr.wlr_pointer_constraint_v1,
	allocator: runtime.Allocator,
	destroy:   wl.Listener,
}

constraint_hint :: proc(s: ^Server, c: ^wlr.wlr_pointer_constraint_v1) {
	if s.shutting_down || locked(s) || s.pointer_grabbed ||
	   s.seat.pointer_state.focused_surface != c.surface || !c.current.cursor_hint.enabled {return}
	// Picking the published scene verifies the seat mapping still names a live leaf.
	surface, _, _, _ := hit_test(s, s.cursor.x, s.cursor.y)
	if surface != c.surface {return}
	cursor_hint(s, c.current.cursor_hint.x, c.current.cursor_hint.y)
	cursor_sync(s)
}

constraint_sync :: proc(s: ^Server) {
	if s.constraints == nil {return}
	next := wlr.constraint_for(s.constraints, s.seat)
	if locked(s) || s.pointer_grabbed || s.shutting_down {next = nil}
	if next == s.active_constraint {return}
	old := s.active_constraint
	s.active_constraint = nil
	if old != nil {
		constraint_hint(s, old)
		wlr.constraint_deactivate(old)
	}
	s.active_constraint = next
	if next != nil {wlr.constraint_activate(next)}
}

pointer_focus_changed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	constraint_sync(wl.owner(listener, Server, "pointer_focus_change"))
}

constraint_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	c := wl.owner(listener, Constraint, "destroy")
	s := c.server
	if s.active_constraint == c.handle {
		s.active_constraint = nil
		constraint_hint(s, c.handle)
	}
	wl.unlisten(listener)
	for p, i in s.constraint_owners {
		if p == c {
			unordered_remove(&s.constraint_owners, i)
			break
		}
	}
	free(c, c.allocator)
}

constraint_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "new_constraint")
	c := new(Constraint)
	c^ = {
		server    = s,
		handle    = (^wlr.wlr_pointer_constraint_v1)(data),
		allocator = context.allocator,
	}
	append(&s.constraint_owners, c)
	wl.listen(&c.handle.events.destroy, &c.destroy, constraint_destroyed)
	constraint_sync(s)
}
// Native deltas wait behind earlier Lua input decisions, then use actual seat focus.
device_motion :: proc(s: ^Server, e: ^vm.Event) {
	dx, dy, ux, uy := e.dx, e.dy, e.ux, e.uy
	if e.absolute {
		dx, dy = e.px - s.cursor.x, e.py - s.cursor.y
		ux, uy = dx, dy
	}
	constraint_sync(s)
	if !s.pointer_grabbed {ext.relative_motion(s.relative, s.seat, e.time, dx, dy, ux, uy)}
	c := s.active_constraint
	if c != nil {
		if c.type == 0 {return}
		dx, dy = wlr.constraint_confine(c, s.seat, dx, dy)
	}
	cursor_position(s, s.cursor.x+dx, s.cursor.y+dy)
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
