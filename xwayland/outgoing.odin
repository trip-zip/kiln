package xwayland

import seat "../seat"
import wl "../wayland"
import xcb "../xcb"
import "core:sys/linux"

Outgoing :: struct {
 xwm: ^Xwm,
 request: xcb.Selection_Request,
 source: ^seat.Source,
 destroy: wl.Listener,
 fd: linux.Fd,
 io: ^wl.Source,
 bytes: []u8,
 used: int,
 incr, waiting, eof: bool,
}
selection_notify :: proc(m: ^Xwm, r: xcb.Selection_Request, success: bool) {
 e := xcb.Selection_Notify{response_type=31, time=r.time, requestor=r.requestor, selection=r.selection, target=r.target, property=r.property if success else 0}
 xcb.send(m.connection, r.requestor, 0, e); schedule_flush(m)
}
outgoing_destroy :: proc(t: ^Outgoing, failed: bool) {
 if failed { selection_notify(t.xwm, t.request, false) }
 wl.unlisten(&t.destroy); wl.source_remove(t.io); linux.close(t.fd); delete(t.bytes)
 for other, i in t.xwm.outgoing { if other == t { ordered_remove(&t.xwm.outgoing, i); break } }; free(t)
}
outgoing_source_destroy :: proc(l: ^wl.Listener, data: rawptr) { outgoing_destroy(wl.owner(l, Outgoing, "destroy"), true) }
outgoing_request :: proc(m: ^Xwm, request: xcb.Selection_Request) {
 r := request; a := &m.atoms; c := m.connection
 // Older requestors ask the owner to use the target as the property.
 if r.property == 0 { r.property = r.target }
 source: ^seat.Source; timestamp: u32
 if r.selection == a[.Clipboard_Manager] { selection_notify(m, r, true); return }
 if r.selection == a[.Xdnd_Selection] {
  timestamp = m.dnd.timestamp
  if r.owner == m.dnd.window && (m.dnd.focus != nil || m.dnd.dropped != nil) { source = m.dnd.source }
 } else if s := selection_find(m, r.selection); s != nil {
  timestamp = s.timestamp
  if r.owner == s.window && s.owner == s.window && m.focus != nil { source = selection_source(s) }
  if source == s.incoming { source = nil }
 }
 if source == nil || source.cancelled || source.finished || r.time != 0 && i32(r.time-timestamp) < 0 { selection_notify(m, r, false); return }
 if r.target == a[.Targets] {
  atoms := make([dynamic]u32, context.temp_allocator)
  append(&atoms, a[.Targets], a[.Timestamp])
  for mime in source.mimes { if atom := mime_atom(m, mime); atom != 0 { append(&atoms, atom) } }
  xcb.write_words(c, r.requestor, r.property, 4, atoms[:]); selection_notify(m, r, true); return
 }
 if r.target == a[.Timestamp] { xcb.write_words(c, r.requestor, r.property, 19, []u32{timestamp}); selection_notify(m, r, true); return }
 if r.target == a[.Selection_Delete] { selection_notify(m, r, true); return }
 mime := atom_mime(m, r.target); found := false
 for offered in source.mimes { if offered == mime { found = true; break } }
 if !found { selection_notify(m, r, false); return }
 for i := len(m.outgoing)-1; i >= 0; i -= 1 { if m.outgoing[i].request.requestor == r.requestor && m.outgoing[i].request.selection == r.selection { outgoing_destroy(m.outgoing[i], true) } }
 fds: [2]linux.Fd
 if linux.pipe2(&fds, {.CLOEXEC}) != .NONE { selection_notify(m, r, false); return }
 flags, _ := linux.fcntl(fds[0], linux.F_GETFL)
 if err := linux.fcntl(fds[0], linux.F_SETFL, flags|{.NONBLOCK}); err != .NONE { linux.close(fds[0]); linux.close(fds[1]); selection_notify(m, r, false); return }
 t := new(Outgoing); t.xwm, t.request, t.source, t.fd = m, r, source, fds[0]
 t.bytes = make([]u8, m.chunk_size); append(&m.outgoing, t)
 wl.listen(&source.events.destroy, &t.destroy, outgoing_source_destroy)
 t.io = wl.loop_on_fd(m.server.display.loop, i32(t.fd), {.Readable}, outgoing_read, t)
 if t.io == nil { linux.close(fds[1]); outgoing_destroy(t, true); return }
 xcb.watch(c, r.requestor, (1<<17)|(1<<22))
 seat.source_send(source, mime, wl.Fd(fds[1])); linux.close(fds[1])
}
outgoing_read :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
 t := cast(^Outgoing)data
 n, err := linux.read(t.fd, t.bytes[t.used:])
 if err == .EAGAIN || err == .EINTR { return 0 }
 if err != .NONE { outgoing_destroy(t, true); return 0 }
 t.used += n; t.eof = n == 0
 if t.used == len(t.bytes) && !t.incr {
  t.incr, t.waiting = true, true
  xcb.write_words(t.xwm.connection, t.request.requestor, t.request.property, t.xwm.atoms[.Incr], []u32{u32(t.used)})
  selection_notify(t.xwm, t.request, true)
 }
 if t.eof || t.used == len(t.bytes) { wl.source_remove(t.io); t.io = nil }
 outgoing_progress(t); return 0
}
outgoing_progress :: proc(t: ^Outgoing) {
 m := t.xwm; r := t.request
 if !t.incr {
  if t.eof { xcb.write_string(m.connection, r.requestor, r.property, r.target, string(t.bytes[:t.used])); selection_notify(m, r, true); outgoing_destroy(t, false) }; return
 }
 if t.waiting || !t.eof && t.used < len(t.bytes) { return }
 xcb.write_string(m.connection, r.requestor, r.property, r.target, string(t.bytes[:t.used])); schedule_flush(m)
 if t.used == 0 && t.eof { outgoing_destroy(t, false); return }
 t.used, t.waiting = 0, true
 if !t.eof && t.io == nil {
  t.io = wl.loop_on_fd(m.server.display.loop, i32(t.fd), {.Readable}, outgoing_read, t)
  if t.io == nil { outgoing_destroy(t, true) }
 }
}
outgoing_ack :: proc(t: ^Outgoing) { t.waiting = false; outgoing_progress(t) }
