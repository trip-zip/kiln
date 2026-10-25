package wayland

import "base:runtime"
import "core:sys/linux"
import "core:time"

Event_Loop :: Loop
Event_Source :: Source
create :: display_create
destroy :: display_destroy
destroy_clients :: display_destroy_clients
flush_clients :: display_flush_clients
run :: display_run
terminate :: proc(display: ^Display) { display.terminated = true }
event_loop :: proc(display: ^Display) -> ^Loop { return display.loop }
add_socket :: display_add_socket
add_destroy_listener :: proc(display: ^Display, listener: ^Listener) { signal_add(&display.destroy_signal, listener) }
listen_c :: proc(signal: ^Signal, listener: ^Listener, notify: Notify) { listener.notify = notify; signal_add(signal, listener) }
listen :: proc{listen_c, listen_odin}
Odin_Notify :: #type proc(^Listener, rawptr)
// Side storage preserves the listener layout shared with backend C signals.
odin_listeners: map[^Listener]Odin_Notify
listen_odin :: proc(signal: ^Signal, listener: ^Listener, notify: Odin_Notify) {
	if odin_listeners == nil { odin_listeners = make(map[^Listener]Odin_Notify, runtime.default_context().allocator) }
	odin_listeners[listener] = notify
	listener.notify = nil
	signal_add(signal, listener)
}
unlisten :: proc(listener: ^Listener) {
	if listener.link.next != nil { list_remove(&listener.link) }
	delete_key(&odin_listeners, listener)
	if len(odin_listeners) == 0 { delete(odin_listeners); odin_listeners = nil }
}
Iterator :: struct { head, next: ^List }
iterate :: proc(head: ^List) -> Iterator { return {head, head.next} }
next :: proc(it: ^Iterator) -> (link: ^List, ok: bool) {
	if it.next == it.head { return nil, false }
	link, it.next = it.next, it.next.next
	return link, true
}
owner :: proc(listener: ^Listener, $T: typeid, $field: string) -> ^T { return runtime.container_of(listener, T, field) }
Signal_Handler :: #type proc(linux.Signal, rawptr) -> i32
FD_Handler :: #type proc(i32, Mask, rawptr) -> i32
READABLE :: Mask{.Readable}
WRITABLE :: Mask{.Writable}
on_signal :: proc(display: ^Display, number: linux.Signal, callback: Signal_Handler, data: rawptr) -> ^Source { return loop_on_signal(display.loop, number, callback, data) }
on_fd :: proc(display: ^Display, fd: i32, mask: Mask, callback: FD_Handler, data: rawptr) -> ^Source { return loop_on_fd(display.loop, fd, mask, callback, data) }
on_idle :: proc(display: ^Display, callback: proc(rawptr), data: rawptr) -> ^Source { return loop_on_idle(display.loop, callback, data) }
on_timer :: proc(display: ^Display, callback: proc(rawptr) -> i32, data: rawptr) -> ^Source { return loop_on_timer(display.loop, callback, data) }
remove_source :: source_remove
update_fd :: source_update_fd
arm_timer :: proc(source: ^Source, delay: time.Duration) -> bool { return source_arm_timer(source, delay) }
dispatch :: proc(display: ^Display, timeout: i32) -> bool { return loop_dispatch(display.loop, timeout) }
client_pid :: proc(resource: ^Resource) -> i32 { return resource.client.credentials.pid }
resource_version :: proc(resource: ^Resource) -> int { return int(resource.version) }
