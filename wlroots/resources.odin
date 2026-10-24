package wlroots

import wl "../wayland"

foreign import lib "system:wlroots-0.20"
foreign lib {
	wlr_seat_client_for_wl_client :: proc(seat: ^wlr_seat, client: ^wl.Client) -> ^wlr_seat_client ---
	wlr_seat_client_validate_event_serial :: proc(client: ^wlr_seat_client, serial: u32) -> bool ---
	wlr_output_from_resource :: proc(resource: ^wl.Resource) -> ^wlr_output ---
	wlr_surface_from_resource :: proc(resource: ^wl.Resource) -> ^wlr_surface ---
	wlr_seat_client_from_resource :: proc(resource: ^wl.Resource) -> ^wlr_seat_client ---
	wlr_seat_client_from_pointer_resource :: proc(resource: ^wl.Resource) -> ^wlr_seat_client ---
	wlr_buffer_try_from_resource :: proc(resource: ^wl.Resource) -> ^wlr_buffer ---
}
