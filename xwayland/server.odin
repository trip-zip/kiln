package xwayland

import seat "../seat"
import wl "../wayland"
import p "../protocols"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

Server :: struct {
 seat: ^seat.Seat,
	display: ^wl.Display,
	global: ^wl.Global,
	client: ^wl.Client,
	display_name: string,
	number: int,
	sockets: [2]linux.Fd,
	socket_sources: [2]^wl.Source,
	wm_fd, ready_fd, pid_fd: linux.Fd,
	ready_source, exit_source, retry_source: ^wl.Source,
	pid: posix.pid_t,
	ready, destroying: bool,
	started: i64,
	client_destroy, display_destroy: wl.Listener,
	events: struct { ready, new_window, destroy: wl.Signal },
	xwm: ^Xwm,
	shells: [dynamic]^Shell_Surface,
	resources: [dynamic]^wl.Resource,
	last_serial: u64,
}
cstr :: proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }
close_fd :: proc(fd: ^linux.Fd) { if fd^ >= 0 { linux.close(fd^); fd^ = -1 } }
lock_path :: proc(root: string, n: int) -> cstring { return cstr(fmt.tprintf("%s/.X%d-lock", root, n)) }
socket_path :: proc(root: string, n: int) -> string { return fmt.tprintf("%s/.X11-unix/X%d", root, n) }
lock_stale :: proc(path: cstring) -> bool {
	fd, err := linux.open(path, {.CLOEXEC}, {})
	if err != .NONE { return false }; defer linux.close(fd)
	bytes: [12]u8; n, read_err := linux.read(fd, bytes[:])
	if read_err != .NONE || n != 11 { return false }
	pid, ok := strconv.parse_i64(strings.trim_space(string(bytes[:10])))
	if !ok || pid <= 0 || pid > i64(max(i32)) { return false }
	return posix.kill(posix.pid_t(pid), cast(posix.Signal)0) != .OK && posix.errno() == .ESRCH
}
reserve_display :: proc(root := "/tmp") -> (number: int, sockets: [2]linux.Fd, ok: bool) {
	number, sockets = -1, {-1, -1}
	dir := cstr(fmt.tprintf("%s/.X11-unix", root))
	if posix.mkdir(dir, transmute(posix.mode_t)u32(0o755)) != .OK && posix.errno() != .EEXIST { return }
	st: posix.stat_t
	if posix.lstat(dir, &st) != .OK || st.st_mode&posix.S_IFMT != posix.S_IFDIR || (st.st_uid != 0 && st.st_uid != posix.getuid()) { return }
	if st.st_mode&transmute(posix.mode_t)u32(0o1000) == {} && st.st_mode&transmute(posix.mode_t)u32(0o022) != {} { return }
	for n in 0..<33 {
		path := lock_path(root, n)
		fd, err := linux.open(path, {.WRONLY, .CREAT, .EXCL, .CLOEXEC}, transmute(linux.Mode)u32(0o444))
		if err != .NONE && lock_stale(path) { linux.unlink(path); fd, err = linux.open(path, {.WRONLY, .CREAT, .EXCL, .CLOEXEC}, transmute(linux.Mode)u32(0o444)) }
		if err != .NONE { continue }
		good, filesystem_bound := true, false
		name := socket_path(root, n)
		for i in 0..<2 {
			sock, e := linux.socket(linux.Address_Family(linux.Protocol_Family.UNIX), .STREAM, {.CLOEXEC}, {})
			if e != .NONE { good = false; break }; sockets[i] = sock
			address := linux.Sock_Addr_Un{sun_family=linux.Address_Family(linux.Protocol_Family.UNIX)}
			start := 1 if i == 0 else 0
			if len(name)+start >= len(address.sun_path) { good = false; break }
			copy(address.sun_path[start:], name)
			if i == 1 { linux.unlink(cstr(name)) }
			// Abstract socket names include every supplied byte, unlike filesystem paths.
			if linux.syscall(linux.SYS_bind, sock, &address, 2+len(name)+1) < 0 { good = false; break }
			if i == 1 { filesystem_bound = true }
			if linux.listen(sock,1) != .NONE { good = false; break }
		}
		text := fmt.tprintf("%10d", posix.getpid()); bytes: [11]u8; copy(bytes[:], text)
		written, write_err := linux.write(fd, bytes[:]); linux.close(fd)
		if good && write_err == .NONE && written == 11 { return n, sockets, true }
		for &sock in sockets { close_fd(&sock) }; linux.unlink(path)
		if filesystem_bound { linux.unlink(cstr(name)) }
	}
	return
}
release_display :: proc(number: int, sockets: ^[2]linux.Fd, root := "/tmp") {
	for &fd in sockets { close_fd(&fd) }
	if number >= 0 { linux.unlink(lock_path(root, number)); linux.unlink(cstr(socket_path(root, number))) }
}
server_create :: proc(display: ^wl.Display) -> ^Server {
	n, sockets, ok := reserve_display(); if !ok { return nil }
	s := new(Server); s.display, s.number, s.sockets = display, n, sockets
	s.wm_fd, s.ready_fd, s.pid_fd = -1, -1, -1
	s.display_name = fmt.aprintf(":%d", n)
	wl.signal_init(&s.events.ready); wl.signal_init(&s.events.new_window); wl.signal_init(&s.events.destroy)
	s.global = wl.global_create(display, &p.xwayland_shell_v1, 1, s, shell_bind)
	wl.listen(&display.destroy_signal, &s.display_destroy, server_display_destroy)
	if s.global == nil || !server_lazy(s) { server_destroy(s); return nil }; return s
}
server_lazy :: proc(s: ^Server) -> bool {
	for i in 0..<2 { s.socket_sources[i] = wl.loop_on_fd(s.display.loop, i32(s.sockets[i]), {.Readable}, server_connected, s) }
	return s.socket_sources[0] != nil && s.socket_sources[1] != nil
}
server_connected :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
	s := cast(^Server)data
	for &source in s.socket_sources { wl.source_remove(source); source = nil }
	if !server_start(s) { fmt.eprintln("Xwayland startup failed; disabling X11"); server_destroy(s) }
	return 0
}
server_start :: proc(s: ^Server) -> bool {
	way, wm, ready: [2]linux.Fd
	way, wm, ready = {-1,-1}, {-1,-1}, {-1,-1}
	defer { for &fd in way { close_fd(&fd) }; for &fd in wm { close_fd(&fd) }; for &fd in ready { close_fd(&fd) } }
	for pair in ([]^[2]linux.Fd{&way, &wm}) {
		if linux.socketpair(.UNIX, .STREAM, {}, pair) != .NONE { return false }
		for fd in pair { if posix.fcntl(posix.FD(fd), .SETFD, i32(posix.FD_CLOEXEC)) < 0 { return false } }
	}
	if linux.pipe2(&ready, {.CLOEXEC, .NONBLOCK}) != .NONE { return false }
	s.client = wl.client_create(s.display, i32(way[0])); if s.client == nil { return false }; way[0] = -1
	wl.listen(&s.client.destroy_signal, &s.client_destroy, server_client_destroy)
	s.wm_fd, s.ready_fd = wm[0], ready[0]; wm[0], ready[0] = -1, -1
	s.ready_source = wl.loop_on_fd(s.display.loop, i32(s.ready_fd), {.Readable}, server_ready, s)
	if s.ready_source == nil { return false }
	executable := os.get_env("WLR_XWAYLAND", context.temp_allocator); if executable == "" { executable = "Xwayland" }
	argv := [17]cstring{cstr(executable), cstr(s.display_name), "-rootless", "-core", "-terminate", "10", "-listenfd", cstr(fmt.tprintf("%d",s.sockets[0])), "-listenfd", cstr(fmt.tprintf("%d",s.sockets[1])), "-displayfd", cstr(fmt.tprintf("%d",ready[1])), "-wm", cstr(fmt.tprintf("%d",wm[1])), "-noTouchPointerEmulation", "-force-xrandr-emulation", nil}
	way_socket := cstr(fmt.tprintf("%d", way[1]))
	s.started = wl.monotonic_ns()
	s.pid = posix.fork()
	if s.pid == 0 {
		for fd in ([5]linux.Fd{s.sockets[0],s.sockets[1],way[1],wm[1],ready[1]}) { if posix.fcntl(posix.FD(fd), .SETFD, i32(0)) < 0 { posix._exit(127) } }
		posix.setenv("WAYLAND_SOCKET", way_socket, true)
		empty: posix.sigset_t; posix.sigemptyset(&empty); posix.sigprocmask(.SETMASK, &empty, nil)
		posix.execvp(argv[0], &argv[0]); posix._exit(127)
	}
	if s.pid < 0 { return false }
	pidfd, err := linux.pidfd_open(linux.Pid(s.pid), {})
	if err == .NONE { s.pid_fd = linux.Fd(pidfd); s.exit_source = wl.loop_on_fd(s.display.loop, i32(pidfd), {.Readable}, server_exited, s) }
	if s.exit_source == nil { s.retry_source = wl.loop_on_timer(s.display.loop, server_reap, s); wl.source_arm_timer(s.retry_source, 100_000_000) }
	return true
}
server_ready :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
	s := cast(^Server)data; bytes: [64]u8
	n, err := linux.read(linux.Fd(fd), bytes[:])
	if err == .EAGAIN || err == .EINTR { return 0 }
	if n <= 0 { server_finish_process(s); return 0 }
	if !strings.contains(string(bytes[:n]), "\n") { return 0 }
	wl.source_remove(s.ready_source); s.ready_source = nil
	// Retain the read end until exit so a second readiness write cannot raise SIGPIPE.
	wm := s.wm_fd; s.wm_fd = -1
	s.xwm = xwm_create(s, i32(wm))
	if s.xwm == nil { server_finish_process(s); return 0 }
	s.ready = true; wl.signal_emit_mutable(&s.events.ready, s); return 0
}
server_finish_process :: proc(s: ^Server) {
	s.ready = false
	if s.xwm != nil { xwm_destroy(s.xwm); s.xwm = nil }
	wl.source_remove(s.ready_source); s.ready_source = nil
	close_fd(&s.ready_fd); close_fd(&s.wm_fd)
	if s.client != nil { c := s.client; s.client = nil; wl.unlisten(&s.client_destroy); wl.client_destroy(c) }
	s.last_serial = 0
}
server_client_destroy :: proc(l: ^wl.Listener, data: rawptr) {
	s := wl.owner(l, Server, "client_destroy"); wl.unlisten(l); s.client = nil
	server_finish_process(s)
	// Wait for the old server to release its sockets before allowing the next spawn.
	if s.pid <= 0 && !s.destroying && !server_lazy(s) { server_destroy(s) }
}
server_exited :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
	s := cast(^Server)data
	posix.waitpid(s.pid, nil, {.NOHANG}); s.pid = 0
	wl.source_remove(s.exit_source); s.exit_source = nil; close_fd(&s.pid_fd)
	server_finish_process(s)
	if !s.destroying {
		if wl.monotonic_ns()-s.started < 5_000_000_000 {
			s.retry_source = wl.loop_on_timer(s.display.loop, server_retry, s); wl.source_arm_timer(s.retry_source, 1_000_000_000)
		} else if !server_lazy(s) { server_destroy(s) }
	}; return 0
}
server_reap :: proc(data: rawptr) -> i32 {
	s := cast(^Server)data
	if posix.waitpid(s.pid,nil,{.NOHANG}) == 0 { wl.source_arm_timer(s.retry_source,100_000_000); return 0 }
	wl.source_remove(s.retry_source); s.retry_source = nil
	return server_exited(-1,{},s)
}
server_retry :: proc(data: rawptr) -> i32 {
	s := cast(^Server)data; wl.source_remove(s.retry_source); s.retry_source = nil
	if !server_lazy(s) { server_destroy(s) }; return 0
}
server_display_destroy :: proc(l: ^wl.Listener, data: rawptr) { server_destroy(wl.owner(l, Server, "display_destroy")) }
server_destroy :: proc(s: ^Server) {
	s.destroying = true; wl.unlisten(&s.display_destroy)
	for source in s.socket_sources { wl.source_remove(source) }
	server_finish_process(s)
	wl.source_remove(s.exit_source); wl.source_remove(s.retry_source); close_fd(&s.pid_fd)
	if s.pid > 0 { posix.waitpid(s.pid, nil, {.NOHANG}) }
	for len(s.shells) > 0 { shell_retire(s.shells[len(s.shells)-1]) }
	for len(s.resources) > 0 { wl.resource_destroy(s.resources[len(s.resources)-1]) }
	if s.global != nil { wl.global_destroy(s.global) }
	release_display(s.number, &s.sockets)
	wl.signal_emit_final(&s.events.destroy, s)
	delete(s.resources); delete(s.shells); delete(s.display_name); free(s)
}
