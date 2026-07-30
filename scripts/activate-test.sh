#!/bin/sh
# The xdg-activation battery: a real request::activate round
# trip, C deriving `valid` from the token's seat, the focus-or-decline decision
# left to Lua's replaceable default.
#
#   scripts/activate-test.sh
#
# Pure headless, and the PROTOCOL half is REAL. scripts/wl-activate (built from
# the tree, the Wayland analog of x11-state) maps a toplevel and actually asks to
# be raised: a stock terminal never calls xdg_activation_v1.activate, so the only
# way to prove C's seat->valid derivation instead of restating it is a client
# that drives the protocol. Two asks, two token provenances:
#
#   valid   the client raises itself with the token core.spawn_with_token minted
#           into its XDG_ACTIVATION_TOKEN. That token was seat-backed at mint, so
#           it reaches request_activate with token->seat != NULL: valid=true, and
#           the stock kiln.defaults.activate focuses it.
#   invalid the client mints its OWN token and commits it with no serial and no
#           seat, so token->seat == NULL: valid=false, and the default declines
#           (urgent set, focus not stolen).
#
# THE VALID FOCUS IS THE ACTIVATION'S, NOT THE MAP'S. A focus=false rule on the
# probe app_ids suppresses focus-on-open in the stock config, so a probe maps
# unfocused and only its activation can move the seat. A holder client of another
# app_id (no rule) owns focus across both legs, so "focus moved to the probe" and
# "focus stayed on the holder" are both real transitions, not nil->nil.
#
# C RANKS NOTHING: kiln never focuses on activation. The whole decision is
# kiln.defaults.activate reading ctx.valid, which a config replaces wholesale by
# assigning its own handler. This battery leaves the stock default in place and
# asserts its two outcomes.
#
# MANUAL, not claimed passed here: a real token-minting launcher on a
# live session. In rc.lua bind kiln.spawn_with_token("wofi --show drun"); pick an
# app; it opens focused (the launcher handed it a seat-backed token). A client
# raising itself off a stale token is declined: it flags urgent and does not
# steal the seat.
#
# Needs: nothing beyond the build (wl-activate is a tree fixture).
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/kiln-activate-test.XXXXXX)"
sock="$work/kiln.sock"
log="$work/kiln.log"
rc="$work/rc.lua"
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

# The rc under test: one tag per screen, the STOCK kiln.defaults.activate left in
# place (this config never mentions activation, which is the point), a focus=false
# rule so the probes map unfocused, and a recorder that keeps the last event's
# facts for readback. The recorder runs ALONGSIDE the default (emit fires every
# class handler), it does not replace it.
cat >"$rc" <<'EOF'
local kiln = require("kiln")
screen.on("added", function(s)
	tag.new { name = "one", screen = s, layout = kiln.layout.tile }
	s.tags[1]:view()
end)
kiln.rule {
	match_any = { app = { "kiln.activate.valid", "kiln.activate.invalid" } },
	props = { focus = false },
}
client.on("request::activate", function(c, ctx)
	LAST_ACTIVATE = { valid = ctx.valid, app_id = ctx.app_id, app = c.app_id }
end)
EOF

# No subshell: $! must be kiln itself, or cleanup kills the wrapper and
# orphans the compositor to init (the capture-test.sh rule).
cd "$repo"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
	KILN_RC="$rc" KILN_SOCK="$sock" ./build/kiln > "$log" 2>&1 &
kiln_pid=$!
sleep 2

check "the compositor booted" "yes" \
	"$(grep -q 'Running Wayland compositor' "$log" && echo yes || echo no)"
# The manager has no Lua handle; that it is created and advertised is proven
# functionally by the valid round trip below. Here just the mint verb is bound.
check "the spawn_with_token verb is bound" "function" \
	"$(eval_kiln 'return type(require("kiln").spawn_with_token)')"

# The focus of the client with a given app_id, or a marker. Walks client.all()
# so a client that mapped and left stops answering (no stale box).
focus_app() { eval_kiln 'return client.focus and client.focus.app_id or "-"'; }
prop() { # app_id lua-expr-over-c
	eval_kiln "for _, c in ipairs(client.all()) do
	  if c.app_id == '$1' then return tostring($2) end
	end
	return 'no-client'"
}
last() { eval_kiln "return LAST_ACTIVATE and tostring(LAST_ACTIVATE.$1) or 'nil'"; }

# =====================================================================
echo "== a holder owns the seat (focus-on-open, no rule)"
eval_kiln 'require("kiln").spawn({"'"$repo"'/build/wl-activate", "hold", "kiln.holder"})' >/dev/null
sleep 3
check "the holder mapped and took focus" "kiln.holder" "$(focus_app)"

# =====================================================================
echo "== valid: a seat-backed token focuses the right client"
eval_kiln 'require("kiln").spawn_with_token({"'"$repo"'/build/wl-activate", "valid", "kiln.activate.valid"})' >/dev/null
sleep 3
check "the valid probe mapped" "true" "$(prop kiln.activate.valid 'c.mapped ~= false')"
check "C derived valid=true from the seat-backed token" "true" "$(last valid)"
check "the default focused the valid probe (off the holder)" "kiln.activate.valid" "$(focus_app)"
check "focus-on-open was suppressed, so activation is what focused it" "true" \
	"$(prop kiln.activate.valid 'c.no_focus == true')"

# =====================================================================
echo "== invalid: a stale token is declined"
# Return the seat to the holder so the decline has something to not-steal from.
h_holder=$(prop kiln.holder 'c.handle')
eval_kiln "require('kiln.object').lookup($h_holder):focus()" >/dev/null
sleep 0.6
check "the holder holds the seat again" "kiln.holder" "$(focus_app)"

eval_kiln 'require("kiln").spawn({"'"$repo"'/build/wl-activate", "invalid", "kiln.activate.invalid"})' >/dev/null
sleep 3
check "the invalid probe mapped" "true" "$(prop kiln.activate.invalid 'c.mapped ~= false')"
check "C derived valid=false from the unbacked token" "false" "$(last valid)"
check "the token app_id rode through as the payload hint" "kiln.activate.invalid" "$(last app_id)"
check "the default declined: the seat stayed on the holder" "kiln.holder" "$(focus_app)"
check "the default flagged the declined probe urgent" "true" "$(prop kiln.activate.invalid 'c.urgent == true')"

# =====================================================================
# No bus error, no duplicate-tree watchdog line snuck through.
#
# The pattern is "error in '", not "bus error in": bus.lua's DEFAULT
# on_error prints "bus error in '...'", but init.lua overrides it to print
# "kiln: error in '...'", and the override is what the real library installs.
# The shared substring catches either sink.
#
# The leg proves it can fail: KILN_BUS_PROBE=1 raises one real error through
# bus.lua's pcall, so the grep below MUST go red under it. A pattern never proven
# able to fail is just a relocated vacuous assert.
if [ -n "${KILN_BUS_PROBE:-}" ]; then
	eval_kiln 'local B = require("kiln.bus")
local b = B.new()
b:on("busprobe", function() error("injected") end)
b:emit("busprobe")' >/dev/null
fi

check "no bus errors, no tree/scene divergence, no duplicate ids" "0" \
	"$(grep -cE "error in '|tree==scene:|DUPLICATE" "$log" || true)"

eval_kiln 'core.quit()' >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
	echo "PASS"
else
	echo "FAIL"
	exit 1
fi
