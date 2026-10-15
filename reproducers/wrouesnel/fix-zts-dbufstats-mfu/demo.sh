#!/bin/bash
# demo.sh -- bug #81 (test-only, #19341): ZTS arc/dbufstats_002_pos flakes on
# fast runners ("mfu count is 0", 3 of 230 CI jobs).  It writes a file, syncs,
# checks its dbufs are on the ARC's MRU list, reads the file and expects some
# on the MFU list.  arc_access() only promotes an MRU buffer when the hit
# comes more than ARC_MINTIME (62 ms) after its previous access (the write
# at the sync), so if the read follows the sync quickly the buffers stay MRU.
# Master's test has only the dbufstat (Python) calls in between; the fix
# (a1157c5e1) sleeps 1 s before the read.
#
# The two builds' ZFS code is the same; what differs is the test.  The image
# carries each commit's dbufstats_002_pos.ksh (/demo/zts/LABEL/, from `git
# show REF:...`) and runs the one of the booted build with ksh93 and a small
# stand-in for the ZTS library (/demo/zts/include/libtest.shlib).  Its
# dbufstat is an awk filter over /proc/spl/kstat/zfs/dbufs, so the steps
# between the sync and the read take milliseconds, as on the CI runners
# where the test failed (the Python dbufstat usually takes longer than
# 62 ms, which is why master's test passes on most machines).
# Run as root:  /demo/demo.sh      about 10 seconds.
# What you will see: 3 runs of the test, each printing the dbuf, MRU and MFU
# counts after the sync and after the read:
#   repro build (68188d1ff = master's test): after the read "mfu count is 0",
#     "FAIL: Compared mfu count should be not equal: 0 == 0", 3/3:
#     "RESULT BUG"
#   fixed build (a1157c5e1): "sleep 1", then a non-zero MFU count, PASS 3/3:
#     "RESULT OK"
# The pool is set up as the arc group's setup.ksh does (default_setup: pool
# p81 on the run disk $DEMO_DISK, $TESTPOOL/$TESTFS on $TESTDIR); exported at
# the end.
set -u
. /etc/demo-env 2>/dev/null
build=${DEMO_BUILD:-${1:-repro}}
T=/demo/zts/$build/dbufstats_002_pos.ksh
[ -f "$T" ] || { echo "RESULT ERROR: no test for build '$build' ($T)"; exit 2; }
d=/var/tmp/p81d; pool=p81
V=${DEMO_DISK:-$d/v0}
zpool destroy -f $pool 2>/dev/null; rm -rf $d; mkdir -p $d
[ -n "${DEMO_DISK:-}" ] || truncate -s 1G $V
export STF_SUITE=/demo/zts TESTPOOL=$pool TESTFS=testfs TESTDIR=/var/tmp/p81d/testdir
echo "# setup (as arc/setup.ksh): pool $pool on $V, $TESTPOOL/$TESTFS on $TESTDIR"
zpool create -f -o cachefile=none $pool $V && zfs create -o mountpoint=$TESTDIR $pool/$TESTFS ||
    { echo "RESULT ERROR: could not create pool $pool on $V"; exit 2; }
echo "# the test's steps between the sync and the read ($T):"
sed -n '/^sync_all_pools/,/cat \$TESTDIR/p' $T | grep -v '^#\|^$' | sed 's/^/  /'
fail=0 pass=0
for i in 1 2 3; do
	echo
	echo "# run $i: ksh $T"
	ksh $T; rc=$?
	case $rc in 0) pass=$((pass + 1)) ;; 1) fail=$((fail + 1)) ;; *) echo "(exit $rc)" ;; esac
done
zpool export $pool && echo "# pool $pool exported (on $V)"
echo
if [ $((pass + fail)) -ne 3 ]; then
	echo "RESULT ERROR: only $((pass + fail))/3 runs passed or failed"; exit 2
elif [ $fail -gt 0 ]; then
	echo "RESULT BUG: dbufstats_002_pos failed $fail/3 (no MRU->MFU promotion when the read follows the sync quickly)"
else
	echo "RESULT OK: dbufstats_002_pos passed 3/3"
fi
