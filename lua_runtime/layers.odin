package lua_runtime

import "base:runtime"
import "core:c"
import "core:math"
import lua "../luajit"

Layer_Answer :: struct { handle, width, height: u32 }
layer_configure :: proc "c" (L: ^lua.State) -> c.int {
    context=runtime.default_context()
    r:=self(L)
    if r.lock_declaring { return lua.L_error(L,"layer configuration cannot be declared in the lock context") }
    context.allocator=r.allocator
    values: [3]u32
    for i in 0..<3 {
        n:=f64(lua.L_checknumber(L,c.int(i+1)))
        if math.is_nan(n) || math.is_inf(n) || n<0 || n>2147483647 || n!=math.floor(n) {
            return lua.L_error(L,"layer_configure expects nonnegative integer handle and sizes")
        }
        values[i]=u32(n)
    }
    answer:=Layer_Answer{values[0],values[1],values[2]}
    if r.declaring { append(&r.layer_answers,answer) }
    else if r.configure_layer!=nil { r.configure_layer(r.data,answer.handle,answer.width,answer.height) }
    return 0
}
// Explicit event-policy answers can start the handshake before any scene exists.
// Declaration answers are held through both Clay and renderer validation.
publish_layer_answers :: proc(r: ^Runtime) {
    if r.configure_layer!=nil {
        for a in r.layer_answers { r.configure_layer(r.data,a.handle,a.width,a.height) }
    }
    clear(&r.layer_answers)
}
