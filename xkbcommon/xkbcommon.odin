package xkbcommon

import "core:c"

foreign import lib "system:xkbcommon"
xkb_context :: struct {}
xkb_keymap :: struct {}
xkb_state :: struct {}
xkb_rule_names :: struct { rules, model, layout, variant, options: cstring }
#assert(size_of(xkb_rule_names) == 40)
#assert(align_of(xkb_rule_names) == 8)
#assert(offset_of(xkb_rule_names, rules) == 0)
#assert(offset_of(xkb_rule_names, model) == 8)
#assert(offset_of(xkb_rule_names, layout) == 16)
#assert(offset_of(xkb_rule_names, variant) == 24)
#assert(offset_of(xkb_rule_names, options) == 32)
xkb_compose_table :: struct {}
xkb_compose_state :: struct {}
xkb_keysym_t :: u32
xkb_keycode_t :: u32
XKB_CONTEXT_NO_FLAGS :: 0
XKB_KEYMAP_COMPILE_NO_FLAGS :: 0
XKB_KEY_Escape :: 0xff1b

foreign lib {
	xkb_keymap_led_get_index :: proc(keymap: ^xkb_keymap, name: cstring) -> u32 ---
	xkb_state_led_index_is_active :: proc(state: ^xkb_state, index: u32) -> c.int ---
	xkb_keymap_ref :: proc(keymap: ^xkb_keymap) -> ^xkb_keymap ---
	xkb_keymap_get_as_string :: proc(keymap: ^xkb_keymap, format: c.int) -> cstring ---
	xkb_state_update_key :: proc(state: ^xkb_state, key: xkb_keycode_t, direction: c.int) -> c.int ---
	xkb_state_serialize_mods :: proc(state: ^xkb_state, components: c.int) -> u32 ---
	xkb_state_serialize_layout :: proc(state: ^xkb_state, components: c.int) -> u32 ---
	xkb_state_key_get_utf8 :: proc(state: ^xkb_state, key: xkb_keycode_t, buffer: cstring, size: c.size_t) -> c.int ---
	xkb_keymap_mod_get_index :: proc(keymap: ^xkb_keymap, name: cstring) -> u32 ---
	xkb_compose_table_new_from_locale :: proc(ctx: ^xkb_context, locale: cstring, flags: c.int) -> ^xkb_compose_table ---
	xkb_compose_table_unref :: proc(table: ^xkb_compose_table) ---
	xkb_compose_state_new :: proc(table: ^xkb_compose_table, flags: c.int) -> ^xkb_compose_state ---
	xkb_compose_state_unref :: proc(state: ^xkb_compose_state) ---
	xkb_compose_state_feed :: proc(state: ^xkb_compose_state, sym: xkb_keysym_t) -> c.int ---
	xkb_compose_state_get_status :: proc(state: ^xkb_compose_state) -> c.int ---
	xkb_compose_state_get_utf8 :: proc(state: ^xkb_compose_state, buffer: cstring, size: c.size_t) -> c.int ---
	xkb_compose_state_reset :: proc(state: ^xkb_compose_state) ---
	xkb_state_mod_name_is_active :: proc(state: ^xkb_state, name: cstring, components: c.int) -> c.int ---
	xkb_keysym_from_name :: proc(name: cstring, flags: c.int) -> xkb_keysym_t ---
	xkb_state_get_keymap :: proc(state: ^xkb_state) -> ^xkb_keymap ---
	xkb_state_key_get_layout :: proc(state: ^xkb_state, key: xkb_keycode_t) -> u32 ---
	xkb_keymap_key_get_syms_by_level :: proc(keymap: ^xkb_keymap, key: xkb_keycode_t, layout, level: u32, syms_out: ^[^]xkb_keysym_t) -> c.int ---
	xkb_state_new :: proc(keymap: ^xkb_keymap) -> ^xkb_state ---
	xkb_state_unref :: proc(state: ^xkb_state) ---
	xkb_state_update_mask :: proc(state: ^xkb_state, depressed, latched, locked, depressed_layout, latched_layout, locked_layout: u32) -> c.int ---
	xkb_keysym_get_name :: proc(sym: xkb_keysym_t, buffer: cstring, size: c.size_t) -> c.int ---
	xkb_keysym_to_utf8 :: proc(sym: xkb_keysym_t, buffer: cstring, size: c.size_t) -> c.int ---
	xkb_context_new :: proc(flags: c.int) -> ^xkb_context ---
	xkb_context_unref :: proc(ctx: ^xkb_context) ---
	xkb_keymap_new_from_names :: proc(ctx: ^xkb_context, names: ^xkb_rule_names, flags: c.int) -> ^xkb_keymap ---
	xkb_keymap_unref :: proc(keymap: ^xkb_keymap) ---
	xkb_state_key_get_syms :: proc(state: ^xkb_state, key: xkb_keycode_t, syms_out: ^[^]xkb_keysym_t) -> c.int ---
}
