package compositor

import layout "../layout"

import "base:runtime"
import auth "../authentication"
import wl "../wayland"
import wlr "../wlroots"
import vm "../lua_runtime"
import "../keymap"

Lock_Owner :: enum { Unlocked, Native, External }
Lock_Surface :: struct {
    server: ^Server,
    handle: ^wlr.wlr_session_lock_surface_v1,
    tree: ^wlr.wlr_scene_tree,
    width,height:i32,
    map_,unmap,destroy:wl.Listener,
}
locked :: proc(s: ^Server) -> bool { return s.lock_owner!=.Unlocked }
init_lock :: proc(s: ^Server) -> bool {
    manager:=wlr.lock_manager_create(s.display)
    s.lock_tree=wlr.wlr_scene_tree_create(&s.scene.tree)
    if manager==nil || s.lock_tree==nil { return false }
    wlr.wlr_scene_node_set_enabled(&s.lock_tree.node,false)
    wl.listen(&manager.events.new_lock,&s.new_lock,lock_added)
    return true
}
lock_cover :: proc(s: ^Server) {
    if s.lock_tree==nil { return }
    // Remove desktop drawables too, including pixels beyond rounded layout extents.
    wlr.wlr_scene_node_set_enabled(&s.desktop_tree.node,!locked(s))
    wlr.wlr_scene_node_raise_to_top(&s.lock_tree.node)
    wlr.wlr_scene_node_set_enabled(&s.lock_tree.node,locked(s))
    for o in s.outputs {
        if o.lock_floor==nil {
            color:=[4]f32{0,0,0,1}
            o.lock_floor=wlr.wlr_scene_rect_create(s.lock_tree,1,1,raw_data(color[:]))
            if o.lock_floor==nil { fail(s,"Cannot create lock coverage");return }
            wlr.wlr_scene_node_lower_to_bottom(&o.lock_floor.node)
        }
        b:wlr.wlr_box
        wlr.wlr_output_layout_get_box(s.layout,o.handle,&b)
        w,h:=wlr.output_cover_size(o.handle)
        wlr.wlr_scene_rect_set_size(o.lock_floor,max(1,b.width,w),max(1,b.height,h))
        wlr.wlr_scene_node_set_position(&o.lock_floor.node,b.x,b.y)
        wlr.wlr_scene_node_set_enabled(&o.lock_floor.node,o.handle.enabled)
        if o.lock_ui!=nil { wlr.wlr_scene_node_set_enabled(&o.lock_ui.tree.node,o.handle.enabled) }
    }
    for p in s.lock_surfaces {
        b:wlr.wlr_box
        wlr.wlr_output_layout_get_box(s.layout,p.handle.output,&b)
        wlr.wlr_scene_node_set_position(&p.tree.node,b.x,b.y)
        wlr.wlr_scene_node_set_enabled(&p.tree.node,p.handle.output.enabled && p.handle.surface.mapped && s.lock_owner==.External)
        if p.handle.output.enabled && (p.width!=b.width || p.height!=b.height) {
            p.width,p.height=b.width,b.height
            wlr.lock_configure(p.handle,b.width,b.height)
        }
    }
}
lock_reset_input :: proc(s: ^Server) {
    s.keyboard_epoch+=1;s.pointer_epoch+=1
    s.keyboard_grabbed=false;s.pointer_grabbed=false;s.pointer_client=0
    for kb in s.keyboards {
        keymap.compose_reset(kb.compose)
        for code in kb.consumed { kb.consumed[code]=true }
        for code in kb.handle.keycodes[:kb.handle.num_keycodes] { kb.consumed[code]=true }
    }
    for code,consumed in s.buttons {
        if !consumed { wlr.wlr_seat_pointer_notify_button(s.seat,0,code,0) }
        s.buttons[code]=true
    }
    wlr.seat_end_grabs(s.seat)
    wlr.wlr_seat_keyboard_notify_clear_focus(s.seat)
    wlr.wlr_seat_pointer_clear_focus(s.seat)
    constraint_sync(s)
}
lock_engage :: proc(s: ^Server, owner: Lock_Owner) {
    auth.cancel(&s.auth)
    wl.remove_source(s.quit_source);s.quit_source=nil
    s.lock_owner=owner;s.lock_generation+=1;s.authenticated=false
    for o in s.outputs { layout.inspector_cancel(&o.ui) }
    lock_reset_input(s)
    lock_cover(s)
    for o in s.outputs { lock_ui_clear(o);o.lock_presented=false;o.lock_submitted=false;dirty(o) }
    idle_recompute(s)
    kind:="native";if owner==.External { kind="ext" }
    queue_event(s,vm.Event{class="session",name="lock",bytes=kind,generation=s.lock_generation})
}
lock_disengage :: proc(s: ^Server) {
    auth.cancel(&s.auth)
    s.lock_owner=.Unlocked;s.lock_generation+=1;s.authenticated=false
    lock_reset_input(s)
    lock_cover(s)
    idle_recompute(s)
    for o in s.outputs { lock_ui_clear(o);dirty(o) }
    queue_event(s,vm.Event{class="session",name="unlock",generation=s.lock_generation})
    pointer_target_refresh(s)
}
runtime_lock :: proc(data: rawptr) -> bool {
    s:=(^Server)(data)
    if locked(s) || s.lua.declaring { return false }
    lock_engage(s,.Native);return true
}
runtime_unlock :: proc(data: rawptr) -> bool {
    s:=(^Server)(data)
    if !locked(s) { return true }
    if s.lua.declaring || s.lock_owner!=.Native || !s.authenticated { return false }
    lock_disengage(s);return true
}
lock_maybe_ack :: proc(s: ^Server) {
    if s.lock_owner!=.External || s.ext_lock==nil || s.lock_acknowledged { return }
    for o in s.outputs { if o.handle.enabled && !o.lock_presented { return } }
    s.lock_acknowledged=true
    wlr.lock_acknowledge(s.ext_lock)
}
lock_presented :: proc "c" (listener: ^wl.Listener,data: rawptr) {
    context=runtime.default_context()
    o:=wl.owner(listener,Output,"present")
    e:=(^wlr.wlr_output_event_present)(data)
    if !locked(o.server) || !o.lock_submitted || !e.presented { return }
    if i32(e.commit_seq-o.lock_commit_seq)<0 { return }
    o.lock_presented=true;lock_maybe_ack(o.server)
}
lock_added :: proc "c" (listener: ^wl.Listener,data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"new_lock");h:=(^wlr.wlr_session_lock_v1)(data)
    if locked(s) { wlr.lock_reject(h);return }
    s.ext_lock=h;s.lock_acknowledged=false
    wl.listen(&h.events.new_surface,&s.lock_new_surface,lock_surface_added)
    wl.listen(&h.events.unlock,&s.lock_unlock,lock_unlocked)
    wl.listen(&h.events.destroy,&s.lock_destroy,lock_destroyed)
    lock_engage(s,.External)
    lock_maybe_ack(s)
}
lock_detach :: proc(s: ^Server) {
    wl.unlisten(&s.lock_new_surface);wl.unlisten(&s.lock_unlock);wl.unlisten(&s.lock_destroy)
    s.ext_lock=nil;s.lock_acknowledged=false
    for p in s.lock_surfaces { wlr.wlr_scene_node_set_enabled(&p.tree.node,false) }
}
lock_unlocked :: proc "c" (listener: ^wl.Listener,data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"lock_unlock")
    lock_detach(s);lock_disengage(s)
}
lock_destroyed :: proc "c" (listener: ^wl.Listener,data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"lock_destroy")
    lock_detach(s)
    if !s.shutting_down { lock_engage(s,.Native) }
}
lock_focus :: proc(s: ^Server) {
    if s.lock_owner!=.External { return }
    for p in s.lock_surfaces {
        if !p.handle.output.enabled || !p.handle.surface.mapped { continue }
        m:wlr.wlr_keyboard_modifiers
        // Empty enter prevents pre-lock held keys from becoming locker input.
        wlr.wlr_seat_keyboard_notify_enter(s.seat,p.handle.surface,nil,0,&m)
        return
    }
    wlr.wlr_seat_keyboard_notify_clear_focus(s.seat)
}
lock_surface_added :: proc "c" (listener: ^wl.Listener,data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"lock_new_surface")
    p:=new(Lock_Surface);p.server=s;p.handle=(^wlr.wlr_session_lock_surface_v1)(data)
    p.tree=wlr.layer_tree_create(s.lock_tree,p.handle.surface)
    if p.tree==nil { free(p);return }
    append(&s.lock_surfaces,p)
    wl.listen(&p.handle.events.destroy,&p.destroy,lock_surface_destroyed)
    wl.listen(&p.handle.surface.events.map_,&p.map_,lock_surface_mapped)
    wl.listen(&p.handle.surface.events.unmap,&p.unmap,lock_surface_unmapped)
    // Disabled outputs still need an initial configure to complete the role handshake.
    p.width,p.height=wlr.output_logical_size(p.handle.output)
    wlr.lock_configure(p.handle,p.width,p.height)
    lock_cover(s)
}
lock_surface_mapped :: proc "c" (listener: ^wl.Listener,data: rawptr) {
    context=runtime.default_context()
    p:=wl.owner(listener,Lock_Surface,"map_");lock_cover(p.server);lock_focus(p.server)
}
lock_surface_unmapped :: proc "c" (listener: ^wl.Listener,data: rawptr) {
    context=runtime.default_context()
    p:=wl.owner(listener,Lock_Surface,"unmap");wlr.wlr_scene_node_set_enabled(&p.tree.node,false);lock_focus(p.server)
}
lock_surface_destroyed :: proc "c" (listener: ^wl.Listener,data: rawptr) {
    context=runtime.default_context()
    p:=wl.owner(listener,Lock_Surface,"destroy");s:=p.server
    wl.unlisten(&p.destroy);wl.unlisten(&p.map_);wl.unlisten(&p.unmap)
    for v,i in s.lock_surfaces { if v==p { ordered_remove(&s.lock_surfaces,i);break } }
    wlr.wlr_scene_node_destroy(&p.tree.node)
    free(p);if !s.shutting_down { lock_focus(s) }
}
lock_input :: proc(s: ^Server,e: ^vm.Event) -> bool {
    if e.name=="request::activate" || e.name=="request::move" || e.name=="request::resize" { return locked(s) || e.lock_generation!=s.lock_generation }
    input:=e.class=="input" || e.native!=.None || (e.class=="session" && e.name=="key")
    if !input { return false }
    if e.lock_generation!=s.lock_generation {
        if !e.pressed {
            if e.native==.Key { if kb:=find_keyboard(s,e.keyboard);kb!=nil { delete_key(&kb.consumed,e.code) } }
            else if e.native==.Button { delete_key(&s.buttons,e.code) }
        }
        return true
    }
    if !locked(s) { return false }
    kb:=find_keyboard(s,e.keyboard)
    if kb==nil { return true }
    if e.name=="key" || e.native==.Key {
        if kb.consumed[e.code] {
            if !e.pressed { delete_key(&kb.consumed,e.code) }
            return true
        }
        if e.pressed { kb.consumed[e.code]=false } else { delete_key(&kb.consumed,e.code) }
        if s.lock_owner==.Native && e.class=="session" { vm.deliver(&s.lua,e) }
        else if s.lock_owner==.External && e.native==.Key && s.seat.keyboard_state.focused_surface!=nil {
            wlr.wlr_seat_set_keyboard(s.seat,kb.handle)
            wlr.wlr_seat_keyboard_notify_key(s.seat,e.time,e.code,u32(e.pressed))
        }
    } else if e.native==.Modifiers && s.lock_owner==.External {
        m:=wlr.wlr_keyboard_modifiers{e.mask[0],e.mask[1],e.mask[2],e.mask[3]}
        wlr.wlr_seat_set_keyboard(s.seat,kb.handle);wlr.wlr_seat_keyboard_notify_modifiers(s.seat,&m)
    }
    return true
}
