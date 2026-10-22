package lua_runtime

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import lua "../luajit"

DATADIR :: #config(KILN_DATADIR, "")
readable :: proc(path: string) -> bool {
	p := strings.clone_to_cstring(path)
	defer delete(p)
	return posix.access(p, {.R_OK}) == .OK
}
resolve_config :: proc() -> string {
	rc := os.get_env("KILN_RC", context.allocator)
	if rc != "" { return rc }
	delete(rc)
	xdg := os.get_env("XDG_CONFIG_HOME", context.allocator); defer delete(xdg)
	home := os.get_env("HOME", context.allocator); defer delete(home)
	path := ""
	if xdg != "" { path = fmt.aprintf("%s/kiln/rc.lua", xdg) }
	else if home != "" { path = fmt.aprintf("%s/.config/kiln/rc.lua", home) }
	if path != "" && readable(path) { return path }
	delete(path)
	if DATADIR != "" {
		path = fmt.aprintf("%s/rc.lua", DATADIR)
		if readable(path) { return path }
		delete(path)
	}
	return strings.clone("kilnrc.lua")
}
Config_Call :: struct { path: cstring, search: string }
load_call :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	cfg := (^Config_Call)(lua.touserdata(L, 1))
	lua.getglobal(L, "package")
	lua.pushlstring(L, cast(cstring)raw_data(cfg.search), c.size_t(len(cfg.search)))
	lua.getfield(L, -2, "path")
	lua.concat(L, 2)
	when DATADIR != "" {
		lua.pushstring(L, ";" + DATADIR + "/lua/?.lua;" + DATADIR + "/lua/?/init.lua")
		lua.concat(L, 2)
	}
	lua.setfield(L, -2, "path")
	lua.pop(L, 1)
	lua.pushcfunction(L, traceback)
	if lua.L_loadfile(L, cfg.path) != .OK { return lua.error(L) }
	if lua.pcall(L, 0, 0, 2) != .OK { return lua.error(L) }
	return 0
}
traceback :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_traceback(L, L, lua.tostring(L, -1), 1)
	return 1
}
load_config :: proc(r: ^Runtime, path: string) -> bool {
	// Retain selection even when parsing fails before the library is required.
	if r.config_path == nil {
		if os.is_absolute_path(path) {
			r.config_path = strings.clone_to_cstring(path, r.allocator)
		} else {
			cwd, err := os.get_working_directory(context.allocator)
			if err != nil { fmt.eprintln("cannot anchor config path:", path); return false }
			absolute := fmt.aprintf("%s/%s", cwd, path)
			r.config_path = strings.clone_to_cstring(absolute, r.allocator)
			delete(absolute)
			delete(cwd)
		}
	}
	r.loading_config = true
	defer r.loading_config = false
	p := r.config_path
	search := strings.clone("lua/?.lua;lua/?/init.lua;")
	defer delete(search)
	if slash := strings.last_index(string(p), "/"); slash >= 0 {
		dir := string(p)[:slash+1]
		old := search
		search = fmt.aprintf("%s?.lua;%slua/?.lua;%slua/?/init.lua;%s", dir, dir, dir, search)
		delete(old)
	}
	cfg := Config_Call{p, search}
	base := lua.gettop(r.state)
	defer lua.settop(r.state, base)
	if lua.cpcall(r.state, load_call, &cfg) != .OK {
		fmt.eprintf("cannot load %s: %s\n", path, lua.tostring(r.state, -1))
		return false
	}
	fmt.printf("loaded %s\n", path)
	return true
}

config_path :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.pushstring(L, self(L).config_path)
	return 1
}
request_reload :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_checktype(L, 1, .FUNCTION)
	r := self(L)
	if r.loading_config || r.reload_pending || r.reloading || r.request_reload == nil {
		lua.pushboolean(L, false)
		return 1
	}
	lua.pushvalue(L, 1)
	r.reload_ref = lua.L_ref(L, lua.REGISTRYINDEX)
	r.reload_pending = true
	r.request_reload(r.data)
	lua.pushboolean(L, true)
	return 1
}
reload_call :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := (^Runtime)(lua.touserdata(L, 1))
	lua.rawgeti(L, lua.REGISTRYINDEX, r.reload_ref)
	lua.call(L, 0, 0)
	return 0
}
// Only the owner queue calls this, after the requesting Lua stack has unwound.
apply_reload :: proc(r: ^Runtime) {
	if !r.reload_pending { return }
	r.reloading = true
	defer { r.reloading = false; r.reload_pending = false }
	defer { lua.L_unref(r.state, lua.REGISTRYINDEX, r.reload_ref); r.reload_ref = lua.NOREF }
	base := lua.gettop(r.state)
	defer lua.settop(r.state, base)
	if lua.cpcall(r.state, reload_call, r) != .OK {
		fmt.eprintln("Lua reload:", lua.tostring(r.state, -1))
	}
}
