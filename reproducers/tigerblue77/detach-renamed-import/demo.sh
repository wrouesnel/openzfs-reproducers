#!/bin/bash
# demo.sh -- openzfs/zfs#19564 (part of #19559): after a crash in the txg of
# a `zpool detach`, a mirror on renamed devices imports DEGRADED, or not at
# all, because the import scan builds the config from labels that no
# uberblock covers.
#
# vdev_config_sync() writes labels 0 and 2 of a txg, then the uberblocks,
# then labels 1 and 3.  A crash in between leaves labels 0 and 2 newer than
# every uberblock.  The kernel loads the pool from the last uberblock and
# reads the label no newer than it; the import scan (libzutil) keeps the
# newest label, which no longer has the detached device.  When the devices
# have moved, the detached device's new path is never handed to the kernel.
# The PR makes the scan skip labels that no uberblock covers.
#
# The crash states are made as in the PR's test: copies of the devices are
# taken before the detach; after it, the uberblock rings and labels 1 and 3
# of the remaining devices are put back with dd (labels 0 and 2 stay as the
# detach wrote them).  Then the files are renamed and imported with -d.
#
#   0. control: three-way mirror, renamed, no crash          -> ONLINE (both)
#   A. three-way, crash before the uberblocks of the detach, the detached
#      device keeps its labels (the PR's test; what #19565 makes the kernel
#      write)                     master: DEGRADED -> RESULT BUG
#                                 PR:     ONLINE   -> RESULT OK
#   B. the same, but the detached device's labels erased, as master erases
#      them before the detach txg (information only: the PR's table says
#      DEGRADED with or without it; #19565 is the other part)
#   C. two-way mirror, detached device keeps its labels (information only:
#      the PR's table says the remaining device is still rejected without
#      #19563)
# Each case ends with `zpool status -v` and a check of the files' checksums.
# Pool tul on 128 MiB files in /var/tmp/dri (renamed into /var/tmp/dri-new,
# copies in /var/tmp/dri-copies).  About 1 minute.
set -u
P=tul D=/var/tmp/dri N=/var/tmp/dri-new B=/var/tmp/dri-copies
SZ=$((128 * 1024 * 1024)) BLK=131072

run() { echo "\$ $*"; "$@" 2>&1 | sed 's/^/  /'; return "${PIPESTATUS[0]}"; }
result() {	# the RESULT line, also through the kernel's console
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}
st() { echo "--- zpool status -v $P   ($1)"; zpool status -v $P 2>&1 | sed '/^$/d; s/^/    /'; }
health() { zpool list -H -o health $P 2>/dev/null || echo "NOT IMPORTED"; }
sums() { (cd /$P && for f in $(ls | sort -V); do echo "$f $(sha256sum < $f | cut -c1-16)"; done) 2>/dev/null; }

clean() {
	zpool destroy -f $P 2>/dev/null
	rm -f $D/d* $N/m* $B/d* $D/sums $D/sums.now
}

# restore what a crash before the uberblocks of the txg leaves untouched, in
# 128 KiB blocks: label 0's uberblock ring (block 1), label 1 (2-3), label
# 2's uberblock ring and label 3 (the last three)
restore_pre() {	# device
	local n=$((SZ / BLK)) c=$B/$(basename $1)
	dd if=$c of=$1 bs=$BLK skip=1 seek=1 count=3 conv=notrunc status=none &&
	dd if=$c of=$1 bs=$BLK skip=$((n - 3)) seek=$((n - 3)) count=3 \
	    conv=notrunc status=none
}

# case <name> <ways> <crash: none|keep|erased> -> prints the health
case_run() {
	local name=$1 ways=$2 crash=$3 i dev=() h
	clean
	for i in $(seq 0 $((ways - 1))); do
		truncate -s $SZ $D/d$i; dev+=($D/d$i)
	done
	run zpool create -f -O compression=off $P mirror "${dev[@]}" || return 2
	for i in $(seq 1 8); do
		dd if=/dev/urandom of=/$P/f$i bs=1M count=1 status=none
	done
	zpool sync $P; sums > $D/sums
	run zpool export $P
	cp --sparse=always "${dev[@]}" $B/
	run zpool import -d $D $P
	if [ "$crash" != none ]; then
		run zpool detach $P ${dev[$((ways - 1))]}
		st "$name: after the detach, before the export"
	fi
	run zpool export $P
	if [ "$crash" != none ]; then
		echo "# crash state: rings and labels 1/3 of the remaining devices put back"
		for i in $(seq 0 $((ways - 2))); do restore_pre ${dev[$i]}; done
		if [ "$crash" = keep ]; then
			echo "# the detached device keeps its labels (copy from before the detach)"
			cp --sparse=always $B/$(basename ${dev[$((ways - 1))]}) ${dev[$((ways - 1))]}
		else
			echo "# the detached device's labels erased, as master's detach leaves it"
		fi
	fi
	echo "# rename: d0.. -> new/m0.."
	for i in $(seq 0 $((ways - 1))); do mv ${dev[$i]} $N/m$i; done
	echo "# what the scan sees:"
	zpool import -d $N 2>&1 | sed -n '/config:/,$p' | sed '/^$/d; s/^/    /'
	run zpool import -d $N $P
	h=$(health)
	if [ "$h" != "NOT IMPORTED" ]; then
		st "$name: imported from renamed devices"
		sums > $D/sums.now
		if cmp -s $D/sums.now $D/sums; then
			echo "  data: all $(wc -l < $D/sums) files match"
		else
			echo "  data: checksums DIFFER"; h="$h-DATA"
		fi
		cd /
		for i in 1 2 3 4 5; do zpool export $P 2>/dev/null && break; sleep 1; done
	fi
	zpool destroy -f $P 2>/dev/null
	echo "== case $name: $h"
	eval "H_$name=\$h"
}

echo "# $(uname -sr); build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# $(zpool version 2>/dev/null | head -1)"
mkdir -p $D $N $B /etc/zfs
zpool destroy -f $P 2>/dev/null

echo; echo "## 0. control: three-way mirror, renamed, no crash"
case_run ctl 3 none
echo; echo "## A. three-way, crash before the uberblocks of the detach, detached device keeps its labels"
case_run A 3 keep
echo; echo "## B. three-way, the same crash, detached device's labels erased (master's detach)"
case_run B 3 erased
echo; echo "## C. two-way, crash before the uberblocks of the detach, detached device keeps its labels"
case_run C 2 keep
clean
H_ctl=${H_ctl:-?} H_A=${H_A:-?} H_B=${H_B:-?} H_C=${H_C:-?}

echo
echo "## summary (healthy = ONLINE with every file intact)"
echo "  0 control           $H_ctl"
echo "  A three-way, keep   $H_A    <- decides the RESULT"
echo "  B three-way, erased $H_B    (information: the PR alone, per its table, doesn't cover it)"
echo "  C two-way, keep     $H_C    (information: needs #19563, per the PR's table)"

if [ "$H_ctl" != ONLINE ]; then
	result "RESULT ERROR: the control did not import ONLINE ($H_ctl)"
elif [ "$H_A" = ONLINE ]; then
	result "RESULT OK: the renamed three-way mirror imported ONLINE after the crash, every file intact"
elif [ "$H_A" = DEGRADED ]; then
	result "RESULT BUG: the renamed three-way mirror imported DEGRADED after the crash (the detached device not found)"
else
	result "RESULT ERROR: case A ended $H_A"
fi
