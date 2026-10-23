package wayland

import "core:testing"
import "core:sys/linux"
import "core:time"

Loop_Test :: struct { calls: int, source, other: ^Source, loop: ^Loop, seen_context: rawptr }
count_timer :: proc(data: rawptr) -> i32 {
	s := cast(^Loop_Test)data
	s.calls += 1
	s.seen_context = context.user_ptr
	return 0
}
@(test)
loop_timers_rearm_disarm_and_preserve_context :: proc(t: ^testing.T) {
	state: Loop_Test
	context.user_ptr = &state
	loop := loop_create()
	defer loop_destroy(loop)
	source := loop_on_timer(loop, count_timer, &state)
	testing.expect(t, source_arm_timer(source, time.Millisecond))
	testing.expect(t, loop_dispatch(loop, 100))
	testing.expect_value(t, state.calls, 1)
	testing.expect(t, state.seen_context == rawptr(&state))
	loop_dispatch(loop, 0)
	testing.expect_value(t, state.calls, 1)
	source_arm_timer(source, time.Millisecond)
	loop_dispatch(loop, 100)
	testing.expect_value(t, state.calls, 2)
	source_arm_timer(source, time.Millisecond)
	source_arm_timer(source, 0)
	loop_dispatch(loop, 5)
	testing.expect_value(t, state.calls, 2)
}
@(test)
loop_readable_sources_can_remove_pending_peers :: proc(t: ^testing.T) {
	loop := loop_create()
	defer loop_destroy(loop)
	pipes: [2]linux.Fd
	testing.expect(t, linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK}) == .NONE)
	defer linux.close(pipes[0]); defer linux.close(pipes[1])
	states: [2]Loop_Test
	for &s in states {
		s.source = loop_on_fd(loop, i32(pipes[0]), {.Readable}, proc(fd: i32, mask: Mask, data: rawptr) -> i32 {
			s := cast(^Loop_Test)data
			s.calls += 1
			source_remove(s.other)
			source_remove(s.source)
			return 0
		}, &s)
	}
	states[0].other, states[1].other = states[1].source, states[0].source
	linux.write(pipes[1], []u8{1})
	loop_dispatch(loop, 100)
	testing.expect_value(t, states[0].calls + states[1].calls, 1)
	byte: [1]u8
	n, _ := linux.read(pipes[0], byte[:])
	testing.expect_value(t, n, 1)
}
@(test)
loop_idles_drain_and_checks_repeat :: proc(t: ^testing.T) {
	loop := loop_create()
	defer loop_destroy(loop)
	s := Loop_Test{loop = loop}
	loop_on_idle(loop, proc(data: rawptr) {
		s := cast(^Loop_Test)data
		s.calls += 1
		loop_on_idle(s.loop, proc(data: rawptr) { (cast(^Loop_Test)data).calls += 1 }, s)
	}, &s)
	loop_dispatch(loop, 0)
	testing.expect_value(t, s.calls, 2)
	loop_dispatch(loop, 0)
	testing.expect_value(t, s.calls, 2)
	s.calls = 0
	source := loop_on_timer(loop, proc(data: rawptr) -> i32 {
		s := cast(^Loop_Test)data
		s.calls += 1
		return 1 if s.calls < 3 else 0
	}, &s)
	source_check(source)
	loop_dispatch(loop, 0)
	testing.expect_value(t, s.calls, 3)
}
@(test)
loop_signal_and_destroy_order :: proc(t: ^testing.T) {
	old: linux.Sig_Set
	linux.rt_sigprocmask(.SIG_BLOCK, nil, &old)
	defer linux.rt_sigprocmask(.SIG_SETMASK, &old, nil)
	loop := loop_create()
	state: Loop_Test
	source := loop_on_signal(loop, .SIGUSR1, proc(number: linux.Signal, data: rawptr) -> i32 {
		(cast(^Loop_Test)data).calls += 1
		return 0
	}, &state)
	if !testing.expect(t, source != nil) { loop_destroy(loop); return }
	linux.tgkill(linux.getpid(), linux.gettid(), .SIGUSR1)
	loop_dispatch(loop, 100)
	testing.expect_value(t, state.calls, 1)
	source_remove(source)
	now: linux.Sig_Set
	linux.rt_sigprocmask(.SIG_BLOCK, nil, &now)
	testing.expect(t, now[0] & (1 << (u32(linux.Signal.SIGUSR1)-1)) != 0)
	listeners: [2]Listener
	for &l in listeners { listen(&loop.destroy_signal, &l, proc "c" (l: ^Listener, data: rawptr) {
		loop := cast(^Loop)data
		context = loop.ctx
		state := cast(^Loop_Test)context.user_ptr
		state.calls += 1
		list_remove(&l.link)
	}) }
	loop.ctx.user_ptr = &state
	loop_destroy(loop)
	testing.expect_value(t, state.calls, 3)
}
@(test)
mutable_signal_skips_removed_and_new_listeners :: proc(t: ^testing.T) {
	signal: Signal
	signal_init(&signal)
	State :: struct { listeners: [3]Listener, signal: ^Signal, calls: int }
	s := State{signal = &signal}
	listen(&signal, &s.listeners[0], proc "c" (l: ^Listener, data: rawptr) {
		context = {}
		s := cast(^State)data
		s.calls += 1
		unlisten(&s.listeners[1])
		unlisten(l)
		listen(s.signal, &s.listeners[2], proc "c" (l: ^Listener, data: rawptr) { (cast(^State)data).calls += 1 })
	})
	listen(&signal, &s.listeners[1], proc "c" (l: ^Listener, data: rawptr) { (cast(^State)data).calls += 10 })
	signal_emit_mutable(&signal, &s)
	testing.expect_value(t, s.calls, 1)
	signal_emit_mutable(&signal, &s)
	testing.expect_value(t, s.calls, 2)
	unlisten(&s.listeners[2])
}
