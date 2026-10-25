package seat

import bk "../backend"
import sf "../surfaces"
import wl "../wayland"
import rg "../region"

surface_of :: proc(r: ^wl.Resource) -> ^sf.Surface { return sf.of(r) if r != nil else nil }
surface_resource :: proc(s: ^sf.Surface) -> ^wl.Resource { return s.resource }
surface_watch :: proc(s: ^sf.Surface, listener: ^wl.Listener, notify: wl.Odin_Notify) { wl.listen(&s.events.destroy, listener, notify) }

Surface_Role :: sf.Role
cursor_surface_committed :: proc (s: ^sf.Surface) {
	rg.clear(&s.input_region)
	if sf.has_buffer(s) { sf.map_(s) }
}
cursor_role := Surface_Role{name="wl_pointer-cursor", no_object=true, commit=cursor_surface_committed}
cursor_role_assign :: proc(surface: ^sf.Surface, r: ^wl.Resource) -> bool {
	if !sf.set_role(surface, &cursor_role, r, 0) { return false }
	rg.clear(&surface.input_region)
	if sf.has_buffer(surface) { sf.map_(surface) }
	return true
}

device_leds :: proc(kb: ^bk.Keyboard, leds: u32) { if kb != nil { bk.keyboard_leds(kb, leds) } }

icon_surface_commit :: proc(s: ^sf.Surface) {
	rg.clear(&s.input_region)
	if sf.has_buffer(s) { sf.map_(s) }
}

surface_watch_commit :: proc(s: ^sf.Surface, listener: ^wl.Listener, notify: wl.Odin_Notify) { wl.listen(&s.events.commit, listener, notify) }
region_copy :: proc(r: ^wl.Resource) -> []rg.Box {
 rects := rg.rectangles(sf.region_of(r)); result := make([]rg.Box,len(rects)); copy(result,rects); return result
}
surface_input_rectangles :: proc(s: ^sf.Surface) -> []rg.Box {
 rects := rg.rectangles(&s.input_region); result := make([]rg.Box,len(rects),context.temp_allocator); copy(result,rects); return result
}
