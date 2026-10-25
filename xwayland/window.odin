package xwayland

import wl "../wayland"
import xcb "../xcb"
import "base:runtime"
import "core:strings"

Hints :: struct { flags: u32, input: bool, initial_state: u32 }
Configure_Event :: struct { x,y: i16, width,height: u16 }
Minimize_Event :: struct { minimize: bool }
Window :: struct {
	xwm: ^Xwm,
	window_id: u32,
	surface: ^Surface,
	serial: u64,
	surface_id: u32,
	x,y: i16,
	width,height: u16,
	override_redirect, mapped: bool,
	title, class, instance, role, wm_name, net_name: string,
	has_class, has_instance: bool,
	pid: i32,
	pid_request: xcb.Pid_Request,
	parent: ^Window,
	window_type, protocols: []u32,
	hints: Hints,
	fullscreen, maximized_vert, maximized_horz, minimized, has_focus: bool,
	events: struct {
		destroy, request_configure, request_minimize, request_maximize, request_fullscreen, request_activate: wl.Signal,
		associate, dissociate, set_title, set_class, set_role, set_parent, set_window_type, set_hints, set_geometry, set_icon, map_request: wl.Signal,
	},
	surface_destroy, surface_commit: wl.Listener,
	data: rawptr,
}
parse_hints :: proc(words: []u32) -> Hints {
	h := Hints{input=true}
	if len(words)<9 { return h }
	h.flags, h.initial_state = words[0], words[2]
	if h.flags&1 != 0 { h.input = words[1]!=0 }; return h
}
urgent :: proc(h: Hints) -> bool { return h.flags&(1<<8) != 0 }
class_presence :: proc(bytes: []u8) -> (has_instance, has_class: bool) {
	for b in bytes { if b == 0 { return true, true } }; return false, len(bytes)>0
}
parse_class :: proc(bytes: []u8) -> (instance, class: string) {
	for b,i in bytes { if b == 0 { return strings.clone(string(bytes[:i])), text_value(bytes[i+1:]) } }
	return "", text_value(bytes)
}
text_value :: proc(bytes: []u8) -> string {
	for b,i in bytes { if b == 0 { return strings.clone(string(bytes[:i])) } }; return strings.clone(string(bytes))
}
window_create :: proc(m: ^Xwm, e: xcb.Create) {
	if m.windows[e.window] != nil { return }
	w := new(Window); w.xwm,w.window_id,w.x,w.y,w.width,w.height,w.override_redirect = m,e.window,e.x,e.y,e.width,e.height,e.override_redirect!=0
	w.hints.input = true
	for &signal in (cast([^]wl.Signal)&w.events)[:size_of(w.events)/size_of(wl.Signal)] { wl.signal_init(&signal) }
	m.windows[w.window_id] = w
	xcb.watch(m.connection,w.window_id,(1<<21)|(1<<22))
	if m.xres { w.pid_request = xcb.request_pid(m.connection,w.window_id) }
	wl.signal_emit_mutable(&m.server.events.new_window,w)
}
poll_pid :: proc(w: ^Window) {
	if w.pid_request == 0 { return }
	pid, done := xcb.poll_pid(w.xwm.connection,w.pid_request)
	if done { w.pid, w.pid_request = pid, 0; wl.signal_emit_mutable(&w.events.set_class,w) }
}
read_property :: proc(w: ^Window, atom: u32) {
	m := w.xwm; a := &m.atoms
	// Icons stay in the compositor's image cache; it performs the only pixel read.
	if atom == a[.Icon] { wl.signal_emit_mutable(&w.events.set_icon,w); return }
	if atom != 67 && atom != 39 && atom != 68 && atom != 35 && atom != a[.Name] && atom != a[.Role] && atom != a[.Protocols] && atom != a[.Types] && atom != a[.State] { return }
	r := xcb.property(m.connection,w.window_id,atom,2048)
	if r == nil { return }; defer xcb.release(r)
	if r.bytes_after != 0 { return }
	bytes := xcb.property_bytes(r)
	text := r.type == 0 || ((r.type == 31 || r.type == a[.Utf8]) && r.format == 8)
	words: []u32
	if r.format == 32 { words = (cast([^]u32)raw_data(bytes))[:len(bytes)/4] }
	switch atom {
	case 67:
		if !text { return }; delete(w.instance); delete(w.class); w.instance,w.class = parse_class(bytes)
		w.has_instance,w.has_class = class_presence(bytes)
		wl.signal_emit_mutable(&w.events.set_class,w)
	case 39, a[.Name]:
		if !text { return }; slot := &w.wm_name if atom == 39 else &w.net_name
		delete(slot^); slot^ = text_value(bytes); w.title = w.net_name if w.net_name != "" else w.wm_name
		wl.signal_emit_mutable(&w.events.set_title,w)
	case a[.Role]:
		if !text { return }; delete(w.role); w.role = text_value(bytes); wl.signal_emit_mutable(&w.events.set_role,w)
	case 68:
		if r.type != 0 && (r.type != 33 || len(words) != 1) { return }
		parent: ^Window; if len(words)>0 { parent = m.windows[words[0]] }
		for p := parent; p != nil; p = p.parent { if p == w { return } }
		w.parent = parent; wl.signal_emit_mutable(&w.events.set_parent,w)
	case 35:
		if r.type != 0 && r.type != 35 && r.type != 4 { return }
		w.hints = parse_hints(words); wl.signal_emit_mutable(&w.events.set_hints,w)
	case a[.Types], a[.Protocols]:
		if r.type != 0 && (r.type != 4 || r.format != 32) { return }
		slot := &w.window_type if atom == a[.Types] else &w.protocols
		delete(slot^); slot^ = make([]u32,len(words)); copy(slot^,words)
		if atom == a[.Types] { wl.signal_emit_mutable(&w.events.set_window_type,w) }
	case a[.State]:
		// The WM owns this property after mapping; client requests arrive as messages.
		if w.mapped || r.type != 0 && (r.type != 4 || r.format != 32) { return }
		w.fullscreen,w.maximized_vert,w.maximized_horz,w.minimized = false,false,false,false
		for v in words {
			if v == a[.Fullscreen] { w.fullscreen = true }; if v == a[.Max_Vert] { w.maximized_vert = true }
			if v == a[.Max_Horz] { w.maximized_horz = true }; if v == a[.Hidden] { w.minimized = true }
		}
	}
}
window_associate :: proc(w: ^Window, s: ^Surface) {
	w.surface, w.surface_id = s, 0
	for atom in ([]u32{67,39,68,35,w.xwm.atoms[.Name],w.xwm.atoms[.Role],w.xwm.atoms[.Protocols],w.xwm.atoms[.Types],w.xwm.atoms[.State]}) { read_property(w,atom) }
	poll_pid(w)
	surface_watch(s,&w.surface_destroy,window_surface_destroy)
	surface_watch_commit(s,&w.surface_commit,window_surface_commit)
	wl.signal_emit_mutable(&w.events.associate,w)
	window_map(w)
}
window_map :: proc(w: ^Window) {
	if w.mapped && w.surface != nil && has_buffer(w.surface) && !surface_mapped(w.surface) { append(&w.xwm.mapped_windows,w); map_surface(w.surface); client_list(w.xwm) }
}
window_surface_destroy :: proc "c" (l: ^wl.Listener, data: rawptr) {
	context = runtime.default_context(); w := wl.owner(l,Window,"surface_destroy"); context = w.xwm.server.display.loop.ctx
	window_dissociate(w)
}
window_surface_commit :: proc "c" (l: ^wl.Listener, data: rawptr) {
	context = runtime.default_context(); w := wl.owner(l,Window,"surface_commit"); context = w.xwm.server.display.loop.ctx
	window_map(w)
}
window_dissociate :: proc(w: ^Window) {
	w.serial,w.surface_id = 0,0
	for s in w.xwm.server.shells { if s.window == w { s.window = nil } }
	if w.surface == nil { return }
	unmap_surface(w.surface)
	for other,i in w.xwm.mapped_windows { if other == w { ordered_remove(&w.xwm.mapped_windows,i); break } }
	wl.signal_emit_mutable(&w.events.dissociate,w)
	wl.unlisten(&w.surface_destroy); wl.unlisten(&w.surface_commit); w.surface = nil
	if w.xwm.focus == w { activate(w,false) }; client_list(w.xwm)
}
window_destroy :: proc(w: ^Window) {
	xcb.cancel_pid(w.xwm.connection,w.pid_request)
	window_dissociate(w)
	if w.xwm.focus == w { focus_changed(w.xwm,nil) }
	for _,other in w.xwm.windows { if other.parent == w { other.parent = nil; wl.signal_emit_mutable(&other.events.set_parent,other) } }
	wl.signal_emit_final(&w.events.destroy,w)
	delete_key(&w.xwm.windows,w.window_id)
	delete(w.wm_name); delete(w.net_name); delete(w.class); delete(w.instance); delete(w.role); delete(w.window_type); delete(w.protocols); free(w)
}
configure :: proc(w: ^Window, x,y: i16, width,height: u16) {
	same_size := w.width == width && w.height == height
	w.x,w.y,w.width,w.height = x,y,width,height
	values := [5]u32{u32(i32(x)),u32(i32(y)),u32(width),u32(height),0}
	xcb.configure(w.xwm.connection,w.window_id,31,values[:])
	if same_size && !w.override_redirect {
		e := xcb.Configure{response_type=22,event=w.window_id,window=w.window_id,x=x,y=y,width=width,height=height}
		xcb.send(w.xwm.connection,w.window_id,1<<17,e)
	}; schedule_flush(w.xwm)
}
contains :: proc(values: []u32, atom: u32) -> bool { for v in values { if v == atom { return true } }; return false }
protocol_message :: proc(w: ^Window, atom: Atom, mask: u32) {
	e := xcb.Message{response_type=33,format=32,window=w.window_id,type=w.xwm.atoms[.Protocols]}
	e.data.data32[0] = w.xwm.atoms[atom]
	xcb.send(w.xwm.connection,w.window_id,mask,e); schedule_flush(w.xwm)
}
close :: proc(w: ^Window) {
	if contains(w.protocols,w.xwm.atoms[.Delete]) { protocol_message(w,.Delete,0) }
	else { xcb.kill_client(w.xwm.connection,w.window_id) }
}
write_state :: proc(w: ^Window) {
	m := w.xwm; a := &m.atoms
	states: [5]u32; n := 0
	if w.fullscreen { states[n] = a[.Fullscreen]; n+=1 }
	if w.maximized_vert { states[n] = a[.Max_Vert]; n+=1 }
	if w.maximized_horz { states[n] = a[.Max_Horz]; n+=1 }
	if w.minimized { states[n] = a[.Hidden]; n+=1 }
	if w.has_focus { states[n] = a[.Focused]; n+=1 }
	xcb.write_words(m.connection,w.window_id,a[.State],4,states[:n])
	state := u32(0) if !w.mapped else (3 if w.minimized else 1)
	xcb.write_words(m.connection,w.window_id,a[.Wm_State],a[.Wm_State],[]u32{state,0}); schedule_flush(m)
}
set_fullscreen :: proc(w: ^Window, on: bool) { w.fullscreen=on; write_state(w) }
set_maximized :: proc(w: ^Window, on: bool) { w.maximized_vert,w.maximized_horz=on,on; write_state(w) }
set_minimized :: proc(w: ^Window, on: bool) { w.minimized=on; write_state(w) }
state_value :: proc(current: bool, action: u32) -> bool {
	switch action { case 0: return false; case 1: return true; case 2: return !current }; return current
}
state_request :: proc(w: ^Window, action: u32, atoms: []u32) {
	a := &w.xwm.atoms; full,vert,horz,mini := w.fullscreen,w.maximized_vert,w.maximized_horz,w.minimized
	for atom,i in atoms {
		if atom == 0 || i>0 && atom == atoms[0] { continue }
		switch atom {
		case a[.Fullscreen]: w.fullscreen = state_value(w.fullscreen,action)
		case a[.Max_Vert]: w.maximized_vert = state_value(w.maximized_vert,action)
		case a[.Max_Horz]: w.maximized_horz = state_value(w.maximized_horz,action)
		case a[.Hidden]: w.minimized = state_value(w.minimized,action)
		}
	}
	if full != w.fullscreen { wl.signal_emit_mutable(&w.events.request_fullscreen,w) }
	if vert != w.maximized_vert || horz != w.maximized_horz { wl.signal_emit_mutable(&w.events.request_maximize,w) }
	if mini != w.minimized { e := Minimize_Event{w.minimized}; wl.signal_emit_mutable(&w.events.request_minimize,&e) }
}
focus_window :: proc(m: ^Xwm, w: ^Window) {
	if w == nil { xcb.focus_root(m.connection); return }
	if w.override_redirect || !w.mapped { return }
	if contains(w.protocols,m.atoms[.Take_Focus]) { protocol_message(w,.Take_Focus,0 if !w.hints.input else 1<<20) }
	if w.hints.input { m.last_focus = xcb.focus(m.connection,w.window_id) }
}
focus_changed :: proc(m: ^Xwm, w: ^Window) {
	if m.focus == w { return }; old := m.focus; m.focus = w
	if old != nil { old.has_focus = false; write_state(old) }
	if w != nil { w.has_focus = true; write_state(w) }
	xcb.write_words(m.connection,m.root,m.atoms[.Active],33,[]u32{w.window_id if w != nil else 0}); schedule_flush(m)
}
activate :: proc(w: ^Window, on: bool) {
	if w.override_redirect || !on && w.xwm.focus != w { return }
	target := w if on else nil
	if target != w.xwm.focus { focus_window(w.xwm,target); focus_changed(w.xwm,target) }; schedule_flush(w.xwm)
}
wants_focus :: proc(w: ^Window) -> bool {
	for kind in ([]Atom{.Combo,.Dnd,.Dropdown,.Menu,.Notification,.Popup,.Splash,.Desktop,.Tooltip,.Utility}) {
		if contains(w.window_type,w.xwm.atoms[kind]) { return false }
	}; return true
}
