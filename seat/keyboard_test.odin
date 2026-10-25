package seat

import bk "../backend"
import wl "../wayland"
import keys "../keymap"
import "core:testing"

@(test)
keyboard_backend_events_own_state_and_ignore_duplicate_transitions :: proc(t: ^testing.T) {
	backend: bk.Keyboard
	wl.signal_init(&backend.events.key); wl.signal_init(&backend.base.events.destroy)
	a,b: Keyboard
	keyboard_init(&a,&backend); keyboard_init(&b,nil)
	defer keyboard_finish(&b)
	km,ok := keys.create_default(); assert(ok); defer keys.destroy(km)
	assert(keyboard_set_keymap(&a,km) && keyboard_set_keymap(&b,km))
	Probe :: struct { key,mods,destroy: wl.Listener, before: u32, changed, destroyed: bool }
	probe: Probe
	wl.listen(&a.events.key,&probe.key,proc(l: ^wl.Listener,data: rawptr) {
		p := wl.owner(l,Probe,"key")
		p.before += 1
	})
	wl.listen(&a.events.modifiers,&probe.mods,proc(l: ^wl.Listener,data: rawptr) { wl.owner(l,Probe,"mods").changed = true })
	wl.listen(&a.events.destroy,&probe.destroy,proc(l: ^wl.Listener,data: rawptr) { wl.owner(l,Probe,"destroy").destroyed = true })
	defer wl.unlisten(&probe.key); defer wl.unlisten(&probe.mods); defer wl.unlisten(&probe.destroy)
	press := bk.Key_Event{keycode=42,state=1}
	wl.signal_emit_mutable(&backend.events.key,&press)
	wl.signal_emit_mutable(&backend.events.key,&press)
	testing.expect(t,probe.changed && probe.before == 2 && len(a.keycodes) == 1)
	testing.expect(t,keys.modifier_mask(a.state)&1 != 0 && keys.modifier_mask(b.state) == 0)
	press.state = 0
	wl.signal_emit_mutable(&backend.events.key,&press)
	testing.expect(t,keys.modifier_mask(a.state)&1 == 0 && len(a.keycodes) == 0)
	wl.signal_emit_mutable(&backend.base.events.destroy,&backend)
	testing.expect(t,probe.destroyed && a.state == nil && a.keymap_fd == -1)
	testing.expect(t,wl.empty(&backend.events.key.listener_list) && wl.empty(&backend.base.events.destroy.listener_list))
}

@(test)
seat_serial_window_uses_display_counter_and_wraps :: proc(t: ^testing.T) {
	d := wl.Display{serial=max(u32)-1}
	s := Seat{display=&d}
	c := Client{seat=&s}
	testing.expect_value(t,next_serial(&c),max(u32))
	testing.expect_value(t,next_serial(&c),u32(1))
	testing.expect(t,valid_serial(&c,max(u32)) && valid_serial(&c,1) && !valid_serial(&c,0) && !valid_serial(&c,2))
	wl.next_serial(&d)
	testing.expect_value(t,next_serial(&c),u32(3))
	testing.expect(t,!valid_serial(&c,2),"another display user's serial is not in the client window")
}

@(test)
keyboard_leds_follow_xkb_lock_transitions :: proc(t: ^testing.T) {
	backend: bk.Keyboard
	wl.signal_init(&backend.events.key); wl.signal_init(&backend.base.events.destroy)
	kb: Keyboard; keyboard_init(&kb,&backend); defer keyboard_finish(&kb)
	km,ok:=keys.create_default(); assert(ok); defer keys.destroy(km)
	assert(keyboard_set_keymap(&kb,km))
	for code,bit in ([2]u32{58,69}) {
		e:=bk.Key_Event{keycode=code,state=1}
		keyboard_update_key(&kb,&e); e.state=0; keyboard_update_key(&kb,&e)
		testing.expect(t,kb.leds&(2 if bit==0 else 1) != 0)
		e.state=1; keyboard_update_key(&kb,&e); e.state=0; keyboard_update_key(&kb,&e)
		testing.expect(t,kb.leds&(2 if bit==0 else 1) == 0)
	}
}
