package seat

import wl "../wayland"
import p "../protocols"
import wlr "../wlroots"
import "base:runtime"

Drag_Icon :: struct { surface: ^wlr.Surface, drag: ^Drag, events: struct { destroy: wl.Signal }, destroy: wl.Listener }
Drag :: struct {
	seat: ^Seat,
	client: ^Client,
	source: ^Source,
	origin, focus: ^wlr.Surface,
	icon: ^Drag_Icon,
	serial, button: u32,
	offers: [dynamic]^Offer,
	devices: [dynamic]^Device,
	events: struct { destroy: wl.Signal },
	client_destroy, origin_destroy, focus_destroy: wl.Listener,
}
Drag_Event :: struct { drag: ^Drag, origin: ^wlr.Surface, serial: u32 }
drag_icon_assign: proc(^Drag_Icon, ^wl.Resource) -> bool
drag_icon_forget: proc(^Drag_Icon)
drag_request :: proc(d: ^Device, source: ^Source, origin, icon: ^wlr.Surface, serial: u32) {
	if source != nil && (source.use != .Unused || source.cancelled || source.finished) { wl.post_error(d.resource, u32(p.Wl_Data_Device_Error.used_source), "source was already used"); return }
	c := d.client
	if c == nil { return }
	s := c.seat; state := &s.pointer_state
	if s.drag != nil || origin == nil || state.focused_client != c || state.focused_surface != origin || len(state.buttons) != 1 || state.grab_serial != serial { return }
	drag := new(Drag)
	drag.seat, drag.client, drag.source, drag.origin, drag.serial, drag.button = s, c, source, origin, serial, state.grab_button
	wl.signal_init(&drag.events.destroy)
	if icon != nil {
		i := new(Drag_Icon); i.surface, i.drag = icon, drag; wl.signal_init(&i.events.destroy)
		if drag_icon_assign == nil || !drag_icon_assign(i, d.resource) { free(i); free(drag); return }
		drag.icon = i; surface_watch(icon, &i.destroy, drag_icon_surface_destroy)
	}
	if source != nil { source.use, source.drag = .Drag, drag }
	wl.listen(&c.events.destroy, &drag.client_destroy, drag_client_destroy)
	surface_watch(origin, &drag.origin_destroy, drag_origin_destroy)
	e := Drag_Event{drag, origin, serial}
	wl.signal_emit_mutable(&s.events.request_start_drag, &e)
	if s.drag != drag { drag_retire(drag, true) }
}
start_pointer_drag :: proc(s: ^Seat, drag: ^Drag, serial: u32) {
	if s.drag != nil || drag.seat != s || drag.serial != serial { return }
	pointer_notify_clear_focus(s)
	s.drag = drag
	wl.signal_emit_mutable(&s.events.start_drag, drag)
}
drag_client_destroy :: proc(l: ^wl.Listener, data: rawptr) { drag_cancel(wl.owner(l, Drag, "client_destroy").seat) }
drag_origin_destroy :: proc "c" (l: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	d := wl.owner(l, Drag, "origin_destroy"); context = d.seat.display.loop.ctx
	drag_cancel(d.seat)
}
drag_icon_surface_destroy :: proc "c" (l: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	i := wl.owner(l, Drag_Icon, "destroy"); context = i.drag.seat.display.loop.ctx
	drag_icon_destroy(i)
}
drag_icon_destroy :: proc(i: ^Drag_Icon) {
	wl.unlisten(&i.destroy)
	i.drag.icon = nil
	if drag_icon_forget != nil { drag_icon_forget(i) }
	wl.signal_emit_final(&i.events.destroy, i)
	free(i)
}
drag_focus_destroy :: proc "c" (l: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	d := wl.owner(l, Drag, "focus_destroy"); context = d.seat.display.loop.ctx
	drag_enter(d, nil, 0, 0)
}
drag_leave :: proc(d: ^Drag, dropped := false) {
	for device in d.devices { wl.post(device.resource, u32(p.Wl_Data_Device_Event.leave)) }
	for o in d.offers { if !dropped { offer_detach(o) }; o.device = nil }
	clear(&d.devices); clear(&d.offers)
	wl.unlisten(&d.focus_destroy); d.focus = nil
}
drag_enter :: proc(d: ^Drag, surface: ^wlr.Surface, sx, sy: f64) {
	if d.focus == surface { return }
	drag_leave(d)
	if surface == nil || (d.source == nil && surface_resource(surface).client != d.client.client) { return }
	d.focus = surface
	surface_watch(surface, &d.focus_destroy, drag_focus_destroy)
	client := client_for(d.seat, surface_resource(surface).client)
	if client == nil { return }
	serial := next_serial(client)
	for device in d.seat.devices {
		if device.manager.primary || device.client != client { continue }
		o: ^Offer
		if d.source != nil { o = offer_create(device, d.source, true); if o != nil { append(&d.offers, o) } }
		append(&d.devices, device)
		wl.post(device.resource, u32(p.Wl_Data_Device_Event.enter), wl.Uint(serial), wl.Object(surface_resource(surface)), fixed(sx), fixed(sy), wl.Object(o.resource if o != nil else nil))
	}
}
drag_motion :: proc(d: ^Drag, time: u32, sx, sy: f64) {
	for device in d.devices { wl.post(device.resource, u32(p.Wl_Data_Device_Event.motion), wl.Uint(time), fixed(sx), fixed(sy)) }
}
drag_offer_remove :: proc(d: ^Drag, o: ^Offer) { for other, i in d.offers { if other == o { ordered_remove(&d.offers, i); break } } }
drag_device_remove :: proc(d: ^Drag, device: ^Device) {
	for i := len(d.offers)-1; i >= 0; i -= 1 { o := d.offers[i]; if o.device == device { offer_detach(o); o.device = nil; ordered_remove(&d.offers, i) } }
	for other, i in d.devices { if other == device { ordered_remove(&d.devices, i); break } }
}
drag_drop :: proc(d: ^Drag) {
	accepted := d.source == nil && len(d.devices) > 0
	for o in d.offers { if o.source != nil && o.accepted && o.action != 0 { accepted = true } }
	if accepted {
		for device in d.devices { wl.post(device.resource, u32(p.Wl_Data_Device_Event.drop)) }
		for o in d.offers { o.dropped = true }
		if d.source != nil && d.source.resource.version >= 3 { wl.post(d.source.resource, u32(p.Wl_Data_Source_Event.dnd_drop_performed)) }
	}
	drag_retire(d, !accepted)
}
drag_cancel :: proc(s: ^Seat) { if s != nil && s.drag != nil { drag_retire(s.drag, true) } }
drag_retire :: proc(d: ^Drag, cancel: bool) {
	if d.seat.drag == d { d.seat.drag = nil }
	if d.source != nil { d.source.drag = nil; if cancel { source_cancel(d.source) } }
	drag_leave(d, !cancel)
	wl.unlisten(&d.client_destroy); wl.unlisten(&d.origin_destroy)
	if d.icon != nil { drag_icon_destroy(d.icon) }
	wl.signal_emit_final(&d.events.destroy, d)
	delete(d.offers); delete(d.devices); free(d)
}
