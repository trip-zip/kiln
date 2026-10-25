package surfaces

import rg "../region"
import "../gles"
import "core:math"

Iterator :: #type proc(^Surface,i32,i32,rawptr)
has_buffer :: proc(s: ^Surface) -> bool { return s.current.buffer_width>0 && s.current.buffer_height>0 }
root :: proc(s: ^Surface) -> ^Surface { s := s; for s.subsurface != nil { s = s.subsurface.parent }; return s }
each :: proc(s: ^Surface, iterator: Iterator, data: rawptr, x: i32 = 0, y: i32 = 0) {
	for list,i in ([2][]Child{s.current.below[:],s.current.above[:]}) {
		if i==1 { iterator(s,x,y,data) }
		for c in list { if c.sub.surface.mapped { each(c.sub.surface,iterator,data,x+c.x,y+c.y) } }
	}
}
// Unmapped children must remain observed so their first desynchronized map wakes the output.
known :: proc(s: ^Surface, iterator: Iterator, data: rawptr) {
	iterator(s,0,0,data)
	for list in ([2][]Child{s.current.below[:],s.current.above[:]}) { for c in list { known(c.sub.surface,iterator,data) } }
}
at :: proc(s: ^Surface, x,y: f64, sx,sy: ^f64) -> ^Surface {
	for list,band in ([2][]Child{s.current.above[:],s.current.below[:]}) {
		if band==1 && x>=0 && y>=0 && x<f64(s.current.width) && y<f64(s.current.height) && rg.contains_point(&s.input_region,i32(math.floor(x)),i32(math.floor(y))) {
			if sx!=nil { sx^ = x }; if sy!=nil { sy^ = y }; return s
		}
		for i:=len(list)-1; i>=0; i-=1 {
			c := list[i]; if !c.sub.surface.mapped { continue }
			if hit := at(c.sub.surface,x-f64(c.x),y-f64(c.y),sx,sy); hit!=nil { return hit }
		}
	}
	return nil
}
extents :: proc(s: ^Surface, x: i32 = 0, y: i32 = 0) -> rg.Box {
	b := rg.Box{x,y,s.current.width,s.current.height}
	for list in ([2][]Child{s.current.below[:],s.current.above[:]}) { for c in list {
		if !c.sub.surface.mapped { continue }
		a := extents(c.sub.surface,x+c.x,y+c.y)
		x1,y1 := min(b.x,a.x),min(b.y,a.y)
		b = {x1,y1,max(b.x+b.width,a.x+a.width)-x1,max(b.y+b.height,a.y+a.height)-y1}
	} }
	return b
}
source_box :: proc(s: ^Surface) -> Fbox {
	c := &s.current
	if !c.viewport.has_src { return {0,0,f64(c.buffer_width),f64(c.buffer_height)} }
	b := c.viewport.src; scale := f64(c.scale)
	b = {b.x*scale,b.y*scale,b.width*scale,b.height*scale}
	w,h := transformed_size(c); return rg.transform_box(b,gles.transform_invert(c.transform),f64(w),f64(h))
}
damage :: proc(s: ^Surface) -> []rg.Box { return rg.rectangles(&s.buffer_damage) }
