/* wl-fractional: a Wayland client that reports the fractional scale kiln hands
 * its surface, for scripts/hidpi-frac-test.sh. The compositor's own raster is
 * scale-aware, but a native client learns its output scale only through
 * wp_fractional_scale_v1; without the manager global a client on a 1.5x output
 * is never told, sizes itself wrong, and its input region drifts from the cursor.
 *
 *   ./build/wl-fractional globals   print which of the two globals are advertised:
 *       "fractional=<yes|no> viewporter=<yes|no>", exit
 *   ./build/wl-fractional scale     map a toplevel, then print the preferred scale
 *       it received: "scale=<n>" in 120ths (180 == 1.5), or "scale=none", exit
 *
 * The test sets the output scale first, then runs this: on a 1.5x output the
 * surface must receive preferred_scale = 180.
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
#include "fractional-scale-v1-client-protocol.h"
#include "viewporter-client-protocol.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wp_fractional_scale_manager_v1 *frac_mgr;
static struct wp_viewporter *viewporter;

static int configured = 0;
static long got_scale = -1;   /* preferred_scale, in 120ths; -1 == not received */

static void frac_preferred_scale(void *data, struct wp_fractional_scale_v1 *f,
		uint32_t scale) {
	got_scale = scale;
}
static const struct wp_fractional_scale_v1_listener frac_listener = {
	.preferred_scale = frac_preferred_scale,
};

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
		const char *iface, uint32_t version) {
	if (strcmp(iface, wl_compositor_interface.name) == 0) {
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	} else if (strcmp(iface, wl_shm_interface.name) == 0) {
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
		wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
	} else if (strcmp(iface, wp_fractional_scale_manager_v1_interface.name) == 0) {
		frac_mgr = wl_registry_bind(reg, name,
			&wp_fractional_scale_manager_v1_interface, 1);
	} else if (strcmp(iface, wp_viewporter_interface.name) == 0) {
		viewporter = wl_registry_bind(reg, name, &wp_viewporter_interface, 1);
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
	int fd = memfd_create("wl-fractional", MFD_CLOEXEC);
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
	const char *mode = argc > 1 ? argv[1] : "scale";

	struct wl_display *dpy = wl_display_connect(NULL);
	if (dpy == NULL) {
		fprintf(stderr, "wl-fractional: cannot connect to WAYLAND_DISPLAY\n");
		return 1;
	}
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(dpy);

	if (strcmp(mode, "globals") == 0) {
		printf("fractional=%s viewporter=%s\n",
			frac_mgr != NULL ? "yes" : "no",
			viewporter != NULL ? "yes" : "no");
		return 0;
	}

	if (!compositor || !shm || !wm_base) {
		fprintf(stderr, "wl-fractional: missing a core global\n");
		return 1;
	}
	if (frac_mgr == NULL) {
		fprintf(stderr, "wl-fractional: no fractional-scale manager advertised\n");
		return 1;
	}
	xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
	struct wl_surface *surface = wl_compositor_create_surface(compositor);
	/* The fractional-scale object for this surface delivers preferred_scale. */
	struct wp_fractional_scale_v1 *frac =
		wp_fractional_scale_manager_v1_get_fractional_scale(frac_mgr, surface);
	wp_fractional_scale_v1_add_listener(frac, &frac_listener, NULL);

	struct xdg_surface *xsurf = xdg_wm_base_get_xdg_surface(wm_base, surface);
	xdg_surface_add_listener(xsurf, &xdg_surf_listener, NULL);
	struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xsurf);
	xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
	xdg_toplevel_set_app_id(toplevel, "kiln.fractional.probe");
	xdg_toplevel_set_title(toplevel, "kiln fractional probe");
	wl_surface_commit(surface);
	while (!configured) {
		if (wl_display_dispatch(dpy) < 0) {
			return 1;
		}
	}
	struct wl_buffer *buf = make_buffer();
	if (buf == NULL) {
		fprintf(stderr, "wl-fractional: buffer allocation failed\n");
		return 1;
	}
	wl_surface_attach(surface, buf, 0, 0);
	wl_surface_damage(surface, 0, 0, 64, 64);
	wl_surface_commit(surface);

	/* The surface enters an output once mapped and placed; the compositor then
	 * sends preferred_scale. Pump a bounded number of roundtrips for it. */
	for (int i = 0; i < 40 && got_scale < 0; i++) {
		if (wl_display_roundtrip(dpy) < 0) {
			break;
		}
	}
	if (got_scale < 0) {
		printf("scale=none\n");
	} else {
		printf("scale=%ld\n", got_scale);
	}
	return 0;
}
