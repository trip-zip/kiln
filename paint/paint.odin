package paint

import "core:strings"
import "core:math"
import c "../cairo"
import p "../pango"

Color :: [4]f32
Radii :: struct { tl, tr, bl, br: f32 }
Widths :: struct { left, right, top, bottom: f32 }
Font :: struct { name: string, desc: ^p.PangoFontDescription }
Fonts :: struct { entries: [dynamic]Font }
Measurer :: struct { handle: ^p.PangoLayout }
Surface :: struct { handle: ^c.cairo_surface_t, width, height, stride: i32 }

intern_font :: proc(f: ^Fonts, description: string) -> i32 {
	name := description
	for byte,i in transmute([]u8)description { if byte == 0 { name = description[:i]; break } }
	if len(f.entries) == 0 && name != "Sans" { intern_font(f, "Sans") }
	for font, i in f.entries { if font.name == name { return i32(i) } }
	z := strings.clone_to_cstring(name)
	defer delete(z)
	d := p.pango_font_description_from_string(z)
	if d == nil { return -3 }
	if p.pango_font_description_get_set_fields(d) & p.PANGO_FONT_MASK_SIZE != 0 {
		p.pango_font_description_free(d)
		return -1
	}
	if len(f.entries) >= 64 { p.pango_font_description_free(d); return -2 }
	append(&f.entries, Font{strings.clone(name), d})
	return i32(len(f.entries)-1)
}
destroy_fonts :: proc(f: ^Fonts) {
	for font in f.entries { delete(font.name); p.pango_font_description_free(font.desc) }
	delete(f.entries)
	f^ = {}
}
init_measurer :: proc(m: ^Measurer) -> bool {
	ctx := p.pango_font_map_create_context(p.pango_cairo_font_map_get_default())
	if ctx == nil { return false }
	defer p.g_object_unref(ctx)
	m.handle = p.pango_layout_new(ctx)
	return m.handle != nil
}
destroy_measurer :: proc(m: ^Measurer) { if m.handle != nil { p.g_object_unref(m.handle); m.handle = nil } }
set_text :: proc(l: ^p.PangoLayout, f: ^Fonts, text: string, id, size: u16, scale: f32 = 1) {
	if len(f.entries) == 0 { intern_font(f, "Sans") }
	index := int(id)
	if index >= len(f.entries) { index = 0 }
	desc := f.entries[index].desc
	p.pango_font_description_set_absolute_size(desc, f64(size)*f64(scale)*p.PANGO_SCALE)
	p.pango_layout_set_font_description(l, desc)
	p.pango_layout_set_width(l, -1)
	p.pango_layout_set_ellipsize(l, 0)
	p.pango_layout_set_text(l, cast(cstring)raw_data(text), i32(len(text)))
}
measure :: proc(m: ^Measurer, f: ^Fonts, text: string, id, size: u16, scale: f32 = 1) -> (f32,f32) {
	set_text(m.handle, f, text, id, size, scale)
	w,h: i32
	p.pango_layout_get_pixel_size(m.handle, &w, &h)
	return f32(w)/scale,f32(h)/scale
}
create :: proc(width, height: i32) -> (Surface, bool) {
	// Bound candidates before asking Cairo for memory; failure leaves the active frame intact.
	if width <= 0 || height <= 0 || i64(width)*i64(height) > 16*1024*1024 { return {}, false }
	s := c.cairo_image_surface_create(.ARGB32, width, height)
	if c.cairo_surface_status(s) != 0 { c.cairo_surface_destroy(s); return {}, false }
	return {s,width,height,c.cairo_image_surface_get_stride(s)}, true
}
destroy :: proc(s: Surface) { if s.handle != nil { c.cairo_surface_destroy(s.handle) } }
data :: proc(s: Surface) -> [^]u8 { c.cairo_surface_flush(s.handle); return c.cairo_image_surface_get_data(s.handle) }
alpha :: proc(s: Surface, x,y: i32) -> u8 {
	if x<0 || y<0 || x>=s.width || y>=s.height { return 0 }
	row := cast([^]u32)&data(s)[int(y)*int(s.stride)]
	return u8(row[x]>>24)
}
source :: proc(cr: ^c.cairo_t, color: Color) { c.cairo_set_source_rgba(cr,f64(color[0]),f64(color[1]),f64(color[2]),f64(color[3])) }
clamp_radii :: proc(r: Radii, w,h: f32) -> Radii {
	m := max(0,min(w,h)/2)
	return {clamp(r.tl,0,m),clamp(r.tr,0,m),clamp(r.bl,0,m),clamp(r.br,0,m)}
}
rounded_path :: proc(cr: ^c.cairo_t, x,y,w,h: f64, radii: Radii) {
	r := clamp_radii(radii,f32(w),f32(h))
	pi :: math.PI
	c.cairo_new_sub_path(cr)
	c.cairo_arc(cr,x+w-f64(r.tr),y+f64(r.tr),f64(r.tr),-pi/2,0)
	c.cairo_arc(cr,x+w-f64(r.br),y+h-f64(r.br),f64(r.br),0,pi/2)
	c.cairo_arc(cr,x+f64(r.bl),y+h-f64(r.bl),f64(r.bl),pi/2,pi)
	c.cairo_arc(cr,x+f64(r.tl),y+f64(r.tl),f64(r.tl),pi,pi*1.5)
	c.cairo_close_path(cr)
}
finish :: proc(cr: ^c.cairo_t, s: Surface) -> bool {
	ok := c.cairo_status(cr) == 0 && c.cairo_surface_status(s.handle) == 0
	c.cairo_destroy(cr)
	c.cairo_surface_flush(s.handle)
	return ok
}
text :: proc(s: Surface, fonts: ^Fonts, value: string, id,size: u16, color: Color, ellipsis: i32 = 0, scale: f32 = 1) -> bool {
	cr := c.cairo_create(s.handle)
	source(cr,color)
	l := p.pango_cairo_create_layout(cr)
	if l == nil { c.cairo_destroy(cr); return false }
	set_text(l,fonts,value,id,size,scale)
	if ellipsis>0 { p.pango_layout_set_width(l,ellipsis*p.PANGO_SCALE); p.pango_layout_set_ellipsize(l,3) }
	p.pango_cairo_show_layout(cr,l)
	p.g_object_unref(l)
	return finish(cr,s)
}
shape :: proc(s: Surface, color: Color, radii: Radii, w,h: i32, x: i32 = 0, y: i32 = 0, border := false, widths := Widths{}) -> bool {
	cr := c.cairo_create(s.handle)
	c.cairo_translate(cr,-f64(x),-f64(y))
	r := clamp_radii(radii,f32(w),f32(h))
	rounded_path(cr,0,0,f64(w),f64(h),r)
	if border {
		bw := widths
		iw,ih := f32(w)-bw.left-bw.right, f32(h)-bw.top-bw.bottom
		if iw>0 && ih>0 {
			inner := Radii{max(0,r.tl-max(bw.top,bw.left)),max(0,r.tr-max(bw.top,bw.right)),max(0,r.bl-max(bw.bottom,bw.left)),max(0,r.br-max(bw.bottom,bw.right))}
			rounded_path(cr,f64(bw.left),f64(bw.top),f64(iw),f64(ih),inner)
		}
		c.cairo_set_fill_rule(cr,.EVEN_ODD)
	}
	source(cr,color)
	c.cairo_fill(cr)
	return finish(cr,s)
}

image :: proc(s, decoded: Surface, color: Color, radii: Radii) -> bool {
	cr := c.cairo_create(s.handle)
	if radii!=(Radii{}) { rounded_path(cr,0,0,f64(s.width),f64(s.height),radii); c.cairo_clip(cr) }
	c.cairo_scale(cr,f64(s.width)/f64(decoded.width),f64(s.height)/f64(decoded.height))
	if color[3]>0 { source(cr,color); c.cairo_mask_surface(cr,decoded.handle,0,0) }
	else { c.cairo_set_source_surface(cr,decoded.handle,0,0); c.cairo_paint(cr) }
	return finish(cr,s)
}
