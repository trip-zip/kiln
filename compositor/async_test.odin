package compositor

import out "../outputs"
import sp "../scene_paint"
import vm "../lua_runtime"
import wl "../wayland"
import "core:testing"
import "core:time"

async_server :: proc(s: ^Server, t: ^testing.T) {
	s.display = wl.create()
	testing.expect(t, s.display != nil)
	s.lua.data = s
	s.lua.timer_add, s.lua.timer_remove = runtime_timer_add, runtime_timer_remove
	s.lua.spawn_pipe = runtime_spawn_pipe
	testing.expect(t, vm.init(&s.lua))
}
expect_eval :: proc(t: ^testing.T, s: ^Server, code, expected: string) {
	reply := vm.evaluate(&s.lua, code)
	defer delete(reply)
	testing.expect_value(t, reply, expected)
}
@(test)
timers_ready_cancellation_reentrancy_and_gc :: proc(t: ^testing.T) {
	s: Server
	async_server(&s, t)
	defer destroy(&s)
	expect_eval(
		t,
		&s,
		`n=0
for _,v in ipairs{false,{},'1',0/0,1/0,2147483648,-2147483649} do
 assert(not pcall(core.timer,v,function() end))
end
assert(not pcall(core.timer,1,false))
local doomed=core.timer(10,function() error('cancelled') end)
core.timer_cancel(doomed)
first=core.timer(0,function()
 n=n+1
core.timer_cancel(first)
core.timer_cancel(second)
 core.timer(-2,function() n=n+10 end)
 error('expected timer failure')
end)
second=core.timer(0,function() n=n+100 end)
assert(n==0)
collectgarbage('collect')
return n`,
		"0\n",
	)
	// Both native sources become ready before their shared idle batch runs.
	time.sleep(5 * time.Millisecond)
	testing.expect(t, wl.dispatch(s.display, 0))
	expect_eval(t, &s, "return n", "1\n")
	time.sleep(5 * time.Millisecond)
	testing.expect(t, wl.dispatch(s.display, 0))
	expect_eval(
		t,
		&s,
		"core.timer_cancel(first);core.timer_cancel(second);core.timer_cancel(9999);return n",
		"11\n",
	)
	testing.expect_value(t, len(s.timers), 0)
	testing.expect_value(t, len(s.lua.timer_refs), 0)
	// A stale queued ID cannot invoke a newly reused Lua registry slot.
	expect_eval(t, &s, "old=core.timer(1,function() n=1000 end);return old", "5\n")
	timer_ready(s.timers[5])
	expect_eval(
		t,
		&s,
		"core.timer_cancel(old);fresh=core.timer(10000,function() n=2000 end);collectgarbage();return fresh",
		"6\n",
	)
	testing.expect(t, wl.dispatch(s.display, 0))
	expect_eval(t, &s, "return n", "11\n")
	// Shutdown owns both a registered source and a queued, undelivered callback.
	expect_eval(t, &s, "core.timer(10000,function() end)", "7\n")
	timer_ready(s.timers[7])
}

@(test)
frame_clock_elapsed_generation_disabled_and_removal :: proc(t: ^testing.T) {
	s := Server {
		display = wl.create(),
	}
	defer destroy(&s)
	handle := out.Output {
		name    = "A",
		enabled = true,
	}
	o := Output {
		server          = &s,
		handle          = &handle,
		tick_on         = true,
		tick_generation = 1,
		tick_last       = 10,
	}
	append(&s.outputs, &o)
	queue_tick(&o, 10.8)
	testing.expect_value(t, len(s.events), 1)
	testing.expect(t, s.events[0].dt > 0.79 && valid_tick(&s, &s.events[0]))
	handle.enabled = false
	for _ in 0 ..< 20 {output_frame(&o.frame, nil)}
	testing.expect_value(t, o.frames, u64(0))
	queue_tick(&o, 11)
	testing.expect_value(t, len(s.events), 1)
	testing.expect(t, !valid_tick(&s, &s.events[0]))
	handle.enabled = true
	o.tick_generation = 2
	testing.expect(t, !valid_tick(&s, &s.events[0]))
	o.tick_generation = 1
	o.tick_on = false
	testing.expect(t, !valid_tick(&s, &s.events[0]))
	clear(&s.outputs)
	testing.expect(t, !valid_tick(&s, &s.events[0]))
}

@(test)
pipe_allocations_owned_bytes_and_registration_failure :: proc(t: ^testing.T) {
	s: Server
	async_server(&s, t)
	defer destroy(&s)
	expect_eval(
		t,
		&s,
		`bytes='';exits=0
core.set_event_handler(function(e)
 if e.name=='out' then bytes=bytes..e.data;collectgarbage()
 elseif e.name=='exit' then exits=exits+1
assert(e.code==0) end
end)`,
		"\n",
	)
	argv := []cstring{"sh", "-c", "printf 'owned\\000bytes'", nil}
	for _ in 0 ..< 8 {
		testing.expect(t, runtime_spawn_pipe(&s, argv) > 0)
	}
	deadline := time.tick_now()
	for len(s.pipes) > 0 || s.event_source != nil {
		testing.expect(t, wl.dispatch(s.display, 10))
		if time.tick_since(deadline) > 2 * time.Second {testing.expect(t, false, "pipe progress")
			break}
	}
	expect_eval(t, &s, "return #bytes,exits", "88\t8\n")
	s.shutting_down = true
	expect_eval(
		t,
		&s,
		"return pcall(core.timer,1,function() end)",
		"false\ttimer registration failed\n",
	)
	testing.expect_value(t, len(s.lua.timer_refs), 0)
	testing.expect_value(t, len(s.timers), 0)
}

@(test)
unrelated_async_work_does_not_block_layout :: proc(t: ^testing.T) {
	s := Server {
		display = wl.create(),
	}
	defer destroy(&s)
	handle := out.Output {
		name = "A",
	}
	o := Output {
		server = &s,
		handle = &handle,
	}
	append(&s.outputs, &o)
	runtime_tick(&s, "missing", true)
	runtime_tick(&s, "A", true)
	generation := o.tick_generation
	runtime_tick(&s, "A", true)
	testing.expect_value(t, o.tick_generation, generation)
	queue_event(&s, vm.Event{class = "timer", id = 1})
	queue_event(&s, vm.Event{class = "spawn", name = "out", bytes = "busy"})
	queue_event(&s, vm.Event{class = "frame", name = "tick", output = "B"})
	testing.expect(t, !pending_layout_facts(&o))
	queue_event(&s, vm.Event{class = "input", name = "key"})
	testing.expect(t, pending_layout_facts(&o))
	runtime_tick(&s, "A", false)
	testing.expect(t, !o.tick_on && o.tick_generation != generation)
	clear(&s.outputs)
}

@(test)
focus_transfer_waits_for_dirty_destination_but_omission_clears :: proc(t: ^testing.T) {
	s := Server {
		display         = wl.create(),
		requested_focus = 7,
	}
	defer destroy(&s)
	h1, h2 := out.Output {
			enabled = true,
		}, out.Output {
			enabled = true,
		}
	a, b := Output {
			handle = &h1,
		}, Output {
			handle = &h2,
			dirty  = true,
		}
	append(&s.outputs, &a, &b)

	view := View {
		id     = 7,
		output = &a,
		mapped = true,
	}
	append(&s.views, &view)
	settle_focus_request(&s, &a)
	testing.expect_value(t, s.requested_focus, u32(7))
	view.output = &b
	append(&b.paint.parts, sp.Part{kind = .Client, id = 7})
	b.dirty = false
	defer sp.output_finish(&b.paint)
	settle_focus_request(&s, &b)
	testing.expect_value(t, s.requested_focus, u32(7))
	clear(&b.paint.parts)
	settle_focus_request(&s, &b)
	testing.expect_value(t, s.requested_focus, u32(0))
	testing.expect_value(t, len(s.events), 1)
	clear(&s.outputs)
	clear(&s.views)
}

@(test)
timer_wakes_poll_without_input_and_cancel_releases_closure :: proc(t: ^testing.T) {
	s: Server
	async_server(&s, t)
	defer destroy(&s)
	expect_eval(
		t,
		&s,
		`weak=setmetatable({},{__mode='v'})
do local value={}
weak[1]=value
 local id=core.timer(10000,function() return value end)
core.timer_cancel(id)
end
collectgarbage()
assert(weak[1]==nil)
core.timer(20,function() awake=true end)
return awake`,
		"nil\n",
	)
	start := time.tick_now()
	testing.expect(t, wl.dispatch(s.display, 500))
	testing.expect(t, time.tick_since(start) < 250 * time.Millisecond)
	expect_eval(t, &s, "return awake", "true\n")
}

@(test)
reload_boundary_retires_ready_timers_and_old_pipe_facts :: proc(t: ^testing.T) {
	s: Server
	async_server(&s, t)
	defer destroy(&s)
	s.lua.request_reload = runtime_request_reload
	expect_eval(
		t,
		&s,
		`n=0;out=0;core.set_event_handler(function(e) out=out+1 end)
old=core.timer(10000,function() n=n+100 end)
assert(core._reload(function()
 core._timers_reset()
core._frame_reset()
 fresh=core.timer(10000,function() n=n+1 end)
end))`,
		"\n",
	)
	timer_ready(s.timers[1])
	queue_event(&s, vm.Event{class = "spawn", name = "out", id = 1, bytes = "old"})
	testing.expect(t, wl.dispatch(s.display, 0))
	expect_eval(t, &s, "return n,out,old,fresh", "0\t0\t1\t2\n")
	testing.expect_value(t, len(s.timers), 1)
	testing.expect_value(t, len(s.lua.timer_refs), 1)
	timer_ready(s.timers[2])
	testing.expect(t, wl.dispatch(s.display, 0))
	expect_eval(t, &s, "return n,out", "1\t0\n")
	// Destruction owns the pending request without calling back into retired policy.
	expect_eval(t, &s, "core._reload(function() error('shutdown reload') end)", "true\n")
}
