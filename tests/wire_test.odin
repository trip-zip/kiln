package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
foot_maps_and_disconnects_over_the_wire :: proc(t: ^testing.T) {
	rc, _ := os.read_entire_file(ROOT + "kilnrc.lua", context.temp_allocator)
	s, ok := boot(t, string(rc))
	if !ok {stop(&s); return}
	defer quit(t, &s)

	env := make([dynamic]string, 0, len(s.env) + 1, context.temp_allocator)
	// The nested parent's display belongs to the server, not its clients.
	for entry in s.env {if !strings.has_prefix(entry, "WAYLAND_DISPLAY=") {append(&env, entry)}}
	append(&env, fmt.tprintf("WAYLAND_DISPLAY=kiln-%d", s.process.pid))
	log, err := os.open(
		fmt.tprintf("%s/foot.log", s.work),
		{.Write, .Create},
		os.Permissions_Default,
	)
	if !testing.expect(t, err == nil) {return}
	defer os.close(log)
	child, start_error := os.process_start(
		{
			command = {
				"foot",
				"--config=/dev/null",
				"--app-id=kiln-wire-test",
				"sh",
				"-c",
				"sleep 60",
			},
			env = env[:],
			stdout = log,
			stderr = log,
		},
	)
	if !testing.expectf(t, start_error == nil, "foot: %v", start_error) {return}
	child_finished := false
	defer if !child_finished {_ = os.process_kill(child); _, _ = os.process_wait(child, time.Second)}
	if !expect_eventually(t, &s, "return #client.all()", "1\n") {return}
	expect_eval(t, &s, "return client.all()[1].app_id", "kiln-wire-test\n")
	time.sleep(time.Second)
	expect_eval(t, &s, "client.all()[1]:close()", "\n")
	expect_eventually(t, &s, "return #client.all()", "0\n")
	state, _ := os.process_wait(child, 5 * time.Second)
	child_finished = state.exited
	testing.expect(t, state.exited, "foot acknowledged close")
	testing.expect(
		t,
		!strings.contains(read_log(&s), "protocol error") && !strings.contains(read_log(&s), "error in client communication"),
		"protocol error in compositor log",
	)
}
