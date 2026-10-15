#!/bin/bash
# demo.sh -- bug #125: the ZTS test cli_root/zpool_import/zpool_import_parallel_admin
# flakes in CI: "test 2 -gt 2.915".  It imports testpool1 with a 10 s injected
# delay (zinject -P import -s 10) and checks that commands to testpool2 aren't
# blocked behind it by requiring each to take under 2 s; on a slow runner
# testpool2's `zpool add ... cache` took 2.9 s.  The fix (a test-only change)
# checks the order instead: each testpool2 command must finish while testpool1
# is still listed in the import_progress kstat, i.e. still loading.  A command
# that waits for the import can only finish after that.
#
# The ZFS code of the two builds is the same; what differs is the test, so
# the image carries each commit's zpool_import_parallel_admin.ksh
# (/demo/zts/LABEL/) and runs the one matching the booted build with ksh93
# and a small stand-in for the ZTS library.  A `zpool` wrapper (/demo/zpool,
# first in PATH) slows testpool2's `zpool add` by 4 s (ZPOOL_MODE=slow), or
# makes it wait for testpool1's import for real (ZPOOL_MODE=blocked: it runs
# `zpool list testpool1` first, which the kernel holds until the load is over).
# Builds: bug = b060bcb1d (master's test), fix = fix-zts-import-parallel-admin.
# Run as root:  /demo/demo.sh      about 60 seconds (4 runs of ~13 s).
# What you will see:
#   3 runs with the slow `zpool add`, then 1 with the blocked one:
#   bug build: slow FAIL 3/3 ("test 2 -gt 4.0..."), blocked FAIL -> "RESULT BUG"
#   fix build: slow PASS 3/3, blocked FAIL ("finished after testpool1's
#              import") -> "RESULT OK" (the new test still catches a real block)
# File vdevs in /var/tmp/dev_import-test, new for each run; the pools are
# destroyed by the test.
set -u
. /etc/demo-env 2>/dev/null
build=${DEMO_BUILD:-${1:-repro}}
T=/demo/zts/$build/zpool_import_parallel_admin.ksh
[ -f "$T" ] || { echo "RESULT ERROR: no test for build '$build' ($T)"; exit 2; }
ZPOOL=$(command -v zpool) d=/var/tmp/p125d
rm -rf $d; mkdir -p $d/bin
ln -s /demo/zpool $d/bin/zpool
export PATH=$d/bin:$PATH ZPOOL STF_SUITE=/demo/zts

echo "# the test of the $build build: $T"
grep -nE 'test "2" -gt|importing "injecting"|state == "during"|^sleep 2' $T | sed 's/^/  /'
slow_fail=0 slow_pass=0 blocked=
for mode in slow slow slow blocked; do
	echo
	# new vdev files for each run, as the ZTS group setup makes them: a
	# device that still has a cache label from the last run makes
	# `zpool add` look through every pool, testpool1 included
	rm -rf /var/tmp/dev_import-test; mkdir -p /var/tmp/dev_import-test
	for i in 0 1 2 3 4; do truncate -s 128M /var/tmp/dev_import-test/disk$i; done
	echo "# ZPOOL_MODE=$mode ksh $T"
	ZPOOL_MODE=$mode ksh $T >$d/out 2>&1; rc=$?
	grep -E '^testpool2: |^FAIL|^PASS|^ERROR' $d/out | sed 's/^/  /'
	case $mode:$rc in
	slow:0) slow_pass=$((slow_pass + 1)) ;;
	slow:1) slow_fail=$((slow_fail + 1)) ;;
	blocked:0) blocked=PASS ;;
	blocked:1) blocked=FAIL ;;
	*) echo "  (exit $rc)"; tail -5 $d/out | sed 's/^/  /' ;;
	esac
done
rm -rf /var/tmp/dev_import-test
echo
r="slow zpool add: FAIL $slow_fail/3, PASS $slow_pass/3; blocked zpool add: ${blocked:-none}"
if [ $((slow_fail + slow_pass)) -ne 3 ] || [ -z "$blocked" ]; then
	echo "RESULT ERROR: a run neither passed nor failed ($r)"; exit 2
elif [ $slow_fail -gt 0 ]; then
	echo "RESULT BUG: the test fails when zpool add is only slow ($r)"
elif [ $blocked = FAIL ]; then
	echo "RESULT OK: a slow zpool add passes, a blocked one still fails ($r)"
else
	echo "RESULT BUG: the test no longer catches a blocked command ($r)"
fi
