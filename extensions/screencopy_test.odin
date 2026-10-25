package extensions

import bk "../backend"
import out "../outputs"
import "../buffers"
import "../gles"
import paint "../paint"
import p "../protocols"
import "../readback"
import sp "../scene_paint"
import wl "../wayland"
import wire "../wayland_c"
import "base:runtime"
import "core:sys/linux"
import "core:testing"


Capture_Test :: struct {
	display: ^wl.Display,
	client: ^wl.Client,
	peer: wl.Connection,
	backend: ^bk.Backend,
	renderer: ^gles.Renderer,
	layout: ^out.Layout,
	scene: ^sp.Scene,
	output: ^out.Output,
	paint: sp.Output,
	manager: ^Screencopy,
}
capture_send :: proc(s: ^Capture_Test, words: []u32, fds: []linux.Fd = nil) {
	assert(wl.connection_queue(&s.peer, (cast([^]u8)raw_data(words))[:len(words)*4], fds) == .NONE)
	assert(wl.connection_flush(&s.peer) == .NONE)
}
capture_pump :: proc(s: ^Capture_Test) -> []u8 {
	wl.loop_dispatch(s.display.loop, 0)
	wl.display_flush_clients(s.display)
	_, _ = wl.connection_read(&s.peer)
	n := int(s.peer.input.head-s.peer.input.tail)
	bytes := make([]u8, n, context.temp_allocator)
	wl.ring_copy(&s.peer.input, bytes)
	s.peer.input.tail += uint(n)
	return bytes
}
capture_event :: proc(bytes: []u8, id, opcode: u32) -> []u8 {
	for at := 0; at+8 <= len(bytes); {
		size := int(wl.word_read(bytes, at+4)>>16)
		assert(size >= 8 && at+size <= len(bytes))
		if wl.word_read(bytes, at) == id && wl.word_read(bytes, at+4)&0xffff == opcode { return bytes[at:at+size] }
		at += size
	}
	return nil
}
capture_bind :: proc(s: ^Capture_Test, name: string, version, id: u32) {
	it := wl.iterate(&s.display.globals)
	for link in wl.next(&it) {
		g := runtime.container_of(link, wl.Global, "link")
		if string(g.interface.name) != name { continue }
		size := 24+(len(name)+4)&~3
		bytes := make([]u8, size, context.temp_allocator)
		wl.word_write(bytes, 0, 2); wl.word_write(bytes, 4, u32(size)<<16)
		wl.word_write(bytes, 8, g.name); wl.word_write(bytes, 12, u32(len(name)+1))
		copy(bytes[16:], name)
		wl.word_write(bytes, size-8, version); wl.word_write(bytes, size-4, id)
		assert(wl.connection_queue(&s.peer, bytes, nil) == .NONE)
		assert(wl.connection_flush(&s.peer) == .NONE)
		capture_pump(s)
		return
	}
	panic("missing global")
}
capture_setup :: proc(t: ^testing.T, version: u32 = 3) -> ^Capture_Test {
	wire.install()
	s := new(Capture_Test)
	s.display = wl.create()
	s.backend = bk.headless_create(s.display)
	s.renderer = gles.create(s.backend.drm_fd)
	assert(s.renderer != nil)
	shm_formats, dmabuf_formats, device, formats_ok := gles.buffer_formats(s.renderer)
	assert(formats_ok && buffers.create_globals(s.display, shm_formats, dmabuf_formats, device, s.renderer.fd))
	s.output = bk.headless_add_output(s.backend, 16, 12)
	assert(bk.start(s.backend))
	s.layout = out.layout_create(s.display)
	s.scene = sp.scene_create()
	s.paint.handle, s.paint.renderer = s.output, s.renderer
	state: out.State
	out.state_init(&state)
	out.set_enabled(&state, true)
	assert(sp.prepare_output(&s.paint, &state, 16, 12) && sp.commit_target(&s.paint, &state))
	out.state_finish(&state)
	assert(out.layout_add_auto(s.layout, s.output) != nil)
	sp.output_init(&s.paint, s.scene, s.output, s.renderer, s.layout)
	s.manager = screencopy_create(s.display, s.scene)
	s.paint.committed = proc(o: ^sp.Output, damage: []gles.Box) {
		s := runtime.container_of(o, Capture_Test, "paint")
		screencopy_committed(s.manager, o, damage)
	}
	append(&s.paint.parts, sp.Part{kind = .Solid, box = {1, 2, 7, 5}, color = {0.8, 0.2, 0.4, 1}})
	fds: [2]linux.Fd
	assert(linux.socketpair(.UNIX, .STREAM, {}, &fds) == .NONE)
	s.client = wl.client_create(s.display, i32(fds[0])); s.peer.fd = fds[1]
	capture_send(s, []u32{1, 12<<16|1, 2})
	capture_pump(s)
	capture_bind(s, "zwlr_screencopy_manager_v1", version, 3)
	capture_bind(s, "wl_output", 4, 4)
	capture_bind(s, "wl_shm", 1, 5)
	it := wl.client_resources(&s.output.resources, s.client)
	r, found := wl.next_resource(&it)
	testing.expect(t, found && r == wl.client_get_object(s.client, 4) && output_of(r) == s.output)
	testing.expect(t, len(s.paint.swapchain.buffers) > 0)
	return s
}
capture_teardown :: proc(s: ^Capture_Test) {
	wl.destroy_clients(s.display)
	wl.connection_close(&s.peer)
	sp.output_finish(&s.paint)
	bk.destroy(s.backend)
	if s.layout != nil { out.layout_destroy(s.layout) }
	sp.scene_destroy(s.scene)
	gles.destroy(s.renderer)
	wl.destroy(s.display)
	free(s)
}
capture_buffer :: proc(s: ^Capture_Test, width, height: u32, format: u32 = 0, extra_stride: u32 = 0) -> []u8 {
	stride := width*4+extra_stride
	size := stride*height
	fd, err := linux.memfd_create("screencopy-test", {.CLOEXEC})
	assert(err == .NONE && linux.ftruncate(fd, i64(size)) == .NONE)
	data, mmap_err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, fd)
	assert(mmap_err == .NONE)
	capture_send(s, []u32{5, 16<<16, 7, size}, []linux.Fd{fd})
	capture_send(s, []u32{7, 32<<16, 8, 0, width, height, stride, format, 7, 8<<16|1})
	capture_pump(s)
	return (cast([^]u8)data)[:size]
}

@(test)
screencopy_matches_last_frame_and_clips_regions :: proc(t: ^testing.T) {
	for version in 1..=3 {
		s := capture_setup(t, u32(version))
		defer capture_teardown(s)
		assert(sp.output_commit(&s.paint))
		shot, ok := readback.capture(s.paint.last, s.output, s.renderer)
		assert(ok)
		defer paint.destroy(shot)
		for region in ([2]bool{false, true}) {
			width, height := u32(16), u32(12)
			if region {
				width, height = 5, 4
				capture_send(s, []u32{3, 36<<16|1, 6, 0, 4, ~u32(1), 3, 7, 4})
			} else { capture_send(s, []u32{3, 20<<16, 6, 0, 4}) }
			events := capture_pump(s)
			advert := capture_event(events, 6, 0)
			if !testing.expect(t, len(advert) == 24) { return }
			testing.expect_value(t, wl.word_read(advert, 12), width)
			testing.expect_value(t, wl.word_read(advert, 16), height)
			testing.expect(t, (capture_event(events, 6, 6) != nil) == (version == 3))
			testing.expect(t, capture_event(events, 6, 5) == nil)
			pixels := capture_buffer(s, width, height)
			defer linux.munmap(raw_data(pixels), uint(len(pixels)))
			capture_send(s, []u32{6, 12<<16, 8})
			events = capture_pump(s)
			ready := capture_event(events, 6, 2)
			if !testing.expect(t, ready != nil) { return }
			testing.expect_value(t, wl.word_read(ready, 8), u32(u64(s.paint.committed_at.tv_sec)>>32))
			testing.expect_value(t, wl.word_read(ready, 12), u32(s.paint.committed_at.tv_sec))
			testing.expect_value(t, wl.word_read(ready, 16), u32(s.paint.committed_at.tv_nsec))
			for row in 0..<int(height) {
				y := row+3 if region else row
				want := paint.data(shot)[y*int(shot.stride):][:int(width)*4]
				testing.expect(t, string(pixels[row*int(width)*4:][:int(width)*4]) == string(want))
			}
			capture_send(s, []u32{6, 8<<16|1, 8, 8<<16})
			capture_pump(s)
		}
	}
}

@(test)
screencopy_waits_for_commits_and_releases_destroyed_buffers :: proc(t: ^testing.T) {
	s := capture_setup(t)
	defer capture_teardown(s)
	capture_send(s, []u32{3, 20<<16, 6, 0, 4})
	capture_pump(s)
	pixels := capture_buffer(s, 16, 12)
	defer linux.munmap(raw_data(pixels), uint(len(pixels)))
	capture_send(s, []u32{6, 12<<16, 8})
	testing.expect(t, capture_event(capture_pump(s), 6, 2) == nil)
	assert(sp.output_commit(&s.paint))
	testing.expect(t, capture_event(capture_pump(s), 6, 2) != nil)
	capture_send(s, []u32{6, 8<<16|1, 3, 20<<16, 6, 0, 4})
	capture_pump(s)
	capture_send(s, []u32{6, 12<<16|2, 8, 3, 8<<16|2, 8, 8<<16})
	testing.expect(t, capture_event(capture_pump(s), 6, 2) == nil)
	screencopy_committed(s.manager, &s.paint, nil)
	testing.expect(t, capture_event(capture_pump(s), 6, 2) == nil)
	sp.damage_box(&s.paint, {1, 2, 2, 2})
	assert(sp.output_commit(&s.paint))
	events := capture_pump(s)
	testing.expect(t, capture_event(events, 6, 4) != nil && capture_event(events, 6, 2) != nil)
	testing.expect(t, s.manager.frames[0].buffer == nil && s.manager.frames[0].output == nil)
}

@(test)
screencopy_output_loss_fails_pending_frame :: proc(t: ^testing.T) {
	s := capture_setup(t)
	defer capture_teardown(s)
	capture_send(s, []u32{3, 20<<16, 6, 0, 4})
	capture_pump(s)
	pixels := capture_buffer(s, 16, 12)
	defer linux.munmap(raw_data(pixels), uint(len(pixels)))
	capture_send(s, []u32{6, 12<<16|2, 8})
	capture_pump(s)
	sp.output_finish(&s.paint)
	s.paint = {}
	out.finish(s.output)
	testing.expect(t, capture_event(capture_pump(s), 6, 3) != nil)
	testing.expect(t, s.manager.frames[0].output == nil && s.manager.frames[0].buffer == nil)
}

@(test)
screencopy_rejects_invalid_buffers_and_repeated_copy :: proc(t: ^testing.T) {
	for mode in 0..<5 {
		s := capture_setup(t)
		defer capture_teardown(s)
		capture_send(s, []u32{3, 20<<16, 6, 0, 4})
		capture_pump(s)
		pixels := capture_buffer(s, 15 if mode == 0 else 16, 12, 1 if mode == 1 else 0, 4 if mode == 2 else 0)
		defer linux.munmap(raw_data(pixels), uint(len(pixels)))
		if mode == 4 {
			capture_send(s, []u32{8, 8<<16})
			capture_pump(s)
			wl.resource_create(s.client, &p.wl_buffer, 1, 8)
		}
		capture_send(s, []u32{6, 12<<16|2, 8})
		if mode == 3 { capture_send(s, []u32{6, 12<<16|2, 8}) }
		err := capture_event(capture_pump(s), 1, 0)
		if !testing.expect(t, err != nil) { return }
		testing.expect_value(t, wl.word_read(err, 12), u32(0) if mode == 3 else u32(1))
		testing.expect_value(t, len(s.manager.frames), 0)
	}
}

@(test)
screencopy_disabled_output_and_empty_region_fail :: proc(t: ^testing.T) {
	s := capture_setup(t)
	defer capture_teardown(s)
	capture_send(s, []u32{3, 36<<16|1, 6, 0, 4, 100, 100, 1, 1})
	testing.expect(t, capture_event(capture_pump(s), 6, 3) != nil)
	capture_send(s, []u32{6, 8<<16|1, 3, 20<<16, 6, 0, 4})
	capture_pump(s)
	pixels := capture_buffer(s, 16, 12)
	defer linux.munmap(raw_data(pixels), uint(len(pixels)))
	capture_send(s, []u32{6, 12<<16|2, 8})
	capture_pump(s)
	state: out.State
	out.state_init(&state)
	defer out.state_finish(&state)
	out.set_enabled(&state, false)
	assert(out.commit(s.output, &state))
	testing.expect(t, capture_event(capture_pump(s), 6, 3) != nil)
}

@(test)
screencopy_region_accounts_for_scale_transform_and_overflow :: proc(t: ^testing.T) {
	output := out.Output{width = 20, height = 12, scale = 2}
	testing.expect_value(t, screencopy_region(&output, {-2, 1, 5, 3}), gles.Box{0, 2, 6, 6})
	testing.expect_value(t, screencopy_region(&output, {max(i32), 0, max(i32), 1}).width, i32(0))
	for transform in 0..<8 {
		output.transform = i32(transform)
		w, h := i32(10), i32(6)
		if transform%2 != 0 { w, h = h, w }
		testing.expect_value(t, screencopy_region(&output, {0, 0, w, h}), gles.Box{0, 0, 20, 12})
	}
}

@(test)
screencopy_version_checks_and_client_disconnect_release_frames :: proc(t: ^testing.T) {
	for reject in ([2]bool{false, true}) {
		s := capture_setup(t, 1)
		defer capture_teardown(s)
		capture_send(s, []u32{3, 20<<16, 6, 0, 4})
		capture_pump(s)
		pixels := capture_buffer(s, 16, 12)
		defer linux.munmap(raw_data(pixels), uint(len(pixels)))
		capture_send(s, []u32{6, 12<<16|(2 if reject else 0), 8})
		events := capture_pump(s)
		if reject {
			testing.expect(t, capture_event(events, 1, 0) != nil)
		} else {
			testing.expect_value(t, len(s.manager.frames), 1)
			wl.client_destroy(s.client)
		}
		testing.expect_value(t, len(s.manager.frames), 0)
		testing.expect_value(t, len(s.manager.bindings), 0)
	}
}

@(test)
output_resource_iterator_selects_only_the_requested_client :: proc(t: ^testing.T) {
	s := capture_setup(t)
	defer capture_teardown(s)
	fds: [2]linux.Fd
	assert(linux.socketpair(.UNIX, .STREAM, {}, &fds) == .NONE)
	other := Capture_Test{display = s.display, client = wl.client_create(s.display, i32(fds[0])), peer = {fd = fds[1]}}
	defer wl.connection_close(&other.peer)
	capture_send(&other, []u32{1, 12<<16|1, 2})
	capture_pump(&other)
	capture_bind(&other, "wl_output", 2, 3)
	for client in ([]^wl.Client{s.client, other.client}) {
		it := wl.client_resources(&s.output.resources, client)
		count := 0
		for r in wl.next_resource(&it) {
			testing.expect(t, r.client == client && output_of(r) == s.output)
			count += 1
		}
		testing.expect_value(t, count, 1)
	}
}
