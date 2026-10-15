#!/bin/bash
# demo.sh -- bug #120: the ZTS test crtime/crtime_001_pos flakes ("Incorrect
# crtime (1791857178 != 1791857179)", seen once on #19267's CI).  It is a test
# bug, not a ZFS bug: the test creates its file with touch(1), and GNU touch
# does open(O_CREAT) (sets crtime == ctime) and then utimensat(fd, NULL)
# (sets ctime again).  When a second boundary falls between the two, ctime
# is one second past crtime.  The fix (956f6a607) creates the file with a
# single `: > file` and sleeps 1 s before its second touch.
#
# The ZFS code of the two builds is the same (the fix only changes the test);
# what differs is the test, so the image carries each commit's
# crtime_001_pos.ksh (/demo/zts/LABEL/, from `git show REF:...`) and runs the
# one matching the booted build with ksh93 and a small stand-in for the ZTS
# library (/demo/zts/include/libtest.shlib).  To hit the race on every run, a
# `touch` wrapper (/demo/slowtouch, first in PATH) does what GNU touch does
# on a new file but waits for the next second between creating it and
# setting its times.
# Run as root:  /demo/demo.sh      about 10 seconds.
# What you will see: the wrapper at work (stat of a new file it made:
# crtime != ctime), then 3 runs of the test:
#   bug build (b060bcb1d = master's test): "FAIL: Incorrect crtime (N != N+1)"
#     in 3/3 runs, "RESULT BUG"
#   fix build (fix-zts-crtime-001-flake 956f6a607): PASS 3/3, "RESULT OK"
#   if the wrapper didn't open the race (crtime == ctime): "RESULT ERROR".
# Pool p120 on the run disk $DEMO_DISK (vm/demo-vm.sh), or on the file
# /var/tmp/p120d/v0 when DEMO_DISK is unset; exported at the end.
set -u
. /etc/demo-env 2>/dev/null
build=${DEMO_BUILD:-${1:-repro}}
T=/demo/zts/$build/crtime_001_pos.ksh
[ -f "$T" ] || { echo "RESULT ERROR: no test for build '$build' ($T)"; exit 2; }
d=/var/tmp/p120d; pool=p120
V=${DEMO_DISK:-$d/v0}
zpool destroy -f $pool 2>/dev/null; rm -rf $d; mkdir -p $d/bin
[ -n "${DEMO_DISK:-}" ] || truncate -s 256M $V
zpool create -f -o cachefile=none $pool $V && zfs create $pool/testdir ||
    { echo "RESULT ERROR: could not create pool $pool on $V"; exit 2; }
ln -s /demo/slowtouch $d/bin/touch
export PATH=$d/bin:$PATH STF_SUITE=/demo/zts TESTPOOL=$pool TESTDIR=/$pool/testdir

echo "# the touch wrapper on a new file: create, wait for the next second, set times"
touch /$pool/testdir/probe
cr=$(stat -c %W /$pool/testdir/probe) ct=$(stat -c %Z /$pool/testdir/probe)
echo "crtime $cr, ctime $ct"
rm -f /$pool/testdir/probe
[ "$cr" != "$ct" ] || { echo "RESULT ERROR: the wrapper did not separate crtime and ctime"; exit 2; }

echo
echo "# the test of the $build build: $T"
grep -nE 'touch|: >|sleep' $T | grep -v '^.*#' | sed 's/^/  /'
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
	echo "RESULT BUG: crtime_001_pos failed $fail/3 (the race the CI hit)"
else
	echo "RESULT OK: crtime_001_pos passed 3/3 with the slow touch"
fi
