package extensions

import gles "../gles"
import out "../outputs"
import sp "../scene_paint"
import wl "../wayland"
import "core:fmt"
import "core:testing"

Xdg_Output_Test :: struct {
	manager: ^Xdg_Output_Manager,
	layout, commit: wl.Listener,
}
xdg_test_layout :: proc(listener: ^wl.Listener, data: rawptr) {
	f := wl.owner(listener, Xdg_Output_Test, "layout")
	context = f.manager.global.display.loop.ctx
	xdg_output_update(f.manager)
}
xdg_test_commit :: proc(listener: ^wl.Listener, data: rawptr) {
	f := wl.owner(listener, Xdg_Output_Test, "commit")
	context = f.manager.global.display.loop.ctx
	xdg_output_update(f.manager, (cast(^out.Commit_Event)data).output)
}
xdg_test_details :: proc(t: ^testing.T, events: []u8, version: u32, box: gles.Box) {
	position, size := capture_event(events, 7, 0), capture_event(events, 7, 1)
	if !testing.expect(t, position != nil && size != nil) { return }
	testing.expect_value(t, i32(wl.word_read(position, 8)), box.x)
	testing.expect_value(t, i32(wl.word_read(position, 12)), box.y)
	testing.expect_value(t, i32(wl.word_read(size, 8)), box.width)
	testing.expect_value(t, i32(wl.word_read(size, 12)), box.height)
	done := capture_event(events, 7, 2)
	if version < 3 {
		testing.expect(t, done != nil && uintptr(raw_data(done)) > uintptr(raw_data(size)))
	} else {
		testing.expect(t, done == nil)
		completion := capture_event(events, 4, 2)
		testing.expect(t, completion != nil && uintptr(raw_data(completion)) > uintptr(raw_data(size)))
	}
}
xdg_test_string :: proc(t: ^testing.T, events: []u8, opcode: u32, want: string) {
	e := capture_event(events, 7, opcode)
	if !testing.expect(t, e != nil) { return }
	testing.expect_value(t, string(e[12:12+wl.word_read(e, 8)-1]), want)
}

@(test)
xdg_output_versions_geometry_metadata_and_completion :: proc(t: ^testing.T) {
	for version in u32(1)..=3 {
		s := capture_setup(t)
		defer capture_teardown(s)
		m := xdg_output_create(s.display, s.layout)
		f := Xdg_Output_Test{manager = m}
		wl.listen(&s.layout.events.change, &f.layout, xdg_test_layout)
		wl.listen(&s.output.events.commit, &f.commit, xdg_test_commit)
		defer wl.unlisten(&f.layout)
		defer wl.unlisten(&f.commit)
		out.set_description(s.output, "Gamma test monitor")
		capture_bind(s, "zxdg_output_manager_v1", version, 6)
		capture_send(s, []u32{6, 16<<16|1, 7, 4})
		events := capture_pump(s)
		xdg_test_details(t, events, version, {0, 0, 16, 12})
		if version >= 2 {
			xdg_test_string(t, events, 3, string(s.output.name))
			xdg_test_string(t, events, 4, "Gamma test monitor")
		} else {
			testing.expect(t, capture_event(events, 7, 3) == nil && capture_event(events, 7, 4) == nil)
		}
		assert(out.layout_add(s.layout, s.output, -13, 27) != nil)
		xdg_test_details(t, capture_pump(s), version, {-13, 27, 16, 12})
		state: out.State
		out.state_init(&state)
		defer out.state_finish(&state)
		out.set_scale(&state, 2)
		assert(out.commit(s.output, &state))
		events = capture_pump(s)
		xdg_test_details(t, events, version, {-13, 27, 8, 6})
		testing.expect(t, capture_event(events, 7, 3) == nil && capture_event(events, 7, 4) == nil)
		out.set_transform(&state, 1)
		assert(out.commit(s.output, &state))
		xdg_test_details(t, capture_pump(s), version, {-13, 27, 6, 8})
		out.set_custom_mode(&state, 20, 14, 60000)
		assert(out.commit(s.output, &state))
		xdg_test_details(t, capture_pump(s), version, {-13, 27, 7, 10})
		out.set_description(s.output, "Renamed monitor")
		events = capture_pump(s)
		if version == 3 {
			xdg_test_string(t, events, 4, "Renamed monitor")
			desc, done := capture_event(events, 7, 4), capture_event(events, 4, 2)
			testing.expect(t, done != nil && uintptr(raw_data(done)) > uintptr(raw_data(desc)))
		} else { testing.expect(t, capture_event(events, 7, 4) == nil) }
		// The child remains valid after the manager and its original wl_output are released.
		capture_send(s, []u32{6, 8<<16, 4, 8<<16})
		capture_pump(s)
		assert(out.layout_add(s.layout, s.output, 2, 3) != nil)
		events = capture_pump(s)
		testing.expect(t, capture_event(events, 7, 0) != nil)
		capture_send(s, []u32{7, 8<<16})
		capture_pump(s)
		testing.expect_value(t, len(m.outputs), 0)
		fmt.printf("xdg-output v%d: position, scale, transform, mode, metadata and done order passed\n", version)
	}
}

@(test)
xdg_output_becomes_inert_when_output_or_layout_is_destroyed :: proc(t: ^testing.T) {
	for layout_lost in ([2]bool{false, true}) {
		s := capture_setup(t)
		defer capture_teardown(s)
		m := xdg_output_create(s.display, s.layout)
		capture_bind(s, "zxdg_output_manager_v1", 3, 6)
		capture_send(s, []u32{6, 16<<16|1, 7, 4})
		capture_pump(s)
		if layout_lost {
			out.layout_destroy(s.layout)
			s.layout = nil
		} else {
			sp.output_finish(&s.paint)
			s.paint = {}
			out.finish(s.output)
		}
		testing.expect(t, m.outputs[0].output == nil)
		xdg_output_update(m)
		capture_send(s, []u32{7, 8<<16})
		capture_pump(s)
		testing.expect_value(t, len(m.outputs), 0)
	}
}
