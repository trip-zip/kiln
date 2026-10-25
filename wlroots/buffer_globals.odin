package wlroots

import wl "../wayland"
import "core:sys/posix"

wlr_linux_dmabuf_feedback_v1 :: struct { main_device: posix.dev_t, tranches: wl.Array }
wlr_linux_dmabuf_feedback_v1_tranche :: struct { target_device: posix.dev_t, flags: u32, formats: wlr_drm_format_set }
#assert(size_of(wlr_linux_dmabuf_feedback_v1) == 32 && align_of(wlr_linux_dmabuf_feedback_v1) == 8 && offset_of(wlr_linux_dmabuf_feedback_v1, main_device) == 0 && offset_of(wlr_linux_dmabuf_feedback_v1, tranches) == 8)
#assert(size_of(wlr_linux_dmabuf_feedback_v1_tranche) == 40 && align_of(wlr_linux_dmabuf_feedback_v1_tranche) == 8 && offset_of(wlr_linux_dmabuf_feedback_v1_tranche, target_device) == 0)
#assert(offset_of(wlr_linux_dmabuf_feedback_v1_tranche, flags) == 8 && offset_of(wlr_linux_dmabuf_feedback_v1_tranche, formats) == 16)
wlr_shm :: struct {}
wlr_linux_dmabuf_v1 :: struct {}
foreign import lib "system:wlroots-0.20"
foreign lib {
	wlr_shm_create :: proc(display: ^wl.Display, version: u32, formats: [^]u32, len: uint) -> ^wlr_shm ---
	wlr_linux_dmabuf_v1_create :: proc(display: ^wl.Display, version: u32, feedback: ^wlr_linux_dmabuf_feedback_v1) -> ^wlr_linux_dmabuf_v1 ---
}
