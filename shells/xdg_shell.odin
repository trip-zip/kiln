package shells

import sf "../surfaces"

import st "../seat"

import p "../protocols"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"
import "core:strings"

Shell :: struct {
	global: ^wl.Global,
	surfaces: [dynamic]^Xdg_Surface,
	events: struct { new_toplevel, new_popup, grab_changed: wl.Signal },
	grab_seat: ^st.Client,
	grab_chain: [dynamic]^Popup,
	grab_destroy: wl.Listener,
	dismissing: bool,
	destroy: wl.Listener,
}
Xdg_Surface :: struct {
	resource, owner: ^wl.Resource,
	shell: ^Shell,
	surface: ^sf.Surface,
	toplevel: ^Toplevel,
	popup: ^Popup,
	popups: [dynamic]^Popup,
	unmapping: bool,
	serial: u32,
}
Toplevel_State :: struct {
	maximized, fullscreen, activated, suspended: bool,
	tiled: u32,
	width, height: i32,
}
Toplevel_Configure :: struct { serial: u32, state: Toplevel_State, decoration_mode: i32 }
Toplevel :: struct {
	resource: ^wl.Resource,
	surface: ^sf.Surface,
	base: ^Xdg_Surface,
	parent: ^Toplevel,
	title, app_id: string,
	current, pending, scheduled: Toplevel_State,
	requested: struct { maximized, minimized, fullscreen: bool, fullscreen_output: ^wlr.wlr_output },
	geometry, pending_geometry, explicit_geometry: wlr.Box,
	geometry_changed: bool,
	initialized, initial_commit, configured, capabilities_sent: bool,
	min_width, min_height, max_width, max_height: i32,
	queue: [dynamic]Toplevel_Configure,
	idle: ^wl.Source,
	decoration: ^Decoration,
	events: struct { destroy, request_maximize, request_fullscreen, request_minimize, set_title, set_app_id: wl.Signal },
	parent_unmap, output_destroy: wl.Listener,
}

xdg_shell_create :: proc(display: ^wl.Display) -> ^Shell {
	s := new(Shell)
	wl.signal_init(&s.events.new_toplevel)
	wl.signal_init(&s.events.new_popup); wl.signal_init(&s.events.grab_changed)
	s.global = wl.global_create_typed(display, &p.xdg_wm_base, 6, s, shell_request, shell_resource_destroy)
	if s.global == nil { free(s); return nil }
	wl.listen(&display.destroy_signal, &s.destroy, shell_destroy)
	return s
}
shell_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Shell, "destroy")
	context = s.global.display.loop.ctx
	for len(s.surfaces) > 0 { wl.resource_destroy(s.surfaces[len(s.surfaces)-1].resource) }
	wl.unlisten(listener)
	wl.global_destroy(s.global)
	delete(s.surfaces)
	delete(s.grab_chain)
	free(s)
}
shell_resource_destroy :: proc(r: ^wl.Resource) {
	s := cast(^Shell)r.data
	for i := len(s.surfaces)-1; i >= 0; i -= 1 {
		x := s.surfaces[i]
		if x.owner == r { wl.resource_destroy(x.resource) }
	}
}
shell_request :: proc(r: ^wl.Resource, request: p.Xdg_Wm_Base_Request, args: []wl.Argument) {
	s := cast(^Shell)r.data
	switch request {
	case .destroy:
		for x in s.surfaces { if x.owner == r { wl.post_error(r, u32(p.Xdg_Wm_Base_Error.defunct_surfaces), "xdg surfaces still exist"); return } }
		wl.resource_destroy(r)
	case .pong:
	case .create_positioner:
		positioner_create(r, u32(args[0].(wl.New_Id)))
	case .get_xdg_surface:
		surface := surface_of(wl.object(args[1]))
		if has_buffer(surface) { wl.post_error(r, u32(p.Xdg_Surface_Error.unconfigured_buffer), "surface already has a buffer"); return }
		x := new(Xdg_Surface)
		x.shell, x.owner, x.surface = s, r, surface
		x.resource = wl.resource_create_typed(r.client, &p.xdg_surface, r.version, u32(args[0].(wl.New_Id)), x, xdg_request, xdg_resource_destroy)
		if x.resource == nil { free(x); return }
		append(&s.surfaces, x)
		if !role_assign(x, r) { wl.resource_destroy(x.resource) }
	}
}
xdg_request :: proc(r: ^wl.Resource, request: p.Xdg_Surface_Request, args: []wl.Argument) {
	x := cast(^Xdg_Surface)r.data
	if x == nil { if request == .destroy { wl.resource_destroy(r) }; return }
	t := x.toplevel
	switch request {
	case .destroy:
		if t != nil || x.popup != nil { wl.post_error(r, u32(p.Xdg_Surface_Error.defunct_role_object), "role object still exists"); return }
		wl.resource_destroy(r)
	case .get_toplevel:
		if t != nil || x.popup != nil { wl.post_error(r, u32(p.Xdg_Surface_Error.already_constructed), "toplevel already exists"); return }
		if has_buffer(x.surface) { wl.post_error(r, u32(p.Xdg_Surface_Error.unconfigured_buffer), "surface already has a buffer"); return }
		t = new(Toplevel)
		t.base, t.surface = x, x.surface
		t.resource = wl.resource_create_typed(r.client, &p.xdg_toplevel, r.version, u32(args[0].(wl.New_Id)), t, toplevel_request, toplevel_resource_destroy)
		if t.resource == nil { free(t); return }
		x.toplevel, x.unmapping = t, false
		for signal in ([]^wl.Signal{&t.events.destroy, &t.events.request_maximize, &t.events.request_fullscreen, &t.events.request_minimize, &t.events.set_title, &t.events.set_app_id}) { wl.signal_init(signal) }
		wl.signal_emit_mutable(&x.shell.events.new_toplevel, t)
	case .get_popup:
		popup_create(x, args)
	case .set_window_geometry:
		if x.popup != nil { popup_window_geometry(x.popup, args); return }
		if t == nil { wl.post_error(r, u32(p.Xdg_Surface_Error.not_constructed), "surface has no role object"); return }
		box := wlr.Box{i32(args[0].(wl.Int)), i32(args[1].(wl.Int)), i32(args[2].(wl.Int)), i32(args[3].(wl.Int))}
		if box.width <= 0 || box.height <= 0 { wl.post_error(r, u32(p.Xdg_Surface_Error.invalid_size), "geometry must have positive size"); return }
		t.pending_geometry, t.geometry_changed = box, true
	case .ack_configure:
		if x.popup != nil { popup_ack(x.popup, u32(args[0].(wl.Uint))); return }
		if t == nil { wl.post_error(r, u32(p.Xdg_Surface_Error.not_constructed), "surface has no role object"); return }
		serial := u32(args[0].(wl.Uint))
		for c, i in t.queue {
			if c.serial != serial { continue }
			t.pending, t.configured = c.state, true
			if t.decoration != nil { t.decoration.pending_mode = c.decoration_mode }
			for _ in 0..=i { ordered_remove(&t.queue, 0) }
			return
		}
		wl.post_error(r, u32(p.Xdg_Surface_Error.invalid_serial), "unknown configure serial")
	}
}
// These roles cannot be synchronized subsurfaces; pending state is applied in the role commit.
xdg_validate :: proc(x: ^Xdg_Surface) {
	if x.popup != nil { popup_validate(x.popup); return }
	t := x.toplevel
	if t == nil { wl.post_error(x.resource, u32(p.Xdg_Surface_Error.not_constructed), "surface has no role object"); return }
	if has_pending_buffer(x.surface) && !t.configured { wl.post_error(x.resource, u32(p.Xdg_Surface_Error.unconfigured_buffer), "initial configure has not been acknowledged"); return }
	if d := t.decoration; d != nil && has_pending_buffer(x.surface) && !d.sent { wl.post_error(d.resource, u32(p.Zxdg_Toplevel_Decoration_V1_Error.unconfigured_buffer), "decoration has not been configured"); return }
	if t.min_width < 0 || t.min_height < 0 || t.max_width < 0 || t.max_height < 0 ||
		(t.max_width != 0 && t.max_width < t.min_width) || (t.max_height != 0 && t.max_height < t.min_height) {
		wl.post_error(t.resource, u32(p.Xdg_Toplevel_Error.invalid_size), "invalid minimum or maximum size")
	}
}
xdg_commit :: proc(x: ^Xdg_Surface) {
	if x.popup != nil { popup_commit(x.popup); return }
	t := x.toplevel
	if t == nil || x.resource.client.failed { return }
	if x.unmapping { x.unmapping = false; return }
	buffer := has_buffer(x.surface)
	if buffer && !t.configured { wl.post_error(x.resource, u32(p.Xdg_Surface_Error.unconfigured_buffer), "initial configure has not been acknowledged"); return }
	t.initial_commit, t.initialized = !t.initialized, true
	t.current = t.pending
	if t.decoration != nil { t.decoration.current_mode = t.decoration.pending_mode }
	if !x.surface.mapped && buffer { map_surface(x.surface) } else { xdg_geometry(x) }
	if t.initial_commit { schedule_configure(t) }
}
xdg_geometry :: proc(x: ^Xdg_Surface) {
	if x.popup != nil { popup_geometry(x.popup); return }
	t := x.toplevel
	if t == nil { return }
	if t.geometry_changed { t.explicit_geometry = t.pending_geometry; t.geometry_changed = false }
	extents, box := surface_extents(x.surface), t.explicit_geometry
	t.geometry = extents
	if box.width > 0 {
		left, top := max(extents.x, box.x), max(extents.y, box.y)
		right, bottom := min(extents.x+extents.width, box.x+box.width), min(extents.y+extents.height, box.y+box.height)
		t.geometry = wlr.Box{left, top, max(0,right-left), max(0,bottom-top)}
	}
}
xdg_reset :: proc(x: ^Xdg_Surface) {
	dismiss_children(x.surface)
	if x.popup != nil { popup_reset(x.popup); return }
	t := x.toplevel
	if t == nil { return }
	if t.idle != nil { wl.source_remove(t.idle); t.idle = nil }
	clear(&t.queue)
	wl.unlisten(&t.parent_unmap); wl.unlisten(&t.output_destroy)
	t.parent, t.requested = nil, {}
	delete(t.title); delete(t.app_id); t.title, t.app_id = "", ""
	t.initialized, t.initial_commit, t.configured, t.capabilities_sent = false, false, false, false
	t.current, t.pending, t.scheduled = {}, {}, {}
	t.geometry, t.pending_geometry, t.explicit_geometry, t.geometry_changed = {}, {}, {}, false
	t.min_width, t.min_height, t.max_width, t.max_height = 0, 0, 0, 0
	if d := t.decoration; d != nil { d.sent = false; d.pending_mode, d.current_mode, d.scheduled_mode = 0, 0, 0 }
}
xdg_retire :: proc(x: ^Xdg_Surface) {
	dismiss_children(x.surface)
	if x.popup != nil { popup_retire(x.popup) }
	role_forget(x)
	delete(x.popups)
	if x.toplevel != nil { toplevel_retire(x.toplevel) }
	x.resource.data = nil
	for other, i in x.shell.surfaces { if other == x { ordered_remove(&x.shell.surfaces, i); break } }
	free(x)
}
xdg_resource_destroy :: proc(r: ^wl.Resource) {
	if x := cast(^Xdg_Surface)r.data; x != nil { xdg_retire(x) }
}
toplevel_retire :: proc(t: ^Toplevel) {
	dismiss_children(t.surface)
	unmap_surface(t.surface)
	if t.decoration != nil {
		wl.post_error(t.decoration.resource, u32(p.Zxdg_Toplevel_Decoration_V1_Error.orphaned), "decoration outlived its toplevel")
		wl.resource_destroy(t.decoration.resource)
	}
	xdg_reset(t.base)
	wl.signal_emit_final(&t.events.destroy, t)
	t.base.toplevel = nil
	t.resource.data = nil
	delete(t.queue)
	free(t)
}
toplevel_resource_destroy :: proc(r: ^wl.Resource) { if t := cast(^Toplevel)r.data; t != nil { toplevel_retire(t) } }

schedule_configure :: proc(t: ^Toplevel) -> u32 {
	if !t.initialized { return 0 }
	if t.idle == nil {
		t.base.serial += 1
		if t.base.serial == 0 { t.base.serial = 1 }
		t.idle = wl.on_idle(t.resource.client.display, toplevel_configure, t)
	}
	return t.base.serial
}
toplevel_configure :: proc(data: rawptr) {
	t := cast(^Toplevel)data
	t.idle = nil
	if !t.capabilities_sent && t.resource.version >= 5 {
		caps := [4]u32{1,2,3,4}
		wl.post(t.resource, u32(p.Xdg_Toplevel_Event.wm_capabilities), wl.Array{size = 16, data = &caps[0]})
	}
	t.capabilities_sent = true
	state := t.scheduled
	values: [9]u32
	n := 0
	if state.maximized { values[n] = 1; n += 1 }
	if state.fullscreen { values[n] = 2; n += 1 }
	if state.activated { values[n] = 4; n += 1 }
	if t.resource.version >= 2 {
		for edge, i in ([4]u32{4,8,1,2}) { if state.tiled & edge != 0 { values[n] = u32(5+i); n += 1 } }
	}
	if state.suspended && t.resource.version >= 6 { values[n] = 9; n += 1 }
	wl.post(t.resource, u32(p.Xdg_Toplevel_Event.configure), wl.Int(state.width), wl.Int(state.height), wl.Array{size = uint(n*4), data = &values[0]})
	mode := i32(0)
	if d := t.decoration; d != nil {
		mode = d.scheduled_mode
		if mode != 0 && (!d.sent || d.pending_mode != mode) {
			wl.post(d.resource, u32(p.Zxdg_Toplevel_Decoration_V1_Event.configure), wl.Uint(mode))
			d.sent = true
		}
	}
	append(&t.queue, Toplevel_Configure{t.base.serial, state, mode})
	wl.post(t.base.resource, u32(p.Xdg_Surface_Event.configure), wl.Uint(t.base.serial))
}
set_activated :: proc(t: ^Toplevel, on: bool) -> u32 { t.scheduled.activated = on; return schedule_configure(t) }
set_maximized :: proc(t: ^Toplevel, on: bool) -> u32 { t.scheduled.maximized = on; return schedule_configure(t) }
set_fullscreen :: proc(t: ^Toplevel, on: bool) -> u32 { t.scheduled.fullscreen = on; return schedule_configure(t) }
set_suspended :: proc(t: ^Toplevel, on: bool) -> u32 { t.scheduled.suspended = on; return schedule_configure(t) }
set_tiled :: proc(t: ^Toplevel, edges: u32) -> u32 { t.scheduled.tiled = edges; return schedule_configure(t) }
set_size :: proc(t: ^Toplevel, width, height: i32) -> u32 { t.scheduled.width, t.scheduled.height = max(0,width), max(0,height); return schedule_configure(t) }
send_close :: proc(t: ^Toplevel) { wl.post(t.resource, u32(p.Xdg_Toplevel_Event.close)) }

parent_set :: proc(t, parent: ^Toplevel) {
	wl.unlisten(&t.parent_unmap)
	t.parent = nil
	if parent != nil && parent.surface.mapped {
		t.parent = parent
		wl.listen(&parent.surface.events.unmap, &t.parent_unmap, parent_unmapped)
	}
}
parent_unmapped :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	t := wl.owner(listener, Toplevel, "parent_unmap")
	context = t.resource.client.display.loop.ctx
	parent_set(t, t.parent.parent)
}
fullscreen_output_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	t := wl.owner(listener, Toplevel, "output_destroy")
	t.requested.fullscreen_output = nil
	wl.unlisten(listener)
}
toplevel_request :: proc(r: ^wl.Resource, request: p.Xdg_Toplevel_Request, args: []wl.Argument) {
	t := cast(^Toplevel)r.data
	if t == nil { if request == .destroy { wl.resource_destroy(r) }; return }
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .set_parent:
		parent: ^Toplevel
		if pr := wl.object(args[0]); pr != nil { parent = cast(^Toplevel)pr.data }
		for it := parent; it != nil; it = it.parent { if it == t { wl.post_error(r, u32(p.Xdg_Toplevel_Error.invalid_parent), "parent cycle"); return } }
		parent_set(t, parent)
	case .set_title:
		text := args[0].(wl.String).value
		delete(t.title); t.title = strings.clone(text)
		wl.signal_emit_mutable(&t.events.set_title, t)
	case .set_app_id:
		delete(t.app_id); t.app_id = strings.clone(args[0].(wl.String).value)
		wl.signal_emit_mutable(&t.events.set_app_id, t)
	case .set_max_size: t.max_width, t.max_height = i32(args[0].(wl.Int)), i32(args[1].(wl.Int))
	case .set_min_size: t.min_width, t.min_height = i32(args[0].(wl.Int)), i32(args[1].(wl.Int))
	case .set_maximized, .unset_maximized:
		t.requested.maximized = request == .set_maximized
		wl.signal_emit_mutable(&t.events.request_maximize, t)
	case .set_fullscreen, .unset_fullscreen:
		wl.unlisten(&t.output_destroy)
		t.requested.fullscreen, t.requested.fullscreen_output = request == .set_fullscreen, nil
		if request == .set_fullscreen { t.requested.fullscreen_output = output_of(wl.object(args[0])) }
		if output := t.requested.fullscreen_output; output != nil { wl.listen(&output.events.destroy, &t.output_destroy, fullscreen_output_destroyed) }
		wl.signal_emit_mutable(&t.events.request_fullscreen, t)
	case .set_minimized:
		t.requested.minimized = true
		wl.signal_emit_mutable(&t.events.request_minimize, t)
	case .show_window_menu, .move, .resize:
		if request == .resize {
			edge := u32(args[2].(wl.Uint))
			if edge != 0 && edge != 1 && edge != 2 && edge != 4 && edge != 5 && edge != 6 && edge != 8 && edge != 9 && edge != 10 { wl.post_error(r, u32(p.Xdg_Toplevel_Error.invalid_resize_edge), "invalid resize edge"); return }
		}
		if !t.configured { wl.post_error(t.base.resource, u32(p.Xdg_Surface_Error.not_constructed), "surface is not configured") }
	}
}
