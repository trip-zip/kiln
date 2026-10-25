package xcb_raw
import "core:c"
xcb_selection_notify_event_t :: struct { response_type: u8, pad0: u8, sequence: u16, time: u32, requestor: u32, selection: u32, target: u32, property: u32, }
xcb_selection_request_event_t :: struct { response_type: u8, pad0: u8, sequence: u16, time: u32, owner: u32, requestor: u32, selection: u32, target: u32, property: u32, }
xcb_xfixes_selection_notify_event_t :: struct { response_type: u8, subtype: u8, sequence: u16, window: u32, owner: u32, selection: u32, timestamp: u32, selection_timestamp: u32, pad0: [8]u8, }
xcb_get_atom_name_cookie_t :: struct { sequence: c.uint, }
xcb_get_atom_name_reply_t :: struct { response_type: u8, pad0: u8, sequence: u16, length: u32, name_len: u16, pad1: [22]u8, }
#assert(size_of(xcb_selection_notify_event_t) == 24 && align_of(xcb_selection_notify_event_t) == 4)
#assert(offset_of(xcb_selection_notify_event_t, response_type) == 0 && offset_of(xcb_selection_notify_event_t, pad0) == 1 && offset_of(xcb_selection_notify_event_t, sequence) == 2 && offset_of(xcb_selection_notify_event_t, time) == 4)
#assert(offset_of(xcb_selection_notify_event_t, requestor) == 8 && offset_of(xcb_selection_notify_event_t, selection) == 12 && offset_of(xcb_selection_notify_event_t, target) == 16 && offset_of(xcb_selection_notify_event_t, property) == 20)
#assert(size_of(xcb_selection_request_event_t) == 28 && align_of(xcb_selection_request_event_t) == 4)
#assert(offset_of(xcb_selection_request_event_t, response_type) == 0 && offset_of(xcb_selection_request_event_t, pad0) == 1 && offset_of(xcb_selection_request_event_t, sequence) == 2 && offset_of(xcb_selection_request_event_t, time) == 4)
#assert(offset_of(xcb_selection_request_event_t, owner) == 8 && offset_of(xcb_selection_request_event_t, requestor) == 12 && offset_of(xcb_selection_request_event_t, selection) == 16 && offset_of(xcb_selection_request_event_t, target) == 20)
#assert(offset_of(xcb_selection_request_event_t, property) == 24)
#assert(size_of(xcb_xfixes_selection_notify_event_t) == 32 && align_of(xcb_xfixes_selection_notify_event_t) == 4)
#assert(offset_of(xcb_xfixes_selection_notify_event_t, response_type) == 0 && offset_of(xcb_xfixes_selection_notify_event_t, subtype) == 1 && offset_of(xcb_xfixes_selection_notify_event_t, sequence) == 2 && offset_of(xcb_xfixes_selection_notify_event_t, window) == 4)
#assert(offset_of(xcb_xfixes_selection_notify_event_t, owner) == 8 && offset_of(xcb_xfixes_selection_notify_event_t, selection) == 12 && offset_of(xcb_xfixes_selection_notify_event_t, timestamp) == 16 && offset_of(xcb_xfixes_selection_notify_event_t, selection_timestamp) == 20)
#assert(offset_of(xcb_xfixes_selection_notify_event_t, pad0) == 24)
#assert(size_of(xcb_get_atom_name_cookie_t) == 4 && align_of(xcb_get_atom_name_cookie_t) == 4)
#assert(offset_of(xcb_get_atom_name_cookie_t, sequence) == 0)
#assert(size_of(xcb_get_atom_name_reply_t) == 32 && align_of(xcb_get_atom_name_reply_t) == 4)
#assert(offset_of(xcb_get_atom_name_reply_t, response_type) == 0 && offset_of(xcb_get_atom_name_reply_t, pad0) == 1 && offset_of(xcb_get_atom_name_reply_t, sequence) == 2 && offset_of(xcb_get_atom_name_reply_t, length) == 4)
#assert(offset_of(xcb_get_atom_name_reply_t, name_len) == 8 && offset_of(xcb_get_atom_name_reply_t, pad1) == 10)
foreign import lib "system:xcb"
foreign lib {
 xcb_get_atom_name :: proc(^xcb_connection_t, u32) -> xcb_get_atom_name_cookie_t ---
 xcb_get_atom_name_reply :: proc(^xcb_connection_t, xcb_get_atom_name_cookie_t, ^^xcb_generic_error_t) -> ^xcb_get_atom_name_reply_t ---
 xcb_get_atom_name_name :: proc(^xcb_get_atom_name_reply_t) -> cstring ---
 xcb_get_atom_name_name_length :: proc(^xcb_get_atom_name_reply_t) -> c.int ---
 xcb_convert_selection :: proc(^xcb_connection_t, u32, u32, u32, u32, u32) -> xcb_void_cookie_t ---
 xcb_delete_property :: proc(^xcb_connection_t, u32, u32) -> xcb_void_cookie_t ---
 xcb_destroy_window :: proc(^xcb_connection_t, u32) -> xcb_void_cookie_t ---
 xcb_get_maximum_request_length :: proc(^xcb_connection_t) -> u32 ---
}
foreign import xfixes "system:xcb-xfixes"
foreign xfixes { xcb_xfixes_select_selection_input :: proc(^xcb_connection_t, u32, u32, u32) -> xcb_void_cookie_t --- }
foreign lib { xcb_connect :: proc(cstring, ^c.int) -> ^xcb_connection_t --- }
