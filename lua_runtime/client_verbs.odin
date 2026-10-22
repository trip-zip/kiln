package lua_runtime

import "base:runtime"
import "core:c"
import "core:math"
import lua "../luajit"

client_integer :: proc(L: ^lua.State, index: c.int, limit: f64) -> u32 {
    if lua.type(L, index) != .NUMBER {
        lua.L_error(L, "client argument must be a number")
        return 0
    }
    n := f64(lua.tonumber(L, index))
    if math.is_nan(n) || n < 0 || n > limit || math.floor(n) != n {
        lua.L_error(L, "client argument must be a nonnegative integer within range")
        return 0
    }
    return u32(n)
}

client_configure :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    handle := client_integer(L, 1, f64(max(u32)))
    width := client_integer(L, 2, f64(max(i32)))
    height := client_integer(L, 3, f64(max(i32)))
    r := self(L)
    if r.configure_client != nil { r.configure_client(r.data, handle, i32(width), i32(height)) }
    return 0
}

client_tiled :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    handle := client_integer(L, 1, f64(max(u32)))
    edges := client_integer(L, 2, f64(max(u32)))
    r := self(L)
    if r.tiled_client != nil { r.tiled_client(r.data, handle, edges) }
    return 0
}

client_mirror :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    handle := client_integer(L, 1, f64(max(u32)))
    name: string
    if !lua.isnoneornil(L, 2) {
        if lua.type(L, 2) != .STRING { return lua.L_error(L, "client output name must be a string or nil") }
        name = string(lua.tostring(L, 2))
    }
    r := self(L)
    if r.mirror_client != nil { r.mirror_client(r.data, handle, name) }
    return 0
}
