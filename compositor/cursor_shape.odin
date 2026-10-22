package compositor

import "base:runtime"
import "core:fmt"
import wl "../wayland"
import wlr "../wlroots"

cursor_shape_requested :: proc "c" (listener: ^wl.Listener,data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"request_cursor_shape")
    e:=(^wlr.wlr_cursor_shape_manager_v1_request_set_shape_event)(data)
    if locked(s) || e.device_type!=0 || s.pointer_grabbed || e.seat_client!=s.seat.pointer_state.focused_client { return }
    name:=wlr.cursor_shape_name(e.shape)
    runtime_cursor(s,name)
    fmt.printf("Cursor shape: %s\n",name)
}
