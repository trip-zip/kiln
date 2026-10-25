package extensions

import out "../outputs"
import "../buffers"
import "../gbm"
import "../gles"
import p "../protocols"
import sp "../scene_paint"
import wl "../wayland"
import "core:math"
import "base:runtime"

Screencopy :: struct {
	global: ^wl.Global,
	scene: ^sp.Scene,
	frames: [dynamic]^Screencopy_Frame,
	bindings: [dynamic]^Screencopy_Binding,
	destroy: wl.Listener,
}
Screencopy_Binding :: struct { manager: ^Screencopy, refs: int, damage: [dynamic]^Screencopy_Damage }
Screencopy_Damage :: struct { binding: ^Screencopy_Binding, output: ^out.Output, box: gles.Box, destroy: wl.Listener }
Screencopy_Frame :: struct {
	manager: ^Screencopy,
	binding: ^Screencopy_Binding,
	resource: ^wl.Resource,
	output: ^out.Output,
	box: gles.Box,
	buffer: ^buffers.Buffer,
	used, done, with_damage: bool,
	destroy, commit: wl.Listener,
}

screencopy_create :: proc(display: ^wl.Display, scene: ^sp.Scene) -> ^Screencopy {
	m := new(Screencopy)
	m.scene = scene
	m.global = wl.global_create_typed(display, &p.zwlr_screencopy_manager_v1, 3, m, screencopy_request,
		screencopy_binding_destroy, screencopy_bind)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, screencopy_destroyed)
	return m
}
screencopy_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Screencopy, "destroy")
	context = m.global.display.loop.ctx
	for len(m.frames) > 0 { wl.resource_destroy(m.frames[len(m.frames)-1].resource) }
	wl.unlisten(listener)
	wl.global_destroy(m.global)
	delete(m.frames)
	delete(m.bindings)
	free(m)
}
screencopy_bind :: proc(r: ^wl.Resource) {
	b := new(Screencopy_Binding)
	b.manager, b.refs = cast(^Screencopy)r.data, 1
	append(&b.manager.bindings, b)
	r.data = b
}
screencopy_damage_destroy :: proc(d: ^Screencopy_Damage) {
	wl.unlisten(&d.destroy)
	for other, i in d.binding.damage { if other == d { ordered_remove(&d.binding.damage, i); break } }
	free(d)
}
screencopy_damage_output_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	d := wl.owner(listener, Screencopy_Damage, "destroy")
	context = d.binding.manager.global.display.loop.ctx
	screencopy_damage_destroy(d)
}
screencopy_binding_unref :: proc(b: ^Screencopy_Binding) {
	b.refs -= 1
	if b.refs != 0 { return }
	for len(b.damage) > 0 { screencopy_damage_destroy(b.damage[len(b.damage)-1]) }
	for other, i in b.manager.bindings { if other == b { ordered_remove(&b.manager.bindings, i); break } }
	delete(b.damage)
	free(b)
}
screencopy_binding_destroy :: proc(r: ^wl.Resource) { screencopy_binding_unref(cast(^Screencopy_Binding)r.data) }
screencopy_damage :: proc(b: ^Screencopy_Binding, output: ^out.Output) -> ^Screencopy_Damage {
	for d in b.damage { if d.output == output { return d } }
	d := new(Screencopy_Damage)
	d.binding, d.output, d.box = b, output, {0, 0, output.width, output.height}
	append(&b.damage, d)
	wl.listen(&output.events.destroy, &d.destroy, screencopy_damage_output_destroyed)
	return d
}
screencopy_request :: proc(r: ^wl.Resource, request: p.Zwlr_Screencopy_Manager_V1_Request, args: []wl.Argument) {
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .capture_output, .capture_output_region:
		binding := cast(^Screencopy_Binding)r.data
		m := binding.manager
		f := new(Screencopy_Frame)
		f.manager, f.binding, f.output = m, binding, output_of(wl.object(args[2]))
		f.resource = wl.resource_create_typed(r.client, &p.zwlr_screencopy_frame_v1, r.version,
			u32(args[0].(wl.New_Id)), f, screencopy_frame_request, screencopy_frame_destroy)
		if f.resource == nil { free(f); return }
		binding.refs += 1
		append(&m.frames, f)
		if f.output == nil || !f.output.enabled { screencopy_failed(f); return }
		f.box = {0, 0, f.output.width, f.output.height}
		if request == .capture_output_region {
			f.box = screencopy_region(f.output, {i32(args[3].(wl.Int)), i32(args[4].(wl.Int)),
				i32(args[5].(wl.Int)), i32(args[6].(wl.Int))})
		}
		if f.box.width <= 0 || f.box.height <= 0 { screencopy_failed(f); return }
		screencopy_damage(binding, f.output)
		wl.listen(&f.output.events.destroy, &f.destroy, screencopy_output_destroyed)
		wl.listen(&f.output.events.commit, &f.commit, screencopy_output_committed)
		wl.post(f.resource, u32(p.Zwlr_Screencopy_Frame_V1_Event.buffer), wl.Uint(0),
			wl.Uint(f.box.width), wl.Uint(f.box.height), wl.Uint(f.box.width*4))
		if r.version >= 3 { wl.post(f.resource, u32(p.Zwlr_Screencopy_Frame_V1_Event.buffer_done)) }
	}
}
screencopy_region :: proc(output: ^out.Output, box: gles.Box) -> gles.Box {
	if box.width <= 0 || box.height <= 0 || output.scale <= 0 { return {} }
	w, h := output.width, output.height
	if output.transform % 2 != 0 { w, h = h, w }
	scale := f64(output.scale)
	// Clip before narrowing so malicious coordinates cannot overflow the pixel box.
	x := i32(math.floor(clamp(f64(box.x)*scale, 0, f64(w))))
	y := i32(math.floor(clamp(f64(box.y)*scale, 0, f64(h))))
	x2 := i32(math.ceil(clamp(f64(i64(box.x)+i64(box.width))*scale, 0, f64(w))))
	y2 := i32(math.ceil(clamp(f64(i64(box.y)+i64(box.height))*scale, 0, f64(h))))
	return gles.transform_box(gles.Box{x, y, x2-x, y2-y}, gles.transform_invert(output.transform), w, h)
}
screencopy_frame_request :: proc(r: ^wl.Resource, request: p.Zwlr_Screencopy_Frame_V1_Request, args: []wl.Argument) {
	f := cast(^Screencopy_Frame)r.data
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .copy, .copy_with_damage:
		if f.done { return }
		if f.used { wl.post_error(r, u32(p.Zwlr_Screencopy_Frame_V1_Error.already_used), "frame already used"); return }
		if !f.output.enabled { screencopy_failed(f); return }
		buffer := buffer_of(wl.object(args[0]))
		if buffer == nil { wl.post_error(r, u32(p.Zwlr_Screencopy_Frame_V1_Error.invalid_buffer), "invalid buffer"); return }
		accepted := false
		defer if !accepted { buffers.unlock(buffer) }
		attrs, shm_ok := buffers.shm(buffer)
		if !shm_ok || buffer.width != f.box.width || buffer.height != f.box.height ||
		   attrs.format != gbm.ARGB8888 || attrs.stride != f.box.width*4 {
			wl.post_error(r, u32(p.Zwlr_Screencopy_Frame_V1_Error.invalid_buffer), "invalid shm buffer attributes"); return
		}
		_, format, stride, accessible := buffers.access_begin(buffer, .Write)
		if !accessible {
			wl.post_error(r, u32(p.Zwlr_Screencopy_Frame_V1_Error.invalid_buffer), "buffer is not writable"); return
		}
		buffers.access_end(buffer)
		if format != gbm.ARGB8888 || stride != int(f.box.width)*4 { wl.post_error(r, u32(p.Zwlr_Screencopy_Frame_V1_Error.invalid_buffer), "invalid buffer layout"); return }
		accepted, f.used, f.with_damage, f.buffer = true, true, request == .copy_with_damage, buffer
		o := sp.get_scene_output(f.manager.scene, f.output)
		if o != nil && o.last != nil && !f.with_damage { screencopy_copy(f, o) } else {
			out.update_needs_frame(f.output)
		}
	}
}
screencopy_release :: proc(f: ^Screencopy_Frame) {
	wl.unlisten(&f.destroy)
	wl.unlisten(&f.commit)
	f.output = nil
	if f.buffer != nil { buffers.unlock(f.buffer); f.buffer = nil }
	f.done = true
}
screencopy_failed :: proc(f: ^Screencopy_Frame) {
	if !f.done { wl.post(f.resource, u32(p.Zwlr_Screencopy_Frame_V1_Event.failed)) }
	screencopy_release(f)
}
screencopy_output_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	f := wl.owner(listener, Screencopy_Frame, "destroy")
	context = f.resource.client.display.loop.ctx
	screencopy_failed(f)
}
screencopy_output_committed :: proc (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	f := wl.owner(listener, Screencopy_Frame, "commit")
	context = f.resource.client.display.loop.ctx
	if !f.output.enabled { screencopy_failed(f) }
}
screencopy_frame_destroy :: proc(r: ^wl.Resource) {
	f := cast(^Screencopy_Frame)r.data
	screencopy_release(f)
	for other, i in f.manager.frames {
		if other == f { ordered_remove(&f.manager.frames, i); break }
	}
	screencopy_binding_unref(f.binding)
	free(f)
}
screencopy_committed :: proc(m: ^Screencopy, o: ^sp.Output, damage: []gles.Box) {
	if m == nil { return }
	for b in m.bindings {
		for d in b.damage {
			if d.output != o.handle { continue }
			for box in damage {
				if d.box.width == 0 || d.box.height == 0 { d.box = box; continue }
				x, y := min(d.box.x, box.x), min(d.box.y, box.y)
				d.box = {x, y, max(d.box.x+d.box.width, box.x+box.width)-x, max(d.box.y+d.box.height, box.y+box.height)-y}
			}
		}
	}
	for f in m.frames {
		if f.output == o.handle && f.buffer != nil {
			d := screencopy_damage(f.binding, f.output)
			if !f.with_damage || d.box.width > 0 && d.box.height > 0 { screencopy_copy(f, o) }
		}
	}
}
screencopy_copy :: proc(f: ^Screencopy_Frame, o: ^sp.Output) {
	b := o.last
	box := f.box
	if b == nil || !o.handle.enabled || box.x+box.width > b.width || box.y+box.height > b.height {
		screencopy_failed(f); return
	}
	data, format, stride, accessible := buffers.access_begin(f.buffer, .Write)
	if !accessible {
		screencopy_failed(f); return
	}
	ok := format == gbm.ARGB8888 && stride == int(box.width)*4 &&
		gles.read_region(o.renderer, b, data, u32(stride), gles.Box(box))
	buffers.access_end(f.buffer)
	if !ok { screencopy_failed(f); return }
	r := f.resource
	wl.post(r, u32(p.Zwlr_Screencopy_Frame_V1_Event.flags), wl.Uint(0))
	if f.with_damage {
		d := screencopy_damage(f.binding, f.output)
		clipped := sp.intersection(box, d.box)
		if clipped.width > 0 && clipped.height > 0 {
			wl.post(r, u32(p.Zwlr_Screencopy_Frame_V1_Event.damage), wl.Uint(clipped.x-box.x),
				wl.Uint(clipped.y-box.y), wl.Uint(clipped.width), wl.Uint(clipped.height))
		}
	}
	screencopy_damage(f.binding, f.output).box = {}
	stamp := o.committed_at
	wl.post(r, u32(p.Zwlr_Screencopy_Frame_V1_Event.ready), wl.Uint(u64(stamp.tv_sec)>>32),
		wl.Uint(stamp.tv_sec), wl.Uint(stamp.tv_nsec))
	screencopy_release(f)
}
