package scene_paint

import paint "../paint"
import "../buffers"
import "base:runtime"
import "../gles"

Buffer :: struct {
	base: buffers.Buffer,
	surface: paint.Surface,
	texture: ^gles.Texture,
	allocator: runtime.Allocator,
	source_x, source_y: i32,
	source_scale_x, source_scale_y: f64,
}
// These internal counters include retained raster and delayed consumer references.
live_buffers, live_bytes, created_buffers: u64
buffer_destroy :: proc(base: ^buffers.Buffer) {
	b := (^Buffer)(base)
	context.allocator = b.allocator
	live_buffers -= 1
	live_bytes -= u64(b.surface.stride) * u64(b.surface.height)
	paint.destroy(b.surface)
	free(b)
}
buffer_access :: proc(base: ^buffers.Buffer, access: buffers.Access) -> (rawptr, u32, int, bool) {
	if access == .Write { return nil, 0, 0, false }
	b := (^Buffer)(base)
	return paint.data(b.surface), buffers.ARGB8888, int(b.surface.stride), true
}
buffer_end :: proc(base: ^buffers.Buffer) {}
wrap :: proc(surface: paint.Surface) -> ^Buffer {
	b := new(Buffer)
	b.surface, b.allocator = surface, context.allocator
	buffers.init(&b.base, surface.width, surface.height)
	b.base.destroy, b.base.access_begin, b.base.access_end = buffer_destroy, buffer_access, buffer_end
	// The raster cache owns CPU pixels independently of renderer imports.
	buffers.lock(&b.base); buffers.drop(&b.base)
	live_buffers += 1; created_buffers += 1
	live_bytes += u64(surface.stride) * u64(surface.height)
	return b
}
