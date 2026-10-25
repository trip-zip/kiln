package seat

import sf "../surfaces"

import wl "../wayland"
import p "../protocols"
import rg "../region"
import "core:math"

Constraint_Manager :: struct {
	global: ^wl.Global,
	constraints: [dynamic]^Constraint,
	bindings: [dynamic]^wl.Resource,
	events: struct { new_constraint: wl.Signal },
	destroy: wl.Listener,
}
Constraint_State :: struct {
	region: []rg.Box,
	explicit_region: bool,
	cursor_hint: struct { enabled: bool, x, y: f64 },
}
Constraint :: struct {
	manager: ^Constraint_Manager,
	resource: ^wl.Resource,
	seat: ^Seat,
	surface: ^sf.Surface,
	type: i32,
	lifetime: u32,
	active, defunct, region_pending, hint_pending: bool,
	current, pending: Constraint_State,
	region: [dynamic]rg.Box,
	events: struct { set_region, destroy: wl.Signal },
	commit, surface_destroy, seat_destroy: wl.Listener,
}
constraints_create :: proc(display: ^wl.Display) -> ^Constraint_Manager {
	m := new(Constraint_Manager)
	wl.signal_init(&m.events.new_constraint)
	m.global = wl.global_create_typed(display, &p.zwp_pointer_constraints_v1, 1, m, constraints_request, constraints_binding_destroy, constraints_bind)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, constraints_destroy)
	return m
}
constraints_bind :: proc(r: ^wl.Resource) { append(&(cast(^Constraint_Manager)r.data).bindings, r) }
constraints_binding_destroy :: proc(r: ^wl.Resource) { remove_resource(&(cast(^Constraint_Manager)r.data).bindings, r) }
constraints_destroy :: proc(l: ^wl.Listener, data: rawptr) {
	m := wl.owner(l, Constraint_Manager, "destroy")
	wl.unlisten(l)
	for len(m.constraints)>0 { wl.resource_destroy(m.constraints[len(m.constraints)-1].resource) }
	for len(m.bindings)>0 { wl.resource_destroy(m.bindings[len(m.bindings)-1]) }
	wl.global_destroy(m.global); delete(m.constraints); delete(m.bindings); free(m)
}
constraint_for :: proc(m: ^Constraint_Manager, surface: ^sf.Surface, s: ^Seat) -> ^Constraint {
	if m != nil { for c in m.constraints { if !c.defunct && c.surface == surface && c.seat == s { return c } } }
	return nil
}
constraints_request :: proc(r: ^wl.Resource, request: p.Zwp_Pointer_Constraints_V1_Request, args: []wl.Argument) {
	if request == .destroy { wl.resource_destroy(r); return }
	m := cast(^Constraint_Manager)r.data
	surface, client := surface_of(wl.object(args[1])), pointer_client_of(wl.object(args[2]))
	if client != nil && constraint_for(m, surface, client.seat) != nil {
		wl.post_error(r, u32(p.Zwp_Pointer_Constraints_V1_Error.already_constrained), "surface already has a constraint for this seat"); return
	}
	lifetime := u32(args[4].(wl.Uint))
	if lifetime != 1 && lifetime != 2 { wl.post_error(r, 0, "invalid constraint lifetime"); return }
	c := new(Constraint); c.manager, c.surface, c.lifetime = m, surface, lifetime
	wl.signal_init(&c.events.set_region); wl.signal_init(&c.events.destroy)
	id := u32(args[0].(wl.New_Id))
	if request == .lock_pointer { c.resource = wl.resource_create_typed(r.client, &p.zwp_locked_pointer_v1, 1, id, c, locked_request, constraint_resource_destroy) }
	else { c.type = 1; c.resource = wl.resource_create_typed(r.client, &p.zwp_confined_pointer_v1, 1, id, c, confined_request, constraint_resource_destroy) }
	if c.resource == nil { free(c); return }
	append(&m.constraints, c)
	if client == nil { c.defunct, c.surface = true, nil; return }
	c.seat = client.seat
	region := wl.object(args[3]); c.current.explicit_region = region != nil
	if region != nil { c.current.region = region_copy(region) }
	surface_watch(surface, &c.surface_destroy, constraint_surface_destroy)
	surface_watch_commit(surface, &c.commit, constraint_committed)
	wl.listen(&c.seat.events.destroy, &c.seat_destroy, constraint_seat_destroy)
	constraint_update_region(c)
	wl.signal_emit_mutable(&m.events.new_constraint, c)
}
constraint_retire :: proc(c: ^Constraint) {
	if c.defunct { return }
	c.defunct, c.active = true, false
	wl.unlisten(&c.commit); wl.unlisten(&c.surface_destroy); wl.unlisten(&c.seat_destroy)
	wl.signal_emit_final(&c.events.destroy, c)
	c.surface, c.seat = nil, nil
}
constraint_resource_destroy :: proc(r: ^wl.Resource) {
	c := cast(^Constraint)r.data
	constraint_retire(c)
	for other, i in c.manager.constraints { if other == c { ordered_remove(&c.manager.constraints,i); break } }
	delete(c.current.region); delete(c.pending.region); delete(c.region); free(c)
}
constraint_seat_destroy :: proc(l: ^wl.Listener, data: rawptr) { constraint_retire(wl.owner(l, Constraint, "seat_destroy")) }
constraint_surface_destroy :: proc (l: ^wl.Listener, data: rawptr) {
	c := wl.owner(l, Constraint, "surface_destroy"); context = c.seat.display.loop.ctx
	constraint_retire(c)
}
constraint_set_region :: proc(c: ^Constraint, r: ^wl.Resource) {
	if c.defunct { return }
	delete(c.pending.region); c.pending.region = nil
	c.pending.explicit_region, c.region_pending = r != nil, true
	if r != nil { c.pending.region = region_copy(r) }
}
locked_request :: proc(r: ^wl.Resource, request: p.Zwp_Locked_Pointer_V1_Request, args: []wl.Argument) {
	c := cast(^Constraint)r.data
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .set_region: constraint_set_region(c, wl.object(args[0]))
	case .set_cursor_position_hint:
		if !c.defunct { c.pending.cursor_hint = {true, f64(args[0].(wl.Fixed))/256, f64(args[1].(wl.Fixed))/256}; c.hint_pending = true }
	}
}
confined_request :: proc(r: ^wl.Resource, request: p.Zwp_Confined_Pointer_V1_Request, args: []wl.Argument) {
	switch request { case .destroy: wl.resource_destroy(r); case .set_region: constraint_set_region(cast(^Constraint)r.data, wl.object(args[0])) }
}
constraint_committed :: proc (l: ^wl.Listener, data: rawptr) {
	c := wl.owner(l, Constraint, "commit"); context = c.seat.display.loop.ctx
	if c.region_pending {
		delete(c.current.region)
		c.current.region, c.current.explicit_region = c.pending.region, c.pending.explicit_region
		c.pending.region, c.region_pending = nil, false
	}
	if c.hint_pending { c.current.cursor_hint, c.hint_pending = c.pending.cursor_hint, false }
	constraint_update_region(c)
	wl.signal_emit_mutable(&c.events.set_region, c)
}
constraint_update_region :: proc(c: ^Constraint) {
	clear(&c.region)
	input := surface_input_rectangles(c.surface)
	if !c.current.explicit_region { append(&c.region, ..input); return }
	for a in input { for b in c.current.region {
		r := rg.intersection(a,b)
		if r.width>0 && r.height>0 { append(&c.region,r) }
	} }
}
constraint_activate :: proc(c: ^Constraint) {
	if c.defunct || c.active { return }
	c.active = true; wl.post(c.resource, 0)
}
constraint_deactivate :: proc(c: ^Constraint) {
	if c.defunct || !c.active { return }
	c.active = false; wl.post(c.resource, 1)
	if c.lifetime == 1 { constraint_retire(c) }
}
region_contains :: proc(rects: []rg.Box, x,y: f64) -> bool {
	for r in rects { if x>=f64(r.x) && x<f64((r.x+r.width)) && y>=f64(r.y) && y<f64((r.y+r.height)) { return true } }
	return false
}
constraint_contains :: proc(c: ^Constraint, x,y: f64) -> bool { return region_contains(c.region[:],x,y) }
// Joining ray intervals preserves passage between adjacent rectangles without crossing holes.
region_travel :: proc(rects: []rg.Box, x,y,dx,dy: f64) -> f64 {
	reach := f64(0)
	for _ in 0..=len(rects) {
		before := reach
		for r in rects {
			lo,hi := f64(0),f64(1)
			for axis in 0..<2 {
				pos,delta := x,dx; left,right := f64(r.x),f64((r.x+r.width))
				if axis==1 { pos,delta,left,right=y,dy,f64(r.y),f64((r.y+r.height)) }
				if delta==0 { if pos<left || pos>=right { hi = -1 }; continue }
				a,b := (left-pos)/delta,(right-pos)/delta
				lo,hi=max(lo,min(a,b)),min(hi,max(a,b))
			}
			if lo<=hi && lo<=reach+1e-12 { reach=max(reach,hi) }
		}
		if reach>=1 || reach==before { break }
	}
	return reach
}
region_closest :: proc(rects: []rg.Box, x,y: f64) -> (f64,f64) {
	best,nx,ny := math.INF_F64,x,y
	for r in rects {
		a,b := clamp(x,f64(r.x),f64((r.x+r.width))-1.0/256),clamp(y,f64(r.y),f64((r.y+r.height))-1.0/256)
		d := (a-x)*(a-x)+(b-y)*(b-y)
		if d<best { best,nx,ny=d,a,b }
	}
	return nx,ny
}
constraint_confine :: proc(c: ^Constraint, x,y,dx,dy: f64) -> (f64,f64) {
	if c.type==0 || !constraint_contains(c,x,y) || math.is_nan(dx) || math.is_nan(dy) || math.is_inf(dx) || math.is_inf(dy) { return 0,0 }
	nx,ny,vx,vy := x,y,dx,dy
	for _ in 0..<3 {
		t := region_travel(c.region[:],nx,ny,vx,vy)
		nx,ny=region_closest(c.region[:],nx+vx*t,ny+vy*t)
		if t>=1 { break }
		vx,vy=vx*(1-t),vy*(1-t)
		if !constraint_contains(c,nx+math.sign(vx)/128,ny) { vx=0 }
		if !constraint_contains(c,nx,ny+math.sign(vy)/128) { vy=0 }
		if vx==0 && vy==0 { break }
	}
	return nx-x,ny-y
}
