package wayland

import "core:sys/linux"

Int :: distinct i32
Uint :: distinct u32
String :: struct { value: string, is_null: bool }
Object :: distinct ^Resource
New_Id :: distinct u32
Fd :: distinct i32
Argument :: union { Int, Uint, Fixed, String, Object, New_Id, Array, Fd }
Signature :: struct { text: string, cursor: int }
argument_next :: proc(s: ^Signature) -> (kind: u8, nullable, ok: bool) {
	for s.cursor < len(s.text) {
		c := s.text[s.cursor]; s.cursor += 1
		if c == '?' { nullable = true; continue }
		if '0' <= c && c <= '9' { continue }
		return c, nullable, true
	}
	return
}
message_since :: proc(message: ^Message) -> (version: i32) {
	for c in string(message.signature) {
		if c < '0' || c > '9' { break }
		version = version*10 + i32(c-'0')
	}
	return max(version, 1)
}
word_read :: proc(bytes: []u8, at: int) -> u32 { return (cast(^u32)&bytes[at])^ }
word_write :: proc(bytes: []u8, at: int, value: u32) { (cast(^u32)&bytes[at])^ = value }
encode :: proc(id, opcode: u32, message: ^Message, args: []Argument, bytes: []u8, fds: ^[20]linux.Fd) -> (size, fd_count: int, ok: bool) {
	assert(len(bytes) >= 8)
	size = 8
	signature := Signature{text = string(message.signature)}
	index := 0
	defer if !ok { for fd in fds[:fd_count] { linux.close(fd) }; fd_count = 0 }
	for {
		kind, nullable, more := argument_next(&signature)
		if !more { break }
		assert(index < len(args))
		arg := args[index]; index += 1
		if kind == 'h' {
			fd, tag_ok := arg.(Fd); assert(tag_ok)
			duplicate, err := linux.fcntl(linux.Fd(fd), linux.F_DUPFD_CLOEXEC, 0)
			if err != .NONE { return }
			fds[fd_count] = duplicate; fd_count += 1
			continue
		}
		if size+4 > len(bytes) { return }
		value: u32
		payload: []u8
		is_string := false
		switch kind {
		case 'i': v, good := arg.(Int); assert(good); value = u32(v)
		case 'u': v, good := arg.(Uint); assert(good); value = u32(v)
		case 'f': v, good := arg.(Fixed); assert(good); value = u32(v)
		case 'o', 'n':
			v, good := arg.(Object); assert(good)
			assert(v != nil || nullable && kind == 'o')
			if v != nil { value = v.id }
		case 's':
			v, good := arg.(String); assert(good)
			assert(!v.is_null || nullable)
			if !v.is_null { payload = transmute([]u8)v.value; value = u32(len(payload)+1); is_string = true }
		case 'a':
			v, good := arg.(Array); assert(good)
			if v.size > uint(len(bytes)) { return }
			payload = (cast([^]u8)v.data)[:v.size]; value = u32(v.size)
		case: panic("invalid protocol signature")
		}
		word_write(bytes, size, value); size += 4
		if kind == 's' || kind == 'a' {
			padded := (int(value)+3)&~3
			if padded > len(bytes)-size { return }
			copy(bytes[size:], payload)
			for at in size+len(payload)..<size+padded { bytes[at] = 0 }
			if is_string { bytes[size+len(payload)] = 0 }
			size += padded
		}
	}
	assert(index == len(args))
	word_write(bytes, 0, id); word_write(bytes, 4, u32(size)<<16 | opcode)
	ok = true
	return
}
Resolve :: #type proc(u32, rawptr) -> ^Resource
Reserve :: #type proc(u32, rawptr) -> bool
unmarshal :: proc(c: ^Connection, bytes: []u8, message: ^Message, args: ^[20]Argument, resolve: Resolve, reserve: Reserve, data: rawptr) -> (count: int, ok: bool) {
	signature := Signature{text = string(message.signature)}
	at := 8
	defer if !ok {
		for arg in args[:count] { if fd, is_fd := arg.(Fd); is_fd { linux.close(linux.Fd(fd)) } }
	}
	for {
		kind, nullable, more := argument_next(&signature)
		if !more { break }
		if count == len(args) { return }
		index := count
		if kind == 'h' {
			if c.fds_in.head == c.fds_in.tail { return }
			args[index] = Fd(fd_take(&c.fds_in)); count += 1; continue
		}
		if at+4 > len(bytes) { return }
		value := word_read(bytes, at); at += 4
		switch kind {
		case 'i': args[index] = Int(value)
		case 'u': args[index] = Uint(value)
		case 'f': args[index] = Fixed(value)
		case 's', 'a':
			padded := (u64(value)+3)&~u64(3)
			if padded > u64(len(bytes)-at) { return }
			// Views into the receive scratch buffer expire when the handler returns.
			if kind == 's' {
				if value == 0 { if !nullable { return }; args[index] = String{is_null = true} } else {
					if bytes[at+int(value)-1] != 0 { return }
					for b in bytes[at:at+int(value)-1] { if b == 0 { return } }
					args[index] = String{value = string(bytes[at:at+int(value)-1])}
				}
			} else { args[index] = Array{size = uint(value), data = raw_data(bytes[at:])} }
			at += int(padded)
		case 'o':
			if value == 0 && !nullable { return }
			object: ^Resource
			if value != 0 { object = resolve(value, data); if object == nil { return } }
			iface := message.types[index]
			if object != nil && iface != nil && !interface_equal(object.interface, iface) { return }
			args[index] = Object(object)
		case 'n':
			if value == 0 || !reserve(value, data) { return }
			args[index] = New_Id(value)
		case: return
		}
		count += 1
	}
	ok = true
	return
}
interface_equal :: proc(a, b: ^Interface) -> bool { return a == b || a != nil && b != nil && string(a.name) == string(b.name) }
