package lua_runtime

import "base:runtime"
import "core:c"
import "core:math"
import lua "../luajit"

inspector :: proc "c" (L:^lua.State)->c.int {
    context=runtime.default_context()
    name:=string(lua.L_checkstring(L,1))
    r:=self(L)
    on:i32=-1
    width:f64=-1
    if lua.istable(L,2) {
        lua.pushnil(L)
        for lua.next(L,2) {
            key:=lua_string(L,-2)
            if key!="enabled" && key!="width" { return lua.L_error(L,"unsupported inspector style option; only enabled and width are supported") }
            if key=="enabled" {
                if !lua.isboolean(L,-1) { return lua.L_error(L,"inspector enabled must be boolean") }
                on=i32(lua.toboolean(L,-1))
            } else {
                width=f64(lua.L_checknumber(L,-1))
                if math.is_nan(width) || math.is_inf(width) || width<0 || width>16384 { return lua.L_error(L,"inspector width out of range") }
            }
            lua.pop(L,1)
        }
    } else if !lua.isnoneornil(L,2) {
        if !lua.isboolean(L,2) { return lua.L_error(L,"inspector expects boolean or table") }
        on=i32(lua.toboolean(L,2))
    }
    if r.declaring && (on>=0 || width>=0) { return lua.L_error(L,"inspector cannot change during declaration") }
    value:=false
    if r.inspect!=nil { value=r.inspect(r.data,name,on,width) }
    lua.pushboolean(L,b32(value))
    return 1
}
inspector_scroll :: proc "c" (L:^lua.State)->c.int {
    context=runtime.default_context()
    name:=string(lua.L_checkstring(L,1))
    write:=!lua.isnoneornil(L,2)
    dx,dy:f32
    if write {
        x,y:=f64(lua.L_checknumber(L,2)),f64(lua.L_checknumber(L,3))
        if math.is_nan(x) || math.is_inf(x) || math.is_nan(y) || math.is_inf(y) || abs(x)>1e6 || abs(y)>1e6 { return lua.L_error(L,"inspector scroll out of range") }
        dx,dy=f32(x),f32(y)
    }
    r:=self(L)
    if r.declaring && write { return lua.L_error(L,"inspector scroll cannot change during declaration") }
    offset:f32
    if r.inspect_scroll!=nil { offset=r.inspect_scroll(r.data,name,dx,dy) }
    if write { return 0 }
    lua.pushnumber(L,lua.Number(offset));return 1
}
