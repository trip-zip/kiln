package compositor

import "core:fmt"
import layout "../layout"
import sp "../scene_paint"
import vm "../lua_runtime"
import wlr "../wlroots"

lock_ui_clear :: proc(o:^Output) {
    ui:=o.lock_ui
    if ui==nil { return }
    r:=&o.server.lua
    if r.current_layout==&ui.ui { r.current_layout=nil }
    if r.frame_layout==&ui.ui { r.frame_layout=nil }
    clear_chrome(ui);layout.destroy(&ui.ui)
    wlr.wlr_scene_node_destroy(&ui.tree.node)
    free(ui);o.lock_ui=nil
}
arrange_lock :: proc(o:^Output) -> bool {
    s:=o.server
    lock_cover(s)
    if s.lock_owner!=.Native { o.dirty=false;return true }
    if !o.dirty || o.arranging { return true }
    o.dirty=false;o.arranging=true
    defer o.arranging=false
    if o.lock_ui==nil {
        ui:=new(Output)
        ui.chrome=make(map[u64]^sp.Node)
        ui.tree=wlr.wlr_scene_tree_create(s.lock_tree)
        if ui.tree==nil || !layout.init(&ui.ui) {
            if ui.tree!=nil { wlr.wlr_scene_node_destroy(&ui.tree.node) }
            layout.destroy(&ui.ui);clear_chrome(ui);free(ui);return true
        }
        o.lock_ui=ui
    }
    ui:=o.lock_ui
    b:wlr.wlr_box
    wlr.wlr_output_layout_get_box(s.layout,o.handle,&b)
    wlr.wlr_scene_node_set_position(&ui.tree.node,b.x,b.y)
    ui.ui.scale=o.handle.scale
    width,height:=wlr.output_cover_size(o.handle)
    nodes,valid:=vm.declare(&s.lua,&ui.ui,string(o.handle.name),width,height,true)
    if !valid { return true }
    commands,ok:=layout.prepare(&ui.ui,width,height,nodes)
    if !ok || !reconcile(ui,commands) { return true }
    layout.publish(&ui.ui,nodes)
    fmt.printf("Lock layout %s: solve %d, nodes %d, rasters %d\n",o.handle.name,ui.ui.solves,len(ui.chrome),ui.rasters)
    return true
}
