package wayland

import "base:runtime"
import "core:sys/linux"
import "core:time"

Event :: enum { Readable, Writable, Hangup, Error }
Mask :: bit_set[Event; u32]
Source_Kind :: enum { FD, Timer, Signal, Idle }
Loop :: struct {
	fd, timer_fd: linux.Fd,
	ctx: runtime.Context,
	sources, timers, idles, checks, garbage: List,
	destroy_signal: Signal,
	depth: int,
}
Source :: struct {
	loop: ^Loop,
	kind: Source_Kind,
	link, timer_link, idle_link, check_link: List,
	fd, original_fd: linux.Fd,
	number: linux.Signal,
	deadline: i64,
	removed, armed, checked: bool,
	due_next: ^Source,
	data: rawptr,
	fd_callback: proc(i32, Mask, rawptr) -> i32,
	timer_callback: proc(rawptr) -> i32,
	signal_callback: proc(linux.Signal, rawptr) -> i32,
	idle_callback: proc(rawptr),
	cleanup: proc(rawptr),
}
loop_create :: proc() -> ^Loop {
	fd, err := linux.epoll_create1({.FDCLOEXEC})
	if err != .NONE { return nil }
	loop := new(Loop)
	loop.fd, loop.timer_fd, loop.ctx = fd, -1, context
	init(&loop.sources); init(&loop.timers); init(&loop.idles); init(&loop.checks); init(&loop.garbage)
	signal_init(&loop.destroy_signal)
	return loop
}
loop_collect :: proc(loop: ^Loop) {
	if loop.depth != 0 { return }
	for !empty(&loop.garbage) {
		source := runtime.container_of(loop.garbage.next, Source, "link")
		list_remove(&source.link)
		if source.cleanup != nil { source.cleanup(source.data) }
		free(source)
	}
}
loop_destroy :: proc(loop: ^Loop) {
	context = loop.ctx
	signal_emit_final(&loop.destroy_signal, loop)
	for !empty(&loop.sources) { source_remove(runtime.container_of(loop.sources.next, Source, "link")) }
	loop_collect(loop)
	if loop.timer_fd >= 0 { linux.close(loop.timer_fd) }
	linux.close(loop.fd)
	free(loop)
}
source_new :: proc(loop: ^Loop, kind: Source_Kind, data: rawptr) -> ^Source {
	context = loop.ctx
	source := new(Source)
	source.loop, source.kind, source.data, source.fd = loop, kind, data, -1
	init(&source.timer_link); init(&source.idle_link); init(&source.check_link)
	insert(loop.sources.prev, &source.link)
	return source
}
epoll_mask :: proc(mask: Mask) -> (events: linux.EPoll_Event_Set) {
	if .Readable in mask { events += {.IN} }
	if .Writable in mask { events += {.OUT} }
	return
}
source_poll :: proc(source: ^Source, mask: Mask) -> bool {
	ep := linux.EPoll_Event{events = epoll_mask(mask), data = {ptr = source}}
	return linux.epoll_ctl(source.loop.fd, .ADD, source.fd, &ep) == .NONE
}
loop_on_fd :: proc(loop: ^Loop, fd: i32, mask: Mask, callback: proc(i32, Mask, rawptr) -> i32, data: rawptr) -> ^Source {
	source := source_new(loop, .FD, data)
	source.original_fd, source.fd_callback = linux.Fd(fd), callback
	duplicate, err := linux.fcntl(linux.Fd(fd), linux.F_DUPFD_CLOEXEC, 0)
	if err != .NONE { source_remove(source); return nil }
	source.fd = duplicate
	if !source_poll(source, mask) { source_remove(source); return nil }
	return source
}
source_update_fd :: proc(source: ^Source, mask: Mask) -> bool {
	if source == nil || source.removed { return false }
	ep := linux.EPoll_Event{events = epoll_mask(mask), data = {ptr = source}}
	return linux.epoll_ctl(source.loop.fd, .MOD, source.fd, &ep) == .NONE
}
loop_on_idle :: proc(loop: ^Loop, callback: proc(rawptr), data: rawptr) -> ^Source {
	source := source_new(loop, .Idle, data)
	source.idle_callback = callback
	insert(loop.idles.prev, &source.idle_link)
	return source
}
loop_on_timer :: proc(loop: ^Loop, callback: proc(rawptr) -> i32, data: rawptr) -> ^Source {
	if loop.timer_fd < 0 {
		fd, err := linux.timerfd_create(.MONOTONIC, {.CLOEXEC, .NONBLOCK})
		if err != .NONE { return nil }
		ep := linux.EPoll_Event{events = {.IN}, data = {ptr = loop}}
		if linux.epoll_ctl(loop.fd, .ADD, fd, &ep) != .NONE { linux.close(fd); return nil }
		loop.timer_fd = fd
	}
	source := source_new(loop, .Timer, data)
	source.timer_callback = callback
	return source
}
monotonic_ns :: proc() -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec)*1_000_000_000 + i64(ts.time_nsec)
}
loop_set_timer :: proc(loop: ^Loop) -> bool {
	if loop.timer_fd < 0 { return true }
	value: linux.ITimer_Spec
	if !empty(&loop.timers) {
		first := runtime.container_of(loop.timers.next, Source, "timer_link")
		value.value.time_sec = uint(first.deadline / 1_000_000_000)
		value.value.time_nsec = uint(first.deadline % 1_000_000_000)
	}
	return linux.timerfd_settime(loop.timer_fd, {.ABSTIME}, &value, nil) == .NONE
}
source_arm_timer :: proc(source: ^Source, delay: time.Duration) -> bool {
	if source == nil || source.removed || source.kind != .Timer { return false }
	if source.armed { list_remove(&source.timer_link); init(&source.timer_link) }
	source.armed = delay > 0
	if source.armed {
		source.deadline = monotonic_ns() + i64(delay)
		position := source.loop.timers.next
		for position != &source.loop.timers {
			other := runtime.container_of(position, Source, "timer_link")
			if other.deadline > source.deadline { break }
			position = position.next
		}
		insert(position.prev, &source.timer_link)
	}
	return loop_set_timer(source.loop)
}
SFD_CLOEXEC :: u32(1) << u32(linux.Open_Flags_Bits.CLOEXEC)
SFD_NONBLOCK :: u32(1) << u32(linux.Open_Flags_Bits.NONBLOCK)
#assert(SFD_CLOEXEC == 0x80000 && SFD_NONBLOCK == 0x800)
Signal_Info :: struct { number: u32, rest: [124]u8 }
#assert(size_of(Signal_Info) == 128)
loop_on_signal :: proc(loop: ^Loop, number: linux.Signal, callback: proc(linux.Signal, rawptr) -> i32, data: rawptr) -> ^Source {
	mask: linux.Sig_Set
	mask[0] = uint(1) << (u32(number)-1)
	value := linux.syscall(linux.SYS_signalfd4, -1, &mask, size_of(mask), SFD_CLOEXEC | SFD_NONBLOCK)
	if value < 0 { return nil }
	if linux.rt_sigprocmask(.SIG_BLOCK, &mask, nil) != .NONE { linux.close(linux.Fd(value)); return nil }
	source := source_new(loop, .Signal, data)
	source.fd, source.number, source.signal_callback = linux.Fd(value), number, callback
	if !source_poll(source, {.Readable}) { source_remove(source); return nil }
	return source
}
source_check :: proc(source: ^Source) {
	if source.removed || source.checked { return }
	source.checked = true
	insert(source.loop.checks.prev, &source.check_link)
}
source_remove :: proc(source: ^Source) {
	if source == nil || source.removed { return }
	context = source.loop.ctx
	if source.armed { source_arm_timer(source, 0) }
	source.removed = true
	if source.fd >= 0 {
		linux.epoll_ctl(source.loop.fd, .DEL, source.fd, nil)
		linux.close(source.fd)
		source.fd = -1
	}
	list_remove(&source.idle_link); list_remove(&source.check_link)
	list_remove(&source.link)
	insert(&source.loop.garbage, &source.link)
	loop_collect(source.loop)
}
loop_idles :: proc(loop: ^Loop) {
	for !empty(&loop.idles) {
		source := runtime.container_of(loop.idles.next, Source, "idle_link")
		list_remove(&source.idle_link); init(&source.idle_link)
		source.idle_callback(source.data)
		if !source.removed { source_remove(source) }
	}
}
source_dispatch :: proc(source: ^Source, mask: Mask) -> i32 {
	if source.removed { return 0 }
	switch source.kind {
	case .FD: return source.fd_callback(i32(source.original_fd), mask, source.data)
	case .Timer: return source.timer_callback(source.data)
	case .Signal:
		info: Signal_Info
		linux.read(source.fd, (cast([^]u8)&info)[:size_of(info)])
		return source.signal_callback(source.number, source.data)
	case .Idle: return 0
	}
	return 0
}
loop_dispatch :: proc(loop: ^Loop, timeout: i32) -> bool {
	context = loop.ctx
	loop.depth += 1
	defer { loop.depth -= 1; loop_collect(loop) }
	loop_idles(loop)
	events: [32]linux.EPoll_Event
	deadline := monotonic_ns() + i64(max(timeout, 0))*1_000_000
	remaining := timeout
	count: i32
	for {
		err: linux.Errno
		count, err = linux.epoll_wait(loop.fd, &events[0], len(events), remaining)
		if err == .NONE { break }
		if err != .EINTR && err != .EAGAIN { return false }
		if timeout > 0 {
			remaining = i32(max(0, (deadline-monotonic_ns())/1_000_000))
			if remaining == 0 { count = 0; break }
		}
	}
	for event in events[:count] {
		if event.data.ptr != rawptr(loop) { continue }
		// Freeze the due set before any callback can change another timer's deadline.
		head, tail: ^Source
		now := monotonic_ns()
		for !empty(&loop.timers) {
			source := runtime.container_of(loop.timers.next, Source, "timer_link")
			if source.deadline > now { break }
			list_remove(&source.timer_link); init(&source.timer_link)
			source.armed, source.due_next = false, nil
			if tail != nil { tail.due_next = source } else { head = source }
			tail = source
		}
		if !loop_set_timer(loop) { return false }
		for source := head; source != nil; source = source.due_next {
			if !source.removed { source_dispatch(source, {}) }
		}
		break
	}
	for event in events[:count] {
		if event.data.ptr == rawptr(loop) { continue }
		mask: Mask
		if .IN in event.events { mask += {.Readable} }
		if .OUT in event.events { mask += {.Writable} }
		if .HUP in event.events { mask += {.Hangup} }
		if .ERR in event.events { mask += {.Error} }
		source_dispatch(cast(^Source)event.data.ptr, mask)
	}
	loop_idles(loop)
	for {
		again := false
		// The casts acknowledge stack links to the escape checker; both cursors are unlinked before return.
		cursor, end: List
		insert(&loop.checks, cast(^List)rawptr(&cursor)); insert(loop.checks.prev, cast(^List)rawptr(&end))
		for cursor.next != &end {
			link := cursor.next
			source := runtime.container_of(link, Source, "check_link")
			list_remove(&cursor); insert(link, cast(^List)rawptr(&cursor))
			again = source_dispatch(source, {}) != 0 || again
		}
		list_remove(&cursor); list_remove(&end)
		if !again { break }
	}
	return true
}
