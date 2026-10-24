package compositor

import ext "../extensions"

import "base:runtime"
import "core:fmt"
import wl "../wayland"

cursor_shape_requested :: proc "c" (listener: ^wl.Listener,data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"request_cursor_shape")
    e:=(^ext.Cursor_Shape_Event)(data)
    if locked(s) || e.device_type!=0 || s.pointer_grabbed || e.seat_client!=s.seat.pointer_state.focused_client { return }
    name:=ext.cursor_shape_name(e.shape)
    runtime_cursor(s,name)
    fmt.printf("Cursor shape: %s\n",name)
}
