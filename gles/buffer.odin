package gles

import "../gbm"
import wl "../wayland"
import "core:sys/posix"
import gl "vendor:OpenGL"
import egl "vendor:egl"

Buffer :: struct {
	renderer:      ^Renderer,
	bo:            ^gbm.Buffer,
	image:         egl.Image,
	fbo, rbo:      u32,
	planes:        [4]Plane,
	n_planes:      i32,
	width, height: i32,
	format:        u32,
	modifier:      u64,
	locks:         int,
	dropped:       bool,
	events:        struct { retire, destroy: wl.Signal },
}

Swapchain :: struct {
	buffers:       [dynamic]^Buffer,
	width, height: i32,
	format:        u32,
	modifiers:     []u64,
}

buffer_create :: proc(r: ^Renderer, width, height: i32, format: u32, mods: []u64) -> ^Buffer {
	if !current(r) {return nil}
	bo := gbm.allocate(r.device, width, height, format, mods)
	if bo == nil {return nil}
	if gbm.planes(bo) < 1 || gbm.planes(bo) > 4 {
		gbm.release(bo)
		return nil
	}
	b := new(Buffer)
	b^ = {
		renderer  = r,
		bo        = bo,
		n_planes  = gbm.planes(bo),
		width     = width,
		height    = height,
		format    = format,
		modifier  = gbm.modifier(bo),
	}
	wl.signal_init(&b.events.retire); wl.signal_init(&b.events.destroy)
	for &p in b.planes {p.fd = -1}
	if len(mods) == 1 && mods[0] == gbm.INVALID {b.modifier = gbm.INVALID}
	ok := false
	defer {
		if !ok {buffer_destroy(b)}
	}
	for i: i32 = 0; i < b.n_planes; i += 1 {
		b.planes[i] = {gbm.fd(bo, i), gbm.stride(bo, i), gbm.offset(bo, i)}
		if b.planes[i].fd < 0 {return nil}
	}
	b.image = image(r, width, height, format, b.modifier, b.planes[:b.n_planes])
	if b.image == egl.NO_IMAGE {return nil}
	gl.GenRenderbuffers(1, &b.rbo)
	gl.BindRenderbuffer(gl.RENDERBUFFER, b.rbo)
	r.image_renderbuffer(gl.RENDERBUFFER, b.image)
	gl.GenFramebuffers(1, &b.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, b.fbo)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, b.rbo)
	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {return nil}
	ok = true
	return b
}

buffer_destroy :: proc(b: ^Buffer) {
	if b == nil {return}
	assert(b.locks == 0)
	context.allocator = b.renderer.allocator
	wl.signal_emit_final(&b.events.destroy,b)
	if current(b.renderer) {
		gl.DeleteFramebuffers(1, &b.fbo)
		gl.DeleteRenderbuffers(1, &b.rbo)
	}
	if b.image != egl.NO_IMAGE {egl.DestroyImage(b.renderer.display, b.image)}
	gbm.release(b.bo)
	for p in b.planes {
		if p.fd >= 0 {posix.close(posix.FD(p.fd))}
	}
	free(b)
}

swapchain_finish :: proc(s: ^Swapchain) {
	for b in s.buffers {
		buffer_drop(b)
	}
	delete(s.buffers)
	delete(s.modifiers)
	s^ = {}
}

acquire :: proc(
	s: ^Swapchain,
	r: ^Renderer,
	width, height: i32,
	format: u32,
	mods: []u64,
) -> ^Buffer {
	if r.lost {return nil}
	same :=
		s.width == width &&
		s.height == height &&
		s.format == format &&
		len(s.modifiers) == len(mods)
	if same {
		for m, i in mods {
			if s.modifiers[i] != m {
				same = false
				break
			}
		}
	}
	if !same {
		swapchain_finish(s)
		s.width, s.height, s.format = width, height, format
		s.modifiers = make([]u64, len(mods))
		copy(s.modifiers, mods)
	}
	for b in s.buffers {
		if b.locks == 0 {
			return buffer_retain(b)
		}
	}
	if len(s.buffers) >= 3 {return nil}
	b := buffer_create(r, width, height, format, mods)
	if b != nil {
		append(&s.buffers, b)
		buffer_retain(b)
	}
	return b
}

read :: proc(r: ^Renderer, b: ^Buffer, dest: rawptr, stride: u32) -> bool {
	if b == nil {return false}
	return read_region(r, b, dest, stride, {0, 0, b.width, b.height})
}

read_region :: proc(r: ^Renderer, b: ^Buffer, dest: rawptr, stride: u32, box: Box) -> bool {
	if b == nil || box.x < 0 || box.y < 0 || box.width <= 0 || box.height <= 0 ||
	   i64(box.x)+i64(box.width) > i64(b.width) || i64(box.y)+i64(box.height) > i64(b.height) ||
	   stride < u32(box.width)*4 || !current(r) {return false}
	// GL packs rows without the destination stride.
	pixels := make([]u8, int(box.width) * int(box.height) * 4)
	defer delete(pixels)
	gl.BindFramebuffer(gl.FRAMEBUFFER, b.fbo)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	format := u32(gl.RGBA)
	if r.bgra {format = GL_BGRA_EXT}
	gl.ReadPixels(box.x, box.y, box.width, box.height, format, gl.UNSIGNED_BYTE, raw_data(pixels))
	if gl.GetError() != gl.NO_ERROR {return false}
	// The pass projects directly into GBM row order, including readback.
	for y in 0 ..< int(box.height) {
		src := pixels[y * int(box.width) * 4:][:int(box.width) * 4]
		dst := (cast([^]u8)dest)[y * int(stride):][:len(src)]
		copy(dst, src)
		if !r.bgra {
			for x in 0 ..< int(box.width) {dst[x * 4], dst[x * 4 + 2] = dst[x * 4 + 2], dst[x * 4]}
		}
		if b.format == gbm.XRGB8888 {
			for x in 0 ..< int(box.width) {dst[x * 4 + 3] = 255}
		}
	}
	return true
}

buffer_retain :: proc(b: ^Buffer) -> ^Buffer { if b != nil { b.locks += 1 }; return b }
buffer_release :: proc(b: ^Buffer) {
	if b == nil { return }; assert(b.locks > 0); b.locks -= 1
	if b.locks == 0 && b.dropped { buffer_destroy(b) }
}
buffer_drop :: proc(b: ^Buffer) {
	assert(!b.dropped)
	wl.signal_emit_final(&b.events.retire,b)
	b.dropped = true; if b.locks == 0 { buffer_destroy(b) }
}
