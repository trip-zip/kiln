package wayland

import "base:runtime"

List :: struct { prev, next: ^List }
Listener :: struct { link: List, notify: Notify }
Signal :: struct { listener_list: List }
Notify :: #type proc "c" (^Listener, rawptr)
#assert(size_of(List) == 16 && offset_of(List, prev) == 0 && offset_of(List, next) == 8)
#assert(size_of(Listener) == 24 && offset_of(Listener, link) == 0 && offset_of(Listener, notify) == 16)
#assert(size_of(Signal) == 16 && offset_of(Signal, listener_list) == 0)
init :: proc(list: ^List) { list.prev, list.next = list, list }
insert :: proc(list, link: ^List) {
 link.prev, link.next = list, list.next
 list.next.prev, list.next = link, link
}
empty :: proc(list: ^List) -> bool { return list.next == list }
list_remove :: proc(link: ^List) {
	link.prev.next, link.next.prev = link.next, link.prev
	link.prev, link.next = nil, nil
}
insert_list :: proc(list, other: ^List) {
	if empty(other) { return }
	other.next.prev, other.prev.next = list, list.next
	list.next.prev, list.next = other.prev, other.next
}
list_length :: proc(list: ^List) -> (count: i32) {
	for link := list.next; link != list; link = link.next { count += 1 }
	return
}
signal_init :: proc(signal: ^Signal) { init(&signal.listener_list) }
signal_add :: proc(signal: ^Signal, listener: ^Listener) { insert(signal.listener_list.prev, &listener.link) }
signal_get :: proc(signal: ^Signal, notify: Notify) -> ^Listener {
	for link := signal.listener_list.next; link != &signal.listener_list; link = link.next {
		listener := runtime.container_of(link, Listener, "link")
		if listener.notify == notify { return listener }
	}
	return nil
}
signal_noop :: proc "c" (listener: ^Listener, data: rawptr) {}
signal_emit_mutable :: proc(signal: ^Signal, data: rawptr) {
	// The casts acknowledge stack links to the escape checker; both cursors are unlinked before return.
	cursor, end: Listener
	cursor.notify, end.notify = signal_noop, signal_noop
	insert(&signal.listener_list, cast(^List)rawptr(&cursor.link))
	insert(signal.listener_list.prev, cast(^List)rawptr(&end.link))
	for cursor.link.next != &end.link {
		link := cursor.link.next
		listener := runtime.container_of(link, Listener, "link")
		list_remove(&cursor.link)
		insert(link, cast(^List)rawptr(&cursor.link))
		listener.notify(listener, data)
	}
	list_remove(&cursor.link)
	list_remove(&end.link)
}
signal_emit_final :: proc(signal: ^Signal, data: rawptr) {
	// Destruction listeners may free their own storage without unlinking it.
	for !empty(&signal.listener_list) {
		link := signal.listener_list.next
		listener := runtime.container_of(link, Listener, "link")
		list_remove(link)
		init(link)
		listener.notify(listener, data)
	}
}
