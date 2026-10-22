package compositor

import wlr "../wlroots"

xdg :: proc(v: ^View) -> ^wlr.wlr_xdg_toplevel { t,_:=v.protocol.(^wlr.wlr_xdg_toplevel);return t }
x11 :: proc(v: ^View) -> ^X11_View { x,_:=v.protocol.(^X11_View);return x }
view_surface :: proc(v: ^View) -> ^wlr.wlr_surface {
    if t:=xdg(v);t!=nil { return t.base.surface }
    if x:=x11(v);x!=nil { return x.surface }
    return nil
}
view_title_text :: proc(v: ^View) -> cstring {
    if t:=xdg(v);t!=nil { return t.title }
    if x:=x11(v);x!=nil { return x.handle.title }
    return nil
}
view_app_text :: proc(v: ^View) -> cstring {
    if t:=xdg(v);t!=nil { return t.app_id }
    if x:=x11(v);x!=nil { return x.handle.class }
    return nil
}
view_override_redirect :: proc(v: ^View) -> bool {
    x:=x11(v);return x!=nil && x.handle.override_redirect
}
view_geometry :: proc(v: ^View) -> wlr.wlr_box {
    if t:=xdg(v);t!=nil { return t.base.geometry }
    if surface:=view_surface(v);surface!=nil { return {width=surface.current.width,height=surface.current.height} }
    return {}
}
view_parent :: proc(v: ^View) -> u32 {
    for p in v.server.views {
        if t:=xdg(v);t!=nil { if pt:=xdg(p);pt!=nil && pt==t.parent { return p.id } }
        else if x:=x11(v);x!=nil { if px:=x11(p);px!=nil && px.handle==x.handle.parent { return p.id } }
    }
    return 0
}
view_states :: proc(v: ^View, replay: bool) -> (full,maxed,minimized: bool) {
    if t:=xdg(v);t!=nil {
        if replay { return t.current.fullscreen,t.current.maximized,false }
        return t.requested.fullscreen,t.requested.maximized,t.requested.minimized
    }
    if x:=x11(v);x!=nil {
        if replay { return x.granted_fullscreen,x.granted_maximized,x.granted_minimized }
        return x.handle.fullscreen,x.handle.maximized_horz && x.handle.maximized_vert,x.handle.minimized
    }
    return
}
view_activate :: proc(v: ^View, on: bool) {
    if t:=xdg(v);t!=nil { wlr.wlr_xdg_toplevel_set_activated(t,on) }
    else if x:=x11(v);x!=nil { wlr.xwayland_activate(x.handle,on) }
}
view_close :: proc(v: ^View) {
    if t:=xdg(v);t!=nil { wlr.wlr_xdg_toplevel_send_close(t) }
    else if x:=x11(v);x!=nil { wlr.xwayland_close(x.handle) }
}
view_fullscreen_hint :: proc(v: ^View, on: bool) {
    if t:=xdg(v);t!=nil { wlr.wlr_xdg_toplevel_set_fullscreen(t,on) }
    else if x:=x11(v);x!=nil { x.granted_fullscreen=on;wlr.xwayland_fullscreen(x.handle,on) }
}
view_maximize_hint :: proc(v: ^View, on: bool) {
    if t:=xdg(v);t!=nil { wlr.wlr_xdg_toplevel_set_maximized(t,on) }
    else if x:=x11(v);x!=nil { x.granted_maximized=on;wlr.xwayland_maximize(x.handle,on) }
}
