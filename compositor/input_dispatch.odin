package compositor

import st "../seat"

import vm "../lua_runtime"
import "../keymap"

runtime_grab_keyboard :: proc(data: rawptr, on: bool) {
	s:=(^Server)(data)
    if locked(s) && on { return }
	if s.keyboard_grabbed==on { return }
	s.keyboard_epoch+=1
	s.keyboard_grabbed=on
	if on {
		// Leave cancels client-held keys. Quarantine them until physical release.
		for kb in s.keyboards {
			for code in kb.consumed { kb.consumed[code]=true }
			for code in kb.keycodes[:] { kb.consumed[code]=true }
		}
		st.keyboard_notify_clear_focus(s.seat)
	} else if !s.shutting_down { runtime_focus(s,s.requested_focus) }
}
runtime_grab_pointer :: proc(data: rawptr, on: bool) {
	s:=(^Server)(data)
    if locked(s) && on { return }
	if s.pointer_grabbed==on { return }
	s.pointer_epoch+=1
	if on {
		// Finish delivered presses before dropping focus and the implicit grab.
		for code, consumed in s.buttons {
			if !consumed { st.pointer_notify_button(s.seat,0,code,0) }
			s.buttons[code]=true
		}
		st.pointer_notify_frame(s.seat)
		s.pointer_grabbed=true
		st.pointer_clear_focus(s.seat)
		if s.pointer_client!=0 {
			s.pointer_client=0
			queue_event(s,vm.Event{class="input",name="pointer_enter"})
		}
	} else {
		s.pointer_grabbed=false
		if !s.shutting_down {
			runtime_cursor(s,"default")
			pointer_refresh(s,0)
			queue_pointer(s,vm.Event{name="motion"})
		}
	}
}
find_keyboard :: proc(s: ^Server, id: u64) -> ^Keyboard {
	for kb in s.keyboards { if kb.id==id { return kb } }
	return nil
}
// Lua resolves policy outside native emissions, before this event can forward.
dispatch_input :: proc(s: ^Server, event: ^vm.Event) {
	e:=event
    if lock_input(s,e) { return }
	if e.native==.DeviceMotion { device_motion(s,e);return }
    current: vm.Event
    if e.native==.Button || e.native==.Axis {
        // Position follows earlier device motion; the queued payload keeps ownership.
        current=e^;pointer_fact(s,&current);current.mods=e.mods;e=&current
    }
	if e.native == .Button && e.pressed {
		surface, _, _, _ := hit_test(s,e.px,e.py)
		if popup_press(s,surface) { s.buttons[e.code] = true; return }
	}
	inspector_consumed:=!e.blocked && !s.pointer_grabbed && inspector_input(s,e)
    if inspector_consumed { pointer_refresh_at(s,e.time,e.px,e.py,false);e.blocked=true;e.claimed=true }
    if e.native==.Button && !e.pressed && s.buttons[e.code] { e.blocked=true;e.claimed=true }
	// A queued event crossing a claim transition cannot replay into lower policy.
	key_epoch,pointer_epoch:=s.keyboard_epoch,s.pointer_epoch
	if e.keyboard!=0 && e.routing_epoch!=key_epoch { e.claimed=true; e.blocked=true }
	else if e.native!=.None && e.keyboard==0 && e.routing_epoch!=pointer_epoch { e.claimed=true; e.blocked=true }
	key_blocked,pointer_blocked:=s.keyboard_grabbed,s.pointer_grabbed
	matched:=e.name=="key" && keymap.bound(s.lua.bindings,e.keysym,e.mods)
	if e.native==.Motion && !s.pointer_grabbed && !e.native_surface { runtime_cursor(s,"default") }
	if e.name!="" && (!inspector_consumed || e.native==.Motion) { vm.deliver(&s.lua,e) }
	if s.shutting_down { return }
	kb:=find_keyboard(s,e.keyboard)
	key_blocked=key_blocked || s.keyboard_grabbed || key_epoch!=s.keyboard_epoch || e.blocked
	pointer_blocked=pointer_blocked || s.pointer_grabbed || pointer_epoch!=s.pointer_epoch || e.blocked
	switch e.native {
	case .None,.DeviceMotion:
	case .Key:
		if kb==nil { return }
		if e.pressed {
			previous,held:=kb.consumed[e.code]
			consumed:=key_blocked || matched || (held && previous)
			kb.consumed[e.code]=consumed
			if consumed { return }
		} else {
			consumed,held:=kb.consumed[e.code]
			delete_key(&kb.consumed,e.code)
			if !held || consumed || key_blocked { return }
		}
		st.set_keyboard(s.seat,&kb.keyboard)
		st.keyboard_notify_key(s.seat,e.time,e.code,u32(e.pressed))
	case .Modifiers:
		if kb==nil || key_blocked { return }
		m:=st.Modifiers{e.mask[0],e.mask[1],e.mask[2],e.mask[3]}
		st.set_keyboard(s.seat,&kb.keyboard)
		st.keyboard_notify_modifiers(s.seat,&m)
	case .Motion:
		if !pointer_blocked { pointer_refresh_at(s,e.time,e.px,e.py,false) }
	case .Button:
		if e.pressed {
			was,held:=s.buttons[e.code]
			consumed:=pointer_blocked || (held && was)
			s.buttons[e.code]=consumed
			if consumed { return }
		} else {
			consumed,held:=s.buttons[e.code]
			delete_key(&s.buttons,e.code)
			if !held || consumed || pointer_blocked { return }
		}
		pointer_refresh_at(s,e.time,e.px,e.py,false)
		st.pointer_notify_button(s.seat,e.time,e.code,i32(e.pressed))
        // A protocol grab can defer an already selected target until dismissal.
        if !s.keyboard_grabbed && runtime_focused(s)!=s.requested_focus { runtime_focus(s,s.requested_focus) }
	case .Axis:
		if pointer_blocked { return }
		pointer_refresh_at(s,e.time,e.px,e.py,false)
		st.pointer_notify_axis(s.seat,e.time,e.orientation,e.delta,e.discrete,e.source,e.direction)
	case .Frame:
		if !pointer_blocked { st.pointer_notify_frame(s.seat) }
	}
}
