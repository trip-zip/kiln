package extensions

import sf "../surfaces"

import p "../protocols"
import wl "../wayland"
import "base:runtime"

Idle_Inhibit_Manager :: struct {
	global: ^wl.Global,
	inhibitors: [dynamic]^Idle_Inhibitor,
	events: struct { new_inhibitor, destroy: wl.Signal },
	destroy: wl.Listener,
}
Idle_Inhibitor :: struct {
	manager: ^Idle_Inhibit_Manager,
	resource: ^wl.Resource,
	surface: ^sf.Surface,
	events: struct { destroy: wl.Signal },
	destroy: wl.Listener,
}
idle_inhibit_create :: proc(display: ^wl.Display) -> ^Idle_Inhibit_Manager {
	m := new(Idle_Inhibit_Manager)
	wl.signal_init(&m.events.new_inhibitor)
	wl.signal_init(&m.events.destroy)
	m.global = wl.global_create_typed(display, &p.zwp_idle_inhibit_manager_v1, 1, m, idle_inhibit_request)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, idle_inhibit_destroyed)
	return m
}
idle_inhibit_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Idle_Inhibit_Manager, "destroy")
	context = m.global.display.loop.ctx
	for len(m.inhibitors) > 0 { wl.resource_destroy(m.inhibitors[len(m.inhibitors)-1].resource) }
	wl.signal_emit_final(&m.events.destroy, m)
	wl.unlisten(listener)
	wl.global_destroy(m.global)
	delete(m.inhibitors)
	free(m)
}
idle_inhibitor_release :: proc(i: ^Idle_Inhibitor) {
	wl.unlisten(&i.destroy)
	if i.surface != nil { wl.signal_emit_final(&i.events.destroy, i.surface) }
	i.surface = nil
}
idle_inhibitor_surface_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	i := wl.owner(listener, Idle_Inhibitor, "destroy")
	context = i.resource.client.display.loop.ctx
	idle_inhibitor_release(i)
}
idle_inhibitor_destroy :: proc(r: ^wl.Resource) {
	i := cast(^Idle_Inhibitor)r.data
	idle_inhibitor_release(i)
	for other, n in i.manager.inhibitors { if other == i { ordered_remove(&i.manager.inhibitors, n); break } }
	free(i)
}
idle_inhibitor_request :: proc(r: ^wl.Resource, request: p.Zwp_Idle_Inhibitor_V1_Request, args: []wl.Argument) {
	switch request { case .destroy: wl.resource_destroy(r) }
}
idle_inhibit_request :: proc(r: ^wl.Resource, request: p.Zwp_Idle_Inhibit_Manager_V1_Request, args: []wl.Argument) {
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .create_inhibitor:
		i := new(Idle_Inhibitor)
		i.manager, i.surface = cast(^Idle_Inhibit_Manager)r.data, surface_of(wl.object(args[1]))
		wl.signal_init(&i.events.destroy)
		i.resource = wl.resource_create_typed(r.client, &p.zwp_idle_inhibitor_v1, r.version,
			u32(args[0].(wl.New_Id)), i, idle_inhibitor_request, idle_inhibitor_destroy)
		if i.resource == nil { free(i); return }
		append(&i.manager.inhibitors, i)
		if i.surface == nil { return }
		wl.listen(&i.surface.events.destroy, &i.destroy, idle_inhibitor_surface_destroyed)
		wl.signal_emit_mutable(&i.manager.events.new_inhibitor, i)
	}
}
