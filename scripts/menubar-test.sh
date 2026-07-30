#!/bin/sh
# The menubar recipe battery: the .desktop launcher recipe booted in a stock rc,
# listing entries and launching one.
#
#   scripts/menubar-test.sh
#
# A menubar is an application on the public API, not a compositor capability, so
# it costs zero stdlib lines: the whole of it is the recipe below, config space
# over kiln.spawn_with_token and kiln.menu. This battery proves the recipe
# stands, in two halves.
#
# THE STATIC HALF is the recipe grep: the menubar recipe reaches for no
# compositor primitive (grep -c 'core\.' is 0). A recipe that could only be
# written by reaching past the public API is a hole in that API, not a recipe;
# that grep is where it would show.
#
# THE LIVE HALF boots the recipe over a FIXTURE application dir (XDG_DATA_HOME
# pointed at a temp tree, XDG_DATA_DIRS emptied, so the scan is deterministic and
# sees only what this test planted). It asserts the scan lists the visible
# entries and skips the ones the desktop-entry standard says never to show
# (NoDisplay, non-Application), then LAUNCHES one and watches it arrive.
#
# THE LAUNCH IS A REAL TOKEN MINT. The planted entry's Exec is build/wl-activate
# (the activation fixture in the tree) in `valid` mode: it raises itself with the
# token spawn_with_token minted into its XDG_ACTIVATION_TOKEN. That token was
# seat-backed at mint, so it reaches request_activate valid=true and the stock
# default focuses it. So "the launcher launched" is proven not by a process
# existing but by the whole activation round trip completing, which is why the
# launch goes through a token at all.
#
# A focus=false rule on the probe app_id suppresses focus-on-open, so the probe
# maps unfocused and only its activation can move the seat: focus landing on it
# is the token's doing, not the map's.
#
# Needs: nothing beyond the build (wl-activate is a tree fixture).
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
docs="${KILN_DOCS:-$HOME/tools/somewm-docs}/kiln/guides"
work="$(mktemp -d /tmp/kiln-menubar-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
apps="$work/xdg/applications"
kiln_pid=""

cleanup() {
	[ -n "$kiln_pid" ] && kill "$kiln_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

fail=0
eval_kiln() { KILN_SOCK="$sock" "$repo/scripts/kiln-eval" "$1"; }
check() { # label expected actual
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n     (%s)\n' "$1" "$3"
	else
		printf 'FAIL %s\n     expected %s\n     got      %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

# =====================================================================
# The static half: the recipe grep. Run first, because a recipe that reaches for
# a primitive is not a recipe, and the boot below would be proving the wrong file.

if [ -f "$docs/app-launcher.md" ]; then
	check "the recipe reaches for no compositor primitive" "0" \
		"$(grep -c 'core\.' "$docs/app-launcher.md" | tr -d ' ')"
else
	printf 'FAIL app-launcher.md is missing from the docs checkout\n'; fail=1
fi

# =====================================================================
# The fixture application dir: one visible entry (the probe, whose Exec carries a
# %U field code to prove the strip), one NoDisplay entry and one non-Application
# entry that must NOT show, and a second visible app to prove the sort.
mkdir -p "$apps"
cat >"$apps/kiln-probe.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Kiln Probe
Exec=$repo/build/wl-activate valid kiln.menubar.probe %U
EOF
cat >"$apps/aardvark.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Aardvark App
Exec=true
EOF
cat >"$apps/hidden.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Should Not Show
NoDisplay=true
Exec=true
EOF
cat >"$apps/link.desktop" <<'EOF'
[Desktop Entry]
Type=Link
Name=Also Not Shown
URL=https://example.invalid
EOF

# =====================================================================
# The stock rc: the menubar recipe verbatim (the LOCAL functions are the
# recipe), then the only scaffolding this battery adds: two globals that
# reach the recipe's local menubar_items over IPC (a later function in the same
# chunk closes over the earlier local), a request::activate recorder alongside
# the stock default, and a focus=false rule so the probe maps unfocused.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
local ui = kiln.ui

-- The application dirs, in XDG order: $XDG_DATA_HOME first, then each entry of
-- $XDG_DATA_DIRS, every one suffixed /applications. Defaults per the XDG
-- base-directory standard when the vars are unset.
local function app_dirs()
	local home = os.getenv("HOME") or ""
	local data_home = os.getenv("XDG_DATA_HOME")
	if data_home == nil or data_home == "" then
		data_home = home .. "/.local/share"
	end
	local data_dirs = os.getenv("XDG_DATA_DIRS")
	if data_dirs == nil or data_dirs == "" then
		data_dirs = "/usr/share:/usr/local/share"
	end
	local dirs = { data_home }
	for d in (data_dirs .. ":"):gmatch("([^:]*):") do
		if d ~= "" then dirs[#dirs + 1] = d end
	end
	for i, d in ipairs(dirs) do
		dirs[i] = d .. "/applications"
	end
	return dirs
end

-- The .desktop files in one dir. Lua's stdlib has no dirent, so ls names them;
-- a recipe is config space and shells out where the stdlib will not.
local function desktops(dir)
	local out = {}
	local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
	if p == nil then
		return out
	end
	for line in p:lines() do
		if line:match("%.desktop$") then
			out[#out + 1] = dir .. "/" .. line
		end
	end
	p:close()
	return out
end

-- One entry: Name and Exec from the [Desktop Entry] group, skipping the ones the
-- desktop-entry standard says never to launch from a menu (NoDisplay, Hidden,
-- non-Application).
-- Exec's field codes (%u, %F, ...) are meaningless without a selected file, so
-- strip them; %% is the one that means a literal percent.
local function parse(path)
	local f = io.open(path, "r")
	if f == nil then
		return nil
	end
	local entry, name, exec, show = false, nil, nil, true
	for line in f:lines() do
		local head = line:match("^%[(.-)%]$")
		if head ~= nil then
			entry = head == "Desktop Entry"
		elseif entry then
			local k, v = line:match("^([%w-]+)%s*=%s*(.*)$")
			if k == "Name" and name == nil then
				name = v
			elseif k == "Exec" then
				exec = v
			elseif k == "Type" and v ~= "Application" then
				show = false
			elseif (k == "NoDisplay" or k == "Hidden") and v == "true" then
				show = false
			end
		end
	end
	f:close()
	if not show or name == nil or exec == nil then
		return nil
	end
	exec = exec:gsub("%%(.)", function(c)
		return c == "%" and "%" or ""
	end)
	return { name = name, exec = (exec:gsub("%s+$", "")) }
end

-- The launcher entries: every .desktop across the dirs, first name wins on a
-- basename clash (XDG precedence), sorted so the menu reads the same each open.
local function apps()
	local seen, out = {}, {}
	for _, dir in ipairs(app_dirs()) do
		for _, path in ipairs(desktops(dir)) do
			local base = path:match("([^/]+)$")
			if not seen[base] then
				seen[base] = true
				local a = parse(path)
				if a ~= nil then
					out[#out + 1] = a
				end
			end
		end
	end
	table.sort(out, function(x, y)
		return x.name:lower() < y.name:lower()
	end)
	return out
end

-- The menu items: each row launches its Exec WITH AN ACTIVATION TOKEN, so the
-- app arrives able to raise itself and the request arbitrates as user-initiated.
-- The launcher is a real minting site, not a simulation of one.
local function menubar_items()
	local items = {}
	for _, a in ipairs(apps()) do
		items[#items + 1] = { a.name, function()
			kiln.spawn_with_token(a.exec)
		end }
	end
	return items
end

-- A bar with the launcher button: pressing it scans fresh and opens the stdlib
-- menu under itself. The scan is on press, not per frame, so the menu is always
-- current and nothing is stored.
screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
	ui.bar(s, { edge = "top", h = 28, color = kiln.theme.bg }, function()
		ui.box({
			id = "apps-btn", color = kiln.theme.accent, radius = 4,
			pad = { x = 8 }, align = "center",
			on_press = function()
				kiln.menu.show { under = "apps-btn", screen = s,
					items = menubar_items() }
			end,
		}, function() ui.text("apps", { color = kiln.theme.bg, size = 12 }) end)
	end)
end)

-- === battery scaffolding below (not part of the recipe) ===
-- Reach the recipe's local menubar_items over IPC: a global function defined
-- later in the same chunk closes over it.
function menubar_names()
	local o = {}
	for _, it in ipairs(menubar_items()) do
		o[#o + 1] = it[1]
	end
	return table.concat(o, ",")
end
function menubar_launch(name)
	for _, it in ipairs(menubar_items()) do
		if it[1] == name then
			it[2]()
			return "fired"
		end
	end
	return "no-item"
end
-- Record the activation facts alongside the stock default (emit fires every
-- handler; this recorder does not replace kiln.defaults.activate).
LAST_ACTIVATE = nil
client.on("request::activate", function(c, ctx)
	LAST_ACTIVATE = { valid = ctx.valid, app = c.app_id }
end)
-- Suppress focus-on-open for the probe, so only its activation can focus it.
kiln.rule {
	match_any = { app = { "kiln.menubar.probe" } },
	props = { focus = false },
}
EOF

# XDG_DATA_HOME at the fixture, XDG_DATA_DIRS emptied to a real empty dir, so the
# scan sees only what this test planted.
mkdir -p "$work/empty"
# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	XDG_DATA_HOME="$work/xdg" XDG_DATA_DIRS="$work/empty" \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"
check "the spawn_with_token minting verb is bound" "function" \
	"$(eval_kiln 'return type(require("kiln").spawn_with_token)')"

prop() { # app_id lua-expr-over-c
	eval_kiln "for _, c in ipairs(client.all()) do
	  if c.app_id == '$1' then return tostring($2) end
	end
	return 'no-client'"
}
focus_app() { eval_kiln 'return client.focus and client.focus.app_id or "-"'; }
last() { eval_kiln "return LAST_ACTIVATE and tostring(LAST_ACTIVATE.$1) or 'nil'"; }

# =====================================================================
echo "== the scan: the visible entries, sorted, filtered"
# Aardvark before Kiln by the sort; the NoDisplay and non-Application entries
# never appear. The %U on the probe's Exec was stripped, proven by the launch
# below arriving at all (an unstripped %U would reach the shell as a bad arg).
check "the recipe lists the visible .desktop entries, sorted and filtered" \
	"Aardvark App,Kiln Probe" "$(eval_kiln 'return menubar_names()')"

# =====================================================================
echo "== the launch: a real token-minting round trip"
check "launching the probe fired its item" "fired" \
	"$(eval_kiln 'return menubar_launch("Kiln Probe")')"
sleep 3
check "the probe mapped" "true" "$(prop kiln.menubar.probe 'c.mapped ~= false')"
check "focus-on-open was suppressed, so the activation is what focused it" "true" \
	"$(prop kiln.menubar.probe 'c.no_focus == true')"
check "C derived valid=true from the recipe's seat-backed token" "true" \
	"$(last valid)"
check "the default focused the launched probe" "kiln.menubar.probe" \
	"$(focus_app)"

# =====================================================================
# No Lua error on the bus, no tree/scene divergence through the launch.
#
# The pattern is "error in '", not "bus error in": init.lua's on_error override
# is what prints. KILN_BUS_PROBE=1 raises one real error through bus.lua's pcall,
# so this leg MUST go red under it, which is what proves the grep can see a
# failure at all.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

check "no bus error, no tree/scene divergence" "0" \
	"$(grep -cE "error in '|tree==scene:|DUPLICATE" "$log" || true)"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
