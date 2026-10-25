package surfaces

import wl "../wayland"
import p "../protocols"

Subsurface :: struct {
	resource: ^wl.Resource,
	surface,parent: ^Surface,
	synchronized,added,has_cache: bool,
	cached_seq: u32,
	current,pending: struct { x,y: i32 },
	client_commit,parent_destroy: wl.Listener,
}
sub_role := Role{name="wl_subsurface",commit=sub_role_commit,destroy=sub_role_destroy}
subcompositor_create :: proc(d: ^wl.Display) -> ^Global { return create_global(d,&p.wl_subcompositor,subcompositor_request) }
subcompositor_request :: proc(r: ^wl.Resource, op: p.Wl_Subcompositor_Request, args: []wl.Argument) {
	if op == .destroy { wl.resource_destroy(r); return }
	s,parent := of(wl.object(args[1])),of(wl.object(args[2]))
	if !set_role(s,&sub_role,r,u32(p.Wl_Subcompositor_Error.bad_surface)) { return }
	if root(parent) == s { wl.post_error(r,u32(p.Wl_Subcompositor_Error.bad_parent),"surface cannot parent itself or an ancestor"); return }
	sub := new(Subsurface); sub.surface,sub.parent,sub.synchronized = s,parent,true
	sub.resource = wl.resource_create_typed(r.client,&p.wl_subsurface,1,u32(args[0].(wl.New_Id)),sub,subsurface_request)
	if sub.resource == nil { free(sub); return }
	s.subsurface = sub; set_role_object(s,sub.resource)
	append(&parent.pending.above,Child{sub=sub})
	wl.listen(&s.events.client_commit,&sub.client_commit,sub_client_commit)
	wl.listen(&parent.events.destroy,&sub.parent_destroy,sub_parent_destroy)
}
effective_sync :: proc(sub: ^Subsurface) -> bool {
	for v := sub; v != nil; v = v.parent.subsurface { if v.synchronized { return true } }; return false
}
release_cache :: proc(sub: ^Subsurface) {
	if sub.has_cache { sub.has_cache = false; unlock_cached(sub.surface,sub.cached_seq) }
}
release_desynchronized :: proc(sub: ^Subsurface) {
	if effective_sync(sub) { return }
	release_cache(sub)
	for list in ([2][]Child{sub.surface.pending.below[:],sub.surface.pending.above[:]}) { for c in list { release_desynchronized(c.sub) } }
}
sub_client_commit :: proc(l: ^wl.Listener, data: rawptr) {
	sub := wl.owner(l,Subsurface,"client_commit")
	if effective_sync(sub) {
		if !sub.has_cache { sub.has_cache = true; sub.cached_seq = lock_pending(sub.surface) }
	} else { release_cache(sub) }
}
parent_commit :: proc(sub: ^Subsurface) {
	release_cache(sub)
	if !sub.added {
		sub.added = true; wl.signal_emit_mutable(&sub.parent.events.new_subsurface,sub); consider_map(sub)
	}
}
consider_map :: proc(sub: ^Subsurface) { if sub.added && sub.parent.mapped && has_buffer(sub.surface) { map_(sub.surface) } }
sub_role_commit :: proc(s: ^Surface) { if s.subsurface != nil { consider_map(s.subsurface) } }
remove_child :: proc(list: ^[dynamic]Child, sub: ^Subsurface) {
	for c,i in list^ { if c.sub == sub { ordered_remove(list,i); return } }
}
sub_role_destroy :: proc(s: ^Surface) { if s.subsurface != nil { subsurface_destroy(s.subsurface) } }
sub_parent_destroy :: proc(l: ^wl.Listener, data: rawptr) { subsurface_destroy(wl.owner(l,Subsurface,"parent_destroy")) }
subsurface_destroy :: proc(sub: ^Subsurface) {
	release_cache(sub); unmap(sub.surface)
	wl.unlisten(&sub.client_commit); wl.unlisten(&sub.parent_destroy)
	for n in ([]^State{&sub.parent.current,&sub.parent.pending}) { remove_child(&n.below,sub); remove_child(&n.above,sub) }
	for n in sub.parent.cached { remove_child(&n.below,sub); remove_child(&n.above,sub) }
	sub.surface.subsurface = nil; sub.resource.data = nil; free(sub)
}
subsurface_request :: proc(r: ^wl.Resource, op: p.Wl_Subsurface_Request, args: []wl.Argument) {
	if op == .destroy { wl.resource_destroy(r); return }
	sub := cast(^Subsurface)r.data
	if sub == nil { return }
	switch op {
	case .destroy:
	case .set_position: sub.pending = {i32(args[0].(wl.Int)),i32(args[1].(wl.Int))}
	case .set_sync: sub.synchronized = true
	case .set_desync:
		sub.synchronized = false; release_desynchronized(sub)
	case .place_above, .place_below:
		sibling := of(wl.object(args[0])); n := &sub.parent.pending
		list: ^[dynamic]Child
		index := 0
		if sibling == sub.parent {
			list = &n.above if op == .place_above else &n.below
			index = 0 if op == .place_above else len(list^)
		} else {
			for candidates in ([]^[dynamic]Child{&n.below,&n.above}) { for c,i in candidates^ {
				if c.sub != sub && c.sub.surface == sibling { list,index = candidates,i; if op == .place_above { index += 1 } }
			} }
		}
		if list == nil { wl.post_error(r,u32(p.Wl_Subsurface_Error.bad_surface),"surface is not a parent or sibling"); return }
		for c,i in list^ { if c.sub == sub && i<index { index -= 1 } }
		remove_child(&n.below,sub); remove_child(&n.above,sub)
		append(list,Child{}); for i:=len(list^)-1; i>index; i-=1 { list^[i] = list^[i-1] }; list^[index] = Child{sub=sub}
	}
}
