package outputs

import "../buffers"
import "../gles"
import wl "../wayland"
import "base:runtime"
import "core:math"
import "core:strings"

Mode :: struct {
	width, height, refresh: i32,
	preferred:              bool,
}

Output :: struct {
	name, description, make, model, serial:         string,
	physical_width, physical_height, subpixel:      i32,
	modes:                                          [dynamic]^Mode,
	current_mode:                                   ^Mode,
	width, height, refresh:                         i32,
	scale:                                          f32,
	transform, adaptive_sync_status:                i32,
	enabled, needs_frame, frame_pending, finishing: bool,
	auto_enable, non_desktop: bool,
	commit_seq:                                     u32,
	formats:                                        []buffers.Format,
	resources:                                      wl.List,
	global:                                         ^wl.Global,
	display:                                        ^wl.Display,
	events:                                         struct {
		frame, needs_frame, commit, present, bind, description, request_state, destroy: wl.Signal,
	},
	impl:                                           ^Impl,
	data:                                           rawptr,
	allocator:                                      runtime.Allocator,
	idle_frame, idle_done:                          ^wl.Source,
	layout:                                         ^Layout,
	x, y:                                           i32,
}

Impl :: struct {
	commit:   proc(_: ^Output, _: ^State) -> bool,
	destroy:  proc(_: ^Output),
	cursor:   proc(_: ^Output, _: ^gles.Buffer, _: i32, _: i32) -> bool,
	move:     proc(_: ^Output, _: i32, _: i32) -> bool,
	schedule: proc(_: ^Output),
}

init :: proc(o: ^Output, impl: ^Impl, display: ^wl.Display, name: string) {
	o.impl, o.display, o.allocator, o.scale = impl, display, context.allocator, 1
	o.auto_enable = true
	o.name = strings.clone(name)
	wl.init(&o.resources)
	for s in ([]^wl.Signal{&o.events.frame, &o.events.needs_frame, &o.events.commit, &o.events.present, &o.events.bind, &o.events.description, &o.events.request_state, &o.events.destroy}) {wl.signal_init(s)}
	if display != nil {create_global(o)}
}

finish :: proc(o: ^Output) {
	if o == nil || o.finishing {return}
	context.allocator = o.allocator
	o.finishing = true
	if o.layout != nil {layout_remove(o.layout, o)}
	wl.remove_source(o.idle_frame)
	wl.remove_source(o.idle_done)
	o.idle_frame, o.idle_done = nil, nil
	wl.signal_emit_final(&o.events.destroy, o)
	if o.global != nil {
		wl.global_destroy(o.global)
		o.global = nil
	}
	for !wl.empty(&o.resources) {
		r := runtime.container_of(o.resources.next, wl.Resource, "link")
		wl.list_remove(&r.link)
		wl.init(&r.link)
		r.data = nil
	}
	for m in o.modes {free(m)}
	delete(o.modes)
	for f in o.formats {delete(f.modifiers)}
	delete(o.formats)
	delete(o.name)
	delete(o.description)
	delete(o.make)
	delete(o.model)
	delete(o.serial)
	if o.impl != nil && o.impl.destroy != nil {o.impl.destroy(o)}
}

set_name :: proc(o: ^Output, name: string) {
	context.allocator = o.allocator
	next := strings.clone(name)
	delete(o.name)
	o.name = next
}

set_description :: proc(o: ^Output, text: string) {
	if o.description == text {return}
	context.allocator = o.allocator
	next := strings.clone(text)
	delete(o.description)
	o.description = next
	it := wl.iterate(&o.resources)
	for link in wl.next(&it) {
		r := resource_from_link(link)
		send_description(r)
	}
	schedule_done(o)
	wl.signal_emit_mutable(&o.events.description, o)
}

set_formats :: proc(o: ^Output, formats: []buffers.Format) {
	context.allocator = o.allocator
	for f in o.formats {delete(f.modifiers)}
	delete(o.formats)
	o.formats = make([]buffers.Format, len(formats))
	for f, i in formats {
		o.formats[i] = {f.format, make([]u64, len(f.modifiers))}
		copy(o.formats[i].modifiers, f.modifiers)
	}
}

preferred_mode :: proc(o: ^Output) -> ^Mode {
	for m in o.modes {if m.preferred {return m}}
	return o.modes[0] if len(o.modes) > 0 else nil
}

transformed_resolution :: proc(o: ^Output) -> (i32, i32) {
	if o.transform % 2 == 0 {return o.width, o.height}
	return o.height, o.width
}

effective_resolution :: proc(o: ^Output) -> (i32, i32) {
	w, h := transformed_resolution(o)
	return i32(f32(w) / o.scale), i32(f32(h) / o.scale)
}

cover_size :: proc(o: ^Output) -> (i32, i32) {
	w, h := transformed_resolution(o)
	return i32(math.ceil(f64(w) / f64(o.scale))), i32(math.ceil(f64(h) / f64(o.scale)))
}
