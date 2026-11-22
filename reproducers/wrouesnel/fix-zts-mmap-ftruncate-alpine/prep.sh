#!/bin/bash
# prep.sh ROOT -- run in the userland builder by builder/in/demo-disk.sh after
# the ZTS scripts are packed.  It edits this image's copy of the runner
# (ROOT/demo.sh = builder/in/zts-run.sh):
#   - after the oops watcher starts, it starts /demo/slow_pool.sh in the
#     background: once mmap_ftruncate creates its file, every I/O to the
#     pool's leaves is delayed 200 ms, one at a time (the slow alpine3-24 CI
#     runners), and the program's phases are timed from outside;
#   - just before the RESULT, it prints slow_pool.sh's log: the whole run
#     against the time of the final ftruncate(fd, 0).
# Any edit not applying exactly once fails the build.
set -euo pipefail
R=${1:?root}
f=$R/demo.sh
n=$(grep -c '^	oops_watch$' "$f" || true)
[ "$n" = 1 ] || { echo "prep.sh: the runner's oops_watch call not found ($n)" >&2; exit 1; }
sed -i '/^	oops_watch$/a\	# (prep.sh of this reproducer) a slow pool, as on the alpine3-24 CI runners, beside the tests\
	( PATH=/usr/sbin:/usr/bin:/sbin:/bin /demo/slow_pool.sh 200 >/run/zts/slow_pool.log 2>&1 ) \&' "$f"
n=$(grep -c '^	if \[ -n "\$fails" \]; then$' "$f" || true)
[ "$n" = 1 ] || { echo "prep.sh: the runner's RESULT block not found ($n)" >&2; exit 1; }
sed -i '/^	if \[ -n "\$fails" \]; then$/i\	# (prep.sh of this reproducer) the slow pool, and the timings of mmap_ftruncate\
	echo "# the slow pool and mmap_ftruncate, timed from outside (slow_pool.sh):"; fold -s -w 76 /run/zts/slow_pool.log 2>/dev/null | sed "s/^/    /"' "$f"
for L in repro fixed; do
	[ -f "$R/zts/$L/tests.list" ] && echo "prep.sh: $L ($(head -1 "$R/zts/$L/commit")): $(cut -d' ' -f2 "$R/zts/$L/tests.list" | tr '\n' ' ')"
done
{
	echo
	echo "# ======== slow_pool.sh (this reproducer; prep.sh starts it beside the tests)"
	cat "$R/slow_pool.sh"
} >>"$f"
