package wlroots

import wl "../wayland"
import xcb "../xcb_raw"
import icccm "../xcb_icccm_raw"

wlr_xwayland :: struct #align(8) {
    server: ^wlr_xwayland_server,
    _opaque_8: [24]u8,
    display_name: cstring,
    _opaque_40: [16]u8,
    seat: ^wlr_seat,
    events: struct { destroy, ready, new_surface: wl.Signal, _opaque_48: [16]u8 },
    _opaque_128: [152]u8,
}
wlr_xwayland_server :: struct #align(8) {
    pid: i32,
    _opaque_4: [36]u8,
    ready: bool,
    _opaque_41: [15]u8,
    display: i32,
    _opaque_60: [68]u8,
    events: struct { start: wl.Signal, _opaque_16: [32]u8 },
    _opaque_176: [56]u8,
}
foreign import xwayland_lib "system:wlroots-0.20"
foreign xwayland_lib {
    wlr_xwayland_create :: proc(display: ^wl.Display, compositor: ^wlr_compositor, lazy: bool) -> ^wlr_xwayland ---
    wlr_xwayland_destroy :: proc(xwayland: ^wlr_xwayland) ---
    wlr_xwayland_set_seat :: proc(xwayland: ^wlr_xwayland, seat: ^wlr_seat) ---
}
xwayland_create :: proc(display: ^wl.Display, compositor: ^wlr_compositor) -> ^wlr_xwayland {
    return wlr_xwayland_create(display,compositor,true)
}
xwayland_destroy :: proc(xwayland: ^wlr_xwayland) { wlr_xwayland_destroy(xwayland) }
xwayland_seat :: proc(xwayland: ^wlr_xwayland, seat: ^wlr_seat) { wlr_xwayland_set_seat(xwayland,seat) }

#assert(size_of(wlr_xwayland)==280 && align_of(wlr_xwayland)==8)
#assert(offset_of(wlr_xwayland,server)==0 && offset_of(wlr_xwayland,display_name)==32)
#assert(offset_of(wlr_xwayland,seat)==56 && offset_of(wlr_xwayland,events)==64)
#assert(size_of(type_of(wlr_xwayland{}.events))==64 && align_of(type_of(wlr_xwayland{}.events))==8)
#assert(offset_of(type_of(wlr_xwayland{}.events),destroy)==0)
#assert(offset_of(type_of(wlr_xwayland{}.events),ready)==16)
#assert(offset_of(type_of(wlr_xwayland{}.events),new_surface)==32)
#assert(size_of(wlr_xwayland_server)==232 && align_of(wlr_xwayland_server)==8)
#assert(offset_of(wlr_xwayland_server,pid)==0 && offset_of(wlr_xwayland_server,ready)==40)
#assert(offset_of(wlr_xwayland_server,display)==56)
#assert(offset_of(wlr_xwayland_server,events)==128)
#assert(size_of(type_of(wlr_xwayland_server{}.events))==48 && align_of(type_of(wlr_xwayland_server{}.events))==8)
#assert(offset_of(type_of(wlr_xwayland_server{}.events),start)==0)

wlr_xwayland_surface_events :: struct #align(8) {
    destroy: wl.Signal,
    request_configure: wl.Signal,
    _opaque_32: [32]u8,
    request_minimize: wl.Signal,
    request_maximize: wl.Signal,
    request_fullscreen: wl.Signal,
    request_activate: wl.Signal,
    _opaque_128: [128]u8,
    associate: wl.Signal,
    dissociate: wl.Signal,
    set_title: wl.Signal,
    set_class: wl.Signal,
    set_role, set_parent: wl.Signal,
    _opaque_352: [16]u8,
    set_window_type, set_hints: wl.Signal,
    _opaque_400: [64]u8,
    set_geometry: wl.Signal,
    _opaque_480: [16]u8,
    set_icon: wl.Signal,
    _opaque_512: [32]u8,
    map_request: wl.Signal,
    _opaque_560: [16]u8,
}
wlr_xwayland_surface :: struct #align(8) {
    window_id: u32,
    _opaque_4: [76]u8,
    surface: ^wlr_surface,
    _opaque_88: [32]u8,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    override_redirect: bool,
    _opaque_129: [7]u8,
    title: cstring,
    class: cstring,
    instance: cstring,
    role: cstring,
    _opaque_168: [8]u8,
    pid: i32,
    _opaque_180: [20]u8,
    parent: ^wlr_xwayland_surface,
    _opaque_208: [16]u8,
    window_type: [^]u32,
    window_type_len: uint,
    _opaque_240: [24]u8,
    hints: ^icccm.xcb_icccm_wm_hints_t,
    _opaque_272: [33]u8,
    fullscreen: bool,
    maximized_vert: bool,
    maximized_horz: bool,
    minimized: bool,
    _opaque_309: [11]u8,
    events: wlr_xwayland_surface_events,
    data: rawptr,
    _opaque_904: [88]u8,
}
wlr_xwayland_surface_configure_event :: struct #align(8) {
    _opaque_0: [8]u8,
    x,y: i16,
    width,height: u16,
    _opaque_16: [8]u8,
}
wlr_xwayland_minimize_event :: struct #align(8) { _opaque_0: [8]u8, minimize: bool }
foreign xwayland_lib {
    wlr_xwayland_surface_configure :: proc(surface: ^wlr_xwayland_surface, x,y: i16, width,height: u16) ---
    wlr_xwayland_surface_activate :: proc(surface: ^wlr_xwayland_surface, activated: bool) ---
    wlr_xwayland_surface_close :: proc(surface: ^wlr_xwayland_surface) ---
    wlr_xwayland_surface_set_minimized :: proc(surface: ^wlr_xwayland_surface, minimized: bool) ---
    wlr_xwayland_surface_set_maximized :: proc(surface: ^wlr_xwayland_surface, maximized_horz,maximized_vert: bool) ---
    wlr_xwayland_surface_set_fullscreen :: proc(surface: ^wlr_xwayland_surface, fullscreen: bool) ---
    wlr_xwayland_surface_override_redirect_wants_focus :: proc(surface: ^wlr_xwayland_surface) -> bool ---
    wlr_xwayland_get_xwm_connection :: proc(xwayland: ^wlr_xwayland) -> ^xcb.xcb_connection_t ---
    wlr_surface_has_buffer :: proc(surface: ^wlr_surface) -> bool ---
    wlr_surface_map :: proc(surface: ^wlr_surface) ---
}
// X11 and Wayland socket dispatch can deliver the first buffer before association.
// Complete the X11 role's map operation after the compositor attaches listeners.
xwayland_map_buffered :: proc(surface: ^wlr_surface) -> bool {
    if !wlr_surface_has_buffer(surface) { return false }
    wlr_surface_map(surface)
    return true
}
xwayland_configure :: proc(surface: ^wlr_xwayland_surface, x,y,width,height: i32) -> bool {
    if x< -32768 || x>32767 || y< -32768 || y>32767 || width<1 || width>65535 || height<1 || height>65535 { return false }
    wlr_xwayland_surface_configure(surface,i16(x),i16(y),u16(width),u16(height))
    return true
}
xwayland_activate :: proc(surface: ^wlr_xwayland_surface, on: bool) { wlr_xwayland_surface_activate(surface,on) }
xwayland_close :: proc(surface: ^wlr_xwayland_surface) { wlr_xwayland_surface_close(surface) }
xwayland_minimize :: proc(surface: ^wlr_xwayland_surface, on: bool) { wlr_xwayland_surface_set_minimized(surface,on) }
xwayland_maximize :: proc(surface: ^wlr_xwayland_surface, on: bool) { wlr_xwayland_surface_set_maximized(surface,on,on) }
xwayland_fullscreen :: proc(surface: ^wlr_xwayland_surface, on: bool) { wlr_xwayland_surface_set_fullscreen(surface,on) }
xwayland_wants_focus :: proc(surface: ^wlr_xwayland_surface) -> bool { return wlr_xwayland_surface_override_redirect_wants_focus(surface) }
// The XWM owns this connection. Resolve it afresh for each operation across restarts.
xwayland_connection :: proc(xwayland: ^wlr_xwayland) -> ^xcb.xcb_connection_t {
    if xwayland==nil { return nil }
    return wlr_xwayland_get_xwm_connection(xwayland)
}
#assert(size_of(wlr_xwayland_surface)==992 && align_of(wlr_xwayland_surface)==8)
#assert(offset_of(wlr_xwayland_surface,window_id)==0 && offset_of(wlr_xwayland_surface,surface)==80)
#assert(offset_of(wlr_xwayland_surface,x)==120 && offset_of(wlr_xwayland_surface,y)==122)
#assert(offset_of(wlr_xwayland_surface,width)==124 && offset_of(wlr_xwayland_surface,height)==126)
#assert(offset_of(wlr_xwayland_surface,override_redirect)==128 && offset_of(wlr_xwayland_surface,title)==136)
#assert(offset_of(wlr_xwayland_surface,class)==144 && offset_of(wlr_xwayland_surface,instance)==152)
#assert(offset_of(wlr_xwayland_surface,pid)==176 && offset_of(wlr_xwayland_surface,parent)==200)
#assert(offset_of(wlr_xwayland_surface,fullscreen)==305 && offset_of(wlr_xwayland_surface,maximized_vert)==306)
#assert(offset_of(wlr_xwayland_surface,maximized_horz)==307 && offset_of(wlr_xwayland_surface,minimized)==308)
#assert(offset_of(wlr_xwayland_surface,events)==320 && offset_of(wlr_xwayland_surface,data)==896)
#assert(size_of(wlr_xwayland_surface_events)==576 && align_of(wlr_xwayland_surface_events)==8)
#assert(offset_of(wlr_xwayland_surface_events,destroy)==0)
#assert(offset_of(wlr_xwayland_surface_events,request_configure)==16)
#assert(offset_of(wlr_xwayland_surface_events,request_minimize)==64)
#assert(offset_of(wlr_xwayland_surface_events,request_maximize)==80)
#assert(offset_of(wlr_xwayland_surface_events,request_fullscreen)==96)
#assert(offset_of(wlr_xwayland_surface_events,request_activate)==112)
#assert(offset_of(wlr_xwayland_surface_events,associate)==256 && offset_of(wlr_xwayland_surface_events,dissociate)==272)
#assert(offset_of(wlr_xwayland_surface_events,set_title)==288 && offset_of(wlr_xwayland_surface_events,set_class)==304)
#assert(offset_of(wlr_xwayland_surface_events,set_geometry)==464)
#assert(size_of(wlr_xwayland_surface_configure_event)==24 && align_of(wlr_xwayland_surface_configure_event)==8)
#assert(offset_of(wlr_xwayland_surface_configure_event,x)==8 && offset_of(wlr_xwayland_surface_configure_event,y)==10)
#assert(offset_of(wlr_xwayland_surface_configure_event,width)==12)
#assert(offset_of(wlr_xwayland_surface_configure_event,height)==14)
#assert(size_of(wlr_xwayland_minimize_event)==16 && align_of(wlr_xwayland_minimize_event)==8)
#assert(offset_of(wlr_xwayland_minimize_event,minimize)==8)

#assert(offset_of(wlr_xwayland_surface,role)==160)

#assert(offset_of(wlr_xwayland_surface,window_type)==224)

#assert(offset_of(wlr_xwayland_surface,window_type_len)==232)

#assert(offset_of(wlr_xwayland_surface,hints)==264)
#assert(offset_of(wlr_xwayland_surface_events,set_role)==320 && offset_of(wlr_xwayland_surface_events,set_parent)==336)
#assert(offset_of(wlr_xwayland_surface_events,set_window_type)==368)
#assert(offset_of(wlr_xwayland_surface_events,set_hints)==384 && offset_of(wlr_xwayland_surface_events,set_icon)==496)

#assert(offset_of(wlr_xwayland_surface_events,map_request)==544)
