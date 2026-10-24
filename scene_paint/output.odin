package scene_paint

import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "../gles"

Output :: struct {
	scene:                    ^Scene,
	handle:                   ^wlr.wlr_output,
	renderer:                 ^gles.Renderer,
	layout:                   ^wlr.wlr_output_layout,
	parts:                    [dynamic]Part,
	damage:                   [dynamic]wlr.Box,
	history:                  [dynamic]^Buffer_History,
	last:                     ^wlr.Render_Buffer,
	committed_at:             posix.timespec,
	committed:                proc(^Output, []wlr.Box),
	commit:                   wl.Listener,
	gamma:                    gles.Gamma,
	swapchain:                gles.Swapchain,
	cursor:                   Cursor,
	bounds:                   wlr.Box,
	width, height, transform: i32,
	scale:                    f32,
	needs_frame:              wl.Listener,
	subscriptions:            [dynamic]^Surface_Events,
	passes:                   u64,
	trace:                    bool,
}

output_init :: proc(
	o: ^Output,
	scene: ^Scene,
	handle: ^wlr.wlr_output,
	renderer: ^gles.Renderer,
	layout: ^wlr.wlr_output_layout,
) {
	o.scene, o.handle, o.renderer, o.layout = scene, handle, renderer, layout
	o.trace = os.get_env("KILN_PAINT_DEBUG", context.temp_allocator) == "1"
	append(&scene.outputs, o)
	wl.listen(&handle.events.needs_frame, &o.needs_frame, output_needed)
	wl.listen(&handle.events.commit, &o.commit, output_committed)
	output_sync(o)
}

get_scene_output :: proc(scene: ^Scene, handle: ^wlr.wlr_output) -> ^Output {
	for o in scene.outputs {
		if o.handle == handle {return o}
	}
	return nil
}

output_finish :: proc(o: ^Output) {
	gles.gamma_finish(&o.gamma)
	cursor_finish(o)
	for len(o.subscriptions) > 0 {unsubscribe(o.subscriptions[len(o.subscriptions) - 1])}
	delete(o.subscriptions)
	wl.unlisten(&o.needs_frame)
	wl.unlisten(&o.commit)
	if o.last != nil {wlr.buffer_release(o.last)}
	gles.swapchain_finish(&o.swapchain)
	delete(o.parts)
	delete(o.damage)
	for len(o.history) > 0 {history_remove(o.history[len(o.history) - 1])}
	delete(o.history)
	if o.scene != nil {
		for other, i in o.scene.outputs {
			if other == o {
				ordered_remove(&o.scene.outputs, i)
				break
			}
		}
	}
}

output_committed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	o := wl.owner(listener, Output, "commit")
	e := cast(^wlr.wlr_output_event_commit)data
	if e.state.committed & wlr.WLR_OUTPUT_STATE_BUFFER != 0 {
		previous := o.last
		o.last = wlr.buffer_retain(e.state.buffer)
		if previous != nil { wlr.buffer_release(previous) }
		o.committed_at = e.when_
	}
}

output_needed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	wlr.wlr_output_schedule_frame(wl.owner(listener, Output, "needs_frame").handle)
}

output_invalidate :: proc(o: ^Output) {
	if o == nil {return}
	damage_box(o, {0, 0, o.width, o.height})
}

damage_box :: proc(o: ^Output, box: wlr.Box) {
	if box.width <= 0 || box.height <= 0 {return}
	append(&o.damage, box)
	if o.handle != nil && o.handle.enabled {wlr.wlr_output_schedule_frame(o.handle)}
}

output_sync :: proc(o: ^Output) {
	b: wlr.Box
	wlr.wlr_output_layout_get_box(o.layout, o.handle, &b)
	h := o.handle
	if o.bounds != b || o.width != h.width || o.height != h.height || o.scale != h.scale ||
	   o.transform != h.transform {
		o.bounds = b
		o.width, o.height, o.scale, o.transform = h.width, h.height, h.scale, h.transform
		output_invalidate(o)
	}
}

output_box :: proc(o: ^Output, box: wlr.Box) -> wlr.Box {
	b := wlr.Box {
		device_edge(box.x, o.scale),
		device_edge(box.y, o.scale),
		device_span(box.x, box.width, o.scale),
		device_span(box.y, box.height, o.scale),
	}
	tw, th := o.width, o.height
	if o.transform % 2 != 0 {tw, th = th, tw}
	return gles.transform_box(b, gles.transform_invert(o.transform), tw, th)
}

coverage :: proc(p: Part) -> wlr.Box {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	box := p.box
	if p.kind != .Client {return box}
	positions := current_surfaces(p)
	for v in positions {
		if !v.popup {continue}
		x, y := min(box.x, v.x), min(box.y, v.y)
		r := max(box.x + box.width, v.x + v.surface.current.width)
		b := max(box.y + box.height, v.y + v.surface.current.height)
		box = {x, y, r - x, b - y}
	}
	return box
}

damage_part :: proc(o: ^Output, p: Part) {
	damage_box(o, output_box(o, p.coverage))
	damage_box(o, output_box(o, coverage(p)))
}

client_damage :: proc(o: ^Output, id: u32, geometry: ^wlr.Box = nil) {
	if o == nil {return}
	for &p in o.parts {
		if p.kind == .Client && p.id == id {
			damage_part(o, p)
			if geometry != nil && p.geometry != geometry^ { p.geometry = geometry^; damage_part(o, p) }
			p.coverage = coverage(p)
		}
	}
}

draw_texture :: proc(
	o: ^Output,
	pass: ^gles.Pass,
	texture: ^gles.Texture,
	source: wlr.wlr_fbox,
	box, clip: wlr.Box,
	transform: i32,
	repaint: []wlr.Box,
) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	boxes := make([dynamic]wlr.Box, context.temp_allocator)
	for damage in repaint {
		b := intersection(damage, clip)
		if b.width > 0 && b.height > 0 {append(&boxes, b)}
	}
	if len(boxes) == 0 {return true}
	gles.texture(pass, texture, source, box, boxes[:], transform)
	return true
}

draw_parts :: proc(
	o: ^Output,
	pass: ^gles.Pass,
	repaint: []wlr.Box,
	drawn: ^[dynamic]^wlr.Surface,
) -> bool {
	transform := gles.transform_invert(o.transform)
	items := draw_order(o)
	for item in items {
		p := item.part
		if p.kind == .Solid {
			gles.rect(pass, output_box(o, p.box), p.color, repaint)
		} else if p.kind == .Raster {
			b := p.pixels
			if b.texture == nil {b.texture = gles.import_buffer(o.renderer, &b.base)}
			if b.texture == nil {return false}
			gles.texture(pass, b.texture, p.source, output_box(o, p.box), repaint, transform)
		} else {
			v := item.position
			texture := surface_texture(o, v.surface)
			if texture == nil {continue}
			box := output_box(o, {v.x, v.y, v.surface.current.width, v.surface.current.height})
			visible := box
			if !v.popup {visible = intersection(box, output_box(o, p.box))}
			visible = intersection(visible, {0, 0, o.width, o.height})
			if visible.width <= 0 || visible.height <= 0 {continue}
			for e in o.subscriptions {
				if e.surface == v.surface {e.visible = true}
			}
			painted := false
			for damage in repaint {
				b := intersection(damage, visible)
				if b.width > 0 && b.height > 0 {
					painted = true
					break
				}
			}
			if !painted {continue}
			t := gles.transform_compose(
				gles.transform_invert(v.surface.current.transform),
				transform,
			)
			if !draw_texture( o, pass, texture, wlr.surface_source(v.surface), box, visible, t, repaint, ) {
				return false
			}
			append(drawn, v.surface)
		}
	}
	return true
}

output_commit :: proc(o: ^Output) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	context.allocator = o.scene.allocator
	output_sync(o)
	if len(o.damage) == 0 && !o.handle.needs_frame {return true}
	state: wlr.wlr_output_state
	wlr.wlr_output_state_init(&state)
	defer wlr.wlr_output_state_finish(&state)
	if len(o.damage) == 0 && o.last != nil {
		wlr.output_buffer(&state, o.last)
		if !commit_target(o, &state) { return false }
		if o.committed != nil { o.committed(o, nil) }
		return true
	}
	buffer := acquire_target(o, o.width, o.height)
	if buffer == nil {return false}
	defer wlr.buffer_release(buffer)
	history_prune(o)
	history := history_acquire(o, buffer)
	pending := history_repaint(history)
	repaint := repaint_union(pending[:], {0, 0, o.width, o.height})
	pass, begun := gles.begin(target_buffer(buffer), o.gamma)
	if !begun {return false}
	for box in repaint {gles.clear(&pass, box)}
	drawn_surfaces := make([dynamic]^wlr.Surface, context.temp_allocator)
	for e in o.subscriptions {e.visible = false}
	drawn := draw_parts(o, &pass, repaint[:], &drawn_surfaces)
	cursor_drawn := draw_cursor(o, &pass, repaint[:], &drawn_surfaces)
	submitted := gles.submit(&pass)
	o.passes += 1
	if o.trace {fmt.printf("Render %s: pass %d damage %v repaint %v\n", o.handle.name, o.passes, o.damage[:], repaint[:])}
	if !drawn || !cursor_drawn || !submitted {
		output_invalidate(o)
		return false
	}
	wlr.output_buffer(&state, buffer)
	if !commit_target(o, &state) {
		output_invalidate(o)
		return false
	}
	if o.committed != nil { o.committed(o, repaint[:]) }
	history_presented(history)
	clear(&o.damage)
	for e in o.subscriptions {surface_visibility(e, e.visible)}

	now: posix.timespec
	posix.clock_gettime(.MONOTONIC, &now)
	for surface in drawn_surfaces {wlr.surface_frame_done(surface, &now)}
	return true
}

set_gamma :: proc(s: ^Scene, output: ^wlr.wlr_output, table: []u16) -> bool {
	o := get_scene_output(s, output)
	if o == nil { return false }
	if !gles.gamma_update(o.renderer, &o.gamma, table) { return false }
	output_invalidate(o)
	return true
}
