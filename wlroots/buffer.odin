package wlroots

import "core:c"
import wl "../wayland"
foreign import lib "system:wlroots-0.20"

WLR_BUFFER_CAP_DMABUF :: u32(1 << 1)

wlr_buffer :: struct #align(8) {
	_opaque_0: [8]u8,
	width, height: c.int,
	dropped: bool,
	_opaque_17: [23]u8,
	events: struct { destroy, release: wl.Signal },
	_opaque72: [16]u8,
}
wlr_dmabuf_attributes :: struct {
	width, height:  i32,
	format:         u32,
	modifier:       u64,
	n_planes:       c.int,
	offset, stride: [4]u32,
	fd:             [4]c.int,
}
#assert(offset_of(wlr_dmabuf_attributes, width) == 0 && offset_of(wlr_dmabuf_attributes, height) == 4 && offset_of(wlr_dmabuf_attributes, format) == 8 && size_of(wlr_dmabuf_attributes) == 80 && align_of(wlr_dmabuf_attributes) == 8)
#assert(offset_of(wlr_dmabuf_attributes, modifier) == 16 && offset_of(wlr_dmabuf_attributes, n_planes) == 24)
#assert(offset_of(wlr_dmabuf_attributes, offset) == 28 && offset_of(wlr_dmabuf_attributes, stride) == 44 && offset_of(wlr_dmabuf_attributes, fd) == 60)
wlr_buffer_impl :: struct {
	destroy: proc "c" (buffer: ^wlr_buffer),
	get_dmabuf: proc "c" (buffer: ^wlr_buffer, attribs: ^wlr_dmabuf_attributes) -> bool,
	_opaque_16: [8]u8,
	begin_data_ptr_access: proc "c" (buffer: ^wlr_buffer, flags: u32, data: ^rawptr, format: ^u32, stride: ^c.size_t) -> bool,
	end_data_ptr_access: proc "c" (buffer: ^wlr_buffer),
}
#assert(size_of(wlr_buffer) == 88 && align_of(wlr_buffer) == 8 && offset_of(wlr_buffer, width) == 8 && offset_of(wlr_buffer, height) == 12 && offset_of(wlr_buffer, dropped) == 16 && offset_of(wlr_buffer, events) == 40)
#assert(size_of(wlr_buffer_impl) == 40 && align_of(wlr_buffer_impl) == 8 && offset_of(wlr_buffer_impl, destroy) == 0 && offset_of(wlr_buffer_impl, get_dmabuf) == 8 && offset_of(wlr_buffer_impl, begin_data_ptr_access) == 24)
#assert(offset_of(wlr_buffer_impl, end_data_ptr_access) == 32)
wlr_fbox :: struct { x,y,width,height: f64 }
#assert(size_of(wlr_fbox)==32 && align_of(wlr_fbox)==8 && offset_of(wlr_fbox,x)==0 && offset_of(wlr_fbox,y)==8 && offset_of(wlr_fbox,width)==16 && offset_of(wlr_fbox,height)==24)
foreign lib {
	wlr_buffer_finish :: proc(buffer: ^wlr_buffer) ---
	wlr_buffer_init :: proc(buffer: ^wlr_buffer, impl: ^wlr_buffer_impl, width,height: c.int) ---
	wlr_buffer_drop :: proc(buffer: ^wlr_buffer) ---
	wlr_buffer_lock :: proc(buffer: ^wlr_buffer) -> ^wlr_buffer ---
	wlr_buffer_unlock :: proc(buffer: ^wlr_buffer) ---
}


buffer_finish :: wlr_buffer_finish

Render_Buffer :: wlr_buffer
buffer_retain :: wlr_buffer_lock
buffer_release :: wlr_buffer_unlock
