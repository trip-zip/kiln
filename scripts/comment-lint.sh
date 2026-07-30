#!/bin/sh
# Comment lint: a comment explains why, in the code's own terms, and never
# references anything outside the code. This greps every comment line for the
# banned reference classes (issue numbers, spec section ids, milestone/shard
# shorthand, dates, planning vocabulary, prior-art names, doc paths, and
# file:line citations) and fails when any survive the allowlist.
#
# Usage: scripts/comment-lint.sh [file...]   (no args = the whole tree)

set -u

PATTERN='#[0-9]+|spec [0-9]|s[0-9]+b?\.[0-9]|6b\.[0-9]|\bM[0-9]+ S[0-9]\b|20[0-9]{2}-[0-9]{2}-[0-9]{2}|docs/|ideas/|somewmrc|[a-zA-Z_]+\.(c|h|lua):[0-9]|\bfalsifier|\bpriced\b|\bledger\b|\bnumerator\b|RECIPE|\bstratum\b|\bamendment\b|\berratum\b|tinywl|TinyWL|\bdwl\b|\bawful\b|\bawesome\b|\bnaughty\b|\bsomewm\b|SomeWM'

# Lines a banned token may legitimately sit on:
#   - CDEF-* machine directives (parsed by scripts/gen-cdef-guard.py, not prose)
#   - in-repo build-contract names: the vendored clay.h and the guard script
#   - hex colors (#rrggbb) that begin with digits
#   - hit-test ids (on_press:tag#3), whose instance suffix is a # plus a digit
ALLOW='CDEF-(BEGIN|END|INCLUDE|ENUM)|third_party/clay\.h|gen-cdef-guard|#[0-9a-fA-F]{6}\b|on_[a-z]+:[^ ]*#[0-9]'

if [ "$#" -gt 0 ]; then
	files="$*"
else
	files="$(ls ./*.c ./*.h kilnrc.lua stress.lua \
		lua/kiln/*.lua meson.build scripts/*.sh scripts/*.py scripts/*.c \
		scripts/*.lua scripts/kiln-eval 2>/dev/null)"
fi

fail=0
for f in $files; do
	case "$f" in
	*.sh | *.py | */kiln-eval | *meson.build)
		# Whole-line # comments only: a # inside a shell/awk/Lua string on a
		# code line (hit ids, gauge greps) is code, not prose.
		hits=$(grep -nE "$PATTERN" "$f" \
			| grep -E '^[0-9]+:[[:space:]]*#([^!]|$)' | grep -vE "$ALLOW")
		;;
	*.lua)
		hits=$(grep -nE "$PATTERN" "$f" | grep -E -- '--' \
			| sed -E 's/^([0-9]+):.*(--.*)$/\1:\2/' \
			| grep -E "$PATTERN" | grep -vE "$ALLOW")
		;;
	*)
		hits=$(grep -nE "$PATTERN" "$f" \
			| grep -E ':[[:space:]]*(/\*|\*([[:space:]]|/)|//)|/\*' \
			| grep -vE "$ALLOW")
		;;
	esac
	if [ -n "$hits" ]; then
		printf '%s\n' "$hits" | sed "s|^|$f:|"
		fail=1
	fi
done

if [ "$fail" -eq 0 ]; then
	echo "comment-lint: clean"
fi
exit "$fail"
