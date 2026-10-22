package readback

import wlr "../wlroots"
import paint "../paint"
import cairo "../cairo"

live_chains,live_states,live_textures:i64
when #config(KILN_OUTPUT_FIXTURE,false) { fail_after:i32 } else { fail_after :: 0 }

// No commit or event dispatch occurs here. Destroying the one-shot buffer
// returns its damage history to the live ring through wlroots' destroy listener.
capture :: proc(scene:^wlr.wlr_scene,output:^wlr.wlr_output,allocator:^wlr.wlr_allocator,renderer:^wlr.wlr_renderer)->(paint.Surface,bool) {
    if output==nil || !output.enabled { return {},false }
    width,height:=output.width,output.height
    if width<=0 || height<=0 || i64(width)*i64(height)>16*1024*1024 { return {},false }
    scene_output:=wlr.wlr_scene_get_scene_output(scene,output)
    if scene_output==nil { return {},false }
    modifier:u64=0x00ff_ffff_ffff_ffff
    format:=wlr.wlr_drm_format{format=0x34325258,len=1,capacity=1,modifiers=&modifier}
    chain:=wlr.wlr_swapchain_create(allocator,width,height,&format)
    if chain==nil { return {},false }
    live_chains+=1
    defer { wlr.wlr_swapchain_destroy(chain);live_chains-=1 }
    if fail_after==1 { return {},false }
    // Readback must use our buffer even when a single client could scan out.
    wlr.wlr_output_lock_attach_render(output,true)
    defer wlr.wlr_output_lock_attach_render(output,false)
    state:wlr.wlr_output_state
    wlr.wlr_output_state_init(&state)
    live_states+=1
    defer { wlr.wlr_output_state_finish(&state);live_states-=1 }
    if fail_after==2 { return {},false }
    options:=wlr.wlr_scene_output_state_options{swapchain=chain}
    if !wlr.wlr_scene_output_build_state(scene_output,&state,&options) || state.buffer==nil { return {},false }
    texture:=wlr.wlr_texture_from_buffer(renderer,state.buffer)
    if texture==nil { return {},false }
    live_textures+=1
    defer { wlr.wlr_texture_destroy(texture);live_textures-=1 }
    if fail_after==3 { return {},false }
    surface,ok:=paint.create(width,height)
    if !ok { return {},false }
    if fail_after==4 { paint.destroy(surface);return {},false }
    // ARGB8888 matches Cairo's native-endian premultiplied storage. The composed
    // XRGB target is opaque, so no second premultiplication can darken channels.
    read:=wlr.wlr_texture_read_pixels_options{data=paint.data(surface),format=0x34325241,stride=u32(surface.stride)}
    if !wlr.wlr_texture_read_pixels(texture,&read) { paint.destroy(surface);return {},false }
    cairo.cairo_surface_mark_dirty(surface.handle)
    return surface,true
}
