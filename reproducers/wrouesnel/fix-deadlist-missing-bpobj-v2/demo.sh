#!/bin/bash
# demo.sh -- wrouesnel/fix-deadlist-missing-bpobj-v2 (openzfs/zfs#19879).
# A dataset's deadlist has an entry whose bpobj is missing (in the issue, a
# failing DIMM).  The demo makes that damage with zhack and then takes a
# snapshot of the dataset, which loads the deadlist's tree:
#   master: txg_sync panics, VERIFY0(bpobj_open(...)) failed (2) in
#           dsl_deadlist_load_tree(); the snapshot never returns.
#   fix:    the entry is reported as lost and treated as empty; the
#           snapshot, a free into the lost entry and the destroys work, the
#           lost entry's blocks are counted as leaked, the pool stays healthy.
set -u
. /etc/demo-env 2>/dev/null
P=dlbpobj
LOST=4294967296		# an object number the pool never allocates
x() { echo "# $*"; "$@"; }
panicked() { dmesg | grep -q 'PANIC at dsl_deadlist.c'; }
st() {	# zpool status -v, without waiting on a stuck pool (a D-state zpool can't be killed)
	echo "# zpool status -v $P"
	zpool status -v $P >/var/tmp/st.out 2>&1 & local p=$! i
	for i in $(seq 50); do kill -0 $p 2>/dev/null || break; sleep 0.1; done
	cat /var/tmp/st.out
	kill -0 $p 2>/dev/null && echo "  (zpool status has not returned after 5 s: the pool is stuck)"
}
bg() {	# bg CMD...: run CMD, wait up to 20 s; sets rc, or reports the panic
	local i
	echo "# $*"
	"$@" & local pid=$!
	for i in $(seq 200); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
	if kill -0 $pid 2>/dev/null; then
		echo "  (still running after 20 s)"
		if panicked; then
			echo; echo "# kernel log:"
			dmesg | grep -A14 'VERIFY0(bpobj_open' | grep -E 'VERIFY|PANIC|dsl_deadlist|dsl_dataset|dsl_sync|spa_sync|txg_sync' | sed 's/^/  KERNEL: /'
			echo; st
			echo
			echo "RESULT BUG: txg_sync PANIC: VERIFY0(bpobj_open(...)) failed (2) in dsl_deadlist_load_tree() on 'zfs snapshot' of a dataset whose deadlist entry has no bpobj; the pool is stuck"
			exit 1
		fi
		echo "RESULT ERROR: '$*' hangs without the panic"; exit 2
	fi
	wait $pid; rc=$?
}
die() { echo "RESULT ERROR: $*"; exit 2; }

echo "=== deadlist entry with a missing bpobj ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build), kernel $(uname -r))"
panicked && die "this boot already hit the panic; power off and boot the demo again"
zpool destroy $P 2>/dev/null
x zpool create -f -o cachefile=none -O compression=off $P $DEMO_DISK || die "zpool create failed"
for fs in a b; do
	x zfs create $P/$fs
	dd if=/dev/urandom of=/$P/$fs/file1 bs=128k count=8 status=none
	dd if=/dev/urandom of=/$P/$fs/file2 bs=128k count=8 status=none
	x zpool sync $P
	x zfs snapshot $P/$fs@s1
	x rm /$P/$fs/file1	# its blocks go to the head's deadlist, in an entry with a bpobj of its own
	x zpool sync $P
done
x zpool export $P || die "export failed"
echo
echo "## damage: free the bpobj of the last deadlist entry of $P/a and $P/b, keep the entries"
for fs in a b; do
	x zhack -d /dev deadlist damage -o $LOST $P/$fs || die "zhack deadlist damage $P/$fs failed"
done
x zpool import -d $DEMO_DISK $P || die "import failed"
st

echo
echo "## a: snapshot it (loads the head's deadlist: the path in #19879)"
bg zfs snapshot $P/a@s2
[ $rc = 0 ] || die "zfs snapshot $P/a@s2 failed ($rc)"
x zpool sync $P
echo "# kernel report:"
{ dmesg; cat /proc/spl/kstat/zfs/dbgmsg; } | grep -F "bpobj $LOST is lost" | sort -u | sed 's/^/  /'
reported=$({ dmesg; cat /proc/spl/kstat/zfs/dbgmsg; } | grep -cF "bpobj $LOST is lost")
bg zfs destroy $P/a@s1; [ $rc = 0 ] || die "zfs destroy $P/a@s1 failed"
bg zfs destroy -r $P/a; [ $rc = 0 ] || die "zfs destroy -r $P/a failed"

echo
echo "## b: free blocks into the lost entry, then destroy it"
x rm /$P/b/file2
bg zpool sync $P
bg zfs destroy -r $P/b; [ $rc = 0 ] || die "zfs destroy -r $P/b failed"
x zpool wait -t free $P
x zpool sync $P
leaked=$(zpool get -Hp -o value leaked $P)
echo "# zpool get leaked $P: $leaked"
st
health=$(zpool list -H -o health $P)
x zpool export $P || die "export failed"
x zpool import -d $DEMO_DISK $P || die "re-import failed"
st
health2=$(zpool list -H -o health $P)
x zpool export $P
echo
if panicked; then
	echo "RESULT BUG: txg_sync PANIC in dsl_deadlist_load_tree() (late)"; exit 1
elif [ "$reported" -gt 0 ] && [ "${leaked:-0}" -gt 0 ] 2>/dev/null && [ "$health" = ONLINE ] && [ "$health2" = ONLINE ]; then
	echo "RESULT OK: the lost bpobj was reported, snapshot/free/destroy all worked, $leaked bytes counted as leaked, pool ONLINE after export/import"
else
	echo "RESULT ERROR: no panic, but reported=$reported leaked=$leaked health=$health/$health2"; exit 2
fi
