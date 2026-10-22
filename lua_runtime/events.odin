package lua_runtime

import "base:runtime"
import "core:c"
import "core:fmt"
import lua "../luajit"

Native_Input :: enum { None, Key, Modifiers, DeviceMotion, Motion, Button, Axis, Frame }
Event :: struct {
    lock_generation:u64,
    notification: ^Notification,
    service,item_id,status:string,
    item_has_id,item_has_title,item_has_status,item_has_icon:bool,
	pointer_device, motion_output: u64,
	allocator: runtime.Allocator,
	id, generation: u64,
	fd, exit_code: i32,
	bytes: string,
	dt: f64,
	native: Native_Input,
	keyboard, routing_epoch: u64,
	time, code: u32,
	blocked, claimed: bool,
	mask: [4]u32,
	orientation, source, direction, discrete: i32,
	delta: f64,
	name: string,
	class: string,
	output, key, utf8: string,
	has_output: bool,
	namespace: string,
	layer, interactivity: i32,
	anchors: u32,
	exclusive: i32,
	margin: [4]i32,
	desired_width, desired_height: u32,
	buffer_mapped, native_surface: bool,
	px, py, dx, dy, ux, uy: f64,
	absolute: bool,
	keysym, mods, button: u32,
	pressed, on, valid: bool,
	handle, parent: u32,
	map_epoch: u64,
	x, y, width, height: i32,
	app_id, title: string,
	wm_class,wm_instance,role,icon,window_type: string,
	has_wm_class,has_wm_instance: bool,
	pid: i32,
	override_redirect,wants_focus: bool,
	has_app_id, has_title: bool,
	fullscreen, maximized, minimized: bool,
}

event_call :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := (^Runtime)(lua.touserdata(L, 1))
	e := r.event
	lua.rawgeti(L, lua.REGISTRYINDEX, r.event_ref)
	lua.newtable(L)
	class := e.class
	if class == "" { class = "client" }
	push_string(L, class); lua.setfield(L, -2, "class")
	push_string(L, e.name); lua.setfield(L, -2, "name")
	switch class {
    case "session":
        if e.name=="authenticated" { number(L,"id",f64(e.id));boolean(L,"success",e.on);push_string(L,e.bytes);lua.setfield(L,-2,"reason") }
        if e.name=="lock" { push_string(L,e.bytes);lua.setfield(L,-2,"kind") }
        if e.name=="key" {
            number(L,"keysym",f64(e.keysym));push_string(L,e.key);lua.setfield(L,-2,"key")
            push_string(L,e.utf8);lua.setfield(L,-2,"utf8");boolean(L,"pressed",e.pressed)
            lua.newtable(L)
            boolean(L,"shift",e.mods&1!=0);boolean(L,"ctrl",e.mods&4!=0)
            boolean(L,"alt",e.mods&8!=0);boolean(L,"super",e.mods&64!=0)
            lua.setfield(L,-2,"mods")
        }
    case "idle":
        if e.name=="inhibit" { boolean(L,"on",e.on) }
    case "notify":
        if e.notification!=nil { notification_fields(L,e.notification) } else { number(L,"id",f64(e.id)) }
    case "tray":
        if e.name=="item" { number(L,"_order",f64(e.id)) }
        push_string(L,e.service);lua.setfield(L,-2,"service")
        for field,i in ([4]cstring{"id","title","status","icon"}) {
            value:=([4]string{e.item_id,e.title,e.status,e.icon})[i]
            present:=[4]bool{e.item_has_id,e.item_has_title,e.item_has_status,e.item_has_icon}
            if present[i] { push_string(L,value);lua.setfield(L,-2,field) }
        }
	case "spawn":
		number(L,"id",f64(e.id))
		if e.name=="out" {
			number(L,"fd",f64(e.fd));push_string(L,e.bytes);lua.setfield(L,-2,"data")
		} else { number(L,"code",f64(e.exit_code)) }
	case "frame":
		push_string(L,e.output);lua.setfield(L,-2,"screen");number(L,"dt",e.dt)
	case "client":
		number(L, "handle", f64(e.handle))
		if e.name=="request::activate" {
			boolean(L,"valid",e.valid)
			if e.has_app_id { push_string(L,e.app_id);lua.setfield(L,-2,"app_id") }
		}
		if e.name=="request::urgent" { boolean(L,"urgent",e.on) }
		if e.name=="request::decoration_mode" { push_string(L,e.bytes);lua.setfield(L,-2,"mode") }
		if e.name == "map" {
			if e.pid>0 { number(L,"pid",f64(e.pid)) }
			if e.override_redirect { boolean(L,"override_redirect",true); boolean(L,"wants_focus",e.wants_focus) }
			if e.parent != 0 { number(L, "transient_for", f64(e.parent)) }
			number(L, "x", f64(e.x)); number(L, "y", f64(e.y))
			if e.fullscreen { boolean(L, "fullscreen", true) }
			if e.maximized { boolean(L, "maximized", true) }
			if e.minimized { boolean(L, "minimized", true) }
		}
		if e.name=="request::configure" { number(L,"x",f64(e.x));number(L,"y",f64(e.y)) }
		if e.name == "map" || e.name == "commit_size" || e.name=="request::configure" {
			number(L, "width", f64(e.width)); number(L, "height", f64(e.height))
		}
		if e.name == "map" || e.name == "metadata" {
            if e.parent!=0 { number(L,"transient_for",f64(e.parent)) }
            if e.pid>0 { number(L,"pid",f64(e.pid)) }
            if e.role!="" { push_string(L,e.role);lua.setfield(L,-2,"role") }
            if e.icon!="" { push_string(L,e.icon);lua.setfield(L,-2,"icon") }
            if e.window_type!="" { push_string(L,e.window_type);lua.setfield(L,-2,"window_type") }
			if e.has_wm_class { push_string(L,e.wm_class);lua.setfield(L,-2,"wm_class") }
			if e.has_wm_instance { push_string(L,e.wm_instance);lua.setfield(L,-2,"wm_instance") }
			if e.has_app_id { push_string(L, e.app_id); lua.setfield(L, -2, "app_id") }
			if e.has_title { push_string(L, e.title); lua.setfield(L, -2, "title") }
		}
		if e.name == "request::fullscreen" || e.name == "request::maximize" || e.name == "request::minimize" {
			boolean(L, "on", e.on)
		}
	case "layer":
		number(L,"handle",f64(e.handle))
		if e.name=="map" || e.name=="commit" || e.name=="mapped" {
			push_string(L,e.namespace);lua.setfield(L,-2,"namespace")
			if e.has_output { push_string(L,e.output);lua.setfield(L,-2,"output") }
			names := [4]string{"background","bottom","top","overlay"}
			interactivity := [3]string{"none","exclusive","on_demand"}
			push_string(L,names[clamp(e.layer,0,3)]);lua.setfield(L,-2,"layer")
			push_string(L,interactivity[clamp(e.interactivity,0,2)]);lua.setfield(L,-2,"interactivity")
			number(L,"width",f64(e.desired_width));number(L,"height",f64(e.desired_height))
			number(L,"exclusive",f64(e.exclusive));boolean(L,"buffer_mapped",e.buffer_mapped)
			lua.newtable(L)
			for key,i in ([4]cstring{"top","bottom","left","right"}) { boolean(L,key,e.anchors & (u32(1)<<u32(i)) != 0) }
			lua.setfield(L,-2,"anchors")
			lua.newtable(L)
			for key,i in ([4]cstring{"top","right","bottom","left"}) { number(L,key,f64(e.margin[i])) }
			lua.setfield(L,-2,"margin")
		}
	case "output":
		push_string(L, e.output); lua.setfield(L, -2, "output")
	case "input":
		if e.claimed { boolean(L,"_claimed",true) }
		switch e.name {
		case "key":
			number(L, "keysym", f64(e.keysym))
			push_string(L, e.key); lua.setfield(L, -2, "key")
			push_string(L, e.utf8); lua.setfield(L, -2, "utf8")
			boolean(L, "pressed", e.pressed)
		case "pointer_enter", "focus":
			if e.handle != 0 { number(L, "handle", f64(e.handle)) }
		case "motion", "button", "axis":
			if e.native_surface { boolean(L,"surface",true) }
			number(L, "x", e.px); number(L, "y", e.py)
			if e.has_output { push_string(L, e.output); lua.setfield(L, -2, "screen") }
			if e.handle != 0 { number(L, "client", f64(e.handle)) }
			if e.name == "button" { number(L, "button", f64(e.button)); boolean(L, "pressed", e.pressed) }
			if e.name == "axis" { number(L, "dx", e.dx); number(L, "dy", e.dy) }
		}
		if e.name == "key" || e.name == "button" || e.name == "axis" {
			lua.newtable(L)
			boolean(L, "shift", e.mods & 1 != 0); boolean(L, "ctrl", e.mods & 4 != 0)
			boolean(L, "alt", e.mods & 8 != 0); boolean(L, "super", e.mods & 64 != 0)
			lua.setfield(L, -2, "mods")
		}
	}
	lua.call(L, 1, 0)
	return 0
}

deliver :: proc(r: ^Runtime, event: ^Event) -> bool {
	if r.event_ref == lua.NOREF || r.state == nil { return true }
	r.event = event
	defer r.event = nil
	base := lua.gettop(r.state)
	defer lua.settop(r.state, base)
	if lua.cpcall(r.state, event_call, r) != .OK {
		fmt.eprintln("Lua event:", lua.tostring(r.state, -1))
		return false
	}
	return true
}

boolean :: proc(L: ^lua.State, key: cstring, value: bool) {
	lua.pushboolean(L, b32(value)); lua.setfield(L, -2, key)
}
