package gles

import "../gbm"
import "../buffers"
import "core:sys/posix"
import gl "vendor:OpenGL"

name :: proc(r: ^Renderer) -> string {
	if !current(r) { return "GLES" }
	return string(cstring(gl.GetString(gl.RENDERER)))
}

buffer_formats :: proc(r: ^Renderer) -> (shm: []u32, dmabuf: []buffers.Format, device_id: u64, ok: bool) {
	shm = make([]u32, 2, context.temp_allocator)
	shm[0], shm[1] = gbm.ARGB8888, gbm.XRGB8888
	device: posix.stat_t
	if posix.fstat(posix.FD(r.fd), &device) != .OK { return }
	formats := make([dynamic]buffers.Format, context.temp_allocator)
	fallback := [2]i32{i32(gbm.ARGB8888), i32(gbm.XRGB8888)}
	offered := r.formats
	if r.query_formats == nil { offered = fallback[:] }
	for format in offered {
		if !rgb(r, u32(format)) { continue }
		mods := make([dynamic]u64, context.temp_allocator)
		if r.query_modifiers == nil {
			append(&mods, gbm.INVALID, 0)
		} else {
			n: i32
			if r.query_modifiers(r.display, format, 0, nil, nil, &n) == 0 { return }
			values := make([]u64, int(n), context.temp_allocator)
			external := make([]u32, int(n), context.temp_allocator)
			if r.query_modifiers(r.display, format, n, raw_data(values), raw_data(external), &n) == 0 { return }
			for value, i in values[:n] { if external[i] == 0 { append(&mods, value) } }
			// External-only formats cannot use the importer's sampler2D shader.
			if n == 0 || len(mods) > 0 { append(&mods, gbm.INVALID) }
		}
		if len(mods) > 0 { append(&formats, buffers.Format{u32(format), mods[:]}) }
	}
	if len(formats) == 0 { return }
	return shm, formats[:], u64(device.st_rdev), true
}
