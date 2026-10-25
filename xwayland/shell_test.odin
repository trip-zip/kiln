package xwayland

import "core:testing"
import "core:sys/linux"
import wl "../wayland"
import p "../protocols"

@(test)
serial_pairing_waits_for_commit_in_both_orders :: proc(t: ^testing.T) {
	for shell_first in ([2]bool{false,true}) {
		display := wl.display_create(); defer wl.display_destroy(display)
		server := Server{display=display}
		m := Xwm{server=&server, windows=make(map[u32]^Window)}; server.xwm=&m; defer delete(m.windows)
		w := Window{xwm=&m,window_id=1}
		for &signal in (cast([^]wl.Signal)&w.events)[:size_of(w.events)/size_of(wl.Signal)] { wl.signal_init(&signal) }
		m.windows[1]=&w
		surface: Surface
		wl.signal_init(&surface.events.destroy); wl.signal_init(&surface.events.commit)
		s := Shell_Surface{server=&server,surface=&surface,pending=42}
		append(&server.shells,&s); defer delete(server.shells)
		if shell_first {
			shell_commit(&s); testing.expect(t,w.surface==nil)
			w.serial=42; pair_window(&w)
		} else {
			w.serial=42; pair_window(&w); testing.expect(t,w.surface==nil)
			shell_commit(&s)
		}
		testing.expect(t,w.surface==&surface && s.window==&w && s.committed)
		wl.unlisten(&w.surface_destroy); wl.unlisten(&w.surface_commit)
	}
}

@(test)
shell_permissions_and_invalid_serials_are_protocol_errors :: proc(t: ^testing.T) {
	for mode in 0..<4 {
		d := wl.display_create(); defer wl.display_destroy(d)
		fds: [2]linux.Fd; testing.expect(t,linux.socketpair(.UNIX,.STREAM,{},&fds)==.NONE)
		c := wl.client_create(d,i32(fds[0])); defer wl.client_destroy(c); defer linux.close(fds[1])
		s := Server{display=d,last_serial=8}
		if mode==0 {
			g := wl.Global{data=&s}; shell_bind(&g,c,1,2); testing.expect(t,c.failed); continue
		}
		shell := Shell_Surface{server=&s,committed=mode==3}
		r := wl.resource_create_typed(c,&p.xwayland_surface_v1,1,2,&shell,shell_surface_request,shell_surface_release)
		shell.resource=r
		serial := u32(0) if mode==1 else (7 if mode==2 else 9)
		shell_surface_request(r,.set_serial,[]wl.Argument{wl.Uint(serial),wl.Uint(0)})
		testing.expect(t,c.failed)
	}
}

@(test)
pending_serial_replacement_and_object_destruction_preserve_committed_pair :: proc(t: ^testing.T) {
	d := wl.display_create(); defer wl.display_destroy(d)
	fds: [2]linux.Fd; testing.expect(t,linux.socketpair(.UNIX,.STREAM,{},&fds)==.NONE)
	c := wl.client_create(d,i32(fds[0])); defer wl.client_destroy(c); defer linux.close(fds[1])
	server := Server{display=d}
	s := Shell_Surface{server=&server}
	r := wl.resource_create_typed(c,&p.xwayland_surface_v1,1,2,&s,shell_surface_request,shell_surface_release)
	s.resource = r
	shell_surface_request(r,.set_serial,[]wl.Argument{wl.Uint(1),wl.Uint(2)})
	testing.expect(t,s.pending == (u64(2)<<32|1) && s.serial == 0 && !s.committed)
	shell_surface_request(r,.set_serial,[]wl.Argument{wl.Uint(2),wl.Uint(2)})
	testing.expect(t,!c.failed && s.pending == (u64(2)<<32|2))
	shell_commit(&s)
	testing.expect(t,s.serial == (u64(2)<<32|2) && s.pending == 0 && s.committed)
	w: Window; s.window=&w
	wl.resource_destroy(r)
	testing.expect(t,s.window == &w && s.committed && s.resource == nil)
}
