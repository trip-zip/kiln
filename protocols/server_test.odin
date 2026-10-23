package protocols

import wl "../wayland"
import "core:sys/linux"
import "core:testing"

@(init)
server_test_tables :: proc "contextless" () { wl.core_interfaces = {&wl_display, &wl_registry, &wl_callback} }
server_pair :: proc(t: ^testing.T) -> (display: ^wl.Display, client: ^wl.Client, peer: wl.Connection) {
	display = wl.display_create()
	fds: [2]linux.Fd
	testing.expect(t, linux.socketpair(.UNIX, .STREAM, {}, &fds) == .NONE)
	client = wl.client_create(display, i32(fds[0]))
	peer.fd = fds[1]
	testing.expect(t, client != nil)
	return
}
send_words :: proc(peer: ^wl.Connection, words: []u32) {
	linux.write(peer.fd, (cast([^]u8)raw_data(words))[:len(words)*4])
}
received :: proc(t: ^testing.T, display: ^wl.Display, peer: ^wl.Connection, buffer: []u8) -> []u8 {
	wl.loop_dispatch(display.loop, 0)
	wl.display_flush_clients(display)
	count, err := wl.connection_read(peer)
	if !testing.expect(t, err == .NONE) { return nil }
	wl.ring_copy(&peer.input, buffer[:count]); peer.input.tail += uint(count)
	return buffer[:count]
}
@(test)
server_registry_sync_remove_and_reuse :: proc(t: ^testing.T) {
	display, client, peer := server_pair(t)
	defer wl.display_destroy(display)
	defer wl.display_destroy_clients(display)
	defer wl.connection_close(&peer)
	testing.expect(t, wl.empty(&display.globals))
	testing.expect_value(t, client.credentials.pid, i32(linux.getpid()))
	testing.expect_value(t, client.credentials.uid, u32(linux.getuid()))
	testing.expect_value(t, client.credentials.gid, u32(linux.getgid()))
	global := wl.global_create(display, &wl_compositor, 1, nil, proc(global: ^wl.Global, client: ^wl.Client, version, id: u32) {
		wl.resource_create(client, global.interface, i32(version), id)
	})
	send_words(&peer, []u32{1, 12<<16|1, 2, 1, 12<<16, 3})
	buffer: [4096]u8
	bytes := received(t, display, &peer, buffer[:])
	if !testing.expect(t, len(bytes) >= 24) { return }
	global_size := int(wl.word_read(bytes, 4)>>16)
	testing.expect_value(t, wl.word_read(bytes, 0), u32(2))
	testing.expect_value(t, wl.word_read(bytes, 8), global.name)
	testing.expect_value(t, wl.word_read(bytes, global_size), u32(3))
	testing.expect_value(t, wl.word_read(bytes, global_size+12), u32(1))
	testing.expect_value(t, wl.word_read(bytes, global_size+20), u32(3))
	testing.expect(t, wl.client_get_object(client, 3) == nil)
	wl.global_remove(global)
	bytes = received(t, display, &peer, buffer[:])
	testing.expect_value(t, len(bytes), 12)
	testing.expect_value(t, wl.word_read(bytes, 4)&0xffff, u32(1))
	bind := [9]u32{2, 36<<16, global.name, 14, 0, 0, 0, 1, 3}
	bind_bytes := (cast([^]u8)&bind)[:size_of(bind)]
	copy(bind_bytes[16:], "wl_compositor")
	// The NUL and four-byte padding occupy four words for this interface name.
	packet: [40]u8
	copy(packet[:], bind_bytes)
	wl.word_write(packet[:], 4, 40<<16)
	wl.word_write(packet[:], 32, 1); wl.word_write(packet[:], 36, 3)
	linux.write(peer.fd, packet[:])
	wl.loop_dispatch(display.loop, 0)
	resource := wl.client_get_object(client, 3)
	if testing.expect(t, resource != nil, "unpublished globals remain bindable") {
		wl.resource_destroy(resource)
		bytes = received(t, display, &peer, buffer[:])
		testing.expect_value(t, wl.word_read(bytes, 8), u32(3))
	}
	wl.global_destroy(global)
	server_a := wl.resource_create(client, &wl_callback, 1, 0)
	id := server_a.id; wl.resource_destroy(server_a)
	server_b := wl.resource_create(client, &wl_callback, 1, 0)
	testing.expect_value(t, server_b.id, id)
}
@(test)
server_invalid_object_posts_error_before_disconnect :: proc(t: ^testing.T) {
	display, _, peer := server_pair(t)
	defer wl.display_destroy(display)
	defer wl.display_destroy_clients(display)
	defer wl.connection_close(&peer)
	send_words(&peer, []u32{404, 8<<16})
	buffer: [4096]u8
	bytes := received(t, display, &peer, buffer[:])
	if !testing.expect(t, len(bytes) >= 20) { return }
	testing.expect_value(t, wl.word_read(bytes, 0), u32(1))
	testing.expect_value(t, wl.word_read(bytes, 4)&0xffff, u32(0))
	testing.expect_value(t, wl.word_read(bytes, 12), u32(0))
	testing.expect(t, wl.empty(&display.clients))
}

@(test)
loop_destroy_listener_can_retire_its_global :: proc(t: ^testing.T) {
	State :: struct { listener: wl.Listener, global: ^wl.Global, called: bool }
	display := wl.create()
	state := State{global = wl.global_create(display, &wl_callback, 1, nil, nil)}
	wl.listen(&display.loop.destroy_signal, &state.listener, proc "c" (listener: ^wl.Listener, data: rawptr) {
		context = wl.owner(listener, State, "listener").global.display.loop.ctx
		state := wl.owner(listener, State, "listener")
		wl.global_destroy(state.global)
		state.called = true
	})
	wl.destroy(display)
	testing.expect(t, state.called)
}
