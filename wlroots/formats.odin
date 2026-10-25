package wlroots
import "core:c"

wlr_drm_format :: struct {
	format:        u32,
	len, capacity: c.size_t,
	modifiers:     [^]u64,
}
wlr_drm_format_set :: struct {
	len, capacity: c.size_t,
	formats:       [^]wlr_drm_format,
}
#assert(offset_of(wlr_drm_format, format) == 0 && offset_of(wlr_drm_format, capacity) == 16 && offset_of(wlr_drm_format_set, len) == 0 && offset_of(wlr_drm_format_set, capacity) == 8)
#assert(size_of(wlr_drm_format) == 32 && align_of(wlr_drm_format) == 8 && offset_of(wlr_drm_format, len) == 8 && offset_of(wlr_drm_format, modifiers) == 24)
#assert(size_of(wlr_drm_format_set) == 24 && align_of(wlr_drm_format_set) == 8 && offset_of(wlr_drm_format_set, formats) == 16)
foreign import lib "system:wlroots-0.20"
foreign lib {
	wlr_output_get_primary_formats :: proc(output: ^wlr_output, caps: u32) -> ^wlr_drm_format_set ---
	wlr_backend_get_drm_fd :: proc(backend: ^wlr_backend) -> c.int ---
}
primary_formats :: wlr_output_get_primary_formats
backend_fd :: wlr_backend_get_drm_fd
