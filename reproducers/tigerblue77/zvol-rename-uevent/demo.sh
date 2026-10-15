#!/bin/bash
# demo.sh -- bug #129 (openzfs #19371, PR #19377): writes to a zvol fail with
# EPERM while the zvol, or a dataset above it, is renamed (Linux).
#
# zvol_os_rename_minor() sets the disk read-only and back to make the kernel
# send a "change" uevent (so udev moves the /dev/zvol links), and the block
# layer refuses writes with EPERM while the flag is set.
#
# Four writers (/demo/zvwrite) write 4 KiB O_DIRECT blocks to /dev/zdN in a
# loop, retrying after a failed write, while demo129/a/vol is renamed back
# and forth 25 times and then demo129/a 25 times (100 renames).  Meanwhile
# /demo/ueventmon counts the kernel's change uevents for zdN: the image has
# no udev, so that count stands in for "udev would still update the links".
#
# Run as root:  /demo/demo.sh       about 5 seconds.
#   bug build (test commit, = master):
#     -> "Operation not permitted N" on the writers' lines, "RESULT BUG"
#   fix build:
#     -> "failed 0" on every writer, 100 change uevents, "RESULT OK"
# Pool demo129 on the run disk $DEMO_DISK (vm/demo-vm.sh), or on the file
# /var/tmp/demo129/vdev when DEMO_DISK is unset; exported at the end.
set -u
D=/var/tmp/demo129; P=demo129
V=${DEMO_DISK:-$D/vdev}
BIN=${DEMO_BIN:-/demo}
zpool destroy -f $P 2>/dev/null; rm -rf $D; mkdir -p $D
[ -n "${DEMO_DISK:-}" ] || truncate -s 512M $V
zpool create -f -o cachefile=none -O mountpoint=none $P $V ||
    { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
zfs create $P/a && zfs create -V 64M $P/a/vol || { echo "RESULT ERROR: zfs create"; exit 2; }
zd=""
for i in $(seq 50); do
	zd=$(ls /sys/block | grep '^zd' | head -1)
	[ -n "$zd" ] && [ -b /dev/$zd ] && break
	sleep 0.1
done
[ -b /dev/$zd ] || { echo "RESULT ERROR: no /dev/zdN for $P/a/vol"; exit 2; }
echo "zvol $P/a/vol is /dev/$zd ($(cat /sys/module/zfs/version))"

stop=$D/stop
$BIN/ueventmon $zd $stop >$D/uevents & um=$!
until grep -q ready $D/uevents 2>/dev/null; do sleep 0.05; done
for w in 1 2 3 4; do $BIN/zvwrite /dev/$zd $stop 1 >$D/writer.$w & done
sleep 1
for i in $(seq 25); do
	zfs rename $P/a/vol $P/a/vol2 && zfs rename $P/a/vol2 $P/a/vol || { touch $stop; echo "RESULT ERROR: zfs rename failed"; exit 2; }
done
echo "renamed $P/a/vol <-> $P/a/vol2 25 times"
for i in $(seq 25); do
	zfs rename $P/a $P/b && zfs rename $P/b $P/a || { touch $stop; echo "RESULT ERROR: zfs rename failed"; exit 2; }
done
echo "renamed $P/a <-> $P/b 25 times"
touch $stop; wait
for w in 1 2 3 4; do echo "writer $w: $(cat $D/writer.$w)"; done
grep change $D/uevents
failed=$(awk '{ s += $NF } END { print s }' $D/writer.*)
ue=$(awk '/change uevents/ { print $NF }' $D/uevents)
zpool export $P && echo "pool $P exported (on $V)"
if [ "$failed" -gt 0 ]; then
	echo "RESULT BUG: $failed writes failed while the zvol was renamed"
elif [ "${ue:-0}" -lt 100 ]; then
	echo "RESULT ERROR: no write failed, but only ${ue:-0} of 100 change uevents were sent"
	exit 2
else
	echo "RESULT OK: no write failed, and every rename sent a change uevent"
fi
