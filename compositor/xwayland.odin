package compositor

import "base:runtime"
import "core:fmt"
import "core:os"
import xcb "../xcb"
import wl "../wayland"
import wlr "../wlroots"

// An invalid display must not fall back to the host's default X server.
X11_UNAVAILABLE :: "kiln-x11-unavailable"

init_xwayland :: proc(s: ^Server, compositor: ^wlr.wlr_compositor) {
    os.set_env("DISPLAY",X11_UNAVAILABLE)
    s.xwayland=wlr.xwayland_create(s.display,compositor)
    if s.xwayland==nil {
        fmt.eprintln("XWayland creation failed; native Wayland remains available")
        return
    }
    wl.listen(&s.xwayland.events.ready,&s.xwayland_ready,xwayland_ready)
    wl.listen(&s.xwayland.events.new_surface,&s.new_xwayland_surface,xwayland_surface_added)
    wl.listen(&s.xwayland.events.destroy,&s.xwayland_destroy,xwayland_destroyed)
    wl.listen(&s.xwayland.server.events.start,&s.xwayland_start,xwayland_started)
    os.set_env("DISPLAY",string(s.xwayland.display_name))
    fmt.printf("XWayland reserved DISPLAY=%s (lazy, not ready)\n",s.xwayland.display_name)
}

xwayland_started :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"xwayland_start")
    s.xwayland_polls=0
    if s.xwayland_watch==nil { s.xwayland_watch=wl.on_timer(s.display,xwayland_check_start,s) }
    if s.xwayland_watch!=nil { wl.arm_timer(s.xwayland_watch,25) }
}
xwayland_check_start :: proc "c" (data: rawptr) -> i32 {
    context=runtime.default_context()
    s:=(^Server)(data)
    s.xwayland_polls+=1
    if s.xwayland==nil || s.xwayland.server==nil || s.xwayland.server.display<0 {
        os.set_env("DISPLAY",X11_UNAVAILABLE)
        fmt.eprintln("XWayland startup failed; child DISPLAY disabled, native Wayland remains available")
    } else if !s.xwayland.server.ready && s.xwayland_polls<400 {
        wl.arm_timer(s.xwayland_watch,25)
        return 0
    } else if !s.xwayland.server.ready {
        fmt.eprintln("XWayland readiness timed out; supervision remains with wlroots")
    }
    wl.remove_source(s.xwayland_watch);s.xwayland_watch=nil
    return 0
}
xwayland_ready :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"xwayland_ready")
    wlr.xwayland_seat(s.xwayland,s.seat)
    connection:=wlr.xwayland_connection(s.xwayland)
    for name,i in X11_ATOMS { s.x11_atoms[i]=xcb.intern(connection,name) }
    wl.remove_source(s.xwayland_watch);s.xwayland_watch=nil
    fmt.printf("XWayland ready DISPLAY=%s seat=%v launcher_pid=%d (wlroots reaped)\n",
        s.xwayland.display_name,s.xwayland.seat==s.seat,s.xwayland.server.pid)
}
xwayland_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
    context=runtime.default_context()
    s:=wl.owner(listener,Server,"xwayland_destroy")
    wl.unlisten(&s.xwayland_ready)
    wl.unlisten(&s.new_xwayland_surface)
    wl.unlisten(&s.xwayland_start)
    wl.unlisten(&s.xwayland_destroy)
    wl.remove_source(s.xwayland_watch);s.xwayland_watch=nil
    s.xwayland=nil
    os.set_env("DISPLAY",X11_UNAVAILABLE)
}

X11_TYPES :: [14]string{"desktop","dock","toolbar","menu","utility","splash","dialog","dropdown_menu","popup_menu","tooltip","notification","combo","dnd","normal"}
X11_ATOMS :: [21]string{
    "_NET_WM_WINDOW_TYPE_DESKTOP","_NET_WM_WINDOW_TYPE_DOCK","_NET_WM_WINDOW_TYPE_TOOLBAR","_NET_WM_WINDOW_TYPE_MENU",
    "_NET_WM_WINDOW_TYPE_UTILITY","_NET_WM_WINDOW_TYPE_SPLASH","_NET_WM_WINDOW_TYPE_DIALOG","_NET_WM_WINDOW_TYPE_DROPDOWN_MENU",
    "_NET_WM_WINDOW_TYPE_POPUP_MENU","_NET_WM_WINDOW_TYPE_TOOLTIP","_NET_WM_WINDOW_TYPE_NOTIFICATION","_NET_WM_WINDOW_TYPE_COMBO",
    "_NET_WM_WINDOW_TYPE_DND","_NET_WM_WINDOW_TYPE_NORMAL","WM_WINDOW_ROLE","_NET_WM_ICON",
    "_NET_WM_STATE","_NET_WM_STATE_FULLSCREEN","_NET_WM_STATE_MAXIMIZED_VERT","_NET_WM_STATE_MAXIMIZED_HORZ","_NET_WM_STATE_HIDDEN",
}
