package compositor

import sp "../scene_paint"

import vm "../lua_runtime"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

primary_selection_requested :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "request_primary_selection")
	wlr.primary_selection_set(s.seat, (^wlr.wlr_seat_request_set_primary_selection_event)(data))
}
drag_requested :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "request_drag")
	e := (^wlr.wlr_seat_request_start_drag_event)(data)
	if locked(s) {if e.drag.source != nil {wlr.wlr_data_source_destroy(e.drag.source)}
		return}
	wlr.pointer_drag_request(s.seat, e)
}
drag_icon_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "drag_icon_destroy")
	wl.unlisten(listener)
	wl.unlisten(&s.drag_commit)
	s.drag_icon = nil
	drag_position(s)
}
drag_part :: proc(s: ^Server, o: ^Output) -> (sp.Part, bool) {
	if s.drag_icon == nil || !s.drag_icon.surface.mapped || locked(s) { return {}, false }
	surface := s.drag_icon.surface
	return sp.Part{kind=.Client, id=sp.DRAG_ICON_ID, surface=surface,
		box={i32(s.cursor.x)-o.x+s.drag_dx, i32(s.cursor.y)-o.y+s.drag_dy,
			surface.current.width, surface.current.height}}, true
}
drag_position :: proc(s: ^Server) {
	for o in s.outputs {
		sp.remove_client(&o.paint, sp.DRAG_ICON_ID)
		if part, ok := drag_part(s, o); ok {
			append(&o.paint.parts, part)
			sp.damage_part(&o.paint, part)
		}
		sp.refresh_subscriptions(&o.paint)
	}
}
drag_committed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "drag_commit")
	s.drag_dx += s.drag_icon.surface.current.dx
	s.drag_dy += s.drag_icon.surface.current.dy
	drag_position(s)
}
drag_started :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "start_drag")
	drag := (^wlr.wlr_drag)(data)
	s.drag_active = true
	wl.listen(&drag.events.destroy, &s.drag_destroy, drag_ended)
	if drag.icon != nil {
		s.drag_icon = drag.icon
		s.drag_dx, s.drag_dy = 0, 0
		wl.listen(&drag.icon.events.destroy, &s.drag_icon_destroy, drag_icon_destroyed)
		wl.listen(&drag.icon.surface.events.commit, &s.drag_commit, drag_committed)
		drag_position(s)
	}
	queue_event(s, vm.Event{class = "drag", name = "start", generation = s.lua.config_generation})
}
drag_ended :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "drag_destroy")
	wl.unlisten(listener)
	s.drag_active = false
	// The native icon can outlive the drag protocol object.
	queue_event(s, vm.Event{class = "drag", name = "end", generation = s.lua.config_generation})
}
