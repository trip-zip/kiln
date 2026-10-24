package compositor

import ext "../extensions"
import p "../protocols"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"
import "core:fmt"
import "core:testing"

extension_event_count :: proc(bytes: []u8, id, opcode: u32) -> (count: int) {
	for at := 0; at+8 <= len(bytes); at += int(wl.word_read(bytes, at+4)>>16) {
		if wl.word_read(bytes, at) == id && wl.word_read(bytes, at+4)&0xffff == opcode { count += 1 }
	}
	return
}
foreign_test_output :: proc(s: ^Server) -> ^wlr.wlr_output {
	s.backend = wlr_headless_backend_create(s.display.loop)
	s.layout = wlr.wlr_output_layout_create(s.display)
	o := wlr_headless_add_output(s.backend, 16, 12)
	state: wlr.wlr_output_state
	wlr.wlr_output_state_init(&state)
	wlr.wlr_output_state_set_enabled(&state, true)
	assert(wlr.wlr_output_commit_state(o, &state))
	wlr.wlr_output_state_finish(&state)
	assert(wlr.wlr_output_layout_add_auto(s.layout, o) != nil)
	return o
}
foreign_test_id :: proc(events: []u8, manager: u32) -> u32 {
	e := extension_event(events, manager, 0)
	assert(e != nil)
	return wl.word_read(e, 8)
}
foreign_test_state :: proc(t: ^testing.T, events: []u8, id: u32, states: []u32) {
	e := extension_event(events, id, 4)
	assert(e != nil)
	testing.expect_value(t, wl.word_read(e, 8), u32(len(states)*4))
	for value, i in states { testing.expect_value(t, wl.word_read(e, 12+i*4), value) }
}

@(test)
owned_foreign_late_binding_batching_requests_and_stop :: proc(t: ^testing.T) {
	s := extension_server()
	defer extension_finish(s)
	extension_hold_events(s)
	o := Output{handle = foreign_test_output(s)}
	s.foreign_manager = ext.foreign_manager_create(s.display)
	base: wlr.wlr_xdg_surface
	top := wlr.wlr_xdg_toplevel{base = &base, title = "Initial title", app_id = "org.example.Editor"}
	view := View{id = 91, server = s, protocol = &top, output = &o, mapped = true}
	// View callbacks enter with the default context; extension storage belongs to the display.
	{
		context = runtime.default_context()
		foreign_create(&view)
	}
	defer foreign_destroy(&view)
	h := view.foreign_handle
	ext.foreign_maximized(h, true)
	ext.foreign_activated(h, true)
	ext.foreign_fullscreen(h, true)
	c := extension_client(s)
	defer wl.connection_close(&c.peer)
	extension_bind(&c, "wl_output", 4, 7)
	events := extension_bind(&c, "zwlr_foreign_toplevel_manager_v1", 3, 8)
	id := foreign_test_id(events, 8)
	testing.expect_value(t, extension_event_string(extension_event(events, id, 0)), "Initial title")
	testing.expect_value(t, extension_event_string(extension_event(events, id, 1)), "org.example.Editor")
	testing.expect_value(t, wl.word_read(extension_event(events, id, 2), 8), u32(7))
	foreign_test_state(t, events, id, []u32{0, 2, 3})
	testing.expect_value(t, extension_event_count(events, id, 5), 1)
	state, done := extension_event(events, id, 4), extension_event(events, id, 5)
	testing.expect(t, uintptr(raw_data(done)) > uintptr(raw_data(state)))
	// No dispatch occurs between setters; only their final values form the batch.
	{
		context = runtime.default_context()
		ext.foreign_title(h, "Intermediate")
		ext.foreign_title(h, "Final title")
		ext.foreign_app_id(h, "org.example.Final")
	}
	ext.foreign_maximized(h, false)
	ext.foreign_minimized(h, true)
	events = extension_pump(&c)
	testing.expect_value(t, extension_event_count(events, id, 0), 1)
	testing.expect_value(t, extension_event_string(extension_event(events, id, 0)), "Final title")
	testing.expect_value(t, extension_event_count(events, id, 5), 1)
	foreign_test_state(t, events, id, []u32{1, 2, 3})
	testing.expect_value(t, extension_event_count(extension_pump(&c), id, 5), 0)
	extension_send(&c, []u32{id, 12<<16|4, 3})
	extension_pump(&c)
	testing.expect_value(t, len(s.events), 1)
	testing.expect(t, s.events[0].name == "request::activate" && s.events[0].handle == 91 && s.events[0].valid)
	extension_clear_events(s)
	extension_send(&c, []u32{id, 8<<16, id, 8<<16|1, id, 8<<16|2, id, 8<<16|3,
		id, 12<<16|8, 7, id, 8<<16|9, id, 8<<16|5})
	extension_pump(&c)
	testing.expect_value(t, len(s.events), 7)
	for name, i in ([]string{"request::maximize", "request::maximize", "request::minimize", "request::minimize", "request::fullscreen", "request::fullscreen", "request::close"}) {
		testing.expect_value(t, s.events[i].name, name)
		if i < 6 { testing.expect_value(t, s.events[i].on, i%2 == 0) }
	}
	extension_clear_events(s)
	extension_send(&c, []u32{8, 8<<16})
	events = extension_pump(&c)
	testing.expect(t, extension_event(events, 8, 1) != nil && wl.client_get_object(c.client, 8) == nil)
	testing.expect_value(t, len(s.foreign_manager.bindings), 0)
	new_handle := ext.foreign_handle_create(s.foreign_manager)
	defer ext.foreign_handle_destroy(new_handle)
	testing.expect(t, extension_event(extension_pump(&c), 8, 0) == nil)
	// stop only stops discovery; the previously announced child stays usable.
	ext.foreign_title(h, "After stop")
	testing.expect(t, extension_event(extension_pump(&c), id, 0) != nil)
	foreign_destroy(&view)
	events = extension_pump(&c)
	testing.expect_value(t, extension_event_count(events, id, 6), 1)
	testing.expect_value(t, extension_event_count(events, id, 5), 0)
	extension_send(&c, []u32{id, 12<<16|4, 3, id, 8<<16|7})
	extension_pump(&c)
	testing.expect_value(t, len(s.events), 0)
	testing.expect(t, wl.client_get_object(c.client, id) == nil)
	fmt.println("Foreign: late title/app_id/state/output snapshot, one done per setter batch, request::activate, all policy requests, finished destructor and closed/inert lifetime passed")
}

@(test)
owned_foreign_versions_parents_and_late_output_bind :: proc(t: ^testing.T) {
	for version in u32(1)..=3 {
		s := extension_server()
		defer extension_finish(s)
		output := foreign_test_output(s)
		m := ext.foreign_manager_create(s.display)
		child := ext.foreign_handle_create(m)
		parent := ext.foreign_handle_create(m)
		defer ext.foreign_handle_destroy(child)
		ext.foreign_parent(child, parent)
		ext.foreign_fullscreen(child, true)
		ext.foreign_output(child, nil, output)
		c := extension_client(s)
		defer wl.connection_close(&c.peer)
		events := extension_bind(&c, "zwlr_foreign_toplevel_manager_v1", version, 7)
		id := foreign_test_id(events, 7)
		parent_id := parent.resources[0].resource.id
		if version == 3 { testing.expect_value(t, wl.word_read(extension_event(events, id, 7), 8), parent_id) } else {
			testing.expect(t, extension_event(events, id, 7) == nil)
		}
		foreign_test_state(t, events, id, []u32{3} if version >= 2 else nil)
		testing.expect(t, extension_event(events, id, 2) == nil)
		events = extension_bind(&c, "wl_output", 4, 8)
		testing.expect_value(t, wl.word_read(extension_event(events, id, 2), 8), u32(8))
		testing.expect_value(t, extension_event_count(events, id, 5), 1)
		// Another output binding gets its own enter, without repeating the first.
		events = extension_bind(&c, "wl_output", 4, 9)
		testing.expect_value(t, extension_event_count(events, id, 2), 1)
		testing.expect_value(t, wl.word_read(extension_event(events, id, 2), 8), u32(9))
		ext.foreign_output(child, output, nil)
		events = extension_pump(&c)
		testing.expect_value(t, extension_event_count(events, id, 3), 2)
		testing.expect_value(t, extension_event_count(events, id, 5), 1)
		ext.foreign_output(child, nil, output)
		extension_pump(&c)
		extension_send(&c, []u32{8, 8<<16})
		extension_pump(&c)
		ext.foreign_output(child, output, nil)
		events = extension_pump(&c)
		testing.expect_value(t, extension_event_count(events, id, 3), 1)
		testing.expect_value(t, wl.word_read(extension_event(events, id, 3), 8), u32(9))
		ext.foreign_handle_destroy(parent)
		events = extension_pump(&c)
		if version == 3 { testing.expect_value(t, wl.word_read(extension_event(events, id, 7), 8), u32(0)) }
		fmt.printf("Foreign v%d: fullscreen/parent version gates, parent created later, late output binds and balanced enter/leave passed\n", version)
	}
}

@(test)
owned_foreign_rectangle_validation_and_output_destruction :: proc(t: ^testing.T) {
	for invalid in ([2]bool{false, true}) {
		s := extension_server()
		defer extension_finish(s)
		output := foreign_test_output(s)
		m := ext.foreign_manager_create(s.display)
		h := ext.foreign_handle_create(m)
		defer ext.foreign_handle_destroy(h)
		ext.foreign_output(h, nil, output)
		c := extension_client(s)
		defer wl.connection_close(&c.peer)
		extension_bind(&c, "wl_output", 4, 7)
		id := foreign_test_id(extension_bind(&c, "zwlr_foreign_toplevel_manager_v1", 3, 8), 8)
		extension_send(&c, []u32{id, 28<<16|6, 6, 0, 0, max(u32) if invalid else 0, 0})
		events := extension_pump(&c)
		if invalid {
			err := extension_event(events, 1, 0)
			assert(err != nil)
			testing.expect_value(t, wl.word_read(err, 12), u32(p.Zwlr_Foreign_Toplevel_Handle_V1_Error.invalid_rectangle))
		} else {
			testing.expect(t, extension_event(events, 1, 0) == nil)
			// Backend destruction removes output pointers before deferred leave delivery.
			wlr.wlr_backend_destroy(s.backend)
			s.backend = nil
			testing.expect_value(t, len(h.outputs), 0)
			events = extension_pump(&c)
			testing.expect_value(t, extension_event_count(events, id, 3), 1)
			testing.expect_value(t, extension_event_count(events, id, 5), 1)
		}
	}
}
