package gles

import "../gbm"
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
	owner:         rawptr,
	available:     bool,
	release:       proc(b: ^Buffer),
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
		available = true,
	}
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
	context.allocator = b.renderer.allocator
	current(b.renderer)
	gl.DeleteFramebuffers(1, &b.fbo)
	gl.DeleteRenderbuffers(1, &b.rbo)
	if b.image != egl.NO_IMAGE {egl.DestroyImage(b.renderer.display, b.image)}
	gbm.release(b.bo)
	for p in b.planes {
		if p.fd >= 0 {posix.close(posix.FD(p.fd))}
	}
	free(b)
}

swapchain_finish :: proc(s: ^Swapchain) {
	for b in s.buffers {
		if b.release != nil {b.release(b)} else {buffer_destroy(b)}
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
		if b.available {
			b.available = false
			return b
		}
	}
	if len(s.buffers) >= 3 {return nil}
	b := buffer_create(r, width, height, format, mods)
	if b != nil {
		append(&s.buffers, b)
		b.available = false
	}
	return b
}

read :: proc(r: ^Renderer, b: ^Buffer, dest: rawptr, stride: u32) -> bool {
	if b == nil || !current(r) || stride < u32(b.width * 4) {return false}
	// GL packs rows without the destination stride.
	pixels := make([]u8, int(b.width) * int(b.height) * 4)
	defer delete(pixels)
	gl.BindFramebuffer(gl.FRAMEBUFFER, b.fbo)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	format := u32(gl.RGBA)
	if r.bgra {format = GL_BGRA_EXT}
	gl.ReadPixels(0, 0, b.width, b.height, format, gl.UNSIGNED_BYTE, raw_data(pixels))
	if gl.GetError() != gl.NO_ERROR {return false}
	// The pass projects directly into GBM row order, including readback.
	for y in 0 ..< int(b.height) {
		src := pixels[y * int(b.width) * 4:][:int(b.width) * 4]
		dst := (cast([^]u8)dest)[y * int(stride):][:len(src)]
		copy(dst, src)
		if !r.bgra {
			for x in 0 ..< int(b.width) {dst[x * 4], dst[x * 4 + 2] = dst[x * 4 + 2], dst[x * 4]}
		}
		if b.format == gbm.XRGB8888 {
			for x in 0 ..< int(b.width) {dst[x * 4 + 3] = 255}
		}
	}
	return true
}
