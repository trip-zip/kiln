package shells

import out "../outputs"
import sf "../surfaces"
import p "../protocols"
import wl "../wayland"
import "base:runtime"

Lock_Manager :: struct {
	global:  ^wl.Global,
	locks:   [dynamic]^Lock,
	events:  struct {
		new_lock: wl.Signal,
	},
	destroy: wl.Listener,
}
Lock :: struct {
	resource:    ^wl.Resource,
	manager:     ^Lock_Manager,
	surfaces:    [dynamic]^Lock_Surface,
	locked_sent: bool,
	events:      struct {
		new_surface, unlock, destroy: wl.Signal,
	},
}
Lock_Configure :: struct {
	serial, width, height: u32,
}
Lock_Surface :: struct {
	resource:                    ^wl.Resource,
	lock:                        ^Lock,
	output:                      ^out.Output,
	surface:                     ^sf.Surface,
	current, pending, scheduled: Lock_Configure,
	queue:                       [dynamic]Lock_Configure,
	serial:                      u32,
	configured, unmapping:       bool,
	idle:                        ^wl.Source,
	events:                      struct {
		destroy: wl.Signal,
	},
	output_destroy:              wl.Listener,
}
lock_manager_create :: proc(display: ^wl.Display) -> ^Lock_Manager {
	m := new(Lock_Manager)
	wl.signal_init(&m.events.new_lock)
	m.global = wl.global_create_typed(
		display,
		&p.ext_session_lock_manager_v1,
		1,
		m,
		lock_manager_request,
	)
	if m.global == nil {free(m); return nil}
	wl.listen(&display.destroy_signal, &m.destroy, lock_manager_destroy)
	return m
}
lock_manager_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Lock_Manager, "destroy")
	context = m.global.display.loop.ctx
	for len(m.locks) > 0 {wl.resource_destroy(m.locks[len(m.locks) - 1].resource)}
	wl.unlisten(listener); wl.global_destroy(m.global)
	delete(m.locks); free(m)
}
lock_manager_request :: proc(
	r: ^wl.Resource,
	request: p.Ext_Session_Lock_Manager_V1_Request,
	args: []wl.Argument,
) {
	if request == .destroy {wl.resource_destroy(r); return}
	l := new(Lock)
	l.manager = cast(^Lock_Manager)r.data
	wl.signal_init(
		&l.events.new_surface,
	); wl.signal_init(&l.events.unlock); wl.signal_init(&l.events.destroy)
	l.resource = wl.resource_create_typed(
		r.client,
		&p.ext_session_lock_v1,
		1,
		u32(args[0].(wl.New_Id)),
		l,
		lock_request,
		lock_resource_destroy,
	)
	if l.resource == nil {free(l); return}
	append(&l.manager.locks, l)
	wl.signal_emit_mutable(&l.manager.events.new_lock, l)
}
lock_request :: proc(
	r: ^wl.Resource,
	request: p.Ext_Session_Lock_V1_Request,
	args: []wl.Argument,
) {
	l := cast(^Lock)r.data
	switch request {
	case .destroy:
		if l != nil &&
		   l.locked_sent {wl.post_error(r, u32(p.Ext_Session_Lock_V1_Error.invalid_destroy), "lock is still held"); return}
		wl.resource_destroy(r)
	case .unlock_and_destroy:
		if l != nil {
			if !l.locked_sent {wl.post_error(r, u32(p.Ext_Session_Lock_V1_Error.invalid_unlock), "locked has not been sent"); return}
			wl.signal_emit_mutable(&l.events.unlock, l)
		}
		wl.resource_destroy(r)
	case .get_lock_surface:
		// A rejected lock still needs to consume IDs from requests already in flight.
		resource := wl.resource_create_typed(
			r.client,
			&p.ext_session_lock_surface_v1,
			1,
			u32(args[0].(wl.New_Id)),
			nil,
			lock_surface_request,
			lock_surface_resource_destroy,
		)
		if resource == nil || l == nil {return}
		output := output_of(wl.object(args[2]))
		if output == nil {return}
		for other in l.surfaces {
			if other.output ==
			   output {wl.post_error(r, u32(p.Ext_Session_Lock_V1_Error.duplicate_output), "output already has a lock surface"); return}
		}
		surface := surface_of(wl.object(args[1]))
		if has_buffer(
			surface,
		) {wl.post_error(r, u32(p.Ext_Session_Lock_V1_Error.already_constructed), "surface already has a buffer"); return}
		s := new(Lock_Surface)
		s.resource, s.lock, s.output, s.surface = resource, l, output, surface
		resource.data = s
		wl.signal_init(&s.events.destroy)
		append(&l.surfaces, s)
		if !role_assign(
			s,
			r,
			u32(p.Ext_Session_Lock_V1_Error.role),
		) {lock_surface_retire(s); return}
		wl.listen(&output.events.destroy, &s.output_destroy, lock_output_destroyed)
		wl.signal_emit_mutable(&l.events.new_surface, s)
	}
}
lock_reject :: proc(l: ^Lock) {
	context = l.resource.client.display.loop.ctx
	wl.post(l.resource, u32(p.Ext_Session_Lock_V1_Event.finished))
	lock_retire(l)
}
lock_acknowledge :: proc(l: ^Lock) {
	assert(!l.locked_sent)
	l.locked_sent = true
	wl.post(l.resource, u32(p.Ext_Session_Lock_V1_Event.locked))
}
lock_retire :: proc(l: ^Lock) {
	context = l.resource.client.display.loop.ctx
	for len(l.surfaces) > 0 {lock_surface_retire(l.surfaces[len(l.surfaces) - 1])}
	wl.signal_emit_final(&l.events.destroy, l)
	l.resource.data = nil
	for other, i in l.manager.locks {if other == l {ordered_remove(&l.manager.locks, i); break}}
	delete(l.surfaces); free(l)
}
lock_resource_destroy :: proc(r: ^wl.Resource) {if l := cast(^Lock)r.data; l != nil {lock_retire(
			l,
		)}}
lock_surface_request :: proc(
	r: ^wl.Resource,
	request: p.Ext_Session_Lock_Surface_V1_Request,
	args: []wl.Argument,
) {
	if request == .destroy {wl.resource_destroy(r); return}
	s := cast(^Lock_Surface)r.data
	if s == nil {return}
	serial := u32(args[0].(wl.Uint))
	for c, i in s.queue {
		if c.serial != serial {continue}
		s.pending, s.configured = c, true
		for _ in 0 ..= i {ordered_remove(&s.queue, 0)}
		return
	}
	wl.post_error(
		r,
		u32(p.Ext_Session_Lock_Surface_V1_Error.invalid_serial),
		"unknown configure serial",
	)
}
lock_surface_validate :: proc(s: ^Lock_Surface) {
	if !s.configured {wl.post_error(s.resource, u32(p.Ext_Session_Lock_Surface_V1_Error.commit_before_first_ack), "initial configure has not been acknowledged"); return}
	if !has_pending_buffer(
		s.surface,
	) {wl.post_error(s.resource, u32(p.Ext_Session_Lock_Surface_V1_Error.null_buffer), "lock surface requires a buffer"); return}
	if s.surface.pending.width != i32(s.pending.width) ||
	   s.surface.pending.height != i32(s.pending.height) {
		wl.post_error(
			s.resource,
			u32(p.Ext_Session_Lock_Surface_V1_Error.dimensions_mismatch),
			"surface size differs from acknowledged configure",
		)
	}
}
// Lock roles cannot be synchronized subsurfaces, so commit applies their pending state directly.
lock_surface_commit :: proc(s: ^Lock_Surface) {
	if s.resource.client.failed {return}
	if s.unmapping {s.unmapping = false; return}
	s.current = s.pending
	if has_buffer(s.surface) {map_surface(s.surface)}
}
lock_configure :: proc(s: ^Lock_Surface, width, height: i32) -> u32 {
	context = s.resource.client.display.loop.ctx
	if s.idle == nil {
		s.serial += 1; if s.serial == 0 {s.serial = 1}
		s.idle = wl.on_idle(s.resource.client.display, lock_send_configure, s)
	}
	s.scheduled = {s.serial, u32(max(1, width)), u32(max(1, height))}
	return s.serial
}
lock_send_configure :: proc(data: rawptr) {
	s := cast(^Lock_Surface)data
	s.idle = nil
	append(&s.queue, s.scheduled)
	wl.post(
		s.resource,
		u32(p.Ext_Session_Lock_Surface_V1_Event.configure),
		wl.Uint(s.scheduled.serial),
		wl.Uint(s.scheduled.width),
		wl.Uint(s.scheduled.height),
	)
}
lock_output_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Lock_Surface, "output_destroy")
	context = s.resource.client.display.loop.ctx
	lock_surface_retire(s)
}
lock_surface_retire :: proc(s: ^Lock_Surface) {
	context = s.resource.client.display.loop.ctx
	if roles[s.surface] == Surface_Object(s) {unmap_surface(s.surface)}
	if s.idle != nil {wl.source_remove(s.idle)}
	wl.signal_emit_final(&s.events.destroy, s)
	role_forget(s); wl.unlisten(&s.output_destroy)
	s.resource.data = nil
	for other, i in s.lock.surfaces {if other == s {ordered_remove(&s.lock.surfaces, i); break}}
	delete(s.queue); free(s)
}
lock_surface_resource_destroy :: proc(r: ^wl.Resource) {if s := cast(^Lock_Surface)r.data;
	   s != nil {lock_surface_retire(s)}}
