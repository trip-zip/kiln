package gles

import "../gbm"
import wl "../wayland"
import "../buffers"
import "core:fmt"
import gl "vendor:OpenGL"
import egl "vendor:egl"

Texture :: struct {
	renderer:      ^Renderer,
	buffer:        ^buffers.Buffer,
	destroy:       wl.Listener,
	name:          u32,
	image:         egl.Image,
	width, height: i32,
	opaque:        bool,
	pins:          u32,
}

texture_destroy :: proc(t: ^Texture) {
	if t == nil {return}
	r := t.renderer
	context.allocator = r.allocator
	wl.unlisten(&t.destroy)
	delete_key(&r.textures, rawptr(t.buffer))
	if r.loaded && current(r) {gl.DeleteTextures(1, &t.name)}
	if t.image != egl.NO_IMAGE {egl.DestroyImage(r.display, t.image)}
	free(t)
}

texture_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	t := wl.owner(listener, Texture, "destroy")
	context.allocator = t.renderer.allocator
	wl.unlisten(listener)
	delete_key(&t.renderer.textures, rawptr(t.buffer))
	t.buffer = nil
	if t.pins == 0 {texture_destroy(t)}
}

texture_retain :: proc(t: ^Texture) -> ^Texture {
	if t != nil {t.pins += 1}
	return t
}

texture_release :: proc(t: ^Texture) {
	if t != nil {
		assert(t.pins > 0)
		t.pins -= 1
		if t.pins == 0 && t.buffer == nil {texture_destroy(t)}
	}
}

needs_buffer :: proc(t: ^Texture) -> bool {
	return t != nil && t.image != egl.NO_IMAGE
}

reject :: proc(r: ^Renderer, format: u32) {
	if !r.rejected[format] {
		r.rejected[format] = true
		fmt.eprintf("GLES: skipped unsupported buffer format 0x%x\n", format)
	}
}

rgb :: proc(r: ^Renderer, format: u32) -> bool {
	// EGL also advertises YUV formats, which require a different sampler contract.
	a, b := u8(format), u8(format >> 8)
	if !((a == 'A' || a == 'X' || a == 'R' || a == 'B') && (b == 'R' || b == 'B' || b == 'G' ||
	   b == 'X' || b == 'A')) {return false}
	if r.query_formats == nil {return format == gbm.ARGB8888 || format == gbm.XRGB8888}
	for f in r.formats {
		if u32(f) == format {return true}
	}
	return false
}
// The cache borrows the buffer until its destroy signal ends the import lifetime.
import_buffer :: proc(r: ^Renderer, b: ^buffers.Buffer) -> ^Texture {
	if b == nil || !current(r) {return nil}
	if t := r.textures[rawptr(b)]; t != nil {return t}
	context.allocator = r.allocator
	t := new(Texture)
	t.renderer, t.buffer, t.width, t.height = r, b, b.width, b.height
	gl.GenTextures(1, &t.name)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, t.name)
	texture_parameters()
	ok := false
	defer {
		if !ok {texture_destroy(t)}
	}
	if attrs, has_dmabuf := buffers.dmabuf(b); has_dmabuf {
		if attrs.n_planes < 1 || attrs.n_planes > 4 || !rgb(r, attrs.format) {
			reject(r, attrs.format)
			return nil
		}
		t.opaque = u8(attrs.format) == 'X' || u8(attrs.format >> 8) == 'X'
		// Compression modifiers export one RGB image as several planes of metadata.
		planes: [4]Plane
		for i in 0 ..< int(attrs.n_planes) {
			planes[i] = {attrs.fd[i], attrs.stride[i], attrs.offset[i]}
		}
		t.image = image(
			r,
			attrs.width,
			attrs.height,
			attrs.format,
			attrs.modifier,
			planes[:attrs.n_planes],
		)
		if t.image == egl.NO_IMAGE {
			reject(r, attrs.format)
			return nil
		}
		r.image_texture(gl.TEXTURE_2D, t.image)
	} else {
		if !upload(t, nil, true) {return nil}
	}
	if gl.GetError() != gl.NO_ERROR {return nil}
	r.textures[rawptr(b)] = t
	wl.listen(&b.events.destroy, &t.destroy, texture_destroyed)
	ok = true
	return t
}
update :: proc(r: ^Renderer, b: ^buffers.Buffer, boxes: []Box) {
	if r == nil || b == nil {return}
	if t := r.textures[rawptr(b)]; t != nil && t.image == egl.NO_IMAGE {
		if !current(r) {return}
		upload(t, boxes, false)
	}
}

upload :: proc(t: ^Texture, boxes: []Box, full: bool) -> bool {
	if t.renderer.lost {return false}
	data, format, stride, accessible := buffers.access_begin(t.buffer, .Read)
	if !accessible {return false}
	defer buffers.access_end(t.buffer)
	if format != gbm.ARGB8888 && format != gbm.XRGB8888 {
		reject(t.renderer, format)
		return false
	}
	t.opaque = format == gbm.XRGB8888
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, t.name)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	whole := [1]Box{{0, 0, t.buffer.width, t.buffer.height}}
	regions := boxes
	if full || t.width != t.buffer.width || t.height != t.buffer.height {
		t.width, t.height = t.buffer.width, t.buffer.height
		regions = whole[:]
		gl.TexImage2D(
			gl.TEXTURE_2D,
			0,
			gl.RGBA,
			t.width,
			t.height,
			0,
			gl.RGBA,
			gl.UNSIGNED_BYTE,
			nil,
		)
	}
	for box in regions {
		x, y := max(box.x, 0), max(box.y, 0)
		w, h := min(box.x + box.width, t.width) - x, min(box.y + box.height, t.height) - y
		if w <= 0 || h <= 0 {continue}
		pixels := make([]u8, int(w) * int(h) * 4, context.temp_allocator)
		for row in 0 ..< int(h) {
			src := (cast([^]u8)data)[(int(y) + row) * int(stride) + int(x) * 4:][:int(w) * 4]
			for col in 0 ..< int(w) {
				i := col * 4
				j := (row * int(w) + col) * 4
				copy(pixels[j:j + 4], []u8{src[i + 2], src[i + 1], src[i], src[i + 3]})
			}
		}
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, x, y, w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	}
	return gl.GetError() == gl.NO_ERROR
}
