package layout

import clay "deps:clay"

// This variable is declared in the public header but omitted by its binding.
foreign import debug_globals "../build/clay/linux/clay.a"
foreign debug_globals {
    @(link_name="Clay__debugViewWidth")
    inspector_width:u32
}
Inspector_Pointer :: struct { point:clay.Vector2, down:bool }
inspector_enabled :: proc(l:^Layout)->bool {
    clay.SetCurrentContext(l.ctx[l.active])
    return clay.IsDebugModeEnabled()
}
inspector_set :: proc(l:^Layout,on:bool) {
    l.persistent=true
    clay.SetCurrentContext(l.ctx[l.active])
    clay.SetDebugModeEnabled(on)
    if !on { inspector_cancel(l) }
}
inspector_cancel :: proc(l:^Layout) {
    clear(&l.inspect_events)
    l.inspect_scroll={};l.inspect_down=false;l.inspect_capture=false
    clay.SetCurrentContext(l.ctx[l.active])
    clay.SetPointerState(l.inspect_point,false);clay.SetPointerState(l.inspect_point,false)
}
inspector_feed :: proc(l:^Layout) {
    if !clay.IsDebugModeEnabled() { return }
    point:=l.inspect_point
    down:=l.inspect_down
    if len(l.inspect_events)>0 {
        event:=l.inspect_events[0]
        ordered_remove(&l.inspect_events,0)
        point,down=event.point,event.down
        clay.SetPointerState(point,false);clay.SetPointerState(point,false)
        clay.SetPointerState(point,down)
    } else {
        clay.SetPointerState(point,down);clay.SetPointerState(point,down)
    }
    // Retire stale scroll containers even on frames with no wheel input.
    clay.UpdateScrollContainers(false,l.inspect_scroll,0)
    l.inspect_scroll={}

}
inspector_retire_edge :: proc(l:^Layout) {
    if !l.persistent { return }
    if !clay.IsDebugModeEnabled() { clear(&l.inspect_events);l.inspect_scroll={};l.inspect_down=false;l.inspect_capture=false }
    // Diagnostics run between solves with a released Clay pointer. Seat facts
    // and queued edges live in the port, so hit queries cannot consume them.
    clay.SetPointerState(l.inspect_point,false);clay.SetPointerState(l.inspect_point,false)
}
inspector_scroll :: proc(l:^Layout,dx,dy:f32)->f32 {
    clay.SetCurrentContext(l.ctx[l.active])
    pane:=clay.GetScrollContainerData(clay.GetElementId(clay.MakeString("Clay__DebugViewOuterScrollPane")))
    if dx!=0 || dy!=0 {
        if !l.inspect_have {
            b:=clay.GetElementData(clay.GetElementId(clay.MakeString("Clay__DebugViewOuterScrollPane")))
            if b.found { l.inspect_point={b.boundingBox.x+b.boundingBox.width/2,b.boundingBox.y+b.boundingBox.height/2} }
        }
        l.inspect_scroll.x+=dx;l.inspect_scroll.y+=dy
    }
    return pane.scrollPosition.y if pane.found else 0
}
inspector_panel :: proc(l:^Layout,x,y:f32)->bool {
    if !inspector_enabled(l) { return false }
    ids:=ordered_hits(l,x,y)
    defer delete(ids)
    panel:=clay.GetElementId(clay.MakeString("Clay__DebugView")).id
    for id in ids { if id.id==panel { return true } }
    return false
}

inspector_highlight :: proc(id:u32)->bool { return id==clay.GetElementId(clay.MakeString("Clay__DebugView_ElementHighlightRectangle")).id }
