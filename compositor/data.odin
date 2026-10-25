package compositor


import sp "../scene_paint"

import vm "../lua_runtime"
import wl "../wayland"
import st "../seat"
import "base:runtime"

drag_icon_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
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
		box={i32(s.cursor_x)-o.x+s.drag_dx, i32(s.cursor_y)-o.y+s.drag_dy,
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
drag_started :: proc (listener: ^wl.Listener, data: rawptr) {
	s := wl.owner(listener, Server, "start_drag")
	drag := (^st.Drag)(data)
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
drag_ended :: proc (listener: ^wl.Listener, data: rawptr) {
	s := wl.owner(listener, Server, "drag_destroy")
	wl.unlisten(listener)
	s.drag_active = false
	queue_event(s, vm.Event{class = "drag", name = "end", generation = s.lua.config_generation})
}

init_data :: proc(s: ^Server) -> bool {
	if st.data_device_manager_create(s.display) == nil || st.primary_selection_manager_create(s.display) == nil { return false }
	wl.listen(&s.seat.events.request_set_selection, &s.request_selection, selection_requested)
	wl.listen(&s.seat.events.request_set_primary_selection, &s.request_primary_selection, primary_selection_requested)
	wl.listen(&s.seat.events.request_start_drag, &s.request_drag, pointer_drag_request)
	wl.listen(&s.seat.events.start_drag, &s.start_drag, drag_started)
	return true
}
selection_requested :: proc(l: ^wl.Listener, data: rawptr) {
	s := wl.owner(l, Server, "request_selection"); e := cast(^st.Selection_Event)data
	st.set_selection(s.seat, e.source, e.serial)
}
primary_selection_requested :: proc(l: ^wl.Listener, data: rawptr) {
	s := wl.owner(l, Server, "request_primary_selection"); e := cast(^st.Selection_Event)data
	st.set_primary_selection(s.seat, e.source, e.serial)
}
pointer_drag_request :: proc(l: ^wl.Listener, data: rawptr) {
	s := wl.owner(l, Server, "request_drag"); e := cast(^st.Drag_Event)data
	if !locked(s) { st.start_pointer_drag(s.seat, e.drag, e.serial) }
}
