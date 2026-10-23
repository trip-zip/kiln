package compositor

import "core:time"
import "base:runtime"
import vm "../lua_runtime"
import wl "../wayland"

Timer :: struct {
	server: ^Server,
	allocator: runtime.Allocator,
	id: u64,
	source: ^wl.Event_Source,
}
runtime_timer_add :: proc(data: rawptr, id: u64, ms: i32) -> bool {
	s:=(^Server)(data)
	if s.shutting_down { return false }
	t:=new(Timer)
	t^={server=s,allocator=context.allocator,id=id}
	t.source=wl.on_timer(s.display,timer_ready,t)
	if t.source==nil || !wl.arm_timer(t.source, time.Duration(ms)*time.Millisecond) {
		wl.remove_source(t.source);free(t);return false
	}
	if s.timers==nil { s.timers=make(map[u64]^Timer) }
	s.timers[id]=t
	return true
}
runtime_timer_remove :: proc(data: rawptr, id: u64) {
	s:=(^Server)(data)
	t,ok:=s.timers[id]
	if !ok { return }
	delete_key(&s.timers,id)
	wl.remove_source(t.source)
	free(t,t.allocator)
}
timer_ready :: proc(data: rawptr) -> i32 {
	t:=(^Timer)(data)
	context.allocator=t.allocator
	s,id:=t.server,t.id
	// Only the ID enters the queue. Cancellation can still retire the Lua ref.
	runtime_timer_remove(s,id)
	queue_event(s,vm.Event{class="timer",id=id})
	return 0
}
