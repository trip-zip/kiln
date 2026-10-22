package lua_runtime

import "base:runtime"
import "core:c"
import "core:math"
import cfg "../input_config"
import lua "../luajit"
import "../keymap"

set_key_bindings :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_checktype(L, 1, .TABLE)
	count := int(lua.objlen(L, 1))
	// Staging on the stack leaves no owned allocation across a Lua error.
	staged: [4096]keymap.Chord
	if count > len(staged) { return lua.L_error(L, "too many key bindings (maximum 4096)") }
	lua.L_checkstack(L, 8, "key bindings")
	for i in 0..<count {
		lua.rawgeti(L, 1, c.int(i+1))
		lua.L_checktype(L, -1, .TABLE)
		lua.getfield(L, -1, "key")
		name := lua.tostring(L, -1)
		sym: u32
		if name != nil { sym = keymap.from_name(string(name)) }
		if sym == 0 { return lua.L_error(L, "unknown key name") }
		lua.pop(L, 1)
		mods: u32
		lua.getfield(L, -1, "mods")
		if lua.istable(L, -1) {
			for j in 0..<int(lua.objlen(L, -1)) {
				lua.rawgeti(L, -1, c.int(j+1))
				switch string(lua.tostring(L, -1)) {
				case "shift": mods |= 1
				case "ctrl": mods |= 4
				case "alt": mods |= 8
				case "super": mods |= 64
				}
				lua.pop(L, 1)
			}
		}
		lua.pop(L, 2)
		staged[i] = {sym, mods}
	}
	r := self(L)
	next := make([]keymap.Chord, count, r.allocator)
	copy(next, staged[:count])
	delete(r.bindings, r.allocator)
	r.bindings = next
	return 0
}
client_close :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	handle := checked_handle(L, 1)
	r := self(L)
	if r.close_client != nil { r.close_client(r.data, handle) }
	return 0
}
client_kill :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	handle := checked_handle(L, 1)
	r := self(L)
	if r.kill_client != nil { r.kill_client(r.data, handle) }
	return 0
}
client_focus_target :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	handle: u32
	if r.focus_target != nil { handle = r.focus_target(r.data) }
	if handle == 0 { lua.pushnil(L) } else { lua.pushnumber(L, lua.Number(handle)) }
	return 1
}

// Keep every converted field on the Lua stack until validation has finished.
input_string :: proc(L: ^lua.State, index: c.int, optional := false) -> cstring {
	if optional && lua.isnoneornil(L, index) { return nil }
	lua.L_checktype(L, index, .STRING)
	return lua.tostring(L, index)
}
input_integer :: proc(L: ^lua.State, index: c.int, low: f64 = 0, high: f64 = 2147483647) -> i32 {
	lua.L_checktype(L, index, .NUMBER)
	n := f64(lua.tonumber(L, index))
	if math.is_nan(n) || math.is_inf(n) || n<low || n>high || n!=math.floor(n) { lua.L_argerror(L,index,"integer out of range"); return 0 }
	return i32(n)
}
input_keymap :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_checktype(L,1,.TABLE)
	names: [5]cstring
	for field, i in ([]cstring{"rules","model","layout","variant","options"}) {
		lua.getfield(L,1,field); names[i]=input_string(L,-1,true)
	}
	r:=self(L)
	if r.set_keymap!=nil { r.set_keymap(r.data,keymap.Names{string(names[0]),string(names[1]),string(names[2]),string(names[3]),string(names[4]),
		{names[0]!=nil,names[1]!=nil,names[2]!=nil,names[3]!=nil,names[4]!=nil}}) }
	return 0
}
input_repeat :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	rate, delay := input_integer(L,1), input_integer(L,2)
	r:=self(L)
	if r.set_repeat!=nil { r.set_repeat(r.data,rate,delay) }
	return 0
}
input_numlock :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_checktype(L,1,.BOOLEAN)
	r:=self(L)
	if r.set_numlock!=nil { r.set_numlock(r.data,bool(lua.toboolean(L,1))) }
	return 0
}
input_grab_keyboard :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_checktype(L,1,.BOOLEAN)
	r:=self(L)
	if r.grab_keyboard!=nil { r.grab_keyboard(r.data,bool(lua.toboolean(L,1))) }
	return 0
}
input_grab_pointer :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_checktype(L,1,.BOOLEAN)
	r:=self(L)
	if r.grab_pointer!=nil { r.grab_pointer(r.data,bool(lua.toboolean(L,1))) }
	return 0
}
input_cursor :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	name:=input_string(L,1)
	r:=self(L)
	if r.set_cursor!=nil { r.set_cursor(r.data,name) }
	return 0
}
input_cursor_theme :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	name:=input_string(L,1,true)
	size:i32=24
	if !lua.isnoneornil(L,2) { size=input_integer(L,2,1,4096) }
	r:=self(L)
	if r.set_cursor_theme!=nil { r.set_cursor_theme(r.data,name,u32(size)) }
	return 0
}
input_pointer :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_checktype(L,1,.TABLE)
	p:cfg.Pointer
	for field,i in ([]cstring{"tap_to_click","natural_scrolling","left_handed"}) {
		lua.getfield(L,1,field)
		if !lua.isnil(L,-1) {
			lua.L_checktype(L,-1,.BOOLEAN)
			value:=cfg.Optional(bool){bool(lua.toboolean(L,-1)),true}
			switch i { case 0:p.tap_to_click=value; case 1:p.natural_scrolling=value; case 2:p.left_handed=value }
		}
	}
	lua.getfield(L,1,"accel_speed")
	if !lua.isnil(L,-1) {
		lua.L_checktype(L,-1,.NUMBER)
		n:=f64(lua.tonumber(L,-1))
		if math.is_nan(n) || math.is_inf(n) { return lua.L_error(L,"accel_speed must be finite") }
		p.accel_speed={n,true}
	}
	for field,i in ([]cstring{"accel_profile","scroll_method","click_method"}) {
		lua.getfield(L,1,field)
		if name:=input_string(L,-1,true);name!=nil {
			value:=cfg.Optional(string){string(name),true}
			switch i { case 0:p.accel_profile=value; case 1:p.scroll_method=value; case 2:p.click_method=value }
		}
	}
	r:=self(L)
	if r.set_pointer!=nil { r.set_pointer(r.data,p) }
	return 0
}
