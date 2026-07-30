#include <assert.h>
#include <getopt.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/input-event-codes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/libinput.h>
#include <wlr/backend/session.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/render/swapchain.h>
#include <drm_fourcc.h>
/* set_numlock writes the locked-modifier mask straight onto the keyboard, the
 * one place kiln reaches past the types API into the device interface. */
#include <wlr/interfaces/wlr_keyboard.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_cursor_shape_v1.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_foreign_toplevel_management_v1.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_gamma_control_v1.h>
#include <wlr/types/wlr_idle_inhibit_v1.h>
#include <wlr/types/wlr_idle_notify_v1.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_primary_selection.h>
#include <wlr/types/wlr_primary_selection_v1.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_session_lock_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_server_decoration.h>
#include <wlr/util/log.h>
#include <wlr/util/region.h>
#include <libinput.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-names.h>
#include <xkbcommon/xkbcommon-compose.h>
#ifdef KILN_XWAYLAND
#include <wlr/xwayland/xwayland.h>
#include <xcb/xcb.h>
#include <xcb/xcb_ewmh.h>
#endif

#include "core.h"
#include "dbus.h"
#include "notify.h"
#include "pam_auth.h"
#include "tray.h"
#include "queue.h"
#include "render.h"
#include "ui.h"

/* Which mechanism owns an engaged session lock. The two are mutually
 * exclusive at the edge (a second engage is refused), so one quarantine and
 * one opaque floor serve both. */
enum lock_owner { LOCK_NONE, LOCK_EXT, LOCK_NATIVE };

/* For brevity's sake, struct members are annotated where they are used. */
struct tinywl_server {
	struct wl_display *wl_display;
	struct wlr_backend *backend;
	/* The seat's VTs. Ctrl+Alt+F1-F12 is compositor-level and non-configurable
	 * (see keyboard_handle_key): it is the escape hatch that must work when Lua
	 * is broken AND while the session is locked, because a lock client that dies
	 * while locked leaves the outputs blank forever by design, and this is the
	 * only way back into the machine. NULL on backends without VTs. */
	struct wlr_session *session;
	struct wlr_renderer *renderer;
	struct wlr_allocator *allocator;
	struct wlr_scene *scene;
	struct wlr_scene_output_layout *scene_layout;
	/* Client surfaces live below the UI tree owned by struct ui. */
	struct wlr_scene_tree *clients_tree;
	struct ui *ui;
	struct core *core;
	/* Origin events flow through here to Lua. Handles are generation
	 * counted by never being reused: a monotonic counter. */
	struct queue *queue;
	uint64_t next_handle;
	/* The one DBus connection, and the services on it. Both NULL without a
	 * session bus or with -Ddbus=disabled: absent, not stubbed. */
	struct kiln_dbus *dbus;
	struct kiln_notify *notify;
	struct kiln_tray *tray;
	/* Which toplevel the cursor is over, to emit pointer_enter once per
	 * change. By handle, so a dead client never needs a pointer compare. */
	uint64_t hovered_handle;
	/* While set, a Lua pointer grab owns the cursor: motion and buttons
	 * still reach Lua, but nothing is forwarded to client surfaces. */
	bool pointer_grabbed;
	/* A Lua keygrabber holds the keyboard: keys still enqueue, nothing
	 * forwards. One bit, no grabber identity. */
	bool keyboard_grabbed;

	struct wlr_xdg_shell *xdg_shell;
	struct wl_listener new_xdg_toplevel;
	struct wl_listener new_xdg_popup;
	struct wl_list toplevels;

#ifdef KILN_XWAYLAND
	/* XWayland: a lazy server (spawned on the first X client) and, once
	 * ready, the WM-side XCB connection. The connection has exactly two
	 * uses: xcb_kill_client, and the
	 * fourteen EWMH _NET_WM_WINDOW_TYPE_* atoms, interned once at ready and
	 * used only to translate a surface's type list into names in CLIENT
	 * order (wlroots answers membership, not order). 0 = intern failed or
	 * never ran; lookups miss and window_type stays absent. */
	struct wlr_xwayland *xwayland;
	struct wl_listener xwayland_ready;
	struct wl_listener new_xwayland_surface;
	xcb_connection_t *xcb_conn;
	xcb_atom_t xwl_type_atoms[14];
	/* WM_WINDOW_ROLE, interned once at ready. wlroots reads _NET_WM_ICON at
	 * associate but not this one, and a client sets its role before mapping, so
	 * xs->role is nil at map; kiln reads the property itself on its own X
	 * connection, the same one the window_type atoms and xcb_kill_client
	 * use. */
	xcb_atom_t xwl_role_atom;
#endif

	/* wlr-layer-shell: bars, launchers, wallpapers. Each surface joins the
	 * same handle space as toplevels and becomes a place-leaf Lua declares
	 * in the band its protocol layer names; C arranges nothing. */
	struct wlr_layer_shell_v1 *layer_shell;
	struct wl_listener new_layer_surface;
	struct wl_list layers;

	/* xdg-decoration: the compositor forces server-side (no client-side draw
	 * path exists), and each request becomes a request::decoration_mode fact
	 * for Lua titlebar policy. */
	struct wlr_xdg_decoration_manager_v1 *xdg_decoration_mgr;
	struct wl_listener new_xdg_decoration;

	/* xdg-activation: a client's request to raise another surfaces as a
	 * request::activate fact (validity = the token was seat-backed); the
	 * compositor also mints tokens for spawn_with_token. Whether a request
	 * becomes focus or urgent is Lua policy; C stores and decides nothing. */
	struct wlr_xdg_activation_v1 *xdg_activation;
	struct wl_listener request_activate;

	/* foreign-toplevel: one write-only handle per mapped client, so taskbars
	 * and panels see kiln's windows. The handle is a mirror fed from the hint
	 * sites that already exist (title/app_id, the state verbs); it is never a
	 * second source of truth, and nothing reads it back. The manager exposes only a destroy
	 * signal, so there is no manager-level listener; each handle's requests
	 * (maximize/minimize/fullscreen/activate/close) come back through the same
	 * origin-event queue the xdg/xwl asks use. */
	struct wlr_foreign_toplevel_manager_v1 *foreign_toplevel_mgr;
	/* Live xdg-popups, so a re-tile of a toplevel can re-unconstrain the
	 * popups rooted on it (the reposition path). */
	struct wl_list popups;

	/* Capture + color. Both are hands-off wlroots globals with
	 * no listener of kiln's own: screencopy reads the composed scene for the
	 * portal/OBS path; gamma is handed to the scene, which owns its set_gamma
	 * listener, LUT apply, and reapply-on-hotplug (wlr_scene_set_gamma_control_
	 * manager_v1). core.screenshot's readback is in-process and needs neither. */
	struct wlr_screencopy_manager_v1 *screencopy_mgr;
	struct wlr_gamma_control_manager_v1 *gamma_control_mgr;
	/* Monotonic screenshot key counter: core.screenshot interns pixels under
	 * "screenshot:<n>" the way notify.c interns under "notify:<id>". */
	unsigned screenshot_seq;

	struct wlr_cursor *cursor;
	struct wlr_xcursor_manager *cursor_mgr;
	struct wl_listener cursor_motion;
	struct wl_listener cursor_motion_absolute;
	struct wl_listener cursor_button;
	struct wl_listener cursor_axis;
	struct wl_listener cursor_frame;

	/* pointer-constraints + relative-pointer. active_constraint
	 * is not authority and not a stack: it is the constraint of whichever
	 * surface holds seat pointer focus, re-derived at every site that moves
	 * pointer focus (motion, grab_pointer, lock engage), and NULL whenever no
	 * surface has it. cursor-shape-v1 rides the same focus fact: a client may
	 * name the shape over itself and no other. */
	struct wlr_pointer_constraints_v1 *pointer_constraints;
	struct wl_listener new_pointer_constraint;
	struct wlr_pointer_constraint_v1 *active_constraint;
	struct wlr_relative_pointer_manager_v1 *relative_pointer_mgr;
	struct wlr_cursor_shape_manager_v1 *cursor_shape_mgr;
	struct wl_listener request_set_shape;

	struct wlr_seat *seat;
	struct wl_listener new_input;
	struct wl_listener request_cursor;
	struct wl_listener request_set_selection;
	/* Primary selection: the middle-click clipboard, mirrored
	 * on the built set_selection shape. The seat forwards; ownership stays
	 * protocol-level, so C only honors the request. */
	struct wlr_primary_selection_v1_device_manager *primary_selection_mgr;
	struct wl_listener request_set_primary_selection;
	/* DnD. The drag grab is wlroots' own; C only
	 * validates the start serial the protocol demands, parents the icon into
	 * the cursor band, and reports drag::start/end. request_start_drag and
	 * start_drag ride the seat for the whole session; drag_destroy is added
	 * per-drag in start_drag and removed when that drag ends. drag_band is
	 * the cursor band's scene tree (above chrome, below the lock band);
	 * drag_icon_tree is the live icon subtree, NULL when no drag is in
	 * flight. */
	struct wl_listener request_start_drag;
	struct wl_listener start_drag;
	struct wl_listener drag_destroy;
	struct wlr_scene_tree *drag_band;
	struct wlr_scene_tree *drag_icon_tree;
	struct wl_list keyboards;
	/* Pointer devices, kept only so set_pointer has a list to apply
	 * libinput config over. No per-device identity reaches Lua: per-device
	 * targeting is the named absence. */
	struct wl_list pointers;

	struct wlr_output_layout *output_layout;
	struct wl_list outputs;
	struct wl_listener new_output;

	/* Session lock: C owns the whole guarantee. lock_owner is the
	 * single fact: it keeps the external ext-session-lock-v1 client and the
	 * native lockscreen mutually exclusive, and anything other than LOCK_NONE
	 * IS the quarantine (session_locked below; no second bool to keep in step).
	 * authenticated is the native unlock gate, set only by a PAM success in C
	 * so a rogue rc.lua cannot bypass it. lock_tree is the topmost scene tree
	 * (the lock band); lock_floor is an opaque black rect at its bottom, shown
	 * while locked so no client buffer can leak even if the lock content above
	 * it is absent or a Lua declare errors. */
	enum lock_owner lock_owner;
	bool authenticated;
	struct wlr_scene_tree *lock_tree;
	struct wlr_scene_rect *lock_floor;
	struct wlr_session_lock_manager_v1 *session_lock_mgr;
	struct wl_listener new_lock;
	struct wlr_session_lock_v1 *ext_lock;
	struct wl_listener lock_new_surface;
	struct wl_listener lock_unlock;
	struct wl_listener lock_destroy;

	/* Idle: the notifier feeds external idle daemons (activity on every input
	 * event); the inhibit manager lets a client (a video player) hold idle off
	 * while its surface is mapped. */
	struct wlr_idle_notifier_v1 *idle_notifier;
	struct wlr_idle_inhibit_manager_v1 *idle_inhibit_mgr;
	struct wl_listener new_idle_inhibitor;
	struct wl_list idle_inhibitors;
	/* What we last told wlroots, so the per-frame recompute only speaks on a
	 * real change. */
	bool idle_inhibited;
	/* The auto-lock timer: a loop timer armed by
	 * core.set_idle_timeout for idle_timeout_ms of no input. idle tracks whether
	 * idle::start has fired without a matching idle::stop, so the two alternate.
	 * Owned here, not in Lua, because the input paths (and the locked-key
	 * quarantine) are C's, so only C holds the complete activity fact a re-arm
	 * needs. */
	struct wl_event_source *idle_timer;
	int idle_timeout_ms;
	bool idle;
};

struct tinywl_idle_inhibitor {
	struct wl_list link;
	struct tinywl_server *server;
	struct wlr_idle_inhibitor_v1 *inhibitor;
	struct wl_listener destroy;
	/* "In effect only while the surface is visible" is the protocol's rule, so
	 * the inhibit state is recomputed whenever this surface maps or unmaps, not
	 * only when the inhibitor object comes and goes. */
	struct wl_listener surface_map;
	struct wl_listener surface_unmap;
};

/* The quarantine gate every input path checks. Derived, never stored: one fact
 * (who owns the lock), so engage and disengage cannot leave it half-set. */
static bool session_locked(struct tinywl_server *server) {
	return server->lock_owner != LOCK_NONE;
}

struct tinywl_output {
	struct wl_list link;
	struct tinywl_server *server;
	struct wlr_output *wlr_output;
	struct ui_output *ui_output;
	struct wl_listener frame;
	struct wl_listener request_state;
	struct wl_listener destroy;
	/* core.tick frame clock: while tick_on, output_frame keeps the frame
	 * scheduled and enqueues frame::tick with the delta since tick_last. Pure
	 * frame-clock mechanism (the true frame delta the contract mandates C
	 * compute); no easing, no animation state. */
	bool tick_on;
	struct timespec tick_last;
};

/* Which protocol owns a toplevel. One struct, one handle space, one borrow
 * contract, one path through solve/reconcile/dispatch; the kind exists only
 * where a verb or listener must speak the owning protocol, and it never
 * gains a second route through the machinery. */
enum toplevel_kind {
	TOPLEVEL_XDG,
	TOPLEVEL_XWL,
};

struct tinywl_toplevel {
	struct wl_list link;
	struct tinywl_server *server;
	enum toplevel_kind kind;
	/* TOPLEVEL_XDG only; NULL on an XWayland toplevel. */
	struct wlr_xdg_toplevel *xdg_toplevel;
	struct wlr_scene_tree *scene_tree;
	uint64_t handle;
	/* The render_state currently borrowing this tree, or NULL when it sits
	 * at home under clients_tree. A release only acts when it matches, so a
	 * migrated client's old output cannot blank the new output's node. */
	void *borrowed_by;
	/* Last size reported to Lua, so commit only emits real changes. */
	int last_width, last_height;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener commit;
	struct wl_listener destroy;
	struct wl_listener set_title;
	struct wl_listener set_app_id;
	/* The state requests. Both shells raise all three, so these slots
	 * are shared like map/unmap/commit/set_title; only the notify differs. */
	struct wl_listener request_maximize;
	struct wl_listener request_fullscreen;
	struct wl_listener request_minimize;
	/* The client's decoration object, if it created one: a write-only
	 * protocol mirror C forces to server-side and cleans up, never reads to
	 * decide anything. NULL until the client requests decoration. */
	struct wlr_xdg_toplevel_decoration_v1 *decoration;
	struct wl_listener set_decoration_mode;
	struct wl_listener destroy_decoration;

	/* The foreign-toplevel mirror for this client, created at map and
	 * destroyed at unmap (one handle per MAPPED client). NULL while unmapped.
	 * foreign_output is the wlr_output the handle last entered, so a screen
	 * change leaves the old one before entering the new (the output mirror
	 * verb); NULL when the handle is on no output. The five listeners are the
	 * taskbar's requests, attached to the handle and removed with it. */
	struct wlr_foreign_toplevel_handle_v1 *foreign;
	struct wlr_output *foreign_output;
	struct wl_listener ft_request_maximize;
	struct wl_listener ft_request_minimize;
	struct wl_listener ft_request_fullscreen;
	struct wl_listener ft_request_activate;
	struct wl_listener ft_request_close;

#ifdef KILN_XWAYLAND
	/* TOPLEVEL_XWL only. The wlr_surface inside blinks in and out between
	 * associate and dissociate; the map/unmap listeners above are attached
	 * only inside that window (xwl_associated tracks it, so destroy can
	 * detach them when a surface dies mid-association). X11 properties are
	 * read at map, never at create: create-time XCB reads race the XWayland
	 * handshake. */
	struct wlr_xwayland_surface *xwl_surface;
	struct wl_listener xwl_associate;
	struct wl_listener xwl_dissociate;
	struct wl_listener xwl_request_configure;
	struct wl_listener xwl_request_activate;
	struct wl_listener xwl_set_class;
	struct wl_listener xwl_set_hints;
	struct wl_listener xwl_set_geometry;
	struct wl_listener xwl_set_role;
	struct wl_listener xwl_set_icon;
	bool xwl_associated;
	/* Whether the last _NET_WM_ICON read decoded pixels into the cache. The
	 * icon key is derived from the handle wherever needed, so nothing is stored
	 * but this bool: it says whether "xwl-icon:<handle>" is a live key to hand
	 * Lua, or nil because the client set no icon we could read. */
	bool xwl_has_icon;
	/* WM_WINDOW_ROLE, read at map and set_role (never on a title change, so no
	 * round trip per rename). Both hints builders reference this; NULL when the
	 * client set no role. See server->xwl_role_atom for why kiln reads it. */
	char *xwl_role;
#endif
};

struct tinywl_layer {
	struct wl_list link;
	struct tinywl_server *server;
	struct wlr_layer_surface_v1 *layer_surface;
	struct wlr_scene_tree *scene_tree;
	uint64_t handle;
	/* Same borrow contract as toplevels: the render_state currently
	 * showing this tree, or NULL when it sits home under clients_tree. */
	void *borrowed_by;
	/* Whether Lua answered this map cycle's facts with layer_configure.
	 * Reset when the surface goes through the configure sequence again.
	 * Read by the watchdog: no fallback configure exists, so an unanswered
	 * surface stays visibly absent and C only logs. */
	bool configured;
	struct wl_event_source *watchdog;
	struct wl_listener commit;
	struct wl_listener unmap;
	struct wl_listener destroy;
	struct wl_listener new_popup;
};

struct tinywl_popup {
	struct wlr_xdg_popup *xdg_popup;
	struct tinywl_server *server;
	/* The toplevel this popup tree is rooted on, by handle: unconstrain reads
	 * that toplevel's retained scene position. A handle, not a pointer, so a
	 * stale root is a lookup miss, never a dereference. */
	uint64_t root_handle;
	struct wl_list link;
	struct wl_listener commit;
	struct wl_listener destroy;
};

struct tinywl_keyboard {
	struct wl_list link;
	struct tinywl_server *server;
	struct wlr_keyboard *wlr_keyboard;
	/* Keycodes whose press was consumed as a binding, so the matching
	 * release is consumed too even if the modifier lifted first. */
	uint8_t consumed[768 / 8];
	/* xkb compose machine: resolves dead-key/compose sequences to utf8
	 * C-side so Lua never touches xkb. NULL if the locale has no table. */
	struct xkb_compose_state *compose;

	struct wl_listener modifiers;
	struct wl_listener key;
	struct wl_listener destroy;
};

/* A pointer device, held only to have something for set_pointer to
 * configure. wlr_cursor owns the device for input; this is a list, not a
 * second owner. */
struct kiln_pointer {
	struct wl_list link;
	struct wlr_input_device *device;
	struct wl_listener destroy;
};

/* One live pointer constraint, held only for its destroy listener: the seat
 * must forget a constraint it activated when the client tears it down. */
struct kiln_pointer_constraint {
	struct tinywl_server *server;
	struct wlr_pointer_constraint_v1 *constraint;
	struct wl_listener destroy;
};

/* --- the handle registry: monotonic ids, stale lookups miss --- */

static struct tinywl_toplevel *toplevel_by_handle(
		struct tinywl_server *server, uint64_t handle) {
	struct tinywl_toplevel *toplevel;
	wl_list_for_each(toplevel, &server->toplevels, link) {
		if (toplevel->handle == handle) {
			return toplevel;
		}
	}
	return NULL;
}

static struct tinywl_layer *layer_by_handle(
		struct tinywl_server *server, uint64_t handle) {
	struct tinywl_layer *layer;
	wl_list_for_each(layer, &server->layers, link) {
		if (layer->handle == handle) {
			return layer;
		}
	}
	return NULL;
}

/* --- client hooks for the renderer (mechanism, no decisions) ---
 *
 * Place-leaves resolve across both surface registries (toplevels, layer
 * surfaces); one handle space, one borrow contract. */

static struct wlr_scene_tree *client_resolve(void *data, uint64_t handle) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	if (toplevel != NULL) {
		return toplevel->scene_tree;
	}
	struct tinywl_layer *layer = layer_by_handle(data, handle);
	return layer != NULL ? layer->scene_tree : NULL;
}

/* Kind guards for the verb and hook branches below. xdg additionally
 * requires the initialized base every xdg verb needs; xwl requires nothing
 * (its surface pointer is valid for the toplevel's whole life, the inner
 * wlr_surface is checked where a leg needs it). */
static struct wlr_xdg_toplevel *toplevel_xdg(struct tinywl_toplevel *toplevel) {
	if (toplevel == NULL || toplevel->kind != TOPLEVEL_XDG ||
			!toplevel->xdg_toplevel->base->initialized) {
		return NULL;
	}
	return toplevel->xdg_toplevel;
}

#ifdef KILN_XWAYLAND
static struct wlr_xwayland_surface *toplevel_xwl(
		struct tinywl_toplevel *toplevel) {
	if (toplevel == NULL || toplevel->kind != TOPLEVEL_XWL) {
		return NULL;
	}
	return toplevel->xwl_surface;
}

/* X11 windows carry root coordinates (= layout coords under the single X
 * screen XWayland presents), so every configure re-derives them from the
 * scene, which the reconciler has already positioned.
 *
 * The configure-suppression flag: override-redirect means the
 * X server never consults the WM about this window's geometry, so the only
 * legal WM behavior is to send nothing. Every C-driven configure funnels
 * through here (the reconciler's configure and reposition legs alike), so
 * this one guard IS the flag. */
static void xwl_send_configure(struct tinywl_toplevel *toplevel,
		int width, int height) {
	if (toplevel->xwl_surface->override_redirect) {
		return;
	}
	int lx = 0, ly = 0;
	wlr_scene_node_coords(&toplevel->scene_tree->node, &lx, &ly);
	wlr_xwayland_surface_configure(toplevel->xwl_surface,
		(int16_t)lx, (int16_t)ly, (uint16_t)width, (uint16_t)height);
}
#endif

/* Deliberately toplevel-only: a layer handle misses and no-ops. The
 * reconciler configures toplevels to their solved box, but a layer surface's
 * only configure path is the layer_configure verb; a
 * second, C-driven path here would be a shadow policy Lua could neither see
 * nor replace. */
static void client_configure(void *data, uint64_t handle,
		int width, int height) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	struct wlr_xdg_toplevel *xdg = toplevel_xdg(toplevel);
	if (xdg != NULL) {
		wlr_xdg_toplevel_set_size(xdg, width, height);
		return;
	}
#ifdef KILN_XWAYLAND
	if (toplevel_xwl(toplevel) != NULL) {
		xwl_send_configure(toplevel, width, height);
	}
#endif
}

static void client_borrow(void *data, uint64_t handle, void *owner) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	if (toplevel != NULL) {
		toplevel->borrowed_by = owner;
		return;
	}
	struct tinywl_layer *layer = layer_by_handle(data, handle);
	if (layer != NULL) {
		layer->borrowed_by = owner;
	}
}

static void client_release(void *data, uint64_t handle, void *owner) {
	struct tinywl_server *server = data;
	struct wlr_scene_tree *tree = NULL;
	struct tinywl_toplevel *toplevel = toplevel_by_handle(server, handle);
	if (toplevel != NULL && toplevel->borrowed_by == owner) {
		tree = toplevel->scene_tree;
		toplevel->borrowed_by = NULL;
	} else if (toplevel == NULL) {
		struct tinywl_layer *layer = layer_by_handle(server, handle);
		if (layer != NULL && layer->borrowed_by == owner) {
			tree = layer->scene_tree;
			layer->borrowed_by = NULL;
		}
	}
	/* Stale handle, or another output owns the tree now: leave it be. */
	if (tree == NULL) {
		return;
	}
	wlr_scene_node_reparent(&tree->node, server->clients_tree);
	wlr_scene_node_set_enabled(&tree->node, false);
}

/* --- client verbs for core.client.* --- */

/* focus is keyboard-enter only: one protocol action. Activation is a
 * separate verb (set_activated), composed with focus by Lua policy, so the
 * two are decoupled here (activate without focus stays possible) and never
 * left to desync (one canonical client:focus() does both). Resolves both
 * surface registries: layer keyboard interactivity is Lua answering the
 * layer event with this same verb. */
static void client_op_focus(void *data, uint64_t handle) {
	struct tinywl_server *server = data;
	/* While locked, Lua focus policy is quarantined out: keyboard focus is
	 * owned by the lock surface (ext) or by nothing (native). This also blocks
	 * a layer surface's keyboard-interactivity grant, which routes here. */
	if (session_locked(server)) {
		return;
	}
	struct wlr_seat *seat = server->seat;
	struct wlr_surface *prev = seat->keyboard_state.focused_surface;
	struct wlr_surface *surface = NULL;
	struct tinywl_toplevel *toplevel = toplevel_by_handle(server, handle);
	struct wlr_xdg_toplevel *xdg = toplevel_xdg(toplevel);

	if (xdg != NULL) {
		surface = xdg->base->surface;
	} else if (toplevel == NULL) {
		struct tinywl_layer *layer = layer_by_handle(server, handle);
		if (layer != NULL) {
			surface = layer->layer_surface->surface;
		}
	}
#ifdef KILN_XWAYLAND
	if (toplevel_xwl(toplevel) != NULL) {
		/* NULL while dissociated: falls through to the clear below, the
		 * same contract as a stale or mid-teardown handle. */
		surface = toplevel->xwl_surface->surface;
	}
#endif

	if (surface == NULL) {
		/* nil, stale, or mid-teardown handle: clear focus. */
		wlr_seat_keyboard_clear_focus(seat);
		return;
	}

	if (prev == surface) {
		return;
	}
	/* No raise: stacking is declaration order, owned by Lua. */
	struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(seat);
	if (keyboard != NULL) {
		wlr_seat_keyboard_notify_enter(seat, surface, keyboard->keycodes,
			keyboard->num_keycodes, &keyboard->modifiers);
	} else {
		wlr_seat_keyboard_notify_enter(seat, surface, NULL, 0, NULL);
	}
}

static void client_op_close(void *data, uint64_t handle) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	struct wlr_xdg_toplevel *xdg = toplevel_xdg(toplevel);
	if (xdg != NULL) {
		wlr_xdg_toplevel_send_close(xdg);
		return;
	}
#ifdef KILN_XWAYLAND
	if (toplevel_xwl(toplevel) != NULL) {
		/* wlroots sends WM_DELETE_WINDOW when the client speaks it and
		 * severs the window otherwise; one call, no policy here. */
		wlr_xwayland_surface_close(toplevel->xwl_surface);
	}
#endif
}

/* The impolite fallback to close. xdg: SIGKILL to the client's pid, so all
 * of its toplevels die. X11: the wl_client behind the resource is the
 * XWayland server itself, so the pid route would take down every X client
 * at once; the X-legal kill is the WM-side connection severing exactly this
 * window's X client (one of that connection's two uses). */
static void client_op_kill(void *data, uint64_t handle) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	if (toplevel == NULL) {
		return;
	}
#ifdef KILN_XWAYLAND
	if (toplevel->kind == TOPLEVEL_XWL) {
		struct tinywl_server *server = data;
		if (server->xcb_conn != NULL) {
			xcb_kill_client(server->xcb_conn,
				toplevel->xwl_surface->window_id);
			xcb_flush(server->xcb_conn);
		}
		return;
	}
#endif
	struct wl_client *client =
		wl_resource_get_client(toplevel->xdg_toplevel->base->resource);
	pid_t pid = 0;
	wl_client_get_credentials(client, &pid, NULL, NULL);
	if (pid > 0) {
		kill(pid, SIGKILL);
	}
}

/* The state hints: each sets one xdg-toplevel protocol state the client
 * renders to (chrome, shadows, exact-size expectations). The geometry is
 * always the declared tree; C never couples hint to geometry. */
static void client_op_set_activated(void *data, uint64_t handle, bool on) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	/* Mirror to the foreign handle first (write-only, both kinds): a taskbar
	 * highlights the active window off this. */
	if (toplevel != NULL && toplevel->foreign != NULL) {
		wlr_foreign_toplevel_handle_v1_set_activated(toplevel->foreign, on);
	}
	struct wlr_xdg_toplevel *xdg = toplevel_xdg(toplevel);
	if (xdg != NULL) {
		wlr_xdg_toplevel_set_activated(xdg, on);
		return;
	}
#ifdef KILN_XWAYLAND
	if (toplevel_xwl(toplevel) != NULL) {
		/* Beyond the _NET_ACTIVE_WINDOW mirror, this runs the ICCCM focus
		 * handshake (WM_TAKE_FOCUS for globally-active clients), which seat
		 * keyboard-enter alone cannot; Lua's focus() composes both verbs. */
		wlr_xwayland_surface_activate(toplevel->xwl_surface, on);
	}
#endif
}

static void client_op_set_fullscreen_hint(void *data, uint64_t handle,
		bool on) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	if (toplevel != NULL && toplevel->foreign != NULL) {
		wlr_foreign_toplevel_handle_v1_set_fullscreen(toplevel->foreign, on);
	}
	struct wlr_xdg_toplevel *xdg = toplevel_xdg(toplevel);
	if (xdg != NULL) {
		wlr_xdg_toplevel_set_fullscreen(xdg, on);
		return;
	}
#ifdef KILN_XWAYLAND
	if (toplevel_xwl(toplevel) != NULL) {
		wlr_xwayland_surface_set_fullscreen(toplevel->xwl_surface, on);
	}
#endif
}

static void client_op_set_maximized_hint(void *data, uint64_t handle,
		bool on) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	if (toplevel != NULL && toplevel->foreign != NULL) {
		wlr_foreign_toplevel_handle_v1_set_maximized(toplevel->foreign, on);
	}
	struct wlr_xdg_toplevel *xdg = toplevel_xdg(toplevel);
	if (xdg != NULL) {
		wlr_xdg_toplevel_set_maximized(xdg, on);
		return;
	}
#ifdef KILN_XWAYLAND
	if (toplevel_xwl(toplevel) != NULL) {
		wlr_xwayland_surface_set_maximized(toplevel->xwl_surface, on, on);
	}
#endif
}

/* tiled (since v2) and suspended (since v6) assert in wlroots if the client
 * bound an older xdg-shell, so a state it cannot receive degrades to a
 * no-op, same spirit as the stale-handle contract. Both are xdg-only: X11
 * has no tiled-edges or suspended state, so an XWayland handle no-ops. */
static void client_op_set_tiled_hint(void *data, uint64_t handle,
		uint32_t edges) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	struct wlr_xdg_toplevel *xdg = toplevel_xdg(toplevel);
	if (xdg != NULL && xdg->base->client->shell->version >=
			XDG_TOPLEVEL_STATE_TILED_LEFT_SINCE_VERSION) {
		wlr_xdg_toplevel_set_tiled(xdg, edges);
	}
}

static void client_op_set_suspended(void *data, uint64_t handle, bool on) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	struct wlr_xdg_toplevel *xdg = toplevel_xdg(toplevel);
	if (xdg != NULL && xdg->base->client->shell->version >=
			XDG_TOPLEVEL_STATE_SUSPENDED_SINCE_VERSION) {
		wlr_xdg_toplevel_set_suspended(xdg, on);
	}
}

/* The minimize hint. xdg-shell has no
 * set_minimized protocol call, so the xdg leg is the foreign mirror alone; X11
 * has WM_STATE iconic, which wlroots writes for us. The runtime still stops
 * DECLARING a minimized client (that is what makes it invisible and unhittable,
 * pure Lua); this verb only tells the client and any taskbar the state. */
static void client_op_set_minimized_hint(void *data, uint64_t handle, bool on) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(data, handle);
	if (toplevel == NULL) {
		return;
	}
	if (toplevel->foreign != NULL) {
		wlr_foreign_toplevel_handle_v1_set_minimized(toplevel->foreign, on);
	}
#ifdef KILN_XWAYLAND
	if (toplevel_xwl(toplevel) != NULL) {
		wlr_xwayland_surface_set_minimized(toplevel->xwl_surface, on);
	}
#endif
}

/* The output mirror: Lua owns which screen a
 * client is declared on and pushes it here so a taskbar can group by output.
 * Write-only; C keeps only the last-entered output on the handle, so a screen
 * change leaves the old one before entering the new. name NULL or unknown
 * leaves all. The alive check guards the one dangling case: the cached output
 * was removed while the client was still mapped (wlroots already dropped it
 * from the handle, so the leave would double-free). */
static bool output_alive(struct tinywl_server *server, struct wlr_output *o) {
	struct tinywl_output *out;
	wl_list_for_each(out, &server->outputs, link) {
		if (out->wlr_output == o) {
			return true;
		}
	}
	return false;
}

static void client_op_set_output_mirror(void *data, uint64_t handle,
		const char *name) {
	struct tinywl_server *server = data;
	struct tinywl_toplevel *toplevel = toplevel_by_handle(server, handle);
	if (toplevel == NULL || toplevel->foreign == NULL) {
		return;
	}
	struct wlr_output *target = NULL;
	if (name != NULL) {
		struct tinywl_output *out;
		wl_list_for_each(out, &server->outputs, link) {
			if (strcmp(out->wlr_output->name, name) == 0) {
				target = out->wlr_output;
				break;
			}
		}
	}
	if (target == toplevel->foreign_output) {
		return;
	}
	if (toplevel->foreign_output != NULL &&
			output_alive(server, toplevel->foreign_output)) {
		wlr_foreign_toplevel_handle_v1_output_leave(toplevel->foreign,
			toplevel->foreign_output);
	}
	if (target != NULL) {
		wlr_foreign_toplevel_handle_v1_output_enter(toplevel->foreign, target);
	}
	toplevel->foreign_output = target;
}

/* --- output verbs (core.output) --- */

/* A stale connector name resolves to NULL and every verb no-ops on it, the
 * contract's stale-name rule. */
static struct tinywl_output *output_by_name(struct tinywl_server *server,
		const char *name) {
	if (name == NULL) {
		return NULL;
	}
	struct tinywl_output *out;
	wl_list_for_each(out, &server->outputs, link) {
		if (strcmp(out->wlr_output->name, name) == 0) {
			return out;
		}
	}
	return NULL;
}

/* The one contracted read: enumeration as discovery, not state tracking. x/y
 * come from the layout box (an output's position is the layout's fact, not the
 * wlr_output's); everything else is the output's live state. */
static int output_op_list(void *data, struct core_output_info *out, int max) {
	struct tinywl_server *server = data;
	int n = 0;
	struct tinywl_output *o;
	wl_list_for_each(o, &server->outputs, link) {
		if (n >= max) {
			break;
		}
		struct wlr_output *w = o->wlr_output;
		struct core_output_info *info = &out[n];
		snprintf(info->name, sizeof(info->name), "%s", w->name);
		info->width = w->width;
		info->height = w->height;
		info->refresh = w->refresh;
		info->scale = w->scale;
		info->enabled = w->enabled;

		struct wlr_box box;
		wlr_output_layout_get_box(server->output_layout, w, &box);
		info->x = box.x;
		info->y = box.y;

		info->modes_len = 0;
		struct wlr_output_mode *mode;
		wl_list_for_each(mode, &w->modes, link) {
			if (info->modes_len >= (int)(sizeof(info->modes) /
					sizeof(info->modes[0]))) {
				break;
			}
			struct core_output_mode *m = &info->modes[info->modes_len++];
			m->width = mode->width;
			m->height = mode->height;
			m->refresh = mode->refresh;
		}
		n++;
	}
	return n;
}

/* Commit one output state field and, on success, mark the output for re-solve
 * and emit the `output change` fact: the next frame then reads fresh geometry,
 * and re-rasters follow the same mark. */
static void output_commit_and_emit(struct tinywl_server *server,
		struct tinywl_output *out, struct wlr_output_state *state) {
	if (wlr_output_commit_state(out->wlr_output, state)) {
		ui_output_mark_dirty(out->ui_output);
		queue_output_change(server->queue, out->wlr_output->name);
	}
}

static void output_op_set_mode(void *data, const char *name, int w, int h,
		int refresh) {
	struct tinywl_server *server = data;
	struct tinywl_output *out = output_by_name(server, name);
	if (out == NULL) {
		return;
	}
	struct wlr_output_state state;
	wlr_output_state_init(&state);
	/* Prefer a listed mode that matches (real hardware); fall back to a custom
	 * mode (the nested and headless backends, which carry no mode list). */
	struct wlr_output_mode *mode, *match = NULL;
	wl_list_for_each(mode, &out->wlr_output->modes, link) {
		if (mode->width == w && mode->height == h &&
				(refresh == 0 || mode->refresh == refresh)) {
			match = mode;
			break;
		}
	}
	if (match != NULL) {
		wlr_output_state_set_mode(&state, match);
	} else {
		wlr_output_state_set_custom_mode(&state, w, h, refresh);
	}
	output_commit_and_emit(server, out, &state);
	wlr_output_state_finish(&state);
}

static void output_op_set_scale(void *data, const char *name, double scale) {
	struct tinywl_server *server = data;
	struct tinywl_output *out = output_by_name(server, name);
	if (out == NULL) {
		return;
	}
	struct wlr_output_state state;
	wlr_output_state_init(&state);
	wlr_output_state_set_scale(&state, (float)scale);
	output_commit_and_emit(server, out, &state);
	wlr_output_state_finish(&state);
}

static void output_op_set_enabled(void *data, const char *name, bool on) {
	struct tinywl_server *server = data;
	struct tinywl_output *out = output_by_name(server, name);
	if (out == NULL) {
		return;
	}
	struct wlr_output_state state;
	wlr_output_state_init(&state);
	wlr_output_state_set_enabled(&state, on);
	output_commit_and_emit(server, out, &state);
	wlr_output_state_finish(&state);
}

/* A backend without
 * VRR support fails the commit, which is the unsupported no-op. */
static void output_op_set_adaptive_sync(void *data, const char *name, bool on) {
	struct tinywl_server *server = data;
	struct tinywl_output *out = output_by_name(server, name);
	if (out == NULL) {
		return;
	}
	struct wlr_output_state state;
	wlr_output_state_init(&state);
	wlr_output_state_set_adaptive_sync_enabled(&state, on);
	output_commit_and_emit(server, out, &state);
	wlr_output_state_finish(&state);
}

/* core.tick(screen, on): arm/disarm the per-output frame clock.
 * On arm, seed tick_last and kick one frame; output_frame does the rest each
 * cycle. A disabled output emits no frames, so DPMS-off freezes ticks for free;
 * re-arming reseeds tick_last so the first post-resume dt is fresh rather than
 * the whole DPMS gap (and Lua clamps whatever it gets). Mechanism only. */
static void output_op_set_tick(void *data, const char *name, bool on) {
	struct tinywl_server *server = data;
	struct tinywl_output *out = output_by_name(server, name);
	if (out == NULL) {
		return;
	}
	out->tick_on = on;
	if (on) {
		clock_gettime(CLOCK_MONOTONIC, &out->tick_last);
		wlr_output_schedule_frame(out->wlr_output);
	}
}

/* Position is a layout move, not an output commit: re-adding an output already
 * in the layout repositions it. Emit the change fact directly (no commit path
 * runs through output_commit_and_emit here). */
static void output_op_set_position(void *data, const char *name, int x, int y) {
	struct tinywl_server *server = data;
	struct tinywl_output *out = output_by_name(server, name);
	if (out == NULL) {
		return;
	}
	wlr_output_layout_add(server->output_layout, out->wlr_output, x, y);
	ui_output_mark_dirty(out->ui_output);
	queue_output_change(server->queue, out->wlr_output->name);
}

/* core.screenshot(screen[, path]): read one output's composed
 * scene into the image cache and return the cache key, usable anywhere an image
 * source is. The whole frame is captured (clients + Clay chrome + wallpaper)
 * because it is the same wlr_scene the output commits every frame, not a
 * per-surface redraw, which is why it does not miss chrome the way an X11-era
 * screenshot does. A one-shot swapchain renders the frame off to the side, so
 * the live output's buffers are untouched; a fresh buffer is full-damage, so an
 * idle output still yields a complete frame. With a path, the surface is also
 * written to a PNG (one cairo call, ui.c). NULL on a stale name or a failed
 * readback: Lua gets nil, never an abort. */
static const char *screenshot_op(void *data, const char *name,
		const char *save_path) {
	struct tinywl_server *server = data;
	struct tinywl_output *out = output_by_name(server, name);
	if (out == NULL) {
		return NULL;
	}
	struct wlr_output *wlr_output = out->wlr_output;
	struct wlr_scene_output *scene_output =
		wlr_scene_get_scene_output(server->scene, wlr_output);
	if (scene_output == NULL) {
		return NULL;
	}
	int width = wlr_output->width, height = wlr_output->height;
	if (width <= 0 || height <= 0) {
		return NULL;
	}

	/* A one-shot swapchain in a plain renderable format. We render to read
	 * back, never to scan out, so no display-format intersection is needed;
	 * XRGB8888 with an implicit modifier is universal across the pixman and
	 * GLES renderers kiln runs on. */
	struct wlr_drm_format format = {
		.format = DRM_FORMAT_XRGB8888,
		.len = 1,
		.capacity = 1,
		.modifiers = (uint64_t[]){ DRM_FORMAT_MOD_INVALID },
	};
	struct wlr_swapchain *swapchain = wlr_swapchain_create(server->allocator,
		width, height, &format);
	if (swapchain == NULL) {
		wlr_log(WLR_ERROR, "screenshot: swapchain create failed");
		return NULL;
	}

	struct wlr_output_state state;
	wlr_output_state_init(&state);
	struct wlr_scene_output_state_options opts = { .swapchain = swapchain };
	const char *key = NULL;
	uint8_t *pixels = NULL;
	struct wlr_texture *texture = NULL;

	if (!wlr_scene_output_build_state(scene_output, &state, &opts) ||
			state.buffer == NULL) {
		wlr_log(WLR_ERROR, "screenshot: scene render failed");
		goto out;
	}

	texture = wlr_texture_from_buffer(server->renderer, state.buffer);
	if (texture == NULL) {
		goto out;
	}
	/* ABGR8888 lands the bytes as R,G,B,A per pixel (little-endian), exactly
	 * gdk-pixbuf's RGBA layout, so ui_image_put's existing conversion takes them
	 * verbatim. The readback format is our choice, independent of the swapchain
	 * format; both renderers produce it (GLES natively, pixman via convert). */
	size_t stride = (size_t)width * 4;
	pixels = malloc(stride * (size_t)height);
	if (pixels == NULL) {
		goto out;
	}
	if (!wlr_texture_read_pixels(texture,
			&(struct wlr_texture_read_pixels_options){
				.data = pixels,
				.format = DRM_FORMAT_ABGR8888,
				.stride = (uint32_t)stride,
			})) {
		wlr_log(WLR_ERROR, "screenshot: read_pixels failed");
		goto out;
	}

	static char keybuf[32];
	snprintf(keybuf, sizeof(keybuf), "screenshot:%u",
		++server->screenshot_seq);
	if (!ui_image_put(server->ui, keybuf, width, height, (int)stride,
			true, 8, 4, pixels, stride * (size_t)height)) {
		goto out;
	}
	if (save_path != NULL &&
			!ui_image_save(server->ui, keybuf, save_path)) {
		wlr_log(WLR_ERROR, "screenshot: PNG write failed for %s", save_path);
	}
	key = keybuf;

out:
	if (texture != NULL) {
		wlr_texture_destroy(texture);
	}
	free(pixels);
	wlr_output_state_finish(&state);
	wlr_swapchain_destroy(swapchain);
	return key;
}

/* --- pointer constraints: activation IS pointer focus --- */

/* The one warp C makes, and it is the protocol's, not policy's: a client that
 * locked the pointer may say where the cursor should sit when the lock ends.
 * The surface-local hint becomes layout coords through the seat's own live
 * mapping (the focused surface, and the surface coords it was last sent), so
 * there is no stored origin and no geometry math. The focus test is also what
 * makes a grab suspension warp-free: the grab cleared pointer focus first, so
 * the hint has no mapping and the cursor stays where the drag found it. */
static void pointer_constraint_warp_to_hint(struct tinywl_server *server,
		struct wlr_pointer_constraint_v1 *constraint) {
	if (!(constraint->current.committed &
			WLR_POINTER_CONSTRAINT_V1_STATE_CURSOR_HINT)) {
		return;
	}
	struct wlr_seat *seat = server->seat;
	if (seat->pointer_state.focused_surface != constraint->surface) {
		return;
	}
	double ox = server->cursor->x - seat->pointer_state.sx;
	double oy = server->cursor->y - seat->pointer_state.sy;
	wlr_cursor_warp(server->cursor, NULL,
		ox + constraint->current.cursor_hint.x,
		oy + constraint->current.cursor_hint.y);
	wlr_seat_pointer_warp(seat, constraint->current.cursor_hint.x,
		constraint->current.cursor_hint.y);
}

/* Activate a constraint, deactivating whichever one was active. No stack and no
 * saved previous pointer: the caller always passes the constraint
 * of the currently focused surface, so the "restore" after a suspension is just
 * this function being called again with what focus now says. */
static void pointer_constraint_activate(struct tinywl_server *server,
		struct wlr_pointer_constraint_v1 *constraint) {
	if (server->active_constraint == constraint) {
		return;
	}
	struct wlr_pointer_constraint_v1 *old = server->active_constraint;
	if (old != NULL) {
		pointer_constraint_warp_to_hint(server, old);
		/* Deactivating a oneshot constraint destroys it, and the destroy
		 * listener below reads active_constraint: clear it first. */
		server->active_constraint = NULL;
		wlr_pointer_constraint_v1_send_deactivated(old);
	}
	server->active_constraint = constraint;
	if (constraint != NULL) {
		wlr_pointer_constraint_v1_send_activated(constraint);
	}
}

/* The whole of C's constraint policy: the constraint of the surface holding
 * seat pointer focus is active, and no other. Called from every site that
 * moves pointer focus. A grab and a session lock both suspend by the same
 * fact they already withhold motion by: they cleared pointer focus. */
static void pointer_constraint_sync(struct tinywl_server *server) {
	struct wlr_surface *focused = server->seat->pointer_state.focused_surface;
	struct wlr_pointer_constraint_v1 *constraint = NULL;
	if (focused != NULL) {
		constraint = wlr_pointer_constraints_v1_constraint_for_surface(
			server->pointer_constraints, focused, server->seat);
	}
	pointer_constraint_activate(server, constraint);
}

static void pointer_constraint_handle_destroy(struct wl_listener *listener,
		void *data) {
	struct kiln_pointer_constraint *kc =
		wl_container_of(listener, kc, destroy);
	if (kc->server->active_constraint == kc->constraint) {
		pointer_constraint_warp_to_hint(kc->server, kc->constraint);
		kc->server->active_constraint = NULL;
	}
	wl_list_remove(&kc->destroy.link);
	free(kc);
}

static void server_new_pointer_constraint(struct wl_listener *listener,
		void *data) {
	struct tinywl_server *server =
		wl_container_of(listener, server, new_pointer_constraint);
	struct wlr_pointer_constraint_v1 *constraint = data;
	struct kiln_pointer_constraint *kc = calloc(1, sizeof(*kc));
	if (kc == NULL) {
		return;
	}
	kc->server = server;
	kc->constraint = constraint;
	kc->destroy.notify = pointer_constraint_handle_destroy;
	wl_signal_add(&constraint->events.destroy, &kc->destroy);
	/* A client asks because the pointer is already over it, so evaluate now
	 * instead of waiting for a motion that a lock would make impossible. */
	pointer_constraint_sync(server);
}

/* --- input verbs for core.input.* --- */

static void process_cursor_motion(struct tinywl_server *server, uint32_t time);
static void lock_band_show(struct tinywl_server *server);
static void idle_inhibit_recompute(struct tinywl_server *server);

/* Called from every input path (key, motion, button, axis), before their
 * session_locked() early returns, so locked-screen typing still counts as
 * activity. Notifies the external idle daemons, closes an open idle::start with
 * idle::stop, and re-arms the auto-lock timer (each activity resets the
 * countdown). The queue-NULL guard is teardown's, the same one the key path
 * takes: keyboards release held keys after the queue is gone. */
static void idle_activity(struct tinywl_server *server) {
	if (server->queue == NULL) {
		return;
	}
	if (server->idle_notifier != NULL) {
		wlr_idle_notifier_v1_notify_activity(server->idle_notifier, server->seat);
	}
	if (server->idle) {
		server->idle = false;
		queue_idle_stop(server->queue);
	}
	if (server->idle_timeout_ms > 0) {
		wl_event_source_timer_update(server->idle_timer,
			server->idle_timeout_ms);
	}
}

/* The timer elapsed: no input for the timeout window. Enter idle once and tell
 * Lua; the timer is one-shot, so it does not re-arm itself (the next activity
 * does, in idle_activity), which is what keeps start and stop paired. */
static int handle_idle_timeout(void *data) {
	struct tinywl_server *server = data;
	if (!server->idle && server->queue != NULL) {
		server->idle = true;
		queue_idle_start(server->queue);
	}
	return 0;
}

/* core.set_idle_timeout(ms): 0 disarms, ms > 0 arms a fresh countdown. Any
 * reconfigure resets the machine (close an open idle::start first) so start and
 * stop stay paired across a kiln.reload, which re-runs rc and calls this again. */
static void input_op_set_idle_timeout(void *data, int ms) {
	struct tinywl_server *server = data;
	if (server->idle && server->queue != NULL) {
		server->idle = false;
		queue_idle_stop(server->queue);
	}
	server->idle_timeout_ms = ms;
	wl_event_source_timer_update(server->idle_timer, ms > 0 ? ms : 0);
}

static void input_op_grab_pointer(void *data, bool on) {
	struct tinywl_server *server = data;
	server->pointer_grabbed = on;
	if (on) {
		/* Drop pointer focus so the surface being dragged stops receiving
		 * motion. The cursor image is Lua's call via set_cursor. */
		wlr_seat_pointer_clear_focus(server->seat);
		/* And that same cleared focus suspends the active constraint: mod+drag
		 * outranks a locked pointer without knowing anything about it. Release
		 * restores it through process_cursor_motion below, which re-derives
		 * focus and calls the same sync. */
		pointer_constraint_sync(server);
	} else {
		/* Relinquish the grab cursor, then restore focus and hover. The
		 * client under the pointer may set its own image on the fresh enter;
		 * process_cursor_motion only resets the image over empty space, so a
		 * drag ending over a window would otherwise keep the grab cursor. */
		wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
		process_cursor_motion(server, 0);
	}
}

/* grab_keyboard(on): one routing bit at the forward site below, and that is
 * the entire delta. While on, every key enqueues
 * through the same leg it always did and none forwards to a client. C never
 * learns who the grabber is: the claim, the routing to it, and the release
 * are Lua's, on the one queue. */
static void input_op_grab_keyboard(void *data, bool on) {
	struct tinywl_server *server = data;
	server->keyboard_grabbed = on;
}

static void input_op_set_cursor(void *data, const char *name) {
	struct tinywl_server *server = data;
	wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, name);
}

/* Swap the xcursor theme manager. wlroots loads a named
 * theme (or the env default for NULL) per output scale on the next lookup, so
 * a fresh manager reloads at every live scale for free.
 * Re-apply the resting cursor so the swap shows without waiting for motion. */
static void input_op_set_cursor_theme(void *data, const char *name, int size) {
	struct tinywl_server *server = data;
	struct wlr_xcursor_manager *old = server->cursor_mgr;
	server->cursor_mgr = wlr_xcursor_manager_create(name, size);
	wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
	wlr_xcursor_manager_destroy(old);
}

/* Whole-map replacement, applied to every keyboard with no restart. The
 * compose state hanging off each keyboard is built from the locale, not from
 * the keymap, so a layout swap leaves it (and any sequence in flight) alone. */
static void input_op_set_keymap(void *data, const struct core_keymap *names) {
	struct tinywl_server *server = data;
	struct xkb_rule_names rules = {
		.rules = names->rules,
		.model = names->model,
		.layout = names->layout,
		.variant = names->variant,
		.options = names->options,
	};
	struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, &rules,
		XKB_KEYMAP_COMPILE_NO_FLAGS);
	if (keymap == NULL) {
		/* A config naming a layout xkb does not have keeps the old map: a
		 * keyboard with no keymap is a keyboard that types nothing. */
		wlr_log(WLR_ERROR, "set_keymap: xkb rejected the rule names");
		xkb_context_unref(context);
		return;
	}
	struct tinywl_keyboard *keyboard;
	wl_list_for_each(keyboard, &server->keyboards, link) {
		wlr_keyboard_set_keymap(keyboard->wlr_keyboard, keymap);
	}
	xkb_keymap_unref(keymap);
	xkb_context_unref(context);
}

static void input_op_set_repeat(void *data, int rate, int delay) {
	struct tinywl_server *server = data;
	struct tinywl_keyboard *keyboard;
	wl_list_for_each(keyboard, &server->keyboards, link) {
		wlr_keyboard_set_repeat_info(keyboard->wlr_keyboard, rate, delay);
	}
}

/* NumLock starts cold on Wayland: nothing latches it at boot the way the X
 * server did. The fix is the locked-modifier mask, not a synthetic keypress. */
static void input_op_set_numlock(void *data, bool on) {
	struct tinywl_server *server = data;
	struct tinywl_keyboard *keyboard;
	wl_list_for_each(keyboard, &server->keyboards, link) {
		struct wlr_keyboard *kb = keyboard->wlr_keyboard;
		xkb_mod_index_t idx =
			xkb_keymap_mod_get_index(kb->keymap, XKB_MOD_NAME_NUM);
		if (idx == XKB_MOD_INVALID) {
			continue;
		}
		uint32_t locked = kb->modifiers.locked;
		if (on) {
			locked |= (uint32_t)1 << idx;
		} else {
			locked &= ~((uint32_t)1 << idx);
		}
		wlr_keyboard_notify_modifiers(kb, kb->modifiers.depressed,
			kb->modifiers.latched, locked, kb->modifiers.group);
	}
}

/* set_pointer: libinput config on one device. A field Lua left nil is
 * untouched, and a field this device does not support is dropped by libinput's
 * own availability call, so no kiln table of device capabilities exists. A
 * device that is not libinput's (a nested backend's, in the test harness) has
 * nothing to configure and falls straight out. */
static void pointer_apply_config(struct wlr_input_device *device,
		const struct core_pointer_config *cfg) {
	if (!wlr_input_device_is_libinput(device)) {
		return;
	}
	struct libinput_device *dev = wlr_libinput_get_device_handle(device);
	if (dev == NULL) {
		return;
	}
	if (cfg->has_tap_to_click &&
			libinput_device_config_tap_get_finger_count(dev) > 0) {
		libinput_device_config_tap_set_enabled(dev, cfg->tap_to_click ?
			LIBINPUT_CONFIG_TAP_ENABLED : LIBINPUT_CONFIG_TAP_DISABLED);
	}
	if (cfg->has_natural_scrolling &&
			libinput_device_config_scroll_has_natural_scroll(dev)) {
		libinput_device_config_scroll_set_natural_scroll_enabled(dev,
			cfg->natural_scrolling);
	}
	if (cfg->has_left_handed &&
			libinput_device_config_left_handed_is_available(dev)) {
		libinput_device_config_left_handed_set(dev, cfg->left_handed);
	}
	if (cfg->has_accel_speed &&
			libinput_device_config_accel_is_available(dev)) {
		libinput_device_config_accel_set_speed(dev, cfg->accel_speed);
	}
	if (cfg->has_accel_profile && cfg->accel_profile != NULL) {
		enum libinput_config_accel_profile profile =
			strcmp(cfg->accel_profile, "flat") == 0 ?
			LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT :
			LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE;
		if (libinput_device_config_accel_get_profiles(dev) & profile) {
			libinput_device_config_accel_set_profile(dev, profile);
		}
	}
	if (cfg->has_scroll_method && cfg->scroll_method != NULL) {
		enum libinput_config_scroll_method method =
			LIBINPUT_CONFIG_SCROLL_NO_SCROLL;
		if (strcmp(cfg->scroll_method, "two_finger") == 0) {
			method = LIBINPUT_CONFIG_SCROLL_2FG;
		} else if (strcmp(cfg->scroll_method, "edge") == 0) {
			method = LIBINPUT_CONFIG_SCROLL_EDGE;
		} else if (strcmp(cfg->scroll_method, "button") == 0) {
			method = LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN;
		}
		/* "none" is zero in libinput's bitmask, so it is not something the
		 * device advertises; it is always settable. */
		if (method == LIBINPUT_CONFIG_SCROLL_NO_SCROLL ||
				(libinput_device_config_scroll_get_methods(dev) & method)) {
			libinput_device_config_scroll_set_method(dev, method);
		}
	}
	if (cfg->has_click_method && cfg->click_method != NULL) {
		enum libinput_config_click_method method =
			LIBINPUT_CONFIG_CLICK_METHOD_NONE;
		if (strcmp(cfg->click_method, "button_areas") == 0) {
			method = LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;
		} else if (strcmp(cfg->click_method, "clickfinger") == 0) {
			method = LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER;
		}
		if (method == LIBINPUT_CONFIG_CLICK_METHOD_NONE ||
				(libinput_device_config_click_get_methods(dev) & method)) {
			libinput_device_config_click_set_method(dev, method);
		}
	}
}

static void input_op_set_pointer(void *data,
		const struct core_pointer_config *cfg) {
	struct tinywl_server *server = data;
	struct kiln_pointer *pointer;
	wl_list_for_each(pointer, &server->pointers, link) {
		pointer_apply_config(pointer->device, cfg);
	}
}

static void keyboard_handle_modifiers(
		struct wl_listener *listener, void *data) {
	/* This event is raised when a modifier key, such as shift or alt, is
	 * pressed. We simply communicate this to the client. */
	struct tinywl_keyboard *keyboard =
		wl_container_of(listener, keyboard, modifiers);
	/*
	 * A seat can only have one keyboard, but this is a limitation of the
	 * Wayland protocol - not wlroots. We assign all connected keyboards to the
	 * same seat. You can swap out the underlying wlr_keyboard like this and
	 * wlr_seat handles this transparently.
	 */
	wlr_seat_set_keyboard(keyboard->server->seat, keyboard->wlr_keyboard);
	wlr_seat_keyboard_notify_modifiers(keyboard->server->seat,
		&keyboard->wlr_keyboard->modifiers);
}

static void spawn(const char *cmd) {
	if (fork() == 0) {
		execl("/bin/sh", "/bin/sh", "-c", cmd, (void *)NULL);
	}
}

static void keyboard_handle_key(
		struct wl_listener *listener, void *data) {
	/* This event is raised when a key is pressed or released. Keybindings
	 * are Lua's decision: the key becomes an origin event with the keysym
	 * resolved to its name and the modifiers to plain booleans, so Lua
	 * never touches xkb. The key is also forwarded to whatever surface
	 * holds seat focus. */
	struct tinywl_keyboard *keyboard =
		wl_container_of(listener, keyboard, key);
	struct tinywl_server *server = keyboard->server;
	/* Teardown finishes keyboards, which release held keys; the queue is
	 * gone and core is being freed by then, so there is nowhere to route
	 * the event. Same guard output_destroy uses. */
	if (server->queue == NULL) {
		return;
	}
	idle_activity(server);
	struct wlr_keyboard_key_event *event = data;
	struct wlr_seat *seat = server->seat;

	/* Translate libinput keycode -> xkbcommon */
	uint32_t keycode = event->keycode + 8;
	const xkb_keysym_t *syms;
	int nsyms = xkb_state_key_get_syms(
			keyboard->wlr_keyboard->xkb_state, keycode, &syms);
	uint32_t modifiers = wlr_keyboard_get_modifiers(keyboard->wlr_keyboard);
	bool pressed = event->state == WL_KEYBOARD_KEY_STATE_PRESSED;

	/* Shift is carried as a modifier bit; it must not ALSO rewrite the key.
	 * xkb_state_key_get_syms returns the sym at the level the held modifiers
	 * select, so shift+q resolves to Q and shift+2 to at. The origin event
	 * then names a chord no config spells, and core_key_bound
	 * compares it against xkb_keysym_from_name("q") and misses, so the chord
	 * is not consumed either and leaks to the focused client. Every mod+shift
	 * binding in a config is dead. X grabs match the unshifted level, which is
	 * what a config writing mods={"mod","shift"}, key="q" means by it.
	 *
	 * So when shift or caps is what moved the level, the chord comes off level
	 * 0 instead. The condition is not decoration: NumLock is a level-selecting
	 * modifier too, and level 0 of a keypad key is KP_End, not KP_1. Dropping
	 * to level 0 unconditionally would kill the numpad bindings (kilnrc.lua
	 * mod+KP_1..KP_9) the moment NumLock was on. Only shift and caps are
	 * cancelled, because only those two are chord modifiers a config also
	 * names in mods.
	 *
	 * The chord alone takes this. Composed text below stays on the real state
	 * (typing a capital must still produce one), and so does the VT escape,
	 * whose keysyms exist only at the ctrl+alt level. */
	const xkb_keysym_t *chord_syms = syms;
	int nchord = nsyms;
	struct xkb_keymap *keymap = keyboard->wlr_keyboard->keymap;
	if (keymap != NULL &&
			(modifiers & (WLR_MODIFIER_SHIFT | WLR_MODIFIER_CAPS))) {
		xkb_layout_index_t layout = xkb_state_key_get_layout(
				keyboard->wlr_keyboard->xkb_state, keycode);
		const xkb_keysym_t *base;
		int n = layout == XKB_LAYOUT_INVALID ? 0 :
			xkb_keymap_key_get_syms_by_level(
				keymap, keycode, layout, 0, &base);
		if (n > 0) {
			chord_syms = base;
			nchord = n;
		}
	}

	/* While locked the compositor quarantines the keyboard: no
	 * chord fires (mod+q is dead), a native lock still feeds its Clay
	 * lockscreen through the origin queue, and an external locker gets the key
	 * through the seat. lock_owner picks which. */
	bool locked = session_locked(server);
	bool native_lock = server->lock_owner == LOCK_NATIVE;
	bool consumed = false;
	uint32_t bit = event->keycode % (sizeof(keyboard->consumed) * 8);
	for (int i = 0; i < nsyms; i++) {
		xkb_keysym_t chord = i < nchord ? chord_syms[i] : syms[i];
		char name[64];
		xkb_keysym_get_name(chord, name, sizeof(name));

		/* Resolve the composed text C-side (empty mid-compose and on
		 * release; text is a press concern). A completed sequence yields
		 * its grapheme then resets; a plain key maps straight through. */
		char utf8[64] = "";
		if (pressed && keyboard->compose != NULL) {
			xkb_compose_state_feed(keyboard->compose, syms[i]);
			switch (xkb_compose_state_get_status(keyboard->compose)) {
			case XKB_COMPOSE_COMPOSING:
				break;
			case XKB_COMPOSE_COMPOSED:
				xkb_compose_state_get_utf8(keyboard->compose,
					utf8, sizeof(utf8));
				xkb_compose_state_reset(keyboard->compose);
				break;
			case XKB_COMPOSE_CANCELLED:
				xkb_compose_state_reset(keyboard->compose);
				break;
			case XKB_COMPOSE_NOTHING:
				xkb_state_key_get_utf8(keyboard->wlr_keyboard->xkb_state,
					keycode, utf8, sizeof(utf8));
				break;
			}
		} else if (pressed) {
			xkb_state_key_get_utf8(keyboard->wlr_keyboard->xkb_state,
				keycode, utf8, sizeof(utf8));
		}

		/* Ctrl+Alt+F1-F12: switch VT. Hardcoded, non-configurable, and it works
		 * when Lua is broken, which is the point of it being here in C.
		 *
		 * BLOCKED while locked. A VT switch out of a
		 * lockscreen is a full bypass the moment any other VT holds a live
		 * session (a logged-in shell, an autologin): you would reach it without
		 * a password. That the target is usually a fresh getty is not a
		 * guarantee the compositor can make, so it does not make it. */
		if (pressed && !locked && server->session != NULL &&
				(modifiers & WLR_MODIFIER_CTRL) &&
				(modifiers & WLR_MODIFIER_ALT) &&
				syms[i] >= XKB_KEY_XF86Switch_VT_1 &&
				syms[i] <= XKB_KEY_XF86Switch_VT_12) {
			unsigned vt = syms[i] - XKB_KEY_XF86Switch_VT_1 + 1;
			wlr_log(WLR_INFO, "switching to VT %u", vt);
			wlr_session_change_vt(server->session, vt);
			return;
		}

		/* The bypass leg of the lock guarantee. Bindings do not fire in C;
		 * they fire in Lua, off the input::key event. So the guarantee cannot
		 * be "Lua agrees not to dispatch": C must make the dispatchable event
		 * not exist.
		 *
		 * Unlocked, a key is input::key and bindings are live. Under a native
		 * lock it is session::key instead, a channel only the lockscreen reads,
		 * so no chord can fire however broken or replaced the config is. Under
		 * an external lock nothing
		 * reaches Lua at all; the key goes to the lock surface through the seat,
		 * so the password never enters LuaJIT. */
		if (!locked) {
			queue_key(server->queue, chord, name, utf8, modifiers, pressed);
		} else if (native_lock) {
			queue_session_key(server->queue, chord, name, utf8,
				modifiers, pressed);
		}
		/* The consume decision must be synchronous, before the seat
		 * forward; the set of consumed chords is Lua's, registered
		 * ahead of time with core.set_key_bindings. Never consulted while
		 * locked: there is nothing to consume, since no binding is reachable. */
		if (!locked && pressed &&
				core_key_bound(server->core, chord, modifiers)) {
			consumed = true;
		}
	}

	if (pressed && consumed) {
		keyboard->consumed[bit / 8] |= 1 << (bit % 8);
	} else if (!pressed && (keyboard->consumed[bit / 8] & (1 << (bit % 8)))) {
		/* Swallow the release of a consumed press, even if the
		 * modifiers lifted first. */
		keyboard->consumed[bit / 8] &= ~(1 << (bit % 8));
		consumed = true;
	}

	/* Forward to a client only when unlocked, or (ext) to the focused lock
	 * surface. A native lock forwards to nothing: no client holds focus.
	 * A keyboard grab is the third way to withhold the forward, and the whole
	 * of what grab_keyboard does: the key was queued above like any other, and
	 * which Lua claim reads it there is not C's business. */
	if (!consumed && !server->keyboard_grabbed &&
			(!locked || server->lock_owner == LOCK_EXT)) {
		wlr_seat_set_keyboard(seat, keyboard->wlr_keyboard);
		wlr_seat_keyboard_notify_key(seat, event->time_msec,
			event->keycode, event->state);
	}
}

static void keyboard_handle_destroy(struct wl_listener *listener, void *data) {
	/* This event is raised by the keyboard base wlr_input_device to signal
	 * the destruction of the wlr_keyboard. It will no longer receive events
	 * and should be destroyed.
	 */
	struct tinywl_keyboard *keyboard =
		wl_container_of(listener, keyboard, destroy);
	xkb_compose_state_unref(keyboard->compose);
	wl_list_remove(&keyboard->modifiers.link);
	wl_list_remove(&keyboard->key.link);
	wl_list_remove(&keyboard->destroy.link);
	wl_list_remove(&keyboard->link);
	free(keyboard);
}

static void server_new_keyboard(struct tinywl_server *server,
		struct wlr_input_device *device) {
	struct wlr_keyboard *wlr_keyboard = wlr_keyboard_from_input_device(device);

	struct tinywl_keyboard *keyboard = calloc(1, sizeof(*keyboard));
	keyboard->server = server;
	keyboard->wlr_keyboard = wlr_keyboard;

	/* We need to prepare an XKB keymap and assign it to the keyboard. This
	 * assumes the defaults (e.g. layout = "us"). */
	struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, NULL,
		XKB_KEYMAP_COMPILE_NO_FLAGS);

	wlr_keyboard_set_keymap(wlr_keyboard, keymap);
	xkb_keymap_unref(keymap);

	/* Build the compose machine from the locale, using the context before it
	 * is unref'd. NULL-tolerant: a locale with no compose table (e.g. "C")
	 * leaves compose NULL and the utf8 path falls through to the plain map. */
	const char *locale = getenv("LC_ALL");
	if (locale == NULL || *locale == '\0') locale = getenv("LC_CTYPE");
	if (locale == NULL || *locale == '\0') locale = getenv("LANG");
	if (locale == NULL || *locale == '\0') locale = "C";
	struct xkb_compose_table *compose_table = xkb_compose_table_new_from_locale(
		context, locale, XKB_COMPOSE_COMPILE_NO_FLAGS);
	if (compose_table != NULL) {
		keyboard->compose = xkb_compose_state_new(compose_table,
			XKB_COMPOSE_STATE_NO_FLAGS);
		xkb_compose_table_unref(compose_table);
	}

	xkb_context_unref(context);
	wlr_keyboard_set_repeat_info(wlr_keyboard, 25, 600);

	keyboard->modifiers.notify = keyboard_handle_modifiers;
	wl_signal_add(&wlr_keyboard->events.modifiers, &keyboard->modifiers);
	keyboard->key.notify = keyboard_handle_key;
	wl_signal_add(&wlr_keyboard->events.key, &keyboard->key);
	keyboard->destroy.notify = keyboard_handle_destroy;
	wl_signal_add(&device->events.destroy, &keyboard->destroy);

	wlr_seat_set_keyboard(server->seat, keyboard->wlr_keyboard);

	wl_list_insert(&server->keyboards, &keyboard->link);
}

static void pointer_handle_destroy(struct wl_listener *listener, void *data) {
	struct kiln_pointer *pointer = wl_container_of(listener, pointer, destroy);
	wl_list_remove(&pointer->destroy.link);
	wl_list_remove(&pointer->link);
	free(pointer);
}

static void server_new_pointer(struct tinywl_server *server,
		struct wlr_input_device *device) {
	/* Pointer handling is proxied through wlr_cursor. The device is also kept
	 * on a list, and for one reason: set_pointer needs something to hand
	 * libinput config to. */
	wlr_cursor_attach_input_device(server->cursor, device);
	struct kiln_pointer *pointer = calloc(1, sizeof(*pointer));
	if (pointer == NULL) {
		return;
	}
	pointer->device = device;
	pointer->destroy.notify = pointer_handle_destroy;
	wl_signal_add(&device->events.destroy, &pointer->destroy);
	wl_list_insert(&server->pointers, &pointer->link);
}

static void server_new_input(struct wl_listener *listener, void *data) {
	/* This event is raised by the backend when a new input device becomes
	 * available. */
	struct tinywl_server *server =
		wl_container_of(listener, server, new_input);
	struct wlr_input_device *device = data;
	switch (device->type) {
	case WLR_INPUT_DEVICE_KEYBOARD:
		server_new_keyboard(server, device);
		break;
	case WLR_INPUT_DEVICE_POINTER:
		server_new_pointer(server, device);
		break;
	default:
		break;
	}
	/* Advertise seat capabilities to clients. A cursor always exists, even
	 * with no pointer devices, so the pointer capability is always
	 * included. */
	uint32_t caps = WL_SEAT_CAPABILITY_POINTER;
	if (!wl_list_empty(&server->keyboards)) {
		caps |= WL_SEAT_CAPABILITY_KEYBOARD;
	}
	wlr_seat_set_capabilities(server->seat, caps);
}

static void seat_request_cursor(struct wl_listener *listener, void *data) {
	struct tinywl_server *server = wl_container_of(
			listener, server, request_cursor);
	/* This event is raised by the seat when a client provides a cursor image */
	struct wlr_seat_pointer_request_set_cursor_event *event = data;
	struct wlr_seat_client *focused_client =
		server->seat->pointer_state.focused_client;
	/* This can be sent by any client, so we check to make sure this one is
	 * actually has pointer focus first. */
	if (focused_client == event->seat_client) {
		/* Once we've vetted the client, we can tell the cursor to use the
		 * provided surface as the cursor image. It will set the hardware cursor
		 * on the output that it's currently on and continue to do so as the
		 * cursor moves between outputs. */
		wlr_cursor_set_surface(server->cursor, event->surface,
				event->hotspot_x, event->hotspot_y);
	}
}

/* cursor-shape-v1: a client names a shape instead of shipping a buffer.
 * The validity test is request_set_cursor's, and for the same reason: the shape
 * a client may name is the shape over itself. Nothing else is checked; there is
 * no shape whitelist and no rank against Lua's set_cursor, because whose ask is
 * live follows from whose pointer focus is live. A grab has cleared pointer
 * focus, so an ask under a grab finds no focused client and dies here, by the
 * mechanism that already withholds motion, button and axis. The enum-to-name
 * mapping is wlroots' helper, never a kiln table; the name goes through the
 * same xcursor call set_cursor wraps, so it is sharp at the output's scale by
 * the same per-scale theme load. */
static void seat_request_set_shape(struct wl_listener *listener, void *data) {
	struct tinywl_server *server = wl_container_of(
			listener, server, request_set_shape);
	struct wlr_cursor_shape_manager_v1_request_set_shape_event *event = data;
	if (event->device_type !=
			WLR_CURSOR_SHAPE_MANAGER_V1_DEVICE_TYPE_POINTER) {
		return;
	}
	if (server->seat->pointer_state.focused_client != event->seat_client) {
		return;
	}
	const char *name = wlr_cursor_shape_v1_name(event->shape);
	wlr_log(WLR_DEBUG, "cursor-shape: honored '%s'", name);
	wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, name);
}

static void seat_request_set_selection(struct wl_listener *listener, void *data) {
	/* A client wants to set the selection (a copy). Always honored:
	 * clipboard ownership is protocol-level, not compositor policy. */
	struct tinywl_server *server = wl_container_of(
			listener, server, request_set_selection);
	struct wlr_seat_request_set_selection_event *event = data;
	wlr_seat_set_selection(server->seat, event->source, event->serial);
}

static void seat_request_set_primary_selection(struct wl_listener *listener,
		void *data) {
	/* The middle-click clipboard's twin of the event above: a client asks to
	 * own the primary selection (a text selection, usually) and kiln honors it.
	 * Same protocol-level policy as the regular clipboard, no state kept. */
	struct tinywl_server *server = wl_container_of(
			listener, server, request_set_primary_selection);
	struct wlr_seat_request_set_primary_selection_event *event = data;
	wlr_seat_set_primary_selection(server->seat, event->source, event->serial);
}

/* DnD. C validates the serial
 * the protocol requires and hands the grab to wlroots; it decides no drop, no
 * target, no action. */
static void seat_drag_destroy(struct wl_listener *listener, void *data) {
	struct tinywl_server *server = wl_container_of(
			listener, server, drag_destroy);
	/* The drag ended, a drop or a cancel alike. The scene tree self-destroys
	 * with the drag icon (drag_icon.c), so only drop our pointer to it. */
	wl_list_remove(&server->drag_destroy.link);
	server->drag_icon_tree = NULL;
	queue_drag_end(server->queue);
}

static void seat_start_drag(struct wl_listener *listener, void *data) {
	struct tinywl_server *server = wl_container_of(
			listener, server, start_drag);
	struct wlr_drag *drag = data;
	/* The icon rides the cursor band: parent it there and pin it at the
	 * cursor now. A
	 * dragless drag (no icon surface) is legal and simply parents nothing.
	 * The icon's own hotspot offset is applied inside wlr_scene_drag_icon_create;
	 * C sets only the tree origin, here and on each motion. */
	if (drag->icon != NULL) {
		server->drag_icon_tree = wlr_scene_drag_icon_create(
			server->drag_band, drag->icon);
		wlr_scene_node_set_position(&server->drag_icon_tree->node,
			(int)server->cursor->x, (int)server->cursor->y);
	}
	server->drag_destroy.notify = seat_drag_destroy;
	wl_signal_add(&drag->events.destroy, &server->drag_destroy);
	queue_drag_start(server->queue);
}

static void seat_request_start_drag(struct wl_listener *listener, void *data) {
	struct tinywl_server *server = wl_container_of(
			listener, server, request_start_drag);
	struct wlr_seat_request_start_drag_event *event = data;
	/* The one protocol gate: the start serial must match a live pointer grab on
	 * the origin surface (wlroots' own check). A valid serial starts wlroots'
	 * pointer drag; an invalid one drops the source, never starts. C arbitrates
	 * nothing beyond this. */
	if (wlr_seat_validate_pointer_grab_serial(server->seat, event->origin,
			event->serial)) {
		wlr_seat_start_pointer_drag(server->seat, event->drag, event->serial);
	} else if (event->drag->source != NULL) {
		wlr_data_source_destroy(event->drag->source);
	}
}

static struct tinywl_toplevel *desktop_toplevel_at(
		struct tinywl_server *server, double lx, double ly,
		struct wlr_surface **surface, double *sx, double *sy) {
	/* The topmost node in the scene at the given layout coords; only buffer
	 * nodes carry a client surface. */
	struct wlr_scene_node *node = wlr_scene_node_at(
		&server->scene->tree.node, lx, ly, sx, sy);
	if (node == NULL || node->type != WLR_SCENE_NODE_BUFFER) {
		return NULL;
	}
	struct wlr_scene_buffer *scene_buffer = wlr_scene_buffer_from_node(node);
	struct wlr_scene_surface *scene_surface =
		wlr_scene_surface_try_from_buffer(scene_buffer);
	if (!scene_surface) {
		return NULL;
	}

	*surface = scene_surface->surface;
	/* Walk up to the tree root that carries node data; only a toplevel's
	 * root sets the data field. A
	 * layer surface's tree carries no data, so the walk runs out: the surface
	 * still forwards pointer input, it just is not a client for Lua routing. */
	struct wlr_scene_tree *tree = node->parent;
	while (tree != NULL && tree->node.data == NULL) {
		tree = tree->node.parent;
	}
	return tree != NULL ? tree->node.data : NULL;
}

static void process_cursor_motion(struct tinywl_server *server, uint32_t time) {
	/* Interactive move and resize are Lua policy, not handled here.
	 * Motion becomes an origin event, and the wlroots-level
	 * pointer focus (enter/motion forwarding to the surface under the
	 * cursor) stays, because it is protocol mechanism. */
	/* While locked, the pointer is quarantined: no motion fact reaches Lua and
	 * nothing is forwarded to a surface. The cursor still tracks and shows the
	 * default image over the lockscreen. */
	if (session_locked(server)) {
		wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
		return;
	}
	/* The drag icon rides the cursor band: its position is
	 * protocol-fixed at the cursor, so C moves the tree here on every motion
	 * (this runs regardless of the drag's pointer grab). The surface's hotspot
	 * offset is applied inside the scene helper; C sets only the tree origin. */
	if (server->drag_icon_tree != NULL) {
		wlr_scene_node_set_position(&server->drag_icon_tree->node,
			(int)server->cursor->x, (int)server->cursor->y);
	}
	struct wlr_output *output = wlr_output_layout_output_at(
		server->output_layout, server->cursor->x, server->cursor->y);
	double sx, sy;
	struct wlr_surface *surface = NULL;
	struct tinywl_toplevel *toplevel = desktop_toplevel_at(server,
		server->cursor->x, server->cursor->y, &surface, &sx, &sy);
	/* Motion carries the same scene-first facts as button and axis: the output
	 * under the cursor so Lua queries the right screen, and the topmost client
	 * handle (0 for chrome) so a hover routes through the one hit authority
	 * exactly like a click. */
	queue_motion(server->queue, server->cursor->x, server->cursor->y,
		output != NULL ? output->name : NULL,
		toplevel != NULL ? toplevel->handle : 0);

	/* The Clay debug panel does its own hit testing inside the solver, so it
	 * needs the seat's position as a fact, not as a Lua round trip. A no-op
	 * while no screen has the inspector up. */
	if (server->ui != NULL) {
		ui_inspector_input(server->ui, server->cursor->x, server->cursor->y,
			-1, false);
	}

	/* Dev-only: sample the topmost-plus-clip agreement invariant on motion.
	 * The scene and Clay must name the same chrome leaf at the cursor; a
	 * divergence aborts. Off unless KILN_AGREE is set (the sample walks
	 * the scene and runs a Clay pointer query, not free on every motion). */
	static int agree = -1;
	if (agree == -1) {
		agree = getenv("KILN_AGREE") != NULL ? 1 : 0;
	}
	if (agree && server->ui != NULL) {
		struct wlr_output *o = wlr_output_layout_output_at(
			server->output_layout, server->cursor->x, server->cursor->y);
		if (o != NULL) {
			ui_agreement_sample(server->ui, o->name,
				server->cursor->x, server->cursor->y);
		}
	}

	if (server->pointer_grabbed) {
		/* A Lua grab owns the cursor: the position went to Lua above, and
		 * nothing is forwarded to the surface under it. The cursor image
		 * stays whatever the grab set. */
		return;
	}

	/* The toplevel under the pointer (and its surface coords) were resolved
	 * above for the motion event; reuse them to forward pointer focus. */
	struct wlr_seat *seat = server->seat;
	uint64_t hovered = toplevel != NULL ? toplevel->handle : 0;
	if (hovered != server->hovered_handle) {
		server->hovered_handle = hovered;
		queue_pointer_enter(server->queue, hovered);
	}

	if (!toplevel) {
		/* If there's no toplevel under the cursor, set the cursor image to a
		 * default. This is what makes the cursor image appear when you move it
		 * around the screen, not over any toplevels. */
		wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
	}
	if (surface) {
		/*
		 * Send pointer enter and motion events.
		 *
		 * The enter event gives the surface "pointer focus", which is distinct
		 * from keyboard focus. You get pointer focus by moving the pointer over
		 * a window.
		 *
		 * Note that wlroots will avoid sending duplicate enter/motion events if
		 * the surface has already has pointer focus or if the client is already
		 * aware of the coordinates passed.
		 */
		wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
		wlr_seat_pointer_notify_motion(seat, time, sx, sy);
	} else {
		/* Clear pointer focus so future button events and such are not sent to
		 * the last client to have the cursor over it. */
		wlr_seat_pointer_clear_focus(seat);
	}

	/* Focus just settled, so the active constraint follows it: the surface that
	 * took focus gets its constraint, the one that lost focus loses it. This is
	 * also the restore path after a grab releases (input_op_grab_pointer calls
	 * back into here), which is why no previous-constraint pointer is kept. */
	pointer_constraint_sync(server);
}

/* Every pointer delta lands here, whichever listener produced it, so the
 * constraint applies once and the relative-pointer send happens once (a
 * second send at the one motion site, never a second path). Both wlr events
 * are a delta against where the cursor already is; an absolute device just
 * states its delta as a destination. */
static void pointer_motion(struct tinywl_server *server,
		struct wlr_input_device *device, uint32_t time_msec,
		double dx, double dy, double dx_unaccel, double dy_unaccel) {
	/* Relative motion is what a locked pointer is for. wlroots drops the send
	 * when no client holds pointer focus, so a grab withholds it exactly as it
	 * withholds motion, button and axis: no guard here. */
	wlr_relative_pointer_manager_v1_send_relative_motion(
		server->relative_pointer_mgr, server->seat,
		(uint64_t)time_msec * 1000, dx, dy, dx_unaccel, dy_unaccel);

	struct wlr_pointer_constraint_v1 *constraint = server->active_constraint;
	if (constraint != NULL &&
			server->seat->pointer_state.focused_surface == constraint->surface) {
		if (constraint->type == WLR_POINTER_CONSTRAINT_V1_LOCKED) {
			/* Locked: the client has the delta above; the cursor does not move
			 * and pointer focus cannot change, so there is nothing else to do. */
			return;
		}
		/* Confined: clamp the move into the region with wlroots' own helper.
		 * The surface-local start is the seat's live mapping, not geometry
		 * kiln recomputes. A move that starts outside the region is refused
		 * rather than teleported. */
		double sx = server->seat->pointer_state.sx;
		double sy = server->seat->pointer_state.sy;
		double cx, cy;
		if (!wlr_region_confine(&constraint->region, sx, sy,
				sx + dx, sy + dy, &cx, &cy)) {
			return;
		}
		dx = cx - sx;
		dy = cy - sy;
	}

	/* The cursor doesn't move unless we tell it to. The cursor automatically
	 * handles constraining the motion to the output layout, as well as any
	 * special configuration applied for the specific input device which
	 * generated the event. */
	wlr_cursor_move(server->cursor, device, dx, dy);
	process_cursor_motion(server, time_msec);
}

static void server_cursor_motion(struct wl_listener *listener, void *data) {
	/* This event is forwarded by the cursor when a pointer emits a _relative_
	 * pointer motion event (i.e. a delta) */
	struct tinywl_server *server =
		wl_container_of(listener, server, cursor_motion);
	struct wlr_pointer_motion_event *event = data;
	idle_activity(server);
	pointer_motion(server, &event->pointer->base, event->time_msec,
		event->delta_x, event->delta_y,
		event->unaccel_dx, event->unaccel_dy);
}

static void server_cursor_motion_absolute(
		struct wl_listener *listener, void *data) {
	/* This event is forwarded by the cursor when a pointer emits an _absolute_
	 * motion event, from 0..1 on each axis. This happens, for example, when
	 * wlroots is running under a Wayland or X11 window rather than KMS+DRM, and
	 * you move the mouse over the window. There is also some hardware which
	 * emits these events. The destination becomes a delta so it meets the
	 * constraint at the same site a mouse's delta does: an absolute device may
	 * not walk a locked cursor out of the window. Accelerated and unaccelerated
	 * are the same number here, because the device applied no acceleration. */
	struct tinywl_server *server =
		wl_container_of(listener, server, cursor_motion_absolute);
	struct wlr_pointer_motion_absolute_event *event = data;
	idle_activity(server);
	double lx, ly;
	wlr_cursor_absolute_to_layout_coords(server->cursor,
		&event->pointer->base, event->x, event->y, &lx, &ly);
	double dx = lx - server->cursor->x;
	double dy = ly - server->cursor->y;
	pointer_motion(server, &event->pointer->base, event->time_msec,
		dx, dy, dx, dy);
}

static void server_cursor_button(struct wl_listener *listener, void *data) {
	/* This event is forwarded by the cursor when a pointer emits a button
	 * event. */
	struct tinywl_server *server =
		wl_container_of(listener, server, cursor_button);
	struct wlr_pointer_button_event *event = data;
	idle_activity(server);
	/* Locked: the pointer is quarantined. No client (or lock surface) takes the
	 * button, and no button fact reaches Lua desktop policy. */
	if (session_locked(server)) {
		return;
	}
	wlr_seat_pointer_notify_button(server->seat,
			event->time_msec, event->button, event->state);
	/* Click-to-focus is Lua policy: Lua hears the button, with the
	 * cursor position for hit testing, the output under it so Lua queries
	 * the right screen, and the held modifiers for chorded buttons. */
	struct wlr_output *output = wlr_output_layout_output_at(
		server->output_layout, server->cursor->x, server->cursor->y);
	struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(server->seat);
	/* The reconciled scene is the single hit authority: the topmost real node
	 * at the cursor decides chrome-vs-client. desktop_toplevel_at yields the
	 * client handle when that node is a client surface, 0 otherwise; Lua
	 * trusts this instead of re-deriving the fork from a Clay query. */
	double sx, sy;
	struct wlr_surface *surface = NULL;
	struct tinywl_toplevel *toplevel = desktop_toplevel_at(server,
		server->cursor->x, server->cursor->y, &surface, &sx, &sy);
	/* Lua names buttons 1/2/3 (left/middle/right), the same way it never
	 * sees raw keycodes; translate the evdev code here. Extra buttons pass
	 * through raw. */
	uint32_t button;
	switch (event->button) {
	case BTN_LEFT: button = 1; break;
	case BTN_MIDDLE: button = 2; break;
	case BTN_RIGHT: button = 3; break;
	default: button = event->button; break;
	}
	queue_button(server->queue, button,
		event->state == WL_POINTER_BUTTON_STATE_PRESSED,
		server->cursor->x, server->cursor->y,
		output != NULL ? output->name : NULL,
		keyboard != NULL ? wlr_keyboard_get_modifiers(keyboard) : 0,
		toplevel != NULL ? toplevel->handle : 0);

	/* The debug panel's rows and close button are left-click only, so that is
	 * the only edge the inspector's seat mirror is told about. A no-op while no
	 * screen has the inspector up. */
	if (server->ui != NULL && event->button == BTN_LEFT) {
		bool pressed = event->state == WL_POINTER_BUTTON_STATE_PRESSED;
		ui_inspector_input(server->ui, server->cursor->x, server->cursor->y,
			pressed ? 1 : 0, pressed);
	}
}

static void server_cursor_axis(struct wl_listener *listener, void *data) {
	/* This event is forwarded by the cursor when a pointer emits an axis event,
	 * for example when you move the scroll wheel. */
	struct tinywl_server *server =
		wl_container_of(listener, server, cursor_axis);
	struct wlr_pointer_axis_event *event = data;
	idle_activity(server);
	/* Locked: scroll is quarantined like motion and buttons. */
	if (session_locked(server)) {
		return;
	}
	/* Notify the client with pointer focus of the axis event.
	 *
	 * Under a Lua pointer grab there is no such client: grab_pointer cleared
	 * pointer focus and process_cursor_motion does not restore it while the
	 * grab holds, and wlr_seat_pointer_send_axis (like button) drops the event
	 * when no client is focused. So the withhold is already what happens
	 * (axis behaves like motion and button under a grab),
	 * and the queue_axis below still reports the wheel to the grabber. No
	 * grab leg here: the one that exists is the cleared focus. */
	wlr_seat_pointer_notify_axis(server->seat,
			event->time_msec, event->orientation, event->delta,
			event->delta_discrete, event->source, event->relative_direction);

	/* Teardown may have torn the queue down already (same guard as keys). */
	if (server->queue == NULL) {
		return;
	}
	/* One wlroots axis event carries one orientation; map it to a single
	 * nonzero delta. The scroll fact is Lua's to interpret (root buttons,
	 * on_scroll); C only reports it, with the cursor position, the output
	 * under it, and the held modifiers, like button. */
	double dx = 0, dy = 0;
	if (event->orientation == WL_POINTER_AXIS_HORIZONTAL_SCROLL) {
		dx = event->delta;
	} else {
		dy = event->delta;
	}
	struct wlr_output *output = wlr_output_layout_output_at(
		server->output_layout, server->cursor->x, server->cursor->y);
	struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(server->seat);
	/* Same scene-first hit authority as button: the topmost node names the
	 * client under the cursor (0 for chrome), so Lua routes the scroll. */
	double sx, sy;
	struct wlr_surface *surface = NULL;
	struct tinywl_toplevel *toplevel = desktop_toplevel_at(server,
		server->cursor->x, server->cursor->y, &surface, &sx, &sy);
	queue_axis(server->queue, dx, dy,
		server->cursor->x, server->cursor->y,
		output != NULL ? output->name : NULL,
		keyboard != NULL ? wlr_keyboard_get_modifiers(keyboard) : 0,
		toplevel != NULL ? toplevel->handle : 0);
}

static void server_cursor_frame(struct wl_listener *listener, void *data) {
	/* This event is forwarded by the cursor when a pointer emits an frame
	 * event. Frame events are sent after regular pointer events to group
	 * multiple events together. For instance, two axis events may happen at the
	 * same time, in which case a frame event won't be sent in between. */
	struct tinywl_server *server =
		wl_container_of(listener, server, cursor_frame);
	/* Notify the client with pointer focus of the frame event. */
	wlr_seat_pointer_notify_frame(server->seat);
}

static void output_frame(struct wl_listener *listener, void *data) {
	struct tinywl_output *output = wl_container_of(listener, output, frame);
	struct wlr_scene *scene = output->server->scene;

	struct wlr_scene_output *scene_output = wlr_scene_get_scene_output(
		scene, output->wlr_output);

	/* Re-solve this output's UI if it is dirty, before the scene commits.
	 * The lock fact travels per frame from the one authority (lock_owner);
	 * ui stores no mirror of it. */
	ui_output_frame(output->ui_output,
		output->server->lock_owner == LOCK_NATIVE);

	/* Visibility is Lua's fact and it lands in the reconcile above, so an
	 * inhibitor's answer can change without any inhibitor or surface event: a
	 * tag switch takes the video off screen. Recompute against the fresh scene.
	 * Skipped entirely when nothing inhibits, which is the usual case. */
	if (!wl_list_empty(&output->server->idle_inhibitors)) {
		idle_inhibit_recompute(output->server);
	}

	/* Render the scene if needed and commit the output */
	wlr_scene_output_commit(scene_output, NULL);

	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_scene_output_send_frame_done(scene_output, &now);

	/* The frame clock: while tick is on for this (enabled) output, deliver the
	 * true frame delta and keep the clock alive for the next cycle. A disabled
	 * output never reaches here (the backend stops its frames), so DPMS-off
	 * freezes ticks at zero cost. C computes the delta and clamps nothing. */
	if (output->tick_on && output->wlr_output->enabled) {
		double dt = (now.tv_sec - output->tick_last.tv_sec)
			+ (now.tv_nsec - output->tick_last.tv_nsec) / 1e9;
		output->tick_last = now;
		queue_frame_tick(output->server->queue,
			output->wlr_output->name, dt);
		wlr_output_schedule_frame(output->wlr_output);
	}
}

static void output_request_state(struct wl_listener *listener, void *data) {
	/* This function is called when the backend requests a new state for
	 * the output. For example, Wayland and X11 backends request a new mode
	 * when the output window is resized. */
	struct tinywl_output *output = wl_container_of(listener, output, request_state);
	const struct wlr_output_event_request_state *event = data;
	wlr_output_commit_state(output->wlr_output, event->state);
	ui_output_mark_dirty(output->ui_output);
}

static void output_destroy(struct wl_listener *listener, void *data) {
	struct tinywl_output *output = wl_container_of(listener, output, destroy);

	/* At shutdown ui_destroy has already torn every ui_output down and
	 * the queue is gone; both guards cover backend-destroy ordering. */
	if (output->server->ui != NULL) {
		ui_output_destroy(output->ui_output);
	}
	if (output->server->queue != NULL) {
		queue_output_remove(output->server->queue,
			output->wlr_output->name);
	}
	struct tinywl_server *server = output->server;
	wl_list_remove(&output->frame.link);
	wl_list_remove(&output->request_state.link);
	wl_list_remove(&output->destroy.link);
	wl_list_remove(&output->link);
	free(output);

	/* Keep the floor sized to the surviving layout while locked. */
	if (session_locked(server) && server->lock_floor != NULL) {
		lock_band_show(server);
	}
}

static void server_new_output(struct wl_listener *listener, void *data) {
	/* This event is raised by the backend when a new output (aka a display or
	 * monitor) becomes available. */
	struct tinywl_server *server =
		wl_container_of(listener, server, new_output);
	struct wlr_output *wlr_output = data;

	/* Configures the output created by the backend to use our allocator
	 * and our renderer. Must be done once, before commiting the output */
	wlr_output_init_render(wlr_output, server->allocator, server->renderer);

	/* The output may be disabled, switch it on. */
	struct wlr_output_state state;
	wlr_output_state_init(&state);
	wlr_output_state_set_enabled(&state, true);

	/* Some backends don't have modes. DRM+KMS does, and we need to set a mode
	 * before we can use the output. The mode is a tuple of (width, height,
	 * refresh rate), and each monitor supports only a specific set of modes. We
	 * just pick the monitor's preferred mode, a more sophisticated compositor
	 * would let the user configure it. */
	struct wlr_output_mode *mode = wlr_output_preferred_mode(wlr_output);
	if (mode != NULL) {
		wlr_output_state_set_mode(&state, mode);
	}

	/* Atomically applies the new output state. */
	wlr_output_commit_state(wlr_output, &state);
	wlr_output_state_finish(&state);

	struct tinywl_output *output = calloc(1, sizeof(*output));
	output->wlr_output = wlr_output;
	output->server = server;

	output->frame.notify = output_frame;
	wl_signal_add(&wlr_output->events.frame, &output->frame);

	output->request_state.notify = output_request_state;
	wl_signal_add(&wlr_output->events.request_state, &output->request_state);

	output->destroy.notify = output_destroy;
	wl_signal_add(&wlr_output->events.destroy, &output->destroy);

	wl_list_insert(&server->outputs, &output->link);

	/* Adds this to the output layout. The add_auto function arranges outputs
	 * from left-to-right in the order they appear. A more sophisticated
	 * compositor would let the user configure the arrangement of outputs in the
	 * layout.
	 *
	 * The output layout utility automatically adds a wl_output global to the
	 * display, which Wayland clients can see to find out information about the
	 * output (such as DPI, scale factor, manufacturer, etc).
	 */
	struct wlr_output_layout_output *l_output = wlr_output_layout_add_auto(server->output_layout,
		wlr_output);
	struct wlr_scene_output *scene_output = wlr_scene_output_create(server->scene, wlr_output);
	wlr_scene_output_layout_add_output(server->scene_layout, l_output, scene_output);

	/* Give the output its own Clay context and retained render state. The
	 * output has its layout position by now. */
	output->ui_output = ui_output_create(server->ui, wlr_output);

	queue_output_add(server->queue, wlr_output->name);

	/* A hotplug while locked must not open an uncovered strip: re-extend the
	 * opaque floor over the new layout. */
	if (session_locked(server)) {
		lock_band_show(server);
	}
}

/* --- session lock: irreducible-C quarantine + opaque floor --- */

/* Size the opaque floor to the whole output layout and show the lock band.
 * Called on every engage and whenever outputs change while locked, so a
 * hotplug can never open an uncovered strip. */
static void lock_band_show(struct tinywl_server *server) {
	struct wlr_box box;
	wlr_output_layout_get_box(server->output_layout, NULL, &box);
	wlr_scene_rect_set_size(server->lock_floor, box.width, box.height);
	wlr_scene_node_set_position(&server->lock_floor->node, box.x, box.y);
	wlr_scene_node_set_enabled(&server->lock_tree->node, true);
}

/* Hide the whole band, not just the floor: the native lockscreen's reconciled
 * nodes live in lock_tree too and would otherwise stay painted over the
 * restored desktop (lock_tree is topmost). The band is the one switch, so the
 * floor's own enabled bit never has to agree with anything. The retained nodes
 * are kept, hidden, and refreshed by the next lock's solve before it commits. */
static void lock_band_hide(struct tinywl_server *server) {
	wlr_scene_node_set_enabled(&server->lock_tree->node, false);
}

/* Engage the quarantine. Setting the owner IS locking (session_locked derives
 * from it), so no window exists where input is trapped with no owner to release
 * it. Dropping seat focus sends leave to any focused client, which releases its
 * held keys (no stuck key on unlock); a live Lua pointer grab is force-stopped. */
static void lock_engage(struct tinywl_server *server, enum lock_owner owner,
		const char *kind) {
	server->lock_owner = owner;
	server->authenticated = false;
	wlr_seat_keyboard_notify_clear_focus(server->seat);
	wlr_seat_pointer_notify_clear_focus(server->seat);
	/* The quarantine cleared pointer focus, so it suspends an active constraint
	 * by the same fact a grab does: a locked screen cannot leave a client's
	 * lock on the cursor standing. */
	pointer_constraint_sync(server);
	server->pointer_grabbed = false;
	server->hovered_handle = 0;
	lock_band_show(server);
	/* Only a native lock draws the compositor's own lockscreen; an external
	 * locker paints its own surface, so the desktop solve stays off. */
	ui_set_lock_visible(server->ui, owner == LOCK_NATIVE);
	/* The floor now occludes everything, so nothing inhibits idle. */
	idle_inhibit_recompute(server);
	queue_session_lock(server->queue, kind);
}

/* Disengage: clear the owner (which is the unlock), hide the band, restore
 * pointer focus/hover. Keyboard focus is Lua policy again (its session::unlock
 * handler re-focuses the pre-lock client). */
static void lock_disengage(struct tinywl_server *server) {
	server->lock_owner = LOCK_NONE;
	server->authenticated = false;
	server->ext_lock = NULL;
	lock_band_hide(server);
	ui_set_lock_visible(server->ui, false);
	/* The desktop is visible again, so a live inhibitor counts again. */
	idle_inhibit_recompute(server);
	if (server->queue != NULL) {
		queue_session_unlock(server->queue);
	}
	process_cursor_motion(server, 0);
}

static void handle_lock_new_surface(struct wl_listener *listener, void *data) {
	struct tinywl_server *server =
		wl_container_of(listener, server, lock_new_surface);
	struct wlr_session_lock_surface_v1 *lock_surface = data;
	/* The lock surface's scene tree lives in lock_tree, above the floor:
	 * created after it, so a later sibling stacks on top. It auto-destroys
	 * with the surface, so a crashed locker leaves only the floor. */
	struct wlr_scene_tree *tree = wlr_scene_subsurface_tree_create(
		server->lock_tree, lock_surface->surface);
	struct wlr_box box;
	wlr_output_layout_get_box(server->output_layout, lock_surface->output, &box);
	wlr_scene_node_set_position(&tree->node, box.x, box.y);
	wlr_session_lock_surface_v1_configure(lock_surface, box.width, box.height);
	/* Hand the external locker keyboard focus so it takes typing; the input
	 * quarantine forwards seat keys to the focused (lock) surface for EXT. */
	struct wlr_keyboard *kb = wlr_seat_get_keyboard(server->seat);
	if (kb != NULL) {
		wlr_seat_keyboard_notify_enter(server->seat, lock_surface->surface,
			kb->keycodes, kb->num_keycodes, &kb->modifiers);
	} else {
		wlr_seat_keyboard_notify_enter(server->seat, lock_surface->surface,
			NULL, 0, NULL);
	}
}

/* Detach the three per-lock listeners exactly once. The unlock path removes
 * the destroy listener too, so a normal destroy-after-unlock does not re-enter
 * here; the crash path (no unlock) removes all three from the destroy handler. */
static void lock_ext_detach(struct tinywl_server *server) {
	wl_list_remove(&server->lock_new_surface.link);
	wl_list_remove(&server->lock_unlock.link);
	wl_list_remove(&server->lock_destroy.link);
}

static void handle_lock_unlock(struct wl_listener *listener, void *data) {
	struct tinywl_server *server =
		wl_container_of(listener, server, lock_unlock);
	lock_ext_detach(server);
	lock_disengage(server);
}

static void handle_lock_destroy(struct wl_listener *listener, void *data) {
	struct tinywl_server *server =
		wl_container_of(listener, server, lock_destroy);
	lock_ext_detach(server);
	server->ext_lock = NULL;
	if (server->lock_owner == LOCK_EXT) {
		/* The locker died while still locked. The floor never drops, so the
		 * desktop is not revealed for even a frame (the exit test) and the
		 * session stays locked. But it must not become a brick: VT switching is
		 * blocked while locked, and the only client that could authenticate is
		 * the one that just died, so there would be no way back into the machine
		 * short of ssh or the power button.
		 *
		 * Hand the lock to the compositor's own lockscreen instead. It
		 * authenticates through the same C PAM gate, and the promotion happens
		 * underneath the opaque floor, so nothing is shown between the locker
		 * dying and the lockscreen drawing. Blanking and recoverability were
		 * never actually a trade. */
		wlr_log(WLR_INFO, "session-lock client died while locked; "
			"promoting to the native lockscreen");
		server->lock_owner = LOCK_NATIVE;
		server->authenticated = false;
		wlr_seat_keyboard_notify_clear_focus(server->seat);
		ui_set_lock_visible(server->ui, true);
		queue_session_lock(server->queue, "native");
	}
}

static void handle_new_lock(struct wl_listener *listener, void *data) {
	struct tinywl_server *server = wl_container_of(listener, server, new_lock);
	struct wlr_session_lock_v1 *lock = data;
	if (server->lock_owner != LOCK_NONE) {
		/* One lock at a time. A second engage (another locker, or one racing a
		 * native lock) is refused; the client sees its object finished. */
		wlr_session_lock_v1_destroy(lock);
		return;
	}
	server->ext_lock = lock;
	lock_engage(server, LOCK_EXT, "ext");

	server->lock_new_surface.notify = handle_lock_new_surface;
	wl_signal_add(&lock->events.new_surface, &server->lock_new_surface);
	server->lock_unlock.notify = handle_lock_unlock;
	wl_signal_add(&lock->events.unlock, &server->lock_unlock);
	server->lock_destroy.notify = handle_lock_destroy;
	wl_signal_add(&lock->events.destroy, &server->lock_destroy);

	/* Send locked immediately: the opaque floor already covers every output,
	 * so there is no pre-commit leak window to gate on. Gating on
	 * an all-output commit would wedge the session if one output never commits. */
	wlr_session_lock_v1_send_locked(lock);
}

/* --- native lock verbs (core.lock/unlock/authenticate) --- */

static bool lock_op_lock(void *data) {
	struct tinywl_server *server = data;
	if (server->lock_owner != LOCK_NONE) {
		return false;
	}
	server->ext_lock = NULL;
	lock_engage(server, LOCK_NATIVE, "native");
	return true;
}

static bool lock_op_unlock(void *data) {
	struct tinywl_server *server = data;
	if (server->lock_owner == LOCK_NONE) {
		/* Already unlocked: idempotent success. */
		return true;
	}
	if (server->lock_owner != LOCK_NATIVE) {
		/* An external lock is not ours to disengage. */
		return false;
	}
	if (!server->authenticated) {
		/* The gate: no unlock without a PAM success this lock. Enforced here
		 * in C so a rogue rc.lua cannot disengage the quarantine. */
		return false;
	}
	lock_disengage(server);
	return true;
}

static bool lock_op_authenticate(void *data, const char *password) {
	struct tinywl_server *server = data;
	if (server->lock_owner != LOCK_NATIVE) {
		return false;
	}
	if (auth_check(password)) {
		server->authenticated = true;
		return true;
	}
	return false;
}

/* --- idle: notifier (activity) + inhibit (hold idle off while on screen) --- */

/* Is this inhibitor's surface actually on screen? The protocol honors an
 * inhibitor only while its surface is visually relevant, and "mapped" is not
 * that: in kiln a mapped client that Lua did not declare (a hidden tag) sits
 * disabled under clients_tree, so mapped-means-visible would let a video on a
 * background tag hold the screen awake forever (C deciding what
 * the protocol left to policy).
 *
 * Whether a client is on screen is Lua's fact, and the reconciled scene is
 * where that fact lands. Reading the scene is not C inventing a rule; it is C
 * reading the result of Lua's declare, the same authority the hit test already
 * trusts. wlr_scene_node_coords is false when the node or any ancestor is
 * disabled, which is exactly the undeclared case. */
static bool inhibitor_visible(struct wlr_idle_inhibitor_v1 *inhibitor) {
	struct wlr_surface *surface = inhibitor->surface;
	if (surface == NULL || !surface->mapped) {
		return false;
	}
	/* The inhibitor may name a subsurface; the scene tree hangs off the root. */
	struct wlr_surface *root = wlr_surface_get_root_surface(surface);
	struct wlr_scene_tree *tree = NULL;
	struct wlr_xdg_surface *xdg = wlr_xdg_surface_try_from_wlr_surface(root);
	if (xdg != NULL) {
		tree = xdg->data;
	} else {
		struct wlr_layer_surface_v1 *ls =
			wlr_layer_surface_v1_try_from_wlr_surface(root);
		if (ls != NULL) {
			tree = ls->data;
		}
	}
	if (tree == NULL) {
		/* A role we do not place (nothing today). Mapped is the best fact we
		 * have; honoring the inhibitor is the protocol-safe direction. */
		return true;
	}
	int lx, ly;
	return wlr_scene_node_coords(&tree->node, &lx, &ly);
}

/* inhibited = any inhibitor whose surface is visible. Recomputed on every edge
 * that can change the answer: the inhibitor coming or going, its surface
 * mapping or unmapping, and (since visibility is Lua's) after each frame's
 * reconcile, which is where a tag switch takes a client off screen. Gated on a
 * real change, so the per-frame call neither spams the log nor re-tells
 * wlroots something it already knows. */
static void idle_inhibit_recompute(struct tinywl_server *server) {
	bool inhibited = false;
	/* Nothing a client draws is visually relevant while locked: the opaque
	 * floor covers every output, whatever the scene still says about the node
	 * underneath it (wlr_scene_node_coords sees enabled/disabled, not
	 * occlusion). The protocol is explicit that this does not hold idle off,
	 * "becomes occluded, loses visibility, or otherwise becomes not visually
	 * relevant for the user". Without this, locking the machine with a video
	 * playing would keep the screen awake forever. */
	if (!session_locked(server)) {
		struct tinywl_idle_inhibitor *ii;
		wl_list_for_each(ii, &server->idle_inhibitors, link) {
			if (inhibitor_visible(ii->inhibitor)) {
				inhibited = true;
				break;
			}
		}
	}
	if (inhibited == server->idle_inhibited) {
		return;
	}
	server->idle_inhibited = inhibited;
	wlr_idle_notifier_v1_set_inhibited(server->idle_notifier, inhibited);
	/* The flip is a fact for the config too: a recipe toggles DND off it (and,
	 * if it wants, whether auto-lock waits). The timer is not consulted here, so
	 * idle::start still fires while inhibited. Guarded like the
	 * input paths: the per-frame recompute can run as the queue tears down. */
	if (server->queue != NULL) {
		queue_idle_inhibit(server->queue, inhibited);
	}
	/* The one answer to "why is the screen not blanking". */
	wlr_log(WLR_INFO, "idle inhibit: inhibited=%d", inhibited);
}

static void handle_idle_inhibitor_surface_map(struct wl_listener *listener,
		void *data) {
	struct tinywl_idle_inhibitor *ii =
		wl_container_of(listener, ii, surface_map);
	idle_inhibit_recompute(ii->server);
}

static void handle_idle_inhibitor_surface_unmap(struct wl_listener *listener,
		void *data) {
	struct tinywl_idle_inhibitor *ii =
		wl_container_of(listener, ii, surface_unmap);
	idle_inhibit_recompute(ii->server);
}

static void handle_idle_inhibitor_destroy(struct wl_listener *listener,
		void *data) {
	struct tinywl_idle_inhibitor *ii =
		wl_container_of(listener, ii, destroy);
	struct tinywl_server *server = ii->server;
	wl_list_remove(&ii->destroy.link);
	wl_list_remove(&ii->surface_map.link);
	wl_list_remove(&ii->surface_unmap.link);
	wl_list_remove(&ii->link);
	free(ii);
	idle_inhibit_recompute(server);
}

static void handle_new_idle_inhibitor(struct wl_listener *listener,
		void *data) {
	struct tinywl_server *server =
		wl_container_of(listener, server, new_idle_inhibitor);
	struct wlr_idle_inhibitor_v1 *inhibitor = data;
	struct tinywl_idle_inhibitor *ii = calloc(1, sizeof(*ii));
	ii->server = server;
	ii->inhibitor = inhibitor;
	ii->destroy.notify = handle_idle_inhibitor_destroy;
	wl_signal_add(&inhibitor->events.destroy, &ii->destroy);
	/* wlroots destroys the inhibitor with its surface, so these listeners never
	 * outlive the surface they are attached to. */
	ii->surface_map.notify = handle_idle_inhibitor_surface_map;
	wl_signal_add(&inhibitor->surface->events.map, &ii->surface_map);
	ii->surface_unmap.notify = handle_idle_inhibitor_surface_unmap;
	wl_signal_add(&inhibitor->surface->events.unmap, &ii->surface_unmap);
	wl_list_insert(&server->idle_inhibitors, &ii->link);
	idle_inhibit_recompute(server);
}

static void force_server_decoration(struct tinywl_toplevel *toplevel);

/* --- foreign-toplevel: the write-only mirror ---
 *
 * Every function here PUSHES a fact the runtime already owns down to the
 * client's foreign handle; none reads the handle back. The five
 * request notifiers feed the SAME origin-event queue the xdg/xwl asks use, so a
 * taskbar's minimize is indistinguishable from the client's own once it reaches
 * Lua: one dispatch path, kind-branched nowhere. */

static void toplevel_foreign_set_identity(struct tinywl_toplevel *toplevel,
		const char *app_id, const char *title) {
	if (toplevel->foreign == NULL) {
		return;
	}
	if (app_id != NULL) {
		wlr_foreign_toplevel_handle_v1_set_app_id(toplevel->foreign, app_id);
	}
	if (title != NULL) {
		wlr_foreign_toplevel_handle_v1_set_title(toplevel->foreign, title);
	}
}

static void ft_request_maximize(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, ft_request_maximize);
	struct wlr_foreign_toplevel_handle_v1_maximized_event *event = data;
	queue_client_request_maximize(toplevel->server->queue, toplevel->handle,
		event->maximized);
}

static void ft_request_minimize(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, ft_request_minimize);
	struct wlr_foreign_toplevel_handle_v1_minimized_event *event = data;
	queue_client_request_minimize(toplevel->server->queue, toplevel->handle,
		event->minimized);
}

static void ft_request_fullscreen(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, ft_request_fullscreen);
	struct wlr_foreign_toplevel_handle_v1_fullscreen_event *event = data;
	queue_client_request_fullscreen(toplevel->server->queue, toplevel->handle,
		event->fullscreen);
}

static void ft_request_activate(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, ft_request_activate);
	struct wlr_foreign_toplevel_handle_v1_activated_event *event = data;
	/* A foreign activate carries the requesting
	 * client's seat, so valid = seat != NULL. A real taskbar arrives
	 * valid=true (user-initiated), unlike the X11 leg which has no seat and is
	 * valid=false. The same request::activate fact, arbitrated in Lua. */
	queue_client_activate(toplevel->server->queue, toplevel->handle,
		event->seat != NULL, NULL);
}

static void ft_request_close(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, ft_request_close);
	/* No existing origin event carried a close ask; request::close is the one
	 * event this shard adds, through the same queue path (Lua's replaceable
	 * default answers it with the close verb). */
	queue_client_request_close(toplevel->server->queue, toplevel->handle);
}

static void toplevel_foreign_create(struct tinywl_toplevel *toplevel,
		const char *app_id, const char *title,
		bool fullscreen, bool maximized, bool minimized) {
	toplevel->foreign = wlr_foreign_toplevel_handle_v1_create(
		toplevel->server->foreign_toplevel_mgr);
	if (toplevel->foreign == NULL) {
		return;
	}
	toplevel_foreign_set_identity(toplevel, app_id, title);
	wlr_foreign_toplevel_handle_v1_set_fullscreen(toplevel->foreign, fullscreen);
	wlr_foreign_toplevel_handle_v1_set_maximized(toplevel->foreign, maximized);
	wlr_foreign_toplevel_handle_v1_set_minimized(toplevel->foreign, minimized);

	toplevel->ft_request_maximize.notify = ft_request_maximize;
	wl_signal_add(&toplevel->foreign->events.request_maximize,
		&toplevel->ft_request_maximize);
	toplevel->ft_request_minimize.notify = ft_request_minimize;
	wl_signal_add(&toplevel->foreign->events.request_minimize,
		&toplevel->ft_request_minimize);
	toplevel->ft_request_fullscreen.notify = ft_request_fullscreen;
	wl_signal_add(&toplevel->foreign->events.request_fullscreen,
		&toplevel->ft_request_fullscreen);
	toplevel->ft_request_activate.notify = ft_request_activate;
	wl_signal_add(&toplevel->foreign->events.request_activate,
		&toplevel->ft_request_activate);
	toplevel->ft_request_close.notify = ft_request_close;
	wl_signal_add(&toplevel->foreign->events.request_close,
		&toplevel->ft_request_close);
}

static void toplevel_foreign_destroy(struct tinywl_toplevel *toplevel) {
	if (toplevel->foreign == NULL) {
		return;
	}
	wl_list_remove(&toplevel->ft_request_maximize.link);
	wl_list_remove(&toplevel->ft_request_minimize.link);
	wl_list_remove(&toplevel->ft_request_fullscreen.link);
	wl_list_remove(&toplevel->ft_request_activate.link);
	wl_list_remove(&toplevel->ft_request_close.link);
	wlr_foreign_toplevel_handle_v1_destroy(toplevel->foreign);
	toplevel->foreign = NULL;
	toplevel->foreign_output = NULL;
}

static void xdg_toplevel_map(struct wl_listener *listener, void *data) {
	/* Called when the surface is mapped, or ready to display on-screen.
	 * The fact is reported; whether it takes focus is Lua's decision. */
	struct tinywl_toplevel *toplevel = wl_container_of(listener, toplevel, map);
	struct tinywl_server *server = toplevel->server;

	struct wlr_box *geo = &toplevel->xdg_toplevel->base->geometry;
	toplevel->last_width = geo->width;
	toplevel->last_height = geo->height;
	/* The state the client asked for before it had a window: xdg-shell
	 * allows set_fullscreen before the initial commit, and that ask fires its
	 * request event before any client object exists to honor it on. It is a
	 * fact the client holds at map, so it rides the map payload, where Lua has
	 * something to apply it to. requested.fullscreen_output is not reported:
	 * no fixture forces multi-output fullscreen. */
	struct queue_client_hints hints = {
		.fullscreen = toplevel->xdg_toplevel->requested.fullscreen,
		.maximized = toplevel->xdg_toplevel->requested.maximized,
		.minimized = toplevel->xdg_toplevel->requested.minimized,
	};
	queue_client_map(server->queue, toplevel->handle,
		toplevel->scene_tree->node.x, toplevel->scene_tree->node.y,
		geo->width, geo->height,
		toplevel->xdg_toplevel->app_id, toplevel->xdg_toplevel->title,
		&hints);
	/* The foreign mirror is born mapped, fed the same identity and opening
	 * state the map payload carries. */
	toplevel_foreign_create(toplevel,
		toplevel->xdg_toplevel->app_id, toplevel->xdg_toplevel->title,
		hints.fullscreen, hints.maximized, hints.minimized);
	/* The surface can be configured now, so the decoration force actually
	 * takes (it was a no-op pre-map); a client that preferred client-side is
	 * held to server-side here. */
	force_server_decoration(toplevel);
}

static void xdg_toplevel_unmap(struct wl_listener *listener, void *data) {
	/* Called when the surface is unmapped, and should no longer be shown. */
	struct tinywl_toplevel *toplevel = wl_container_of(listener, toplevel, unmap);

	queue_client_unmap(toplevel->server->queue, toplevel->handle);
	/* One handle per MAPPED client: it dies here and a remap mints a fresh
	 * one, so an unmapped client never lingers in a taskbar. */
	toplevel_foreign_destroy(toplevel);
}

static void xdg_toplevel_commit(struct wl_listener *listener, void *data) {
	/* Called when a new surface state is committed. */
	struct tinywl_toplevel *toplevel = wl_container_of(listener, toplevel, commit);

	if (toplevel->xdg_toplevel->base->initial_commit) {
		/* When an xdg_surface performs an initial commit, the compositor must
		 * reply with a configure so the client can map the surface. 0,0 lets
		 * the client pick its own dimensions. */
		wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel, 0, 0);
		return;
	}

	struct wlr_box *geo = &toplevel->xdg_toplevel->base->geometry;
	if (toplevel->xdg_toplevel->base->surface->mapped &&
			(geo->width != toplevel->last_width ||
			 geo->height != toplevel->last_height)) {
		toplevel->last_width = geo->width;
		toplevel->last_height = geo->height;
		queue_client_commit_size(toplevel->server->queue,
			toplevel->handle, geo->width, geo->height);
	}
}

#ifdef KILN_XWAYLAND
/* Defined with the icon helpers below; used here to hand metadata the same key
 * the map payload carries. */
static void xwl_icon_key(uint64_t handle, char *buf, size_t len);
#endif

/* One metadata event for both kinds: xdg carries app_id/title, X11 carries
 * title plus the class/instance hints (payload growth, not a second
 * event). Shared by the set_title listener, which both kinds wire. */
static void toplevel_emit_metadata(struct tinywl_toplevel *toplevel) {
#ifdef KILN_XWAYLAND
	if (toplevel->kind == TOPLEVEL_XWL) {
		struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
		struct queue_client_hints hints = {
			.class = xs->class,
			.instance = xs->instance,
			.pid = xs->pid,
			/* Role and icon ride metadata too: a set_role or
			 * set_icon after map re-states them here, and a client that
			 * dropped its icon marshals nil so the Lua field clears. */
			.role = toplevel->xwl_role,
		};
		char iconkey[40];
		if (toplevel->xwl_has_icon) {
			xwl_icon_key(toplevel->handle, iconkey, sizeof(iconkey));
			hints.icon = iconkey;
		}
		queue_client_metadata(toplevel->server->queue, toplevel->handle,
			NULL, xs->title, &hints);
		/* X11 has no app_id; its WM_CLASS is the closest identity a taskbar
		 * can key on, so the foreign mirror carries the class. */
		toplevel_foreign_set_identity(toplevel, xs->class, xs->title);
		return;
	}
#endif
	queue_client_metadata(toplevel->server->queue, toplevel->handle,
		toplevel->xdg_toplevel->app_id, toplevel->xdg_toplevel->title, NULL);
	toplevel_foreign_set_identity(toplevel,
		toplevel->xdg_toplevel->app_id, toplevel->xdg_toplevel->title);
}

static void toplevel_set_title(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, set_title);
	toplevel_emit_metadata(toplevel);
}

static void xdg_toplevel_set_app_id(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, set_app_id);
	toplevel_emit_metadata(toplevel);
}

static void xdg_toplevel_destroy(struct wl_listener *listener, void *data) {
	/* Called when the xdg_toplevel is destroyed. */
	struct tinywl_toplevel *toplevel = wl_container_of(listener, toplevel, destroy);

	queue_client_destroy(toplevel->server->queue, toplevel->handle);
	/* Normally the unmap already tore the mirror down; a destroy without a
	 * preceding unmap (or a stray one) must not leak the handle. */
	toplevel_foreign_destroy(toplevel);

	wl_list_remove(&toplevel->link);
	wl_list_remove(&toplevel->map.link);
	wl_list_remove(&toplevel->unmap.link);
	wl_list_remove(&toplevel->commit.link);
	wl_list_remove(&toplevel->destroy.link);
	wl_list_remove(&toplevel->set_title.link);
	wl_list_remove(&toplevel->set_app_id.link);
	wl_list_remove(&toplevel->request_maximize.link);
	wl_list_remove(&toplevel->request_fullscreen.link);
	wl_list_remove(&toplevel->request_minimize.link);
	/* If the client still holds a decoration, its destroy listener never
	 * fired; drop the decoration listeners so they cannot dangle. */
	if (toplevel->decoration != NULL) {
		wl_list_remove(&toplevel->set_decoration_mode.link);
		wl_list_remove(&toplevel->destroy_decoration.link);
	}

	free(toplevel);
}

/* The client asked for a state. The ask is a fact for
 * Lua, which honors it by declaring the client into the band and mirroring the
 * state back with set_fullscreen_hint / set_maximized_hint; C sets no state and
 * resizes nothing.
 *
 * The configure that rides along is the one thing the protocol leaves no
 * freedom in: xdg-shell says the compositor "will respond by emitting a
 * configure event" to set/unset maximized and fullscreen, whether or not the
 * state is granted. It re-sends the current state and decides nothing. Before
 * the initial commit there is nothing to configure; the client is still setting
 * up, so the ask is still reported and the configure is not sent.
 *
 * set_minimized obliges no configure (xdg-shell: "there is no way to know if
 * the surface is currently minimized"), so the minimize handler has no such leg. */
static void xdg_toplevel_request_maximize(
		struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, request_maximize);
	queue_client_request_maximize(toplevel->server->queue, toplevel->handle,
		toplevel->xdg_toplevel->requested.maximized);
	if (toplevel->xdg_toplevel->base->initialized) {
		wlr_xdg_surface_schedule_configure(toplevel->xdg_toplevel->base);
	}
}

static void xdg_toplevel_request_fullscreen(
		struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, request_fullscreen);
	/* requested.fullscreen_output (the client's preferred output) is not
	 * reported: no fixture forces multi-output fullscreen yet, and the
	 * absence is the decision. */
	queue_client_request_fullscreen(toplevel->server->queue, toplevel->handle,
		toplevel->xdg_toplevel->requested.fullscreen);
	if (toplevel->xdg_toplevel->base->initialized) {
		wlr_xdg_surface_schedule_configure(toplevel->xdg_toplevel->base);
	}
}

static void xdg_toplevel_request_minimize(
		struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, request_minimize);
	/* Constantly true on this path: xdg-shell has no un-minimize request. */
	queue_client_request_minimize(toplevel->server->queue, toplevel->handle,
		toplevel->xdg_toplevel->requested.minimized);
}

static const char *decoration_mode_name(
		enum wlr_xdg_toplevel_decoration_v1_mode mode) {
	switch (mode) {
	case WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE:
		return "client_side";
	case WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE:
		return "server_side";
	default:
		return "none";
	}
}

/* Force server-side decoration: this
 * compositor draws all chrome, there is no client-side path. set_mode needs a
 * surface that can receive a configure, so it is a no-op until the initial
 * commit; the map handler forces it once initialized, and this also re-forces
 * if a mapped client later re-requests. Idempotent: the client reconfigures
 * only on a real change. */
static void force_server_decoration(struct tinywl_toplevel *toplevel) {
	if (toplevel->decoration != NULL &&
			toplevel->xdg_toplevel->base->initialized) {
		wlr_xdg_toplevel_decoration_v1_set_mode(toplevel->decoration,
			WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
	}
}

static void xdg_toplevel_decoration_request_mode(
		struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, set_decoration_mode);
	/* The client's preferred mode is a fact for Lua titlebar policy, nothing
	 * the compositor acts on. */
	queue_client_decoration_mode(toplevel->server->queue, toplevel->handle,
		decoration_mode_name(toplevel->decoration->requested_mode));
	force_server_decoration(toplevel);
}

static void xdg_toplevel_decoration_destroy(
		struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, destroy_decoration);
	wl_list_remove(&toplevel->set_decoration_mode.link);
	wl_list_remove(&toplevel->destroy_decoration.link);
	toplevel->decoration = NULL;
}

static void server_new_xdg_decoration(struct wl_listener *listener, void *data) {
	struct tinywl_server *server =
		wl_container_of(listener, server, new_xdg_decoration);
	struct wlr_xdg_toplevel_decoration_v1 *deco = data;
	/* Resolve our toplevel through the scene tree stashed at creation:
	 * base->data is the scene tree, its node.data is the toplevel. */
	struct wlr_scene_tree *st = deco->toplevel->base->data;
	struct tinywl_toplevel *toplevel = st != NULL ? st->node.data : NULL;
	if (toplevel == NULL) {
		return;
	}
	toplevel->decoration = deco;
	toplevel->set_decoration_mode.notify = xdg_toplevel_decoration_request_mode;
	wl_signal_add(&deco->events.request_mode, &toplevel->set_decoration_mode);
	toplevel->destroy_decoration.notify = xdg_toplevel_decoration_destroy;
	wl_signal_add(&deco->events.destroy, &toplevel->destroy_decoration);
}

/* Resolve a client surface to our toplevel through the scene tree stashed at
 * creation (base->data is the scene tree, its node.data is the toplevel), the
 * same hop the decoration path uses. NULL for anything we do not own. */
static struct tinywl_toplevel *toplevel_from_surface(struct wlr_surface *surface) {
	struct wlr_xdg_toplevel *xt = wlr_xdg_toplevel_try_from_wlr_surface(surface);
	if (xt != NULL) {
		struct wlr_scene_tree *st = xt->base->data;
		return st != NULL ? st->node.data : NULL;
	}
#ifdef KILN_XWAYLAND
	struct wlr_xwayland_surface *xs =
		wlr_xwayland_surface_try_from_wlr_surface(surface);
	if (xs != NULL) {
		return xs->data;
	}
#endif
	return NULL;
}

static void server_request_activate(struct wl_listener *listener, void *data) {
	struct tinywl_server *server =
		wl_container_of(listener, server, request_activate);
	struct wlr_xdg_activation_v1_request_activate_event *event = data;
	struct tinywl_toplevel *toplevel = toplevel_from_surface(event->surface);
	if (toplevel == NULL) {
		return;
	}
	/* A token reaches request_activate with a seat only if it was minted from
	 * a validated recent input event (wlroots rejects a stale serial at commit),
	 * so seat != NULL means user-initiated. That is the whole fact; the
	 * focus-vs-urgent decision is Lua's, never the compositor's. */
	queue_client_activate(server->queue, toplevel->handle,
		event->token->seat != NULL, event->token->app_id);
}

/* Mint an xdg-activation token seat-backed by our seat and return its
 * exportable name (owned by wlroots, in the pool for 30s). core.spawn_with_token
 * sets XDG_ACTIVATION_TOKEN to this so a launched client can raise itself with a
 * token that arbitrates as user-initiated. The seat is set directly: the token's
 * seat_destroy link is init at create and only removed at destroy, so this never
 * outlives into a dangling listener. */
static const char *activation_op_mint_token(void *data) {
	struct tinywl_server *server = data;
	struct wlr_xdg_activation_token_v1 *token =
		wlr_xdg_activation_token_v1_create(server->xdg_activation);
	if (token == NULL) {
		return NULL;
	}
	token->seat = server->seat;
	return wlr_xdg_activation_token_v1_get_name(token);
}

static void server_new_xdg_toplevel(struct wl_listener *listener, void *data) {
	struct tinywl_server *server = wl_container_of(listener, server, new_xdg_toplevel);
	struct wlr_xdg_toplevel *xdg_toplevel = data;

	struct tinywl_toplevel *toplevel = calloc(1, sizeof(*toplevel));
	toplevel->server = server;
	toplevel->xdg_toplevel = xdg_toplevel;
	toplevel->handle = ++server->next_handle;
	toplevel->scene_tree =
		wlr_scene_xdg_surface_create(toplevel->server->clients_tree, xdg_toplevel->base);
	toplevel->scene_tree->node.data = toplevel;
	xdg_toplevel->base->data = toplevel->scene_tree;
	/* Invisible until the renderer borrows it for a solved box; the
	 * toplevels list holds every live toplevel, mapped or not, so
	 * handles resolve for the toplevel's whole life. */
	wlr_scene_node_set_enabled(&toplevel->scene_tree->node, false);
	wl_list_insert(&server->toplevels, &toplevel->link);

	/* Listen to the various events it can emit */
	toplevel->map.notify = xdg_toplevel_map;
	wl_signal_add(&xdg_toplevel->base->surface->events.map, &toplevel->map);
	toplevel->unmap.notify = xdg_toplevel_unmap;
	wl_signal_add(&xdg_toplevel->base->surface->events.unmap, &toplevel->unmap);
	toplevel->commit.notify = xdg_toplevel_commit;
	wl_signal_add(&xdg_toplevel->base->surface->events.commit, &toplevel->commit);

	toplevel->destroy.notify = xdg_toplevel_destroy;
	wl_signal_add(&xdg_toplevel->events.destroy, &toplevel->destroy);

	toplevel->set_title.notify = toplevel_set_title;
	wl_signal_add(&xdg_toplevel->events.set_title, &toplevel->set_title);
	toplevel->set_app_id.notify = xdg_toplevel_set_app_id;
	wl_signal_add(&xdg_toplevel->events.set_app_id, &toplevel->set_app_id);

	/* request_move and request_resize are not forwarded: an interactive
	 * move or resize starts from Lua policy (a binding or a titlebar drag),
	 * never from the client's ask.
	 * The state requests are origin events, answered in Lua. */
	toplevel->request_maximize.notify = xdg_toplevel_request_maximize;
	wl_signal_add(&xdg_toplevel->events.request_maximize, &toplevel->request_maximize);
	toplevel->request_fullscreen.notify = xdg_toplevel_request_fullscreen;
	wl_signal_add(&xdg_toplevel->events.request_fullscreen, &toplevel->request_fullscreen);
	toplevel->request_minimize.notify = xdg_toplevel_request_minimize;
	wl_signal_add(&xdg_toplevel->events.request_minimize, &toplevel->request_minimize);
}

#ifdef KILN_XWAYLAND
/* --- XWayland surfaces: same struct, same handle space, same events ---
 *
 * The protocol differences live here and only here: the wlr_surface blinks
 * in and out (associate/dissociate), geometry travels via explicit X
 * configures rather than commits, and the client can ask to place itself
 * (request_configure), which becomes a fact for Lua like every other ask. */

/* The fourteen EWMH window types, by their _NET_WM_WINDOW_TYPE_* suffix.
 * Index-parallel with server->xwl_type_atoms. */
static const char *const xwl_type_names[14] = {
	"desktop", "dock", "toolbar", "menu", "utility", "splash", "dialog",
	"dropdown_menu", "popup_menu", "tooltip", "notification", "combo",
	"dnd", "normal",
};
static const char *const xwl_type_atom_names[14] = {
	"_NET_WM_WINDOW_TYPE_DESKTOP", "_NET_WM_WINDOW_TYPE_DOCK",
	"_NET_WM_WINDOW_TYPE_TOOLBAR", "_NET_WM_WINDOW_TYPE_MENU",
	"_NET_WM_WINDOW_TYPE_UTILITY", "_NET_WM_WINDOW_TYPE_SPLASH",
	"_NET_WM_WINDOW_TYPE_DIALOG", "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU",
	"_NET_WM_WINDOW_TYPE_POPUP_MENU", "_NET_WM_WINDOW_TYPE_TOOLTIP",
	"_NET_WM_WINDOW_TYPE_NOTIFICATION", "_NET_WM_WINDOW_TYPE_COMBO",
	"_NET_WM_WINDOW_TYPE_DND", "_NET_WM_WINDOW_TYPE_NORMAL",
};

/* _NET_WM_WINDOW_TYPE translated to names, in CLIENT order, comma-joined:
 * the list's order is the client's preference, and ranking it C-side would
 * be C deciding what was left to policy. Atoms outside the EWMH
 * fourteen are omitted: naming them would cost a round trip per map.
 * NULL when nothing is recognized. */
static const char *xwl_window_types(struct tinywl_toplevel *toplevel,
		char *buf, size_t size) {
	struct tinywl_server *server = toplevel->server;
	struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
	size_t len = 0;
	for (size_t i = 0; i < xs->window_type_len; i++) {
		for (size_t t = 0; t < 14; t++) {
			if (server->xwl_type_atoms[t] == XCB_ATOM_NONE ||
					server->xwl_type_atoms[t] != xs->window_type[i]) {
				continue;
			}
			size_t need = strlen(xwl_type_names[t]) + (len > 0 ? 1 : 0);
			if (len + need + 1 > size) {
				break;
			}
			if (len > 0) {
				buf[len++] = ',';
			}
			strcpy(buf + len, xwl_type_names[t]);
			len += strlen(xwl_type_names[t]);
			break;
		}
	}
	return len > 0 ? buf : NULL;
}

/* The icon cache key for a handle, deterministic so nothing is stored but the
 * key's own presence flag: Lua and C derive the same string from the handle. */
static void xwl_icon_key(uint64_t handle, char *buf, size_t len) {
	snprintf(buf, len, "xwl-icon:%" PRIu64, handle);
}

/* Read WM_WINDOW_ROLE into toplevel->xwl_role (freeing any prior value). This
 * is the finding the plan did not foresee: wlroots reads _NET_WM_ICON at
 * associate but not WM_WINDOW_ROLE, and a client sets its role before mapping,
 * so xs->role is nil at map. kiln reads the property itself on its own X
 * connection, the ~15 lines a working role fact costs. Blocking, at map and
 * set_role only, the icon's discipline. NULL on any failure. */
static void xwl_read_role(struct tinywl_toplevel *toplevel) {
	struct tinywl_server *server = toplevel->server;
	free(toplevel->xwl_role);
	toplevel->xwl_role = NULL;
	if (server->xcb_conn == NULL ||
			server->xwl_role_atom == XCB_ATOM_NONE) {
		return;
	}
	xcb_get_property_reply_t *reply = xcb_get_property_reply(server->xcb_conn,
		xcb_get_property(server->xcb_conn, 0, toplevel->xwl_surface->window_id,
			server->xwl_role_atom, XCB_ATOM_ANY, 0, 128), NULL);
	if (reply == NULL) {
		return;
	}
	int len = xcb_get_property_value_length(reply);
	if (len > 0) {
		toplevel->xwl_role = strndup(xcb_get_property_value(reply), (size_t)len);
	}
	free(reply);
}

/* Decode the client's _NET_WM_ICON into the image cache, largest frame wins.
 * This is the one place kiln reads an X property itself: wlroots deliberately
 * fetches _NET_WM_ICON with length 0 and points compositors at its helper, so
 * the round trip lives here. It is blocking on the xwm connection, at map and
 * on set_icon only (never on a title change), the way tray's put_pixmap reads
 * its icon synchronously off DBus. The frames are packed uint32 ARGB out of the
 * ewmh iterator (host order); ui_image_put wants RGBA bytes, so this is the
 * tray reorder loop's shape over a different source layout. Returns whether a
 * frame was accepted, so the caller can flag the key live. */
static bool xwl_put_icon(struct tinywl_toplevel *toplevel) {
	struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
	xcb_ewmh_get_wm_icon_reply_t reply = {0};
	if (!wlr_xwayland_surface_fetch_icon(xs, &reply)) {
		return false;
	}

	/* Largest area wins (the tray put_pixmap guard): a taskbar wants the
	 * crispest frame the client shipped, and Lua/Clay scale the one C kept. */
	uint32_t best_w = 0, best_h = 0;
	const uint32_t *best = NULL;
	xcb_ewmh_wm_icon_iterator_t it = xcb_ewmh_get_wm_icon_iterator(&reply);
	for (; it.rem > 0; xcb_ewmh_get_wm_icon_next(&it)) {
		if (it.width == 0 || it.height == 0 ||
				(uint64_t)it.width * it.height <=
					(uint64_t)best_w * best_h) {
			continue;
		}
		best_w = it.width;
		best_h = it.height;
		best = it.data;
	}

	bool ok = false;
	if (best != NULL) {
		size_t n = (size_t)best_w * best_h;
		uint8_t *rgba = malloc(n * 4);
		if (rgba != NULL) {
			for (size_t i = 0; i < n; i++) {
				uint32_t v = best[i];
				rgba[i * 4 + 0] = (v >> 16) & 0xff; /* r */
				rgba[i * 4 + 1] = (v >> 8) & 0xff;  /* g */
				rgba[i * 4 + 2] = v & 0xff;         /* b */
				rgba[i * 4 + 3] = (v >> 24) & 0xff; /* a */
			}
			char key[40];
			xwl_icon_key(toplevel->handle, key, sizeof(key));
			ok = ui_image_put(toplevel->server->ui, key, (int)best_w,
				(int)best_h, (int)best_w * 4, true, 8, 4, rgba, n * 4);
			free(rgba);
		}
	}
	xcb_ewmh_get_wm_icon_reply_wipe(&reply);
	return ok;
}

/* The X map fact, read and enqueued. Two callers: xwl_map, and replay
 * re-stating it for a Lua layer that dropped its model. The hints are returned
 * because the foreign mirror is fed from the same snapshot the payload carries;
 * replay discards them (it never touches the mirror, which still exists). */
static struct queue_client_hints xwl_emit_map(struct tinywl_toplevel *toplevel) {
	struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
	/* Hints are read here, at map: wlroots has cached them all by now, and
	 * create-time reads race the XWayland handshake (prior-art scar). */
	struct tinywl_toplevel *parent =
		xs->parent != NULL ? xs->parent->data : NULL;
	char types[256];
	struct queue_client_hints hints = {
		.class = xs->class,
		.instance = xs->instance,
		.window_type = xwl_window_types(toplevel, types, sizeof(types)),
		.pid = xs->pid,
		.transient_for = parent != NULL ? parent->handle : 0,
		.override_redirect = xs->override_redirect,
		/* wlroots' ICCCM answer, only asked for OR windows: whether this
		 * kind of window takes focus is what the type list implies, and
		 * kiln adds no opinion on top. */
		.wants_focus = xs->override_redirect &&
			wlr_xwayland_surface_override_redirect_wants_focus(xs),
		/* The state the window already carries as it maps. An X client
		 * writes _NET_WM_STATE on the window before mapping (firefox opens
		 * maximized this way), which wlroots reads into these fields and
		 * never signals, correctly: nothing changed, so there was no request.
		 * A snapshot like every other hint here; C acts on none of it. EWMH
		 * maximizes per axis, and both axes is the state a maximize means. */
		.fullscreen = xs->fullscreen,
		.maximized = xs->maximized_horz && xs->maximized_vert,
		.minimized = xs->minimized,
		/* WM_WINDOW_ROLE verbatim; wlroots reads the property
		 * for us. The icon is set below only when a frame was decoded: the
		 * fetch itself is xwl_map's/xwl_set_icon's job, so replay (which also
		 * lands here) re-hands the key it already cached instead of a fresh
		 * round trip. Same for role: read at map, referenced here. */
		.role = toplevel->xwl_role,
	};
	char iconkey[40];
	if (toplevel->xwl_has_icon) {
		xwl_icon_key(toplevel->handle, iconkey, sizeof(iconkey));
		hints.icon = iconkey;
	}
	/* x/y are the client's own placement ask (root coords): a managed
	 * window gets tiled over it, override-redirect declares it verbatim.
	 * No app_id; X11 speaks WM_CLASS. */
	queue_client_map(toplevel->server->queue, toplevel->handle,
		xs->x, xs->y, xs->width, xs->height, NULL, xs->title, &hints);
	return hints;
}

static void xwl_map(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel = wl_container_of(listener, toplevel, map);
	struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
	wlr_log(WLR_DEBUG, "xwl map: window %u handle %" PRIu64 " class %s",
		xs->window_id, toplevel->handle,
		xs->class != NULL ? xs->class : "(nil)");
	toplevel->last_width = xs->width;
	toplevel->last_height = xs->height;
	/* Read the icon and role before the map payload is built, so both ride the
	 * same event; set_icon/set_role re-run them later for a live change. */
	toplevel->xwl_has_icon = xwl_put_icon(toplevel);
	xwl_read_role(toplevel);
	struct queue_client_hints hints = xwl_emit_map(toplevel);
	/* Same mirror on the X leg: WM_CLASS stands in for app_id, states from
	 * the map snapshot. */
	toplevel_foreign_create(toplevel, xs->class, xs->title,
		hints.fullscreen, hints.maximized, hints.minimized);
}

static void xwl_unmap(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel = wl_container_of(listener, toplevel, unmap);
	queue_client_unmap(toplevel->server->queue, toplevel->handle);
	toplevel_foreign_destroy(toplevel);
}

/* The X analog of xdg_toplevel_commit's size leg:
 * set_geometry misses WM-initiated resizes (wlroots writes its
 * cache at configure time, so the ConfigureNotify round trip diffs to
 * nothing), but the client's resized buffer always lands here. OR surfaces
 * are excluded: their one geometry fact rides the set_geometry notification
 * (commit_size never fires for OR). */
static void xwl_commit(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, commit);
	struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
	if (xs->surface == NULL || !xs->surface->mapped ||
			xs->override_redirect) {
		return;
	}
	int w = xs->surface->current.width;
	int h = xs->surface->current.height;
	if (w > 0 && h > 0 &&
			(w != toplevel->last_width || h != toplevel->last_height)) {
		toplevel->last_width = w;
		toplevel->last_height = h;
		queue_client_commit_size(toplevel->server->queue, toplevel->handle,
			w, h);
	}
}

static void xwl_associate(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, xwl_associate);
	struct wlr_surface *surface = toplevel->xwl_surface->surface;
	wlr_log(WLR_DEBUG, "xwl associate: window %u handle %" PRIu64,
		toplevel->xwl_surface->window_id, toplevel->handle);
	/* The wlr_surface exists as of now. Its scene surface goes INSIDE the
	 * stable outer tree created at new_surface and dies with the
	 * wlr_surface at dissociate, so the borrow contract and the
	 * one-tree-per-handle identity rule never see the blink. */
	wlr_scene_surface_create(toplevel->scene_tree, surface);
	toplevel->map.notify = xwl_map;
	wl_signal_add(&surface->events.map, &toplevel->map);
	toplevel->unmap.notify = xwl_unmap;
	wl_signal_add(&surface->events.unmap, &toplevel->unmap);
	toplevel->commit.notify = xwl_commit;
	wl_signal_add(&surface->events.commit, &toplevel->commit);
	toplevel->xwl_associated = true;
}

static void xwl_dissociate(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, xwl_dissociate);
	/* The wlr_surface is going away and takes its scene surface with it;
	 * only the listeners on it must go. */
	if (toplevel->xwl_associated) {
		wl_list_remove(&toplevel->map.link);
		wl_list_remove(&toplevel->unmap.link);
		wl_list_remove(&toplevel->commit.link);
		toplevel->xwl_associated = false;
	}
}

static void xwl_request_configure(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, xwl_request_configure);
	struct wlr_xwayland_surface_configure_event *event = data;
	struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
	/* Pre-map the WM has no opinion (Lua has seen nothing to declare), so
	 * obeying verbatim is the one legal answer; without it the client never
	 * receives the configure it waits on and never maps. */
	if (xs->surface == NULL || !xs->surface->mapped) {
		wlr_xwayland_surface_configure(xs,
			event->x, event->y, event->width, event->height);
		return;
	}
	/* Mapped: a fact for Lua. A tiled config ignores it and re-declares;
	 * floating policy may honor it. No OR leg exists here: the X server
	 * does not redirect OR configures to the WM, so OR geometry arrives
	 * only via set_geometry, already applied. */
	queue_client_request_configure(toplevel->server->queue, toplevel->handle,
		event->x, event->y, event->width, event->height);
}

static void xwl_request_activate(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, xwl_request_activate);
	/* An X client asking for itself, with no seat-backed token to check:
	 * the same request::activate fact xdg-activation emits, valid=false. */
	queue_client_activate(toplevel->server->queue, toplevel->handle,
		false, NULL);
}

/* The same three state requests as xdg, arriving as _NET_WM_STATE client
 * messages. wlroots' xwm writes the requested state onto the surface and only
 * then emits, and only when it changed, so the ask is read straight off the
 * surface. Kind-branched here in the protocol wiring; one event, one dispatch
 * path, one Lua handler. */
static void xwl_request_fullscreen(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, request_fullscreen);
	queue_client_request_fullscreen(toplevel->server->queue, toplevel->handle,
		toplevel->xwl_surface->fullscreen);
}

static void xwl_request_maximize(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, request_maximize);
	/* EWMH maximizes per axis; a client asking for one axis is asking for a
	 * half-maximized window, which is not the state this WM has. Both axes
	 * is the ask; anything less reads as not maximized. */
	struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
	queue_client_request_maximize(toplevel->server->queue, toplevel->handle,
		xs->maximized_horz && xs->maximized_vert);
}

static void xwl_request_minimize(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, request_minimize);
	/* Unlike xdg, X11 carries the bool: an X client can ask to be restored. */
	struct wlr_xwayland_minimize_event *event = data;
	queue_client_request_minimize(toplevel->server->queue, toplevel->handle,
		event->minimize);
}

static void xwl_set_class(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, xwl_set_class);
	toplevel_emit_metadata(toplevel);
}

/* WM_WINDOW_ROLE changed after map: re-read it ourselves (wlroots signals the
 * change but leaves the pre-map read to us, see xwl_read_role) and re-state
 * metadata, the set_class shape. */
static void xwl_set_role(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, xwl_set_role);
	xwl_read_role(toplevel);
	toplevel_emit_metadata(toplevel);
}

/* _NET_WM_ICON changed: re-read it (a live swap re-puts under the same key, so
 * ui_image_put's gen bump re-rasters the visible cell) and re-state metadata so
 * the key marshals, or clears to nil when the client dropped its icon. */
static void xwl_set_icon(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, xwl_set_icon);
	toplevel->xwl_has_icon = xwl_put_icon(toplevel);
	toplevel_emit_metadata(toplevel);
}

static void xwl_set_hints(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, xwl_set_hints);
	struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
	/* WM_HINTS: urgency is the one live fact Lua acts on. */
	queue_client_urgent(toplevel->server->queue, toplevel->handle,
		xs->hints != NULL &&
			(xs->hints->flags & XCB_ICCCM_WM_HINT_X_URGENCY) != 0);
}

static void xwl_set_geometry(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, xwl_set_geometry);
	struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
	if (xs->surface == NULL || !xs->surface->mapped) {
		return;
	}
	/* Override-redirect only: the X server already applied the client's own
	 * geometry (ConfigureNotify; OR windows never generate
	 * request_configure), so this is the applied fact on the same event,
	 * notification reading. Lua re-declares the float there.
	 * No managed leg: a managed size change only ever materializes as a
	 * surface commit (self-resizes are intercepted, and wlroots caches our
	 * own configures optimistically, so this signal never fires for them);
	 * xwl_commit below is the one managed size source, like xdg. */
	if (xs->override_redirect) {
		toplevel->last_width = xs->width;
		toplevel->last_height = xs->height;
		queue_client_request_configure(toplevel->server->queue,
			toplevel->handle, xs->x, xs->y, xs->width, xs->height);
	}
}

static void xwl_surface_destroy(struct wl_listener *listener, void *data) {
	struct tinywl_toplevel *toplevel =
		wl_container_of(listener, toplevel, destroy);
	queue_client_destroy(toplevel->server->queue, toplevel->handle);
	toplevel_foreign_destroy(toplevel);
	if (toplevel->xwl_associated) {
		wl_list_remove(&toplevel->map.link);
		wl_list_remove(&toplevel->unmap.link);
		wl_list_remove(&toplevel->commit.link);
	}
	wl_list_remove(&toplevel->link);
	wl_list_remove(&toplevel->destroy.link);
	wl_list_remove(&toplevel->xwl_associate.link);
	wl_list_remove(&toplevel->xwl_dissociate.link);
	wl_list_remove(&toplevel->xwl_request_configure.link);
	wl_list_remove(&toplevel->xwl_request_activate.link);
	wl_list_remove(&toplevel->request_fullscreen.link);
	wl_list_remove(&toplevel->request_maximize.link);
	wl_list_remove(&toplevel->request_minimize.link);
	wl_list_remove(&toplevel->set_title.link);
	wl_list_remove(&toplevel->xwl_set_class.link);
	wl_list_remove(&toplevel->xwl_set_role.link);
	wl_list_remove(&toplevel->xwl_set_icon.link);
	wl_list_remove(&toplevel->xwl_set_hints.link);
	wl_list_remove(&toplevel->xwl_set_geometry.link);
	/* Ours to destroy: this tree outlives associate blinks so the handle
	 * keeps one identity (xdg trees die with their surface instead). The
	 * renderer resolves by handle each frame and drops its pointer once
	 * resolve misses. */
	wlr_scene_node_destroy(&toplevel->scene_tree->node);
	free(toplevel->xwl_role);
	free(toplevel);
}

static void server_new_xwayland_surface(struct wl_listener *listener,
		void *data) {
	struct tinywl_server *server =
		wl_container_of(listener, server, new_xwayland_surface);
	struct wlr_xwayland_surface *xsurface = data;

	struct tinywl_toplevel *toplevel = calloc(1, sizeof(*toplevel));
	toplevel->server = server;
	toplevel->kind = TOPLEVEL_XWL;
	toplevel->xwl_surface = xsurface;
	toplevel->handle = ++server->next_handle;
	wlr_log(WLR_DEBUG, "xwl new surface: window %u handle %" PRIu64
		" override_redirect %d", xsurface->window_id, toplevel->handle,
		xsurface->override_redirect);
	/* One scene tree for the toplevel's whole life, like xdg; see
	 * xwl_associate for what lives inside it. */
	toplevel->scene_tree = wlr_scene_tree_create(server->clients_tree);
	toplevel->scene_tree->node.data = toplevel;
	xsurface->data = toplevel;
	wlr_scene_node_set_enabled(&toplevel->scene_tree->node, false);
	wl_list_insert(&server->toplevels, &toplevel->link);

	toplevel->xwl_associate.notify = xwl_associate;
	wl_signal_add(&xsurface->events.associate, &toplevel->xwl_associate);
	toplevel->xwl_dissociate.notify = xwl_dissociate;
	wl_signal_add(&xsurface->events.dissociate, &toplevel->xwl_dissociate);
	toplevel->destroy.notify = xwl_surface_destroy;
	wl_signal_add(&xsurface->events.destroy, &toplevel->destroy);
	toplevel->xwl_request_configure.notify = xwl_request_configure;
	wl_signal_add(&xsurface->events.request_configure,
		&toplevel->xwl_request_configure);
	toplevel->xwl_request_activate.notify = xwl_request_activate;
	wl_signal_add(&xsurface->events.request_activate,
		&toplevel->xwl_request_activate);
	/* The state requests hang on the create set, where the other X11 request
	 * listeners already are: they arrive as client messages on the window,
	 * which outlives the associate/dissociate blinks of its wlr_surface. */
	toplevel->request_fullscreen.notify = xwl_request_fullscreen;
	wl_signal_add(&xsurface->events.request_fullscreen,
		&toplevel->request_fullscreen);
	toplevel->request_maximize.notify = xwl_request_maximize;
	wl_signal_add(&xsurface->events.request_maximize,
		&toplevel->request_maximize);
	toplevel->request_minimize.notify = xwl_request_minimize;
	wl_signal_add(&xsurface->events.request_minimize,
		&toplevel->request_minimize);
	toplevel->set_title.notify = toplevel_set_title;
	wl_signal_add(&xsurface->events.set_title, &toplevel->set_title);
	toplevel->xwl_set_class.notify = xwl_set_class;
	wl_signal_add(&xsurface->events.set_class, &toplevel->xwl_set_class);
	toplevel->xwl_set_role.notify = xwl_set_role;
	wl_signal_add(&xsurface->events.set_role, &toplevel->xwl_set_role);
	toplevel->xwl_set_icon.notify = xwl_set_icon;
	wl_signal_add(&xsurface->events.set_icon, &toplevel->xwl_set_icon);
	toplevel->xwl_set_hints.notify = xwl_set_hints;
	wl_signal_add(&xsurface->events.set_hints, &toplevel->xwl_set_hints);
	toplevel->xwl_set_geometry.notify = xwl_set_geometry;
	wl_signal_add(&xsurface->events.set_geometry,
		&toplevel->xwl_set_geometry);
}

static void server_xwayland_ready(struct wl_listener *listener, void *data) {
	struct tinywl_server *server =
		wl_container_of(listener, server, xwayland_ready);
	wlr_xwayland_set_seat(server->xwayland, server->seat);
	/* The WM-side connection: kill, plus the fourteen
	 * window-type atoms. Failure degrades both loudly, never a fallback. */
	server->xcb_conn = xcb_connect(server->xwayland->display_name, NULL);
	if (server->xcb_conn != NULL &&
			xcb_connection_has_error(server->xcb_conn)) {
		wlr_log(WLR_ERROR,
			"WM-side XCB connection failed; kill and window_type degraded");
		xcb_disconnect(server->xcb_conn);
		server->xcb_conn = NULL;
	}
	if (server->xcb_conn == NULL) {
		return;
	}
	/* Intern once; atoms are server-global, so these values are the same
	 * ones xwm holds and compare directly against a surface's type list. */
	xcb_intern_atom_cookie_t cookies[14];
	for (size_t t = 0; t < 14; t++) {
		cookies[t] = xcb_intern_atom(server->xcb_conn, 0,
			strlen(xwl_type_atom_names[t]), xwl_type_atom_names[t]);
	}
	for (size_t t = 0; t < 14; t++) {
		xcb_intern_atom_reply_t *reply =
			xcb_intern_atom_reply(server->xcb_conn, cookies[t], NULL);
		if (reply == NULL) {
			wlr_log(WLR_ERROR, "intern %s failed; window_type degraded",
				xwl_type_atom_names[t]);
			continue;
		}
		server->xwl_type_atoms[t] = reply->atom;
		free(reply);
	}
	/* WM_WINDOW_ROLE, the one property kiln reads itself (see the field). */
	xcb_intern_atom_reply_t *role_reply = xcb_intern_atom_reply(server->xcb_conn,
		xcb_intern_atom(server->xcb_conn, 0, strlen("WM_WINDOW_ROLE"),
			"WM_WINDOW_ROLE"), NULL);
	if (role_reply != NULL) {
		server->xwl_role_atom = role_reply->atom;
		free(role_reply);
	}
}
#endif /* KILN_XWAYLAND */

/* Re-state the map fact for every mapped toplevel. kiln.reload() drops
 * Lua's client model and rebuilds it from the origin queue, so what the
 * compositor knows has to be restated rather than remembered across the reload.
 * Synthetic maps ride the one queue like every other origin event, which is why
 * a reload needs no second path into Lua.
 *
 * No handle argument: which clients exist is exactly what the caller forgot.
 *
 * The foreign-toplevel mirror is untouched. It already exists for every mapped
 * client and never depended on Lua's model; recreating it here would leak a
 * handle per reload. */
static void client_op_replay(void *data) {
	struct tinywl_server *server = data;
	/* rc.lua runs inside core_create, which is before queue_create: a config
	 * that called reload at load time would have nowhere to route. Same guard
	 * the key and output paths use. */
	if (server->queue == NULL) {
		return;
	}
	struct tinywl_toplevel *toplevel;
	wl_list_for_each(toplevel, &server->toplevels, link) {
		/* The list holds pre-map toplevels too (insert is at create), and an
		 * unmapped client has no map fact to state. */
		if (toplevel->kind == TOPLEVEL_XDG) {
			if (!toplevel->xdg_toplevel->base->surface->mapped) {
				continue;
			}
			/* current, not requested: requested is the pre-map ask that
			 * xdg_toplevel_map reported once, and Lua has since honored or
			 * refused it. current is the state the client is actually in.
			 * xdg-shell has no minimized state, so there is nothing to read
			 * for it: a client Lua had minimized replays unminimized, which is
			 * honest (that state was Lua's, and Lua dropped it). */
			struct queue_client_hints hints = {
				.fullscreen = toplevel->xdg_toplevel->current.fullscreen,
				.maximized = toplevel->xdg_toplevel->current.maximized,
			};
			struct wlr_box *geo = &toplevel->xdg_toplevel->base->geometry;
			queue_client_map(server->queue, toplevel->handle,
				toplevel->scene_tree->node.x, toplevel->scene_tree->node.y,
				geo->width, geo->height, toplevel->xdg_toplevel->app_id,
				toplevel->xdg_toplevel->title, &hints);
			continue;
		}
#ifdef KILN_XWAYLAND
		struct wlr_xwayland_surface *xs = toplevel->xwl_surface;
		/* Not xwl_commit's test, which also skips override-redirect because OR
		 * geometry rides set_geometry instead. An OR window is a client Lua
		 * knows about (xwl_map states it, hints and all), so replay states it. */
		if (xs->surface == NULL || !xs->surface->mapped) {
			continue;
		}
		xwl_emit_map(toplevel);
#endif
	}
}

/* Climb the popup parent chain to the surface that roots it (an xdg toplevel
 * or a layer surface, e.g. a waybar tooltip) and return that root's handle
 * (0 if none, e.g. a popup parented to something we do not track). Nested
 * popups walk up through their parent popups. */
static uint64_t popup_root_handle(struct tinywl_server *server,
		struct wlr_xdg_popup *xdg_popup) {
	struct wlr_surface *surface = xdg_popup->parent;
	while (surface != NULL) {
		struct wlr_xdg_toplevel *xt =
			wlr_xdg_toplevel_try_from_wlr_surface(surface);
		if (xt != NULL) {
			struct tinywl_toplevel *tl;
			wl_list_for_each(tl, &server->toplevels, link) {
				if (tl->xdg_toplevel == xt) {
					return tl->handle;
				}
			}
			return 0;
		}
		struct wlr_layer_surface_v1 *ls =
			wlr_layer_surface_v1_try_from_wlr_surface(surface);
		if (ls != NULL) {
			struct tinywl_layer *layer;
			wl_list_for_each(layer, &server->layers, link) {
				if (layer->layer_surface == ls) {
					return layer->handle;
				}
			}
			return 0;
		}
		struct wlr_xdg_popup *pp =
			wlr_xdg_popup_try_from_wlr_surface(surface);
		if (pp == NULL) {
			return 0;
		}
		surface = pp->parent;
	}
	return 0;
}

/* The layout-absolute position and last-known size of a popup root, from the
 * retained scene graph: a toplevel's declared size or a layer surface's last
 * acked configure. False when the root is gone or currently not shown. */
static bool root_geometry(struct tinywl_server *server, uint64_t handle,
		int *lx, int *ly, int *width, int *height) {
	struct tinywl_toplevel *toplevel = toplevel_by_handle(server, handle);
	if (toplevel != NULL) {
		if (!wlr_scene_node_coords(&toplevel->scene_tree->node, lx, ly)) {
			return false;
		}
		*width = toplevel->last_width;
		*height = toplevel->last_height;
		return true;
	}
	struct tinywl_layer *layer = layer_by_handle(server, handle);
	if (layer != NULL) {
		if (!wlr_scene_node_coords(&layer->scene_tree->node, lx, ly)) {
			return false;
		}
		*width = layer->layer_surface->current.actual_width;
		*height = layer->layer_surface->current.actual_height;
		return true;
	}
	return false;
}

/* Unconstrain a popup against the output box, expressed in its root toplevel's
 * surface coordinates. Protocol arithmetic with zero freedom: the positioner
 * rules decide the flip, and the root's scene position is retained state from
 * the last solve. Returns true if a box was computed and sent (which schedules
 * the configure); false when there is nothing to unconstrain against, so the
 * caller can fall back to an empty configure. */
static bool popup_unconstrain(struct tinywl_popup *popup) {
	struct tinywl_server *server = popup->server;
	/* The root's layout-absolute position, from the retained scene graph.
	 * False when the root is gone or currently disabled, i.e. not shown. */
	int lx, ly, rw, rh;
	if (!root_geometry(server, popup->root_handle, &lx, &ly, &rw, &rh)) {
		return false;
	}
	/* The output the root sits on; a NULL output (off every output) makes
	 * get_box return the whole-layout extents, a safe fallback. */
	struct wlr_output *output = wlr_output_layout_output_at(
		server->output_layout, lx + rw / 2.0, ly + rh / 2.0);
	struct wlr_box box;
	wlr_output_layout_get_box(server->output_layout, output, &box);
	box.x -= lx;
	box.y -= ly;
	wlr_log(WLR_DEBUG, "popup unconstrain: root %llu box %d,%d %dx%d",
		(unsigned long long)popup->root_handle,
		box.x, box.y, box.width, box.height);
	wlr_xdg_popup_unconstrain_from_box(popup->xdg_popup, &box);
	return true;
}

/* A borrowed client tree was placed or moved (a first placement or a
 * re-tile): re-unconstrain every popup rooted on it, so an open popup
 * repositions. One frame of staleness, then corrected. C to C,
 * no Lua in the path. X11 windows additionally carry root coordinates, so
 * the new scene position is re-sent (the reconciler's configure ran before
 * the position existed on a first placement, and does not run at all on a
 * pure move). */
static void client_reposition(void *data, uint64_t handle) {
	struct tinywl_server *server = data;
	struct tinywl_popup *popup;
	wl_list_for_each(popup, &server->popups, link) {
		if (popup->root_handle == handle) {
			popup_unconstrain(popup);
		}
	}
#ifdef KILN_XWAYLAND
	/* The size re-sent is the surface's own: wlroots caches X11 geometry
	 * optimistically at configure time, so after any configure of ours
	 * xwl_surface->width/height IS the last size we sent, and before one it
	 * is the client's own initial geometry, the only size there is.
	 * scripts/xwl-reposition-test.sh asserts exactly this. */
	struct tinywl_toplevel *toplevel = toplevel_by_handle(server, handle);
	if (toplevel_xwl(toplevel) != NULL) {
		xwl_send_configure(toplevel, toplevel->xwl_surface->width,
			toplevel->xwl_surface->height);
	}
#endif
}

/* Does this client currently present a live xdg-popup? The reconciler folds
 * such a client to the top of the draw order so its popup is not occluded by a
 * neighbor tile it overhangs. */
static bool client_has_popup(void *data, uint64_t handle) {
	struct tinywl_server *server = data;
	struct tinywl_popup *popup;
	wl_list_for_each(popup, &server->popups, link) {
		if (popup->root_handle == handle) {
			return true;
		}
	}
	return false;
}

/* A popup opened or closed: the owner's fold-to-top state changed, but a popup
 * map/unmap is a scene repaint, not a Clay solve. Mark the owner's output dirty
 * so the reconciler runs and applies (or drops) the raise. */
static void popup_mark_owner_dirty(struct tinywl_popup *popup) {
	int lx, ly, rw, rh;
	if (!root_geometry(popup->server, popup->root_handle,
			&lx, &ly, &rw, &rh)) {
		return;
	}
	struct wlr_output *output = wlr_output_layout_output_at(
		popup->server->output_layout, lx + rw / 2.0, ly + rh / 2.0);
	if (output != NULL) {
		ui_mark_dirty_name(popup->server->ui, output->name);
	}
}

static void xdg_popup_commit(struct wl_listener *listener, void *data) {
	/* Called when a new surface state is committed. */
	struct tinywl_popup *popup = wl_container_of(listener, popup, commit);

	if (popup->xdg_popup->base->initial_commit) {
		/* The initial commit must be answered with a configure. Unconstrain
		 * from retained state (which schedules the configure); if there is no
		 * root to unconstrain against, fall back to an empty configure. */
		if (!popup_unconstrain(popup)) {
			wlr_xdg_surface_schedule_configure(popup->xdg_popup->base);
		}
	}
}

static void xdg_popup_destroy(struct wl_listener *listener, void *data) {
	/* Called when the xdg_popup is destroyed. */
	struct tinywl_popup *popup = wl_container_of(listener, popup, destroy);

	/* Drop the owner's fold-to-top: the scheduled solve runs after this popup
	 * leaves the list, so has_popup then reports false and the owner lowers. */
	popup_mark_owner_dirty(popup);
	wl_list_remove(&popup->link);
	wl_list_remove(&popup->commit.link);
	wl_list_remove(&popup->destroy.link);

	free(popup);
}

static void popup_register(struct tinywl_server *server,
		struct wlr_xdg_popup *xdg_popup) {
	struct tinywl_popup *popup = calloc(1, sizeof(*popup));
	popup->xdg_popup = xdg_popup;
	popup->server = server;
	popup->root_handle = popup_root_handle(server, xdg_popup);
	wl_list_insert(&server->popups, &popup->link);
	/* Fold the owner to the top now that it has a popup (see the hook). */
	popup_mark_owner_dirty(popup);

	/* We must add xdg popups to the scene graph so they get rendered. The
	 * wlroots scene graph provides a helper for this, but to use it we must
	 * provide the proper parent scene node of the xdg popup. The data field
	 * of every surface we own (xdg_surface and layer_surface alike) holds its
	 * scene tree; a popup can root on either (a menu on a toplevel, a tooltip
	 * on a bar). */
	struct wlr_scene_tree *parent_tree = NULL;
	struct wlr_xdg_surface *parent =
		wlr_xdg_surface_try_from_wlr_surface(xdg_popup->parent);
	if (parent != NULL) {
		parent_tree = parent->data;
	} else {
		struct wlr_layer_surface_v1 *ls =
			wlr_layer_surface_v1_try_from_wlr_surface(xdg_popup->parent);
		if (ls != NULL) {
			parent_tree = ls->data;
		}
	}
	if (parent_tree != NULL) {
		xdg_popup->base->data =
			wlr_scene_xdg_surface_create(parent_tree, xdg_popup->base);
	} else {
		/* A parent we do not track: the popup gets no scene node and stays
		 * invisible; the empty-configure fallback still answers its commit. */
		wlr_log(WLR_ERROR, "xdg-popup on untracked parent surface");
	}

	popup->commit.notify = xdg_popup_commit;
	wl_signal_add(&xdg_popup->base->surface->events.commit, &popup->commit);

	popup->destroy.notify = xdg_popup_destroy;
	wl_signal_add(&xdg_popup->events.destroy, &popup->destroy);
}

static void server_new_xdg_popup(struct wl_listener *listener, void *data) {
	/* This event is raised when a client creates a new popup. */
	struct tinywl_server *server =
		wl_container_of(listener, server, new_xdg_popup);
	struct wlr_xdg_popup *xdg_popup = data;

	/* A popup may be created parentless: a layer-shell client parents it
	 * afterwards via zwlr_layer_surface_v1.get_popup, which raises that
	 * layer surface's new_popup, where it is registered instead. A popup
	 * never parented cannot legally commit (protocol error), so skipping
	 * here strands nothing. */
	if (xdg_popup->parent == NULL) {
		return;
	}
	popup_register(server, xdg_popup);
}

/* --- layer-shell: surfaces as place-leaves, arranged by nobody here ---
 *
 * A layer surface is the same place-leaf life as a toplevel: registered with
 * a handle, borrowed by the renderer for whatever box Lua declared, released
 * home when undeclared. C converts protocol state to facts and sends the one
 * configure Lua asks for; which band it lands in, where it sits, and what
 * size answers its ask are all Lua. */

static const char *layer_protocol_name(enum zwlr_layer_shell_v1_layer layer) {
	switch (layer) {
	case ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND: return "background";
	case ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM: return "bottom";
	case ZWLR_LAYER_SHELL_V1_LAYER_TOP: return "top";
	case ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY: return "overlay";
	}
	return "top";
}

static const char *layer_interactivity_name(
		enum zwlr_layer_surface_v1_keyboard_interactivity ki) {
	switch (ki) {
	case ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE:
		return "none";
	case ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE:
		return "exclusive";
	case ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_ON_DEMAND:
		return "on_demand";
	}
	return "none";
}

static void layer_facts(struct tinywl_layer *layer,
		struct queue_layer_facts *facts) {
	struct wlr_layer_surface_v1 *ls = layer->layer_surface;
	struct wlr_layer_surface_v1_state *st = &ls->current;
	*facts = (struct queue_layer_facts){
		.handle = layer->handle,
		.namespace_ = ls->namespace,
		/* NULL when the client left the output choice to the compositor;
		 * the choice is Lua's, made by declaring on a screen. */
		.output = ls->output != NULL ? ls->output->name : NULL,
		.layer_name = layer_protocol_name(st->layer),
		.interactivity =
			layer_interactivity_name(st->keyboard_interactive),
		.anchor_top = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP,
		.anchor_bottom = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM,
		.anchor_left = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT,
		.anchor_right = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
		.exclusive = st->exclusive_zone,
		.margin_top = st->margin.top,
		.margin_right = st->margin.right,
		.margin_bottom = st->margin.bottom,
		.margin_left = st->margin.left,
		.width = st->desired_width,
		.height = st->desired_height,
	};
}

/* No fallback configure exists, so a surface whose layer::map went
 * unanswered stays visibly absent; this logs the exact surface and event
 * after a few seconds and decides nothing. */
static int layer_watchdog_fire(void *data) {
	struct tinywl_layer *layer = data;
	if (!layer->configured) {
		wlr_log(WLR_ERROR, "layer-shell watchdog: surface '%s' "
			"(handle %llu): layer::map dispatched, no layer_configure "
			"answered",
			layer->layer_surface->namespace,
			(unsigned long long)layer->handle);
	}
	return 0;
}

#define LAYER_WATCHDOG_MS 3000

static void layer_surface_commit(struct wl_listener *listener, void *data) {
	struct tinywl_layer *layer = wl_container_of(listener, layer, commit);
	struct wlr_layer_surface_v1 *ls = layer->layer_surface;
	if (layer->server->queue == NULL) {
		return;
	}
	struct queue_layer_facts facts;
	if (ls->initial_commit) {
		/* The configure handshake starts here: the client blocks until Lua
		 * answers the layer::map facts with layer_configure. Unlike an xdg
		 * toplevel's initial commit, C sends nothing. */
		layer->configured = false;
		layer_facts(layer, &facts);
		queue_layer_map(layer->server->queue, &facts);
		wl_event_source_timer_update(layer->watchdog, LAYER_WATCHDOG_MS);
		return;
	}
	if (ls->current.committed != 0) {
		/* A later commit changed the surface's declared state (anchors,
		 * size, exclusive px, interactivity, layer): fresh facts, same
		 * answer path. Buffer-only commits pass silently. */
		layer_facts(layer, &facts);
		queue_layer_commit(layer->server->queue, &facts);
	}
}

static void layer_surface_unmap(struct wl_listener *listener, void *data) {
	struct tinywl_layer *layer = wl_container_of(listener, layer, unmap);
	/* The protocol re-runs the configure sequence on remap, so the next
	 * cycle's layer::map must be answered anew. */
	layer->configured = false;
	wl_event_source_timer_update(layer->watchdog, 0);
	if (layer->server->queue != NULL) {
		queue_layer_unmap(layer->server->queue, layer->handle);
	}
}

/* A popup parented on this layer surface after a parentless creation (the
 * zwlr get_popup flow): register it now that popup_root_handle can resolve
 * its root. */
static void layer_surface_new_popup(struct wl_listener *listener, void *data) {
	struct tinywl_layer *layer = wl_container_of(listener, layer, new_popup);
	popup_register(layer->server, data);
}

static void layer_surface_destroy(struct wl_listener *listener, void *data) {
	struct tinywl_layer *layer = wl_container_of(listener, layer, destroy);
	if (layer->server->queue != NULL) {
		queue_layer_destroy(layer->server->queue, layer->handle);
	}
	wl_event_source_remove(layer->watchdog);
	wl_list_remove(&layer->commit.link);
	wl_list_remove(&layer->unmap.link);
	wl_list_remove(&layer->destroy.link);
	wl_list_remove(&layer->new_popup.link);
	wl_list_remove(&layer->link);
	free(layer);
}

static void server_new_layer_surface(struct wl_listener *listener,
		void *data) {
	struct tinywl_server *server =
		wl_container_of(listener, server, new_layer_surface);
	struct wlr_layer_surface_v1 *ls = data;

	struct tinywl_layer *layer = calloc(1, sizeof(*layer));
	layer->server = server;
	layer->layer_surface = ls;
	layer->handle = ++server->next_handle;
	/* Home under clients_tree, disabled, until a declare borrows it: the
	 * same place-leaf life as a toplevel. node.data stays NULL, so the
	 * pointer paths forward input to the surface without treating it as a
	 * client. ls->data carries the tree for popup rooting, the same slot
	 * xdg surfaces use. */
	layer->scene_tree = wlr_scene_subsurface_tree_create(
		server->clients_tree, ls->surface);
	wlr_scene_node_set_enabled(&layer->scene_tree->node, false);
	ls->data = layer->scene_tree;
	layer->watchdog = wl_event_loop_add_timer(
		wl_display_get_event_loop(server->wl_display),
		layer_watchdog_fire, layer);
	wl_list_insert(&server->layers, &layer->link);

	layer->commit.notify = layer_surface_commit;
	wl_signal_add(&ls->surface->events.commit, &layer->commit);
	layer->unmap.notify = layer_surface_unmap;
	wl_signal_add(&ls->surface->events.unmap, &layer->unmap);
	layer->destroy.notify = layer_surface_destroy;
	wl_signal_add(&ls->events.destroy, &layer->destroy);
	layer->new_popup.notify = layer_surface_new_popup;
	wl_signal_add(&ls->events.new_popup, &layer->new_popup);
}

/* core.layer_configure(handle, w, h): the answer to layer::map/commit and
 * the only configure path a layer surface has. Disarms the watchdog. */
static void layer_op_configure(void *data, uint64_t handle,
		int width, int height) {
	struct tinywl_layer *layer = layer_by_handle(data, handle);
	if (layer == NULL || !layer->layer_surface->initialized) {
		return;
	}
	layer->configured = true;
	wl_event_source_timer_update(layer->watchdog, 0);
	wlr_layer_surface_v1_configure(layer->layer_surface, width, height);
}

/* Which config to run, in precedence order: an explicit KILN_RC, the user's
 * config under XDG, the packaged default under the install datadir, and finally
 * kilnrc.lua for running from an uninstalled source tree, where the config
 * carries its source name rather than its installed one. Returns a malloc'd
 * path the caller frees after core_create. */
static char *resolve_rc_path(void) {
	const char *env = getenv("KILN_RC");
	if (env != NULL && *env != '\0') {
		return strdup(env);
	}

	char path[PATH_MAX];
	const char *xdg = getenv("XDG_CONFIG_HOME");
	const char *home = getenv("HOME");
	if (xdg != NULL && *xdg != '\0') {
		snprintf(path, sizeof(path), "%s/kiln/rc.lua", xdg);
		if (access(path, R_OK) == 0) return strdup(path);
	} else if (home != NULL && *home != '\0') {
		snprintf(path, sizeof(path), "%s/.config/kiln/rc.lua", home);
		if (access(path, R_OK) == 0) return strdup(path);
	}

#ifdef KILN_DATADIR
	snprintf(path, sizeof(path), "%s/rc.lua", KILN_DATADIR);
	if (access(path, R_OK) == 0) return strdup(path);
#endif

	return strdup("kilnrc.lua");
}

int main(int argc, char *argv[]) {
	wlr_log_init(WLR_DEBUG, NULL);
	char *startup_cmd = NULL;

	int c;
	while ((c = getopt(argc, argv, "s:h")) != -1) {
		switch (c) {
		case 's':
			startup_cmd = optarg;
			break;
		default:
			printf("Usage: %s [-s startup command]\n", argv[0]);
			return 0;
		}
	}
	if (optind < argc) {
		printf("Usage: %s [-s startup command]\n", argv[0]);
		return 0;
	}

	struct tinywl_server server = {0};
	/* The Wayland display is managed by libwayland. It handles accepting
	 * clients from the Unix socket, manging Wayland globals, and so on. */
	server.wl_display = wl_display_create();
	/* The backend is a wlroots feature which abstracts the underlying input and
	 * output hardware. The autocreate option will choose the most suitable
	 * backend based on the current environment, such as opening an X11 window
	 * if an X11 server is running. */
	/* The session handle is what VT switching needs; it is NULL on backends
	 * that have no VTs (headless, nested wayland), where the chord no-ops. */
	server.backend = wlr_backend_autocreate(
		wl_display_get_event_loop(server.wl_display), &server.session);
	if (server.backend == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlr_backend");
		return 1;
	}

	/* Autocreates a renderer, either Pixman, GLES2 or Vulkan for us. The user
	 * can also specify a renderer using the WLR_RENDERER env var.
	 * The renderer is responsible for defining the various pixel formats it
	 * supports for shared memory, this configures that for clients. */
	server.renderer = wlr_renderer_autocreate(server.backend);
	if (server.renderer == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlr_renderer");
		return 1;
	}

	wlr_renderer_init_wl_display(server.renderer, server.wl_display);

	/* Autocreates an allocator for us.
	 * The allocator is the bridge between the renderer and the backend. It
	 * handles the buffer creation, allowing wlroots to render onto the
	 * screen */
	server.allocator = wlr_allocator_autocreate(server.backend,
		server.renderer);
	if (server.allocator == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlr_allocator");
		return 1;
	}

	/* This creates some hands-off wlroots interfaces. The compositor is
	 * necessary for clients to allocate surfaces, the subcompositor allows to
	 * assign the role of subsurfaces to surfaces and the data device manager
	 * handles the clipboard. Each of these wlroots interfaces has room for you
	 * to dig your fingers in and play with their behavior if you want. Note that
	 * the clients cannot set the selection directly without compositor approval,
	 * see the handling of the request_set_selection event below.*/
	struct wlr_compositor *compositor =
		wlr_compositor_create(server.wl_display, 5, server.renderer);
	wlr_subcompositor_create(server.wl_display);
	wlr_data_device_manager_create(server.wl_display);
	/* Primary selection: the manager global that lets clients
	 * offer and read the middle-click clipboard. The seat listener that honors
	 * a set request is wired next to the regular clipboard's, below. */
	server.primary_selection_mgr =
		wlr_primary_selection_v1_device_manager_create(server.wl_display);

	/* Screencopy: the portal path OBS rides. A hands-off wlroots
	 * global that reads the composed scene straight from the output on a
	 * client's request; zero listeners, zero verbs, zero node interaction. */
	server.screencopy_mgr = wlr_screencopy_manager_v1_create(server.wl_display);

	/* HiDPI client half: tell clients the scale of the output they are on.
	 * wlr_scene already computes each surface's preferred scale from its primary
	 * output and calls wlr_fractional_scale_v1_notify_scale + set_preferred_buffer_scale
	 * (types/scene/surface.c); without these two globals that notify has nothing to
	 * send to and no way for a client to submit a fractionally-scaled buffer, so a
	 * native client on a 1.5x output renders at the wrong density and its input
	 * region drifts from the cursor. viewporter lets the client map its scaled
	 * buffer to the logical box; fractional-scale carries the exact 1.5. Both are
	 * plain wlroots globals: zero listeners, zero Lua, zero policy. */
	wlr_viewporter_create(server.wl_display);
	wlr_fractional_scale_manager_v1_create(server.wl_display, 1);

	/* Creates an output layout, which a wlroots utility for working with an
	 * arrangement of screens in a physical layout. */
	server.output_layout = wlr_output_layout_create(server.wl_display);
	/* xdg-output: logical output names and geometry, mirrored entirely by
	 * wlroots from the layout. Shell clients hard-require it (wofi
	 * dereferences it unchecked, waybar reads output names from it); no
	 * listener, no Lua, nothing to decide. */
	wlr_xdg_output_manager_v1_create(server.wl_display,
		server.output_layout);

	/* Configure a listener to be notified when new outputs are available on the
	 * backend. */
	wl_list_init(&server.outputs);
	server.new_output.notify = server_new_output;
	wl_signal_add(&server.backend->events.new_output, &server.new_output);

	/* Create a scene graph. This is a wlroots abstraction that handles all
	 * rendering and damage tracking. All the compositor author needs to do
	 * is add things that should be rendered to the scene graph at the proper
	 * positions and then call wlr_scene_output_commit() to render a frame if
	 * necessary.
	 */
	server.scene = wlr_scene_create();
	server.scene_layout = wlr_scene_attach_output_layout(server.scene, server.output_layout);

	/* Gamma control: wlsunset and friends set a per-output gamma
	 * LUT. The scene owns the whole mechanism, so kiln keeps no listener of its
	 * own: wlr_scene_set_gamma_control_manager_v1 registers the set_gamma
	 * listener, folds the LUT into the color transform it already applies in
	 * wlr_scene_output_commit, and re-arms it whenever an output re-enables
	 * (types/scene/wlr_scene.c), which is the reapply-on-hotplug this
	 * needs. */
	server.gamma_control_mgr =
		wlr_gamma_control_manager_v1_create(server.wl_display);
	wlr_scene_set_gamma_control_manager_v1(server.scene,
		server.gamma_control_mgr);

	/* Clients render below the UI: the clients tree is created first, the
	 * UI tree second, and sibling order is stacking order. */
	server.clients_tree = wlr_scene_tree_create(&server.scene->tree);
	server.ui = ui_create(server.wl_display, &server.scene->tree,
		server.output_layout);
	/* The drag icon band: a scene tree above all clients and UI
	 * chrome and below the lock band, created here so sibling order (clients,
	 * ui, drag_band, lock_tree) places it exactly there; empty until
	 * a drag parents an icon into it. */
	server.drag_band = wlr_scene_tree_create(&server.scene->tree);
	/* The lock band: a scene tree created last, so it is the topmost sibling
	 * unconditionally, above every client and all UI chrome. The opaque floor
	 * is its first (bottom) child, kept disabled until a lock engages; lock
	 * surfaces and the native lockscreen render above it. */
	server.lock_owner = LOCK_NONE;
	server.lock_tree = wlr_scene_tree_create(&server.scene->tree);
	const float lock_floor_color[4] = { 0.0f, 0.0f, 0.0f, 1.0f };
	server.lock_floor = wlr_scene_rect_create(server.lock_tree, 0, 0,
		lock_floor_color);
	/* The band stays hidden until a lock engages: it is topmost, so anything
	 * left in it (the floor, a retained lockscreen frame) would paint over the
	 * desktop. Hiding the band is the only switch; the floor rides it. */
	wlr_scene_node_set_enabled(&server.lock_tree->node, false);
	ui_set_lock_tree(server.ui, server.lock_tree);
	char *rc_path = resolve_rc_path();
	server.core = core_create(server.wl_display, server.ui, rc_path);
	free(rc_path);
	ui_set_core(server.ui, server.core);
	server.queue = queue_create(server.core,
		wl_display_get_event_loop(server.wl_display));
	core_set_queue(server.core, server.queue);

	/* Mechanism callbacks: client verbs for Lua, scene-tree hooks for
	 * the renderer. Both copied by value. */
	struct core_client_ops client_ops = {
		.focus = client_op_focus,
		.configure = client_configure,
		.close_client = client_op_close,
		.kill_client = client_op_kill,
		.set_activated = client_op_set_activated,
		.set_fullscreen_hint = client_op_set_fullscreen_hint,
		.set_maximized_hint = client_op_set_maximized_hint,
		.set_tiled_hint = client_op_set_tiled_hint,
		.set_suspended = client_op_set_suspended,
		.set_minimized_hint = client_op_set_minimized_hint,
		.set_output_mirror = client_op_set_output_mirror,
		.replay = client_op_replay,
		.data = &server,
	};
	core_set_client_ops(server.core, &client_ops);
	struct core_input_ops input_ops = {
		.grab_pointer = input_op_grab_pointer,
		.grab_keyboard = input_op_grab_keyboard,
		.set_cursor = input_op_set_cursor,
		.set_keymap = input_op_set_keymap,
		.set_repeat = input_op_set_repeat,
		.set_numlock = input_op_set_numlock,
		.set_pointer = input_op_set_pointer,
		.set_cursor_theme = input_op_set_cursor_theme,
		.set_idle_timeout = input_op_set_idle_timeout,
		.data = &server,
	};
	core_set_input_ops(server.core, &input_ops);
	struct core_output_ops output_ops = {
		.list = output_op_list,
		.set_mode = output_op_set_mode,
		.set_scale = output_op_set_scale,
		.set_position = output_op_set_position,
		.set_enabled = output_op_set_enabled,
		.set_adaptive_sync = output_op_set_adaptive_sync,
		.tick = output_op_set_tick,
		.screenshot = screenshot_op,
		.data = &server,
	};
	core_set_output_ops(server.core, &output_ops);
	struct core_activation_ops activation_ops = {
		.mint_token = activation_op_mint_token,
		.data = &server,
	};
	core_set_activation_ops(server.core, &activation_ops);
	struct core_layer_ops layer_ops = {
		.configure = layer_op_configure,
		.data = &server,
	};
	core_set_layer_ops(server.core, &layer_ops);
	struct core_lock_ops lock_ops = {
		.lock = lock_op_lock,
		.unlock = lock_op_unlock,
		.authenticate = lock_op_authenticate,
		.data = &server,
	};
	core_set_lock_ops(server.core, &lock_ops);

	/* The DBus services. The connection is shared; each service owns its own
	 * name and sets its own verb ops. */
	server.dbus = kiln_dbus_create(
		wl_display_get_event_loop(server.wl_display));
	server.notify = kiln_notify_create(server.dbus, server.core,
		server.queue, server.ui);
	server.tray = kiln_tray_create(server.dbus, server.core,
		server.queue, server.ui);

	struct render_client_hooks client_hooks = {
		.resolve = client_resolve,
		.configure = client_configure,
		.borrow = client_borrow,
		.release = client_release,
		.reposition = client_reposition,
		.has_popup = client_has_popup,
		.data = &server,
	};
	ui_set_client_hooks(server.ui, &client_hooks);

	/* Set up xdg-shell version 3. The xdg-shell is a Wayland protocol which is
	 * used for application windows. For more detail on shells, refer to
	 * https://drewdevault.com/2018/07/29/Wayland-shells.html.
	 */
	wl_list_init(&server.toplevels);
	wl_list_init(&server.popups);
	server.xdg_shell = wlr_xdg_shell_create(server.wl_display, 3);
	server.new_xdg_toplevel.notify = server_new_xdg_toplevel;
	wl_signal_add(&server.xdg_shell->events.new_toplevel, &server.new_xdg_toplevel);
	server.new_xdg_popup.notify = server_new_xdg_popup;
	wl_signal_add(&server.xdg_shell->events.new_popup, &server.new_xdg_popup);

	/* wlr-layer-shell v4: each surface becomes layer::* facts and a
	 * place-leaf handle; arrangement, bands, and the configure answer are
	 * Lua's. */
	wl_list_init(&server.layers);
	server.layer_shell = wlr_layer_shell_v1_create(server.wl_display, 4);
	server.new_layer_surface.notify = server_new_layer_surface;
	wl_signal_add(&server.layer_shell->events.new_surface,
		&server.new_layer_surface);

	/* Server-side decoration is forced: the compositor draws all
	 * chrome, so clients never draw their own. The xdg-decoration manager
	 * answers each toplevel with SERVER_SIDE and emits request::decoration_mode;
	 * the legacy KDE manager defaults to SERVER for clients that use it. */
	server.xdg_decoration_mgr =
		wlr_xdg_decoration_manager_v1_create(server.wl_display);
	server.new_xdg_decoration.notify = server_new_xdg_decoration;
	wl_signal_add(&server.xdg_decoration_mgr->events.new_toplevel_decoration,
		&server.new_xdg_decoration);
	wlr_server_decoration_manager_set_default_mode(
		wlr_server_decoration_manager_create(server.wl_display),
		WLR_SERVER_DECORATION_MANAGER_MODE_SERVER);

	/* xdg-activation: request_activate becomes a fact for Lua focus policy;
	 * the manager also mints spawn_with_token tokens (activation ops below). */
	server.xdg_activation = wlr_xdg_activation_v1_create(server.wl_display);
	server.request_activate.notify = server_request_activate;
	wl_signal_add(&server.xdg_activation->events.request_activate,
		&server.request_activate);

	/* foreign-toplevel: created and advertised. No manager-level listener (the
	 * manager emits only destroy, torn down with the display); the per-client
	 * handles are minted at map. */
	server.foreign_toplevel_mgr =
		wlr_foreign_toplevel_manager_v1_create(server.wl_display);

#ifdef KILN_XWAYLAND
	/* XWayland, lazy: the X server spawns on the first X client. DISPLAY is
	 * set now (display_name is reserved at create), the seat and the WM-side
	 * XCB connection at ready. X surfaces enter the same toplevels list, the
	 * same handle space, and the same client::* events. */
	server.xwayland = wlr_xwayland_create(server.wl_display, compositor, true);
	if (server.xwayland != NULL) {
		server.xwayland_ready.notify = server_xwayland_ready;
		wl_signal_add(&server.xwayland->events.ready, &server.xwayland_ready);
		server.new_xwayland_surface.notify = server_new_xwayland_surface;
		wl_signal_add(&server.xwayland->events.new_surface,
			&server.new_xwayland_surface);
		setenv("DISPLAY", server.xwayland->display_name, true);
	} else {
		wlr_log(WLR_ERROR, "wlr_xwayland_create failed; running without X11");
	}
#else
	(void)compositor;
#endif

	/* Session lock: the manager hands us a lock object per engage. Everything
	 * the protocol requires (fullscreen per output, above all, exclusive input,
	 * blank on locker death) is C mechanism; Lua only hears lock/unlock (1.2). */
	server.session_lock_mgr =
		wlr_session_lock_manager_v1_create(server.wl_display);
	server.new_lock.notify = handle_new_lock;
	wl_signal_add(&server.session_lock_mgr->events.new_lock, &server.new_lock);

	/* Idle: notifier feeds external idle daemons; inhibit manager lets a client
	 * hold idle off while its surface is mapped (recomputed on add/remove). */
	server.idle_notifier = wlr_idle_notifier_v1_create(server.wl_display);
	wl_list_init(&server.idle_inhibitors);
	server.idle_inhibit_mgr = wlr_idle_inhibit_v1_create(server.wl_display);
	server.new_idle_inhibitor.notify = handle_new_idle_inhibitor;
	wl_signal_add(&server.idle_inhibit_mgr->events.new_inhibitor,
		&server.new_idle_inhibitor);
	/* The auto-lock timer: the layer-watchdog pattern, a loop
	 * timer created disarmed. core.set_idle_timeout arms it; input re-arms it;
	 * handle_idle_timeout emits idle::start when it elapses. */
	server.idle_timer = wl_event_loop_add_timer(
		wl_display_get_event_loop(server.wl_display),
		handle_idle_timeout, &server);

	/*
	 * Creates a cursor, which is a wlroots utility for tracking the cursor
	 * image shown on screen.
	 */
	server.cursor = wlr_cursor_create();
	wlr_cursor_attach_output_layout(server.cursor, server.output_layout);

	/* Creates an xcursor manager, another wlroots utility which loads up
	 * Xcursor themes to source cursor images from and makes sure that cursor
	 * images are available at all scale factors on the screen (necessary for
	 * HiDPI support). */
	server.cursor_mgr = wlr_xcursor_manager_create(NULL, 24);

	/*
	 * wlr_cursor *only* displays an image on screen. It does not move around
	 * when the pointer moves. However, we can attach input devices to it, and
	 * it will generate aggregate events for all of them. In these events, we
	 * can choose how we want to process them, forwarding them to clients and
	 * moving the cursor around. More detail on this process is described in
	 * https://drewdevault.com/2018/07/17/Input-handling-in-wlroots.html.
	 *
	 * And more comments are sprinkled throughout the notify functions above.
	 */
	server.cursor_motion.notify = server_cursor_motion;
	wl_signal_add(&server.cursor->events.motion, &server.cursor_motion);
	server.cursor_motion_absolute.notify = server_cursor_motion_absolute;
	wl_signal_add(&server.cursor->events.motion_absolute,
			&server.cursor_motion_absolute);
	server.cursor_button.notify = server_cursor_button;
	wl_signal_add(&server.cursor->events.button, &server.cursor_button);
	server.cursor_axis.notify = server_cursor_axis;
	wl_signal_add(&server.cursor->events.axis, &server.cursor_axis);
	server.cursor_frame.notify = server_cursor_frame;
	wl_signal_add(&server.cursor->events.frame, &server.cursor_frame);

	/*
	 * Configures a seat, which is a single "seat" at which a user sits and
	 * operates the computer. This conceptually includes up to one keyboard,
	 * pointer, touch, and drawing tablet device. We also rig up a listener to
	 * let us know when new input devices are available on the backend.
	 */
	wl_list_init(&server.keyboards);
	wl_list_init(&server.pointers);
	server.new_input.notify = server_new_input;
	wl_signal_add(&server.backend->events.new_input, &server.new_input);
	server.seat = wlr_seat_create(server.wl_display, "seat0");
	server.request_cursor.notify = seat_request_cursor;
	wl_signal_add(&server.seat->events.request_set_cursor,
			&server.request_cursor);
	server.request_set_selection.notify = seat_request_set_selection;
	wl_signal_add(&server.seat->events.request_set_selection,
			&server.request_set_selection);
	/* Primary selection rides the same seat, one listener mirroring the
	 * clipboard's. */
	server.request_set_primary_selection.notify =
		seat_request_set_primary_selection;
	wl_signal_add(&server.seat->events.request_set_primary_selection,
			&server.request_set_primary_selection);
	/* DnD: validate the start serial and adopt the drag icon into the cursor
	 * band. drag_destroy is per-drag (added in start_drag). */
	server.request_start_drag.notify = seat_request_start_drag;
	wl_signal_add(&server.seat->events.request_start_drag,
			&server.request_start_drag);
	server.start_drag.notify = seat_start_drag;
	wl_signal_add(&server.seat->events.start_drag, &server.start_drag);

	/* pointer-constraints + relative-pointer: the
	 * only mechanism a client has to lock or confine the cursor, and the one
	 * XWayland translates an X11 pointer grab into, so without these globals a
	 * game's grab lands on nothing. Advertised here; activated by pointer focus
	 * and nothing else (pointer_constraint_sync above). */
	server.pointer_constraints =
		wlr_pointer_constraints_v1_create(server.wl_display);
	server.new_pointer_constraint.notify = server_new_pointer_constraint;
	wl_signal_add(&server.pointer_constraints->events.new_constraint,
			&server.new_pointer_constraint);
	server.relative_pointer_mgr =
		wlr_relative_pointer_manager_v1_create(server.wl_display);

	/* cursor-shape-v1: a client names a shape rather than shipping a buffer.
	 * The name feeds the same xcursor manager set_cursor uses, which loads a
	 * theme per output scale, so a named shape is sharp on a fractional output
	 * with no cache of kiln's own. */
	server.cursor_shape_mgr =
		wlr_cursor_shape_manager_v1_create(server.wl_display, 1);
	server.request_set_shape.notify = seat_request_set_shape;
	wl_signal_add(&server.cursor_shape_mgr->events.request_set_shape,
			&server.request_set_shape);

	/* Add a Unix socket to the Wayland display. */
	const char *socket = wl_display_add_socket_auto(server.wl_display);
	if (!socket) {
		wlr_backend_destroy(server.backend);
		return 1;
	}

	/* Start the backend. This will enumerate outputs and inputs, become the DRM
	 * master, etc */
	if (!wlr_backend_start(server.backend)) {
		wlr_backend_destroy(server.backend);
		wl_display_destroy(server.wl_display);
		return 1;
	}

	/* Set the WAYLAND_DISPLAY environment variable to our socket and run the
	 * startup command if requested. */
	setenv("WAYLAND_DISPLAY", socket, true);
	if (startup_cmd) {
		spawn(startup_cmd);
	}
	/* Run the Wayland event loop. This does not return until you exit the
	 * compositor. Starting the backend rigged up all of the necessary event
	 * loop configuration to listen to libinput events, DRM events, generate
	 * frame events at the refresh rate, and so on. */
	wlr_log(WLR_INFO, "Running Wayland compositor on WAYLAND_DISPLAY=%s",
			socket);
	wl_display_run(server.wl_display);


	/* Once wl_display_run returns, we destroy all clients then shut down the
	 * server. */
	wl_display_destroy_clients(server.wl_display);

#ifdef KILN_XWAYLAND
	/* Before the display goes: destroying the server tears down remaining X
	 * surfaces through their normal destroy handlers while the queue still
	 * exists. The manager listeners must detach first (wlroots asserts empty
	 * lists at destroy, same as the managers below). */
	if (server.xwayland != NULL) {
		wl_list_remove(&server.xwayland_ready.link);
		wl_list_remove(&server.new_xwayland_surface.link);
		wlr_xwayland_destroy(server.xwayland);
	}
	if (server.xcb_conn != NULL) {
		xcb_disconnect(server.xcb_conn);
	}
#endif

	wl_list_remove(&server.new_xdg_toplevel.link);
	wl_list_remove(&server.new_xdg_popup.link);
	wl_list_remove(&server.new_layer_surface.link);
	/* wlroots asserts these manager listener lists are empty at
	 * wl_display_destroy; leaving either attached is an abort on quit. */
	wl_list_remove(&server.new_xdg_decoration.link);
	wl_list_remove(&server.request_activate.link);
	wl_list_remove(&server.new_lock.link);
	wl_list_remove(&server.new_idle_inhibitor.link);
	wl_list_remove(&server.new_pointer_constraint.link);
	wl_list_remove(&server.request_set_shape.link);
	/* The auto-lock timer is loop-owned; remove it before the loop dies (the
	 * layer watchdog's teardown, per-source). */
	wl_event_source_remove(server.idle_timer);
	/* wl_display_destroy_clients above tore down any live lock and inhibitor
	 * surfaces, firing their destroy handlers (which detach per-object
	 * listeners and free the inhibitor wrappers), so nothing lock-related
	 * remains attached here. */

	wl_list_remove(&server.cursor_motion.link);
	wl_list_remove(&server.cursor_motion_absolute.link);
	wl_list_remove(&server.cursor_button.link);
	wl_list_remove(&server.cursor_axis.link);
	wl_list_remove(&server.cursor_frame.link);

	wl_list_remove(&server.new_input.link);
	wl_list_remove(&server.request_cursor.link);
	wl_list_remove(&server.request_set_selection.link);
	wl_list_remove(&server.request_set_primary_selection.link);
	/* The two seat-lifetime drag listeners; drag_destroy is not here (it lives
	 * only while a drag is in flight, removed when that drag ends). */
	wl_list_remove(&server.request_start_drag.link);
	wl_list_remove(&server.start_drag.link);

	wl_list_remove(&server.new_output.link);

	kiln_tray_destroy(server.tray);
	kiln_notify_destroy(server.notify);
	kiln_dbus_destroy(server.dbus);
	queue_destroy(server.queue);
	server.queue = NULL;
	core_destroy(server.core);
	ui_destroy(server.ui);
	server.ui = NULL;
	wlr_scene_node_destroy(&server.scene->tree.node);
	wlr_xcursor_manager_destroy(server.cursor_mgr);
	wlr_cursor_destroy(server.cursor);
	wlr_allocator_destroy(server.allocator);
	wlr_renderer_destroy(server.renderer);
	wlr_backend_destroy(server.backend);
	wl_display_destroy(server.wl_display);
	return 0;
}
