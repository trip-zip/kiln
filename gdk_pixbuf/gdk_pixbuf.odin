package gdk_pixbuf

import "core:c"
foreign import lib "system:gdk_pixbuf-2.0"
foreign import glib "system:glib-2.0"
GdkPixbuf :: struct {}
GError :: struct {}
foreign lib {
	gdk_pixbuf_new_from_file :: proc(filename: cstring, error: ^^GError) -> ^GdkPixbuf ---
	gdk_pixbuf_get_width :: proc(pixbuf: ^GdkPixbuf) -> c.int ---
	gdk_pixbuf_get_height :: proc(pixbuf: ^GdkPixbuf) -> c.int ---
	gdk_pixbuf_get_n_channels :: proc(pixbuf: ^GdkPixbuf) -> c.int ---
	gdk_pixbuf_get_rowstride :: proc(pixbuf: ^GdkPixbuf) -> c.int ---
	gdk_pixbuf_get_has_alpha :: proc(pixbuf: ^GdkPixbuf) -> c.int ---
	gdk_pixbuf_get_bits_per_sample :: proc(pixbuf: ^GdkPixbuf) -> c.int ---
	gdk_pixbuf_get_colorspace :: proc(pixbuf: ^GdkPixbuf) -> c.int ---
	gdk_pixbuf_get_pixels :: proc(pixbuf: ^GdkPixbuf) -> [^]u8 ---
}
foreign glib {
	g_error_free :: proc(error: ^GError) ---
}
