package pango

import "core:c"
import cairo "../cairo"
foreign import lib "system:pango-1.0"
foreign import pc "system:pangocairo-1.0"
foreign import gobject "system:gobject-2.0"
PangoFontDescription :: struct {}
PangoLayout :: struct {}
PangoFontMap :: struct {}
PangoContext :: struct {}
PANGO_SCALE :: 1024
PANGO_FONT_MASK_SIZE :: 1 << 5
foreign lib {
	pango_font_description_from_string :: proc(str: cstring) -> ^PangoFontDescription ---
	pango_font_description_get_set_fields :: proc(desc: ^PangoFontDescription) -> c.int ---
	pango_font_description_set_absolute_size :: proc(desc: ^PangoFontDescription, size: f64) ---
	pango_font_description_free :: proc(desc: ^PangoFontDescription) ---
	pango_font_map_create_context :: proc(fontmap: ^PangoFontMap) -> ^PangoContext ---
	pango_layout_new :: proc(ctx: ^PangoContext) -> ^PangoLayout ---
	pango_layout_set_font_description :: proc(layout: ^PangoLayout, desc: ^PangoFontDescription) ---
	pango_layout_set_width :: proc(layout: ^PangoLayout, width: c.int) ---
	pango_layout_set_ellipsize :: proc(layout: ^PangoLayout, ellipsize: c.int) ---
	pango_layout_set_text :: proc(layout: ^PangoLayout, text: cstring, length: c.int) ---
	pango_layout_get_pixel_size :: proc(layout: ^PangoLayout, width, height: ^c.int) ---
}
foreign pc {
	pango_cairo_font_map_get_default :: proc() -> ^PangoFontMap ---
	pango_cairo_create_layout :: proc(cr: ^cairo.cairo_t) -> ^PangoLayout ---
	pango_cairo_show_layout :: proc(cr: ^cairo.cairo_t, layout: ^PangoLayout) ---
}
foreign gobject {
	g_object_unref :: proc(object: rawptr) ---
}
