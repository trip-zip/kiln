package wayland

import "core:testing"

@(test)
odin_signal_callbacks_can_remove_peers_and_free_the_owner :: proc(t: ^testing.T) {
	Owner :: struct { signal: Signal, destroy: Listener }
	Probe :: struct { listener, peer: Listener, calls: int }
	o := new(Owner)
	signal_init(&o.signal)
	probe: Probe
	listen(&o.signal,&probe.listener,proc(l: ^Listener,data: rawptr) {
		p := owner(l,Probe,"listener")
		p.calls += 1
		unlisten(&p.peer)
	})
	listen(&o.signal,&probe.peer,proc(l: ^Listener,data: rawptr) { panic("removed callback ran") })
	signal_emit_mutable(&o.signal,nil)
	testing.expect_value(t,probe.calls,1)
	listen(&o.signal,&o.destroy,proc(l: ^Listener,data: rawptr) { free(owner(l,Owner,"destroy")) })
	signal_emit_final(&o.signal,nil)
	unlisten(&probe.listener)
	testing.expect_value(t,probe.calls,2)
}
