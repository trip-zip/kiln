package wlroots

import wl "../wayland_server"

wlr_gamma_control_manager_v1 :: struct #align(8) {
    _opaque_0: [24]u8,
    fallback_gamma_size: uintptr,
    events: struct { destroy, set_gamma: wl.wl_signal },
    _opaque_64: [32]u8,
}
#assert(size_of(wlr_gamma_control_manager_v1)==96 && align_of(wlr_gamma_control_manager_v1)==8)
#assert(offset_of(wlr_gamma_control_manager_v1,fallback_gamma_size)==24)
foreign import gamma_lib "system:wlroots-0.20"
foreign gamma_lib {
    wlr_gamma_control_manager_v1_create :: proc(display:^wl.wl_display) -> ^wlr_gamma_control_manager_v1 ---
}
gamma_create :: proc(display:^wl.wl_display) -> ^wlr_gamma_control_manager_v1 {
    manager:=wlr_gamma_control_manager_v1_create(display)
    if manager!=nil { manager.fallback_gamma_size=256 }
    return manager
}
