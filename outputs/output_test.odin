package outputs

import "../gles"
import p "../protocols"
import wl "../wayland"
import "core:sys/linux"
import "core:testing"

Commit_Probe :: struct {
	calls:    int,
	accept:   bool,
	commit:   wl.Listener,
	sequence: u32,
	width:    i32,
}

probe_commit :: proc(o: ^Output, s: ^State) -> bool {
	v := cast(^Commit_Probe)o.data
	v.calls += 1
	return v.accept
}

probe_committed :: proc(l: ^wl.Listener, data: rawptr) {
	v := wl.owner(l, Commit_Probe, "commit")
	e := cast(^Commit_Event)data
	v.sequence, v.width = e.output.commit_seq, e.output.width
}

@(test)
commit_rejection_is_atomic_and_state_owns_its_buffer :: proc(t: ^testing.T) {
	v := Commit_Probe {
		accept = true,
	}
	impl := Impl {
		commit = probe_commit,
	}
	o: Output
	init(&o, &impl, nil, "test")
	defer finish(&o)
	o.data = &v
	wl.listen(&o.events.commit, &v.commit, probe_committed)
	defer wl.unlisten(&v.commit)
	s: State
	defer state_finish(&s)
	testing.expect(t, commit(&o, &s))
	testing.expect_value(t, v.calls, 0)
	set_enabled(&s, true)
	testing.expect(t, !commit(&o, &s))
	testing.expect_value(t, v.calls, 0)
	set_custom_mode(&s, 8, 6, 60000)
	b := gles.Buffer {
		width  = 7,
		height = 6,
	}
	set_buffer(&s, &b)
	testing.expect_value(t, b.locks, 1)
	testing.expect(t, !commit(&o, &s))
	testing.expect_value(t, v.calls, 0)
	b.width = 8
	v.accept = false
	testing.expect(t, !commit(&o, &s))
	testing.expect(t, !o.enabled && o.width == 0 && o.commit_seq == 0)
	v.accept = true
	testing.expect(t, commit(&o, &s))
	testing.expect(t, o.enabled && o.frame_pending && !o.needs_frame)
	testing.expect_value(t, v.sequence, u32(1))
	testing.expect_value(t, v.width, i32(8))
	set_buffer(&s, &b)
	testing.expect_value(t, b.locks, 1)
	state_finish(&s)
	testing.expect_value(t, b.locks, 0)
	set_scale(&s, 0)
	testing.expect(t, !commit(&o, &s))
	testing.expect_value(t, o.scale, f32(1))
}

@(test)
layout_preserves_fractional_interior_and_reflows_auto_outputs :: proc(t: ^testing.T) {
	l := layout_create(nil)
	defer layout_destroy(l)
	a, b: Output
	init(&a, nil, nil, "a")
	init(&b, nil, nil, "b")
	defer finish(&a)
	defer finish(&b)
	a.enabled, b.enabled = true, true
	a.width, a.height, b.width, b.height = 100, 80, 60, 40
	layout_add(l, &a, -100, 10)
	layout_add_auto(l, &b)
	testing.expect_value(t, layout_box(l, &b), gles.Box{0, 10, 60, 40})
	x, y := layout_closest_point(l, nil, -0.25, 20)
	testing.expect_value(t, x, -0.25)
	testing.expect_value(t, y, f64(20))
	testing.expect(t, layout_output_at(l, -0.25, 20) == &a)
	a.scale = 2
	a.transform = 1
	layout_reconfigure(l)
	testing.expect_value(t, layout_box(l, &b), gles.Box{-60, 10, 60, 40})
	a.enabled = false
	layout_reconfigure(l)
	testing.expect_value(t, layout_box(l), gles.Box{0, 0, 60, 40})
	finish(&b)
	testing.expect_value(t, layout_box(l), gles.Box{})
}

Bind_Probe :: struct {
	bind:   wl.Listener,
	listed: bool,
}

probe_bind :: proc(l: ^wl.Listener, data: rawptr) {
	v := wl.owner(l, Bind_Probe, "bind")
	e := cast(^Bind_Event)data
	it := wl.client_resources(&e.output.resources, e.resource.client)
	for r in wl.next_resource(&it) {if r == e.resource {v.listed = of(r) == e.output}}
}

@(test)
output_global_versions_and_inert_resources :: proc(t: ^testing.T) {
	for version in u32(1) ..= 4 {
		d := wl.create()
		defer wl.destroy(d)
		fds: [2]linux.Fd
		assert(linux.socketpair(.UNIX, .STREAM, {}, &fds) == .NONE)
		c := wl.client_create(d, i32(fds[0]))
		defer wl.destroy_clients(d)
		peer := wl.Connection {
			fd = fds[1],
		}
		defer wl.connection_close(&peer)
		o: Output
		init(&o, nil, d, "TEST-1")
		defer finish(&o)
		o.width, o.height, o.refresh, o.scale = 32, 24, 60000, 1.5
		set_description(&o, "test display")
		v: Bind_Probe
		wl.listen(&o.events.bind, &v.bind, probe_bind)
		defer wl.unlisten(&v.bind)
		o.global.bind(o.global, c, version, 2)
		r := wl.client_get_object(c, 2)
		testing.expect(t, v.listed && of(r) == &o)
		wl.display_flush_clients(d)
		n, _ := wl.connection_read(&peer)
		bytes: [1024]u8
		wl.ring_copy(&peer.input, bytes[:n])
		peer.input.tail += uint(n)
		opcodes: [dynamic]u32
		defer delete(opcodes)
		for at := 0;
		    at < n;
		    at += int(
			    wl.word_read(bytes[:], at + 4) >> 16,
		    ) {append(&opcodes, wl.word_read(bytes[:], at + 4) & 0xffff)}
		want := []u32{0, 1}
		if version >=
		   4 {want = []u32{0, 1, 3, 4, 5, 2}} else if version >= 2 {want = []u32{0, 1, 3, 2}}
		testing.expect_value(t, len(opcodes), len(want))
		for op, i in want {testing.expect_value(t, opcodes[i], op)}
		finish(&o)
		testing.expect(t, of(r) == nil)
		r.dispatcher(r, u32(p.Wl_Output_Request.release), nil)
		testing.expect(t, wl.client_get_object(c, 2) == nil)
	}
}
