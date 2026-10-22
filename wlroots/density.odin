package wlroots

import wl "../wayland_server"

wlr_viewporter :: struct {}
wlr_fractional_scale_manager_v1 :: struct {}
foreign import density_lib "system:wlroots-0.20"
foreign density_lib {
    wlr_viewporter_create :: proc(display: ^wl.wl_display) -> ^wlr_viewporter ---
    wlr_fractional_scale_manager_v1_create :: proc(display: ^wl.wl_display, version: u32) -> ^wlr_fractional_scale_manager_v1 ---
}

density_protocols_create :: proc(display: ^wl.wl_display) -> bool {
    return wlr_viewporter_create(display)!=nil && wlr_fractional_scale_manager_v1_create(display,1)!=nil
}
