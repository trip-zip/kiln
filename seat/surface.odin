package seat

import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

surface_of :: proc(r: ^wl.Resource) -> ^wlr.Surface { return wlr.wlr_surface_from_resource(r) if r != nil else nil }
surface_resource :: proc(s: ^wlr.Surface) -> ^wl.Resource { return s.resource }
surface_watch :: proc(s: ^wlr.Surface, listener: ^wl.Listener, notify: wl.Notify) { wl.listen(&s.events.destroy, listener, notify) }

Surface_Role :: struct {
	name: cstring,
	no_object: bool,
	client_commit, commit, map_, unmap, destroy: proc "c" (^wlr.Surface),
}
#assert(size_of(Surface_Role) == 56 && align_of(Surface_Role) == 8)
#assert(offset_of(Surface_Role, name) == 0 && offset_of(Surface_Role, no_object) == 8)
#assert(offset_of(Surface_Role, client_commit) == 16 && offset_of(Surface_Role, commit) == 24)
#assert(offset_of(Surface_Role, map_) == 32 && offset_of(Surface_Role, unmap) == 40 && offset_of(Surface_Role, destroy) == 48)
#assert(offset_of(wlr.Surface, resource) == 0 && offset_of(wlr.Surface, events) == 712)
#assert(offset_of(wlr.wlr_surface_events, destroy) == 80)
foreign import surface_lib "system:wlroots-0.20"
foreign surface_lib {
	wlr_surface_set_role :: proc(^wlr.Surface, ^Surface_Role, ^wl.Resource, u32) -> bool ---
	wlr_surface_has_buffer :: proc(^wlr.Surface) -> bool ---
	wlr_surface_map :: proc(^wlr.Surface) ---
}
foreign import pixman_lib "system:pixman-1"
foreign pixman_lib { pixman_region32_clear :: proc(^wlr.pixman_region32_t) --- }
#assert(offset_of(wlr.Surface, input_region) == 72)
cursor_surface_committed :: proc "c" (s: ^wlr.Surface) {
	context = runtime.default_context()
	context = s.resource.client.display.loop.ctx
	pixman_region32_clear(&s.input_region)
	if wlr_surface_has_buffer(s) { wlr_surface_map(s) }
}
cursor_role := Surface_Role{name="wl_pointer-cursor", no_object=true, commit=cursor_surface_committed}
cursor_role_assign :: proc(surface: ^wlr.Surface, r: ^wl.Resource) -> bool {
	if !wlr_surface_set_role(surface, &cursor_role, r, 0) { return false }
	pixman_region32_clear(&surface.input_region)
	if wlr_surface_has_buffer(surface) { wlr_surface_map(surface) }
	return true
}

device_leds :: proc(kb: ^wlr.wlr_keyboard, leds: u32) { if kb != nil { wlr.wlr_keyboard_led_update(kb, leds) } }

icon_surface_commit :: proc(s: ^wlr.Surface) {
	pixman_region32_clear(&s.input_region)
	if wlr_surface_has_buffer(s) { wlr_surface_map(s) }
}

surface_watch_commit :: proc(s: ^wlr.Surface, listener: ^wl.Listener, notify: wl.Notify) { wl.listen(&s.events.commit, listener, notify) }
foreign surface_lib { wlr_region_from_resource :: proc(^wl.Resource) -> ^wlr.pixman_region32_t --- }
foreign pixman_lib { pixman_region32_rectangles :: proc(^wlr.pixman_region32_t, ^i32) -> [^]wlr.pixman_box32_t --- }
region_copy :: proc(r: ^wl.Resource) -> []wlr.pixman_box32_t {
	n: i32; rects := pixman_region32_rectangles(wlr_region_from_resource(r), &n)
	copy_ := make([]wlr.pixman_box32_t,int(n)); copy(copy_,rects[:n]); return copy_
}
surface_input_rectangles :: proc(s: ^wlr.Surface) -> []wlr.pixman_box32_t {
	n: i32; rects := pixman_region32_rectangles(&s.input_region, &n)
	result := make([]wlr.pixman_box32_t,int(n),context.temp_allocator)
	copy(result,rects[:n]); return result
}
#assert(offset_of(wlr.Surface, current)==96 && offset_of(wlr.wlr_surface_events, commit)==16)
#assert(offset_of(wlr.wlr_surface_state,width)==144 && offset_of(wlr.wlr_surface_state,height)==148)
#assert(offset_of(wlr.pixman_box32_t,x1)==0 && offset_of(wlr.pixman_box32_t,y1)==4 && offset_of(wlr.pixman_box32_t,x2)==8 && offset_of(wlr.pixman_box32_t,y2)==12)
