#ifndef KILN_UI_H
#define KILN_UI_H

#include <cairo.h>
#include <pango/pango.h>
#include <stdbool.h>
#include <stdint.h>

struct core;
struct wl_display;
struct wlr_output;
struct wlr_output_layout;
struct wlr_scene_tree;

struct ui;
struct ui_output;

struct ui *ui_create(struct wl_display *display,
	struct wlr_scene_tree *parent, struct wlr_output_layout *output_layout);
void ui_destroy(struct ui *ui);

struct ui_output *ui_output_create(struct ui *ui, struct wlr_output *wlr_output);
void ui_output_destroy(struct ui_output *uo);

/* Called from the output frame handler; solves and reconciles only if dirty.
 * lock_active is kiln.c's lock owner fact, derived at the call (native lock
 * up), never stored on this side of the boundary: it picks the lockscreen
 * solve over the desktop solve for this frame. */
void ui_output_frame(struct ui_output *uo, bool lock_active);
void ui_output_mark_dirty(struct ui_output *uo);
void ui_mark_all_dirty(struct ui *ui);
bool ui_mark_dirty_name(struct ui *ui, const char *name);

/* The Lua core that owns the frame handler; set once at startup. */
void ui_set_core(struct ui *ui, struct core *core);

/* The topmost lock band, set once at startup: the native lockscreen
 * reconciles into it, above the C opaque floor. */
void ui_set_lock_tree(struct ui *ui, struct wlr_scene_tree *lock_tree);

/* Show or hide the retained native-lockscreen render trees (kiln.c, on a
 * native lock engage/disengage), and dirty every output for the solve swap.
 * Which solve a frame runs is not stored here; it rides ui_output_frame. */
void ui_set_lock_visible(struct ui *ui, bool visible);

/* How the renderer reaches client scene trees; implemented by kiln.c and
 * set once at startup, before any output exists. */
struct render_client_hooks;
void ui_set_client_hooks(struct ui *ui,
	const struct render_client_hooks *hooks);

/* Pointer query against the last solved layout of one screen, in layout
 * coordinates. Fills out with up to max element ids under the point,
 * topmost first, and returns the count. */
struct ui_hit {
	const char *name;
	int32_t name_len;
	uint32_t index;
};
int ui_hits(struct ui *ui, const char *screen, double lx, double ly,
	struct ui_hit *out, int max);

/* Dev-only agreement sample (KILN_AGREE): asserts the scene and Clay name
 * the same chrome leaf at the layout point, aborting on divergence. Skips
 * points that resolve to a client surface (scene overrides Clay there). */
void ui_agreement_sample(struct ui *ui, const char *screen,
	double lx, double ly);

/* The Clay debug inspector. Clay ships the whole panel; what only C
 * can do is flip the per-context flag, write Clay's style globals, and feed
 * Clay's cross-call pointer edge machine so the panel's own click and wheel
 * handling (which runs INSIDE Clay_EndLayout) sees a seat. Which screen
 * toggles, which key binds it and which wheel events route there is Lua's.
 *
 * Desktop contexts only: the lock context is never touched, so a lockscreen
 * can never be inspected or narrowed.
 *
 * The state of record is Clay's own debugModeEnabled, not a copy here: the
 * panel can close itself from inside the solver, and any copy would be wrong
 * the moment it did. C keeps one counter, and only as a cheap gate on the
 * per-motion mirror below; it is resynced wherever a self-close is observable. */
bool ui_inspector_enabled(struct ui *ui, const char *screen);
bool ui_inspector_set(struct ui *ui, const char *screen, bool on);

/* Clay's debug style lives in plain process-wide globals,
 * not per screen: these write those globals and mark every debug-enabled output
 * dirty, so a restyle shows without another toggle. rgba is 0-255. */
enum ui_inspector_color {
	UI_INSPECTOR_COLOR_1,        /* the panel's four base colors */
	UI_INSPECTOR_COLOR_2,
	UI_INSPECTOR_COLOR_3,
	UI_INSPECTOR_COLOR_4,
	UI_INSPECTOR_COLOR_SELECTED, /* the selected tree row */
	UI_INSPECTOR_COLOR_HIGHLIGHT,/* the hovered-element overlay in the scene */
};
void ui_inspector_set_color(struct ui *ui, enum ui_inspector_color which,
	const float rgba[4]);
void ui_inspector_set_width(struct ui *ui, float width);

/* Wheel over the panel: accumulate a delta for the next solve to apply, and
 * read back the tree pane's y offset. Accumulating rather than applying is not
 * a nicety: Clay_UpdateScrollContainers purges every scroll container that has
 * not been declared since the last call, so it may run exactly once per solve,
 * which is what the solve path does with whatever is accumulated here. */
void ui_inspector_scroll(struct ui *ui, const char *screen, double dx, double dy);
double ui_inspector_scroll_offset(struct ui *ui, const char *screen);

/* The seat mirror, called from kiln.c's motion and button handlers. Stores
 * facts only: down is 1, 0, or -1 for "unchanged" (motion), and press_edge
 * latches a press that the next solve must turn into Clay's PRESSED_THIS_FRAME.
 * No policy, and a no-op while no screen has the inspector up. */
void ui_inspector_input(struct ui *ui, double lx, double ly,
	int down, bool press_edge);

/* core.font(desc): intern a Pango font description into the font table,
 * returning the id a text declaration carries as fontId, so a config names a
 * face in the string form Pango parses and never handles the integer Clay
 * actually carries. Ids are write-once, so one stays safe to hold for as long as
 * the process lives.
 *
 * Crossed by the FFI directly rather than through a kiln_* wrapper in core.h:
 * there is no core to reach and nothing to marshal, so a wrapper would have been
 * naming convention with a function call attached. No length argument either,
 * because Pango wants the NUL a Lua string already carries, not a count.
 *
 * Negative is a refusal:
 *
 *   UI_FONT_ERR_SIZE  the description carries a size, which would be silently
 *                     overridden because size is its own channel, set at the
 *                     output's device scale per call.
 *   UI_FONT_ERR_FULL  the table is at its cap.
 *
 * A family no font on the system provides is not a refusal; Pango substitutes,
 * which keeps a typo a visual bug instead of a dead session. */
#define UI_FONT_ERR_SIZE (-1)
#define UI_FONT_ERR_FULL (-2)
int32_t ui_font_intern(const char *name);

/* Flags a text declaration carries through Clay's per-element userData, which is
 * documented as passed through untouched to the render command and is not part
 * of the measure cache key. A flag word in a pointer slot because that slot is
 * the only channel from a text declaration to the renderer that Clay leaves to
 * its host: everything else on a text config has a meaning Clay assigns. */
#define UI_TEXT_ELLIPSIZE 1u

/* Shared font and text setup so measurement and rasterization agree, on every
 * axis that decides a glyph run's extent. font_id resolves through the font
 * table above, and is in this signature rather than read from somewhere both
 * callers reach so that a face reaching one path and not the other is a compile
 * error: it would otherwise show up as text wrapping where it does not draw.
 * scale is the output's scale, and the font is set at device size (font_size *
 * scale) so measurement and the raster both work in device pixels, which is
 * what keeps a fractional output's text sharp and its wrap decisions matching
 * the raster.
 *
 * max_width is a device-pixel bound past which the run is truncated with an
 * ellipsis, or 0 for none. It is in this signature for the same reason font_id
 * is, and the measure path is the caller that must always pass 0: a measure
 * bounded by the same number the bound is derived FROM would shrink the box, and
 * a smaller box means a tighter bound, which is a run that truncates itself away
 * over a few frames. */
void ui_set_text(PangoLayout *layout, const char *text, int len,
	uint16_t font_id, uint16_t font_size, float scale, int max_width);

/* The image cache: one entry per path, decoded once (gdk-pixbuf) to a cairo
 * surface the renderer scales and rounds into the solved box. The entry
 * pointer is stable for the process (it is what Clay carries as imageData
 * across the solve); only its contents change on reload. gen bumps on every
 * successful (re)decode so the renderer knows to re-raster.
 *
 * Decoded pixels live under a byte budget, enforced after every decode
 * and again at the end of every solve: least-recently-declared surfaces are
 * dropped (pixels only; the entry struct stays, preserving pointer
 * stability) and re-decode on their next declare. Entries declared by the in-progress solve are never
 * dropped, so a live command's native pointer stays valid through its
 * reconcile. bytes is the decoded surface size; touch is the solve clock of
 * the last declare that asked for the entry. */
struct image_entry {
	char *path;
	cairo_surface_t *native;
	int width, height;
	uint64_t gen;
	size_t bytes;
	uint64_t touch;
	bool decoded, failed;
};

/* Resolves path to its stable cache entry, decoding on first sight. Never
 * stats an already-cached path (the declare pass stays I/O free). */
struct image_entry *ui_image_get(struct ui *ui, const char *path);

/* Puts already-decoded pixels in the cache under a key, for images that arrive
 * in a message rather than on disk: the notify image-data hint, and the tray
 * icons after it. The pixel layout is the hint's own (iiibiiay: width, height,
 * rowstride, has_alpha, bits_per_sample, channels, data), which is gdk-pixbuf's
 * layout, so the caller forwards it verbatim and owns nothing afterwards.
 * false if the message's own numbers do not describe the buffer it sent.
 *
 * The key is not a path and never resolves to one (it is "notify:<id>"), which
 * makes the entry unre-decodable: an eviction is permanent and the leaf renders
 * blank. That is the existing failed-entry path, and it is not reachable for a
 * displayed image, since eviction claims the least-recently-DECLARED pixels. */
bool ui_image_put(struct ui *ui, const char *key, int width, int height,
	int rowstride, bool has_alpha, int bits_per_sample, int channels,
	const uint8_t *pixels, size_t pixels_len);

/* Writes a cached entry's decoded surface to a PNG at path. Used by
 * core.screenshot's optional save leg: the readback is already in the cache
 * under its key, so a save is one cairo call over that surface. false if the
 * key is absent or undecoded, or cairo could not write the file. */
bool ui_image_save(struct ui *ui, const char *key, const char *path);

/* Drops the decoded surface so the next ui_image_get re-decodes and bumps gen.
 * The only invalidation there is; nothing implicit. */
void ui_image_reload(struct ui *ui, const char *path);

#endif
