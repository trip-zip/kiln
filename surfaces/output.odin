package surfaces

import wl "../wayland"
import wlr "../wlroots"
import p "../protocols"
import "core:math"
import "core:sys/posix"
import "base:runtime"

Surface_Output :: struct { surface: ^Surface, output: ^wlr.wlr_output, bind,destroy: wl.Listener }
Output_Bind :: struct { output: ^wlr.wlr_output, resource: ^wl.Resource }
#assert(size_of(Output_Bind)==16 && align_of(Output_Bind)==8 && offset_of(Output_Bind,output)==0 && offset_of(Output_Bind,resource)==8)
output_remove :: proc(o: ^Surface_Output) {
	wl.unlisten(&o.bind); wl.unlisten(&o.destroy)
	for other,i in o.surface.outputs { if other == o { ordered_remove(&o.surface.outputs,i); break } }; free(o)
}
output_gone :: proc "c" (l: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	o := wl.owner(l,Surface_Output,"destroy"); context = o.surface.resource.client.display.loop.ctx; output_remove(o)
}
output_bound :: proc "c" (l: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	o := wl.owner(l,Surface_Output,"bind"); context = o.surface.resource.client.display.loop.ctx
	e := cast(^Output_Bind)data
	if e.resource.client == o.surface.resource.client { wl.post(o.surface.resource,u32(p.Wl_Surface_Event.enter),wl.Object(e.resource)) }
}
enter :: proc(s: ^Surface, output: ^wlr.wlr_output) {
	for o in s.outputs { if o.output == output { return } }
	o := new(Surface_Output); o.surface,o.output = s,output; append(&s.outputs,o)
	wl.listen(&output.events.bind,&o.bind,output_bound); wl.listen(&output.events.destroy,&o.destroy,output_gone)
	it := wl.client_resources(&output.resources,s.resource.client)
	for r in wl.next_resource(&it) { wl.post(s.resource,u32(p.Wl_Surface_Event.enter),wl.Object(r)) }
}
leave :: proc(s: ^Surface, output: ^wlr.wlr_output) {
	for o in s.outputs { if o.output == output {
		output_remove(o)
		it := wl.client_resources(&output.resources,s.resource.client)
		for r in wl.next_resource(&it) { wl.post(s.resource,u32(p.Wl_Surface_Event.leave),wl.Object(r)) }; return
	} }
}
density :: proc(s: ^Surface, outputs: []^wlr.wlr_output) {
	scale: f32 = 1; transform: i32
	for o in outputs { if o.scale>=scale { scale,transform = o.scale,o.transform } }
	set_preferred_scale(s,i32(math.ceil(scale))); set_preferred_transform(s,transform); notify_scale(s,f64(scale))
}
frame_done :: proc(s: ^Surface, now: ^posix.timespec) {
	for len(s.current.frame_callbacks)>0 {
		r := s.current.frame_callbacks[0]; wl.post(r,0,wl.Uint(u64(now.tv_sec)*1000+u64(now.tv_nsec)/1000000)); wl.resource_destroy(r)
	}
}
