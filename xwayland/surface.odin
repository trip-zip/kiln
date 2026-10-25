package xwayland

import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

Surface :: wlr.Surface
Surface_Role :: struct {
	name: cstring,
	no_object: bool,
	client_commit, commit, map_, unmap, destroy: proc "c" (^wlr.Surface),
}
#assert(size_of(Surface_Role)==56 && align_of(Surface_Role)==8)
#assert(offset_of(Surface_Role,name)==0 && offset_of(Surface_Role,no_object)==8)
#assert(offset_of(Surface_Role,client_commit)==16 && offset_of(Surface_Role,commit)==24)
#assert(offset_of(Surface_Role,map_)==32 && offset_of(Surface_Role,unmap)==40 && offset_of(Surface_Role,destroy)==48)
#assert(offset_of(wlr.Surface,resource)==0 && offset_of(wlr.Surface,events)==712 && offset_of(wlr.Surface,mapped)==688)
#assert(offset_of(wlr.wlr_surface_events,destroy)==80 && offset_of(wlr.wlr_surface_events,commit)==16)
foreign import surface_lib "system:wlroots-0.20"
foreign surface_lib {
	wlr_surface_set_role :: proc(^wlr.Surface, ^Surface_Role, ^wl.Resource, u32) -> bool ---
	wlr_surface_map :: proc(^wlr.Surface) ---
	wlr_surface_unmap :: proc(^wlr.Surface) ---
	wlr_surface_has_buffer :: proc(^wlr.Surface) -> bool ---
}
surface_of :: proc(r: ^wl.Resource) -> ^Surface {
	if r == nil || string(r.interface.name) != "wl_surface" { return nil }
	return wlr.wlr_surface_from_resource(r)
}
surface_resource :: proc(s: ^Surface) -> ^wl.Resource { return s.resource }
surface_watch :: proc(s: ^Surface, l: ^wl.Listener, callback: wl.Notify) { wl.listen(&s.events.destroy, l, callback) }
surface_watch_commit :: proc(s: ^Surface, l: ^wl.Listener, callback: wl.Notify) { wl.listen(&s.events.commit, l, callback) }
map_surface :: wlr_surface_map
unmap_surface :: wlr_surface_unmap
has_buffer :: wlr_surface_has_buffer
surface_mapped :: proc(s: ^Surface) -> bool { return s.mapped }
roles: map[^Surface]^Shell_Surface
// The protocol object may be destroyed without ending the surface association.
role := Surface_Role{name="xwayland_surface_v1", no_object=true, commit=surface_committed}
legacy_role := Surface_Role{name="xwayland_surface", no_object=true}
role_assign :: proc(s: ^Shell_Surface, error_resource: ^wl.Resource) -> bool {
	if roles[s.surface] != nil { wl.post_error(error_resource, 0, "surface already has an Xwayland role"); return false }
	if !wlr_surface_set_role(s.surface, &role, error_resource, 0) { return false }
	if roles == nil { roles = make(map[^Surface]^Shell_Surface) }; roles[s.surface] = s
	return true
}
role_forget :: proc(s: ^Shell_Surface) {
	delete_key(&roles, s.surface); if len(roles)==0 { delete(roles); roles=nil }
}
surface_committed :: proc "c" (surface: ^Surface) {
	context = runtime.default_context(); context = surface.resource.client.display.loop.ctx
	if s := roles[surface]; s != nil { shell_commit(s) }
}
legacy_assign :: proc(s: ^Surface) -> bool { return wlr_surface_set_role(s, &legacy_role, s.resource, 0) }
