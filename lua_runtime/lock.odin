package lua_runtime

import "base:runtime"
import "core:c"
import lua "../luajit"

lock :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context();r:=self(L)
    lua.pushboolean(L,b32(r.lock!=nil && r.lock(r.data)));return 1
}
unlock :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context();r:=self(L)
    lua.pushboolean(L,b32(r.unlock!=nil && r.unlock(r.data)));return 1
}

Lock_State :: struct { owner:string, generation:u64, authenticated,pending:bool, request:u64, surfaces,inhibitors:int }
authenticate :: proc "c" (L:^lua.State)->c.int {
    context=runtime.default_context()
    lua.L_checktype(L,1,.STRING)
    r:=self(L);id:u64
    if r.authenticate!=nil { id=r.authenticate(r.data,lua_string(L,1)) }
    if id==0 { lua.pushnil(L) } else { lua.pushnumber(L,lua.Number(id)) }
    return 1
}
lock_state :: proc "c" (L:^lua.State)->c.int {
    context=runtime.default_context();r:=self(L);s:Lock_State
    if r.lock_state!=nil { s=r.lock_state(r.data) }
    lua.newtable(L);push_string(L,s.owner);lua.setfield(L,-2,"owner")
    number(L,"generation",f64(s.generation));number(L,"request",f64(s.request))
    boolean(L,"authenticated",s.authenticated);boolean(L,"pending",s.pending)
    number(L,"surfaces",f64(s.surfaces));number(L,"inhibitors",f64(s.inhibitors))
    return 1
}
