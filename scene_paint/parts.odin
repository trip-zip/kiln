package scene_paint

import sf "../surfaces"
import sh "../shells"
import wl "../wayland"
import "base:runtime"
import "../gles"

DRAG_ICON_ID :: u32(0xffffffff)

Scene :: struct {
	renderer:                     ^gles.Renderer,
	sources:                      map[^sf.Surface]^Source,
	new_surface:                  wl.Listener,
	allocator:                    runtime.Allocator,
	outputs:                      [dynamic]^Output,
}

scene_create :: proc() -> ^Scene {
	s := new(Scene)
	s.allocator = context.allocator
	s.sources = make(map[^sf.Surface]^Source)
	return s
}

scene_destroy :: proc(s: ^Scene) {
	context.allocator = s.allocator
	wl.unlisten(&s.new_surface)
	for len(s.sources) > 0 {
		for _, source in s.sources {
			source_remove(source)
			break
		}
	}
	delete(s.sources)
	delete(s.outputs)
	free(s)
}

// Publishing compares value parts, so command order is the only stacking state.
publish :: proc(o: ^Output, parts: []Part) -> u64 {
	mutations: u64
	for i in 0 ..< max(len(o.parts), len(parts)) {
		if i < len(o.parts) && i < len(parts) && same_part(o.parts[i], parts[i]) {continue}
		if i < len(o.parts) {damage_part(o, o.parts[i])}
		if i < len(parts) {damage_part(o, parts[i])}
		mutations += 1
	}
	clear(&o.parts)
	append(&o.parts, ..parts)
	for &p in o.parts {p.coverage = coverage(p)}
	refresh_subscriptions(o)
	return mutations
}

find_client :: proc(o: ^Output, id: u32) -> (Part, bool) {
	for p in o.parts {
		if p.kind == .Client && p.id == id {return p, true}
	}
	return {}, false
}

remove_client :: proc(o: ^Output, id: u32) {
	for i := len(o.parts) - 1; i >= 0; i -= 1 {
		if o.parts[i].kind == .Client && o.parts[i].id == id {
			damage_part(o, o.parts[i])
			ordered_remove(&o.parts, i)
		}
	}
}

intersection :: proc(a, b: gles.Box) -> gles.Box {
	x, y := max(a.x, b.x), max(a.y, b.y)
	return {
		x,
		y,
		max(0, min(a.x + a.width, b.x + b.width) - x),
		max(0, min(a.y + a.height, b.y + b.height) - y),
	}
}

contains :: proc(box: gles.Box, x, y: f64) -> bool {
	return(
		x >= f64(box.x) &&
		y >= f64(box.y) &&
		x < f64(box.x + box.width) &&
		y < f64(box.y + box.height) \
	)
}

Surface_Position :: struct {
	surface: ^sf.Surface,
	x, y:    i32,
	popup:   bool,
}

collect_surface :: proc (surface: ^sf.Surface, x, y: i32, data: rawptr) {
	append((^[dynamic]Surface_Position)(data), Surface_Position{surface = surface, x = x, y = y})
}
collect_popup :: proc(surface: ^sf.Surface, x,y: i32, data: rawptr) {
	append((^[dynamic]Surface_Position)(data), Surface_Position{surface=surface,x=x,y=y})
}
current_surfaces :: proc(p: Part) -> [dynamic]Surface_Position {
	list := make([dynamic]Surface_Position, context.temp_allocator)
	if p.surface == nil || !p.surface.mapped {return list}
	sf.each(p.surface, collect_surface, &list)
	base := len(list)
	sh.popups(p.surface, collect_popup, &list)
	for &position, i in list {
		position.x += p.box.x
		position.y += p.box.y
		if p.geometry != (gles.Box{}) {
			position.x -= p.geometry.x
			position.y -= p.geometry.y
		}
		position.popup = i >= base
	}
	return list
}
// Popups form a second band, preserving their owners' command order.
Draw_Item :: struct {
	part:     Part,
	position: Surface_Position,
}

draw_order :: proc(o: ^Output) -> [dynamic]Draw_Item {
	items := make([dynamic]Draw_Item, context.temp_allocator)
	for popups in ([2]bool{false, true}) {
		for p in o.parts {
			if p.kind != .Client {
				if !popups {append(&items, Draw_Item{part = p})}
				continue
			}
			positions := current_surfaces(p)
			for v in positions {
				if v.popup == popups {append(&items, Draw_Item{p, v})}
			}
		}
	}
	return items
}

client_at :: proc(o: ^Output, x, y: f64) -> (surface: ^sf.Surface, id: u32, sx, sy: f64) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	for popups in ([2]bool{true, false}) {
		for i := len(o.parts) - 1; i >= 0; i -= 1 {
			p := o.parts[i]
			if p.kind != .Client || (p.id == 0 || p.id == DRAG_ICON_ID) {continue}
			positions := current_surfaces(p)
			for j := len(positions) - 1; j >= 0; j -= 1 {
				v := positions[j]
				if v.popup != popups || (!popups && !contains(p.box, x, y)) {continue}
				surface = sf.at(v.surface, x - f64(v.x), y - f64(v.y), &sx, &sy)
				if surface != nil {return surface, p.id, sx, sy}
			}
		}
	}
	return
}

same_part :: proc(a, b: Part) -> bool {
	x, y := a, b
	x.coverage, y.coverage = {}, {}
	return x == y
}
