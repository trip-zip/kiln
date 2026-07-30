/* Test fixture: send an X11 window-state request, the thing an X client does
 * when it asks the WM to fullscreen, maximize, or minimize it. Built only when
 * -Dxwayland is enabled, never installed.
 *
 * The request-family batteries (scripts/activate-test.sh,
 * scripts/fullscreen-test.sh) need each of those three asks driven on demand,
 * both on and off. Firefox raises the fullscreen one itself (F11), but nothing
 * on the box asks for the other two to order:
 * xdotool's windowstate never reaches the WM, and no app self-maximizes or
 * un-minimizes when told to. Hence this.
 *
 *   ./build/x11-state <window-id> fullscreen|maximize|minimize on|off
 *
 * The window id is what xdotool search prints (decimal, or 0x hex). Fullscreen
 * and maximize go out as _NET_WM_STATE client messages to the root window, the
 * EWMH ask; minimize as WM_CHANGE_STATE (ICCCM iconic/normal), which is the one
 * X11 way to ask for un-minimize and the reason the minimize payload carries a
 * bool at all.
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xcb/xcb.h>
#include <xcb/xcb_icccm.h>

#define NET_WM_STATE_REMOVE 0
#define NET_WM_STATE_ADD 1

static xcb_atom_t intern(xcb_connection_t *c, const char *name) {
	xcb_intern_atom_reply_t *r = xcb_intern_atom_reply(
		c, xcb_intern_atom(c, 0, strlen(name), name), NULL);
	xcb_atom_t a = r != NULL ? r->atom : XCB_ATOM_NONE;
	free(r);
	return a;
}

/* Both message kinds go to the root with SUBSTRUCTURE_NOTIFY|REDIRECT, which is
 * what makes the WM (and only the WM) see them. */
static void send_to_root(xcb_connection_t *c, xcb_screen_t *s, xcb_window_t win,
		xcb_atom_t type, const uint32_t data[5]) {
	xcb_client_message_event_t ev = {
		.response_type = XCB_CLIENT_MESSAGE,
		.format = 32,
		.window = win,
		.type = type,
	};
	memcpy(ev.data.data32, data, sizeof(uint32_t) * 5);
	xcb_send_event(c, 0, s->root,
		XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT,
		(const char *)&ev);
	xcb_flush(c);
}

int main(int argc, char **argv) {
	if (argc != 4) {
		fprintf(stderr, "usage: x11-state <window-id> "
			"fullscreen|maximize|minimize on|off\n");
		return 1;
	}
	xcb_window_t win = (xcb_window_t)strtoul(argv[1], NULL, 0);
	const char *state = argv[2];
	bool on = strcmp(argv[3], "on") == 0;

	xcb_connection_t *c = xcb_connect(NULL, NULL);
	if (xcb_connection_has_error(c)) {
		fprintf(stderr, "x11-state: cannot connect to X (is DISPLAY set?)\n");
		return 1;
	}
	xcb_screen_t *s = xcb_setup_roots_iterator(xcb_get_setup(c)).data;

	if (strcmp(state, "minimize") == 0) {
		/* ICCCM: iconify is a state request, and NormalState is how a taskbar
		 * asks for the window back. */
		uint32_t data[5] = {
			on ? XCB_ICCCM_WM_STATE_ICONIC : XCB_ICCCM_WM_STATE_NORMAL,
			0, 0, 0, 0,
		};
		send_to_root(c, s, win, intern(c, "WM_CHANGE_STATE"), data);
	} else {
		xcb_atom_t p1 = XCB_ATOM_NONE, p2 = XCB_ATOM_NONE;
		if (strcmp(state, "fullscreen") == 0) {
			p1 = intern(c, "_NET_WM_STATE_FULLSCREEN");
		} else if (strcmp(state, "maximize") == 0) {
			/* EWMH maximizes per axis; both is the ask a maximize button makes. */
			p1 = intern(c, "_NET_WM_STATE_MAXIMIZED_VERT");
			p2 = intern(c, "_NET_WM_STATE_MAXIMIZED_HORZ");
		} else {
			fprintf(stderr, "x11-state: unknown state '%s'\n", state);
			return 1;
		}
		/* Source indication 2 (pager): a request made on the user's behalf. */
		uint32_t data[5] = {
			on ? NET_WM_STATE_ADD : NET_WM_STATE_REMOVE, p1, p2, 2, 0,
		};
		send_to_root(c, s, win, intern(c, "_NET_WM_STATE"), data);
	}

	/* Round trip before disconnecting: a flush only hands the request to the
	 * socket, and a connection that closes behind it can have its SendEvent
	 * dropped before the server acts on it. Asking for a reply proves the
	 * server processed everything queued ahead of it. */
	free(xcb_get_input_focus_reply(c, xcb_get_input_focus(c), NULL));

	printf("x11-state: 0x%x %s %s\n", win, state, on ? "on" : "off");
	xcb_disconnect(c);
	return 0;
}
