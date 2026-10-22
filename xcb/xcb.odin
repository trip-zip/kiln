package xcb

import "core:c/libc"
import "core:strings"
import raw "../xcb_raw"
// XKillClient targets the owning connection, including its other windows.
kill_client :: proc(connection: ^raw.xcb_connection_t, window: u32) -> bool {
    if connection==nil || window==0 || raw.xcb_connection_has_error(connection)!=0 { return false }
    raw.xcb_kill_client(connection,window)
    return raw.xcb_flush(connection)>0
}

// Replies belong to XCB's allocator, independent of the compositor callback context.
release :: proc(reply: rawptr) { libc.free(reply) }
intern :: proc(connection: ^raw.xcb_connection_t, name: string) -> u32 {
    if connection==nil || len(name)>65535 { return 0 }
    reply:=raw.xcb_intern_atom_reply(connection,raw.xcb_intern_atom(connection,0,u16(len(name)),cstring(raw_data(name))),nil)
    if reply==nil { return 0 }
    defer release(reply)
    return reply.atom
}
property :: proc(connection: ^raw.xcb_connection_t, window, atom, words: u32, kind: u32=0) -> ^raw.xcb_get_property_reply_t {
    if connection==nil || atom==0 { return nil }
    return raw.xcb_get_property_reply(connection,raw.xcb_get_property(connection,0,window,atom,kind,0,words),nil)
}
property_bytes :: proc(reply: ^raw.xcb_get_property_reply_t) -> []u8 {
    if reply==nil { return nil }
    return ([^]u8)(raw.xcb_get_property_value(reply))[:raw.xcb_get_property_value_length(reply)]
}
role :: proc(connection: ^raw.xcb_connection_t, window, atom: u32) -> string {
    reply:=property(connection,window,atom,128)
    if reply==nil { return "" }
    defer release(reply)
    data:=property_bytes(reply)
    for ch,i in data { if ch==0 { data=data[:i];break } }
    return strings.clone(string(data))
}
