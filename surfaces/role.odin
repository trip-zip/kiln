package surfaces

import wl "../wayland"
import "core:fmt"

Role :: struct { name: string, no_object: bool, client_commit,commit,map_,unmap,destroy: proc(^Surface) }
set_role :: proc(s: ^Surface, role: ^Role, error_resource: ^wl.Resource, code: u32) -> bool {
	if s.role != nil && s.role != role {
		if error_resource != nil { wl.post_error(error_resource,code,fmt.tprintf("Cannot assign role %s to wl_surface@%d, already has role %s",role.name,s.resource.id,s.role.name)) }
		return false
	}
	if s.role_resource != nil {
		if error_resource != nil { wl.post_error(error_resource,code,fmt.tprintf("Cannot reassign role %s to wl_surface@%d, role object still exists",role.name,s.resource.id)) }
		return false
	}
	s.role = role; return true
}
set_role_object :: proc(s: ^Surface, r: ^wl.Resource) {
	assert(s.role != nil && !s.role.no_object && s.role_resource == nil && r != nil)
	s.role_resource = r; wl.listen(&r.destroy_signal,&s.role_destroy,role_object_gone)
}
role_object_gone :: proc(l: ^wl.Listener, data: rawptr) { destroy_role_object(wl.owner(l,Surface,"role_destroy")) }
destroy_role_object :: proc(s: ^Surface) {
	if s.role_resource == nil { return }
	unmap(s)
	if s.role.destroy != nil { s.role.destroy(s) }
	s.role_resource = nil; wl.unlisten(&s.role_destroy)
}
role_active :: proc(s: ^Surface) -> bool { return s.role != nil && (s.role.no_object || s.role_resource != nil) }
map_surface :: proc(s: ^Surface) {
	if s.mapped { return }; assert(has_buffer(s)); s.mapped = true
	for list in ([2][]Child{s.current.below[:],s.current.above[:]}) { for c in list { consider_map(c.sub) } }
	if role_active(s) && s.role.map_ != nil { s.role.map_(s) }
	wl.signal_emit_mutable(&s.events.map_,s)
}
map_ :: map_surface
unmap :: proc(s: ^Surface) {
	if !s.mapped { return }; s.mapped = false
	wl.signal_emit_mutable(&s.events.unmap,s)
	if role_active(s) && s.role.unmap != nil { s.role.unmap(s) }
	for list in ([2][]Child{s.current.below[:],s.current.above[:]}) { for c in list { unmap(c.sub.surface) } }
}
