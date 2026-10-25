package region

import "core:testing"
import "core:math"

Bitmap :: [64][64]bool
paint :: proc(bits: ^Bitmap, b: Box, value: bool) {
	for y in max(0,b.y)..<min(64,b.y+b.height) { for x in max(0,b.x)..<min(64,b.x+b.width) { bits[y][x] = value } }
}
check_bitmap :: proc(t: ^testing.T, r: ^Region, want: Bitmap) {
	counts: [64][64]int
	for b in rectangles(r) {
		testing.expect(t,b.width>0 && b.height>0)
		for y in max(0,b.y)..<min(64,b.y+b.height) { for x in max(0,b.x)..<min(64,b.x+b.width) { counts[y][x] += 1 } }
	}
	any_ := false
	for y in 0..<64 { for x in 0..<64 {
		if !testing.expect(t,counts[y][x]<=1 && (counts[y][x]>0)==want[y][x] && contains_point(r,i32(x),i32(y))==want[y][x]) { return }
		any_ = any_ || want[y][x]
	} }
	testing.expect_value(t,empty(r),!any_)
	if any_ {
		b := extents(r)
		for y in 0..<64 { for x in 0..<64 { if want[y][x] { testing.expect(t,x>=int(b.x) && x<int(b.x+b.width) && y>=int(b.y) && y<int(b.y+b.height)) } } }
	}
}
random_box :: proc(seed: ^u32) -> Box {
	v: [4]i32
	for &n in v { seed^ = seed^*1664525+1013904223; n = i32((seed^>>16)%32) }
	return {v[0],v[1],v[2],v[3]}
}
@(test)
region_operations_match_bitmap :: proc(t: ^testing.T) {
	seed := u32(75931)
	for _ in 0..<80 {
		a,b,c: Region; defer finish(&a); defer finish(&b); defer finish(&c)
		aa,bb: Bitmap
		for i in 0..<20 {
			r := random_box(&seed)
			if i%3==0 { subtract_rect(&a,r); paint(&aa,r,false) } else { union_rect(&a,r); paint(&aa,r,true) }
			q := random_box(&seed); union_rect(&b,q); paint(&bb,q,true)
		}
		check_bitmap(t,&a,aa); check_bitmap(t,&b,bb)
		copy(&c,&a); union_regions(&c,&b); want: Bitmap
		for y in 0..<64 { for x in 0..<64 { want[y][x] = aa[y][x] || bb[y][x] } }; check_bitmap(t,&c,want)
		copy(&c,&a); subtract(&c,&b)
		for y in 0..<64 { for x in 0..<64 { want[y][x] = aa[y][x] && !bb[y][x] } }; check_bitmap(t,&c,want)
		copy(&c,&a); intersect(&c,&b)
		for y in 0..<64 { for x in 0..<64 { want[y][x] = aa[y][x] && bb[y][x] } }; check_bitmap(t,&c,want)
		box := random_box(&seed); copy(&c,&a); intersect_rect(&c,box)
		for y in 0..<64 { for x in 0..<64 { want[y][x] = aa[y][x] && x>=int(box.x) && x<int(box.x+box.width) && y>=int(box.y) && y<int(box.y+box.height) } }; check_bitmap(t,&c,want)
		copy(&c,&a); translate(&c,3,-2); want = {}
		for y in 0..<64 { for x in 0..<64 { if aa[y][x] { paint(&want,{i32(x)+3,i32(y)-2,1,1},true) } } }; check_bitmap(t,&c,want)
		copy(&c,&a); scale(&c,0.75,0.5); want = {}
		for y in 0..<64 { for x in 0..<64 { if aa[y][x] {
			x1,y1 := i32(math.floor(f64(x)*0.75)),i32(math.floor(f64(y)*0.5))
			paint(&want,{x1,y1,i32(math.ceil(f64(x+1)*0.75))-x1,i32(math.ceil(f64(y+1)*0.5))-y1},true)
		} } }; check_bitmap(t,&c,want)
		for tr in i32(0)..<8 {
			copy(&c,&a); transform(&c,tr,64,64); want = {}
			for y in 0..<64 { for x in 0..<64 { if aa[y][x] {
				nx,ny := x,y
				for _ in 0..<(tr&3) { nx,ny=63-ny,nx }
				if tr&4 != 0 { nx=63-nx }
				want[ny][nx] = true
			} } }; check_bitmap(t,&c,want)
		}
		clear(&c); check_bitmap(t,&c,Bitmap{})
	}
}
@(test)
region_edges_do_not_wrap :: proc(t: ^testing.T) {
	r: Region; defer finish(&r)
	union_rect(&r,{max(i32)-4,max(i32)-4,20,20})
	testing.expect_value(t,extents(&r),Box{max(i32)-4,max(i32)-4,4,4})
	union_rect(&r,{0,0,-1,5}); testing.expect_value(t,len(rectangles(&r)),1)
}
