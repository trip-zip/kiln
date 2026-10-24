package wayland

import "base:runtime"

resource_create_typed :: proc(client: ^Client, iface: ^Interface, version: i32, id: u32,
	data: rawptr, $dispatch: proc(^Resource, $Opcode, []Argument), destructor: proc(^Resource) = nil) -> ^Resource {
	r := resource_create(client, iface, version, id)
	if r == nil { client_no_memory(client); return nil }
	r.data, r.destructor = data, destructor
	r.dispatcher = proc(r: ^Resource, opcode: u32, args: []Argument) { dispatch(r, Opcode(opcode), args) }
	return r
}

global_create_typed :: proc(display: ^Display, iface: ^Interface, version: i32,
	data: ^$T, $dispatch: proc(^Resource, $Opcode, []Argument), destructor: proc(^Resource) = nil,
	initialize: proc(^Resource) = nil) -> ^Global {
	g := global_create(display, iface, version, data, proc(g: ^Global, client: ^Client, version, id: u32) {
		r := resource_create_typed(client, g.interface, i32(version), id, g.data, dispatch, g.resource_destructor)
		if r != nil && g.resource_initialize != nil { g.resource_initialize(r) }
	})
	if g != nil { g.resource_destructor, g.resource_initialize = destructor, initialize }
	return g
}

object :: proc(arg: Argument) -> ^Resource { return cast(^Resource)arg.(Object) }

Client_Resources :: struct { links: Iterator, client: ^Client }
client_resources :: proc(head: ^List, client: ^Client) -> Client_Resources { return {iterate(head), client} }
next_resource :: proc(it: ^Client_Resources) -> (resource: ^Resource, ok: bool) {
	for link in next(&it.links) {
		r := runtime.container_of(link, Resource, "link")
		if r.client == it.client { return r, true }
	}
	return nil, false
}
