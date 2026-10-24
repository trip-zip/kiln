package wayland

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

Core_Interfaces :: struct { display, registry, callback: ^Interface }
core_interfaces: Core_Interfaces
Display :: struct {
	loop: ^Loop,
	clients, globals, registries, sockets: List,
	destroy_signal, posted: Signal,
	next_global, serial: u32,
	terminated, debug: bool,
}
Global :: struct {
	display: ^Display,
	interface: ^Interface,
	version, name: u32,
	data, c_bind: rawptr,
	bind: proc(^Global, ^Client, u32, u32),
	resource_destructor, resource_initialize: proc(^Resource),
	link, offers: List,
	unpublished: bool,
}
Registry :: struct { resource: ^Resource, offers: List }
Offer :: struct { global: ^Global, registry: ^Registry, global_link, registry_link: List }
Socket :: struct { display: ^Display, fd, lock_fd: linux.Fd, path, lock_path: cstring, source: ^Source, link: List }
display_create :: proc() -> ^Display {
	loop := loop_create()
	if loop == nil { return nil }
	display := new(Display)
	display.loop, display.next_global = loop, 1
	init(&display.clients); init(&display.globals); init(&display.registries); init(&display.sockets)
	signal_init(&display.destroy_signal)
	signal_init(&display.posted)
	debug := os.get_env("WAYLAND_DEBUG", context.temp_allocator)
	display.debug = debug == "1" || debug == "server"
	return display
}
display_destroy :: proc(display: ^Display) {
	context = display.loop.ctx
	signal_emit_final(&display.destroy_signal, display)
	for !empty(&display.sockets) {
		socket := runtime.container_of(display.sockets.next, Socket, "link")
		source_remove(socket.source); linux.close(socket.fd)
		linux.unlink(socket.path); linux.unlink(socket.lock_path); linux.close(socket.lock_fd)
		delete(socket.path); delete(socket.lock_path); list_remove(&socket.link); free(socket)
	}
	// Loop destroy listeners may still own globals.
	loop_destroy(display.loop)
	for !empty(&display.globals) {
		global := runtime.container_of(display.globals.next, Global, "link")
		list_remove(&global.link); free(global)
	}
	free(display)
}
display_run :: proc(display: ^Display) {
	display.terminated = false
	for !display.terminated { display_flush_clients(display); if !loop_dispatch(display.loop, -1) { break } }
}
display_request :: proc(resource: ^Resource, opcode: u32, args: []Argument) {
	client := resource.client
	switch opcode {
	case 0:
		callback := resource_create(client, core_interfaces.callback, 1, u32(args[0].(New_Id)))
		if callback == nil { client_no_memory(client); return }
		post(callback, 0, Uint(client.display.serial)); resource_destroy(callback)
	case 1:
		registry_resource := resource_create(client, core_interfaces.registry, 1, u32(args[0].(New_Id)))
		if registry_resource == nil { client_no_memory(client); return }
		registry := new(Registry)
		registry.resource = registry_resource; init(&registry.offers)
		registry_resource.data, registry_resource.dispatcher, registry_resource.destructor = registry, registry_request, registry_destroy
		insert(&client.display.registries, &registry_resource.link)
		for link := client.display.globals.next; link != &client.display.globals; link = link.next {
			global := runtime.container_of(link, Global, "link")
			if !global.unpublished { global_offer(global, registry) }
		}
	}
}
registry_request :: proc(resource: ^Resource, opcode: u32, args: []Argument) {
	display := resource.client.display
	name, iface, version, id := u32(args[0].(Uint)), args[1].(String).value, u32(args[2].(Uint)), u32(args[3].(New_Id))
	for link := display.globals.next; link != &display.globals; link = link.next {
		global := runtime.container_of(link, Global, "link")
		if global.name != name { continue }
		if string(global.interface.name) != iface { post_error(resource, 0, fmt.tprintf("invalid interface for global %d: expected %s, got %s", name, global.interface.name, iface)); return }
		if version == 0 { post_error(resource, 0, fmt.tprintf("invalid version for global %s (%d): 0 is not a valid version", iface, name)); return }
		if version > global.version { post_error(resource, 0, fmt.tprintf("invalid version for global %s (%d): expected at most %d, got %d", iface, name, global.version, version)); return }
		global.bind(global, resource.client, version, id)
		return
	}
	post_error(resource, 0, fmt.tprintf("global %s (%d) is unavailable", iface, name))
}
offer_destroy :: proc(offer: ^Offer) { list_remove(&offer.global_link); list_remove(&offer.registry_link); free(offer) }
registry_destroy :: proc(resource: ^Resource) {
	registry := cast(^Registry)resource.data
	for !empty(&registry.offers) { offer_destroy(runtime.container_of(registry.offers.next, Offer, "registry_link")) }
	list_remove(&resource.link); free(registry)
}
global_offer :: proc(global: ^Global, registry: ^Registry) {
	offer := new(Offer)
	offer.global, offer.registry = global, registry
	insert(&global.offers, &offer.global_link); insert(&registry.offers, &offer.registry_link)
	post(registry.resource, 0, Uint(global.name), String{value = string(global.interface.name)}, Uint(global.version))
}
global_create :: proc(display: ^Display, iface: ^Interface, version: i32, data: rawptr, bind: proc(^Global, ^Client, u32, u32)) -> ^Global {
	context = display.loop.ctx
	if version < 1 || version > iface.version || display.next_global == max(u32) { return nil }
	global := new(Global)
	global.display, global.interface, global.version, global.data, global.bind = display, iface, u32(version), data, bind
	global.name = display.next_global; display.next_global += 1
	init(&global.offers); insert(display.globals.prev, &global.link)
	for link := display.registries.next; link != &display.registries; link = link.next {
		resource := runtime.container_of(link, Resource, "link")
		global_offer(global, cast(^Registry)resource.data)
	}
	return global
}
global_remove :: proc(global: ^Global) {
	context = global.display.loop.ctx
	assert(!global.unpublished)
	global.unpublished = true
	for link := global.offers.next; link != &global.offers; link = link.next {
		offer := runtime.container_of(link, Offer, "global_link")
		post(offer.registry.resource, 1, Uint(global.name))
	}
}
global_destroy :: proc(global: ^Global) {
	context = global.display.loop.ctx
	if !global.unpublished { global_remove(global) }
	for !empty(&global.offers) { offer_destroy(runtime.container_of(global.offers.next, Offer, "global_link")) }
	list_remove(&global.link); free(global)
}
socket_ready :: proc(fd: i32, mask: Mask, data: rawptr) -> i32 {
	socket := cast(^Socket)data
	address: linux.Sock_Addr_Un
	peer, err := linux.accept(linux.Fd(fd), &address, {.CLOEXEC})
	if err == .NONE && client_create(socket.display, i32(peer)) == nil { linux.close(peer) }
	return 1
}
display_add_socket :: proc(display: ^Display, name: string) -> bool {
	context = display.loop.ctx
	path := name
	if !strings.has_prefix(name, "/") {
		dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
		if !strings.has_prefix(dir, "/") { return false }
		path = fmt.tprintf("%s/%s", dir, name)
	}
	if len(path) >= 108 { return false }
	cpath := strings.clone_to_cstring(path)
	lock_path := strings.clone_to_cstring(fmt.tprintf("%s.lock", path))
	lock_fd, lock_error := linux.open(lock_path, {.CREAT, .CLOEXEC, .RDWR}, transmute(linux.Mode)u32(0o660))
	if lock_error != .NONE { delete(cpath); delete(lock_path); return false }
	if linux.flock(lock_fd, {.EX, .NB}) != .NONE { linux.close(lock_fd); delete(cpath); delete(lock_path); return false }
	ok := false
	defer if !ok { linux.unlink(cpath); linux.unlink(lock_path); linux.close(lock_fd); delete(cpath); delete(lock_path) }
	linux.unlink(cpath)
	fd, err := linux.socket(linux.Address_Family(linux.Protocol_Family.UNIX), .STREAM, {.CLOEXEC, .NONBLOCK}, {})
	if err != .NONE { return false }
	defer if !ok { linux.close(fd) }
	address := linux.Sock_Addr_Un{sun_family = linux.Address_Family(linux.Protocol_Family.UNIX)}
	copy(address.sun_path[:], path)
	if linux.bind(fd, &address) != .NONE || linux.listen(fd, 128) != .NONE { return false }
	socket := new(Socket)
	socket.display, socket.fd, socket.lock_fd, socket.path, socket.lock_path = display, fd, lock_fd, cpath, lock_path
	socket.source = loop_on_fd(display.loop, i32(fd), {.Readable}, socket_ready, socket)
	if socket.source == nil { free(socket); return false }
	insert(display.sockets.prev, &socket.link)
	ok = true
	return true
}
