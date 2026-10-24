package extensions

import p "../protocols"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"
import "core:fmt"

Cursor_Shape_Manager :: struct {
	global: ^wl.Global,
	devices: [dynamic]^Cursor_Shape_Device,
	focus: [dynamic]^Cursor_Shape_Focus,
	events: struct { request_set_shape, destroy: wl.Signal },
	destroy, posted: wl.Listener,
}
Cursor_Shape_Event :: struct {
	seat_client: ^wlr.wlr_seat_client,
	device_type: i32,
	serial: u32,
	shape: i32,
}
Cursor_Shape_Device :: struct { manager: ^Cursor_Shape_Manager, resource: ^wl.Resource, focus: ^Cursor_Shape_Focus }
Cursor_Shape_Focus :: struct {
	manager: ^Cursor_Shape_Manager,
	client: ^wlr.wlr_seat_client,
	serial: u32,
	entered: bool,
	destroy: wl.Listener,
}
// Enum spelling is generated from XML; CSS cursor names use hyphens.
cursor_shape_names: [p.Wp_Cursor_Shape_Device_V1_Shape][32]u8
@(init)
cursor_shape_names_init :: proc "contextless" () {
	context = runtime.default_context()
	for shape in p.Wp_Cursor_Shape_Device_V1_Shape {
		name := fmt.bprintf(cursor_shape_names[shape][:], "%v", shape)
		for c, i in name { if c == '_' { cursor_shape_names[shape][i] = '-' } }
	}
}
cursor_shape_name :: proc(shape: i32) -> cstring {
	if shape < i32(min(p.Wp_Cursor_Shape_Device_V1_Shape)) || shape > i32(max(p.Wp_Cursor_Shape_Device_V1_Shape)) { return nil }
	return cstring(&cursor_shape_names[p.Wp_Cursor_Shape_Device_V1_Shape(shape)][0])
}
cursor_shape_create :: proc(display: ^wl.Display) -> ^Cursor_Shape_Manager {
	m := new(Cursor_Shape_Manager)
	wl.signal_init(&m.events.request_set_shape)
	wl.signal_init(&m.events.destroy)
	m.global = wl.global_create_typed(display, &p.wp_cursor_shape_manager_v1, 2, m, cursor_shape_request)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, cursor_shape_destroyed)
	wl.listen(&display.posted, &m.posted, cursor_shape_posted)
	return m
}
cursor_shape_focus :: proc(m: ^Cursor_Shape_Manager, client: ^wlr.wlr_seat_client) -> ^Cursor_Shape_Focus {
	if client == nil { return nil }
	for f in m.focus { if f.client == client { return f } }
	f := new(Cursor_Shape_Focus)
	f.manager, f.client = m, client
	append(&m.focus, f)
	wl.listen(&client.events.destroy, &f.destroy, cursor_shape_client_destroyed)
	return f
}
cursor_shape_focus_release :: proc(f: ^Cursor_Shape_Focus) {
	for d in f.manager.devices { if d.focus == f { d.focus = nil } }
	for other, i in f.manager.focus { if other == f { ordered_remove(&f.manager.focus, i); break } }
	wl.unlisten(&f.destroy)
	free(f)
}
cursor_shape_client_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	f := wl.owner(listener, Cursor_Shape_Focus, "destroy")
	context = f.manager.global.display.loop.ctx
	cursor_shape_focus_release(f)
}
cursor_shape_posted :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Cursor_Shape_Manager, "posted")
	context = m.global.display.loop.ctx
	e := cast(^wl.Posted_Event)data
	if e.resource.interface == &p.wl_pointer && (e.opcode == u32(p.Wl_Pointer_Event.enter) || e.opcode == u32(p.Wl_Pointer_Event.leave)) {
		f := cursor_shape_focus(m, pointer_seat_client_of(e.resource))
		if f != nil { f.serial, f.entered = u32(e.args[0].(wl.Uint)), e.opcode == u32(p.Wl_Pointer_Event.enter) }
	} else if e.resource.interface == &p.wl_seat && e.opcode == u32(p.Wl_Seat_Event.capabilities) && u32(e.args[0].(wl.Uint))&1 == 0 {
		client := seat_client_of(e.resource)
		for d in m.devices { if d.focus != nil && d.focus.client == client { d.focus = nil } }
	}
}
cursor_shape_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Cursor_Shape_Manager, "destroy")
	context = m.global.display.loop.ctx
	wl.unlisten(&m.posted)
	for len(m.devices) > 0 { wl.resource_destroy(m.devices[len(m.devices)-1].resource) }
	for len(m.focus) > 0 { cursor_shape_focus_release(m.focus[len(m.focus)-1]) }
	wl.signal_emit_final(&m.events.destroy, m)
	wl.unlisten(listener)
	wl.global_destroy(m.global)
	delete(m.devices)
	delete(m.focus)
	free(m)
}
cursor_shape_device_destroy :: proc(r: ^wl.Resource) {
	d := cast(^Cursor_Shape_Device)r.data
	for other, i in d.manager.devices { if other == d { ordered_remove(&d.manager.devices, i); break } }
	free(d)
}
cursor_shape_device_request :: proc(r: ^wl.Resource, request: p.Wp_Cursor_Shape_Device_V1_Request, args: []wl.Argument) {
	d := cast(^Cursor_Shape_Device)r.data
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .set_shape:
		if d.focus == nil { return }
		shape, serial := u32(args[1].(wl.Uint)), u32(args[0].(wl.Uint))
		if cursor_shape_name(i32(shape)) == nil || r.version < 2 && shape > u32(p.Wp_Cursor_Shape_Device_V1_Shape.zoom_out) {
			wl.post_error(r, u32(p.Wp_Cursor_Shape_Device_V1_Error.invalid_shape), "invalid cursor shape")
			return
		}
		f := d.focus
		if !f.entered || serial != f.serial || f.client != f.client.seat.pointer_state.focused_client { return }
		event := Cursor_Shape_Event{seat_client = f.client, serial = serial, shape = i32(shape)}
		wl.signal_emit_mutable(&d.manager.events.request_set_shape, &event)
	}
}
cursor_shape_request :: proc(r: ^wl.Resource, request: p.Wp_Cursor_Shape_Manager_V1_Request, args: []wl.Argument) {
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .get_pointer, .get_tablet_tool_v2:
		d := new(Cursor_Shape_Device)
		d.manager = cast(^Cursor_Shape_Manager)r.data
		d.resource = wl.resource_create_typed(r.client, &p.wp_cursor_shape_device_v1, r.version,
			u32(args[0].(wl.New_Id)), d, cursor_shape_device_request, cursor_shape_device_destroy)
		if d.resource == nil { free(d); return }
		append(&d.manager.devices, d)
		if request == .get_pointer { d.focus = cursor_shape_focus(d.manager, pointer_seat_client_of(wl.object(args[1]))) }
	}
}
