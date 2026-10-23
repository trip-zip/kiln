package compositor

import "core:os"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

start_command :: proc(s: ^Server, socket, command: string) -> bool {
	if os.set_env("WAYLAND_DISPLAY", socket) != nil { return false }
	// Wayland blocks termination signals for signalfd. Children need ordinary delivery.
	empty, previous: posix.sigset_t
	posix.sigemptyset(&empty)
	if posix.sigprocmask(.SETMASK, &empty, &previous) != .OK { return false }
	defer posix.sigprocmask(.SETMASK, &previous, nil)
	child, err := os.process_start({command = []string{"/bin/sh", "-c", command},
		stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if err != nil { return false }
	s.startup, s.startup_running = child, true
	return true
}

startup_exited :: proc(number: linux.Signal, data: rawptr) -> i32 {
	s := (^Server)(data)
	if s.startup_running {
		_, err := os.process_wait(s.startup, timeout = 0)
		if err != .Timeout { s.startup_running = false }
	}
	return 0
}

finish_startup :: proc(s: ^Server) {
	if !s.startup_running { return }
	_, err := os.process_wait(s.startup, timeout = time.Second)
	if err == .Timeout {
		_ = os.process_terminate(s.startup)
		_, err = os.process_wait(s.startup, timeout = time.Second)
		if err == .Timeout {
			_ = os.process_kill(s.startup)
			_, _ = os.process_wait(s.startup)
		}
	}
}
