package wlroots

import wl "../wayland_server"

wlr_gamma_control_manager_v1 :: struct #align(8) {
    _opaque_0: [24]u8,
    fallback_gamma_size: uintptr,
    _opaque_32: [64]u8,
}
#assert(size_of(wlr_gamma_control_manager_v1)==96 && align_of(wlr_gamma_control_manager_v1)==8)
#assert(offset_of(wlr_gamma_control_manager_v1,fallback_gamma_size)==24)
foreign import gamma_lib "system:wlroots-0.20"
foreign gamma_lib {
    wlr_gamma_control_manager_v1_create :: proc(display:^wl.wl_display) -> ^wlr_gamma_control_manager_v1 ---
    wlr_scene_set_gamma_control_manager_v1 :: proc(scene:^wlr_scene,manager:^wlr_gamma_control_manager_v1) ---
}
gamma_create :: proc(display:^wl.wl_display,scene:^wlr_scene) -> ^wlr_gamma_control_manager_v1 {
    manager:=wlr_gamma_control_manager_v1_create(display)
    if manager!=nil { wlr_scene_set_gamma_control_manager_v1(scene,manager) }
    return manager
}
