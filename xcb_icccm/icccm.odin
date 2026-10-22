package xcb_icccm
import raw "../xcb_icccm_raw"
urgent :: proc(hints: ^raw.xcb_icccm_wm_hints_t) -> bool {
    return hints!=nil && raw.xcb_icccm_wm_hints_get_urgency(hints)!=0
}
