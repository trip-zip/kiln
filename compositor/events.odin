package compositor

import xw "../xwayland"

import sp "../scene_paint"

import vm "../lua_runtime"
import pam "../pam"
import wl "../wayland"

import "core:strings"

free_event :: proc(event: ^vm.Event) {
	context.allocator = event.allocator
	vm.free_notification(event.notification)
	delete(event.service)
	delete(event.item_id)
	delete(event.status)
	delete(event.namespace)
	delete(event.bytes)
	delete(event.app_id)
	delete(event.title)
	delete(event.wm_class)
	delete(event.wm_instance)
	delete(event.role)
	delete(event.icon)
	delete(event.window_type)
	delete(event.output)
	delete(event.key)
	if event.class == "session" &&
	   event.name == "key" {pam.clear_secret(transmute([]u8)event.utf8)}
	delete(event.utf8)
}
// Every variable-length payload is copied before the originating signal returns.
queue_event :: proc(s: ^Server, event: vm.Event) {
	if s.shutting_down {return}
	e := event
	e.lock_generation = s.lock_generation
	e.allocator = context.allocator
	e.notification = vm.clone_notification(event.notification)
	e.service, e.item_id, e.status =
		strings.clone(e.service), strings.clone(e.item_id), strings.clone(e.status)
	e.namespace = strings.clone(e.namespace)
	e.bytes = strings.clone(e.bytes)
	if e.keyboard !=
	   0 {e.routing_epoch = s.keyboard_epoch} else if e.native != .None {e.routing_epoch = s.pointer_epoch}
	e.app_id, e.title = strings.clone(e.app_id), strings.clone(e.title)
	e.wm_class, e.wm_instance = strings.clone(e.wm_class), strings.clone(e.wm_instance)
	e.role, e.icon, e.window_type =
		strings.clone(e.role), strings.clone(e.icon), strings.clone(e.window_type)
	e.output = strings.clone(e.output)
	e.key, e.utf8 = strings.clone(e.key), strings.clone(e.utf8)
	if e.class == "input" && e.name == "motion" && len(s.events) > 0 {
		last := &s.events[len(s.events) - 1]
		if last.class == "input" && last.name == "motion" {
			free_event(last)
			last^ = e
			return
		}
	}
	append(&s.events, e)
	if s.event_source == nil {
		s.event_source = wl.on_idle(s.display, drain_events, s)
		if s.event_source == nil {fail(s, "Cannot schedule events")}
	}
}
queue_client :: proc(view: ^View, name: string, replay := false) {
	types: string
	defer delete(types)
	g := view_geometry(view)
	e := vm.Event {
		name      = name,
		handle    = view.id,
		width     = g.width,
		height    = g.height,
		map_epoch = view.map_epoch,
	}
	if name == "map" {
		if view.output != nil {
			if p, ok := sp.find_client(&view.output.paint, view.id);
			   ok {e.x, e.y = p.box.x, p.box.y}
		}
		e.fullscreen, e.maximized, e.minimized = view_states(view, replay)
		e.parent = view_parent(view)
	}
	if name == "map" || name == "metadata" {
		e.parent = view_parent(view)
		title := view_title_text(view)
		e.title, e.has_title = string(title), title != nil
		if t := xdg(view);
		   t !=
		   nil {e.app_id, e.has_app_id = string(t.app_id), t.app_id != ""} else if x := x11(view); x != nil {
			xs := x.handle
			e.role, e.icon = x.role, x.icon
			types = x11_types(x)
			e.window_type = types
			e.pid = xs.pid
			e.wm_class, e.wm_instance = string(xs.class), string(xs.instance)
			e.has_wm_class, e.has_wm_instance = xs.has_class, xs.has_instance
			if name == "map" {
				e.x, e.y, e.width, e.height = i32(xs.x), i32(xs.y), i32(xs.width), i32(xs.height)
				e.pid = xs.pid
				if !replay &&
				   x.initial_state {e.fullscreen, e.maximized, e.minimized = x.initial_fullscreen, x.initial_maximized, x.initial_minimized}
				e.override_redirect = xs.override_redirect
				e.wants_focus = xs.override_redirect && xw.wants_focus(xs)
			}
		}
	}
	full, maxed, _ := view_states(view, false)
	switch name {
	case "request::fullscreen":
		e.on = full
	case "request::maximize":
		e.on = maxed
	case "request::minimize":
		e.on = true
	}
	queue_event(view.server, e)
}
queue_output :: proc(output: ^Output, name: string) {
	queue_event(
		output.server,
		vm.Event {
			class = "output",
			name = name,
			output = string(output.handle.name),
			generation = output.lifetime,
		},
	)
}
drain_events :: proc(data: rawptr) {
	drain_pending((^Server)(data))
}
drain_pending :: proc(s: ^Server) {
	s.event_source = nil
	// Detach the batch before calling Lua so future events have separate ownership.
	events := s.events
	s.events = nil
	defer delete(events)
	// Idle callbacks can run just before poll; protocol writes must not await input.
	defer wl.flush_clients(s.display)
	for &event in events {
		if event.native == .DeviceMotion &&
		   !valid_motion(
				   s,
				   &event,
			   ) {} else if event.class == "session" && event.generation != s.lock_generation && event.name != "key" {} else if event.class == "reload" {lock_reload(s)} else if (event.class == "spawn" || event.class == "drag") && event.generation != s.lua.config_generation {} else if event.class == "layer" && !valid_layer_event(s, &event) {} else if event.class == "output" && event.name != "remove" && !valid_output_event(s, &event) {} else if event.class != "layer" && event.name == "map" && !valid_map(s, &event) {} else if event.map_epoch != 0 && (event.name == "metadata" || event.name == "commit_size" || event.name == "request::configure" || event.name == "request::urgent" || event.name == "request::fullscreen" || event.name == "request::maximize" || event.name == "request::minimize") && !valid_map(s, &event) {} else if event.class == "timer" {vm.fire_timer(&s.lua, event.id)} else if event.class != "frame" || valid_tick(s, &event) {dispatch_input(s, &event)
			x11_settled_state(s, &event)}
		free_event(&event)
	}
}

valid_output_event :: proc(s: ^Server, event: ^vm.Event) -> bool {
	for o in s.outputs {if o.lifetime == event.generation && string(o.handle.name) == event.output {return true}}
	return false
}

// Replays are snapshots, not permission to resurrect an unmapped or remapped view.
valid_map :: proc(s: ^Server, event: ^vm.Event) -> bool {
	for v in s.views {
		if v.id == event.handle {return v.mapped && v.map_epoch == event.map_epoch}
	}
	return false
}
