#ifndef KILN_CORE_H
#define KILN_CORE_H

#include <stdbool.h>
#include <stdint.h>

struct lua_State;
struct wl_display;
struct ui;
struct queue;

struct core;

/* Client verbs: one protocol action each, on a generation-checked handle.
 * Implemented by kiln.c; a stale handle is a checked no-op there. */
struct core_client_ops {
	void (*focus)(void *data, uint64_t handle);
	void (*configure)(void *data, uint64_t handle, int width, int height);
	void (*close_client)(void *data, uint64_t handle);
	void (*kill_client)(void *data, uint64_t handle);
	void (*set_activated)(void *data, uint64_t handle, bool on);
	void (*set_fullscreen_hint)(void *data, uint64_t handle, bool on);
	void (*set_maximized_hint)(void *data, uint64_t handle, bool on);
	void (*set_tiled_hint)(void *data, uint64_t handle, uint32_t edges);
	void (*set_suspended)(void *data, uint64_t handle, bool on);
	void (*set_minimized_hint)(void *data, uint64_t handle, bool on);
	/* The foreign-toplevel output mirror: name is the connector string of the
	 * screen the client is declared on, NULL to leave every output. */
	void (*set_output_mirror)(void *data, uint64_t handle, const char *name);
	/* Re-emit the map fact for every mapped toplevel, so a Lua layer that
	 * dropped its client model can rebuild it. No handle: the compositor
	 * holds the client list, and which clients exist is exactly what the caller
	 * has forgotten. */
	void (*replay)(void *data);
	void *data;
};
void core_set_client_ops(struct core *core,
	const struct core_client_ops *ops);

/* The xkb names a whole-map replacement is built from (no incremental
 * xkb surface: the map is replaced or nothing). NULL means the xkb default. */
struct core_keymap {
	const char *rules;
	const char *model;
	const char *layout;
	const char *variant;
	const char *options;
};

/* libinput pointer config (whole-value setters, nil fields untouched, so
 * each field carries its own set flag). Applied to every pointer device;
 * per-device targeting is the named absence. Enum-valued fields stay strings at
 * this boundary and are resolved against libinput's own enums in kiln.c, so
 * core keeps no table of libinput's vocabulary. */
struct core_pointer_config {
	bool has_tap_to_click;      bool tap_to_click;
	bool has_natural_scrolling; bool natural_scrolling;
	bool has_left_handed;       bool left_handed;
	bool has_accel_speed;       double accel_speed;   /* -1.0 .. 1.0 */
	bool has_accel_profile;     const char *accel_profile;  /* flat|adaptive */
	bool has_scroll_method;     const char *scroll_method;
	bool has_click_method;      const char *click_method;
};

/* Input verbs. grab_pointer(on) routes cursor motion to Lua policy only
 * (interactive move/resize): while grabbed, C forwards nothing to the
 * surface under the pointer, but still emits motion, button, and axis events.
 * grab_keyboard(on) is the same single routing bit for keys: while on, every
 * key still enqueues and none forwards to a client. Neither is a state
 * machine. Who holds a grab is a Lua-side claim on the one queue, and C never
 * learns it: a C-side grabber identity would be a second dispatch authority
 * for the same events. Implemented by kiln.c. */
struct core_input_ops {
	void (*grab_pointer)(void *data, bool on);
	void (*grab_keyboard)(void *data, bool on);
	void (*set_cursor)(void *data, const char *name);
	void (*set_keymap)(void *data, const struct core_keymap *names);
	void (*set_repeat)(void *data, int rate, int delay);
	void (*set_numlock)(void *data, bool on);
	void (*set_pointer)(void *data, const struct core_pointer_config *cfg);
	/* set_cursor_theme(name, size): swap the xcursor theme manager. The
	 * per-scale load stays wlroots': it reloads the named theme at each output's
	 * live scale on the next image lookup. A NULL
	 * name restores the env default. */
	void (*set_cursor_theme)(void *data, const char *name, int size);
	/* set_idle_timeout(ms): arm the auto-lock timer for ms of no input (0
	 * disarms), the one fact the public API could not express.
	 * kiln.c owns the timer because, while natively locked, input never
	 * reaches Lua, so only the C input sites hold the
	 * complete activity fact a re-arm needs. Rides this seat-scope struct like a
	 * top-level verb (core.replay's precedent on client_ops). */
	void (*set_idle_timeout)(void *data, int ms);
	void *data;
};
void core_set_input_ops(struct core *core,
	const struct core_input_ops *ops);

/* The one layer-shell verb: Lua's answer to the layer::map/commit facts.
 * Sends the protocol configure for width x height; no other configure path
 * for layer surfaces exists in C. Implemented by
 * kiln.c; a stale handle is a checked no-op. */
struct core_layer_ops {
	void (*configure)(void *data, uint64_t handle, int width, int height);
	void *data;
};
void core_set_layer_ops(struct core *core,
	const struct core_layer_ops *ops);

/* Native session lock verbs. lock engages the compositor's own
 * lockscreen (the quarantine + opaque floor); unlock is C-gated on a prior
 * authenticate success, so Lua alone can never disengage it; authenticate runs
 * the PAM check. Each returns whether the action took effect. Implemented by
 * kiln.c. The lock/unlock facts also reach Lua as informational session::*
 * origin events it cannot veto. */
struct core_lock_ops {
	bool (*lock)(void *data);
	bool (*unlock)(void *data);
	bool (*authenticate)(void *data, const char *password);
	void *data;
};
void core_set_lock_ops(struct core *core,
	const struct core_lock_ops *ops);

/* Activation: mint an xdg-activation token seat-backed by the current seat and
 * return its exportable name (owned by wlroots). core.spawn_with_token sets
 * XDG_ACTIVATION_TOKEN to it so a launched client can raise itself with a token
 * that arbitrates as user-initiated. Implemented by kiln.c. */
struct core_activation_ops {
	const char *(*mint_token)(void *data);
	void *data;
};
void core_set_activation_ops(struct core *core,
	const struct core_activation_ops *ops);

/* Notifications: the two verbs that close the DBus loop, each ONE signal
 * emission and nothing else. Lua decided a
 * notification is gone and why, so closed() emits NotificationClosed; Lua
 * dispatched an action button, so action() emits ActionInvoked. Neither
 * consults any C-side notification, because none exists: reason is the protocol
 * integer (1 expired, 2 dismissed, 3 closed by call, 4 undefined) and the map
 * from Lua's reason names to it lives in Lua. Implemented by notify.c. */
struct core_notify_ops {
	void (*closed)(void *data, uint32_t id, int reason);
	void (*action)(void *data, uint32_t id, const char *key);
	void *data;
};
void core_set_notify_ops(struct core *core,
	const struct core_notify_ops *ops);

/* Systray: the one verb that forwards a click, a single DBus method call on the
 * item and nothing else. kind is "activate" or
 * "secondary" (a and b are the pointer x,y for those) or "scroll" (a is the
 * delta, b the orientation "vertical"/"horizontal"). C holds no tray state; a
 * service that named nothing still alive is the item's problem to answer or drop.
 * Implemented by tray.c. */
struct core_tray_ops {
	void (*activate)(void *data, const char *service, const char *kind,
		int a, const char *b);
	void *data;
};
void core_set_tray_ops(struct core *core, const struct core_tray_ops *ops);

/* Output verbs: write-only, one wlroots call each, targeted by connector
 * name; a stale name is a checked no-op in kiln.c. Facts flow back through the
 * `output change` origin event (kiln.c emits it after a successful apply); the
 * one read is list(), which fills a caller-owned array of core_output_info and
 * returns the count (the l_hits shape). Implemented by kiln.c. */
struct core_output_mode {
	int width, height, refresh;
};
struct core_output_info {
	char name[64];
	int width, height, refresh;
	double scale;
	int x, y;
	bool enabled;
	struct core_output_mode modes[32];
	int modes_len;
};
struct core_output_ops {
	int (*list)(void *data, struct core_output_info *out, int max);
	void (*set_mode)(void *data, const char *name, int w, int h, int refresh);
	void (*set_scale)(void *data, const char *name, double scale);
	void (*set_position)(void *data, const char *name, int x, int y);
	void (*set_enabled)(void *data, const char *name, bool on);
	void (*set_adaptive_sync)(void *data, const char *name, bool on);
	/* core.tick(screen, on): while on, keep that output's frame clock scheduled
	 * and enqueue frame::tick with the true frame delta each frame.
	 * Mechanism only; easing, dt clamp, and duration are Lua's. */
	void (*tick)(void *data, const char *name, bool on);
	/* core.screenshot(screen[, path]): read that output's
	 * composed scene into the image cache and return the cache key (owned by
	 * kiln.c, stable until the next screenshot), usable as an image source. With
	 * a path, also write the surface to a PNG. NULL on a stale name or a failed
	 * readback. */
	const char *(*screenshot)(void *data, const char *name,
		const char *save_path);
	void *data;
};
void core_set_output_ops(struct core *core, const struct core_output_ops *ops);

/* The FFI boundary: verbs Lua calls
 * through ffi.C instead of the Lua stack, exported for the executable's dynamic
 * symbol table. The core pointer arrives from Lua as the lightuserdata core.c
 * stores at core.__ptr. Arguments are validated in lua/kiln/cffi.lua, at the
 * public edge; these trust their caller. lua/kiln/cffi.lua's cdef is compiled
 * against these declarations by the generated guard (scripts/gen-cdef-guard.py),
 * so a cdef that drifts fails the build.
 *
 * Each is one verb of the primitive namespace, named for the core.* path Lua
 * calls it by; the contract of each is the comment over its body in core.c. */
void kiln_dirty(struct core *core, const char *name);
void kiln_tick(struct core *core, const char *name, bool on);
void kiln_quit(struct core *core);
void kiln_timer_cancel(struct core *core, uint64_t id);
void kiln_set_idle_timeout(struct core *core, int ms);
void kiln_layer_configure(struct core *core, uint64_t handle,
	int width, int height);
bool kiln_lock(struct core *core);
bool kiln_unlock(struct core *core);
bool kiln_authenticate(struct core *core, const char *password);
void kiln_notify_closed(struct core *core, uint32_t id, int reason);
void kiln_notify_action(struct core *core, uint32_t id, const char *key);
void kiln_tray_activate(struct core *core, const char *service,
	const char *kind, int a, const char *b);

void kiln_client_focus(struct core *core, uint64_t handle);
void kiln_client_configure(struct core *core, uint64_t handle,
	int width, int height);
void kiln_client_close(struct core *core, uint64_t handle);
void kiln_client_kill(struct core *core, uint64_t handle);
void kiln_client_set_activated(struct core *core, uint64_t handle, bool on);
void kiln_client_set_fullscreen_hint(struct core *core, uint64_t handle,
	bool on);
void kiln_client_set_maximized_hint(struct core *core, uint64_t handle,
	bool on);
void kiln_client_set_tiled_hint(struct core *core, uint64_t handle,
	uint32_t edges);
void kiln_client_set_suspended(struct core *core, uint64_t handle, bool on);
void kiln_client_set_minimized_hint(struct core *core, uint64_t handle,
	bool on);
void kiln_client_set_output_mirror(struct core *core, uint64_t handle,
	const char *name);

void kiln_input_grab_pointer(struct core *core, bool on);
void kiln_input_grab_keyboard(struct core *core, bool on);
void kiln_input_set_keymap(struct core *core, struct core_keymap names);
void kiln_input_set_repeat(struct core *core, int rate, int delay);
void kiln_input_set_numlock(struct core *core, bool on);
void kiln_input_set_pointer(struct core *core, struct core_pointer_config cfg);
void kiln_input_set_cursor(struct core *core, const char *name);
void kiln_input_set_cursor_theme(struct core *core, const char *name, int size);

void kiln_output_set_mode(struct core *core, const char *name,
	int w, int h, int refresh);
void kiln_output_set_scale(struct core *core, const char *name, double scale);
void kiln_output_set_position(struct core *core, const char *name, int x, int y);
void kiln_output_set_enabled(struct core *core, const char *name, bool on);
void kiln_output_set_adaptive_sync(struct core *core, const char *name, bool on);

/* The three readbacks. Data crosses by value: hits and output_list fill
 * an out-array the caller owns and sizes, and box answers with this struct.
 * Nothing here is retained
 * on the Lua side past the conversion to plain tables. struct ui_hit is ui.h's;
 * a pointer to it needs no definition here, and the cdef guard is compiled
 * against ui.h so its layout is pinned like the rest. */
struct ui_hit;

/* Boxes cross as half-up-rounded integers, once, in C (the core.box contract):
 * Lua px are screen px, so re-declaring a read-back box moves nothing. found is
 * false for an id that was never declared and before the first solve; Lua turns
 * that into nil. */
struct core_box {
	bool found;
	int x, y, width, height;
};

/* No core parameter: the Clay context this reads is Clay's own global, and the
 * deleted wrapper only wanted core to reach the lua_State it marshalled with. */
struct core_box kiln_box(const char *name, int32_t name_len, uint32_t index);
int kiln_hits(struct core *core, const char *screen, double x, double y,
	struct ui_hit *out, int max);
int kiln_output_list(struct core *core, struct core_output_info *out, int max);

/* The declare path. core.open, core.close and core.text fill one scratch
 * Clay_ElementDeclaration in lua/kiln/cffi.lua, reused across frames, and call
 * Clay__OpenElement, Clay__ConfigureOpenElementPtr and Clay__CloseElement
 * themselves. Only pointers to Clay types cross, so forward declarations are
 * all this header needs; the cdef carries the layouts and the guard pins them.
 *
 * These four exist because the Lua side cannot do them without allocating or
 * without reaching past clay.h's public surface. A Clay call that answers with
 * a value boxes one cdata per element per frame in the interpreter and at
 * trace exits; on compiled traces LuaJIT sinks the box. What these buy is the
 * unsunk remainder and the narrower clay.h surface. */
struct Clay_ElementDeclaration;
struct Clay_ElementId;
struct Clay_ImageElementConfig;
struct Clay_String;
struct Clay_TextElementConfig;

/* Clay__HashString answers with a Clay_ElementId by value. Writes it into out
 * (NULL to skip) and returns the hash alone, which is what a floating parentId
 * takes. Both id shapes are one call: a plain string is index 0. */
uint32_t kiln_hash_id(const char *name, int32_t name_len, uint32_t index,
	struct Clay_ElementId *out);

/* Clay__StoreTextElementConfig answers with a pointer into Clay's per-frame
 * config array, which is the only place a text config may live. */
void kiln_text(const struct Clay_String *text,
	const struct Clay_TextElementConfig *config);

/* imageData is the stable cache entry pointer; Clay retains it across the solve
 * and ui_image_get copies the path. Written into the declaration's image config
 * rather than returned, for the same no-boxing reason. */
void kiln_image(struct core *core, const char *path,
	struct Clay_ImageElementConfig *out);

/* core.surface(handle, decl?): the place-leaf. The declaration is Lua's, filled
 * into the same scratch; everything the place-leaf contract asks for is here.
 * NULL decl means the grow/grow default. False means this handle was already
 * declared this frame, which the caller turns into an error. */
bool kiln_surface(struct core *core, uint64_t handle,
	const struct Clay_ElementDeclaration *decl);

/* The depth of Clay's open-element stack, defined in clay_impl.c because
 * Clay_Context exists only inside CLAY_IMPLEMENTATION. With the declare verbs on
 * the Lua side, this is how core_declare_ref rebalances a pass that left
 * elements open. */
int kiln_clay_open_depth(void);

/* Synchronous key consume filter: true if Lua registered this exact
 * chord via core.set_key_bindings, meaning C must not forward the key
 * to the focused client. mods is the wlroots modifier mask. */
bool core_key_bound(struct core *core, uint32_t keysym, uint32_t mods);

/* Boots LuaJIT, registers the core.* primitives, opens the IPC eval socket,
 * and runs rc_path. A missing or broken rc.lua logs and leaves the frame
 * handler unset; the compositor keeps running. */
struct core *core_create(struct wl_display *display, struct ui *ui,
	const char *rc_path);
void core_destroy(struct core *core);

/* The origin event queue back-pointer, set by kiln.c right after queue_create.
 * core.spawn_pipe emits spawn::out/spawn::exit through it. */
void core_set_queue(struct core *core, struct queue *queue);

/* Runs the Lua frame handler for one screen, between Clay_BeginLayout and
 * Clay_EndLayout. Returns false if the handler errored (or is unset); the
 * caller then keeps the previous frame. */
bool core_declare(struct core *core, const char *screen, int width, int height);

/* Runs the Lua lock frame handler (core.set_lock_handler) for one screen into
 * the caller's current Clay context. Same contract as core_declare; used by
 * ui.c to draw the native lockscreen into its dedicated lock render target. */
bool core_declare_lock(struct core *core, const char *screen,
	int width, int height);

/* For the origin event queue: push the Lua event handler (false if none is
 * registered), marshal arguments onto core_state, then core_call. Every
 * entry runs under pcall with a traceback handler. */
struct lua_State *core_state(struct core *core);
bool core_push_event_handler(struct core *core);
bool core_call(struct core *core, int nargs);

#endif
