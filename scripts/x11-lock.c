/* Test fixture: an X11 client that takes the pointer the way a game does, so
 * the pointer-constraint battery (scripts/pointer-test.sh) is re-runnable from
 * the tree. Built only when -Dxwayland is enabled, never installed.
 *
 *   ./build/x11-lock            (spawned inside kiln, on the nest's DISPLAY)
 *
 * A real game is impractical headless, so this is the smallest client that
 * produces the same protocol traffic. It hides its cursor and grabs the
 * pointer, and XWayland answers that pair by asking the compositor for a
 * locked pointer, which is the whole point:
 * an X11 grab is not implemented by XWayland, it is translated into
 * pointer-constraints, so with no constraints global it is silently dropped.
 *
 * It reports on stdout, which is kiln's stdout when kiln spawns it: one line
 * per burst of motion, carrying the running count and the pointer position the
 * X server thinks it has. A locked pointer keeps that count climbing while the
 * compositor's own cursor does not move at all.
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xcb/xcb.h>

int main(void) {
	xcb_connection_t *c = xcb_connect(NULL, NULL);
	if (xcb_connection_has_error(c)) {
		fprintf(stderr, "x11-lock: no X display\n");
		return 1;
	}
	xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(c)).data;

	/* An empty 1x1 bitmap is an invisible cursor: the hidden cursor is half of
	 * what makes XWayland lock (the other half is the grab below). */
	xcb_pixmap_t blank = xcb_generate_id(c);
	xcb_create_pixmap(c, 1, blank, screen->root, 1, 1);
	xcb_gcontext_t gc = xcb_generate_id(c);
	uint32_t gcv[] = { 0, 0 };
	xcb_create_gc(c, gc, blank, XCB_GC_FOREGROUND | XCB_GC_BACKGROUND, gcv);
	xcb_rectangle_t r = { 0, 0, 1, 1 };
	xcb_poly_fill_rectangle(c, blank, gc, 1, &r);
	xcb_cursor_t hidden = xcb_generate_id(c);
	xcb_create_cursor(c, hidden, blank, blank, 0, 0, 0, 0, 0, 0, 0, 0);

	xcb_window_t win = xcb_generate_id(c);
	/* A background pixel, so the X server paints the window and XWayland has a
	 * buffer to commit: a window that never draws never maps, and a surface
	 * that never maps cannot hold pointer focus, which is what activates a
	 * constraint. Attribute order follows the mask bits. */
	uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK | XCB_CW_CURSOR;
	uint32_t values[] = {
		screen->black_pixel,
		XCB_EVENT_MASK_POINTER_MOTION | XCB_EVENT_MASK_BUTTON_PRESS |
			XCB_EVENT_MASK_KEY_PRESS | XCB_EVENT_MASK_STRUCTURE_NOTIFY |
			XCB_EVENT_MASK_FOCUS_CHANGE,
		hidden,
	};
	xcb_create_window(c, XCB_COPY_FROM_PARENT, win, screen->root,
		0, 0, 400, 300, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
		screen->root_visual, mask, values);

	const char *name = "kiln-lock";
	xcb_change_property(c, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_NAME,
		XCB_ATOM_STRING, 8, strlen(name), name);
	/* WM_CLASS is instance\0class\0: the fact a client rule matches on. */
	const char cls[] = "kiln-lock\0kiln-lock";
	xcb_change_property(c, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_CLASS,
		XCB_ATOM_STRING, 8, sizeof(cls) - 1, cls);

	xcb_map_window(c, win);
	xcb_flush(c);

	bool grabbed = false;
	int motions = 0;
	xcb_generic_event_t *ev;
	while ((ev = xcb_wait_for_event(c)) != NULL) {
		switch (ev->response_type & 0x7f) {
		case XCB_MAP_NOTIFY:
		case XCB_ENTER_NOTIFY:
		case XCB_FOCUS_IN:
			/* Grab once the window is up: the pointer belongs to this client
			 * now, cursor hidden, exactly as a game takes it for mouselook. */
			if (!grabbed) {
				xcb_grab_pointer_reply_t *reply = xcb_grab_pointer_reply(c,
					xcb_grab_pointer(c, 0, win,
						XCB_EVENT_MASK_POINTER_MOTION |
							XCB_EVENT_MASK_BUTTON_PRESS |
							XCB_EVENT_MASK_BUTTON_RELEASE,
						XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC,
						win, hidden, XCB_CURRENT_TIME),
					NULL);
				grabbed = reply != NULL &&
					reply->status == XCB_GRAB_STATUS_SUCCESS;
				free(reply);
				printf("LOCKFIX grab=%s\n", grabbed ? "ok" : "failed");
				fflush(stdout);
			}
			break;
		case XCB_MOTION_NOTIFY: {
			xcb_motion_notify_event_t *m = (xcb_motion_notify_event_t *)ev;
			motions++;
			/* One line per event: under a lock these are the deltas the game
			 * lives on, arriving while the compositor's cursor stands still. */
			printf("LOCKFIX motions=%d at=%d,%d\n", motions,
				m->event_x, m->event_y);
			fflush(stdout);
			break;
		}
		default:
			break;
		}
		free(ev);
	}
	xcb_disconnect(c);
	return 0;
}
