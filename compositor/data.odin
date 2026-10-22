package compositor

import "base:runtime"
import wl "../wayland"
import wlr "../wlroots"
import vm "../lua_runtime"

primary_selection_requested :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"request_primary_selection")
    wlr.primary_selection_set(s.seat,(^wlr.wlr_seat_request_set_primary_selection_event)(data))
}
drag_requested :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"request_drag")
    e:=(^wlr.wlr_seat_request_start_drag_event)(data)
    if locked(s) { if e.drag.source!=nil { wlr.wlr_data_source_destroy(e.drag.source) };return }
    wlr.pointer_drag_request(s.seat,e)
}
drag_icon_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"drag_icon_destroy")
    wl.unlisten(listener)
    s.drag_icon=nil
}
drag_position :: proc(s: ^Server) {
    if s.drag_icon!=nil {
        wlr.wlr_scene_node_set_position(&s.drag_icon.node,i32(s.cursor.x),i32(s.cursor.y))
        wlr.wlr_scene_node_raise_to_top(&s.drag_band.node)
        lock_cover(s)
    }
}
drag_started :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"start_drag")
    drag:=(^wlr.wlr_drag)(data)
    s.drag_active=true
    wl.listen(&drag.events.destroy,&s.drag_destroy,drag_ended)
    if drag.icon!=nil {
        s.drag_icon=wlr.drag_icon_create(s.drag_band,drag.icon)
        if s.drag_icon==nil { fail(s,"Cannot create drag icon");return }
        wl.listen(&s.drag_icon.node.events.destroy,&s.drag_icon_destroy,drag_icon_destroyed)
        drag_position(s)
    }
    queue_event(s,vm.Event{class="drag",name="start",generation=s.lua.config_generation})
}
drag_ended :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"drag_destroy")
    wl.unlisten(listener)
    s.drag_active=false
    // The icon can die before or after the drag; its scene listener owns the pointer.
    queue_event(s,vm.Event{class="drag",name="end",generation=s.lua.config_generation})
}
