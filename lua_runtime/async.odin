package lua_runtime

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import lua "../luajit"

// IDs stay exactly representable in Lua numbers and are never reused.
MAX_ASYNC_ID :: u64(9007199254740991)
checked_id :: proc(L: ^lua.State, index: c.int) -> u64 {
	n := f64(lua.tonumber(L, index))
	if lua.type(L,index)!=.NUMBER || math.is_nan(n) || n<0 || n>f64(MAX_ASYNC_ID) || math.floor(n)!=n {
		lua.L_error(L,"id must be an exact nonnegative integer")
		return 0
	}
	return u64(n)
}
timer :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	n := f64(lua.tonumber(L,1))
	if lua.type(L,1)!=.NUMBER || math.is_nan(n) || n<f64(min(i32)) || n>f64(max(i32)) {
		return lua.L_error(L,"timer delay must be a finite signed 32-bit number of milliseconds")
	}
	lua.L_checktype(L,2,.FUNCTION)
	r:=self(L)
	if r.timer_add==nil || r.next_timer==MAX_ASYNC_ID { return lua.L_error(L,"timer unavailable") }
	// Lua allocation finishes before acquiring native registrations.
	lua.pushvalue(L,2)
	ref:=lua.L_ref(L,lua.REGISTRYINDEX)
	r.next_timer+=1
	id:=r.next_timer
	if !r.timer_add(r.data,id,max(1,i32(n))) {
		lua.L_unref(L,lua.REGISTRYINDEX,ref)
		return lua.L_error(L,"timer registration failed")
	}
	r.timer_refs[id]=ref
	lua.pushnumber(L,lua.Number(id))
	return 1
}
cancel_timer :: proc(r: ^Runtime, id: u64) {
	ref,ok:=r.timer_refs[id]
	if !ok { return }
	delete_key(&r.timer_refs,id)
	if r.timer_remove!=nil { r.timer_remove(r.data,id) }
	lua.L_unref(r.state,lua.REGISTRYINDEX,ref)
}
timer_cancel :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	id:=checked_id(L,1)
	cancel_timer(self(L),id)
	return 0
}
reset_timers :: proc(r: ^Runtime) {
	for id in r.timer_refs { cancel_timer(r,id) }
}
timers_reset :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	reset_timers(self(L))
	return 0
}
timer_call :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r:=(^Runtime)(lua.touserdata(L,1))
	lua.rawgeti(L,lua.REGISTRYINDEX,r.timer_ref)
	lua.call(L,0,0)
	return 0
}
fire_timer :: proc(r: ^Runtime, id: u64) {
	ref,ok:=r.timer_refs[id]
	if !ok || r.state==nil { return }
	delete_key(&r.timer_refs,id)
	// The detached reference survives reentrant cancellation/reset and errors.
	defer lua.L_unref(r.state,lua.REGISTRYINDEX,ref)
	r.timer_ref=ref
	base:=lua.gettop(r.state)
	defer lua.settop(r.state,base)
	if lua.cpcall(r.state,timer_call,r)!=.OK { fmt.eprintln("Lua timer:",lua.tostring(r.state,-1)) }
}

pipe_spawn :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r:=self(L)
	if r.spawn_pipe==nil { return lua.L_error(L,"spawn_pipe unavailable") }
	table:=lua.istable(L,1)
	if !table && !lua.isstring(L,1) { return lua.L_error(L,"spawn_pipe takes an argv table or string") }
	count:=3
	if table {
		count=int(lua.objlen(L,1))
		if count==0 || count>=int(max(c.int)) { return lua.L_error(L,"spawn_pipe needs a nonempty representable argv") }
		lua.L_checkstack(L,c.int(count+1),"spawn argv")
		for i in 0..<count {
			lua.rawgeti(L,1,c.int(i+1))
			if !lua.isstring(L,-1) { return lua.L_error(L,"spawn argv must contain strings or numbers") }
			lua.tostring(L,-1)
		}
	} else { lua.tostring(L,1) }
	argv:=make([]cstring,count+1)
	if table {
		base:=lua.gettop(L)-c.int(count)+1
		for i in 0..<count { argv[i]=lua.tostring(L,base+c.int(i)) }
	} else { argv[0],argv[1],argv[2]="/bin/sh","-c",lua.tostring(L,1) }
	id:=r.spawn_pipe(r.data,argv)
	delete(argv)
	if id==0 { return lua.L_error(L,"spawn_pipe setup failed (pidfd support is required)") }
	lua.pushnumber(L,lua.Number(id))
	return 1
}
tick :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if lua.type(L,1)!=.STRING || lua.type(L,2)!=.BOOLEAN { return lua.L_error(L,"tick takes screen name and boolean") }
	r:=self(L)
	if r.tick!=nil { r.tick(r.data,string(lua.tostring(L,1)),bool(lua.toboolean(L,2))) }
	return 0
}

clocks_reset :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := self(L)
	if r.reset_clocks != nil { r.reset_clocks(r.data) }
	return 0
}
