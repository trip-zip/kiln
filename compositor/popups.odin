package compositor

import sh "../shells"
import sp "../scene_paint"

import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

Popup :: struct {
	allocator:                                runtime.Allocator,
	server:                                   ^Server,
	handle:                                   ^sh.Popup,
	root:                                     u32,
	mapped:                                   bool,
	last_x, last_y:                           i32,
	commit, destroy, reposition, map_, unmap: wl.Listener,
}
root_placement :: proc(s: ^Server, id: u32) -> (sp.Part, ^Output, i32, i32) {
	for v in s.views {
		if v.id == id && v.mapped && v.output != nil && xdg(v) != nil {
			if p, ok := sp.find_client(&v.output.paint, id); ok {
				return p, v.output, xdg(v).geometry.x, xdg(v).geometry.y
			}
		}
	}
	if l := find_layer(s, id); l != nil && l.mapped && l.output != nil {
		if p, ok := sp.find_client(&l.output.paint, id); ok {return p, l.output, 0, 0}
	}
	return {}, nil, 0, 0
}
popup_visible :: proc(p: ^Popup) -> bool {
	_, output, _, _ := root_placement(p.server, p.root)
	return output != nil && output.handle.enabled
}
popup_dirty :: proc(p: ^Popup) {
	_, output, _, _ := root_placement(p.server, p.root)
	if output != nil {sp.client_damage(&output.paint, p.root)}
	dirty(output)
}
popup_attach :: proc(p: ^Popup) {
	if p.root != 0 || p.handle.parent == nil {return}
	s := p.server
	for v in s.views {
		if xdg(v) != nil && view_surface(v) == p.handle.parent {p.root = v.id
			return}
	}
	for l in s.layers {if l.handle.surface == p.handle.parent {p.root = l.id
			return}}
	for other in s.popups {
		if other != p && other.handle.surface == p.handle.parent {p.root = other.root
			return}
	}
}
popup_register :: proc(s: ^Server, handle: ^sh.Popup) {
	for p in s.popups {if p.handle == handle {popup_attach(p)
			return}}
	p := new(Popup)
	p.allocator = context.allocator
	p.server = s
	p.handle = handle
	append(&s.popups, p)
	popup_attach(p)
	wl.listen(&handle.surface.events.commit, &p.commit, popup_commit)
	wl.listen(&handle.surface.events.map_, &p.map_, popup_map)
	wl.listen(&handle.surface.events.unmap, &p.unmap, popup_unmap)
	wl.listen(&handle.events.destroy, &p.destroy, popup_destroy)
	wl.listen(&handle.events.reposition, &p.reposition, popup_reposition)
}
popup_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	popup_register(wl.owner(listener, Server, "new_popup"), (^sh.Popup)(data))
}
popup_constrain :: proc(p: ^Popup, force := false) -> bool {
	part, output, gx, gy := root_placement(p.server, p.root)
	if output == nil || p.handle.parent == nil {return false}
	x, y := output.x + part.box.x, output.y + part.box.y
	box: wlr.wlr_box
	wlr.wlr_output_layout_get_box(p.server.layout, output.handle, &box)
	// The xdg scene root is the geometry origin; the helper consumes surface coordinates.
	box.x -= x - gx
	box.y -= y - gy
	sh.popup_constrain(p.handle, box, force)
	return true
}
popup_commit :: proc (listener: ^wl.Listener, data: rawptr) {
	p := wl.owner(listener, Popup, "commit")
	_, o, _, _ := root_placement(p.server, p.root)
	if o != nil {sp.client_damage(&o.paint, p.root)}
	if p.mapped &&
	   (p.handle.current.geometry.x != p.last_x || p.handle.current.geometry.y != p.last_y) {
		p.last_x, p.last_y = p.handle.current.geometry.x, p.handle.current.geometry.y
		popup_dirty(p)
	}
	if p.handle.initial_commit {
		popup_attach(p)
		if !popup_constrain(p, true) {sh.popup_schedule_configure(p.handle)}
	}
}
popup_reposition :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	popup_constrain(wl.owner(listener, Popup, "reposition"))
}
popup_map :: proc (listener: ^wl.Listener, data: rawptr) {
	p := wl.owner(listener, Popup, "map_")
	p.mapped = true
	popup_dirty(p)
}
popup_unmap :: proc (listener: ^wl.Listener, data: rawptr) {
	p := wl.owner(listener, Popup, "unmap")
	p.mapped = false
	popup_dirty(p)
	pointer_target_refresh(p.server)
}
popup_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	p := wl.owner(listener, Popup, "destroy")
	context.allocator = p.allocator
	popup_dirty(p)
	wl.unlisten(&p.commit)
	wl.unlisten(&p.destroy)
	wl.unlisten(&p.reposition)
	wl.unlisten(&p.map_)
	wl.unlisten(&p.unmap)
	for other, i in p.server.popups {if other == p {ordered_remove(&p.server.popups, i)
			break}}
	free(p)
}
refresh_popups :: proc(output: ^Output) {
	for p in output.server.popups {
		_, owner, _, _ := root_placement(output.server, p.root)
		if owner == output && p.handle.initialized {popup_constrain(p)}
	}
}
