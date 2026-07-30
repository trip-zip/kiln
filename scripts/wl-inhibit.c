/* wl-inhibit: a Wayland client that maps a toplevel and holds idle off with an
 * idle-inhibitor, for the idle battery (scripts/idle-test.sh). kiln's inhibit
 * leg only flips idle::inhibit while an inhibitor's surface is visible, so
 * proving it needs a
 * real client that binds zwp_idle_inhibit_manager_v1, maps a surface the stock
 * config tiles on screen, and creates an inhibitor on it. kiln's server half is
 * a plain wlroots global and needs no generated code; only the fixture, which
 * speaks the wire protocol, does.
 *
 *   ./build/wl-inhibit globals   print whether the manager is advertised:
 *       "idle_inhibit=<yes|no>", exit
 *   ./build/wl-inhibit           map a toplevel (app_id kiln.inhibit.probe),
 *       create an inhibitor on it, print "inhibitor ready", dispatch until killed
 *
 * The test launches the second mode in the background and kills the saved pid to
 * drop the inhibitor (the manager destroys the inhibitor with its surface).
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
#include "idle-inhibit-unstable-v1-client-protocol.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct zwp_idle_inhibit_manager_v1 *inhibit_mgr;

static int configured = 0;

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
		const char *iface, uint32_t version) {
	if (strcmp(iface, wl_compositor_interface.name) == 0) {
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	} else if (strcmp(iface, wl_shm_interface.name) == 0) {
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
		wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
	} else if (strcmp(iface, zwp_idle_inhibit_manager_v1_interface.name) == 0) {
		inhibit_mgr = wl_registry_bind(reg, name,
			&zwp_idle_inhibit_manager_v1_interface, 1);
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

static struct wl_buffer *make_buffer(void) {
	int w = 64, h = 64, stride = w * 4, size = stride * h;
	int fd = memfd_create("wl-inhibit", MFD_CLOEXEC);
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
	const char *mode = argc > 1 ? argv[1] : "inhibit";

	struct wl_display *dpy = wl_display_connect(NULL);
	if (dpy == NULL) {
		fprintf(stderr, "wl-inhibit: cannot connect to WAYLAND_DISPLAY\n");
		return 1;
	}
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(dpy);

	if (strcmp(mode, "globals") == 0) {
		printf("idle_inhibit=%s\n", inhibit_mgr != NULL ? "yes" : "no");
		return 0;
	}

	if (!compositor || !shm || !wm_base) {
		fprintf(stderr, "wl-inhibit: missing a core global\n");
		return 1;
	}
	if (inhibit_mgr == NULL) {
		fprintf(stderr, "wl-inhibit: no idle-inhibit manager advertised\n");
		return 1;
	}
	xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
	struct wl_surface *surface = wl_compositor_create_surface(compositor);
	struct xdg_surface *xsurf = xdg_wm_base_get_xdg_surface(wm_base, surface);
	xdg_surface_add_listener(xsurf, &xdg_surf_listener, NULL);
	struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xsurf);
	xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
	xdg_toplevel_set_app_id(toplevel, "kiln.inhibit.probe");
	xdg_toplevel_set_title(toplevel, "kiln inhibit probe");
	wl_surface_commit(surface);
	while (!configured) {
		if (wl_display_dispatch(dpy) < 0) {
			return 1;
		}
	}
	struct wl_buffer *buf = make_buffer();
	if (buf == NULL) {
		fprintf(stderr, "wl-inhibit: buffer allocation failed\n");
		return 1;
	}
	wl_surface_attach(surface, buf, 0, 0);
	wl_surface_damage(surface, 0, 0, 64, 64);
	wl_surface_commit(surface);

	/* The inhibitor holds idle off while this surface is visible; kiln flips
	 * idle::inhibit once the config tiles the surface on screen. */
	struct zwp_idle_inhibitor_v1 *inhibitor =
		zwp_idle_inhibit_manager_v1_create_inhibitor(inhibit_mgr, surface);
	wl_surface_commit(surface);
	wl_display_roundtrip(dpy);
	printf("inhibitor ready\n");
	fflush(stdout);

	/* Dispatch until killed: the test drops the inhibitor by killing us, and
	 * the manager destroys the inhibitor object with the surface. */
	while (wl_display_dispatch(dpy) >= 0) {
	}
	zwp_idle_inhibitor_v1_destroy(inhibitor);
	return 0;
}
