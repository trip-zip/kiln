package compositor

import st "../seat"

import sp "../scene_paint"

import layout "../layout"

import auth "../authentication"
import "../keymap"
import vm "../lua_runtime"
import sh "../shells"
import wl "../wayland"
import wlr "../wlroots"
import "base:runtime"

Lock_Owner :: enum {
	Unlocked,
	Native,
	External,
}
Lock_Surface :: struct {
	server:                       ^Server,
	handle:                       ^sh.Lock_Surface,
	width, height:                i32,
	map_, unmap, destroy, commit: wl.Listener,
}
locked :: proc(s: ^Server) -> bool {return s.lock_owner != .Unlocked}
init_lock :: proc(s: ^Server) -> bool {
	manager := sh.lock_manager_create(s.display)
	if manager == nil {return false}
	wl.listen(&manager.events.new_lock, &s.new_lock, lock_added)
	return true
}
lock_cover :: proc(s: ^Server) {
	for o in s.outputs {
		if o.covered != locked(s) {
			o.covered = locked(s)
			sp.publish(&o.paint, nil)
			sp.output_invalidate(&o.paint)
		}
		if s.lock_owner == .External {
			parts := make([dynamic]sp.Part)
			defer delete(parts)
			for p in s.lock_surfaces {
				if p.handle.output != o.handle {continue}
				w, h := wlr.output_logical_size(o.handle)
				if p.width != w || p.height != h {
					p.width, p.height = w, h
					sh.lock_configure(p.handle, w, h)
				}
				if p.handle.surface.mapped {
					append(
						&parts,
						sp.Part{kind = .Client, surface = p.handle.surface, box = {0, 0, w, h}},
					)
				}
			}
			sp.publish(&o.paint, parts[:])
		}
	}
}
lock_reset_input :: proc(s: ^Server) {
	st.drag_cancel(s.seat)
	s.keyboard_epoch += 1
	s.pointer_epoch += 1
	s.keyboard_grabbed = false
	s.pointer_grabbed = false
	s.pointer_client = 0
	for kb in s.keyboards {
		keymap.compose_reset(kb.compose)
		for code in kb.consumed {kb.consumed[code] = true}
		for code in kb.keycodes[:] {kb.consumed[code] = true}
	}
	for code, consumed in s.buttons {
		if !consumed {st.pointer_notify_button(s.seat, 0, code, 0)}
		s.buttons[code] = true
	}
	sh.grab_dismiss(s.shell)
	st.keyboard_notify_clear_focus(s.seat)
	st.pointer_clear_focus(s.seat)
	constraint_sync(s)
}
lock_engage :: proc(s: ^Server, owner: Lock_Owner) {
	auth.cancel(&s.auth)
	wl.remove_source(s.quit_source)
	s.quit_source = nil
	s.lock_owner = owner
	s.lock_generation += 1
	s.authenticated = false
	for o in s.outputs {layout.inspector_cancel(&o.ui)}
	lock_reset_input(s)
	lock_cover(s)
	for o in s.outputs {lock_ui_clear(o)
		o.lock_presented = false
		o.lock_submitted = false
		dirty(o)}
	idle_recompute(s)
	kind := "native"
	if owner == .External {kind = "ext"}
	queue_event(
		s,
		vm.Event{class = "session", name = "lock", bytes = kind, generation = s.lock_generation},
	)
}
lock_disengage :: proc(s: ^Server) {
	auth.cancel(&s.auth)
	s.lock_owner = .Unlocked
	s.lock_generation += 1
	s.authenticated = false
	lock_reset_input(s)
	lock_cover(s)
	idle_recompute(s)
	for o in s.outputs {lock_ui_clear(o)
		dirty(o)}
	queue_event(s, vm.Event{class = "session", name = "unlock", generation = s.lock_generation})
	pointer_target_refresh(s)
}
runtime_lock :: proc(data: rawptr) -> bool {
	s := (^Server)(data)
	if locked(s) || s.lua.declaring {return false}
	lock_engage(s, .Native)
	return true
}
runtime_unlock :: proc(data: rawptr) -> bool {
	s := (^Server)(data)
	if !locked(s) {return true}
	if s.lua.declaring || s.lock_owner != .Native || !s.authenticated {return false}
	lock_disengage(s)
	return true
}
lock_maybe_ack :: proc(s: ^Server) {
	if s.lock_owner != .External || s.ext_lock == nil || s.lock_acknowledged {return}
	for o in s.outputs {if o.handle.enabled && !o.lock_presented {return}}
	s.lock_acknowledged = true
	sh.lock_acknowledge(s.ext_lock)
}
lock_presented :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	o := wl.owner(listener, Output, "present")
	e := (^wlr.wlr_output_event_present)(data)
	if !locked(o.server) || !o.lock_submitted || !e.presented {return}
	if i32(e.commit_seq - o.lock_commit_seq) < 0 {return}
	o.lock_presented = true
	lock_maybe_ack(o.server)
}
lock_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "new_lock")
	h := (^sh.Lock)(data)
	if locked(s) {sh.lock_reject(h)
		return}
	s.ext_lock = h
	s.lock_acknowledged = false
	wl.listen(&h.events.new_surface, &s.lock_new_surface, lock_surface_added)
	wl.listen(&h.events.unlock, &s.lock_unlock, lock_unlocked)
	wl.listen(&h.events.destroy, &s.lock_destroy, lock_destroyed)
	lock_engage(s, .External)
	lock_maybe_ack(s)
}
lock_detach :: proc(s: ^Server) {
	wl.unlisten(&s.lock_new_surface)
	wl.unlisten(&s.lock_unlock)
	wl.unlisten(&s.lock_destroy)
	s.ext_lock = nil
	s.lock_acknowledged = false
	for o in s.outputs {sp.publish(&o.paint, nil)
		sp.output_invalidate(&o.paint)}
}
lock_unlocked :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "lock_unlock")
	lock_detach(s)
	lock_disengage(s)
}
lock_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "lock_destroy")
	lock_detach(s)
	if !s.shutting_down {lock_engage(s, .Native)}
}
lock_focus :: proc(s: ^Server) {
	if s.lock_owner != .External {return}
	for p in s.lock_surfaces {
		if !p.handle.output.enabled || !p.handle.surface.mapped {continue}
		m: st.Modifiers
		// Empty enter prevents pre-lock held keys from becoming locker input.
		st.keyboard_enter(s.seat, p.handle.surface, nil, m)
		return
	}
	st.keyboard_notify_clear_focus(s.seat)
}
lock_surface_added :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	s := wl.owner(listener, Server, "lock_new_surface")
	p := new(Lock_Surface)
	p.server = s
	p.handle = (^sh.Lock_Surface)(data)
	append(&s.lock_surfaces, p)
	wl.listen(&p.handle.surface.events.commit, &p.commit, lock_surface_committed)
	wl.listen(&p.handle.events.destroy, &p.destroy, lock_surface_destroyed)
	wl.listen(&p.handle.surface.events.map_, &p.map_, lock_surface_mapped)
	wl.listen(&p.handle.surface.events.unmap, &p.unmap, lock_surface_unmapped)
	// Disabled outputs still need an initial configure to complete the role handshake.
	p.width, p.height = wlr.output_logical_size(p.handle.output)
	sh.lock_configure(p.handle, p.width, p.height)
	lock_cover(s)
}
lock_surface_committed :: proc (listener: ^wl.Listener, data: rawptr) {
	p := wl.owner(listener, Lock_Surface, "commit")
	if o := sp.get_scene_output(p.server.scene, p.handle.output);
	   o != nil {sp.output_invalidate(o)}
}
lock_surface_mapped :: proc (listener: ^wl.Listener, data: rawptr) {
	p := wl.owner(listener, Lock_Surface, "map_")
	lock_cover(p.server)
	lock_focus(p.server)
}
lock_surface_unmapped :: proc (listener: ^wl.Listener, data: rawptr) {
	p := wl.owner(listener, Lock_Surface, "unmap")
	lock_cover(p.server)
	lock_focus(p.server)
}
lock_surface_destroyed :: proc "c" (listener: ^wl.Listener, data: rawptr) {
	context = runtime.default_context()
	p := wl.owner(listener, Lock_Surface, "destroy")
	s := p.server
	wl.unlisten(&p.destroy)
	wl.unlisten(&p.map_)
	wl.unlisten(&p.unmap)
	for v, i in s.lock_surfaces {if v == p {ordered_remove(&s.lock_surfaces, i)
			break}}
	wl.unlisten(&p.commit)
	lock_cover(s)
	free(p)
	if !s.shutting_down {lock_focus(s)}
}
lock_input :: proc(s: ^Server, e: ^vm.Event) -> bool {
	if e.name == "request::activate" ||
	   e.name == "request::move" ||
	   e.name == "request::resize" {return locked(s) || e.lock_generation != s.lock_generation}
	input := e.class == "input" || e.native != .None || (e.class == "session" && e.name == "key")
	if !input {return false}
	if e.lock_generation != s.lock_generation {
		if !e.pressed {
			if e.native ==
			   .Key {if kb := find_keyboard(s, e.keyboard); kb != nil {delete_key(&kb.consumed, e.code)}} else if e.native == .Button {delete_key(&s.buttons, e.code)}
		}
		return true
	}
	if !locked(s) {return false}
	kb := find_keyboard(s, e.keyboard)
	if kb == nil {return true}
	if e.name == "key" || e.native == .Key {
		if kb.consumed[e.code] {
			if !e.pressed {delete_key(&kb.consumed, e.code)}
			return true
		}
		if e.pressed {kb.consumed[e.code] = false} else {delete_key(&kb.consumed, e.code)}
		if s.lock_owner == .Native &&
		   e.class ==
			   "session" {vm.deliver(&s.lua, e)} else if s.lock_owner == .External && e.native == .Key && s.seat.keyboard_state.focused_surface != nil {
			st.set_keyboard(s.seat, &kb.keyboard)
			st.keyboard_notify_key(s.seat, e.time, e.code, u32(e.pressed))
		}
	} else if e.native == .Modifiers && s.lock_owner == .External {
		m := st.Modifiers{e.mask[0], e.mask[1], e.mask[2], e.mask[3]}
		st.set_keyboard(s.seat, &kb.keyboard)
		st.keyboard_notify_modifiers(s.seat, &m)
	}
	return true
}
