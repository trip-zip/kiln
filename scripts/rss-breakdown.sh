#!/bin/sh
# RSS breakdown of a running kiln: where every MB lives, categorized.
#
#   scripts/rss-breakdown.sh [pid]
#
# Without a pid, picks the newest kiln process. Reads /proc/<pid>/smaps_rollup
# for the totals and /proc/<pid>/smaps for the per-mapping map. No root needed
# for your own processes.
set -eu
# -x on the comm name first (immune to shells whose command line quotes a
# kiln path), then the anchored cmdline pattern for renamed binaries.
pid="${1:-$(pgrep -nx kiln || pgrep -n -f '(^|/)(build/)?kiln$' || true)}"
if [ -z "$pid" ] || [ ! -r "/proc/$pid/smaps" ]; then
	echo "rss-breakdown: no readable kiln pid (got '$pid')" >&2
	exit 1
fi

echo "== kiln pid $pid: $(tr '\0' ' ' < /proc/$pid/cmdline)"
echo "== totals (smaps_rollup, kB)"
grep -E '^(Rss|Pss|Pss_Anon|Pss_File|Pss_Shmem|Private_Dirty|Shared_Clean|Swap):' \
	"/proc/$pid/smaps_rollup"

echo "== by category (Rss kB)"
awk '
/^[0-9a-f]+-[0-9a-f]+ / {
	path = $6
	if (path == "") path = "[anon]"
	if (path == "[heap]")                          cat = "heap (malloc)"
	else if (path == "[anon]")                     cat = "anon (mmap: GL contexts, arenas, JIT)"
	else if (path ~ /^\/memfd:|^\/dev\/shm/)       cat = "shmem/memfd (wl_shm client buffers)"
	else if (path ~ /dmabuf|\/dev\/dri/)           cat = "GPU (dmabuf, dri)"
	else if (path ~ /libLLVM|libgallium|libGL|libEGL|libvulkan|_dri\.so/) \
	                                               cat = "GL/Mesa driver code"
	else if (path ~ /\/fonts\//)                   cat = "font files (mmap, shared)"
	else if (path ~ /\.so/)                        cat = "other shared libs"
	else                                           cat = "other file-backed"
}
/^Rss:/  { rss[cat] += $2 }
END { for (c in rss) printf "%10d  %s\n", rss[c], c }
' "/proc/$pid/smaps" | sort -rn

echo "== top mappings over 1 MB (Rss kB)"
awk '
/^[0-9a-f]+-[0-9a-f]+ / { path = $6; if (path == "") path = "[anon]" }
/^Rss:/ { rss[path] += $2 }
END { for (p in rss) if (rss[p] > 1024) printf "%10d  %s\n", rss[p], p }
' "/proc/$pid/smaps" | sort -rn
