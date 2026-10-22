package xcb_ewmh_raw
import "core:c"
import x "../xcb_raw"
xcb_ewmh_get_wm_icon_reply_t :: struct { num_icons: c.uint, _reply: ^x.xcb_get_property_reply_t }
xcb_ewmh_wm_icon_iterator_t :: struct { width,height: u32, data: [^]u32, rem,index: c.uint }
foreign import lib "system:xcb-ewmh"
foreign lib {
    xcb_ewmh_get_wm_icon_from_reply :: proc(icon: ^xcb_ewmh_get_wm_icon_reply_t, reply: ^x.xcb_get_property_reply_t) -> u8 ---
    xcb_ewmh_get_wm_icon_iterator :: proc(icon: ^xcb_ewmh_get_wm_icon_reply_t) -> xcb_ewmh_wm_icon_iterator_t ---
    xcb_ewmh_get_wm_icon_next :: proc(iterator: ^xcb_ewmh_wm_icon_iterator_t) ---
    xcb_ewmh_get_wm_icon_reply_wipe :: proc(icon: ^xcb_ewmh_get_wm_icon_reply_t) ---
}
#assert(size_of(xcb_ewmh_get_wm_icon_reply_t)==16 && align_of(xcb_ewmh_get_wm_icon_reply_t)==8)
#assert(offset_of(xcb_ewmh_get_wm_icon_reply_t,num_icons)==0 && offset_of(xcb_ewmh_get_wm_icon_reply_t,_reply)==8)
#assert(size_of(xcb_ewmh_wm_icon_iterator_t)==24 && align_of(xcb_ewmh_wm_icon_iterator_t)==8)
#assert(offset_of(xcb_ewmh_wm_icon_iterator_t,width)==0 && offset_of(xcb_ewmh_wm_icon_iterator_t,height)==4)
#assert(offset_of(xcb_ewmh_wm_icon_iterator_t,data)==8 && offset_of(xcb_ewmh_wm_icon_iterator_t,rem)==16 && offset_of(xcb_ewmh_wm_icon_iterator_t,index)==20)
