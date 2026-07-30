/* The Lua side of the boundary: LuaJIT hosting rc.lua, the core.* declare
 * primitives (thin marshalling onto Clay's element API, no interpretation),
 * timers, spawn, and the IPC eval socket. Every C-to-Lua entry runs under
 * pcall with a traceback handler. */

/* pipe2 (core.spawn_pipe) is outside _POSIX_C_SOURCE; this file uses no
 * GNU-variant of any other function, so the wider feature set is inert. */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

#include "clay.h"
#include "core.h"
#include "queue.h"
#include "ui.h"

struct core {
	lua_State *L;
	struct ui *ui;
	struct wl_display *display;
	struct wl_event_loop *loop;
	int frame_handler_ref;
	int event_handler_ref;
	/* The native lockscreen's frame handler, declared into a dedicated Clay
	 * context while natively locked. */
	int lock_handler_ref;
	/* The core table itself, so a declare pass can hand Lua the anchor table
	 * without a global lookup. Strings passed to Clay this frame (element ids,
	 * text) are Lua's and Clay only borrows pointers into them, so
	 * lua/kiln/cffi.lua anchors them in the fresh table installed at
	 * core.__declare below, whose absence is what tells the declare verbs they
	 * are outside a pass.
	 *
	 * How long they have to live is a per-Clay-context question, not a per-pass
	 * one: the context's element hashmap keeps the stringId pointers of
	 * its last solve, and ui_hits reads names straight out of that hashmap, so
	 * a name is readable until that same context declares again. The pass table
	 * is therefore also parked in core.__anchors under its context, and parking
	 * the new one is the release of that context's previous one. */
	int core_ref;
	struct core_client_ops client_ops;
	struct core_input_ops input_ops;
	struct core_activation_ops activation_ops;
	struct core_layer_ops layer_ops;
	struct core_lock_ops lock_ops;
	struct core_notify_ops notify_ops;
	struct core_tray_ops tray_ops;
	struct core_output_ops output_ops;
	/* Surfaces declared this frame, to make a double declare loud. */
	uint64_t *surfaces;
	size_t surfaces_len, surfaces_cap;
	/* Chords Lua asked C to consume instead of forwarding. */
	struct core_binding {
		uint32_t keysym;
		uint32_t mods;
	} *bindings;
	size_t bindings_len;
	struct wl_list timers;
	/* Monotonic timer id source: never reused, so a fired or cancelled id is
	 * permanently stale and core.timer_cancel on it no-ops. */
	uint64_t next_timer_id;
	/* Async spawn: the queue back-pointer chunks are emitted through, the live
	 * pipe list, its monotonic id source, and the SIGCHLD fallback reaper, which
	 * stays NULL on any kernel with pidfd because each child's exit arrives on
	 * an fd of its own instead. */
	struct queue *queue;
	struct wl_list spawn_pipes;
	uint64_t next_spawn_id;
	struct wl_event_source *sigchld;
	int ipc_fd;
	struct wl_event_source *ipc_source;
	char ipc_path[108];
};

struct core_timer {
	struct wl_list link;
	struct core *core;
	struct wl_event_source *source;
	int fn_ref;
	uint64_t id;
};

/* --- pcall plumbing --- */

static int traceback(lua_State *L) {
	luaL_traceback(L, L, lua_tostring(L, -1), 1);
	return 1;
}

/* Call with nargs already pushed under the function. Logs on error. */
static bool core_pcall(struct core *core, int nargs, int nresults) {
	lua_State *L = core->L;
	int base = lua_gettop(L) - nargs;
	lua_pushcfunction(L, traceback);
	lua_insert(L, base);
	int ret = lua_pcall(L, nargs, nresults, base);
	lua_remove(L, base);
	if (ret != 0) {
		fprintf(stderr, "lua error: %s\n", lua_tostring(L, -1));
		lua_pop(L, 1);
		return false;
	}
	return true;
}

/* --- the core.* primitives --- */

static struct core *core_from_lua(lua_State *L) {
	return lua_touserdata(L, lua_upvalueindex(1));
}

/* --- the FFI boundary: Lua-to-C verbs cross through ffi.C ---
 *
 * From here down, most verbs Lua calls are exported kiln_* functions it
 * reaches through ffi.C rather than the Lua stack, each staying with the
 * namespace it belongs to. There is no argument checking in them on
 * purpose: validation is Lua's, at the public edge, and
 * lua/kiln/cffi.lua's cdef is pinned to these signatures by the generated
 * guard, so a drift fails the build rather than the frame.
 *
 * C-to-Lua stays classic API, which is why the callback registrars and
 * the table- and varargs-shaped verbs are still l_* wrappers around this. The
 * readbacks cross the same way as the rest: by value, into an array the
 * caller sized, with the conversion to Lua tables done on the Lua side. The
 * declare path crosses by pointer instead: the declaration is filled on
 * the Lua side into one scratch reused across frames, and Lua opens, configures
 * and closes the element itself. */

/* --- the declare path: the four calls Lua cannot make cheaply ---
 *
 * What is left of it in C is the four things Lua cannot do without boxing a
 * cdata per element per frame in the interpreter and at trace exits (LuaJIT
 * sinks the box on compiled traces), or without a contract that is not the
 * declaration's. The whole table-to-Clay mapping is lua/kiln/cffi.lua's. */

/* The id, for both shapes at once: a plain string is index 0. Clay__HashString
 * answers with a Clay_ElementId by value, so out takes it and the return is the
 * hash alone, which is all a floating parentId wants. The name bytes are Lua's
 * and stay anchored for the pass, which is the contract this whole path rests
 * on (spec, and the anchor table core_declare_ref installs below). */
uint32_t kiln_hash_id(const char *name, int32_t name_len, uint32_t index,
		Clay_ElementId *out) {
	Clay_ElementId id = Clay__HashString(
		(Clay_String) { .length = name_len, .chars = name }, index, 0);
	if (out != NULL) {
		*out = id;
	}
	return id.id;
}

/* core.text's leaf. Clay__StoreTextElementConfig answers with a pointer into
 * Clay's per-frame config array, which is the only place a text config may
 * live; taking that pointer in Lua would box one cdata per text leaf per
 * frame in the interpreter and at trace exits (sunk on compiled traces). */
void kiln_text(const Clay_String *text, const Clay_TextElementConfig *config) {
	Clay__OpenTextElement(*text, Clay__StoreTextElementConfig(*config));
}

/* The declaration's image. imageData is the stable cache entry pointer, which
 * Clay retains across the solve; ui_image_get copies the path. Written into the
 * caller's config rather than returned, for the same no-boxing reason. */
void kiln_image(struct core *core, const char *path,
		Clay_ImageElementConfig *out) {
	out->imageData = ui_image_get(core->ui, path);
}

/* core.surface(handle, decl?): the place-leaf. The declaration arrives filled
 * from the Lua side, or NULL for the grow/grow default the verb has always had;
 * everything else here is the place-leaf contract, unchanged from the wrapper
 * this replaces. The element's custom data carries the client handle to the
 * renderer, the id derives from the handle so the retained key is stable across
 * frames, and open/configure/close happen together because nothing may be a
 * surface's child. False means the handle was already declared this frame; the
 * Lua edge turns that into the error the wrapper raised. */
bool kiln_surface(struct core *core, uint64_t handle,
		const Clay_ElementDeclaration *decl) {
	for (size_t i = 0; i < core->surfaces_len; i++) {
		if (core->surfaces[i] == handle) {
			return false;
		}
	}
	if (core->surfaces_len == core->surfaces_cap) {
		core->surfaces_cap = core->surfaces_cap ? core->surfaces_cap * 2 : 8;
		core->surfaces = realloc(core->surfaces,
			core->surfaces_cap * sizeof(*core->surfaces));
	}
	core->surfaces[core->surfaces_len++] = handle;

	Clay_ElementDeclaration d = { 0 };
	if (decl != NULL) {
		d = *decl;
	} else {
		d.layout.sizing.width.type = CLAY__SIZING_TYPE_GROW;
		d.layout.sizing.height.type = CLAY__SIZING_TYPE_GROW;
	}
	d.id = Clay__HashString(CLAY_STRING("core.surface"), (uint32_t)handle, 0);
	d.custom.customData = (void *)(uintptr_t)handle;

	Clay__OpenElement();
	Clay__ConfigureOpenElementPtr(&d);
	Clay__CloseElement();
	return true;
}

/* core.hits(screen, x, y): element ids under a layout point, innermost
 * first, from the last solve. The out-array is the caller's
 * (lua/kiln/cffi.lua allocates it once); a name is a pointer into the id
 * strings of that screen's last declare plus a length, and those strings are
 * anchored until that same screen declares again (core_declare_ref). */
int kiln_hits(struct core *core, const char *screen, double x, double y,
		struct ui_hit *out, int max) {
	return ui_hits(core->ui, screen, x, y, out, max);
}

/* core.box(id): the solved box of an element in the current screen context,
 * as { x, y, width, height } half-up integers. Reads back the last box the id
 * EVER had in this context, not just the last solve: Clay's element hashmap is
 * persistent memory and Clay_GetElementData never consults generation, so an
 * id that left the tree keeps answering with its final box.
 * Not a liveness test; assert absence through core.hits, which only
 * names what the live tree put under a point. nil only for an id never
 * declared, or before the first solve. A pure wrap of Clay_GetElementData; the
 * id hashes exactly as it was declared (string or { name, index }). Callable
 * any time: inside the frame handler it reads the PREVIOUS solve (boundingBox
 * is only rewritten at EndLayout), which is the area a layout reads back.
 *
 * The id arrives split into the two things Clay hashes, name bytes and index,
 * because that is all a lookup needs: Clay_GetElementData consults id.id alone,
 * so unlike a declare this hash is never retained and the string it is taken
 * from does not have to outlive the call. Lua's edge maps its two id shapes
 * onto it, a plain string being index 0.
 *
 * No core: the current Clay context is Clay's own global, and the only thing the
 * deleted wrapper wanted core for was the lua_State it marshalled through.
 *
 * Documented public API: reading a solved box back is how a config, and the
 * stock widgets with it, react to layout without ever computing one. */
struct core_box kiln_box(const char *name, int32_t name_len, uint32_t index) {
	struct core_box box = { 0 };

	/* No solve has run yet: no current context to query. */
	if (Clay_GetCurrentContext() == NULL) {
		return box;
	}

	Clay_String key = { .length = name_len, .chars = name };
	Clay_ElementData data = Clay_GetElementData(Clay__HashString(key, index, 0));
	if (!data.found) {
		return box;
	}

	/* Boxes cross the boundary as half-up-rounded integers, once, in C: Lua
	 * px are screen px, so re-declaring a read-back box moves nothing. */
	Clay_BoundingBox b = data.boundingBox;
	box.found = true;
	box.x = (int)floorf(b.x + 0.5f);
	box.y = (int)floorf(b.y + 0.5f);
	box.width = (int)floorf(b.width + 0.5f);
	box.height = (int)floorf(b.height + 0.5f);
	return box;
}

/* --- core.client verbs --- */

void kiln_client_focus(struct core *core, uint64_t handle) {
	if (core->client_ops.focus != NULL) {
		core->client_ops.focus(core->client_ops.data, handle);
	}
}

void kiln_client_configure(struct core *core, uint64_t handle,
		int width, int height) {
	if (core->client_ops.configure != NULL) {
		core->client_ops.configure(core->client_ops.data, handle,
			width, height);
	}
}

void kiln_client_close(struct core *core, uint64_t handle) {
	if (core->client_ops.close_client != NULL) {
		core->client_ops.close_client(core->client_ops.data, handle);
	}
}

void kiln_client_kill(struct core *core, uint64_t handle) {
	if (core->client_ops.kill_client != NULL) {
		core->client_ops.kill_client(core->client_ops.data, handle);
	}
}

void kiln_client_set_activated(struct core *core, uint64_t handle, bool on) {
	if (core->client_ops.set_activated != NULL) {
		core->client_ops.set_activated(core->client_ops.data, handle, on);
	}
}

void kiln_client_set_fullscreen_hint(struct core *core, uint64_t handle,
		bool on) {
	if (core->client_ops.set_fullscreen_hint != NULL) {
		core->client_ops.set_fullscreen_hint(core->client_ops.data,
			handle, on);
	}
}

void kiln_client_set_maximized_hint(struct core *core, uint64_t handle,
		bool on) {
	if (core->client_ops.set_maximized_hint != NULL) {
		core->client_ops.set_maximized_hint(core->client_ops.data,
			handle, on);
	}
}

void kiln_client_set_tiled_hint(struct core *core, uint64_t handle,
		uint32_t edges) {
	if (core->client_ops.set_tiled_hint != NULL) {
		core->client_ops.set_tiled_hint(core->client_ops.data,
			handle, edges);
	}
}

void kiln_client_set_suspended(struct core *core, uint64_t handle, bool on) {
	if (core->client_ops.set_suspended != NULL) {
		core->client_ops.set_suspended(core->client_ops.data, handle, on);
	}
}

void kiln_client_set_minimized_hint(struct core *core, uint64_t handle,
		bool on) {
	if (core->client_ops.set_minimized_hint != NULL) {
		core->client_ops.set_minimized_hint(core->client_ops.data, handle, on);
	}
}

/* name is the connector of the screen the client is declared on, NULL to leave
 * every output. */
void kiln_client_set_output_mirror(struct core *core, uint64_t handle,
		const char *name) {
	if (core->client_ops.set_output_mirror != NULL) {
		core->client_ops.set_output_mirror(core->client_ops.data, handle, name);
	}
}

/* --- the key consume filter --- */

static const struct {
	const char *name;
	uint32_t bit;
} mod_names[] = {
	{ "shift", WLR_MODIFIER_SHIFT },
	{ "ctrl", WLR_MODIFIER_CTRL },
	{ "alt", WLR_MODIFIER_ALT },
	{ "super", WLR_MODIFIER_LOGO },
};

/* Pushes the field and returns true only if it is a table. A Lua-stack idiom,
 * not a mapping onto a Clay struct; its one caller is the binding table
 * below. */
static bool field_table(lua_State *L, int idx, const char *key) {
	lua_getfield(L, idx, key);
	if (lua_istable(L, -1)) {
		return true;
	}
	lua_pop(L, 1);
	return false;
}

/* core.set_key_bindings({ { mods = {"alt"}, key = "Return" }, ... })
 * replaces the whole set. C consumes exactly these chords; every other
 * key is forwarded to the focused client. */
static int l_set_key_bindings(lua_State *L) {
	struct core *core = core_from_lua(L);
	luaL_checktype(L, 1, LUA_TTABLE);
	size_t count = lua_objlen(L, 1);

	free(core->bindings);
	core->bindings = calloc(count, sizeof(*core->bindings));
	core->bindings_len = 0;

	for (size_t i = 1; i <= count; i++) {
		lua_rawgeti(L, 1, (int)i);
		luaL_checktype(L, -1, LUA_TTABLE);

		lua_getfield(L, -1, "key");
		const char *keyname = lua_tostring(L, -1);
		xkb_keysym_t sym = keyname != NULL ?
			xkb_keysym_from_name(keyname, XKB_KEYSYM_NO_FLAGS) :
			XKB_KEY_NoSymbol;
		lua_pop(L, 1);
		if (sym == XKB_KEY_NoSymbol) {
			return luaL_error(L, "binding %d: unknown key name", (int)i);
		}

		uint32_t mods = 0;
		if (field_table(L, -1, "mods")) {
			size_t nmods = lua_objlen(L, -1);
			for (size_t m = 1; m <= nmods; m++) {
				lua_rawgeti(L, -1, (int)m);
				const char *name = lua_tostring(L, -1);
				for (size_t k = 0;
						name != NULL &&
						k < sizeof(mod_names) / sizeof(mod_names[0]);
						k++) {
					if (strcmp(name, mod_names[k].name) == 0) {
						mods |= mod_names[k].bit;
					}
				}
				lua_pop(L, 1);
			}
			lua_pop(L, 1);
		}

		core->bindings[core->bindings_len].keysym = sym;
		core->bindings[core->bindings_len].mods = mods;
		core->bindings_len++;
		lua_pop(L, 1);
	}
	return 0;
}

bool core_key_bound(struct core *core, uint32_t keysym, uint32_t mods) {
	/* Compare only the modifiers Lua can name; locked modifiers like
	 * NumLock (MOD2) and CapsLock ride along in the raw mask and would
	 * otherwise make an exact match miss, so the key gets forwarded to
	 * the client while the Lua handler still fires. */
	mods &= WLR_MODIFIER_SHIFT | WLR_MODIFIER_CTRL | WLR_MODIFIER_ALT |
		WLR_MODIFIER_LOGO;
	for (size_t i = 0; i < core->bindings_len; i++) {
		if (core->bindings[i].keysym == keysym &&
				core->bindings[i].mods == mods) {
			return true;
		}
	}
	return false;
}

void core_set_client_ops(struct core *core,
		const struct core_client_ops *ops) {
	core->client_ops = *ops;
}

/* core.input.grab_pointer(on): hand the cursor to Lua policy, or return it. */
void kiln_input_grab_pointer(struct core *core, bool on) {
	if (core->input_ops.grab_pointer != NULL) {
		core->input_ops.grab_pointer(core->input_ops.data, on);
	}
}

/* core.input.grab_keyboard(on): while on, keys keep entering the queue and
 * none reaches a client, so a Lua grabber reads them off the one queue ahead
 * of bindings. C tracks no grabber and no stack; the claim is Lua's. */
void kiln_input_grab_keyboard(struct core *core, bool on) {
	if (core->input_ops.grab_keyboard != NULL) {
		core->input_ops.grab_keyboard(core->input_ops.data, on);
	}
}

/* core.input.set_keymap{ layout =, variant =, options =, model =, rules = }:
 * one xkb_keymap_new_from_names, applied to every keyboard. Whole-map
 * replacement, no readback. The compose table is built from the locale,
 * not the keymap, so it survives untouched. The names arrive by value and
 * point into the caller's Lua table, which outlives the call. */
void kiln_input_set_keymap(struct core *core, struct core_keymap names) {
	if (core->input_ops.set_keymap != NULL) {
		core->input_ops.set_keymap(core->input_ops.data, &names);
	}
}

/* core.input.set_repeat(rate, delay): wlr_keyboard_set_repeat_info. */
void kiln_input_set_repeat(struct core *core, int rate, int delay) {
	if (core->input_ops.set_repeat != NULL) {
		core->input_ops.set_repeat(core->input_ops.data, rate, delay);
	}
}

/* core.input.set_numlock(on): the locked-modifier mask on every keyboard, the
 * Wayland-starts-cold NumLock fix. */
void kiln_input_set_numlock(struct core *core, bool on) {
	if (core->input_ops.set_numlock != NULL) {
		core->input_ops.set_numlock(core->input_ops.data, on);
	}
}

/* core.input.set_pointer{ tap_to_click =, natural_scrolling =, accel_speed =,
 * accel_profile =, scroll_method =, click_method =, left_handed = }: libinput
 * config over every pointer device. A nil field is untouched, which is
 * what the set flags carry; a device that does not support a field ignores it
 * in kiln.c. Per-device targeting is the named absence. */
void kiln_input_set_pointer(struct core *core, struct core_pointer_config cfg) {
	if (core->input_ops.set_pointer != NULL) {
		core->input_ops.set_pointer(core->input_ops.data, &cfg);
	}
}

/* core.input.set_cursor(name): the cursor image is Lua's choice, not C's. */
void kiln_input_set_cursor(struct core *core, const char *name) {
	if (core->input_ops.set_cursor != NULL) {
		core->input_ops.set_cursor(core->input_ops.data, name);
	}
}

/* core.input.set_cursor_theme(name, size?): swap the xcursor theme. The
 * per-scale sharpness stays wlroots': it reloads the named theme at each output's
 * live scale on the next lookup, so this only points it at a new theme and base
 * size, no new shape. A NULL name restores the env default. */
void kiln_input_set_cursor_theme(struct core *core, const char *name,
		int size) {
	if (core->input_ops.set_cursor_theme != NULL) {
		core->input_ops.set_cursor_theme(core->input_ops.data, name, size);
	}
}

void core_set_input_ops(struct core *core,
		const struct core_input_ops *ops) {
	core->input_ops = *ops;
}

/* core.output.list(): the one output read, enumeration as discovery.
 * kiln.c fills a caller-owned array, which is now the caller's on both sides:
 * lua/kiln/cffi.lua owns the out-array
 * and builds the per-output { name, width, height, refresh, scale, x, y,
 * enabled, modes } shape from it. Runtime changes still arrive as
 * `output change` events, not from re-reading this. */
int kiln_output_list(struct core *core, struct core_output_info *out, int max) {
	return core->output_ops.list != NULL ?
		core->output_ops.list(core->output_ops.data, out, max) : 0;
}

/* core.output.set_mode(name, w, h, refresh?): refresh optional (0 lets kiln.c
 * pick a matching mode or set a custom one at whatever rate the backend gives). */
void kiln_output_set_mode(struct core *core, const char *name,
		int w, int h, int refresh) {
	if (core->output_ops.set_mode != NULL) {
		core->output_ops.set_mode(core->output_ops.data, name, w, h, refresh);
	}
}

/* core.output.set_scale(name, f): runtime rescale by connector name. */
void kiln_output_set_scale(struct core *core, const char *name, double scale) {
	if (core->output_ops.set_scale != NULL) {
		core->output_ops.set_scale(core->output_ops.data, name, scale);
	}
}

/* core.output.set_position(name, x, y): a wlr_output_layout move. */
void kiln_output_set_position(struct core *core, const char *name,
		int x, int y) {
	if (core->output_ops.set_position != NULL) {
		core->output_ops.set_position(core->output_ops.data, name, x, y);
	}
}

/* core.output.set_enabled(name, on): output enable/disable. */
void kiln_output_set_enabled(struct core *core, const char *name, bool on) {
	if (core->output_ops.set_enabled != NULL) {
		core->output_ops.set_enabled(core->output_ops.data, name, on);
	}
}

/* core.output.set_adaptive_sync(name, on): the VRR toggle; nothing else can
 * enable VRR. */
void kiln_output_set_adaptive_sync(struct core *core, const char *name,
		bool on) {
	if (core->output_ops.set_adaptive_sync != NULL) {
		core->output_ops.set_adaptive_sync(core->output_ops.data, name, on);
	}
}

void core_set_output_ops(struct core *core,
		const struct core_output_ops *ops) {
	core->output_ops = *ops;
}

void core_set_activation_ops(struct core *core,
		const struct core_activation_ops *ops) {
	core->activation_ops = *ops;
}

/* core.layer_configure(handle, w, h): Lua's answer to a layer::map/commit
 * fact. The only configure path a layer surface has. */
void kiln_layer_configure(struct core *core, uint64_t handle,
		int width, int height) {
	if (core->layer_ops.configure != NULL) {
		core->layer_ops.configure(core->layer_ops.data, handle,
			width, height);
	}
}

void core_set_layer_ops(struct core *core,
		const struct core_layer_ops *ops) {
	core->layer_ops = *ops;
}

/* core.lock(): engage the native lockscreen. Returns false if a lock (native
 * or external) is already active. */
bool kiln_lock(struct core *core) {
	return core->lock_ops.lock != NULL &&
		core->lock_ops.lock(core->lock_ops.data);
}

/* core.unlock(): disengage the native lockscreen. Returns false unless a prior
 * core.authenticate succeeded; the gate is enforced in C, so a config alone
 * can never disengage the lock. */
bool kiln_unlock(struct core *core) {
	return core->lock_ops.unlock != NULL &&
		core->lock_ops.unlock(core->lock_ops.data);
}

/* core.authenticate(password): verify via PAM. On success the C unlock gate
 * opens; returns whether it matched. Synchronous (see pam_auth.h). */
bool kiln_authenticate(struct core *core, const char *password) {
	return core->lock_ops.authenticate != NULL &&
		core->lock_ops.authenticate(core->lock_ops.data, password);
}

void core_set_lock_ops(struct core *core,
		const struct core_lock_ops *ops) {
	core->lock_ops = *ops;
}

/* core.notify_closed(id, reason): a notification is gone and Lua says why, so
 * NotificationClosed goes out. reason is the protocol integer; C neither knows
 * nor checks whether the id ever named anything. */
void kiln_notify_closed(struct core *core, uint32_t id, int reason) {
	if (core->notify_ops.closed != NULL) {
		core->notify_ops.closed(core->notify_ops.data, id, reason);
	}
}

/* core.notify_action(id, key): a button was pressed, so ActionInvoked goes out.
 * Whether the notification then closes is Lua's call, made with the verb above. */
void kiln_notify_action(struct core *core, uint32_t id, const char *key) {
	if (core->notify_ops.action != NULL) {
		core->notify_ops.action(core->notify_ops.data, id, key);
	}
}

/* core.tray_activate(service, kind, a, b): a tray icon was clicked or scrolled,
 * so one method call goes out to the item. C forwards; whether the click meant
 * anything is the item's answer, not ours. */
void kiln_tray_activate(struct core *core, const char *service,
		const char *kind, int a, const char *b) {
	if (core->tray_ops.activate != NULL) {
		core->tray_ops.activate(core->tray_ops.data, service, kind, a, b);
	}
}

void core_set_tray_ops(struct core *core, const struct core_tray_ops *ops) {
	core->tray_ops = *ops;
}

void core_set_notify_ops(struct core *core,
		const struct core_notify_ops *ops) {
	core->notify_ops = *ops;
}

/* core.dirty([name]): mark one output dirty by connector name, every output
 * when name is NULL. An unknown name is a no-op. Documented public API:
 * redeclare-on-change is the whole update model, and this is the verb that
 * requests the redeclare, for configs and the stock widgets alike. */
void kiln_dirty(struct core *core, const char *name) {
	if (name != NULL) {
		ui_mark_dirty_name(core->ui, name);
	} else {
		ui_mark_all_dirty(core->ui);
	}
}

/* The style keys core.inspector's table form accepts, in the order of the
 * enum they name. Clay's debug palette is process-global, so these are not
 * addressed to the screen the call names. */
static const struct {
	const char *key;
	enum ui_inspector_color which;
} inspector_colors[] = {
	{ "color1", UI_INSPECTOR_COLOR_1 },
	{ "color2", UI_INSPECTOR_COLOR_2 },
	{ "color3", UI_INSPECTOR_COLOR_3 },
	{ "color4", UI_INSPECTOR_COLOR_4 },
	{ "selected", UI_INSPECTOR_COLOR_SELECTED },
	{ "highlight", UI_INSPECTOR_COLOR_HIGHLIGHT },
};

/* core.inspector(screen) reads, core.inspector(screen, bool) sets, and
 * core.inspector(screen, table) takes an optional `enabled` plus the style
 * keys. Always returns the post-call enabled state, read back from
 * Clay rather than from anything stored here: the panel can close itself from
 * inside the solver, so Clay's own flag is the only honest answer. */
static int l_inspector(lua_State *L) {
	struct core *core = core_from_lua(L);
	const char *screen = luaL_checkstring(L, 1);

	if (lua_istable(L, 2)) {
		lua_getfield(L, 2, "width");
		if (!lua_isnil(L, -1)) {
			ui_inspector_set_width(core->ui, (float)lua_tonumber(L, -1));
		}
		lua_pop(L, 1);
		for (size_t i = 0; i < sizeof(inspector_colors) /
				sizeof(inspector_colors[0]); i++) {
			lua_getfield(L, 2, inspector_colors[i].key);
			if (lua_istable(L, -1)) {
				/* Read straight into the float[4] ui_inspector_set_color
				 * takes: the Clay_Color the deleted to_color built was only
				 * ever unpacked again on the next line. */
				static const char *const channels[] = { "r", "g", "b", "a" };
				float rgba[4] = { 0, 0, 0, 255 };
				for (size_t c = 0; c < 4; c++) {
					lua_getfield(L, -1, channels[c]);
					if (lua_isnumber(L, -1)) {
						rgba[c] = (float)lua_tonumber(L, -1);
					}
					lua_pop(L, 1);
				}
				ui_inspector_set_color(core->ui,
					inspector_colors[i].which, rgba);
			}
			lua_pop(L, 1);
		}
		lua_getfield(L, 2, "enabled");
		if (!lua_isnil(L, -1)) {
			ui_inspector_set(core->ui, screen, lua_toboolean(L, -1));
		}
		lua_pop(L, 1);
	} else if (!lua_isnoneornil(L, 2)) {
		ui_inspector_set(core->ui, screen, lua_toboolean(L, 2));
	}

	lua_pushboolean(L, ui_inspector_enabled(core->ui, screen));
	return 1;
}

/* core.inspector_scroll(screen, dx, dy) hands the panel a wheel delta for its
 * next solve; core.inspector_scroll(screen) reads the tree pane's y offset
 * back, which is what a test asserts against. Lua routes a wheel here only when
 * the hits under the cursor name the panel exactly, so this verb never has to
 * decide whether the scroll was meant for the inspector. */
static int l_inspector_scroll(lua_State *L) {
	struct core *core = core_from_lua(L);
	const char *screen = luaL_checkstring(L, 1);
	if (lua_isnoneornil(L, 2)) {
		lua_pushnumber(L, ui_inspector_scroll_offset(core->ui, screen));
		return 1;
	}
	ui_inspector_scroll(core->ui, screen, luaL_checknumber(L, 2),
		luaL_checknumber(L, 3));
	return 0;
}

/* core.tick(screen, on): arm/disarm that output's frame clock.
 * While on, C keeps the frame scheduled and delivers frame::tick with the true
 * delta each cycle; easing and dt clamp are Lua's. A top-level verb, not
 * core.output.*. */
void kiln_tick(struct core *core, const char *name, bool on) {
	if (core->output_ops.tick != NULL) {
		core->output_ops.tick(core->output_ops.data, name, on);
	}
}

/* core.screenshot(screen[, path]): read the screen's composed
 * scene into the image cache and return the cache key (usable as an image
 * source); with a path, also write it to a PNG. A top-level verb like tick,
 * not core.output.*. nil on a stale name or a
 * failed readback: a screenshot is a request, never a reason to abort. */
static int l_screenshot(lua_State *L) {
	struct core *core = core_from_lua(L);
	const char *name = luaL_checkstring(L, 1);
	const char *path = luaL_optstring(L, 2, NULL);
	if (core->output_ops.screenshot == NULL) {
		return 0;
	}
	const char *key = core->output_ops.screenshot(core->output_ops.data,
		name, path);
	if (key == NULL) {
		return 0;
	}
	lua_pushstring(L, key);
	return 1;
}

/* core.image_reload(path): drop the cached decode so the next declare re-reads
 * the file. The only image invalidation; the declare pass never stats on its
 * own. Marking dirty is the caller's job, like any state change. */
static int l_image_reload(lua_State *L) {
	struct core *core = core_from_lua(L);
	ui_image_reload(core->ui, luaL_checkstring(L, 1));
	return 0;
}

/* Replaces a registry-anchored handler with the function at stack slot 1. */
static int set_handler_ref(lua_State *L, int *ref) {
	luaL_checktype(L, 1, LUA_TFUNCTION);
	luaL_unref(L, LUA_REGISTRYINDEX, *ref);
	lua_pushvalue(L, 1);
	*ref = luaL_ref(L, LUA_REGISTRYINDEX);
	return 0;
}

/* Pushes a registry-anchored handler; false if none is set. */
static bool push_handler_ref(lua_State *L, int ref) {
	if (ref == LUA_REFNIL) {
		return false;
	}
	lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
	return true;
}

static int l_set_frame_handler(lua_State *L) {
	struct core *core = core_from_lua(L);
	return set_handler_ref(L, &core->frame_handler_ref);
}

static int l_set_event_handler(lua_State *L) {
	struct core *core = core_from_lua(L);
	return set_handler_ref(L, &core->event_handler_ref);
}

static int l_set_lock_handler(lua_State *L) {
	struct core *core = core_from_lua(L);
	return set_handler_ref(L, &core->lock_handler_ref);
}

static void quit_idle(void *data) {
	struct core *core = data;
	wl_display_terminate(core->display);
}

/* core.set_idle_timeout(ms): arm the auto-lock timer for ms of no input; nil
 * or 0 disarms. A top-level verb riding core_input_ops, like core.replay on
 * client_ops. The state machine and the timer live in kiln.c. */
void kiln_set_idle_timeout(struct core *core, int ms) {
	if (core->input_ops.set_idle_timeout != NULL) {
		core->input_ops.set_idle_timeout(core->input_ops.data, ms);
	}
}

void kiln_quit(struct core *core) {
	/* Deferred to the loop: a terminate posted before wl_display_run
	 * (rc.lua quitting at load time) would be overwritten when run
	 * starts; an idle callback survives the transition. */
	wl_event_loop_add_idle(core->loop, quit_idle, core);
}

/* core.replay(): re-emit the map fact for every live client. The reload
 * verb Lua needs and cannot write for itself, because after it drops its client
 * model the compositor is the only one who still knows what is on screen. */
static int l_replay(lua_State *L) {
	struct core *core = core_from_lua(L);
	if (core->client_ops.replay != NULL) {
		core->client_ops.replay(core->client_ops.data);
	}
	return 0;
}

static int timer_fire(void *data) {
	struct core_timer *timer = data;
	struct core *core = timer->core;
	lua_rawgeti(core->L, LUA_REGISTRYINDEX, timer->fn_ref);
	luaL_unref(core->L, LUA_REGISTRYINDEX, timer->fn_ref);
	wl_event_source_remove(timer->source);
	wl_list_remove(&timer->link);
	free(timer);
	core_pcall(core, 0, 0);
	return 0;
}

/* core.timer(ms, fn): fire fn once after ms milliseconds on the compositor
 * loop; returns the id core.timer_cancel takes. One-shot on purpose: a
 * cadence is the callback re-arming itself, so repetition stays a Lua
 * decision. Documented public API: chrome that must move without input, the
 * stock clock being the exemplar, schedules itself through this. */
static int l_timer(lua_State *L) {
	struct core *core = core_from_lua(L);
	int ms = luaL_checkinteger(L, 1);
	luaL_checktype(L, 2, LUA_TFUNCTION);

	struct core_timer *timer = calloc(1, sizeof(*timer));
	timer->core = core;
	lua_pushvalue(L, 2);
	timer->fn_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	timer->source = wl_event_loop_add_timer(core->loop, timer_fire, timer);
	wl_event_source_timer_update(timer->source, ms > 0 ? ms : 1);
	timer->id = ++core->next_timer_id;
	wl_list_insert(&core->timers, &timer->link);
	lua_pushinteger(L, (lua_Integer)timer->id);
	return 1;
}

/* core.timer_cancel(id): disarm a still-pending one-shot. The id
 * source is monotonic, so a fired timer's id is already gone from the list and a
 * cancel on it (or on any unknown id) walks off the end and no-ops. Same
 * teardown as timer_fire, minus the fire. */
void kiln_timer_cancel(struct core *core, uint64_t id) {
	struct core_timer *timer, *tmp;
	wl_list_for_each_safe(timer, tmp, &core->timers, link) {
		if (timer->id != id) {
			continue;
		}
		luaL_unref(core->L, LUA_REGISTRYINDEX, timer->fn_ref);
		wl_event_source_remove(timer->source);
		wl_list_remove(&timer->link);
		free(timer);
		break;
	}
}

/* Child side of a spawn (post-fork): undo the SIGUSR-era mask inheritance,
 * detach, and exec the argv table or shell string at stack index 1. Never
 * returns. Shared by core.spawn and core.spawn_with_token so the two stay one
 * exec path (the env difference is set by the caller before this runs). */
static void spawn_child(lua_State *L) {
	sigset_t mask;
	sigemptyset(&mask);
	sigprocmask(SIG_SETMASK, &mask, NULL);
	setsid();
	if (lua_istable(L, 1)) {
		int argc = lua_objlen(L, 1);
		char **argv = calloc(argc + 1, sizeof(char *));
		for (int i = 0; i < argc; i++) {
			lua_rawgeti(L, 1, i + 1);
			argv[i] = strdup(lua_tostring(L, -1));
			lua_pop(L, 1);
		}
		execvp(argv[0], argv);
	} else {
		execl("/bin/sh", "/bin/sh", "-c", lua_tostring(L, 1), (void *)NULL);
	}
	_exit(127);
}

/* Fire and forget, so the compositor keeps no child to reap: the intermediate
 * forks the process that actually execs and exits immediately, orphaning it
 * onto init. The wait below is for that intermediate alone and returns as soon
 * as it has forked, which is why it can be a blocking one. core.spawn_pipe
 * wants the opposite and keeps its child, because it reports the exit code. */
static void spawn_detached(lua_State *L, const char *token) {
	pid_t pid = fork();
	if (pid == 0) {
		if (fork() != 0) {
			_exit(0);
		}
		/* Set below both forks, so the compositor's own environment is never
		 * the thing carrying it. */
		if (token != NULL) {
			setenv("XDG_ACTIVATION_TOKEN", token, 1);
		}
		spawn_child(L);
	}
	if (pid > 0) {
		waitpid(pid, NULL, 0);
	}
}

static int l_spawn(lua_State *L) {
	if (!lua_istable(L, 1) && !lua_isstring(L, 1)) {
		return luaL_error(L, "core.spawn takes an argv table or a string");
	}
	spawn_detached(L, NULL);
	return 0;
}

/* core.spawn_with_token(cmd): like spawn, but mint an xdg-activation token in
 * the compositor first and hand it to the child via XDG_ACTIVATION_TOKEN, so
 * the launched client can raise itself and the request arbitrates as
 * user-initiated (the mint is seat-backed). The token is minted BEFORE fork
 * because it lives in the compositor's wlroots context; the child inherits the
 * name string in its copied stack, and setenv copies it again. */
static int l_spawn_with_token(lua_State *L) {
	struct core *core = core_from_lua(L);
	if (!lua_istable(L, 1) && !lua_isstring(L, 1)) {
		return luaL_error(L,
			"core.spawn_with_token takes an argv table or a string");
	}
	const char *token = core->activation_ops.mint_token != NULL ?
		core->activation_ops.mint_token(core->activation_ops.data) : NULL;
	spawn_detached(L, token);
	return 0;
}

/* Async spawn: pipe2 the child's stdout and stderr back to the
 * loop, emit each raw read as spawn::out, and one spawn::exit once both streams
 * hit EOF and the child is reaped. Line framing, throttling, and any stdout/stderr
 * merge are Lua's; C moves bytes and reaps. */
struct spawn_pipe {
	struct wl_list link;
	struct core *core;
	uint64_t id;
	pid_t pid;
	struct spawn_stream {
		struct spawn_pipe *pipe;
		int num; /* 1 (stdout) or 2 (stderr), the spawn::out.fd fact */
		int fd; /* -1 once the stream is EOF-closed */
		struct wl_event_source *src;
	} out, err;
	/* The child's exit as an epoll fact of its own: a pidfd, readable exactly
	 * once, when this pid becomes a zombie. -1 once reaped, or from the start
	 * on the fallback path below. */
	int exitfd;
	struct wl_event_source *exit_src;
	bool reaped;
	int code;
};

static void spawn_drop_exitfd(struct spawn_pipe *p) {
	if (p->exit_src != NULL) {
		wl_event_source_remove(p->exit_src);
		p->exit_src = NULL;
	}
	if (p->exitfd != -1) {
		close(p->exitfd);
		p->exitfd = -1;
	}
}

/* The one ordering guarantee: spawn::exit waits for both streams AND the reap,
 * because the exit and pipe-readable are separate epoll facts with no order,
 * and exit-before-final-chunk would be a lie on the one queue. */
static void spawn_maybe_finish(struct spawn_pipe *p) {
	if (p->out.fd != -1 || p->err.fd != -1 || !p->reaped) {
		return;
	}
	spawn_drop_exitfd(p);
	queue_spawn_exit(p->core->queue, p->id, p->code);
	wl_list_remove(&p->link);
	free(p);
}

/* Frees p when the streams are already done, so nothing may touch it after. */
static void spawn_reaped(struct spawn_pipe *p, int status) {
	p->code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
	p->reaped = true;
	spawn_drop_exitfd(p);
	spawn_maybe_finish(p);
}

static int spawn_readable(int fd, uint32_t mask, void *data) {
	(void)mask;
	struct spawn_stream *s = data;
	char buf[4096];
	ssize_t n = read(fd, buf, sizeof(buf));
	if (n > 0) {
		queue_spawn_out(s->pipe->core->queue, s->pipe->id, s->num, buf, n);
		return 0;
	}
	/* EOF (or a hangup with nothing left): retire this stream. */
	wl_event_source_remove(s->src);
	close(fd);
	s->fd = -1;
	spawn_maybe_finish(s->pipe);
	return 0;
}

/* The pidfd went readable, so this child is a zombie and waitpid cannot block. */
static int spawn_exited(int fd, uint32_t mask, void *data) {
	(void)fd;
	(void)mask;
	struct spawn_pipe *p = data;
	int status;
	if (waitpid(p->pid, &status, WNOHANG) != p->pid) {
		/* The fallback reaper below got there first and has already reported
		 * the status; this fd has no second job. */
		spawn_drop_exitfd(p);
		return 0;
	}
	spawn_reaped(p, status);
	return 0;
}

/* The fallback reaper, installed only when pidfd_open fails. It carries the
 * defect pidfd exists to avoid: SIGCHLD is process-directed, so the kernel
 * hands it to any thread that does not block it, and this compositor links
 * libraries whose worker threads clear their own signal mask. Delivered there,
 * SIGCHLD's default action is to ignore it, so the signalfd behind this source
 * never becomes readable and that child is never reaped. */
static int spawn_sigchld(int signal, void *data) {
	(void)signal;
	struct core *core = data;
	int status;
	pid_t pid;
	while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
		struct spawn_pipe *p;
		wl_list_for_each(p, &core->spawn_pipes, link) {
			if (p->pid != pid) {
				continue;
			}
			spawn_reaped(p, status);
			break;
		}
	}
	return 0;
}

static int l_spawn_pipe(lua_State *L) {
	struct core *core = core_from_lua(L);
	if (!lua_istable(L, 1) && !lua_isstring(L, 1)) {
		return luaL_error(L, "core.spawn_pipe takes an argv table or a string");
	}
	/* CLOEXEC on both ends (same reason ipc_connection sets it): a concurrent
	 * core.spawn or this pipe's own exec must not inherit these fds. The child's
	 * dup2 onto 1/2 clears CLOEXEC on the dup targets so those survive exec. */
	int out_fds[2], err_fds[2];
	if (pipe2(out_fds, O_CLOEXEC) != 0) {
		return luaL_error(L, "core.spawn_pipe: pipe2 failed");
	}
	if (pipe2(err_fds, O_CLOEXEC) != 0) {
		close(out_fds[0]);
		close(out_fds[1]);
		return luaL_error(L, "core.spawn_pipe: pipe2 failed");
	}
	pid_t pid = fork();
	if (pid < 0) {
		close(out_fds[0]);
		close(out_fds[1]);
		close(err_fds[0]);
		close(err_fds[1]);
		return luaL_error(L, "core.spawn_pipe: fork failed");
	}
	if (pid == 0) {
		/* Child: dup2 the write ends onto 1 and 2 (dup2 clears O_CLOEXEC so they
		 * survive exec; the read ends and originals stay O_CLOEXEC and close
		 * themselves). spawn_child clears the inherited signal mask, since a
		 * blocked signal survives exec and would otherwise be this compositor's
		 * to hand every process it starts. */
		dup2(out_fds[1], 1);
		dup2(err_fds[1], 2);
		spawn_child(L);
	}
	close(out_fds[1]);
	close(err_fds[1]);
	struct spawn_pipe *p = calloc(1, sizeof(*p));
	p->core = core;
	p->id = ++core->next_spawn_id;
	p->pid = pid;
	p->out.pipe = p;
	p->out.num = 1;
	p->out.fd = out_fds[0];
	p->err.pipe = p;
	p->err.num = 2;
	p->err.fd = err_fds[0];
	p->out.src = wl_event_loop_add_fd(core->loop, p->out.fd,
		WL_EVENT_READABLE, spawn_readable, &p->out);
	p->err.src = wl_event_loop_add_fd(core->loop, p->err.fd,
		WL_EVENT_READABLE, spawn_readable, &p->err);
	/* The exit as an fd rather than as a signal. A pidfd names ONE child and
	 * goes readable when that child does, so the loop learns of the exit the
	 * same way it learns of a readable stream, and a second child exiting can
	 * neither merge with the first nor be delivered to a thread that discards
	 * it. That last part is not hypothetical: a signal-based reaper strands
	 * children here, and a re-arming watch stops after a handful of runs. */
	p->exitfd = (int)syscall(SYS_pidfd_open, pid, 0);
	if (p->exitfd >= 0) {
		p->exit_src = wl_event_loop_add_fd(core->loop, p->exitfd,
			WL_EVENT_READABLE, spawn_exited, p);
	} else if (core->sigchld == NULL) {
		/* No pidfd (pre-5.3): fall back to the signal, lazily, and inherit its
		 * unreliability rather than never reaping at all. */
		core->sigchld = wl_event_loop_add_signal(core->loop, SIGCHLD,
			spawn_sigchld, core);
	}
	wl_list_insert(&core->spawn_pipes, &p->link);
	lua_pushinteger(L, (lua_Integer)p->id);
	return 1;
}

void core_set_queue(struct core *core, struct queue *queue) {
	core->queue = queue;
}

/* --- the frame entry --- */

/* Run one declare pass through the given Lua handler into the current Clay
 * context. Shared by the desktop frame and the native lockscreen; the caller
 * (ui.c) selects the Clay context, this only marshals the handler call. */
static bool core_declare_ref(struct core *core, int handler_ref,
		const char *screen, int width, int height) {
	lua_State *L = core->L;

	/* Hand Lua a fresh anchor table for this pass, at core.__declare (the
	 * in-declare flag the declare verbs check) and in core.__anchors under this
	 * Clay context. The second one is the lifetime: parking this pass's table
	 * releases the one the same context parked last time, which is exactly when
	 * its hashmap stopped pointing at those strings. The key is the context and
	 * not the screen name because a screen has two of them, desktop and lock
	 * (ui.c), and one must not release the other's names. */
	lua_rawgeti(L, LUA_REGISTRYINDEX, core->core_ref);
	lua_getfield(L, -1, "__anchors");
	lua_pushlightuserdata(L, Clay_GetCurrentContext());
	lua_newtable(L);
	lua_pushvalue(L, -1);
	lua_setfield(L, -5, "__declare");
	lua_rawset(L, -3);
	lua_pop(L, 2);

	core->surfaces_len = 0;
	int base = kiln_clay_open_depth();
	bool ok = false;
	if (push_handler_ref(L, handler_ref)) {
		lua_pushstring(L, screen);
		lua_pushinteger(L, width);
		lua_pushinteger(L, height);
		ok = core_pcall(core, 3, 0);
	}

	lua_rawgeti(L, LUA_REGISTRYINDEX, core->core_ref);
	lua_pushnil(L);
	lua_setfield(L, -2, "__declare");
	lua_pop(L, 1);

	/* A failed handler can leave elements open; rebalance so Clay's
	 * EndLayout runs on a consistent tree. Clay's own open stack is the count
	 * now that the opens happen on the Lua side. */
	while (kiln_clay_open_depth() > base) {
		Clay__CloseElement();
	}
	return ok;
}

bool core_declare(struct core *core, const char *screen, int width,
		int height) {
	return core_declare_ref(core, core->frame_handler_ref,
		screen, width, height);
}

/* The native lockscreen's declare, into its own dedicated Clay context (ui.c).
 * A failure here keeps the previous lock frame; the C opaque floor below it
 * means the desktop is never revealed. */
bool core_declare_lock(struct core *core, const char *screen, int width,
		int height) {
	return core_declare_ref(core, core->lock_handler_ref,
		screen, width, height);
}

/* --- the origin event entry (used by queue.c) --- */

struct lua_State *core_state(struct core *core) {
	return core->L;
}

bool core_push_event_handler(struct core *core) {
	return push_handler_ref(core->L, core->event_handler_ref);
}

bool core_call(struct core *core, int nargs) {
	return core_pcall(core, nargs, 0);
}

/* --- the IPC eval socket --- */

struct ipc_client {
	struct core *core;
	struct wl_event_source *source;
	int fd;
	char *buf;
	size_t len, cap;
	/* The assembled reply and how much of it the peer has taken. Non-NULL
	 * from the moment the request is answered, which is also what tells the
	 * one callback below that it is draining rather than reading. */
	char *out;
	size_t out_len, out_off;
};

static void ipc_client_close(struct ipc_client *client) {
	wl_event_source_remove(client->source);
	close(client->fd);
	free(client->buf);
	free(client->out);
	free(client);
}

/* Hand the peer as much of the reply as it will take right now, and answer
 * whether any is still owed. A reply is as long as it is (a client listing on
 * a busy session runs to kilobytes), so it cannot live in a fixed buffer and
 * one send can be short once it exceeds the socket buffer: dropping the tail
 * would hand back a truncated answer indistinguishable from a complete one.
 *
 * Which is why the fd is non-blocking and the remainder waits for a writable
 * event instead of being looped over here. A peer is free to ask for megabytes
 * and then not read them, and a blocking retry loop would sit inside send()
 * with the whole compositor behind it: no input, no frames, no Wayland
 * dispatch for anyone, until that one peer got around to draining.
 *
 * MSG_NOSIGNAL, not write(): a client that quits mid-reply leaves the peer
 * gone, and the default SIGPIPE disposition would take the whole session down
 * with it. Scoped to this send rather than a process-wide SIG_IGN, which would
 * silently change every other write the compositor makes. */
static bool ipc_flush(struct ipc_client *client) {
	while (client->out_off < client->out_len) {
		ssize_t n = send(client->fd, client->out + client->out_off,
			client->out_len - client->out_off, MSG_NOSIGNAL);
		if (n > 0) {
			client->out_off += (size_t)n;
		} else if (n < 0 && errno == EINTR) {
			continue;
		} else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
			return true;
		} else {
			/* The peer is gone. Nothing is owed to it. */
			return false;
		}
	}
	return false;
}

static void ipc_eval(struct ipc_client *client) {
	struct core *core = client->core;
	lua_State *L = core->L;

	if (client->buf == NULL) {
		return;
	}

	/* The request crosses, one reply string comes back. Loading a chunk,
	 * calling it, and joining what it answered with are all Lua's, and doing
	 * them here would be that language's work written as stack arithmetic.
	 * What is left is the crossing and the copy, which is the only part the
	 * socket forces into C. */
	int base = lua_gettop(L);
	lua_getglobal(L, "kiln_eval");
	lua_pushlstring(L, client->buf, client->len);
	if (lua_pcall(L, 1, 1, 0) != 0) {
		/* The reply layer is the thing that failed, so its failure has to be
		 * spelled out here or the socket answers nothing at all. */
		const char *msg = lua_tostring(L, -1);
		lua_pushfstring(L, "ERROR: %s\n", msg != NULL ? msg : "?");
	}

	/* Copied out, because the send may outlive this call by many event-loop
	 * turns and the Lua string is about to be collectable. */
	size_t len = 0;
	const char *reply = lua_tolstring(L, -1, &len);
	if (reply != NULL) {
		client->out = malloc(len);
		if (client->out != NULL) {
			memcpy(client->out, reply, len);
			client->out_len = len;
		}
	}
	lua_settop(L, base);
}

/* Reading and draining are one callback because they are one fd: the mask is
 * flipped to writable once there is a reply to hand back, and client->out is
 * what says which half this is. */
static int ipc_client_ready(int fd, uint32_t mask, void *data) {
	struct ipc_client *client = data;

	if (client->out != NULL) {
		if (!ipc_flush(client)) {
			ipc_client_close(client);
		}
		return 0;
	}

	char chunk[1024];
	ssize_t n = read(fd, chunk, sizeof(chunk));
	if (n > 0) {
		if (client->len + n + 1 > client->cap) {
			client->cap = (client->len + n + 1) * 2;
			client->buf = realloc(client->buf, client->cap);
		}
		memcpy(client->buf + client->len, chunk, n);
		client->len += n;
		client->buf[client->len] = '\0';
		return 0;
	}
	if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
		return 0;
	}
	if (n == 0) {
		ipc_eval(client);
		if (client->out != NULL && ipc_flush(client)) {
			/* The request is fully read, so nothing is lost by giving the
			 * fd over to the tail of the reply. */
			wl_event_source_fd_update(client->source, WL_EVENT_WRITABLE);
			return 0;
		}
	}
	ipc_client_close(client);
	return 0;
}

static int ipc_connection(int fd, uint32_t mask, void *data) {
	struct core *core = data;
	int client_fd = accept(fd, NULL, NULL);
	if (client_fd < 0) {
		return 0;
	}
	/* CLOEXEC, or core.spawn children inherit the connection and the
	 * eval client never sees EOF. NONBLOCK so neither half of the exchange
	 * can hold the event loop: the reply drains on writable events. */
	fcntl(client_fd, F_SETFD, FD_CLOEXEC);
	fcntl(client_fd, F_SETFL, O_NONBLOCK);
	struct ipc_client *client = calloc(1, sizeof(*client));
	client->core = core;
	client->fd = client_fd;
	client->source = wl_event_loop_add_fd(core->loop, client_fd,
		WL_EVENT_READABLE, ipc_client_ready, client);
	return 0;
}

static void ipc_create(struct core *core) {
	/* KILN_SOCK gives an instance a private socket; without it two
	 * instances (a nested session and a headless test run) would steal
	 * the default path from each other. */
	const char *override = getenv("KILN_SOCK");
	if (override != NULL) {
		snprintf(core->ipc_path, sizeof(core->ipc_path), "%s", override);
	} else {
		const char *dir = getenv("XDG_RUNTIME_DIR");
		if (dir == NULL) {
			dir = "/tmp";
		}
		snprintf(core->ipc_path, sizeof(core->ipc_path),
			"%s/kiln.sock", dir);
	}
	unlink(core->ipc_path);

	core->ipc_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	struct sockaddr_un addr = { .sun_family = AF_UNIX };
	snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", core->ipc_path);
	if (bind(core->ipc_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
			listen(core->ipc_fd, 4) < 0) {
		wlr_log(WLR_ERROR, "IPC socket %s failed: %s",
			core->ipc_path, strerror(errno));
		close(core->ipc_fd);
		core->ipc_fd = -1;
		return;
	}
	/* Owner-only, explicitly: connecting to a unix socket needs write
	 * permission on its inode, and bind() takes that from the umask. Under a
	 * real session XDG_RUNTIME_DIR is 0700 and this is redundant, but the
	 * fallback above is /tmp, where a permissive umask would leave the socket
	 * group- or world-connectable. Anything that connects here evaluates
	 * arbitrary Lua in the compositor, which while locked means an
	 * unrate-limited core.authenticate oracle against PAM (the retry backoff is
	 * Layer 2 policy, and IPC does not go through it). Same-UID access is
	 * already total compromise; this only ensures it stays same-UID. */
	if (chmod(core->ipc_path, 0600) < 0) {
		wlr_log(WLR_ERROR, "IPC socket %s: chmod 0600 failed: %s",
			core->ipc_path, strerror(errno));
		close(core->ipc_fd);
		core->ipc_fd = -1;
		unlink(core->ipc_path);
		return;
	}
	core->ipc_source = wl_event_loop_add_fd(core->loop, core->ipc_fd,
		WL_EVENT_READABLE, ipc_connection, core);
	wlr_log(WLR_INFO, "IPC eval socket at %s", core->ipc_path);
}

/* --- lifecycle --- */

/* What C still registers on the Lua stack: the callback registrars and the
 * C-to-Lua paths (rule 2), and the table- and varargs-shaped verbs. Everything
 * else Lua reaches as an exported kiln_* through lua/kiln/cffi.lua, which
 * installs it back under the same name; core.client, core.input and
 * core.output are built wholly there. */
static const struct luaL_Reg core_fns[] = {
	{ "inspector", l_inspector },
	{ "inspector_scroll", l_inspector_scroll },
	{ "screenshot", l_screenshot },
	{ "image_reload", l_image_reload },
	{ "set_frame_handler", l_set_frame_handler },
	{ "set_event_handler", l_set_event_handler },
	{ "set_lock_handler", l_set_lock_handler },
	{ "set_key_bindings", l_set_key_bindings },
	{ "timer", l_timer },
	{ "spawn", l_spawn },
	{ "spawn_with_token", l_spawn_with_token },
	{ "spawn_pipe", l_spawn_pipe },
	{ "replay", l_replay },
	{ NULL, NULL },
};

/* Register each fn as a closure over core into the table on top of the
 * stack. */
static void register_fns(lua_State *L, struct core *core,
		const struct luaL_Reg *fns) {
	for (const struct luaL_Reg *fn = fns; fn->name != NULL; fn++) {
		lua_pushlightuserdata(L, core);
		lua_pushcclosure(L, fn->func, 1);
		lua_setfield(L, -2, fn->name);
	}
}

/* require("kiln") must resolve for whichever rc.lua we run, and the config
 * never sets package.path itself. Prepend the lua/ subtree of the rc's own
 * directory and of the cwd: the first serves a config living in a checkout,
 * the second serves the batteries, which generate an rc under /tmp but launch
 * from the repo root. When installed, append the datadir's lua/ subtree so a
 * user config with no library beside it finds the packaged one. */
static void add_package_path(lua_State *L, const char *rc_path) {
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "path");            /* package, path */

	lua_pushstring(L, "lua/?.lua;lua/?/init.lua;");
	lua_pushvalue(L, -2);                   /* old path */
	lua_concat(L, 2);
	lua_replace(L, -2);                     /* package, newpath */

	const char *slash = strrchr(rc_path, '/');
	if (slash != NULL) {
		lua_pushlstring(L, rc_path, slash - rc_path + 1);
		lua_pushstring(L, "?.lua;");
		lua_pushvalue(L, -2);               /* dir */
		lua_pushstring(L, "lua/?.lua;");
		lua_pushvalue(L, -4);               /* dir */
		lua_pushstring(L, "lua/?/init.lua;");
		lua_pushvalue(L, -7);               /* old path */
		lua_concat(L, 7);   /* "<dir>?.lua;<dir>lua/?.lua;<dir>lua/?/init.lua;" .. old */
		lua_replace(L, -2);                 /* package, newpath */
	}

#ifdef KILN_DATADIR
	lua_pushvalue(L, -1);
	lua_pushstring(L, ";" KILN_DATADIR "/lua/?.lua;" KILN_DATADIR "/lua/?/init.lua");
	lua_concat(L, 2);
	lua_replace(L, -2);                     /* package, newpath */
#endif

	lua_setfield(L, -2, "path");
	lua_pop(L, 1);
}

struct core *core_create(struct wl_display *display, struct ui *ui,
		const char *rc_path) {
	struct core *core = calloc(1, sizeof(*core));
	core->ui = ui;
	core->display = display;
	core->loop = wl_display_get_event_loop(display);
	core->frame_handler_ref = LUA_REFNIL;
	core->event_handler_ref = LUA_REFNIL;
	core->lock_handler_ref = LUA_REFNIL;
	wl_list_init(&core->timers);
	wl_list_init(&core->spawn_pipes);
	core->ipc_fd = -1;

	core->L = luaL_newstate();
	luaL_openlibs(core->L);
	add_package_path(core->L, rc_path);

	/* core.* with the core pointer as shared upvalue; each verb closes over
	 * core. core.client, core.input and core.output are built in cffi.lua,
	 * which is where every verb of theirs now lives. */
	lua_newtable(core->L);
	register_fns(core->L, core, core_fns);
	/* The one thing the FFI boundary needs from this side: the core it
	 * addresses. lua/kiln/cffi.lua casts it once and passes it back to the
	 * exported kiln_* verbs; it is opaque there and never dereferenced. */
	lua_pushlightuserdata(core->L, core);
	lua_setfield(core->L, -2, "__ptr");
	/* One entry per live Clay context, holding that context's last declare
	 * pass's anchor table (the struct core comment above). Nothing
	 * prunes it: a destroyed output leaves its last frame's strings parked
	 * under a dead address, bounded by the outputs a session ever had, and a
	 * recycled address is overwritten by that new context's first declare. */
	lua_newtable(core->L);
	lua_setfield(core->L, -2, "__anchors");
	lua_pushvalue(core->L, -1);
	lua_setglobal(core->L, "core");
	/* Kept in the registry too: every declare pass installs this pass's anchor
	 * table on it, and a registry index is cheaper than a global lookup. */
	core->core_ref = luaL_ref(core->L, LUA_REGISTRYINDEX);

	ipc_create(core);

	if (luaL_loadfile(core->L, rc_path) != 0) {
		fprintf(stderr, "cannot load %s: %s\n", rc_path,
			lua_tostring(core->L, -1));
		lua_pop(core->L, 1);
	} else if (core_pcall(core, 0, 0)) {
		wlr_log(WLR_INFO, "loaded %s", rc_path);
	}
	return core;
}

void core_destroy(struct core *core) {
	struct core_timer *timer, *tmp;
	wl_list_for_each_safe(timer, tmp, &core->timers, link) {
		wl_event_source_remove(timer->source);
		wl_list_remove(&timer->link);
		free(timer);
	}
	if (core->ipc_source != NULL) {
		wl_event_source_remove(core->ipc_source);
		close(core->ipc_fd);
		unlink(core->ipc_path);
	}
	lua_close(core->L);
	free(core->surfaces);
	free(core->bindings);
	free(core);
}
