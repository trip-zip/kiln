package wayland

import "base:runtime"
import raw "../wayland_server"
import "core:strings"

Display :: raw.wl_display
Event_Loop :: raw.wl_event_loop
Event_Source :: raw.wl_event_source
List :: raw.wl_list
Listener :: raw.wl_listener
Signal :: raw.wl_signal
Notify :: raw.wl_notify_func_t

create :: raw.wl_display_create
destroy :: raw.wl_display_destroy
destroy_clients :: raw.wl_display_destroy_clients
event_loop :: raw.wl_display_get_event_loop
flush_clients :: raw.wl_display_flush_clients
run :: raw.wl_display_run
terminate :: raw.wl_display_terminate
init :: raw.wl_list_init
insert :: raw.wl_list_insert
empty :: raw.wl_list_empty
listen :: proc(signal: ^Signal, listener: ^Listener, notify: Notify) {
	listener.notify = notify
	raw.wl_signal_add(signal, listener)
}
unlisten :: proc(listener: ^Listener) {
	if listener.link.next != nil { raw.wl_list_remove(&listener.link) }
}
add_socket :: proc(display: ^Display, name: string) -> bool {
	cname := strings.clone_to_cstring(name)
	defer delete(cname)
	return raw.wl_display_add_socket(display, cname) == 0
}

// Cache the successor so a callback may remove its own link.
Iterator :: struct { head, next: ^List }
iterate :: proc(head: ^List) -> Iterator { return {head, head.next} }
next :: proc(it: ^Iterator) -> (link: ^List, ok: bool) {
	if it.next == it.head { return nil, false }
	link, it.next = it.next, it.next.next
	return link, true
}
owner :: proc(listener: ^Listener, $T: typeid, $field: string) -> ^T {
	return runtime.container_of(listener, T, field)
}

Signal_Handler :: #type proc "c" (signal_number: i32, data: rawptr) -> i32
on_signal :: proc(display: ^Display, number: i32, callback: Signal_Handler, data: rawptr) -> ^Event_Source {
	return raw.wl_event_loop_add_signal(event_loop(display), number, callback, data)
}
remove_source :: proc(source: ^Event_Source) {
	if source != nil { raw.wl_event_source_remove(source) }
}

FD_Handler :: #type proc "c" (fd: i32, mask: u32, data: rawptr) -> i32
READABLE :: raw.WL_EVENT_READABLE
WRITABLE :: raw.WL_EVENT_WRITABLE
on_fd :: proc(display: ^Display, fd: i32, mask: u32, callback: FD_Handler, data: rawptr) -> ^Event_Source {
	return raw.wl_event_loop_add_fd(event_loop(display), fd, mask, callback, data)
}
update_fd :: proc(source: ^Event_Source, mask: u32) -> bool {
	return raw.wl_event_source_fd_update(source, mask) == 0
}
on_idle :: proc(display: ^Display, callback: proc "c" (rawptr), data: rawptr) -> ^Event_Source {
	return raw.wl_event_loop_add_idle(event_loop(display), callback, data)
}

client_pid :: proc(resource: ^raw.wl_resource) -> i32 {
	pid: i32
	raw.wl_client_get_credentials(raw.wl_resource_get_client(resource), &pid, nil, nil)
	return pid
}

resource_version :: proc(resource: ^raw.wl_resource) -> int {
	return int(raw.wl_resource_get_version(resource))
}

on_timer :: proc(display: ^Display, callback: proc "c" (rawptr) -> i32, data: rawptr) -> ^Event_Source {
	return raw.wl_event_loop_add_timer(event_loop(display), callback, data)
}
arm_timer :: proc(source: ^Event_Source, ms: i32) -> bool {
	return raw.wl_event_source_timer_update(source, ms) == 0
}
dispatch :: proc(display: ^Display, timeout: i32) -> bool {
	return raw.wl_event_loop_dispatch(event_loop(display), timeout) == 0
}
