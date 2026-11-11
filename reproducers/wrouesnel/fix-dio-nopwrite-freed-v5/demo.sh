#!/bin/bash
# demo.sh -- bug #57 / PR #19336 (openzfs #19294?): a Direct I/O write
# nopwrites against a block that was freed in an earlier txg that has not
# synced yet.  That sync turns the block pointer into a hole and frees the
# block, so when the Direct I/O write's txg syncs, its nopwrite override no
# longer matches and zio_done() fails
#   VERIFY(BP_EQUAL(zio->io_bp, &zio->io_bp_orig))
# in the sync thread: the pool hangs (without that check the file would
# point at a freed block).  This is the panic and stack of issue #19294.
#
# The same steps as the ZTS test direct/dio_nopwrite_freed:
#   txg N-1  32 MiB of dirty data, synced slowly (zinject write delay)
#   txg N    truncate the file to 0 (frees block 0), then a long free that
#            exceeds zfs_per_txg_dirty_frees_percent=1 of zfs_dirty_data_max
#            (pinned at 256M) so N quiesces early and stays unsynced
#   txg N+1  O_DIRECT rewrite of block 0 with the same data (nopwrite-able:
#            sha256 + compression)
# then the delay is removed and the pool synced.
#
# Demo-image copy (vm/mkdemo.sh, release builds): helper diowrite.c is
# prebuilt at /demo/diowrite.  Run as root:  /demo/demo.sh   about 15 s.
# Builds:
#   bug: PR test commit (master)
#     -> "VERIFY(BP_EQUAL(zio->io_bp, &zio->io_bp_orig)) failed" and its
#        stack, "RESULT BUG"; the pool is hung (power off with virsh destroy)
#     (a debug build trips ASSERT3U(BP_GET_CHECKSUM(bp), ==, zp->zp_checksum)
#      at zio.c:1935 first, bug #59 / PR #19335)
#   fix: PR head -> the rewrite is a real write, the file reads back right,
#        scrub clean, "RESULT OK"
# Pool demo57 on the run disk $DEMO_DISK, or on /var/tmp/demo57/vdev.
# On the fix it is exported at the end; after the bug it stays hung.
set -u
D=/var/tmp/demo57; P=demo57; Z=/sys/module/zfs/parameters
V=${DEMO_DISK:-$D/vdev}
H=${DIO_BIN:-/demo/diowrite}
[ -x "$H" ] || { echo "no helper $H" >&2; exit 2; }
kst() { awk -v k="$2" '$1 == k { print $3 }' "$1"; }
zinject -c all >/dev/null 2>&1
zpool destroy -f $P 2>/dev/null; rm -rf $D; mkdir -p $D
[ -n "${DEMO_DISK:-}" ] || truncate -s 2G $V
old_ddm=$(cat $Z/zfs_dirty_data_max) old_tt=$(cat $Z/zfs_txg_timeout)
old_fp=$(cat $Z/zfs_per_txg_dirty_frees_percent)
restore() {
	echo "$old_ddm" > $Z/zfs_dirty_data_max; echo "$old_tt" > $Z/zfs_txg_timeout
	echo "$old_fp" > $Z/zfs_per_txg_dirty_frees_percent
}
echo 600 > $Z/zfs_txg_timeout
echo $((256 * 1024 * 1024)) > $Z/zfs_dirty_data_max
zpool create -f -o cachefile=none -O checksum=sha256 -O compression=lz4 \
    -O recordsize=128k -O atime=off $P $V && [ -d /$P ] ||
    { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
zfs create -o direct=standard $P/fs
M=/$P/fs; file=$M/file
echo "pool $P on $V; zfs_nopwrite_enabled=$(cat $Z/zfs_nopwrite_enabled)"
kmsg0=$(dmesg | wc -l)

dd if=/dev/urandom of=$D/blk bs=128k count=1 status=none
cp $D/blk $file
dd if=/dev/urandom of=$file bs=128k seek=1 count=3 conv=notrunc status=none
for i in $(seq 0 39); do
	dd if=/dev/urandom of=$M/sparse bs=128k count=1 seek=$((i * 1024)) \
	    conv=notrunc status=none
done
dd if=/dev/urandom of=$M/other bs=128k count=8 status=none
zpool sync $P
echo 1 > $Z/zfs_per_txg_dirty_frees_percent

echo "txg N-1: 32 MiB to sync, each write delayed 400 ms"
zinject -d $V -D 400:1 -T write $P >/dev/null
dd if=/dev/urandom of=$M/filler bs=1M count=32 status=none
zpool sync $P & s1=$!
sleep 2
echo "txg N:   truncate file to 0 (frees its block 0), then long frees"
truncate -s 0 $file
truncate -s 0 $M/sparse
delays=$(kst /proc/spl/kstat/zfs/dmu_tx dmu_tx_dirty_frees_delay)
truncate -s 0 $M/other & t1=$!
sleep 2
if [ "$(kst /proc/spl/kstat/zfs/dmu_tx dmu_tx_dirty_frees_delay)" -le "$delays" ]; then
	zinject -c all >/dev/null; wait; restore; zpool export $P
	echo "RESULT ERROR: the long free did not wait for the next txg (setup failed)"
	exit 2
fi
echo "txg N+1: O_DIRECT rewrite of block 0 with the same data"
w0=$(kst /proc/spl/kstat/zfs/$P/iostats direct_write_count)
$H $D/blk $file 131072
w1=$(kst /proc/spl/kstat/zfs/$P/iostats direct_write_count)
echo "direct_write_count $w0 -> $w1"
[ "$w1" -gt "$w0" ] || { zinject -c all >/dev/null; wait; restore; zpool export $P
	echo "RESULT ERROR: the rewrite was not a Direct I/O write"; exit 2; }

echo "removing the delay and syncing"
zinject -c all >/dev/null
zpool sync $P & s2=$!
for _ in $(seq 60); do
	dmesg | tail -n +$((kmsg0 + 1)) | grep -q -E 'VERIFY|PANIC at' && break
	kill -0 $s1 $t1 $s2 2>/dev/null || break
	sleep 1
done
sleep 1
msg=$(dmesg | tail -n +$((kmsg0 + 1)) | grep -E 'VERIFY|PANIC at')
if [ -n "$msg" ]; then
	echo "$msg"
	echo "(the sync thread is stopped: the pool is hung; end the VM with virsh destroy)"
	if grep -q 'VERIFY(BP_EQUAL' <<<"$msg"; then
		echo "RESULT BUG: the Direct I/O nopwrite of a freed block failed VERIFY(BP_EQUAL) in zio_done"
	else
		echo "RESULT BUG: the sync of the Direct I/O nopwrite of a freed block failed an assertion (see above)"
	fi
	exit 1
fi
wait
restore
if cmp -s -n 131072 $D/blk $file; then echo "file block 0 reads back the rewritten data"
else echo "file block 0 differs from the rewritten data"; bad=1; fi
zpool scrub -w $P
zpool status $P | grep -E 'scan:|errors:'
zpool status $P | grep -q 'No known data errors' || bad=1
zpool export $P && echo "pool $P exported (on $V)"
if [ "${bad:-0}" = 1 ]; then
	echo "RESULT ERROR: no panic, but the data or the pool is wrong (see above)"; exit 2
fi
echo "RESULT OK: the Direct I/O rewrite after the free synced; data and pool are fine"
