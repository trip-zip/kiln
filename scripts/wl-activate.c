/* wl-activate: the smallest Wayland client that drives xdg-activation on demand,
 * the analog of scripts/x11-state.c for the request::activate battery
 * (scripts/activate-test.sh).
 * A stock terminal never calls xdg_activation_v1.activate, so proving that C
 * derives `valid` from the token's seat needs a client that actually asks.
 *
 *   ./build/wl-activate valid    [app_id]  raise using $XDG_ACTIVATION_TOKEN
 *       (seat-backed by spawn_with_token, so it must arrive valid=true)
 *   ./build/wl-activate invalid  [app_id]  mint an own token with no serial and
 *       raise with it (no seat, so it must arrive valid=false)
 *   ./build/wl-activate hold     [app_id]  map and block, never activate (a focus
 *       holder the decline leg checks against)
 *
 * It maps one toplevel with the given app_id (default kiln.activate.probe),
 * activates its own surface, then blocks as a live client kiln can focus or
 * decline. Killed by the test's cleanup, or by the compositor closing it.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "xdg-activation-v1-client-protocol.h"

#define DEFAULT_APP_ID "kiln.activate.probe"

static const char *app_id = DEFAULT_APP_ID;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct xdg_activation_v1 *activation;

static struct wl_surface *surface;
static int configured = 0;
static char *minted_token = NULL;

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
		const char *iface, uint32_t version) {
	if (strcmp(iface, wl_compositor_interface.name) == 0) {
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	} else if (strcmp(iface, wl_shm_interface.name) == 0) {
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
		wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
	} else if (strcmp(iface, xdg_activation_v1_interface.name) == 0) {
		activation = wl_registry_bind(reg, name, &xdg_activation_v1_interface, 1);
	}
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

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

static void tok_done(void *data, struct xdg_activation_token_v1 *t,
		const char *token) {
	minted_token = strdup(token);
}
static const struct xdg_activation_token_v1_listener token_listener = {
	.done = tok_done,
};

/* An opaque 64x64 buffer, the minimum for the surface to map (wlroots fires map
 * only once a buffer is committed). */
static struct wl_buffer *make_buffer(void) {
	int w = 64, h = 64, stride = w * 4, size = stride * h;
	int fd = memfd_create("wl-activate", MFD_CLOEXEC);
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

int main(int argc, char **argv) {
	const char *mode = argc > 1 ? argv[1] : "valid";
	if (argc > 2 && argv[2][0] != '\0') {
		app_id = argv[2];
	}

	struct wl_display *dpy = wl_display_connect(NULL);
	if (dpy == NULL) {
		fprintf(stderr, "wl-activate: cannot connect to WAYLAND_DISPLAY\n");
		return 1;
	}
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(dpy);
	if (!compositor || !shm || !wm_base || !activation) {
		fprintf(stderr, "wl-activate: compositor is missing a required global\n");
		return 1;
	}
	xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);

	surface = wl_compositor_create_surface(compositor);
	struct xdg_surface *xsurf = xdg_wm_base_get_xdg_surface(wm_base, surface);
	xdg_surface_add_listener(xsurf, &xdg_surf_listener, NULL);
	struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xsurf);
	xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
	xdg_toplevel_set_app_id(toplevel, app_id);
	xdg_toplevel_set_title(toplevel, "kiln activate probe");
	wl_surface_commit(surface);
	while (!configured) {
		if (wl_display_dispatch(dpy) < 0) {
			return 1;
		}
	}
	struct wl_buffer *buf = make_buffer();
	if (buf == NULL) {
		fprintf(stderr, "wl-activate: buffer allocation failed\n");
		return 1;
	}
	wl_surface_attach(surface, buf, 0, 0);
	wl_surface_damage(surface, 0, 0, 64, 64);
	wl_surface_commit(surface);
	wl_display_roundtrip(dpy);

	if (strcmp(mode, "invalid") == 0) {
		/* Own token, committed WITHOUT set_serial/set_seat: wlroots has no seat
		 * to attach, so it reaches request_activate with token->seat == NULL and
		 * must arrive valid=false. set_app_id rides through as the payload hint. */
		struct xdg_activation_token_v1 *tok =
			xdg_activation_v1_get_activation_token(activation);
		xdg_activation_token_v1_add_listener(tok, &token_listener, NULL);
		xdg_activation_token_v1_set_app_id(tok, app_id);
		xdg_activation_token_v1_set_surface(tok, surface);
		xdg_activation_token_v1_commit(tok);
		while (minted_token == NULL) {
			if (wl_display_dispatch(dpy) < 0) {
				return 1;
			}
		}
		xdg_activation_v1_activate(activation, minted_token, surface);
		wl_display_roundtrip(dpy);
	} else if (strcmp(mode, "valid") == 0) {
		/* The token spawn_with_token minted and handed us in the environment. It
		 * was seat-backed at mint, so raising with it must arrive valid=true. */
		const char *tok = getenv("XDG_ACTIVATION_TOKEN");
		if (tok == NULL || *tok == '\0') {
			fprintf(stderr, "wl-activate: no XDG_ACTIVATION_TOKEN in env\n");
			return 1;
		}
		xdg_activation_v1_activate(activation, tok, surface);
		wl_display_roundtrip(dpy);
	}
	/* mode "hold" activates nothing: it just stays mapped and focused. */

	/* Stay a live client so kiln can focus or decline us, until killed. */
	while (wl_display_dispatch(dpy) != -1) {
	}
	return 0;
}
