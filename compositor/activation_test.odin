package compositor

import sh "../shells"

import ext "../extensions"

import "core:testing"
import "core:strings"
import wl "../wayland"
import wlr "../wlroots"
import vm "../lua_runtime"

@(test)
activation_owns_payload_and_retires_mints :: proc(t: ^testing.T) {
    s:=Server{display=wl.create()}
    s.seat=wlr.wlr_seat_create(s.display,"activation")
    s.activation=ext.activation_create(s.display)
    testing.expect(t,s.activation!=nil && s.seat!=nil)
    defer destroy(&s)
    for _ in 0..<20 {
        token,name:=runtime_mint_token(&s)
        testing.expect(t,token!=nil && name!=nil)
        testing.expect_value(t,len(s.minted_tokens),1)
        runtime_retire_token(&s,token)
        testing.expect_value(t,len(s.minted_tokens),0)
    }
    surface:wlr.wlr_surface
    top:=sh.Toplevel{surface=&surface}
    v:=View{id=42,server=&s,protocol=&top,mapped=true}
    append(&s.views,&v)
    defer clear(&s.views)
    app:=strings.clone_to_cstring("hint")
    token:=ext.Activation_Token{seat=s.seat,app_id=app}
    event:=ext.Activation_Event{token=&token,surface=&surface}
    activation_requested(&s.request_activate,&event)
    delete(app)
    testing.expect_value(t,len(s.events),1)
    testing.expect_value(t,s.events[0].app_id,"hint")
    testing.expect(t,s.events[0].valid && s.events[0].handle==42)
    s.lua.data=&s;s.lua.mint_token=runtime_mint_token;s.lua.retire_token=runtime_retire_token
    testing.expect(t,vm.init(&s.lua))
    expect_eval(t,&s,"core.spawn_with_token({});core.spawn_with_token({'/nonexistent/kiln-activation-unit'})","\n")
    testing.expect_value(t,len(s.minted_tokens),0)
    expect_eval(t,&s,"core.set_event_handler(function(e) E=e;collectgarbage('collect') end)","\n")
    wl.remove_source(s.event_source);drain_pending(&s)
    expect_eval(t,&s,"return E.name,E.handle,E.valid,E.app_id","request::activate\t42\ttrue\thint\n")
    // A seat signal retires our token using only public listener fields.
    minted,_:=runtime_mint_token(&s)
    testing.expect(t,minted!=nil)
    minted_seat_destroyed(&s.minted_tokens[0].seat_destroy,nil)
    testing.expect_value(t,len(s.minted_tokens),0)
    runtime_mint_token(&s)
}
