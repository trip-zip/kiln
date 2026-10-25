package xwayland

import sf "../surfaces"

import wl "../wayland"

Surface :: sf.Surface
Surface_Role :: sf.Role
surface_of :: proc(r: ^wl.Resource) -> ^Surface {
	if r == nil || string(r.interface.name) != "wl_surface" { return nil }
	return sf.of(r)
}
surface_resource :: proc(s: ^Surface) -> ^wl.Resource { return s.resource }
surface_watch :: proc(s: ^Surface, l: ^wl.Listener, callback: wl.Odin_Notify) { wl.listen(&s.events.destroy, l, callback) }
surface_watch_commit :: proc(s: ^Surface, l: ^wl.Listener, callback: wl.Odin_Notify) { wl.listen(&s.events.commit, l, callback) }
map_surface :: sf.map_
unmap_surface :: sf.unmap
has_buffer :: sf.has_buffer
surface_mapped :: proc(s: ^Surface) -> bool { return s.mapped }
roles: map[^Surface]^Shell_Surface
// The protocol object may be destroyed without ending the surface association.
role := Surface_Role{name="xwayland_surface_v1", no_object=true, commit=surface_committed}
legacy_role := Surface_Role{name="xwayland_surface", no_object=true}
role_assign :: proc(s: ^Shell_Surface, error_resource: ^wl.Resource) -> bool {
	if roles[s.surface] != nil { wl.post_error(error_resource, 0, "surface already has an Xwayland role"); return false }
	if !sf.set_role(s.surface, &role, error_resource, 0) { return false }
	if roles == nil { roles = make(map[^Surface]^Shell_Surface) }; roles[s.surface] = s
	return true
}
role_forget :: proc(s: ^Shell_Surface) {
	delete_key(&roles, s.surface); if len(roles)==0 { delete(roles); roles=nil }
}
surface_committed :: proc (surface: ^Surface) {
	if s := roles[surface]; s != nil { shell_commit(s) }
}
legacy_assign :: proc(s: ^Surface) -> bool { return sf.set_role(s, &legacy_role, s.resource, 0) }
