package wayland

import "base:runtime"
import "core:fmt"
import "core:sys/linux"

SERVER_ID_START :: u32(0xff000000)
MAX_OBJECTS :: 0x00f00000
SO_PEERCRED :: i32(linux.Socket_Option.PEERCRED)
#assert(SO_PEERCRED == 17)
Object_Entry :: struct { resource: ^Resource, next_free: u32 }
Client :: struct {
	display: ^Display,
	connection: Connection,
	source: ^Source,
	display_resource: ^Resource,
	objects, server_objects: [dynamic]Object_Entry,
	free_head: u32,
	credentials: Credentials,
	link: List,
	destroy_signal: Signal,
	failed, destroying, dispatching, destroy_pending: bool,
	writable: bool,
}
client_get_object :: proc(client: ^Client, id: u32) -> ^Resource {
	if id < SERVER_ID_START {
		if id < u32(len(client.objects)) { return client.objects[id].resource }
	} else if id-SERVER_ID_START < u32(len(client.server_objects)) { return client.server_objects[id-SERVER_ID_START].resource }
	return nil
}
client_resolve :: proc(id: u32, data: rawptr) -> ^Resource { return client_get_object(cast(^Client)data, id) }
client_reserve :: proc(id: u32, data: rawptr) -> bool {
	client := cast(^Client)data
	if id == 0 || id > MAX_OBJECTS || id > u32(len(client.objects)) { return false }
	if id == u32(len(client.objects)) { append(&client.objects, Object_Entry{}) }
	return client.objects[id].resource == nil
}
client_create :: proc(display: ^Display, fd: i32) -> ^Client {
	context = display.loop.ctx
	credentials: Credentials
	credential_size := u32(size_of(credentials))
	result := linux.syscall(linux.SYS_getsockopt, fd, SOL_SOCKET, SO_PEERCRED, &credentials, &credential_size)
	if result < 0 || credential_size != size_of(credentials) { return nil }
	client := new(Client)
	client.display, client.connection.fd, client.credentials = display, linux.Fd(fd), credentials
	client.free_head = max(u32)
	signal_init(&client.destroy_signal)
	client.source = loop_on_fd(display.loop, fd, {.Readable}, client_ready, client)
	if client.source == nil { free(client); return nil }
	append(&client.objects, Object_Entry{})
	client.display_resource = resource_create(client, core_interfaces.display, 1, 1)
	client.display_resource.dispatcher = display_request
	client.display_resource.destructor = proc(resource: ^Resource) { resource.client.display_resource = nil }
	insert(display.clients.prev, &client.link)
	return client
}
client_destroy :: proc(client: ^Client) {
	if client.destroying { return }
	if client.dispatching { client.destroy_pending = true; return }
	context = client.display.loop.ctx
	client.destroying = true
	list_remove(&client.link); init(&client.link)
	signal_emit_final(&client.destroy_signal, client)
	connection_flush(&client.connection)
	for i := 0; i < len(client.objects); i += 1 {
		if resource := client.objects[i].resource; resource != nil { resource_destroy(resource) }
	}
	for i := 0; i < len(client.server_objects); i += 1 {
		if resource := client.server_objects[i].resource; resource != nil { resource_destroy(resource) }
	}
	source_remove(client.source)
	connection_close(&client.connection)
	delete(client.objects); delete(client.server_objects)
	free(client)
}
client_flush :: proc(client: ^Client) -> bool {
	err := connection_flush(&client.connection)
	if err != .NONE && err != .EAGAIN { return false }
	writable := err == .EAGAIN
	if writable != client.writable {
		mask := Mask{.Readable}
		if writable { mask += {.Writable} }
		if !source_update_fd(client.source, mask) { return false }
		client.writable = writable
	}
	return true
}
client_ready :: proc(fd: i32, mask: Mask, data: rawptr) -> i32 {
	client := cast(^Client)data
	if .Hangup in mask || .Error in mask { client_destroy(client); return 1 }
	if .Writable in mask && !client_flush(client) { client_destroy(client); return 1 }
	if .Readable not_in mask { return 0 }
	available, err := connection_read(&client.connection)
	if err == .EAGAIN { return 0 }
	if available == 0 || err != .NONE { client_destroy(client); return 1 }
	for ring_size(&client.connection.input) >= 8 {
		header: [8]u8
		ring_copy(&client.connection.input, header[:])
		id, word := word_read(header[:], 0), word_read(header[:], 4)
		size, opcode := int(word>>16), word&0xffff
		if size < 8 || size > BUFFER_SIZE || size%4 != 0 { post_error(client.display_resource, 1, "invalid message length"); break }
		if size > ring_size(&client.connection.input) { break }
		resource := client_get_object(client, id)
		if resource == nil { post_error(client.display_resource, 0, fmt.tprintf("invalid object %d", id)); break }
		if opcode >= u32(resource.interface.method_count) { post_error(client.display_resource, 1, fmt.tprintf("invalid method %d, object %s#%d", opcode, resource.interface.name, id)); break }
		message := &resource.interface.methods[opcode]
		if resource.version > 0 && message_since(message) > resource.version { post_error(client.display_resource, 1, fmt.tprintf("invalid version for %s#%d.%s (%d, need at least %d)", resource.interface.name, id, message.name, resource.version, message_since(message))); break }
		bytes: [BUFFER_SIZE]u8
		ring_copy(&client.connection.input, bytes[:size])
		client.connection.input.tail += uint(size)
		args: [20]Argument
		count, ok := unmarshal(&client.connection, bytes[:size], message, &args, client_resolve, client_reserve, client)
		if !ok { post_error(client.display_resource, 1, fmt.tprintf("invalid arguments for %s#%d.%s", resource.interface.name, id, message.name)); break }
		trace(resource, message, args[:count], false)
		client.dispatching = true
		if resource.dispatcher != nil { resource.dispatcher(resource, opcode, args[:count]) } else { c_dispatch(resource, opcode, args[:count]) }
		client.dispatching = false
		if client.failed || client.destroy_pending { break }
	}
	if client.failed { log(fmt.tprintf("error in client communication (pid %d)\n", client.credentials.pid)) }
	if client.failed || client.destroy_pending { client_destroy(client) }
	return 1
}
display_flush_clients :: proc(display: ^Display) {
	for link := display.clients.next; link != &display.clients; {
		client := runtime.container_of(link, Client, "link")
		link = link.next
		if client.failed || !client_flush(client) { client_destroy(client) }
	}
}
display_destroy_clients :: proc(display: ^Display) {
	context = display.loop.ctx
	pending: List
	init(&pending); insert_list(cast(^List)rawptr(&pending), &display.clients); init(&display.clients)
	for !empty(&pending) { client_destroy(runtime.container_of(pending.next, Client, "link")) }
	if !empty(&display.clients) { log("display_destroy_clients: new clients were created by destroy callbacks\n") }
}
