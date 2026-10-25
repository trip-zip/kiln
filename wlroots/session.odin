package wlroots

import wl "../wayland"

wlr_session :: struct #align(8) {
    active:bool,
    _opaque_1:[327]u8,
    events:struct { active: wl.Signal, _opaque_16: [16]u8, destroy: wl.Signal },
    _opaque_376:[24]u8,
}
#assert(size_of(wlr_session)==400 && align_of(wlr_session)==8 && offset_of(wlr_session,active)==0 && offset_of(wlr_session,events)==328)
foreign import session_lib "system:wlroots-0.20"
foreign session_lib {
    wlr_session_change_vt :: proc(session:^wlr_session,vt:u32) -> bool ---
}
session_switch :: proc(session:^wlr_session,vt:u32) -> bool { return session!=nil && wlr_session_change_vt(session,vt) }
session_active :: proc(session:^wlr_session) -> bool { return session==nil || session.active }
