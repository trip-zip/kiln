package compositor

import ext "../extensions"

import "core:time"
import vm "../lua_runtime"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

Idle_Inhibitor :: struct {
	server:               ^Server,
	handle:               ^ext.Idle_Inhibitor,
	destroy, map_, unmap: wl.Listener,
}
init_idle :: proc(s: ^Server) -> bool {
	manager: ^ext.Idle_Inhibit_Manager
	s.idle_notifier, manager = ext.idle_create(s.display)
	if s.idle_notifier == nil || manager == nil {return false}
	wl.listen(&manager.events.new_inhibitor, &s.new_idle_inhibitor, idle_inhibitor_added)
	s.idle_timer = wl.on_timer(s.display, idle_timeout, s)
	return s.idle_timer != nil
}
runtime_idle_timeout :: proc(data: rawptr, ms: i32) {
	s := (^Server)(data)
	if s.idle {s.idle = false
		queue_event(s, vm.Event{class = "idle", name = "stop"})}
	s.idle_timeout_ms = max(0, ms)
	wl.arm_timer(s.idle_timer, time.Duration(s.idle_timeout_ms)*time.Millisecond)
}
idle_timeout :: proc(data: rawptr) -> i32 {
	s := (^Server)(data)
	if !s.shutting_down && !s.idle && s.idle_timeout_ms > 0 {
		s.idle = true
		queue_event(s, vm.Event{class = "idle", name = "start"})
	}
	return 0
}
idle_activity :: proc(s: ^Server) {
	if s.shutting_down {return}
	if s.idle_notifier != nil {ext.idle_activity(s.idle_notifier, s.seat)}
	if s.idle {s.idle = false
		queue_event(s, vm.Event{class = "idle", name = "stop"})}
	if s.idle_timeout_ms > 0 {wl.arm_timer(s.idle_timer, time.Duration(s.idle_timeout_ms)*time.Millisecond)}
}
inhibitor_visible :: proc(s: ^Server, surface: ^wlr.wlr_surface) -> bool {
	if surface == nil || !surface.mapped {return false}
	root := wlr.surface_root(surface)
	for v in s.views {if view_surface(v) == root {return v.mapped && v.output != nil && v.output.handle.enabled && client_visible(v.output, v.id)}}
	for l in s.layers {if l.handle.surface == root {return l.mapped && l.output != nil && l.output.handle.enabled && client_visible(l.output, l.id)}}
	for p in s.popups {if p.handle.base.surface == root {return p.mapped && popup_visible(p)}}
	// Conservatively count unknown mapped roles only while an output is enabled.
	for o in s.outputs {if o.handle.enabled {return true}}
	return false
}
idle_recompute :: proc(s: ^Server) {
	if s == nil || s.idle_notifier == nil || s.shutting_down {return}
	on := false
	for i in s.idle_inhibitors {if !locked(s) && inhibitor_visible(s, i.handle.surface) {on = true
			break}}
	if on == s.idle_inhibited {return}
	s.idle_inhibited = on
	ext.idle_inhibit(s.idle_notifier, on)
	queue_event(s, vm.Event{class = "idle", name = "inhibit", on = on})
}
idle_inhibitor_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "new_idle_inhibitor")
	i := new(Idle_Inhibitor)
	i.server = s
	i.handle = (^ext.Idle_Inhibitor)(data)
	append(&s.idle_inhibitors, i)
	wl.listen(&i.handle.events.destroy, &i.destroy, idle_inhibitor_destroyed)
	wl.listen(&i.handle.surface.events.map_, &i.map_, idle_surface_mapped)
	wl.listen(&i.handle.surface.events.unmap, &i.unmap, idle_surface_unmapped)
	idle_recompute(s)
}
idle_surface_mapped :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	idle_recompute(wl.owner(listener, Idle_Inhibitor, "map_").server)
}
idle_surface_unmapped :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	idle_recompute(wl.owner(listener, Idle_Inhibitor, "unmap").server)
}
idle_inhibitor_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	i := wl.owner(listener, Idle_Inhibitor, "destroy")
	s := i.server
	wl.unlisten(&i.destroy)
	wl.unlisten(&i.map_)
	wl.unlisten(&i.unmap)
	for v, n in s.idle_inhibitors {if v == i {ordered_remove(&s.idle_inhibitors, n)
			break}}
	free(i)
	idle_recompute(s)
}
