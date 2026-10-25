package compositor

import sf "../surfaces"

import xw "../xwayland"

import sh "../shells"
import "core:strings"

import wlr "../wlroots"

xdg :: proc(v: ^View) -> ^sh.Toplevel { t,_:=v.protocol.(^sh.Toplevel);return t }
x11 :: proc(v: ^View) -> ^X11_View { x,_:=v.protocol.(^X11_View);return x }
view_surface :: proc(v: ^View) -> ^sf.Surface {
    if t:=xdg(v);t!=nil { return t.surface }
    if x:=x11(v);x!=nil { return x.surface }
    return nil
}
view_title_text :: proc(v: ^View) -> cstring {
    if t:=xdg(v);t!=nil { return strings.clone_to_cstring(t.title, context.temp_allocator) if t.title != "" else nil }
    if x:=x11(v);x!=nil { return strings.clone_to_cstring(x.handle.title, context.temp_allocator) if x.handle.title != "" else nil }
    return nil
}
view_app_text :: proc(v: ^View) -> cstring {
    if t:=xdg(v);t!=nil { return strings.clone_to_cstring(t.app_id, context.temp_allocator) if t.app_id != "" else nil }
    if x:=x11(v);x!=nil { return strings.clone_to_cstring(x.handle.class, context.temp_allocator) if x.handle.class != "" else nil }
    return nil
}
view_override_redirect :: proc(v: ^View) -> bool {
    x:=x11(v);return x!=nil && x.handle.override_redirect
}
view_geometry :: proc(v: ^View) -> wlr.wlr_box {
    if t:=xdg(v);t!=nil { return t.geometry }
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
    if t:=xdg(v);t!=nil { sh.set_activated(t,on) }
    else if x:=x11(v);x!=nil { xw.activate(x.handle,on) }
}
view_close :: proc(v: ^View) {
    if t:=xdg(v);t!=nil { sh.send_close(t) }
    else if x:=x11(v);x!=nil { xw.close(x.handle) }
}
view_fullscreen_hint :: proc(v: ^View, on: bool) {
    if t:=xdg(v);t!=nil { sh.set_fullscreen(t,on) }
    else if x:=x11(v);x!=nil { x.granted_fullscreen=on;xw.set_fullscreen(x.handle,on) }
}
view_maximize_hint :: proc(v: ^View, on: bool) {
    if t:=xdg(v);t!=nil { sh.set_maximized(t,on) }
    else if x:=x11(v);x!=nil { x.granted_maximized=on;xw.set_maximized(x.handle,on) }
}
