package surfaces

import wl "../wayland"
import p "../protocols"
import rg "../region"
import "../gles"
import "core:math"

reject :: proc(s: ^Surface, r: ^wl.Resource, code: u32, message: string) {
	if !s.pending_rejected { wl.post_error(r,code,message); s.pending_rejected = true }
}
transformed_size :: proc(s: ^State) -> (w,h: i32) {
	w,h = s.buffer_width,s.buffer_height
	if s.transform & 1 != 0 { w,h = h,w }; return
}
source_size :: proc(s: ^State) -> (w,h: i32) {
	if s.buffer_width == 0 && s.buffer_height == 0 { return }
	if s.viewport.has_src { return i32(s.viewport.src.width),i32(s.viewport.src.height) }
	w,h = transformed_size(s); return w/s.scale,h/s.scale
}
finalize :: proc(s: ^Surface) {
	n := &s.pending
	if .Buffer in n.committed {
		r := s.pending_buffer; set_pending_buffer(s,nil)
		n.buffer = buffer_of(r)
		if r != nil && n.buffer == nil { reject(s,r,max(u32),"unknown buffer type") }
		n.buffer_width,n.buffer_height = 0,0
		if n.buffer != nil { n.buffer_width,n.buffer_height = n.buffer.width,n.buffer.height }
	}
	if !n.viewport.has_src && (n.buffer_width%n.scale != 0 || n.buffer_height%n.scale != 0) && s.role != nil && s.role.name != "wl_pointer-cursor" && s.role.name != "wp_tablet_tool-cursor" {
		reject(s,s.resource,u32(p.Wl_Surface_Error.invalid_size),"buffer size is not divisible by scale")
	}
	n.width,n.height = source_size(n)
	if n.viewport.has_dst && n.buffer_width>0 && n.buffer_height>0 { n.width,n.height = n.viewport.dst_width,n.viewport.dst_height }
	rg.intersect_rect(&n.surface_damage,{0,0,n.width,n.height})
	rg.intersect_rect(&n.buffer_damage,{0,0,n.buffer_width,n.buffer_height})
}
update_damage :: proc(dst: ^rg.Region, n: ^State) {
	rg.copy(dst,&n.surface_damage)
	if n.viewport.has_dst {
		w,h := source_size(n)
		rg.scale(dst,f64(w)/f64(n.viewport.dst_width),f64(h)/f64(n.viewport.dst_height))
	}
	if n.viewport.has_src { rg.translate(dst,i32(math.floor(n.viewport.src.x)),i32(math.floor(n.viewport.src.y))) }
	rg.scale(dst,f64(n.scale))
	w,h := transformed_size(n); rg.transform(dst,gles.transform_invert(n.transform),w,h)
	rg.union_regions(dst,&n.buffer_damage)
}
move_state :: proc(dst, src: ^State) {
	dst.width,dst.height,dst.buffer_width,dst.buffer_height = src.width,src.height,src.buffer_width,src.buffer_height
	if .Scale in src.committed { dst.scale = src.scale }
	if .Transform in src.committed { dst.transform = src.transform }
	dst.dx,dst.dy = 0,0
	if .Offset in src.committed { dst.dx,dst.dy = src.dx,src.dy; src.dx,src.dy = 0,0 }
	if .Buffer in src.committed { buffer_unlock(dst.buffer); dst.buffer,src.buffer = src.buffer,nil }
	rg.copy(&dst.surface_damage,&src.surface_damage); rg.clear(&src.surface_damage)
	rg.copy(&dst.buffer_damage,&src.buffer_damage); rg.clear(&src.buffer_damage)
	if .Opaque in src.committed { rg.copy(&dst.opaque,&src.opaque) }
	if .Input in src.committed { rg.copy(&dst.input,&src.input); dst.input_infinite = src.input_infinite }
	if .Viewport in src.committed { dst.viewport = src.viewport }
	for r in src.frame_callbacks { r.data = dst; append(&dst.frame_callbacks,r) }; clear(&src.frame_callbacks)
	clear(&dst.below); append(&dst.below,..src.below[:])
	clear(&dst.above); append(&dst.above,..src.above[:])
	dst.committed,src.committed = src.committed,{}
	dst.seq,dst.locks,src.locks = src.seq,src.locks,0
}
apply :: proc(s: ^Surface, n: ^State) {
	assert(n.locks == 0)
	s.unmap_commit = .Buffer in n.committed && n.buffer == nil && s.mapped
	if .Buffer in n.committed && n.buffer == nil { unmap(s) }
	update_damage(&s.buffer_damage,n)
	c := &s.current
	s.previous = {c.scale,c.transform,c.width,c.height,c.buffer_width,c.buffer_height}
	move_state(c,n)
	if .Buffer in c.committed { s.opaque = buffer_opaque(c.buffer) }
	bounds := rg.Box{0,0,c.width,c.height}
	rg.clear(&s.opaque_region)
	if has_buffer(s) {
		if s.opaque { rg.union_rect(&s.opaque_region,bounds) } else { rg.copy(&s.opaque_region,&c.opaque); rg.intersect_rect(&s.opaque_region,bounds) }
	}
	rg.clear(&s.input_region)
	if c.input_infinite { rg.union_rect(&s.input_region,bounds) } else { rg.copy(&s.input_region,&c.input); rg.intersect_rect(&s.input_region,bounds) }
	for list in ([2][]Child{c.below[:],c.above[:]}) { for child in list { child.sub.current = {child.x,child.y}; parent_commit(child.sub) } }
	if n == &s.pending { s.pending.seq += 1 }
	if role_active(s) && s.role.commit != nil { s.role.commit(s) }
	wl.signal_emit_mutable(&s.events.commit,s)
	buffer_unlock(c.buffer); c.buffer = nil
}
commit :: proc(s: ^Surface) {
	s.handling_commit = true; finalize(s)
	if role_active(s) && s.role.client_commit != nil { s.role.client_commit(s) }
	wl.signal_emit_mutable(&s.events.client_commit,s)
	s.handling_commit = false
	if s.pending_rejected || s.resource.client.failed { return }
	for list in ([2][]Child{s.pending.below[:],s.pending.above[:]}) { for &c in list { c.x,c.y = c.sub.pending.x,c.sub.pending.y } }
	if s.pending.locks>0 || len(s.cached)>0 {
		state := new(State); state_init(state); move_state(state,&s.pending)
		// Cached commits need the full effective geometry even when only damage changed.
		state.scale,state.transform,state.viewport = s.pending.scale,s.pending.transform,s.pending.viewport
		append(&s.cached,state); s.pending.seq += 1
	} else { apply(s,&s.pending) }
}
lock_pending :: proc(s: ^Surface) -> u32 { s.pending.locks += 1; return s.pending.seq }
unlock_cached :: proc(s: ^Surface, seq: u32) {
	if seq == s.pending.seq { assert(s.pending.locks>0); s.pending.locks -= 1; return }
	found := false
	for n in s.cached { if n.seq == seq { assert(n.locks>0); n.locks -= 1; found = true; break } }; assert(found)
	for len(s.cached)>0 && s.cached[0].locks == 0 {
		n := s.cached[0]; ordered_remove(&s.cached,0); apply(s,n); state_finish(n); free(n)
	}
}
