package wayland

import "base:runtime"
import "core:testing"

Observer :: struct { prefix: u64, listener: Listener, calls: int, received: rawptr }
observe :: proc "c" (listener: ^Listener, data: rawptr) {
	context = runtime.default_context()
	o := owner(listener, Observer, "listener")
	o.calls += 1
	o.received = data
}

@(test)
c_emits_to_odin_listener :: proc(t: ^testing.T) {
	signal: Signal
	signal_init(&signal)
	o: Observer
	listen(&signal, &o.listener, observe)
	value := 42
	signal_emit_mutable(&signal, &value)
	testing.expect_value(t, o.calls, 1)
	testing.expect(t, o.received == rawptr(&value))
	unlisten(&o.listener)
	signal_emit_mutable(&signal, nil)
	testing.expect_value(t, o.calls, 1)
	testing.expect(t, empty(&signal.listener_list))
}

@(test)
c_display_destruction_calls_embedded_listener :: proc(t: ^testing.T) {
	d := create()
	testing.expect(t, d != nil)
	o: Observer
	o.listener.notify = observe
	add_destroy_listener(d, &o.listener)
	destroy(d)
	testing.expect_value(t, o.calls, 1)
	testing.expect(t, o.received == rawptr(d))
}

@(test)
list_order_survives_insert_remove :: proc(t: ^testing.T) {
	head: List
	nodes: [3]List
	init(&head)
	testing.expect(t, empty(&head))
	insert(&head, &nodes[0])
	insert(&nodes[0], &nodes[1])
	insert(&head, &nodes[2])
	expected := [?]^List{&nodes[2], &nodes[0], &nodes[1]}
	it := iterate(&head)
	for want in expected {
		got, ok := next(&it)
		testing.expect(t, ok && got == want)
		testing.expect(t, got.next.prev == got && got.prev.next == got)
	}
	_, ok := next(&it)
	testing.expect(t, !ok)
	list_remove(&nodes[0])
	testing.expect(t, nodes[2].next == &nodes[1] && nodes[1].prev == &nodes[2])
	it = iterate(&head)
	for link in next(&it) { list_remove(link) }
	testing.expect(t, empty(&head) && head.prev == &head)
}

@(test)
odin_emit_allows_self_removal :: proc(t: ^testing.T) {
	signal: Signal
	signal_init(&signal)
	observers: [2]Observer
	for &o in observers { listen(&signal, &o.listener, proc "c" (l: ^Listener, data: rawptr) {
		context = runtime.default_context()
		observe(l, data)
		unlisten(l)
	}) }
	signal_emit_mutable(&signal, nil)
	for o in observers { testing.expect_value(t, o.calls, 1) }
	testing.expect(t, empty(&signal.listener_list))
}
