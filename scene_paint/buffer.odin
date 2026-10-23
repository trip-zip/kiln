package scene_paint

import paint "../paint"
import wlr "../wlroots"
import "base:runtime"
import "core:c"

Buffer :: struct {
	base:                           wlr.wlr_buffer,
	surface:                        paint.Surface,
	texture:                        ^wlr.Texture,
	allocator:                      runtime.Allocator,
	source_x, source_y:             i32,
	source_scale_x, source_scale_y: f64,
}
// These internal counters include retained raster and delayed consumer references.
live_buffers, live_bytes, created_buffers: u64
buffer_impl := wlr.wlr_buffer_impl {
	destroy               = buffer_destroy,
	begin_data_ptr_access = buffer_access,
	end_data_ptr_access   = buffer_end,
}
buffer_destroy :: proc "c" (base: ^wlr.wlr_buffer) {
	context = runtime.default_context()
	b := (^Buffer)(base)
	context.allocator = b.allocator
	live_buffers -= 1
	live_bytes -= u64(b.surface.stride) * u64(b.surface.height)
	paint.destroy(b.surface)
	free(b)
}
buffer_access :: proc "c" (
	base: ^wlr.wlr_buffer,
	flags: u32,
	data: ^rawptr,
	format: ^u32,
	stride: ^c.size_t,
) -> bool {
	context = runtime.default_context()
	if flags & 2 != 0 {return false}
	b := (^Buffer)(base)
	data^ = paint.data(b.surface)
	format^ = 0x34325241 // DRM_FORMAT_ARGB8888, native-endian premultiplied Cairo ARGB32.
	stride^ = c.size_t(b.surface.stride)
	return true
}
buffer_end :: proc "c" (base: ^wlr.wlr_buffer) {context = runtime.default_context()}
wrap :: proc(surface: paint.Surface) -> ^Buffer {
	b := new(Buffer)
	b.surface, b.allocator = surface, context.allocator
	wlr.wlr_buffer_init(&b.base, &buffer_impl, surface.width, surface.height)
	// The raster cache owns CPU pixels independently of renderer imports.
	wlr.wlr_buffer_lock(&b.base)
	wlr.wlr_buffer_drop(&b.base)
	live_buffers += 1
	created_buffers += 1
	live_bytes += u64(surface.stride) * u64(surface.height)
	return b
}
