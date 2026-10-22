package compositor

import "base:runtime"
import "core:fmt"
import vm "../lua_runtime"
import layout "../layout"
import wl "../wayland"
import wlr "../wlroots"

Layer :: struct {
    allocator: runtime.Allocator,
    server: ^Server,
    handle: ^wlr.wlr_layer_surface_v1,
    tree: ^wlr.wlr_scene_tree,
    output: ^Output,
    id: u32,
    epoch: u64,
    explicit_output, mapped, configured: bool,
    width, height: u32,
    watchdog: ^wl.Event_Source,
    commit, map_, unmap, destroy, new_popup: wl.Listener,
}
find_layer :: proc(s: ^Server, id: u32) -> ^Layer {
    if s==nil { return nil }
    for l in s.layers { if l.id==id { return l } }
    return nil
}
queue_layer :: proc(l: ^Layer, name: string) {
    h:=l.handle
    st:=h.current
    e:=vm.Event{class="layer",name=name,handle=l.id,map_epoch=l.epoch,
        namespace=string(h.namespace),layer=st.layer,interactivity=st.keyboard_interactive,
        anchors=st.anchor,exclusive=st.exclusive_zone,
        margin={st.margin.top,st.margin.right,st.margin.bottom,st.margin.left},
        desired_width=st.desired_width,desired_height=st.desired_height,buffer_mapped=l.mapped}
    if l.explicit_output && h.output!=nil { e.has_output=true;e.output=string(h.output.name) }
    queue_event(l.server,e)
}
valid_layer_event :: proc(s: ^Server, e: ^vm.Event) -> bool {
    if e.name=="unmap" || e.name=="destroy" { return true }
    l:=find_layer(s,e.handle)
    return l!=nil && l.epoch==e.map_epoch && l.handle.initialized
}
layer_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"new_layer")
    h:=(^wlr.wlr_layer_surface_v1)(data)
    explicit:=h.output!=nil
    // This association satisfies the protocol lifetime, not desktop placement.
    // The requested-output fact remains absent until Lua chooses a scene owner.
    if h.output==nil {
        if len(s.outputs)==0 { wlr.layer_close(h);return }
        h.output=s.outputs[0].handle
    }
    l:=new(Layer)
    l.allocator=context.allocator
    l.server,l.handle,l.explicit_output=s,h,explicit
    s.next_view_id+=1;l.id=s.next_view_id
    l.tree=wlr.layer_tree_create(s.desktop_tree,h.surface)
    if l.tree==nil { free(l);wlr.layer_close(h);return }
    h.data=l.tree
    l.watchdog=wl.on_timer(s.display,layer_watchdog,l)
    append(&s.layers,l)
    wl.listen(&h.surface.events.commit,&l.commit,layer_commit)
    wl.listen(&h.surface.events.map_,&l.map_,layer_map)
    wl.listen(&h.surface.events.unmap,&l.unmap,layer_unmap)
    wl.listen(&h.events.destroy,&l.destroy,layer_destroy)
    wl.listen(&h.events.new_popup,&l.new_popup,layer_popup)
}
layer_watchdog :: proc "c" (data: rawptr) -> i32 {
    context=runtime.default_context()
    l:=(^Layer)(data)
    if !l.configured {
        fmt.eprintf("layer-shell watchdog: surface '%s' (handle %d): layer::map dispatched, no layer_configure answered\n",l.handle.namespace,l.id)
    }
    return 0
}
layer_commit :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    l:=wl.owner(listener,Layer,"commit")
    if l.handle.initial_commit {
        l.epoch+=1;l.configured=false
        queue_layer(l,"map")
        if l.watchdog!=nil { wl.arm_timer(l.watchdog,3000) }
    } else if l.handle.initialized && l.handle.current.committed!=0 { queue_layer(l,"commit") }
}
layer_map :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    l:=wl.owner(listener,Layer,"map_")
    l.mapped=true
    queue_layer(l,"mapped")
}
layer_unmap :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    l:=wl.owner(listener,Layer,"unmap")
    l.mapped=false;l.configured=false
    if l.watchdog!=nil { wl.arm_timer(l.watchdog,0) }
    queue_layer(l,"unmap")
    wlr.wlr_scene_node_set_enabled(&l.tree.node,false)
    pointer_target_refresh(l.server)
    for output in l.server.outputs { layout.forget_client(&output.ui,l.id) }
    dirty(l.output)
    if l.server.requested_focus==l.id { l.server.requested_focus=0;clear_focus(l.server) }
}
layer_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    l:=wl.owner(listener,Layer,"destroy")
    context.allocator=l.allocator
    queue_layer(l,"destroy")
    wl.remove_source(l.watchdog)
    wl.unlisten(&l.new_popup);wl.unlisten(&l.commit);wl.unlisten(&l.map_);wl.unlisten(&l.unmap);wl.unlisten(&l.destroy)
    for output in l.server.outputs { layout.forget_client(&output.ui,l.id) }
    if l.server.requested_focus==l.id { l.server.requested_focus=0;clear_focus(l.server) }
    dirty(l.output)
    for other,i in l.server.layers { if other==l { ordered_remove(&l.server.layers,i);break } }
    l.handle.data=nil
    wlr.wlr_scene_node_destroy(&l.tree.node)
    pointer_target_refresh(l.server)
    free(l)
}
runtime_layer_configure :: proc(data: rawptr, id, width, height: u32) {
    l:=find_layer((^Server)(data),id)
    if l==nil || !l.handle.initialized { return }
    if l.configured && l.width==width && l.height==height { return }
    l.configured=true;l.width=width;l.height=height
    if l.watchdog!=nil { wl.arm_timer(l.watchdog,0) }
    wlr.layer_configure(l.handle,width,height)
}
// Output destruction cannot leave either a protocol association or scene parent dangling.
remove_layer_output :: proc(s: ^Server, output: ^Output) {
    i:=0
    for i<len(s.layers) {
        l:=s.layers[i]
        if l.handle.output==output.handle {
            if layer_output_closes(l,len(s.outputs)>0) { wlr.layer_close(l.handle);continue }
            l.handle.output=s.outputs[0].handle
        }
        if l.output==output {
            l.output=nil
            wlr.wlr_scene_node_reparent(&l.tree.node,s.desktop_tree)
            wlr.wlr_scene_node_set_enabled(&l.tree.node,false)
        }
        i+=1
    }
}

layer_output_closes :: proc(l: ^Layer, has_survivor: bool) -> bool {
    return l.explicit_output || !has_survivor
}
