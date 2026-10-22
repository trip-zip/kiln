package compositor

import "base:runtime"
import "core:strings"
import wl "../wayland"
import wlr "../wlroots"
import vm "../lua_runtime"

foreign_identity :: proc(v: ^View) {
    if v.foreign_handle==nil { return }
    ctitle,capp:=view_title_text(v),view_app_text(v)
    title,app:=string(ctitle),string(capp)
    if title!=v.foreign_title {
        delete(v.foreign_title,v.foreign_allocator);v.foreign_title=strings.clone(title,v.foreign_allocator)
        wlr.foreign_title(v.foreign_handle,ctitle if ctitle!=nil else "")
    }
    if app!=v.foreign_app {
        delete(v.foreign_app,v.foreign_allocator);v.foreign_app=strings.clone(app,v.foreign_allocator)
        wlr.foreign_app_id(v.foreign_handle,capp if capp!=nil else "")
    }
}
foreign_create :: proc(v: ^View) {
    if v.server.foreign_manager==nil { return }
    v.foreign_allocator=context.allocator
    v.foreign_handle=wlr.foreign_handle_create(v.server.foreign_manager)
    if v.foreign_handle==nil { fail(v.server,"Cannot create foreign toplevel");return }
    foreign_identity(v)
    full,maxed,minimized:=view_states(v,false)
    wlr.foreign_maximized(v.foreign_handle,maxed)
    wlr.foreign_minimized(v.foreign_handle,minimized)
    wlr.foreign_fullscreen(v.foreign_handle,full)
    v.foreign_output=nil
    foreign_place(v,v.output)
    wl.listen(&v.foreign_handle.events.request_maximize,&v.foreign_maximize,foreign_request_maximize)
    wl.listen(&v.foreign_handle.events.request_minimize,&v.foreign_minimize,foreign_request_minimize)
    wl.listen(&v.foreign_handle.events.request_activate,&v.foreign_activate,foreign_request_activate)
    wl.listen(&v.foreign_handle.events.request_fullscreen,&v.foreign_fullscreen,foreign_request_fullscreen)
    wl.listen(&v.foreign_handle.events.request_close,&v.foreign_close,foreign_request_close)
}
foreign_destroy :: proc(v: ^View) {
    if v.foreign_handle==nil { return }
    wl.unlisten(&v.foreign_maximize)
    wl.unlisten(&v.foreign_minimize)
    wl.unlisten(&v.foreign_activate)
    wl.unlisten(&v.foreign_fullscreen)
    wl.unlisten(&v.foreign_close)
    wlr.foreign_handle_destroy(v.foreign_handle);v.foreign_handle=nil;v.foreign_output=nil
    delete(v.foreign_title,v.foreign_allocator);delete(v.foreign_app,v.foreign_allocator);v.foreign_title="";v.foreign_app=""
}
foreign_place :: proc(v: ^View, output: ^Output) {
    target: ^wlr.wlr_output
    if output!=nil { target=output.handle }
    wlr.foreign_output(v.foreign_handle,v.foreign_output,target)
    v.foreign_output=target
}
foreign_request_maximize :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    v:=wl.owner(listener,View,"foreign_maximize")
    e:=(^wlr.wlr_foreign_toplevel_handle_v1_maximized_event)(data)
    queue_event(v.server,vm.Event{name="request::maximize",handle=v.id,on=e.maximized})
}
foreign_request_minimize :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    v:=wl.owner(listener,View,"foreign_minimize")
    e:=(^wlr.wlr_foreign_toplevel_handle_v1_minimized_event)(data)
    queue_event(v.server,vm.Event{name="request::minimize",handle=v.id,on=e.minimized})
}
foreign_request_fullscreen :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    v:=wl.owner(listener,View,"foreign_fullscreen")
    e:=(^wlr.wlr_foreign_toplevel_handle_v1_fullscreen_event)(data)
    queue_event(v.server,vm.Event{name="request::fullscreen",handle=v.id,on=e.fullscreen})
}
foreign_request_activate :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    v:=wl.owner(listener,View,"foreign_activate")
    e:=(^wlr.wlr_foreign_toplevel_handle_v1_activated_event)(data)
    queue_event(v.server,vm.Event{name="request::activate",handle=v.id,valid=e.seat!=nil})
}
foreign_request_close :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    v:=wl.owner(listener,View,"foreign_close")
    queue_event(v.server,vm.Event{name="request::close",handle=v.id})
}
