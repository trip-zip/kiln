package wayland

import "core:testing"

@(test)
client_backpressure_arms_and_drains_writable_interest :: proc(t: ^testing.T) {
	a, b := pair_open(t)
	defer connection_close(&a); defer connection_close(&b)
	loop := loop_create()
	defer loop_destroy(loop)
	seen: Mask
	client := Client{connection = a}
	client.source = loop_on_fd(loop, i32(a.fd), {.Readable}, proc(fd: i32, mask: Mask, data: rawptr) -> i32 {
		(cast(^Mask)data)^ = mask
		return 0
	}, &seen)
	if !testing.expect(t, client.source != nil) { return }
	for _ in 0..<3 { testing.expect(t, client_flush(&client)) }
	testing.expect(t, loop_dispatch(loop, 0) && seen == {})
	bytes: [3000]u8
	for _ in 0..<10000 {
		testing.expect(t, connection_queue(&client.connection, bytes[:], nil) == .NONE)
		if !testing.expect(t, client_flush(&client)) { return }
		if client.writable { break }
	}
	if !testing.expect(t, client.writable && ring_size(&client.connection.output) > 0) { return }
	for _ in 0..<3 { testing.expect(t, client_flush(&client)) }
	for {
		n, err := connection_read(&b)
		b.input.tail = b.input.head
		if err == .EAGAIN { break }
		if !testing.expect(t, err == .NONE && n > 0) { return }
	}
	testing.expect(t, loop_dispatch(loop, 0) && .Writable in seen)
	testing.expect(t, client_flush(&client) && !client.writable && ring_size(&client.connection.output) == 0)
	for _ in 0..<3 { testing.expect(t, client_flush(&client)) }
	seen = {}
	testing.expect(t, loop_dispatch(loop, 0) && seen == {})
}
