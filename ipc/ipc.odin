package ipc

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import wl "../wayland"

Server :: struct {
	display: ^wl.Display,
	fd: posix.FD,
	source: ^wl.Event_Source,
	path: cstring,
	identity: posix.stat_t,
	owned: bool,
	clients: [dynamic]^Client,
	data: rawptr,
	evaluate: proc(rawptr, string) -> string,
}
Client :: struct {
	server: ^Server,
	source: ^wl.Event_Source,
	fd: posix.FD,
	request: [dynamic]u8,
	reply: string,
	sent: int,
	writing: bool,
}
#assert(size_of(posix.sockaddr_un) == 110)
#assert(offset_of(posix.sockaddr_un, sun_family) == 0)
#assert(offset_of(posix.sockaddr_un, sun_path) == 2)

socket_path :: proc() -> string {
	path, set := os.lookup_env("KILN_SOCK", context.allocator)
	if set { return path }
	delete(path)
	dir, found := os.lookup_env("XDG_RUNTIME_DIR", context.allocator)
	defer delete(dir)
	return fmt.aprintf("%s/kiln.sock", dir if found else "/tmp")
}
configure_fd :: proc(fd: posix.FD) -> bool {
	return posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC) == 0 &&
		   posix.fcntl(fd, .SETFL, posix.O_NONBLOCK) == 0
}
init :: proc(s: ^Server, display: ^wl.Display, path: string,
			 evaluate: proc(rawptr, string) -> string, data: rawptr) -> bool {
	s.fd = -1
	s.display, s.evaluate, s.data = display, evaluate, data
	if len(path) == 0 || len(path) >= 108 { return false }
	s.path = strings.clone_to_cstring(path)
	s.fd = posix.socket(.UNIX, .STREAM)
	if s.fd < 0 || !configure_fd(s.fd) { return false }
	address: posix.sockaddr_un
	address.sun_family = .UNIX
	copy(address.sun_path[:], path)
	// Never unlink to make bind succeed: the existing name may have an owner.
	old_mask := posix.umask({.IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH})
	result := posix.bind(s.fd, cast(^posix.sockaddr)&address, size_of(address))
	posix.umask(old_mask)
	if result != .OK { return false }
	if posix.lstat(s.path, &s.identity) != .OK { return false }
	s.owned = true
	if posix.chmod(s.path, {.IRUSR, .IWUSR}) != .OK || posix.listen(s.fd, 4) != .OK { return false }
	s.source = wl.on_fd(display, i32(s.fd), wl.READABLE, connection, s)
	if s.source == nil { return false }
	return os.set_env("KILN_SOCK", path) == nil
}
destroy :: proc(s: ^Server) {
	for len(s.clients) > 0 { close_client(s.clients[len(s.clients)-1]) }
	delete(s.clients)
	wl.remove_source(s.source)
	if s.path != nil {
		if s.fd >= 0 { posix.close(s.fd) }
		now: posix.stat_t
		if s.owned && posix.lstat(s.path, &now) == .OK &&
		   now.st_dev == s.identity.st_dev && now.st_ino == s.identity.st_ino {
			posix.unlink(s.path)
		}
		delete(s.path)
	}
	s^ = {}
}
close_client :: proc(client: ^Client) {
	s := client.server
	for item, i in s.clients {
		if item == client { unordered_remove(&s.clients, i); break }
	}
	wl.remove_source(client.source)
	posix.close(client.fd)
	delete(client.request)
	delete(client.reply)
	free(client)
}
connection :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
	s := (^Server)(data)
	peer := posix.accept(posix.FD(fd), nil, nil)
	if peer < 0 { return 0 }
	if !configure_fd(peer) { posix.close(peer); return 0 }
	client := new(Client)
	client.server, client.fd = s, peer
	client.source = wl.on_fd(s.display, i32(peer), wl.READABLE, ready, client)
	if client.source == nil { posix.close(peer); free(client); return 0 }
	append(&s.clients, client)
	return 0
}
flush :: proc(client: ^Client) {
	// Bound work per dispatch even when a reader drains a very large reply.
	left := len(client.reply)-client.sent
	if left == 0 { close_client(client); return }
	n := posix.send(client.fd, raw_data(client.reply[client.sent:]), c.size_t(min(left, 65536)), {.NOSIGNAL})
	if n > 0 {
		client.sent += int(n)
		if client.sent == len(client.reply) { close_client(client) }
	} else if n == 0 || (posix.errno() != .EAGAIN && posix.errno() != .EINTR) {
		close_client(client)
	}
}
ready :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
	client := (^Client)(data)
	if client.writing { flush(client); return 0 }
	chunk: [4096]u8
	n := posix.read(client.fd, raw_data(chunk[:]), len(chunk))
	if n > 0 { append(&client.request, ..chunk[:int(n)]); return 0 }
	if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EINTR) { return 0 }
	if n < 0 || len(client.request) == 0 { close_client(client); return 0 }
	client.reply = client.server.evaluate(client.server.data, string(client.request[:]))
	client.writing = true
	if !wl.update_fd(client.source, wl.WRITABLE) { close_client(client); return 0 }
	flush(client)
	return 0
}
