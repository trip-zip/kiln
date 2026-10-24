package compositor

import ext "../extensions"

import "base:runtime"
import wl "../wayland"
import vm "../lua_runtime"

Minted_Token :: struct {
    server: ^Server,
    allocator: runtime.Allocator,
    token: ^ext.Activation_Token,
    destroy, seat_destroy: wl.Listener,
}
activation_requested :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"request_activate")
    e:=(^ext.Activation_Event)(data)
    for v in s.views {
        if xdg(v)!=nil && view_surface(v) == e.surface && v.mapped {
            queue_event(s,vm.Event{name="request::activate",handle=v.id,
                valid=e.token.seat!=nil,app_id=string(e.token.app_id),has_app_id=e.token.app_id!=nil})
            return
        }
    }
}
minted_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    m:=wl.owner(listener,Minted_Token,"destroy")
    wl.unlisten(&m.destroy);wl.unlisten(&m.seat_destroy)
    for t,i in m.server.minted_tokens { if t==m { unordered_remove(&m.server.minted_tokens,i);break } }
    free(m,m.allocator)
}
minted_seat_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    m:=wl.owner(listener,Minted_Token,"seat_destroy")
    // Trusted mints have no client serial or private protocol seat listener.
    ext.activation_retire(m.token)
}
runtime_mint_token :: proc(data: rawptr) -> (rawptr,cstring) {
    s:=(^Server)(data)
    if s.shutting_down || s.activation==nil || s.seat==nil { return nil,nil }
    token,name:=ext.activation_mint(s.activation)
    if token==nil { return nil,nil }
    m:=new(Minted_Token)
    m^={server=s,allocator=context.allocator,token=token}
    wl.listen(&token.events.destroy,&m.destroy,minted_destroyed)
    wl.listen(&s.seat.events.destroy,&m.seat_destroy,minted_seat_destroyed)
    token.seat=s.seat
    append(&s.minted_tokens,m)
    return token,name
}
runtime_retire_token :: proc(data,token: rawptr) {
    ext.activation_retire((^ext.Activation_Token)(token))
}
