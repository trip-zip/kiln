package lua_runtime

import "base:runtime"
import "core:c"
import "core:math"
import lua "../luajit"

set_idle_timeout :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context()
    ms:f64
    if !lua.isnoneornil(L,1) { ms=f64(lua.L_checknumber(L,1)) }
    if math.is_nan(ms) || math.is_inf(ms) || ms>f64(max(i32)) || ms<0 || math.floor(ms)!=ms { return lua.L_error(L,"idle timeout must be integer milliseconds from 0 through 2147483647") }
    r:=self(L)
    if r.set_idle_timeout!=nil { r.set_idle_timeout(r.data,i32(ms)) }
    return 0
}
