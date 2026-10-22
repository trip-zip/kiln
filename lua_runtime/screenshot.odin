package lua_runtime

import "base:runtime"
import "core:c"
import lua "../luajit"

screenshot :: proc "c" (L:^lua.State)->c.int {
    context=runtime.default_context()
    name:=string(lua.L_checkstring(L,1))
    path:=lua.L_optstring(L,2,nil)
    r:=self(L)
    if r.declaring || r.capture==nil { return 0 }
    // The cache owns the key and pixels before any fallible Lua stack operation.
    key:=r.capture(r.data,name,path)
    if key=="" { return 0 }
    lua.pushlstring(L,cast(cstring)raw_data(key),c.size_t(len(key)))
    return 1
}
