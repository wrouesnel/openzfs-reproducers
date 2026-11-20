#!/bin/bash
# prep.sh ROOT -- bug #274, run in the userland builder by
# builder/in/demo-disk.sh after the ZTS scripts are packed.  It edits this
# image's copy of the runner (ROOT/demo.sh = builder/in/zts-run.sh):
#   - after the oops watcher starts, it starts /demo/inject_mmp_delay.sh in
#     the background: once MMP writes to testpool, every write to its leaf is
#     delayed 1.5 s for 3 s (the CI stall: one MMP write took 1.25 s);
#   - just before the RESULT, it prints the injector's log and the pools'
#     kernel state (a suspended pool left behind shows as SUSPENDED).
# Any edit not applying exactly once fails the build.
set -euo pipefail
R=${1:?root}
f=$R/demo.sh
n=$(grep -c '^	oops_watch$' "$f" || true)
[ "$n" = 1 ] || { echo "prep.sh: the runner's oops_watch call not found ($n)" >&2; exit 1; }
sed -i '/^	oops_watch$/a\	# (prep.sh of this reproducer) the MMP write stall, beside the tests\
	( PATH=/usr/sbin:/usr/bin:/sbin:/bin /demo/inject_mmp_delay.sh testpool 1500 3 >/run/zts/inject.log 2>&1 ) &' "$f"
n=$(grep -c '^	if \[ -n "\$fails" \]; then$' "$f" || true)
[ "$n" = 1 ] || { echo "prep.sh: the runner's RESULT block not found ($n)" >&2; exit 1; }
sed -i '/^	if \[ -n "\$fails" \]; then$/i\	# (prep.sh of this reproducer) the injection, and what is left imported\
	echo "# the MMP write stall (inject_mmp_delay.sh):"; sed "s/^/    /" /run/zts/inject.log 2>/dev/null\
	echo "# pools still imported after the run, kernel state:"\
	for k in /proc/spl/kstat/zfs/*/state; do [ -e "$k" ] \&\& echo "    $(basename "$(dirname "$k")"): $(cat "$k")"; done\
	ls /proc/spl/kstat/zfs/*/state >/dev/null 2>\&1 || echo "    (none)"' "$f"
for L in repro fixed; do
	[ -f "$R/zts/$L/tests.list" ] && echo "prep.sh: $L ($(head -1 "$R/zts/$L/commit")): $(cut -d' ' -f2 "$R/zts/$L/tests.list" | tr '\n' ' ')"
done
{
	echo
	echo "# ======== inject_mmp_delay.sh (this reproducer; prep.sh starts it beside the tests)"
	cat "$R/inject_mmp_delay.sh"
} >>"$f"
