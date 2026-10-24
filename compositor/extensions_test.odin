package compositor

import ext "../extensions"
import p "../protocols"
import wl "../wayland"
import wire "../wayland_c"
import wlr "../wlroots"
import "base:runtime"
import "core:fmt"
import "core:sys/linux"
import "core:testing"
import "core:time"

foreign import extension_test_lib "system:wlroots-0.20"
foreign extension_test_lib { wlr_seat_destroy :: proc(seat: ^wlr.wlr_seat) --- }
Extension_Client :: struct { display: ^wl.Display, client: ^wl.Client, peer: wl.Connection }
extension_send :: proc(c: ^Extension_Client, words: []u32) {
	assert(wl.connection_queue(&c.peer, (cast([^]u8)raw_data(words))[:len(words)*4], nil) == .NONE)
	assert(wl.connection_flush(&c.peer) == .NONE)
}
extension_pump :: proc(c: ^Extension_Client, wait_ms: i32 = 0) -> []u8 {
	deadline := wl.monotonic_ns()+i64(wait_ms)*1_000_000
	for {
		wl.loop_dispatch(c.display.loop, i32(max(0, (deadline-wl.monotonic_ns()+999_999)/1_000_000)))
		if wl.monotonic_ns() >= deadline { break }
	}
	wl.display_flush_clients(c.display)
	_, _ = wl.connection_read(&c.peer)
	n := int(c.peer.input.head-c.peer.input.tail)
	bytes := make([]u8, n, context.temp_allocator)
	wl.ring_copy(&c.peer.input, bytes)
	c.peer.input.tail += uint(n)
	return bytes
}
extension_event :: proc(bytes: []u8, id, opcode: u32) -> []u8 {
	for at := 0; at+8 <= len(bytes); {
		size := int(wl.word_read(bytes, at+4)>>16)
		assert(size >= 8 && at+size <= len(bytes))
		if wl.word_read(bytes, at) == id && wl.word_read(bytes, at+4)&0xffff == opcode { return bytes[at:at+size] }
		at += size
	}
	return nil
}
extension_bind :: proc(c: ^Extension_Client, name: string, version, id: u32) -> []u8 {
	it := wl.iterate(&c.display.globals)
	for link in wl.next(&it) {
		g := runtime.container_of(link, wl.Global, "link")
		if string(g.interface.name) != name { continue }
		size := 24+(len(name)+4)&~3
		bytes := make([]u8, size, context.temp_allocator)
		wl.word_write(bytes, 0, 2); wl.word_write(bytes, 4, u32(size)<<16)
		wl.word_write(bytes, 8, g.name); wl.word_write(bytes, 12, u32(len(name)+1))
		copy(bytes[16:], name)
		wl.word_write(bytes, size-8, version); wl.word_write(bytes, size-4, id)
		assert(wl.connection_queue(&c.peer, bytes, nil) == .NONE)
		assert(wl.connection_flush(&c.peer) == .NONE)
		return extension_pump(c)
	}
	panic("missing global")
}
extension_server :: proc() -> ^Server {
	wire.install()
	s := new(Server)
	s.display = wl.create()
	s.seat = wlr.wlr_seat_create(s.display, "extension-test")
	wlr.wlr_seat_set_capabilities(s.seat, 1)
	assert(wlr.wlr_compositor_create(s.display, 6, nil) != nil)
	return s
}
extension_finish :: proc(s: ^Server) {
	s.shutting_down = true
	wl.destroy_clients(s.display)
	wl.unlisten(&s.new_idle_inhibitor)
	wl.unlisten(&s.request_cursor_shape)
	wl.unlisten(&s.request_activate)
	for len(s.minted_tokens) > 0 { ext.activation_retire(s.minted_tokens[0].token) }
	delete(s.minted_tokens)
	delete(s.views)
	delete(s.popups)
	delete(s.layers)
	wl.remove_source(s.idle_timer)
	wl.remove_source(s.event_source)
	for &event in s.events { free_event(&event) }
	delete(s.events)
	delete(s.idle_inhibitors)
	delete(s.outputs)
	if s.backend != nil { wlr.wlr_backend_destroy(s.backend) }
	if s.layout != nil { wlr.wlr_output_layout_destroy(s.layout) }
	delete(s.cursor_name, s.cursor_name_allocator)
	wl.destroy(s.display)
	free(s)
}
extension_client :: proc(s: ^Server, version: u32 = 5) -> Extension_Client {
	fds: [2]linux.Fd
	assert(linux.socketpair(.UNIX, .STREAM, {}, &fds) == .NONE)
	c := Extension_Client{display = s.display, client = wl.client_create(s.display, i32(fds[0])), peer = {fd = fds[1]}}
	extension_send(&c, []u32{1, 12<<16|1, 2})
	extension_pump(&c)
	extension_bind(&c, "wl_seat", version, 3)
	extension_send(&c, []u32{3, 12<<16, 4})
	extension_pump(&c)
	extension_bind(&c, "wl_compositor", 6, 5)
	extension_send(&c, []u32{5, 12<<16, 6})
	extension_pump(&c)
	return c
}
extension_focus :: proc(s: ^Server, c: ^Extension_Client, pointer_id: u32 = 4) -> u32 {
	wlr.wlr_seat_pointer_notify_enter(s.seat, ext.surface_of(wl.client_get_object(c.client, 6)), 0, 0)
	e := extension_event(extension_pump(c), pointer_id, 0)
	assert(e != nil)
	return wl.word_read(e, 8)
}

@(test)
idle_notifications_timeout_activity_inhibition_and_lifetime :: proc(t: ^testing.T) {
	s := extension_server()
	defer extension_finish(s)
	assert(init_idle(s))
	c := extension_client(s)
	defer wl.connection_close(&c.peer)
	extension_bind(&c, "ext_idle_notifier_v1", 1, 7)
	extension_send(&c, []u32{7, 20<<16|1, 8, 20, 3})
	start := wl.monotonic_ns()
	testing.expect(t, extension_event(extension_pump(&c), 8, 0) == nil)
	events := extension_pump(&c, 30)
	testing.expect(t, extension_event(events, 8, 0) != nil && wl.monotonic_ns()-start >= 20_000_000)
	testing.expect(t, extension_event(extension_pump(&c, 25), 8, 0) == nil, "no duplicate idled")
	other := wlr.wlr_seat_create(s.display, "other-seat")
	ext.idle_activity(s.idle_notifier, other)
	testing.expect(t, extension_event(extension_pump(&c), 8, 1) == nil, "activity is seat-specific")
	idle_activity(s)
	testing.expect(t, extension_event(extension_pump(&c), 8, 1) != nil)
	extension_bind(&c, "ext_idle_notifier_v1", 2, 9)
	extension_send(&c, []u32{9, 20<<16|2, 10, 20, 3, 9, 20<<16|1, 11, 20, 3})
	extension_pump(&c)
	ext.idle_inhibit(s.idle_notifier, true)
	events = extension_pump(&c, 30)
	testing.expect(t, extension_event(events, 8, 0) == nil && extension_event(events, 11, 0) == nil)
	testing.expect(t, extension_event(events, 10, 0) != nil, "input notification ignores inhibitors")
	idle_activity(s)
	testing.expect(t, extension_event(extension_pump(&c), 10, 1) != nil)
	ext.idle_inhibit(s.idle_notifier, false)
	events = extension_pump(&c, 30)
	for id in ([]u32{8, 10, 11}) { testing.expect(t, extension_event(events, id, 0) != nil) }
	ext.idle_inhibit(s.idle_notifier, true)
	events = extension_pump(&c)
	for id in ([]u32{8, 11}) { testing.expect(t, extension_event(events, id, 1) != nil) }
	testing.expect(t, extension_event(events, 10, 1) == nil)
	// Zero is immediately idle; the full unsigned timeout must not overflow.
	extension_send(&c, []u32{9, 20<<16|2, 12, 0, 3, 9, 20<<16|2, 13, max(u32), 3})
	events = extension_pump(&c)
	testing.expect(t, extension_event(events, 12, 0) != nil && extension_event(events, 13, 0) == nil)
	long_notification := cast(^ext.Idle_Notification)wl.client_get_object(c.client, 13).data
	testing.expect_value(t, long_notification.timeout, time.Duration(max(u32))*time.Millisecond)
	extension_send(&c, []u32{7, 8<<16, 9, 8<<16})
	extension_pump(&c)
	testing.expect_value(t, len(s.idle_notifier.notifications), 5)
	wlr_seat_destroy(s.seat)
	s.seat = nil
	for n in s.idle_notifier.notifications { testing.expect(t, n.seat == nil && n.timer == nil) }
	events = extension_pump(&c, 30)
	for id in ([]u32{8, 10, 11, 12, 13}) { testing.expect(t, extension_event(events, id, 0) == nil && extension_event(events, id, 1) == nil) }
	wl.client_destroy(c.client)
	testing.expect_value(t, len(s.idle_notifier.notifications), 0)
	fmt.println("Idle: timeout, resumed, seat filtering, inhibition, v2 input, zero/large timeout and teardown passed")
}

@(test)
idle_inhibitor_on_unmapped_surface_does_not_inhibit :: proc(t: ^testing.T) {
	s := extension_server()
	defer extension_finish(s)
	s.backend = wlr_headless_backend_create(s.display.loop)
	handle := wlr_headless_add_output(s.backend, 16, 12)
	state: wlr.wlr_output_state
	wlr.wlr_output_state_init(&state)
	wlr.wlr_output_state_set_enabled(&state, true)
	assert(wlr.wlr_output_commit_state(handle, &state))
	wlr.wlr_output_state_finish(&state)
	output := Output{handle = handle}
	append(&s.outputs, &output)
	assert(init_idle(s))
	c := extension_client(s)
	defer wl.connection_close(&c.peer)
	extension_bind(&c, "zwp_idle_inhibit_manager_v1", 1, 7)
	extension_send(&c, []u32{7, 16<<16|1, 8, 6})
	extension_pump(&c)
	testing.expect_value(t, len(s.idle_inhibitors), 1)
	testing.expect(t, !s.idle_inhibitors[0].handle.surface.mapped)
	testing.expect(t, !s.idle_inhibited && !s.idle_notifier.inhibited)
	extension_bind(&c, "ext_idle_notifier_v1", 1, 9)
	extension_send(&c, []u32{9, 20<<16|1, 10, 10, 3, 7, 8<<16})
	extension_pump(&c)
	testing.expect(t, extension_event(extension_pump(&c, 20), 10, 0) != nil)
	extension_send(&c, []u32{6, 8<<16})
	extension_pump(&c)
	testing.expect_value(t, len(s.idle_inhibitors), 0)
	testing.expect(t, (cast(^ext.Idle_Inhibitor)wl.client_get_object(c.client, 8).data).surface == nil)
	extension_send(&c, []u32{8, 8<<16})
	extension_pump(&c)
	fmt.println("Idle inhibitor: real unmapped surface reached compositor policy without inhibiting; surface destroy retired it")
}

@(test)
cursor_shape_focus_serials_capabilities_and_names :: proc(t: ^testing.T) {
	s := extension_server()
	defer extension_finish(s)
	m := ext.cursor_shape_create(s.display)
	wl.listen(&m.events.request_set_shape, &s.request_cursor_shape, cursor_shape_requested)
	Probe :: struct { listener: wl.Listener, count: int }
	probe: Probe
	wl.listen(&m.events.request_set_shape, &probe.listener, proc "c" (listener: ^wl.Listener, data: rawptr) {
		context = runtime.default_context()
		wl.owner(listener, Probe, "listener").count += 1
	})
	defer wl.unlisten(&probe.listener)
	a, b := extension_client(s), extension_client(s)
	defer wl.connection_close(&a.peer)
	defer wl.connection_close(&b.peer)
	serial := extension_focus(s, &a)
	for c in ([]^Extension_Client{&a, &b}) {
		extension_bind(c, "wp_cursor_shape_manager_v1", 2, 7)
		extension_send(c, []u32{7, 16<<16|1, 8, 4})
		extension_pump(c)
	}
	extension_send(&a, []u32{8, 16<<16|1, serial, 9})
	extension_pump(&a)
	testing.expect_value(t, string(s.cursor_name), "text")
	extension_send(&a, []u32{8, 16<<16|1, serial-1, 4})
	extension_pump(&a)
	testing.expect_value(t, string(s.cursor_name), "text")
	button := wlr.wlr_seat_pointer_notify_button(s.seat, 1, 272, 1)
	wlr.wlr_seat_pointer_notify_button(s.seat, 2, 272, 0)
	extension_pump(&a)
	extension_send(&a, []u32{8, 16<<16|1, button, 3})
	extension_pump(&a)
	testing.expect(t, string(s.cursor_name) == "text", "button serial is not enter serial")
	extension_send(&a, []u32{8, 16<<16|1, serial, 4})
	extension_pump(&a)
	testing.expect(t, string(s.cursor_name) == "pointer", "enter survives later button serials")
	b_serial := extension_focus(s, &b)
	extension_pump(&a)
	extension_send(&a, []u32{8, 16<<16|1, serial, 6})
	extension_pump(&a)
	testing.expect_value(t, string(s.cursor_name), "pointer")
	testing.expect_value(t, probe.count, 2)
	extension_send(&b, []u32{8, 16<<16|1, b_serial, 6})
	extension_pump(&b)
	testing.expect_value(t, string(s.cursor_name), "wait")
	s.pointer_grabbed = true
	extension_send(&b, []u32{8, 16<<16|1, b_serial, 30})
	extension_pump(&b)
	testing.expect_value(t, string(s.cursor_name), "wait")
	s.pointer_grabbed = false
	wlr.wlr_seat_set_capabilities(s.seat, 0)
	extension_pump(&b)
	wlr.wlr_seat_set_capabilities(s.seat, 1)
	extension_pump(&b)
	extension_send(&b, []u32{3, 12<<16, 9})
	enter := extension_event(extension_pump(&b), 9, 0)
	assert(enter != nil)
	b_serial = wl.word_read(enter, 8)
	extension_send(&b, []u32{8, 16<<16|1, b_serial, 35, 7, 16<<16|1, 10, 9})
	extension_pump(&b)
	testing.expect(t, string(s.cursor_name) == "wait", "old shape device stays inert after capability returns")
	extension_send(&b, []u32{10, 16<<16|1, b_serial, 35, 7, 8<<16, 9, 8<<16|1})
	extension_pump(&b)
	testing.expect_value(t, string(s.cursor_name), "dnd-ask")
	extension_send(&b, []u32{10, 16<<16|1, b_serial, 36})
	extension_pump(&b)
	testing.expect(t, string(s.cursor_name) == "all-resize", "device survives pointer and manager release")
	testing.expect_value(t, probe.count, 6)
	for shape in p.Wp_Cursor_Shape_Device_V1_Shape {
		name := fmt.tprintf("%v", shape)
		actual := string(ext.cursor_shape_name(i32(shape)))
		testing.expect_value(t, len(actual), len(name))
		for c, i in name { testing.expect_value(t, actual[i], u8('-') if c == '_' else u8(c)) }
	}
	fmt.println("Cursor shape: focused enter accepted; stale, button, unfocused and grabbed requests ignored; all 36 generated names checked")
}

@(test)
cursor_shape_invalid_values_and_version_errors :: proc(t: ^testing.T) {
	for shape, i in ([]u32{0, 37, max(u32), 35, 36}) {
		s := extension_server()
		defer extension_finish(s)
		m := ext.cursor_shape_create(s.display)
		c := extension_client(s)
		defer wl.connection_close(&c.peer)
		extension_bind(&c, "wp_cursor_shape_manager_v1", 1 if i >= 3 else 2, 7)
		extension_send(&c, []u32{7, 16<<16|1, 8, 4, 8, 16<<16|1, 0, shape})
		e := extension_event(extension_pump(&c), 1, 0)
		assert(e != nil)
		testing.expect_value(t, wl.word_read(e, 12), u32(p.Wp_Cursor_Shape_Device_V1_Error.invalid_shape))
		testing.expect_value(t, len(m.devices), 0)
	}
}

@(test)
relative_pointer_delivers_only_to_focus_with_microsecond_timestamp :: proc(t: ^testing.T) {
	s := extension_server()
	defer extension_finish(s)
	m := ext.relative_create(s.display)
	a, b := extension_client(s, 1), extension_client(s)
	defer wl.connection_close(&a.peer)
	defer wl.connection_close(&b.peer)
	for c in ([]^Extension_Client{&a, &b}) {
		extension_bind(c, "zwp_relative_pointer_manager_v1", 1, 7)
		extension_send(c, []u32{7, 16<<16|1, 8, 4})
		extension_pump(c)
	}
	stamp := u32(0xfedcba98)
	for focused, i in ([]^Extension_Client{&a, &b}) {
		extension_focus(s, focused)
		other := &b if i == 0 else &a
		extension_pump(other)
		ext.relative_motion(m, s.seat, stamp, 1.5, -2.25, 0.5/256, -0.5/256)
		e := extension_event(extension_pump(focused), 8, 0)
		assert(e != nil)
		testing.expect_value(t, wl.word_read(e, 8), u32((u64(stamp)*1000)>>32))
		testing.expect_value(t, wl.word_read(e, 12), u32(u64(stamp)*1000))
		for want, at in ([]i32{384, -576, 1, -1}) { testing.expect_value(t, i32(wl.word_read(e, 16+at*4)), want) }
		testing.expect(t, extension_event(extension_pump(other), 8, 0) == nil)
	}
	wlr.wlr_seat_pointer_notify_clear_focus(s.seat)
	extension_pump(&b)
	ext.relative_motion(m, s.seat, stamp, 1, 2, 3, 4)
	testing.expect(t, extension_event(extension_pump(&b), 8, 0) == nil)
	extension_focus(s, &b)
	extension_send(&b, []u32{7, 8<<16})
	extension_pump(&b)
	ext.relative_motion(m, s.seat, stamp, 1, 2, 3, 4)
	testing.expect(t, extension_event(extension_pump(&b), 8, 0) != nil)
	wlr.wlr_seat_set_capabilities(s.seat, 0)
	extension_pump(&b)
	ext.relative_motion(m, s.seat, stamp, 1, 2, 3, 4)
	testing.expect(t, extension_event(extension_pump(&b), 8, 0) == nil)
	extension_send(&b, []u32{4, 8<<16|1})
	extension_pump(&b)
	testing.expect(t, m.pointers[1].pointer == nil && m.pointers[1].seat == nil)
	wlr_seat_destroy(s.seat)
	s.seat = nil
	for r in m.pointers { testing.expect(t, r.seat == nil && r.pointer == nil) }
	fmt.printf("Relative motion: focused clients only, wl_pointer v1/v5, timestamp %d us split %d:%d, signed 24.8 deltas and lifetime passed\n", u64(stamp)*1000, (u64(stamp)*1000)>>32, u32(u64(stamp)*1000))
}

@(test)
idle_v1_rejects_input_request_and_disconnect_removes_armed_timers :: proc(t: ^testing.T) {
	for bad_version in ([2]bool{true, false}) {
		s := extension_server()
		defer extension_finish(s)
		assert(init_idle(s))
		c := extension_client(s)
		defer wl.connection_close(&c.peer)
		extension_bind(&c, "ext_idle_notifier_v1", 1, 7)
		extension_send(&c, []u32{7, 20<<16|(2 if bad_version else 1), 8, 100, 3})
		events := extension_pump(&c)
		if bad_version { testing.expect(t, extension_event(events, 1, 0) != nil) } else {
			testing.expect(t, s.idle_notifier.notifications[0].timer.armed)
			wl.connection_close(&c.peer)
			wl.loop_dispatch(s.display.loop, 0)
		}
		testing.expect_value(t, len(s.idle_notifier.notifications), 0)
		testing.expect(t, wl.empty(&s.display.loop.timers))
	}
}

@(test)
cursor_shape_tablet_is_inert_and_seat_destroy_releases_focus :: proc(t: ^testing.T) {
	s := extension_server()
	defer extension_finish(s)
	m := ext.cursor_shape_create(s.display)
	wl.listen(&m.events.request_set_shape, &s.request_cursor_shape, cursor_shape_requested)
	c := extension_client(s)
	defer wl.connection_close(&c.peer)
	extension_bind(&c, "wp_cursor_shape_manager_v1", 2, 7)
	// Kiln has no tablet global; a typed stand-in exercises the accepted inert request.
	assert(wl.resource_create(c.client, &p.zwp_tablet_tool_v2, 1, 8) != nil)
	extension_send(&c, []u32{7, 16<<16|2, 9, 8, 9, 16<<16|1, 0, 0, 7, 16<<16|1, 10, 4})
	testing.expect(t, extension_event(extension_pump(&c), 1, 0) == nil)
	testing.expect(t, m.devices[0].focus == nil && m.devices[1].focus != nil)
	wlr_seat_destroy(s.seat)
	s.seat = nil
	testing.expect_value(t, len(m.focus), 0)
	for d in m.devices { testing.expect(t, d.focus == nil) }
	extension_send(&c, []u32{10, 16<<16|1, 0, 9, 9, 8<<16, 10, 8<<16})
	testing.expect(t, extension_event(extension_pump(&c), 1, 0) == nil)
	testing.expect(t, s.cursor_name == nil)
	testing.expect_value(t, len(m.devices), 0)
}
