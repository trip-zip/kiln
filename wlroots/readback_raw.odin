package wlroots

foreign import lib "system:wlroots-0.20"
wlr_swapchain :: struct {}
wlr_texture :: struct {}
wlr_texture_read_pixels_options :: struct {
    data:rawptr,
    format,stride,dst_x,dst_y:u32,
    src_box:wlr_box,
}
#assert(size_of(wlr_texture_read_pixels_options)==40 && align_of(wlr_texture_read_pixels_options)==8)
#assert(offset_of(wlr_texture_read_pixels_options,data)==0 && offset_of(wlr_texture_read_pixels_options,format)==8)
#assert(offset_of(wlr_texture_read_pixels_options,stride)==12 && offset_of(wlr_texture_read_pixels_options,dst_x)==16)
#assert(offset_of(wlr_texture_read_pixels_options,dst_y)==20 && offset_of(wlr_texture_read_pixels_options,src_box)==24)
#assert(offset_of(wlr_output_state,buffer)==56)

foreign lib {
    wlr_texture_from_buffer :: proc(renderer:^wlr_renderer,buffer:^wlr_buffer)->^wlr_texture ---
    wlr_texture_destroy :: proc(texture:^wlr_texture) ---
    wlr_texture_read_pixels :: proc(texture:^wlr_texture,options:^wlr_texture_read_pixels_options)->bool ---
}
