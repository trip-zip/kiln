package buffers

import wl "../wayland"
import p "../protocols"
import "core:sys/linux"
import "core:sys/posix"
import "core:slice"

Shm :: struct { global: ^wl.Global, formats: []u32, destroy: wl.Listener }
Pool :: struct { mapping: ^Mapping, fd: i32, refs: int, formats: []u32 }
Mapping :: struct { data: rawptr, size: uint, refs: int }
Shm_Buffer :: struct { resource: Resource, pool: ^Pool, format: u32, offset, stride: i32, guard: Guard }
shm_create :: proc(display: ^wl.Display, version: i32, formats: []u32) -> ^Shm {
	s := new(Shm); s.formats = slice.clone(formats)
	s.global = wl.global_create_typed(display, &p.wl_shm, version, s, shm_request, nil, shm_bind)
	if s.global == nil { delete(s.formats); free(s); return nil }
	wl.listen(&display.destroy_signal, &s.destroy, shm_destroy)
	return s
}
shm_destroy :: proc(l: ^wl.Listener, data: rawptr) {
	s := wl.owner(l, Shm, "destroy"); wl.unlisten(l); wl.global_destroy(s.global); delete(s.formats); free(s)
}
shm_bind :: proc(r: ^wl.Resource) {
	for f in (cast(^Shm)r.data).formats {
		wire := f
		if f == ARGB8888 { wire = 0 } else if f == XRGB8888 { wire = 1 }
		wl.post(r, 0, wl.Uint(wire))
	}
}
mapping_create :: proc(fd, size: i32) -> ^Mapping {
	data, err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, linux.Fd(fd))
	if err != nil { return nil }
	m := new(Mapping); m.data, m.size, m.refs = data, uint(size), 1
	return m
}
mapping_unref :: proc(m: ^Mapping) {
	m.refs -= 1
	if m.refs == 0 { linux.munmap(m.data, m.size); free(m) }
}
pool_unref :: proc(pool: ^Pool) {
	pool.refs -= 1
	if pool.refs == 0 { mapping_unref(pool.mapping); posix.close(posix.FD(pool.fd)); delete(pool.formats); free(pool) }
}
pool_destroy :: proc(r: ^wl.Resource) { pool_unref(cast(^Pool)r.data) }
shm_request :: proc(r: ^wl.Resource, op: p.Wl_Shm_Request, args: []wl.Argument) {
	switch op {
	case .release: wl.resource_destroy(r)
	case .create_pool:
		fd, size := i32(args[1].(wl.Fd)), i32(args[2].(wl.Int))
		accepted := false
		defer if !accepted { posix.close(posix.FD(fd)) }
		if size <= 0 { wl.post_error(r, u32(p.Wl_Shm_Error.invalid_stride), "invalid pool size"); return }
		m := mapping_create(fd, size)
		if m == nil { wl.post_error(r, u32(p.Wl_Shm_Error.invalid_fd), "cannot map pool"); return }
		pool := new(Pool); pool.mapping, pool.fd, pool.refs = m, fd, 1
		// Pools outlive the binding which advertised their formats.
		pool.formats = slice.clone((cast(^Shm)r.data).formats)
		accepted = true
		if wl.resource_create_typed(r.client, &p.wl_shm_pool, r.version, u32(args[0].(wl.New_Id)), pool, pool_request, pool_destroy) == nil { pool_unref(pool) }
	}
}
pool_request :: proc(r: ^wl.Resource, op: p.Wl_Shm_Pool_Request, args: []wl.Argument) {
	pool := cast(^Pool)r.data
	switch op {
	case .destroy: wl.resource_destroy(r)
	case .resize:
		size := i32(args[0].(wl.Int))
		if size <= 0 || uint(size) < pool.mapping.size { wl.post_error(r, u32(p.Wl_Shm_Error.invalid_stride), "pool cannot shrink"); return }
		m := mapping_create(pool.fd, size)
		if m == nil { wl.post_error(r, u32(p.Wl_Shm_Error.invalid_fd), "cannot map pool"); return }
		mapping_unref(pool.mapping); pool.mapping = m
	case .create_buffer:
		offset, w, h, stride := i32(args[1].(wl.Int)), i32(args[2].(wl.Int)), i32(args[3].(wl.Int)), i32(args[4].(wl.Int))
		if offset < 0 || w <= 0 || h <= 0 || stride < w || u64(offset)+u64(stride)*u64(h) > u64(pool.mapping.size) {
			wl.post_error(r, u32(p.Wl_Shm_Error.invalid_stride), "invalid buffer extent"); return
		}
		format := u32(args[5].(wl.Uint))
		if format > 1 { wl.post_error(r, u32(p.Wl_Shm_Error.invalid_format), "unsupported shm format"); return }
		if format == 0 { format = ARGB8888 } else if format == 1 { format = XRGB8888 }
		if !slice.contains(pool.formats, format) || (format != ARGB8888 && format != XRGB8888) {
			wl.post_error(r, u32(p.Wl_Shm_Error.invalid_format), "unsupported shm format"); return
		}
		if u64(stride) < u64(w)*4 { wl.post_error(r, u32(p.Wl_Shm_Error.invalid_stride), "stride smaller than row"); return }
		b := new(Shm_Buffer); b.pool, b.offset, b.stride, b.format = pool, offset, stride, format
		pool.refs += 1
		init(&b.resource.base, w, h)
		b.resource.base.destroy, b.resource.base.shm = shm_buffer_destroy, shm_attributes
		b.resource.base.access_begin, b.resource.base.access_end = shm_access, shm_end
		resource_create(&b.resource, r.client, u32(args[0].(wl.New_Id)))
	}
}
shm_buffer_destroy :: proc(base: ^Buffer) { b := cast(^Shm_Buffer)base; pool_unref(b.pool); free(b) }
shm_attributes :: proc(base: ^Buffer) -> (Shm_Attributes, bool) {
	b := cast(^Shm_Buffer)base
	return {b.pool.fd, b.format, base.width, base.height, b.stride, int(b.offset)}, true
}
shm_access :: proc(base: ^Buffer, access: Access) -> (rawptr, u32, int, bool) {
	b := cast(^Shm_Buffer)base
	if !guard_begin(&b.guard, b.pool.mapping) { return nil, 0, 0, false }
	return rawptr(uintptr(b.guard.mapping.data)+uintptr(b.offset)), b.format, int(b.stride), true
}
shm_end :: proc(base: ^Buffer) { guard_end(&(cast(^Shm_Buffer)base).guard) }
