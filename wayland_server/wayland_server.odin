package wayland_server

import "core:c"

foreign import lib "system:wayland-server"

wl_display :: struct {}
wl_event_loop :: struct {}
wl_event_source :: struct {}
wl_resource :: struct {}
wl_client :: struct {}
wl_list :: struct { prev, next: ^wl_list }
wl_listener :: struct { link: wl_list, notify: wl_notify_func_t }
wl_signal :: struct { listener_list: wl_list }
wl_notify_func_t :: #type proc "c" (listener: ^wl_listener, data: rawptr)

#assert(size_of(wl_list) == 16)
#assert(offset_of(wl_list, prev) == 0)
#assert(offset_of(wl_list, next) == 8)
#assert(size_of(wl_listener) == 24)
#assert(offset_of(wl_listener, link) == 0)
#assert(offset_of(wl_listener, notify) == 16)
#assert(size_of(wl_signal) == 16)
#assert(offset_of(wl_signal, listener_list) == 0)

WL_EVENT_READABLE :: 1
WL_EVENT_WRITABLE :: 2
WL_EVENT_HANGUP :: 4
WL_EVENT_ERROR :: 8

foreign lib {
	wl_event_loop_dispatch :: proc(loop: ^wl_event_loop, timeout: c.int) -> c.int ---
	wl_event_loop_add_timer :: proc(loop: ^wl_event_loop, callback: proc "c" (rawptr) -> c.int, data: rawptr) -> ^wl_event_source ---
	wl_event_source_timer_update :: proc(source: ^wl_event_source, ms: c.int) -> c.int ---
	wl_display_flush_clients :: proc(display: ^wl_display) ---
	wl_resource_get_version :: proc(resource: ^wl_resource) -> c.int ---
	wl_resource_get_client :: proc(resource: ^wl_resource) -> ^wl_client ---
	wl_client_get_credentials :: proc(client: ^wl_client, pid: ^i32, uid, gid: ^u32) ---
	wl_event_loop_add_fd :: proc(loop: ^wl_event_loop, fd: c.int, mask: u32, callback: proc "c" (c.int, u32, rawptr) -> c.int, data: rawptr) -> ^wl_event_source ---
	wl_event_source_fd_update :: proc(source: ^wl_event_source, mask: u32) -> c.int ---
	wl_event_loop_add_idle :: proc(loop: ^wl_event_loop, callback: proc "c" (rawptr), data: rawptr) -> ^wl_event_source ---
	wl_display_create :: proc() -> ^wl_display ---
	wl_display_destroy :: proc(display: ^wl_display) ---
	wl_display_destroy_clients :: proc(display: ^wl_display) ---
	wl_display_get_event_loop :: proc(display: ^wl_display) -> ^wl_event_loop ---
	wl_display_add_socket :: proc(display: ^wl_display, name: cstring) -> c.int ---
	wl_display_run :: proc(display: ^wl_display) ---
	wl_display_terminate :: proc(display: ^wl_display) ---
	wl_signal_emit_mutable :: proc(signal: ^wl_signal, data: rawptr) ---
	wl_display_add_destroy_listener :: proc(display: ^wl_display, listener: ^wl_listener) ---
	wl_event_loop_add_signal :: proc(loop: ^wl_event_loop, signal_number: c.int, callback: proc "c" (c.int, rawptr) -> c.int, data: rawptr) -> ^wl_event_source ---
	wl_event_source_remove :: proc(source: ^wl_event_source) -> c.int ---
}

wl_list_init :: proc(list: ^wl_list) { list.prev, list.next = list, list }
wl_list_insert :: proc(list, elm: ^wl_list) {
	elm.prev = list
	elm.next = list.next
	list.next.prev = elm
	list.next = elm
}
wl_list_remove :: proc(elm: ^wl_list) {
	elm.prev.next = elm.next
	elm.next.prev = elm.prev
	elm.prev, elm.next = nil, nil
}
wl_list_empty :: proc(list: ^wl_list) -> bool { return list.next == list }

wl_signal_init :: proc(signal: ^wl_signal) { wl_list_init(&signal.listener_list) }
wl_signal_add :: proc(signal: ^wl_signal, listener: ^wl_listener) {
	wl_list_insert(signal.listener_list.prev, &listener.link)
}
wl_signal_emit :: proc(signal: ^wl_signal, data: rawptr) {
	for link := signal.listener_list.next; link != &signal.listener_list; {
		next := link.next
		listener := (^wl_listener)(link)
		listener.notify(listener, data)
		link = next
	}
}
