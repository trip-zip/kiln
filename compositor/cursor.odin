package compositor

import sp "../scene_paint"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

cursor_sync :: proc(s: ^Server) {
	if s.cursor == nil {return}
	for o in s.outputs {
		if len(s.pointers) == 0 {
			sp.cursor_set(&o.paint, nil, nil, s.cursor.x, s.cursor.y, 0, 0)
			continue
		}
		image: ^wlr.wlr_xcursor_image
		if s.cursor_named && s.cursor_manager != nil {
			wlr.wlr_xcursor_manager_load(s.cursor_manager, o.handle.scale)
			c := wlr.wlr_xcursor_manager_get_xcursor(
				s.cursor_manager,
				s.cursor_name,
				o.handle.scale,
			)
			if c == nil {c = wlr.wlr_xcursor_manager_get_xcursor(s.cursor_manager, "default", o.handle.scale)}
			if c != nil && c.image_count > 0 {image = c.images[0]}
		}
		sp.cursor_set(
			&o.paint,
			s.cursor_surface,
			image,
			s.cursor.x,
			s.cursor.y,
			s.cursor_hx,
			s.cursor_hy,
		)
	}
}

cursor_surface_set :: proc(s: ^Server, surface: ^wlr.wlr_surface, hx, hy: i32) {
	wl.unlisten(&s.cursor_surface_destroy)
	wl.unlisten(&s.cursor_surface_commit)
	s.cursor_surface, s.cursor_hx, s.cursor_hy = surface, hx, hy
	if surface != nil {
		wl.listen(&surface.events.destroy, &s.cursor_surface_destroy, cursor_surface_destroyed)
		wl.listen(&surface.events.commit, &s.cursor_surface_commit, cursor_surface_committed)
	}
	cursor_sync(s)
}

cursor_surface_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "cursor_surface_destroy")
	cursor_surface_set(s, nil, 0, 0)
}

cursor_surface_committed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "cursor_surface_commit")
	s.cursor_hx -= s.cursor_surface.current.dx
	s.cursor_hy -= s.cursor_surface.current.dy
	cursor_sync(s)
}
