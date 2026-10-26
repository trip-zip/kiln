package shells

import p "../protocols"
import wl "../wayland"
import "base:runtime"

Decoration_Manager :: struct {
	global, legacy: ^wl.Global,
	events: struct { new_toplevel_decoration: wl.Signal },
	destroy: wl.Listener,
}
Decoration :: struct {
	resource: ^wl.Resource,
	toplevel: ^Toplevel,
	scheduled_mode, requested_mode, pending_mode, current_mode: i32,
	sent: bool,
	events: struct { destroy, request_mode: wl.Signal },
}
decoration_create :: proc(display: ^wl.Display) -> ^Decoration_Manager {
	m := new(Decoration_Manager)
	wl.signal_init(&m.events.new_toplevel_decoration)
	m.global = wl.global_create_typed(display, &p.zxdg_decoration_manager_v1, 1, m, decoration_manager_request)
	m.legacy = wl.global_create_typed(display, &p.org_kde_kwin_server_decoration_manager, 1, m, legacy_manager_request, initialize = legacy_bind)
	if m.global == nil || m.legacy == nil {
		if m.global != nil { wl.global_destroy(m.global) }
		if m.legacy != nil { wl.global_destroy(m.legacy) }
		free(m); return nil
	}
	wl.listen(&display.destroy_signal, &m.destroy, decoration_manager_destroy)
	return m
}
decoration_manager_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Decoration_Manager, "destroy")
	context = m.global.display.loop.ctx
	wl.unlisten(listener)
	wl.global_destroy(m.global); wl.global_destroy(m.legacy)
	free(m)
}
decoration_manager_request :: proc(r: ^wl.Resource, request: p.Zxdg_Decoration_Manager_V1_Request, args: []wl.Argument) {
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .get_toplevel_decoration:
		t := cast(^Toplevel)wl.object(args[1]).data
		if t == nil { return }
		if t.decoration != nil { wl.post_error(r, u32(p.Zxdg_Toplevel_Decoration_V1_Error.already_constructed), "toplevel already has a decoration"); return }
		if has_buffer(t.surface) { wl.post_error(r, u32(p.Zxdg_Toplevel_Decoration_V1_Error.unconfigured_buffer), "toplevel already has a buffer"); return }
		d := new(Decoration)
		d.toplevel = t
		wl.signal_init(&d.events.destroy); wl.signal_init(&d.events.request_mode)
		d.resource = wl.resource_create_typed(r.client, &p.zxdg_toplevel_decoration_v1, 1, u32(args[0].(wl.New_Id)), d, decoration_request, decoration_destroy)
		if d.resource == nil { free(d); return }
		t.decoration = d
		wl.signal_emit_mutable(&(cast(^Decoration_Manager)r.data).events.new_toplevel_decoration, d)
	}
}
decoration_request :: proc(r: ^wl.Resource, request: p.Zxdg_Toplevel_Decoration_V1_Request, args: []wl.Argument) {
	d := cast(^Decoration)r.data
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .set_mode, .unset_mode:
		d.requested_mode = 0
		if request == .set_mode {
			mode := u32(args[0].(wl.Uint))
			if mode != 1 && mode != 2 { wl.post_error(r, u32(p.Zxdg_Toplevel_Decoration_V1_Error.invalid_mode), "invalid decoration mode"); return }
			d.requested_mode = i32(mode)
		}
		wl.signal_emit_mutable(&d.events.request_mode, d)
		if d.toplevel.initialized { schedule_configure(d.toplevel) }
	}
}
decoration_destroy :: proc(r: ^wl.Resource) {
	d := cast(^Decoration)r.data
	wl.signal_emit_final(&d.events.destroy, d)
	d.toplevel.decoration = nil
	free(d)
}
set_mode :: proc(d: ^Decoration, mode: i32) -> u32 {
	assert(mode == 1 || mode == 2)
	d.scheduled_mode = mode
	return schedule_configure(d.toplevel)
}
decoration_server_mode :: proc(d: ^Decoration) {
	if d != nil && d.toplevel.initialized && d.scheduled_mode != 2 { set_mode(d, 2) }
}
legacy_bind :: proc(r: ^wl.Resource) { wl.post(r, u32(p.Org_Kde_Kwin_Server_Decoration_Manager_Event.default_mode), wl.Uint(2)) }
legacy_manager_request :: proc(r: ^wl.Resource, request: p.Org_Kde_Kwin_Server_Decoration_Manager_Request, args: []wl.Argument) {
	switch request {
	case .create:
		mode := new(u32)
		mode^ = u32(p.Org_Kde_Kwin_Server_Decoration_Mode.Server)
		decoration := wl.resource_create_typed(r.client, &p.org_kde_kwin_server_decoration, 1, u32(args[0].(wl.New_Id)), mode, legacy_request, legacy_destroy)
		if decoration == nil { free(mode); return }
		wl.post(decoration, u32(p.Org_Kde_Kwin_Server_Decoration_Event.mode), wl.Uint(mode^))
	}
}
// The protocol acknowledges a request by echoing its mode. Answering with any
// other mode makes the client ask again, and both sides spin forever.
legacy_request :: proc(r: ^wl.Resource, request: p.Org_Kde_Kwin_Server_Decoration_Request, args: []wl.Argument) {
	switch request {
	case .release: wl.resource_destroy(r)
	case .request_mode:
		mode := cast(^u32)r.data
		requested := u32(args[0].(wl.Uint))
		if requested > u32(p.Org_Kde_Kwin_Server_Decoration_Mode.Server) || requested == mode^ { return }
		mode^ = requested
		wl.post(r, u32(p.Org_Kde_Kwin_Server_Decoration_Event.mode), wl.Uint(requested))
	}
}
legacy_destroy :: proc(r: ^wl.Resource) { free(r.data) }
