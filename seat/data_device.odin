package seat

import wl "../wayland"
import p "../protocols"
import "core:strings"
import "core:sys/linux"

Data_Manager :: struct { global: ^wl.Global, primary: bool, resources: [dynamic]^wl.Resource, destroy: wl.Listener }
Source :: struct {
	manager: ^Data_Manager,
	resource: ^wl.Resource,
	mimes: [dynamic]string,
	offers: [dynamic]^Offer,
	use: enum { Unused, Selection, Drag },
	actions, action: u32,
	actions_set, cancelled, finished: bool,
	seat: ^Seat,
	drag: ^Drag,
}
Device :: struct { manager: ^Data_Manager, resource: ^wl.Resource, client: ^Client, selection: ^Offer, destroy: wl.Listener }
Offer :: struct {
	manager: ^Data_Manager,
	resource: ^wl.Resource,
	source: ^Source,
	device: ^Device,
	mimes: [dynamic]string,
	drag, dropped, finished, accepted: bool,
	actions, preferred, action: u32,
}
Selection_Event :: struct { source: ^Source, serial: u32 }
data_device_manager_create :: proc(display: ^wl.Display) -> ^Data_Manager {
	m := new(Data_Manager)
	m.global = wl.global_create_typed(display, &p.wl_data_device_manager, 3, m, data_manager_request, data_manager_release, data_manager_bound)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, data_manager_destroy)
	return m
}
data_manager_bound :: proc(r: ^wl.Resource) { append(&(cast(^Data_Manager)r.data).resources, r) }
data_manager_release :: proc(r: ^wl.Resource) { remove_resource(&(cast(^Data_Manager)r.data).resources, r) }
data_manager_destroy :: proc(l: ^wl.Listener, data: rawptr) {
	m := wl.owner(l, Data_Manager, "destroy")
	wl.unlisten(l)
	for len(m.resources) > 0 { wl.resource_destroy(m.resources[len(m.resources)-1]) }
	wl.global_destroy(m.global); delete(m.resources); free(m)
}
data_manager_request :: proc(r: ^wl.Resource, request: p.Wl_Data_Device_Manager_Request, args: []wl.Argument) {
	switch request {
	case .release: wl.resource_destroy(r)
	case .create_data_source: source_create(cast(^Data_Manager)r.data, r, u32(args[0].(wl.New_Id)))
	case .get_data_device: device_create(cast(^Data_Manager)r.data, r, u32(args[0].(wl.New_Id)), client_of(wl.object(args[1])))
	}
}
source_create :: proc(m: ^Data_Manager, parent: ^wl.Resource, id: u32) {
	s := new(Source); s.manager = m
	if m.primary { s.resource = wl.resource_create_typed(parent.client, &p.zwp_primary_selection_source_v1, 1, id, s, primary_source_request, source_destroy) }
	else { s.resource = wl.resource_create_typed(parent.client, &p.wl_data_source, parent.version, id, s, source_request, source_destroy) }
	if s.resource == nil { free(s); return }
	append(&m.resources, s.resource)
}
source_of :: proc(r: ^wl.Resource) -> ^Source { return cast(^Source)r.data if r != nil else nil }
source_offer :: proc(s: ^Source, mime: string) {
	if s.cancelled || s.finished { return }
	for old in s.mimes { if old == mime { return } }
	append(&s.mimes, strings.clone(mime))
}
source_request :: proc(r: ^wl.Resource, request: p.Wl_Data_Source_Request, args: []wl.Argument) {
	s := cast(^Source)r.data
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .offer: source_offer(s, args[0].(wl.String).value)
	case .set_actions:
		actions := u32(args[0].(wl.Uint))
		if actions&~u32(7) != 0 { wl.post_error(r, u32(p.Wl_Data_Source_Error.invalid_action_mask), "invalid source actions"); return }
		if s.actions_set || s.use != .Unused { wl.post_error(r, u32(p.Wl_Data_Source_Error.invalid_source), "source actions already assigned"); return }
		s.actions, s.actions_set = actions, true
	}
}
offer_detach :: proc(o: ^Offer) {
	if o.source == nil { return }
	for other, i in o.source.offers { if other == o { ordered_remove(&o.source.offers, i); break } }
	o.source = nil
}
source_cancel :: proc(s: ^Source) {
	if s == nil || s.cancelled || s.finished { return }
	s.cancelled = true
	wl.post(s.resource, 1 if s.manager.primary else u32(p.Wl_Data_Source_Event.cancelled))
	for len(s.offers) > 0 { offer_detach(s.offers[len(s.offers)-1]) }
}
source_destroy :: proc(r: ^wl.Resource) {
	s := cast(^Source)r.data
	if s.drag != nil { drag_cancel(s.drag.seat) }
	if s.seat != nil { selection_set(s.seat, nil, wl.next_serial(s.seat.display), s.manager.primary) }
	for len(s.offers) > 0 { offer_detach(s.offers[len(s.offers)-1]) }
	remove_resource(&s.manager.resources, r)
	for mime in s.mimes { delete(mime) }; delete(s.mimes); delete(s.offers); free(s)
}
device_create :: proc(m: ^Data_Manager, parent: ^wl.Resource, id: u32, c: ^Client) {
	d := new(Device); d.manager, d.client = m, c
	if m.primary { d.resource = wl.resource_create_typed(parent.client, &p.zwp_primary_selection_device_v1, 1, id, d, primary_device_request, device_destroy) }
	else { d.resource = wl.resource_create_typed(parent.client, &p.wl_data_device, parent.version, id, d, device_request, device_destroy) }
	if d.resource == nil { free(d); return }
	append(&m.resources, d.resource)
	if c != nil {
		append(&c.seat.devices, d)
		wl.listen(&c.events.destroy, &d.destroy, device_client_destroy)
		if c.seat.keyboard_state.focused_client == c { device_selection(d) }
	}
}
device_release :: proc(d: ^Device) {
	wl.unlisten(&d.destroy)
	if d.selection != nil { offer_detach(d.selection); d.selection.device = nil; d.selection = nil }
	if d.client != nil {
		s := d.client.seat
		if s.drag != nil { drag_device_remove(s.drag, d) }
		for other, i in s.devices { if other == d { ordered_remove(&s.devices, i); break } }
		d.client = nil
	}
}
device_client_destroy :: proc(l: ^wl.Listener, data: rawptr) { device_release(wl.owner(l, Device, "destroy")) }
device_destroy :: proc(r: ^wl.Resource) {
	d := cast(^Device)r.data
	device_release(d); remove_resource(&d.manager.resources, r); free(d)
}
device_request :: proc(r: ^wl.Resource, request: p.Wl_Data_Device_Request, args: []wl.Argument) {
	d := cast(^Device)r.data
	switch request {
	case .release: wl.resource_destroy(r)
	case .set_selection: selection_request(d, source_of(wl.object(args[0])), u32(args[1].(wl.Uint)))
	case .start_drag: drag_request(d, source_of(wl.object(args[0])), surface_of(wl.object(args[1])), surface_of(wl.object(args[2])), u32(args[3].(wl.Uint)))
	}
}
selection_request :: proc(d: ^Device, source: ^Source, serial: u32) {
	if source != nil && source.seat != nil && d.client != nil && source.seat == d.client.seat {
		previous := source.seat.primary_selection_serial if d.manager.primary else source.seat.selection_serial
		// Toolkit retries of an identical selection do not constitute a new use.
		if serial == previous { return }
	}
	if source != nil && (source.use != .Unused || source.cancelled || source.finished) {
		if !d.manager.primary { wl.post_error(d.resource, u32(p.Wl_Data_Device_Error.used_source), "source was already used") }; return
	}
	if source != nil && source.actions_set { wl.post_error(source.resource, u32(p.Wl_Data_Source_Error.invalid_source), "drag source cannot be a selection"); return }
	c := d.client
	if c == nil || !valid_serial(c, serial) { return }
	s := c.seat
	previous := s.primary_selection_serial if d.manager.primary else s.selection_serial
	current := s.primary_selection_source if d.manager.primary else s.selection_source
	if current != nil && i32(serial-previous) < 0 { return }
	e := Selection_Event{source, serial}
	wl.signal_emit_mutable(&s.events.request_set_primary_selection if d.manager.primary else &s.events.request_set_selection, &e)
}
set_selection :: proc(s: ^Seat, source: ^Source, serial: u32) { selection_set(s, source, serial, false) }
set_primary_selection :: proc(s: ^Seat, source: ^Source, serial: u32) { selection_set(s, source, serial, true) }
selection_set :: proc(s: ^Seat, source: ^Source, serial: u32, primary: bool) {
	slot := &s.primary_selection_source if primary else &s.selection_source
	if slot^ == source { return }
	if old := slot^; old != nil { old.seat = nil; source_cancel(old) }
	slot^ = source
	if primary { s.primary_selection_serial = serial } else { s.selection_serial = serial }
	if source != nil { source.seat, source.use = s, .Selection }
	for d in s.devices { if d.manager.primary == primary { device_selection(d) } }
}
selection_focus :: proc(s: ^Seat) { for d in s.devices { device_selection(d) } }
device_selection :: proc(d: ^Device) {
	if d.selection != nil { offer_detach(d.selection); d.selection.device = nil; d.selection = nil }
	if d.client == nil || d.client.seat.keyboard_state.focused_client != d.client { return }
	s := d.client.seat
	source := s.primary_selection_source if d.manager.primary else s.selection_source
	if source != nil { d.selection = offer_create(d, source, false) }
	wl.post(d.resource, 1 if d.manager.primary else u32(p.Wl_Data_Device_Event.selection), wl.Object(d.selection.resource if d.selection != nil else nil))
}
offer_create :: proc(d: ^Device, source: ^Source, drag: bool) -> ^Offer {
	o := new(Offer); o.manager, o.source, o.device, o.drag = d.manager, source, d, drag
	if d.manager.primary { o.resource = wl.resource_create_typed(d.resource.client, &p.zwp_primary_selection_offer_v1, 1, 0, o, primary_offer_request, offer_destroy) }
	else { o.resource = wl.resource_create_typed(d.resource.client, &p.wl_data_offer, d.resource.version, 0, o, offer_request, offer_destroy) }
	if o.resource == nil { free(o); return nil }
	append(&o.manager.resources, o.resource); append(&source.offers, o)
	wl.post(d.resource, 0, wl.Object(o.resource))
	for mime in source.mimes { append(&o.mimes, strings.clone(mime)); wl.post(o.resource, 0, wl.String{value=mime}) }
	if drag {
		if o.resource.version < 3 { o.actions = 1 }
		else { wl.post(o.resource, u32(p.Wl_Data_Offer_Event.source_actions), wl.Uint(source.actions if source.actions_set else 1)) }
		offer_action(o)
	}
	return o
}
offer_receive :: proc(o: ^Offer, mime: string, fd: wl.Fd) {
	// SCM_RIGHTS gives this process its own descriptor; post duplicates it for the source.
	defer linux.close(linux.Fd(fd))
	if o.source == nil || o.finished { return }
	for offered in o.mimes { if offered == mime {
		wl.post(o.source.resource, 0 if o.manager.primary else u32(p.Wl_Data_Source_Event.send), wl.String{value=mime}, fd)
		return
	} }
}
offer_destroy :: proc(r: ^wl.Resource) {
	o := cast(^Offer)r.data
	if o.drag && o.source != nil && o.dropped && !o.finished {
		if r.version < 3 { offer_finish(o) } else { source_cancel(o.source) }
	}
	if o.device != nil {
		if o.device.selection == o { o.device.selection = nil }
		if o.device.client != nil && o.device.client.seat.drag != nil { drag_offer_remove(o.device.client.seat.drag, o) }
	}
	offer_detach(o); remove_resource(&o.manager.resources, r)
	for mime in o.mimes { delete(mime) }; delete(o.mimes); free(o)
}
offer_action :: proc(o: ^Offer) {
	if o.source == nil { return }
	s := o.source
	common := o.actions & (s.actions if s.actions_set else 1)
	action := o.preferred if common&o.preferred != 0 else common & (~common+1)
	if action == o.action { return }
	o.action = action
	if o.dropped { return }
	if s.action != action { s.action = action; if s.resource.version >= 3 { wl.post(s.resource, u32(p.Wl_Data_Source_Event.action), wl.Uint(action)) } }
	if o.resource.version >= 3 { wl.post(o.resource, u32(p.Wl_Data_Offer_Event.action), wl.Uint(action)) }
}
offer_finish :: proc(o: ^Offer) {
	s := o.source
	if s == nil || s.finished { return }
	if s.resource.version >= 3 {
		if s.action != o.action { wl.post(s.resource, u32(p.Wl_Data_Source_Event.action), wl.Uint(o.action)) }
		wl.post(s.resource, u32(p.Wl_Data_Source_Event.dnd_finished))
	}
	s.finished, o.finished = true, true
	for len(s.offers) > 0 { offer_detach(s.offers[len(s.offers)-1]) }
}
offer_request :: proc(r: ^wl.Resource, request: p.Wl_Data_Offer_Request, args: []wl.Argument) {
	o := cast(^Offer)r.data
	if request == .destroy { wl.resource_destroy(r); return }
	if o.finished {
		if request == .receive { linux.close(linux.Fd(args[1].(wl.Fd))) }
		wl.post_error(r, u32(p.Wl_Data_Offer_Error.invalid_offer), "offer already finished"); return
	}
	switch request {
	case .destroy:
	case .receive: offer_receive(o, args[0].(wl.String).value, args[1].(wl.Fd))
	case .accept:
		if !o.drag || o.source == nil { return }
		mime := args[1].(wl.String)
		o.accepted = false
		for offered in o.mimes { if !mime.is_null && mime.value == offered { o.accepted = true } }
		wl.post(o.source.resource, u32(p.Wl_Data_Source_Event.target), wl.String{value=mime.value, is_null=!o.accepted})
	case .finish:
		if !o.drag || !o.dropped || !o.accepted || o.action == 0 || o.action == 4 {
			wl.post_error(r, u32(p.Wl_Data_Offer_Error.invalid_finish), "offer is not ready to finish"); return
		}
		offer_finish(o)
	case .set_actions:
		if !o.drag { wl.post_error(r, u32(p.Wl_Data_Offer_Error.invalid_offer), "selection has no drag actions"); return }
		actions, preferred := u32(args[0].(wl.Uint)), u32(args[1].(wl.Uint))
		if actions&~u32(7) != 0 { wl.post_error(r, u32(p.Wl_Data_Offer_Error.invalid_action_mask), "invalid destination actions"); return }
		if preferred&(preferred-1) != 0 || preferred&actions != preferred || (o.dropped && o.action == 4 && (preferred == 4 || preferred == 0 || (o.source != nil && preferred&o.source.actions == 0))) {
			wl.post_error(r, u32(p.Wl_Data_Offer_Error.invalid_action), "invalid preferred action"); return
		}
		o.actions, o.preferred = actions, preferred; offer_action(o)
	}
}
