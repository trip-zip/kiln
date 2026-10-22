package scene_paint

import "core:math"
import "core:fmt"
import "core:strings"
import paint "../paint"
import layout "../layout"
import wlr "../wlroots"

Node :: struct {
	root: ^wlr.wlr_scene_node,
	rect: ^wlr.wlr_scene_rect,
	command: layout.Command,
	buffers: [dynamic]^Buffer,
	bytes: u64,
	parts: [dynamic]Part,
	scale: f32,
}
key :: proc(command: layout.Command) -> u64 {
	kind: u64
	switch _ in command.content { case layout.Rectangle: kind=1; case layout.Border: kind=2; case layout.Text: kind=3; case layout.Client: kind=4; case layout.Image: kind=5 }
	return u64(command.id)<<8 | kind
}
owned_copy :: proc(command: layout.Command) -> layout.Command {
	copy := command
	if t, ok := copy.content.(layout.Text); ok { t.value = strings.clone(t.value); copy.content = t }
	return copy
}
free_command :: proc(command: layout.Command) { if t, ok := command.content.(layout.Text); ok { delete(t.value) } }
equal_content :: proc(a,b: layout.Command) -> bool {
	return a.box.width == b.box.width && a.box.height == b.box.height && a.content == b.content
}
square :: proc(c: layout.Command) -> bool { r, ok := c.content.(layout.Rectangle); return ok && !layout.inspector_highlight(c.id) && r.radii == paint.Radii{} }
premultiply :: proc(c: paint.Color) -> paint.Color { return {c[0]*c[3],c[1]*c[3],c[2]*c[3],c[3]} }
add_rect :: proc(n: ^Node, parent: ^wlr.wlr_scene_tree, x,y,w,h: i32, color: paint.Color) -> bool {
	if w<=0 || h<=0 { return true }
	c := premultiply(color)
	r := wlr.wlr_scene_rect_create(parent,w,h,raw_data(c[:]))
	if r == nil { return false }
	wlr.wlr_scene_node_set_position(&r.node,x,y)
	append(&n.parts,Part{node=&r.node,rect=r,box={f32(x),f32(y),f32(w),f32(h)}})
	return true
}
add_buffer :: proc(n: ^Node, parent: ^wlr.wlr_scene_tree, s: paint.Surface, x,y,w,h: i32) -> bool {
	b := wrap(s)
    b.passthrough=layout.inspector_highlight(n.command.id)
	fmt.printf("Raster %d: scale %.3f origin %.0f,%.0f logical %dx%d device %dx%d\n",n.command.id,n.scale,n.command.box.x+f32(x),n.command.box.y+f32(y),w,h,s.width,s.height)
	append(&n.buffers,b)
	n.bytes += u64(s.stride)*u64(s.height)
	b.source_scale_x,b.source_scale_y=f64(s.width)/f64(w),f64(s.height)/f64(h)
	sb := wlr.wlr_scene_buffer_create(parent,&b.base)
	if sb == nil { return false }
	wlr.wlr_scene_buffer_set_dest_size(sb,w,h)
	sb.node.data = b
	sb.point_accepts_input = accepts_input
	wlr.wlr_scene_node_set_position(&sb.node,x,y)
	append(&n.parts,Part{node=&sb.node,buffer=sb,pixels=b,box={f32(x),f32(y),f32(w),f32(h)}})
	return true
}
destroy :: proc(n: ^Node) {
	if n == nil { return }
	if n.root != nil { wlr.wlr_scene_node_destroy(n.root) }
	for b in n.buffers { wlr.wlr_buffer_unlock(&b.base) }
	delete(n.buffers)
	delete(n.parts)
	free_command(n.command)
	free(n)
}
// Fallible scene allocation stays under a disabled staging tree until publication.
create :: proc(parent: ^wlr.wlr_scene_tree, command: layout.Command, fonts: ^paint.Fonts, scale: f32 = 1) -> (^Node, bool) {
	n := new(Node)
	n.command = owned_copy(command)
	n.scale=scale
	ok := false
	defer { if !ok { destroy(n) } }
	w,h := max(0,i32(command.box.width)),max(0,i32(command.box.height))
	dw,dh:=device_span(i32(command.box.x),w,scale),device_span(i32(command.box.y),h,scale)
	tree := wlr.wlr_scene_tree_create(parent)
	if tree == nil { return nil,false }
	n.root = &tree.node
	if square(command) {
		c := premultiply(command.content.(layout.Rectangle).color)
		n.rect = wlr.wlr_scene_rect_create(tree,w,h,raw_data(c[:]))
		if n.rect == nil { return nil,false }
		append(&n.parts,Part{node=&n.rect.node,rect=n.rect,box={0,0,f32(w),f32(h)}})
	} else {
		if w>0 && h>0 {
			switch v in command.content {
			case layout.Rectangle:
				s, valid := paint.create(dw,dh)
				if !valid { return nil,false }
				if !paint.shape(s,v.color,scale_radii(v.radii,scale),dw,dh) { paint.destroy(s); return nil,false }
				if !add_buffer(n,tree,s,0,0,w,h) { return nil,false }
			case layout.Image:
				if v.usable {
					if v.entry.generation!=v.generation || v.entry.surface.handle==nil { return nil,false }
					s,valid := paint.create(dw,dh)
					if !valid { return nil,false }
					if !paint.image(s,v.entry.surface,v.color,scale_radii(v.radii,scale)) { paint.destroy(s); return nil,false }
					if !add_buffer(n,tree,s,0,0,w,h) { return nil,false }
				}
			case layout.Text:
				s, valid := paint.create(dw,dh)
				if !valid { return nil,false }
				if !paint.text(s,fonts,v.value,v.font,v.size,v.color,device_span(i32(command.box.x),v.ellipsis,scale),scale) { paint.destroy(s); return nil,false }
				if !add_buffer(n,tree,s,0,0,w,h) { return nil,false }
			case layout.Border:
				if !border(n,tree,v,w,h) { return nil,false }
			case layout.Client: return nil,false
			}
		}
	}
	ok = true
	return n,true
}

border :: proc(n: ^Node, tree: ^wlr.wlr_scene_tree, v: layout.Border, w,h: i32) -> bool {
	r := paint.clamp_radii(v.radii,f32(w),f32(h))
	bw := v.widths
	left, right := min(w,i32(bw.left)),min(w,i32(bw.right))
	top, bottom := min(h,i32(bw.top)),min(h,i32(bw.bottom))
	bottom = min(bottom,h-top)
	right = min(right,w-left)
	if r == (paint.Radii{}) {
		bottom = min(bottom,h-top)
		right = min(right,w-left)
		return add_rect(n,tree,0,0,w,top,v.color) && add_rect(n,tree,0,h-bottom,w,bottom,v.color) &&
			add_rect(n,tree,0,top,left,h-top-bottom,v.color) && add_rect(n,tree,w-right,top,right,h-top-bottom,v.color)
	}
	// Nonoverlapping tiles partition the ring, including radii larger than edge spans.
	lx := min(w,max(left,i32(math.ceil(max(r.tl,r.bl)))))
	rx := min(w-lx,max(right,i32(math.ceil(max(r.tr,r.br)))))
	ty := min(h,max(top,i32(math.ceil(max(r.tl,r.tr)))))
	by := min(h-ty,max(bottom,i32(math.ceil(max(r.bl,r.br)))))
	if !add_rect(n,tree,lx,0,w-lx-rx,top,v.color) || !add_rect(n,tree,lx,h-bottom,w-lx-rx,bottom,v.color) ||
		!add_rect(n,tree,0,ty,left,h-ty-by,v.color) || !add_rect(n,tree,w-right,ty,right,h-ty-by,v.color) { return false }
	tiles := [?][4]i32{{0,0,lx,ty},{w-rx,0,rx,ty},{0,h-by,lx,by},{w-rx,h-by,rx,by}}
	for tile in tiles {
		x,y,tw,th := tile[0],tile[1],tile[2],tile[3]
		if tw<=0 || th<=0 { continue }
		ox,oy:=i32(n.command.box.x),i32(n.command.box.y)
		dx,dy:=device_span(ox,x,n.scale),device_span(oy,y,n.scale)
		dw,dh:=device_span(ox,w,n.scale),device_span(oy,h,n.scale)
		s, valid := paint.create(device_span(ox+x,tw,n.scale),device_span(oy+y,th,n.scale))
		if !valid { return false }
		if !paint.shape(s,v.color,scale_radii(r,n.scale),dw,dh,dx,dy,true,scale_widths(bw,n.scale)) { paint.destroy(s); return false }
		if !add_buffer(n,tree,s,x,y,tw,th) { return false }
	}
	return true
}

// Match scene scaling: a span is the difference of its rounded device edges.
device_edge :: proc(origin: i32, scale: f32) -> i32 { return i32(math.round(f32(origin)*scale)) }
device_span :: proc(origin, length: i32, scale: f32) -> i32 { return device_edge(origin+length,scale)-device_edge(origin,scale) }
phase :: proc(origin: f32, scale: f32) -> f64 { return f64(device_edge(i32(origin),scale))-f64(i32(origin))*f64(scale) }
reusable :: proc(n: ^Node, c: layout.Command, scale: f32) -> bool {
    return equal_content(n.command,c) && n.scale==scale &&
        phase(n.command.box.x,scale)==phase(c.box.x,scale) && phase(n.command.box.y,scale)==phase(c.box.y,scale)
}
scale_radii :: proc(r: paint.Radii, scale: f32) -> paint.Radii { return {r.tl*scale,r.tr*scale,r.bl*scale,r.br*scale} }
scale_widths :: proc(w: paint.Widths, scale: f32) -> paint.Widths { return {w.left*scale,w.right*scale,w.top*scale,w.bottom*scale} }
