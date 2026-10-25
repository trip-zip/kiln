package buffers

import wl "../wayland"
import "core:testing"
import "core:sys/posix"

Lifetime_Probe :: struct { base: Buffer, release: wl.Listener, destroyed: bool, releases: int }
probe_destroy :: proc(b: ^Buffer) { (cast(^Lifetime_Probe)b).destroyed = true }
probe_release :: proc(l: ^wl.Listener, data: rawptr) {
	probe := wl.owner(l,Lifetime_Probe,"release")
	probe.releases += 1; wl.unlisten(l); drop(&probe.base)
}
probe_access :: proc(b: ^Buffer, access: Access) -> (rawptr,u32,int,bool) { return b,ARGB8888,4,true }
probe_end :: proc(b: ^Buffer) {}
@(test)
release_listener_can_drop_while_access_defers_destruction :: proc(t: ^testing.T) {
	probe: Lifetime_Probe
	init(&probe.base,1,1); probe.base.destroy = probe_destroy
	probe.base.access_begin, probe.base.access_end = probe_access, probe_end
	wl.listen(&probe.base.events.release,&probe.release,probe_release)
	lock(&probe.base); lock(&probe.base)
	_,_,_,ok := access_begin(&probe.base,.Read); testing.expect(t,ok)
	unlock(&probe.base); testing.expect(t,probe.releases == 0)
	unlock(&probe.base); testing.expect(t,probe.releases == 1 && !probe.destroyed)
	access_end(&probe.base); testing.expect(t,probe.destroyed)
}
chained_signals: int
chain_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, ctx: rawptr) { chained_signals += 1 }
@(test)
shm_guard_chains_unrelated_sigbus :: proc(t: ^testing.T) {
	// A real signal checks chaining without relying on a deliberately invalid memory access.
	if !bus_installed {
		action := posix.sigaction_t{sa_sigaction = handle_bus,sa_flags = {.SIGINFO,.SA_NODEFER}}
		assert(posix.sigaction(.SIGBUS,&action,&previous_bus) == .OK); bus_installed = true
	}
	old := previous_bus; defer previous_bus = old
	previous_bus = {sa_sigaction = chain_handler,sa_flags = {.SIGINFO}}
	before := chained_signals
	posix.raise(.SIGBUS)
	testing.expect_value(t,chained_signals,before+1)
}
