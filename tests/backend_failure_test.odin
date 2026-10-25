package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
rejected_frame_tears_down_without_an_assert :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "kiln-rejected-frame-", context.allocator)
	if !testing.expect(t, err == nil) { return }
	defer { os.remove_all(dir); delete(dir) }
	binary := fmt.tprintf("%s/kiln", dir)
	compiler, start_error := os.process_start({command = {"odin", "build", ROOT,
		"-define:KILN_OUTPUT_FIXTURE=true", fmt.tprintf("-out:%s", binary),
		"-extra-linker-flags:-Wl,--export-dynamic"}})
	if !testing.expect(t, start_error == nil) { return }
	built, _ := os.process_wait(compiler)
	if !testing.expect_value(t, built.exit_code, 0) { return }
	rc, _ := os.read_entire_file(ROOT+"kilnrc.lua", context.temp_allocator)
	s, ok := boot(t, string(rc), binary)
	if !ok { stop(&s); return }
	defer stop(&s)
	expect_eval(t, &s, `local ffi=require('ffi');ffi.cdef[[bool kiln_test_output(int,const char*,int,int);]];return ffi.C.kiln_test_output(10,core.output.list()[1].name,0,0)`, "true\n")
	state, _ := os.process_wait(s.process, 10*time.Second)
	if state.exited { s.process = {} }
	log := read_log(&s)
	testing.expect(t, state.exited && state.exit_code == 1, log)
	testing.expect(t, strings.contains(log, "Failed to commit output frame"), log)
	testing.expect(t, !strings.contains(log, "Assertion") && !strings.contains(log, "assertion"), log)
	testing.expect(t, strings.contains(log, "Paint cleanup: live buffers 0, live bytes 0"), log)
	testing.expect(t, !os.exists(s.sock), "failed compositor removed its private socket")
	if directory := os.get_env("KILN_TEST_ARTIFACTS", context.temp_allocator); directory != "" {
		_ = os.write_entire_file(fmt.tprintf("%s/%v-rejected-frame.log", directory, backend()), log)
	}
}
