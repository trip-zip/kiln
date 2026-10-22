package lua_runtime

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sys/posix"
import "core:sys/linux"
import lua "../luajit"
import paint "../paint"
import images "../images"
import layout "../layout"
import "../keymap"
import cfg "../input_config"

Mode :: struct { width, height, refresh: i32 }
Output :: struct {
	name: string,
	width, height, refresh, x, y: i32,
	logical_width, logical_height: i32,
	scale: f64,
	enabled: bool,
	modes: [32]Mode,
	mode_count: int,
}
Runtime :: struct {
    capture: proc(rawptr,string,cstring)->string,
    inspect:proc(rawptr,string,i32,f64)->bool,
    inspect_scroll:proc(rawptr,string,f32,f32)->f32,
    authenticate:proc(rawptr,string)->u64,
    lock_state:proc(rawptr)->Lock_State,
    lock,unlock:proc(rawptr)->bool,
    set_idle_timeout: proc(rawptr,i32),
    notify_closed: proc(rawptr,u32,i32),
    notify_action: proc(rawptr,u32,string),
    tray_activate: proc(rawptr,string,string,i32,string),
	state: ^lua.State,
	allocator: runtime.Allocator,
	data: rawptr,
	output: proc(rawptr, int) -> (Output, bool),
	output_set: proc(rawptr, string, Output_Change),
	quit: proc(rawptr),
	timer_add: proc(rawptr, u64, i32) -> bool,
	timer_remove: proc(rawptr, u64),
	timer_refs: map[u64]c.int,
	next_timer: u64,
	timer_ref: c.int,
	spawn_pipe: proc(rawptr, []cstring) -> u64,
	mint_token: proc(rawptr) -> (rawptr,cstring),
	retire_token: proc(rawptr,rawptr),
	tick: proc(rawptr, string, bool),
	replay, discover, request_reload, reset_clocks: proc(rawptr),
	config_path: cstring,
	loading_config, reload_pending, reloading: bool,
	reload_ref: c.int,
	config_generation: u64,
	focus: proc(rawptr, u32),
	configure_layer: proc(rawptr, u32, u32, u32),
	configure_client: proc(rawptr, u32, i32, i32),
	tiled_client: proc(rawptr, u32, u32),
	mirror_client: proc(rawptr, u32, string),
	layer_answers: [dynamic]Layer_Answer,
	activate, fullscreen, maximize, minimize, suspend: proc(rawptr, u32, bool),
	focused, focus_target: proc(rawptr) -> u32,
	close_client, kill_client: proc(rawptr, u32),
	set_keymap: proc(rawptr, keymap.Names),
	set_repeat: proc(rawptr, i32, i32),
	set_numlock, grab_keyboard, grab_pointer: proc(rawptr, bool),
	set_pointer: proc(rawptr, cfg.Pointer),
	set_cursor: proc(rawptr, cstring),
	set_cursor_theme: proc(rawptr, cstring, u32),
	bindings: []keymap.Chord,
	frame_ref, event_ref, lock_ref: c.int,
    lock_declaring: bool,
	ui_begin_ref, ui_publish_ref: c.int,
	declaring: bool,
	frame: layout.Frame,
	fonts: paint.Fonts,
	images: images.Cache,
	ids, surfaces: map[u32]bool,
	current_layout, frame_layout: ^layout.Layout,
	screen: string,
	width, height: i32,
	valid_client: proc(rawptr, u32, string) -> bool,
	find_layout: proc(rawptr, string) -> (^layout.Layout, i32, i32),
	dirty: proc(rawptr, string, bool),
	hit_result: []layout.Hit,
	event: ^Event,
	request, reply: string,
	reply_allocator: runtime.Allocator,
}

init :: proc(r: ^Runtime) -> bool {
	r.allocator = context.allocator
	images.init(&r.images)
	paint.intern_font(&r.fonts,"Sans")
	r.frame_ref, r.event_ref, r.reload_ref = lua.NOREF, lua.NOREF, lua.NOREF
	r.lock_ref=lua.NOREF
	r.ui_begin_ref,r.ui_publish_ref=lua.NOREF,lua.NOREF
	r.timer_refs = make(map[u64]c.int)
	r.ids, r.surfaces = make(map[u32]bool), make(map[u32]bool)
	r.state = lua.L_newstate()
	if r.state == nil { return false }
	if lua.cpcall(r.state, setup, r) != .OK {
		fmt.eprintln("Lua initialization:", lua.tostring(r.state, -1))
		lua.settop(r.state, 0)
		return false
	}
	return true
}
destroy :: proc(r: ^Runtime) {
	if r.state != nil {
		reply:=evaluate(r, "for _,n in ipairs{'kiln.desktop_services','kiln.grab','kiln.widgets','kiln.ui','kiln.spawn','kiln.animation'} do local m=package.loaded[n];if m then (m.reset or m._reset)() end end")
		delete(reply)
		reset_timers(r)
		lua.close(r.state); r.state = nil
	}
	layout.destroy_frame(&r.frame)
	paint.destroy_fonts(&r.fonts)
	images.destroy(&r.images)
	delete(r.config_path, r.allocator)
	delete(r.timer_refs)
	delete(r.bindings)
	delete(r.ids)
	delete(r.surfaces)
	delete(r.hit_result)
	delete(r.layer_answers)
}
setup :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := lua.touserdata(L, 1)
	lua.L_openlibs(L)
	lua.newtable(L)
	entries := []lua.L_Reg{{"inspector",inspector},{"inspector_scroll",inspector_scroll},{"screenshot",screenshot},{"set_lock_handler",set_lock_handler},{"authenticate",authenticate},{"_lock_state",lock_state},{"lock",lock},{"unlock",unlock},{"set_idle_timeout",set_idle_timeout},{"notify_closed",notify_closed},{"notify_action",notify_action},{"tray_activate",tray_activate},{"_monotonic",monotonic},{"layer_configure", layer_configure}, {"_clocks_reset", clocks_reset}, {"_config_path", config_path}, {"_reload", request_reload}, {"_frame_reset", reset_frame_handler}, {"timer", timer}, {"timer_cancel", timer_cancel}, {"_timers_reset", timers_reset}, {"spawn_pipe", pipe_spawn}, {"tick", tick}, {"_ui_hooks", ui_hooks}, {"set_key_bindings", set_key_bindings}, {"replay", replay}, {"_discover", discover}, {"spawn", spawn}, {"spawn_with_token", spawn_with_token}, {"quit", quit}, {"set_frame_handler", set_frame_handler}, {"set_event_handler", set_event_handler}}
	for entry in entries {
		lua.pushlightuserdata(L, r)
		lua.pushcclosure(L, entry.func, 1)
		lua.setfield(L, -2, entry.name)
	}
	lua.newtable(L)
	lua.pushlightuserdata(L, r)
	lua.pushcclosure(L, outputs, 1)
	lua.setfield(L, -2, "list")
	for entry in ([]lua.L_Reg{{"set_mode", output_mode}, {"set_scale", output_scale},
		{"set_position", output_position}, {"set_enabled", output_enabled},
		{"set_adaptive_sync", output_adaptive_sync}, {"_geometry", output_geometry}}) {
		lua.pushlightuserdata(L, r)
		lua.pushcclosure(L, entry.func, 1)
		lua.setfield(L, -2, entry.name)
	}
	lua.setfield(L, -2, "output")
	lua.newtable(L)
	verbs := []lua.L_Reg{{"configure", client_configure}, {"set_tiled_hint", client_tiled}, {"set_output_mirror", client_mirror}, {"set_fullscreen_hint", client_fullscreen}, {"set_maximized_hint", client_maximize}, {"set_suspended", client_suspend}, {"set_minimized_hint", client_minimize}, {"close", client_close}, {"kill", client_kill}, {"_focus_target", client_focus_target}, {"focus", client_focus}, {"set_activated", client_activate}, {"focused", client_focused}}
	for entry in verbs {
		lua.pushlightuserdata(L, r)
		lua.pushcclosure(L, entry.func, 1)
		lua.setfield(L, -2, entry.name)
	}
	lua.setfield(L, -2, "client")
	lua.newtable(L)
	for entry in ([]lua.L_Reg{{"set_keymap", input_keymap}, {"set_repeat", input_repeat}, {"set_numlock", input_numlock},
		{"set_pointer", input_pointer}, {"set_cursor", input_cursor}, {"set_cursor_theme", input_cursor_theme},
		{"grab_keyboard", input_grab_keyboard}, {"grab_pointer", input_grab_pointer}}) {
		lua.pushlightuserdata(L, r); lua.pushcclosure(L, entry.func, 1); lua.setfield(L, -2, entry.name)
	}
	lua.setfield(L, -2, "input")
	lua.setglobal(L, "core")
	if lua.L_loadstring(L, #load("eval.lua", cstring)) != .OK { return lua.error(L) }
	lua.call(L, 0, 0)
	if lua.L_loadstring(L, #load("declarations.lua", cstring)) != .OK { return lua.error(L) }
	lua.newtable(L)
	bridge := []lua.L_Reg{{"image_reload", image_reload}, {"font", font}, {"text", frame_text}, {"guard", frame_guard}, {"open", frame_open}, {"close", frame_close},
		{"contains", frame_contains}, {"box", read_box}, {"hits", read_hits}, {"dirty", mark_dirty}}
	for entry in bridge {
		lua.pushlightuserdata(L, r)
		lua.pushcclosure(L, entry.func, 1)
		lua.setfield(L, -2, entry.name)
	}
	lua.call(L, 1, 0)
	return 0
}
self :: proc(L: ^lua.State) -> ^Runtime {
	return (^Runtime)(lua.touserdata(L, lua.GLOBALSINDEX - 1))
}
quit :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	if r.quit != nil { r.quit(r.data) }
	return 0
}
number :: proc(L: ^lua.State, key: cstring, value: f64) {
	lua.pushnumber(L, lua.Number(value)); lua.setfield(L, -2, key)
}
outputs :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	lua.newtable(L)
	if r.output == nil { return 1 }
	for i in 0..<16 {
		o, ok := r.output(r.data, i)
		if !ok { break }
		lua.newtable(L)
		lua.pushlstring(L, cast(cstring)raw_data(o.name), c.size_t(len(o.name)))
		lua.setfield(L, -2, "name")
		number(L, "width", f64(o.width)); number(L, "height", f64(o.height))
		number(L, "refresh", f64(o.refresh)); number(L, "scale", o.scale)
		number(L, "x", f64(o.x)); number(L, "y", f64(o.y))
		lua.pushboolean(L, b32(o.enabled)); lua.setfield(L, -2, "enabled")
		lua.newtable(L)
		for m, j in o.modes[:o.mode_count] {
			lua.newtable(L)
			number(L, "width", f64(m.width)); number(L, "height", f64(m.height))
			number(L, "refresh", f64(m.refresh)); lua.rawseti(L, -2, c.int(j+1))
		}
		lua.setfield(L, -2, "modes")
		lua.rawseti(L, -2, c.int(i+1))
	}
	return 1
}
spawn :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    return spawn_command(L,false)
}
spawn_with_token :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    return spawn_command(L,true)
}
spawn_command :: proc(L: ^lua.State, with_token: bool) -> c.int {
	if !lua.istable(L, 1) && !lua.isstring(L, 1) {
		if with_token { return lua.L_error(L,"core.spawn_with_token takes an argv table or a string") }
		return lua.L_error(L, "core.spawn takes an argv table or a string")
	}
	count := 3
	table := lua.istable(L, 1)
	if table {
		count = int(lua.objlen(L, 1))
		// Invalid argv cannot exec, but spawn still has no result.
		if count == 0 { return 0 }
		lua.L_checkstack(L, c.int(count), "spawn argv")
		// Anchor converted strings on the Lua stack before owning Odin memory.
		for i in 0..<count {
			lua.rawgeti(L, 1, c.int(i+1))
			if !lua.isstring(L, -1) { return 0 }
			lua.tostring(L, -1)
		}
	} else { lua.tostring(L, 1) }
	argv := make([]cstring, count+1)
	defer delete(argv)
	if table {
		base := lua.gettop(L) - c.int(count) + 1
		for i in 0..<count { argv[i] = lua.tostring(L, base+c.int(i)) }
	} else { argv[0], argv[1], argv[2] = "/bin/sh", "-c", lua.tostring(L, 1) }
    r:=self(L)
    token: rawptr
    token_name: cstring
    if with_token {
        if r.mint_token!=nil { token,token_name=r.mint_token(r.data) }
        if token==nil || token_name==nil {
            if token!=nil { r.retire_token(r.data,token) }
            fmt.eprintln("core.spawn_with_token: token mint failed");return 0
        }
    }
    succeeded:=false
    defer { if token!=nil && !succeeded { r.retire_token(r.data,token) } }
    child_env: [dynamic]cstring
    entry: cstring
    if with_token {
        entry=fmt.caprintf("XDG_ACTIVATION_TOKEN=%s",token_name)
        for i:=0;posix.environ[i]!=nil;i+=1 {
            if !strings.has_prefix(string(posix.environ[i]),"XDG_ACTIVATION_TOKEN=") { append(&child_env,posix.environ[i]) }
        }
        append(&child_env,entry,nil)
    }
    defer delete(child_env)
    defer delete(entry)
    errors: [2]linux.Fd
    if linux.pipe2(&errors,{.CLOEXEC})!=nil { fmt.eprintln("core.spawn: error pipe failed");return 0 }
    defer posix.close(posix.FD(errors[0]))
    pid := posix.fork()
    if pid == 0 {
        posix.close(posix.FD(errors[0]))
        detached:=posix.fork()
        if detached<0 { spawn_child_failed(posix.FD(errors[1])) }
        if detached>0 { posix._exit(0) }
        if with_token { posix.environ=raw_data(child_env) }
		empty: posix.sigset_t
		posix.sigemptyset(&empty)
		posix.sigprocmask(.SETMASK, &empty, nil)
		posix.setsid()
		posix.execvp(argv[0], raw_data(argv))
		spawn_child_failed(posix.FD(errors[1]))
	}
	posix.close(posix.FD(errors[1]))
	if pid > 0 {
		for posix.waitpid(pid, nil, {}) < 0 && posix.errno() == .EINTR {}
	}
    if pid<0 { fmt.eprintln("core.spawn: fork failed");return 0 }
    failure: i32
    n: int
    for {
        n=int(posix.read(posix.FD(errors[0]),cast([^]u8)&failure,size_of(failure)))
        if n>=0 || posix.errno()!=.EINTR { break }
    }
    succeeded=n==0
    if !succeeded { fmt.eprintf("core.spawn: child setup or exec failed (%d)\n",failure) }
    return 0
}
spawn_child_failed :: proc(fd: posix.FD) {
    failure:=i32(posix.errno())
    for posix.write(fd,cast([^]u8)&failure,size_of(failure))<0 && posix.errno()==.EINTR {}
    posix._exit(127)
}

// The protected trampoline includes global lookup and argument allocation.
// Nothing it owns depends on an Odin defer surviving Lua's longjmp.
evaluate_call :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := (^Runtime)(lua.touserdata(L, 1))
	lua.getglobal(L, "kiln_eval")
	lua.pushlstring(L, cast(cstring)raw_data(r.request), c.size_t(len(r.request)))
	lua.call(L, 1, 1)
	n: c.size_t
	p := lua.tolstring(L, -1, &n)
	if p != nil {
		r.reply = strings.clone(string(([^]u8)(p)[:int(n)]), r.reply_allocator)
	}
	return 0
}
// The caller owns the copied reply, which can outlive the next VM call.
evaluate :: proc(r: ^Runtime, source: string) -> string {
	L := r.state
	base := lua.gettop(L)
	defer lua.settop(L, base)
	r.request, r.reply, r.reply_allocator = source, "", context.allocator
	defer r.request = ""
	if lua.cpcall(L, evaluate_call, r) != .OK {
		if lua.type(L, -1) != .STRING { return strings.clone("ERROR: ?\n") }
		msg := lua.tostring(L, -1)
		if msg == nil { return strings.clone("ERROR: ?\n") }
		return fmt.aprintf("ERROR: %s\n", msg)
	}
	return r.reply
}

replay :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	if r.replay != nil { r.replay(r.data) }
	return 0
}
discover :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	if r.discover != nil { r.discover(r.data) }
	return 0
}
client_focus :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	handle: u32
	if !lua.isnoneornil(L, 1) { handle = checked_handle(L, 1) }
	r := self(L)
	if r.focus != nil { r.focus(r.data, handle) }
	return 0
}
client_activate :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	handle := checked_handle(L, 1)
	r := self(L)
	if r.activate != nil { r.activate(r.data, handle, bool(lua.toboolean(L, 2))) }
	return 0
}
client_focused :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	handle: u32
	if r.focused != nil { handle = r.focused(r.data) }
	if handle == 0 { lua.pushnil(L) } else { lua.pushnumber(L, lua.Number(handle)) }
	return 1
}

checked_handle :: proc(L: ^lua.State, index: c.int) -> u32 {
	n := f64(lua.L_checknumber(L, index))
	if math.is_nan(n) || n < 1 || n > f64(max(u32)) || math.floor(n) != n {
		lua.L_error(L, "client handle must be a positive integer")
		return 0
	}
	return u32(n)
}

client_fullscreen :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	handle := checked_handle(L, 1)
	if lua.type(L, 2) != .BOOLEAN { return lua.L_error(L, "client state must be boolean") }
	r := self(L)
	if r.fullscreen != nil { r.fullscreen(r.data, handle, bool(lua.toboolean(L, 2))) }
	return 0
}

client_maximize :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	handle := checked_handle(L, 1)
	if lua.type(L, 2) != .BOOLEAN { return lua.L_error(L, "client state must be boolean") }
	r := self(L)
	if r.maximize != nil { r.maximize(r.data, handle, bool(lua.toboolean(L, 2))) }
	return 0
}

client_suspend :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	handle := checked_handle(L, 1)
	if lua.type(L, 2) != .BOOLEAN { return lua.L_error(L, "client state must be boolean") }
	r := self(L)
	if r.suspend != nil { r.suspend(r.data, handle, bool(lua.toboolean(L, 2))) }
	return 0
}

client_minimize :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	handle := checked_handle(L, 1)
	if lua.type(L, 2) != .BOOLEAN { return lua.L_error(L, "client state must be boolean") }
	r:=self(L)
	if r.minimize!=nil { r.minimize(r.data,handle,bool(lua.toboolean(L,2))) }
	return 0
}
