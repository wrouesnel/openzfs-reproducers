#!/bin/bash
# demo.sh -- wrouesnel/fix-removal-suspend-svr-lifetime-v2 (openzfs/zfs#9357).
# The ZTS test removal_suspend_complete, step by step, twice: a pool of two
# 256 MiB files with 64 MiB of data; the test-only hook
# zfs_removal_suspend_complete_race is armed (1) and the first vdev removed.
# Once its copy is done the removal waits (stage 2) for a suspend; then
#   case export:  zpool export      (the zloop path, spa_async_suspend)
#   case cancel:  zpool remove -s   (must fail: the removal completed)
# The hook makes the woken suspend retake svr_lock late, after
# spa_finish_removal() has done its own suspend, and records:
#   stage 7 (master): the removal state was freed while the suspend still
#           used it ("removal freed under a suspend that waited")
#   stage 6 (fix):    it was freed only after the suspend was done
# Each case then checks the removal completed, the vdev is gone, the data
# is unchanged, a scrub is clean and zdb -cd passes.
set -u
. /etc/demo-env 2>/dev/null
P=rmsusp D=/var/tmp/rmsusp T=/sys/module/zfs/parameters/zfs_removal_suspend_complete_race
x() { echo "# $*"; "$@"; }
die() { echo "RESULT ERROR: $*"; echo 0 >$T 2>/dev/null; exit 2; }
stage() { cat $T; }
[ -w $T ] || die "this build has no zfs_removal_suspend_complete_race"
echo "=== suspend across a removal's completion ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build), kernel $(uname -r))"
declare -A ST OUT
bad=0
for c in export cancel; do
	echo; echo "## case $c"
	echo 0 >$T
	zpool destroy -f $P 2>/dev/null
	mkdir -p $D; rm -f $D/d1 $D/d2
	truncate -s 256M $D/d1 $D/d2
	x zpool create -f -O compression=off $P $D/d1 $D/d2 || die "zpool create failed"
	dd if=/dev/urandom of=/$P/file bs=1M count=64 status=none
	sum=$(sha256sum /$P/file | cut -d' ' -f1)
	x zpool sync $P
	echo "# echo 1 > zfs_removal_suspend_complete_race"; echo 1 >$T
	x zpool remove $P $D/d1 || die "zpool remove failed"
	for i in $(seq 600); do [ "$(stage)" = 2 ] && break; sleep 0.1; done
	echo "  stage $(stage): the removal's copy is done and it waits for a suspend"
	[ "$(stage)" = 2 ] || die "the removal never reached stage 2"
	if [ $c = export ]; then
		echo "# zpool export $P"
		out=$(zpool export $P 2>&1); rc=$?
		echo "  -> exit $rc${out:+: $out}"
		ST[$c]=$(stage)
		[ $rc = 0 ] || { OUT[$c]="export failed: $out"; }
		x zpool import -d $D $P || die "import failed"
	else
		echo "# zpool remove -s $P   (must fail: the removal completed)"
		out=$(zpool remove -s $P 2>&1); rc=$?
		echo "  -> exit $rc${out:+: $out}"
		ST[$c]=$(stage)
		[ $rc != 0 ] || OUT[$c]="remove -s succeeded"
	fi
	echo "  stage ${ST[$c]}: $(case ${ST[$c]} in 6) echo "the removal was freed after the suspend was done";; 7) echo "the removal was freed while the suspend still used it";; *) echo "the suspend didn't wait across the completion";; esac)"
	grep -h 'removal freed under a suspend' /proc/spl/kstat/zfs/dbgmsg | tail -1 | sed 's/^/  dbgmsg: /'
	echo 0 >$T
	x zpool sync $P
	echo "# zpool status -v $P"; zpool status -v $P
	zpool status $P | grep -q 'Removal of vdev .* completed' || OUT[$c]="${OUT[$c]:-} removal not complete"
	zpool list -v -H $P | grep -q "$D/d1" && OUT[$c]="${OUT[$c]:-} $D/d1 still in the pool"
	[ "$(sha256sum /$P/file | cut -d' ' -f1)" = "$sum" ] && echo "  data unchanged (sha256)" || OUT[$c]="${OUT[$c]:-} data changed"
	x zpool scrub -w $P
	zpool status $P | grep -q 'No known data errors' || OUT[$c]="${OUT[$c]:-} scrub errors"
	echo "# zdb -cd $P"; zdb -cd $P >$D/zdb.out 2>&1 && echo "  zdb ok" || { tail -5 $D/zdb.out; OUT[$c]="${OUT[$c]:-} zdb -cd failed"; }
	[ $c = cancel ] && x zpool export $P || x zpool destroy $P
	[ "${ST[$c]}" = 7 ] && bad=1
done
echo
s="export: stage ${ST[export]}${OUT[export]:+ (${OUT[export]# })}, remove -s: stage ${ST[cancel]}${OUT[cancel]:+ (${OUT[cancel]# })}"
if [ $bad = 1 ]; then
	echo "RESULT BUG: the removal was freed while a suspend still used it ($s)"; exit 1
elif [ "${ST[export]}" = 6 ] && [ "${ST[cancel]}" = 6 ] && [ -z "${OUT[export]:-}${OUT[cancel]:-}" ]; then
	echo "RESULT OK: the removal was freed only after the suspend was done; removal complete, data intact, scrub and zdb clean ($s)"
else
	echo "RESULT ERROR: $s"; exit 2
fi
