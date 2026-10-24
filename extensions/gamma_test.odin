package extensions

import "../cairo"
import paint "../paint"
import "../readback"
import sp "../scene_paint"
import wl "../wayland"
import wlr "../wlroots"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

gamma_test_changed :: proc(data: rawptr, output: ^wlr.wlr_output, table: []u16) -> bool {
	return sp.set_gamma(cast(^sp.Scene)data, output, table)
}
gamma_test_control :: proc(t: ^testing.T, s: ^Capture_Test) -> ^Gamma {
	m := gamma_create(s.display, gamma_test_changed, s.scene)
	capture_bind(s, "zwlr_gamma_control_manager_v1", 1, 6)
	capture_send(s, []u32{6, 16<<16, 7, 4})
	event := capture_event(capture_pump(s), 7, 0)
	assert(event != nil)
	testing.expect_value(t, wl.word_read(event, 8), u32(256))
	return m
}
gamma_test_set :: proc(s: ^Capture_Test, short: bool = false) {
	table: [768]u16
	for i in 0..<256 {
		table[i], table[256+i], table[512+i] = u16(i*257/2), u16(i*257), u16(i*257/4)
	}
	fd, err := linux.memfd_create("gamma-test", {.CLOEXEC})
	assert(err == .NONE)
	n := 6 if short else size_of(table)
	written, write_err := linux.write(fd, (cast([^]u8)&table)[:n])
	assert(write_err == .NONE && written == n)
	// pread must start at zero even though the sender's file position is at EOF.
	capture_send(s, []u32{7, 8<<16}, []linux.Fd{fd})
}
gamma_test_pixels :: proc(t: ^testing.T, s: ^Capture_Test, name: string) -> []u8 {
	assert(sp.output_commit(&s.paint))
	shot, ok := readback.capture(sp.target_buffer(s.paint.last), s.output, s.renderer)
	assert(ok)
	defer paint.destroy(shot)
	bytes := make([]u8, int(shot.stride)*int(shot.height), context.temp_allocator)
	copy(bytes, paint.data(shot)[:len(bytes)])
	if directory := os.get_env("KILN_TEST_ARTIFACTS", context.temp_allocator); directory != "" {
		path := strings.clone_to_cstring(fmt.tprintf("%s/gamma-%s.png", directory, name), context.temp_allocator)
		testing.expect_value(t, cairo.cairo_surface_write_to_png(shot.handle, path), i32(0))
	}
	return bytes
}

@(test)
gamma_ramp_changes_pixels_and_failures_or_disconnect_restore_identity :: proc(t: ^testing.T) {
	for mode in 0..<5 {
		s := capture_setup(t)
		defer capture_teardown(s)
		m := gamma_test_control(t, s)
		before := gamma_test_pixels(t, s, fmt.tprintf("%d-before", mode))
		gamma_test_set(s)
		capture_pump(s)
		table := gamma_table(m, s.output)
		testing.expect_value(t, len(table), 768)
		testing.expect_value(t, s.paint.gamma.size, i32(256))
		testing.expect_value(t, s.paint.gamma.table[255], u16(32767))
		ramped := gamma_test_pixels(t, s, fmt.tprintf("%d-ramped", mode))
		changed := 0
		for i in 0..<len(before)/4 { if string(before[i*4:][:4]) != string(ramped[i*4:][:4]) { changed += 1 } }
		testing.expect_value(t, changed, 35)
		switch mode {
		case 0:
			fds: [2]linux.Fd
			assert(linux.pipe2(&fds, {.CLOEXEC}) == .NONE)
			defer linux.close(fds[1])
			capture_send(s, []u32{7, 8<<16}, []linux.Fd{fds[0]})
			testing.expect(t, capture_event(capture_pump(s), 7, 1) != nil)
		case 1:
			gamma_test_set(s, true)
			err := capture_event(capture_pump(s), 1, 0)
			assert(err != nil)
			testing.expect_value(t, wl.word_read(err, 12), u32(1))
		case 2:
			wl.connection_close(&s.peer)
			wl.loop_dispatch(s.display.loop, 0)
		case 3:
			capture_send(s, []u32{7, 8<<16|1})
			capture_pump(s)
		case 4:
			m.changed = proc(data: rawptr, output: ^wlr.wlr_output, table: []u16) -> bool {
				if len(table) != 0 { return false }
				return gamma_test_changed(data, output, table)
			}
			gamma_test_set(s)
			testing.expect(t, capture_event(capture_pump(s), 7, 1) != nil)
		}
		testing.expect_value(t, len(gamma_table(m, s.output)), 0)
		testing.expect_value(t, s.paint.gamma.name, u32(0))
		after := gamma_test_pixels(t, s, fmt.tprintf("%d-restored", mode))
		testing.expect(t, string(before) == string(after))
		fmt.printf("Gamma reset %d: %d pixels changed by ramp, restored byte-identical\n", mode, changed)
	}
}

@(test)
gamma_exclusivity_manager_and_output_lifetimes :: proc(t: ^testing.T) {
	s := capture_setup(t)
	defer capture_teardown(s)
	m := gamma_test_control(t, s)
	gamma_test_set(s)
	capture_pump(s)
	capture_send(s, []u32{6, 16<<16, 8, 4})
	testing.expect(t, capture_event(capture_pump(s), 8, 1) != nil)
	testing.expect_value(t, len(gamma_table(m, s.output)), 768)
	fds: [2]linux.Fd
	assert(linux.socketpair(.UNIX, .STREAM, {}, &fds) == .NONE)
	other := Capture_Test{display = s.display, client = wl.client_create(s.display, i32(fds[0])), peer = {fd = fds[1]}}
	defer wl.connection_close(&other.peer)
	capture_send(&other, []u32{1, 12<<16|1, 2})
	capture_pump(&other)
	capture_bind(&other, "wl_output", 4, 3)
	capture_bind(&other, "zwlr_gamma_control_manager_v1", 1, 4)
	capture_send(&other, []u32{4, 16<<16, 5, 3})
	testing.expect(t, capture_event(capture_pump(&other), 5, 1) != nil)
	capture_send(s, []u32{6, 8<<16|1})
	capture_pump(s)
	testing.expect_value(t, len(gamma_table(m, s.output)), 768)
	sp.output_finish(&s.paint)
	s.paint = {}
	wlr_output_destroy(s.output)
	testing.expect(t, capture_event(capture_pump(s), 7, 1) != nil)
	for c in m.controls { testing.expect(t, c.output == nil) }
	gamma_test_set(s)
	testing.expect(t, capture_event(capture_pump(s), 1, 0) == nil)
}
