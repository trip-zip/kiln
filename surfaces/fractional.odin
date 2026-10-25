package surfaces

import wl "../wayland"
import p "../protocols"
import "core:math"

Fractional :: struct { resource: ^wl.Resource, surface: ^Surface }
fractional_scale_create :: proc(d: ^wl.Display) -> ^Global { return create_global(d,&p.wp_fractional_scale_manager_v1,fractional_manager_request) }
fractional_manager_request :: proc(r: ^wl.Resource, op: p.Wp_Fractional_Scale_Manager_V1_Request, args: []wl.Argument) {
	if op == .destroy { wl.resource_destroy(r); return }
	s := of(wl.object(args[1]))
	if s.fractional != nil { wl.post_error(r,u32(p.Wp_Fractional_Scale_Manager_V1_Error.fractional_scale_exists),"surface already has a scale object"); return }
	f := new(Fractional); f.surface = s
	f.resource = wl.resource_create_typed(r.client,&p.wp_fractional_scale_v1,1,u32(args[0].(wl.New_Id)),f,fractional_request,fractional_destroy)
	if f.resource == nil { free(f); return }
	s.fractional = f
	if s.fractional_scale != 0 { fractional_send(s) }
}
fractional_request :: proc(r: ^wl.Resource, op: p.Wp_Fractional_Scale_V1_Request, args: []wl.Argument) { wl.resource_destroy(r) }
fractional_destroy :: proc(r: ^wl.Resource) {
	f := cast(^Fractional)r.data; if f.surface != nil { f.surface.fractional = nil }; free(f)
}
fractional_send :: proc(s: ^Surface) { wl.post(s.fractional.resource,0,wl.Uint(math.round(s.fractional_scale*120))) }
notify_scale :: proc(s: ^Surface, scale: f64) {
	if s.fractional_scale == scale { return }; s.fractional_scale = scale
	if s.fractional != nil { fractional_send(s) }
}
set_preferred_scale :: proc(s: ^Surface, scale: i32) {
	if s.resource.version<6 || s.preferred_scale==scale { return }
	wl.post(s.resource,u32(p.Wl_Surface_Event.preferred_buffer_scale),wl.Int(scale)); s.preferred_scale = scale
}
set_preferred_transform :: proc(s: ^Surface, transform: i32) {
	if s.resource.version<6 || s.preferred_transform_sent && s.preferred_transform==transform { return }
	wl.post(s.resource,u32(p.Wl_Surface_Event.preferred_buffer_transform),wl.Uint(transform))
	s.preferred_transform,s.preferred_transform_sent = transform,true
}
