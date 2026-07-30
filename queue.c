/* The origin event queue. Listeners in kiln.c enqueue plain facts; an idle
 * callback drains the queue and hands each event to the Lua handler as one
 * table: { class=, name=, ...payload }. C interprets nothing. */

#include <stdlib.h>
#include <string.h>
#include <lauxlib.h>
#include <lua.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_keyboard.h>

#include "core.h"
#include "queue.h"

enum queue_event_type {
	EV_CLIENT_MAP,
	EV_CLIENT_UNMAP,
	EV_CLIENT_DESTROY,
	EV_CLIENT_COMMIT_SIZE,
	EV_CLIENT_METADATA,
	EV_CLIENT_DECORATION_MODE,
	EV_CLIENT_ACTIVATE,
	EV_CLIENT_REQUEST_CONFIGURE,
	EV_CLIENT_URGENT,
	EV_CLIENT_FULLSCREEN,
	EV_CLIENT_MAXIMIZE,
	EV_CLIENT_MINIMIZE,
	EV_CLIENT_REQUEST_CLOSE,
	EV_KEY,
	EV_BUTTON,
	EV_MOTION,
	EV_AXIS,
	EV_POINTER_ENTER,
	EV_OUTPUT_ADD,
	EV_OUTPUT_REMOVE,
	EV_OUTPUT_CHANGE,
	EV_LAYER_MAP,
	EV_LAYER_COMMIT,
	EV_LAYER_UNMAP,
	EV_LAYER_DESTROY,
	EV_SESSION_LOCK,
	EV_SESSION_UNLOCK,
	EV_SESSION_KEY,
	EV_DRAG_START,
	EV_DRAG_END,
	EV_NOTIFY,
	EV_NOTIFY_CLOSE,
	EV_TRAY_ITEM,
	EV_TRAY_GONE,
	EV_FRAME_TICK,
	EV_SPAWN_OUT,
	EV_SPAWN_EXIT,
	EV_IDLE_START,
	EV_IDLE_STOP,
	EV_IDLE_INHIBIT,
};

static const struct {
	const char *class;
	const char *name;
} event_info[] = {
	[EV_CLIENT_MAP] = { "client", "map" },
	[EV_CLIENT_UNMAP] = { "client", "unmap" },
	[EV_CLIENT_DESTROY] = { "client", "destroy" },
	[EV_CLIENT_COMMIT_SIZE] = { "client", "commit_size" },
	[EV_CLIENT_METADATA] = { "client", "metadata" },
	[EV_CLIENT_DECORATION_MODE] = { "client", "request::decoration_mode" },
	[EV_CLIENT_ACTIVATE] = { "client", "request::activate" },
	[EV_CLIENT_REQUEST_CONFIGURE] = { "client", "request::configure" },
	[EV_CLIENT_URGENT] = { "client", "request::urgent" },
	[EV_CLIENT_FULLSCREEN] = { "client", "request::fullscreen" },
	[EV_CLIENT_MAXIMIZE] = { "client", "request::maximize" },
	[EV_CLIENT_MINIMIZE] = { "client", "request::minimize" },
	[EV_CLIENT_REQUEST_CLOSE] = { "client", "request::close" },
	[EV_KEY] = { "input", "key" },
	[EV_BUTTON] = { "input", "button" },
	[EV_MOTION] = { "input", "motion" },
	[EV_AXIS] = { "input", "axis" },
	[EV_POINTER_ENTER] = { "input", "pointer_enter" },
	[EV_OUTPUT_ADD] = { "output", "add" },
	[EV_OUTPUT_REMOVE] = { "output", "remove" },
	[EV_OUTPUT_CHANGE] = { "output", "change" },
	[EV_LAYER_MAP] = { "layer", "map" },
	[EV_LAYER_COMMIT] = { "layer", "commit" },
	[EV_LAYER_UNMAP] = { "layer", "unmap" },
	[EV_LAYER_DESTROY] = { "layer", "destroy" },
	[EV_SESSION_LOCK] = { "session", "lock" },
	[EV_SESSION_UNLOCK] = { "session", "unlock" },
	[EV_SESSION_KEY] = { "session", "key" },
	[EV_DRAG_START] = { "drag", "start" },
	[EV_DRAG_END] = { "drag", "end" },
	[EV_NOTIFY] = { "notify", "notify" },
	[EV_NOTIFY_CLOSE] = { "notify", "close" },
	[EV_TRAY_ITEM] = { "tray", "item" },
	[EV_TRAY_GONE] = { "tray", "gone" },
	[EV_FRAME_TICK] = { "frame", "tick" },
	[EV_SPAWN_OUT] = { "spawn", "out" },
	[EV_SPAWN_EXIT] = { "spawn", "exit" },
	[EV_IDLE_START] = { "idle", "start" },
	[EV_IDLE_STOP] = { "idle", "stop" },
	[EV_IDLE_INHIBIT] = { "idle", "inhibit" },
};

/* Notify carries two variable-length lists (the actions, and the passthrough
 * hints), which the flat event struct below cannot hold. They get ONE owning
 * pointer rather than eight more overloaded fields; the store owns every string
 * in it and event_free drops the lot. notify::close needs none of it and rides
 * `handle` like any other id. */
struct notify_store {
	uint32_t id, replaces_id;
	char *app_name, *app_icon, *summary, *body, *urgency, *image;
	int32_t expire_timeout;
	struct queue_action *actions;
	size_t actions_len;
	struct queue_hint *hints;
	size_t hints_len;
};

struct queue_event {
	struct wl_list link;
	enum queue_event_type type;
	uint64_t handle;
	int x, y, width, height;
	double px, py, dx, dy;
	uint32_t keysym, mods, button;
	bool pressed;
	char *str1, *str2;
	/* Layer events: namespace, output, layer_name, interactivity. Client
	 * map/metadata: class, instance ride str3/str4 (X11 hints; NULL and
	 * absent for xdg clients). */
	char *str3, *str4;
	char *str5; /* client map: window_type names, client order, comma-joined */
	/* client map/metadata: WM_WINDOW_ROLE (str6) and the icon cache key
	 * (str7), both X11-only; NULL and absent for xdg clients. */
	char *str6, *str7;
	int pid;
	uint64_t handle2; /* client map: transient_for parent handle (0 = none) */
	bool wants_focus; /* client map: only read when pressed (= OR) is set */
	/* client map: the state the client already holds as it maps, both kinds. */
	bool st_fullscreen, st_maximized, st_minimized;
	bool a_top, a_bottom, a_left, a_right;
	int32_t exclusive;
	int32_t m_top, m_right, m_bottom, m_left;
	struct notify_store *notify; /* EV_NOTIFY only */
	size_t len; /* spawn::out chunk length; the bytes ride str1 (event_free frees it) */
};

struct queue {
	struct core *core;
	struct wl_event_loop *loop;
	struct wl_list events;
	struct wl_event_source *idle;
};

static void queue_flush(void *data);

static struct queue_event *enqueue(struct queue *queue,
		enum queue_event_type type) {
	struct queue_event *ev = calloc(1, sizeof(*ev));
	ev->type = type;
	wl_list_insert(queue->events.prev, &ev->link);
	if (queue->idle == NULL) {
		queue->idle = wl_event_loop_add_idle(queue->loop,
			queue_flush, queue);
	}
	return ev;
}

static void notify_free(struct notify_store *n) {
	if (n == NULL) {
		return;
	}
	free(n->app_name);
	free(n->app_icon);
	free(n->summary);
	free(n->body);
	free(n->urgency);
	free(n->image);
	for (size_t i = 0; i < n->actions_len; i++) {
		free(n->actions[i].key);
		free(n->actions[i].label);
	}
	free(n->actions);
	for (size_t i = 0; i < n->hints_len; i++) {
		free(n->hints[i].key);
		free(n->hints[i].str);
	}
	free(n->hints);
	free(n);
}

static void event_free(struct queue_event *ev) {
	wl_list_remove(&ev->link);
	free(ev->str1);
	free(ev->str2);
	free(ev->str3);
	free(ev->str4);
	free(ev->str5);
	free(ev->str6);
	free(ev->str7);
	notify_free(ev->notify);
	free(ev);
}

/* --- marshalling one event into one Lua table --- */

static void set_string(lua_State *L, const char *key, const char *value) {
	if (value != NULL) {
		lua_pushstring(L, value);
		lua_setfield(L, -2, key);
	}
}

static void set_number(lua_State *L, const char *key, double value) {
	lua_pushnumber(L, value);
	lua_setfield(L, -2, key);
}

static void set_bool(lua_State *L, const char *key, bool value) {
	lua_pushboolean(L, value);
	lua_setfield(L, -2, key);
}

static void push_mods(lua_State *L, uint32_t mods) {
	lua_newtable(L);
	set_bool(L, "shift", mods & WLR_MODIFIER_SHIFT);
	set_bool(L, "ctrl", mods & WLR_MODIFIER_CTRL);
	set_bool(L, "alt", mods & WLR_MODIFIER_ALT);
	set_bool(L, "super", mods & WLR_MODIFIER_LOGO);
	lua_setfield(L, -2, "mods");
}

static void event_push(lua_State *L, struct queue_event *ev) {
	lua_newtable(L);
	set_string(L, "class", event_info[ev->type].class);
	set_string(L, "name", event_info[ev->type].name);

	switch (ev->type) {
	case EV_CLIENT_MAP:
		set_number(L, "handle", (double)ev->handle);
		set_number(L, "x", ev->x);
		set_number(L, "y", ev->y);
		set_number(L, "width", ev->width);
		set_number(L, "height", ev->height);
		set_string(L, "app_id", ev->str1);
		set_string(L, "title", ev->str2);
		/* X11 hints: absent (nil) for xdg clients and for X clients that do
		 * not declare them. override_redirect marshals only when true.
		 * wm_class/wm_instance, because the envelope owns the "class" key
		 * (every event carries class="client"); the Lua client property is
		 * still c.class. */
		set_string(L, "wm_class", ev->str3);
		set_string(L, "wm_instance", ev->str4);
		if (ev->pid > 0) {
			set_number(L, "pid", ev->pid);
		}
		if (ev->handle2 != 0) {
			set_number(L, "transient_for", (double)ev->handle2);
		}
		set_string(L, "window_type", ev->str5);
		/* WM_WINDOW_ROLE and the icon cache key. X11-only, so
		 * nil for xdg clients; a vanished icon or role marshals as nil, which
		 * is how the Lua reader clears its field. */
		set_string(L, "role", ev->str6);
		set_string(L, "icon", ev->str7);
		if (ev->pressed) {
			set_bool(L, "override_redirect", true);
			set_bool(L, "wants_focus", ev->wants_focus);
		}
		/* The state the client opens in. Only when set, so a client
		 * that opens plain carries nothing: the same shape the request
		 * events use, and Lua honors it with the same handlers. */
		if (ev->st_fullscreen) {
			set_bool(L, "fullscreen", true);
		}
		if (ev->st_maximized) {
			set_bool(L, "maximized", true);
		}
		if (ev->st_minimized) {
			set_bool(L, "minimized", true);
		}
		break;
	case EV_CLIENT_UNMAP:
	case EV_CLIENT_DESTROY:
	case EV_CLIENT_REQUEST_CLOSE:
		set_number(L, "handle", (double)ev->handle);
		break;
	case EV_CLIENT_COMMIT_SIZE:
		set_number(L, "handle", (double)ev->handle);
		set_number(L, "width", ev->width);
		set_number(L, "height", ev->height);
		break;
	case EV_CLIENT_METADATA:
		set_number(L, "handle", (double)ev->handle);
		set_string(L, "app_id", ev->str1);
		set_string(L, "title", ev->str2);
		set_string(L, "wm_class", ev->str3);
		set_string(L, "wm_instance", ev->str4);
		set_string(L, "role", ev->str6);
		set_string(L, "icon", ev->str7);
		break;
	case EV_CLIENT_REQUEST_CONFIGURE:
		set_number(L, "handle", (double)ev->handle);
		set_number(L, "x", ev->x);
		set_number(L, "y", ev->y);
		set_number(L, "width", ev->width);
		set_number(L, "height", ev->height);
		break;
	case EV_CLIENT_URGENT:
		set_number(L, "handle", (double)ev->handle);
		set_bool(L, "urgent", ev->pressed);
		break;
	case EV_CLIENT_FULLSCREEN:
	case EV_CLIENT_MAXIMIZE:
	case EV_CLIENT_MINIMIZE:
		set_number(L, "handle", (double)ev->handle);
		set_bool(L, "on", ev->pressed);
		break;
	case EV_CLIENT_DECORATION_MODE:
		set_number(L, "handle", (double)ev->handle);
		set_string(L, "mode", ev->str1);
		break;
	case EV_CLIENT_ACTIVATE:
		set_number(L, "handle", (double)ev->handle);
		set_bool(L, "valid", ev->pressed);
		set_string(L, "app_id", ev->str1);
		break;
	case EV_SESSION_KEY:
	case EV_KEY:
		set_number(L, "keysym", ev->keysym);
		set_string(L, "key", ev->str1);
		/* utf8 is always present (empty string mid-compose / on release). */
		lua_pushstring(L, ev->str2 != NULL ? ev->str2 : "");
		lua_setfield(L, -2, "utf8");
		set_bool(L, "pressed", ev->pressed);
		push_mods(L, ev->mods);
		break;
	case EV_BUTTON:
		set_number(L, "button", ev->button);
		set_bool(L, "pressed", ev->pressed);
		set_number(L, "x", ev->px);
		set_number(L, "y", ev->py);
		set_string(L, "screen", ev->str1);
		/* handle 0 (topmost real node is chrome or nothing) marshals as nil. */
		if (ev->handle != 0) {
			set_number(L, "client", (double)ev->handle);
		}
		push_mods(L, ev->mods);
		break;
	case EV_MOTION:
		set_number(L, "x", ev->px);
		set_number(L, "y", ev->py);
		set_string(L, "screen", ev->str1);
		/* handle 0 (topmost real node is chrome or nothing) marshals as nil,
		 * so a hover routes chrome-vs-client exactly like a button. */
		if (ev->handle != 0) {
			set_number(L, "client", (double)ev->handle);
		}
		break;
	case EV_AXIS:
		set_number(L, "dx", ev->dx);
		set_number(L, "dy", ev->dy);
		set_number(L, "x", ev->px);
		set_number(L, "y", ev->py);
		set_string(L, "screen", ev->str1);
		/* handle 0 (topmost real node is chrome or nothing) marshals as nil. */
		if (ev->handle != 0) {
			set_number(L, "client", (double)ev->handle);
		}
		push_mods(L, ev->mods);
		break;
	case EV_POINTER_ENTER:
		/* handle 0 (pointer over no client) marshals as nil. */
		if (ev->handle != 0) {
			set_number(L, "handle", (double)ev->handle);
		}
		break;
	case EV_OUTPUT_ADD:
	case EV_OUTPUT_REMOVE:
	case EV_OUTPUT_CHANGE:
		set_string(L, "output", ev->str1);
		break;
	case EV_FRAME_TICK:
		set_string(L, "screen", ev->str1);
		set_number(L, "dt", ev->dx);
		break;
	case EV_SPAWN_OUT:
		set_number(L, "id", (double)ev->handle);
		set_number(L, "fd", ev->x);
		/* Raw chunk, may lack a trailing newline; pushed by length because C
		 * never inspects it and it can carry embedded NULs. */
		lua_pushlstring(L, ev->str1, ev->len);
		lua_setfield(L, -2, "data");
		break;
	case EV_SPAWN_EXIT:
		set_number(L, "id", (double)ev->handle);
		set_number(L, "code", ev->x);
		break;
	case EV_LAYER_MAP:
	case EV_LAYER_COMMIT:
		set_number(L, "handle", (double)ev->handle);
		set_string(L, "namespace", ev->str1);
		/* output nil: the client let the compositor choose; placement is
		 * Lua's. */
		set_string(L, "output", ev->str2);
		set_string(L, "layer", ev->str3);
		set_string(L, "interactivity", ev->str4);
		lua_newtable(L);
		set_bool(L, "top", ev->a_top);
		set_bool(L, "bottom", ev->a_bottom);
		set_bool(L, "left", ev->a_left);
		set_bool(L, "right", ev->a_right);
		lua_setfield(L, -2, "anchors");
		lua_newtable(L);
		set_number(L, "top", ev->m_top);
		set_number(L, "right", ev->m_right);
		set_number(L, "bottom", ev->m_bottom);
		set_number(L, "left", ev->m_left);
		lua_setfield(L, -2, "margin");
		set_number(L, "exclusive", ev->exclusive);
		set_number(L, "width", ev->width);
		set_number(L, "height", ev->height);
		break;
	case EV_LAYER_UNMAP:
	case EV_LAYER_DESTROY:
		set_number(L, "handle", (double)ev->handle);
		break;
	case EV_SESSION_LOCK:
		/* kind is "ext" (an external locker) or "native" (core.lock).
		 * Informational only: Lua cannot veto the lock. */
		set_string(L, "kind", ev->str1);
		break;
	case EV_SESSION_UNLOCK:
		break;
	case EV_DRAG_START:
	case EV_DRAG_END:
		/* Informational, zero-payload: a drag began / ended. Lua reads only
		 * class and name. */
		break;
	case EV_IDLE_START:
	case EV_IDLE_STOP:
		/* Zero-payload: the idle timer elapsed / input returned. The two
		 * strictly alternate; Lua reads only class and name. */
		break;
	case EV_IDLE_INHIBIT:
		set_bool(L, "on", ev->pressed);
		break;
	case EV_NOTIFY: {
		struct notify_store *n = ev->notify;
		set_number(L, "id", n->id);
		if (n->replaces_id != 0) {
			set_number(L, "replaces_id", n->replaces_id);
		}
		set_string(L, "app_name", n->app_name);
		set_string(L, "app_icon", n->app_icon);
		set_string(L, "summary", n->summary);
		set_string(L, "body", n->body);
		set_string(L, "urgency", n->urgency);
		/* The image-cache key, never the pixels. */
		set_string(L, "image", n->image);
		set_number(L, "expire_timeout", n->expire_timeout);
		/* actions = { { key =, label = }, ... }, in the order the client sent
		 * them: an action list is ordered and C does not reorder it. */
		lua_newtable(L);
		for (size_t i = 0; i < n->actions_len; i++) {
			lua_newtable(L);
			set_string(L, "key", n->actions[i].key);
			set_string(L, "label", n->actions[i].label);
			lua_rawseti(L, -2, (int)i + 1);
		}
		lua_setfield(L, -2, "actions");
		/* Every hint we did not type, flat and verbatim. */
		lua_newtable(L);
		for (size_t i = 0; i < n->hints_len; i++) {
			struct queue_hint *h = &n->hints[i];
			switch (h->type) {
			case QUEUE_HINT_STRING:
				set_string(L, h->key, h->str);
				break;
			case QUEUE_HINT_NUMBER:
				set_number(L, h->key, h->num);
				break;
			case QUEUE_HINT_BOOL:
				set_bool(L, h->key, h->boolean);
				break;
			}
		}
		lua_setfield(L, -2, "hints");
		break;
	}
	case EV_NOTIFY_CLOSE:
		set_number(L, "id", (double)ev->handle);
		break;
	case EV_TRAY_ITEM:
		set_string(L, "service", ev->str1);
		set_string(L, "id", ev->str2);
		set_string(L, "title", ev->str3);
		set_string(L, "status", ev->str4);
		/* The image-cache key, or the passed-through IconName; nil when the
		 * item offered neither. Which one it is, and what to do with a name,
		 * is the display's business. */
		set_string(L, "icon", ev->str5);
		break;
	case EV_TRAY_GONE:
		set_string(L, "service", ev->str1);
		break;
	}
}

static void queue_flush(void *data) {
	struct queue *queue = data;
	/* Idle sources fire once and are destroyed by the loop. */
	queue->idle = NULL;

	while (!wl_list_empty(&queue->events)) {
		struct queue_event *ev = wl_container_of(
			queue->events.next, ev, link);
		if (core_push_event_handler(queue->core)) {
			event_push(core_state(queue->core), ev);
			core_call(queue->core, 1);
		}
		event_free(ev);
	}
}

/* --- enqueue entry points --- */

static void hints_fill(struct queue_event *ev,
		const struct queue_client_hints *hints) {
	if (hints == NULL) {
		return;
	}
	ev->str3 = hints->class != NULL ? strdup(hints->class) : NULL;
	ev->str4 = hints->instance != NULL ? strdup(hints->instance) : NULL;
	ev->str5 = hints->window_type != NULL ? strdup(hints->window_type) : NULL;
	ev->str6 = hints->role != NULL ? strdup(hints->role) : NULL;
	ev->str7 = hints->icon != NULL ? strdup(hints->icon) : NULL;
	ev->pid = hints->pid;
	ev->handle2 = hints->transient_for;
	ev->pressed = hints->override_redirect;
	ev->wants_focus = hints->wants_focus;
	ev->st_fullscreen = hints->fullscreen;
	ev->st_maximized = hints->maximized;
	ev->st_minimized = hints->minimized;
}

void queue_client_map(struct queue *queue, uint64_t handle,
		int x, int y, int width, int height,
		const char *app_id, const char *title,
		const struct queue_client_hints *hints) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_MAP);
	ev->handle = handle;
	ev->x = x;
	ev->y = y;
	ev->width = width;
	ev->height = height;
	ev->str1 = app_id != NULL ? strdup(app_id) : NULL;
	ev->str2 = title != NULL ? strdup(title) : NULL;
	hints_fill(ev, hints);
}

void queue_client_unmap(struct queue *queue, uint64_t handle) {
	enqueue(queue, EV_CLIENT_UNMAP)->handle = handle;
}

void queue_session_lock(struct queue *queue, const char *kind) {
	enqueue(queue, EV_SESSION_LOCK)->str1 = kind != NULL ? strdup(kind) : NULL;
}

void queue_session_unlock(struct queue *queue) {
	enqueue(queue, EV_SESSION_UNLOCK);
}

void queue_session_key(struct queue *queue, uint32_t keysym,
		const char *keyname, const char *utf8, uint32_t mods, bool pressed) {
	struct queue_event *ev = enqueue(queue, EV_SESSION_KEY);
	ev->keysym = keysym;
	ev->str1 = keyname != NULL ? strdup(keyname) : NULL;
	ev->str2 = utf8 != NULL ? strdup(utf8) : NULL;
	ev->mods = mods;
	ev->pressed = pressed;
}

void queue_drag_start(struct queue *queue) {
	enqueue(queue, EV_DRAG_START);
}

void queue_drag_end(struct queue *queue) {
	enqueue(queue, EV_DRAG_END);
}

/* idle::start / idle::stop: zero-payload, the timer elapsed or input returned.
 * idle::inhibit { on }: a visible inhibitor came or went (on rides pressed, the
 * urgent/request pattern). See queue.h for why C never combines them. */
void queue_idle_start(struct queue *queue) {
	enqueue(queue, EV_IDLE_START);
}

void queue_idle_stop(struct queue *queue) {
	enqueue(queue, EV_IDLE_STOP);
}

void queue_idle_inhibit(struct queue *queue, bool on) {
	enqueue(queue, EV_IDLE_INHIBIT)->pressed = on;
}

void queue_client_destroy(struct queue *queue, uint64_t handle) {
	enqueue(queue, EV_CLIENT_DESTROY)->handle = handle;
}

void queue_client_commit_size(struct queue *queue, uint64_t handle,
		int width, int height) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_COMMIT_SIZE);
	ev->handle = handle;
	ev->width = width;
	ev->height = height;
}

void queue_client_metadata(struct queue *queue, uint64_t handle,
		const char *app_id, const char *title,
		const struct queue_client_hints *hints) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_METADATA);
	ev->handle = handle;
	ev->str1 = app_id != NULL ? strdup(app_id) : NULL;
	ev->str2 = title != NULL ? strdup(title) : NULL;
	hints_fill(ev, hints);
}

void queue_client_request_configure(struct queue *queue, uint64_t handle,
		int x, int y, int width, int height) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_REQUEST_CONFIGURE);
	ev->handle = handle;
	ev->x = x;
	ev->y = y;
	ev->width = width;
	ev->height = height;
}

void queue_client_urgent(struct queue *queue, uint64_t handle, bool urgent) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_URGENT);
	ev->handle = handle;
	ev->pressed = urgent;
}

void queue_client_request_fullscreen(struct queue *queue, uint64_t handle,
		bool on) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_FULLSCREEN);
	ev->handle = handle;
	ev->pressed = on;
}

void queue_client_request_maximize(struct queue *queue, uint64_t handle,
		bool on) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_MAXIMIZE);
	ev->handle = handle;
	ev->pressed = on;
}

void queue_client_request_minimize(struct queue *queue, uint64_t handle,
		bool on) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_MINIMIZE);
	ev->handle = handle;
	ev->pressed = on;
}

void queue_client_request_close(struct queue *queue, uint64_t handle) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_REQUEST_CLOSE);
	ev->handle = handle;
}

void queue_client_decoration_mode(struct queue *queue, uint64_t handle,
		const char *mode) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_DECORATION_MODE);
	ev->handle = handle;
	ev->str1 = mode != NULL ? strdup(mode) : NULL;
}

void queue_client_activate(struct queue *queue, uint64_t handle,
		bool valid, const char *app_id) {
	struct queue_event *ev = enqueue(queue, EV_CLIENT_ACTIVATE);
	ev->handle = handle;
	ev->pressed = valid;
	ev->str1 = app_id != NULL ? strdup(app_id) : NULL;
}

void queue_key(struct queue *queue, uint32_t keysym, const char *keyname,
		const char *utf8, uint32_t mods, bool pressed) {
	struct queue_event *ev = enqueue(queue, EV_KEY);
	ev->keysym = keysym;
	ev->str1 = keyname != NULL ? strdup(keyname) : NULL;
	ev->str2 = utf8 != NULL ? strdup(utf8) : NULL;
	ev->mods = mods;
	ev->pressed = pressed;
}

void queue_button(struct queue *queue, uint32_t button, bool pressed,
		double x, double y, const char *screen, uint32_t mods,
		uint64_t client) {
	struct queue_event *ev = enqueue(queue, EV_BUTTON);
	ev->button = button;
	ev->pressed = pressed;
	ev->px = x;
	ev->py = y;
	ev->str1 = screen != NULL ? strdup(screen) : NULL;
	ev->mods = mods;
	ev->handle = client;
}

void queue_pointer_enter(struct queue *queue, uint64_t handle) {
	enqueue(queue, EV_POINTER_ENTER)->handle = handle;
}

void queue_motion(struct queue *queue, double x, double y,
		const char *screen, uint64_t client) {
	/* Motion floods; collapse runs so Lua sees only the newest position, the
	 * screen under it, and the topmost client (0 for chrome) for hover routing. */
	if (!wl_list_empty(&queue->events)) {
		struct queue_event *last = wl_container_of(
			queue->events.prev, last, link);
		if (last->type == EV_MOTION) {
			last->px = x;
			last->py = y;
			free(last->str1);
			last->str1 = screen != NULL ? strdup(screen) : NULL;
			last->handle = client;
			return;
		}
	}
	struct queue_event *ev = enqueue(queue, EV_MOTION);
	ev->px = x;
	ev->py = y;
	ev->str1 = screen != NULL ? strdup(screen) : NULL;
	ev->handle = client;
}

void queue_axis(struct queue *queue, double dx, double dy,
		double x, double y, const char *screen, uint32_t mods,
		uint64_t client) {
	/* Delivered 1:1; only motion coalesces. */
	struct queue_event *ev = enqueue(queue, EV_AXIS);
	ev->dx = dx;
	ev->dy = dy;
	ev->px = x;
	ev->py = y;
	ev->str1 = screen != NULL ? strdup(screen) : NULL;
	ev->mods = mods;
	ev->handle = client;
}

static void layer_fill(struct queue_event *ev,
		const struct queue_layer_facts *facts) {
	ev->handle = facts->handle;
	ev->str1 = facts->namespace_ != NULL ? strdup(facts->namespace_) : NULL;
	ev->str2 = facts->output != NULL ? strdup(facts->output) : NULL;
	ev->str3 = facts->layer_name != NULL ? strdup(facts->layer_name) : NULL;
	ev->str4 = facts->interactivity != NULL ?
		strdup(facts->interactivity) : NULL;
	ev->a_top = facts->anchor_top;
	ev->a_bottom = facts->anchor_bottom;
	ev->a_left = facts->anchor_left;
	ev->a_right = facts->anchor_right;
	ev->exclusive = facts->exclusive;
	ev->m_top = facts->margin_top;
	ev->m_right = facts->margin_right;
	ev->m_bottom = facts->margin_bottom;
	ev->m_left = facts->margin_left;
	ev->width = (int)facts->width;
	ev->height = (int)facts->height;
}

void queue_layer_map(struct queue *queue,
		const struct queue_layer_facts *facts) {
	layer_fill(enqueue(queue, EV_LAYER_MAP), facts);
}

void queue_layer_commit(struct queue *queue,
		const struct queue_layer_facts *facts) {
	layer_fill(enqueue(queue, EV_LAYER_COMMIT), facts);
}

void queue_layer_unmap(struct queue *queue, uint64_t handle) {
	enqueue(queue, EV_LAYER_UNMAP)->handle = handle;
}

void queue_layer_destroy(struct queue *queue, uint64_t handle) {
	enqueue(queue, EV_LAYER_DESTROY)->handle = handle;
}

void queue_output_add(struct queue *queue, const char *name) {
	enqueue(queue, EV_OUTPUT_ADD)->str1 = strdup(name);
}

void queue_output_remove(struct queue *queue, const char *name) {
	enqueue(queue, EV_OUTPUT_REMOVE)->str1 = strdup(name);
}

void queue_output_change(struct queue *queue, const char *name) {
	enqueue(queue, EV_OUTPUT_CHANGE)->str1 = strdup(name);
}

/* frame::tick { screen, dt }: one per output frame while core.tick is on for it.
 * dt is the true frame delta in seconds; C clamps nothing (the large resume dt
 * is Lua's to bound). str1 = screen name, dx = dt. */
void queue_frame_tick(struct queue *queue, const char *screen, double dt) {
	struct queue_event *ev = enqueue(queue, EV_FRAME_TICK);
	ev->str1 = strdup(screen);
	ev->dx = dt;
}

/* spawn::out { id, fd, data }: one raw read chunk. The bytes are copied into str1
 * with len (event_free's free(str1) covers it); id rides handle, fd rides x. */
void queue_spawn_out(struct queue *queue, uint64_t id, int fd,
		const char *data, size_t len) {
	struct queue_event *ev = enqueue(queue, EV_SPAWN_OUT);
	ev->handle = id;
	ev->x = fd;
	ev->str1 = malloc(len);
	memcpy(ev->str1, data, len);
	ev->len = len;
}

/* spawn::exit { id, code }: id rides handle, the exit status rides x. */
void queue_spawn_exit(struct queue *queue, uint64_t id, int code) {
	struct queue_event *ev = enqueue(queue, EV_SPAWN_EXIT);
	ev->handle = id;
	ev->x = code;
}

static char *dup_or_null(const char *s) {
	return s != NULL ? strdup(s) : NULL;
}

void queue_notify(struct queue *queue, const struct queue_notify_facts *facts) {
	struct notify_store *n = calloc(1, sizeof(*n));
	n->id = facts->id;
	n->replaces_id = facts->replaces_id;
	n->app_name = dup_or_null(facts->app_name);
	n->app_icon = dup_or_null(facts->app_icon);
	n->summary = dup_or_null(facts->summary);
	n->body = dup_or_null(facts->body);
	n->urgency = dup_or_null(facts->urgency);
	n->image = dup_or_null(facts->image);
	n->expire_timeout = facts->expire_timeout;
	/* The lists are handed over whole, strings and all: the service built them
	 * while walking the message and has no use for them after. */
	n->actions = facts->actions;
	n->actions_len = facts->actions_len;
	n->hints = facts->hints;
	n->hints_len = facts->hints_len;
	enqueue(queue, EV_NOTIFY)->notify = n;
}

void queue_notify_close(struct queue *queue, uint32_t id) {
	enqueue(queue, EV_NOTIFY_CLOSE)->handle = id;
}

void queue_tray_item(struct queue *queue,
		const struct queue_tray_facts *facts) {
	struct queue_event *ev = enqueue(queue, EV_TRAY_ITEM);
	ev->str1 = dup_or_null(facts->service);
	ev->str2 = dup_or_null(facts->id);
	ev->str3 = dup_or_null(facts->title);
	ev->str4 = dup_or_null(facts->status);
	ev->str5 = dup_or_null(facts->icon);
}

void queue_tray_gone(struct queue *queue, const char *service) {
	enqueue(queue, EV_TRAY_GONE)->str1 = dup_or_null(service);
}

/* --- lifecycle --- */

struct queue *queue_create(struct core *core, struct wl_event_loop *loop) {
	struct queue *queue = calloc(1, sizeof(*queue));
	queue->core = core;
	queue->loop = loop;
	wl_list_init(&queue->events);
	return queue;
}

void queue_destroy(struct queue *queue) {
	while (!wl_list_empty(&queue->events)) {
		struct queue_event *ev = wl_container_of(
			queue->events.next, ev, link);
		event_free(ev);
	}
	if (queue->idle != NULL) {
		wl_event_source_remove(queue->idle);
	}
	free(queue);
}
