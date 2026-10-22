package scene_paint

import "base:runtime"
import "core:c"
import paint "../paint"
import wlr "../wlroots"

Buffer :: struct {
	base: wlr.wlr_buffer,
    passthrough:bool,
	surface: paint.Surface,
	allocator: runtime.Allocator,
	source_x,source_y: i32,
	source_scale_x,source_scale_y: f64,
}
// These internal counters include retained raster and delayed consumer references.
live_buffers, live_bytes, created_buffers: u64
buffer_impl := wlr.wlr_buffer_impl{destroy=buffer_destroy, begin_data_ptr_access=buffer_access, end_data_ptr_access=buffer_end}
buffer_destroy :: proc "c" (base: ^wlr.wlr_buffer) {
	context = runtime.default_context()
	b := (^Buffer)(base)
	context.allocator = b.allocator
	live_buffers -= 1
	live_bytes -= u64(b.surface.stride)*u64(b.surface.height)
	paint.destroy(b.surface)
	free(b)
}
buffer_access :: proc "c" (base: ^wlr.wlr_buffer, flags: u32, data: ^rawptr, format: ^u32, stride: ^c.size_t) -> bool {
	context = runtime.default_context()
	if flags & 2 != 0 { return false }
	b := (^Buffer)(base)
	data^ = paint.data(b.surface)
	format^ = 0x34325241 // DRM_FORMAT_ARGB8888, native-endian premultiplied Cairo ARGB32.
	stride^ = c.size_t(b.surface.stride)
	return true
}
buffer_end :: proc "c" (base: ^wlr.wlr_buffer) { context = runtime.default_context() }
wrap :: proc(surface: paint.Surface) -> ^Buffer {
	b := new(Buffer)
	b.surface, b.allocator = surface, context.allocator
	wlr.wlr_buffer_init(&b.base, &buffer_impl, surface.width, surface.height)
	// Retain CPU pixels for alpha picking after the scene imports its texture.
	wlr.wlr_buffer_lock(&b.base)
	wlr.wlr_buffer_drop(&b.base)
	live_buffers += 1
	created_buffers += 1
	live_bytes += u64(surface.stride)*u64(surface.height)
	return b
}
accepts_input :: proc "c" (sb: ^wlr.wlr_scene_buffer, sx,sy: ^f64) -> bool {
	context = runtime.default_context()
	b := (^Buffer)(sb.node.data)
	return !b.passthrough && paint.alpha(b.surface, i32(sx^*b.source_scale_x)+b.source_x, i32(sy^*b.source_scale_y)+b.source_y) != 0
}
