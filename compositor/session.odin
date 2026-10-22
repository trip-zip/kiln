package compositor

import "base:runtime"
import "core:fmt"
import wl "../wayland"
import wlr "../wlroots"

session_changed :: proc "c" (listener:^wl.Listener,data:rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"session_active")
    if wlr.session_active(s.session) { for o in s.outputs { dirty(o) } }
}
session_destroyed :: proc "c" (listener:^wl.Listener,data:rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"session_destroy")
    wl.unlisten(&s.session_active);wl.unlisten(listener)
    s.session=nil
}
vt_number :: proc(symbol,mods:u32) -> u32 {
    if mods&4==0 || mods&8==0 || symbol<0x1008fe01 || symbol>0x1008fe0c { return 0 }
    return symbol-0x1008fe01+1
}
native_vt :: proc(s:^Server,syms:[]u32,mods:u32,pressed:bool,switch_vt:proc(^wlr.wlr_session,u32)->bool = wlr.session_switch) -> bool {
    if locked(s) || !pressed || s.session==nil { return false }
    for sym in syms {
        vt:=vt_number(sym,mods)
        if vt==0 { continue }
        if !switch_vt(s.session,vt) { fmt.eprintf("VT %d request rejected\n",vt) }
        return true
    }
    return false
}
