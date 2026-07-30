/* wl-drag: the smallest Wayland client that starts a real DnD drag, the fixture
 * for the DnD battery (scripts/dnd-test.sh). kiln's DnD leg validates the
 * start_drag serial wlroots demands, parents the drag icon into the cursor band,
 * and emits drag::start / drag::end. Proving that needs a client that maps, takes
 * a real pointer button, and calls wl_data_device.start_drag with the button
 * serial; a stock app will not do it on command.
 *
 *   ./build/wl-drag [app_id]
 *
 * Maps a plain xdg toplevel (kiln tiles it to fill the nest), then blocks
 * dispatching. On the FIRST pointer button press it starts a drag: a
 * wl_data_source offering text/plain, plus a small shm icon surface, handed to
 * wl_data_device.start_drag with the press serial (button still held, so the
 * serial is a live pointer-grab serial kiln's validation accepts). The drag ends
 * when the outer harness releases the button (a drop). The process stays alive so
 * the whole start..end window is observable over kiln's IPC socket; it exits on
 * xdg_toplevel.close or SIGKILL.
 *
 * Needs only core wayland + xdg-shell (no extra protocol xml); the data-device is
 * in the core wayland.xml, like wl_seat.
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

/* --- globals bound from the registry --- */
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct xdg_wm_base *wm_base;
static struct wl_data_device_manager *ddm;

static struct wl_surface *surface;      /* the origin surface (the drag starts here) */
static struct wl_data_device *data_dev;
static struct wl_pointer *pointer;
static bool dragging = false;           /* one drag per run, on the first press */

/* --- a plain 0xff-filled ARGB buffer, w x h --- */
static struct wl_buffer *make_buffer(int w, int h) {
	int stride = w * 4, size = stride * h;
	int fd = memfd_create("wl-drag", MFD_CLOEXEC);
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

/* --- data source: stubs. C answers no target and no action; the source just
 * has to exist and offer a type for the drag to be well-formed. --- */
static void src_target(void *d, struct wl_data_source *s, const char *mime) {}
static void src_send(void *d, struct wl_data_source *s, const char *mime,
		int32_t fd) {
	/* A target accepted a drop and asked for the data; write a token and close. */
	const char *text = "kiln-dnd";
	if (write(fd, text, strlen(text)) < 0) { /* nothing to do on failure */ }
	close(fd);
}
static void src_cancelled(void *d, struct wl_data_source *s) {}
static void src_dnd_drop_performed(void *d, struct wl_data_source *s) {}
static void src_dnd_finished(void *d, struct wl_data_source *s) {}
static void src_action(void *d, struct wl_data_source *s, uint32_t action) {}
static const struct wl_data_source_listener src_listener = {
	.target = src_target,
	.send = src_send,
	.cancelled = src_cancelled,
	.dnd_drop_performed = src_dnd_drop_performed,
	.dnd_finished = src_dnd_finished,
	.action = src_action,
};

static void start_drag(uint32_t serial) {
	struct wl_data_source *source =
		wl_data_device_manager_create_data_source(ddm);
	wl_data_source_add_listener(source, &src_listener, NULL);
	wl_data_source_offer(source, "text/plain");

	/* The drag icon: a small surface with a buffer, ridden by kiln's cursor band. */
	struct wl_surface *icon = wl_compositor_create_surface(compositor);
	struct wl_buffer *ibuf = make_buffer(32, 32);
	wl_surface_attach(icon, ibuf, 0, 0);
	wl_surface_damage(icon, 0, 0, 32, 32);
	wl_surface_commit(icon);

	wl_data_device_start_drag(data_dev, source, surface, icon, serial);
	fprintf(stderr, "wl-drag: start_drag issued (serial %u)\n", serial);
}

/* --- pointer: the first button PRESS, while held, is our drag serial --- */
static void pt_enter(void *d, struct wl_pointer *p, uint32_t serial,
		struct wl_surface *s, wl_fixed_t sx, wl_fixed_t sy) {}
static void pt_leave(void *d, struct wl_pointer *p, uint32_t serial,
		struct wl_surface *s) {}
static void pt_motion(void *d, struct wl_pointer *p, uint32_t time,
		wl_fixed_t sx, wl_fixed_t sy) {}
static void pt_button(void *d, struct wl_pointer *p, uint32_t serial,
		uint32_t time, uint32_t button, uint32_t state) {
	if (state == WL_POINTER_BUTTON_STATE_PRESSED && !dragging) {
		dragging = true;
		start_drag(serial);
	}
}
static void pt_axis(void *d, struct wl_pointer *p, uint32_t time, uint32_t axis,
		wl_fixed_t value) {}
static void pt_frame(void *d, struct wl_pointer *p) {}
static void pt_axis_source(void *d, struct wl_pointer *p, uint32_t s) {}
static void pt_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) {}
static void pt_axis_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v) {}
static const struct wl_pointer_listener pt_listener = {
	.enter = pt_enter,
	.leave = pt_leave,
	.motion = pt_motion,
	.button = pt_button,
	.axis = pt_axis,
	.frame = pt_frame,
	.axis_source = pt_axis_source,
	.axis_stop = pt_axis_stop,
	.axis_discrete = pt_axis_discrete,
};

/* --- seat: grab the pointer once the seat announces it has one --- */
static void seat_caps(void *d, struct wl_seat *s, uint32_t caps) {
	if ((caps & WL_SEAT_CAPABILITY_POINTER) && pointer == NULL) {
		pointer = wl_seat_get_pointer(s);
		wl_pointer_add_listener(pointer, &pt_listener, NULL);
	}
}
static void seat_name(void *d, struct wl_seat *s, const char *name) {}
static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_caps,
	.name = seat_name,
};

/* --- registry --- */
static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
		const char *iface, uint32_t version) {
	if (strcmp(iface, wl_compositor_interface.name) == 0) {
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	} else if (strcmp(iface, wl_shm_interface.name) == 0) {
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (strcmp(iface, wl_seat_interface.name) == 0) {
		seat = wl_registry_bind(reg, name, &wl_seat_interface, 3);
		wl_seat_add_listener(seat, &seat_listener, NULL);
	} else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
		wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
	} else if (strcmp(iface, wl_data_device_manager_interface.name) == 0) {
		ddm = wl_registry_bind(reg, name,
			&wl_data_device_manager_interface, 3);
	}
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

/* --- xdg-shell --- */
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

int main(int argc, char **argv) {
	const char *app_id = argc > 1 ? argv[1] : "kiln.dnd.probe";

	struct wl_display *dpy = wl_display_connect(NULL);
	if (dpy == NULL) {
		fprintf(stderr, "wl-drag: cannot connect to WAYLAND_DISPLAY\n");
		return 1;
	}
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(dpy);       /* bind globals */
	wl_display_roundtrip(dpy);       /* drain seat capabilities -> pointer */

	if (!compositor || !shm || !wm_base || !seat || !ddm) {
		fprintf(stderr, "wl-drag: missing a required global\n");
		return 1;
	}
	data_dev = wl_data_device_manager_get_data_device(ddm, seat);

	xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
	surface = wl_compositor_create_surface(compositor);
	struct xdg_surface *xsurf = xdg_wm_base_get_xdg_surface(wm_base, surface);
	xdg_surface_add_listener(xsurf, &xdg_surf_listener, NULL);
	struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xsurf);
	xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
	xdg_toplevel_set_app_id(toplevel, app_id);
	xdg_toplevel_set_title(toplevel, "kiln dnd probe");
	wl_surface_commit(surface);
	while (!configured) {
		if (wl_display_dispatch(dpy) < 0) {
			return 1;
		}
	}
	/* A large buffer at the tile origin, so the surface covers the area the
	 * harness aims the pointer at (a tiny buffer would sit in the top-left
	 * corner and the press would miss it, leaving the fixture without pointer
	 * focus and the start serial invalid). */
	struct wl_buffer *buf = make_buffer(1000, 700);
	if (buf == NULL) {
		fprintf(stderr, "wl-drag: buffer allocation failed\n");
		return 1;
	}
	wl_surface_attach(surface, buf, 0, 0);
	wl_surface_damage(surface, 0, 0, 1000, 700);
	wl_surface_commit(surface);

	/* Mapped and holding a pointer; the drag starts on the harness's button
	 * press and runs until it releases. Stay alive so drag::start..drag::end is
	 * fully observable, until killed or closed. */
	while (wl_display_dispatch(dpy) != -1) {
	}
	return 0;
}
