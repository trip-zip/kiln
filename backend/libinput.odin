package backend

import li "../libinput"
import wl "../wayland"
import "core:fmt"
import "core:os"
import "core:strings"

Input :: struct {
	backend: ^Backend,
	handle: ^li.libinput,
	source: ^wl.Source,
	active: wl.Listener,
	paths: [dynamic]Input_Path,
	devices: [dynamic]^Input_Device,
	suspended: bool,
}
Input_Path :: struct { path: string, handle: ^li.libinput_device }
Input_Device :: struct { input: ^Input, handle: ^li.libinput_device, keyboard: Keyboard, pointer: Pointer, has_keyboard, has_pointer: bool }
input_interface := li.libinput_interface{input_open,input_close}
input_open :: proc "c" (path: cstring, flags: i32, data: rawptr) -> i32 {
	i := cast(^Input)data; context = i.backend.loop.ctx
	return session_open(i.backend.session,string(path),flags)
}
input_close :: proc "c" (fd: i32, data: rawptr) { i := cast(^Input)data; context = i.backend.loop.ctx; session_close(i.backend.session,fd) }
input_create :: proc(b: ^Backend) -> ^Input {
	i := new(Input); i.backend = b
	i.handle = li.libinput_path_create_context(&input_interface,i)
	if i.handle == nil { free(i); return nil }
	li.libinput_log_set_priority(i.handle,.LIBINPUT_LOG_PRIORITY_INFO)
	i.source = wl.loop_on_fd(b.loop,li.libinput_get_fd(i.handle),{.Readable},input_ready,i)
	if i.source == nil { input_destroy(i); return nil }
	wl.listen(&b.session.events.active,&i.active,input_active)
	if !b.session.active { li.libinput_suspend(i.handle); i.suspended = true }
	input_scan(i)
	input_ready(0,{},i)
	return i
}
input_scan :: proc(i: ^Input) {
	if i == nil || i.suspended { return }
	entries,_ := os.read_all_directory_by_path("/dev/input",context.temp_allocator)
	for e in entries { if input_event_name(e.name) { input_add(i,fmt.tprintf("/dev/input/%s",e.name)) } }
}
input_event_name :: proc(name: string) -> bool {
	if !strings.has_prefix(name,"event") || len(name) == 5 { return false }
	for c in name[5:] { if c < '0' || c > '9' { return false } }; return true
}
input_add :: proc(i: ^Input, path: string) {
	for p in i.paths { if p.path == path { return } }
	device := li.libinput_path_add_device(i.handle,strings.clone_to_cstring(path,context.temp_allocator))
	if device != nil { append(&i.paths,Input_Path{strings.clone(path),li.libinput_device_ref(device)}) }
}
input_remove :: proc(i: ^Input, path: string) {
	for p,n in i.paths { if p.path == path {
		li.libinput_path_remove_device(p.handle); li.libinput_device_unref(p.handle)
		delete(p.path); ordered_remove(&i.paths,n); return
	} }
}
input_active :: proc(l: ^wl.Listener, data: rawptr) {
	i := wl.owner(l,Input,"active")
	if i.backend.session.active {
		if i.suspended {
			if li.libinput_resume(i.handle) != 0 { fmt.eprintln("libinput: resume failed"); drm_failed(cast(^DRM)i.backend.data); return }
			i.suspended = false; input_scan(i)
		}
	} else if !i.suspended { i.suspended = true; li.libinput_suspend(i.handle) }
	input_ready(0,{},i)
}
input_leds :: proc(k: ^Keyboard, leds: u32) { li.libinput_device_led_update(k.base.libinput,i32(leds&7)) }
input_added :: proc(i: ^Input, handle: ^li.libinput_device) {
	d := new(Input_Device); d.input, d.handle = i,li.libinput_device_ref(handle)
	name := string(li.libinput_device_get_name(handle))
	for &path in i.paths { if path.path == fmt.tprintf("/dev/input/%s",li.libinput_device_get_sysname(handle)) && path.handle != handle {
		li.libinput_device_unref(path.handle); path.handle = li.libinput_device_ref(handle)
	} }
	d.has_keyboard, d.has_pointer = li.libinput_device_has_capability(handle,0) != 0,li.libinput_device_has_capability(handle,1) != 0
	append(&i.devices,d)
	if d.has_keyboard {
		k := &d.keyboard; k.base = {kind=.Keyboard,name=strings.clone(name),libinput=handle}; k.leds = input_leds
		wl.signal_init(&k.base.events.destroy); wl.signal_init(&k.events.key)
		wl.signal_emit_mutable(&i.backend.events.new_input,&k.base)
	}
	if d.has_pointer {
		p := &d.pointer; p.base = {kind=.Pointer,name=strings.clone(name),libinput=handle}
		p.output_name = strings.clone(string(li.libinput_device_get_output_name(handle)))
		for signal in ([]^wl.Signal{&p.base.events.destroy,&p.events.motion,&p.events.motion_absolute,&p.events.button,&p.events.axis,&p.events.frame}) { wl.signal_init(signal) }
		wl.signal_emit_mutable(&i.backend.events.new_input,&p.base)
	}
}
input_device_destroy :: proc(d: ^Input_Device) {
	if d.has_keyboard { wl.signal_emit_final(&d.keyboard.base.events.destroy,&d.keyboard.base); delete(d.keyboard.base.name) }
	if d.has_pointer { wl.signal_emit_final(&d.pointer.base.events.destroy,&d.pointer.base); delete(d.pointer.base.name); delete(d.pointer.output_name) }
	for other,n in d.input.devices { if other == d { ordered_remove(&d.input.devices,n); break } }
	li.libinput_device_unref(d.handle); free(d)
}
input_ready :: proc(fd: i32, mask: wl.Mask, data: rawptr) -> i32 {
	i := cast(^Input)data
	if li.libinput_dispatch(i.handle) != 0 { fmt.eprintln("libinput: dispatch failed"); drm_failed(cast(^DRM)i.backend.data); return 0 }
	for {
		event := li.libinput_get_event(i.handle); if event == nil { break }
		input_event(i,event); li.libinput_event_destroy(event)
	}
	return 0
}
input_event :: proc(i: ^Input, event: ^li.libinput_event) {
	type := li.libinput_event_get_type(event); handle := li.libinput_event_get_device(event)
	if type == 1 { input_added(i,handle); return }
	d: ^Input_Device; for device in i.devices { if device.handle == handle { d = device; break } }; if d == nil { return }
	if type == 2 { input_device_destroy(d); return }
	if type == 300 && d.has_keyboard {
		key := li.libinput_event_get_keyboard_event(event)
		e := Key_Event{u32(li.libinput_event_keyboard_get_time_usec(key)/1000),li.libinput_event_keyboard_get_key(key),li.libinput_event_keyboard_get_key_state(key)}
		wl.signal_emit_mutable(&d.keyboard.events.key,&e); return
	}
	if !d.has_pointer || type < 400 || type > 406 || type == 403 { return }
	p := &d.pointer; motion := li.libinput_event_get_pointer_event(event); time := u32(li.libinput_event_pointer_get_time_usec(motion)/1000)
	switch type {
	case 400:
		e := Motion_Event{p,time,li.libinput_event_pointer_get_dx(motion),li.libinput_event_pointer_get_dy(motion),li.libinput_event_pointer_get_dx_unaccelerated(motion),li.libinput_event_pointer_get_dy_unaccelerated(motion)}
		wl.signal_emit_mutable(&p.events.motion,&e)
	case 401:
		e := Motion_Absolute_Event{p,time,li.libinput_event_pointer_get_absolute_x_transformed(motion,1),li.libinput_event_pointer_get_absolute_y_transformed(motion,1)}
		wl.signal_emit_mutable(&p.events.motion_absolute,&e)
	case 402:
		e := Button_Event{p,time,li.libinput_event_pointer_get_button(motion),li.libinput_event_pointer_get_button_state(motion)}
		wl.signal_emit_mutable(&p.events.button,&e)
	case 404,405,406:
		for axis: i32 = 0; axis < 2; axis += 1 { if li.libinput_event_pointer_has_axis(motion,axis) != 0 {
			e := Axis_Event{pointer=p,time_msec=time,source=type-404,orientation=axis,delta=li.libinput_event_pointer_get_scroll_value(motion,axis),relative_direction=i32(li.libinput_device_config_scroll_get_natural_scroll_enabled(handle) != 0)}
			if type == 404 { e.delta_discrete = i32(li.libinput_event_pointer_get_scroll_value_v120(motion,axis)) }
			wl.signal_emit_mutable(&p.events.axis,&e)
		} }
	}
	wl.signal_emit_mutable(&p.events.frame,p)
}
input_destroy :: proc(i: ^Input) {
	if i == nil { return }
	wl.unlisten(&i.active); wl.remove_source(i.source)
	for len(i.devices) > 0 { input_device_destroy(i.devices[len(i.devices)-1]) }
	for p in i.paths { li.libinput_path_remove_device(p.handle); li.libinput_device_unref(p.handle); delete(p.path) }
	li.libinput_unref(i.handle); delete(i.paths); delete(i.devices); free(i)
}
