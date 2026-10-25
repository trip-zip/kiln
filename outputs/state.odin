package outputs

import "../gles"
import wl "../wayland"
import "core:math"
import "core:sys/posix"

Field :: enum {
	Buffer,
	Mode,
	Enabled,
	Scale,
	Transform,
	Adaptive_Sync,
}

State :: struct {
	committed:     bit_set[Field],
	enabled:       bool,
	mode:          ^Mode,
	custom_mode:   Mode,
	scale:         f32,
	transform:     i32,
	adaptive_sync: bool,
	buffer:        ^gles.Buffer,
}

state_init :: proc(s: ^State) {s^ = {}}
state_finish :: proc(s: ^State) {
	gles.buffer_release(s.buffer)
	s.buffer = nil
	s.committed -= {.Buffer}
}

set_enabled :: proc(s: ^State, enabled: bool) {
	s.enabled = enabled
	s.committed += {.Enabled}
}

set_mode :: proc(s: ^State, mode: ^Mode) {
	s.mode = mode
	s.committed += {.Mode}
}

set_custom_mode :: proc(s: ^State, w, h, refresh: i32) {
	s.mode = nil
	s.custom_mode = {w, h, refresh, false}
	s.committed += {.Mode}
}

set_scale :: proc(s: ^State, scale: f32) {
	s.scale = scale
	s.committed += {.Scale}
}

set_transform :: proc(s: ^State, transform: i32) {
	s.transform = transform
	s.committed += {.Transform}
}

set_adaptive_sync_enabled :: proc(s: ^State, enabled: bool) {
	s.adaptive_sync = enabled
	s.committed += {.Adaptive_Sync}
}

set_buffer :: proc(s: ^State, b: ^gles.Buffer) {
	next := gles.buffer_retain(b)
	gles.buffer_release(s.buffer)
	s.buffer = next
	s.committed += {.Buffer}
}

commit :: proc(o: ^Output, s: ^State) -> bool {
	if o.finishing {return false}
	if s.committed == {} {return true}
	w, h := o.width, o.height
	if .Mode in s.committed {
		m := s.mode^ if s.mode != nil else s.custom_mode
		w, h = m.width, m.height
		if w <= 0 || h <= 0 || m.refresh < 0 {return false}
	}
	enabled := s.enabled if .Enabled in s.committed else o.enabled
	if enabled && (w <= 0 || h <= 0) {return false}
	if .Buffer in s.committed &&
	(!enabled || s.buffer == nil || s.buffer.width != w || s.buffer.height != h) {return false}
	if .Scale in s.committed &&
	(s.scale <= 0 || math.is_nan(s.scale) || math.is_inf(s.scale)) {return false}
	if .Transform in s.committed && (s.transform < 0 || s.transform > 7) {return false}
	if o.impl == nil || !o.impl.commit(o, s) {return false}
	if .Mode in s.committed {
		m := s.mode^ if s.mode != nil else s.custom_mode
		o.width, o.height, o.refresh, o.current_mode = w, h, m.refresh, s.mode
	}
	if .Enabled in s.committed {o.enabled = s.enabled}
	if .Scale in s.committed {o.scale = s.scale}
	if .Transform in s.committed {o.transform = s.transform}
	if .Adaptive_Sync in s.committed {o.adaptive_sync_status = i32(s.adaptive_sync)}
	o.commit_seq += 1
	if .Buffer in s.committed {
		o.frame_pending, o.needs_frame = true, false
		wl.remove_source(o.idle_frame)
		o.idle_frame = nil
	}
	if !o.enabled {
		o.frame_pending = false
		wl.remove_source(o.idle_frame)
		o.idle_frame = nil
	}
	it := wl.iterate(&o.resources)
	for link in wl.next(&it) {
		r := resource_from_link(link)
		if .Mode in s.committed {send_mode(r)}
		if s.committed & {.Mode, .Transform} != {} {send_geometry(r)}
		if .Scale in s.committed {send_scale(r)}
	}
	if s.committed & {.Mode, .Transform, .Scale} != {} {schedule_done(o)}
	e := Commit_Event {
		output = o,
		state  = s,
	}
	posix.clock_gettime(.MONOTONIC, &e.when_)
	wl.signal_emit_mutable(&o.events.commit, &e)
	return true
}
