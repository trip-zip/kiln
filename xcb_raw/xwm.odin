package xcb_raw
import "core:c"
xcb_screen_t :: struct { root: u32, default_colormap: u32, white_pixel: u32, black_pixel: u32, current_input_masks: u32, width_in_pixels: u16, height_in_pixels: u16, width_in_millimeters: u16, height_in_millimeters: u16, min_installed_maps: u16, max_installed_maps: u16, root_visual: u32, backing_stores: u8, save_unders: u8, root_depth: u8, allowed_depths_len: u8, }
xcb_screen_iterator_t :: struct { data: ^xcb_screen_t, rem: c.int, index: c.int, }
xcb_generic_event_t :: struct { response_type: u8, pad0: u8, sequence: u16, pad: [7]u32, full_sequence: u32, }
xcb_generic_error_t :: struct { response_type: u8, error_code: u8, sequence: u16, resource_id: u32, minor_code: u16, major_code: u8, pad0: u8, pad: [5]u32, full_sequence: u32, }
xcb_create_notify_event_t :: struct { response_type: u8, pad0: u8, sequence: u16, parent: u32, window: u32, x: i16, y: i16, width: u16, height: u16, border_width: u16, override_redirect: u8, pad1: u8, }
xcb_destroy_notify_event_t :: struct { response_type: u8, pad0: u8, sequence: u16, event: u32, window: u32, }
xcb_unmap_notify_event_t :: struct { response_type: u8, pad0: u8, sequence: u16, event: u32, window: u32, from_configure: u8, pad1: [3]u8, }
xcb_map_notify_event_t :: struct { response_type: u8, pad0: u8, sequence: u16, event: u32, window: u32, override_redirect: u8, pad1: [3]u8, }
xcb_map_request_event_t :: struct { response_type: u8, pad0: u8, sequence: u16, parent: u32, window: u32, }
xcb_configure_notify_event_t :: struct { response_type: u8, pad0: u8, sequence: u16, event: u32, window: u32, above_sibling: u32, x: i16, y: i16, width: u16, height: u16, border_width: u16, override_redirect: u8, pad1: u8, }
xcb_configure_request_event_t :: struct { response_type: u8, stack_mode: u8, sequence: u16, parent: u32, window: u32, sibling: u32, x: i16, y: i16, width: u16, height: u16, border_width: u16, value_mask: u16, }
xcb_property_notify_event_t :: struct { response_type: u8, pad0: u8, sequence: u16, window: u32, atom: u32, time: u32, state: u8, pad1: [3]u8, }
xcb_client_message_data_t :: struct #raw_union { data8: [20]u8, data16: [10]u16, data32: [5]u32, }
xcb_client_message_event_t :: struct { response_type: u8, format: u8, sequence: u16, window: u32, type: u32, data: xcb_client_message_data_t, }
xcb_focus_in_event_t :: struct { response_type: u8, detail: u8, sequence: u16, event: u32, mode: u8, pad0: [3]u8, }
xcb_query_extension_reply_t :: struct { response_type: u8, pad0: u8, sequence: u16, length: u32, present: u8, major_opcode: u8, first_event: u8, first_error: u8, }
xcb_res_client_id_spec_t :: struct { client: u32, mask: u32, }
xcb_res_client_id_value_t :: struct { spec: xcb_res_client_id_spec_t, length: u32, }
xcb_res_client_id_value_iterator_t :: struct { data: ^xcb_res_client_id_value_t, rem: c.int, index: c.int, }
xcb_res_query_client_ids_cookie_t :: struct { sequence: c.uint, }
xcb_res_query_client_ids_reply_t :: struct { response_type: u8, pad0: u8, sequence: u16, length: u32, num_ids: u32, pad1: [20]u8, }
xcb_xfixes_query_version_cookie_t :: struct { sequence: c.uint, }
xcb_xfixes_query_version_reply_t :: struct { response_type: u8, pad0: u8, sequence: u16, length: u32, major_version: u32, minor_version: u32, pad1: [16]u8, }
xcb_composite_query_version_cookie_t :: struct { sequence: c.uint, }
xcb_composite_query_version_reply_t :: struct { response_type: u8, pad0: u8, sequence: u16, length: u32, major_version: u32, minor_version: u32, pad1: [16]u8, }
xcb_res_query_version_cookie_t :: struct { sequence: c.uint, }
xcb_res_query_version_reply_t :: struct { response_type: u8, pad0: u8, sequence: u16, length: u32, server_major: u16, server_minor: u16, }
#assert(size_of(xcb_screen_t) == 40 && align_of(xcb_screen_t) == 4)
#assert(offset_of(xcb_screen_t, root) == 0 && offset_of(xcb_screen_t, default_colormap) == 4 && offset_of(xcb_screen_t, white_pixel) == 8 && offset_of(xcb_screen_t, black_pixel) == 12)
#assert(offset_of(xcb_screen_t, current_input_masks) == 16 && offset_of(xcb_screen_t, width_in_pixels) == 20 && offset_of(xcb_screen_t, height_in_pixels) == 22 && offset_of(xcb_screen_t, width_in_millimeters) == 24)
#assert(offset_of(xcb_screen_t, height_in_millimeters) == 26 && offset_of(xcb_screen_t, min_installed_maps) == 28 && offset_of(xcb_screen_t, max_installed_maps) == 30 && offset_of(xcb_screen_t, root_visual) == 32)
#assert(offset_of(xcb_screen_t, backing_stores) == 36 && offset_of(xcb_screen_t, save_unders) == 37 && offset_of(xcb_screen_t, root_depth) == 38 && offset_of(xcb_screen_t, allowed_depths_len) == 39)
#assert(size_of(xcb_screen_iterator_t) == 16 && align_of(xcb_screen_iterator_t) == 8)
#assert(offset_of(xcb_screen_iterator_t, data) == 0 && offset_of(xcb_screen_iterator_t, rem) == 8 && offset_of(xcb_screen_iterator_t, index) == 12)
#assert(size_of(xcb_generic_event_t) == 36 && align_of(xcb_generic_event_t) == 4)
#assert(offset_of(xcb_generic_event_t, response_type) == 0 && offset_of(xcb_generic_event_t, pad0) == 1 && offset_of(xcb_generic_event_t, sequence) == 2 && offset_of(xcb_generic_event_t, pad) == 4)
#assert(offset_of(xcb_generic_event_t, full_sequence) == 32)
#assert(size_of(xcb_generic_error_t) == 36 && align_of(xcb_generic_error_t) == 4)
#assert(offset_of(xcb_generic_error_t, response_type) == 0 && offset_of(xcb_generic_error_t, error_code) == 1 && offset_of(xcb_generic_error_t, sequence) == 2 && offset_of(xcb_generic_error_t, resource_id) == 4)
#assert(offset_of(xcb_generic_error_t, minor_code) == 8 && offset_of(xcb_generic_error_t, major_code) == 10 && offset_of(xcb_generic_error_t, pad0) == 11 && offset_of(xcb_generic_error_t, pad) == 12)
#assert(offset_of(xcb_generic_error_t, full_sequence) == 32)
#assert(size_of(xcb_create_notify_event_t) == 24 && align_of(xcb_create_notify_event_t) == 4)
#assert(offset_of(xcb_create_notify_event_t, response_type) == 0 && offset_of(xcb_create_notify_event_t, pad0) == 1 && offset_of(xcb_create_notify_event_t, sequence) == 2 && offset_of(xcb_create_notify_event_t, parent) == 4)
#assert(offset_of(xcb_create_notify_event_t, window) == 8 && offset_of(xcb_create_notify_event_t, x) == 12 && offset_of(xcb_create_notify_event_t, y) == 14 && offset_of(xcb_create_notify_event_t, width) == 16)
#assert(offset_of(xcb_create_notify_event_t, height) == 18 && offset_of(xcb_create_notify_event_t, border_width) == 20 && offset_of(xcb_create_notify_event_t, override_redirect) == 22 && offset_of(xcb_create_notify_event_t, pad1) == 23)
#assert(size_of(xcb_destroy_notify_event_t) == 12 && align_of(xcb_destroy_notify_event_t) == 4)
#assert(offset_of(xcb_destroy_notify_event_t, response_type) == 0 && offset_of(xcb_destroy_notify_event_t, pad0) == 1 && offset_of(xcb_destroy_notify_event_t, sequence) == 2 && offset_of(xcb_destroy_notify_event_t, event) == 4)
#assert(offset_of(xcb_destroy_notify_event_t, window) == 8)
#assert(size_of(xcb_unmap_notify_event_t) == 16 && align_of(xcb_unmap_notify_event_t) == 4)
#assert(offset_of(xcb_unmap_notify_event_t, response_type) == 0 && offset_of(xcb_unmap_notify_event_t, pad0) == 1 && offset_of(xcb_unmap_notify_event_t, sequence) == 2 && offset_of(xcb_unmap_notify_event_t, event) == 4)
#assert(offset_of(xcb_unmap_notify_event_t, window) == 8 && offset_of(xcb_unmap_notify_event_t, from_configure) == 12 && offset_of(xcb_unmap_notify_event_t, pad1) == 13)
#assert(size_of(xcb_map_notify_event_t) == 16 && align_of(xcb_map_notify_event_t) == 4)
#assert(offset_of(xcb_map_notify_event_t, response_type) == 0 && offset_of(xcb_map_notify_event_t, pad0) == 1 && offset_of(xcb_map_notify_event_t, sequence) == 2 && offset_of(xcb_map_notify_event_t, event) == 4)
#assert(offset_of(xcb_map_notify_event_t, window) == 8 && offset_of(xcb_map_notify_event_t, override_redirect) == 12 && offset_of(xcb_map_notify_event_t, pad1) == 13)
#assert(size_of(xcb_map_request_event_t) == 12 && align_of(xcb_map_request_event_t) == 4)
#assert(offset_of(xcb_map_request_event_t, response_type) == 0 && offset_of(xcb_map_request_event_t, pad0) == 1 && offset_of(xcb_map_request_event_t, sequence) == 2 && offset_of(xcb_map_request_event_t, parent) == 4)
#assert(offset_of(xcb_map_request_event_t, window) == 8)
#assert(size_of(xcb_configure_notify_event_t) == 28 && align_of(xcb_configure_notify_event_t) == 4)
#assert(offset_of(xcb_configure_notify_event_t, response_type) == 0 && offset_of(xcb_configure_notify_event_t, pad0) == 1 && offset_of(xcb_configure_notify_event_t, sequence) == 2 && offset_of(xcb_configure_notify_event_t, event) == 4)
#assert(offset_of(xcb_configure_notify_event_t, window) == 8 && offset_of(xcb_configure_notify_event_t, above_sibling) == 12 && offset_of(xcb_configure_notify_event_t, x) == 16 && offset_of(xcb_configure_notify_event_t, y) == 18)
#assert(offset_of(xcb_configure_notify_event_t, width) == 20 && offset_of(xcb_configure_notify_event_t, height) == 22 && offset_of(xcb_configure_notify_event_t, border_width) == 24 && offset_of(xcb_configure_notify_event_t, override_redirect) == 26)
#assert(offset_of(xcb_configure_notify_event_t, pad1) == 27)
#assert(size_of(xcb_configure_request_event_t) == 28 && align_of(xcb_configure_request_event_t) == 4)
#assert(offset_of(xcb_configure_request_event_t, response_type) == 0 && offset_of(xcb_configure_request_event_t, stack_mode) == 1 && offset_of(xcb_configure_request_event_t, sequence) == 2 && offset_of(xcb_configure_request_event_t, parent) == 4)
#assert(offset_of(xcb_configure_request_event_t, window) == 8 && offset_of(xcb_configure_request_event_t, sibling) == 12 && offset_of(xcb_configure_request_event_t, x) == 16 && offset_of(xcb_configure_request_event_t, y) == 18)
#assert(offset_of(xcb_configure_request_event_t, width) == 20 && offset_of(xcb_configure_request_event_t, height) == 22 && offset_of(xcb_configure_request_event_t, border_width) == 24 && offset_of(xcb_configure_request_event_t, value_mask) == 26)
#assert(size_of(xcb_property_notify_event_t) == 20 && align_of(xcb_property_notify_event_t) == 4)
#assert(offset_of(xcb_property_notify_event_t, response_type) == 0 && offset_of(xcb_property_notify_event_t, pad0) == 1 && offset_of(xcb_property_notify_event_t, sequence) == 2 && offset_of(xcb_property_notify_event_t, window) == 4)
#assert(offset_of(xcb_property_notify_event_t, atom) == 8 && offset_of(xcb_property_notify_event_t, time) == 12 && offset_of(xcb_property_notify_event_t, state) == 16 && offset_of(xcb_property_notify_event_t, pad1) == 17)
#assert(size_of(xcb_client_message_data_t) == 20 && align_of(xcb_client_message_data_t) == 4)
#assert(offset_of(xcb_client_message_data_t, data8) == 0 && offset_of(xcb_client_message_data_t, data16) == 0 && offset_of(xcb_client_message_data_t, data32) == 0)
#assert(size_of(xcb_client_message_event_t) == 32 && align_of(xcb_client_message_event_t) == 4)
#assert(offset_of(xcb_client_message_event_t, response_type) == 0 && offset_of(xcb_client_message_event_t, format) == 1 && offset_of(xcb_client_message_event_t, sequence) == 2 && offset_of(xcb_client_message_event_t, window) == 4)
#assert(offset_of(xcb_client_message_event_t, type) == 8 && offset_of(xcb_client_message_event_t, data) == 12)
#assert(size_of(xcb_focus_in_event_t) == 12 && align_of(xcb_focus_in_event_t) == 4)
#assert(offset_of(xcb_focus_in_event_t, response_type) == 0 && offset_of(xcb_focus_in_event_t, detail) == 1 && offset_of(xcb_focus_in_event_t, sequence) == 2 && offset_of(xcb_focus_in_event_t, event) == 4)
#assert(offset_of(xcb_focus_in_event_t, mode) == 8 && offset_of(xcb_focus_in_event_t, pad0) == 9)
#assert(size_of(xcb_query_extension_reply_t) == 12 && align_of(xcb_query_extension_reply_t) == 4)
#assert(offset_of(xcb_query_extension_reply_t, response_type) == 0 && offset_of(xcb_query_extension_reply_t, pad0) == 1 && offset_of(xcb_query_extension_reply_t, sequence) == 2 && offset_of(xcb_query_extension_reply_t, length) == 4)
#assert(offset_of(xcb_query_extension_reply_t, present) == 8 && offset_of(xcb_query_extension_reply_t, major_opcode) == 9 && offset_of(xcb_query_extension_reply_t, first_event) == 10 && offset_of(xcb_query_extension_reply_t, first_error) == 11)
#assert(size_of(xcb_res_client_id_spec_t) == 8 && align_of(xcb_res_client_id_spec_t) == 4)
#assert(offset_of(xcb_res_client_id_spec_t, client) == 0 && offset_of(xcb_res_client_id_spec_t, mask) == 4)
#assert(size_of(xcb_res_client_id_value_t) == 12 && align_of(xcb_res_client_id_value_t) == 4)
#assert(offset_of(xcb_res_client_id_value_t, spec) == 0 && offset_of(xcb_res_client_id_value_t, length) == 8)
#assert(size_of(xcb_res_client_id_value_iterator_t) == 16 && align_of(xcb_res_client_id_value_iterator_t) == 8)
#assert(offset_of(xcb_res_client_id_value_iterator_t, data) == 0 && offset_of(xcb_res_client_id_value_iterator_t, rem) == 8 && offset_of(xcb_res_client_id_value_iterator_t, index) == 12)
#assert(size_of(xcb_res_query_client_ids_cookie_t) == 4 && align_of(xcb_res_query_client_ids_cookie_t) == 4)
#assert(offset_of(xcb_res_query_client_ids_cookie_t, sequence) == 0)
#assert(size_of(xcb_res_query_client_ids_reply_t) == 32 && align_of(xcb_res_query_client_ids_reply_t) == 4)
#assert(offset_of(xcb_res_query_client_ids_reply_t, response_type) == 0 && offset_of(xcb_res_query_client_ids_reply_t, pad0) == 1 && offset_of(xcb_res_query_client_ids_reply_t, sequence) == 2 && offset_of(xcb_res_query_client_ids_reply_t, length) == 4)
#assert(offset_of(xcb_res_query_client_ids_reply_t, num_ids) == 8 && offset_of(xcb_res_query_client_ids_reply_t, pad1) == 12)
#assert(size_of(xcb_xfixes_query_version_cookie_t) == 4 && align_of(xcb_xfixes_query_version_cookie_t) == 4)
#assert(offset_of(xcb_xfixes_query_version_cookie_t, sequence) == 0)
#assert(size_of(xcb_xfixes_query_version_reply_t) == 32 && align_of(xcb_xfixes_query_version_reply_t) == 4)
#assert(offset_of(xcb_xfixes_query_version_reply_t, response_type) == 0 && offset_of(xcb_xfixes_query_version_reply_t, pad0) == 1 && offset_of(xcb_xfixes_query_version_reply_t, sequence) == 2 && offset_of(xcb_xfixes_query_version_reply_t, length) == 4)
#assert(offset_of(xcb_xfixes_query_version_reply_t, major_version) == 8 && offset_of(xcb_xfixes_query_version_reply_t, minor_version) == 12 && offset_of(xcb_xfixes_query_version_reply_t, pad1) == 16)
#assert(size_of(xcb_composite_query_version_cookie_t) == 4 && align_of(xcb_composite_query_version_cookie_t) == 4)
#assert(offset_of(xcb_composite_query_version_cookie_t, sequence) == 0)
#assert(size_of(xcb_composite_query_version_reply_t) == 32 && align_of(xcb_composite_query_version_reply_t) == 4)
#assert(offset_of(xcb_composite_query_version_reply_t, response_type) == 0 && offset_of(xcb_composite_query_version_reply_t, pad0) == 1 && offset_of(xcb_composite_query_version_reply_t, sequence) == 2 && offset_of(xcb_composite_query_version_reply_t, length) == 4)
#assert(offset_of(xcb_composite_query_version_reply_t, major_version) == 8 && offset_of(xcb_composite_query_version_reply_t, minor_version) == 12 && offset_of(xcb_composite_query_version_reply_t, pad1) == 16)
#assert(size_of(xcb_res_query_version_cookie_t) == 4 && align_of(xcb_res_query_version_cookie_t) == 4)
#assert(offset_of(xcb_res_query_version_cookie_t, sequence) == 0)
#assert(size_of(xcb_res_query_version_reply_t) == 12 && align_of(xcb_res_query_version_reply_t) == 4)
#assert(offset_of(xcb_res_query_version_reply_t, response_type) == 0 && offset_of(xcb_res_query_version_reply_t, pad0) == 1 && offset_of(xcb_res_query_version_reply_t, sequence) == 2 && offset_of(xcb_res_query_version_reply_t, length) == 4)
#assert(offset_of(xcb_res_query_version_reply_t, server_major) == 8 && offset_of(xcb_res_query_version_reply_t, server_minor) == 10)
xcb_setup_t :: struct {}
xcb_auth_info_t :: struct {}
xcb_extension_t :: struct {}
foreign import xwm_lib "system:xcb"
foreign xwm_lib {
	xcb_connect_to_fd :: proc(c.int, ^xcb_auth_info_t) -> ^xcb_connection_t ---
	xcb_disconnect :: proc(^xcb_connection_t) ---
	xcb_get_file_descriptor :: proc(^xcb_connection_t) -> c.int ---
	xcb_get_setup :: proc(^xcb_connection_t) -> ^xcb_setup_t ---
	xcb_setup_roots_iterator :: proc(^xcb_setup_t) -> xcb_screen_iterator_t ---
	xcb_generate_id :: proc(^xcb_connection_t) -> u32 ---
	xcb_poll_for_event :: proc(^xcb_connection_t) -> ^xcb_generic_event_t ---
	xcb_discard_reply :: proc(^xcb_connection_t, c.uint) ---
	xcb_poll_for_reply :: proc(^xcb_connection_t, c.uint, ^rawptr, ^^xcb_generic_error_t) -> c.int ---
	xcb_change_window_attributes :: proc(^xcb_connection_t, u32, u32, rawptr) -> xcb_void_cookie_t ---
	xcb_create_window :: proc(^xcb_connection_t, u8, u32, u32, i16, i16, u16, u16, u16, u16, u32, u32, rawptr) -> xcb_void_cookie_t ---
	xcb_map_window :: proc(^xcb_connection_t, u32) -> xcb_void_cookie_t ---
	xcb_configure_window :: proc(^xcb_connection_t, u32, u16, rawptr) -> xcb_void_cookie_t ---
	xcb_change_property :: proc(^xcb_connection_t, u8, u32, u32, u32, u8, u32, rawptr) -> xcb_void_cookie_t ---
	xcb_set_selection_owner :: proc(^xcb_connection_t, u32, u32, u32) -> xcb_void_cookie_t ---
	xcb_send_event :: proc(^xcb_connection_t, u8, u32, u32, cstring) -> xcb_void_cookie_t ---
	xcb_set_input_focus :: proc(^xcb_connection_t, u8, u32, u32) -> xcb_void_cookie_t ---
	xcb_set_input_focus_checked :: proc(^xcb_connection_t, u8, u32, u32) -> xcb_void_cookie_t ---
	xcb_prefetch_extension_data :: proc(^xcb_connection_t, ^xcb_extension_t) ---
	xcb_get_extension_data :: proc(^xcb_connection_t, ^xcb_extension_t) -> ^xcb_query_extension_reply_t ---
}
foreign import composite "system:xcb-composite"
foreign composite {
	xcb_composite_id: xcb_extension_t
	xcb_composite_query_version :: proc(^xcb_connection_t, u32, u32) -> xcb_composite_query_version_cookie_t ---
	xcb_composite_query_version_reply :: proc(^xcb_connection_t, xcb_composite_query_version_cookie_t, ^^xcb_generic_error_t) -> ^xcb_composite_query_version_reply_t ---
	xcb_composite_redirect_subwindows :: proc(^xcb_connection_t, u32, u8) -> xcb_void_cookie_t ---
}
foreign import xfixes "system:xcb-xfixes"
foreign xfixes {
	xcb_xfixes_id: xcb_extension_t
	xcb_xfixes_query_version :: proc(^xcb_connection_t, u32, u32) -> xcb_xfixes_query_version_cookie_t ---
	xcb_xfixes_query_version_reply :: proc(^xcb_connection_t, xcb_xfixes_query_version_cookie_t, ^^xcb_generic_error_t) -> ^xcb_xfixes_query_version_reply_t ---
	xcb_xfixes_set_client_disconnect_mode :: proc(^xcb_connection_t, u32) -> xcb_void_cookie_t ---
}
foreign import res "system:xcb-res"
foreign res {
	xcb_res_id: xcb_extension_t
	xcb_res_query_version :: proc(^xcb_connection_t, u8, u8) -> xcb_res_query_version_cookie_t ---
	xcb_res_query_version_reply :: proc(^xcb_connection_t, xcb_res_query_version_cookie_t, ^^xcb_generic_error_t) -> ^xcb_res_query_version_reply_t ---
	xcb_res_query_client_ids :: proc(^xcb_connection_t, u32, ^xcb_res_client_id_spec_t) -> xcb_res_query_client_ids_cookie_t ---
	xcb_res_query_client_ids_ids_iterator :: proc(^xcb_res_query_client_ids_reply_t) -> xcb_res_client_id_value_iterator_t ---
	xcb_res_client_id_value_value :: proc(^xcb_res_client_id_value_t) -> [^]u32 ---
	xcb_res_client_id_value_value_length :: proc(^xcb_res_client_id_value_t) -> c.int ---
	xcb_res_client_id_value_next :: proc(^xcb_res_client_id_value_iterator_t) ---
}
