package xcb

import raw "../xcb_raw"
import "core:strings"

Selection_Notify :: raw.xcb_selection_notify_event_t
Selection_Request :: raw.xcb_selection_request_event_t
Selection_Owner :: raw.xcb_xfixes_selection_notify_event_t
selection_events :: proc(c: ^Connection) -> u8 {
 e := raw.xcb_get_extension_data(c, &raw.xcb_xfixes_id)
 return e.first_event if e != nil && e.present != 0 else 0
}
watch_selection :: proc(c: ^Connection, window, atom: u32) { raw.xcb_xfixes_select_selection_input(c, window, atom, 7) }
convert_selection :: proc(c: ^Connection, window, selection, target, property, time: u32) { raw.xcb_convert_selection(c, window, selection, target, property, time) }
delete_property :: proc(c: ^Connection, window, atom: u32) { raw.xcb_delete_property(c, window, atom) }
destroy_window :: proc(c: ^Connection, window: u32) { raw.xcb_destroy_window(c, window) }
selection_window :: proc(c: ^Connection, root: u32, dnd := false) -> u32 {
 id := raw.xcb_generate_id(c); mask: u32 = (1<<19)|(1<<22)
 size: u16 = 8192 if dnd else 10
 raw.xcb_create_window(c, 0, id, root, 0, 0, size, size, 0, 2 if dnd else 1, 0, 1<<11, &mask); return id
}
atom_name :: proc(c: ^Connection, atom: u32) -> string {
 r := raw.xcb_get_atom_name_reply(c, raw.xcb_get_atom_name(c, atom), nil)
 if r == nil { return "" }; defer release(r)
 return strings.clone(string((cast([^]u8)raw.xcb_get_atom_name_name(r))[:raw.xcb_get_atom_name_name_length(r)]))
}
selection_chunk_size :: proc(c: ^Connection) -> int { return int(min(u32(65536), (raw.xcb_get_maximum_request_length(c)-64)*4)) }
connect_display :: proc(display: string) -> ^Connection {
 name := strings.clone_to_cstring(display, context.temp_allocator); c := raw.xcb_connect(name, nil)
 if failed(c) { disconnect(c); return nil }; return c
}
