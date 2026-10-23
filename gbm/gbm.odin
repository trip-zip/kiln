package gbm

Device :: gbm_device
Buffer :: gbm_bo
ARGB8888 :: u32(0x34325241)
XRGB8888 :: u32(0x34325258)
INVALID :: u64(0x00ffffffffffffff)
create :: gbm_create_device
destroy :: gbm_device_destroy
release :: gbm_bo_destroy
planes :: gbm_bo_get_plane_count
fd :: gbm_bo_get_fd_for_plane
stride :: gbm_bo_get_stride_for_plane
offset :: gbm_bo_get_offset
modifier :: gbm_bo_get_modifier
format :: gbm_bo_get_format
allocate :: proc(device: ^Device, width, height: i32, format: u32, modifiers: []u64) -> ^Buffer {
	if len(modifiers) == 1 &&
	   modifiers[0] == INVALID {return gbm_bo_create(device, u32(width), u32(height), format, GBM_BO_USE_RENDERING | GBM_BO_USE_SCANOUT)}
	return gbm_bo_create_with_modifiers2(
		device,
		u32(width),
		u32(height),
		format,
		raw_data(modifiers),
		u32(len(modifiers)),
		GBM_BO_USE_RENDERING | GBM_BO_USE_SCANOUT,
	)
}
