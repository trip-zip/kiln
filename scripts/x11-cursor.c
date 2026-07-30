/* Test fixture: print the cursor image the X server currently holds, so the
 * cursor battery (scripts/cursor-test.sh) can assert what the compositor
 * actually handed the output. Built only when -Dxwayland is enabled (it needs
 * no XWayland, just the same xcb this tree already links), never installed.
 *
 *   ./build/x11-cursor            (on the OUTER display, the Xvfb kiln nests in)
 *
 * kiln runs on the wlroots X11 backend for these tests, and that backend sets
 * the cursor as a real X cursor on its window: XFixes hands back the very
 * pixels, at the very size, the compositor chose. That size is the whole "no
 * blur" claim: an xcursor theme loaded at the output's scale yields a raster
 * that grew with the scale, not a base-size raster stretched to fit.
 */
#include <stdio.h>
#include <stdlib.h>
#include <xcb/xcb.h>
#include <xcb/xfixes.h>

int main(void) {
	xcb_connection_t *c = xcb_connect(NULL, NULL);
	if (xcb_connection_has_error(c)) {
		fprintf(stderr, "x11-cursor: no X display\n");
		return 1;
	}
	/* XFixes must be negotiated before GetCursorImage is legal. */
	free(xcb_xfixes_query_version_reply(c,
		xcb_xfixes_query_version(c, 4, 0), NULL));

	xcb_xfixes_get_cursor_image_reply_t *img =
		xcb_xfixes_get_cursor_image_reply(c,
			xcb_xfixes_get_cursor_image(c), NULL);
	if (img == NULL) {
		fprintf(stderr, "x11-cursor: no cursor image\n");
		xcb_disconnect(c);
		return 1;
	}
	printf("w=%u h=%u hot=%u,%u\n", img->width, img->height,
		img->xhot, img->yhot);
	free(img);
	xcb_disconnect(c);
	return 0;
}
