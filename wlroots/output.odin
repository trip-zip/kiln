package wlroots

import "core:math"

wlr_output_event_present :: struct #align (8) {
	_opaque_0:  [8]u8,
	commit_seq: u32,
	presented:  bool,
	_opaque_13: [35]u8,
}
foreign import output_lib "system:wlroots-0.20"
foreign output_lib {
	wlr_output_is_x11 :: proc(output: ^wlr_output) -> bool ---
	wlr_output_effective_resolution :: proc(output: ^wlr_output, width, height: ^i32) ---
	wlr_output_transformed_resolution :: proc(output: ^wlr_output, width, height: ^i32) ---
}
#assert(size_of(wlr_output_event_present) == 48 && align_of(wlr_output_event_present) == 8)
#assert(
	offset_of(wlr_output_event_present, commit_seq) == 8 &&
	offset_of(wlr_output_event_present, presented) == 12,
)

output_logical_size :: proc(
	output: ^wlr_output,
) -> (
	width, height: i32,
) {wlr_output_effective_resolution(output, &width, &height); return}

output_cover_size :: proc(output: ^wlr_output) -> (width, height: i32) {
	wlr_output_transformed_resolution(output, &width, &height)
	// Effective layout dimensions truncate; opaque coverage must include edge pixels.
	return i32(
		math.ceil(f64(width) / f64(output.scale)),
	), i32(math.ceil(f64(height) / f64(output.scale)))
}

lock_next_sequence :: proc(output: ^wlr_output) -> u32 {
	// X11 submits its Present serial before the common commit counter advances.
	if wlr_output_is_x11(output) {return output.commit_seq}
	return output.commit_seq + 1
}
