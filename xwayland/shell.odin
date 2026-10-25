package xwayland

import wl "../wayland"
import p "../protocols"

Shell_Surface :: struct {
	server: ^Server,
	resource: ^wl.Resource,
	surface: ^Surface,
	pending, serial: u64,
	committed: bool,
	window: ^Window,
	destroy: wl.Listener,
}
shell_bind :: proc(g: ^wl.Global, c: ^wl.Client, version, id: u32) {
	s := cast(^Server)g.data
	if c != s.client { wl.post_error(c.display_resource, 3, "Permission denied"); return }
	r := wl.resource_create_typed(c, &p.xwayland_shell_v1, i32(version), id, s, shell_request, shell_release)
	if r != nil { append(&s.resources, r) }
}
shell_release :: proc(r: ^wl.Resource) {
	s := cast(^Server)r.data
	for other, i in s.resources { if other == r { ordered_remove(&s.resources, i); break } }
}
shell_request :: proc(r: ^wl.Resource, op: p.Xwayland_Shell_V1_Request, args: []wl.Argument) {
	if op == .destroy { wl.resource_destroy(r); return }
	s := new(Shell_Surface); s.server, s.surface = cast(^Server)r.data, surface_of(wl.object(args[1]))
	if s.surface == nil { free(s); wl.post_error(r, 0, "invalid surface"); return }
	s.resource = wl.resource_create_typed(r.client, &p.xwayland_surface_v1, 1, u32(args[0].(wl.New_Id)), s, shell_surface_request, shell_surface_release)
	if s.resource == nil { free(s); return }
	if !role_assign(s, r) { s.resource.data = nil; wl.resource_destroy(s.resource); free(s); return }
	surface_watch(s.surface, &s.destroy, shell_surface_destroy)
	append(&s.server.shells, s)
}
shell_surface_request :: proc(r: ^wl.Resource, op: p.Xwayland_Surface_V1_Request, args: []wl.Argument) {
	if op == .destroy { wl.resource_destroy(r); return }
	s := cast(^Shell_Surface)r.data; if s == nil { return }
	serial := u64(args[0].(wl.Uint)) | u64(args[1].(wl.Uint))<<32
	if s.committed { wl.post_error(r, 0, "surface already associated"); return }
	if serial == 0 || serial <= s.server.last_serial { wl.post_error(r, 1, "invalid serial"); return }
	s.pending = serial; s.server.last_serial = serial
}
shell_surface_release :: proc(r: ^wl.Resource) {
	if s := cast(^Shell_Surface)r.data; s != nil { s.resource = nil; s.pending = 0 }
}
shell_commit :: proc(s: ^Shell_Surface) {
	if s.pending != 0 {
		if s.committed { if s.resource != nil { wl.post_error(s.resource, 0, "surface already associated") }; return }
		s.serial, s.pending, s.committed = s.pending, 0, true
		pair_shell(s)
	}
	if s.window != nil { window_map(s.window) }
}
pair_shell :: proc(s: ^Shell_Surface) {
	if !s.committed || s.window != nil || s.server.xwm == nil { return }
	for _, w in s.server.xwm.windows {
		if w.serial == s.serial && w.surface == nil { s.window = w; window_associate(w, s.surface); return }
	}
}
pair_window :: proc(w: ^Window) {
	if w.surface != nil || w.serial == 0 { return }
	for s in w.xwm.server.shells {
		if s.committed && s.serial == w.serial && s.window == nil { s.window = w; window_associate(w, s.surface); return }
	}
}
shell_surface_destroy :: proc (l: ^wl.Listener, data: rawptr) {
	s := wl.owner(l, Shell_Surface, "destroy"); context = s.server.display.loop.ctx
	shell_retire(s)
}
shell_retire :: proc(s: ^Shell_Surface) {
	wl.unlisten(&s.destroy)
	if s.window != nil { window_dissociate(s.window) }
	if s.resource != nil { s.resource.data = nil }
	role_forget(s)
	for other, i in s.server.shells { if other == s { ordered_remove(&s.server.shells, i); break } }
	free(s)
}
