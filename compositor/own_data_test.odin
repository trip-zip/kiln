package compositor

import sf "../surfaces"

import st "../seat"
import wl "../wayland"
import p "../protocols"
import "core:sys/linux"
import "core:testing"

data_bind :: proc(c: ^Extension_Client, primary: bool, version: u32 = 3) {
	extension_bind(c, "zwp_primary_selection_device_manager_v1" if primary else "wl_data_device_manager", 1 if primary else version, 7)
	extension_send(c, []u32{7,16<<16|1,8,3,7,12<<16,9})
	extension_text_request(c,9,0,"text/plain")
	extension_pump(c)
}
data_surface :: proc(c: ^Extension_Client) -> ^sf.Surface { return sf.of(wl.client_get_object(c.client,6)) }
data_selection :: proc(s: ^Server, c: ^Extension_Client, primary: bool) -> []u8 {
	st.keyboard_notify_enter(s.seat,data_surface(c))
	st.keyboard_notify_key(s.seat,1,30,1)
	extension_pump(c)
	extension_send(c,[]u32{8,16<<16|(0 if primary else 1),9,s.display.serial})
	return extension_pump(c)
}
data_receive :: proc(c: ^Extension_Client, offer: u32, primary: bool, fd: linux.Fd) {
	bytes := make([]u8,24,context.temp_allocator)
	wl.word_write(bytes,0,offer); wl.word_write(bytes,4,24<<16|(0 if primary else 1)); wl.word_write(bytes,8,11)
	copy(bytes[12:],"text/plain")
	duplicate, err := linux.fcntl(fd, linux.F_DUPFD_CLOEXEC, 0); assert(err == .NONE)
	assert(wl.connection_queue(&c.peer,bytes,[]linux.Fd{duplicate}) == .NONE)
	assert(wl.connection_flush(&c.peer) == .NONE)
}
data_accept :: proc(c: ^Extension_Client, offer: u32) {
	bytes := make([]u8,28,context.temp_allocator)
	wl.word_write(bytes,0,offer); wl.word_write(bytes,4,28<<16); wl.word_write(bytes,8,1); wl.word_write(bytes,12,11)
	copy(bytes[16:],"text/plain")
	assert(wl.connection_queue(&c.peer,bytes,nil) == .NONE); assert(wl.connection_flush(&c.peer) == .NONE)
}
@(test)
owned_selections_offer_focus_receive_destroy_and_multiple_bindings :: proc(t: ^testing.T) {
	for primary in ([]bool{false,true}) {
		s := extension_server(); defer extension_finish(s)
		assert(init_data(s)); extension_hold_events(s)
		a,b := extension_client(s),extension_client(s)
		defer wl.connection_close(&a.peer); defer wl.connection_close(&b.peer)
		data_bind(&a,primary); data_bind(&b,primary)
		events := data_selection(s,&a,primary)
		first := extension_event(events,8,0); assert(first != nil)
		offer := wl.word_read(first,8)
		testing.expect_value(t,extension_event_string(extension_event(events,offer,0)),"text/plain")
		testing.expect_value(t,wl.word_read(extension_event(events,8,1 if primary else 5),8),offer)
		st.keyboard_notify_enter(s.seat,data_surface(&b)); events=extension_pump(&b)
		offer=wl.word_read(extension_event(events,8,0),8)
		testing.expect(t,extension_event(events,offer,0) != nil && extension_event(events,8,1 if primary else 5) != nil)
		extension_send(&b,[]u32{7,16<<16|1,10,3})
		testing.expect(t,extension_event(extension_pump(&b),10,1 if primary else 5) != nil,"new device receives focused selection")
		fds: [2]linux.Fd; assert(linux.pipe2(&fds,{.CLOEXEC,.NONBLOCK}) == .NONE)
		defer linux.close(fds[0]); defer linux.close(fds[1])
		data_receive(&b,offer,primary,fds[1]); extension_pump(&b); events=extension_pump(&a)
		testing.expect_value(t,extension_event_string(extension_event(events,9,0 if primary else 1)),"text/plain")
		fd := wl.fd_take(&a.peer.fds_in); assert(fd>=0)
		linux.write(fd,transmute([]u8)string("selection payload")); linux.close(fd)
		buffer: [64]u8; n,err := linux.read(fds[0],buffer[:])
		testing.expect(t,err == .NONE && string(buffer[:n]) == "selection payload")
		// Closing the transferred duplicate must leave the caller's descriptor usable.
		n,err=linux.write(fds[1],[]u8{42}); testing.expect(t,err == .NONE && n == 1)
		extension_send(&a,[]u32{9,8<<16|(1 if primary else 1)})
		extension_pump(&a); events=extension_pump(&b)
		testing.expect_value(t,wl.word_read(extension_event(events,8,1 if primary else 5),8),u32(0))
		testing.expect_value(t,wl.word_read(extension_event(events,10,1 if primary else 5),8),u32(0))
		testing.expect(t,s.seat.selection_source == nil && s.seat.primary_selection_source == nil)
	}
}
@(test)
owned_drag_serial_focus_actions_drop_finish_and_lua_events :: proc(t: ^testing.T) {
	for preferred in ([]u32{1,2,4}) {
		s := extension_server(); defer extension_finish(s)
		assert(init_data(s)); extension_hold_events(s)
		a,b := extension_client(s),extension_client(s)
		defer wl.connection_close(&a.peer); defer wl.connection_close(&b.peer)
		data_bind(&a,false); data_bind(&b,false)
		extension_send(&a,[]u32{9,12<<16|2,7}); extension_pump(&a)
		extension_focus(s,&a); serial:=st.pointer_notify_button(s.seat,1,272,1)
		extension_send(&a,[]u32{8,24<<16,9,6,0,serial-1}); extension_pump(&a)
		testing.expect(t,s.seat.drag == nil && !s.drag_active)
		extension_send(&a,[]u32{8,24<<16,9,6,0,serial}); extension_pump(&a)
		testing.expect(t,s.seat.drag != nil && s.drag_active && s.events[len(s.events)-1].class == "drag" && s.events[len(s.events)-1].name == "start")
		st.pointer_notify_enter(s.seat,data_surface(&b),10,20)
		st.pointer_notify_motion(s.seat,3,12,21)
		events:=extension_pump(&b)
		testing.expect(t,extension_event(events,4,0) == nil,"drag owns focus instead of wl_pointer")
		offer:=wl.word_read(extension_event(events,8,0),8)
		testing.expect(t,extension_event(events,8,1) != nil && extension_event(events,8,3) != nil)
		testing.expect_value(t,wl.word_read(extension_event(events,offer,1),8),u32(7))
		data_accept(&b,offer); extension_send(&b,[]u32{offer,16<<16|4,7,preferred})
		events=extension_pump(&b)
		testing.expect_value(t,wl.word_read(extension_event(events,offer,2),8),preferred)
		st.pointer_notify_button(s.seat,4,272,0)
		events=extension_pump(&b)
		testing.expect(t,extension_event(events,8,4) != nil && extension_event(events,8,2) != nil)
		testing.expect(t,!s.drag_active && s.seat.drag == nil && s.events[len(s.events)-1].name == "end")
		events=extension_pump(&a); testing.expect(t,extension_event(events,9,3) != nil)
		if preferred == 4 { extension_send(&b,[]u32{offer,16<<16|4,1,1}) }
		else { extension_send(&b,[]u32{offer,16<<16|4,7,preferred}) }
		extension_send(&b,[]u32{offer,8<<16|3}); extension_pump(&b)
		testing.expect(t,extension_event(extension_pump(&a),9,4) != nil,"source receives dnd_finished")
	}
}
@(test)
owned_drag_icon_commit_lifetime_and_lock_cancellation :: proc(t: ^testing.T) {
	s := shell_test_server(); defer shell_test_finish(s)
	assert(init_data(s))
	c:=shell_test_client(s); defer wl.connection_close(&c.peer)
	popup_test_parent(t,&c)
	extension_bind(&c,"wl_data_device_manager",3,14)
	extension_send(&c,[]u32{14,16<<16|1,15,3,14,12<<16,16,16,12<<16|2,1,5,12<<16,17})
	extension_text_request(&c,16,0,"text/plain"); extension_pump(&c)
	extension_focus(s,&c); serial:=st.pointer_notify_button(s.seat,1,272,1)
	extension_send(&c,[]u32{15,24<<16,16,6,17,serial,17,20<<16|1,22,0,0,17,8<<16|6})
	testing.expect(t,extension_event(extension_pump(&c),1,0) == nil && s.drag_icon != nil && s.drag_icon.surface.mapped)
	lock_reset_input(s)
	events:=extension_pump(&c)
	testing.expect(t,s.drag_icon == nil && !s.drag_active && s.seat.drag == nil)
	testing.expect(t,extension_event(events,16,2) != nil,"lock cancels source")
	// The icon keeps its permanent role after the drag ends.
	serial = extension_focus(s,&c)
	extension_send(&c,[]u32{4,24<<16,serial,17,0,0})
	shell_test_error(t,&c,4,u32(p.Wl_Pointer_Error.role))
}
@(test)
owned_data_protocol_errors :: proc(t: ^testing.T) {
	for mode in 0..<7 {
		s:=extension_server(); defer extension_finish(s)
		assert(init_data(s)); extension_hold_events(s)
		c:=extension_client(s); defer wl.connection_close(&c.peer); data_bind(&c,false)
		id,code:=u32(9),u32(0)
		switch mode {
		case 0: extension_send(&c,[]u32{9,12<<16|2,8})
		case 1: extension_send(&c,[]u32{9,12<<16|2,1,9,12<<16|2,1}); code=1
		case 2:
			data_selection(s,&c,false)
			extension_send(&c,[]u32{8,16<<16|1,9,s.display.serial})
			testing.expect(t,extension_event(extension_pump(&c),1,0) == nil,"identical selection retry is harmless")
			st.set_selection(s.seat,nil,wl.next_serial(s.display))
			extension_send(&c,[]u32{8,16<<16|1,9,s.display.serial}); id,code=8,1
		case 3,4,5,6:
			events:=data_selection(s,&c,false); id=wl.word_read(extension_event(events,8,0),8)
			if mode == 3 { extension_send(&c,[]u32{id,8<<16|3}); code=0 }
			else if mode == 4 { extension_send(&c,[]u32{id,16<<16|4,1,1}); code=3 }
			else {
				st.set_selection(s.seat,nil,wl.next_serial(s.display))
				extension_send(&c,[]u32{7,12<<16,10,10,12<<16|2,7}); extension_text_request(&c,10,0,"text/plain"); extension_pump(&c)
				extension_focus(s,&c); serial:=st.pointer_notify_button(s.seat,1,272,1)
				extension_send(&c,[]u32{8,24<<16,10,6,0,serial}); extension_pump(&c)
				st.pointer_notify_enter(s.seat,data_surface(&c),1,1)
				id=wl.word_read(extension_event(extension_pump(&c),8,0),8)
				extension_send(&c,[]u32{id,16<<16|4,8 if mode==5 else 3,0 if mode==5 else 3}); code=1 if mode==5 else 2
			}
		}
		shell_test_error(t,&c,id,code)
	}
}

@(test)
owned_drag_legacy_null_source_and_cancellation_lifetimes :: proc(t: ^testing.T) {
	for mode in 0..<5 {
		s:=extension_server(); defer extension_finish(s)
		assert(init_data(s)); extension_hold_events(s)
		a,b:=extension_client(s),extension_client(s)
		defer wl.connection_close(&a.peer); defer wl.connection_close(&b.peer)
		data_bind(&a,false); data_bind(&b,false,1)
		extension_focus(s,&a); serial:=st.pointer_notify_button(s.seat,1,272,1)
		if mode == 4 { s.lock_owner = .Native }
		extension_send(&a,[]u32{8,24<<16,0 if mode==1 else 9,6,0,serial}); extension_pump(&a)
		if mode == 4 {
			testing.expect(t,s.seat.drag == nil && !s.drag_active)
			testing.expect(t,extension_event(extension_pump(&a),9,2) != nil || (cast(^st.Source)wl.client_get_object(a.client,9).data).cancelled)
			continue
		}
		st.pointer_notify_enter(s.seat,data_surface(&b),1,1)
		events:=extension_pump(&b)
		if mode == 1 {
			testing.expect(t,extension_event(events,8,1) == nil,"null source never enters another client")
			st.pointer_notify_enter(s.seat,data_surface(&a),1,1)
			events=extension_pump(&a); testing.expect(t,extension_event(events,8,1) != nil)
			st.pointer_notify_button(s.seat,2,272,0); testing.expect(t,!s.drag_active)
		} else if mode == 2 {
			extension_send(&a,[]u32{9,8<<16|1}); extension_pump(&a)
			testing.expect(t,!s.drag_active && s.seat.drag == nil)
			testing.expect(t,extension_event(extension_pump(&b),8,2) != nil)
		} else if mode == 3 {
			extension_send(&b,[]u32{6,8<<16}); extension_pump(&b)
			st.pointer_notify_button(s.seat,2,272,0)
			testing.expect(t,extension_event(extension_pump(&a),9,2) != nil,"drop outside cancels source")
		} else {
			offer:=wl.word_read(extension_event(events,8,0),8)
			testing.expect(t,extension_event(events,offer,1) == nil && extension_event(events,offer,2) == nil,"v1 has no action events")
			data_accept(&b,offer); extension_pump(&b)
			st.pointer_notify_button(s.seat,2,272,0)
			testing.expect(t,extension_event(extension_pump(&b),8,4) != nil)
			extension_send(&b,[]u32{offer,8<<16|2}); extension_pump(&b)
			testing.expect(t,extension_event(extension_pump(&a),9,4) != nil,"legacy receiver finishes by destroying its offer")
		}
	}
}

@(test)
owned_drag_action_intersection_and_preference_table :: proc(t: ^testing.T) {
	for row in ([][4]u32{{1,2,2,0},{3,3,2,2},{7,3,0,1},{6,7,1,2},{4,7,4,4},{0,7,1,0}}) {
		s:=extension_server(); defer extension_finish(s); assert(init_data(s)); extension_hold_events(s)
		c:=extension_client(s); defer wl.connection_close(&c.peer); data_bind(&c,false)
		extension_send(&c,[]u32{9,12<<16|2,row[0]}); extension_pump(&c)
		extension_focus(s,&c); serial:=st.pointer_notify_button(s.seat,1,272,1)
		extension_send(&c,[]u32{8,24<<16,9,6,0,serial}); extension_pump(&c)
		st.pointer_notify_enter(s.seat,data_surface(&c),1,1)
		offer:=wl.word_read(extension_event(extension_pump(&c),8,0),8)
		data_accept(&c,offer); extension_send(&c,[]u32{offer,16<<16|4,row[1],row[2]}); extension_pump(&c)
		testing.expect_value(t,(cast(^st.Offer)wl.client_get_object(c.client,offer).data).action,row[3])
		st.drag_cancel(s.seat)
	}
}

@(test)
owned_selection_accepts_pointer_serial_without_keyboard_focus :: proc(t: ^testing.T) {
	for primary in ([]bool{false,true}) {
		s:=extension_server(); defer extension_finish(s); assert(init_data(s)); extension_hold_events(s)
		a,b:=extension_client(s),extension_client(s)
		defer wl.connection_close(&a.peer); defer wl.connection_close(&b.peer)
		data_bind(&a,primary); data_bind(&b,primary)
		st.keyboard_notify_enter(s.seat,data_surface(&b)); extension_pump(&b)
		extension_focus(s,&a); serial:=st.pointer_notify_button(s.seat,1,272,1)
		extension_send(&a,[]u32{8,16<<16|(0 if primary else 1),9,serial}); extension_pump(&a)
		events:=extension_pump(&b)
		testing.expect(t,extension_event(events,8,0)!=nil && extension_event(events,8,1 if primary else 5)!=nil)
		testing.expect(t,(s.seat.primary_selection_source if primary else s.seat.selection_source)!=nil)
		extension_send(&a,[]u32{8,16<<16|(0 if primary else 1),0,serial-1}); extension_pump(&a)
		testing.expect(t,(s.seat.primary_selection_source if primary else s.seat.selection_source)!=nil,"older selection serial is still rejected")
	}
}
