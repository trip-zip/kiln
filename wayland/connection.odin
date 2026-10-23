package wayland

import "core:sys/linux"

BUFFER_SIZE :: 4096
MAX_FDS_OUT :: 28
SOL_SOCKET :: i32(linux.Socket_API_Level.SOCKET)
#assert(SOL_SOCKET == 1)
// core:sys/linux lacks the ancillary type needed to transfer descriptor ownership.
SCM_RIGHTS :: i32(1)
Ring :: struct { bytes: [BUFFER_SIZE]u8, head, tail: uint }
FD_Ring :: struct { fds: [BUFFER_SIZE/4]linux.Fd, head, tail: uint }
Connection :: struct { fd: linux.Fd, input, output: Ring, fds_in, fds_out: FD_Ring }
Control :: struct { length: uint, level, kind: i32, fds: [MAX_FDS_OUT]linux.Fd }
Credentials :: struct { pid: i32, uid, gid: u32 }
#assert(size_of(Control) == 128 && offset_of(Control, fds) == 16)
#assert(size_of(Credentials) == 12)
#assert(size_of(linux.Msg_Hdr) == 56)
#assert(size_of(linux.IO_Vec) == 16)
ring_size :: proc(r: ^Ring) -> int { return int(r.head-r.tail) }
ring_put :: proc(r: ^Ring, bytes: []u8) {
	assert(ring_size(r)+len(bytes) <= BUFFER_SIZE)
	at := int(r.head % BUFFER_SIZE)
	n := copy(r.bytes[at:], bytes)
	copy(r.bytes[:], bytes[n:])
	r.head += uint(len(bytes))
}
ring_copy :: proc(r: ^Ring, bytes: []u8) {
	assert(len(bytes) <= ring_size(r))
	at := int(r.tail % BUFFER_SIZE)
	n := copy(bytes, r.bytes[at:])
	copy(bytes[n:], r.bytes[:])
}
fd_put :: proc(r: ^FD_Ring, fd: linux.Fd) { r.fds[r.head % len(r.fds)] = fd; r.head += 1 }
fd_take :: proc(r: ^FD_Ring) -> linux.Fd { fd := r.fds[r.tail % len(r.fds)]; r.tail += 1; return fd }
connection_close :: proc(c: ^Connection) {
	for c.fds_in.head != c.fds_in.tail { linux.close(fd_take(&c.fds_in)) }
	for c.fds_out.head != c.fds_out.tail { linux.close(fd_take(&c.fds_out)) }
	linux.close(c.fd)
}
connection_flush :: proc(c: ^Connection) -> linux.Errno {
	for ring_size(&c.output) > 0 {
		control := Control{level = SOL_SOCKET, kind = SCM_RIGHTS}
		fd_count := min(int(c.fds_out.head-c.fds_out.tail), MAX_FDS_OUT)
		for i in 0..<fd_count { control.fds[i] = c.fds_out.fds[(c.fds_out.tail+uint(i))%len(c.fds_out.fds)] }
		control.length = uint(16 + fd_count*4)
		at := int(c.output.tail % BUFFER_SIZE)
		count := ring_size(&c.output)
		// A byte must accompany each fd batch, including when more batches follow.
		if fd_count == MAX_FDS_OUT { count = 1 }
		first := min(count, BUFFER_SIZE-at)
		iov := [2]linux.IO_Vec{{&c.output.bytes[at], uint(first)}, {&c.output.bytes[0], uint(count-first)}}
		msg := linux.Msg_Hdr{iov = iov[:1]}
		if first < count { msg.iov = iov[:] }
		if fd_count > 0 { msg.control = (cast([^]u8)&control)[:control.length] }
		n, err := linux.sendmsg(c.fd, &msg, {.DONTWAIT, .NOSIGNAL})
		if err == .EINTR { continue }
		if err != .NONE { return err }
		if n == 0 { return .EPIPE }
		for _ in 0..<fd_count { linux.close(fd_take(&c.fds_out)) }
		c.output.tail += uint(n)
	}
	return .NONE
}
connection_queue :: proc(c: ^Connection, bytes: []u8, fds: []linux.Fd) -> linux.Errno {
	if ring_size(&c.output)+len(bytes) > BUFFER_SIZE || int(c.fds_out.head-c.fds_out.tail) >= MAX_FDS_OUT {
		err := connection_flush(c)
		if err != .NONE && err != .EAGAIN { return err }
	}
	// With the default maximum, a stalled client can buffer at most 4096 bytes.
	if ring_size(&c.output)+len(bytes) > BUFFER_SIZE || int(c.fds_out.head-c.fds_out.tail)+len(fds) > len(c.fds_out.fds) { return .E2BIG }
	ring_put(&c.output, bytes)
	for fd in fds { fd_put(&c.fds_out, fd) }
	return .NONE
}
connection_read :: proc(c: ^Connection) -> (count: int, err: linux.Errno) {
	for ring_size(&c.input) < BUFFER_SIZE {
		space := BUFFER_SIZE-ring_size(&c.input)
		at := int(c.input.head % BUFFER_SIZE)
		first := min(space, BUFFER_SIZE-at)
		iov := [2]linux.IO_Vec{{&c.input.bytes[at], uint(first)}, {&c.input.bytes[0], uint(space-first)}}
		control: Control
		msg := linux.Msg_Hdr{iov = iov[:1], control = (cast([^]u8)&control)[:size_of(control)]}
		if first < space { msg.iov = iov[:] }
		n, read_error := linux.recvmsg(c.fd, &msg, {.DONTWAIT, .CMSG_CLOEXEC})
		if read_error == .EINTR { continue }
		if read_error == .EAGAIN && ring_size(&c.input) > 0 { break }
		if read_error != .NONE { return -1, read_error }
		if n == 0 { break }
		overflow := .CTRUNC in msg.flags
		for offset := 0; offset+16 <= len(msg.control); {
			header := cast(^Control)&msg.control[offset]
			length := int(header.length)
			if length < 16 || length > len(msg.control)-offset { return -1, .EINVAL }
			if header.level == SOL_SOCKET && header.kind == SCM_RIGHTS {
				fd_count := (length-16)/4
				for i in 0..<fd_count {
					fd := (cast([^]linux.Fd)&msg.control[offset+16])[i]
					if overflow || c.fds_in.head-c.fds_in.tail >= uint(len(c.fds_in.fds)) { linux.close(fd); overflow = true } else { fd_put(&c.fds_in, fd) }
				}
			}
			offset += (length+7)&~7
		}
		if overflow { return -1, .EOVERFLOW }
		c.input.head += uint(n)
		// Level-triggered readiness will report any bytes left in the socket.
		break
	}
	return ring_size(&c.input), .NONE
}
