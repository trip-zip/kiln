package extensions

import p "../protocols"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

Xdg_Output_Manager :: struct {
	global: ^wl.Global,
	layout: ^wlr.wlr_output_layout,
	outputs: [dynamic]^Xdg_Output,
	destroy, layout_destroy: wl.Listener,
}
Xdg_Output :: struct {
	manager: ^Xdg_Output_Manager,
	resource: ^wl.Resource,
	output: ^wlr.wlr_output,
	box: wlr.Box,
	destroy, description: wl.Listener,
}

xdg_output_create :: proc(display: ^wl.Display, layout: ^wlr.wlr_output_layout) -> ^Xdg_Output_Manager {
	m := new(Xdg_Output_Manager)
	m.layout = layout
	m.global = wl.global_create_typed(display, &p.zxdg_output_manager_v1, 3, m, xdg_output_request)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, xdg_output_destroyed)
	wl.listen(&layout.events.destroy, &m.layout_destroy, xdg_output_layout_destroyed)
	return m
}
xdg_output_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Xdg_Output_Manager, "destroy")
	context = m.global.display.loop.ctx
	for len(m.outputs) > 0 { wl.resource_destroy(m.outputs[len(m.outputs)-1].resource) }
	wl.unlisten(&m.destroy)
	wl.unlisten(&m.layout_destroy)
	wl.global_destroy(m.global)
	delete(m.outputs)
	free(m)
}
xdg_output_release :: proc(o: ^Xdg_Output) {
	wl.unlisten(&o.destroy)
	wl.unlisten(&o.description)
	o.output = nil
}
xdg_output_layout_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Xdg_Output_Manager, "layout_destroy")
	context = m.global.display.loop.ctx
	for o in m.outputs { xdg_output_release(o) }
	m.layout = nil
	wl.unlisten(listener)
}
xdg_output_lost :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	xdg_output_release(wl.owner(listener, Xdg_Output, "destroy"))
}
xdg_output_resource_destroy :: proc(r: ^wl.Resource) {
	o := cast(^Xdg_Output)r.data
	xdg_output_release(o)
	for other, i in o.manager.outputs { if other == o { ordered_remove(&o.manager.outputs, i); break } }
	free(o)
}
xdg_output_description :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	o := wl.owner(listener, Xdg_Output, "description")
	context = o.resource.client.display.loop.ctx
	if o.resource.version >= 3 && o.output.description != nil {
		wl.post(o.resource, u32(p.Zxdg_Output_V1_Event.description), wl.String{value = string(o.output.description)})
		wlr.wlr_output_schedule_done(o.output)
	}
}
xdg_output_details :: proc(o: ^Xdg_Output) {
	wl.post(o.resource, u32(p.Zxdg_Output_V1_Event.logical_position), wl.Int(o.box.x), wl.Int(o.box.y))
	wl.post(o.resource, u32(p.Zxdg_Output_V1_Event.logical_size), wl.Int(o.box.width), wl.Int(o.box.height))
	if o.resource.version < 3 { wl.post(o.resource, u32(p.Zxdg_Output_V1_Event.done)) }
	// Queue completion after every resource's properties, including core output changes.
	wlr.wlr_output_schedule_done(o.output)
}
xdg_output_update :: proc(m: ^Xdg_Output_Manager, output: ^wlr.wlr_output = nil) {
	if m == nil || m.layout == nil { return }
	for o in m.outputs {
		if o.output == nil || output != nil && o.output != output { continue }
		box: wlr.Box
		wlr.wlr_output_layout_get_box(m.layout, o.output, &box)
		if box != o.box { o.box = box; xdg_output_details(o) }
	}
}
xdg_output_resource_request :: proc(r: ^wl.Resource, request: p.Zxdg_Output_V1_Request, args: []wl.Argument) {
	switch request { case .destroy: wl.resource_destroy(r) }
}
xdg_output_request :: proc(r: ^wl.Resource, request: p.Zxdg_Output_Manager_V1_Request, args: []wl.Argument) {
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .get_xdg_output:
		m := cast(^Xdg_Output_Manager)r.data
		o := new(Xdg_Output)
		o.manager, o.output = m, output_of(wl.object(args[1]))
		o.resource = wl.resource_create_typed(r.client, &p.zxdg_output_v1, r.version,
			u32(args[0].(wl.New_Id)), o, xdg_output_resource_request, xdg_output_resource_destroy)
		if o.resource == nil { free(o); return }
		append(&m.outputs, o)
		if o.output == nil || m.layout == nil { o.output = nil; return }
		wl.listen(&o.output.events.destroy, &o.destroy, xdg_output_lost)
		wl.listen(&o.output.events.description, &o.description, xdg_output_description)
		if r.version >= 2 {
			wl.post(o.resource, u32(p.Zxdg_Output_V1_Event.name), wl.String{value = string(o.output.name)})
			if o.output.description != nil {
				wl.post(o.resource, u32(p.Zxdg_Output_V1_Event.description), wl.String{value = string(o.output.description)})
			}
		}
		wlr.wlr_output_layout_get_box(m.layout, o.output, &o.box)
		xdg_output_details(o)
	}
}
