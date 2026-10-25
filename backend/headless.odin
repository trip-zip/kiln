package backend

import out "../outputs"
import wl "../wayland"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

Headless :: struct {
	base:            Backend,
	outputs:         [dynamic]^Headless_Output,
	next:            u32,
	default_outputs: bool,
}

Headless_Output :: struct {
	output:  out.Output,
	backend: ^Headless,
	timer:   ^wl.Source,
	commit:  wl.Listener,
}

headless_impl := Backend_Impl {
	start   = headless_start,
	destroy = headless_destroy,
}

headless_output_impl := out.Impl {
	commit   = headless_commit,
	destroy  = headless_output_destroy,
	schedule = headless_schedule,
}

headless_create :: proc(display: ^wl.Display) -> ^Backend {
	h := new(Headless)
	init(&h.base, display, &headless_impl)
	h.base.data = h
	return &h.base
}

headless_add_output :: proc(b: ^Backend, width, height: u32) -> ^out.Output {
	if b.impl != &headless_impl ||
	   width == 0 ||
	   height == 0 ||
	   width > u32(max(i32)) ||
	   height > u32(max(i32)) {return nil}
	context = b.loop.ctx
	h := cast(^Headless)b.data
	h.next += 1
	o := new(Headless_Output)
	o.backend = h
	out.init(&o.output, &headless_output_impl, b.display, fmt.tprintf("HEADLESS-%d", h.next))
	o.output.data = o
	out.set_description(&o.output, fmt.tprintf("Headless output %d", h.next))
	m := new(out.Mode)
	m^ = {i32(width), i32(height), 60000, false}
	append(&o.output.modes, m)
	o.output.current_mode, o.output.width, o.output.height, o.output.refresh =
		m, m.width, m.height, m.refresh
	o.timer = wl.loop_on_timer(b.loop, headless_frame, o)
	wl.listen(&o.output.events.commit, &o.commit, headless_committed)
	append(&h.outputs, o)
	if b.started {wl.signal_emit_mutable(&b.events.new_output, &o.output)}
	return &o.output
}

headless_start :: proc(b: ^Backend) -> bool {
	h := cast(^Headless)b.data
	if h.default_outputs && len(h.outputs) == 0 {
		count := 1
		if value, ok := os.lookup_env("KILN_HEADLESS_OUTPUTS", context.temp_allocator); ok {
			n, valid := strconv.parse_int(value)
			if valid && n >= 0 {count = n}
		}
		for _ in 0 ..< count {if headless_add_output(b, 1280, 720) == nil {return false}}
	}
	b.started = true
	for o in h.outputs {wl.signal_emit_mutable(&b.events.new_output, &o.output)}
	return true
}

headless_commit :: proc(o: ^out.Output, s: ^out.State) -> bool {return true}
headless_committed :: proc(l: ^wl.Listener, data: rawptr) {
	h := wl.owner(l, Headless_Output, "commit")
	o := &h.output
	if !o.enabled {
		wl.arm_timer(h.timer, 0)
		return
	}
	// A one-shot deadline gives continuous animation a refresh cadence without waking idle outputs.
	if !h.timer.armed {wl.arm_timer(h.timer, time.Duration(1_000_000_000_000 / i64(max(o.refresh, 1))))}
	out.send_present(o, out.Present_Event{commit_seq = o.commit_seq, presented = true})
}

headless_schedule :: proc(o: ^out.Output) {
	h := cast(^Headless_Output)o.data
	if !h.timer.armed {wl.arm_timer(h.timer, time.Duration(1_000_000_000_000 / i64(max(o.refresh, 1))))}
}

headless_frame :: proc(data: rawptr) -> i32 {
	h := cast(^Headless_Output)data
	if h.output.enabled && h.output.needs_frame {out.send_frame(&h.output)}
	return 0
}

headless_output_destroy :: proc(o: ^out.Output) {
	h := cast(^Headless_Output)o.data
	wl.unlisten(&h.commit)
	wl.remove_source(h.timer)
	for other, i in h.backend.outputs {
		if other == h {
			ordered_remove(&h.backend.outputs, i)
			break
		}
	}
	free(h)
}

headless_destroy :: proc(b: ^Backend) {
	context = b.loop.ctx
	h := cast(^Headless)b.data
	for len(h.outputs) > 0 {out.finish(&h.outputs[len(h.outputs) - 1].output)}
	delete(h.outputs)
	free(h)
}
