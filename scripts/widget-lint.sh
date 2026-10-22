#!/bin/sh
# Widget lint: the stock widgets' contract is that every one is what a config
# would have written in the public element API, written once. This makes the
# claim mechanical instead of asserted: every external name a widget reaches
# for must be a blessed public require, a blessed dotted read, or the widgets
# table's own name. ui.* and the module-local widgets table are locals, so
# they never surface in the global scan; they are the two allowed
# vocabularies. Anything else is a private door a config could not walk
# through with the same spelling, and a widget using one is no longer a
# config program.
#
# Usage: scripts/widget-lint.sh [file...]   (no args = lua/kiln/widgets.lua)

set -u

# Every external-looking token in non-comment code: require calls, plus
# dotted reads off the public globals and off the module tables a widget
# binds locally (state, kiln). The dot after the root is what separates a
# global read from a same-named field or method elsewhere on the line.
PATTERN='require\("[^"]*"\)|\b(core|state|client|screen|tag|layer|drag|notification|kiln)\.[a-zA-Z_.]+'

# The blessed surface. The test each entry passes: a config reaches the same
# name with the same spelling.
#   - the public modules the widgets compose with
#   - core.box / core.dirty / core.timer / core.timer_cancel /
#     core.input.set_cursor, documented core API
#   - state.theme (the same table kiln.theme names), any depth into it
#   - the client global, a documented public global
#   - kiln.widgets, the module's own public name (it appears in diagnostics
#     as a string, which the scan cannot tell from code and need not)
ALLOW=':(require\("kiln\.(ui|state|grab|icon|layout|systray)"\)|core\.(box|dirty|timer|timer_cancel|tray_activate|input\.set_cursor)|state\.theme(\.[a-zA-Z_.]+)?|screen\.all|client\.[a-zA-Z_.]+|kiln\.widgets(\.[a-zA-Z_.]+)?)$'

if [ "$#" -gt 0 ]; then
	files="$*"
else
	files="lua/kiln/widgets.lua"
fi

fail=0
for f in $files; do
	# Comment tails are stripped first so prose naming an unblessed symbol
	# does not fail the lint; sed keeps the line count so numbers stay true.
	hits=$(sed -E 's/--.*//' "$f" | grep -noE "$PATTERN" | grep -vE "$ALLOW")
	if [ -n "$hits" ]; then
		printf '%s\n' "$hits" | sed "s|^|$f:|"
		fail=1
	fi
done

if [ "$fail" -eq 0 ]; then
	echo "widget-lint: clean"
fi
exit "$fail"
