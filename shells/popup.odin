package shells

import p "../protocols"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

Popup_State :: struct {
	geometry: wlr.Box,
	rules:    Positioner_Rules,
}
Popup_Configure :: struct {
	serial: u32,
	state:  Popup_State,
}
Popup :: struct {
	resource:                                                           ^wl.Resource,
	base:                                                               ^Xdg_Surface,
	surface, parent:                                                    ^wlr.Surface,
	scheduled, current, pending:                                        Popup_State,
	geometry, explicit_geometry, pending_geometry:                      wlr.Box,
	geometry_changed, initialized, initial_commit, configured, grabbed: bool,
	reposition_pending:                                                 bool,
	reposition_token:                                                   u32,
	idle:                                                               ^wl.Source,
	queue:                                                              [dynamic]Popup_Configure,
	events:                                                             struct {
		destroy, reposition: wl.Signal,
	},
	parent_destroy, parent_unmap, parent_commit:                        wl.Listener,
}
popup_create :: proc(x: ^Xdg_Surface, args: []wl.Argument) {
	if x.toplevel != nil ||
	   x.popup !=
		   nil {wl.post_error(x.resource, u32(p.Xdg_Surface_Error.already_constructed), "role object already exists"); return}
	if has_buffer(
		x.surface,
	) {wl.post_error(x.resource, u32(p.Xdg_Surface_Error.unconfigured_buffer), "surface already has a buffer"); return}
	rules := (cast(^Positioner_Rules)wl.object(args[2]).data)^
	if !positioner_complete(
		rules,
	) {wl.post_error(x.owner, u32(p.Xdg_Wm_Base_Error.invalid_positioner), "positioner is incomplete"); return}
	parent: ^wlr.Surface
	if r := wl.object(args[1]); r != nil {
		px := cast(^Xdg_Surface)r.data
		if px == nil ||
		   (px.toplevel == nil && px.popup == nil) ||
		   px ==
			   x {wl.post_error(x.owner, u32(p.Xdg_Wm_Base_Error.invalid_popup_parent), "invalid popup parent"); return}
		parent = px.surface
	}
	v := new(Popup)
	v.base, v.surface = x, x.surface
	v.scheduled = {positioner_geometry(rules), rules}
	wl.signal_init(&v.events.destroy); wl.signal_init(&v.events.reposition)
	v.resource = wl.resource_create_typed(
		x.resource.client,
		&p.xdg_popup,
		x.resource.version,
		u32(args[0].(wl.New_Id)),
		v,
		popup_request,
		popup_resource_destroy,
	)
	if v.resource == nil {free(v); return}
	x.popup, x.unmapping = v, false
	if parent != nil {popup_parent(v, parent)}
	wl.signal_emit_mutable(&x.shell.events.new_popup, v)
}
popup_parent :: proc(v: ^Popup, parent: ^wlr.Surface) -> bool {
	list := popup_list(parent)
	if v.parent != nil ||
	   v.initialized ||
	   list == nil ||
	   parent.resource.client != v.resource.client {
		wl.post_error(
			v.base.owner,
			u32(p.Xdg_Wm_Base_Error.invalid_popup_parent),
			"invalid popup parent",
		); return false
	}
	v.parent = parent
	append(list, v)
	wl.listen(&parent.events.destroy, &v.parent_destroy, popup_parent_gone)
	wl.listen(&parent.events.unmap, &v.parent_unmap, popup_parent_unmapped)
	wl.listen(&parent.events.commit, &v.parent_commit, popup_parent_committed)
	return true
}
popup_parent_gone :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	v := wl.owner(listener, Popup, "parent_destroy")
	context = v.resource.client.display.loop.ctx
	popup_dismiss(v)
}
popup_parent_unmapped :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	v := wl.owner(listener, Popup, "parent_unmap")
	context = v.resource.client.display.loop.ctx
	popup_dismiss(v)
}
popup_parent_committed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	v := wl.owner(listener, Popup, "parent_commit")
	context = v.resource.client.display.loop.ctx
	if v.scheduled.rules.reactive {wl.signal_emit_mutable(&v.events.reposition, v)}
}
popup_window_geometry :: proc(v: ^Popup, args: []wl.Argument) {
	box := wlr.Box {
		i32(args[0].(wl.Int)),
		i32(args[1].(wl.Int)),
		i32(args[2].(wl.Int)),
		i32(args[3].(wl.Int)),
	}
	if box.width <= 0 ||
	   box.height <=
		   0 {wl.post_error(v.base.resource, u32(p.Xdg_Surface_Error.invalid_size), "geometry must have positive size"); return}
	v.pending_geometry, v.geometry_changed = box, true
}
popup_geometry :: proc(v: ^Popup) {
	if v.geometry_changed {v.explicit_geometry = v.pending_geometry; v.geometry_changed = false}
	extents, box := surface_extents(v.surface), v.explicit_geometry
	v.geometry = extents
	if box.width > 0 {
		x, y := max(extents.x, box.x), max(extents.y, box.y)
		v.geometry = {
			x,
			y,
			max(0, min(extents.x + extents.width, box.x + box.width) - x),
			max(0, min(extents.y + extents.height, box.y + box.height) - y),
		}
	}
}
popup_validate :: proc(v: ^Popup) {
	if v.parent ==
	   nil {wl.post_error(v.base.resource, u32(p.Xdg_Surface_Error.not_constructed), "popup has no parent"); return}
	if has_pending_buffer(v.surface) &&
	   !v.configured {wl.post_error(v.base.resource, u32(p.Xdg_Surface_Error.unconfigured_buffer), "initial configure has not been acknowledged")}
}
popup_commit :: proc(v: ^Popup) {
	if v.resource.client.failed {return}
	if v.base.unmapping {v.base.unmapping = false; return}
	buffer := has_buffer(v.surface)
	if buffer && (!v.configured || v.parent == nil || !v.parent.mapped) {
		wl.post_error(
			v.base.owner,
			u32(p.Xdg_Wm_Base_Error.invalid_popup_parent),
			"popup parent is not mapped",
		); return
	}
	v.initial_commit, v.initialized = !v.initialized, true
	v.current = v.pending
	if !v.surface.mapped && buffer {map_surface(v.surface)} else {popup_geometry(v)}
	if v.initial_commit {popup_schedule_configure(v)}
}
popup_ack :: proc(v: ^Popup, serial: u32) {
	for c, i in v.queue {
		if c.serial != serial {continue}
		v.pending, v.configured = c.state, true
		for _ in 0 ..= i {ordered_remove(&v.queue, 0)}
		return
	}
	wl.post_error(
		v.base.resource,
		u32(p.Xdg_Surface_Error.invalid_serial),
		"unknown configure serial",
	)
}
popup_schedule_configure :: proc(v: ^Popup) -> u32 {
	if !v.initialized {return 0}
	if v.idle == nil {
		v.base.serial += 1
		if v.base.serial == 0 {v.base.serial = 1}
		v.idle = wl.on_idle(v.resource.client.display, popup_configure, v)
	}
	return v.base.serial
}
popup_configure :: proc(data: rawptr) {
	v := cast(^Popup)data
	v.idle = nil
	if v.reposition_pending {wl.post(v.resource, u32(p.Xdg_Popup_Event.repositioned), wl.Uint(v.reposition_token)); v.reposition_pending = false}
	box := v.scheduled.geometry
	wl.post(
		v.resource,
		u32(p.Xdg_Popup_Event.configure),
		wl.Int(box.x),
		wl.Int(box.y),
		wl.Int(box.width),
		wl.Int(box.height),
	)
	append(&v.queue, Popup_Configure{v.base.serial, v.scheduled})
	wl.post(v.base.resource, u32(p.Xdg_Surface_Event.configure), wl.Uint(v.base.serial))
}
popup_request :: proc(r: ^wl.Resource, request: p.Xdg_Popup_Request, args: []wl.Argument) {
	v := cast(^Popup)r.data
	if v == nil {if request == .destroy {wl.resource_destroy(r)}; return}
	switch request {
	case .destroy:
		if len(v.base.popups) !=
		   0 {wl.post_error(v.base.owner, u32(p.Xdg_Wm_Base_Error.not_the_topmost_popup), "popup still has children"); return}
		wl.resource_destroy(r)
	case .grab:
		popup_grab(v, wl.object(args[0]), u32(args[1].(wl.Uint)))
	case .reposition:
		rules := (cast(^Positioner_Rules)wl.object(args[0]).data)^
		if !positioner_complete(
			rules,
		) {wl.post_error(v.base.owner, u32(p.Xdg_Wm_Base_Error.invalid_positioner), "positioner is incomplete"); return}
		v.scheduled = {positioner_geometry(rules), rules}
		v.reposition_pending, v.reposition_token = true, u32(args[1].(wl.Uint))
		popup_schedule_configure(v)
		wl.signal_emit_mutable(&v.events.reposition, v)
	}
}
popup_reset :: proc(v: ^Popup) {
	if v.idle != nil {wl.source_remove(v.idle); v.idle = nil}
	clear(&v.queue)
	v.initialized, v.initial_commit, v.configured = false, false, false
	grab_remove(v)
}
popup_retire :: proc(v: ^Popup) {
	dismiss_children(v.surface)
	unmap_surface(v.surface)
	popup_reset(v)
	wl.unlisten(&v.parent_destroy); wl.unlisten(&v.parent_unmap); wl.unlisten(&v.parent_commit)
	if list := popup_list(v.parent);
	   list != nil {for other, i in list^ {if other == v {ordered_remove(list, i); break}}}
	wl.signal_emit_final(&v.events.destroy, v)
	v.base.popup, v.resource.data = nil, nil
	delete(v.queue)
	free(v)
}
popup_resource_destroy :: proc(r: ^wl.Resource) {if v := cast(^Popup)r.data;
	   v != nil {popup_retire(v)}}
popup_dismiss :: proc(v: ^Popup) {
	dismiss_children(v.surface)
	wl.post(v.resource, u32(p.Xdg_Popup_Event.popup_done))
	popup_retire(v)
}
dismiss_children :: proc(surface: ^wlr.Surface) {
	if list := popup_list(surface);
	   list != nil {for len(list^) > 0 {popup_dismiss(list^[len(list^) - 1])}}
}
get_toplevel_coords :: proc(v: ^Popup, x, y: i32) -> (i32, i32) {
	parent := v.parent
	tx, ty := x, y
	for parent != nil {
		xdg := xdg_of(parent)
		if xdg == nil {break}
		if xdg.popup !=
		   nil {tx += xdg.popup.current.geometry.x; ty += xdg.popup.current.geometry.y; parent = xdg.popup.parent} else {if xdg.toplevel != nil {tx += xdg.toplevel.geometry.x; ty += xdg.toplevel.geometry.y}; break}
	}
	return tx, ty
}
unconstrain_from_box :: proc(v: ^Popup, bounds: wlr.Box) {
	x, y := get_toplevel_coords(v, 0, 0)
	constraint := bounds; constraint.x -= x; constraint.y -= y
	v.scheduled.geometry = positioner_unconstrain(v.scheduled.rules, constraint)
	popup_schedule_configure(v)
}
// Buffer commits must not schedule unchanged geometry and create a configure feedback loop.
popup_constrain :: proc(v: ^Popup, bounds: wlr.Box, force: bool) {
	x, y := get_toplevel_coords(v, 0, 0)
	constraint := bounds; constraint.x -= x; constraint.y -= y
	geometry := positioner_unconstrain(v.scheduled.rules, constraint)
	if force || geometry != v.scheduled.geometry {unconstrain_from_box(v, bounds)}
}
Surface_Iterator :: #type proc(_: ^wlr.Surface, _: i32, _: i32, _: rawptr)
popups :: proc(
	surface: ^wlr.Surface,
	iterator: Surface_Iterator,
	data: rawptr,
	x := i32(0),
	y := i32(0),
) {
	list := popup_list(surface)
	if list == nil {return}
	origin := window_geometry(surface)
	for v in list^ {
		if !v.surface.mapped {continue}
		px, py :=
			x +
			origin.x +
			v.current.geometry.x -
			v.geometry.x,
			y +
			origin.y +
			v.current.geometry.y -
			v.geometry.y
		surface_tree(v.surface, px, py, iterator, data)
		popups(v.surface, iterator, data, px, py)
	}
}
grab_client :: proc(s: ^Shell) -> ^wl.Client {return(
		s.grab_seat.client if s != nil && s.grab_seat != nil else nil \
	)}
grab_surface :: proc(s: ^Shell) -> ^wlr.Surface {return(
		s.grab_chain[0].surface if s != nil && len(s.grab_chain) > 0 else nil \
	)}
popup_grab :: proc(v: ^Popup, seat_resource: ^wl.Resource, serial: u32) {
	s := v.base.shell
	parent := xdg_of(v.parent)
	if v.surface.mapped ||
	   v.grabbed ||
	   v.parent == nil ||
	   (len(s.grab_chain) > 0 && v.parent != s.grab_chain[0].surface) ||
	   (len(s.grab_chain) == 0 && parent != nil && parent.popup != nil) {
		wl.post_error(
			v.resource,
			u32(p.Xdg_Popup_Error.invalid_grab),
			"popup is not the newest grab child",
		); return
	}
	seat := seat_client_of(seat_resource)
	if seat == nil || !valid_grab_serial(seat, serial) {popup_dismiss(v); return}
	if s.grab_seat != nil &&
	   s.grab_seat !=
		   seat {wl.post_error(v.resource, u32(p.Xdg_Popup_Error.invalid_grab), "popup belongs to another grab"); return}
	if s.grab_seat ==
	   nil {s.grab_seat = seat; wl.listen(&seat.events.destroy, &s.grab_destroy, grab_seat_destroyed)}
	append(&s.grab_chain, v)
	for i := len(s.grab_chain) - 1; i > 0; i -= 1 {s.grab_chain[i] = s.grab_chain[i - 1]}
	s.grab_chain[0], v.grabbed = v, true
	wl.signal_emit_mutable(&s.events.grab_changed, s)
}
grab_remove :: proc(v: ^Popup) {
	if !v.grabbed {return}
	s := v.base.shell
	v.grabbed = false
	for other, i in s.grab_chain {if other == v {ordered_remove(&s.grab_chain, i); break}}
	if len(s.grab_chain) == 0 {wl.unlisten(&s.grab_destroy); s.grab_seat = nil}
	if !s.dismissing {wl.signal_emit_mutable(&s.events.grab_changed, s)}
}
grab_dismiss :: proc(s: ^Shell) {
	if s == nil || s.dismissing || len(s.grab_chain) == 0 {return}
	s.dismissing = true
	for len(s.grab_chain) > 0 {popup_dismiss(s.grab_chain[0])}
	s.dismissing = false
	wl.signal_emit_mutable(&s.events.grab_changed, s)
}
grab_seat_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	s := wl.owner(listener, Shell, "grab_destroy")
	context = s.global.display.loop.ctx
	grab_dismiss(s)
}
