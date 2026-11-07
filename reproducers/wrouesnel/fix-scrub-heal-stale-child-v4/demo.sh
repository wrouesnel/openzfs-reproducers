#!/bin/bash
# demo.sh -- bug #127: a scrub that heals a cleared vdev reports the data the
# vdev's DTL already says it is missing as checksum errors.  This is the CI
# flake redundancy_draid_spare1 "Unexpected CKSUM errors" on a distributed spare.
#
# Builds (vm/demo-vm.sh 127 LABEL):
#   bug  5bb2c5551  the test commit on master b060bcb1d
#   fix  2e661a806  vdev_mirror: in a scrub, skip and repair children whose
#                   DTL is missing the txg, as a resilver does
#
# Cases: mirror(d0, d1), and draid2:3d:7c:2s on d0..d6 (LAYOUT=), each with
# a second top-level vdev mirror(m0, m1).  A child of the first
# vdev is faulted and misses writes (dRAID: it is replaced by distributed
# spare 0, then spare 1 is rebuilt sequentially; its spare columns
# that land on the faulted child go to spare 0 only).  A sequential rebuild of
# m1 is started and held (zfs_scan_suspend_progress=1), the faulted child is
# cleared (the resilver it requests is dropped while a rebuild is active), the
# rebuild finishes, and `zpool scrub` heals the child.
#   bug build: CKSUM errors reported by that scrub (mirror: on the child,
#              dRAID: on distributed spare 1) -> RESULT BUG
#   fix build: 0 CKSUM, the scrub still repairs the data -> RESULT OK
# Both builds: a second scrub repairs 0B (no data was ever lost).
# Run disks: 10 (DEMO_DISKS), or files in /var/tmp/demo127.
set -u
P=demo127; PP=/sys/module/zfs/parameters
read -r -a DISKS <<< "${DEMO_DISKS:-}"
if [ ${#DISKS[@]} -lt 10 ]; then
	D=/var/tmp/demo127; mkdir -p $D
	DISKS=(); for i in $(seq 0 9); do truncate -s 512M $D/d$i; DISKS+=($D/d$i); done
fi
LAYOUT=${LAYOUT:-draid2:3d:7c:2s}; NSP=${LAYOUT##*:}; NSP=${NSP%s}; PAR=${LAYOUT%%:*}; PAR=${PAR#draid}
cks() { zpool status -p $P | awk '!NF{v=0} v{e+=$NF} /CKSUM$/{v=1} END{print e+0}'; }
fill() { for i in $(seq $1); do dd if=/dev/urandom of=/$P/f.$RANDOM.$i bs=1M count=10 status=none; done; zpool sync $P; }
bad=0; vacuous=0
run_case() {	# mirror | draid
	local t=$1 m0 m1 m2 c rep
	echo; echo "=== case: $t ==="
	zpool destroy -f $P 2>/dev/null; for d in "${DISKS[@]}"; do zpool labelclear -f $d 2>/dev/null; done
	echo 0 > $PP/zfs_scan_suspend_progress; echo 0 > $PP/zfs_rebuild_scrub_enabled
	if [ $t = mirror ]; then
		m0=${DISKS[2]} m1=${DISKS[3]} m2=${DISKS[4]}
		zpool create -f -o cachefile=none -O compression=off $P \
		    mirror ${DISKS[0]} ${DISKS[1]} mirror $m0 $m1 || { echo "RESULT ERROR: create"; exit 2; }
		fill 10
		echo "+ zpool offline -f $P ${DISKS[0]}; write 100M more"
		zpool offline -f $P ${DISKS[0]}; fill 10
	else
		m0=${DISKS[7]} m1=${DISKS[8]} m2=${DISKS[9]}
		zpool create -f -o cachefile=none -O compression=off $P \
		    $LAYOUT ${DISKS[@]:0:7} mirror $m0 $m1 || { echo "RESULT ERROR: create"; exit 2; }
		fill 60
		for i in $(seq 0 $((NSP-1))); do
			echo "+ zpool offline -f $P ${DISKS[$i]}; zpool replace -w -s $P ${DISKS[$i]} draid$PAR-0-$i"
			zpool offline -f $P ${DISKS[$i]}
			zpool replace -w -s $P ${DISKS[$i]} draid$PAR-0-$i
			[ $i = 0 ] || zpool detach $P ${DISKS[$i]}
		done
	fi
	zpool scrub -w $P; echo "scrub with the child faulted: CKSUM $(cks)"
	echo "+ hold a sequential rebuild of $m1, then zpool clear $P ${DISKS[0]}"
	echo 1 > $PP/zfs_scan_suspend_progress
	zpool replace -f -s $P $m1 $m2 || { echo "RESULT ERROR: replace"; exit 2; }
	zpool clear $P ${DISKS[0]}
	zpool sync -f $P; zpool sync -f $P; zpool sync -f $P
	echo 0 > $PP/zfs_scan_suspend_progress
	zpool wait -t resilver $P
	if zpool status $P | grep scan: | grep -v '(' | grep -q resilver; then
		echo "(a resilver ran: setup missed the scrub path)"; vacuous=1
	fi
	echo "+ zpool scrub -w $P"
	zpool scrub -w $P
	zpool status -p $P | sed -n '/scan:/,/errors:/p' | grep -v '^$'
	c=$(cks); rep=$(zpool status $P | grep -m1 'scan:' | grep -o 'repaired [^ ]*')
	echo ">>> $t: the scrub that healed ${DISKS[0]} ($rep) reported $c checksum errors"
	[ "$rep" = "repaired 0B" ] && { echo "(nothing healed: setup missed the case)"; vacuous=1; }
	[ $c -gt 0 ] && bad=1
	zpool clear $P; zpool scrub -w $P
	echo ">>> $t: second scrub: $(zpool status $P | grep -m1 'scan:' | grep -o 'repaired [^ ]*'), CKSUM $(cks)"
}
run_case mirror
run_case draid
echo 1 > $PP/zfs_rebuild_scrub_enabled
zpool export $P
if [ $vacuous = 1 ]; then echo "RESULT ERROR (the scrub did not do the healing)"
elif [ $bad = 1 ]; then echo "RESULT BUG (checksum errors for data the DTL said was missing)"
else echo "RESULT OK (healed without checksum errors)"; fi
