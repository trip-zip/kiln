package readback

import wlr "../wlroots"
import paint "../paint"
import cairo "../cairo"

live_chains,live_states,live_textures:i64
when #config(KILN_OUTPUT_FIXTURE,false) { fail_after:i32 } else { fail_after :: 0 }

// Capture the exact committed frame without acquiring or painting another buffer.
capture :: proc(buffer:^wlr.Render_Buffer,output:^wlr.wlr_output,renderer:^wlr.wlr_renderer)->(paint.Surface,bool) {
    if output==nil || !output.enabled || buffer==nil { return {},false }
    width,height:=buffer.width,buffer.height
    if width<=0 || height<=0 || i64(width)*i64(height)>16*1024*1024 { return {},false }
    if fail_after==1 { return {},false }
    wlr.buffer_retain(buffer)
    defer wlr.buffer_release(buffer)
    if fail_after==2 { return {},false }
    texture:=wlr.texture_create(renderer,buffer)
    if texture==nil { return {},false }
    live_textures+=1
    defer { wlr.texture_destroy(texture);live_textures-=1 }
    if fail_after==3 { return {},false }
    surface,ok:=paint.create(width,height)
    if !ok { return {},false }
    if fail_after==4 { paint.destroy(surface);return {},false }
    // ARGB8888 matches Cairo's native-endian premultiplied storage. The composed
    // XRGB target is opaque, so no second premultiplication can darken channels.
    if !wlr.read_pixels(texture,paint.data(surface),u32(surface.stride)) { paint.destroy(surface);return {},false }
    cairo.cairo_surface_mark_dirty(surface.handle)
    return surface,true
}
