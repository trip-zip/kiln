package wlroots

foreign import lib "system:wlroots-0.20"
wlr_swapchain :: struct {}
wlr_texture :: struct {}
wlr_drm_format :: struct {
    format:u32,
    len,capacity:uint,
    modifiers:^u64,
}
wlr_scene_output_state_options :: struct {
    timer,color_transform:rawptr,
    swapchain:^wlr_swapchain,
}
wlr_texture_read_pixels_options :: struct {
    data:rawptr,
    format,stride,dst_x,dst_y:u32,
    src_box:wlr_box,
}
#assert(size_of(wlr_drm_format)==32 && align_of(wlr_drm_format)==8)
#assert(offset_of(wlr_drm_format,format)==0 && offset_of(wlr_drm_format,len)==8)
#assert(offset_of(wlr_drm_format,capacity)==16 && offset_of(wlr_drm_format,modifiers)==24)
#assert(size_of(wlr_scene_output_state_options)==24 && align_of(wlr_scene_output_state_options)==8)
#assert(offset_of(wlr_scene_output_state_options,timer)==0 && offset_of(wlr_scene_output_state_options,color_transform)==8)
#assert(offset_of(wlr_scene_output_state_options,swapchain)==16)
#assert(size_of(wlr_texture_read_pixels_options)==40 && align_of(wlr_texture_read_pixels_options)==8)
#assert(offset_of(wlr_texture_read_pixels_options,data)==0 && offset_of(wlr_texture_read_pixels_options,format)==8)
#assert(offset_of(wlr_texture_read_pixels_options,stride)==12 && offset_of(wlr_texture_read_pixels_options,dst_x)==16)
#assert(offset_of(wlr_texture_read_pixels_options,dst_y)==20 && offset_of(wlr_texture_read_pixels_options,src_box)==24)
#assert(offset_of(wlr_output_state,buffer)==56)

foreign lib {
    wlr_swapchain_create :: proc(allocator:^wlr_allocator,width,height:i32,format:^wlr_drm_format)->^wlr_swapchain ---
    wlr_swapchain_destroy :: proc(swapchain:^wlr_swapchain) ---
    wlr_scene_output_build_state :: proc(output:^wlr_scene_output,state:^wlr_output_state,options:^wlr_scene_output_state_options)->bool ---
    wlr_output_lock_attach_render :: proc(output:^wlr_output,lock:bool) ---
    wlr_texture_from_buffer :: proc(renderer:^wlr_renderer,buffer:^wlr_buffer)->^wlr_texture ---
    wlr_texture_destroy :: proc(texture:^wlr_texture) ---
    wlr_texture_read_pixels :: proc(texture:^wlr_texture,options:^wlr_texture_read_pixels_options)->bool ---
}
