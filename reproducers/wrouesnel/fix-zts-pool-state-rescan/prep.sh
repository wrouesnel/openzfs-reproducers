#!/bin/bash
# prep.sh ROOT -- run in the userland builder by builder/in/demo-disk.sh after
# the ZTS scripts are packed.  It edits this image's copy of the runner
# (ROOT/demo.sh = builder/in/zts-run.sh):
#   - after the oops watcher starts, it turns off the kernel's hung-task
#     warning (pool_state suspends testpool2 for 200 s on purpose, so a
#     blocked txg_sync is the test working, and in the break the pool stays
#     suspended: the runner would report the warning instead of the test's
#     FAIL; the group's cleanup then hangs on testpool2 until its timeout
#     KILLs it, as in CI), and it links /demo/flaky_lsscsi.sh as
#     lsscsi on the tests' PATH and starts `flaky_lsscsi.sh arm 3` in the
#     background: once pool_state removes its scsi_debug disk, the next 3
#     lsscsi calls that list the disk print "unexpected scan_for_first
#     error" in its device column (the CI flake, every time);
#   - after each test, it prints what the test and its own cleanup left
#     behind (after_test.sh: pools' kernel state, zpool list, zpool status
#     -v, the scsi_debug disk, the trigger's log), before the group's
#     cleanup can touch it;
#   - just before the RESULT, it prints the same once more, after the group's
#     cleanup.
# Any edit not applying exactly once fails the build.
set -euo pipefail
R=${1:?root}
f=$R/demo.sh
n=$(grep -c '^	oops_watch$' "$f" || true)
[ "$n" = 1 ] || { echo "prep.sh: the runner's oops_watch call not found ($n)" >&2; exit 1; }
sed -i '/^	oops_watch$/a\	# (prep.sh of this reproducer) lsscsi as in the CI flake: "unexpected" right after the rescan\
	echo 0 >/proc/sys/kernel/hung_task_timeout_secs; echo "# hung-task warnings off (this reproducer): pool_state suspends testpool2 for 200 s on purpose"\
	ln -sf /demo/flaky_lsscsi.sh /run/zts/bin/lsscsi; rm -f /run/zts/lsscsi.arm /run/zts/lsscsi.log\
	( PATH=/usr/sbin:/usr/bin:/sbin:/bin /demo/flaky_lsscsi.sh arm 3 ) &\
	echo "# lsscsi on the tests'"'"' PATH is /demo/flaky_lsscsi.sh (this reproducer): after remove_disk, its next 3 calls listing the scsi_debug disk print \\"unexpected scan_for_first error\\""' "$f"
n=$(grep -c '^			run_one "\$d" "\$t" "\$to"; rc=\$?$' "$f" || true)
[ "$n" = 1 ] || { echo "prep.sh: the runner's test run_one not found ($n)" >&2; exit 1; }
sed -i '/^			run_one "\$d" "\$t" "\$to"; rc=\$?$/a\			# (prep.sh of this reproducer) what the test and its own cleanup left behind\
			PATH=/usr/sbin:/usr/bin:/sbin:/bin /demo/after_test.sh "after $d/$t and its own cleanup, before the group'"'"'s cleanup"' "$f"
n=$(grep -c '^	if \[ -n "\$fails" \]; then$' "$f" || true)
[ "$n" = 1 ] || { echo "prep.sh: the runner's RESULT block not found ($n)" >&2; exit 1; }
sed -i '/^	if \[ -n "\$fails" \]; then$/i\	# (prep.sh of this reproducer) the final state, after the group'"'"'s cleanup\
	PATH=/usr/sbin:/usr/bin:/sbin:/bin /demo/after_test.sh "final state, after the group'"'"'s cleanup"' "$f"
for L in repro fixed; do
	[ -f "$R/zts/$L/tests.list" ] && echo "prep.sh: $L ($(head -1 "$R/zts/$L/commit")): $(cut -d' ' -f2 "$R/zts/$L/tests.list" | tr '\n' ' ')"
done
for s in flaky_lsscsi.sh after_test.sh; do
	echo
	echo "# ======== $s (this reproducer; prep.sh runs it)"
	cat "$R/$s"
done >>"$f"
