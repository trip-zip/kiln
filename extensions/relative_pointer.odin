package extensions

import st "../seat"

import p "../protocols"
import wl "../wayland"
import "core:math"

Relative_Manager :: struct {
	global: ^wl.Global,
	pointers: [dynamic]^Relative_Pointer,
	destroy: wl.Listener,
}
Relative_Pointer :: struct {
	manager: ^Relative_Manager,
	resource, pointer: ^wl.Resource,
	seat: ^st.Seat,
	seat_destroy, pointer_destroy: wl.Listener,
}
relative_create :: proc(display: ^wl.Display) -> ^Relative_Manager {
	m := new(Relative_Manager)
	m.global = wl.global_create_typed(display, &p.zwp_relative_pointer_manager_v1, 1, m, relative_request)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, relative_destroyed)
	return m
}
relative_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	m := wl.owner(listener, Relative_Manager, "destroy")
	for len(m.pointers) > 0 { wl.resource_destroy(m.pointers[len(m.pointers)-1].resource) }
	wl.unlisten(listener)
	wl.global_destroy(m.global)
	delete(m.pointers)
	free(m)
}
relative_release :: proc(r: ^Relative_Pointer) {
	wl.unlisten(&r.seat_destroy)
	wl.unlisten(&r.pointer_destroy)
	r.seat, r.pointer = nil, nil
}
relative_seat_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	relative_release(wl.owner(listener, Relative_Pointer, "seat_destroy"))
}
relative_pointer_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	relative_release(wl.owner(listener, Relative_Pointer, "pointer_destroy"))
}
relative_resource_destroy :: proc(resource: ^wl.Resource) {
	r := cast(^Relative_Pointer)resource.data
	relative_release(r)
	for other, i in r.manager.pointers { if other == r { ordered_remove(&r.manager.pointers, i); break } }
	free(r)
}
relative_pointer_request :: proc(r: ^wl.Resource, request: p.Zwp_Relative_Pointer_V1_Request, args: []wl.Argument) {
	switch request { case .destroy: wl.resource_destroy(r) }
}
relative_request :: proc(resource: ^wl.Resource, request: p.Zwp_Relative_Pointer_Manager_V1_Request, args: []wl.Argument) {
	switch request {
	case .destroy: wl.resource_destroy(resource)
	case .get_relative_pointer:
		r := new(Relative_Pointer)
		r.manager, r.pointer = cast(^Relative_Manager)resource.data, wl.object(args[1])
		r.resource = wl.resource_create_typed(resource.client, &p.zwp_relative_pointer_v1, resource.version,
			u32(args[0].(wl.New_Id)), r, relative_pointer_request, relative_resource_destroy)
		if r.resource == nil { free(r); return }
		append(&r.manager.pointers, r)
		client := pointer_seat_client_of(r.pointer)
		if client == nil { r.pointer = nil; return }
		r.seat = client.seat
		wl.listen(&r.seat.events.destroy, &r.seat_destroy, relative_seat_destroyed)
		wl.listen(&r.pointer.destroy_signal, &r.pointer_destroy, relative_pointer_destroyed)
	}
}
relative_motion :: proc(m: ^Relative_Manager, seat: ^st.Seat, time_msec: u32, dx, dy, ux, uy: f64) {
	if m == nil || seat == nil || seat.pointer_state.focused_client == nil { return }
	stamp := u64(time_msec)*1000
	for r in m.pointers {
		if r.seat != seat || pointer_seat_client_of(r.pointer) != seat.pointer_state.focused_client { continue }
		wl.post(r.resource, u32(p.Zwp_Relative_Pointer_V1_Event.relative_motion), wl.Uint(stamp>>32), wl.Uint(stamp),
			wl.Fixed(math.round(dx*256)), wl.Fixed(math.round(dy*256)),
			wl.Fixed(math.round(ux*256)), wl.Fixed(math.round(uy*256)))
	}
}
