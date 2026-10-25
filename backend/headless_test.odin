package backend

import out "../outputs"
import wl "../wayland"
import "core:testing"

Headless_Probe :: struct {
	added, frame, present:  wl.Listener,
	adds, frames, presents: int,
	sequence:               u32,
}

headless_test_added :: proc(l: ^wl.Listener, data: rawptr) {wl.owner(l, Headless_Probe, "added").adds += 1}
headless_test_frame :: proc(l: ^wl.Listener, data: rawptr) {wl.owner(l, Headless_Probe, "frame").frames += 1}
headless_test_present :: proc(l: ^wl.Listener, data: rawptr) {
	v := wl.owner(l, Headless_Probe, "present")
	e := cast(^out.Present_Event)data
	v.presents += 1
	v.sequence = e.commit_seq
}

@(test)
headless_announces_at_start_and_paces_only_scheduled_frames :: proc(t: ^testing.T) {
	d := wl.create()
	defer wl.destroy(d)
	b := headless_create(d)
	defer destroy(b)
	v: Headless_Probe
	wl.listen(&b.events.new_output, &v.added, headless_test_added)
	defer wl.unlisten(&v.added)
	o := headless_add_output(b, 32, 24)
	testing.expect_value(t, v.adds, 0)
	testing.expect(t, start(b))
	testing.expect_value(t, v.adds, 1)
	testing.expect(t, start(b))
	testing.expect_value(t, v.adds, 1)
	wl.listen(&o.events.frame, &v.frame, headless_test_frame)
	defer wl.unlisten(&v.frame)
	wl.listen(&o.events.present, &v.present, headless_test_present)
	defer wl.unlisten(&v.present)
	s: out.State
	out.set_enabled(&s, true)
	testing.expect(t, out.commit(o, &s))
	testing.expect_value(t, v.sequence, o.commit_seq)
	testing.expect_value(t, v.presents, 1)
	for _ in 0 ..< 8 {out.schedule_frame(o)}
	wl.dispatch(d, 25)
	testing.expect_value(t, v.frames, 1)
	wl.dispatch(d, 25)
	testing.expect_value(t, v.frames, 1)
	out.schedule_frame(o)
	out.set_enabled(&s, false)
	testing.expect(t, out.commit(o, &s))
	wl.dispatch(d, 25)
	testing.expect_value(t, v.frames, 1)
	testing.expect(t, !(cast(^Headless_Output)o.data).timer.armed)
	out.set_enabled(&s, true)
	testing.expect(t, out.commit(o, &s))
	out.schedule_frame(o)
	out.finish(o)
	wl.dispatch(d, 25)
	testing.expect_value(t, v.frames, 1)
	testing.expect_value(t, len((cast(^Headless)b.data).outputs), 0)
}

@(test)
headless_hotplug_and_display_teardown_release_sources :: proc(t: ^testing.T) {
	d := wl.create()
	b := headless_create(d)
	testing.expect(t, start(b))
	v: Headless_Probe
	wl.listen(&b.events.new_output, &v.added, headless_test_added)
	o := headless_add_output(b, 40, 30)
	testing.expect_value(t, v.adds, 1)
	s: out.State
	out.set_enabled(&s, true)
	testing.expect(t, out.commit(o, &s))
	out.schedule_frame(o)
	wl.unlisten(&v.added)
	wl.destroy(d)
}
