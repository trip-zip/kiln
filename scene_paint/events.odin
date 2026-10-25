package scene_paint

import sf "../surfaces"

import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

// These are native event subscriptions only: placement always comes from the part list.
Surface_Events :: struct {
	output:                       ^Output,
	surface:                      ^sf.Surface,
	id:                           u32,
	commit, map_, unmap, destroy: wl.Listener,
	needed, entered, visible:     bool,
}

Subscription_Context :: struct {
	output: ^Output,
	id:     u32,
}

subscribe :: proc (surface: ^sf.Surface, x, y: i32, data: rawptr) {
	args := (^Subscription_Context)(data)
	o := args.output
	context.allocator = o.scene.allocator
	for e in o.subscriptions {
		if e.surface == surface {
			e.needed = true
			e.id = args.id
			return
		}
	}
	e := new(Surface_Events)
	e.output, e.surface, e.needed = o, surface, true
	e.id = args.id
	append(&o.subscriptions, e)
	wl.listen(&surface.events.commit, &e.commit, surface_changed)
	wl.listen(&surface.events.map_, &e.map_, surface_mapped)
	wl.listen(&surface.events.unmap, &e.unmap, surface_unmapped)
	wl.listen(&surface.events.destroy, &e.destroy, surface_destroyed)
}

refresh_subscriptions :: proc(o: ^Output) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if o.scene == nil {return}
	for e in o.subscriptions {e.needed = false}
	for p in o.parts {
		if p.kind != .Client || p.surface == nil {continue}
		args := Subscription_Context{o, p.id}
		sf.known(p.surface, subscribe, &args)
		positions := current_surfaces(p)
		for v in positions {
			if v.popup {sf.known(v.surface, subscribe, &args)}
		}
	}
	if o.cursor.surface != nil {
		args := Subscription_Context{o, 0}
		subscribe(o.cursor.surface, 0, 0, &args)
	}
	for i := len(o.subscriptions) - 1; i >= 0; i -= 1 {
		if !o.subscriptions[i].needed {unsubscribe(o.subscriptions[i])}
	}
}

surface_visibility :: proc(e: ^Surface_Events, visible: bool) {
	if e.entered == visible {return}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	e.entered = visible
	if visible {
		sf.enter(e.surface, e.output.handle)
	} else {
		sf.leave(e.surface, e.output.handle)
	}
	outputs := make([dynamic]^wlr.wlr_output, context.temp_allocator)
	for o in e.output.scene.outputs {
		for other in o.subscriptions {
			if other.surface == e.surface && other.entered {append(&outputs, o.handle)}
		}
	}
	sf.density(e.surface, outputs[:])
}

unsubscribe :: proc(e: ^Surface_Events) {
	context.allocator = e.output.scene.allocator
	surface_visibility(e, false)
	wl.unlisten(&e.commit)
	wl.unlisten(&e.map_)
	wl.unlisten(&e.unmap)
	wl.unlisten(&e.destroy)
	for other, i in e.output.subscriptions {
		if other == e {
			ordered_remove(&e.output.subscriptions, i)
			break
		}
	}
	free(e)
}

changed_surface :: proc(e: ^Surface_Events) {
	o := e.output
	context.allocator = o.scene.allocator
	if o.cursor.surface == e.surface {
		damage_box(o, o.cursor.device_box)
		return
	}
	// Old popup coverage belongs to its containing part, even after an unmap.
	for &p in o.parts {
		if p.kind != .Client || p.id != e.id {continue}
		damage_part(o, p)
		p.coverage = coverage(p)
	}
	refresh_subscriptions(o)
}

surface_changed :: proc (listener: ^wl.Listener, data: rawptr) {
	e := wl.owner(listener, Surface_Events, "commit")
	changed_surface(e)
}

surface_mapped :: proc (listener: ^wl.Listener, data: rawptr) {
	changed_surface(wl.owner(listener, Surface_Events, "map_"))
}

surface_unmapped :: proc (listener: ^wl.Listener, data: rawptr) {
	changed_surface(wl.owner(listener, Surface_Events, "unmap"))
}

surface_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	e := wl.owner(listener, Surface_Events, "destroy")
	o := e.output
	context.allocator = o.scene.allocator
	for i := len(o.parts) - 1; i >= 0; i -= 1 {
		p := o.parts[i]
		if p.kind != .Client || p.id != e.id {continue}
		damage_box(o, output_box(o, p.coverage))
		if p.surface == e.surface {ordered_remove(&o.parts, i)}
	}
	unsubscribe(e)
}
