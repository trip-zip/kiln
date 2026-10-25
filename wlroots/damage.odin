package wlroots

// Damage remains borrowed protocol state while wlroots owns surfaces.
pixman_region32_t :: struct #align(8) { _opaque: [24]u8 }
#assert(size_of(pixman_region32_t)==24 && align_of(pixman_region32_t)==8)
foreign import pixman_lib "system:pixman-1"
pixman_box32_t :: struct {
	x1, y1, x2, y2: i32,
}
#assert(size_of(pixman_box32_t) == 16 && align_of(pixman_box32_t) == 4)
foreign pixman_lib {pixman_region32_rectangles :: proc(region: ^pixman_region32_t, count: ^i32) -> [^]pixman_box32_t ---
}

surface_damage :: proc(surface: ^Surface) -> []Box {
	n: i32
	rects := pixman_region32_rectangles(&surface.buffer_damage, &n)
	boxes := make([]Box, int(n), context.temp_allocator)
	for r, i in rects[:n] {boxes[i] = {r.x1, r.y1, r.x2 - r.x1, r.y2 - r.y1}}
	return boxes
}
