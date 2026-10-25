package compositor

import bk "../backend"
import sf "../surfaces"
import st "../seat"
import km "../keymap"
import wl "../wayland"
import p "../protocols"
import "core:sys/linux"
import "core:testing"

@(test)
owned_seat_keyboard_keymap_pressed_keys_and_display_serials :: proc(t: ^testing.T) {
	s := extension_server()
	defer extension_finish(s)
	st.set_capabilities(s.seat, 3)
	kb: st.Keyboard
	st.keyboard_init(&kb, nil)
	defer st.keyboard_finish(&kb)
	map_, ok := km.create_default()
	assert(ok)
	defer km.destroy(map_)
	testing.expect(t, st.keyboard_set_keymap(&kb, map_))
	st.set_keyboard(s.seat, &kb)
	c := extension_client(s, 9)
	defer wl.connection_close(&c.peer)
	binding := extension_bind(&c, "wl_seat", 9, 7)
	testing.expect_value(t, wl.word_read(extension_event(binding, 7, 0),8), u32(3))
	testing.expect(t, extension_event(binding,7,1) != nil, "seat name on bind")
	extension_send(&c, []u32{3,12<<16|1,8,7,12<<16|1,9})
	events := extension_pump(&c)
	for id in ([]u32{8,9}) {
		keymap_event := extension_event(events,id,0)
		testing.expect_value(t, wl.word_read(keymap_event,8), u32(1))
		testing.expect_value(t, wl.word_read(keymap_event,12), kb.keymap_size)
		repeat := extension_event(events,id,5)
		testing.expect_value(t, wl.word_read(repeat,8), u32(25))
		testing.expect_value(t, wl.word_read(repeat,12), u32(600))
		fd := wl.fd_take(&c.peer.fds_in)
		defer linux.close(fd)
		seals, err := linux.fcntl(fd, linux.F_GET_SEALS)
		testing.expect(t, err == .NONE && {.SHRINK,.GROW,.WRITE} <= seals)
		last: [1]u8
		n, read_err := linux.pread(fd,last[:],i64(kb.keymap_size)-1)
		testing.expect(t, read_err == .NONE && n == 1 && last[0] == 0, "keymap size includes NUL")
		testing.expect(t, linux.ftruncate(fd,0) != .NONE)
	}
	press := bk.Key_Event{keycode=42,state=1}
	st.keyboard_update_key(&kb,&press)
	testing.expect(t, kb.modifiers.depressed != 0 && km.modifier_mask(kb.state)&1 != 0)
	surface := sf.of(wl.client_get_object(c.client,6))
	before := s.display.serial
	st.keyboard_notify_enter(s.seat,surface)
	events = extension_pump(&c)
	for id in ([]u32{8,9}) {
		enter := extension_event(events,id,1)
		testing.expect_value(t, wl.word_read(enter,8), before+1)
		testing.expect_value(t, wl.word_read(enter,16), u32(4))
		testing.expect_value(t, wl.word_read(enter,20), u32(42))
		mods := extension_event(events,id,4)
		testing.expect_value(t, wl.word_read(mods,8), before+2)
		testing.expect_value(t, wl.word_read(mods,12), kb.modifiers.depressed)
	}
	st.keyboard_notify_key(s.seat,77,30,1)
	st.keyboard_notify_modifiers(s.seat,&kb.modifiers)
	events = extension_pump(&c)
	key := extension_event(events,8,3)
	testing.expect_value(t, wl.word_read(key,8), before+3)
	testing.expect_value(t, wl.word_read(key,12), u32(77))
	testing.expect_value(t, wl.word_read(key,16), u32(30))
	client := st.client_of(wl.client_get_object(c.client,3))
	testing.expect(t, st.valid_serial(client,before+3) && !st.valid_serial(client,before+5))
	st.keyboard_notify_clear_focus(s.seat)
	events = extension_pump(&c)
	testing.expect_value(t, wl.word_read(extension_event(events,8,2),8), before+5)
	st.keyboard_enter(s.seat,surface,nil,{})
	events = extension_pump(&c)
	testing.expect_value(t, wl.word_read(extension_event(events,8,1),16),u32(0))
	st.keyboard_set_repeat_info(&kb,0,100)
	events = extension_pump(&c)
	testing.expect_value(t,wl.word_read(extension_event(events,9,5),8),u32(0))
}

@(test)
owned_pointer_versions_focus_cursor_serial_and_resource_lifetimes :: proc(t: ^testing.T) {
	for version in ([]u32{4,5,7,8,9}) {
		s := extension_server()
		defer extension_finish(s)
		c := extension_client(s,version)
		defer wl.connection_close(&c.peer)
		extension_bind(&c,"wl_seat",version,7)
		extension_send(&c,[]u32{7,12<<16,8})
		extension_pump(&c)
		serial := extension_focus(s,&c)
		client := st.pointer_client_of(wl.client_get_object(c.client,4))
		testing.expect(t, st.pointer_client_of(wl.client_get_object(c.client,8)) == client)
		Probe :: struct { listener: wl.Listener, count: int, hotspot: i32 }
		probe: Probe
		wl.listen(&s.seat.events.request_set_cursor,&probe.listener,proc(l: ^wl.Listener,data: rawptr) {
			probe := wl.owner(l,Probe,"listener")
			probe.count += 1
			probe.hotspot = (cast(^st.Cursor_Event)data).hotspot_x
		})
		defer wl.unlisten(&probe.listener)
		extension_send(&c,[]u32{4,24<<16,serial-1,0,2,3,4,24<<16,serial,0,5,6})
		extension_pump(&c)
		testing.expect_value(t,probe.count,1)
		testing.expect_value(t,probe.hotspot,i32(5))
		st.pointer_notify_motion(s.seat,10,12.5,30)
		button := st.pointer_notify_button(s.seat,11,272,1)
		st.pointer_notify_axis(s.seat,12,0,15,120,0,1)
		st.pointer_notify_frame(s.seat)
		events := extension_pump(&c)
		for id in ([]u32{4,8}) {
			testing.expect(t,extension_event(events,id,2) != nil)
			testing.expect_value(t,wl.word_read(extension_event(events,id,3),8),button)
			testing.expect(t,(extension_event(events,id,5) != nil) == (version>=5))
			testing.expect(t,(extension_event(events,id,8) != nil) == (version>=5 && version<8))
			testing.expect(t,(extension_event(events,id,9) != nil) == (version>=8))
			testing.expect(t,(extension_event(events,id,10) != nil) == (version>=9))
		}
		testing.expect(t,st.valid_serial(client,button))
		extension_send(&c,[]u32{4,24<<16,button,0,9,9})
		extension_pump(&c)
		testing.expect_value(t,probe.count,1)
		st.pointer_notify_clear_focus(s.seat)
		events=extension_pump(&c)
		testing.expect(t,extension_event(events,4,1) != nil && extension_event(events,8,1) != nil)
		extension_send(&c,[]u32{4,24<<16,serial,0,9,9})
		extension_pump(&c)
		testing.expect_value(t,probe.count,1)
	}
}

@(test)
owned_seat_surface_destruction_and_missing_touch_capability :: proc(t: ^testing.T) {
	s := extension_server()
	defer extension_finish(s)
	c := extension_client(s,9)
	defer wl.connection_close(&c.peer)
	extension_focus(s,&c)
	st.keyboard_notify_enter(s.seat,s.seat.pointer_state.focused_surface)
	extension_send(&c,[]u32{6,8<<16})
	extension_pump(&c)
	testing.expect(t,s.seat.keyboard_state.focused_surface == nil && s.seat.pointer_state.focused_surface == nil)
	extension_send(&c,[]u32{3,12<<16|2,7})
	err := extension_event(extension_pump(&c),1,0)
	testing.expect(t,err != nil)
	testing.expect_value(t,wl.word_read(err,12),u32(p.Wl_Seat_Error.missing_capability))
}

@(test)
owned_popup_grab_accepts_pointer_button_and_keyboard_serials :: proc(t: ^testing.T) {
	for keyboard in ([]bool{false,true}) {
		s := shell_test_server(); defer shell_test_finish(s)
		c := shell_test_client(s); defer wl.connection_close(&c.peer)
		popup_test_parent(t,&c); popup_test_positioner(&c)
		extension_focus(s,&c)
		serial: u32
		if keyboard {
			st.keyboard_notify_enter(s.seat,xdg(s.views[0]).surface)
			st.keyboard_notify_key(s.seat,1,30,1)
			serial = s.display.serial
		} else { serial = st.pointer_notify_button(s.seat,1,272,1) }
		popup_test_create(&c,11,12,13,8)
		extension_send(&c,[]u32{13,16<<16|1,3,serial})
		events := extension_pump(&c)
		testing.expect(t,extension_event(events,1,0) == nil && s.popups[0].handle.grabbed)
	}
}

@(test)
owned_pointer_cursor_surface_commits_and_rejects_other_roles :: proc(t: ^testing.T) {
	s := shell_test_server(); defer shell_test_finish(s)
	c := shell_test_client(s); defer wl.connection_close(&c.peer)
	popup_test_parent(t,&c)
	serial := extension_focus(s,&c)
	extension_send(&c,[]u32{5,12<<16,11,4,24<<16,serial,11,2,3})
	testing.expect(t,extension_event(extension_pump(&c),1,0) == nil)
	cursor := sf.of(wl.client_get_object(c.client,11))
	extension_send(&c,[]u32{11,20<<16|1,22,0,0,11,8<<16|6})
	testing.expect(t,extension_event(extension_pump(&c),1,0) == nil && cursor.mapped)
	testing.expect_value(t,cursor.current.width,i32(64))
	// A role conflict must fail on the pointer even when the surface has a valid buffer.
	extension_send(&c,[]u32{4,24<<16,serial,6,0,0})
	shell_test_error(t,&c,4,u32(p.Wl_Pointer_Error.role))
}

@(test)
owned_seat_destroy_leaves_bound_and_new_children_inert :: proc(t: ^testing.T) {
	s := extension_server(); defer extension_finish(s)
	c := extension_client(s,9); defer wl.connection_close(&c.peer)
	extension_focus(s,&c)
	st.destroy(s.seat); s.seat = nil
	extension_send(&c,[]u32{3,12<<16,7,3,12<<16|1,8,7,24<<16,0,0,0,0,4,8<<16|1,7,8<<16|1,8,8<<16,3,8<<16|3})
	testing.expect(t,extension_event(extension_pump(&c),1,0) == nil)
}
