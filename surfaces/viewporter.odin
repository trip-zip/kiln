package surfaces

import wl "../wayland"
import p "../protocols"
import "core:math"

Viewport :: struct { resource: ^wl.Resource, surface: ^Surface, commit: wl.Listener }
viewporter_create :: proc(d: ^wl.Display) -> ^Global { return create_global(d,&p.wp_viewporter,viewporter_request) }
viewporter_request :: proc(r: ^wl.Resource, op: p.Wp_Viewporter_Request, args: []wl.Argument) {
	if op == .destroy { wl.resource_destroy(r); return }
	s := of(wl.object(args[1]))
	if s.viewport != nil { wl.post_error(r,u32(p.Wp_Viewporter_Error.viewport_exists),"surface already has a viewport"); return }
	v := new(Viewport); v.surface = s
	v.resource = wl.resource_create_typed(r.client,&p.wp_viewport,1,u32(args[0].(wl.New_Id)),v,viewport_request,viewport_destroy)
	if v.resource == nil { free(v); return }
	s.viewport = v; wl.listen(&s.events.client_commit,&v.commit,viewport_validate)
}
viewport_detach :: proc(v: ^Viewport) {
	wl.unlisten(&v.commit)
	if v.surface != nil { v.surface.viewport = nil; v.surface.pending.viewport = {}; v.surface.pending.committed += {.Viewport}; v.surface = nil }
}
viewport_destroy :: proc(r: ^wl.Resource) { v := cast(^Viewport)r.data; viewport_detach(v); free(v) }
viewport_request :: proc(r: ^wl.Resource, op: p.Wp_Viewport_Request, args: []wl.Argument) {
	if op == .destroy { wl.resource_destroy(r); return }
	v := cast(^Viewport)r.data
	if v.surface == nil { wl.post_error(r,u32(p.Wp_Viewport_Error.no_surface),"viewport surface is gone"); return }
	n := &v.surface.pending
	if op == .set_source {
		b := Fbox{f64(args[0].(wl.Fixed))/256,f64(args[1].(wl.Fixed))/256,f64(args[2].(wl.Fixed))/256,f64(args[3].(wl.Fixed))/256}
		unset := b == Fbox{-1,-1,-1,-1}
		if !unset && (b.x<0 || b.y<0 || b.width<=0 || b.height<=0) { wl.post_error(r,u32(p.Wp_Viewport_Error.bad_value),"invalid viewport source"); return }
		n.viewport.src,n.viewport.has_src = b,!unset
	} else {
		w,h := i32(args[0].(wl.Int)),i32(args[1].(wl.Int))
		unset := w == -1 && h == -1
		if !unset && (w<=0 || h<=0) { wl.post_error(r,u32(p.Wp_Viewport_Error.bad_value),"invalid viewport destination"); return }
		n.viewport.dst_width,n.viewport.dst_height,n.viewport.has_dst = w,h,!unset
	}
	n.committed += {.Viewport}
}
viewport_validate :: proc(l: ^wl.Listener, data: rawptr) {
	v := wl.owner(l,Viewport,"commit"); n := &v.surface.pending; b := n.viewport.src
	if !n.viewport.has_dst && (math.floor(b.width)!=b.width || math.floor(b.height)!=b.height) {
		reject(v.surface,v.resource,u32(p.Wp_Viewport_Error.bad_size),"source size must be integral without a destination"); return
	}
	w,h := transformed_size(n)
	if n.viewport.has_src && n.buffer_width>0 && n.buffer_height>0 && (b.x+b.width>f64(w/n.scale) || b.y+b.height>f64(h/n.scale)) {
		reject(v.surface,v.resource,u32(p.Wp_Viewport_Error.out_of_buffer),"source rectangle outside buffer")
	}
}
