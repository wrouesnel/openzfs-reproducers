#!/bin/bash
# demo.sh -- bug #69 (openzfs/zfs#13679): detaching the device a healing
# resilver is writing to leaves the resilver running with nothing to do.
# `zpool status` keeps saying "resilver in progress", a sequential attach
# (`zpool attach -s`) is refused, and with scan progress suspended (as here,
# to hold the race window open) it never ends.  dsl_scan only ended a
# resilver when it finished its pass; the fix ends it once no device needs it.
#
# Image version of the first case of the ZTS test
# replacement/resilver_detach_target (test commit 129bc1125).
# Run as root:  /demo/demo.sh      about 20 s (unfixed) or 10 s (fixed).
# What you will see: a mirror of the first two run disks with 32 MiB of
# data; zfs_scan_suspend_progress=1 so a resilver makes no progress; then
#   zpool attach (third run disk) -> "resilver in progress"
#   zpool detach (that disk), then up to 15 s of `zpool status` scan lines:
#     unfixed (test commit 129bc1125): still "resilver in progress" after
#       15 s, and `zpool attach -s` is refused: "RESULT BUG"
#     fixed (fix-resilver-detached-target c2451409c): the resilver ends
#       ("resilvered ... canceled"/no scan) within a second or two, the
#       sequential attach is accepted: "RESULT OK"
#   if the first resilver never shows up: "RESULT ERROR".
# Pool p69 on the run disks $DEMO_DISKS (3), or files in /var/tmp/p69d; it is
# exported at the end (vm/demo-vm.sh 69 LABEL --disk ... can import it).
set -u
pool=p69 P=/sys/module/zfs/parameters
read -r -a V <<< "${DEMO_DISKS:-}"
if [ ${#V[@]} -lt 3 ]; then
	d=/var/tmp/p69d; rm -rf $d; mkdir -p $d
	V=(); for i in 0 1 2; do truncate -s 512M $d/v$i; V+=($d/v$i); done
fi
v0=${V[0]} v1=${V[1]} sp=${V[2]}
resilvering() { zpool status $pool | grep -q 'resilver in progress'; }
scanline() { zpool status $pool | sed -n 's/^ *scan: //p' | head -1; }
zpool destroy -f $pool 2>/dev/null
zpool create -f -o cachefile=none $pool mirror $v0 $v1 ||
    { echo "RESULT ERROR: could not create pool $pool"; exit 2; }
dd if=/dev/urandom of=/$pool/file bs=1M count=32 2>/dev/null; zpool sync $pool
echo 50 >$P/zfs_resilver_min_time_ms
echo 1 >$P/zfs_scan_suspend_progress
echo "# pool $pool: mirror $v0 $v1, 32 MiB; zfs_scan_suspend_progress=1"
echo
echo "# zpool attach $pool $v0 $sp"
zpool attach $pool $v0 $sp
for _ in $(seq 30); do resilvering && break; sleep 0.5; done
resilvering || { echo 0 >$P/zfs_scan_suspend_progress; echo "RESULT ERROR: no resilver started"; exit 2; }
echo "  scan: $(scanline)"
echo "# zpool detach $pool $sp"
zpool detach $pool $sp
gone=no
for i in $(seq 15); do
	sleep 1
	echo "  after ${i}s: scan: $(scanline)"
	resilvering || { gone=yes; break; }
done
echo "# zpool attach -s $pool $v0 $sp   (a sequential resilver)"
if out=$(zpool attach -s $pool $v0 $sp 2>&1); then seq=accepted; else seq=refused; fi
echo "  $seq${out:+: $out}"
echo 0 >$P/zfs_scan_suspend_progress
zpool wait -t resilver $pool
[ $seq = accepted ] && zpool detach $pool $sp
zpool status $pool | sed -n '/config:/,/errors:/p' | grep -v '^$'
zpool export $pool && echo "# pool $pool exported (on ${V[*]})"
echo
if [ $gone = no ]; then
	echo "RESULT BUG: the resilver kept running for 15 s after its target was detached (sequential attach $seq)"
elif [ $seq = refused ]; then
	echo "RESULT ERROR: the resilver ended but the sequential attach was refused"; exit 2
else
	echo "RESULT OK: the resilver ended when its target was detached"
fi
