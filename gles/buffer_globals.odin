package gles

import "../gbm"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"
import "core:sys/posix"
import gl "vendor:OpenGL"

name :: proc(r: ^Renderer) -> string {
	if !current(r) { return "GLES" }
	return string(cstring(gl.GetString(gl.RENDERER)))
}

buffer_globals :: proc(r: ^Renderer, display: ^wl.Display) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	shm := [2]u32{gbm.ARGB8888, gbm.XRGB8888}
	if wlr.wlr_shm_create(display, 2, &shm[0], len(shm)) == nil { return false }
	device: posix.stat_t
	if posix.fstat(posix.FD(r.fd), &device) != .OK { return false }
	formats := make([dynamic]wlr.wlr_drm_format, context.temp_allocator)
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
			if r.query_modifiers(r.display, format, 0, nil, nil, &n) == 0 { return false }
			values := make([]u64, int(n), context.temp_allocator)
			external := make([]u32, int(n), context.temp_allocator)
			if r.query_modifiers(r.display, format, n, raw_data(values), raw_data(external), &n) == 0 { return false }
			for value, i in values[:n] { if external[i] == 0 { append(&mods, value) } }
			// External-only formats cannot use the importer's sampler2D shader.
			if n == 0 || len(mods) > 0 { append(&mods, gbm.INVALID) }
		}
		if len(mods) > 0 { append(&formats, wlr.wlr_drm_format{u32(format), uint(len(mods)), uint(len(mods)), raw_data(mods)}) }
	}
	if len(formats) == 0 { return false }
	tranche := wlr.wlr_linux_dmabuf_feedback_v1_tranche{target_device = device.st_rdev,
		formats = {uint(len(formats)), uint(len(formats)), raw_data(formats)}}
	feedback := wlr.wlr_linux_dmabuf_feedback_v1{main_device = device.st_rdev,
		tranches = {size = size_of(tranche), data = &tranche}}
	return wlr.wlr_linux_dmabuf_v1_create(display, 4, &feedback) != nil
}
