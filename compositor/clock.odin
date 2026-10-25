package compositor

import out "../outputs"
import "core:sys/posix"
import vm "../lua_runtime"

monotonic :: proc() -> f64 {
	now: posix.timespec
	posix.clock_gettime(.MONOTONIC,&now)
	return f64(now.tv_sec)+f64(now.tv_nsec)/1e9
}
runtime_tick :: proc(data: rawptr, name: string, on: bool) {
	s:=(^Server)(data)
	for o in s.outputs {
		if string(o.handle.name)!=name || o.tick_on==on { continue }
		s.next_clock+=1
		o.tick_generation=s.next_clock
		o.tick_on=on
		if on {
			o.tick_last=monotonic()
			if o.handle.enabled && !s.shutting_down { out.schedule_frame(o.handle) }
		}
	}
}
queue_tick :: proc(o: ^Output, now: f64) {
	if !o.tick_on || !o.handle.enabled { return }
	dt:=now-o.tick_last
	o.tick_last=now
	queue_event(o.server,vm.Event{class="frame",name="tick",output=string(o.handle.name),dt=dt,generation=o.tick_generation})
}
valid_tick :: proc(s: ^Server, e: ^vm.Event) -> bool {
	for o in s.outputs {
		if string(o.handle.name)==e.output {
			return o.tick_on && o.handle.enabled && o.tick_generation==e.generation
		}
	}
	return false
}

runtime_reset_clocks :: proc(data: rawptr) {
	s := (^Server)(data)
	for o in s.outputs { runtime_tick(s, string(o.handle.name), false) }
}
