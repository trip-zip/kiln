package region

import "core:math"

Box :: struct { x, y, width, height: i32 }
Region :: struct { boxes: [dynamic]Box }
clear :: proc(r: ^Region) { resize(&r.boxes,0) }
finish :: proc(r: ^Region) { delete(r.boxes); r^ = {} }
copy :: proc(dst, src: ^Region) {
	if dst == src { return }
	clear(dst); append(&dst.boxes, ..src.boxes[:])
}
rectangles :: proc(r: ^Region) -> []Box { return r.boxes[:] }
empty :: proc(r: ^Region) -> bool { return len(r.boxes) == 0 }
right :: proc(b: Box) -> i64 { return i64(b.x)+i64(b.width) }
bottom :: proc(b: Box) -> i64 { return i64(b.y)+i64(b.height) }
clipped :: proc(b: Box) -> Box {
	if b.width <= 0 || b.height <= 0 { return {} }
	return {b.x, b.y, i32(min(right(b), i64(max(i32)))-i64(b.x)), i32(min(bottom(b), i64(max(i32)))-i64(b.y))}
}
intersection :: proc(a, b: Box) -> Box {
	x, y := max(a.x,b.x), max(a.y,b.y)
	return {x,y,i32(max(0,min(right(a),right(b))-i64(x))),i32(max(0,min(bottom(a),bottom(b))-i64(y)))}
}
put :: proc(r: ^Region, b: Box) { if b.width > 0 && b.height > 0 { append(&r.boxes,b) } }
split :: proc(dst: ^Region, a,b: Box) {
	i := intersection(a,b)
	if i.width == 0 || i.height == 0 { put(dst,a); return }
	put(dst,{a.x,a.y,a.width,i.y-a.y})
	put(dst,{a.x,i32(bottom(i)),a.width,i32(bottom(a)-bottom(i))})
	put(dst,{a.x,i.y,i.x-a.x,i.height})
	put(dst,{i32(right(i)),i.y,i32(right(a)-right(i)),i.height})
}
subtract_rect :: proc(r: ^Region, box: Box) {
	b := clipped(box)
	if b.width == 0 || b.height == 0 { return }
	next: Region
	for a in r.boxes { split(&next,a,b) }
	finish(r); r^ = next
}
union_rect :: proc(r: ^Region, box: Box) {
	b := clipped(box)
	if b.width == 0 || b.height == 0 { return }
	pieces: Region; put(&pieces,b)
	for a in r.boxes { subtract_rect(&pieces,a) }
	append(&r.boxes,..pieces.boxes[:]); finish(&pieces)
}
union_regions :: proc(r, other: ^Region) {
	if r == other { return }
	for b in other.boxes { union_rect(r,b) }
}
subtract :: proc(r, other: ^Region) {
	if r == other { clear(r); return }
	for b in other.boxes { subtract_rect(r,b) }
}
intersect_rect :: proc(r: ^Region, box: Box) {
	next: Region
	for b in r.boxes { put(&next,intersection(b,box)) }
	finish(r); r^ = next
}
intersect :: proc(r, other: ^Region) {
	if r == other { return }
	next: Region
	for a in r.boxes { for b in other.boxes { put(&next,intersection(a,b)) } }
	finish(r); r^ = next
}
translate :: proc(r: ^Region, x,y: i32) {
	next: Region
	for b in r.boxes {
		x1,y1 := clamp(i64(b.x)+i64(x),i64(min(i32)),i64(max(i32))),clamp(i64(b.y)+i64(y),i64(min(i32)),i64(max(i32)))
		x2,y2 := clamp(right(b)+i64(x),i64(min(i32)),i64(max(i32))),clamp(bottom(b)+i64(y),i64(min(i32)),i64(max(i32)))
		put(&next,{i32(x1),i32(y1),i32(x2-x1),i32(y2-y1)})
	}
	finish(r); r^ = next
}
scale_xy :: proc(r: ^Region, x,y: f64) {
	next: Region
	for b in r.boxes {
		x1,y1 := clamp(math.floor(f64(b.x)*x),f64(min(i32)),f64(max(i32))),clamp(math.floor(f64(b.y)*y),f64(min(i32)),f64(max(i32)))
		x2,y2 := clamp(math.ceil(f64(right(b))*x),f64(min(i32)),f64(max(i32))),clamp(math.ceil(f64(bottom(b))*y),f64(min(i32)),f64(max(i32)))
		union_rect(&next,{i32(x1),i32(y1),i32(min(x2-x1,f64(max(i32)))),i32(min(y2-y1,f64(max(i32))))})
	}
	finish(r); r^ = next
}
transform_box :: proc(b: $B, t: i32, width,height: $N) -> B {
	x,y,w,h := b.x,b.y,b.width,b.height
	switch t {
	case 0: return b
	case 1: return {height-y-h,x,h,w}
	case 2: return {width-x-w,height-y-h,w,h}
	case 3: return {y,width-x-w,h,w}
	case 4: return {width-x-w,y,w,h}
	case 5: return {y,x,h,w}
	case 6: return {x,height-y-h,w,h}
	case 7: return {height-y-h,width-x-w,h,w}
	}
	return b
}
transform :: proc(r: ^Region, t,width,height: i32) {
	for &b in r.boxes { b = transform_box(b,t,width,height) }
}
contains_point :: proc(r: ^Region, x,y: i32) -> bool {
	for b in r.boxes { if x>=b.x && i64(x)<right(b) && y>=b.y && i64(y)<bottom(b) { return true } }
	return false
}
extents :: proc(r: ^Region) -> Box {
	if empty(r) { return {} }
	b := r.boxes[0]
	for a in r.boxes[1:] {
		x,y := min(a.x,b.x),min(a.y,b.y)
		b = {x,y,i32(min(max(right(a),right(b))-i64(x),i64(max(i32)))),i32(min(max(bottom(a),bottom(b))-i64(y),i64(max(i32))))}
	}
	return b
}

scale_uniform :: proc(r: ^Region, s: f64) { scale_xy(r,s,s) }
scale :: proc{scale_xy,scale_uniform}
