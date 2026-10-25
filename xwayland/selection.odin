package xwayland

import seat "../seat"
import wl "../wayland"
import xcb "../xcb"
import "core:strings"

Selection :: struct {
 xwm: ^Xwm,
 atom, window, owner, timestamp, pending_time: u32,
 primary: bool,
 incoming: ^seat.Source,
 changed: wl.Listener,
}
selection_source :: proc(s: ^Selection) -> ^seat.Source {
 if s.xwm.seat == nil { return nil }
 return s.xwm.seat.primary_selection_source if s.primary else s.xwm.seat.selection_source
}
selection_init :: proc(m: ^Xwm) {
 m.selection_event = xcb.selection_events(m.connection); m.chunk_size = xcb.selection_chunk_size(m.connection)
 for &s, i in m.selections {
  s.xwm, s.primary, s.atom = m, i == 1, m.atoms[.Clipboard] if i == 0 else 1
  s.window = xcb.selection_window(m.connection, m.root)
  xcb.watch_selection(m.connection, s.window, s.atom)
 }
 xcb.selection_owner(m.connection, m.selections[0].window, m.atoms[.Clipboard_Manager])
 m.dnd.xwm = m; m.dnd.window = xcb.selection_window(m.connection, m.root, true)
 xcb.watch_selection(m.connection, m.dnd.window, m.atoms[.Xdnd_Selection])
 xcb.write_words(m.connection, m.dnd.window, m.atoms[.Xdnd_Aware], 4, []u32{5})
 m.seat = m.server.seat
 if m.seat == nil { return }
 wl.listen(&m.seat.events.destroy, &m.seat_destroy, selection_seat_destroy)
 wl.listen(&m.seat.events.set_selection, &m.selections[0].changed, selection_changed)
 wl.listen(&m.seat.events.set_primary_selection, &m.selections[1].changed, selection_changed)
 wl.listen(&m.seat.events.start_drag, &m.dnd.start, dnd_start)
 for &s in m.selections { selection_sync(&s) }
}
selection_seat_destroy :: proc(l: ^wl.Listener, data: rawptr) {
 m := wl.owner(l, Xwm, "seat_destroy"); selection_finish(m); m.seat, m.server.seat = nil, nil
}
selection_finish :: proc(m: ^Xwm) {
 wl.unlisten(&m.seat_destroy); dnd_finish(&m.dnd)
 for &s in m.selections {
  wl.unlisten(&s.changed)
  if s.incoming != nil { seat.source_release(s.incoming); s.incoming = nil }
 }
 for len(m.incoming) > 0 { incoming_destroy(m.incoming[len(m.incoming)-1]) }
 for len(m.outgoing) > 0 { outgoing_destroy(m.outgoing[len(m.outgoing)-1], true) }
 delete(m.incoming); delete(m.outgoing); m.incoming, m.outgoing = nil, nil
 for _,name in m.mime_names { delete(name) }; delete(m.mime_names); m.mime_names = nil
 delete(m.incoming_windows); m.incoming_windows = nil
}
selection_changed :: proc(l: ^wl.Listener, data: rawptr) { selection_sync(wl.owner(l, Selection, "changed")) }
selection_sync :: proc(s: ^Selection) {
 source := selection_source(s)
 if source != nil && source == s.incoming { return }
 if source != nil || s.owner == s.window { xcb.selection_owner(s.xwm.connection, s.window if source != nil else 0, s.atom); schedule_flush(s.xwm) }
}
selection_find :: proc(m: ^Xwm, atom: u32) -> ^Selection { for &s in m.selections { if s.atom == atom { return &s } }; return nil }
selection_own_window :: proc(m: ^Xwm, id: u32) -> bool {
 if id == m.wm_window || id == m.dnd.window { return true }
 for &s in m.selections { if s.window == id { return true } }
 return m.incoming_windows[id]
}
mime_from_name :: proc(name: string) -> string {
 switch name { case "UTF8_STRING": return "text/plain;charset=utf-8"; case "TEXT": return "text/plain" }
 return name if strings.contains(name, "/") else ""
}
mime_to_name :: proc(mime: string) -> string {
 switch mime { case "text/plain;charset=utf-8": return "UTF8_STRING"; case "text/plain": return "TEXT" }; return mime
}
mime_atom :: proc(m: ^Xwm, mime: string) -> u32 {
 name := mime_to_name(mime)
 if name == "UTF8_STRING" { return m.atoms[.Utf8] }; if name == "TEXT" { return m.atoms[.Text] }
 for atom, old in m.mime_names { if old == name { return atom } }
 atom := xcb.intern(m.connection, name)
 if atom != 0 { m.mime_names[atom] = strings.clone(name) }; return atom
}
atom_mime :: proc(m: ^Xwm, atom: u32) -> string {
 if atom == m.atoms[.Utf8] { return "text/plain;charset=utf-8" }; if atom == m.atoms[.Text] { return "text/plain" }
 name, ok := m.mime_names[atom]
 if !ok { name = xcb.atom_name(m.connection, atom); m.mime_names[atom] = name }
 return mime_from_name(name)
}
selection_event :: proc(m: ^Xwm, event: xcb.Event) -> bool {
 #partial switch e in event {
 case xcb.Selection_Owner: incoming_owner(m, e); return true
 case xcb.Selection_Notify: incoming_notify(m, e); return true
 case xcb.Selection_Request: outgoing_request(m, e); return true
 case xcb.Property:
  if e.state == 0 && e.atom == m.atoms[.Wl_Selection] {
   for t in m.incoming { if t.window == e.window && t.incr && t.io == nil { incoming_read(t); return true } }
  }
  if e.state == 1 { for t in m.outgoing { if t.request.requestor == e.window && t.request.property == e.atom && t.incr { outgoing_ack(t); return true } } }
 case xcb.Destroy:
  if m.incoming_windows[e.window] { delete_key(&m.incoming_windows, e.window); return true }
  for i := len(m.outgoing)-1; i >= 0; i -= 1 { if m.outgoing[i].request.requestor == e.window { outgoing_destroy(m.outgoing[i], false) } }
 case xcb.Message: if e.format == 32 && dnd_message(&m.dnd, e) { return true }
 }
 return false
}
