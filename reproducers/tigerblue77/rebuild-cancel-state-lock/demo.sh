#!/bin/bash
# demo.sh -- tigerblue77/rebuild-cancel-state-lock (PR #19612).
# The PR's ZTS test replacement/rebuild_reopen, step by step: a pool of 4
# disks (64 metaslabs each, so the rebuild checks often) with 64 MiB of
# data and a fifth disk.  Disk 2 is replaced by disk 5 with a sequential
# rebuild (`zpool replace -s`), and back, 3 times.  During each rebuild
# 4 loops run `zpool scrub`, which is refused while the rebuild runs but
# first reopens every vdev (each leaf is closed for a moment):
#   master: a rebuild check lands while the new leaf is closed, finds
#           nothing to resilver and cancels the rebuild ("rebuild ...
#           canceled" in the history, "resilver (replacing-1) canceled"),
#           so the new disk is not rebuilt.  Here one of the looping scrubs
#           is then accepted, finds the new disk's missing data as checksum
#           errors and repairs it; in ZTS replacement/scrub_cancel, where
#           no scrub follows, `zpool wait` hangs instead
#           (`zpool status -v` at the end shows the CKSUM count)
#   fix:    no rebuild is canceled and every replacement finishes
set -u
. /etc/demo-env 2>/dev/null
P=rbreopen STOP=/var/tmp/rbreopen.stop
M=/sys/module/zfs/parameters
read -ra DK <<<"$DEMO_DISKS"
x() { echo "# $*"; "$@"; }
die() { echo "RESULT ERROR: $*"; touch $STOP; echo 0 >$M/zfs_scan_suspend_progress; exit 2; }
resilvering() { zpool status $P | grep -qE 'resilver.* in progress'; }
replacing() { zpool status $P | grep -qE 'replacing-[0-9]'; }
[ ${#DK[@]} -ge 5 ] || die "needs 5 run disks"
echo "=== sequential rebuilds under refused scrubs ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build), kernel $(uname -r))"
zpool destroy $P 2>/dev/null
echo "# echo 64 > zfs_vdev_min_ms_count"; echo 64 >$M/zfs_vdev_min_ms_count
x zpool create -f -o cachefile=none $P ${DK[0]} ${DK[1]} ${DK[2]} ${DK[3]} || die "zpool create failed"
x zfs create $P/fs
dd if=/dev/urandom of=/$P/fs/file bs=1M count=64 status=none
sum=$(sha256sum /$P/fs/file | cut -d' ' -f1)
x zpool sync $P
bad= done=0 n=0 rep=
cycle() {	# OLD NEW
	n=$((n + 1))
	echo; echo "## replace $n: ${1##*/} -> ${2##*/}"
	echo 1 >$M/zfs_scan_suspend_progress
	x zpool replace -s $P $1 $2 || die "zpool replace -s failed"
	resilvering || die "no resilver in progress after replace -s"
	echo "# zpool scrub $P   (refused: a resilver is running)"
	zpool scrub $P 2>&1 | sed 's/^/  /'
	rm -f $STOP
	echo "# 4 x: while :; do zpool scrub $P; done &"
	for i in 1 2 3 4; do ( while [ ! -e $STOP ]; do zpool scrub $P >/dev/null 2>&1; done ) & done
	echo 0 >$M/zfs_scan_suspend_progress
	for i in $(seq 120); do resilvering || break; sleep 1; done
	touch $STOP; wait
	zpool status $P | grep -E 'scan:|replacing' | sed 's/^/  /'
	if zpool history -i $P | grep -q 'rebuild.*canceled'; then
		zpool history -i $P | grep -E 'rebuild|vdev attach' | tail -3 | sed 's/^/  history: /'
		bad="replace $n, $(zpool history -i $P | grep 'rebuild.*canceled' | tail -1 | grep -oE '\[txg:[0-9]+\]')"
		for i in $(seq 60); do replacing || break; sleep 1; done
		zpool wait -t scrub $P
		rep=$(zpool status $P | grep -oE 'replacing-[0-9]+' | head -1)
		newdisk=${2##*/}
		cks=$(zpool status $P | awk -v d=$newdisk '$1 == d { print $5; exit }')
		return 1
	fi
	for i in $(seq 60); do replacing || break; sleep 1; done
	replacing && { bad="replace $n: replacing vdev still there 60 s after the rebuild"; rep=yes; return 1; }
	done=$n
}
for i in 1 2 3; do
	cycle ${DK[1]} ${DK[4]} || break
	cycle ${DK[4]} ${DK[1]} || break
done
echo 0 >$M/zfs_scan_suspend_progress
echo
echo "# zpool history -i $P (rebuild events)"
zpool history -i $P | grep -E 'rebuild|vdev attach|detach' | tail -8 | sed 's/^/  /'
echo "# zpool status -v $P"; zpool status -v $P
ok=no; [ "$(sha256sum /$P/fs/file | cut -d' ' -f1)" = "$sum" ] && ok=yes
echo "  data unchanged: $ok"
x zpool export $P
echo
if [ -n "$bad" ]; then
	if [ -n "$rep" ]; then
		echo "RESULT BUG: the rebuild cancelled itself during refused scrubs ($bad); $rep remained 60 s later"
	elif [ "${cks:-0}" != 0 ]; then
		echo "RESULT BUG: the rebuild cancelled itself during refused scrubs ($bad), leaving $newdisk un-rebuilt; the scrubs accepted afterwards counted $cks checksum errors on it (repaired; see zpool status -v), and the replacement then finished"
	else
		echo "RESULT BUG: the rebuild cancelled itself during refused scrubs ($bad); the replacement was finished afterwards by another scan"
	fi
	exit 1
elif [ "$done" = 6 ] && [ $ok = yes ]; then
	echo "RESULT OK: every rebuild completed and every replacement finished during refused scrubs (6 replacements), data unchanged"
else
	echo "RESULT ERROR: $done of 6 replacements, data unchanged: $ok"; exit 2
fi
