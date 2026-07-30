/* The Clay binding: one Clay_Context per output with its own arena and a
 * Pango measure callback. Solves run only when an output is dirty; the tree
 * itself is declared by the Lua frame handler through core.*. Text
 * measurement is cached by Clay itself: the context keeps a cross-frame
 * hash of measured words with generational eviction, so the callback only
 * runs on misses and must stay pure, callable at any point in a solve. */

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <pango/pangocairo.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/util/log.h>

#include "clay.h"
#include "core.h"
#include "render.h"
#include "ui.h"

/* Entry 0 of the font table, and the face a declaration naming none gets.
 * Clay passes fontId 0 for its debug view's own text, so entry 0 has to name a
 * face that exists whatever a config does with the rest of the table. */
#define UI_FONT_FAMILY "Sans"

/* The font table's cap. An interned face is never evicted and its id never
 * reused, so this is what bounds a config building description strings in a
 * loop instead of naming a fixed set: past it interning refuses and Lua raises.
 */
#define UI_MAX_FONTS 64

/* Far above any tree declared today. Sized
 * generously so the stress harness can push node counts up (the arena scales
 * with this, ~24 MB per output at this cap; unused elements cost nothing). */
#define UI_MAX_ELEMENTS 32768

/* Default image decode budget, MB. Two panel-sized wallpapers plus icon
 * change; a working set larger than the budget stays correct but re-decodes
 * per frame. KILN_IMAGE_BUDGET_MB overrides. */
#define UI_IMAGE_BUDGET_MB 64

struct ui {
	struct wlr_scene_tree *tree;
	/* The topmost lock band. While natively locked, each output
	 * solves its lockscreen into a dedicated Clay context reconciled here,
	 * above the C opaque floor, instead of the desktop tree. Set once at
	 * startup; NULL leaves the native lockscreen unavailable. */
	struct wlr_scene_tree *lock_tree;
	struct wlr_output_layout *output_layout;
	struct core *core;
	struct render_client_hooks client_hooks;
	struct wl_listener layout_change;
	struct wl_list outputs;
	PangoContext *pango;
	PangoLayout *measure_layout;
	/* The scale of the output currently solving, published before each Clay pass
	 * so the shared measure callback (userData is this ui, not an output) measures
	 * text at that output's device size. Reset to that output's scale every solve. */
	float measure_scale;
	uint64_t solve_count;
	/* The path-keyed image cache. Entries are heap-stable for the process
	 * (Clay carries their addresses as imageData), so this holds pointers.
	 * Decoded bytes are budgeted: image_bytes tracks the resident
	 * total, image_clock advances per solve and stamps entry->touch, and
	 * eviction drops the least-recently-declared pixels once a decode
	 * overruns image_budget. */
	struct image_entry **images;
	size_t images_len, images_cap;
	size_t image_bytes, image_budget;
	uint64_t image_clock;
	/* The Clay debug inspector's seat mirror. The facts are seat-wide,
	 * so they live here and not per output: one cursor, one button. insp_have_pos
	 * is what separates "the cursor is at 0,0" from "no seat has ever said";
	 * with no input device at all (the headless backend) the solve path must not
	 * force a position it was never told, or it would move Clay's pointer off
	 * whatever a core.hits query put it on.
	 *
	 * inspector_on_count is a gate, not a state: it exists so the per-motion
	 * mirror costs a comparison while the inspector is down. Clay's own
	 * debugModeEnabled is the state of record, and this is resynced from it
	 * wherever a self-close is observable. */
	size_t inspector_on_count;
	double insp_x, insp_y;
	bool insp_have_pos, insp_down;
};

struct ui_output {
	struct wl_list link;
	struct ui *ui;
	struct wlr_output *wlr_output;
	Clay_Context *clay;
	void *arena_memory;
	struct render_state *render;
	bool dirty;
	/* The native lockscreen's per-output context, lazily created on first
	 * native lock and reconciled into ui->lock_tree. Separate from the desktop
	 * context so a lock-declare error keeps only the last lock frame (the
	 * opaque floor covers any gap), never the desktop. */
	Clay_Context *lock_clay;
	void *lock_arena_memory;
	struct render_state *lock_render;
	/* The inspector's per-output latches. The press edge is latched
	 * rather than applied because Clay's PRESSED_THIS_FRAME only means anything
	 * during a layout pass, and it is per output because only the output under
	 * the cursor should be told a button went down there. The scroll delta
	 * accumulates for the same reason the press latches: it can only be handed
	 * to Clay once per solve. */
	bool insp_press_pending;
	double insp_scroll_x, insp_scroll_y;
};

/* The font table. Clay carries a fontId and nothing else, so resolving one to a
 * face is the renderer's job and this is where that happens.
 *
 * File-static rather than a field of struct ui because rasterize_text is handed
 * a render command and a scale and has no ui to reach, and the measure and the
 * raster have to resolve an id the same way or text wraps where it does not
 * draw.
 *
 * Ids are write-once: an entry is appended, never rewritten, so a live
 * declaration's id keeps meaning the face it was interned for. Rewriting one
 * would leave Clay's measure cache answering with the old face's widths for
 * good, because that cache keys on the id. */
static struct {
	const char *name;
	PangoFontDescription *desc;
} ui_fonts[UI_MAX_FONTS];
static int ui_fonts_len;

static void ui_fonts_init(void) {
	if (ui_fonts_len > 0) {
		return;
	}
	ui_fonts[0].name = UI_FONT_FAMILY;
	ui_fonts[0].desc = pango_font_description_from_string(UI_FONT_FAMILY);
	ui_fonts_len = 1;
}

int32_t ui_font_intern(const char *name) {
	ui_fonts_init();
	for (int i = 0; i < ui_fonts_len; i++) {
		if (strcmp(ui_fonts[i].name, name) == 0) {
			return i;
		}
	}

	/* Pango's own parser is the only thing that knows what a description means,
	 * so a carried size is its set-fields mask rather than a scan for a trailing
	 * number: a family whose name ends in a digit is not a size. Refused before
	 * the cap is consulted, so a bad description names its real problem even
	 * with the table full. */
	PangoFontDescription *desc = pango_font_description_from_string(name);
	if (pango_font_description_get_set_fields(desc) & PANGO_FONT_MASK_SIZE) {
		pango_font_description_free(desc);
		return UI_FONT_ERR_SIZE;
	}
	if (ui_fonts_len == UI_MAX_FONTS) {
		pango_font_description_free(desc);
		return UI_FONT_ERR_FULL;
	}

	ui_fonts[ui_fonts_len].name = strdup(name);
	ui_fonts[ui_fonts_len].desc = desc;
	return ui_fonts_len++;
}

void ui_set_text(PangoLayout *layout, const char *text, int len,
		uint16_t font_id, uint16_t font_size, float scale, int max_width) {
	ui_fonts_init();
	/* An id past the table resolves to entry 0 rather than aborting: the id is
	 * whatever a declaration put in the field, and Clay's debug view writes 0
	 * into it without interning anything. */
	PangoFontDescription *desc = font_id < ui_fonts_len
		? ui_fonts[font_id].desc : ui_fonts[0].desc;
	pango_font_description_set_absolute_size(desc,
		(double)font_size * scale * PANGO_SCALE);
	pango_layout_set_font_description(layout, desc);

	/* Both set unconditionally, because the measure layout is reused across
	 * every leaf on the output: a bound left behind by the previous call would
	 * truncate the next run. Unbounded is Pango's -1 rather than 0, which is a
	 * layout zero pixels wide. Where the cut lands is Pango's to choose, since
	 * only it knows where a cluster ends. */
	pango_layout_set_width(layout,
		max_width > 0 ? max_width * PANGO_SCALE : -1);
	pango_layout_set_ellipsize(layout,
		max_width > 0 ? PANGO_ELLIPSIZE_END : PANGO_ELLIPSIZE_NONE);
	pango_layout_set_text(layout, text, len);
}

static Clay_Dimensions ui_measure_text(Clay_StringSlice text,
		Clay_TextElementConfig *config, void *user_data) {
	struct ui *ui = user_data;
	float scale = ui->measure_scale > 0.0f ? ui->measure_scale : 1.0f;

	/* Measure at device size, report logical: Pango rounds glyph advances to
	 * whole DEVICE pixels, so dividing the device extent by scale hands Clay the
	 * exact logical size the raster will reproduce (rasterize_text uses the same
	 * device font size). Wrap and box sizing then match the raster to the pixel.
	 *
	 * Never bounded, whatever the declaration asked for: what a truncated run is
	 * bounded BY is derived from the box this measurement produces, so bounding
	 * the measurement too would feed that derivation its own output. */
	ui_set_text(ui->measure_layout, text.chars, text.length,
		config->fontId, config->fontSize, scale, 0);
	int width, height;
	pango_layout_get_pixel_size(ui->measure_layout, &width, &height);

	return (Clay_Dimensions) { .width = width / scale, .height = height / scale };
}

/* --- Clay context lifecycle --- */

static void ui_handle_clay_error(Clay_ErrorData error) {
	/* Abort mode is on kiln-wide: a Clay error (including render
	 * command array overflow) is a bug, not a condition to ride out. */
	wlr_log(WLR_ERROR, "clay error %d: %.*s", error.errorType,
		error.errorText.length, error.errorText.chars);
	abort();
}

struct ui_output *ui_output_create(struct ui *ui, struct wlr_output *wlr_output) {
	struct ui_output *uo = calloc(1, sizeof(*uo));
	uo->ui = ui;
	uo->wlr_output = wlr_output;

	int width, height;
	wlr_output_effective_resolution(wlr_output, &width, &height);

	uint32_t arena_size = Clay_MinMemorySize();
	uo->arena_memory = malloc(arena_size);
	Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(
		arena_size, uo->arena_memory);
	uo->clay = Clay_Initialize(arena,
		(Clay_Dimensions) { .width = width, .height = height },
		(Clay_ErrorHandler) { .errorHandlerFunction = ui_handle_clay_error });
	/* The measure function pointer is global in Clay, but the userData is
	 * stored on the current context, so set it once per context. */
	Clay_SetMeasureTextFunction(ui_measure_text, ui);

	uo->render = render_create(ui->tree);
	wl_list_insert(&ui->outputs, &uo->link);
	ui_output_mark_dirty(uo);
	return uo;
}

void ui_output_destroy(struct ui_output *uo) {
	/* The Clay_Context lives inside the arena being freed. Clay keeps a
	 * global current-context pointer; left dangling, the next
	 * Clay_MinMemorySize or Clay_Initialize would read freed memory. */
	if (Clay_GetCurrentContext() == uo->clay ||
			(uo->lock_clay != NULL &&
				Clay_GetCurrentContext() == uo->lock_clay)) {
		Clay_SetCurrentContext(NULL);
	}
	wl_list_remove(&uo->link);
	render_destroy(uo->render, &uo->ui->client_hooks);
	free(uo->arena_memory);
	if (uo->lock_clay != NULL) {
		render_destroy(uo->lock_render, &uo->ui->client_hooks);
		free(uo->lock_arena_memory);
	}
	free(uo);
}

void ui_output_mark_dirty(struct ui_output *uo) {
	uo->dirty = true;
	wlr_output_schedule_frame(uo->wlr_output);
}

void ui_mark_all_dirty(struct ui *ui) {
	struct ui_output *uo;
	wl_list_for_each(uo, &ui->outputs, link) {
		ui_output_mark_dirty(uo);
	}
}

static struct ui_output *ui_output_by_name(struct ui *ui, const char *name) {
	struct ui_output *uo;
	wl_list_for_each(uo, &ui->outputs, link) {
		if (strcmp(uo->wlr_output->name, name) == 0) {
			return uo;
		}
	}
	return NULL;
}

bool ui_mark_dirty_name(struct ui *ui, const char *name) {
	struct ui_output *uo = ui_output_by_name(ui, name);
	if (uo != NULL) {
		ui_output_mark_dirty(uo);
		return true;
	}
	return false;
}

void ui_set_core(struct ui *ui, struct core *core) {
	ui->core = core;
}

void ui_set_lock_tree(struct ui *ui, struct wlr_scene_tree *lock_tree) {
	ui->lock_tree = lock_tree;
}

/* kiln.c calls this on a native lock engage/disengage. Marking every output
 * dirty forces the swap between the desktop solve and the lockscreen solve;
 * which of the two a frame runs is not stored here, it arrives per frame
 * through ui_output_frame from kiln.c's lock owner, the one authority.
 *
 * The lock render tree is hidden whenever the native lockscreen is not the one
 * drawing. Its nodes are retained, not dropped, so they would otherwise still be
 * sitting in the band the next time anything raises it: an EXTERNAL lock (which
 * has no native content of its own) would flash the previous lockscreen until
 * its own surface committed over the top. */
void ui_set_lock_visible(struct ui *ui, bool visible) {
	struct ui_output *uo;
	wl_list_for_each(uo, &ui->outputs, link) {
		if (uo->lock_render != NULL) {
			render_set_enabled(uo->lock_render, visible);
		}
	}
	ui_mark_all_dirty(ui);
}

void ui_set_client_hooks(struct ui *ui,
		const struct render_client_hooks *hooks) {
	ui->client_hooks = *hooks;
}

int ui_hits(struct ui *ui, const char *screen, double lx, double ly,
		struct ui_hit *out, int max) {
	struct ui_output *uo = ui_output_by_name(ui, screen);
	if (uo == NULL) {
		return 0;
	}

	double ox = lx, oy = ly;
	wlr_output_layout_output_coords(ui->output_layout, uo->wlr_output,
		&ox, &oy);

	Clay_SetCurrentContext(uo->clay);
	Clay_SetPointerState((Clay_Vector2) { .x = ox, .y = oy }, false);
	Clay_ElementIdArray ids = Clay_GetPointerOverIds();

	/* Clay lists ancestors first; reverse so the innermost element is
	 * first, which is the natural dispatch order. */
	int count = 0;
	for (int32_t i = ids.length - 1; i >= 0 && count < max; i--) {
		Clay_ElementId *id = &ids.internalArray[i];
		out[count].name = id->stringId.chars;
		out[count].name_len = id->stringId.length;
		out[count].index = id->offset;
		count++;
	}
	return count;
}

/* Check 3 of the agreement invariant, sampled on motion (dev only). The scene
 * is the single hit authority; this asserts it agrees with Clay over chrome:
 * the topmost chrome leaf the scene shows at the point must be an element Clay
 * also reports covering it. A point resolving to a client surface is
 * arbitration territory (the scene overrides Clay there by design, e.g. a
 * client popup overhanging its box) and is skipped. Set membership, not strict
 * innermost equality, bridges the render-command-vs-layout-element id
 * granularity (a text leaf, a border side): every element carries a hashmap
 * item, so its id is in pointerOverIds when the point is in its box. A genuine
 * z/clip/passthrough divergence (the scene showing a node Clay does not place
 * at the point) is not a member, and aborts. */
void ui_agreement_sample(struct ui *ui, const char *screen,
		double lx, double ly) {
	struct ui_output *uo = ui_output_by_name(ui, screen);
	if (uo == NULL) {
		return;
	}

	/* Scene side: ui->tree sits at the layout origin, so the layout point is
	 * already in its coordinate space. It holds chrome and placed client
	 * surfaces, the whole arbitration surface. */
	double nx, ny;
	struct wlr_scene_node *node = wlr_scene_node_at(
		&ui->tree->node, lx, ly, &nx, &ny);
	if (node != NULL && node->type == WLR_SCENE_NODE_BUFFER) {
		struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(node);
		if (wlr_scene_surface_try_from_buffer(sb) != NULL) {
			return;
		}
	}
	uint32_t scene_id = render_hit_id(uo->render, node);
	if (scene_id == 0) {
		return;
	}

	/* Clay side: the same point, output-local, like ui_hits. */
	double ox = lx, oy = ly;
	wlr_output_layout_output_coords(ui->output_layout, uo->wlr_output,
		&ox, &oy);
	Clay_SetCurrentContext(uo->clay);
	Clay_SetPointerState((Clay_Vector2) { .x = ox, .y = oy }, false);
	Clay_ElementIdArray ids = Clay_GetPointerOverIds();
	for (int32_t i = 0; i < ids.length; i++) {
		if (ids.internalArray[i].id == scene_id) {
			return;
		}
	}
	/* Divergence: abort like the other invariants (abort mode is on
	 * kiln-wide). Log the full picture first (layout and output-local coords,
	 * the scene leaf id, and Clay's whole id chain) so the mismatch is
	 * diagnosable. */
	char idbuf[256];
	int off = 0;
	for (int32_t i = 0; i < ids.length && off < (int)sizeof(idbuf) - 12; i++) {
		off += snprintf(idbuf + off, sizeof(idbuf) - off, "%08x ",
			ids.internalArray[i].id);
	}
	if (ids.length == 0) {
		snprintf(idbuf, sizeof(idbuf), "(none)");
	}
	wlr_log(WLR_ERROR, "agreement: scene id %08x at layout %.0f,%.0f "
		"local %.0f,%.0f on %s; clay ids: %s",
		scene_id, lx, ly, ox, oy, screen, idbuf);
	abort();
}

/* --- the Clay debug inspector: flag, style globals, pointer feed --- */

/* The debug palette is plain globals with external linkage that the vendored
 * header never declares in its header section, so name them here; these
 * externs must match those definitions exactly. The panel width and the
 * highlight color are declared upstream and used as-is. */
extern Clay_Color CLAY__DEBUGVIEW_COLOR_1;
extern Clay_Color CLAY__DEBUGVIEW_COLOR_2;
extern Clay_Color CLAY__DEBUGVIEW_COLOR_3;
extern Clay_Color CLAY__DEBUGVIEW_COLOR_4;
extern Clay_Color CLAY__DEBUGVIEW_COLOR_SELECTED_ROW;

/* Recount from Clay, which is the state of record. The panel closes itself from
 * inside the solver, so the counter is never authoritative and is only ever
 * derived. Saves and restores the current context: callers run mid-solve. */
static void ui_inspector_resync(struct ui *ui) {
	Clay_Context *previous = Clay_GetCurrentContext();
	size_t count = 0;
	struct ui_output *uo;
	wl_list_for_each(uo, &ui->outputs, link) {
		Clay_SetCurrentContext(uo->clay);
		if (Clay_IsDebugModeEnabled()) {
			count++;
		}
	}
	ui->inspector_on_count = count;
	Clay_SetCurrentContext(previous);
}

bool ui_inspector_enabled(struct ui *ui, const char *screen) {
	struct ui_output *uo = ui_output_by_name(ui, screen);
	if (uo == NULL) {
		return false;
	}
	Clay_SetCurrentContext(uo->clay);
	return Clay_IsDebugModeEnabled();
}

bool ui_inspector_set(struct ui *ui, const char *screen, bool on) {
	struct ui_output *uo = ui_output_by_name(ui, screen);
	if (uo == NULL) {
		return false;
	}
	/* uo->clay, never uo->lock_clay: the lockscreen has its own context and
	 * inspecting it would narrow the thing covering the desktop. */
	Clay_SetCurrentContext(uo->clay);
	Clay_SetDebugModeEnabled(on);
	ui_output_mark_dirty(uo);
	ui_inspector_resync(ui);
	Clay_SetCurrentContext(uo->clay);
	return Clay_IsDebugModeEnabled();
}

/* Clay's debug style is process-global, so a write is not addressed to a
 * screen; every output already showing the panel needs a solve to pick it up. */
static void ui_inspector_restyled(struct ui *ui) {
	Clay_Context *previous = Clay_GetCurrentContext();
	struct ui_output *uo;
	wl_list_for_each(uo, &ui->outputs, link) {
		Clay_SetCurrentContext(uo->clay);
		if (Clay_IsDebugModeEnabled()) {
			ui_output_mark_dirty(uo);
		}
	}
	Clay_SetCurrentContext(previous);
}

void ui_inspector_set_color(struct ui *ui, enum ui_inspector_color which,
		const float rgba[4]) {
	Clay_Color color = {
		.r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
	switch (which) {
	case UI_INSPECTOR_COLOR_1: CLAY__DEBUGVIEW_COLOR_1 = color; break;
	case UI_INSPECTOR_COLOR_2: CLAY__DEBUGVIEW_COLOR_2 = color; break;
	case UI_INSPECTOR_COLOR_3: CLAY__DEBUGVIEW_COLOR_3 = color; break;
	case UI_INSPECTOR_COLOR_4: CLAY__DEBUGVIEW_COLOR_4 = color; break;
	case UI_INSPECTOR_COLOR_SELECTED:
		CLAY__DEBUGVIEW_COLOR_SELECTED_ROW = color;
		break;
	case UI_INSPECTOR_COLOR_HIGHLIGHT:
		Clay__debugViewHighlightColor = color;
		break;
	}
	ui_inspector_restyled(ui);
}

void ui_inspector_set_width(struct ui *ui, float width) {
	Clay__debugViewWidth = (uint32_t)(width > 0 ? width : 0);
	ui_inspector_restyled(ui);
}

void ui_inspector_scroll(struct ui *ui, const char *screen,
		double dx, double dy) {
	struct ui_output *uo = ui_output_by_name(ui, screen);
	if (uo == NULL) {
		return;
	}
	uo->insp_scroll_x += dx;
	uo->insp_scroll_y += dy;
	ui_output_mark_dirty(uo);
}

double ui_inspector_scroll_offset(struct ui *ui, const char *screen) {
	struct ui_output *uo = ui_output_by_name(ui, screen);
	if (uo == NULL) {
		return 0;
	}
	Clay_SetCurrentContext(uo->clay);
	Clay_ScrollContainerData data = Clay_GetScrollContainerData(
		Clay_GetElementId(CLAY_STRING("Clay__DebugViewOuterScrollPane")));
	return data.found ? data.scrollPosition->y : 0;
}

void ui_inspector_input(struct ui *ui, double lx, double ly,
		int down, bool press_edge) {
	if (ui->inspector_on_count == 0) {
		return;
	}
	ui->insp_x = lx;
	ui->insp_y = ly;
	ui->insp_have_pos = true;
	if (down >= 0) {
		ui->insp_down = down != 0;
	}

	/* The press edge is latched onto the output the cursor is over, and only
	 * that one: another enabled output must not be told a button went down in
	 * a place it does not contain. */
	struct wlr_output *at = wlr_output_layout_output_at(
		ui->output_layout, lx, ly);
	if (at == NULL) {
		return;
	}
	struct ui_output *uo = ui_output_by_name(ui, at->name);
	if (uo == NULL) {
		return;
	}
	if (press_edge) {
		uo->insp_press_pending = true;
	}
	/* Motion and release both need a solve too: the hovered row, the highlight
	 * overlay and Clay's own pointer state all only move when one runs. */
	ui_output_mark_dirty(uo);
}

/* Output layout changes move outputs; every UI tree needs repositioning. */
static void ui_handle_layout_change(struct wl_listener *listener, void *data) {
	struct ui *ui = wl_container_of(listener, ui, layout_change);
	ui_mark_all_dirty(ui);
}

/* --- solve and frame control --- */

static void image_evict(struct ui *ui);

/* Monotonic microseconds, for the per-frame timing breakdown. */
static uint64_t ui_now_us(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000 + (uint64_t)ts.tv_nsec / 1000;
}

/* The native lockscreen solve: declare the Lua lock handler into this output's
 * dedicated lock context and reconcile into ui->lock_tree, above the C opaque
 * floor. A declare failure keeps the previous lock frame; the floor guarantees
 * the desktop is never revealed either way. */
static void ui_output_solve_lock(struct ui_output *uo) {
	struct ui *ui = uo->ui;
	int width, height;
	wlr_output_effective_resolution(uo->wlr_output, &width, &height);

	if (uo->lock_clay == NULL) {
		uint32_t arena_size = Clay_MinMemorySize();
		uo->lock_arena_memory = malloc(arena_size);
		Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(
			arena_size, uo->lock_arena_memory);
		uo->lock_clay = Clay_Initialize(arena,
			(Clay_Dimensions) { .width = width, .height = height },
			(Clay_ErrorHandler) {
				.errorHandlerFunction = ui_handle_clay_error });
		Clay_SetMeasureTextFunction(ui_measure_text, ui);
		uo->lock_render = render_create(ui->lock_tree);
	}

	Clay_SetCurrentContext(uo->lock_clay);
	Clay_SetLayoutDimensions(
		(Clay_Dimensions) { .width = width, .height = height });
	ui->measure_scale = uo->wlr_output->scale;
	Clay_BeginLayout();
	bool ok = core_declare_lock(ui->core, uo->wlr_output->name, width, height);
	Clay_RenderCommandArray commands = Clay_EndLayout();
	ui->solve_count++;
	if (!ok) {
		wlr_log(WLR_INFO, "lock solve #%zu on %s: declare failed, keeping "
			"previous frame", (size_t)ui->solve_count, uo->wlr_output->name);
		return;
	}

	struct wlr_output_layout_output *lo = wlr_output_layout_get(
		ui->output_layout, uo->wlr_output);
	if (lo != NULL) {
		render_set_position(uo->lock_render, lo->x, lo->y);
	}
	render_set_scale(uo->lock_render, uo->wlr_output->scale);
	render_reconcile(uo->lock_render, commands, &ui->client_hooks);
}

/* Hand Clay one solve's worth of pointer, for the debug panel only.
 *
 * Everything here is forced to an ABSOLUTE state rather than mirrored
 * incrementally, because Clay's pointer state is an edge machine driven by a
 * function that other call sites also invoke: ui_hits runs Clay_SetPointerState
 * on every core.hits, and each of those advances the machine. Since the
 * transition is a pure function of (previous state, down), two consecutive
 * calls pin any state regardless of what those queries left behind:
 * (up, down) is the only PRESSED_THIS_FRAME, (down, down) is PRESSED, and
 * (up, up) is RELEASED.
 *
 * Runs before Clay_BeginLayout, against the previous frame's tree, which is
 * what the panel's own hit testing wants: the row under the cursor and the
 * close button it may have pressed both belong to the panel it drew last time.
 *
 * With no seat position ever reported (the headless backend has no input
 * device) nothing is forced at all: there is no seat fact to force from, and
 * moving Clay's pointer to a position nobody asked for would silently override
 * whatever a core.hits query put it on.
 *
 * Returns true if a press edge was fed, which the caller must retire after
 * EndLayout. Not inside the declare/solve timing spans: this is pointer
 * bookkeeping, not layout work. */
static bool ui_inspector_feed(struct ui_output *uo, Clay_Vector2 *point) {
	struct ui *ui = uo->ui;

	/* Output-local, the same conversion ui_hits does: the seat's facts are in
	 * layout coordinates, Clay solves each output at its own origin. */
	double ox = ui->insp_x, oy = ui->insp_y;
	wlr_output_layout_output_coords(ui->output_layout, uo->wlr_output, &ox, &oy);
	*point = (Clay_Vector2) { .x = ox, .y = oy };

	bool pressed_edge = false;
	if (ui->insp_have_pos) {
		bool mine = wlr_output_layout_output_at(ui->output_layout,
			ui->insp_x, ui->insp_y) == uo->wlr_output;
		if (uo->insp_press_pending && mine) {
			Clay_SetPointerState(*point, false);
			Clay_SetPointerState(*point, true);
			uo->insp_press_pending = false;
			pressed_edge = true;
			if (!ui->insp_down) {
				/* A click short enough that the release landed before this
				 * solve. The release still has to reach Clay, or the machine
				 * sits in PRESSED and the next real press has no edge to give
				 * the panel. */
				ui_output_mark_dirty(uo);
			}
		} else if (ui->insp_down && mine) {
			Clay_SetPointerState(*point, true);
			Clay_SetPointerState(*point, true);
		} else {
			Clay_SetPointerState(*point, false);
			Clay_SetPointerState(*point, false);
		}
	}

	/* The one place kiln calls this, and at most once per solve: it drops every
	 * scroll container that has not been declared since the last call, so a
	 * second call in the same pass would purge the panel's own panes. The
	 * accumulator is what makes once enough. Clay's internal branch stays in
	 * charge (no Clay_SetExternalScrollHandlingEnabled): the panel's clips and
	 * its hovered-row math are both written against it. */
	if (uo->insp_scroll_x != 0 || uo->insp_scroll_y != 0) {
		Clay_UpdateScrollContainers(false, (Clay_Vector2) {
			.x = uo->insp_scroll_x, .y = uo->insp_scroll_y }, 0);
		uo->insp_scroll_x = 0;
		uo->insp_scroll_y = 0;
	}
	return pressed_edge;
}

static void ui_output_solve(struct ui_output *uo, bool lock_active) {
	struct ui *ui = uo->ui;

	/* While natively locked, this output draws its lockscreen instead of the
	 * desktop; the desktop tree keeps its last scene, occluded by the floor. */
	if (lock_active) {
		ui_output_solve_lock(uo);
		return;
	}

	/* Advance the image-eviction clock: entries this solve declares are
	 * stamped with the new value and exempt from eviction until it passes. */
	ui->image_clock++;

	Clay_SetCurrentContext(uo->clay);
	int width, height;
	wlr_output_effective_resolution(uo->wlr_output, &width, &height);
	Clay_SetLayoutDimensions(
		(Clay_Dimensions) { .width = width, .height = height });
	/* Publish this output's scale for the measure callback (device-size text). */
	ui->measure_scale = uo->wlr_output->scale;

	/* The debug panel is drawn by Clay inside EndLayout, so its click and wheel
	 * handling reads a pointer state that has to be in place before the pass
	 * starts. Nothing happens here while the panel is down. */
	bool inspecting = Clay_IsDebugModeEnabled();
	Clay_Vector2 insp_point = { 0 };
	bool insp_edge = inspecting && ui_inspector_feed(uo, &insp_point);

	/* Three spans: declare is the Lua frame handler building the Clay tree,
	 * solve is Clay's layout pass, reconcile is the diff into wlr_scene
	 * (text rasterization included, only on change). */
	uint64_t t0 = ui_now_us();
	Clay_BeginLayout();
	bool ok = core_declare(ui->core, uo->wlr_output->name, width, height);
	uint64_t t1 = ui_now_us();
	Clay_RenderCommandArray commands = Clay_EndLayout();
	uint64_t t2 = ui_now_us();

	if (inspecting) {
		if (insp_edge) {
			/* Retire the edge now that the pass that wanted it is over. Clay
			 * fires an element's hover handler from inside SetPointerState,
			 * BEFORE the state transition at its tail, and the panel's close
			 * button registers such a handler every frame: left standing, the
			 * next core.hits with the cursor over that button would close the
			 * panel out of nowhere. If this call itself fires that handler the
			 * press really was on the button, and EndLayout closed the panel
			 * already, so it is the same answer twice. */
			Clay_SetPointerState(insp_point, ui->insp_down);
		}
		if (!Clay_IsDebugModeEnabled()) {
			/* The panel closed itself from inside the solve. This pass laid out
			 * narrow and then emitted no panel, so one more solve is owed to
			 * give the width back, and the gate has to learn about it. */
			ui_inspector_resync(ui);
			Clay_SetCurrentContext(uo->clay);
			ui_output_mark_dirty(uo);
		}
	}

	ui->solve_count++;
	if (!ok) {
		/* Keep the last good frame on screen; the error already went to
		 * stderr from the pcall wrapper. */
		wlr_log(WLR_INFO, "solve #%zu on %s: declare failed, keeping "
			"previous frame", (size_t)ui->solve_count,
			uo->wlr_output->name);
		return;
	}

	struct wlr_output_layout_output *lo = wlr_output_layout_get(
		ui->output_layout, uo->wlr_output);
	if (lo != NULL) {
		render_set_position(uo->render, lo->x, lo->y);
	}
	render_set_scale(uo->render, uo->wlr_output->scale);
	int muts = render_reconcile(uo->render, commands, &ui->client_hooks);
	uint64_t t3 = ui_now_us();

	/* Enforce the image budget on every solve, not only at decode time: a
	 * declare that stopped mentioning images must release their pixels, or
	 * the cache is monotonic until the next unrelated decode. This solve's
	 * entries are exempt by their touch stamp; the reconcile above is done,
	 * so nothing still reads an older entry's surface. */
	image_evict(ui);

	wlr_log(WLR_INFO, "solve #%zu on %s: %d commands, %d mutations, "
		"declare=%" PRIu64 "us solve=%" PRIu64 "us reconcile=%" PRIu64 "us "
		"total=%" PRIu64 "us rnodes=%zu bufs=%d raster_kb=%zu images_kb=%zu",
		(size_t)ui->solve_count, uo->wlr_output->name,
		commands.length, muts, t1 - t0, t2 - t1, t3 - t2, t3 - t0,
		render_node_count(uo->render), render_buffers_created(uo->render),
		render_raster_bytes(uo->render) >> 10, ui->image_bytes >> 10);
}

void ui_output_frame(struct ui_output *uo, bool lock_active) {
	if (!uo->dirty) {
		return;
	}
	uo->dirty = false;
	ui_output_solve(uo, lock_active);
}

/* --- the image cache --- */

/* gdk-pixbuf gives non-premultiplied R,G,B[,A] bytes; cairo ARGB32 wants a
 * native-endian uint32 with premultiplied alpha (little-endian here, so the
 * bytes land B,G,R,A). Written from the gdk-pixbuf/cairo contracts, not lifted. */
static cairo_surface_t *pixbuf_to_cairo(GdkPixbuf *pb) {
	int w = gdk_pixbuf_get_width(pb);
	int h = gdk_pixbuf_get_height(pb);
	int channels = gdk_pixbuf_get_n_channels(pb);
	int pb_stride = gdk_pixbuf_get_rowstride(pb);
	bool has_alpha = gdk_pixbuf_get_has_alpha(pb);
	const guchar *pixels = gdk_pixbuf_get_pixels(pb);

	cairo_surface_t *surface = cairo_image_surface_create(
		CAIRO_FORMAT_ARGB32, w, h);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(surface);
		return NULL;
	}
	int c_stride = cairo_image_surface_get_stride(surface);
	unsigned char *dst = cairo_image_surface_get_data(surface);
	for (int y = 0; y < h; y++) {
		const guchar *s = pixels + (size_t)y * pb_stride;
		uint32_t *d = (uint32_t *)(dst + (size_t)y * c_stride);
		for (int x = 0; x < w; x++) {
			uint8_t r = s[0], g = s[1], b = s[2];
			uint8_t a = has_alpha ? s[3] : 0xff;
			r = (uint8_t)((uint32_t)r * a / 255);
			g = (uint8_t)((uint32_t)g * a / 255);
			b = (uint8_t)((uint32_t)b * a / 255);
			d[x] = ((uint32_t)a << 24) | ((uint32_t)r << 16) |
				((uint32_t)g << 8) | (uint32_t)b;
			s += channels;
		}
	}
	cairo_surface_mark_dirty(surface);
	return surface;
}

static struct image_entry *image_find(struct ui *ui, const char *path) {
	for (size_t i = 0; i < ui->images_len; i++) {
		if (strcmp(ui->images[i]->path, path) == 0) {
			return ui->images[i];
		}
	}
	return NULL;
}

static void image_decode(struct image_entry *e) {
	e->decoded = true;
	GError *err = NULL;
	GdkPixbuf *pb = gdk_pixbuf_new_from_file(e->path, &err);
	if (pb == NULL) {
		e->failed = true;
		wlr_log(WLR_ERROR, "image decode failed for %s: %s", e->path,
			err != NULL ? err->message : "unknown");
		if (err != NULL) {
			g_error_free(err);
		}
		return;
	}
	e->native = pixbuf_to_cairo(pb);
	g_object_unref(pb);
	if (e->native == NULL) {
		e->failed = true;
		return;
	}
	e->width = cairo_image_surface_get_width(e->native);
	e->height = cairo_image_surface_get_height(e->native);
	e->failed = false;
	e->gen++;
}

/* Drop least-recently-declared decoded pixels until the budget holds.
 * Entries touched by the in-progress solve are exempt: their native pointer
 * may be read by this solve's reconcile. If everything resident is exempt,
 * the budget yields to the live set. Pixels only; the entry struct and its
 * imageData pointer are stable for the process. */
static void image_evict(struct ui *ui) {
	while (ui->image_bytes > ui->image_budget) {
		struct image_entry *lru = NULL;
		for (size_t i = 0; i < ui->images_len; i++) {
			struct image_entry *e = ui->images[i];
			if (e->native == NULL || e->touch >= ui->image_clock) {
				continue;
			}
			if (lru == NULL || e->touch < lru->touch) {
				lru = e;
			}
		}
		if (lru == NULL) {
			return;
		}
		cairo_surface_destroy(lru->native);
		lru->native = NULL;
		lru->decoded = false;
		ui->image_bytes -= lru->bytes;
		lru->bytes = 0;
	}
}

/* Find or create the entry for a key, without deciding anything about pixels.
 * The key is only a path when something means to decode a file from it. */
static struct image_entry *image_intern(struct ui *ui, const char *key) {
	struct image_entry *e = image_find(ui, key);
	if (e != NULL) {
		return e;
	}
	e = calloc(1, sizeof(*e));
	e->path = strdup(key);
	if (ui->images_len == ui->images_cap) {
		ui->images_cap = ui->images_cap ? ui->images_cap * 2 : 8;
		ui->images = realloc(ui->images,
			ui->images_cap * sizeof(*ui->images));
	}
	ui->images[ui->images_len++] = e;
	return e;
}

struct image_entry *ui_image_get(struct ui *ui, const char *path) {
	struct image_entry *e = image_intern(ui, path);
	e->touch = ui->image_clock;
	if (!e->decoded) {
		image_decode(e);
		if (e->native != NULL) {
			e->bytes = (size_t)cairo_image_surface_get_stride(
				e->native) * e->height;
			ui->image_bytes += e->bytes;
			image_evict(ui);
		}
	}
	return e;
}

/* Pixels that arrived in a message instead of a file (the notify image-data
 * hint, and the tray icons next). The layout is gdk-pixbuf's own, which is what
 * the hint's (iiibiiay) already is, so the conversion is the file path's. */
bool ui_image_put(struct ui *ui, const char *key, int width, int height,
		int rowstride, bool has_alpha, int bits_per_sample, int channels,
		const uint8_t *pixels, size_t pixels_len) {
	int want_channels = has_alpha ? 4 : 3;
	if (width <= 0 || height <= 0 || bits_per_sample != 8 ||
			channels != want_channels ||
			rowstride < width * channels) {
		return false;
	}
	/* The sender's own numbers say how much it should have sent. A message that
	 * disagrees with itself is a short buffer we would read off the end of. */
	size_t need = (size_t)rowstride * (size_t)(height - 1) +
		(size_t)width * (size_t)channels;
	if (pixels_len < need) {
		return false;
	}

	/* Borrowed, not owned: the pixbuf is a view over the caller's bytes for the
	 * length of the conversion, which copies into the cairo surface. */
	GdkPixbuf *pb = gdk_pixbuf_new_from_data(pixels, GDK_COLORSPACE_RGB,
		has_alpha, bits_per_sample, width, height, rowstride, NULL, NULL);
	if (pb == NULL) {
		return false;
	}
	cairo_surface_t *native = pixbuf_to_cairo(pb);
	g_object_unref(pb);
	if (native == NULL) {
		return false;
	}

	struct image_entry *e = image_intern(ui, key);
	if (e->native != NULL) {
		cairo_surface_destroy(e->native);
		ui->image_bytes -= e->bytes;
	}
	e->native = native;
	e->width = cairo_image_surface_get_width(native);
	e->height = cairo_image_surface_get_height(native);
	e->decoded = true;
	e->failed = false;
	/* gen is what tells the renderer to re-raster an entry whose pointer never
	 * changes, so a replacing image (a progress icon, a tray item swapping its
	 * icon) redraws instead of showing the old pixels. */
	e->gen++;
	e->bytes = (size_t)cairo_image_surface_get_stride(native) * e->height;
	e->touch = ui->image_clock;
	ui->image_bytes += e->bytes;
	/* Budgeted like any other entry. It has no file to re-decode from, so
	 * an eviction is permanent: image_decode fails on the key and the leaf goes
	 * blank, the existing failed-entry path. Eviction takes the
	 * least-recently-DECLARED pixels and a visible image is declared every
	 * frame, so the victim is never one that is on screen. */
	image_evict(ui);
	return true;
}

bool ui_image_save(struct ui *ui, const char *key, const char *path) {
	struct image_entry *e = image_find(ui, key);
	if (e == NULL || e->native == NULL) {
		return false;
	}
	return cairo_surface_write_to_png(e->native, path) ==
		CAIRO_STATUS_SUCCESS;
}

void ui_image_reload(struct ui *ui, const char *path) {
	struct image_entry *e = image_find(ui, path);
	if (e == NULL) {
		return;
	}
	if (e->native != NULL) {
		cairo_surface_destroy(e->native);
		e->native = NULL;
		ui->image_bytes -= e->bytes;
		e->bytes = 0;
	}
	/* decoded=false forces the next declare's ui_image_get to re-decode and
	 * bump gen; the entry pointer (live imageData) is untouched. */
	e->decoded = false;
	e->failed = false;
}

struct ui *ui_create(struct wl_display *display,
		struct wlr_scene_tree *parent,
		struct wlr_output_layout *output_layout) {
	struct ui *ui = calloc(1, sizeof(*ui));
	ui->tree = wlr_scene_tree_create(parent);
	ui->output_layout = output_layout;
	ui->pango = pango_font_map_create_context(
		pango_cairo_font_map_get_default());
	ui->measure_layout = pango_layout_new(ui->pango);
	wl_list_init(&ui->outputs);

	ui->layout_change.notify = ui_handle_layout_change;
	wl_signal_add(&output_layout->events.change, &ui->layout_change);

	ui->image_budget = (size_t)UI_IMAGE_BUDGET_MB << 20;
	const char *budget_mb = getenv("KILN_IMAGE_BUDGET_MB");
	if (budget_mb != NULL && atoi(budget_mb) > 0) {
		ui->image_budget = (size_t)atoi(budget_mb) << 20;
	}

	/* Applies to every context initialized afterwards. The defaults size
	 * the arena for 8192 elements (about 6 MB per output). */
	Clay_SetMaxElementCount(UI_MAX_ELEMENTS);
	return ui;
}

void ui_destroy(struct ui *ui) {
	struct ui_output *uo, *tmp;
	wl_list_for_each_safe(uo, tmp, &ui->outputs, link) {
		ui_output_destroy(uo);
	}
	wl_list_remove(&ui->layout_change.link);
	for (size_t i = 0; i < ui->images_len; i++) {
		if (ui->images[i]->native != NULL) {
			cairo_surface_destroy(ui->images[i]->native);
		}
		free(ui->images[i]->path);
		free(ui->images[i]);
	}
	free(ui->images);
	g_object_unref(ui->measure_layout);
	g_object_unref(ui->pango);
	free(ui);
}
