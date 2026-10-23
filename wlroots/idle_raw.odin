package wlroots

import wl "../wayland"

wlr_idle_notifier_v1 :: struct {}
wlr_idle_inhibit_manager_v1 :: struct #align(8) {
    _opaque_0: [24]u8,
    events: struct { new_inhibitor, destroy: wl.Signal },
    _opaque_56: [32]u8,
}
wlr_idle_inhibitor_v1 :: struct #align(8) {
    surface: ^wlr_surface,
    _opaque_8: [24]u8,
    events: struct { destroy: wl.Signal },
    _opaque_48: [32]u8,
}
foreign import idle_lib "system:wlroots-0.20"
foreign idle_lib {
    wlr_idle_notifier_v1_create :: proc(display: ^wl.Display) -> ^wlr_idle_notifier_v1 ---
    wlr_idle_notifier_v1_set_inhibited :: proc(notifier: ^wlr_idle_notifier_v1, inhibited: bool) ---
    wlr_idle_notifier_v1_notify_activity :: proc(notifier: ^wlr_idle_notifier_v1, seat: ^wlr_seat) ---
    wlr_idle_inhibit_v1_create :: proc(display: ^wl.Display) -> ^wlr_idle_inhibit_manager_v1 ---
    wlr_surface_get_root_surface :: proc(surface: ^wlr_surface) -> ^wlr_surface ---
}
#assert(size_of(wlr_idle_inhibit_manager_v1)==88 && align_of(wlr_idle_inhibit_manager_v1)==8)
#assert(offset_of(wlr_idle_inhibit_manager_v1,events)==24)
#assert(size_of(type_of(wlr_idle_inhibit_manager_v1{}.events))==32 && align_of(type_of(wlr_idle_inhibit_manager_v1{}.events))==8)
#assert(offset_of(type_of(wlr_idle_inhibit_manager_v1{}.events),new_inhibitor)==0)
#assert(offset_of(type_of(wlr_idle_inhibit_manager_v1{}.events),destroy)==16)
#assert(size_of(wlr_idle_inhibitor_v1)==80 && align_of(wlr_idle_inhibitor_v1)==8)
#assert(offset_of(wlr_idle_inhibitor_v1,surface)==0 && offset_of(wlr_idle_inhibitor_v1,events)==32)
#assert(size_of(type_of(wlr_idle_inhibitor_v1{}.events))==16 && align_of(type_of(wlr_idle_inhibitor_v1{}.events))==8)
#assert(offset_of(type_of(wlr_idle_inhibitor_v1{}.events),destroy)==0)
