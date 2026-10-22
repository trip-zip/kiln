package compositor

import "base:runtime"
import wl "../wayland"
import wlr "../wlroots"
import vm "../lua_runtime"

queue_decoration :: proc(view: ^View) {
    names:=[3]string{"none","client_side","server_side"}
    queue_event(view.server,vm.Event{name="request::decoration_mode",handle=view.id,bytes=names[clamp(view.decoration_mode,0,2)]})
}
decoration_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"new_decoration")
    d:=(^wlr.wlr_xdg_toplevel_decoration_v1)(data)
    for v in s.views {
        if xdg(v)!=d.toplevel { continue }
        v.decoration=d
        wl.listen(&d.events.request_mode,&v.decoration_request,decoration_request)
        wl.listen(&d.events.destroy,&v.decoration_destroy,decoration_destroy)
        wlr.decoration_server_mode(d)
        return
    }
}
decoration_request :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    v:=wl.owner(listener,View,"decoration_request")
    v.decoration_mode=v.decoration.requested_mode
    v.decoration_requested=true
    queue_decoration(v)
    wlr.decoration_server_mode(v.decoration)
}
decoration_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    v:=wl.owner(listener,View,"decoration_destroy")
    wl.unlisten(&v.decoration_request);wl.unlisten(&v.decoration_destroy)
    v.decoration=nil
}
