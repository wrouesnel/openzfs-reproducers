#!/bin/bash
# demo.sh -- bug #22 / PR #19299 "dbuf: apply caching hints when redirtying a
# dirty dbuf": data written with "don't cache this" stays in the dbuf cache
# (and so in ARC memory, arcstats uncached_size) when it is written in pieces
# smaller than a record.  No data is lost; the cost is memory, and hot dbufs
# of other files are pushed out of the dbuf cache.
#
# Each case starts on a freshly imported pool (empty caches), reads a 4 MiB
# "hot" file twice so its 32 records sit in the dbuf cache, writes a 32 MiB
# file (256 records of 128k), runs `zpool sync` twice, and prints:
#   file      how many of the file's level-0 records are in the dbuf cache
#             (/proc/spl/kstat/zfs/dbufs, dbc=1: what dbufstat -F dbc=1 counts)
#   dbuf L0   all level-0 dbufs in the dbuf cache (dbufstats cache_level_0)
#   uncached  arcstats uncached_size: uncached ARC data still held in memory
#   hot       the hot file's records in the dbuf cache, before -> after
# A case is BUG when 16 or more of the file's 256 records (2 MiB) stay in the
# dbuf cache although the write asked for no caching.  The ARC is pinned at
# 256 MiB, so the dbuf cache target is 8 MiB (1/32, dbuf_cache_shift=5).
#
# Cases (recordsize=128k, compression=off):
#   full-128k    control: primarycache=none, whole-record writes
#   cached-4k    control: primarycache=all, 4k writes (meant to be cached)
#   none-4k      primarycache=none, 4k writes
#   odirect-4k   O_DIRECT 4k writes (smaller than a record: ZFS turns them
#                into uncached buffered I/O)
#   dontcache-4k pwritev2(RWF_DONTCACHE) 4k writes (Linux 6.14+)
#   rewrite      `zfs rewrite` of a cold 32 MiB file (Uncached I/O by design)
#   fsync        O_DIRECT 4k writes, then fsync() while they are still in
#                the open txg: the ZIL copies them with
#                dmu_read(DMU_KEEP_CACHING), which marks each record
#                partially read again
# Each file is read back and compared with what was written.
#
# Builds (vm/mkdemo.sh 22 b-lts-6.18 ..., base linux-lts-6.18.56):
#   bug  master c27dff0c3: all 5 uncached cases BUG (4 before Linux 6.14,
#        which has no RWF_DONTCACHE: dontcache-4k is skipped)
#        -> "RESULT BUG: uncached data stays in the dbuf cache in every case (5 of 5): ..."
#   pr   PR #19299 head f5c2bea14: fixes none-4k, odirect-4k, dontcache-4k;
#        rewrite and fsync remain
#        -> "RESULT BUG: uncached data stays in the dbuf cache in 2 of 5 cases: rewrite fsync"
#   fix  fix-partial-read-redirty-v2 head 2d2cd4ca8: all 5 OK
#        -> "RESULT OK: no uncached data left in the dbuf cache in 5 of 5 cases"
# Run as root:  /demo/demo.sh       about 40 seconds (KVM, 2 vCPUs).
# Pool demo22 on the run disk $DEMO_DISK (vm/demo-vm.sh), or on the file
# /var/tmp/demo22/vdev when DEMO_DISK is unset.  Exported at the end.
set -u
P=demo22 D=/var/tmp/demo22
V=${DEMO_DISK:-$D/vdev}
UW=${UW:-/demo/uwrite}
MB=32 REC=256 HOTMB=4 HOTREC=32 LIMIT=16
[ -x "$UW" ] || { echo "RESULT ERROR: no helper $UW"; exit 2; }
zpool destroy -f $P 2>/dev/null; rm -rf $D; mkdir -p $D
[ -n "${DEMO_DISK:-}" ] || truncate -s 1G $V
M=/sys/module/zfs/parameters
k() { awk -v n="$2" '$1 == n { print $3 }' /proc/spl/kstat/zfs/$1; }
mib() { awk -v b="$1" 'BEGIN { printf "%.1f MiB", b / 1048576 }'; }

# Pin the ARC target at 256 MiB, so the dbuf cache target is 8 MiB.
echo $((256 << 20)) >$M/zfs_arc_max
echo $((256 << 20)) >$M/zfs_arc_min
TXG_TIMEOUT=$(cat $M/zfs_txg_timeout) SYNC_PCT=$(cat $M/zfs_dirty_data_sync_percent)

zpool create -f -o cachefile=none -O compression=off -O recordsize=128k $P $V &&
    [ -d /$P ] || { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
zfs create -o primarycache=none $P/none
zfs create -o primarycache=all $P/all
zfs create -o primarycache=all $P/hot
idir=$D; [ -n "${DEMO_DISK:-}" ] && idir=$V
echo "pool $P on $V; zfs $(cat /sys/module/zfs/version)"
echo "ARC target $(mib $(k arcstats c)), dbuf cache target $(mib $(k dbufstats cache_target_bytes));" \
    "each case writes $MB MiB ($REC records of 128k); BUG when >= $LIMIT records stay cached"
$UW write /$P/hot/hot $HOTMB 131072 plain || { echo "RESULT ERROR: writing the hot file failed"; exit 2; }

# records DATASET FILE: the file's level-0 dbufs in the dbuf cache
records() {
	local os obj
	os=$(zfs get -Hpo value objsetid $P/$1) obj=$(stat -c %i /$P/$1/$2)
	awk -v p=$P -v os=$os -v obj=$obj \
	    '$1 == p && $2 == os && $3 == obj && $4 == 0 && $12 == 1 { n++ } END { print n + 0 }' \
	    /proc/spl/kstat/zfs/dbufs
}
fresh() {	# export + import: empty caches; then make the hot file hot
	zpool export $P && zpool import -o cachefile=none -d $idir $P ||
	    { echo "RESULT ERROR: could not re-import $P"; exit 2; }
	sleep 1
	cat /$P/hot/hot >/dev/null; cat /$P/hot/hot >/dev/null
	HOT0=$(records hot hot)
}
settle() { zpool sync $P; sleep 1; zpool sync $P; }

bad=() ncase=0 err=()
# measure NAME KIND DATASET FILE DESCRIPTION; KIND = control-off | control-on | case
measure() {
	# every number before the read-back, which itself evicts what it reads
	local n=$(records $3 $4) hot=$(records hot hot) v=OK
	local l0=$(k dbufstats cache_level_0) l0b=$(k dbufstats cache_level_0_bytes)
	local unc=$(k arcstats uncached_size)
	case $2 in
	control-off) [ $n -lt $LIMIT ] || { v="ERROR (control: expected < $LIMIT)"; err+=("$1"); } ;;
	control-on) [ $n -ge $LIMIT ] || { v="ERROR (control: expected >= $LIMIT)"; err+=("$1"); } ;;
	case) ncase=$((ncase + 1)); [ $n -lt $LIMIT ] || { v=BUG; bad+=("$1"); } ;;
	esac
	[ $2 = control-on ] && [ "$v" = OK ] && v="OK (cached, as asked)"
	if ! $UW verify /$P/$3/$4 $MB; then v="$v, DATA WRONG"; err+=("$1-data"); fi
	printf '%-13s file %3d/%d records cached (%s)  dbuf L0 %3d (%s)  uncached %s  hot %d->%d  %s\n' \
	    "$1" $n $REC "$(mib $((n << 17)))" $l0 "$(mib $l0b)" "$(mib $unc)" $HOT0 $hot "$v"
	printf '%-13s   (%s)\n' "" "$5"
}

echo
fresh; $UW write /$P/none/full $MB 131072 plain; settle
measure full-128k control-off none full "primarycache=none, 128k writes: whole records leave nothing"
fresh; $UW write /$P/all/cached $MB 4096 plain; settle
measure cached-4k control-on all cached "primarycache=all, 4k writes: cached data, fills the dbuf cache"
fresh; $UW write /$P/none/f4k $MB 4096 plain; settle
measure none-4k case none f4k "primarycache=none, 4k writes"
fresh; $UW write /$P/all/direct $MB 4096 direct; settle
measure odirect-4k case all direct "O_DIRECT 4k writes on primarycache=all"
fresh; $UW write /$P/all/dontcache $MB 4096 dontcache; rc=$?; settle
if [ $rc = 3 ]; then
	printf '%-13s skipped: this kernel or build refuses RWF_DONTCACHE\n' dontcache-4k
else
	measure dontcache-4k case all dontcache "pwritev2(RWF_DONTCACHE) 4k writes on primarycache=all"
fi
$UW write /$P/all/cold $MB 131072 direct; settle	# full records, O_DIRECT: nothing cached
fresh; zfs rewrite /$P/all/cold || err+=(rewrite-cmd); settle
measure rewrite case all cold "zfs rewrite of a cold 32 MiB file on primarycache=all"
# keep the writes in the open txg until the fsync: the txg sync thread
# reads zfs_txg_timeout when it starts waiting, so set it before the import
echo 600 >$M/zfs_txg_timeout; echo 100 >$M/zfs_dirty_data_sync_percent
fresh; zpool sync $P
# the first ZIL commit after the import creates the log and waits for the
# txg to sync, which would drop the itxs of the writes: commit once first
$UW write /$P/all/warmup 1 4096 plain fsync
$UW write /$P/all/fsync $MB 4096 direct
$UW fsync /$P/all/fsync	# as dd conv=fsync would
echo $TXG_TIMEOUT >$M/zfs_txg_timeout; echo $SYNC_PCT >$M/zfs_dirty_data_sync_percent
settle
measure fsync case all fsync "O_DIRECT 4k writes, then fsync() (ZIL copy) before the txg syncs"

echo
zpool export $P && echo "pool $P exported (on $V)"
if [ ${#err[@]} -gt 0 ]; then
	echo "RESULT ERROR: ${err[*]} (see above)"; exit 2
elif [ ${#bad[@]} -gt 0 ]; then
	# "every case": stable across kernels (dontcache-4k runs on 6.14+ only)
	all="${#bad[@]} of $ncase cases"; [ ${#bad[@]} = $ncase ] && all="every case ($ncase of $ncase)"
	echo "RESULT BUG: uncached data stays in the dbuf cache in $all: ${bad[*]}"
else
	echo "RESULT OK: no uncached data left in the dbuf cache in $ncase of $ncase cases"
fi
