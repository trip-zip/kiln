package buffers

import wl "../wayland"
import p "../protocols"
import "core:sys/linux"
import "core:sys/posix"
import "core:slice"
import "core:mem"

Format :: struct { format: u32, modifiers: []u64 }
Table_Entry :: struct { format, pad: u32, modifier: u64 }
#assert(size_of(posix.dev_t) == 8)
#assert(size_of(Table_Entry) == 16 && align_of(Table_Entry) == 8 && offset_of(Table_Entry, format) == 0 && offset_of(Table_Entry, pad) == 4 && offset_of(Table_Entry, modifier) == 8)
Dmabuf :: struct { global: ^wl.Global, formats: []Format, device: u64, table_fd, check_fd: i32, indices: []u16, destroy: wl.Listener }
create_globals :: proc(display: ^wl.Display, shm_formats: []u32, formats: []Format, device: u64, check_fd: i32) -> bool {
	return shm_create(display, 2, shm_formats) != nil && dmabuf_create(display, formats, device, check_fd) != nil
}
offered :: proc(m: ^Dmabuf, format: u32, modifier: u64) -> bool {
	for f in m.formats { if f.format == format { return slice.contains(f.modifiers, modifier) } }
	return false
}
dmabuf_create :: proc(display: ^wl.Display, formats: []Format, device: u64, check_fd: i32) -> ^Dmabuf {
	m := new(Dmabuf); m.device, m.check_fd, m.table_fd = device, -1, -1
	ok := false
	defer if !ok { dmabuf_finish(m) }
	if check_fd >= 0 {
		m.check_fd = i32(posix.fcntl(posix.FD(check_fd), .DUPFD_CLOEXEC, i32(0)))
		if m.check_fd < 0 { return nil }
	}
	m.formats = make([]Format, len(formats))
	table := make([dynamic]Table_Entry, context.temp_allocator)
	for f, i in formats {
		m.formats[i] = {f.format, slice.clone(f.modifiers)}
		for mod in f.modifiers { append(&table, Table_Entry{format = f.format, modifier = mod}) }
	}
	if len(table) == 0 || len(table) > 65536 { return nil }
	m.indices = make([]u16, len(table)); for &index, i in m.indices { index = u16(i) }
	fd, err := linux.memfd_create("kiln-dmabuf-formats", {.CLOEXEC, .ALLOW_SEALING})
	if err != nil { return nil }; m.table_fd = i32(fd)
	bytes := mem.slice_to_bytes(table[:]); written := 0
	for written < len(bytes) {
		n := posix.write(posix.FD(fd), raw_data(bytes[written:]), uint(len(bytes))-uint(written))
		if n <= 0 { return nil }; written += int(n)
	}
	if linux.fcntl_add_seals(fd, .ADD_SEALS, {.SEAL, .SHRINK, .GROW, .WRITE}) != nil { return nil }
	m.global = wl.global_create_typed(display, &p.zwp_linux_dmabuf_v1, 4, m, dmabuf_request, nil, dmabuf_bind)
	if m.global == nil { return nil }
	wl.listen(&display.destroy_signal, &m.destroy, dmabuf_destroy)
	ok = true; return m
}
dmabuf_finish :: proc(m: ^Dmabuf) {
	if m.check_fd >= 0 { posix.close(posix.FD(m.check_fd)) }
	if m.table_fd >= 0 { posix.close(posix.FD(m.table_fd)) }
	for f in m.formats { delete(f.modifiers) }; delete(m.formats); delete(m.indices); free(m)
}
dmabuf_destroy :: proc(l: ^wl.Listener, data: rawptr) {
	m := wl.owner(l, Dmabuf, "destroy"); wl.unlisten(l); wl.global_destroy(m.global); dmabuf_finish(m)
}
dmabuf_bind :: proc(r: ^wl.Resource) {
	if r.version >= 4 { return }
	m := cast(^Dmabuf)r.data
	for f in m.formats {
		if r.version < 3 { if slice.contains(f.modifiers, INVALID) { wl.post(r, 0, wl.Uint(f.format)) }; continue }
		mods := f.modifiers
		implicit := [1]u64{INVALID}
		// Implicit modifiers avoid older Xwayland choosing an unusable linear path.
		if len(mods) == 2 && slice.contains(mods, INVALID) && slice.contains(mods, 0) { mods = implicit[:] }
		for mod in mods { wl.post(r, 1, wl.Uint(f.format), wl.Uint(mod>>32), wl.Uint(u32(mod))) }
	}
}
feedback_request :: proc(r: ^wl.Resource, op: p.Zwp_Linux_Dmabuf_Feedback_V1_Request, args: []wl.Argument) { wl.resource_destroy(r) }
feedback_send :: proc(m: ^Dmabuf, r: ^wl.Resource) {
	device := wl.Array{size = 8, data = &m.device}
	wl.post(r, 2, device)
	wl.post(r, 1, wl.Fd(m.table_fd), wl.Uint(len(m.indices)*size_of(Table_Entry)))
	wl.post(r, 4, device); wl.post(r, 6, wl.Uint(0))
	wl.post(r, 5, wl.Array{size = uint(len(m.indices)*2), data = raw_data(m.indices)}); wl.post(r, 3); wl.post(r, 0)
}
dmabuf_request :: proc(r: ^wl.Resource, op: p.Zwp_Linux_Dmabuf_V1_Request, args: []wl.Argument) {
	m := cast(^Dmabuf)r.data
	switch op {
	case .destroy: wl.resource_destroy(r)
	case .create_params:
		params := new(Params); params.manager = m; params.attrs.fd = {-1, -1, -1, -1}
		if wl.resource_create_typed(r.client, &p.zwp_linux_buffer_params_v1, r.version, u32(args[0].(wl.New_Id)), params, params_request, params_destroy) == nil { free(params) }
	case .get_default_feedback, .get_surface_feedback:
		f := wl.resource_create_typed(r.client, &p.zwp_linux_dmabuf_feedback_v1, r.version, u32(args[0].(wl.New_Id)), nil, feedback_request)
		if f != nil { feedback_send(m, f) }
	}
}
