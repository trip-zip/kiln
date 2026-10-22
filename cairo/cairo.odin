package cairo

import "core:c"
foreign import lib "system:cairo"
cairo_t :: struct {}
cairo_surface_t :: struct {}
cairo_format_t :: enum c.int { INVALID = -1, ARGB32 = 0 }
cairo_fill_rule_t :: enum c.int { WINDING, EVEN_ODD }
foreign lib {
    cairo_surface_write_to_png :: proc(surface:^cairo_surface_t,path:cstring)->c.int ---
	cairo_surface_mark_dirty :: proc(surface: ^cairo_surface_t) ---
	cairo_scale :: proc(cr: ^cairo_t, sx,sy: f64) ---
	cairo_clip :: proc(cr: ^cairo_t) ---
	cairo_mask_surface :: proc(cr: ^cairo_t, surface: ^cairo_surface_t, x,y: f64) ---
	cairo_set_source_surface :: proc(cr: ^cairo_t, surface: ^cairo_surface_t, x,y: f64) ---
	cairo_paint :: proc(cr: ^cairo_t) ---
	cairo_image_surface_create :: proc(format: cairo_format_t, width, height: c.int) -> ^cairo_surface_t ---
	cairo_image_surface_get_data :: proc(surface: ^cairo_surface_t) -> [^]u8 ---
	cairo_image_surface_get_stride :: proc(surface: ^cairo_surface_t) -> c.int ---
	cairo_surface_status :: proc(surface: ^cairo_surface_t) -> c.int ---
	cairo_surface_destroy :: proc(surface: ^cairo_surface_t) ---
	cairo_surface_flush :: proc(surface: ^cairo_surface_t) ---
	cairo_create :: proc(surface: ^cairo_surface_t) -> ^cairo_t ---
	cairo_destroy :: proc(cr: ^cairo_t) ---
	cairo_status :: proc(cr: ^cairo_t) -> c.int ---
	cairo_set_source_rgba :: proc(cr: ^cairo_t, r,g,b,a: f64) ---
	cairo_new_sub_path :: proc(cr: ^cairo_t) ---
	cairo_arc :: proc(cr: ^cairo_t, xc,yc,radius,angle1,angle2: f64) ---
	cairo_close_path :: proc(cr: ^cairo_t) ---
	cairo_set_fill_rule :: proc(cr: ^cairo_t, rule: cairo_fill_rule_t) ---
	cairo_fill :: proc(cr: ^cairo_t) ---
	cairo_translate :: proc(cr: ^cairo_t, tx,ty: f64) ---
}
