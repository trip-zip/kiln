package compositor

import "core:testing"
import "core:strings"
import vm "../lua_runtime"
import wl "../wayland"
import wlr "../wlroots"
import layout "../layout"
import sp "../scene_paint"

@(test)
layer_facts_own_payloads_and_reject_dead_map_cycles :: proc(t: ^testing.T) {
    s:=Server{display=wl.create()}
    testing.expect(t,vm.init(&s.lua))
    defer destroy(&s)
    namespace:=strings.clone_to_cstring("copied")
    defer delete(namespace)
    native:=wlr.wlr_layer_surface_v1{namespace=namespace,initialized=true,current={desired_width=90,desired_height=40,anchor=13,exclusive_zone=30}}
    l:=Layer{server=&s,handle=&native,id=8,epoch=1}
    append(&s.layers,&l)
    queue_layer(&l,"map")
    (([^]u8)(namespace))[0]='X'
    testing.expect_value(t,s.events[0].namespace,"copied")
    testing.expect(t,!s.events[0].has_output && valid_layer_event(&s,&s.events[0]))
    l.epoch+=1
    testing.expect(t,!valid_layer_event(&s,&s.events[0]))
    clear(&s.layers)
    testing.expect(t,!valid_layer_event(&s,&s.events[0]))
    reply:=vm.evaluate(&s.lua,"seen=0;core.set_event_handler(function()seen=seen+1 end)")
    delete(reply)
    wl.remove_source(s.event_source);drain_pending(&s)
    reply=vm.evaluate(&s.lua,"return seen")
    testing.expect_value(t,reply,"0\n");delete(reply)
}

@(test)
layer_borrowed_tree_and_popup_order_are_retained :: proc(t: ^testing.T) {
    scene:=wlr.wlr_scene_create()
    defer wlr.wlr_scene_node_destroy(&scene.tree.node)
    s: Server
    defer delete(s.layers)
    defer delete(s.popups)
    output:=Output{server=&s,tree=&scene.tree,chrome=make(map[u64]^sp.Node)}
    defer clear_chrome(&output)
    native: wlr.wlr_layer_surface_v1
    l:=Layer{server=&s,handle=&native,id=4,mapped=true,output=&output,tree=wlr.wlr_scene_tree_create(&scene.tree)}
    append(&s.layers,&l)
    cmds:=[2]layout.Command{{1,{10,20,90,40},layout.Client{4},{}},{2,{0,0,400,300},layout.Rectangle{{0.1,0.2,0.3,1},{}},{}}}
    testing.expect(t,reconcile(&output,cmds[:]))
    testing.expect(t,reconcile(&output,cmds[:]))
    testing.expect_value(t,output.mutations,0)
    testing.expect_value(t,output.configures,0)
    p:=Popup{root=4,mapped=true};append(&s.popups,&p)
    testing.expect(t,reconcile(&output,cmds[:]))
    testing.expect(t,l.tree.node.link.next==&output.tree.children)
    testing.expect(t,reconcile(&output,cmds[:]))
    testing.expect_value(t,output.mutations,0)
    p.mapped=false
    testing.expect(t,reconcile(&output,cmds[:]))
    testing.expect(t,l.tree.node.link.prev==&output.tree.children)
    testing.expect(t,reconcile(&output,nil))
    testing.expect(t,!l.tree.node.enabled)
}

// Synthetic removal isolates ownership from backend hotplug and protocol transport.
@(test)
layer_output_removal_preserves_only_compositor_selected_owners :: proc(t: ^testing.T) {
    scene:=wlr.wlr_scene_create()
    defer wlr.wlr_scene_node_destroy(&scene.tree.node)
    s:=Server{scene=scene,desktop_tree=&scene.tree}
    defer delete(s.layers)
    defer delete(s.outputs)
    old_handle,next_handle: wlr.wlr_output
    old:=Output{handle=&old_handle,tree=wlr.wlr_scene_tree_create(&scene.tree)}
    next:=Output{handle=&next_handle}
    append(&s.outputs,&next)
    native:=wlr.wlr_layer_surface_v1{output=&old_handle}
    l:=Layer{handle=&native,output=&old,tree=wlr.wlr_scene_tree_create(old.tree)}
    append(&s.layers,&l)
    testing.expect(t,!layer_output_closes(&l,true))
    remove_layer_output(&s,&old)
    testing.expect(t,native.output==&next_handle && l.output==nil && l.tree.node.parent==&scene.tree && !l.tree.node.enabled)
    testing.expect(t,layer_output_closes(&l,false))
    l.explicit_output=true
    testing.expect(t,layer_output_closes(&l,true))
}
