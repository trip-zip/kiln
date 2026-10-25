package keymap

import "core:c"
import "core:os"
import "core:strings"
import raw "../xkbcommon"

Map :: raw.xkb_keymap
State :: raw.xkb_state
Symbol :: raw.xkb_keysym_t
ESCAPE :: raw.XKB_KEY_Escape

create_default :: proc() -> (keymap: ^Map, ok: bool) {
	xkb := raw.xkb_context_new(raw.XKB_CONTEXT_NO_FLAGS)
	if xkb == nil { return nil, false }
	defer raw.xkb_context_unref(xkb)
	keymap = raw.xkb_keymap_new_from_names(xkb, nil, raw.XKB_KEYMAP_COMPILE_NO_FLAGS)
	return keymap, keymap != nil
}
destroy :: raw.xkb_keymap_unref
symbols :: proc(state: ^State, evdev_key: u32) -> []Symbol {
	syms: [^]Symbol
	count := raw.xkb_state_key_get_syms(state, evdev_key + 8, &syms)
	return syms[:count]
}

// The caller keeps both buffers alive until its event snapshot is queued.
describe :: proc(sym: Symbol, name, utf8: []u8) -> (string, string) {
	n := raw.xkb_keysym_get_name(sym, cast(cstring)raw_data(name), c.size_t(len(name)))
	u := raw.xkb_keysym_to_utf8(sym, cast(cstring)raw_data(utf8), c.size_t(len(utf8)))
	return string(name[:clamp(int(n), 0, len(name)-1)]), string(utf8[:clamp(int(u)-1, 0, len(utf8)-1)])
}

// Shift and Caps affect text, while chord names keep the base level.
// NumLock alone retains the numbered keypad level.
chord_symbols :: proc(state: ^State, evdev_key, mods: u32) -> []Symbol {
	if mods & 3 != 0 || raw.xkb_state_mod_name_is_active(state, "Lock", 8) > 0 {
		group := raw.xkb_state_key_get_layout(state, evdev_key + 8)
		if group != max(u32) {
			syms: [^]Symbol
			n := raw.xkb_keymap_key_get_syms_by_level(raw.xkb_state_get_keymap(state), evdev_key + 8, group, 0, &syms)
			if n > 0 { return syms[:n] }
		}
	}
	return symbols(state, evdev_key)
}
from_name :: proc(name: string) -> Symbol {
	cname := strings.clone_to_cstring(name)
	defer delete(cname)
	return raw.xkb_keysym_from_name(cname, 0)
}
Chord :: struct { sym, mods: u32 }
bound :: proc(bindings: []Chord, sym, mods: u32) -> bool {
	for b in bindings { if b.sym == sym && b.mods == mods & 77 { return true } }
	return false
}
// Each keyboard owns its exact keycodes, with no modulo collisions.
consume :: proc(held: ^map[u32]bool, code: u32, pressed, matched: bool) -> bool {
	if pressed {
		if matched { held^[code] = true }
		return held^[code]
	}
	was := held^[code]
	delete_key(held, code)
	return was
}

Names :: struct { rules, model, layout, variant, options: string, present: [5]bool }
create :: proc(names: Names) -> ^Map {
	ctx := raw.xkb_context_new(0)
	if ctx == nil { return nil }
	defer raw.xkb_context_unref(ctx)
	values: [5]cstring
	for name,i in ([5]string{names.rules,names.model,names.layout,names.variant,names.options}) {
		if names.present[i] || name!="" { values[i]=strings.clone_to_cstring(name) }
	}
	defer for value in values { delete(value) }
	n := raw.xkb_rule_names{values[0],values[1],values[2],values[3],values[4]}
	return raw.xkb_keymap_new_from_names(ctx, &n, 0)
}
numlock_mask :: proc(state: ^State, locked: u32, on: bool) -> u32 {
	idx := raw.xkb_keymap_mod_get_index(raw.xkb_state_get_keymap(state), "NumLock")
	if idx >= 32 { return locked }
	if on { return locked | (u32(1)<<idx) }
	return locked &~ (u32(1)<<idx)
}
Compose :: raw.xkb_compose_state
locale_name :: proc(all, ctype, lang: string) -> string {
	for value in ([]string{all, ctype, lang}) { if value != "" { return value } }
	return "C"
}
compose_create :: proc(locale: string) -> ^Compose {
	ctx := raw.xkb_context_new(0)
	if ctx == nil { return nil }
	defer raw.xkb_context_unref(ctx)
	name := strings.clone_to_cstring(locale)
	defer delete(name)
	table := raw.xkb_compose_table_new_from_locale(ctx, name, 0)
	if table == nil { return nil }
	defer raw.xkb_compose_table_unref(table)
	return raw.xkb_compose_state_new(table, 0)
}
compose_default :: proc() -> ^Compose {
	all := os.get_env("LC_ALL", context.allocator)
	ctype := os.get_env("LC_CTYPE", context.allocator)
	lang := os.get_env("LANG", context.allocator)
	defer delete(all); defer delete(ctype); defer delete(lang)
	return compose_create(locale_name(all, ctype, lang))
}
compose_destroy :: raw.xkb_compose_state_unref
compose_reset :: proc(compose: ^Compose) { if compose!=nil { raw.xkb_compose_state_reset(compose) } }
text :: proc(compose: ^Compose, sym: Symbol, pressed: bool, buffer: []u8, state: ^State = nil, evdev_key: u32 = 0) -> string {
	if !pressed { return "" }
	if compose != nil {
		raw.xkb_compose_state_feed(compose, sym)
		switch raw.xkb_compose_state_get_status(compose) {
		case 1: return ""
		case 2:
			n := raw.xkb_compose_state_get_utf8(compose, cast(cstring)raw_data(buffer), c.size_t(len(buffer)))
			raw.xkb_compose_state_reset(compose)
			return string(buffer[:clamp(int(n), 0, len(buffer)-1)])
		case 3:
			raw.xkb_compose_state_reset(compose)
			return ""
		}
	}
	if state!=nil {
		n:=raw.xkb_state_key_get_utf8(state,evdev_key+8,cast(cstring)raw_data(buffer),c.size_t(len(buffer)))
		return string(buffer[:clamp(int(n),0,len(buffer)-1)])
	}
	n := raw.xkb_keysym_to_utf8(sym, cast(cstring)raw_data(buffer), c.size_t(len(buffer)))
	return string(buffer[:clamp(int(n)-1, 0, len(buffer)-1)])
}

Modifiers :: struct { depressed, latched, locked, group: u32 }
state_create :: raw.xkb_state_new
state_destroy :: raw.xkb_state_unref
state_update_key :: proc(state: ^State, code: u32, pressed: bool) { raw.xkb_state_update_key(state, code+8, c.int(pressed)) }
state_modifiers :: proc(state: ^State) -> Modifiers {
	return {raw.xkb_state_serialize_mods(state, 1), raw.xkb_state_serialize_mods(state, 2), raw.xkb_state_serialize_mods(state, 4), raw.xkb_state_serialize_layout(state, 128)}
}
// Depressed and latched only: a locked Caps or Num must not change a chord or an input fact.
modifier_mask :: proc(state: ^State) -> (mask: u32) {
	for name, i in ([8]cstring{"Shift", "Lock", "Control", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5"}) {
		if raw.xkb_state_mod_name_is_active(state, name, 3) > 0 { mask |= u32(1)<<uint(i) }
	}
	return
}
