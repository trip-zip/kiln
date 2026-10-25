package compositor

import st "../seat"

import "base:runtime"
import "core:fmt"
import "core:strings"
import "../keymap"
import cfg "../input_config"
import wl "../wayland"
import wlr "../wlroots"

Pointer :: struct {
	server:  ^Server,
	device:  ^wlr.wlr_input_device,
	id:      u64,
	destroy, motion, absolute, button, axis, frame: wl.Listener,
	output: ^Output,
}

pointer_destroy :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	p := wl.owner(listener, Pointer, "destroy")
	wl.unlisten(listener)
	for l in ([]^wl.Listener{&p.motion, &p.absolute, &p.button, &p.axis, &p.frame}) { wl.unlisten(l) }
	for other, i in p.server.pointers {
		if other == p {
			ordered_remove(&p.server.pointers, i)
			break
		}
	}
	cursor_sync(p.server)
	free(p)
}

runtime_keymap :: proc(data: rawptr, names: keymap.Names) {
	km := keymap.create(names)
	if km == nil {
		fmt.eprintln("set_keymap: xkb rejected the rule names")
		return
	}
	defer keymap.destroy(km)
	for kb in (^Server)(data).keyboards {
		if !st.keyboard_set_keymap( &kb.keyboard, km, ) {fmt.eprintln("set_keymap: keyboard rejected map")}
	}
}

runtime_repeat :: proc(data: rawptr, rate, delay: i32) {
	for kb in (^Server)(data).keyboards {st.keyboard_set_repeat_info(&kb.keyboard, rate, delay)}
}

runtime_numlock :: proc(data: rawptr, on: bool) {
	for kb in (^Server)(data).keyboards {
		m := kb.modifiers
		locked := keymap.numlock_mask(kb.state, m.locked, on)
		st.keyboard_set_modifiers(&kb.keyboard, m.depressed, m.latched, locked, m.group)
	}
}

runtime_pointer :: proc(data: rawptr, p: cfg.Pointer) {
	for pointer in (^Server)(data).pointers {cfg.apply(pointer.device, p)}
}

runtime_cursor :: proc(data: rawptr, name: cstring) {
	s := (^Server)(data)
	copy := strings.clone_to_cstring(string(name))
	if s.cursor_name != nil {delete(s.cursor_name, s.cursor_name_allocator)}
	s.cursor_name = copy
	s.cursor_name_allocator = context.allocator
	s.cursor_named = true
	cursor_surface_set(s, nil, 0, 0)
	cursor_density(s)
}

cursor_theme_ready :: proc(manager: ^st.Cursor_Manager, scale: f32) -> bool {
	return(
		st.xcursor_manager_load(manager, scale) &&
		st.xcursor_manager_get_xcursor(manager, "default", scale) != nil \
	)
}

runtime_cursor_theme :: proc(data: rawptr, name: cstring, size: u32) {
	s := (^Server)(data)
	next := st.xcursor_manager_create(name, size)
	if next == nil {return}
	if !cursor_theme_ready(next, 1) {
		st.xcursor_manager_destroy(next)
		return
	}
	for output in s.outputs {
		if !cursor_theme_ready(next, output.handle.scale) {
			st.xcursor_manager_destroy(next)
			return
		}
	}
	old := s.cursor_manager
	s.cursor_manager = next
	if s.cursor_named {runtime_cursor(s, s.cursor_name)}
	st.xcursor_manager_destroy(old)
}

map_pointers :: proc(s: ^Server) {
	for p in s.pointers {
		handle := wlr.wlr_pointer_from_input_device(p.device)
		p.output = nil
		if handle.output_name == nil {continue}
		for o in s.outputs {
			if string(o.handle.name) == string(handle.output_name) {
				p.output = o
				break
			}
		}
	}
}

cursor_density :: proc(s: ^Server) {
	cursor_sync(s)
	if !s.cursor_named || s.cursor_manager == nil {return}
	for o in s.outputs {
		cursor := st.xcursor_manager_get_xcursor(
			s.cursor_manager,
			s.cursor_name,
			o.handle.scale,
		)
		if cursor != nil && len(cursor.images) > 0 {
			frame := cursor.images[0]
			fmt.printf(
				"Cursor raster %s: %s scale %.3f device %dx%d\n",
				o.handle.name,
				s.cursor_name,
				o.handle.scale,
				frame.width,
				frame.height,
			)
		}
	}
}
