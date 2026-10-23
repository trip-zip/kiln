package gbm

import "core:c"

foreign import lib "system:gbm"
GBM_BO_USE_SCANOUT :: u32(1)
GBM_BO_USE_RENDERING :: u32(4)
gbm_device :: struct {}
gbm_bo :: struct {}
gbm_bo_handle :: struct #raw_union {
	ptr: rawptr,
	s32: i32,
	u32: u32,
	s64: i64,
	u64: u64,
}
#assert(size_of(gbm_bo_handle) == 8 && align_of(gbm_bo_handle) == 8)
foreign lib {
	gbm_create_device :: proc(fd: c.int) -> ^gbm_device ---
	gbm_device_destroy :: proc(device: ^gbm_device) ---
	gbm_bo_create_with_modifiers2 :: proc(device: ^gbm_device, width, height, format: u32, modifiers: [^]u64, count: c.uint, flags: u32) -> ^gbm_bo ---
	gbm_bo_create :: proc(device: ^gbm_device, width, height, format, flags: u32) -> ^gbm_bo ---
	gbm_bo_destroy :: proc(bo: ^gbm_bo) ---
	gbm_bo_get_plane_count :: proc(bo: ^gbm_bo) -> c.int ---
	gbm_bo_get_fd_for_plane :: proc(bo: ^gbm_bo, plane: c.int) -> c.int ---
	gbm_bo_get_stride_for_plane :: proc(bo: ^gbm_bo, plane: c.int) -> u32 ---
	gbm_bo_get_offset :: proc(bo: ^gbm_bo, plane: c.int) -> u32 ---
	gbm_bo_get_modifier :: proc(bo: ^gbm_bo) -> u64 ---
	gbm_bo_get_format :: proc(bo: ^gbm_bo) -> u32 ---
	gbm_bo_get_handle_for_plane :: proc(bo: ^gbm_bo, plane: c.int) -> gbm_bo_handle ---
}
