package lua_runtime

import "base:runtime"
import "core:c"
import "core:math"
import lua "../luajit"

Output_Change :: union { Output_Mode, Output_Scale, Output_Position, Output_Enabled, Output_Adaptive_Sync }
Output_Mode :: struct { width, height, refresh: i32 }
Output_Scale :: struct { value: f32 }
Output_Position :: struct { x, y: i32 }
Output_Enabled :: struct { value: bool }
Output_Adaptive_Sync :: struct { value: bool }

// Bound geometry before conversion: layout edge sums and raster strides use signed ints.
output_integer :: proc(L: ^lua.State, index: c.int, low, high: f64) -> i32 {
    n:=f64(lua.L_checknumber(L,index))
    if math.is_nan(n) || n<low || n>high || math.floor(n)!=n {
        lua.L_error(L,"output argument %d must be an integer in [%g, %g]",index,low,high)
        return 0
    }
    return i32(n)
}
output_apply :: proc(L: ^lua.State, name: cstring, change: Output_Change) -> c.int {
    r:=self(L)
    if r.output_set!=nil { r.output_set(r.data,string(name),change) }
    return 0
}
output_mode :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context()
    name:=lua.L_checkstring(L,1)
    w,h:=output_integer(L,2,1,32768),output_integer(L,3,1,32768)
    refresh:i32
    if !lua.isnoneornil(L,4) { refresh=output_integer(L,4,0,1000000) }
    return output_apply(L,name,Output_Mode{w,h,refresh})
}
output_scale :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context()
    name:=lua.L_checkstring(L,1)
    n:=f64(lua.L_checknumber(L,2))
    if math.is_nan(n) || n<0.25 || n>8 { return lua.L_error(L,"output scale must be finite and in [0.25, 8]") }
    return output_apply(L,name,Output_Scale{f32(n)})
}
output_position :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context()
    name:=lua.L_checkstring(L,1)
    x,y:=output_integer(L,2,-1048576,1048576),output_integer(L,3,-1048576,1048576)
    return output_apply(L,name,Output_Position{x,y})
}
output_enabled :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context()
    name:=lua.L_checkstring(L,1)
    if lua.type(L,2)!=.BOOLEAN { return lua.L_error(L,"output enabled must be boolean") }
    return output_apply(L,name,Output_Enabled{bool(lua.toboolean(L,2))})
}
output_adaptive_sync :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context()
    name:=lua.L_checkstring(L,1)
    if lua.type(L,2)!=.BOOLEAN { return lua.L_error(L,"output adaptive sync must be boolean") }
    return output_apply(L,name,Output_Adaptive_Sync{bool(lua.toboolean(L,2))})
}
output_geometry :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context()
    name:=string(lua.L_checkstring(L,1))
    r:=self(L)
    if r.output==nil { return 0 }
    for i in 0..<16 {
        o,ok:=r.output(r.data,i)
        if !ok { break }
        if o.name!=name { continue }
        lua.pushnumber(L,lua.Number(o.logical_width));lua.pushnumber(L,lua.Number(o.logical_height))
        return 2
    }
    return 0
}
