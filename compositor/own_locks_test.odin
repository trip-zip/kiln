package compositor

import bk "../backend"
import out "../outputs"
import "../layout"
import p "../protocols"
import sp "../scene_paint"
import sh "../shells"
import wl "../wayland"
import "base:runtime"
import "core:testing"

lock_test_server :: proc(outputs := 1) -> ^Server {
	s := shell_test_server()
	s.scene = sp.scene_create()
	assert(init_lock(s))
	for i in 0 ..< outputs {
		o := new(Output); o.server = s
		assert(layout.init(&o.ui))
		if i == 0 {o.handle = foreign_test_output(s)} else {
			o.handle = bk.headless_add_output(s.backend, 16, 12)
			state: out.State
			out.state_init(&state)
			out.set_enabled(&state, true)
			assert(out.commit(o.handle, &state))
			out.state_finish(&state)
			assert(out.layout_add_auto(s.layout, o.handle) != nil)
		}
		o.paint.scene = s.scene
		append(&s.outputs, o); append(&s.scene.outputs, &o.paint)
		wl.listen(&o.handle.events.present, &o.present, lock_presented)
	}
	return s
}
lock_test_finish :: proc(s: ^Server) {
	s.shutting_down = true
	wl.destroy_clients(s.display)
	wl.unlisten(&s.new_lock)
	for o in s.outputs {wl.unlisten(&o.present); sp.output_finish(&o.paint); layout.destroy(&o.ui); free(o)}
	clear(&s.outputs)
	delete(s.lock_surfaces)
	sp.scene_destroy(s.scene)
	shell_test_finish(s)
}
lock_test_client :: proc(s: ^Server) -> Extension_Client {
	c := shell_test_client(s)
	extension_bind(&c, "ext_session_lock_manager_v1", 1, 10)
	extension_bind(&c, "wl_output", 4, 13)
	extension_send(&c, []u32{10, 12 << 16 | 1, 11})
	return c
}
lock_test_surface :: proc(c: ^Extension_Client) -> []u8 {
	extension_send(c, []u32{5, 12 << 16, 12, 11, 20 << 16 | 1, 14, 12, 13})
	return extension_pump(c)
}
lock_test_present :: proc(o: ^Output, submitted: u32 = 10, presented: u32 = 10, success := true) {
	o.lock_submitted, o.lock_commit_seq = true, submitted
	event := out.Present_Event {
		commit_seq = presented,
		presented  = success,
	}
	wl.signal_emit_mutable(&o.handle.events.present, &event)
}
lock_test_map :: proc(c: ^Extension_Client, serial: u32 = 1) {
	shell_test_buffer(c, 16, 12)
	extension_send(c, []u32{14, 12 << 16 | 1, serial, 12, 20 << 16 | 1, 22, 0, 0, 12, 8 << 16 | 6})
	extension_pump(c)
}

@(test)
owned_lock_present_ack_state_unlock_and_rejection :: proc(t: ^testing.T) {
	s := lock_test_server(2); defer lock_test_finish(s)
	c := lock_test_client(s); defer wl.connection_close(&c.peer)
	events := lock_test_surface(&c)
	testing.expect(t, locked(s) && !s.lock_acknowledged && extension_event(events, 11, 0) == nil)
	configure := extension_event(events, 14, 0); assert(configure != nil)
	testing.expect(
		t,
		wl.word_read(configure, 8) == 1 &&
		wl.word_read(configure, 12) == 16 &&
		wl.word_read(configure, 16) == 12,
	)
	it := wl.iterate(&s.display.globals); output_index := 0
	for link in wl.next(&it) {
		g := runtime.container_of(link, wl.Global, "link")
		if string(g.interface.name) != "wl_output" {continue}
		output_index += 1
		if output_index ==
		   2 {extension_send(&c, []u32{2, 36 << 16, g.name, 10, 0x6f5f6c77, 0x75707475, 0x74, 4, 15}); break}
	}
	extension_send(&c, []u32{5, 12 << 16, 16, 11, 20 << 16 | 1, 17, 16, 15})
	events = extension_pump(&c)
	testing.expect(t, extension_event(events, 17, 0) != nil && len(s.lock_surfaces) == 2)
	lock_test_map(&c)
	extension_send(
		&c,
		[]u32{17, 12 << 16 | 1, 1, 16, 20 << 16 | 1, 22, 0, 0, 16, 8 << 16 | 6},
	); extension_pump(&c)
	native := s.lock_surfaces[0].handle
	testing.expect(
		t,
		native.surface.mapped &&
		native.current.width == 16 &&
		s.seat.keyboard_state.focused_surface == native.surface,
	)
	testing.expect(t, len(s.outputs[0].paint.parts) == 1)
	lock_test_present(s.outputs[0], 10, 9)
	lock_test_present(s.outputs[1], 10, 10, false)
	testing.expect(t, !s.lock_acknowledged)
	lock_test_present(s.outputs[0]); testing.expect(t, !s.lock_acknowledged)
	lock_test_present(s.outputs[1]); events = extension_pump(&c)
	testing.expect(t, s.lock_acknowledged && extension_event_count(events, 11, 0) == 1)
	lock_test_present(
		s.outputs[1],
	); testing.expect(t, extension_event(extension_pump(&c), 11, 0) == nil)
	other := lock_test_client(s); defer wl.connection_close(&other.peer)
	events = extension_pump(&other)
	testing.expect(t, extension_event(events, 11, 1) != nil && s.ext_lock == native.lock)
	events = lock_test_surface(&other)
	testing.expect(
		t,
		extension_event(events, 1, 0) == nil && wl.client_get_object(other.client, 14).data == nil,
	)
	extension_send(&other, []u32{14, 12 << 16 | 1, 0, 14, 8 << 16, 11, 8 << 16})
	testing.expect(t, extension_event(extension_pump(&other), 1, 0) == nil)
	a := sh.lock_configure(native, 32, 24); b := sh.lock_configure(native, 16, 12)
	testing.expect(t, a == b && a == 2)
	events = extension_pump(&c)
	testing.expect(t, extension_event_count(events, 14, 0) == 1)
	extension_send(&c, []u32{14, 12 << 16 | 1, b}); extension_pump(&c)
	testing.expect(t, native.pending.serial == b && native.current.serial == 1)
	extension_send(&c, []u32{12, 8 << 16 | 6}); extension_pump(&c)
	testing.expect(t, native.current.serial == b && native.surface.mapped)
	extension_send(&c, []u32{11, 8 << 16 | 2, 14, 12 << 16 | 1, 0, 14, 8 << 16, 12, 8 << 16})
	events = extension_pump(&c)
	testing.expect(
		t,
		!locked(s) &&
		s.ext_lock == nil &&
		len(s.lock_surfaces) == 0 &&
		extension_event(events, 1, 0) == nil,
	)
}

@(test)
owned_lock_protocol_errors :: proc(t: ^testing.T) {
	for scenario in 0 ..< 11 {
		s := lock_test_server(); defer lock_test_finish(s)
		c := lock_test_client(s); defer wl.connection_close(&c.peer)
		extension_pump(&c)
		object, code := u32(14), u32(p.Ext_Session_Lock_Surface_V1_Error.invalid_serial)
		if scenario < 8 {lock_test_surface(&c)}
		switch scenario {
		case 0:
			extension_send(&c, []u32{14, 12 << 16 | 1, 0})
		case 1:
			extension_send(&c, []u32{14, 12 << 16 | 1, 1, 14, 12 << 16 | 1, 1})
		case 2:
			shell_test_buffer(&c, 16, 12)
			extension_send(&c, []u32{12, 20 << 16 | 1, 22, 0, 0, 12, 8 << 16 | 6})
			code = u32(p.Ext_Session_Lock_Surface_V1_Error.commit_before_first_ack)
		case 3:
			extension_send(&c, []u32{14, 12 << 16 | 1, 1, 12, 8 << 16 | 6})
			code = u32(p.Ext_Session_Lock_Surface_V1_Error.null_buffer)
		case 4:
			shell_test_buffer(&c)
			extension_send(
				&c,
				[]u32{14, 12 << 16 | 1, 1, 12, 20 << 16 | 1, 22, 0, 0, 12, 8 << 16 | 6},
			)
			code = u32(p.Ext_Session_Lock_Surface_V1_Error.dimensions_mismatch)
		case 5:
			extension_send(&c, []u32{5, 12 << 16, 15, 11, 20 << 16 | 1, 16, 15, 13})
			object, code = 11, u32(p.Ext_Session_Lock_V1_Error.duplicate_output)
		case 6:
			lock_test_map(&c); lock_test_present(s.outputs[0]); extension_pump(&c)
			extension_send(&c, []u32{11, 8 << 16})
			object, code = 11, u32(p.Ext_Session_Lock_V1_Error.invalid_destroy)
		case 7:
			extension_send(&c, []u32{11, 8 << 16 | 2})
			object, code = 11, u32(p.Ext_Session_Lock_V1_Error.invalid_unlock)
		case 8:
			extension_send(&c, []u32{11, 20 << 16 | 1, 14, 6, 13})
			object, code = 11, u32(p.Ext_Session_Lock_V1_Error.role)
		case 9:
			shell_test_buffer(&c)
			extension_send(&c, []u32{5, 12 << 16, 12, 12, 20 << 16 | 1, 22, 0, 0})
			extension_send(&c, []u32{12, 8 << 16 | 6})
			extension_send(&c, []u32{11, 20 << 16 | 1, 14, 12, 13})
			object, code = 11, u32(p.Ext_Session_Lock_V1_Error.already_constructed)
		case 10:
			lock_test_surface(&c); lock_test_map(&c)
			extension_send(&c, []u32{12, 20 << 16 | 1, 0, 0, 0, 12, 8 << 16 | 6})
			code = u32(p.Ext_Session_Lock_Surface_V1_Error.null_buffer)
		}
		shell_test_error(t, &c, object, code)
		testing.expect(t, locked(s) && s.ext_lock == nil && len(s.lock_surfaces) == 0)
	}
}

@(test)
owned_lock_disconnect_promotes_to_native_lock :: proc(t: ^testing.T) {
	s := lock_test_server(); defer lock_test_finish(s)
	c := lock_test_client(s); defer wl.connection_close(&c.peer)
	lock_test_surface(&c); lock_test_map(&c)
	lock_test_present(s.outputs[0]); extension_pump(&c)
	generation := s.lock_generation
	wl.connection_close(&c.peer); extension_pump(&c)
	testing.expect(
		t,
		locked(s) &&
		s.lock_owner == .Native &&
		s.ext_lock == nil &&
		len(s.lock_surfaces) == 0 &&
		s.lock_generation > generation,
	)
	// Only the compositor's own authentication may end a lock whose client died.
	next := lock_test_client(s); defer wl.connection_close(&next.peer)
	events := extension_pump(&next)
	testing.expect(
		t,
		extension_event(events, 11, 1) != nil &&
		s.lock_owner == .Native &&
		s.ext_lock == nil &&
		locked(s),
	)
}

@(test)
owned_lock_output_and_resource_lifetime_and_serial_wrap :: proc(t: ^testing.T) {
	for scenario in 0 ..< 5 {
		s := lock_test_server(); defer lock_test_finish(s)
		c := lock_test_client(s); defer wl.connection_close(&c.peer)
		lock_test_surface(&c)
		native := s.lock_surfaces[0].handle
		native.serial = max(u32)
		testing.expect_value(t, sh.lock_configure(native, 0, -1), u32(1))
		events := extension_pump(&c)
		conf := extension_event(events, 14, 0); assert(conf != nil)
		testing.expect(t, wl.word_read(conf, 12) == 1 && wl.word_read(conf, 16) == 1)
		sh.lock_configure(native, 16, 12); extension_pump(&c)
		if scenario != 4 {lock_test_map(&c, 2)}
		sh.lock_configure(native, 16, 12)
		switch scenario {
		case 0:
			extension_send(&c, []u32{14, 8 << 16, 12, 8 << 16})
		case 1:
			extension_send(&c, []u32{12, 8 << 16, 14, 8 << 16})
		case 2:
			wl.unlisten(&s.outputs[0].present)
			bk.destroy(s.backend); s.backend = nil
			// Output destruction makes the role resource inert even before the client notices removal.
			extension_send(&c, []u32{14, 12 << 16 | 1, 0, 14, 8 << 16, 12, 8 << 16})
			sp.output_finish(
				&s.outputs[0].paint,
			); layout.destroy(&s.outputs[0].ui); free(s.outputs[0])
			clear(&s.outputs)
		case 3:
			sh.lock_reject(s.ext_lock)
		case 4:
			extension_send(&c, []u32{11, 8 << 16})
		}
		events = extension_pump(&c)
		if scenario == 1 {
			err := extension_event(events, 1, 0); assert(err != nil)
			testing.expect(t, wl.word_read(err, 8) == 12 && wl.word_read(err, 12) == 4)
		} else {testing.expect(t, extension_event(events, 1, 0) == nil)}
		testing.expect(t, len(s.lock_surfaces) == 0 && locked(s))
	}
}
