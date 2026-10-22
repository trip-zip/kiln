package xcb_ewmh
import raw "../xcb_ewmh_raw"
import x "../xcb"
import xr "../xcb_raw"
MAX_ICON_PIXELS :: 16*1024*1024
// Validate the entire property before a library iterator can advance over pixels.
valid_icons :: proc(words: []u32) -> bool {
    if len(words)==0 { return false }
    for i:=0; i<len(words); {
        if len(words)-i<2 { return false }
        n:=u64(words[i])*u64(words[i+1])
        if n>MAX_ICON_PIXELS || n>u64(len(words)-i-2) { return false }
        i+=2+int(n)
    }
    return true
}
icon :: proc(connection: ^xr.xcb_connection_t, window, atom: u32) -> (pixels: []u32, width,height: i32) {
    reply:=x.property(connection,window,atom,MAX_ICON_PIXELS+1024,6)
    if reply==nil { return }
    // A bounded read rejects truncation instead of parsing a partial icon frame.
    bytes:=x.property_bytes(reply)
    if reply.type!=6 || reply.format!=32 || reply.bytes_after!=0 || len(bytes)%4!=0 {
        x.release(reply);return
    }
    words:=([^]u32)(raw_data(bytes))[:len(bytes)/4]
    if !valid_icons(words) { x.release(reply);return }
    icons:raw.xcb_ewmh_get_wm_icon_reply_t
    if raw.xcb_ewmh_get_wm_icon_from_reply(&icons,reply)==0 { x.release(reply);return }
    defer raw.xcb_ewmh_get_wm_icon_reply_wipe(&icons)
    best:raw.xcb_ewmh_wm_icon_iterator_t
    it:=raw.xcb_ewmh_get_wm_icon_iterator(&icons)
    for it.rem>0 {
        if u64(it.width)*u64(it.height)>u64(best.width)*u64(best.height) { best=it }
        raw.xcb_ewmh_get_wm_icon_next(&it)
    }
    if best.width==0 || best.height==0 { return }
    pixels=make([]u32,int(best.width)*int(best.height))
    copy(pixels,best.data[:len(pixels)])
    width,height=i32(best.width),i32(best.height)
    return
}
