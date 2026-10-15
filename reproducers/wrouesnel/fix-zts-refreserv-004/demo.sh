#!/bin/bash
# demo.sh -- bug #114 (test-only; replaces #74): ZTS refreserv/refreserv_004_pos
# fails on every Linux and FreeBSD CI run (it is on zts-report's "known"
# list).  It sets a filesystem's refreservation to all the space its parent's
# quota leaves it ($avail), then writes a file of exactly $avail bytes with
# mkfile, and the write of the last, partial record is refused:
#   mkfile: initialized 10223616 of 10316800 bytes: Disk quota exceeded
# mkfile writes zeros (holes under compression), so it never tested the
# reservation; the fix (fix-zts-refreserv-004-v2 6ea2d556d) writes
# incompressible whole records, 1 MiB short of $avail, syncing after each,
# and checks the limit with a margin.
#
# The two builds' ZFS code is the same; what differs is the test.  The image
# carries each commit's refreserv_004_pos.ksh (/demo/zts/LABEL/, from `git
# show REF:...`) and runs the one of the booted build with ksh93, the ZTS
# helpers mkfile and file_write (/demo/bin), and a small stand-in for the ZTS
# library (/demo/zts/include/libtest.shlib).  The pool is set up as the
# refreserv group's setup.ksh does (compression=off, $TESTPOOL/$TESTFS).
# Run as root:  /demo/demo.sh      about 10-20 seconds.
# What you will see:
#   bug build (68188d1ff = master's test): "mkfile: initialized N of M bytes:
#     Disk quota exceeded", "FAIL: mkfile ... exited 1", "RESULT BUG"
#   fix build (6ea2d556d): the records written one by one, both log_mustnot
#     checks, "PASS", "RESULT OK"
# Pool p114 on the run disk $DEMO_DISK (vm/demo-vm.sh), or on the file
# /var/tmp/p114d/v0 when DEMO_DISK is unset; exported at the end.
set -u
. /etc/demo-env 2>/dev/null
build=${DEMO_BUILD:-${1:-repro}}
T=/demo/zts/$build/refreserv_004_pos.ksh
[ -f "$T" ] || { echo "RESULT ERROR: no test for build '$build' ($T)"; exit 2; }
d=/var/tmp/p114d; pool=p114
V=${DEMO_DISK:-$d/v0}
zpool destroy -f $pool 2>/dev/null; rm -rf $d; mkdir -p $d
[ -n "${DEMO_DISK:-}" ] || truncate -s 1G $V
export STF_SUITE=/demo/zts TESTPOOL=$pool TESTFS=testfs TESTDIR=/var/tmp/p114d/testdir
echo "# setup (as refreserv/setup.ksh): pool $pool on $V, compression=off, $TESTPOOL/$TESTFS on $TESTDIR"
zpool create -f -o cachefile=none $pool $V && zfs set compression=off $pool &&
    zfs create -o mountpoint=$TESTDIR $pool/$TESTFS ||
    { echo "RESULT ERROR: could not create pool $pool on $V"; exit 2; }
echo
echo "# ksh $T"
# the fixed test writes ~70 records (file_write, silent) with a `zpool sync`
# after each: those syncs are shown as one line
ksh $T 2>&1 | awk '
	/^SUCCESS: zpool sync [^-]/ { if (!n++) f = $0; next }
	n { print "SUCCESS: " n " x " substr(f, 10) " (one after each record written)"; n = 0 }
	{ print; fflush() }'
rc=${PIPESTATUS[0]}
echo "(exit $rc)"
zpool export $pool && echo "# pool $pool exported (on $V)"
echo
case $rc in
1) echo "RESULT BUG: refreserv_004_pos failed (the failure every CI run shows)" ;;
0) echo "RESULT OK: refreserv_004_pos passed" ;;
*) echo "RESULT ERROR: the test exited $rc"; exit 2 ;;
esac
