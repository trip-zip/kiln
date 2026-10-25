package compositor

import gles "../gles"
import bk "../backend"
import out "../outputs"
import sf "../surfaces"
import st "../seat"
import sp "../scene_paint"
import wl "../wayland"
import "core:math"

cursor_sync :: proc(s: ^Server) {
	for o in s.outputs {
		if len(s.pointers) == 0 {
			sp.cursor_set(&o.paint, nil, nil, s.cursor_x, s.cursor_y, 0, 0)
			continue
		}
		image: ^st.Cursor_Image
		if s.cursor_named && s.cursor_manager != nil {
			st.xcursor_manager_load(s.cursor_manager, o.handle.scale)
			c := st.xcursor_manager_get_xcursor(
				s.cursor_manager,
				s.cursor_name,
				o.handle.scale,
			)
			if c == nil {c = st.xcursor_manager_get_xcursor(s.cursor_manager, "default", o.handle.scale)}
			if c != nil && len(c.images) > 0 {image = c.images[0]}
		}
		sp.cursor_set(
			&o.paint,
			s.cursor_surface,
			image,
			s.cursor_x,
			s.cursor_y,
			s.cursor_hx,
			s.cursor_hy,
		)
	}
}

cursor_surface_set :: proc(s: ^Server, surface: ^sf.Surface, hx, hy: i32) {
	wl.unlisten(&s.cursor_surface_destroy)
	wl.unlisten(&s.cursor_surface_commit)
	s.cursor_surface, s.cursor_hx, s.cursor_hy = surface, hx, hy
	if surface != nil {
		wl.listen(&surface.events.destroy, &s.cursor_surface_destroy, cursor_surface_destroyed)
		wl.listen(&surface.events.commit, &s.cursor_surface_commit, cursor_surface_committed)
	}
	cursor_sync(s)
}

cursor_surface_destroyed :: proc (listener: ^wl.Listener, data: rawptr) {
	s := wl.owner(listener, Server, "cursor_surface_destroy")
	cursor_surface_set(s, nil, 0, 0)
}

cursor_surface_committed :: proc (listener: ^wl.Listener, data: rawptr) {
	s := wl.owner(listener, Server, "cursor_surface_commit")
	s.cursor_hx -= s.cursor_surface.current.dx
	s.cursor_hy -= s.cursor_surface.current.dy
	cursor_sync(s)
}

// Position queries keep input constraints without creating rendering cursors.
cursor_position :: proc(s: ^Server, x, y: f64) {
	if s.layout == nil { return }
	lx := s.cursor_x if math.is_nan(x) else x
	ly := s.cursor_y if math.is_nan(y) else y
	if math.is_inf(lx) || math.is_inf(ly) { return }
	box: gles.Box
	box = out.layout_box(s.layout, nil)
	if box.width <= 0 || box.height <= 0 { return }
	s.cursor_x, s.cursor_y = out.layout_closest_point(s.layout, nil, lx, ly)
}

cursor_absolute_position :: proc(s: ^Server, pointer: ^bk.Pointer, x, y: f64) -> (f64, f64) {
	output: ^out.Output
	for o in s.outputs { if o.lifetime == pointer_output(s, pointer) { output = o.handle; break } }
	box: gles.Box
	box = out.layout_box(s.layout, output)
	return s.cursor_x if math.is_nan(x) else f64(box.x)+x*f64(box.width),
		s.cursor_y if math.is_nan(y) else f64(box.y)+y*f64(box.height)
}

cursor_hint :: proc(s: ^Server, x, y: f64) {
	lx, ly := s.cursor_x-s.seat.pointer_state.sx+x, s.cursor_y-s.seat.pointer_state.sy+y
	if !math.is_nan(lx) && !math.is_nan(ly) && lx >= f64(min(i32)) && lx <= f64(max(i32)) &&
	   ly >= f64(min(i32)) && ly <= f64(max(i32)) && out.layout_contains_point(s.layout, nil, f64(i32(lx)), f64(i32(ly))) {
		s.cursor_x, s.cursor_y = lx, ly
		st.pointer_warp(s.seat, x, y)
	}
}

// The queued output lifetime prevents a removed device mapping from targeting its replacement.
cursor_mapped_position :: proc(s: ^Server, output: u64, x,y: f64) -> (f64,f64) {
	if output != 0 { for o in s.outputs { if o.lifetime == output {
		box: gles.Box; box = out.layout_box(s.layout, o.handle)
		if box.width>0 && box.height>0 { return clamp(x,f64(box.x),f64(box.x+box.width)-1.0/256),clamp(y,f64(box.y),f64(box.y+box.height)-1.0/256) }
	} } }
	return x,y
}
