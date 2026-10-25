package compositor

import xw "../xwayland"
import wl "../wayland"
import "core:os"
import "core:fmt"

X11_UNAVAILABLE :: "kiln-x11-unavailable"
init_xwayland :: proc(s: ^Server) {
 os.set_env("DISPLAY", X11_UNAVAILABLE)
 s.xwayland = xw.server_create(s.display)
 if s.xwayland == nil { fmt.eprintln("XWayland creation failed; native Wayland remains available"); return }
 s.xwayland.seat = s.seat
 wl.listen(&s.xwayland.events.ready,&s.xwayland_ready,xwayland_ready)
 wl.listen(&s.xwayland.events.new_window,&s.new_xwayland_surface,xwayland_surface_added)
 wl.listen(&s.xwayland.events.destroy,&s.xwayland_destroy,xwayland_destroyed)
 os.set_env("DISPLAY",s.xwayland.display_name)
 fmt.printf("XWayland reserved DISPLAY=%s (lazy, not ready)\n",s.xwayland.display_name)
}
xwayland_ready :: proc(l: ^wl.Listener, data: rawptr) {
 s := wl.owner(l,Server,"xwayland_ready")
 for &atom,i in s.x11_atoms { atom = s.xwayland.xwm.atoms[xw.Atom(i)] }
 fmt.printf("XWayland ready DISPLAY=%s pid=%d\n",s.xwayland.display_name,s.xwayland.pid)
}
xwayland_destroyed :: proc(l: ^wl.Listener, data: rawptr) {
 s := wl.owner(l,Server,"xwayland_destroy")
 wl.unlisten(&s.xwayland_ready); wl.unlisten(&s.new_xwayland_surface); wl.unlisten(l)
 s.xwayland = nil; os.set_env("DISPLAY",X11_UNAVAILABLE)
}
x11_configure_window :: proc(w: ^xw.Window, x,y,width,height: i32) -> bool {
 if x < -32768 || x > 32767 || y < -32768 || y > 32767 || width < 1 || width > 65535 || height < 1 || height > 65535 { return false }
 xw.configure(w,i16(x),i16(y),u16(width),u16(height)); return true
}
X11_TYPES :: [14]string{"desktop","dock","toolbar","menu","utility","splash","dialog","dropdown_menu","popup_menu","tooltip","notification","combo","dnd","normal"}
