package xwayland

import "core:testing"
import wl "../wayland"

@(test)
hints_and_class_are_bounded_and_owned :: proc(t: ^testing.T) {
	testing.expect(t, parse_hints(nil).input)
	words := [9]u32{1|2|256,0,3,0,0,0,0,0,0}
	h := parse_hints(words[:]); testing.expect(t, !h.input && urgent(h) && h.initial_state==3)
	words[0] = 256; testing.expect(t, parse_hints(words[:]).input)
	bytes := []u8{'a',0,'B',0,'x'}
	instance,class := parse_class(bytes); defer delete(instance); defer delete(class)
	bytes[0]='z'; testing.expect_value(t,instance,"a"); testing.expect_value(t,class,"B")
	hi,hc := class_presence([]u8{0}); testing.expect(t,hi && hc)
	hi,hc = class_presence(nil); testing.expect(t,!hi && !hc)
	i,c := parse_class([]u8{'b','a','d'}); defer delete(i); defer delete(c)
	testing.expect_value(t,i,""); testing.expect_value(t,c,"bad")
}

@(test)
state_requests_decode_both_atoms_and_reject_invalid_actions :: proc(t: ^testing.T) {
	m: Xwm; m.atoms[.Fullscreen]=1; m.atoms[.Max_Vert]=2; m.atoms[.Max_Horz]=3; m.atoms[.Hidden]=4
	w := Window{xwm=&m}
	for &signal in (cast([^]wl.Signal)&w.events)[:size_of(w.events)/size_of(wl.Signal)] { wl.signal_init(&signal) }
	state_request(&w,1,[]u32{2,3}); testing.expect(t,w.maximized_vert && w.maximized_horz)
	state_request(&w,2,[]u32{1,1}); testing.expect(t,w.fullscreen)
	state_request(&w,4,[]u32{1,4}); testing.expect(t,w.fullscreen && !w.minimized)
	state_request(&w,0,[]u32{1,2}); testing.expect(t,!w.fullscreen && !w.maximized_vert && w.maximized_horz)
	state_request(&w,1,[]u32{4,0}); testing.expect(t,w.minimized)
}
