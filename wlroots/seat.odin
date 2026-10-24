package wlroots

foreign import seat_lib "system:wlroots-0.20"
foreign seat_lib {
	wlr_seat_keyboard_end_grab :: proc(seat: ^wlr_seat) ---
	wlr_seat_pointer_end_grab :: proc(seat: ^wlr_seat) ---
}
seat_end_grabs :: proc(seat: ^wlr_seat) {
	wlr_seat_keyboard_end_grab(seat)
	wlr_seat_pointer_end_grab(seat)
}
