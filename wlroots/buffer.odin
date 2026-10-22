package wlroots

import "core:c"
import wl "../wayland_server"
foreign import lib "system:wlroots-0.20"

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
wlr_dmabuf_attributes :: struct {}
wlr_shm_attributes :: struct {}
wlr_buffer_impl :: struct {
	destroy: proc "c" (buffer: ^wlr_buffer),
	get_dmabuf: proc "c" (buffer: ^wlr_buffer, attribs: ^wlr_dmabuf_attributes) -> bool,
	get_shm: proc "c" (buffer: ^wlr_buffer, attribs: ^wlr_shm_attributes) -> bool,
	begin_data_ptr_access: proc "c" (buffer: ^wlr_buffer, flags: u32, data: ^rawptr, format: ^u32, stride: ^c.size_t) -> bool,
	end_data_ptr_access: proc "c" (buffer: ^wlr_buffer),
}
wlr_scene_buffer :: struct #align(8) {
	node: wlr_scene_node,
	buffer: ^wlr_buffer,
	_opaque120: [80]u8,
	point_accepts_input: proc "c" (buffer: ^wlr_scene_buffer, sx, sy: ^f64) -> bool,
	_opaque208: [248]u8,
}
#assert(size_of(wlr_buffer) == 88)
#assert(align_of(wlr_buffer) == 8)
#assert(offset_of(wlr_buffer, impl) == 0)
#assert(offset_of(wlr_buffer, width) == 8)
#assert(offset_of(wlr_buffer, height) == 12)
#assert(offset_of(wlr_buffer, dropped) == 16)
#assert(offset_of(wlr_buffer, n_locks) == 24)
#assert(offset_of(wlr_buffer, accessing_data_ptr) == 32)
#assert(offset_of(wlr_buffer, events) == 40)
#assert(offset_of(wlr_buffer, _opaque72) == 72)
#assert(size_of(wlr_buffer_impl) == 40)
#assert(align_of(wlr_buffer_impl) == 8)
#assert(offset_of(wlr_buffer_impl, destroy) == 0)
#assert(offset_of(wlr_buffer_impl, get_dmabuf) == 8)
#assert(offset_of(wlr_buffer_impl, get_shm) == 16)
#assert(offset_of(wlr_buffer_impl, begin_data_ptr_access) == 24)
#assert(offset_of(wlr_buffer_impl, end_data_ptr_access) == 32)
#assert(size_of(wlr_scene_buffer) == 456)
#assert(align_of(wlr_scene_buffer) == 8)
#assert(offset_of(wlr_scene_buffer, node) == 0)
#assert(offset_of(wlr_scene_buffer, buffer) == 112)
#assert(offset_of(wlr_scene_buffer, point_accepts_input) == 200)
#assert(offset_of(wlr_scene_node, link) == 16)
#assert(offset_of(wlr_scene_tree, children) == 112)
wlr_fbox :: struct { x,y,width,height: f64 }
#assert(size_of(wlr_fbox)==32)
#assert(align_of(wlr_fbox)==8)
#assert(offset_of(wlr_fbox,x)==0)
#assert(offset_of(wlr_fbox,y)==8)
#assert(offset_of(wlr_fbox,width)==16)
#assert(offset_of(wlr_fbox,height)==24)
foreign lib {
	wlr_scene_buffer_set_source_box :: proc(buffer: ^wlr_scene_buffer, box: ^wlr_fbox) ---
	wlr_buffer_init :: proc(buffer: ^wlr_buffer, impl: ^wlr_buffer_impl, width,height: c.int) ---
	wlr_buffer_drop :: proc(buffer: ^wlr_buffer) ---
	wlr_buffer_lock :: proc(buffer: ^wlr_buffer) -> ^wlr_buffer ---
	wlr_buffer_unlock :: proc(buffer: ^wlr_buffer) ---
	wlr_buffer_begin_data_ptr_access :: proc(buffer: ^wlr_buffer, flags: u32, data: ^rawptr, format: ^u32, stride: ^c.size_t) -> bool ---
	wlr_buffer_end_data_ptr_access :: proc(buffer: ^wlr_buffer) ---
	wlr_scene_buffer_set_dest_size :: proc(buffer: ^wlr_scene_buffer, width,height: c.int) ---
	wlr_scene_buffer_create :: proc(parent: ^wlr_scene_tree, buffer: ^wlr_buffer) -> ^wlr_scene_buffer ---
	wlr_scene_node_place_above :: proc(node, sibling: ^wlr_scene_node) ---
	wlr_scene_node_lower_to_bottom :: proc(node: ^wlr_scene_node) ---
}
