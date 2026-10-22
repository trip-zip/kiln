package xcb_icccm_raw
xcb_icccm_wm_hints_t :: struct {}
foreign import lib "system:xcb-icccm"
foreign lib {
    xcb_icccm_wm_hints_get_urgency :: proc(hints: ^xcb_icccm_wm_hints_t) -> u32 ---
}
