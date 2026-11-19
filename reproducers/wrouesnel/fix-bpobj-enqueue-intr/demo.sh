#!/bin/bash
# demo.sh -- bug #278 (openzfs/zfs#19945): overwriting a cloned, dedup or
# gang block makes the zio write-done (z_wr_int) thread read the pool's free
# bpobj; with one z_wr_int thread and a vdev queue of one I/O, the txg never
# syncs.
#
# dbuf_write_done() kills the overwritten block with
# dsl_dataset_block_kill(..., async=B_TRUE).  Since 46c4f2ce0b (#16722) gang,
# dedup and cloned blocks go on the pool's free bpobj there, through
# bpobj_enqueue(), which reads the bpobj's last block (its L1, then L0) when
# it isn't cached.  That read waits in the write-done thread: every write
# completion on that taskq (the ZIL's too) waits for it.  With
# zfs_vdev_max_active=1 the read is never issued at all: the vdev's only slot
# is held by a write whose completion is queued behind the waiting thread.
# The fix defers these enqueues to the txg sync (dsl_dataset_sync_done()),
# like the deadlist case next to it.
#
# For each kind of block (clone, dedup, gang):
#   1. a pool whose writes complete on one z_wr_int thread
#      (zio_taskq_write="sync null fixed,1,1 null"); a file of 4000 blocks
#   2. overwrite it with the free bpobj's processing off
#      (zfs_free_bpobj_enabled=0): 4000 blocks wait on the free bpobj
#      ("freeing"); export and import, so the bpobj isn't cached
#   3. zfs_vdev_max_active=1, writes delayed 100 ms (so one is always in
#      flight), overwrite 64 more blocks, zpool sync, given 45 s
#   repro (BRANCH~1: the prerequisite and the test, without the fix): the
#      sync is still waiting after 45 s; z_wr_int is in bpobj_enqueue ->
#      dbuf_read -> zio_wait.  The demo then restores max_active and reads a
#      file that isn't cached, which issues the stuck read
#      -> "RESULT BUG: the txg sync stalled ..."
#   fixed (branch head): the sync finishes in seconds
#   4. process the free bpobj: freeing drops to 0, nothing leaked; the new
#      data reads back; a scrub finds no errors
#      -> "RESULT OK: the txg synced promptly for clone, dedup and gang ..."
# Pool demo278 on the run disk $DEMO_DISK (or a file in /var/tmp/demo278),
# recreated for each kind; the last one is exported at the end.
# About 2 minutes (4 on the repro).
set -u
P=demo278 D=/var/tmp/demo278 W=45 NBLKS=4000 KBLKS=64
PRM=/sys/module/zfs/parameters
mkdir -p $D
V=${DEMO_DISK:-}
[ -n "$V" ] || { truncate -s 1G $D/vdev0; V=$D/vdev0; }

run() { echo "\$ $*"; "$@"; }
st() {	# [label]: the pool's state after a step
	echo "--- zpool status -v $P${1:+   ($1)}"
	zpool status -v $P 2>&1 | sed 's/^/    /'
}
result() {	# the RESULT line, also through the kernel's console
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}
die() { restore; result "RESULT ERROR: $*"; exit 2; }
setq() { printf '%s' "$2" >$PRM/$1; }	# no newline: zio_taskq_write rejects it
setp() { echo "\$ echo -n '$2' > $PRM/$1"; setq "$@"; }
showp() { echo "  $1 = $(cat $PRM/$1)"; }
freeing() { zpool get -Hpo value freeing $P; }
tids() {	# the z_wr_int threads (any process's tasks)
	local t
	for t in /proc/[0-9]*/task/[0-9]*; do
		case $(cat $t/comm 2>/dev/null) in z_wr_int*) echo $t ;; esac
	done
}
TQ0=$(cat $PRM/zio_taskq_write) MA0=$(cat $PRM/zfs_vdev_max_active)
FG0=$(cat $PRM/metaslab_force_ganging) FGP0=$(cat $PRM/metaslab_force_ganging_pct)
restore() {
	zinject -c all >/dev/null 2>&1
	setq zfs_vdev_max_active "$MA0"; setq metaslab_force_ganging "$FG0"
	setq metaslab_force_ganging_pct "$FGP0"; setq zfs_free_bpobj_enabled 1
}

echo "# $(uname -sr); $(nproc) vCPUs; build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# vdev: $V"
zinject -c all >/dev/null 2>&1
zpool destroy -f $P 2>/dev/null
mkdir -p /etc/zfs

stalled= synced= fail=
for kind in clone dedup gang; do
	bs=4096 props= file=/$P/fs/a
	case $kind in dedup) props="-o dedup=on" ;; gang) bs=16384 ;; esac
	echo; echo "################ $kind blocks ################"
	zpool destroy -f $P 2>/dev/null; zpool labelclear -f "$V" 2>/dev/null

	echo; echo "## $kind 1. a pool with one z_wr_int thread; a file of $NBLKS blocks of $bs bytes"
	setp zio_taskq_write "sync null fixed,1,1 null"; showp zio_taskq_write
	run zpool create -f -o ashift=12 -o feature@block_cloning=enabled \
	    -O compression=off -O recordsize=$bs $P "$V" || die "zpool create failed"
	run zfs create $props $P/fs
	echo "  z_wr_int threads: $(tids | wc -l)"
	if [ $kind = gang ]; then
		echo "  (every block bigger than 8 KiB is written as a gang block)"
		setp metaslab_force_ganging 8193; setp metaslab_force_ganging_pct 100
	fi
	run dd if=/dev/urandom of=$file bs=$bs count=$NBLKS status=none
	run zpool sync $P
	if [ $kind = clone ]; then
		run cp --reflink=always $file /$P/fs/b || die "cp --reflink failed"
		run zpool sync $P
		file=/$P/fs/b
		echo "  bcloneused: $(zpool get -Hpo value bcloneused $P)"
		[ "$(zpool get -Hpo value bcloneused $P)" -gt 0 ] || die "the copy isn't a clone"
	fi

	echo; echo "## $kind 2. fill the free bpobj with its processing off; export, import"
	setp zfs_free_bpobj_enabled 0
	run dd if=/dev/urandom of=$file bs=$bs count=$NBLKS conv=notrunc status=none
	run zpool sync $P
	echo "  freeing: $(freeing) bytes ($NBLKS blocks on the free bpobj)"
	[ "$(freeing)" -ge $((NBLKS * bs)) ] || die "the free bpobj holds only $(freeing) bytes"
	run dd if=/dev/urandom of=/$P/kick bs=128k count=8 status=none
	run zpool export $P
	run zpool import -d "$(dirname "$V")" $P || die "import failed"
	echo "\$ cat $file > /dev/null    (the file's own blocks cached, the free bpobj not)"
	cat $file >/dev/null
	setp metaslab_force_ganging "$FG0"; setp metaslab_force_ganging_pct "$FGP0"
	st "imported; freeing $(freeing)"

	echo; echo "## $kind 3. one I/O per vdev, writes delayed 100 ms; overwrite $KBLKS blocks; zpool sync (given $W s)"
	dd if=/dev/urandom of=$D/new bs=$bs count=$KBLKS status=none
	run zinject -d "$V" -D 100:1 -T write $P
	setp zfs_vdev_max_active 1
	run dd if=$D/new of=$file bs=$bs count=$KBLKS conv=notrunc status=none
	echo "\$ zpool sync $P &"
	t0=$(date +%s%N)
	zpool sync $P &
	sp=$!
	seen=0 stack= wr=$(tids)
	end=$(($(date +%s) + W))
	while [ $(date +%s) -lt $end ]; do
		kill -0 $sp 2>/dev/null || break
		for t in $wr; do
			s=$(cat $t/stack 2>/dev/null)
			if grep -q bpobj_enqueue <<<"$s"; then
				seen=$((seen + 1)); [ -n "$stack" ] || stack=$s
			fi
		done
		sleep 0.2
	done
	if kill -0 $sp 2>/dev/null; then
		echo "  zpool sync: STILL WAITING after $(( ($(date +%s%N) - t0) / 1000000000 )) s (the txg can't sync)"
		echo "  the z_wr_int thread's kernel stack:"
		for t in $wr; do sed 's/^/    /' $t/stack | head -16; done
		echo "  txg_sync's kernel stack:"
		for t in /proc/[0-9]*/task/[0-9]*; do
			[ "$(cat $t/comm 2>/dev/null)" = txg_sync ] && sed 's/^/    /' $t/stack | head -8
		done
		st "the txg is stuck"
		echo "  restart the queue: max_active back to $MA0, and a read that misses the ARC"
		run zinject -c all
		setp zfs_vdev_max_active "$MA0"
		echo "\$ cat /$P/kick > /dev/null"
		cat /$P/kick >/dev/null
		end=$(($(date +%s) + 60))
		while [ $(date +%s) -lt $end ] && kill -0 $sp 2>/dev/null; do sleep 0.2; done
		kill -0 $sp 2>/dev/null && die "the txg sync is still stuck after the restart"
		wait $sp
		echo "  zpool sync finished only after the restart, $(( ($(date +%s%N) - t0) / 1000000000 )) s after it began"
		stalled+=" $kind"
	else
		wait $sp
		ms=$(( ($(date +%s%N) - t0) / 1000000 ))
		echo "  zpool sync finished in $ms ms; samples with z_wr_int in bpobj_enqueue: $seen"
		[ -n "$stack" ] && { echo "  z_wr_int was seen in bpobj_enqueue:"; sed 's/^/    /' <<<"$stack" | head -16; }
		synced+=" $kind:${ms}ms"
		run zinject -c all
		setp zfs_vdev_max_active "$MA0"
	fi

	echo; echo "## $kind 4. process the free bpobj; check the data and the pool"
	setp zfs_free_bpobj_enabled 1
	run zpool sync $P
	for _ in $(seq 300); do [ "$(freeing)" = 0 ] && break; sleep 0.2; done
	lk=$(zpool get -Hpo value leaked $P)
	echo "  freeing: $(freeing), leaked: $lk"
	[ "$(freeing)" = 0 ] || fail+="$kind: freeing $(freeing) left; "
	[ "$lk" = 0 ] || fail+="$kind: leaked $lk; "
	run dd if=$file of=$D/read bs=$bs count=$KBLKS status=none
	run cmp $D/new $D/read || fail+="$kind: the new data differs; "
	run zpool scrub -w $P || fail+="$kind: scrub failed; "
	st "$kind: the final state"
	s=$(zpool status -v $P)
	echo "$s" | awk -v p=$P '$1 == p { print $2; exit }' | grep -qx ONLINE || fail+="$kind: pool not ONLINE; "
	echo "$s" | grep -q 'errors: No known data errors' || fail+="$kind: data errors; "
done
run zpool export $P
restore; setq zio_taskq_write "$TQ0"

echo
echo "summary: stalled:${stalled:- none}; synced:${synced:- none}"
if [ -n "$stalled" ]; then
	result "RESULT BUG: the txg sync stalled overwriting${stalled} blocks (z_wr_int waiting in bpobj_enqueue for a free-bpobj read)${fail:+ (and: ${fail%; })}"
	exit 1
fi
if [ -n "$fail" ]; then
	result "RESULT ERROR: the txg synced, but: ${fail%; }"
	exit 2
fi
result "RESULT OK: the txg synced promptly for clone, dedup and gang blocks (${synced# }); freed space released, data and scrub clean"
exit 0
