/* wl-toplevel: the smallest Wayland client that drives
 * wlr-foreign-toplevel-management on demand, the foreign-toplevel analog of
 * scripts/wl-activate.c for scripts/foreign-test.sh. A stock terminal never
 * binds the manager, so proving kiln advertises one write-only handle per mapped
 * client (correct title/app_id/state) and that a taskbar's set_minimized /
 * activate round-trip through the existing request events needs a client that
 * actually speaks the protocol.
 *
 *   ./build/wl-toplevel open <app_id> <title>   map a plain xdg toplevel with
 *       the given identity, then block (the OBSERVED window the others read)
 *   ./build/wl-toplevel list                    bind the foreign manager, print
 *       one "title|app_id|state" line per advertised toplevel, exit
 *   ./build/wl-toplevel minimize <app_id>       ask the matching toplevel to
 *       minimize (zwlr_foreign_toplevel_handle_v1.set_minimized), exit
 *   ./build/wl-toplevel activate  <app_id>      ask it to activate, carrying this
 *       client's seat (so kiln can answer the named question: seat -> valid), exit
 *
 * state is comma-joined from the protocol's state array, or "normal" when empty.
 */
#define _GNU_SOURCE
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

/* --- shared globals --- */
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct xdg_wm_base *wm_base;
static struct zwlr_foreign_toplevel_manager_v1 *manager;

/* --- the foreign toplevels we learn about (list/minimize/activate modes) --- */
struct ft {
	struct zwlr_foreign_toplevel_handle_v1 *handle;
	char *app_id;
	char *title;
	bool maximized, minimized, activated, fullscreen;
	bool done;
	struct ft *next;
};
static struct ft *toplevels;

static struct ft *ft_lookup(struct zwlr_foreign_toplevel_handle_v1 *h) {
	for (struct ft *t = toplevels; t != NULL; t = t->next) {
		if (t->handle == h) {
			return t;
		}
	}
	return NULL;
}

/* --- foreign toplevel handle events --- */
static void ft_title(void *data, struct zwlr_foreign_toplevel_handle_v1 *h,
		const char *title) {
	struct ft *t = ft_lookup(h);
	free(t->title);
	t->title = strdup(title);
}
static void ft_app_id(void *data, struct zwlr_foreign_toplevel_handle_v1 *h,
		const char *app_id) {
	struct ft *t = ft_lookup(h);
	free(t->app_id);
	t->app_id = strdup(app_id);
}
static void ft_output_enter(void *data,
		struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) {}
static void ft_output_leave(void *data,
		struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) {}
static void ft_state(void *data, struct zwlr_foreign_toplevel_handle_v1 *h,
		struct wl_array *states) {
	struct ft *t = ft_lookup(h);
	t->maximized = t->minimized = t->activated = t->fullscreen = false;
	uint32_t *s;
	wl_array_for_each(s, states) {
		switch (*s) {
		case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED:
			t->maximized = true; break;
		case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED:
			t->minimized = true; break;
		case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED:
			t->activated = true; break;
		case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN:
			t->fullscreen = true; break;
		}
	}
}
static void ft_done(void *data, struct zwlr_foreign_toplevel_handle_v1 *h) {
	struct ft *t = ft_lookup(h);
	t->done = true;
}
static void ft_closed(void *data, struct zwlr_foreign_toplevel_handle_v1 *h) {}
static void ft_parent(void *data, struct zwlr_foreign_toplevel_handle_v1 *h,
		struct zwlr_foreign_toplevel_handle_v1 *parent) {}
static const struct zwlr_foreign_toplevel_handle_v1_listener ft_listener = {
	.title = ft_title,
	.app_id = ft_app_id,
	.output_enter = ft_output_enter,
	.output_leave = ft_output_leave,
	.state = ft_state,
	.done = ft_done,
	.closed = ft_closed,
	.parent = ft_parent,
};

static void mgr_toplevel(void *data,
		struct zwlr_foreign_toplevel_manager_v1 *mgr,
		struct zwlr_foreign_toplevel_handle_v1 *h) {
	struct ft *t = calloc(1, sizeof(*t));
	t->handle = h;
	t->next = toplevels;
	toplevels = t;
	zwlr_foreign_toplevel_handle_v1_add_listener(h, &ft_listener, NULL);
}
static void mgr_finished(void *data,
		struct zwlr_foreign_toplevel_manager_v1 *mgr) {}
static const struct zwlr_foreign_toplevel_manager_v1_listener mgr_listener = {
	.toplevel = mgr_toplevel,
	.finished = mgr_finished,
};

/* --- registry --- */
static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
		const char *iface, uint32_t version) {
	if (strcmp(iface, wl_compositor_interface.name) == 0) {
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	} else if (strcmp(iface, wl_shm_interface.name) == 0) {
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (strcmp(iface, wl_seat_interface.name) == 0) {
		seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
	} else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
		wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
	} else if (strcmp(iface,
			zwlr_foreign_toplevel_manager_v1_interface.name) == 0) {
		manager = wl_registry_bind(reg, name,
			&zwlr_foreign_toplevel_manager_v1_interface, 3);
	}
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

/* --- xdg-shell (open mode only) --- */
static int configured = 0;
static void wm_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
	xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener wm_listener = { wm_ping };
static void surf_configure(void *data, struct xdg_surface *xs, uint32_t serial) {
	xdg_surface_ack_configure(xs, serial);
	configured = 1;
}
static const struct xdg_surface_listener xdg_surf_listener = { surf_configure };
static void tl_configure(void *data, struct xdg_toplevel *t, int32_t w,
		int32_t h, struct wl_array *states) {}
static void tl_close(void *data, struct xdg_toplevel *t) { exit(0); }
static const struct xdg_toplevel_listener tl_listener = {
	.configure = tl_configure,
	.close = tl_close,
};

static struct wl_buffer *make_buffer(void) {
	int w = 64, h = 64, stride = w * 4, size = stride * h;
	int fd = memfd_create("wl-toplevel", MFD_CLOEXEC);
	if (fd < 0 || ftruncate(fd, size) < 0) {
		return NULL;
	}
	void *m = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (m == MAP_FAILED) {
		close(fd);
		return NULL;
	}
	memset(m, 0xff, size);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
	struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
		WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	munmap(m, size);
	close(fd);
	return buf;
}

static int run_open(struct wl_display *dpy, const char *app_id,
		const char *title) {
	if (!compositor || !shm || !wm_base) {
		fprintf(stderr, "wl-toplevel: missing a global for open\n");
		return 1;
	}
	xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
	struct wl_surface *surface = wl_compositor_create_surface(compositor);
	struct xdg_surface *xsurf = xdg_wm_base_get_xdg_surface(wm_base, surface);
	xdg_surface_add_listener(xsurf, &xdg_surf_listener, NULL);
	struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xsurf);
	xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
	xdg_toplevel_set_app_id(toplevel, app_id);
	xdg_toplevel_set_title(toplevel, title);
	wl_surface_commit(surface);
	while (!configured) {
		if (wl_display_dispatch(dpy) < 0) {
			return 1;
		}
	}
	struct wl_buffer *buf = make_buffer();
	if (buf == NULL) {
		fprintf(stderr, "wl-toplevel: buffer allocation failed\n");
		return 1;
	}
	wl_surface_attach(surface, buf, 0, 0);
	wl_surface_damage(surface, 0, 0, 64, 64);
	wl_surface_commit(surface);
	/* Stay a live mapped client the manager can advertise, until killed. */
	while (wl_display_dispatch(dpy) != -1) {
	}
	return 0;
}

/* Two extra roundtrips drain the manager's toplevel burst: the toplevel events
 * arrive after we bind the manager, then title/app_id/state/done per handle. */
static void drain(struct wl_display *dpy) {
	wl_display_roundtrip(dpy);
	wl_display_roundtrip(dpy);
}

static const char *state_str(struct ft *t, char *buf, size_t n) {
	buf[0] = '\0';
	size_t len = 0;
	const char *names[4] = { NULL, NULL, NULL, NULL };
	if (t->maximized)  names[0] = "maximized";
	if (t->minimized)  names[1] = "minimized";
	if (t->activated)  names[2] = "activated";
	if (t->fullscreen) names[3] = "fullscreen";
	for (int i = 0; i < 4; i++) {
		if (names[i] == NULL) {
			continue;
		}
		len += snprintf(buf + len, n - len, "%s%s",
			len > 0 ? "," : "", names[i]);
	}
	return len > 0 ? buf : "normal";
}

int main(int argc, char **argv) {
	const char *mode = argc > 1 ? argv[1] : "list";

	struct wl_display *dpy = wl_display_connect(NULL);
	if (dpy == NULL) {
		fprintf(stderr, "wl-toplevel: cannot connect to WAYLAND_DISPLAY\n");
		return 1;
	}
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(dpy);

	if (strcmp(mode, "open") == 0) {
		const char *app_id = argc > 2 ? argv[2] : "kiln.toplevel.probe";
		const char *title = argc > 3 ? argv[3] : "kiln toplevel probe";
		return run_open(dpy, app_id, title);
	}

	if (manager == NULL) {
		fprintf(stderr, "wl-toplevel: no foreign-toplevel manager advertised\n");
		return 1;
	}
	zwlr_foreign_toplevel_manager_v1_add_listener(manager, &mgr_listener, NULL);
	drain(dpy);

	if (strcmp(mode, "list") == 0) {
		char buf[64];
		for (struct ft *t = toplevels; t != NULL; t = t->next) {
			printf("%s|%s|%s\n", t->title != NULL ? t->title : "",
				t->app_id != NULL ? t->app_id : "",
				state_str(t, buf, sizeof(buf)));
		}
		return 0;
	}

	/* minimize / activate: find the toplevel by app_id and send the request. */
	const char *want = argc > 2 ? argv[2] : "";
	struct ft *target = NULL;
	for (struct ft *t = toplevels; t != NULL; t = t->next) {
		if (t->app_id != NULL && strcmp(t->app_id, want) == 0) {
			target = t;
			break;
		}
	}
	if (target == NULL) {
		fprintf(stderr, "wl-toplevel: no toplevel with app_id %s\n", want);
		return 1;
	}
	if (strcmp(mode, "minimize") == 0) {
		zwlr_foreign_toplevel_handle_v1_set_minimized(target->handle);
	} else if (strcmp(mode, "activate") == 0) {
		if (seat == NULL) {
			fprintf(stderr, "wl-toplevel: no seat for activate\n");
			return 1;
		}
		zwlr_foreign_toplevel_handle_v1_activate(target->handle, seat);
	} else {
		fprintf(stderr, "wl-toplevel: unknown mode %s\n", mode);
		return 1;
	}
	wl_display_roundtrip(dpy);
	return 0;
}
