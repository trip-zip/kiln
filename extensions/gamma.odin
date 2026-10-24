package extensions

import p "../protocols"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"
import "core:sys/linux"

Gamma :: struct {
	global: ^wl.Global,
	controls: [dynamic]^Gamma_Control,
	size: u32,
	changed: proc(rawptr, ^wlr.wlr_output, []u16) -> bool,
	data: rawptr,
	destroy: wl.Listener,
}
Gamma_Control :: struct {
	manager: ^Gamma,
	resource: ^wl.Resource,
	output: ^wlr.wlr_output,
	table: []u16,
	size: u32,
	destroy: wl.Listener,
}

gamma_create :: proc(display: ^wl.Display, changed: proc(rawptr, ^wlr.wlr_output, []u16) -> bool, data: rawptr) -> ^Gamma {
	m := new(Gamma)
	m.size = 256
	m.changed, m.data = changed, data
	m.global = wl.global_create_typed(display, &p.zwlr_gamma_control_manager_v1, 1, m, gamma_request)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, gamma_destroyed)
	return m
}
gamma_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	m := wl.owner(listener, Gamma, "destroy")
	context = m.global.display.loop.ctx
	for len(m.controls) > 0 { wl.resource_destroy(m.controls[len(m.controls)-1].resource) }
	wl.unlisten(listener)
	wl.global_destroy(m.global)
	delete(m.controls)
	free(m)
}
gamma_table :: proc(m: ^Gamma, output: ^wlr.wlr_output) -> []u16 {
	if m != nil { for c in m.controls { if c.output == output { return c.table } } }
	return nil
}
gamma_request :: proc(r: ^wl.Resource, request: p.Zwlr_Gamma_Control_Manager_V1_Request, args: []wl.Argument) {
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .get_gamma_control:
		m := cast(^Gamma)r.data
		c := new(Gamma_Control)
		c.manager = m
		c.resource = wl.resource_create_typed(r.client, &p.zwlr_gamma_control_v1, r.version,
			u32(args[0].(wl.New_Id)), c, gamma_control_request, gamma_control_destroy)
		if c.resource == nil { free(c); return }
		append(&m.controls, c)
		output := output_of(wl.object(args[1]))
		if output == nil || m.size == 0 { gamma_failed(c); return }
		for other in m.controls { if other.output == output { gamma_failed(c); return } }
		c.output, c.size = output, m.size
		wl.listen(&output.events.destroy, &c.destroy, gamma_output_destroyed)
		wl.post(c.resource, u32(p.Zwlr_Gamma_Control_V1_Event.gamma_size), wl.Uint(c.size))
	}
}
gamma_release :: proc(c: ^Gamma_Control) {
	wl.unlisten(&c.destroy)
	if c.output != nil { c.manager.changed(c.manager.data, c.output, nil) }
	c.output = nil
	delete(c.table)
	c.table = nil
}
gamma_failed :: proc(c: ^Gamma_Control) {
	wl.post(c.resource, u32(p.Zwlr_Gamma_Control_V1_Event.failed))
	gamma_release(c)
}
gamma_output_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	c := wl.owner(listener, Gamma_Control, "destroy")
	context = c.resource.client.display.loop.ctx
	// The scene output can already be gone when the backend emits destroy.
	c.output = nil
	gamma_failed(c)
}
gamma_control_destroy :: proc(r: ^wl.Resource) {
	c := cast(^Gamma_Control)r.data
	gamma_release(c)
	for other, i in c.manager.controls { if other == c { ordered_remove(&c.manager.controls, i); break } }
	free(c)
}
gamma_control_request :: proc(r: ^wl.Resource, request: p.Zwlr_Gamma_Control_V1_Request, args: []wl.Argument) {
	c := cast(^Gamma_Control)r.data
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .set_gamma:
		fd := linux.Fd(args[0].(wl.Fd))
		defer linux.close(fd)
		if c.output == nil { return }
		// A client-owned descriptor must never block the display loop.
		flags, err := linux.fcntl(fd, linux.F_GETFL)
		if err != .NONE { gamma_failed(c); return }
		err = linux.fcntl(fd, linux.F_SETFL, flags | {.NONBLOCK})
		if err != .NONE { gamma_failed(c); return }
		table := make([]u16, 3*int(c.size))
		defer delete(table)
		n, read_err := linux.pread(fd, (cast([^]u8)raw_data(table))[:len(table)*2], 0)
		if read_err != .NONE { gamma_failed(c); return }
		if n != len(table)*2 {
			gamma_release(c)
			wl.post_error(r, u32(p.Zwlr_Gamma_Control_V1_Error.invalid_gamma), "invalid gamma table size")
			return
		}
		if !c.manager.changed(c.manager.data, c.output, table) { gamma_failed(c); return }
		delete(c.table)
		c.table = table
		table = nil
	}
}
