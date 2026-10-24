package compositor

import p "../protocols"
import sp "../scene_paint"
import sh "../shells"
import wl "../wayland"
import wlr "../wlroots"
import "core:testing"

popup_test_parent :: proc(t: ^testing.T, c: ^Extension_Client) {
	serial := shell_test_initial(t, c)
	shell_test_buffer(c)
	extension_send(c, []u32{8, 12 << 16 | 4, serial, 6, 20 << 16 | 1, 22, 0, 0, 6, 8 << 16 | 6})
	extension_pump(c)
}
popup_test_create :: proc(
	c: ^Extension_Client,
	surface, xdg, popup, parent: u32,
	positioner: u32 = 10,
) -> []u8 {
	extension_send(
		c,
		[]u32 {
			5,
			12 << 16,
			surface,
			7,
			16 << 16 | 2,
			xdg,
			surface,
			xdg,
			20 << 16 | 2,
			popup,
			parent,
			positioner,
		},
	)
	return extension_pump(c)
}
popup_test_positioner :: proc(c: ^Extension_Client) {
	extension_send(
		c,
		[]u32 {
			7,
			12 << 16 | 1,
			10,
			10,
			16 << 16 | 1,
			64,
			48,
			10,
			24 << 16 | 2,
			10,
			10,
			20,
			20,
			10,
			12 << 16 | 3,
			8,
			10,
			12 << 16 | 4,
			8,
			10,
			12 << 16 | 5,
			63,
		},
	)
	extension_pump(c)
}
popup_test_map :: proc(t: ^testing.T, c: ^Extension_Client, surface, xdg: u32) {
	extension_send(c, []u32{surface, 8 << 16 | 6})
	events := extension_pump(c)
	configure := extension_event(events, xdg, 0)
	assert(configure != nil)
	extension_send(
		c,
		[]u32 {
			xdg,
			12 << 16 | 4,
			wl.word_read(configure, 8),
			surface,
			20 << 16 | 1,
			22,
			0,
			0,
			surface,
			8 << 16 | 6,
		},
	)
	extension_pump(c)
}

@(test)
owned_popups_reposition_nested_coordinates_and_no_configure_loop :: proc(t: ^testing.T) {
	s := shell_test_server(); defer shell_test_finish(s)
	c := shell_test_client(s); defer wl.connection_close(&c.peer)
	popup_test_parent(t, &c); popup_test_positioner(&c)
	popup_test_create(&c, 11, 12, 13, 8)
	testing.expect(t, len(s.popups) == 1 && !s.popups[0].handle.initialized)
	popup_test_map(t, &c, 11, 12)
	first := s.popups[0].handle
	testing.expect_value(t, first.current.geometry, wlr.Box{30, 30, 64, 48})
	testing.expect(t, s.popups[0].mapped && s.popups[0].root == s.views[0].id)
	popup_test_create(&c, 14, 15, 16, 12); popup_test_map(t, &c, 14, 15)
	second := s.popups[1].handle
	x, y := sh.get_toplevel_coords(second, 3, 4)
	testing.expect(t, x == 33 && y == 34)
	sh.popup_constrain(second, {0, 0, 400, 300}, false)
	testing.expect(t, second.idle == nil, "unchanged geometry sends no configure")
	extension_send(&c, []u32{10, 16 << 16 | 6, 350, 250, 16, 16 << 16 | 2, 10, 77})
	events := extension_pump(&c)
	reposition, configure, surface_configure :=
		extension_event(events, 16, 2),
		extension_event(events, 16, 0),
		extension_event(events, 15, 0)
	assert(reposition != nil && configure != nil && surface_configure != nil)
	testing.expect_value(t, wl.word_read(reposition, 8), u32(77))
	testing.expect(
		t,
		uintptr(raw_data(reposition)) < uintptr(raw_data(configure)) &&
		uintptr(raw_data(configure)) < uintptr(raw_data(surface_configure)),
	)
	sh.popup_constrain(second, {0, 0, 400, 300}, false)
	testing.expect_value(t, second.scheduled.geometry, wlr.Box{296, 212, 64, 48})
	events = extension_pump(&c)
	extension_send(
		&c,
		[]u32{15, 12 << 16 | 4, wl.word_read(extension_event(events, 15, 0), 8), 14, 8 << 16 | 6},
	)
	extension_pump(&c)
	sh.popup_constrain(second, {0, 0, 400, 300}, false)
	testing.expect(t, second.idle == nil)
	positions := make([dynamic]sp.Surface_Position); defer delete(positions)
	sh.popups(
		xdg(s.views[0]).surface,
		proc(surface: ^wlr.Surface, x, y: i32, data: rawptr) {append(
				cast(^[dynamic]sp.Surface_Position)data,
				sp.Surface_Position{surface = surface, x = x, y = y},
			)},
		&positions,
	)
	testing.expect(t, len(positions) == 2 && positions[1].x == 326 && positions[1].y == 242)
	extension_send(
		&c,
		[]u32{16, 8 << 16, 15, 8 << 16, 14, 8 << 16, 13, 8 << 16, 12, 8 << 16, 11, 8 << 16},
	)
	testing.expect(t, extension_event(extension_pump(&c), 1, 0) == nil && len(s.popups) == 0)
}

@(test)
owned_popup_grab_focus_and_outside_dismissal_newest_first :: proc(t: ^testing.T) {
	s := shell_test_server(); defer shell_test_finish(s)
	c := shell_test_client(s); defer wl.connection_close(&c.peer)
	popup_test_parent(t, &c); popup_test_positioner(&c)
	parent := xdg(s.views[0]).surface
	enter_surface(s, parent)
	serial := extension_focus(s, &c)
	popup_test_create(&c, 11, 12, 13, 8)
	extension_send(&c, []u32{13, 16 << 16 | 1, 3, serial}); extension_pump(&c)
	first := s.popups[0].handle
	testing.expect(
		t,
		sh.grab_client(s.shell) == c.client &&
		s.seat.keyboard_state.focused_surface == first.surface,
	)
	popup_test_map(t, &c, 11, 12)
	popup_test_create(&c, 14, 15, 16, 12)
	extension_send(&c, []u32{16, 16 << 16 | 1, 3, serial}); extension_pump(&c)
	popup_test_map(t, &c, 14, 15)
	testing.expect(t, s.seat.keyboard_state.focused_surface == s.popups[1].handle.surface)
	other := shell_test_client(s); defer wl.connection_close(&other.peer)
	popup_test_parent(t, &other)
	other_surface := xdg(s.views[1]).surface
	output := Output {
		handle = foreign_test_output(s),
		server = s,
	}
	append(&s.outputs, &output)
	append(
		&output.paint.parts,
		sp.Part{kind = .Client, id = s.views[0].id, surface = parent, box = {0, 0, 8, 12}},
	)
	append(
		&output.paint.parts,
		sp.Part{kind = .Client, id = s.views[1].id, surface = other_surface, box = {8, 0, 8, 12}},
	)
	defer {clear(&s.outputs); delete(output.paint.parts)}
	pointer_refresh_at(s, 0, 2, 2, false, false)
	testing.expect(t, s.seat.pointer_state.focused_surface == parent)
	pointer_refresh_at(s, 0, 10, 2, false, false)
	testing.expect(
		t,
		s.seat.pointer_state.focused_surface == nil,
		"foreign client cannot receive pointer focus during grab",
	)
	testing.expect(
		t,
		popup_pointer_allowed(s, parent) &&
		!popup_pointer_allowed(s, other_surface) &&
		!popup_pointer_allowed(s, nil),
	)
	testing.expect(t, !popup_press(s, parent) && popup_press(s, other_surface))
	events := extension_pump(&c)
	done_child, done_parent := extension_event(events, 16, 1), extension_event(events, 13, 1)
	assert(done_child != nil && done_parent != nil)
	testing.expect(t, uintptr(raw_data(done_child)) < uintptr(raw_data(done_parent)))
	testing.expect(
		t,
		len(s.popups) == 0 &&
		sh.grab_client(s.shell) == nil &&
		s.seat.keyboard_state.focused_surface == parent,
	)
}

@(test)
owned_popup_protocol_errors_and_invalid_grab_serial :: proc(t: ^testing.T) {
	for scenario in 0 ..< 7 {
		s := shell_test_server(); defer shell_test_finish(s)
		c := shell_test_client(s); defer wl.connection_close(&c.peer)
		popup_test_parent(t, &c); popup_test_positioner(&c)
		if scenario ==
		   0 {extension_send(&c, []u32{10, 24 << 16 | 2, 0, 0, 0, 0}); extension_pump(&c)}
		created := popup_test_create(&c, 11, 12, 13, 0 if scenario == 1 else 8)
		if scenario == 0 {
			err := extension_event(created, 1, 0); assert(err != nil)
			testing.expect(
				t,
				wl.word_read(err, 8) == 7 &&
				wl.word_read(err, 12) == u32(p.Xdg_Wm_Base_Error.invalid_positioner),
			)
			continue
		}
		switch scenario {
		case 0:
		case 1:
			extension_send(&c, []u32{11, 8 << 16 | 6})
			shell_test_error(t, &c, 12, u32(p.Xdg_Surface_Error.not_constructed))
		case 2:
			extension_send(&c, []u32{13, 16 << 16 | 1, 3, 0})
			events := extension_pump(&c)
			testing.expect(
				t,
				extension_event(events, 13, 1) != nil &&
				extension_event(events, 1, 0) == nil &&
				len(s.popups) == 0,
			)
		case 3:
			serial := extension_focus(s, &c)
			extension_send(&c, []u32{13, 16 << 16 | 1, 3, serial}); extension_pump(&c)
			popup_test_create(&c, 14, 15, 16, 8)
			extension_send(
				&c,
				[]u32{16, 16 << 16 | 1, 3, serial},
			); shell_test_error(t, &c, 16, u32(p.Xdg_Popup_Error.invalid_grab))
		case 4:
			extension_send(&c, []u32{11, 20 << 16 | 1, 22, 0, 0, 11, 8 << 16 | 6})
			shell_test_error(t, &c, 12, u32(p.Xdg_Surface_Error.unconfigured_buffer))
		case 5:
			popup_test_map(t, &c, 11, 12)
			popup_test_create(&c, 14, 15, 16, 12)
			extension_send(
				&c,
				[]u32{13, 8 << 16},
			); shell_test_error(t, &c, 7, u32(p.Xdg_Wm_Base_Error.not_the_topmost_popup))
		case 6:
			popup_test_map(t, &c, 11, 12)
			extension_send(
				&c,
				[]u32{12, 12 << 16 | 4, 1},
			); shell_test_error(t, &c, 12, u32(p.Xdg_Surface_Error.invalid_serial))
		}
	}
}

@(test)
owned_popup_on_native_layer_parent_draws_and_retires :: proc(t: ^testing.T) {
	s := shell_test_server(); defer shell_test_finish(s)
	assert(sh.layer_shell_create(s.display) != nil)
	c := shell_test_client(s); defer wl.connection_close(&c.peer)
	popup_test_parent(t, &c); popup_test_positioner(&c)
	extension_bind(&c, "zwlr_layer_shell_v1", 4, 17)
	extension_send(
		&c,
		[]u32 {
			5,
			12 << 16,
			11,
			17,
			32 << 16,
			18,
			11,
			0,
			2,
			4,
			0x726162,
			18,
			16 << 16,
			64,
			48,
			11,
			8 << 16 | 6,
		},
	)
	extension_pump(&c)
	layer := cast(^sh.Layer_Surface)wl.client_get_object(c.client, 18).data
	serial := sh.layer_configure(layer, 64, 48)
	extension_pump(&c)
	extension_send(
		&c,
		[]u32{18, 12 << 16 | 6, serial, 11, 20 << 16 | 1, 22, 0, 0, 11, 8 << 16 | 6},
	)
	extension_pump(&c)
	testing.expect(t, layer.surface.mapped)
	popup_test_create(&c, 14, 15, 16, 0)
	extension_send(&c, []u32{18, 12 << 16 | 5, 16}); extension_pump(&c)
	popup_test_map(t, &c, 14, 15)
	testing.expect(t, s.popups[0].handle.parent == layer.surface)
	positions := sp.current_surfaces(sp.Part{surface = layer.surface, box = {5, 6, 64, 48}})
	testing.expect(
		t,
		len(positions) == 2 && positions[1].popup && positions[1].x == 35 && positions[1].y == 36,
	)
	sh.layer_close(layer)
	extension_send(&c, []u32{18, 12 << 16 | 5, 16})
	events := extension_pump(&c)
	testing.expect(
		t,
		extension_event(events, 16, 1) != nil &&
		extension_event(events, 1, 0) == nil &&
		len(s.popups) == 0,
	)
}

@(test)
owned_popup_grab_teardown_and_lock_dismissal :: proc(t: ^testing.T) {
	for scenario in 0 ..< 4 {
		s := shell_test_server(); defer shell_test_finish(s)
		c := shell_test_client(s); defer wl.connection_close(&c.peer)
		popup_test_parent(t, &c); popup_test_positioner(&c)
		enter_surface(s, xdg(s.views[0]).surface)
		serial := extension_focus(s, &c)
		popup_test_create(&c, 11, 12, 13, 8)
		extension_send(&c, []u32{13, 16 << 16 | 1, 3, serial}); extension_pump(&c)
		popup_test_map(t, &c, 11, 12)
		switch scenario {
		case 0:
			s.lock_owner = .Native
			lock_reset_input(s)
			events := extension_pump(&c)
			testing.expect(
				t,
				extension_event(events, 13, 1) != nil &&
				s.seat.keyboard_state.focused_surface == nil,
			)
		case 1:
			extension_send(&c, []u32{9, 8 << 16, 8, 8 << 16, 6, 8 << 16})
			extension_pump(&c)
		case 2:
			wl.connection_close(&c.peer); extension_pump(&c)
		case 3:
			popup_test_create(&c, 14, 15, 16, 12)
			extension_send(&c, []u32{16, 16 << 16 | 1, 3, serial}); extension_pump(&c)
			extension_send(&c, []u32{16, 8 << 16}); extension_pump(&c)
			testing.expect(
				t,
				sh.grab_surface(s.shell) == s.popups[0].handle.surface &&
				s.seat.keyboard_state.focused_surface == sh.grab_surface(s.shell),
			)
			testing.expect(t, popup_press(s, nil))
		}
		testing.expect(
			t,
			len(s.popups) == 0 && sh.grab_client(s.shell) == nil && !s.popup_grab_active,
		)
	}
}

@(test)
owned_positioner_wire_validation_and_parent_hints :: proc(t: ^testing.T) {
	for scenario in 0 ..< 6 {
		s := shell_test_server(); defer shell_test_finish(s)
		c := shell_test_client(s); defer wl.connection_close(&c.peer)
		popup_test_positioner(&c)
		switch scenario {
		case 0:
			extension_send(&c, []u32{10, 16 << 16 | 1, 0, 48})
		case 1:
			extension_send(&c, []u32{10, 24 << 16 | 2, 0, 0, ~u32(0), 20})
		case 2:
			extension_send(&c, []u32{10, 12 << 16 | 3, 9})
		case 3:
			extension_send(&c, []u32{10, 12 << 16 | 4, 9})
		case 4:
			extension_send(&c, []u32{10, 12 << 16 | 5, 64})
		case 5:
			extension_send(
				&c,
				[]u32{10, 8 << 16 | 7, 10, 16 << 16 | 8, 400, 300, 10, 12 << 16 | 9, 123},
			)
			extension_pump(&c)
			popup_test_create(&c, 11, 12, 13, 8)
			rules := s.popups[0].handle.scheduled.rules
			testing.expect(
				t,
				rules.reactive &&
				rules.parent_width == 400 &&
				rules.parent_height == 300 &&
				rules.parent_configure == 123,
			)
			extension_send(&c, []u32{10, 8 << 16})
			extension_pump(&c)
			testing.expect_value(t, s.popups[0].handle.scheduled.rules, rules)
			continue
		}
		shell_test_error(t, &c, 10, u32(p.Xdg_Positioner_Error.invalid_input))
	}
}
