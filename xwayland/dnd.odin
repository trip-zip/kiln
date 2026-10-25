package xwayland

import seat "../seat"
import wl "../wayland"
import xcb "../xcb"

Dnd :: struct {
 xwm: ^Xwm,
 window, time, timestamp: u32,
 drag: ^seat.Drag,
 source: ^seat.Source,
 focus, dropped: ^Window,
 start, enter, motion, drop, retire, source_destroy, focus_destroy, dropped_destroy: wl.Listener,
}
dnd_send :: proc(d: ^Dnd, window: ^Window, atom: Atom, data: [5]u32) {
 if window == nil { return }
 xcb.send(d.xwm.connection, window.window_id, 0, xcb.Message{response_type=33, format=32, window=window.window_id, type=d.xwm.atoms[atom], data={data32=data}})
 schedule_flush(d.xwm)
}
dnd_clear :: proc(d: ^Dnd) {
 dnd_send(d, d.focus, .Xdnd_Leave, {d.window, 0, 0, 0, 0})
 for l in ([]^wl.Listener{&d.enter,&d.motion,&d.drop,&d.retire,&d.source_destroy,&d.focus_destroy,&d.dropped_destroy}) { wl.unlisten(l) }
 d.drag, d.source, d.focus, d.dropped = nil, nil, nil, nil
}
dnd_finish :: proc(d: ^Dnd) { wl.unlisten(&d.start); dnd_clear(d) }
dnd_source_destroy :: proc(l: ^wl.Listener, data: rawptr) { dnd_clear(wl.owner(l, Dnd, "source_destroy")) }
dnd_start :: proc(l: ^wl.Listener, data: rawptr) {
 d := wl.owner(l, Dnd, "start"); dnd_clear(d)
 drag := cast(^seat.Drag)data; if drag.source == nil { return }
 d.drag, d.source = drag, drag.source
 wl.listen(&drag.events.focus, &d.enter, dnd_enter)
 wl.listen(&drag.events.motion, &d.motion, dnd_motion)
 wl.listen(&drag.events.drop, &d.drop, dnd_drop)
 wl.listen(&drag.events.destroy, &d.retire, dnd_retire)
 wl.listen(&d.source.events.destroy, &d.source_destroy, dnd_source_destroy)
 xcb.selection_owner(d.xwm.connection, d.window, d.xwm.atoms[.Xdnd_Selection]); schedule_flush(d.xwm)
}
dnd_focus_destroy :: proc(l: ^wl.Listener, data: rawptr) {
 d := wl.owner(l, Dnd, "focus_destroy"); wl.unlisten(l); d.focus = nil
 if d.drag != nil { d.drag.external_accepted = false }
}
dnd_dropped_destroy :: proc(l: ^wl.Listener, data: rawptr) { d := wl.owner(l, Dnd, "dropped_destroy"); wl.unlisten(l); d.dropped = nil }
dnd_enter :: proc(l: ^wl.Listener, data: rawptr) {
 d := wl.owner(l, Dnd, "enter"); m := d.xwm
 dnd_send(d, d.focus, .Xdnd_Leave, {d.window, 0, 0, 0, 0}); wl.unlisten(&d.focus_destroy); d.focus = nil
 seat.source_action(d.source, 0)
 for _,w in m.windows { if w.surface != nil && w.surface == d.drag.focus { d.focus = w; break } }
 if d.focus == nil { return }
 wl.listen(&d.focus.events.destroy, &d.focus_destroy, dnd_focus_destroy)
 atoms := make([dynamic]u32, context.temp_allocator)
 for mime in d.source.mimes { if atom := mime_atom(m, mime); atom != 0 { append(&atoms, atom) } }
 values := [5]u32{d.window, 5<<24, 0, 0, 0}
 if len(atoms) > 3 { values[1] |= 1; xcb.write_words(m.connection, d.window, m.atoms[.Xdnd_Type_List], 4, atoms[:]) }
 else { copy(values[2:], atoms[:]) }
 dnd_send(d, d.focus, .Xdnd_Enter, values)
}
dnd_action :: proc(d: ^Dnd, action: u32) -> u32 {
 switch action { case 1: return d.xwm.atoms[.Xdnd_Copy]; case 2: return d.xwm.atoms[.Xdnd_Move]; case 4: return d.xwm.atoms[.Xdnd_Ask] }; return 0
}
dnd_motion :: proc(l: ^wl.Listener, data: rawptr) {
 d := wl.owner(l, Dnd, "motion"); e := cast(^seat.Drag_Motion)data; d.time = e.time
 if d.focus == nil { return }
 action := d.source.actions if d.source.actions_set else 1
 preferred := action & (~action+1)
 x, y := u32(i32(d.focus.x)+i32(e.sx))&0xffff, u32(i32(d.focus.y)+i32(e.sy))&0xffff
 dnd_send(d, d.focus, .Xdnd_Position, {d.window, 0, x<<16|y, e.time, dnd_action(d, preferred)})
}
dnd_drop :: proc(l: ^wl.Listener, data: rawptr) {
 d := wl.owner(l, Dnd, "drop"); d.dropped = d.focus
 if d.dropped != nil { wl.listen(&d.dropped.events.destroy, &d.dropped_destroy, dnd_dropped_destroy) }
 dnd_send(d, d.dropped, .Xdnd_Drop, {d.window, 0, d.time, 0, 0})
}
dnd_retire :: proc(l: ^wl.Listener, data: rawptr) {
 d := wl.owner(l, Dnd, "retire")
 if d.dropped == nil { dnd_send(d, d.focus, .Xdnd_Leave, {d.window, 0, 0, 0, 0}) }
 for listener in ([]^wl.Listener{&d.enter,&d.motion,&d.drop,&d.retire,&d.focus_destroy}) { wl.unlisten(listener) }
 d.drag, d.focus = nil, nil
}
dnd_message :: proc(d: ^Dnd, e: xcb.Message) -> bool {
 a := &d.xwm.atoms; values := e.data.data32
 if e.type == a[.Xdnd_Status] {
  if d.drag == nil || d.focus == nil || values[0] != d.focus.window_id { return true }
  action: u32
  for candidate in ([]u32{1,2,4}) { if values[4] == dnd_action(d, candidate) { action = candidate } }
  if values[4] == a[.Xdnd_Private] { action = 1 }
  action &= d.source.actions if d.source.actions_set else 1
  d.drag.external_accepted = values[1]&1 != 0 && action != 0
  seat.source_action(d.source, action if d.drag.external_accepted else 0); return true
 }
 if e.type == a[.Xdnd_Finished] {
  if d.drag != nil || d.dropped == nil || values[0] != d.dropped.window_id { return true }
  if values[1]&1 != 0 { seat.source_finish(d.source) } else { seat.source_cancel(d.source) }
  dnd_clear(d); return true
 }; return false
}
