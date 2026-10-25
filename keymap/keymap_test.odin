package keymap

import "core:testing"
import raw "../xkbcommon"

@(test)
symbol_names_and_text :: proc(t: ^testing.T) {
	name: [128]u8
	utf8: [8]u8
	n, u := describe(97, name[:], utf8[:])
	testing.expect_value(t, n, "a")
	testing.expect_value(t, u, "a")
	n, u = describe(ESCAPE, name[:], utf8[:])
	testing.expect_value(t, n, "Escape")
	testing.expect_value(t, u, "\x1b")
}

@(test)
exact_chords_and_held_key_ownership :: proc(t: ^testing.T) {
	bindings := []Chord{{97, 64}, {49, 65}}
	testing.expect(t, bound(bindings, 97, 64))
	testing.expect(t, bound(bindings, 97, 64|2|16))
	testing.expect(t, !bound(bindings, 97, 65))
	held := make(map[u32]bool)
	second := make(map[u32]bool)
	defer delete(held)
	defer delete(second)
	testing.expect(t, consume(&held, 30, true, true))
	testing.expect(t, !consume(&second, 30, false, false))
	testing.expect(t, !consume(&held, 30+256, false, false))
	testing.expect(t, consume(&held, 30, true, false))
	testing.expect(t, consume(&held, 30, false, false))
	testing.expect(t, !consume(&held, 30, false, true))
}

@(test)
base_level_chords_keep_shifted_text :: proc(t: ^testing.T) {
	km, ok := create_default()
	testing.expect(t, ok)
	if !ok { return }
	defer destroy(km)
	state := raw.xkb_state_new(km)
	testing.expect(t, state != nil)
	if state == nil { return }
	defer raw.xkb_state_unref(state)
	raw.xkb_state_update_mask(state, 1, 0, 0, 0, 0, 0)
	testing.expect_value(t, symbols(state, 16)[0], Symbol('Q'))
	testing.expect_value(t, chord_symbols(state, 16, 1)[0], Symbol('q'))
	testing.expect_value(t, symbols(state, 3)[0], Symbol('@'))
	testing.expect_value(t, chord_symbols(state, 3, 1)[0], Symbol('2'))
	raw.xkb_state_update_mask(state, 0, 0, 2, 0, 0, 0)
	testing.expect_value(t, symbols(state, 16)[0], Symbol('Q'))
	testing.expect_value(t, chord_symbols(state, 16, 0)[0], Symbol('q'))
	raw.xkb_state_update_mask(state, 0, 0, 16, 0, 0, 0)
	testing.expect_value(t, chord_symbols(state, 79, 16)[0], from_name("KP_1"))
}

@(test)
compose_lifetimes_and_keymap_replacement :: proc(t: ^testing.T) {
	testing.expect_value(t, locale_name("", "", ""), "C")
	testing.expect_value(t, locale_name("", "en_US.UTF-8", "C"), "en_US.UTF-8")
	testing.expect_value(t, locale_name("C", "en_US.UTF-8", "other"), "C")
	a,b:=compose_create("en_US.UTF-8"),compose_create("en_US.UTF-8")
	defer compose_destroy(a); defer compose_destroy(b)
	testing.expect(t,a!=nil && b!=nil)
	buf:[256]u8
	testing.expect_value(t,text(a,from_name("dead_acute"),true,buf[:]),"")
	testing.expect_value(t,text(b,from_name("e"),true,buf[:]),"e")
	testing.expect_value(t,text(a,from_name("dead_acute"),false,buf[:]),"")
	km2:=create(Names{layout="de"})
	testing.expect(t,km2!=nil)
	if km2!=nil { destroy(km2) }
	testing.expect(t,create(Names{layout="kiln-no-such-map"})==nil)
	testing.expect_value(t,text(a,from_name("e"),true,buf[:]),"é")
	testing.expect_value(t,text(a,from_name("e"),false,buf[:]),"")
	testing.expect_value(t,text(a,from_name("dead_acute"),true,buf[:]),"")
	testing.expect_value(t,text(a,from_name("Escape"),true,buf[:]),"")
	testing.expect_value(t,text(a,from_name("A"),true,buf[:]),"A")
	absent:=compose_create("kiln_NO_SUCH_LOCALE.UTF-8")
	defer compose_destroy(absent)
	testing.expect(t,absent==nil)
	testing.expect_value(t,text(absent,from_name("a"),true,buf[:]),"a")
	km,ok:=create_default()
	testing.expect(t,ok)
	if !ok { return }
	defer destroy(km)
	state:=raw.xkb_state_new(km)
	defer raw.xkb_state_unref(state)
	raw.xkb_state_update_mask(state,4,0,0,0,0,0)
	testing.expect_value(t,text(nil,from_name("a"),true,buf[:],state,30),"\x01")
	locked:=numlock_mask(state,2,true)
	testing.expect(t,locked!=2 && locked&2!=0)
	testing.expect_value(t,numlock_mask(state,locked,false),u32(2))
}

@(test)
locked_modifiers_stay_out_of_the_chord_mask :: proc(t: ^testing.T) {
	km, ok := create_default()
	testing.expect(t, ok)
	if !ok { return }
	defer destroy(km)
	state := state_create(km)
	defer state_destroy(state)
	state_update_key(state, 58, true)
	state_update_key(state, 58, false)
	testing.expect(t, state_modifiers(state).locked&2 != 0)
	testing.expect_value(t, modifier_mask(state), 0)
	state_update_key(state, 42, true)
	testing.expect_value(t, modifier_mask(state), 1)
}
