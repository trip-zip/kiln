package xwayland

import seat "../seat"
import wl "../wayland"
import xcb "../xcb"
import "core:sys/linux"

Incoming :: struct {
 xwm: ^Xwm,
 window, target, owner: u32,
 selection: ^Selection,
 fd: linux.Fd,
 io: ^wl.Source,
 bytes: []u8,
 offset: int,
 incr: bool,
}
incoming_owner :: proc(m: ^Xwm, e: xcb.Selection_Owner) {
 if e.selection == m.atoms[.Xdnd_Selection] { if e.owner == m.dnd.window { m.dnd.timestamp = e.timestamp }; return }
 s := selection_find(m, e.selection); if s == nil || m.seat == nil { return }
 for i := len(m.incoming)-1; i >= 0; i -= 1 { t := m.incoming[i]; if t.selection == s && t.owner != e.owner { incoming_destroy(t) } }
 s.owner, s.pending_time = e.owner, e.timestamp
 if e.owner == s.window { s.timestamp = e.timestamp; return }
 if e.owner == 0 {
  if s.incoming != nil { seat.source_release(s.incoming); s.incoming = nil }; return
 }
 xcb.convert_selection(m.connection, s.window, s.atom, m.atoms[.Targets], m.atoms[.Wl_Selection], e.timestamp)
}
incoming_notify :: proc(m: ^Xwm, e: xcb.Selection_Notify) {
 for t in m.incoming {
  if t.window != e.requestor { continue }
  if e.property == 0 || e.target != t.target { incoming_destroy(t) } else { incoming_read(t) }; return
 }
 s := selection_find(m, e.selection)
 if s == nil || m.seat == nil || e.requestor != s.window || e.target != m.atoms[.Targets] || e.time != s.pending_time { return }
 if e.property == 0 || s.owner == 0 || s.owner == s.window { return }
 reply := xcb.property(m.connection, s.window, e.property, 4096, 4)
 defer xcb.release(reply)
 xcb.delete_property(m.connection, s.window, e.property)
 // Only a focused X client may replace a Wayland selection.
 if reply == nil || reply.format != 32 || reply.bytes_after != 0 || m.focus == nil { return }
 source := seat.source_new(s.primary); source.send, source.data = incoming_send, s
 for atom in (cast([^]u32)raw_data(xcb.property_bytes(reply)))[:reply.value_len] {
  mime := atom_mime(m, atom); if mime != "" { seat.source_offer(source, mime) }
 }
 old := s.incoming; s.incoming = source
 seat.selection_set(m.seat, source, wl.next_serial(m.server.display), s.primary)
 if old != nil { seat.source_release(old) }
}
incoming_send :: proc(source: ^seat.Source, mime: string, fd: wl.Fd) {
 s := cast(^Selection)source.data; m := s.xwm
 duplicate, err := linux.fcntl(linux.Fd(fd), linux.F_DUPFD_CLOEXEC, 0); if err != .NONE { return }
 flags, _ := linux.fcntl(duplicate, linux.F_GETFL)
 if error := linux.fcntl(duplicate, linux.F_SETFL, flags|{.NONBLOCK}); error != .NONE { linux.close(duplicate); return }
 t := new(Incoming); t.selection, t.owner = s, s.owner; t.xwm, t.fd, t.target = m, duplicate, mime_atom(m, mime)
 t.window = xcb.selection_window(m.connection, m.root); m.incoming_windows[t.window] = true; append(&m.incoming, t)
 xcb.convert_selection(m.connection, t.window, s.atom, t.target, m.atoms[.Wl_Selection], 0); schedule_flush(m)
}
incoming_destroy :: proc(t: ^Incoming) {
 m := t.xwm; wl.source_remove(t.io); linux.close(t.fd); delete(t.bytes)
 xcb.destroy_window(m.connection, t.window); schedule_flush(m)
 for other, i in m.incoming { if other == t { ordered_remove(&m.incoming, i); break } }; free(t)
}
incoming_read :: proc(t: ^Incoming) {
 m := t.xwm; atom := m.atoms[.Wl_Selection]
 reply := xcb.property(m.connection, t.window, atom, 0x1fffffff); defer xcb.release(reply)
 if reply == nil || reply.type == 0 || reply.bytes_after != 0 { incoming_destroy(t); return }
 if reply.type == m.atoms[.Incr] {
  t.incr = true; xcb.delete_property(m.connection, t.window, atom); schedule_flush(m); return
 }
 bytes := xcb.property_bytes(reply)
 if len(bytes) == 0 { incoming_destroy(t); return }
 t.bytes = make([]u8, len(bytes)); copy(t.bytes, bytes); t.offset = 0
 t.io = wl.loop_on_fd(m.server.display.loop, i32(t.fd), {.Writable}, incoming_write, t)
 if t.io == nil { incoming_destroy(t) }
}
incoming_write :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
 t := cast(^Incoming)data
 n, err := linux.write(t.fd, t.bytes[t.offset:])
 if err == .EAGAIN || err == .EINTR { return 0 }
 if err != .NONE || n == 0 { incoming_destroy(t); return 0 }
 t.offset += n
 if t.offset < len(t.bytes) { return 0 }
 if !t.incr { incoming_destroy(t); return 0 }
 wl.source_remove(t.io); t.io = nil; delete(t.bytes); t.bytes = nil
 xcb.delete_property(t.xwm.connection, t.window, t.xwm.atoms[.Wl_Selection]); schedule_flush(t.xwm); return 0
}
