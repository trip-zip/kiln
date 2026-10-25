package outputs

import "../gles"
import wl "../wayland"
import "base:runtime"

Layout :: struct {
	outputs:         [dynamic]^Layout_Output,
	events:          struct {
		change, destroy: wl.Signal,
	},
	allocator:       runtime.Allocator,
	display_destroy: wl.Listener,
}

Layout_Output :: struct {
	layout: ^Layout,
	output: ^Output,
	x, y:   i32,
	auto:   bool,
	commit: wl.Listener,
}

layout_create :: proc(display: ^wl.Display) -> ^Layout {
	l := new(Layout)
	l.allocator = context.allocator
	wl.signal_init(&l.events.change)
	wl.signal_init(&l.events.destroy)
	if display !=
	   nil {wl.listen(&display.destroy_signal, &l.display_destroy, layout_display_destroyed)}
	return l
}

layout_destroy :: proc(l: ^Layout) {
	context.allocator = l.allocator
	wl.unlisten(&l.display_destroy)
	wl.signal_emit_final(&l.events.destroy, l)
	for e in l.outputs {wl.unlisten(&e.commit); e.output.layout = nil; free(e)}
	delete(l.outputs)
	free(l)
}

layout_find :: proc(l: ^Layout, o: ^Output) -> ^Layout_Output {
	for e in l.outputs {if e.output == o {return e}}
	return nil
}

layout_add :: proc(l: ^Layout, o: ^Output, x, y: i32, auto := false) -> ^Layout_Output {
	context.allocator = l.allocator
	if o.layout != nil && o.layout != l {layout_remove(o.layout, o)}
	e := layout_find(l, o)
	if e == nil {
		e = new(Layout_Output)
		e.layout, e.output, o.layout = l, o, l
		// Stable allocations keep listener addresses valid as outputs arrive.
		append(&l.outputs, e)
		wl.listen(&o.events.commit, &e.commit, layout_committed)
	}
	e.x, e.y, e.auto = x, y, auto
	layout_reconfigure(l)
	return e
}

layout_add_auto :: proc(l: ^Layout, o: ^Output) -> ^Layout_Output {
	return layout_add(l, o, 0, 0, true)
}

layout_remove :: proc(l: ^Layout, o: ^Output) {
	context.allocator = l.allocator
	for e, i in l.outputs {
		if e.output != o {continue}
		wl.unlisten(&e.commit)
		ordered_remove(&l.outputs, i)
		o.layout = nil
		free(e)
		layout_reconfigure(l)
		return
	}
}

layout_committed :: proc(listener: ^wl.Listener, data: rawptr) {
	e := cast(^Commit_Event)data
	if e.state.committed & {.Mode, .Scale, .Transform, .Enabled} != {} {
		layout_reconfigure(wl.owner(listener, Layout_Output, "commit").layout)
	}
}

layout_reconfigure :: proc(l: ^Layout) {
	x, y := min(i32), min(i32)
	for e in l.outputs {
		if e.auto || !e.output.enabled {continue}
		w, _ := effective_resolution(e.output)
		if e.x + w > x {x, y = e.x + w, e.y}
	}
	if x == min(i32) {x, y = 0, 0}
	for e in l.outputs {
		if e.auto {
			e.x, e.y = x, y
			if e.output.enabled {w, _ := effective_resolution(e.output); x += w}
		}
		if e.output.x != e.x || e.output.y != e.y {
			e.output.x, e.output.y = e.x, e.y
			update_global(e.output)
		}
	}
	wl.signal_emit_mutable(&l.events.change, l)
}

layout_box :: proc(l: ^Layout, o: ^Output = nil) -> (b: gles.Box) {
	if l == nil {return}
	found := false
	for e in l.outputs {
		if o != nil && e.output != o {continue}
		w, h := effective_resolution(e.output)
		if o != nil {return {e.x, e.y, w, h}}
		if !e.output.enabled {continue}
		if !found {
			b = {e.x, e.y, w, h}
			found = true
		} else {
			r, bot := max(b.x + b.width, e.x + w), max(b.y + b.height, e.y + h)
			b.x, b.y = min(b.x, e.x), min(b.y, e.y)
			b.width, b.height = r - b.x, bot - b.y
		}
	}
	return
}

layout_output_at :: proc(l: ^Layout, x, y: f64) -> ^Output {
	for e in l.outputs {
		if e.output.enabled && layout_contains_point(l, e.output, x, y) {return e.output}
	}
	return nil
}

layout_contains_point :: proc(l: ^Layout, o: ^Output, x, y: f64) -> bool {
	if o == nil {return layout_output_at(l, x, y) != nil}
	if !o.enabled {return false}
	b := layout_box(l, o)
	return x >= f64(b.x) && y >= f64(b.y) && x < f64(b.x + b.width) && y < f64(b.y + b.height)
}

layout_closest_point :: proc(l: ^Layout, o: ^Output, x, y: f64) -> (f64, f64) {
	cx, cy, distance := x, y, f64(1.7976931348623157e308)
	for e in l.outputs {
		if !e.output.enabled || o != nil && e.output != o {continue}
		b := layout_box(l, e.output)
		if b.width <= 0 || b.height <= 0 {continue}
		nx, ny := max(x, f64(b.x)), max(y, f64(b.y))
		if nx >= f64(b.x + b.width) {nx = f64(b.x + b.width) - 1}
		if ny >= f64(b.y + b.height) {ny = f64(b.y + b.height) - 1}
		d := (nx - x) * (nx - x) + (ny - y) * (ny - y)
		if d < distance {cx, cy, distance = nx, ny, d}
	}
	return cx, cy
}

layout_display_destroyed :: proc(l: ^wl.Listener, data: rawptr) {
	layout_destroy(wl.owner(l, Layout, "display_destroy"))
}
