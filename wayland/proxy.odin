package wayland

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

Proxy :: struct {
	id: u32,
	interface: ^Interface,
	version: u32,
	remote: ^Remote,
	data: rawptr,
	listener: proc(^Proxy, u32, []Argument),
	retired: bool,
}
Remote :: struct {
	wire: Connection,
	objects: map[u32]^Proxy,
	free_ids: [dynamic]u32,
	next_id: u32,
	source: ^Source,
	ctx: runtime.Context,
	depth: int,
	closed, failed: bool,
	data: rawptr,
	error: proc(rawptr),
}

remote_open :: proc(loop: ^Loop, name: string) -> ^Remote {
	path := name
	if path == "" { path = os.get_env("WAYLAND_DISPLAY", context.temp_allocator) }
	if path == "" { path = "wayland-0" }
	if !strings.has_prefix(path, "/") { path = fmt.tprintf("%s/%s", os.get_env("XDG_RUNTIME_DIR", context.temp_allocator), path) }
	address: linux.Sock_Addr_Un
	if len(path) >= len(address.sun_path) { return nil }
	address.sun_family = .UNIX
	copy(address.sun_path[:], path)
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, {})
	if err != .NONE { return nil }
	if linux.connect(fd, &address) != .NONE { linux.close(fd); return nil }
	c := remote_adopt(loop, fd)
	return c
}

remote_adopt :: proc(loop: ^Loop, fd: linux.Fd) -> ^Remote {
	c := new(Remote)
	c.wire.fd, c.ctx, c.next_id = fd, context, 2
	c.objects = make(map[u32]^Proxy)
	p := new(Proxy)
	p^ = {id=1, interface=core_interfaces.display, version=1, remote=c, listener=remote_display_event}
	c.objects[1] = p
	if loop != nil {
		c.source = loop_on_fd(loop, i32(fd), {.Readable}, remote_ready, c)
		if c.source == nil { remote_close(c); return nil }
	}
	return c
}

remote_free :: proc(c: ^Remote) {
	context = c.ctx
	for _, p in c.objects { free(p) }
	delete(c.objects); delete(c.free_ids); free(c)
}

remote_close :: proc(c: ^Remote) {
	if c == nil || c.closed { return }
	context = c.ctx
	c.closed = true
	source_remove(c.source); c.source = nil
	connection_close(&c.wire)
	if c.depth == 0 { remote_free(c) }
}

remote_fail :: proc(c: ^Remote, reason: string) {
	if c.failed || c.closed { return }
	c.failed = true
	fmt.eprintf("Wayland parent: %s\n", reason)
	if c.error != nil { c.error(c.data) }
}

proxy_new :: proc(c: ^Remote, iface: ^Interface, version: u32, listener: proc(^Proxy,u32,[]Argument) = nil, data: rawptr = nil) -> ^Proxy {
	if c.closed || c.failed { return nil }
	context = c.ctx
	id := c.next_id
	if len(c.free_ids) > 0 { id = pop(&c.free_ids) } else {
		if id >= SERVER_ID_START { remote_fail(c, "object ids exhausted"); return nil }
		c.next_id += 1
	}
	p := new(Proxy)
	p^ = {id=id, interface=iface, version=version, remote=c, listener=listener, data=data}
	c.objects[id] = p
	return p
}

proxy_release :: proc(p: ^Proxy, destructor: i32 = -1) {
	if p == nil || p.retired { return }
	c := p.remote
	c.depth += 1
	defer { c.depth -= 1; if c.closed && c.depth == 0 { remote_free(c) } }
	if destructor >= 0 { proxy_request(p, u32(destructor)) }
	p.retired, p.listener, p.data = true, nil, nil
	// Client ids cannot be reused until the server acknowledges their destruction.
	if p.id >= SERVER_ID_START { delete_key(&p.remote.objects,p.id); free(p) }
}

proxy_request :: proc(p: ^Proxy, opcode: u32, args: ..Argument) -> bool {
	if p == nil || p.retired { return false }
	c := p.remote
	c.depth += 1
	defer { c.depth -= 1; if c.closed && c.depth == 0 { remote_free(c) } }
	if c.closed || c.failed || opcode >= u32(p.interface.method_count) { return false }
	message := &p.interface.methods[opcode]
	if message_since(message) > i32(p.version) { return false }
	bytes: [BUFFER_SIZE]u8
	fds: [20]linux.Fd
	size, count, ok := encode(p.id, opcode, message, args, bytes[:], &fds)
	if !ok { return false }
	err := connection_queue(&c.wire, bytes[:size], fds[:count])
	if err != .NONE { for fd in fds[:count] { linux.close(fd) }; remote_fail(c,fmt.tprintf("request queue failed: %v",err)); return false }
	return remote_flush(c)
}

remote_flush :: proc(c: ^Remote) -> bool {
	if c.closed || c.failed { return false }
	err := connection_flush(&c.wire)
	if err != .NONE && err != .EAGAIN { remote_fail(c,fmt.tprintf("request flush failed: %v",err)); return false }
	if c.source != nil {
		mask := Mask{.Readable}
		if ring_size(&c.wire.output) > 0 { mask += {.Writable} }
		source_update_fd(c.source, mask)
	}
	return true
}

proxy_bind :: proc(registry: ^Proxy, name: u32, iface: ^Interface, version: u32, listener: proc(^Proxy,u32,[]Argument) = nil, data: rawptr = nil) -> ^Proxy {
	p := proxy_new(registry.remote, iface, version, listener, data)
	if p == nil { return nil }
	if !proxy_request(registry,0,Uint(name),String{value=string(iface.name)},Uint(version),Proxy_Object(p)) { proxy_release(p); return nil }
	return p
}

remote_display_event :: proc(p: ^Proxy, opcode: u32, args: []Argument) {
	c := p.remote
	if opcode == 0 { remote_fail(c, fmt.tprintf("protocol error %d: %s",args[1].(Uint),args[2].(String).value)); return }
	id := u32(args[0].(Uint))
	object := c.objects[id]
	if id < 2 || id >= SERVER_ID_START || object == nil || !object.retired { remote_fail(c,"invalid delete_id"); return }
	delete_key(&c.objects,id); free(object); append(&c.free_ids,id)
}

remote_resolve :: proc(id: u32, data: rawptr) -> ^Proxy { return (cast(^Remote)data).objects[id] }
remote_reserve :: proc(id: u32, data: rawptr) -> bool { return id >= SERVER_ID_START && (cast(^Remote)data).objects[id] == nil }

remote_dispatch :: proc(c: ^Remote) -> bool {
	c.depth += 1
	defer { c.depth -= 1; if c.closed && c.depth == 0 { remote_free(c) } }
	for !c.closed && !c.failed && ring_size(&c.wire.input) >= 8 {
		bytes: [BUFFER_SIZE]u8
		ring_copy(&c.wire.input,bytes[:8])
		id, header := word_read(bytes[:],0), word_read(bytes[:],4)
		size, opcode := int(header>>16), header&0xffff
		if size < 8 || size%4 != 0 || size > BUFFER_SIZE { remote_fail(c,"invalid event size"); break }
		if ring_size(&c.wire.input) < size { break }
		p := c.objects[id]
		if p == nil || opcode >= u32(p.interface.event_count) { remote_fail(c,"unknown event object or opcode"); break }
		message := &p.interface.events[opcode]
		if message_since(message) > i32(p.version) { remote_fail(c,"event exceeds negotiated version"); break }
		ring_copy(&c.wire.input,bytes[:size]); c.wire.input.tail += uint(size)
		args: [20]Argument
		count, ok := unmarshal(&c.wire,bytes[:size],message,&args,nil,remote_reserve,c,remote_resolve)
		if !ok { remote_fail(c,"invalid event arguments"); break }
		for arg,i in args[:count] {
			if child, is_new := arg.(New_Id); is_new {
				iface := message.types[i]
				if iface == nil { remote_fail(c,"untyped server object"); break }
				q := new(Proxy); q^ = {id=u32(child),interface=iface,version=min(p.version,u32(iface.version)),remote=c}
				c.objects[q.id] = q
			}
		}
		if !c.closed && !c.failed && !p.retired && p.listener != nil { p.listener(p,opcode,args[:count]) } else {
			for arg in args[:count] { if fd, is_fd := arg.(Fd); is_fd { linux.close(linux.Fd(fd)) } }
		}
	}
	return !c.closed && !c.failed
}

remote_ready :: proc(fd: i32, mask: Mask, data: rawptr) -> i32 {
	c := cast(^Remote)data
	context = c.ctx
	c.depth += 1
	defer { c.depth -= 1; if c.closed && c.depth == 0 { remote_free(c) } }
	if .Readable in mask {
		n, err := connection_read(&c.wire)
		if err != .NONE && err != .EAGAIN || n == 0 && err == .NONE { remote_fail(c,"connection closed"); return 0 }
		if !remote_dispatch(c) { return 0 }
	}
	if .Hangup in mask || .Error in mask { remote_fail(c,"connection lost"); return 0 }
	remote_flush(c)
	return 0
}

remote_sync_done :: proc(p: ^Proxy, opcode: u32, args: []Argument) {
	(cast(^bool)p.data)^ = true
	proxy_release(p)
}

remote_roundtrip :: proc(c: ^Remote) -> bool {
	c.depth += 1
	defer { c.depth -= 1; if c.closed && c.depth == 0 { remote_free(c) } }
	done := false
	p := proxy_new(c,core_interfaces.callback,1,remote_sync_done,&done)
	if p == nil || !proxy_request(c.objects[1],0,Proxy_Object(p)) { return false }
	deadline := monotonic_ns()+5_000_000_000
	for !done && !c.closed && !c.failed {
		if !remote_dispatch(c) || done { break }
		remaining := (deadline-monotonic_ns())/1_000_000
		if remaining <= 0 { remote_fail(c,"round trip timed out"); break }
		poll := [1]linux.Poll_Fd{{fd=c.wire.fd,events={.IN}}}
		if ring_size(&c.wire.output) > 0 { poll[0].events += {.OUT} }
		_, err := linux.poll(poll[:],i32(remaining))
		if err == .EINTR { continue }
		if err != .NONE { remote_fail(c,"poll failed"); break }
		mask: Mask
		if .IN in poll[0].revents { mask += {.Readable} }
		if .OUT in poll[0].revents { mask += {.Writable} }
		if .HUP in poll[0].revents { mask += {.Hangup} }
		if .ERR in poll[0].revents { mask += {.Error} }
		remote_ready(i32(c.wire.fd),mask,c)
	}
	if !done && !c.closed { proxy_release(p) }
	return done && !c.closed && !c.failed
}
