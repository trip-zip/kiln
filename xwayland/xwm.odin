package xwayland

import seat "../seat"
import wl "../wayland"
import xcb "../xcb"
import "core:fmt"
import "core:slice"

Atom :: enum {
	Desktop, Dock, Toolbar, Menu, Utility, Splash, Dialog, Dropdown, Popup, Tooltip, Notification, Combo, Dnd, Normal,
	Role, Icon, State, Fullscreen, Max_Vert, Max_Horz, Hidden,
	Protocols, Delete, Take_Focus, Wm_State, Change_State, Utf8, Name, Types,
	Surface_Id, Surface_Serial, Active, Close, Focused, Supported, Check, Client_List, Wm_S0, Cm_S0,
 Clipboard, Clipboard_Manager, Targets, Timestamp, Selection_Delete, Text, Incr, Wl_Selection, Xdnd_Selection, Xdnd_Aware, Xdnd_Type_List, Xdnd_Enter, Xdnd_Position, Xdnd_Leave, Xdnd_Drop, Xdnd_Status, Xdnd_Finished, Xdnd_Copy, Xdnd_Move, Xdnd_Ask, Xdnd_Private,
}
ATOM_NAMES :: [?]string{
	"_NET_WM_WINDOW_TYPE_DESKTOP","_NET_WM_WINDOW_TYPE_DOCK","_NET_WM_WINDOW_TYPE_TOOLBAR","_NET_WM_WINDOW_TYPE_MENU",
	"_NET_WM_WINDOW_TYPE_UTILITY","_NET_WM_WINDOW_TYPE_SPLASH","_NET_WM_WINDOW_TYPE_DIALOG","_NET_WM_WINDOW_TYPE_DROPDOWN_MENU",
	"_NET_WM_WINDOW_TYPE_POPUP_MENU","_NET_WM_WINDOW_TYPE_TOOLTIP","_NET_WM_WINDOW_TYPE_NOTIFICATION","_NET_WM_WINDOW_TYPE_COMBO",
	"_NET_WM_WINDOW_TYPE_DND","_NET_WM_WINDOW_TYPE_NORMAL","WM_WINDOW_ROLE","_NET_WM_ICON",
	"_NET_WM_STATE","_NET_WM_STATE_FULLSCREEN","_NET_WM_STATE_MAXIMIZED_VERT","_NET_WM_STATE_MAXIMIZED_HORZ","_NET_WM_STATE_HIDDEN",
	"WM_PROTOCOLS","WM_DELETE_WINDOW","WM_TAKE_FOCUS","WM_STATE","WM_CHANGE_STATE","UTF8_STRING","_NET_WM_NAME","_NET_WM_WINDOW_TYPE",
	"WL_SURFACE_ID","WL_SURFACE_SERIAL","_NET_ACTIVE_WINDOW","_NET_CLOSE_WINDOW","_NET_WM_STATE_FOCUSED","_NET_SUPPORTED","_NET_SUPPORTING_WM_CHECK","_NET_CLIENT_LIST","WM_S0","_NET_WM_CM_S0",
 "CLIPBOARD","CLIPBOARD_MANAGER","TARGETS","TIMESTAMP","DELETE","TEXT","INCR","_WL_SELECTION","XdndSelection","XdndAware","XdndTypeList","XdndEnter","XdndPosition","XdndLeave","XdndDrop","XdndStatus","XdndFinished","XdndActionCopy","XdndActionMove","XdndActionAsk","XdndActionPrivate",
}
Xwm :: struct {
	server: ^Server,
	connection: ^xcb.Connection,
	root, wm_window: u32,
	atoms: [Atom]u32,
	windows: map[u32]^Window,
	mapped_windows: [dynamic]^Window,
	source, flush_source, legacy_source: ^wl.Source,
	focus: ^Window,
	last_focus: u16,
	xres: bool,
 seat: ^seat.Seat,
 selections: [2]Selection,
 dnd: Dnd,
 incoming: [dynamic]^Incoming,
 outgoing: [dynamic]^Outgoing,
 mime_names: map[u32]string,
 incoming_windows: map[u32]bool,
 seat_destroy: wl.Listener,
 selection_event: u8,
 chunk_size: int,
}
connection :: proc(s: ^Server) -> ^xcb.Connection { return s.xwm.connection if s != nil && s.xwm != nil else nil }
xwm_create :: proc(s: ^Server, fd: i32) -> ^Xwm {
	c := xcb.connect(fd); if c == nil { return nil }
	m := new(Xwm); m.server, m.connection = s, c; m.windows = make(map[u32]^Window); m.mime_names = make(map[u32]string); m.incoming_windows = make(map[u32]bool)
	composite, res := xcb.extensions(c); m.xres = res
	names := ATOM_NAMES
	if !composite || !xcb.intern_all(c, names[:], slice.enumerated_array(&m.atoms)) { xwm_destroy(m); return nil }
	screen := xcb.screen(c); m.root = screen.root
	xcb.watch(c, m.root, (1<<19)|(1<<20)|(1<<22)); xcb.redirect(c, m.root)
	m.wm_window = xcb.create_window(c, m.root, screen.root_visual)
	a := &m.atoms
	xcb.write_words(c, m.root, a[.Check], 33, []u32{m.wm_window})
	xcb.write_words(c, m.wm_window, a[.Check], 33, []u32{m.wm_window})
	xcb.write_string(c, m.wm_window, a[.Name], a[.Utf8], "kiln")
	xcb.selection_owner(c, m.wm_window, a[.Wm_S0]); xcb.selection_owner(c, m.wm_window, a[.Cm_S0])
	supported := [11]u32{a[.State],a[.Fullscreen],a[.Max_Vert],a[.Max_Horz],a[.Hidden],a[.Focused],a[.Active],a[.Close],a[.Client_List],a[.Check],a[.Types]}
	xcb.write_words(c, m.root, a[.Supported], 4, supported[:]); xcb.write_words(c, m.root, a[.Active], 33, []u32{0})
	selection_init(m)
	m.source = wl.loop_on_fd(s.display.loop, xcb.fd(c), {.Readable}, xwm_dispatch, m)
	if m.source == nil { xwm_destroy(m); return nil }
	// Setup replies can queue events without leaving the connection fd readable.
	wl.source_check(m.source)
	xcb.flush(c); return m
}
xwm_destroy :: proc(m: ^Xwm) {
	selection_finish(m)
	wl.source_remove(m.source); wl.source_remove(m.flush_source); wl.source_remove(m.legacy_source)
	for len(m.windows)>0 { for _,w in m.windows { window_destroy(w); break } }
	delete(m.windows); delete(m.mapped_windows); xcb.disconnect(m.connection); free(m)
}
schedule_flush :: proc(m: ^Xwm) {
	if m.flush_source == nil { m.flush_source = wl.loop_on_idle(m.server.display.loop, xwm_flush, m) }
}
xwm_flush :: proc(data: rawptr) { m := cast(^Xwm)data; m.flush_source = nil; xcb.flush(m.connection) }
client_list :: proc(m: ^Xwm) {
	ids := make([dynamic]u32, context.temp_allocator)
	for w in m.mapped_windows { if !w.override_redirect { append(&ids,w.window_id) } }
	xcb.write_words(m.connection, m.root, m.atoms[.Client_List], 33, ids[:]); schedule_flush(m)
}
xwm_dispatch :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
	m := cast(^Xwm)data
	for {
		e, ok := xcb.poll(m.connection, m.selection_event); if !ok { break }
		if selection_event(m, e) { continue }
		#partial switch ev in e {
		case xcb.Create:
			if !selection_own_window(m, ev.window) && ev.parent == m.root { window_create(m, ev) }
		case xcb.Destroy: if w := m.windows[ev.window]; w != nil { window_destroy(w) }
		case xcb.Map_Request:
			if w := m.windows[ev.window]; w != nil { wl.signal_emit_mutable(&w.events.map_request, w) }
			xcb.map_window(m.connection, ev.window)
		case xcb.Map:
			if w := m.windows[ev.window]; w != nil {
				w.mapped, w.override_redirect = true, ev.override_redirect != 0
				if !w.override_redirect { write_state(w) }; window_map(w)
			}
		case xcb.Unmap:
			if w := m.windows[ev.window]; w != nil { w.mapped = false; window_dissociate(w); write_state(w) }
		case xcb.Configure_Request: configure_request(m, ev)
		case xcb.Configure:
			if w := m.windows[ev.window]; w != nil {
				changed := w.x != ev.x || w.y != ev.y || w.width != ev.width || w.height != ev.height
				w.x,w.y,w.width,w.height,w.override_redirect = ev.x,ev.y,ev.width,ev.height,ev.override_redirect != 0
				if changed { wl.signal_emit_mutable(&w.events.set_geometry,w) }
			}
		case xcb.Property: if w := m.windows[ev.window]; w != nil { read_property(w, ev.atom) }
		case xcb.Message: if ev.format == 32 { if w := m.windows[ev.window]; w != nil { client_message(w, ev) } }
		case xcb.Focus:
			if ev.detail != 5 && ev.mode != 1 && ev.mode != 2 && u16(ev.sequence-m.last_focus) < max(u16)/2 {
				w := m.windows[ev.event]
				if w != nil && m.focus != nil && w.pid != 0 && w.pid == m.focus.pid { focus_changed(m, w) }
				else { focus_window(m, m.focus) }
			}
		case xcb.Error: fmt.eprintf("XWM error code=%d major=%d minor=%d resource=%d\n",ev.error_code,ev.major_code,ev.minor_code,ev.resource_id)
		}
	}
	if xcb.failed(m.connection) { server_finish_process(m.server); return 0 }
	for _,w in m.windows { poll_pid(w) }
	xcb.flush(m.connection); return 0
}
configure_request :: proc(m: ^Xwm, ev: xcb.Configure_Request) {
	w := m.windows[ev.window]
	if w != nil && ev.value_mask&15 != 0 {
		e := Configure_Event{w.x,w.y,w.width,w.height}
		if ev.value_mask&1 != 0 { e.x = ev.x }; if ev.value_mask&2 != 0 { e.y = ev.y }
		if ev.value_mask&4 != 0 { e.width = ev.width }; if ev.value_mask&8 != 0 { e.height = ev.height }
		wl.signal_emit_mutable(&w.events.request_configure, &e)
		// Policy may decline or defer a mapped request; acknowledge the current geometry.
		if w.mapped { configure(w,w.x,w.y,w.width,w.height) }
	} else {
		values := make([dynamic]u32, context.temp_allocator)
		all := [7]u32{u32(i32(ev.x)),u32(i32(ev.y)),u32(ev.width),u32(ev.height),0,ev.sibling,u32(ev.stack_mode)}
		for v,i in all { if ev.value_mask&(1<<uint(i)) != 0 { append(&values,v) } }
		xcb.configure(m.connection,ev.window,ev.value_mask,values[:])
	}
}
client_message :: proc(w: ^Window, ev: xcb.Message) {
	m := w.xwm; a := &m.atoms; d := ev.data.data32
	switch ev.type {
	case a[.Surface_Serial]:
		if w.serial == 0 { w.serial = u64(d[0])|u64(d[1])<<32; pair_window(w) }
	case a[.Surface_Id]:
		w.surface_id = d[0]; legacy_pair(m)
		if w.surface == nil && m.legacy_source == nil { m.legacy_source = wl.loop_on_timer(m.server.display.loop, legacy_retry, m); wl.source_arm_timer(m.legacy_source, 1_000_000) }
	case a[.State]: state_request(w, d[0], d[1:3])
	case a[.Change_State]: if d[0] == 1 || d[0] == 3 { e := Minimize_Event{d[0]==3}; wl.signal_emit_mutable(&w.events.request_minimize,&e) }
	case a[.Active]: wl.signal_emit_mutable(&w.events.request_activate,w)
	case a[.Close]: close(w)
	}
}
legacy_pair :: proc(m: ^Xwm) -> bool {
	pending := false
	for _,w in m.windows {
		if w.surface_id == 0 || w.surface != nil { continue }
		r := wl.client_get_object(m.server.client,w.surface_id)
		if r == nil { pending = true; continue }
		s := surface_of(r); w.surface_id = 0
		if s != nil && legacy_assign(s) { window_associate(w,s) }
	}; return pending
}
legacy_retry :: proc(data: rawptr) -> i32 {
	m := cast(^Xwm)data
	if legacy_pair(m) { wl.source_arm_timer(m.legacy_source, 1_000_000) }
	else { wl.source_remove(m.legacy_source); m.legacy_source = nil }; return 0
}
