package compositor

import xw "../xwayland"

import sh "../shells"

import ext "../extensions"


import layout "../layout"
import vm "../lua_runtime"
import wl "../wayland"
import wlr "../wlroots"
import xcb "../xcb"
import "base:runtime"
import "core:fmt"
import "core:sys/posix"

runtime_eval :: proc(data: rawptr, source: string) -> string {
	return vm.evaluate(&(^Server)(data).lua, source)
}
request_quit :: proc(data: rawptr) {
	s := (^Server)(data)
	if s.quit_source == nil {
		s.quit_source = wl.on_idle(s.display, quit_idle, s)
		if s.quit_source == nil {fail(s, "Cannot schedule quit")}
	}
}
quit_idle :: proc(data: rawptr) {
	s := (^Server)(data)
	s.quit_source = nil
	wl.terminate(s.display)
}
runtime_output :: proc(data: rawptr, index: int) -> (vm.Output, bool) {
	s := (^Server)(data)
	if index >= len(s.outputs) {return {}, false}
	// Enumerate newest outputs first, matching discovery order.
	w := s.outputs[len(s.outputs) - 1 - index].handle
	box: wlr.wlr_box
	wlr.wlr_output_layout_get_box(s.layout, w, &box)
	name := string(w.name)
	o := vm.Output {
		name    = name[:min(len(name), 63)],
		width   = w.width,
		height  = w.height,
		refresh = w.refresh,
		scale   = f64(w.scale),
		enabled = w.enabled,
		x       = box.x,
		y       = box.y,
	}
	o.logical_width, o.logical_height = box.width, box.height
	it := wl.iterate(&w.modes)
	for link, ok := wl.next(&it); ok && o.mode_count < len(o.modes); link, ok = wl.next(&it) {
		m := runtime.container_of(link, wlr.wlr_output_mode, "link")
		o.modes[o.mode_count] = {m.width, m.height, m.refresh}
		o.mode_count += 1
	}
	return o, true
}

runtime_dirty :: proc(data: rawptr, name: string, all: bool) {
	s := (^Server)(data)
	for output in s.outputs {
		if all || string(output.handle.name) == name {dirty(output)}
	}
}
runtime_layout :: proc(data: rawptr, name: string) -> (^layout.Layout, i32, i32) {
	s := (^Server)(data)
	for output in s.outputs {
		if string(output.handle.name) == name {
			box: wlr.wlr_box
			wlr.wlr_output_layout_get_box(s.layout, output.handle, &box)
			return &output.ui, box.x, box.y
		}
	}
	return nil, 0, 0
}
runtime_client :: proc(data: rawptr, handle: u32, screen: string) -> bool {
	if l := find_layer((^Server)(data), handle); l != nil {return l.mapped}
	for view in (^Server)(data).views {
		if view.id == handle {return view.mapped}
	}
	return false
}

runtime_replay :: proc(data: rawptr) {
	s := (^Server)(data)
	seen := make(map[u32]bool)
	defer delete(seen)
	// Parents must exist in the replacement registry when dialog rules run.
	for {
		progress := false
		for view in s.views {
			if !view.mapped || seen[view.id] {continue}
			waiting := false
			for parent in s.views {
				if parent.id == view_parent(view) &&
				   parent.mapped &&
				   !seen[parent.id] {waiting = true
					break}
			}
			if waiting {continue}
			seen[view.id] = true
			queue_client(view, "map", true)
			if x := x11(view); x != nil {x11_urgency(x)}
			progress = true
		}
		if !progress {break}
	}
}
runtime_discover :: proc(data: rawptr) {
	for output in (^Server)(data).outputs {queue_output(output, "add")}
}
runtime_focus :: proc(data: rawptr, handle: u32) {
	s := (^Server)(data)
	if locked(s) {return}
	if handle == 0 {s.requested_focus = 0
		clear_focus(s)
		return}
	if l := find_layer(s, handle); l != nil && l.handle.initialized {
		if s.requested_focus != handle {clear_focus(s)}
		s.requested_focus = handle
		if l.mapped &&
		   client_visible(l.output, l.id) &&
		   l.output != nil &&
		   l.output.handle.enabled {enter_surface(s, l.handle.surface)}
		return
	}
	for view in s.views {
		if view.id != handle || !view.mapped {continue}
		s.requested_focus = handle
		if s.focused != view {clear_focus(s)}
		if view.output != nil &&
		   view.output.handle.enabled &&
		   client_visible(view.output, view.id) {focus(view)}
		return
	}
}
runtime_activate :: proc(data: rawptr, handle: u32, on: bool) {
	if locked((^Server)(data)) {return}
	for view in (^Server)(data).views {
		if view.id == handle && view.mapped {ext.foreign_activated(view.foreign_handle, on)
			view_activate(view, on)
			return}
	}
}
runtime_focused :: proc(data: rawptr) -> u32 {
	s := (^Server)(data)
	if s.seat == nil {return 0}
	for l in s.layers {if l.mapped && l.handle.surface == s.seat.keyboard_state.focused_surface {return l.id}}
	for p in s.popups {if p.mapped && p.handle.base.surface == s.seat.keyboard_state.focused_surface {return p.root}}
	for view in s.views {
		if view.mapped &&
		   view_surface(view) == s.seat.keyboard_state.focused_surface {return view.id}
	}
	return 0
}

runtime_close :: proc(data: rawptr, handle: u32) {
	for view in (^Server)(data).views {
		if view.id == handle {view_close(view)
			return}
	}
}
runtime_kill :: proc(data: rawptr, handle: u32) {
	for view in (^Server)(data).views {
		if view.id != handle {continue}
		if x := x11(view); x != nil {
			if !xcb.kill_client(
				xw.connection(view.server.xwayland),
				x.handle.window_id,
			) {fmt.eprintln("X11 kill failed: no live XWM connection")}
			return
		}
		pid := posix.pid_t(wl.client_pid(view_surface(view).resource))
		if pid > 0 && pid != posix.getpid() {posix.kill(pid, .SIGKILL)}
		return
	}
}
// A policy focus may be waiting for its first successful declaration.
runtime_focus_target :: proc(data: rawptr) -> u32 {
	s := (^Server)(data)
	if l := find_layer(s, s.requested_focus); l != nil && l.handle.initialized {return l.id}
	for view in s.views {
		if view.id == s.requested_focus && view.mapped {return view.id}
	}
	return runtime_focused(data)
}

runtime_fullscreen :: proc(data: rawptr, handle: u32, on: bool) {
	for view in (^Server)(data).views {
		if view.id == handle && view.mapped {ext.foreign_fullscreen(view.foreign_handle, on)
			view_fullscreen_hint(view, on)
			return}
	}
}
runtime_maximize :: proc(data: rawptr, handle: u32, on: bool) {
	for view in (^Server)(data).views {
		if view.id == handle && view.mapped {ext.foreign_maximized(view.foreign_handle, on)
			view_maximize_hint(view, on)
			return}
	}
}
runtime_suspend :: proc(data: rawptr, handle: u32, on: bool) {
	for view in (^Server)(data).views {
		if view.id == handle &&
		   view.mapped &&
		   xdg(view) != nil &&
		   wl.resource_version(xdg(view).resource) >= 6 {
			sh.set_suspended(xdg(view), on)
			return
		}
	}
}

runtime_request_reload :: proc(data: rawptr) {
	queue_event((^Server)(data), vm.Event{class = "reload"})
}

runtime_minimize :: proc(data: rawptr, handle: u32, on: bool) {
	for v in (^Server)(data).views {if v.id == handle && v.mapped {ext.foreign_minimized(v.foreign_handle, on)
			if x := x11(v); x != nil {x.granted_minimized = on
				xw.set_minimized(x.handle, on)}
			return}}
}

runtime_client_configure :: proc(data: rawptr, handle: u32, width, height: i32) {
	for v in (^Server)(data).views {
		if v.id != handle {continue}
		if t := xdg(v); t != nil {
			sh.set_size(t, width, height)
		} else if x := x11(v); x != nil && !view_override_redirect(v) {
			px, py: i32
			view_position(v, &px, &py)
			if !x11_configure_window(x.handle, px, py, width, height) {
				fmt.eprintln(
					"X11 requested geometry exceeds protocol limits; retaining last X geometry",
				)
			}
		}
		return
	}
}

runtime_client_tiled :: proc(data: rawptr, handle, edges: u32) {
	for v in (^Server)(data).views {
		if v.id != handle {continue}
		if t := xdg(v); t != nil && wl.resource_version(t.resource) >= 2 {
			sh.set_tiled(t, edges)
		}
		return
	}
}

runtime_client_mirror :: proc(data: rawptr, handle: u32, name: string) {
	s := (^Server)(data)
	for v in s.views {
		if v.id != handle || v.foreign_handle == nil {continue}
		target: ^Output
		for output in s.outputs {
			if string(output.handle.name) == name {target = output
				break}
		}
		foreign_place(v, target)
		return
	}
}
