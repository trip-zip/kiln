package wlroots

import "core:c"
import wl "../wayland_server"
foreign import lib "system:wlroots-0.20"

WLR_BUFFER_CAP_DMABUF :: u32(1 << 1)
WLR_BUFFER_DATA_PTR_ACCESS_READ :: u32(1 << 0)

wlr_buffer :: struct #align(8) {
	impl: ^wlr_buffer_impl,
	width, height: c.int,
	dropped: bool,
	_padding17: [7]u8,
	n_locks: c.size_t,
	accessing_data_ptr: bool,
	_padding33: [7]u8,
	events: struct { destroy, release: wl.wl_signal },
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
#assert(offset_of(wlr_dmabuf_attributes, width) == 0 && offset_of(wlr_dmabuf_attributes, height) == 4 && offset_of(wlr_dmabuf_attributes, format) == 8)
#assert(size_of(wlr_dmabuf_attributes) == 80 && align_of(wlr_dmabuf_attributes) == 8)
#assert(offset_of(wlr_dmabuf_attributes, modifier) == 16 && offset_of(wlr_dmabuf_attributes, n_planes) == 24)
#assert(offset_of(wlr_dmabuf_attributes, offset) == 28 && offset_of(wlr_dmabuf_attributes, stride) == 44 && offset_of(wlr_dmabuf_attributes, fd) == 60)
wlr_shm_attributes :: struct {}
wlr_buffer_impl :: struct {
	destroy: proc "c" (buffer: ^wlr_buffer),
	get_dmabuf: proc "c" (buffer: ^wlr_buffer, attribs: ^wlr_dmabuf_attributes) -> bool,
	get_shm: proc "c" (buffer: ^wlr_buffer, attribs: ^wlr_shm_attributes) -> bool,
	begin_data_ptr_access: proc "c" (buffer: ^wlr_buffer, flags: u32, data: ^rawptr, format: ^u32, stride: ^c.size_t) -> bool,
	end_data_ptr_access: proc "c" (buffer: ^wlr_buffer),
}
#assert(size_of(wlr_buffer) == 88 && align_of(wlr_buffer) == 8)
#assert(offset_of(wlr_buffer, impl) == 0 && offset_of(wlr_buffer, width) == 8 && offset_of(wlr_buffer, height) == 12)
#assert(offset_of(wlr_buffer, dropped) == 16 && offset_of(wlr_buffer, n_locks) == 24)
#assert(offset_of(wlr_buffer, accessing_data_ptr) == 32 && offset_of(wlr_buffer, events) == 40)
#assert(offset_of(wlr_buffer, _opaque72) == 72)
#assert(size_of(wlr_buffer_impl) == 40 && align_of(wlr_buffer_impl) == 8)
#assert(offset_of(wlr_buffer_impl, destroy) == 0 && offset_of(wlr_buffer_impl, get_dmabuf) == 8)
#assert(offset_of(wlr_buffer_impl, get_shm) == 16 && offset_of(wlr_buffer_impl, begin_data_ptr_access) == 24)
#assert(offset_of(wlr_buffer_impl, end_data_ptr_access) == 32)
wlr_fbox :: struct { x,y,width,height: f64 }
#assert(size_of(wlr_fbox)==32)
#assert(align_of(wlr_fbox)==8)
#assert(offset_of(wlr_fbox,x)==0 && offset_of(wlr_fbox,y)==8 && offset_of(wlr_fbox,width)==16)
#assert(offset_of(wlr_fbox,height)==24)
foreign lib {
	wlr_buffer_get_dmabuf :: proc(buffer: ^wlr_buffer, attrs: ^wlr_dmabuf_attributes) -> bool ---
	wlr_buffer_finish :: proc(buffer: ^wlr_buffer) ---
	wlr_buffer_init :: proc(buffer: ^wlr_buffer, impl: ^wlr_buffer_impl, width,height: c.int) ---
	wlr_buffer_drop :: proc(buffer: ^wlr_buffer) ---
	wlr_buffer_lock :: proc(buffer: ^wlr_buffer) -> ^wlr_buffer ---
	wlr_buffer_unlock :: proc(buffer: ^wlr_buffer) ---
	wlr_buffer_begin_data_ptr_access :: proc(buffer: ^wlr_buffer, flags: u32, data: ^rawptr, format: ^u32, stride: ^c.size_t) -> bool ---
	wlr_buffer_end_data_ptr_access :: proc(buffer: ^wlr_buffer) ---
}

buffer_dmabuf :: wlr_buffer_get_dmabuf
buffer_access :: wlr_buffer_begin_data_ptr_access
buffer_access_end :: wlr_buffer_end_data_ptr_access

buffer_finish :: wlr_buffer_finish
