#!/bin/bash
# demo.sh -- bug #250: block-cloning space accounting while a txg syncs.
#
# A block clone is charged to its dataset in full when the cloned block is
# "born" in syncing context, and the BRT gives the same amount back as saved
# space.  On master the saved space only reaches the pool's available space
# at the end of spa_sync(), so for the rest of the sync `available` drops by
# the whole cloned size (to 0 when that is more than the free space) and
# open-context creates, writes and clones fail with ENOSPC.  This is the CI
# flake zpool_prefetch_002_pos ("open: /testpool/brt/clone.48: No space left
# on device").
#
# Steps (the ZTS test block_cloning_avail_during_sync, made visible):
#   1 GiB pool, one 128 MiB file, 16 clones of it (2 GiB logical, more than
#   the pool's free space), all in one txg (zfs_txg_timeout=3600).  zinject
#   delays every write by 1 s and `zpool sync` starts, so the sync of the
#   clones stays in progress.  Once the clones are charged (used jumps),
#   show available and try `touch`; then clear the delay and let it finish.
#   repro: available=0 mid-sync, touch ENOSPC          -> RESULT BUG
#   fixed: available unchanged mid-sync, touch works   -> RESULT OK
set -u
P=demo250; FS=$P/fs; M=/$FS; PP=/sys/module/zfs/parameters
V=${DEMO_DISK:-}
if [ -z "$V" ]; then V=/var/tmp/demo250.vdev; truncate -s 1G $V; fi
N=16; SRCMB=128

run() { echo "+ $*"; "$@"; }
space() {	# label
	echo "--- $1"
	zfs get -p -o name,property,value available,used $FS | sed 's/^/    /'
	zpool list -p -o name,size,alloc,free,bcloneused,bclonesaved $P | sed 's/^/    /'
}
gp() { zfs get -Hp -o value "$1" $FS; }

echo "build: ${DEMO_BUILD:-?}"
zpool destroy -f $P 2>/dev/null; zpool labelclear -f $V 2>/dev/null
echo 1 > $PP/zfs_bclone_enabled 2>/dev/null
txg0=$(cat $PP/zfs_txg_timeout); sp0=$(cat $PP/zfs_dirty_data_sync_percent)
dm0=$(cat $PP/zfs_dirty_data_max)
# Keep all the clones in one txg: no timed sync, and no dirty-data sync
# trigger (in this small VM it would split them into txgs of a few clones).
run eval "echo 3600 > $PP/zfs_txg_timeout"
run eval "echo 100 > $PP/zfs_dirty_data_sync_percent"
run eval "echo $((512*1024*1024)) > $PP/zfs_dirty_data_max"
run zpool create -f -o cachefile=none -o feature@block_cloning=enabled \
    -O recordsize=128k $P $V || { echo "RESULT ERROR: create"; exit 2; }
run zfs create $FS
run dd if=/dev/urandom of=$M/src bs=1M count=$SRCMB status=none
run zpool sync $P
space "before cloning"
a0=$(gp available); u0=$(gp used)

echo "+ for i in 1..$N: clonefile -f $M/src $M/clone.\$i   # $N x ${SRCMB} MiB = $((N*SRCMB)) MiB logical"
for i in $(seq 1 $N); do
	cerr=$(clonefile -f $M/src $M/clone.$i 2>&1 >/dev/null) || {
		echo "    clone $i: $cerr"; echo "RESULT ERROR: clone $i failed (the clones were not all in one txg)"; exit 2; }
done
space "after cloning (not synced yet: used and bclone_saved unchanged)"
if [ "$(gp used)" -gt $((u0 + 64*1024*1024)) ]; then
	echo "RESULT ERROR (the clones were synced before the held sync: setup missed the case)"; exit 2
fi
zpool status -v $P

cloned=$((N * SRCMB * 1024 * 1024))
run zinject -d $V -D 1000:1 -T write $P
echo "+ zpool sync $P &   # every write now takes 1 s, the sync stays open"
zpool sync $P & sp=$!

want=$((u0 + cloned / 2)); u=$(gp used)
for t in $(seq 1 600); do
	[ "$u" -ge "$want" ] && break; sleep 0.1; u=$(gp used)
done
a=$(gp available)
space "MID-SYNC (the clones are charged: used jumped)"
echo "+ touch $M/newfile"
if terr=$(touch $M/newfile 2>&1); then tok=1; echo "    created"; else tok=0; echo "    $terr"; fi
echo "+ dd if=/dev/zero of=$M/newdata bs=1M count=1"
dd if=/dev/zero of=$M/newdata bs=1M count=1 status=none 2>&1 | sed 's/^/    /'
if kill -0 $sp 2>/dev/null; then insync=1; echo "(zpool sync still running: these checks were mid-sync)"
else insync=0; echo "(the sync had already finished: no proof either way)"; fi

run zinject -c all
echo "+ wait for zpool sync"; wait $sp
run zpool sync $P
space "after the sync"
a1=$(gp available)
saved=$(zpool get -Hp -o value bclone_saved $P)
run ls -l $M
echo "+ cmp $M/src $M/clone.1 && cmp $M/src $M/clone.$N"
cmp $M/src $M/clone.1 && cmp $M/src $M/clone.$N && echo "    clones match the source"
zpool status -v $P
echo $txg0 > $PP/zfs_txg_timeout; echo $sp0 > $PP/zfs_dirty_data_sync_percent
echo $dm0 > $PP/zfs_dirty_data_max
run zpool export $P

mb() { echo $(( $1 / 1048576 ))MiB; }
echo
echo ">>> available: before $(mb $a0), mid-sync $(mb $a), after $(mb $a1); bclone_saved $(mb $saved)"
echo ">>> mid-sync create: $([ $tok = 1 ] && echo ok || echo "$terr")"
if [ $insync = 0 ] || [ "$saved" -ne $cloned ]; then
	echo "RESULT ERROR (the sync finished before the check, or not all clones were saved)"
elif [ $tok = 0 ] || [ $a -lt $((a0 - 64*1024*1024)) ]; then
	[ "$a" -eq 0 ] && to=" to 0" || to=""
	echo "RESULT BUG (available dropped$to mid-sync: $(mb $a0) -> $(mb $a), touch: ${terr:-ok}; $(mb $a1) after the sync)"
else
	echo "RESULT OK (available unchanged mid-sync: $(mb $a0) -> $(mb $a), create works; $(mb $a1) after the sync)"
fi
