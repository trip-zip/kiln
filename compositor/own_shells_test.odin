package compositor

import gles "../gles"
import "../buffers"
import sf "../surfaces"
import sh "../shells"
import p "../protocols"
import wl "../wayland"
import "core:sys/linux"
import "core:testing"

shell_test_server :: proc() -> ^Server {
	s := extension_server()
	extension_hold_events(s)
	s.shell = sh.xdg_shell_create(s.display)
	assert(s.shell != nil)
	wl.listen(&s.shell.events.new_toplevel, &s.new_toplevel, view_added)
	wl.listen(&s.shell.events.new_popup, &s.new_popup, popup_added)
	wl.listen(&s.shell.events.grab_changed, &s.popup_grab, popup_grab_changed)
	m := sh.decoration_create(s.display)
	assert(m != nil)
	wl.listen(&m.events.new_toplevel_decoration, &s.new_decoration, decoration_added)
	formats := [2]u32{0x34325241, 0x34325258}
	assert(buffers.shm_create(s.display, 1, formats[:]) != nil)
	return s
}
shell_test_finish :: proc(s: ^Server) {
	wl.unlisten(&s.new_toplevel); wl.unlisten(&s.new_decoration)
	wl.unlisten(&s.new_popup); wl.unlisten(&s.popup_grab); wl.unlisten(&s.popup_previous_destroy)
	extension_finish(s)
}
shell_test_client :: proc(s: ^Server, version: u32 = 6) -> Extension_Client {
	c := extension_client(s)
	extension_bind(&c, "xdg_wm_base", version, 7)
	extension_send(&c, []u32{7, 16<<16|2, 8, 6, 8, 12<<16|1, 9})
	extension_pump(&c)
	// Retired callback IDs let each scenario reuse fixed IDs without skipping wire allocation slots.
	for id in u32(10)..=22 { extension_send(&c, []u32{1, 12<<16, id}); extension_pump(&c) }
	return c
}
shell_test_buffer :: proc(c: ^Extension_Client, width: i32 = 64, height: i32 = 48, bind_shm := true) {
	if bind_shm { extension_bind(c, "wl_shm", 1, 20) }
	fd, err := linux.memfd_create("shell-buffer", {.CLOEXEC})
	assert(err == .NONE)
	assert(linux.ftruncate(fd, i64(width*height*4)) == .NONE)
	words := [4]u32{20, 16<<16, 21, u32(width*height*4)}
	assert(wl.connection_queue(&c.peer, (cast([^]u8)&words)[:size_of(words)], []linux.Fd{fd}) == .NONE)
	assert(wl.connection_flush(&c.peer) == .NONE)
	extension_send(c, []u32{21, 32<<16, 22, 0, u32(width), u32(height), u32(width*4), 0, 21, 8<<16|1})
	extension_pump(c)
}
shell_test_initial :: proc(t: ^testing.T, c: ^Extension_Client) -> u32 {
	extension_send(c, []u32{6, 8<<16|6})
	events := extension_pump(c)
	configure := extension_event(events, 8, 0)
	assert(configure != nil)
	testing.expect(t, extension_event(events, 9, 0) != nil)
	return wl.word_read(configure, 8)
}
shell_test_error :: proc(t: ^testing.T, c: ^Extension_Client, object, code: u32) {
	err := extension_event(extension_pump(c), 1, 0)
	if !testing.expect(t, err != nil, "wire protocol error") { return }
	testing.expect_value(t, wl.word_read(err, 8), object)
	testing.expect_value(t, wl.word_read(err, 12), code)
	testing.expect(t, wl.empty(&c.display.clients), "client disconnected")
}

@(test)
owned_toplevel_configure_metadata_mapping_and_remapping :: proc(t: ^testing.T) {
	s := shell_test_server()
	defer shell_test_finish(s)
	c := shell_test_client(s)
	defer wl.connection_close(&c.peer)
	assert(len(s.views) == 1)
	v := s.views[0]
	top := xdg(v)
	testing.expect(t, !top.initialized && top.idle == nil && len(top.queue) == 0, "no configure before the first empty commit")
	extension_text_request(&c, 9, 2, "Shell title")
	extension_text_request(&c, 9, 3, "org.kiln.ShellTest")
	extension_pump(&c)
	testing.expect_value(t, top.title, "Shell title")
	testing.expect_value(t, top.app_id, "org.kiln.ShellTest")
	testing.expect(t, len(s.events) >= 2 && s.events[len(s.events)-1].app_id == "org.kiln.ShellTest", "metadata reached the compositor")
	extension_bind(&c, "zxdg_decoration_manager_v1", 1, 10)
	extension_send(&c, []u32{10, 16<<16|1, 11, 9, 11, 12<<16|1, 1})
	extension_pump(&c)
	testing.expect(t, v.decoration != nil && v.decoration_requested && v.decoration_mode == 1)
	serial := shell_test_initial(t, &c)
	testing.expect_value(t, serial, u32(1))
	testing.expect_value(t, v.decoration.scheduled_mode, i32(2))
	testing.expect(t, !v.mapped && top.initialized && top.initial_commit)
	extension_send(&c, []u32{8, 12<<16|4, serial})
	extension_pump(&c)
	testing.expect_value(t, top.current.tiled, u32(0))
	shell_test_buffer(&c)
	extension_send(&c, []u32{6, 20<<16|1, 22, 0, 0, 6, 8<<16|6})
	extension_pump(&c)
	testing.expect(t, v.mapped && top.surface.mapped && !top.initial_commit, "map signal reached the view")
	testing.expect_value(t, top.geometry, gles.Box{0,0,64,48})
	testing.expect_value(t, v.decoration.current_mode, i32(2))
	testing.expect_value(t, top.current.tiled, u32(15))
	sh.set_size(top, 100, 80); sh.set_maximized(top, true); sh.set_activated(top, true)
	events := extension_pump(&c)
	testing.expect_value(t, extension_event_count(events, 8, 0), 1)
	serial = wl.word_read(extension_event(events, 8, 0), 8)
	extension_send(&c, []u32{8, 12<<16|4, serial})
	extension_pump(&c)
	testing.expect(t, !top.current.maximized && top.current.width == 0, "ack only changes pending state")
	extension_send(&c, []u32{6, 8<<16|6})
	extension_pump(&c)
	testing.expect(t, top.current.maximized && top.current.activated && top.current.width == 100)
	extension_send(&c, []u32{6, 20<<16|1, 0, 0, 0, 6, 8<<16|6})
	events = extension_pump(&c)
	testing.expect(t, !v.mapped && !top.initialized && !top.initial_commit && top.title == "")
	testing.expect(t, extension_event(events, 8, 0) == nil, "unmapping commit is not the next initial commit")
	serial = shell_test_initial(t, &c)
	extension_send(&c, []u32{8, 12<<16|4, serial, 6, 20<<16|1, 22, 0, 0, 6, 8<<16|6})
	extension_pump(&c)
	testing.expect(t, v.mapped && v.map_epoch == 2)
	extension_send(&c, []u32{11, 8<<16, 9, 8<<16, 8, 8<<16, 6, 8<<16, 7, 8<<16})
	events = extension_pump(&c)
	testing.expect(t, extension_event(events, 1, 0) == nil && len(s.views) == 0)
}

@(test)
owned_toplevel_rejects_invalid_protocol_sequences :: proc(t: ^testing.T) {
	for scenario in 0..<10 {
		s := shell_test_server()
		defer shell_test_finish(s)
		c := shell_test_client(s)
		defer wl.connection_close(&c.peer)
		object, code := u32(8), u32(p.Xdg_Surface_Error.invalid_serial)
		switch scenario {
		case 0, 1:
			serial := shell_test_initial(t, &c)
			if scenario == 0 { extension_send(&c, []u32{8, 12<<16|4, serial}); extension_pump(&c) }
			extension_send(&c, []u32{8, 12<<16|4, serial if scenario == 0 else 0})
		case 2, 3:
			shell_test_buffer(&c)
			if scenario == 3 { shell_test_initial(t, &c) }
			extension_send(&c, []u32{6, 20<<16|1, 22, 0, 0, 6, 8<<16|6})
			code = u32(p.Xdg_Surface_Error.unconfigured_buffer)
		case 4:
			extension_send(&c, []u32{8, 24<<16|3, 0, 0, 0, 30})
			code = u32(p.Xdg_Surface_Error.invalid_size)
		case 5:
			extension_send(&c, []u32{8, 12<<16|1, 12})
			code = u32(p.Xdg_Surface_Error.already_constructed)
		case 6:
			extension_send(&c, []u32{8, 8<<16})
			code = u32(p.Xdg_Surface_Error.defunct_role_object)
		case 7:
			extension_send(&c, []u32{7, 8<<16})
			object, code = 7, u32(p.Xdg_Wm_Base_Error.defunct_surfaces)
		case 8:
			extension_send(&c, []u32{9, 16<<16|8, 10, 20, 9, 16<<16|7, 5, 10, 6, 8<<16|6})
			object, code = 9, u32(p.Xdg_Toplevel_Error.invalid_size)
		case 9:
			extension_send(&c, []u32{9, 12<<16|1, 9})
			object, code = 9, u32(p.Xdg_Toplevel_Error.invalid_parent)
		}
		shell_test_error(t, &c, object, code)
		testing.expect_value(t, len(s.views), 0)
	}
}

@(test)
owned_toplevel_serial_wrap_versions_and_destroy_orders :: proc(t: ^testing.T) {
	for version in ([4]u32{1,2,5,6}) {
		s := shell_test_server()
		defer shell_test_finish(s)
		c := shell_test_client(s, version)
		defer wl.connection_close(&c.peer)
		top := xdg(s.views[0])
		top.base.serial = max(u32)
		testing.expect_value(t, shell_test_initial(t, &c), u32(1))
		sh.set_suspended(top, true); sh.set_tiled(top, 15)
		events := extension_pump(&c)
		event := extension_event(events, 9, 0)
		assert(event != nil)
		testing.expect_value(t, wl.word_read(event, 16), u32(0 if version == 1 else 20 if version == 6 else 16))
		if version == 1 {
			extension_send(&c, []u32{6, 8<<16})
			shell_test_error(t, &c, 6, 4)
			continue
		}
		else if version == 2 { extension_send(&c, []u32{9, 8<<16, 8, 8<<16, 6, 8<<16}) }
		else { wl.connection_close(&c.peer) }
		events = extension_pump(&c)
		testing.expect(t, extension_event(events, 1, 0) == nil && len(s.views) == 0)
	}
}

@(test)
owned_decorations_force_server_mode_and_validate_lifetime :: proc(t: ^testing.T) {
	for scenario in 0..<5 {
		s := shell_test_server()
		defer shell_test_finish(s)
		c := shell_test_client(s)
		defer wl.connection_close(&c.peer)
		events := extension_bind(&c, "org_kde_kwin_server_decoration_manager", 1, 12)
		testing.expect_value(t, wl.word_read(extension_event(events, 12, 0), 8), u32(2))
		extension_send(&c, []u32{12, 16<<16, 13, 6, 13, 12<<16|1, 1, 13, 12<<16|1, 0})
		events = extension_pump(&c)
		testing.expect_value(t, extension_event_count(events, 13, 0), 3)
		for at := 0; at < len(events); at += int(wl.word_read(events, at+4)>>16) {
			if wl.word_read(events, at) == 13 { testing.expect_value(t, wl.word_read(events, at+8), u32(2)) }
		}
		extension_bind(&c, "zxdg_decoration_manager_v1", 1, 10)
		if scenario == 3 {
			serial := shell_test_initial(t, &c)
			shell_test_buffer(&c)
			extension_send(&c, []u32{8, 12<<16|4, serial, 6, 20<<16|1, 22, 0, 0, 6, 8<<16|6})
			extension_pump(&c)
		}
		extension_send(&c, []u32{10, 16<<16|1, 11, 9})
		if scenario == 3 { shell_test_error(t, &c, 10, 0); continue }
		extension_pump(&c)
		switch scenario {
		case 0:
			extension_send(&c, []u32{11, 12<<16|1, 1, 6, 8<<16|6})
			events = extension_pump(&c)
			deco, configure := extension_event(events, 11, 0), extension_event(events, 8, 0)
			assert(deco != nil && configure != nil)
			testing.expect_value(t, wl.word_read(deco, 8), u32(2))
			testing.expect(t, uintptr(raw_data(deco)) < uintptr(raw_data(configure)), "decoration precedes surface configure")
			extension_send(&c, []u32{11, 8<<16|2})
			events = extension_pump(&c)
			testing.expect(t, extension_event(events, 8, 0) != nil)
		case 1:
			extension_send(&c, []u32{10, 16<<16|1, 14, 9})
			shell_test_error(t, &c, 10, 1)
		case 2:
			extension_send(&c, []u32{11, 12<<16|1, 9})
			shell_test_error(t, &c, 11, 3)
		case 4:
			extension_send(&c, []u32{9, 8<<16})
			shell_test_error(t, &c, 11, 2)
		}
	}
}

@(test)
owned_toplevel_geometry_includes_subsurfaces_and_latches_explicit_bounds :: proc(t: ^testing.T) {
	s := shell_test_server()
	defer shell_test_finish(s)
	assert(sf.subcompositor_create(s.display) != nil)
	c := shell_test_client(s)
	defer wl.connection_close(&c.peer)
	serial := shell_test_initial(t, &c)
	shell_test_buffer(&c, 64, 48)
	extension_bind(&c, "wl_subcompositor", 1, 10)
	extension_send(&c, []u32{5, 12<<16, 11, 10, 20<<16|1, 12, 11, 6,
		12, 16<<16|1, ~u32(19), ~u32(9), 11, 20<<16|1, 22, 0, 0, 11, 8<<16|6,
		8, 12<<16|4, serial, 6, 20<<16|1, 22, 0, 0, 6, 8<<16|6})
	extension_pump(&c)
	top := xdg(s.views[0])
	testing.expect(t, top.surface.mapped)
	testing.expect_value(t, top.geometry, gles.Box{-20,-10,84,58})
	extension_send(&c, []u32{8, 24<<16|3, ~u32(29), ~u32(29), 100, 100})
	extension_pump(&c)
	testing.expect(t, top.geometry == (gles.Box{-20,-10,84,58}), "geometry is double-buffered")
	extension_send(&c, []u32{6, 8<<16|6})
	extension_pump(&c)
	testing.expect(t, top.geometry == (gles.Box{-20,-10,84,58}), "explicit bounds are clamped to extents")
	extension_send(&c, []u32{12, 16<<16|1, ~u32(39), ~u32(19), 6, 8<<16|6})
	extension_pump(&c)
	testing.expect(t, top.geometry == (gles.Box{-30,-20,94,68}), "explicit box is remembered and effective geometry is re-clamped")
	extension_send(&c, []u32{8, 24<<16|3, 5, 6, 20, 30, 6, 8<<16|6})
	extension_pump(&c)
	testing.expect_value(t, top.geometry, gles.Box{5,6,20,30})
}

@(test)
owned_toplevel_creation_and_decoration_reject_pending_buffers :: proc(t: ^testing.T) {
	s := shell_test_server()
	defer shell_test_finish(s)
	c := shell_test_client(s)
	defer wl.connection_close(&c.peer)
	shell_test_buffer(&c)
	serial := shell_test_initial(t, &c)
	extension_send(&c, []u32{8, 12<<16|4, serial})
	extension_pump(&c)
	extension_bind(&c, "zxdg_decoration_manager_v1", 1, 10)
	extension_send(&c, []u32{10, 16<<16|1, 11, 9, 6, 20<<16|1, 22, 0, 0, 6, 8<<16|6})
	shell_test_error(t, &c, 11, 0)
}

@(test)
owned_toplevel_recreation_keeps_surface_serials_and_cancels_idle :: proc(t: ^testing.T) {
	s := shell_test_server()
	defer shell_test_finish(s)
	c := shell_test_client(s)
	defer wl.connection_close(&c.peer)
	extension_send(&c, []u32{6, 8<<16|6, 9, 8<<16, 8, 12<<16|1, 9})
	cancelled := extension_pump(&c)
	testing.expect(t, extension_event(cancelled, 8, 0) == nil, "destroy cancels the pending idle configure")
	first := shell_test_initial(t, &c)
	testing.expect_value(t, first, u32(2))
	extension_send(&c, []u32{9, 8<<16, 8, 12<<16|1, 9, 6, 8<<16|6})
	events := extension_pump(&c)
	configure := extension_event(events, 8, 0)
	assert(configure != nil)
	testing.expect_value(t, wl.word_read(configure, 8), first+1)
	testing.expect_value(t, len(s.views), 1)
	extension_send(&c, []u32{8, 12<<16|4, first})
	shell_test_error(t, &c, 8, u32(p.Xdg_Surface_Error.invalid_serial))
}

@(test)
owned_toplevel_accepts_raw_title_and_reclamps_smaller_buffer :: proc(t: ^testing.T) {
	s := shell_test_server()
	defer shell_test_finish(s)
	c := shell_test_client(s)
	defer wl.connection_close(&c.peer)
	extension_text_request(&c, 9, 2, "raw\xfftitle")
	extension_pump(&c)
	top := xdg(s.views[0])
	testing.expect_value(t, top.title, "raw\xfftitle")
	serial := shell_test_initial(t, &c)
	shell_test_buffer(&c)
	extension_send(&c, []u32{8, 12<<16|4, serial, 8, 24<<16|3, 0, 0, 64, 48, 6, 20<<16|1, 22, 0, 0, 6, 8<<16|6})
	extension_pump(&c)
	testing.expect_value(t, top.geometry, gles.Box{0,0,64,48})
	extension_send(&c, []u32{22, 8<<16})
	extension_pump(&c)
	shell_test_buffer(&c, 32, 24, false)
	extension_send(&c, []u32{6, 20<<16|1, 22, 0, 0, 6, 8<<16|6})
	extension_pump(&c)
	testing.expect_value(t, top.geometry, gles.Box{0,0,32,24})
}
