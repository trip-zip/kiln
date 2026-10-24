package wayland

import "core:c/libc"
import "core:sys/linux"

Resource :: struct {
	id: u32,
	interface: ^Interface,
	client: ^Client,
	version: i32,
	data, implementation, c_destructor: rawptr,
	dispatcher: proc(^Resource, u32, []Argument),
	destructor: proc(^Resource),
	destroy_signal: Signal,
	link: List,
	destroying: bool,
}
c_dispatch: proc(^Resource, u32, []Argument)
c_destroy: proc(^Resource)
resource_create :: proc(client: ^Client, iface: ^Interface, version: i32, requested_id: u32) -> ^Resource {
	context = client.display.loop.ctx
	id := requested_id
	if id == 0 {
		if client.free_head != max(u32) {
			index := client.free_head
			client.free_head = client.server_objects[index].next_free
			id = SERVER_ID_START+index
		} else {
			if len(client.server_objects) > MAX_OBJECTS { return nil }
			id = SERVER_ID_START+u32(len(client.server_objects))
			append(&client.server_objects, Object_Entry{})
		}
	} else if id < SERVER_ID_START {
		if !client_reserve(id, client) { return nil }
	} else if id-SERVER_ID_START >= u32(len(client.server_objects)) { return nil }
	resource := new(Resource)
	resource.id, resource.interface, resource.client, resource.version = id, iface, client, version
	signal_init(&resource.destroy_signal); init(&resource.link)
	if id < SERVER_ID_START { client.objects[id].resource = resource } else { client.server_objects[id-SERVER_ID_START].resource = resource }
	return resource
}
resource_set_implementation :: proc(resource: ^Resource, implementation, data, destructor: rawptr) {
	resource.implementation, resource.data, resource.c_destructor = implementation, data, destructor
	resource.dispatcher, resource.destructor = nil, nil
}
resource_destroy :: proc(resource: ^Resource) {
	if resource == nil || resource.destroying { return }
	client := resource.client
	context = client.display.loop.ctx
	resource.destroying = true
	signal_emit_final(&resource.destroy_signal, resource)
	if resource.destructor != nil { resource.destructor(resource) }
	if resource.c_destructor != nil { c_destroy(resource) }
	id := resource.id
	if id < SERVER_ID_START {
		if client.display_resource != nil { post(client.display_resource, 1, Uint(id)) }
		client.objects[id].resource = nil
	} else {
		index := id-SERVER_ID_START
		client.server_objects[index] = Object_Entry{next_free = client.free_head}
		client.free_head = index
	}
	free(resource)
}
// Observers borrow the event for the duration of post and must not destroy its resources.
Posted_Event :: struct { resource: ^Resource, opcode: u32, args: []Argument }
post :: proc(resource: ^Resource, opcode: u32, args: ..Argument) {
	client := resource.client
	if client.failed { return }
	assert(opcode < u32(resource.interface.event_count))
	for arg in args {
		if object, ok := arg.(Object); ok && object != nil { assert(object.client == client) }
	}
	bytes: [BUFFER_SIZE]u8
	fds: [20]linux.Fd
	message := &resource.interface.events[opcode]
	size, count, encoded := encode(resource.id, opcode, message, args, bytes[:], &fds)
	if !encoded { client.failed = true; return }
	trace(resource, message, args, true)
	if connection_queue(&client.connection, bytes[:size], fds[:count]) != .NONE {
		for fd in fds[:count] { linux.close(fd) }
		client.failed = true
	} else if !empty(&client.display.posted.listener_list) {
		event := Posted_Event{resource, opcode, args}
		signal_emit_mutable(&client.display.posted, &event)
	}
}
post_error :: proc(resource: ^Resource, code: u32, message: string) {
	client := resource.client
	if client.failed || client.display_resource == nil { return }
	post(client.display_resource, 0, Object(resource), Uint(code), String{value = message[:min(len(message),127)]})
	client.failed = true
}
client_no_memory :: proc(client: ^Client) {
	if client.display_resource != nil { post_error(client.display_resource, 2, "no memory") }
}
array_init :: proc(array: ^Array) { array^ = {} }
array_release :: proc(array: ^Array) { libc.free(array.data); array.data = rawptr(uintptr(4)) }
array_add :: proc(array: ^Array, size: uint) -> rawptr {
	if size > max(uint)-array.size { return nil }
	capacity := max(array.alloc, 16)
	for capacity < array.size+size {
		if capacity > max(uint)/2 { return nil }
		capacity *= 2
	}
	if capacity > array.alloc {
		assert(array.alloc > 0 || array.data == nil)
		storage := libc.realloc(array.data, capacity)
		if storage == nil { return nil }
		array.data, array.alloc = storage, capacity
	}
	result := rawptr(uintptr(array.data)+uintptr(array.size))
	array.size += size
	return result
}
array_copy :: proc(array, source: ^Array) -> bool {
	if array.size < source.size && array_add(array, source.size-array.size) == nil { return false }
	array.size = source.size
	copy((cast([^]u8)array.data)[:array.size], (cast([^]u8)source.data)[:source.size])
	return true
}
