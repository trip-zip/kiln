-- The FFI boundary: the whole Lua-to-C direction of the primitive namespace,
-- and the only file in lua/ that may say ffi.cdef or ffi.C.
--
-- Shape:
--   * kiln is LuaJIT-only, so ffi is always there.
--   * Only Lua-to-C calls cross here. Events, the frame handler, and every
--     other C-to-Lua path stay classic API in core.c.
--   * No cdata leaves this file. The core pointer, the resolved symbols, the
--     argument structs and the readback scratch arrays are the cdata in scope;
--     none appears in an argument or a return value of a public verb.
--   * Every verb validates its arguments here, before ffi.C is touched: the
--     cdef'd functions trust their caller absolutely, and a wrong type reaching
--     one is a segfault, not an error message.
--
-- The verbs are installed onto the `core` table under their canonical
-- primitive names, so no caller and no IPC snippet can tell which transport a
-- verb is on.
--
-- The verb rows near the bottom are one row per verb: the core.* name first,
-- then one checker per argument.

local ffi = require("ffi")

ffi.cdef[[
/* CDEF-BEGIN
 *
 * scripts/gen-cdef-guard.py reads the text between these markers out of this
 * file and compiles it against core.h, so a signature that drifts from the C
 * it names fails the build. Without that, a cdef is an unchecked assertion
 * about another language's memory layout: the wrong one corrupts silently.
 * Keep every declaration inside the markers. */

/* CDEF-INCLUDE "ui.h" */

struct core;

/* The structs that cross, all of them by value (only by-value data crosses;
 * handles stay uint64_t). Copied from the header that
 * owns each, core.h but for struct ui_hit, which is ui.h's and is why the guard
 * includes it; the guard pins sizeof and every field offset against the real
 * definition, so a field added, dropped, or reordered there fails the build
 * here. */
struct core_keymap {
	const char *rules;
	const char *model;
	const char *layout;
	const char *variant;
	const char *options;
};
struct core_pointer_config {
	bool has_tap_to_click;      bool tap_to_click;
	bool has_natural_scrolling; bool natural_scrolling;
	bool has_left_handed;       bool left_handed;
	bool has_accel_speed;       double accel_speed;
	bool has_accel_profile;     const char *accel_profile;
	bool has_scroll_method;     const char *scroll_method;
	bool has_click_method;      const char *click_method;
};

/* The readbacks. hits and output_list fill an out-array this file owns
 * and sizes; box answers with one small struct. A hit's name is a pointer plus
 * a length, never a C string. */
struct ui_hit {
	const char *name;
	int32_t name_len;
	uint32_t index;
};
struct core_box {
	bool found;
	int x, y, width, height;
};
struct core_output_mode {
	int width, height, refresh;
};
struct core_output_info {
	char name[64];
	int width, height, refresh;
	double scale;
	int x, y;
	bool enabled;
	struct core_output_mode modes[32];
	int modes_len;
};

void kiln_dirty(struct core *core, const char *name);
void kiln_tick(struct core *core, const char *name, bool on);
void kiln_quit(struct core *core);
void kiln_timer_cancel(struct core *core, uint64_t id);
void kiln_set_idle_timeout(struct core *core, int ms);
void kiln_layer_configure(struct core *core, uint64_t handle,
	int width, int height);
bool kiln_lock(struct core *core);
bool kiln_unlock(struct core *core);
bool kiln_authenticate(struct core *core, const char *password);
void kiln_notify_closed(struct core *core, uint32_t id, int reason);
void kiln_notify_action(struct core *core, uint32_t id, const char *key);
void kiln_tray_activate(struct core *core, const char *service,
	const char *kind, int a, const char *b);

void kiln_client_focus(struct core *core, uint64_t handle);
void kiln_client_configure(struct core *core, uint64_t handle,
	int width, int height);
void kiln_client_close(struct core *core, uint64_t handle);
void kiln_client_kill(struct core *core, uint64_t handle);
void kiln_client_set_activated(struct core *core, uint64_t handle, bool on);
void kiln_client_set_fullscreen_hint(struct core *core, uint64_t handle,
	bool on);
void kiln_client_set_maximized_hint(struct core *core, uint64_t handle,
	bool on);
void kiln_client_set_tiled_hint(struct core *core, uint64_t handle,
	uint32_t edges);
void kiln_client_set_suspended(struct core *core, uint64_t handle, bool on);
void kiln_client_set_minimized_hint(struct core *core, uint64_t handle,
	bool on);
void kiln_client_set_output_mirror(struct core *core, uint64_t handle,
	const char *name);

void kiln_input_grab_pointer(struct core *core, bool on);
void kiln_input_grab_keyboard(struct core *core, bool on);
void kiln_input_set_keymap(struct core *core, struct core_keymap names);
void kiln_input_set_repeat(struct core *core, int rate, int delay);
void kiln_input_set_numlock(struct core *core, bool on);
void kiln_input_set_pointer(struct core *core, struct core_pointer_config cfg);
void kiln_input_set_cursor(struct core *core, const char *name);
void kiln_input_set_cursor_theme(struct core *core, const char *name, int size);

void kiln_output_set_mode(struct core *core, const char *name,
	int w, int h, int refresh);
void kiln_output_set_scale(struct core *core, const char *name, double scale);
void kiln_output_set_position(struct core *core, const char *name, int x, int y);
void kiln_output_set_enabled(struct core *core, const char *name, bool on);
void kiln_output_set_adaptive_sync(struct core *core, const char *name, bool on);

struct core_box kiln_box(const char *name, int32_t name_len, uint32_t index);
int kiln_hits(struct core *core, const char *screen, double x, double y,
	struct ui_hit *out, int max);
int kiln_output_list(struct core *core, struct core_output_info *out, int max);

/* The one crossing that is not a kiln_* verb: interning a font description needs
 * no core and no marshalling, so it is ui.h's own symbol. The guard already
 * includes that header, so this signature is pinned like every other. */
int32_t ui_font_intern(const char *name);

/* The Clay declaration chain. The declare path fills a Clay_ElementDeclaration
 * on this side, so its layout has to be described here, and Clay__* internals
 * are fair game because third_party/clay.h is vendored and pinned.
 *
 * Two rules this copy follows, both of them checkable. Every struct keeps
 * clay.h's tag, so the guard can pin it field by field against the real
 * definition. And every field clay.h declares with one of its packed enums
 * (enum __attribute__((__packed__)), one byte) is uint8_t here, because
 * LuaJIT's FFI has no packed-enum syntax: the CDEF-ENUM lines below are what
 * make the compiler check that one byte is still the truth, so the substitution
 * is pinned rather than assumed. */
/* CDEF-INCLUDE "clay.h" */
/* CDEF-ENUM Clay_LayoutDirection */
/* CDEF-ENUM Clay_LayoutAlignmentX */
/* CDEF-ENUM Clay_LayoutAlignmentY */
/* CDEF-ENUM Clay__SizingType */
/* CDEF-ENUM Clay_TextElementConfigWrapMode */
/* CDEF-ENUM Clay_TextAlignment */
/* CDEF-ENUM Clay_FloatingAttachPointType */
/* CDEF-ENUM Clay_PointerCaptureMode */
/* CDEF-ENUM Clay_FloatingAttachToElement */
/* CDEF-ENUM Clay_FloatingClipToElement */

struct Clay_String {
	bool isStaticallyAllocated;
	int32_t length;
	const char *chars;
};
struct Clay_ElementId {
	uint32_t id;
	uint32_t offset;
	uint32_t baseId;
	struct Clay_String stringId;
};
struct Clay_Color {
	float r, g, b, a;
};
struct Clay_Vector2 {
	float x, y;
};
struct Clay_Dimensions {
	float width, height;
};
struct Clay_CornerRadius {
	float topLeft, topRight, bottomLeft, bottomRight;
};
struct Clay_ChildAlignment {
	uint8_t x;
	uint8_t y;
};
struct Clay_SizingMinMax {
	float min, max;
};
/* The one union in the chain: percent and minMax share the same bytes, and
 * which of them is live is what type says. */
struct Clay_SizingAxis {
	union {
		struct Clay_SizingMinMax minMax;
		float percent;
	} size;
	uint8_t type;
};
struct Clay_Sizing {
	struct Clay_SizingAxis width;
	struct Clay_SizingAxis height;
};
struct Clay_Padding {
	uint16_t left, right, top, bottom;
};
struct Clay_LayoutConfig {
	struct Clay_Sizing sizing;
	struct Clay_Padding padding;
	uint16_t childGap;
	struct Clay_ChildAlignment childAlignment;
	uint8_t layoutDirection;
};
struct Clay_TextElementConfig {
	void *userData;
	struct Clay_Color textColor;
	uint16_t fontId;
	uint16_t fontSize;
	uint16_t letterSpacing;
	uint16_t lineHeight;
	uint8_t wrapMode;
	uint8_t textAlignment;
};
struct Clay_AspectRatioElementConfig {
	float aspectRatio;
};
struct Clay_ImageElementConfig {
	void *imageData;
};
struct Clay_FloatingAttachPoints {
	uint8_t element;
	uint8_t parent;
};
struct Clay_FloatingElementConfig {
	struct Clay_Vector2 offset;
	struct Clay_Dimensions expand;
	uint32_t parentId;
	int16_t zIndex;
	struct Clay_FloatingAttachPoints attachPoints;
	uint8_t pointerCaptureMode;
	uint8_t attachTo;
	uint8_t clipTo;
};
struct Clay_CustomElementConfig {
	void *customData;
};
struct Clay_ClipElementConfig {
	bool horizontal;
	bool vertical;
	struct Clay_Vector2 childOffset;
};
struct Clay_BorderWidth {
	uint16_t left, right, top, bottom, betweenChildren;
};
struct Clay_BorderElementConfig {
	struct Clay_Color color;
	struct Clay_BorderWidth width;
};
struct Clay_ElementDeclaration {
	struct Clay_ElementId id;
	struct Clay_LayoutConfig layout;
	struct Clay_Color backgroundColor;
	struct Clay_CornerRadius cornerRadius;
	struct Clay_AspectRatioElementConfig aspectRatio;
	struct Clay_ImageElementConfig image;
	struct Clay_FloatingElementConfig floating;
	struct Clay_CustomElementConfig custom;
	struct Clay_ClipElementConfig clip;
	struct Clay_BorderElementConfig border;
	void *userData;
};

/* Clay's own element API, called straight from the declare verbs. These three
 * return nothing, which is why they can be: a Clay call that answers with a
 * value would box one cdata per element per frame, and the kiln_* three below
 * exist to take those returns in C instead. */
void Clay__OpenElement(void);
void Clay__ConfigureOpenElementPtr(const struct Clay_ElementDeclaration *config);
void Clay__CloseElement(void);

uint32_t kiln_hash_id(const char *name, int32_t name_len, uint32_t index,
	struct Clay_ElementId *out);
void kiln_text(const struct Clay_String *text,
	const struct Clay_TextElementConfig *config);
void kiln_image(struct core *core, const char *path,
	struct Clay_ImageElementConfig *out);
bool kiln_surface(struct core *core, uint64_t handle,
	const struct Clay_ElementDeclaration *decl);

/* CDEF-END */
]]

local C = ffi.C

-- The compositor this boundary addresses. core.__ptr is the lightuserdata
-- core.c stores beside the primitives; casting it once here is the only place
-- the pointer is handled, and it is never dereferenced on this side.
local core_table = rawget(_G, "core")
if core_table == nil or core_table.__ptr == nil then
	error("kiln.cffi: no core.__ptr; this library only loads inside kiln", 2)
end
local ptr = ffi.cast("struct core *", core_table.__ptr)

-- The argument checkers. Each takes the value and the verb's name,
-- raises at the caller's line if the value cannot cross, and returns what
-- does; the conversion to the cdef'd C type is then the FFI's.
local function num(v, who)
	if type(v) ~= "number" then
		error(who .. ": expected a number, got " .. type(v), 3)
	end
	return v
end

local function str(v, who)
	if type(v) ~= "string" then
		error(who .. ": expected a string, got " .. type(v), 3)
	end
	return v
end

-- nil crosses as NULL, which is what "unset" means to every one of these.
local function optstr(v, who)
	if v ~= nil and type(v) ~= "string" then
		error(who .. ": expected a string or nil, got " .. type(v), 3)
	end
	return v
end

-- luaL_optnumber(L, n, default), moved to this side.
local function optnum(default)
	return function(v, who)
		if v == nil then
			return default
		end
		if type(v) ~= "number" then
			error(who .. ": expected a number or nil, got " .. type(v), 3)
		end
		return v
	end
end

-- lua_toboolean's contract, kept exactly: any value is legal and only nil and
-- false are false. Converting here is still validation, because the cdef'd bool
-- would refuse a table or a string outright.
local function bool(v)
	return v and true or false
end

local function checktable(t, who)
	if type(t) ~= "table" then
		error(who .. ": expected a table, got " .. type(t), 3)
	end
end

local function field(t, key, who, want)
	local v = t[key]
	if v ~= nil and type(v) ~= want then
		error(who .. ": " .. key .. " must be a " .. want .. " or nil, got "
			.. type(v), 3)
	end
	return v
end

-- core.client, core.input and core.output are wholly this file's now: C
-- registers nothing into any of the three.
local client, input, output = {}, {}, {}

-- One verb per row, installed under its core.* name.
-- A row is that name followed by one checker per argument; the
-- symbol is the same name under kiln_<prefix>, and resolving it here means a cdef
-- naming a function the executable does not export fails at load, not at use.
local function bind(tbl, verb_prefix, sym_prefix, rows)
	for _, row in ipairs(rows) do
		local name = row[1]
		local call, who = C[sym_prefix .. name], verb_prefix .. name
		local a, b, c, d = row[2], row[3], row[4], row[5]
		if a == nil then
			tbl[name] = function() return call(ptr) end
		elseif b == nil then
			tbl[name] = function(x) return call(ptr, a(x, who)) end
		elseif c == nil then
			tbl[name] = function(x, y) return call(ptr, a(x, who), b(y, who)) end
		elseif d == nil then
			tbl[name] = function(x, y, z)
				return call(ptr, a(x, who), b(y, who), c(z, who))
			end
		else
			tbl[name] = function(x, y, z, w)
				return call(ptr, a(x, who), b(y, who), c(z, who), d(w, who))
			end
		end
	end
end

bind(core_table, "core.", "kiln_", {
	{ "dirty", optstr },
	{ "tick", str, bool },
	{ "quit" },
	{ "timer_cancel", num },
	{ "set_idle_timeout", optnum(0) },
	{ "layer_configure", num, num, num },
	{ "lock" },
	{ "unlock" },
	{ "authenticate", str },
	{ "notify_closed", num, num },
	{ "notify_action", num, str },
	{ "tray_activate", str, str, optnum(0), optstr },
})

bind(client, "core.client.", "kiln_client_", {
	{ "focus", optnum(0) },                -- nil focuses nothing, handle 0
	{ "configure", num, num, num },
	{ "close", num },
	{ "kill", num },
	{ "set_activated", num, bool },
	{ "set_fullscreen_hint", num, bool },
	{ "set_maximized_hint", num, bool },
	{ "set_tiled_hint", num, num },
	{ "set_suspended", num, bool },
	{ "set_minimized_hint", num, bool },
	{ "set_output_mirror", num, optstr },  -- nil leaves every output
})

bind(input, "core.input.", "kiln_input_", {
	{ "grab_pointer", bool },
	{ "grab_keyboard", bool },
	{ "set_repeat", num, num },
	{ "set_numlock", bool },
	{ "set_cursor", str },
	{ "set_cursor_theme", optstr, optnum(24) },
})

bind(output, "core.output.", "kiln_output_", {
	{ "set_mode", str, num, num, optnum(0) },
	{ "set_scale", str, num },
	{ "set_position", str, num, num },
	{ "set_enabled", str, bool },
	{ "set_adaptive_sync", str, bool },
})

-- The two table-shaped verbs, the only ones the rows above cannot express.
-- Each takes one table of optional fields and crosses as a by-value struct,
-- the shape core.h already had. The strings inside the struct point into the
-- caller's table, which is alive for the whole call, so they stay anchored.

local keymap_fields = { "rules", "model", "layout", "variant", "options" }

-- core.input.set_keymap{ layout =, variant =, ... }: whole-map replacement, no
-- readback. A nil field is xkb's own default.
function input.set_keymap(t)
	local who = "core.input.set_keymap"
	checktable(t, who)
	local names = ffi.new("struct core_keymap")
	for _, k in ipairs(keymap_fields) do
		names[k] = field(t, k, who, "string")
	end
	C.kiln_input_set_keymap(ptr, names)
end

local pointer_bools = { "tap_to_click", "natural_scrolling", "left_handed" }
local pointer_strings = { "accel_profile", "scroll_method", "click_method" }

-- core.input.set_pointer{ ... }: libinput config over every pointer device.
-- A nil field is untouched, which is what the has_ flags carry, so
-- sending only what changed is exactly the contract.
function input.set_pointer(t)
	local who = "core.input.set_pointer"
	checktable(t, who)
	local cfg = ffi.new("struct core_pointer_config")
	for _, k in ipairs(pointer_bools) do
		cfg["has_" .. k] = t[k] ~= nil
		cfg[k] = t[k] and true or false
	end
	for _, k in ipairs(pointer_strings) do
		local v = field(t, k, who, "string")
		cfg["has_" .. k] = v ~= nil
		cfg[k] = v
	end
	local speed = field(t, "accel_speed", who, "number")
	cfg.has_accel_speed = speed ~= nil
	cfg.accel_speed = speed or 0
	C.kiln_input_set_pointer(ptr, cfg)
end

-- The readbacks. Two of them fill an out-array, allocated once here rather
-- than per call, on the side that owns it. Reuse is
-- safe because kiln runs one event loop and neither verb calls back into Lua, so
-- nothing can be reading one of these while a call refills it; the loops below
-- copy every field into plain Lua values before returning, so no cdata outlives
-- the call either (rule 4).
local HITS_MAX, OUTPUTS_MAX = 32, 16
local hits_out = ffi.new("struct ui_hit[?]", HITS_MAX)
local outputs_out = ffi.new("struct core_output_info[?]", OUTPUTS_MAX)

-- core.hits(screen, x, y): element ids under a layout point, innermost first.
function core_table.hits(screen, x, y)
	local who = "core.hits"
	local n = C.kiln_hits(ptr, str(screen, who), num(x, who), num(y, who),
		hits_out, HITS_MAX)
	local out = {}
	for i = 0, n - 1 do
		local h = hits_out[i]
		-- A name is (pointer, length). An anonymous Clay element carries
		-- CLAY__STRING_DEFAULT, whose chars are NULL, so a bare ffi.string would
		-- strlen a null pointer; this is what lua_pushlstring did.
		out[i + 1] = { name = ffi.string(h.name, h.name_len), index = h.index }
	end
	return out
end

-- core.box(id): the solved box of an element, { x, y, width, height } or nil.
-- The two id shapes Clay hashes are one call: a plain string is index 0.
function core_table.box(id)
	local who = "core.box"
	local name, index = id, 0
	if type(id) == "table" then
		name, index = id[1], id[2]
		-- A non-numeric index hashed as 0 collapses every such id onto one hash,
		-- and the collision trips CLAY_ERROR_TYPE_DUPLICATE_ID and aborts the
		-- session. The marshal boundary rejected it; so does this one.
		if type(index) ~= "number" then
			error(who .. ": table id index must be a number, got "
				.. type(index), 2)
		end
	end
	if type(name) ~= "string" then
		error(who .. ": expected a string id or { name, index }, got "
			.. type(name), 2)
	end
	local b = C.kiln_box(name, #name, index)
	if not b.found then
		return nil
	end
	return { x = b.x, y = b.y, width = b.width, height = b.height }
end

-- core.font(desc): a Pango font description ("Sans Bold", "Monospace") to the
-- id a text declaration carries as fontId. Interned, so the same description
-- always answers with the same id and an id is safe to hold.
--
-- No pass() guard: interning is not a declaration, and the declare path reaches
-- this on a cache miss from inside the frame handler as readily as a config
-- reaches it at startup.
--
-- The two refusal codes pair with UI_FONT_ERR_* in ui.h. Macros are the one
-- thing the cdef guard cannot compile against the C, so they are matched here by
-- hand and the messages are what a config sees.
local FONT_ERR = {
	[-1] = "a font description cannot carry a size; pass size = N instead",
	[-2] = "the font table is full",
}
function core_table.font(desc)
	local who = "core.font"
	if type(desc) ~= "string" then
		error(who .. ": expected a font description string, got "
			.. type(desc), 2)
	end
	local id = C.ui_font_intern(desc)
	if id < 0 then
		error(who .. ": " .. (FONT_ERR[id] or "refused") .. ": " .. desc, 2)
	end
	return id
end

-- core.output.list(): the one output read, enumeration as discovery.
function output.list()
	local n = C.kiln_output_list(ptr, outputs_out, OUTPUTS_MAX)
	local out = {}
	for i = 0, n - 1 do
		local o = outputs_out[i]
		local modes = {}
		for m = 0, o.modes_len - 1 do
			local mode = o.modes[m]
			modes[m + 1] = { width = mode.width, height = mode.height,
				refresh = mode.refresh }
		end
		out[i + 1] = {
			name = ffi.string(o.name),
			width = o.width, height = o.height, refresh = o.refresh,
			scale = o.scale, x = o.x, y = o.y,
			enabled = o.enabled, modes = modes,
		}
	end
	return out
end

-- The declare path. One scratch declaration, filled in place and handed
-- to Clay by pointer: Clay copies what it keeps during
-- Clay__ConfigureOpenElementPtr, so one struct serves every element of every
-- frame and nothing is allocated per element. The same holds for the text
-- config and the Clay_String the two verbs pass by pointer.
local decl = ffi.new("struct Clay_ElementDeclaration")
local DECL_SIZE = ffi.sizeof("struct Clay_ElementDeclaration")
local text_cfg = ffi.new("struct Clay_TextElementConfig")
local TEXT_SIZE = ffi.sizeof("struct Clay_TextElementConfig")
local clay_str = ffi.new("struct Clay_String")

-- Resolved once, the way bind() resolves the verbs it installs: C[name] is an
-- __index metamethod on the ffi.C namespace, and this is the one path in the
-- file that runs per element per frame rather than per user call.
local clay_open = C.Clay__OpenElement
local clay_configure = C.Clay__ConfigureOpenElementPtr
local clay_close = C.Clay__CloseElement
local kiln_hash_id = C.kiln_hash_id
local kiln_text = C.kiln_text
local kiln_image = C.kiln_image
local kiln_surface = C.kiln_surface
local ffi_fill = ffi.fill

-- The enum name tables, the field_enum name arrays of core.c in their declared
-- order. A number still crosses as itself, which is what the C did.
local SIZING = { fit = 0, grow = 1, percent = 2, fixed = 3 }
local DIRECTION = { ltr = 0, ttb = 1 }
local ALIGN_X = { left = 0, right = 1, center = 2 }
local ALIGN_Y = { top = 0, bottom = 1, center = 2 }
local WRAP = { words = 0, newlines = 1, none = 2 }
-- The one text flag, mirroring ui.h's own value. Prebuilt rather than cast per
-- call because Clay's channel for it is a pointer field, and casting on the
-- declare path would allocate where nothing else does. Nothing compares this
-- number to the header, so what catches it drifting is section 4 of the paint
-- battery: a wrong bit truncates nothing and those legs go red.
local TEXT_ELLIPSIZE = ffi.cast("void *", 1)
local TEXT_ALIGN = { left = 0, center = 1, right = 2 }
local ATTACH_TO = { none = 0, parent = 1, element = 2, root = 3 }
local CAPTURE = { capture = 0, passthrough = 1 }
local CLIP_TO = { none = 0, attached_parent = 1 }
local ATTACH_POINT = {
	left_top = 0, left_center = 1, left_bottom = 2,
	center_top = 3, center_center = 4, center_bottom = 5,
	right_top = 6, right_center = 7, right_bottom = 8,
}

-- The field readers, each the accept-set of the C helper it replaces, exactly.
-- field_num tested lua_isnumber, which is true of a numeric string, so tonumber
-- is the conversion and not a tightening; anything else falls to the default,
-- silently, as it always has. Declaration fields are not validated at the edge
-- the way an argument is: a wrong-typed field has always meant "use the
-- default", and turning that into an error would be a behavior change on the
-- hottest path in kiln, not a rule-5 improvement.
local function fnum(t, key, default)
	local v = tonumber(t[key])
	if v == nil then
		return default
	end
	return v
end

local function ftab(t, key)
	local v = t[key]
	if type(v) == "table" then
		return v
	end
	return nil
end

-- field_enum: the number branch first, because lua_isnumber ran first and takes
-- a numeric string with it; then the name lookup; then the default.
local function fenum(t, key, names, default)
	local v = t[key]
	local n = tonumber(v)
	if n ~= nil then
		return n
	end
	if type(v) == "string" then
		local e = names[v]
		if e ~= nil then
			return e
		end
	end
	return default
end

local function fill_color(dst, t)
	dst.r = fnum(t, "r", 0)
	dst.g = fnum(t, "g", 0)
	dst.b = fnum(t, "b", 0)
	dst.a = fnum(t, "a", 255)
end

-- One sizing axis: a bare number (or a numeric string, which lua_isnumber took)
-- is fixed pixels, and a table carries its type plus the bounds that type reads.
-- Only one arm of the union may be written, which is why the percent branch and
-- the minMax branches are exclusive here exactly as they were in C.
local function fill_axis(dst, v)
	local px = tonumber(v)
	if px ~= nil then
		dst.type = SIZING.fixed
		dst.size.minMax.min = px
		dst.size.minMax.max = px
	elseif type(v) == "table" then
		local ty = fenum(v, "type", SIZING, SIZING.fit)
		dst.type = ty
		if ty == SIZING.percent then
			dst.size.percent = fnum(v, "percent", 0)
		elseif ty == SIZING.fixed then
			px = fnum(v, "px", 0)
			dst.size.minMax.min = px
			dst.size.minMax.max = px
		else
			dst.size.minMax.min = fnum(v, "min", 0)
			dst.size.minMax.max = fnum(v, "max", 0)
		end
	end
end

-- The anchor table for the pass, and the open depth. Both are handed to us by
-- core.__declare: C installs a fresh table before each declare pass and clears
-- it after (core.c), so its absence is "outside the frame handler" and a change
-- of identity is "a new pass started". Anchoring is the contract Clay's strings
-- live on: Clay keeps a pointer into the bytes of the Lua string, and keeps it
-- in the context's element hashmap long after the pass, which is why the table
-- is not this upvalue's to release. C parks it in core.__anchors under the Clay
-- context and drops it when that same context declares again; holding it
-- here is only how the current pass reaches it.
local anchors, anchor_n, depth = nil, 0, 0

local function pass(who)
	local t = core_table.__declare
	if t == nil then
		error(who .. ": declare primitives are only callable inside "
			.. "the frame handler", 3)
	end
	if t ~= anchors then
		anchors, anchor_n, depth = t, 0, 0
	end
	return t
end

local function anchor(s)
	anchor_n = anchor_n + 1
	anchors[anchor_n] = s
	return s
end

-- The two id shapes Clay hashes, as one call: a plain string is index 0. out
-- takes the whole Clay_ElementId, or nil when only the hash is wanted (a
-- floating parentId). A number id is legal and coerces to its decimal string;
-- any other type is refused before it can reach the hash.
local function set_id(out, id, who)
	local name, index = id, 0
	if type(id) == "table" then
		name, index = id[1], id[2]
		-- A non-numeric index hashed as 0 collapses every such id onto one
		-- hash, and the collision trips CLAY_ERROR_TYPE_DUPLICATE_ID and aborts
		-- the session. The marshal boundary rejected it; so does this one.
		if type(index) ~= "number" then
			error(who .. ": table id index must be a number, got "
				.. type(index), 4)
		end
	end
	if type(name) == "number" then
		name = tostring(name)
	elseif type(name) ~= "string" then
		error(who .. ": expected a string id or { name, index }, got "
			.. type(name), 4)
	end
	anchor(name)
	return kiln_hash_id(name, #name, index, out)
end

-- The decl table mirrors Clay_ElementDeclaration one to one. The scratch is
-- zeroed first, so an absent field is Clay's own default and nothing survives
-- from the element before.
local function fill(d, t, who)
	ffi_fill(d, DECL_SIZE)

	if t.id ~= nil then
		set_id(d.id, t.id, who)
	end

	local layout = ftab(t, "layout")
	if layout ~= nil then
		local sizing = ftab(layout, "sizing")
		if sizing ~= nil then
			fill_axis(d.layout.sizing.width, sizing.width)
			fill_axis(d.layout.sizing.height, sizing.height)
		end
		local pad = ftab(layout, "padding")
		if pad ~= nil then
			d.layout.padding.left = fnum(pad, "left", 0)
			d.layout.padding.right = fnum(pad, "right", 0)
			d.layout.padding.top = fnum(pad, "top", 0)
			d.layout.padding.bottom = fnum(pad, "bottom", 0)
		end
		d.layout.childGap = fnum(layout, "childGap", 0)
		local align = ftab(layout, "childAlignment")
		if align ~= nil then
			d.layout.childAlignment.x = fenum(align, "x", ALIGN_X, 0)
			d.layout.childAlignment.y = fenum(align, "y", ALIGN_Y, 0)
		end
		d.layout.layoutDirection =
			fenum(layout, "layoutDirection", DIRECTION, 0)
	end

	local bg = ftab(t, "backgroundColor")
	if bg ~= nil then
		fill_color(d.backgroundColor, bg)
	end
	local radius = ftab(t, "cornerRadius")
	if radius ~= nil then
		d.cornerRadius.topLeft = fnum(radius, "topLeft", 0)
		d.cornerRadius.topRight = fnum(radius, "topRight", 0)
		d.cornerRadius.bottomLeft = fnum(radius, "bottomLeft", 0)
		d.cornerRadius.bottomRight = fnum(radius, "bottomRight", 0)
	end
	d.aspectRatio.aspectRatio = fnum(t, "aspectRatio", 0)

	local image = ftab(t, "image")
	if image ~= nil then
		local path = image.path
		-- lua_tostring took a string or a number and answered NULL for anything
		-- else, which left imageData unset; the same three cases here.
		if type(path) == "number" then
			path = tostring(path)
		end
		if type(path) == "string" then
			kiln_image(ptr, path, d.image)
		end
	end

	local float = ftab(t, "floating")
	if float ~= nil then
		local offset = ftab(float, "offset")
		if offset ~= nil then
			d.floating.offset.x = fnum(offset, "x", 0)
			d.floating.offset.y = fnum(offset, "y", 0)
		end
		local expand = ftab(float, "expand")
		if expand ~= nil then
			d.floating.expand.width = fnum(expand, "width", 0)
			d.floating.expand.height = fnum(expand, "height", 0)
		end
		if float.parentId ~= nil then
			d.floating.parentId = set_id(nil, float.parentId, who)
		end
		d.floating.zIndex = fnum(float, "zIndex", 0)
		local points = ftab(float, "attachPoints")
		if points ~= nil then
			d.floating.attachPoints.element =
				fenum(points, "element", ATTACH_POINT, 0)
			d.floating.attachPoints.parent =
				fenum(points, "parent", ATTACH_POINT, 0)
		end
		d.floating.pointerCaptureMode =
			fenum(float, "pointerCaptureMode", CAPTURE, 0)
		d.floating.attachTo = fenum(float, "attachTo", ATTACH_TO, 0)
		d.floating.clipTo = fenum(float, "clipTo", CLIP_TO, 0)
	end

	local clip = ftab(t, "clip")
	if clip ~= nil then
		-- lua_toboolean, kept: only nil and false are false.
		d.clip.horizontal = clip.horizontal and true or false
		d.clip.vertical = clip.vertical and true or false
		local offset = ftab(clip, "childOffset")
		if offset ~= nil then
			d.clip.childOffset.x = fnum(offset, "x", 0)
			d.clip.childOffset.y = fnum(offset, "y", 0)
		end
	end

	local border = ftab(t, "border")
	if border ~= nil then
		local color = ftab(border, "color")
		if color ~= nil then
			fill_color(d.border.color, color)
		end
		local width = ftab(border, "width")
		if width ~= nil then
			d.border.width.left = fnum(width, "left", 0)
			d.border.width.right = fnum(width, "right", 0)
			d.border.width.top = fnum(width, "top", 0)
			d.border.width.bottom = fnum(width, "bottom", 0)
			d.border.width.betweenChildren =
				fnum(width, "betweenChildren", 0)
		end
	end
end

-- core.open(decl): open one element and configure it from the scratch. The
-- declaration is dead the moment Clay has copied it, which is why one scratch
-- can serve the whole frame.
function core_table.open(t)
	local who = "core.open"
	pass(who)
	if type(t) ~= "table" then
		error(who .. ": expected a table, got " .. type(t), 2)
	end
	fill(decl, t, who)
	clay_open()
	clay_configure(decl)
	depth = depth + 1
end

-- core.close(): close the innermost open element. The depth is this side's now,
-- reset by every new pass; C rebalances whatever a failed handler leaves open
-- against Clay's own stack.
function core_table.close()
	local who = "core.close"
	pass(who)
	if depth == 0 then
		error("core.close without matching core.open", 2)
	end
	clay_close()
	depth = depth - 1
end

-- core.text(str, cfg?): a text leaf. luaL_checkstring took a number and coerced
-- it, so this does too; the bytes are anchored for the pass because Clay keeps
-- a pointer into them until the commands are consumed.
function core_table.text(s, cfg)
	local who = "core.text"
	pass(who)
	if type(s) == "number" then
		s = tostring(s)
	elseif type(s) ~= "string" then
		error(who .. ": expected a string, got " .. type(s), 2)
	end
	anchor(s)
	clay_str.length, clay_str.chars = #s, s
	ffi_fill(text_cfg, TEXT_SIZE)
	if type(cfg) == "table" then
		local color = ftab(cfg, "textColor")
		if color ~= nil then
			fill_color(text_cfg.textColor, color)
		end
		text_cfg.fontId = fnum(cfg, "fontId", 0)
		text_cfg.fontSize = fnum(cfg, "fontSize", 16)
		text_cfg.letterSpacing = fnum(cfg, "letterSpacing", 0)
		text_cfg.lineHeight = fnum(cfg, "lineHeight", 0)
		text_cfg.wrapMode = fenum(cfg, "wrapMode", WRAP, 0)
		text_cfg.textAlignment = fenum(cfg, "textAlignment", TEXT_ALIGN, 0)
		-- Only ever set, never cleared: the fill above zeroed it.
		if cfg.ellipsize then
			text_cfg.userData = TEXT_ELLIPSIZE
		end
	else
		text_cfg.fontSize = 16
	end
	kiln_text(clay_str, text_cfg)
end

-- core.surface(handle, decl?): the place-leaf. The declaration is this
-- side's, the same scratch; the contract is C's, and kiln_surface keeps all
-- of it, including the double-declare guard whose false answer becomes an
-- error here.
function core_table.surface(handle, t)
	local who = "core.surface"
	pass(who)
	local h = tonumber(handle)
	if h == nil then
		error(who .. ": expected a number, got " .. type(handle), 2)
	end
	local d = nil
	if type(t) == "table" then
		fill(decl, t, who)
		d = decl
	end
	if not kiln_surface(ptr, h, d) then
		error(string.format("%s: handle %d declared twice in one frame",
			who, h), 2)
	end
end

core_table.client = client
core_table.input = input
core_table.output = output

-- Nothing reads this return value: installing over the primitive namespace is
-- the whole effect. The namespaces are handed back so require() caches a value.
return { client = client, input = input, output = output }
