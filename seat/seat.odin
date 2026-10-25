package seat

import wl "../wayland"
import p "../protocols"
import "core:strings"

Seat :: struct {
	display: ^wl.Display,
	global: ^wl.Global,
	name: string,
	capabilities, ever_capabilities: u32,
	clients: [dynamic]^Client,
	devices: [dynamic]^Device,
	selection_source, primary_selection_source: ^Source,
	selection_serial, primary_selection_serial: u32,
	drag: ^Drag,
	keyboard_state: Keyboard_State,
	pointer_state: Pointer_State,
	events: struct { set_selection, set_primary_selection, request_set_selection, request_set_primary_selection, request_start_drag, start_drag, request_set_cursor, pointer_focus_change, keyboard_focus_change, destroy: wl.Signal },
	destroy: wl.Listener,
}
Client :: struct {
	client: ^wl.Client,
	seat: ^Seat,
	seats, pointers, keyboards: [dynamic]^wl.Resource,
	serials: [128]struct { first, last: u32 },
	serial_count, serial_end: int,
	enter_serial: u32,
	pointer_entered: bool,
	axis_value: [2]f64,
	axis_discrete: [2]i32,
	events: struct { destroy: wl.Signal },
	destroy: wl.Listener,
}
create :: proc(display: ^wl.Display, name: cstring) -> ^Seat {
	s := new(Seat)
	s.display, s.name = display, strings.clone(string(name))
	for signal in ([]^wl.Signal{&s.events.set_selection, &s.events.set_primary_selection, &s.events.request_set_cursor, &s.events.pointer_focus_change,
		&s.events.keyboard_focus_change, &s.events.destroy, &s.events.request_set_selection, &s.events.request_set_primary_selection, &s.events.request_start_drag, &s.events.start_drag}) { wl.signal_init(signal) }
	s.global = wl.global_create_typed(display, &p.wl_seat, 9, s, seat_request, seat_resource_destroy, seat_bind)
	if s.global == nil { delete(s.name); free(s); return nil }
	wl.listen(&display.destroy_signal, &s.destroy, seat_display_destroyed)
	return s
}
seat_display_destroyed :: proc(listener: ^wl.Listener, data: rawptr) { destroy(wl.owner(listener, Seat, "destroy")) }
destroy :: proc(s: ^Seat) {
	wl.unlisten(&s.destroy)
	drag_cancel(s)
	set_selection(s, nil, 0); set_primary_selection(s, nil, 0)
	wl.signal_emit_final(&s.events.destroy, s)
	pointer_notify_clear_focus(s)
	keyboard_notify_clear_focus(s)
	set_keyboard(s, nil)
	for len(s.clients) > 0 { client_destroy(s.clients[len(s.clients)-1]) }
	wl.global_destroy(s.global)
	delete(s.devices); delete(s.clients); delete(s.name); delete(s.pointer_state.buttons); delete(s.keyboard_state.keycodes)
	free(s)
}
client_for :: proc(s: ^Seat, client: ^wl.Client) -> ^Client {
	for c in s.clients { if c.client == client { return c } }
	return nil
}
client_of :: proc(r: ^wl.Resource) -> ^Client { return cast(^Client)r.data if r != nil && r.interface == &p.wl_seat else nil }
pointer_client_of :: proc(r: ^wl.Resource) -> ^Client { return cast(^Client)r.data if r != nil && r.interface == &p.wl_pointer else nil }
seat_bind :: proc(r: ^wl.Resource) {
	s := cast(^Seat)r.data
	c := client_for(s, r.client)
	if c == nil {
		c = new(Client)
		c.client, c.seat = r.client, s
		wl.signal_init(&c.events.destroy)
		append(&s.clients, c)
		wl.listen(&r.client.destroy_signal, &c.destroy, client_gone)
	}
	r.data = c
	append(&c.seats, r)
	wl.post(r, u32(p.Wl_Seat_Event.capabilities), wl.Uint(s.capabilities))
	if r.version >= 2 { wl.post(r, u32(p.Wl_Seat_Event.name), wl.String{value=s.name}) }
}
remove_resource :: proc(resources: ^[dynamic]^wl.Resource, r: ^wl.Resource) {
	for other, i in resources^ { if other == r { ordered_remove(resources, i); return } }
}
seat_resource_destroy :: proc(r: ^wl.Resource) {
	if c := client_of(r); c != nil {
		remove_resource(&c.seats, r)
		if len(c.seats) == 0 { client_destroy(c) }
	}
}
client_gone :: proc(listener: ^wl.Listener, data: rawptr) { client_destroy(wl.owner(listener, Client, "destroy")) }
client_destroy :: proc(c: ^Client) {
	s := c.seat
	if s.pointer_state.focused_client == c { pointer_notify_clear_focus(s) }
	if s.keyboard_state.focused_client == c { keyboard_notify_clear_focus(s) }
	wl.signal_emit_final(&c.events.destroy, c)
	wl.unlisten(&c.destroy)
	for resources in ([]^[dynamic]^wl.Resource{&c.seats, &c.pointers, &c.keyboards}) {
		for r in resources^ { r.data = nil }
		delete(resources^)
	}
	for other, i in s.clients { if other == c { ordered_remove(&s.clients, i); break } }
	free(c)
}
seat_request :: proc(r: ^wl.Resource, request: p.Wl_Seat_Request, args: []wl.Argument) {
	c := client_of(r)
	if request == .release { wl.resource_destroy(r); return }
	if c == nil {
		switch request {
		case .get_pointer: wl.resource_create_typed(r.client, &p.wl_pointer, r.version, u32(args[0].(wl.New_Id)), nil, pointer_request, pointer_destroy)
		case .get_keyboard: wl.resource_create_typed(r.client, &p.wl_keyboard, r.version, u32(args[0].(wl.New_Id)), nil, keyboard_request, keyboard_destroy)
		case .get_touch: wl.post_error(r, u32(p.Wl_Seat_Error.missing_capability), "seat never had touch capability")
		case .release:
		}
		return
	}
	capability := u32(1) if request == .get_pointer else u32(2) if request == .get_keyboard else u32(4)
	if c.seat.ever_capabilities&capability == 0 { wl.post_error(r, u32(p.Wl_Seat_Error.missing_capability), "seat never had this capability"); return }
	switch request {
	case .get_pointer: pointer_bind(c, r.version, u32(args[0].(wl.New_Id)))
	case .get_keyboard: keyboard_bind(c, r.version, u32(args[0].(wl.New_Id)))
	case .get_touch, .release:
	}
}
set_capabilities :: proc(s: ^Seat, caps: u32) {
	if s.capabilities == caps { return }
	s.capabilities, s.ever_capabilities = caps, s.ever_capabilities|caps
	for c in s.clients {
		if caps&1 == 0 {
			for r in c.pointers { r.data = nil }
			clear(&c.pointers)
			c.pointer_entered = false
		}
		if caps&2 == 0 { for r in c.keyboards { r.data = nil }; clear(&c.keyboards) }
		if cursor_shape_capabilities != nil { cursor_shape_capabilities(c, caps) }
		for r in c.seats { wl.post(r, u32(p.Wl_Seat_Event.capabilities), wl.Uint(caps)) }
	}
}
next_serial :: proc(c: ^Client) -> u32 {
	serial := wl.next_serial(c.seat.display)
	if serial == 0 { serial = wl.next_serial(c.seat.display) }
	if c.serial_count == 0 { c.serial_count = 1; c.serials[0] = {serial, serial} }
	else if c.serials[c.serial_end].last+1 == serial { c.serials[c.serial_end].last = serial }
	else { c.serial_end = (c.serial_end+1)%len(c.serials); c.serial_count = min(c.serial_count+1,len(c.serials)); c.serials[c.serial_end] = {serial,serial} }
	return serial
}
valid_serial :: proc(c: ^Client, serial: u32) -> bool {
	if c == nil || serial == 0 { return false }
	cur := c.seat.display.serial
	distance := cur-serial
	if distance >= max(u32)/2 { return false }
	for i in 0..<c.serial_count {
		range := c.serials[(c.serial_end-i+len(c.serials))%len(c.serials)]
		if distance < cur-range.last { return false }
		if distance <= cur-range.first { return true }
	}
	return c.serial_count == len(c.serials)
}

cursor_shape_entered: proc(^Client, u32)
cursor_shape_capabilities: proc(^Client, u32)
