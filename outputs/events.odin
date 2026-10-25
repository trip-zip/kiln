package outputs

import wl "../wayland"
import "core:sys/posix"

Commit_Event :: struct {
	output: ^Output,
	when_:  posix.timespec,
	state:  ^State,
}

Present_Event :: struct {
	output:     ^Output,
	commit_seq: u32,
	presented:  bool,
	when_:      posix.timespec,
}

Bind_Event :: struct {
	output:   ^Output,
	resource: ^wl.Resource,
}

Request_State_Event :: struct {
	output: ^Output,
	state:  ^State,
}

update_needs_frame :: proc(o: ^Output) {
	if o.needs_frame || o.finishing {return}
	o.needs_frame = true
	wl.signal_emit_mutable(&o.events.needs_frame, o)
}

schedule_frame :: proc(o: ^Output) {
	if o.finishing || !o.enabled {return}
	update_needs_frame(o)
	if o.frame_pending || o.idle_frame != nil {return}
	if o.impl != nil && o.impl.schedule != nil {
		o.impl.schedule(o)
		return
	}
	if o.display != nil {o.idle_frame = wl.on_idle(o.display, frame_idle, o)}
}

frame_idle :: proc(data: rawptr) {
	o := cast(^Output)data
	o.idle_frame = nil
	send_frame(o)
}

send_frame :: proc(o: ^Output) {
	o.frame_pending = false
	wl.remove_source(o.idle_frame)
	o.idle_frame = nil
	if o.enabled {wl.signal_emit_mutable(&o.events.frame, o)}
}

send_present :: proc(o: ^Output, event: Present_Event) {
	e := event
	e.output = o
	if e.presented && e.when_ == (posix.timespec{}) {posix.clock_gettime(.MONOTONIC, &e.when_)}
	if e.commit_seq == o.commit_seq {o.frame_pending = false}
	wl.signal_emit_mutable(&o.events.present, &e)
}

schedule_done :: proc(o: ^Output) {
	if o.idle_done == nil &&
	   o.display != nil &&
	   !o.finishing {o.idle_done = wl.on_idle(o.display, done_idle, o)}
}

done_idle :: proc(data: rawptr) {
	o := cast(^Output)data
	o.idle_done = nil
	it := wl.iterate(&o.resources)
	for link in wl.next(&it) {
		r := resource_from_link(link)
		send_done(r)
	}
}

request_state :: proc(o: ^Output, s: ^State) {
	e := Request_State_Event{o, s}
	wl.signal_emit_mutable(&o.events.request_state, &e)
}
