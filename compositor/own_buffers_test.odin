package compositor

import "../buffers"
import wl "../wayland"
import p "../protocols"
import "core:sys/linux"
import "core:sys/posix"
import "core:testing"
import "core:mem"
import "core:os"

buffer_test_fd :: proc(size: i64) -> linux.Fd {
	fd, err := linux.memfd_create("buffer-test", {.CLOEXEC})
	assert(err == nil && linux.ftruncate(fd, size) == nil)
	return fd
}
buffer_test_send_fd :: proc(c: ^Extension_Client, words: []u32, fd: linux.Fd) {
	copy_fd, err := linux.dup(fd); assert(err == nil)
	assert(wl.connection_queue(&c.peer, mem.slice_to_bytes(words), []linux.Fd{copy_fd}) == nil)
	assert(wl.connection_flush(&c.peer) == nil)
	wl.loop_dispatch(c.display.loop, 0)
}
buffer_test_pool :: proc(c: ^Extension_Client, fd: linux.Fd, size: u32) {
	buffer_test_send_fd(c, []u32{7,16<<16,8,size}, fd)
}
buffer_test_add :: proc(c: ^Extension_Client, fd: linux.Fd, plane: u32 = 0, offset: u32 = 0, stride: u32 = 16, modifier: u64 = buffers.INVALID) {
	buffer_test_send_fd(c, []u32{8,28<<16|1,plane,offset,stride,u32(modifier>>32),u32(modifier)}, fd)
}
buffer_test_dmabuf :: proc(s: ^Server, check_fd: i32 = -1) -> ^buffers.Dmabuf {
	mods := [2]u64{buffers.INVALID, 0}
	formats := [2]buffers.Format{{buffers.ARGB8888,mods[:]},{buffers.XRGB8888,mods[:1]}}
	m := buffers.dmabuf_create(s.display, formats[:], 0x1122334455667788, check_fd)
	assert(m != nil); return m
}
@(test)
owned_shm_rejects_invalid_pools_formats_strides_and_extents :: proc(t: ^testing.T) {
	for scenario in 0..<13 {
		s := surface_server(); defer extension_finish(s)
		c := surface_client(s); defer wl.connection_close(&c.peer)
		events := extension_bind(&c,"wl_shm",2,7)
		testing.expect(t, extension_event_count(events,7,0) == 2)
		fd := buffer_test_fd(4096); defer linux.close(fd)
		object, code := u32(8), u32(p.Wl_Shm_Error.invalid_stride)
		if scenario == 0 { buffer_test_pool(&c,fd,0); object = 7 } else if scenario == 1 {
			pipes: [2]linux.Fd; assert(linux.pipe2(&pipes, {}) == nil)
			defer linux.close(pipes[0]); defer linux.close(pipes[1])
			buffer_test_pool(&c,pipes[0],4096); object, code = 7, u32(p.Wl_Shm_Error.invalid_fd)
		} else {
			buffer_test_pool(&c,fd,4096); extension_pump(&c)
			offset,w,h,stride,format := u32(0),u32(4),u32(4),u32(16),u32(0)
			switch scenario {
			case 2: offset = max(u32)
			case 3: w = 0
			case 4: h = max(u32)
			case 5: stride = 15
			case 6: offset = 4090
			case 7: h, stride = 0x7fffffff, 0x7fffffff
			case 8: format = 123; code = u32(p.Wl_Shm_Error.invalid_format)
			case 12: format = buffers.ARGB8888; code = u32(p.Wl_Shm_Error.invalid_format)
			case 9: w, stride = 0x40000000, 0x40000000
			case 10,11:
				size := u32(4095) if scenario == 10 else 0
				extension_send(&c,[]u32{8,12<<16|2,size}); shell_test_error(t,&c,8,code); continue
			}
			extension_send(&c,[]u32{8,32<<16,9,offset,w,h,stride,format})
		}
		shell_test_error(t,&c,object,code)
	}
}
@(test)
owned_shm_resize_active_access_truncate_and_resource_lifetime :: proc(t: ^testing.T) {
	s := surface_server(); defer extension_finish(s)
	c := surface_client(s); defer wl.connection_close(&c.peer)
	extension_bind(&c,"wl_shm",2,7)
	fd := buffer_test_fd(4096); defer linux.close(fd)
	value := u32(0x12345678); assert(posix.pwrite(posix.FD(fd), cast([^]u8)&value, 4, 0) == 4)
	buffer_test_pool(&c,fd,4096)
	extension_send(&c,[]u32{8,32<<16,9,0,4,4,16,1}); extension_pump(&c)
	b := buffers.of(wl.client_get_object(c.client,9)); assert(b != nil)
	testing.expect(t,buffers.of(wl.client_get_object(c.client,6)) == nil && buffers.is_opaque(b))
	first, format, stride, ok := buffers.access_begin(b,.Read)
	testing.expect(t,ok && format == buffers.XRGB8888 && stride == 16 && (cast(^u32)first)^ == value)
	_,_,_,twice := buffers.access_begin(b,.Read); testing.expect(t,!twice)
	assert(linux.ftruncate(fd,8192) == nil)
	extension_send(&c,[]u32{8,12<<16|2,8192}); extension_pump(&c)
	// Resize must preserve pointers which consumers are still using.
	extension_send(&c,[]u32{8,32<<16,10,4096,4,4,16,0}); extension_pump(&c)
	other := buffers.of(wl.client_get_object(c.client,10)); assert(other != nil)
	second,_,_,other_ok := buffers.access_begin(other,.Write); testing.expect(t,other_ok)
	testing.expect(t,!buffers.is_opaque(other))
	assert(linux.ftruncate(fd,0) == nil)
	testing.expect_value(t,(cast(^u32)first)^,u32(0))
	testing.expect_value(t,(cast(^u32)second)^,u32(0))
	(cast(^u32)second)^ = 99
	// Resource destruction must not require consumers to finish in stack order.
	extension_send(&c,[]u32{9,8<<16,10,8<<16,8,8<<16|1,7,8<<16|1}); extension_pump(&c)
	testing.expect(t,b.dropped && other.dropped)
	buffers.access_end(b); buffers.unlock(b)
	testing.expect_value(t,(cast(^u32)second)^,u32(99))
	buffers.access_end(other); buffers.unlock(other)
	testing.expect(t,extension_event(extension_pump(&c),1,0) == nil)
}
@(test)
owned_dmabuf_validates_params_and_closes_rejected_planes :: proc(t: ^testing.T) {
	before, _ := os.read_all_directory_by_path("/proc/self/fd", context.temp_allocator)
	for scenario in 0..<13 {
		s := extension_server(); defer extension_finish(s)
		buffer_test_dmabuf(s)
		c := surface_client(s); defer wl.connection_close(&c.peer)
		extension_bind(&c,"zwp_linux_dmabuf_v1",4,7)
		extension_send(&c,[]u32{7,12<<16|1,8}); extension_pump(&c)
		fd := buffer_test_fd(4096); defer linux.close(fd)
		code := p.Zwp_Linux_Buffer_Params_V1_Error.incomplete
		w,h,format,flags := u32(4),u32(4),buffers.ARGB8888,u32(0)
		switch scenario {
		case 0: buffer_test_add(&c,fd,4); code = .plane_idx
		case 1: buffer_test_add(&c,fd); buffer_test_add(&c,fd); code = .plane_set
		case 2: buffer_test_add(&c,fd); buffer_test_add(&c,fd,1,0,16,0); code = .invalid_format
		case 3:
		case 4: buffer_test_add(&c,fd,1)
		case 5: buffer_test_add(&c,fd); buffer_test_add(&c,fd,2)
		case 6: buffer_test_add(&c,fd); format = 123; code = .invalid_format
		case 7: buffer_test_add(&c,fd,0,0,16,42); code = .invalid_format
		case 8: buffer_test_add(&c,fd); flags = 1; code = .invalid_format
		case 9: buffer_test_add(&c,fd); w = 0; code = .invalid_dimensions
		case 10: buffer_test_add(&c,fd,0,4090); code = .out_of_bounds
		case 11: buffer_test_add(&c,fd,0,0,0xffffffff); code = .out_of_bounds
		case 12: buffer_test_add(&c,fd,0,0,0); code = .out_of_bounds
		}
		if scenario > 2 { extension_send(&c,[]u32{8,28<<16|3,9,w,h,format,flags}) }
		shell_test_error(t,&c,8,u32(code))
	}
	after, _ := os.read_all_directory_by_path("/proc/self/fd", context.temp_allocator)
	testing.expect(t,len(after) == len(before),"rejected plane fds are closed")
}
@(test)
owned_dmabuf_import_failure_and_one_shot_params :: proc(t: ^testing.T) {
	for scenario in 0..<4 {
		s := extension_server(); defer extension_finish(s)
		fd := buffer_test_fd(4096); defer linux.close(fd)
		m := buffer_test_dmabuf(s, i32(fd) if scenario < 2 else -1)
		if scenario < 2 { testing.expect(t,m.check_fd != i32(fd)) }
		c := surface_client(s); defer wl.connection_close(&c.peer)
		extension_bind(&c,"zwp_linux_dmabuf_v1",4,7)
		extension_send(&c,[]u32{7,12<<16|1,8}); buffer_test_add(&c,fd)
		if scenario == 1 { extension_send(&c,[]u32{8,28<<16|3,9,4,4,buffers.ARGB8888,0}); shell_test_error(t,&c,8,7); continue }
		extension_send(&c,[]u32{8,24<<16|2,4,4,buffers.ARGB8888,0})
		events := extension_pump(&c)
		if scenario == 0 { testing.expect(t,extension_event(events,8,1) != nil) } else {
			created := extension_event(events,8,0); assert(created != nil)
			id := wl.word_read(created,8); r := wl.client_get_object(c.client,id)
			b := buffers.of(r); assert(b != nil)
			a,ok := buffers.dmabuf(b); testing.expect(t,ok && a.n_planes == 1 && a.width == 4 && a.fd[0] >= 0)
			if scenario == 2 {
				buffers.unlock(b); testing.expect(t,extension_event(extension_pump(&c),id,0) != nil)
				b = buffers.of(r); wl.resource_destroy(r); testing.expect(t,b.dropped)
			} else { wl.resource_destroy(r) }
			buffers.unlock(b)
			testing.expect(t,posix.fcntl(posix.FD(a.fd[0]),.GETFD) < 0,"plane fd dies with last buffer reference")
		}
		if scenario == 3 { buffer_test_add(&c,fd) } else { extension_send(&c,[]u32{8,24<<16|2,4,4,buffers.ARGB8888,0}) }
		shell_test_error(t,&c,8,0)
	}
}
@(test)
owned_dmabuf_feedback_table_seals_indices_and_legacy_binds :: proc(t: ^testing.T) {
	s := extension_server(); defer extension_finish(s)
	buffer_test_dmabuf(s)
	c := surface_client(s); defer wl.connection_close(&c.peer)
	for version in u32(1)..=4 {
		events := extension_bind(&c,"zwp_linux_dmabuf_v1",version,7)
		if version < 3 { testing.expect(t,extension_event_count(events,7,0) == 2) }
		if version == 3 {
			testing.expect(t,extension_event_count(events,7,1) == 2)
			e := extension_event(events,7,1)
			testing.expect(t,wl.word_read(e,12) == u32(buffers.INVALID>>32) && wl.word_read(e,16) == u32(buffers.INVALID & 0xffffffff))
		}
		if version == 4 {
			testing.expect(t,len(events) == 0)
			for surface_feedback in ([]bool{false,true}) {
				if surface_feedback { extension_send(&c,[]u32{7,16<<16|3,8,6}) } else { extension_send(&c,[]u32{7,12<<16|2,8}) }
				events = extension_pump(&c)
				device := extension_event(events,8,2); target := extension_event(events,8,4)
				testing.expect(t,wl.word_read(device,8) == 8 && wl.word_read(target,8) == 8)
				testing.expect(t,wl.word_read(device,12) == 0x55667788 && wl.word_read(device,16) == 0x11223344)
				table := extension_event(events,8,1); testing.expect_value(t,wl.word_read(table,8),u32(48))
				assert(c.peer.fds_in.head-c.peer.fds_in.tail == 1)
				fd := wl.fd_take(&c.peer.fds_in); defer linux.close(fd)
				entries: [3]buffers.Table_Entry
				testing.expect(t,posix.pread(posix.FD(fd),cast([^]u8)&entries,size_of(entries),0) == size_of(entries))
				testing.expect(t,entries[0] == buffers.Table_Entry{buffers.ARGB8888,0,buffers.INVALID} && entries[1].modifier == 0 && entries[2].format == buffers.XRGB8888)
				testing.expect_value(t,posix.fcntl(posix.FD(fd),posix.FCNTL_Cmd(1034)),i32(15))
				indices := extension_event(events,8,5); testing.expect_value(t,wl.word_read(indices,8),u32(6))
				testing.expect(t,indices[12] == 0 && indices[14] == 1 && indices[16] == 2)
				testing.expect(t,extension_event(events,8,3) != nil && extension_event(events,8,0) != nil && wl.word_read(extension_event(events,8,6),8) == 0)
				extension_send(&c,[]u32{8,8<<16}); extension_pump(&c)
			}
		}
		extension_send(&c,[]u32{7,8<<16}); extension_pump(&c)
	}
}

@(test)
owned_dmabuf_auxiliary_planes_have_independent_extents :: proc(t: ^testing.T) {
	s := extension_server(); defer extension_finish(s)
	buffer_test_dmabuf(s)
	c := surface_client(s); defer wl.connection_close(&c.peer)
	extension_bind(&c,"zwp_linux_dmabuf_v1",4,7)
	extension_send(&c,[]u32{7,12<<16|1,8})
	pixels, auxiliary := buffer_test_fd(64), buffer_test_fd(16)
	defer linux.close(pixels); defer linux.close(auxiliary)
	buffer_test_add(&c,pixels); buffer_test_add(&c,auxiliary,1)
	extension_send(&c,[]u32{8,28<<16|3,9,4,4,buffers.ARGB8888,0}); extension_pump(&c)
	b := buffers.of(wl.client_get_object(c.client,9))
	if testing.expect(t,b != nil,"auxiliary storage need not contain full image rows") { buffers.unlock(b) }
}
