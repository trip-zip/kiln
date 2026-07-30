#ifndef KILN_QUEUE_H
#define KILN_QUEUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct core;
struct wl_event_loop;

struct queue;

/* The origin event queue: protocol facts collected from wlroots listeners
 * and delivered, one table per event, to the single Lua dispatch entry
 * (the handler set with core.set_event_handler). Delivery is deferred to
 * an idle callback so Lua never runs inside a wlroots signal emission. */
struct queue *queue_create(struct core *core, struct wl_event_loop *loop);
void queue_destroy(struct queue *queue);

/* X11 hint facts riding client::map and client::metadata: payload growth on
 * the existing events, never new events, so
 * Lua stays surface-kind-agnostic. NULL for xdg clients; absent fields
 * marshal as nil. transient_for is the parent's handle (0 = none).
 * window_type is the recognized EWMH _NET_WM_WINDOW_TYPE names comma-joined
 * in CLIENT order, never ranked (ranking a client's own preference list would
 * be C deciding what was left to policy); NULL when the
 * client set none we recognize. wants_focus is wlroots' ICCCM answer for an
 * override-redirect window and marshals only alongside that flag. */
struct queue_client_hints {
	const char *class;
	const char *instance;
	const char *window_type;
	int pid;
	uint64_t transient_for;
	bool override_redirect;
	bool wants_focus;
	/* The state the client already holds at map, on both kinds.
	 * A window can open in a state instead of
	 * asking for one: an X11 client writes _NET_WM_STATE on the window
	 * before it maps, and xdg-shell lets a client set_fullscreen before its
	 * initial commit. Neither reaches the request events (the X11 one is
	 * property state wlroots never signals, the xdg one fires before any
	 * client object exists), so it rides the map payload like every other
	 * fact the client already holds. Snapshot, never policy: C acts on none
	 * of them. */
	bool fullscreen;
	bool maximized;
	bool minimized;
	/* Two more X11-only facts. role is WM_WINDOW_ROLE
	 * verbatim, the identity a rule keys on beyond the class (a "pop-up" vs a
	 * "browser" of the same app); NULL when unset. icon is not pixels: C has
	 * already decoded the largest _NET_WM_ICON into the image cache under this
	 * key, so what rides the payload is the KEY ("xwl-icon:<handle>"), the same
	 * message-keyed convention notify/tray use. NULL when the client set no
	 * icon we could read. */
	const char *role;
	const char *icon;
};

void queue_client_map(struct queue *queue, uint64_t handle,
	int x, int y, int width, int height,
	const char *app_id, const char *title,
	const struct queue_client_hints *hints);
void queue_client_unmap(struct queue *queue, uint64_t handle);
void queue_client_destroy(struct queue *queue, uint64_t handle);
void queue_client_commit_size(struct queue *queue, uint64_t handle,
	int width, int height);
void queue_client_metadata(struct queue *queue, uint64_t handle,
	const char *app_id, const char *title,
	const struct queue_client_hints *hints);
/* An X11 client asked to place or size itself (there is no xdg analog).
 * The fact is reported and Lua decides: a tiled config ignores it and
 * re-declares, floating policy may honor it. C obeys verbatim only where
 * the protocol leaves no freedom (pre-map, and override-redirect). */
void queue_client_request_configure(struct queue *queue, uint64_t handle,
	int x, int y, int width, int height);
/* ICCCM urgency (WM_HINTS) flipped; part of the request family.
 * Whether urgent becomes focus, a badge, or nothing is Lua policy. */
void queue_client_urgent(struct queue *queue, uint64_t handle, bool urgent);
/* The client asked for a state. One event
 * per request from either shell; C answers none of them, sets no state, and
 * resizes nothing. Lua honors or ignores, and mirrors what it decided back
 * with the set_*_hint verbs.
 *
 * on is the state the client asked FOR, so an unset request is the same event
 * with on=false. Two readings of minimize, both protocol facts: X11 carries
 * the bool (wlr_xwayland_minimize_event.minimize), while xdg is constantly
 * true, since xdg-shell has no un-minimize request. */
void queue_client_request_fullscreen(struct queue *queue, uint64_t handle,
	bool on);
void queue_client_request_maximize(struct queue *queue, uint64_t handle,
	bool on);
void queue_client_request_minimize(struct queue *queue, uint64_t handle,
	bool on);
/* A taskbar asked to close this client, through wlr-foreign-toplevel's
 * request_close. No client-side protocol carries a close ASK (the xdg/xwl close
 * verbs are compositor->client), so this is the one origin event
 * foreign-toplevel adds; it rides the same queue path as the rest, and
 * Lua's replaceable default answers it with the close verb. */
void queue_client_request_close(struct queue *queue, uint64_t handle);
/* The client's preferred xdg-decoration mode ("client_side", "server_side", or
 * "none"), a fact for Lua policy: the compositor forces server-side regardless,
 * and titlebar presence is Lua declaring one or not. */
void queue_client_decoration_mode(struct queue *queue, uint64_t handle,
	const char *mode);
/* An xdg-activation request to raise this client. valid is the one protocol
 * fact Lua arbitrates on: the token reached us with a seat, meaning it was
 * minted from a validated recent input event (user-initiated) rather than a
 * background steal. app_id is the token's app_id hint (may be NULL). C decides
 * nothing: whether this becomes a focus or an urgent flag is Lua policy. */
void queue_client_activate(struct queue *queue, uint64_t handle,
	bool valid, const char *app_id);

/* mods is the wlroots modifier mask; it is resolved to named booleans
 * before Lua sees it. keyname is the xkb keysym name. utf8 is the composed
 * text of the keysym (xkb compose resolved C-side), empty mid-compose and on
 * release; NULL is treated as empty. */
void queue_key(struct queue *queue, uint32_t keysym, const char *keyname,
	const char *utf8, uint32_t mods, bool pressed);
/* screen is the output name under the pointer (NULL if none), so Lua hit
 * tests the right screen; mods is resolved to named booleans like keys.
 * client is the handle of the topmost client surface at the cursor (0 if the
 * topmost real node is chrome or nothing): the scene is the hit authority, so
 * Lua trusts this for chrome-vs-client instead of re-deriving it from Clay. */
void queue_button(struct queue *queue, uint32_t button, bool pressed,
	double x, double y, const char *screen, uint32_t mods, uint64_t client);
/* Motion coalesces (latest wins). screen is the output under the cursor and
 * client the topmost client handle (0 for chrome/none), the same scene-first
 * facts button/axis carry, so a hover routes chrome-vs-client like a click. */
void queue_motion(struct queue *queue, double x, double y,
	const char *screen, uint64_t client);
/* dx/dy are the scroll deltas (one axis nonzero per event); x/y the cursor
 * position, screen the output under it, mods resolved like keys/buttons,
 * client the topmost client surface handle (0 if chrome/none), as for button. */
void queue_axis(struct queue *queue, double dx, double dy,
	double x, double y, const char *screen, uint32_t mods, uint64_t client);
/* handle 0 means the pointer left every client surface. */
void queue_pointer_enter(struct queue *queue, uint64_t handle);

void queue_output_add(struct queue *queue, const char *name);
void queue_output_remove(struct queue *queue, const char *name);
void queue_output_change(struct queue *queue, const char *name);

/* frame::tick { screen, dt }: one per output frame while
 * core.tick is on for that output. dt is the true frame delta in seconds,
 * delivered raw; the large resume dt is clamped in Lua, not here. */
void queue_frame_tick(struct queue *queue, const char *screen, double dt);

/* Layer-shell facts, filled by kiln.c from the surface's committed state.
 * layer_name is the protocol layer verbatim ("background", "bottom", "top",
 * "overlay"); the band it declares into is Lua's mapping, C has no band
 * vocabulary. output may be NULL (the client let the compositor choose;
 * placement is then Lua's). width/height are the client's DESIRED size
 * (0 = compositor assigns, legal only when anchored to both opposite
 * edges); the answered size arrives via layer_configure, never from C. */
struct queue_layer_facts {
	uint64_t handle;
	const char *namespace_;
	const char *output;
	const char *layer_name;
	const char *interactivity; /* "none", "exclusive", "on_demand" */
	bool anchor_top, anchor_bottom, anchor_left, anchor_right;
	int32_t exclusive;
	int32_t margin_top, margin_right, margin_bottom, margin_left;
	uint32_t width, height;
};

/* layer::map is the surface's initial commit: the "wants to map" fact the
 * client blocks on until Lua answers with layer_configure (no C fallback
 * configure exists). layer::commit is a later commit that
 * changed the surface's declared state, same payload. */
void queue_layer_map(struct queue *queue,
	const struct queue_layer_facts *facts);
void queue_layer_commit(struct queue *queue,
	const struct queue_layer_facts *facts);
void queue_layer_unmap(struct queue *queue, uint64_t handle);
void queue_layer_destroy(struct queue *queue, uint64_t handle);

/* Notifications. C answers the DBus method and reports
 * the facts; it holds no notification, expires nothing, places nothing, ranks
 * nothing. id is minted by the service (the Notify reply is synchronous, so C
 * must answer before Lua could see the event); replaces_id is the client's own
 * (0 = none), and Lua decides what replacing means.
 *
 * The hint treatment: exactly two
 * hints are typed, because two are all that need code. urgency is the byte
 * resolved to its name ("low"/"normal"/"critical"; NULL when the client set
 * none, and the default is Lua's). image is the image-cache KEY of the
 * image-data hint's pixels, which the service decoded and put in the cache; the
 * event never carries pixels. Every other scalar hint rides `hints` verbatim,
 * image-path and value and category included, and containers are dropped.
 * C ranks nothing: which image fact wins is the display's decision, in Lua.
 *
 * expire_timeout is the client's, in ms, verbatim: -1 means "server decides"
 * and 0 means "never", and both are Lua's to interpret. */
enum queue_hint_type {
	QUEUE_HINT_STRING,
	QUEUE_HINT_NUMBER,
	QUEUE_HINT_BOOL,
};

struct queue_hint {
	char *key;
	enum queue_hint_type type;
	char *str;
	double num;
	bool boolean;
};

struct queue_action {
	char *key;
	char *label;
};

struct queue_notify_facts {
	uint32_t id;
	uint32_t replaces_id;
	const char *app_name;
	const char *app_icon;
	const char *summary;
	const char *body;
	const char *urgency;
	const char *image;
	int32_t expire_timeout;
	/* Both arrays are handed over: the queue takes ownership of the arrays and
	 * of every string in them, and frees them with the event. */
	struct queue_action *actions;
	size_t actions_len;
	struct queue_hint *hints;
	size_t hints_len;
};

void queue_notify(struct queue *queue, const struct queue_notify_facts *facts);
/* CloseNotification: the client asked. C closes nothing; Lua dismisses, and the
 * NotificationClosed signal goes out when Lua calls core.notify_closed. */
void queue_notify_close(struct queue *queue, uint32_t id);

/* Systray. The SNI watcher proxies each
 * StatusNotifierItem: C owns the name, reads the item's properties, and reports
 * them. It ranks nothing and shows nothing; where a tray sits, which theme
 * resolves a name, and whether an item is drawn are Lua's.
 *
 * tray::item is an upsert, keyed by service (the item's bus name): the same
 * service arriving again is the same item with new facts, and Lua updates in
 * place. icon is the image-cache KEY of the item's IconPixmap, which the watcher
 * decoded and put in the cache; an item that ships no pixmap and only an
 * IconName passes the NAME through here instead (icon is then that name, and the
 * theme lookup over it is Lua policy). id/title/status are the SNI properties
 * verbatim; any may be NULL and marshals as nil. */
struct queue_tray_facts {
	const char *service;
	const char *id;
	const char *title;
	const char *status;
	const char *icon;
};

void queue_tray_item(struct queue *queue, const struct queue_tray_facts *facts);
/* The item unregistered or its bus name vanished. C drops it; Lua removes it. */
void queue_tray_gone(struct queue *queue, const char *service);

/* Session lock: the engage/disengage of a lock is an informational
 * origin event Lua cannot veto. kind is "ext" (an external ext-session-lock-v1
 * client) or "native" (the compositor's own core.lock lockscreen). */
void queue_session_lock(struct queue *queue, const char *kind);
void queue_session_unlock(struct queue *queue);

/* The native lockscreen's key channel. While natively locked C emits keys HERE
 * and never as input::key, so the desktop binding dispatch (which reads
 * input::key) is unreachable and no chord can fire under the lockscreen, no
 * matter what the config does. Same payload as input::key. This is the one
 * thing that makes "no bypass" a C guarantee rather than a Lua promise. */
void queue_session_key(struct queue *queue, uint32_t keysym,
	const char *keyname, const char *utf8, uint32_t mods, bool pressed);

/* DnD. The drag grab is wlroots' own; these two
 * are informational origin events Lua cannot veto, zero-payload like
 * session::unlock. drag::start fires when the seat begins the drag (the icon,
 * if any, is already parented into the cursor band when this drains); drag::end
 * fires once for BOTH outcomes, a drop and a cancel, because the compositor
 * arbitrates neither. No target, no action, no drop policy reaches Lua: a
 * C leg deciding any of those would be C owning policy, refused. */
void queue_drag_start(struct queue *queue);
void queue_drag_end(struct queue *queue);

/* Async spawn. spawn::out { id, fd, data } is one raw read
 * chunk from a spawned child's stdout (fd 1) or stderr (fd 2); C inspects none
 * of the bytes, so the line split is Lua's. spawn::exit { id, code } fires once,
 * after both streams reach EOF AND the child is reaped; code is the exit status,
 * 128 + signal for a killed child (shell convention). */
void queue_spawn_out(struct queue *queue, uint64_t id, int fd,
	const char *data, size_t len);
void queue_spawn_exit(struct queue *queue, uint64_t id, int code);

/* Idle. The auto-lock leg the public API could not express.
 * idle::start fires when the idle timer (core.set_idle_timeout) elapses with no
 * input; idle::stop fires on the first input after, and the two strictly
 * alternate. Both are zero-payload facts: C locks nothing, blanks nothing, dims
 * nothing, and whether idle::start becomes kiln.lock is the config's line.
 * idle::inhibit { on } is the existing inhibit leg's flip (a video player holding
 * idle off while visible); C never combines it with the timer, so the timer
 * fires idle::start even while on is true and whether inhibit blocks auto-lock is
 * the config's own `if`. */
void queue_idle_start(struct queue *queue);
void queue_idle_stop(struct queue *queue);
void queue_idle_inhibit(struct queue *queue, bool on);

#endif
