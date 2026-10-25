// Boots the real binary and drives it the way a user or a script does: a
// process, its IPC socket and the Lua API. Nothing here reaches into the
// compositor's packages, so the backend underneath can change without
// touching a test.
package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

ROOT :: #directory + "../"

// Headless draws into memory and needs no display. Nested draws inside the
// desktop this test runs on, so the same assertions see the real renderer.
Backend :: enum { Headless, Nested }

Session :: struct {
	process: os.Process,
	work: string,
	sock: string,
	log: string,
	env: [dynamic]string,
}

backend :: proc() -> Backend {
	if os.get_env("KILN_TEST_BACKEND", context.temp_allocator) == "nested" { return .Nested }
	return .Headless
}

// The one place the backend is named.
backend_env :: proc(b: Backend, env: ^[dynamic]string) {
	switch b {
	case .Headless:
		append(env, strings.clone("WLR_BACKENDS=headless"), strings.clone("WLR_LIBINPUT_NO_DEVICES=1"))
	case .Nested:
		outer := os.get_env("WAYLAND_DISPLAY", context.temp_allocator)
		dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
		append(env, strings.clone("WLR_BACKENDS=wayland"), fmt.aprintf("WAYLAND_DISPLAY=%s/%s", dir, outer))
	}
}

boot :: proc(t: ^testing.T, config: string) -> (s: Session, ok: bool) {
	s, ok = boot_start(t, config)
	// Cleanup must precede copying the returned Session, including its owned strings.
	if !ok { stop(&s) }
	return
}

boot_start :: proc(t: ^testing.T, config: string) -> (s: Session, ok: bool) {
	err: os.Error
	s.work, err = os.make_directory_temp("", "kiln-test-", context.allocator)
	if !testing.expect(t, err == nil, "temp dir") { return }
	runtime_dir := fmt.tprintf("%s/runtime", s.work)
	if derr := os.make_directory(runtime_dir, {.Read_User, .Write_User, .Execute_User}); derr != nil { testing.expectf(t, false, "runtime dir: %v", derr); return }
	rc := fmt.tprintf("%s/rc.lua", s.work)
	if werr := os.write_entire_file(rc, config); werr != nil { testing.expectf(t, false, "write rc: %v", werr); return }
	s.sock = fmt.aprintf("%s/eval.sock", s.work)
	s.log = fmt.aprintf("%s/server.log", s.work)

	// A private environment: no config, data or bus of the user's leaks in.
	for key in ([]string{"PATH", "USER", "TERM", "LANG", "DISPLAY"}) {
		if v, set := os.lookup_env(key, context.temp_allocator); set { append(&s.env, fmt.aprintf("%s=%s", key, v)) }
	}
	append(&s.env,
		fmt.aprintf("HOME=%s/home", s.work),
		fmt.aprintf("XDG_RUNTIME_DIR=%s", runtime_dir),
		fmt.aprintf("XDG_CONFIG_HOME=%s/config", s.work),
		fmt.aprintf("XDG_DATA_HOME=%s/data", s.work),
		fmt.aprintf("XDG_CACHE_HOME=%s/cache", s.work),
		fmt.aprintf("DBUS_SESSION_BUS_ADDRESS=unix:path=%s/absent-bus", runtime_dir),
		fmt.aprintf("KILN_RC=%s", rc),
		fmt.aprintf("KILN_SOCK=%s", s.sock))
	backend_env(backend(), &s.env)

	log, lerr := os.open(s.log, {.Write, .Create, .Trunc}, os.Permissions_Default)
	if !testing.expect(t, lerr == nil, "log file") { return }
	defer os.close(log)
	s.process, err = os.process_start({
		command = {ROOT + "build/kiln"}, env = s.env[:], working_dir = ROOT,
		stdout = log, stderr = log,
	})
	if !testing.expectf(t, err == nil, "start build/kiln: %v", err) { return }
	ok = wait_until(t, proc(s: ^Session) -> bool { return strings.contains(read_log(s), "Running Wayland compositor") }, &s, "compositor ready")
	if !ok { return }
	// Nested, the first frame only arrives once the parent shows the window.
	ok = wait_until(t, proc(s: ^Session) -> bool { return strings.contains(read_log(s), "First frame committed") }, &s,
		"first frame (nested: the parent must show the window, so a tag or rule that hides it blocks every test)")
	return
}

read_log :: proc(s: ^Session) -> string {
	data, _ := os.read_entire_file(s.log, context.temp_allocator)
	return string(data)
}

running :: proc(s: ^Session) -> bool {
	if s.process.pid <= 0 { return false }
	state, err := os.process_wait(s.process, 0)
	if state.exited || (err != nil && err != .Timeout) { s.process = {}; return false }
	return true
}

wait_until :: proc(t: ^testing.T, done: proc(^Session) -> bool, s: ^Session, what: string, timeout := 10 * time.Second) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if done(s) { return true }
		if !running(s) {
			testing.expectf(t, false, "%s: compositor exited\n%s", what, read_log(s))
			return false
		}
		time.sleep(25 * time.Millisecond)
	}
	testing.expectf(t, false, "%s: timeout\n%s", what, read_log(s))
	return false
}

// Send-then-EOF: the compositor evaluates on half-close and writes one reply.
eval :: proc(s: ^Session, source: string, allocator := context.temp_allocator) -> string {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 { return "<socket failed>" }
	defer posix.close(fd)
	address: posix.sockaddr_un
	address.sun_family = .UNIX
	copy(address.sun_path[:], s.sock)
	if posix.connect(fd, cast(^posix.sockaddr)&address, size_of(address)) != .OK { return "<connect failed>" }
	sent := 0
	for sent < len(source) {
		remaining := len(source) - sent
		n := int(posix.write(fd, raw_data(source[sent:]), uint(remaining)))
		if n <= 0 { return "<write failed>" }
		sent += n
	}
	posix.shutdown(fd, .WR)
	reply := strings.builder_make(allocator)
	buffer: [4096]u8
	for {
		n := posix.read(fd, &buffer[0], len(buffer))
		if n <= 0 { break }
		strings.write_bytes(&reply, buffer[:n])
	}
	return strings.to_string(reply)
}

expect_eval :: proc(t: ^testing.T, s: ^Session, source, want: string, loc := #caller_location) -> bool {
	got := eval(s, source)
	return testing.expectf(t, got == want, "%s\n  want %q\n  got  %q", source, want, got, loc = loc)
}

// Polls an expression until it answers as expected, for facts that settle a
// frame or two after the verb that causes them.
expect_eventually :: proc(t: ^testing.T, s: ^Session, source, want: string, loc := #caller_location) -> bool {
	start := time.tick_now()
	got := ""
	for time.tick_since(start) < 10 * time.Second {
		got = eval(s, source)
		if got == want { return true }
		if !running(s) { break }
		time.sleep(30 * time.Millisecond)
	}
	testing.expectf(t, false, "%s\n  want %q\n  last %q", source, want, got, loc = loc)
	return false
}

// A clean quit is part of every test: exit 0, no assertion in the log, and
// the socket removed by its owner.
quit :: proc(t: ^testing.T, s: ^Session) {
	defer stop(s)
	if !running(s) { return }
	expect_eval(t, s, "core.quit()", "\n")
	state, _ := os.process_wait(s.process, 5 * time.Second)
	if state.exited { s.process = {} }
	log := read_log(s)
	testing.expectf(t, state.exited && state.exit_code == 0, "quit: exited %v code %d\n%s", state.exited, state.exit_code, log)
	testing.expect(t, !strings.contains(log, "Assertion"), "assertion in log")
	testing.expect(t, !os.exists(s.sock), "socket leaked")
}

stop :: proc(s: ^Session) {
	if running(s) {
		_ = os.process_terminate(s.process)
		state, _ := os.process_wait(s.process, 5 * time.Second)
		if !state.exited {
			_ = os.process_kill(s.process)
			_, _ = os.process_wait(s.process, 5 * time.Second)
		}
	}
	if s.work != "" { os.remove_all(s.work) }
	for e in s.env { delete(e) }
	delete(s.env)
	delete(s.work)
	delete(s.sock)
	delete(s.log)
	s^ = {}
}
