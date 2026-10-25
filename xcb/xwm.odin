package xcb

import raw "../xcb_raw"

Connection :: raw.xcb_connection_t
Screen :: raw.xcb_screen_t
Create :: raw.xcb_create_notify_event_t
Destroy :: raw.xcb_destroy_notify_event_t
Unmap :: raw.xcb_unmap_notify_event_t
Map :: raw.xcb_map_notify_event_t
Map_Request :: raw.xcb_map_request_event_t
Configure :: raw.xcb_configure_notify_event_t
Configure_Request :: raw.xcb_configure_request_event_t
Property :: raw.xcb_property_notify_event_t
Message :: raw.xcb_client_message_event_t
Focus :: raw.xcb_focus_in_event_t
Error :: raw.xcb_generic_error_t
Event :: union { Create, Destroy, Unmap, Map, Map_Request, Configure, Configure_Request, Property, Message, Focus, Error, Selection_Notify, Selection_Request, Selection_Owner }
connect :: proc(fd: i32) -> ^Connection {
	c := raw.xcb_connect_to_fd(fd, nil)
	if raw.xcb_connection_has_error(c) != 0 { raw.xcb_disconnect(c); return nil }; return c
}
disconnect :: raw.xcb_disconnect
flush :: raw.xcb_flush
failed :: proc(c: ^Connection) -> bool { return raw.xcb_connection_has_error(c) != 0 }
fd :: raw.xcb_get_file_descriptor
screen :: proc(c: ^Connection) -> Screen { return raw.xcb_setup_roots_iterator(raw.xcb_get_setup(c)).data^ }
intern_all :: proc(c: ^Connection, names: []string, atoms: []u32) -> bool {
	cookies := make([]raw.xcb_intern_atom_cookie_t, len(names), context.temp_allocator)
	for name, i in names { cookies[i] = raw.xcb_intern_atom(c, 0, u16(len(name)), cstring(raw_data(name))) }
	ok := true
	for cookie, i in cookies {
		reply := raw.xcb_intern_atom_reply(c, cookie, nil)
		if reply == nil { ok = false; continue }; atoms[i] = reply.atom; release(reply)
	}; return ok
}
extensions :: proc(c: ^Connection) -> (composite, xres: bool) {
	for ext in ([]^raw.xcb_extension_t{&raw.xcb_composite_id, &raw.xcb_xfixes_id, &raw.xcb_res_id}) { raw.xcb_prefetch_extension_data(c, ext) }
	if e := raw.xcb_get_extension_data(c, &raw.xcb_composite_id); e != nil && e.present != 0 {
		r := raw.xcb_composite_query_version_reply(c, raw.xcb_composite_query_version(c, 0, 4), nil)
		composite = r != nil; release(r)
	}
	if e := raw.xcb_get_extension_data(c, &raw.xcb_xfixes_id); e != nil && e.present != 0 {
		r := raw.xcb_xfixes_query_version_reply(c, raw.xcb_xfixes_query_version(c, 6, 0), nil)
		if r != nil && r.major_version >= 6 { raw.xcb_xfixes_set_client_disconnect_mode(c, 1) }; release(r)
	}
	if e := raw.xcb_get_extension_data(c, &raw.xcb_res_id); e != nil && e.present != 0 {
		r := raw.xcb_res_query_version_reply(c, raw.xcb_res_query_version(c, 1, 2), nil)
		xres = r != nil && (r.server_major > 1 || r.server_major == 1 && r.server_minor >= 2); release(r)
	}; return
}
redirect :: proc(c: ^Connection, root: u32) { raw.xcb_composite_redirect_subwindows(c, root, 1) }
watch :: proc(c: ^Connection, window, mask: u32) { value := mask; raw.xcb_change_window_attributes(c, window, 1<<11, &value) }
create_window :: proc(c: ^Connection, root, visual: u32) -> u32 {
	id := raw.xcb_generate_id(c); raw.xcb_create_window(c, 0, id, root, 0, 0, 10, 10, 0, 1, visual, 0, nil); return id
}
map_window :: proc(c: ^Connection, id: u32) { raw.xcb_map_window(c, id) }
selection_owner :: proc(c: ^Connection, window, atom: u32) { raw.xcb_set_selection_owner(c, window, atom, 0) }
write_words :: proc(c: ^Connection, window, atom, kind: u32, words: []u32) { raw.xcb_change_property(c, 0, window, atom, kind, 32, u32(len(words)), raw_data(words)) }
write_string :: proc(c: ^Connection, window, atom, kind: u32, value: string) { raw.xcb_change_property(c, 0, window, atom, kind, 8, u32(len(value)), raw_data(value)) }
configure :: proc(c: ^Connection, window: u32, mask: u16, values: []u32) { raw.xcb_configure_window(c, window, mask, raw_data(values)) }
send :: proc(c: ^Connection, window, mask: u32, event: $T) {
	// XSendEvent always reads 32 bytes, including padding absent from shorter event structs.
	value := event; bytes: [32]u8; copy(bytes[:], (cast([^]u8)&value)[:size_of(T)])
	raw.xcb_send_event(c, 0, window, mask, cast(cstring)&bytes[0])
}
focus :: proc(c: ^Connection, window: u32) -> u16 { return u16(raw.xcb_set_input_focus(c, 1, window, 0).sequence) }
focus_root :: proc(c: ^Connection) { raw.xcb_set_input_focus_checked(c, 1, 1, 0) }
Pid_Request :: distinct u32
request_pid :: proc(c: ^Connection, window: u32) -> Pid_Request {
	spec := raw.xcb_res_client_id_spec_t{window, 2}; return Pid_Request(raw.xcb_res_query_client_ids(c, 1, &spec).sequence)
}
cancel_pid :: proc(c: ^Connection, request: Pid_Request) { if request != 0 { raw.xcb_discard_reply(c,u32(request)) } }
poll_pid :: proc(c: ^Connection, request: Pid_Request) -> (pid: i32, done: bool) {
	reply: rawptr; err: ^raw.xcb_generic_error_t
	if raw.xcb_poll_for_reply(c, u32(request), &reply, &err) == 0 { return }
	done = true; defer release(reply); defer release(err)
	if reply == nil { return }
	it := raw.xcb_res_query_client_ids_ids_iterator(cast(^raw.xcb_res_query_client_ids_reply_t)reply)
	for it.rem > 0 {
		if it.data.spec.mask&2 != 0 && raw.xcb_res_client_id_value_value_length(it.data) > 0 { pid = i32(raw.xcb_res_client_id_value_value(it.data)[0]); break }
		raw.xcb_res_client_id_value_next(&it)
	}; return
}
poll :: proc(c: ^Connection, selection_event: u8 = 0) -> (event: Event, ok: bool) {
	e := raw.xcb_poll_for_event(c); if e == nil { return }; defer release(e)
	ok = true
	if selection_event != 0 && e.response_type&0x7f == selection_event { return (cast(^Selection_Owner)e)^, true }
	switch e.response_type&0x7f {
	case 0: event = (cast(^Error)e)^
	case 9: event = (cast(^Focus)e)^
	case 16: event = (cast(^Create)e)^
	case 17: event = (cast(^Destroy)e)^
	case 18: event = (cast(^Unmap)e)^
	case 19: event = (cast(^Map)e)^
	case 20: event = (cast(^Map_Request)e)^
	case 22: event = (cast(^Configure)e)^
	case 23: event = (cast(^Configure_Request)e)^
	case 28: event = (cast(^Property)e)^
	case 30: event = (cast(^Selection_Request)e)^
	case 31: event = (cast(^Selection_Notify)e)^
	case 33: event = (cast(^Message)e)^
	}; return
}
