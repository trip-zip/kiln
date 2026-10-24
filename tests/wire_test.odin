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
	for entry in s.env {if !strings.has_prefix(entry, "WAYLAND_DISPLAY=") && !strings.has_prefix(entry, "WAYLAND_DEBUG=") {append(&env, entry)}}
	append(&env, fmt.tprintf("WAYLAND_DISPLAY=kiln-%d", s.process.pid), "WAYLAND_DEBUG=client")
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
	trace, trace_err := os.read_entire_file(fmt.tprintf("%s/foot.log", s.work), context.temp_allocator)
	testing.expect(t, trace_err == nil)
	for protocol in ([]string{"zxdg_output_manager_v1", "wp_cursor_shape_manager_v1", "xdg_activation_v1"}) {
		bound := false
		for line in strings.split_lines(string(trace), context.temp_allocator) {
			if strings.contains(line, ".bind(") && strings.contains(line, fmt.tprintf("\"%s\"", protocol)) {
				bound = true
				fmt.printf("Foot %v bind: %s\n", backend(), line)
			}
		}
		testing.expectf(t, bound, "foot bound %s", protocol)
	}
	testing.expect(t, strings.contains(string(trace), ".logical_size("), "foot received xdg-output details")
	if directory := os.get_env("KILN_TEST_ARTIFACTS", context.temp_allocator); directory != "" {
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%v-foot.log", directory, backend()), trace) == nil)
	}

}
