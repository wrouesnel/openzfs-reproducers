#!/bin/bash
# demo.sh -- a scrub can't repair a split block of a removed vdev from the
# old device of a "spare" (or "replacing") vdev (openzfs/zfs#19808).
#
# When a top-level vdev is removed, a block can be copied to its new place in
# several segments ("split block").  A scrub then reads every copy of every
# segment and tries combinations until one matches the block's checksum.  On
# master only the children of a mirror count as copies: a spare or replacing
# vdev under the mirror counts as ONE copy, and when its two devices differ,
# reading it gives a checksum error, so the good copy on its old device is
# never tried.  #19808 reads each child of a resilvered spare as its own copy.
#
#   mirror-1: spare-0 (b0 = old device, intact; sp = hot spare, damaged), b1 (damaged)
#
# Builds:
#   bug  openzfs/zfs master
#        -> "RESULT BUG: scrub left a permanent error ... b0 still holds it ..."
#   fix  tigerblue77/zfs indirect-spare-copies (the head of #19808)
#        -> "RESULT OK: scrub repaired the split block ..."
# Run as root:  /demo/demo.sh       well under a minute.
set -u
P=split D=/var/tmp/split
PRM=/sys/module/zfs/parameters/zfs_remove_max_segment

run() { echo "# $*"; "$@"; }
st() { echo; echo "## zpool status -v $P"; zpool status -v $P | sed 's/^/   /'; echo; }
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
die() { echo "RESULT ERROR: $*"; exit 2; }
sum() { sha256sum /$P/file 2>/dev/null | cut -d' ' -f1 | grep . || echo "READ ERROR ($(cat /$P/file 2>&1 >/dev/null | head -1))"; }
cksum_of() { zpool status -p $P | awk -v d="$1" '$1 == d { print $5; exit }'; }

zpool destroy -f $P 2>/dev/null
rm -rf $D; mkdir -p $D
truncate -s 256M $D/a0 $D/a1 $D/b0 $D/b1 $D/sp
oldmax=$(cat $PRM)

step "1. mirror a0,a1 with a hot spare; write a 512K file (4 blocks of 128K)"
run zpool create -f -o ashift=9 -O compression=off -O recordsize=128k -O primarycache=metadata \
    $P mirror $D/a0 $D/a1 spare $D/sp || die "could not create $P"
run dd if=/dev/urandom of=/$P/file bs=128k count=4 status=none
run zpool sync $P
GOOD=$(sum)
echo "-> sha256 of /$P/file: $GOOD"
st

step "2. add mirror b0,b1 and remove a0,a1, copying in 32K segments"
echo "# echo 32768 > $PRM"; echo 32768 >$PRM
run zpool add -f $P mirror $D/b0 $D/b1
run zpool remove -w $P mirror-0 || die "removal failed"
echo $oldmax >$PRM
run zpool sync $P
st

step "3. find where the file's first block went: it is split into segments"
obj=$(stat -c %i /$P/file)
dva=$(zdb -ddddd $P/ $obj | awk '$2 == "L0" && $3 ~ /^0:/ { print $3; exit }')
[ -n "$dva" ] || die "no block of the file on the removed vdev"
off=$((16#$(echo $dva | cut -d: -f2))) size=$((16#$(echo $dva | cut -d: -f3)))
echo "-> first block: DVA $dva (on removed vdev 0), mapped to vdev 1 as:"
SEGS=""
zdb -mmmm $P | grep -E '<0:[0-9a-f]+:[0-9a-f]+> -> <1:' | sed 's/[<>]//g' >$D/map
while read src arrow dst rest; do
	so=$((16#$(echo $src | cut -d: -f2))) sz=$((16#$(echo $src | cut -d: -f3)))
	to=$((16#$(echo $dst | cut -d: -f2)))
	lo=$((so > off ? so : off)) hi=$((so + sz < off + size ? so + sz : off + size))
	if ((lo < hi)); then
		echo "   segment: vdev 1 offset $((to + lo - so)), $((hi - lo)) bytes"
		SEGS="$SEGS $((to + lo - so)):$((hi - lo))"
	fi
done <$D/map
n=$(echo $SEGS | wc -w)
[ "$n" -gt 1 ] || die "the block isn't split ($n segment)"
echo "-> $n segments"

step "4. replace b0 with the hot spare: mirror-1 now holds spare-0 (b0, sp) and b1"
run zpool replace $P $D/b0 $D/sp || die "replace failed"
run zpool wait -t resilver $P
st

step "5. silent damage: zero every segment of that block on sp and on b1 (b0 keeps the only good copy)"
for seg in $SEGS; do
	o=${seg%%:*} l=${seg##*:}
	for dev in $D/sp $D/b1; do
		run dd if=/dev/zero of=$dev bs=512 conv=notrunc status=none seek=$(((4194304 + o) / 512)) count=$((l / 512))
	done
done
st

step "6. scrub"
run zpool scrub -w $P
st
B0=$(cksum_of $D/b0) B1=$(cksum_of $D/b1) SP=$(cksum_of $D/sp)
echo "-> checksum errors: b0 $B0, b1 $B1, sp $SP"
PERM=no; zpool status -v $P | grep -q "Permanent errors" && PERM=yes

step "7. export/import (drop caches) and read the file"
run zpool export $P && run zpool import -d $D $P || die "export/import failed"
S7=$(sum)
echo "-> sha256 now: $S7"
echo "   expected:   $GOOD"
st

if [ "$PERM" = yes ]; then
	step "8. (bug) is the good copy still there? Offline the two damaged devices and read again"
	echo "# (primarycache=metadata: file data is read from the disks every time)"
	run zpool offline $P $D/b1
	run zpool offline $P $D/sp
	st
	S8=$(sum)
	echo "-> sha256 reading from b0 alone: $S8"
	run zpool online $P $D/b1
	run zpool online $P $D/sp
	run zpool wait -t resilver $P
	st
	[ "$S8" = "$GOOD" ] || die "b0 doesn't hold the block either"
	step "9. (bug) zpool detach b0, as a replace does when it finishes: the good copy is gone"
	run zpool detach $P $D/b0
	run zpool scrub -w $P
	run zpool export $P && run zpool import -d $D $P
	S9=$(sum)
	echo "-> sha256 now: $S9"
	st
	echo "RESULT BUG: scrub left a permanent error in /$P/file although b0 still holds it intact; after detaching b0 the file is lost"
	exit 0
fi

[ "$S7" = "$GOOD" ] || { echo "RESULT FAIL: no permanent error reported, but the file doesn't match"; exit 0; }
[ "$B0" -eq 0 ] && [ "$B1" -gt 0 ] && [ "$SP" -gt 0 ] ||
    { echo "RESULT FAIL: checksum errors b0 $B0, b1 $B1, sp $SP (want 0, >0, >0)"; exit 0; }

step "8. (fix) zpool detach b0, as a replace does when it finishes, scrub again, read again"
run zpool detach $P $D/b0
run zpool clear $P
run zpool scrub -w $P
run zpool export $P && run zpool import -d $D $P || die "export/import failed"
S8=$(sum)
echo "-> sha256 now: $S8"
st
[ "$S8" = "$GOOD" ] || { echo "RESULT FAIL: the file changed after detaching b0"; exit 0; }
zpool status -v $P | grep -q "repaired 0B .* with 0 errors" ||
    { echo "RESULT FAIL: the second scrub still found something to repair"; exit 0; }
zpool destroy -f $P
echo "RESULT OK: scrub repaired the split block from b0 (checksum errors: b0 $B0, b1 $B1, sp $SP); the file is intact, also after detaching b0"
