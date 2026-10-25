package surfaces

import wl "../wayland"
import p "../protocols"
import rg "../region"

Field :: enum { Buffer, Surface_Damage, Buffer_Damage, Opaque, Input, Transform, Scale, Frame, Viewport, Offset }
Committed :: bit_set[Field]
Viewport_State :: struct { has_src, has_dst: bool, src: Fbox, dst_width, dst_height: i32 }
Fbox :: struct { x,y,width,height: f64 }
Child :: struct { sub: ^Subsurface, x,y: i32 }
State :: struct {
	committed: Committed,
	seq: u32,
	buffer: ^Buffer,
	dx,dy: i32,
	surface_damage, buffer_damage, opaque, input: rg.Region,
	input_infinite: bool,
	transform, scale: i32,
	frame_callbacks: [dynamic]^wl.Resource,
	width,height,buffer_width,buffer_height: i32,
	below,above: [dynamic]Child,
	viewport: Viewport_State,
	locks: int,
}
Surface :: struct {
	resource: ^wl.Resource,
	compositor: ^Compositor,
	current,pending: State,
	cached: [dynamic]^State,
	buffer_damage,opaque_region,input_region: rg.Region,
	mapped: bool,
	role: ^Role,
	role_resource: ^wl.Resource,
	role_data: rawptr,
	outputs: [dynamic]^Surface_Output,
	events: struct { client_commit,commit,map_,unmap,new_subsurface,destroy: wl.Signal },
	previous: struct { scale,transform,width,height,buffer_width,buffer_height: i32 },
	unmap_commit,opaque,handling_commit,pending_rejected: bool,
	preferred_scale,preferred_transform: i32,
	preferred_transform_sent: bool,
	pending_buffer: ^wl.Resource,
	pending_buffer_destroy,role_destroy: wl.Listener,
	fractional: ^Fractional,
	fractional_scale: f64,
	viewport: ^Viewport,
	subsurface: ^Subsurface,
}
of :: proc(r: ^wl.Resource) -> ^Surface {
	if r == nil || r.interface != &p.wl_surface { return nil }
	return cast(^Surface)r.data
}
state_init :: proc(s: ^State) { s.scale = 1; s.input_infinite = true }
state_finish :: proc(s: ^State) {
	buffer_unlock(s.buffer)
	for len(s.frame_callbacks)>0 { wl.resource_destroy(s.frame_callbacks[len(s.frame_callbacks)-1]) }
	delete(s.frame_callbacks); delete(s.below); delete(s.above)
	for r in ([]^rg.Region{&s.surface_damage,&s.buffer_damage,&s.opaque,&s.input}) { rg.finish(r) }
}
set_pending_buffer :: proc(s: ^Surface, r: ^wl.Resource) {
	wl.unlisten(&s.pending_buffer_destroy); s.pending_buffer = r
	if r != nil { wl.listen(&r.destroy_signal,&s.pending_buffer_destroy,pending_buffer_gone) }
}
pending_buffer_gone :: proc(l: ^wl.Listener, data: rawptr) { set_pending_buffer(wl.owner(l,Surface,"pending_buffer_destroy"),nil) }
callback_destroy :: proc(r: ^wl.Resource) {
	state := cast(^State)r.data
	for other,i in state.frame_callbacks { if other == r { ordered_remove(&state.frame_callbacks,i); break } }
}
callback_request :: proc(r: ^wl.Resource, op: u32, args: []wl.Argument) {}
surface_request :: proc(r: ^wl.Resource, op: p.Wl_Surface_Request, args: []wl.Argument) {
	s := of(r); next := &s.pending
	switch op {
	case .destroy:
		if s.role_resource != nil { wl.post_error(r,u32(p.Wl_Surface_Error.defunct_role_object),"surface still has a role object"); return }
		wl.resource_destroy(r)
	case .attach:
		x,y := i32(args[1].(wl.Int)),i32(args[2].(wl.Int))
		if r.version>=5 && (x!=0 || y!=0) { wl.post_error(r,u32(p.Wl_Surface_Error.invalid_offset),"attach offset must be zero"); return }
		next.committed += {.Buffer}; set_pending_buffer(s,wl.object(args[0]))
		if r.version<5 { next.committed += {.Offset}; next.dx,next.dy = x,y }
	case .damage, .damage_buffer:
		b := rg.Box{i32(args[0].(wl.Int)),i32(args[1].(wl.Int)),i32(args[2].(wl.Int)),i32(args[3].(wl.Int))}
		if b.width<0 || b.height<0 { return }
		if op == .damage { next.committed += {.Surface_Damage}; rg.union_rect(&next.surface_damage,b) }
		else { next.committed += {.Buffer_Damage}; rg.union_rect(&next.buffer_damage,b) }
	case .frame:
		cb := wl.resource_create_typed(r.client,&p.wl_callback,1,u32(args[0].(wl.New_Id)),next,callback_request,callback_destroy)
		if cb != nil { append(&next.frame_callbacks,cb); next.committed += {.Frame} }
	case .set_opaque_region, .set_input_region:
		input := op == .set_input_region
		dst := &next.input if input else &next.opaque
		next.committed += {.Input} if input else {.Opaque}
		source := region_of(wl.object(args[0])); rg.clear(dst)
		if source != nil { rg.copy(dst,source) }
		if input { next.input_infinite = source == nil }
	case .commit: commit(s)
	case .set_buffer_transform:
		v := i32(args[0].(wl.Int))
		if v<0 || v>7 { wl.post_error(r,u32(p.Wl_Surface_Error.invalid_transform),"invalid buffer transform"); return }
		next.committed += {.Transform}; next.transform = v
	case .set_buffer_scale:
		v := i32(args[0].(wl.Int))
		if v<=0 { wl.post_error(r,u32(p.Wl_Surface_Error.invalid_scale),"buffer scale must be positive"); return }
		next.committed += {.Scale}; next.scale = v
	case .offset: next.committed += {.Offset}; next.dx,next.dy = i32(args[0].(wl.Int)),i32(args[1].(wl.Int))
	case .get_release:
	}
}
surface_destroy :: proc(r: ^wl.Resource) {
	s := of(r); destroy_role_object(s)
	wl.signal_emit_final(&s.events.destroy,s)
	if s.viewport != nil { viewport_detach(s.viewport) }
	if s.fractional != nil { s.fractional.surface = nil; s.fractional = nil }
	wl.unlisten(&s.pending_buffer_destroy); wl.unlisten(&s.role_destroy)
	for state in s.cached { state_finish(state); free(state) }; delete(s.cached)
	state_finish(&s.pending); state_finish(&s.current)
	for region in ([]^rg.Region{&s.buffer_damage,&s.opaque_region,&s.input_region}) { rg.finish(region) }
	for len(s.outputs)>0 { output_remove(s.outputs[len(s.outputs)-1]) }; delete(s.outputs)
	free(s)
}
