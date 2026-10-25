package surfaces

import wl "../wayland"
import p "../protocols"

Compositor :: struct { global: ^wl.Global, events: struct { new_surface: wl.Signal }, destroy: wl.Listener }
Global :: struct { global: ^wl.Global, destroy: wl.Listener }
create_global :: proc(display: ^wl.Display, iface: ^wl.Interface, $dispatch: proc(^wl.Resource,$Op,[]wl.Argument)) -> ^Global {
	g := new(Global)
	g.global = wl.global_create_typed(display,iface,1,g,dispatch)
	if g.global == nil { free(g); return nil }
	wl.listen(&display.destroy_signal,&g.destroy,global_destroy)
	return g
}
global_destroy :: proc(l: ^wl.Listener, data: rawptr) {
	g := wl.owner(l,Global,"destroy"); wl.unlisten(l); wl.global_destroy(g.global); free(g)
}
compositor_create :: proc(display: ^wl.Display, version: i32) -> ^Compositor {
	c := new(Compositor); wl.signal_init(&c.events.new_surface)
	c.global = wl.global_create_typed(display,&p.wl_compositor,version,c,compositor_request)
	if c.global == nil { free(c); return nil }
	wl.listen(&display.destroy_signal,&c.destroy,compositor_destroy)
	return c
}
compositor_destroy :: proc(l: ^wl.Listener, data: rawptr) {
	c := wl.owner(l,Compositor,"destroy"); wl.unlisten(l); wl.global_destroy(c.global); free(c)
}
compositor_request :: proc(r: ^wl.Resource, op: p.Wl_Compositor_Request, args: []wl.Argument) {
	id := u32(args[0].(wl.New_Id))
	switch op {
	case .release: wl.resource_destroy(r)
	case .create_region: region_create(r.client,r.version,id)
	case .create_surface:
		s := new(Surface); s.compositor = cast(^Compositor)r.data
		state_init(&s.current); state_init(&s.pending); s.pending.seq = 1
		for signal in ([]^wl.Signal{&s.events.client_commit,&s.events.commit,&s.events.map_,&s.events.unmap,&s.events.new_subsurface,&s.events.destroy}) { wl.signal_init(signal) }
		s.resource = wl.resource_create_typed(r.client,&p.wl_surface,r.version,id,s,surface_request,surface_destroy)
		if s.resource == nil { free(s); return }
		wl.signal_emit_mutable(&s.compositor.events.new_surface,s)
	}
}
