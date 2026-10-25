package extensions

import sf "../surfaces"

import st "../seat"

import p "../protocols"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"
import "core:strings"

Foreign_Manager :: struct {
	global: ^wl.Global,
	bindings: [dynamic]^wl.Resource,
	handles: [dynamic]^Foreign_Handle,
	destroy: wl.Listener,
}
Foreign_Property :: enum { Title, App_Id, State, Outputs, Parent }
Foreign_Handle :: struct {
	manager: ^Foreign_Manager,
	resources: [dynamic]^Foreign_Resource,
	outputs: [dynamic]^Foreign_Output,
	parent: ^Foreign_Handle,
	title, app_id: string,
	state: bit_set[p.Zwlr_Foreign_Toplevel_Handle_V1_State; u32],
	idle: ^wl.Event_Source,
	events: struct { request_maximize, request_minimize, request_activate, request_fullscreen, request_close, set_rectangle, destroy: wl.Signal },
}
Foreign_Resource :: struct {
	handle: ^Foreign_Handle,
	resource: ^wl.Resource,
	dirty: bit_set[Foreign_Property],
	entered: [dynamic]^Foreign_Enter,
}
Foreign_Output :: struct { handle: ^Foreign_Handle, output: ^wlr.wlr_output, destroy, bind: wl.Listener }
Foreign_Enter :: struct { owner: ^Foreign_Resource, resource: ^wl.Resource, destroy: wl.Listener }
Foreign_Maximized_Event :: struct { toplevel: ^Foreign_Handle, maximized: bool }
Foreign_Minimized_Event :: struct { toplevel: ^Foreign_Handle, minimized: bool }
Foreign_Activated_Event :: struct { toplevel: ^Foreign_Handle, seat: ^st.Seat }
Foreign_Fullscreen_Event :: struct { toplevel: ^Foreign_Handle, fullscreen: bool, output: ^wlr.wlr_output }
Foreign_Rectangle_Event :: struct { toplevel: ^Foreign_Handle, surface: ^sf.Surface, x, y, width, height: i32 }

foreign_manager_create :: proc(display: ^wl.Display) -> ^Foreign_Manager {
	context = display.loop.ctx
	m := new(Foreign_Manager)
	m.global = wl.global_create_typed(display, &p.zwlr_foreign_toplevel_manager_v1, 3, m,
		foreign_manager_request, foreign_binding_destroy, foreign_bind)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, foreign_manager_destroyed)
	return m
}
foreign_manager_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Foreign_Manager, "destroy")
	context = m.global.display.loop.ctx
	for len(m.handles) > 0 { foreign_handle_destroy(m.handles[len(m.handles)-1]) }
	for len(m.bindings) > 0 { wl.resource_destroy(m.bindings[len(m.bindings)-1]) }
	wl.unlisten(listener)
	wl.global_destroy(m.global)
	delete(m.handles)
	delete(m.bindings)
	free(m)
}
foreign_manager_request :: proc(r: ^wl.Resource, request: p.Zwlr_Foreign_Toplevel_Manager_V1_Request, args: []wl.Argument) {
	switch request {
	case .stop:
		wl.post(r, u32(p.Zwlr_Foreign_Toplevel_Manager_V1_Event.finished))
		wl.resource_destroy(r)
	}
}
foreign_binding_destroy :: proc(r: ^wl.Resource) {
	m := cast(^Foreign_Manager)r.data
	for other, i in m.bindings { if other == r { ordered_remove(&m.bindings, i); break } }
}
foreign_resource_create :: proc(h: ^Foreign_Handle, binding: ^wl.Resource) -> ^Foreign_Resource {
	c := new(Foreign_Resource)
	c.handle, c.dirty = h, { .Title, .App_Id, .State, .Outputs, .Parent }
	c.resource = wl.resource_create_typed(binding.client, &p.zwlr_foreign_toplevel_handle_v1,
		binding.version, 0, c, foreign_handle_request, foreign_resource_destroy)
	if c.resource == nil { free(c); return nil }
	append(&h.resources, c)
	wl.post(binding, u32(p.Zwlr_Foreign_Toplevel_Manager_V1_Event.toplevel), wl.Object(c.resource))
	return c
}
foreign_bind :: proc(r: ^wl.Resource) {
	m := cast(^Foreign_Manager)r.data
	append(&m.bindings, r)
	created := make([dynamic]^Foreign_Resource, context.temp_allocator)
	for h in m.handles { if c := foreign_resource_create(h, r); c != nil { append(&created, c) } }
	// All parent IDs must exist before any child refers to them.
	for c in created { foreign_send(c) }
}
foreign_handle_create :: proc(m: ^Foreign_Manager) -> ^Foreign_Handle {
	context = m.global.display.loop.ctx
	h := new(Foreign_Handle)
	h.manager = m
	for signal in ([]^wl.Signal{&h.events.request_maximize, &h.events.request_minimize, &h.events.request_activate,
		&h.events.request_fullscreen, &h.events.request_close, &h.events.set_rectangle, &h.events.destroy}) { wl.signal_init(signal) }
	append(&m.handles, h)
	for r in m.bindings { foreign_resource_create(h, r) }
	foreign_mark(h, {.Title, .App_Id, .State, .Outputs, .Parent})
	return h
}
foreign_enter_forget :: proc(e: ^Foreign_Enter) {
	wl.unlisten(&e.destroy)
	for other, i in e.owner.entered { if other == e { ordered_remove(&e.owner.entered, i); break } }
	free(e)
}
foreign_enter_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	e := wl.owner(listener, Foreign_Enter, "destroy")
	context = e.owner.resource.client.display.loop.ctx
	foreign_enter_forget(e)
}
foreign_resource_destroy :: proc(r: ^wl.Resource) {
	c := cast(^Foreign_Resource)r.data
	if c == nil { return }
	for len(c.entered) > 0 { foreign_enter_forget(c.entered[len(c.entered)-1]) }
	delete(c.entered)
	for other, i in c.handle.resources { if other == c { ordered_remove(&c.handle.resources, i); break } }
	r.data = nil
	free(c)
}
foreign_output_forget :: proc(o: ^Foreign_Output) {
	wl.unlisten(&o.destroy)
	wl.unlisten(&o.bind)
	for other, i in o.handle.outputs { if other == o { ordered_remove(&o.handle.outputs, i); break } }
	free(o)
}
foreign_handle_destroy :: proc(h: ^Foreign_Handle) {
	if h == nil { return }
	context = h.manager.global.display.loop.ctx
	wl.remove_source(h.idle)
	wl.signal_emit_final(&h.events.destroy, h)
	for len(h.resources) > 0 {
		r := h.resources[len(h.resources)-1].resource
		wl.post(r, u32(p.Zwlr_Foreign_Toplevel_Handle_V1_Event.closed))
		foreign_resource_destroy(r)
	}
	for len(h.outputs) > 0 { foreign_output_forget(h.outputs[len(h.outputs)-1]) }
	for other in h.manager.handles { if other.parent == h { foreign_parent(other, nil) } }
	for other, i in h.manager.handles { if other == h { ordered_remove(&h.manager.handles, i); break } }
	delete(h.resources)
	delete(h.outputs)
	delete(h.title)
	delete(h.app_id)
	free(h)
}
foreign_flush :: proc(data: rawptr) {
	h := cast(^Foreign_Handle)data
	h.idle = nil
	for c in h.resources { foreign_send(c) }
}
foreign_mark :: proc(h: ^Foreign_Handle, properties: bit_set[Foreign_Property]) {
	for c in h.resources { c.dirty += properties }
	if h.idle == nil { h.idle = wl.on_idle(h.manager.global.display, foreign_flush, h) }
}
foreign_send_outputs :: proc(c: ^Foreign_Resource) {
	wanted := make([dynamic]^wl.Resource, context.temp_allocator)
	for o in c.handle.outputs {
		it := wl.client_resources(&o.output.resources, c.resource.client)
		for r in wl.next_resource(&it) { append(&wanted, r) }
	}
	for i := len(c.entered)-1; i >= 0; i -= 1 {
		e := c.entered[i]
		found := false
		for r in wanted { if r == e.resource { found = true; break } }
		if !found {
			wl.post(c.resource, u32(p.Zwlr_Foreign_Toplevel_Handle_V1_Event.output_leave), wl.Object(e.resource))
			foreign_enter_forget(e)
		}
	}
	for r in wanted {
		found := false
		for e in c.entered { if e.resource == r { found = true; break } }
		if found { continue }
		e := new(Foreign_Enter)
		e.owner, e.resource = c, r
		append(&c.entered, e)
		wl.listen(&r.destroy_signal, &e.destroy, foreign_enter_destroyed)
		wl.post(c.resource, u32(p.Zwlr_Foreign_Toplevel_Handle_V1_Event.output_enter), wl.Object(r))
	}
}
foreign_send :: proc(c: ^Foreign_Resource) {
	if c.dirty == {} { return }
	h, r := c.handle, c.resource
	if .Title in c.dirty { wl.post(r, u32(p.Zwlr_Foreign_Toplevel_Handle_V1_Event.title), wl.String{value = h.title}) }
	if .App_Id in c.dirty { wl.post(r, u32(p.Zwlr_Foreign_Toplevel_Handle_V1_Event.app_id), wl.String{value = h.app_id}) }
	if .Outputs in c.dirty { foreign_send_outputs(c) }
	if .State in c.dirty {
		values: [4]u32
		n := 0
		for state in p.Zwlr_Foreign_Toplevel_Handle_V1_State {
			if state in h.state && (state != .fullscreen || r.version >= 2) { values[n] = u32(state); n += 1 }
		}
		wl.post(r, u32(p.Zwlr_Foreign_Toplevel_Handle_V1_Event.state), wl.Array{size = uint(n*4), data = &values[0]})
	}
	if .Parent in c.dirty && r.version >= 3 {
		parent: ^wl.Resource
		if h.parent != nil { for other in h.parent.resources { if other.resource.client == r.client { parent = other.resource; break } } }
		if parent != nil || h.parent == nil { wl.post(r, u32(p.Zwlr_Foreign_Toplevel_Handle_V1_Event.parent), wl.Object(parent)) }
	}
	wl.post(r, u32(p.Zwlr_Foreign_Toplevel_Handle_V1_Event.done))
	c.dirty = {}
}
foreign_title :: proc(h: ^Foreign_Handle, value: cstring) {
	if h == nil || h.title == string(value) { return }
	context = h.manager.global.display.loop.ctx
	delete(h.title); h.title = strings.clone(string(value))
	foreign_mark(h, {.Title})
}
foreign_app_id :: proc(h: ^Foreign_Handle, value: cstring) {
	if h == nil || h.app_id == string(value) { return }
	context = h.manager.global.display.loop.ctx
	delete(h.app_id); h.app_id = strings.clone(string(value))
	foreign_mark(h, {.App_Id})
}
foreign_state :: proc(h: ^Foreign_Handle, state: p.Zwlr_Foreign_Toplevel_Handle_V1_State, on: bool) {
	if h == nil || (state in h.state) == on { return }
	if on { h.state += {state} } else { h.state -= {state} }
	foreign_mark(h, {.State})
}
foreign_maximized :: proc(h: ^Foreign_Handle, on: bool) { foreign_state(h, .maximized, on) }
foreign_minimized :: proc(h: ^Foreign_Handle, on: bool) { foreign_state(h, .minimized, on) }
foreign_activated :: proc(h: ^Foreign_Handle, on: bool) { foreign_state(h, .activated, on) }
foreign_fullscreen :: proc(h: ^Foreign_Handle, on: bool) { foreign_state(h, .fullscreen, on) }
foreign_parent :: proc(h, parent: ^Foreign_Handle) {
	if h == nil || h.parent == parent { return }
	h.parent = parent
	foreign_mark(h, {.Parent})
}
foreign_output_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	o := wl.owner(listener, Foreign_Output, "destroy")
	context = o.handle.manager.global.display.loop.ctx
	foreign_mark(o.handle, {.Outputs})
	foreign_output_forget(o)
}
foreign_output_bound :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	o := wl.owner(listener, Foreign_Output, "bind")
	context = o.handle.manager.global.display.loop.ctx
	foreign_mark(o.handle, {.Outputs})
}
foreign_output :: proc(h: ^Foreign_Handle, old, next: ^wlr.wlr_output) {
	if h == nil || old == next { return }
	context = h.manager.global.display.loop.ctx
	for o in h.outputs { if o.output == old { foreign_output_forget(o); break } }
	if next != nil {
		found := false
		for o in h.outputs { if o.output == next { found = true; break } }
		if !found {
			o := new(Foreign_Output)
			o.handle, o.output = h, next
			append(&h.outputs, o)
			wl.listen(&next.events.destroy, &o.destroy, foreign_output_destroyed)
			wl.listen(&next.events.bind, &o.bind, foreign_output_bound)
		}
	}
	foreign_mark(h, {.Outputs})
}
foreign_handle_request :: proc(r: ^wl.Resource, request: p.Zwlr_Foreign_Toplevel_Handle_V1_Request, args: []wl.Argument) {
	if request == .destroy { wl.resource_destroy(r); return }
	c := cast(^Foreign_Resource)r.data
	if c == nil { return }
	h := c.handle
	switch request {
	case .destroy:
	case .set_maximized, .unset_maximized:
		e := Foreign_Maximized_Event{h, request == .set_maximized}
		wl.signal_emit_mutable(&h.events.request_maximize, &e)
	case .set_minimized, .unset_minimized:
		e := Foreign_Minimized_Event{h, request == .set_minimized}
		wl.signal_emit_mutable(&h.events.request_minimize, &e)
	case .activate:
		client := seat_client_of(wl.object(args[0]))
		if client != nil { e := Foreign_Activated_Event{h, client.seat}; wl.signal_emit_mutable(&h.events.request_activate, &e) }
	case .set_fullscreen, .unset_fullscreen:
		e := Foreign_Fullscreen_Event{toplevel = h, fullscreen = request == .set_fullscreen}
		if e.fullscreen { e.output = output_of(wl.object(args[0])) }
		wl.signal_emit_mutable(&h.events.request_fullscreen, &e)
	case .close: wl.signal_emit_mutable(&h.events.request_close, h)
	case .set_rectangle:
		e := Foreign_Rectangle_Event{h, surface_of(wl.object(args[0])), i32(args[1].(wl.Int)),
			i32(args[2].(wl.Int)), i32(args[3].(wl.Int)), i32(args[4].(wl.Int))}
		if e.width < 0 || e.height < 0 { wl.post_error(r, u32(p.Zwlr_Foreign_Toplevel_Handle_V1_Error.invalid_rectangle), "negative rectangle size"); return }
		wl.signal_emit_mutable(&h.events.set_rectangle, &e)
	}
}
