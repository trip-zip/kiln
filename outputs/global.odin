package outputs

import p "../protocols"
import wl "../wayland"
import "base:runtime"
import "core:math"

resource_from_link :: proc(link: ^wl.List) -> ^wl.Resource {
	return runtime.container_of(link, wl.Resource, "link")
}

of :: proc(r: ^wl.Resource) -> ^Output {
	if r == nil || !wl.interface_equal(r.interface, &p.wl_output) {return nil}
	return cast(^Output)r.data
}

create_global :: proc(o: ^Output) {
	o.global = wl.global_create_typed(
		o.display,
		&p.wl_output,
		4,
		o,
		output_request,
		resource_destroy,
		output_bind,
	)
}

output_request :: proc(
	r: ^wl.Resource,
	request: p.Wl_Output_Request,
	args: []wl.Argument,
) {wl.resource_destroy(r)}
resource_destroy :: proc(r: ^wl.Resource) {wl.list_remove(&r.link)}
output_bind :: proc(r: ^wl.Resource) {
	o := of(r)
	if o == nil {return}
	wl.insert(&o.resources, &r.link)
	send_geometry(r)
	send_mode(r)
	send_scale(r)
	if r.version >= 4 {
		wl.post(r, 4, wl.String{value = o.name})
		send_description(r)
	}
	send_done(r)
	e := Bind_Event{o, r}
	wl.signal_emit_mutable(&o.events.bind, &e)
}

send_geometry :: proc(r: ^wl.Resource) {
	o := of(r)
	wl.post(
		r,
		0,
		wl.Int(o.x),
		wl.Int(o.y),
		wl.Int(o.physical_width),
		wl.Int(o.physical_height),
		wl.Int(o.subpixel),
		wl.String{value = o.make if o.make != "" else "Unknown"},
		wl.String{value = o.model if o.model != "" else "Unknown"},
		wl.Int(o.transform),
	)
}

send_mode :: proc(r: ^wl.Resource) {
	o := of(r)
	flags := u32(1)
	if o.current_mode != nil && o.current_mode.preferred {flags |= 2}
	wl.post(r, 1, wl.Uint(flags), wl.Int(o.width), wl.Int(o.height), wl.Int(o.refresh))
}

send_scale :: proc(r: ^wl.Resource) {
	if r.version >= 2 {
		wl.post(r, 3, wl.Int(math.ceil(of(r).scale)))
	}
}

send_description :: proc(r: ^wl.Resource) {
	if r.version >= 4 && of(r).description != "" {
		wl.post(r, 5, wl.String{value = of(r).description})
	}
}

send_done :: proc(r: ^wl.Resource) {if r.version >= 2 {wl.post(r, 2)}}
update_global :: proc(o: ^Output) {
	it := wl.iterate(&o.resources)
	for link in wl.next(&it) {send_geometry(resource_from_link(link))}
	schedule_done(o)
}
