package buffers

import wl "../wayland"
import p "../protocols"

ARGB8888 :: u32(0x34325241)
XRGB8888 :: u32(0x34325258)
INVALID :: u64(0x00ffffffffffffff)
Access :: enum { Read, Write }
Dmabuf_Attributes :: struct { width, height: i32, format: u32, modifier: u64, n_planes: int, offset, stride: [4]u32, fd: [4]i32 }
Shm_Attributes :: struct { fd: i32, format: u32, width, height, stride: i32, offset: int }
Buffer :: struct {
	width, height: i32,
	locks: int,
	dropped, accessing, releasing: bool,
	events: struct { destroy, release: wl.Signal },
	destroy: proc(^Buffer),
	dmabuf: proc(^Buffer) -> (Dmabuf_Attributes, bool),
	shm: proc(^Buffer) -> (Shm_Attributes, bool),
	access_begin: proc(^Buffer, Access) -> (rawptr, u32, int, bool),
	access_end: proc(^Buffer),
}
init :: proc(b: ^Buffer, width, height: i32) {
	b.width, b.height = width, height
	wl.signal_init(&b.events.destroy); wl.signal_init(&b.events.release)
}
lock :: proc(b: ^Buffer) -> ^Buffer { if b != nil { b.locks += 1 }; return b }
consider_destroy :: proc(b: ^Buffer) {
	if !b.dropped || b.locks != 0 || b.accessing || b.releasing { return }
	wl.signal_emit_final(&b.events.destroy, b)
	b.destroy(b)
}
unlock :: proc(b: ^Buffer) {
	if b == nil { return }
	assert(b.locks > 0); b.locks -= 1
	if b.locks == 0 {
		// Release listeners may drop the producer's last reference.
		b.releasing = true; wl.signal_emit_mutable(&b.events.release, b); b.releasing = false
		consider_destroy(b)
	}
}
drop :: proc(b: ^Buffer) { assert(!b.dropped); b.dropped = true; consider_destroy(b) }
dmabuf :: proc(b: ^Buffer) -> (Dmabuf_Attributes, bool) { if b != nil && b.dmabuf != nil { return b.dmabuf(b) }; return {}, false }
shm :: proc(b: ^Buffer) -> (Shm_Attributes, bool) { if b != nil && b.shm != nil { return b.shm(b) }; return {}, false }
access_begin :: proc(b: ^Buffer, access: Access) -> (rawptr, u32, int, bool) {
	if b == nil || b.access_begin == nil || b.accessing { return nil, 0, 0, false }
	data, format, stride, ok := b.access_begin(b, access)
	b.accessing = ok
	return data, format, stride, ok
}
access_end :: proc(b: ^Buffer) { assert(b.accessing); b.access_end(b); b.accessing = false; consider_destroy(b) }
is_opaque :: proc(b: ^Buffer) -> bool {
	format: u32
	if a, ok := dmabuf(b); ok { format = a.format } else if a, shm_ok := shm(b); shm_ok { format = a.format } else { return false }
	return format == XRGB8888 || u8(format) == 'X' || u8(format >> 8) == 'X'
}
Resource :: struct { base: Buffer, resource: ^wl.Resource, release: wl.Listener }
resource_release :: proc(l: ^wl.Listener, data: rawptr) {
	b := wl.owner(l, Resource, "release")
	if b.resource != nil { wl.post(b.resource, 0) }
}
resource_destroy :: proc(r: ^wl.Resource) {
	b := cast(^Resource)r.data
	b.resource = nil; wl.unlisten(&b.release); drop(&b.base)
}
resource_request :: proc(r: ^wl.Resource, op: p.Wl_Buffer_Request, args: []wl.Argument) { wl.resource_destroy(r) }
resource_create :: proc(b: ^Resource, client: ^wl.Client, id: u32) -> bool {
	b.resource = wl.resource_create_typed(client, &p.wl_buffer, 1, id, b, resource_request, resource_destroy)
	if b.resource == nil { drop(&b.base); return false }
	wl.listen(&b.base.events.release, &b.release, resource_release)
	return true
}
of :: proc(r: ^wl.Resource) -> ^Buffer {
	if r == nil || r.interface != &p.wl_buffer || r.destructor != resource_destroy { return nil }
	return lock(&(cast(^Resource)r.data).base)
}
