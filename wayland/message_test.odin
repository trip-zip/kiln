package wayland

import "core:testing"
import "core:sys/linux"

pair_open :: proc(t: ^testing.T) -> (a, b: Connection) {
	fds: [2]linux.Fd
	testing.expect(t, linux.socketpair(.UNIX, .STREAM, {}, &fds) == .NONE)
	return Connection{fd = fds[0]}, Connection{fd = fds[1]}
}
@(test)
wire_roundtrips_arguments_and_fds_across_ring_boundary :: proc(t: ^testing.T) {
	a, b := pair_open(t)
	defer connection_close(&a); defer connection_close(&b)
	a.output.head, a.output.tail = 4090, 4090
	b.input.head, b.input.tail = 4090, 4090
	pipe: [2]linux.Fd
	linux.pipe2(&pipe, {.CLOEXEC, .NONBLOCK})
	defer linux.close(pipe[0]); defer linux.close(pipe[1])
	iface := Interface{name = "test"}
	object := Resource{id = 7, interface = &iface}
	types := [10]^Interface{4 = &iface, 5 = &iface}
	message := Message{"all", "12iufs?onah?s?o", &types[0]}
	payload := [3]u8{4, 8, 12}
	args := [?]Argument{Int(-3), Uint(42), Fixed(-256), String{value = "hello"}, Object(&object), Object(&object), Array{size = 3, data = &payload[0]}, Fd(pipe[1]), String{is_null = true}, Object(nil)}
	bytes: [4096]u8
	fds: [20]linux.Fd
	size, fd_count, ok := encode(2, 3, &message, args[:], bytes[:], &fds)
	testing.expect(t, ok && fd_count == 1)
	testing.expect(t, fds[0] != pipe[1])
	testing.expect(t, connection_queue(&a, bytes[:size], fds[:fd_count]) == .NONE)
	testing.expect(t, connection_flush(&a) == .NONE)
	n, err := connection_read(&b)
	testing.expect(t, err == .NONE && n == size)
	scratch: [4096]u8
	ring_copy(&b.input, scratch[:n])
	got: [20]Argument
	count, decoded := unmarshal(&b, scratch[:n], &message, &got,
		proc(id: u32, data: rawptr) -> ^Resource { return cast(^Resource)data },
		proc(id: u32, data: rawptr) -> bool { return id == 7 }, &object)
	if !testing.expect(t, decoded && count == len(args)) { return }
	testing.expect_value(t, got[0].(Int), Int(-3))
	testing.expect_value(t, got[1].(Uint), Uint(42))
	testing.expect_value(t, got[2].(Fixed), Fixed(-256))
	testing.expect_value(t, got[3].(String).value, "hello")
	testing.expect(t, got[4].(Object) == Object(&object))
	testing.expect_value(t, got[5].(New_Id), New_Id(7))
	array := got[6].(Array)
	testing.expect_value(t, string((cast([^]u8)array.data)[:array.size]), string(payload[:]))
	fd := linux.Fd(got[7].(Fd))
	defer linux.close(fd)
	flags, _ := linux.fcntl(fd, linux.F_GETFD)
	testing.expect(t, i32(flags)&1 == 1)
	linux.write(fd, payload[:])
	readback: [3]u8
	read_count, _ := linux.read(pipe[0], readback[:])
	testing.expect(t, read_count == 3 && readback == payload)
	testing.expect(t, got[8].(String).is_null && got[9].(Object) == nil)
}
@(test)
wire_rejects_embedded_and_missing_nul :: proc(t: ^testing.T) {
	types: [1]^Interface
	message := Message{"text", "s", &types[0]}
	for payload in ([2][4]u8{{'x', 0, 'y', 0}, {'x', 'y', 'z', 'w'}}) {
		bytes: [16]u8
		word_write(bytes[:], 8, 4)
		for byte, i in payload { bytes[12+i] = byte }
		c: Connection
		args: [20]Argument
		_, ok := unmarshal(&c, bytes[:], &message, &args, nil, nil, nil)
		testing.expect(t, !ok)
	}
}
@(test)
wire_flushes_on_overflow_and_keeps_eagain_bytes :: proc(t: ^testing.T) {
	a, b := pair_open(t)
	defer connection_close(&a); defer connection_close(&b)
	data: [3000]u8
	data[0] = 91
	testing.expect(t, connection_queue(&a, data[:], nil) == .NONE)
	testing.expect(t, connection_queue(&a, data[:], nil) == .NONE)
	testing.expect_value(t, ring_size(&a.output), 3000)
	n, _ := connection_read(&b)
	testing.expect_value(t, n, 3000)
	stalled := false
	for _ in 0..<10000 {
		err := connection_flush(&a)
		if err == .EAGAIN { stalled = true; break }
		if err != .NONE { break }
		connection_queue(&a, data[:], nil)
	}
	testing.expect(t, stalled && ring_size(&a.output) > 0)
	pending := ring_size(&a.output)
	testing.expect(t, connection_flush(&a) == .EAGAIN)
	testing.expect_value(t, ring_size(&a.output), pending)
}

@(test)
wire_reads_one_ancillary_batch_per_call :: proc(t: ^testing.T) {
	a, b := pair_open(t)
	defer connection_close(&a); defer connection_close(&b)
	pipe: [2]linux.Fd
	linux.pipe2(&pipe, {.CLOEXEC, .NONBLOCK})
	defer linux.close(pipe[0]); defer linux.close(pipe[1])
	for value in ([2]u8{17, 29}) {
		fd, err := linux.fcntl(pipe[1], linux.F_DUPFD_CLOEXEC, 0)
		testing.expect(t, err == .NONE)
		bytes := [1]u8{value}
		fds := [1]linux.Fd{fd}
		testing.expect(t, connection_queue(&a, bytes[:], fds[:]) == .NONE)
		testing.expect(t, connection_flush(&a) == .NONE)
	}
	for value, i in ([2]u8{17, 29}) {
		n, err := connection_read(&b)
		testing.expect(t, err == .NONE && n == 1)
		if n != 1 { return }
		bytes: [1]u8
		ring_copy(&b.input, bytes[:]); b.input.tail = b.input.head
		testing.expect_value(t, bytes[0], value)
		testing.expect_value(t, b.fds_in.head, uint(i+1))
	}
}
