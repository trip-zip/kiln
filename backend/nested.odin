package backend

import buf "../buffers"
import "../gles"
import out "../outputs"
import p "../protocols"
import wl "../wayland"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"

Nested :: struct {
	base: Backend,
	remote: ^wl.Remote,
	registry, compositor, wm, decoration, dmabuf, relative, feedback: ^wl.Proxy,
	outputs: [dynamic]^Nested_Output,
	parents: [dynamic]^Parent_Output,
	seats: [dynamic]^Nested_Seat,
	buffers: [dynamic]^Nested_Buffer,
	formats: [dynamic]buf.Format,
	table: []Feedback_Format,
	main_device, tranche_device: u64,
	next: u32,
	failure: ^wl.Source,
}
Feedback_Format :: struct { format, padding: u32, modifier: u64 }
Parent_Output :: struct { backend: ^Nested, proxy: ^wl.Proxy, name: u32, refresh, scale: i32 }
Nested_Output :: struct {
	output: out.Output,
	backend: ^Nested,
	surface, shell, toplevel, decoration, frame: ^wl.Proxy,
	parent: ^Parent_Output,
	attached: ^Nested_Buffer,
	width, height: i32,
	seq: u32,
	close: ^wl.Source,
	configured, announced, presented: bool,
}
Nested_Buffer :: struct {
	backend: ^Nested,
	buffer: ^gles.Buffer,
	proxy: ^wl.Proxy,
	retire: wl.Listener,
	busy, retired: bool,
}

nested_impl := Backend_Impl{start=nested_start, destroy=nested_destroy, add_output=nested_window}
nested_output_impl := out.Impl{commit=nested_commit, destroy=nested_output_destroy, schedule=nested_schedule}

nested_failed :: proc(data: rawptr) {
	n := cast(^Nested)data
	if n.failure == nil { n.failure = wl.on_idle(n.base.display,nested_failure,n) }
}
nested_failure :: proc(data: rawptr) { n := cast(^Nested)data; n.failure = nil; destroy(&n.base) }

nested_create :: proc(display: ^wl.Display) -> ^Backend {
	n := new(Nested)
	init(&n.base,display,&nested_impl); n.base.data = n
	ok := false
	defer if !ok { destroy(&n.base) }
	n.remote = wl.remote_open(display.loop, "")
	if n.remote == nil { fmt.eprintln("Nested: cannot connect to Wayland parent"); return nil }
	n.remote.data, n.remote.error = n, nested_failed
	n.registry = wl.proxy_new(n.remote,&p.wl_registry,1,nested_registry,n)
	wl.proxy_request(n.remote.objects[1],1,wl.Proxy_Object(n.registry))
	if !wl.remote_roundtrip(n.remote) { return nil }
	if n.compositor == nil || n.wm == nil || n.dmabuf == nil {
		fmt.eprintln("Nested: parent requires wl_compositor 4, xdg_wm_base and zwp_linux_dmabuf_v1 4")
		return nil
	}
	n.feedback = wl.proxy_new(n.remote,&p.zwp_linux_dmabuf_feedback_v1,4,nested_feedback,n)
	wl.proxy_request(n.dmabuf,2,wl.Proxy_Object(n.feedback))
	if !wl.remote_roundtrip(n.remote) || len(n.formats) == 0 { fmt.eprintln("Nested: parent has no DMA-BUF formats"); return nil }
	if node, found := gles.render_node(gles.drm_directory(posix.dev_t(n.main_device))); found && node != "" {
		fd, err := linux.open(fmt.ctprintf("/dev/dri/%s",node),{.RDWR,.CLOEXEC})
		if err == .NONE { n.base.drm_fd = i32(fd) }
	}
	ok = true
	return &n.base
}

nested_registry :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	n := cast(^Nested)proxy.data
	name := u32(args[0].(wl.Uint))
	if opcode == 1 {
		for s in n.seats { if s.name == name { nested_seat_destroy(s); return } }
		for parent,i in n.parents { if parent.name == name {
			for o in n.outputs { if o.parent == parent { o.parent = nil; nested_resize(o) } }
			wl.proxy_release(parent.proxy,0 if parent.proxy.version >= 3 else -1)
			ordered_remove(&n.parents,i); free(parent); return
		} }
		return
	}
	version := u32(args[2].(wl.Uint))
	switch args[1].(wl.String).value {
	case "wl_compositor": if version >= 4 { n.compositor = wl.proxy_bind(proxy,name,&p.wl_compositor,4) }
	case "xdg_wm_base": n.wm = wl.proxy_bind(proxy,name,&p.xdg_wm_base,1,nested_ping)
	case "zxdg_decoration_manager_v1": n.decoration = wl.proxy_bind(proxy,name,&p.zxdg_decoration_manager_v1,1)
	case "zwp_linux_dmabuf_v1": if version >= 4 { n.dmabuf = wl.proxy_bind(proxy,name,&p.zwp_linux_dmabuf_v1,4) }
	case "zwp_relative_pointer_manager_v1": n.relative = wl.proxy_bind(proxy,name,&p.zwp_relative_pointer_manager_v1,1)
	case "wl_seat":
		if version >= 5 {
			s := new(Nested_Seat); s.backend, s.name = n, name
			s.proxy = wl.proxy_bind(proxy,name,&p.wl_seat,min(version,9),nested_seat_event,s)
			append(&n.seats,s)
		}
	case "wl_output":
		o := new(Parent_Output); o^ = {backend=n,name=name,refresh=60000,scale=1}
		o.proxy = wl.proxy_bind(proxy,name,&p.wl_output,min(version,4),nested_parent_event,o)
		append(&n.parents,o)
	}
}
nested_ping :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) { wl.proxy_request(proxy,3,args[0]) }

nested_feedback :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	n := cast(^Nested)proxy.data
	switch opcode {
	case 0:
		for o in n.outputs { out.set_formats(&o.output,n.formats[:]) }
	case 1:
		fd, size := linux.Fd(args[0].(wl.Fd)), uint(args[1].(wl.Uint))
		defer linux.close(fd)
		if len(n.table) > 0 { linux.munmap(raw_data(n.table),uint(len(n.table)*size_of(Feedback_Format))); n.table = nil }
		if size == 0 || size%16 != 0 || size > 16*1024*1024 { wl.remote_fail(n.remote,"invalid DMA-BUF format table"); return }
		address, err := linux.mmap(0,size,{.READ},{.PRIVATE},fd)
		if err != .NONE { wl.remote_fail(n.remote,"cannot map DMA-BUF format table"); return }
		n.table = (cast([^]Feedback_Format)address)[:size/16]
	case 2,4:
		array := args[0].(wl.Array)
		if array.size != size_of(u64) { wl.remote_fail(n.remote,"invalid DMA-BUF device"); return }
		device: u64
		copy((cast([^]u8)&device)[:8],(cast([^]u8)array.data)[:8])
		if opcode == 2 {
			n.main_device = device
			for f in n.formats { delete(f.modifiers) }; clear(&n.formats)
		} else { n.tranche_device = device }
	case 5:
		if n.main_device != n.tranche_device { return }
		array := args[0].(wl.Array)
		if array.size%2 != 0 { wl.remote_fail(n.remote,"invalid DMA-BUF tranche"); return }
		for index in (cast([^]u16)array.data)[:array.size/2] {
			if int(index) >= len(n.table) { wl.remote_fail(n.remote,"invalid DMA-BUF format index"); return }
			entry := n.table[index]
			found := false
			for &f in n.formats { if f.format == entry.format {
				for m in f.modifiers { if m == entry.modifier { found = true; break } }
				if !found {
					mods := make([]u64,len(f.modifiers)+1); copy(mods,f.modifiers); mods[len(f.modifiers)] = entry.modifier
					delete(f.modifiers); f.modifiers = mods
				}
				found = true; break
			} }
			if !found { mods := make([]u64,1); mods[0] = entry.modifier; append(&n.formats,buf.Format{entry.format,mods}) }
		}
	}
}

nested_parent_event :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	parent := cast(^Parent_Output)proxy.data
	if opcode == 1 && u32(args[0].(wl.Uint))&1 != 0 {
		parent.refresh = i32(args[3].(wl.Int))
		if parent.refresh <= 0 { parent.refresh = 60000 }
		for o in parent.backend.outputs { if o.parent == parent { nested_resize(o) } }
	}
	if opcode == 3 { parent.scale = max(i32(args[0].(wl.Int)),1) }
}
nested_refresh :: proc(o: ^Nested_Output) -> i32 { return o.parent.refresh if o.parent != nil && o.parent.refresh > 0 else 60000 }
nested_resize :: proc(o: ^Nested_Output) {
	refresh := nested_refresh(o)
	if !o.announced { o.output.width, o.output.height, o.output.refresh = o.width,o.height,refresh; return }
	if o.width == o.output.width && o.height == o.output.height && refresh == o.output.refresh { return }
	s: out.State
	out.set_custom_mode(&s,o.width,o.height,refresh)
	defer out.state_finish(&s)
	out.request_state(&o.output,&s)
}
nested_surface_event :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	o := cast(^Nested_Output)proxy.data
	parent := cast(^Parent_Output)args[0].(wl.Proxy_Object).data
	if opcode == 0 { o.parent = parent; nested_resize(o) }
}
nested_configure :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	o := cast(^Nested_Output)proxy.data
	wl.proxy_request(proxy,4,args[0])
	o.configured = true
	nested_resize(o)
}
nested_toplevel :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	o := cast(^Nested_Output)proxy.data
	if opcode == 0 {
		w,h := i32(args[0].(wl.Int)),i32(args[1].(wl.Int))
		if w > 0 { o.width = w }; if h > 0 { o.height = h }
	} else if opcode == 1 {
		if o.close == nil { o.close = wl.on_idle(o.backend.base.display,nested_closed,o) }
	}
}

nested_closed :: proc(data: rawptr) {
	o := cast(^Nested_Output)data
	n := o.backend
	o.close = nil; out.finish(&o.output)
	if len(n.outputs) == 0 { destroy(&n.base) }
}

nested_window :: proc(b: ^Backend) -> ^out.Output {
	n := cast(^Nested)b.data
	if n.remote.failed { return nil }
	o := new(Nested_Output); o.backend, o.width, o.height = n,1280,720
	n.next += 1
	out.init(&o.output,&nested_output_impl,b.display,fmt.tprintf("NESTED-%d",n.next))
	o.output.data = o
	out.set_description(&o.output,fmt.tprintf("Nested output %d",n.next))
	out.set_formats(&o.output,n.formats[:])
	append(&n.outputs,o)
	o.surface = wl.proxy_new(n.remote,&p.wl_surface,4,nested_surface_event,o)
	wl.proxy_request(n.compositor,0,wl.Proxy_Object(o.surface))
	o.shell = wl.proxy_new(n.remote,&p.xdg_surface,1,nested_configure,o)
	wl.proxy_request(n.wm,2,wl.Proxy_Object(o.shell),wl.Proxy_Object(o.surface))
	o.toplevel = wl.proxy_new(n.remote,&p.xdg_toplevel,1,nested_toplevel,o)
	wl.proxy_request(o.shell,1,wl.Proxy_Object(o.toplevel))
	wl.proxy_request(o.toplevel,2,wl.String{value="kiln"})
	wl.proxy_request(o.toplevel,3,wl.String{value="kiln"})
	wl.proxy_request(o.toplevel,8,wl.Int(1280),wl.Int(720))
	if n.decoration != nil {
		o.decoration = wl.proxy_new(n.remote,&p.zxdg_toplevel_decoration_v1,1)
		wl.proxy_request(n.decoration,1,wl.Proxy_Object(o.decoration),wl.Proxy_Object(o.toplevel))
		wl.proxy_request(o.decoration,1,wl.Uint(2))
	}
	wl.proxy_request(o.surface,6)
	if !wl.remote_roundtrip(n.remote) || !o.configured { out.finish(&o.output); return nil }
	wl.proxy_request(o.toplevel,8,wl.Int(0),wl.Int(0))
	o.announced = true
	if b.started { wl.signal_emit_mutable(&b.events.new_output,&o.output) }
	return &o.output
}
nested_start :: proc(b: ^Backend) -> bool {
	b.started = true
	n := cast(^Nested)b.data
	for s in n.seats { nested_capabilities(s) }
	return nested_window(b) != nil
}

nested_buffer_destroy :: proc(v: ^Nested_Buffer) {
	wl.unlisten(&v.retire)
	for o in v.backend.outputs { if o.attached == v { o.attached = nil } }
	wl.proxy_release(v.proxy,0)
	for other,i in v.backend.buffers { if other == v { ordered_remove(&v.backend.buffers,i); break } }
	if v.busy { gles.buffer_release(v.buffer) }
	free(v)
}
nested_buffer_retired :: proc(l: ^wl.Listener, data: rawptr) {
	v := wl.owner(l,Nested_Buffer,"retire")
	wl.unlisten(l); v.retired = true
	if !v.busy { nested_buffer_destroy(v) }
}
nested_buffer_release :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	v := cast(^Nested_Buffer)proxy.data
	if v.retired { nested_buffer_destroy(v); return }
	if v.busy { v.busy = false; gles.buffer_release(v.buffer) }
}
nested_buffer :: proc(n: ^Nested, b: ^gles.Buffer) -> ^Nested_Buffer {
	for v in n.buffers { if v.buffer == b { return v } }
	v := new(Nested_Buffer); v.backend, v.buffer = n,b
	params := wl.proxy_new(n.remote,&p.zwp_linux_buffer_params_v1,4)
	if params == nil { free(v); return nil }
	wl.proxy_request(n.dmabuf,1,wl.Proxy_Object(params))
	v.proxy = wl.proxy_new(n.remote,&p.wl_buffer,1,nested_buffer_release,v)
	if v.proxy == nil { wl.proxy_release(params,0); free(v); return nil }
	for plane,i in b.planes[:b.n_planes] {
		wl.proxy_request(params,1,wl.Fd(plane.fd),wl.Uint(i),wl.Uint(plane.offset),wl.Uint(plane.stride),wl.Uint(b.modifier>>32),wl.Uint(b.modifier&0xffffffff))
	}
	ok := wl.proxy_request(params,3,wl.Proxy_Object(v.proxy),wl.Int(b.width),wl.Int(b.height),wl.Uint(b.format),wl.Uint(0))
	wl.proxy_release(params,0)
	if !ok { wl.proxy_release(v.proxy,0); free(v); return nil }
	wl.listen(&b.events.retire,&v.retire,nested_buffer_retired)
	append(&n.buffers,v)
	return v
}
nested_frame :: proc(proxy: ^wl.Proxy, opcode: u32, args: []wl.Argument) {
	o := cast(^Nested_Output)proxy.data
	wl.proxy_release(proxy); o.frame = nil
	if o.presented { o.presented = false; out.send_present(&o.output,out.Present_Event{commit_seq=o.seq,presented=true}) }
	if o.output.needs_frame { out.send_frame(&o.output) }
}
nested_frame_request :: proc(o: ^Nested_Output) -> bool {
	if o.frame != nil { return true }
	o.frame = wl.proxy_new(o.backend.remote,&p.wl_callback,1,nested_frame,o)
	return wl.proxy_request(o.surface,3,wl.Proxy_Object(o.frame))
}
nested_schedule :: proc(output: ^out.Output) {
	o := cast(^Nested_Output)output.data
	if o.frame == nil && nested_frame_request(o) { wl.proxy_request(o.surface,6) }
}
nested_commit :: proc(output: ^out.Output, state: ^out.State) -> bool {
	o := cast(^Nested_Output)output.data
	if o.backend.remote.failed || .Adaptive_Sync in state.committed && state.adaptive_sync { return false }
	if .Enabled in state.committed && !state.enabled {
		wl.proxy_release(o.frame); o.frame = nil; o.presented = false
		o.configured = false; o.attached = nil
		return wl.proxy_request(o.surface,1,wl.Proxy_Object(nil),wl.Int(0),wl.Int(0)) && wl.proxy_request(o.surface,6)
	}
	if .Buffer not_in state.committed { return true }
	if !o.configured {
		wl.proxy_request(o.surface,6)
		if !wl.remote_roundtrip(o.backend.remote) || !o.configured { return false }
	}
	v := nested_buffer(o.backend,state.buffer)
	if v == nil { return false }
	// Reusing the current image for a state change must not reattach an unreleased buffer.
	if v.busy && o.attached != v { return false }
	if !v.busy {
		gles.buffer_retain(v.buffer); v.busy = true
		if !wl.proxy_request(o.surface,1,wl.Proxy_Object(v.proxy),wl.Int(0),wl.Int(0)) { return false }
		o.attached = v
	}
	if !wl.proxy_request(o.surface,9,wl.Int(0),wl.Int(0),wl.Int(state.buffer.width),wl.Int(state.buffer.height)) ||
	   !nested_frame_request(o) || !wl.proxy_request(o.surface,6) { return false }
	o.seq, o.presented = output.commit_seq+1,true
	return true
}

nested_output_destroy :: proc(output: ^out.Output) {
	o := cast(^Nested_Output)output.data
	wl.remove_source(o.close)
	for s in o.backend.seats { if s.entered == o { s.entered = nil; delete(s.pointer.output_name); s.pointer.output_name = "" } }
	wl.proxy_release(o.frame)
	wl.proxy_release(o.decoration,0); wl.proxy_release(o.toplevel,0)
	wl.proxy_release(o.shell,0); wl.proxy_release(o.surface,0)
	for other,i in o.backend.outputs { if other == o { ordered_remove(&o.backend.outputs,i); break } }
	free(o)
}
nested_destroy :: proc(b: ^Backend) {
	n := cast(^Nested)b.data
	wl.remove_source(n.failure)
	for len(n.outputs) > 0 { out.finish(&n.outputs[len(n.outputs)-1].output) }
	for len(n.seats) > 0 { nested_seat_destroy(n.seats[len(n.seats)-1]) }
	for len(n.buffers) > 0 { nested_buffer_destroy(n.buffers[len(n.buffers)-1]) }
	for parent in n.parents { free(parent) }
	if len(n.table) > 0 { linux.munmap(raw_data(n.table),uint(len(n.table)*16)) }
	for f in n.formats { delete(f.modifiers) }
	delete(n.formats); delete(n.outputs); delete(n.parents); delete(n.seats); delete(n.buffers)
	wl.remote_close(n.remote)
	if b.drm_fd >= 0 { linux.close(linux.Fd(b.drm_fd)) }
	free(n)
}
