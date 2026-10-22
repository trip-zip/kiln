package compositor

import "base:runtime"
import wl "../wayland"
import wlr "../wlroots"

Popup :: struct {
    allocator: runtime.Allocator,
    server: ^Server,
    handle: ^wlr.wlr_xdg_popup,
    root: u32,
    tree: ^wlr.wlr_scene_tree,
    mapped: bool,
    last_x,last_y: i32,
    commit, destroy, reposition, map_, unmap, tree_destroy: wl.Listener,
}
root_tree :: proc(s: ^Server, id: u32) -> (^wlr.wlr_scene_tree,^Output,i32,i32) {
    for v in s.views {
        if v.id==id && v.mapped && xdg(v)!=nil { return v.tree,v.output,xdg(v).base.geometry.x,xdg(v).base.geometry.y }
    }
    if l:=find_layer(s,id);l!=nil && l.mapped { return l.tree,l.output,0,0 }
    return nil,nil,0,0
}
popup_dirty :: proc(p: ^Popup) {
    _,output,_,_:=root_tree(p.server,p.root)
    dirty(output)
}
has_popup :: proc(s: ^Server, id: u32) -> bool {
    for p in s.popups { if p.root==id && p.mapped { return true } }
    return false
}
popup_attach :: proc(p: ^Popup) {
    if p.tree!=nil || p.handle.parent==nil { return }
    s:=p.server
    parent: ^wlr.wlr_scene_tree
    for v in s.views { if xdg(v)!=nil && view_surface(v)==p.handle.parent { parent=v.tree;p.root=v.id;break } }
    if parent==nil {
        for l in s.layers { if l.handle.surface==p.handle.parent { parent=l.tree;p.root=l.id;break } }
    }
    if parent==nil {
        for other in s.popups {
            if other!=p && other.handle.base.surface==p.handle.parent { parent=other.tree;p.root=other.root;break }
        }
    }
    if parent==nil { p.root=0;return }
    p.tree=wlr.wlr_scene_xdg_surface_create(parent,p.handle.base)
    if p.tree==nil { return }
    p.handle.base.data=p.tree
    wl.listen(&p.tree.node.events.destroy,&p.tree_destroy,popup_tree_destroy)
}
popup_register :: proc(s: ^Server, handle: ^wlr.wlr_xdg_popup) {
    for p in s.popups { if p.handle==handle { popup_attach(p);return } }
    p:=new(Popup)
    p.allocator=context.allocator;p.server=s;p.handle=handle
    append(&s.popups,p)
    popup_attach(p)
    wl.listen(&handle.base.surface.events.commit,&p.commit,popup_commit)
    wl.listen(&handle.base.surface.events.map_,&p.map_,popup_map)
    wl.listen(&handle.base.surface.events.unmap,&p.unmap,popup_unmap)
    wl.listen(&handle.events.destroy,&p.destroy,popup_destroy)
    wl.listen(&handle.events.reposition,&p.reposition,popup_reposition)
}
popup_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    popup_register(wl.owner(listener,Server,"new_popup"),(^wlr.wlr_xdg_popup)(data))
}
layer_popup :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    popup_register(wl.owner(listener,Layer,"new_popup").server,(^wlr.wlr_xdg_popup)(data))
}
popup_tree_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    p:=wl.owner(listener,Popup,"tree_destroy")
    p.handle.base.data=nil;p.tree=nil
    wl.unlisten(listener)
}
popup_constrain :: proc(p: ^Popup, force := false) -> bool {
    tree,output,gx,gy:=root_tree(p.server,p.root)
    if tree==nil || output==nil || p.handle.parent==nil { return false }
    x,y: i32
    if !wlr.wlr_scene_node_coords(&tree.node,&x,&y) { return false }
    box: wlr.wlr_box
    wlr.wlr_output_layout_get_box(p.server.layout,output.handle,&box)
    // The xdg scene root is the geometry origin; the helper consumes surface coordinates.
    box.x-=x-gx;box.y-=y-gy
    wlr.popup_constrain(p.handle,box,force)
    return true
}
popup_commit :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    p:=wl.owner(listener,Popup,"commit")
    if p.mapped && p.tree!=nil && (p.tree.node.x!=p.last_x || p.tree.node.y!=p.last_y) {
        p.last_x,p.last_y=p.tree.node.x,p.tree.node.y
        popup_dirty(p)
    }
    if p.handle.base.initial_commit {
        popup_attach(p)
        if !popup_constrain(p,true) { wlr.wlr_xdg_surface_schedule_configure(p.handle.base) }
    }
}
popup_reposition :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    popup_constrain(wl.owner(listener,Popup,"reposition"))
}
popup_map :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    p:=wl.owner(listener,Popup,"map_");p.mapped=true;popup_dirty(p)
}
popup_unmap :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    p:=wl.owner(listener,Popup,"unmap");p.mapped=false;popup_dirty(p);pointer_target_refresh(p.server)
}
popup_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    p:=wl.owner(listener,Popup,"destroy")
    context.allocator=p.allocator
    popup_dirty(p)
    wl.unlisten(&p.commit);wl.unlisten(&p.destroy);wl.unlisten(&p.reposition)
    wl.unlisten(&p.map_);wl.unlisten(&p.unmap)
    if p.tree!=nil { wlr.wlr_scene_node_destroy(&p.tree.node) }
    wl.unlisten(&p.tree_destroy)
    for other,i in p.server.popups { if other==p { ordered_remove(&p.server.popups,i);break } }
    free(p)
}
refresh_popups :: proc(output: ^Output) {
    for p in output.server.popups {
        _,owner,_,_:=root_tree(output.server,p.root)
        if owner==output && p.handle.base.initialized { popup_constrain(p) }
    }
}
