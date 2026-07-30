/* Test fixture: a managed X11 client that declares an icon and a role, the two
 * facts the icon battery (scripts/icon-test.sh) asserts. Built only when
 * -Dxwayland is enabled, never installed.
 *
 * The icon leg needs a window carrying _NET_WM_ICON at more than one size, so
 * largest-wins is distinguishable from first-wins: nothing on the box lets you
 * order that on demand, and a real app's icon is whatever its theme ships. The
 * role leg needs WM_WINDOW_ROLE set at all, which few apps bother with. Hence
 * this.
 *
 *   ./build/x11-icon        (100x80, class KilnIcon, role pop-up)
 *
 * The icon property carries the 8x8 FIRST and the 16x16 SECOND, so a compositor
 * that keeps the first one it sees keeps red, and one that keeps the largest
 * keeps green. The test asserts green.
 *
 * Runs until killed, the way a real client stays mapped.
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <xcb/xcb.h>

/* _NET_WM_ICON is CARDINAL/32: width, height, then width*height pixels of
 * packed ARGB, and any number of those triples back to back. */
#define SMALL 8
#define LARGE 16
#define ICON_LEN (2 + SMALL * SMALL + 2 + LARGE * LARGE)

static xcb_atom_t intern(xcb_connection_t *c, const char *name) {
	xcb_intern_atom_reply_t *r = xcb_intern_atom_reply(
		c, xcb_intern_atom(c, 0, strlen(name), name), NULL);
	xcb_atom_t a = r != NULL ? r->atom : XCB_ATOM_NONE;
	free(r);
	return a;
}

/* Wait until the WM is up before mapping. XWayland starts lazily on the first
 * client, and a window mapped before xwm has grabbed SubstructureRedirect on
 * the root loses its MapRequest for good: a real, slow-starting app never hits
 * this, but a bare xcb client that connects and maps in one breath does. The WM
 * announces itself by pointing _NET_SUPPORTING_WM_CHECK at a child window, so
 * poll for it (bounded, then map anyway). */
static void wait_for_wm(xcb_connection_t *c, xcb_screen_t *s) {
	xcb_atom_t check = intern(c, "_NET_SUPPORTING_WM_CHECK");
	if (check == XCB_ATOM_NONE) {
		return;
	}
	for (int i = 0; i < 200; i++) {
		xcb_get_property_reply_t *r = xcb_get_property_reply(c,
			xcb_get_property(c, 0, s->root, check, XCB_ATOM_WINDOW, 0, 1), NULL);
		bool set = r != NULL && xcb_get_property_value_length(r) >= 4;
		free(r);
		if (set) {
			return;
		}
		struct timespec ts = { .tv_sec = 0, .tv_nsec = 50 * 1000 * 1000 };
		nanosleep(&ts, NULL);
	}
}

int main(void) {
	xcb_connection_t *c = xcb_connect(NULL, NULL);
	if (xcb_connection_has_error(c)) {
		fprintf(stderr, "x11-icon: cannot connect to X (is DISPLAY set?)\n");
		return 1;
	}
	xcb_screen_t *s = xcb_setup_roots_iterator(xcb_get_setup(c)).data;

	/* Let XWayland's WM come up first, or the map below is lost (see above). */
	wait_for_wm(c, s);

	xcb_window_t win = xcb_generate_id(c);
	uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
	uint32_t vals[] = { s->white_pixel, XCB_EVENT_MASK_EXPOSURE };
	xcb_create_window(c, XCB_COPY_FROM_PARENT, win, s->root, 0, 0, 100, 80, 1,
		XCB_WINDOW_CLASS_INPUT_OUTPUT, s->root_visual, mask, vals);

	/* WM_CLASS is instance\0class; "KilnIcon" is what the test matches on. */
	xcb_change_property(c, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_CLASS,
		XCB_ATOM_STRING, 8, 18, "kilnicon\0KilnIcon");

	/* WM_WINDOW_ROLE is ICCCM but not predefined, so it interns like any other.
	 * wlroots reads it into wlr_xwayland_surface.role for us. */
	xcb_atom_t role = intern(c, "WM_WINDOW_ROLE");
	if (role != XCB_ATOM_NONE) {
		xcb_change_property(c, XCB_PROP_MODE_REPLACE, win, role,
			XCB_ATOM_STRING, 8, 6, "pop-up");
	}

	/* Smallest first, on purpose: see the header. Solid colors, fully opaque,
	 * so a center-pixel probe of the rendered cell names which one survived. */
	uint32_t icon[ICON_LEN];
	size_t i = 0;
	icon[i++] = SMALL;
	icon[i++] = SMALL;
	for (int p = 0; p < SMALL * SMALL; p++) {
		icon[i++] = 0xffff0000; /* red */
	}
	icon[i++] = LARGE;
	icon[i++] = LARGE;
	for (int p = 0; p < LARGE * LARGE; p++) {
		icon[i++] = 0xff00ff00; /* green */
	}
	xcb_atom_t net_icon = intern(c, "_NET_WM_ICON");
	if (net_icon != XCB_ATOM_NONE) {
		xcb_change_property(c, XCB_PROP_MODE_REPLACE, win, net_icon,
			XCB_ATOM_CARDINAL, 32, ICON_LEN, icon);
	}

	xcb_map_window(c, win);
	xcb_flush(c);

	printf("x11-icon: mapped 0x%x with %dx%d red then %dx%d green\n",
		win, SMALL, SMALL, LARGE, LARGE);
	fflush(stdout);

	xcb_generic_event_t *ev;
	while ((ev = xcb_wait_for_event(c)) != NULL) {
		free(ev);
	}
	xcb_disconnect(c);
	return 0;
}
