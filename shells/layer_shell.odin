package shells

import out "../outputs"
import sf "../surfaces"
import p "../protocols"
import wl "../wayland"
import "base:runtime"
import "core:strings"

Layer_Shell :: struct {
	global:   ^wl.Global,
	surfaces: [dynamic]^Layer_Surface,
	events:   struct {
		new_surface: wl.Signal,
	},
	destroy:  wl.Listener,
}
Layer_State :: struct {
	committed, anchor:                             u32,
	exclusive_zone:                                i32,
	margin:                                        struct {
		top, right, bottom, left: i32,
	},
	keyboard_interactive:                          i32,
	desired_width, desired_height:                 u32,
	layer:                                         i32,
	configure_serial, actual_width, actual_height: u32,
}
Layer_Configure :: struct {
	serial, width, height: u32,
}
Layer_Surface :: struct {
	resource, owner:                                    ^wl.Resource,
	shell:                                              ^Layer_Shell,
	surface:                                            ^sf.Surface,
	output:                                             ^out.Output,
	namespace:                                          string,
	current, pending:                                   Layer_State,
	initialized, initial_commit, configured, unmapping: bool,
	initial_layer:                                      i32,
	serial:                                             u32,
	scheduled:                                          Layer_Configure,
	queue:                                              [dynamic]Layer_Configure,
	idle:                                               ^wl.Source,
	popups:                                             [dynamic]^Popup,
	events:                                             struct {
		destroy, new_popup: wl.Signal,
	},
	owner_destroy:                                      wl.Listener,
	data:                                               rawptr,
}
// Version four excludes exclusive-edge requests from the advertised interface.
layer_shell_create :: proc(display: ^wl.Display) -> ^Layer_Shell {
	s := new(Layer_Shell)
	wl.signal_init(&s.events.new_surface)
	s.global = wl.global_create_typed(display, &p.zwlr_layer_shell_v1, 4, s, layer_shell_request)
	if s.global == nil {free(s); return nil}
	wl.listen(&display.destroy_signal, &s.destroy, layer_shell_destroy)
	return s
}
layer_shell_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Layer_Shell, "destroy")
	context = s.global.display.loop.ctx
	for len(s.surfaces) > 0 {wl.resource_destroy(s.surfaces[len(s.surfaces) - 1].resource)}
	wl.unlisten(listener); wl.global_destroy(s.global)
	delete(s.surfaces); free(s)
}
layer_shell_request :: proc(
	r: ^wl.Resource,
	request: p.Zwlr_Layer_Shell_V1_Request,
	args: []wl.Argument,
) {
	if request == .destroy {wl.resource_destroy(r); return}
	s := cast(^Layer_Shell)r.data
	layer := u32(args[3].(wl.Uint))
	if layer >
	   3 {wl.post_error(r, u32(p.Zwlr_Layer_Shell_V1_Error.invalid_layer), "invalid layer"); return}
	surface := surface_of(wl.object(args[1]))
	if has_buffer(
		surface,
	) {wl.post_error(r, u32(p.Zwlr_Layer_Shell_V1_Error.already_constructed), "surface already has a buffer"); return}
	l := new(Layer_Surface)
	l.shell, l.owner, l.surface = s, r, surface
	l.output = output_of(wl.object(args[2]))
	l.namespace = strings.clone(args[4].(wl.String).value)
	l.initial_layer, l.current.layer, l.pending.layer = i32(layer), i32(layer), i32(layer)
	wl.signal_init(&l.events.destroy)
	wl.signal_init(&l.events.new_popup)
	l.resource = wl.resource_create_typed(
		r.client,
		&p.zwlr_layer_surface_v1,
		r.version,
		u32(args[0].(wl.New_Id)),
		l,
		layer_request,
		layer_resource_destroy,
	)
	if l.resource == nil {delete(l.namespace); free(l); return}
	append(&s.surfaces, l)
	wl.listen(&r.destroy_signal, &l.owner_destroy, layer_owner_destroyed)
	if !role_assign(l, r) {wl.resource_destroy(l.resource); return}
	wl.signal_emit_mutable(&s.events.new_surface, l)
}
layer_owner_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	l := wl.owner(listener, Layer_Surface, "owner_destroy")
	context = l.resource.client.display.loop.ctx
	wl.unlisten(listener); l.owner = nil
}
layer_request :: proc(
	r: ^wl.Resource,
	request: p.Zwlr_Layer_Surface_V1_Request,
	args: []wl.Argument,
) {
	l := cast(^Layer_Surface)r.data
	if request == .destroy {wl.resource_destroy(r); return}
	if l == nil {return}
	switch request {
	case .destroy:
	case .set_size:
		width, height := u32(args[0].(wl.Uint)), u32(args[1].(wl.Uint))
		if l.pending.desired_width != width ||
		   l.pending.desired_height != height {l.pending.committed |= 1}
		l.pending.desired_width, l.pending.desired_height = width, height
	case .set_anchor:
		anchor := u32(args[0].(wl.Uint))
		if anchor & ~u32(15) !=
		   0 {wl.post_error(r, u32(p.Zwlr_Layer_Surface_V1_Error.invalid_anchor), "invalid anchor"); return}
		if l.pending.anchor != anchor {l.pending.committed |= 2}
		l.pending.anchor = anchor
	case .set_exclusive_zone:
		zone := i32(args[0].(wl.Int))
		if l.pending.exclusive_zone != zone {l.pending.committed |= 4}
		l.pending.exclusive_zone = zone
	case .set_margin:
		margin := type_of(l.pending.margin) {
			i32(args[0].(wl.Int)),
			i32(args[1].(wl.Int)),
			i32(args[2].(wl.Int)),
			i32(args[3].(wl.Int)),
		}
		if l.pending.margin != margin {l.pending.committed |= 8}
		l.pending.margin = margin
	case .set_keyboard_interactivity:
		value := u32(args[0].(wl.Uint))
		if value >
		   (2 if r.version >= 4 else 1) {wl.post_error(r, u32(p.Zwlr_Layer_Surface_V1_Error.invalid_keyboard_interactivity), "invalid keyboard interactivity"); return}
		l.pending.keyboard_interactive = i32(value); l.pending.committed |= 16
	case .get_popup:
		if popup := cast(^Popup)wl.object(args[0]).data;
		   popup !=
		   nil {if popup_parent(popup, l.surface) {wl.signal_emit_mutable(&l.events.new_popup, popup)}}
	case .ack_configure:
		serial := u32(args[0].(wl.Uint))
		for c, i in l.queue {
			if c.serial != serial {continue}
			l.pending.configure_serial, l.pending.actual_width, l.pending.actual_height =
				c.serial, c.width, c.height
			l.configured = true
			for _ in 0 ..= i {ordered_remove(&l.queue, 0)}
			return
		}
		wl.post_error(
			r,
			u32(p.Zwlr_Layer_Surface_V1_Error.invalid_surface_state),
			"unknown configure serial",
		)
	case .set_layer:
		value := u32(args[0].(wl.Uint))
		if value > 3 {
			if l.owner !=
			   nil {wl.post_error(l.owner, u32(p.Zwlr_Layer_Shell_V1_Error.invalid_layer), "invalid layer")} else {wl.post_error(r, u32(p.Zwlr_Layer_Surface_V1_Error.invalid_surface_state), "invalid layer after manager destruction")}
			return
		}
		if l.pending.layer != i32(value) {l.pending.committed |= 32}
		l.pending.layer = i32(value)
	case .set_exclusive_edge:
	}
}
layer_validate :: proc(l: ^Layer_Surface) {
	if has_pending_buffer(l.surface) &&
	   !l.configured {wl.post_error(l.resource, u32(p.Zwlr_Layer_Surface_V1_Error.invalid_surface_state), "initial configure has not been acknowledged"); return}
	if (l.pending.desired_width == 0 && l.pending.anchor & 12 != 12) ||
	   (l.pending.desired_height == 0 && l.pending.anchor & 3 != 3) {
		wl.post_error(
			l.resource,
			u32(p.Zwlr_Layer_Surface_V1_Error.invalid_size),
			"zero size requires opposite anchors",
		)
	}
}
// Layer roles cannot be synchronized subsurfaces, so commit applies their pending state directly.
layer_commit :: proc(l: ^Layer_Surface) {
	if l.resource.client.failed {return}
	if l.unmapping {l.unmapping = false; return}
	l.initial_commit, l.initialized = !l.initialized, true
	l.current = l.pending; l.pending.committed = 0
	if has_buffer(l.surface) {map_surface(l.surface)}
}
layer_reset :: proc(l: ^Layer_Surface) {
	dismiss_children(l.surface)
	if l.idle != nil {wl.source_remove(l.idle); l.idle = nil}
	clear(&l.queue)
	l.initialized, l.initial_commit, l.configured = false, false, false
	l.current, l.pending = {}, {}
	l.current.layer, l.pending.layer = l.initial_layer, l.initial_layer
}
layer_configure :: proc(l: ^Layer_Surface, width, height: u32) -> u32 {
	if !l.initialized {return 0}
	if l.idle == nil {
		l.serial += 1; if l.serial == 0 {l.serial = 1}
		l.idle = wl.on_idle(l.resource.client.display, layer_send_configure, l)
	}
	l.scheduled = {l.serial, width, height}
	return l.serial
}
layer_send_configure :: proc(data: rawptr) {
	l := cast(^Layer_Surface)data
	l.idle = nil
	append(&l.queue, l.scheduled)
	wl.post(
		l.resource,
		u32(p.Zwlr_Layer_Surface_V1_Event.configure),
		wl.Uint(l.scheduled.serial),
		wl.Uint(l.scheduled.width),
		wl.Uint(l.scheduled.height),
	)
}
layer_close :: proc(l: ^Layer_Surface) {
	if l == nil {return}
	context = l.resource.client.display.loop.ctx
	dismiss_children(l.surface)
	wl.post(l.resource, u32(p.Zwlr_Layer_Surface_V1_Event.closed))
	layer_retire(l)
}
layer_retire :: proc(l: ^Layer_Surface) {
	context = l.resource.client.display.loop.ctx
	dismiss_children(l.surface)
	if roles[l.surface] == Surface_Object(l) {unmap_surface(l.surface)}
	layer_reset(l)
	wl.signal_emit_final(&l.events.destroy, l)
	role_forget(l)
	wl.unlisten(&l.owner_destroy)
	l.resource.data = nil
	for other, i in l.shell.surfaces {if other == l {ordered_remove(&l.shell.surfaces, i); break}}
	delete(l.queue); delete(l.popups); delete(l.namespace); free(l)
}
layer_resource_destroy :: proc(r: ^wl.Resource) {if l := cast(^Layer_Surface)r.data;
	   l != nil {layer_retire(l)}}
