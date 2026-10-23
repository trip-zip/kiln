package wayland_c

import wl "../wayland"

FD_Callback :: #type proc "c" (_: i32, _: u32, _: rawptr) -> i32
Timer_Callback :: #type proc "c" (_: rawptr) -> i32
Idle_Callback :: #type proc "c" (_: rawptr)
Bind_Callback :: #type proc "c" (_: ^wl.Client, _: rawptr, _: u32, _: u32)
Source_Callback :: struct {
	fd:    FD_Callback,
	timer: Timer_Callback,
	idle:  Idle_Callback,
	data:  rawptr,
}
source_cleanup :: proc(data: rawptr) {free(cast(^Source_Callback)data)}
finish_source :: proc(source: ^wl.Source, callback: ^Source_Callback) -> ^wl.Source {
	if source == nil {free(callback)} else {source.cleanup = source_cleanup}
	return source
}
add_fd :: proc(
	loop: ^wl.Loop,
	fd: i32,
	mask: u32,
	callback: FD_Callback,
	data: rawptr,
) -> ^wl.Source {
	context = loop.ctx
	bridge := new(Source_Callback); bridge.fd, bridge.data = callback, data
	source := wl.loop_on_fd(
		loop,
		fd,
		transmute(wl.Mask)mask,
		proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
			b := cast(^Source_Callback)data; return b.fd(fd, transmute(u32)mask, b.data)
		},
		bridge,
	)
	return finish_source(source, bridge)
}
add_timer :: proc(loop: ^wl.Loop, callback: Timer_Callback, data: rawptr) -> ^wl.Source {
	context = loop.ctx
	bridge := new(Source_Callback); bridge.timer, bridge.data = callback, data
	source := wl.loop_on_timer(
		loop,
		proc(data: rawptr) -> i32 {b := cast(^Source_Callback)data; return b.timer(b.data)},
		bridge,
	)
	return finish_source(source, bridge)
}
add_idle :: proc(loop: ^wl.Loop, callback: Idle_Callback, data: rawptr) -> ^wl.Source {
	context = loop.ctx
	bridge := new(Source_Callback); bridge.idle, bridge.data = callback, data
	source := wl.loop_on_idle(
		loop,
		proc(data: rawptr) {b := cast(^Source_Callback)data; b.idle(b.data)},
		bridge,
	)
	return finish_source(source, bridge)
}
add_global :: proc(
	display: ^wl.Display,
	iface: ^wl.Interface,
	version: i32,
	data: rawptr,
	bind: Bind_Callback,
) -> ^wl.Global {
	global := wl.global_create(
		display,
		iface,
		version,
		data,
		proc(g: ^wl.Global, c: ^wl.Client, v, id: u32) {Bind_Callback(g.c_bind)(c, g.data, v, id)},
	)
	if global != nil {global.c_bind = rawptr(bind)}
	return global
}
destroy_resource :: proc(resource: ^wl.Resource) {
	callback := cast(proc "c" (_: ^wl.Resource))resource.c_destructor
	callback(resource)
}

C_Argument :: struct #raw_union {
	i: i32,
	u: u32,
	f: i32,
	s: cstring,
	o: ^wl.Resource,
	n: u32,
	a: ^wl.Array,
	h: i32,
}
#assert(size_of(C_Argument) == 8)
Dispatch :: #type proc "c" (client: ^wl.Client, resource: ^wl.Resource, a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19: uintptr)
dispatch :: proc(resource: ^wl.Resource, opcode: u32, args: []wl.Argument) {
	values: [20]uintptr
	arrays: [20]wl.Array
	for arg, i in args {
		switch v in arg {
		case wl.Int:
			values[i] = uintptr(u32(v))
		case wl.Uint:
			values[i] = uintptr(v)
		case wl.Fixed:
			values[i] = uintptr(u32(v))
		case wl.String:
			if !v.is_null {values[i] = uintptr(raw_data(v.value))}
		case wl.Object:
			values[i] = uintptr(v)
		case wl.New_Id:
			values[i] = uintptr(v)
		case wl.Array:
			arrays[i] = v; values[i] = uintptr(&arrays[i])
		case wl.Fd:
			values[i] = uintptr(u32(v))
		}
	}
	table := cast([^]rawptr)resource.implementation
	assert(table != nil && table[opcode] != nil)
	Dispatch(table[opcode])(
		resource.client,
		resource,
		values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7], values[8], values[9], values[10], values[11], values[12], values[13], values[14], values[15], values[16], values[17], values[18], values[19],
	)
}
event :: proc(resource: ^wl.Resource, opcode: u32, values: []uintptr) {
	args: [20]wl.Argument
	signature := wl.Signature {
		text = string(resource.interface.events[opcode].signature),
	}
	count := 0
	for {
		kind, _, more := wl.argument_next(&signature)
		if !more {break}
		value := values[count]
		switch kind {
		case 'i':
			args[count] = wl.Int(u32(value))
		case 'u':
			args[count] = wl.Uint(u32(value))
		case 'f':
			args[count] = wl.Fixed(u32(value))
		case 's':
			z := cstring(rawptr(value)); args[count] = wl.String {
				value   = string(z),
				is_null = z == nil,
			}
		case 'o', 'n':
			args[count] = wl.Object(rawptr(value))
		case 'a':
			assert(value != 0); args[count] = (cast(^wl.Array)rawptr(value))^
		case 'h':
			args[count] = wl.Fd(u32(value))
		}
		count += 1
	}
	wl.post(resource, opcode, ..args[:count])
}
