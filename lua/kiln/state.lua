-- Shared runtime state, split out so ui.lua and init.lua can both reach
-- it without a require cycle.

return {
	modkey = "alt",
	theme = {
		bg = "#181820",
		bg2 = "#101014",
		fg = "#dcdce6",
		accent = "#5078be",
		muted = "#3c3c4b",
		font_size = 14,
		-- The default face, as a Pango description. Size is font_size and not
		-- part of this string: it is its own channel, set at the output's
		-- device scale per raster, so a size here would be overridden.
		font = "Sans",
		-- The default cell gap: the workarea's inset and the space a layout
		-- leaves between its cells. A tag overrides it with t.gap.
		gap = 8,
		bar_height = 32,
		-- Composite client: border colored by focus, one titlebar
		-- row of draw-leaves. All choice, overridable from rc.lua.
		titlebar_height = 22,
		titlebar = "#22222c",
		titlebar_focus = "#2c2c3a",
		close = "#c05068",
		-- An unfocused client that raised request::activate as urgent: the
		-- border reads the property at declare, no styling subsystem.
		urgent = "#e0a050",
		client_radius = 4,
		-- The focus ring's weight. A border is the only chrome an undecorated
		-- client has, so its width is a theme value like its color.
		border_width = 2,
		-- Interactive resize: invisible edge handles on floating
		-- clients drive a grab. handle_size is the edge band width in px; a
		-- resize never shrinks a client below min_size. Both are choice.
		resize_handle = 6,
		min_size = 60,
		-- The menu: a float column of rows in the overlay band. Width
		-- and row height are the only geometry it has; nesting is Clay's.
		-- menu_submenu_icon is the one optional key: an image path a config sets
		-- to draw a chevron glyph on submenu rows instead of the default ">"
		-- text. It cannot be listed here with a value, because a Lua table
		-- cannot hold a declared nil, and nil IS the default.
		menu_width = 200,
		menu_height = 24,
		-- The tooltip: Clay fits it to its text, so the only
		-- geometry it has is how far off its target it hangs.
		tooltip_gap = 4,
		-- Notifications: a float column in the overlay band, top-right of
		-- the focused screen. Width is the only size it has (Clay fits the
		-- height to the text); offset is how far it sits off the two edges, and
		-- gap the space between stacked popups. notification_timeout is seconds
		-- per urgency and is what a client's "server decides" (-1) resolves to;
		-- critical is sticky because critical ignores timeouts entirely, so its 0
		-- is a statement, not a default anyone reads.
		notification_width = 320,
		notification_offset = 12,
		notification_gap = 8,
		notification_radius = 0,
		notification_timeout = { low = 5, normal = 5, critical = 0 },
		-- The prompt: a floating entry in the overlay band, offset from
		-- the top of the screen. Width takes any ui sizing form. Choice.
		prompt_width = "50%",
		prompt_offset = 80,
		-- Cursor policy is Lua's (C only takes an xcursor name): the move grab
		-- and each resize edge name a theme cursor, overridable from rc.lua like
		-- AwesomeWM's beautiful cursor config. Edge keys are compass points.
		cursors = {
			move = "grabbing",
			resize = {
				n = "n-resize", s = "s-resize", e = "e-resize", w = "w-resize",
				ne = "ne-resize", nw = "nw-resize",
				se = "se-resize", sw = "sw-resize",
			},
		},
	},
	screens = {},
	-- Live layer-shell surfaces, in map order (which is declare order, the
	-- within-band tiebreak).
	layers = {},
	-- Screen names whose layer surfaces owe a re-answer, set by `output change`
	-- and drained by the next declare on that screen. A set, not a queue:
	-- three mode changes before one frame still owe exactly one re-answer.
	layer_reanswer = {},
	-- Bound chords, keyed by chord string: one entry per EXPANDED key ("1-9" is
	-- nine of these). This is what dispatch looks in and what C consumes.
	keys = {},
	-- The key registry: one entry per key{} CALL, in declaration order, holding
	-- the range as written plus desc and group. This is what a hotkeys popup
	-- reads; it is deliberately not the same table as `keys`,
	-- because a cheat sheet wants "1-9  view tag" and dispatch wants "alt+5".
	key_specs = {},
	buttons = {},
	rules = {},
	-- Declare-time press handlers by element id. presses is the table for
	-- the screen currently declaring; screen_presses stashes each screen's
	-- finished table so a button dispatches to the right one (one wipe per
	-- screen frame would otherwise erase the other screen's handlers).
	presses = {},
	screen_presses = {},
	press_n = 0,
	-- Where the pointer last was, as { x, y, screen }: the motion event's fact,
	-- kept because nothing else in Lua knows it and placement.under_mouse asks.
	-- nil until the first motion, which is also the honest answer on a headless
	-- boot and under a keyboard-summoned launcher.
	pointer = nil,
}
