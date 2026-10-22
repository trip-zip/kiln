package xcb_raw

import "core:c"
xcb_connection_t :: struct {}
xcb_void_cookie_t :: struct { sequence: c.uint }
foreign import lib "system:xcb"
foreign lib {
    xcb_kill_client :: proc(connection: ^xcb_connection_t, resource: u32) -> xcb_void_cookie_t ---
    xcb_flush :: proc(connection: ^xcb_connection_t) -> c.int ---
    xcb_connection_has_error :: proc(connection: ^xcb_connection_t) -> c.int ---
}
#assert(size_of(xcb_void_cookie_t)==4 && align_of(xcb_void_cookie_t)==4)
#assert(offset_of(xcb_void_cookie_t,sequence)==0)

xcb_get_property_cookie_t :: struct { sequence: c.uint }
xcb_intern_atom_cookie_t :: struct { sequence: c.uint }
xcb_generic_error_t :: struct {}
xcb_get_property_reply_t :: struct {
    response_type, format: u8,
    sequence: u16,
    length, type, bytes_after, value_len: u32,
    pad0: [12]u8,
}
xcb_intern_atom_reply_t :: struct {
    response_type, pad0: u8,
    sequence: u16,
    length, atom: u32,
}
foreign lib {
    xcb_intern_atom :: proc(c: ^xcb_connection_t, only_if_exists: u8, name_len: u16, name: cstring) -> xcb_intern_atom_cookie_t ---
    xcb_intern_atom_reply :: proc(c: ^xcb_connection_t, cookie: xcb_intern_atom_cookie_t, error: ^^xcb_generic_error_t) -> ^xcb_intern_atom_reply_t ---
    xcb_get_property :: proc(c: ^xcb_connection_t, delete: u8, window, property, type, long_offset, long_length: u32) -> xcb_get_property_cookie_t ---
    xcb_get_property_reply :: proc(c: ^xcb_connection_t, cookie: xcb_get_property_cookie_t, error: ^^xcb_generic_error_t) -> ^xcb_get_property_reply_t ---
    xcb_get_property_value :: proc(reply: ^xcb_get_property_reply_t) -> rawptr ---
    xcb_get_property_value_length :: proc(reply: ^xcb_get_property_reply_t) -> c.int ---
}
#assert(size_of(xcb_get_property_cookie_t)==4 && align_of(xcb_get_property_cookie_t)==4 && offset_of(xcb_get_property_cookie_t,sequence)==0)
#assert(size_of(xcb_intern_atom_cookie_t)==4 && align_of(xcb_intern_atom_cookie_t)==4 && offset_of(xcb_intern_atom_cookie_t,sequence)==0)
#assert(size_of(xcb_get_property_reply_t)==32 && align_of(xcb_get_property_reply_t)==4)
#assert(offset_of(xcb_get_property_reply_t,response_type)==0 && offset_of(xcb_get_property_reply_t,sequence)==2 && offset_of(xcb_get_property_reply_t,pad0)==20)
#assert(offset_of(xcb_get_property_reply_t,format)==1 && offset_of(xcb_get_property_reply_t,length)==4)
#assert(offset_of(xcb_get_property_reply_t,type)==8 && offset_of(xcb_get_property_reply_t,bytes_after)==12 && offset_of(xcb_get_property_reply_t,value_len)==16)
#assert(size_of(xcb_intern_atom_reply_t)==12 && align_of(xcb_intern_atom_reply_t)==4 && offset_of(xcb_intern_atom_reply_t,atom)==8)
#assert(offset_of(xcb_intern_atom_reply_t,response_type)==0 && offset_of(xcb_intern_atom_reply_t,pad0)==1 && offset_of(xcb_intern_atom_reply_t,sequence)==2 && offset_of(xcb_intern_atom_reply_t,length)==4)
