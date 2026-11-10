#!/bin/bash
# demo.sh -- openzfs/zfs#19766 (@bScones): concurrent sync writes into a new
# block log all-zero TX_WRITE payloads, and ZIL replay writes those zeros over
# data whose write had already returned.
#
# When several threads write into the same not yet allocated block of a new
# file, the first to dirty it publishes its dirty record before it raises
# dn_maxblkid.  Another writer that finds the block already dirty in that
# window copies its data in, then reads it back for its log record
# (zfs_log_write(), WR_COPIED) through dmu_read_impl(), whose "past
# dn_maxblkid, so a hole" shortcut returns zeros.  The live file is right; the
# log holds zeros; a crash plus replay writes them to disk.
#
# No test-only delay: the natural race.  ROUNDS rounds of:
#   1. pool on files with a slog (on tmpfs), dataset recordsize=128k,
#      logbias=latency; zpool freeze (from here on only the ZIL reaches
#      disk, so every logged write is replayed, as after a crash)
#   2. /demo/zil_zero_race: for each of NFILES new O_DSYNC files, NTHREADS
#      threads released together each pwrite() 4 KiB into the file's second
#      block (offset 128K + i * 16K); then check the live files (correct on
#      both builds)
#   3. crash: copy the vdevs (the crash image), drop the live pool
#   4. zdb -ivvvv of the crash image's log: TX_WRITE records whose payload
#      is all zeros (every payload starts "RACE file=...")
#   5. import the crash image (replays the log), zpool status -v, check
#      every range
# Builds:
#   repro: openzfs/zfs master (the branch's base) -> zero payloads in the log,
#          zero ranges after replay: "RESULT BUG: ..."
#   fixed: test-zil-concurrent-new-block-pr67 (+ #19767, dmu_read_impl()
#          no longer trusts dn_maxblkid for power-of-2 blocks) -> "RESULT OK: ..."
# This checks only the zero payloads (the read side).  The free side (a hole
# punched over a write in the same window is skipped) is not exercised here;
# #19767 does not change it.
# The race is not forced: on 4 vCPUs master logs a few zero payloads per
# round (5-11 per 3200 writes in our runs).
# Run as root:  /demo/demo.sh       a few minutes.
set -u
P=zil19766 D=/var/tmp/zil19766 C=/var/tmp/zil19766-crash
ROUNDS=${ROUNDS:-3} NFILES=${NFILES:-400} NTHREADS=8 LEN=4096 BLK=131072
build=${DEMO_BUILD:-?}

run() { echo "# $*"; "$@"; }
st() { echo; echo "## zpool status -v $P"; zpool status -v $P | sed 's/^/   /'; echo; }
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
die() { echo "RESULT ERROR: $*"; exit 2; }
clean() {
	zpool destroy -f $P 2>/dev/null
	rm -f $D/* $C/*; rmdir $D $C 2>/dev/null
}

clean; mkdir -p $D $C
echo "build: $build   $(nproc) CPUs   zfs $(cat /sys/module/zfs/version 2>/dev/null)"
cat <<TXT
Each round: $NFILES new O_DSYNC files; per file $NTHREADS threads, released
together, each pwrite() $LEN bytes into the file's second block (recordsize
$BLK; offsets $BLK + i * $((BLK / NTHREADS))).  Every write returns only once
it is in the ZIL, so after a crash each range must come back with its data:
each starts "RACE file=F thr=T ...", never zeros.
TXT

tot_w=0 tot_z=0 tot_r=0 tot_rz=0 tot_bf=0 tot_live=0 shown=0
for r in $(seq "$ROUNDS"); do
	step "round $r/$ROUNDS, 1. pool $P (file vdev + slog on tmpfs), then freeze"
	truncate -s 1G $D/d0 $D/l0
	run zpool create -f -o cachefile=none $P $D/d0 log $D/l0 || die "could not create $P"
	run zfs create -o recordsize=$BLK -o compression=off -o logbias=latency $P/fs ||
	    die "could not create $P/fs"
	M=/$P/fs
	echo "# dd if=/dev/zero of=$M/sync conv=fdatasync,fsync bs=1 count=1   (gives the dataset a ZIL header)"
	dd if=/dev/zero of=$M/sync conv=fdatasync,fsync bs=1 count=1 status=none
	run zpool sync $P
	run zpool freeze $P || die "zpool freeze failed"
	echo "-> frozen: from here on only the ZIL reaches the disks, as after a crash"
	st

	step "round $r/$ROUNDS, 2. the race: $NFILES files x $NTHREADS threads x $LEN bytes"
	run /demo/zil_zero_race write $M $NFILES $NTHREADS $LEN $BLK || die "zil_zero_race write failed"
	echo "-> every pwrite() returned (O_DSYNC: each is in the log).  The live files:"
	echo "# /demo/zil_zero_race verify $M $NFILES $NTHREADS $LEN $BLK"
	live=$(/demo/zil_zero_race verify $M $NFILES $NTHREADS $LEN $BLK)
	echo "$live" | head -5 | sed 's/^/   /'
	lb=$(echo "$live" | tail -1 | sed -E 's/.*bad_files=([0-9]+).*/\1/')
	tot_live=$((tot_live + lb))
	st

	step "round $r/$ROUNDS, 3. crash: copy the vdevs, drop the live pool"
	run cp --sparse=always $D/d0 $D/l0 $C/ || die "could not copy the vdevs"
	echo "crash image: $(ls $C | tr '\n' ' ')"
	run zpool destroy -f $P

	step "round $r/$ROUNDS, 4. the log in the crash image: zdb -e -p $C -ivvvv $P/fs"
	zdb -e -p $C -ivvvv $P/fs >$D/zil.txt 2>&1
	nw=$(grep -c TX_WRITE $D/zil.txt)
	nz=$(awk '/TX_WRITE/ {getline; getline; if ($1 == "0" && $2 == "0" && $3 == "0") n++} END {print n + 0}' $D/zil.txt)
	echo "TX_WRITE records in the log: $nw (expect $((NFILES * NTHREADS)) from the race, + the sync file's)"
	echo "TX_WRITE records whose payload is all zeros: $nz"
	if [ "$nz" -gt 0 ] && [ $shown -lt 2 ]; then
		echo "-> the first zero record, with its neighbours (same file, other threads):"
		awk '/TX_WRITE/ {h=$0; getline; a=$0; getline; b=$0
			if ($1 == "0" && $2 == "0" && $3 == "0" && !done) {
				t = a; sub(/.*foid /, "", t); sub(/,.*/, "", t); foid = t; done=1 }
			rec[++n]=h "\n" a "\n" substr(b, 1, 64); fo[n]=a }
			END { for (i = 1; i <= n; i++) if (index(fo[i], "foid " foid ",")) print rec[i] }' \
		    $D/zil.txt | sed 's/^\t*/   /'
	fi
	tot_w=$((tot_w + nw)) tot_z=$((tot_z + nz))

	step "round $r/$ROUNDS, 5. import the crash image (replays the log), check every range"
	run zpool import -o cachefile=none -d $C $P || die "could not import the crash image"
	st
	echo "# /demo/zil_zero_race verify $M $NFILES $NTHREADS $LEN $BLK"
	out=$(/demo/zil_zero_race verify $M $NFILES $NTHREADS $LEN $BLK)
	echo "$out" | grep -v SUMMARY | head -8 | sed 's/^/   /'
	echo "$out" | tail -1 | sed 's/^/   /'
	s=$(echo "$out" | tail -1)
	rz=$(echo "$s" | sed -E 's/.*zero=([0-9]+).*/\1/')
	rm_=$(echo "$s" | sed -E 's/.*mismatch=([0-9]+).*/\1/')
	bf=$(echo "$s" | sed -E 's/.*bad_files=([0-9]+).*/\1/')
	tot_r=$((tot_r + NFILES * NTHREADS)) tot_rz=$((tot_rz + rz + rm_)) tot_bf=$((tot_bf + bf))
	first=$(echo "$out" | awk '/ (ZERO|MISMATCH) / {print $1, $3; exit}')
	if [ -n "$first" ] && [ $shown -lt 2 ]; then
		f=${first% *} off=${first#*off=}
		echo "-> one of them after replay ($f, offset $off): its write had returned"
		echo "# od -A d -t x1 -j $off -N 32 $f     (expect 52 41 43 45 = \"RACE\")"
		od -A d -t x1 -j "$off" -N 32 "$f" | sed 's/^/   /'
		shown=$((shown + 1))
	fi
	run zpool export $P
	rm -f $C/* $D/*
done

step "summary ($build build, $ROUNDS rounds)"
echo "writes acknowledged:                     $tot_r"
echo "bad files live, before the crash:        $tot_live"
echo "TX_WRITE records logged as zeros (zdb):  $tot_z of $tot_w"
echo "ranges wrong after replay:               $tot_rz in $tot_bf files"
clean
if [ "$tot_live" != 0 ]; then
	echo "RESULT ERROR: $tot_live live files were already wrong before the crash (not this bug)"
	exit 2
fi
if [ "$tot_z" != 0 ] || [ "$tot_rz" != 0 ]; then
	echo "-> the live files were right, but the log held zeros for writes that had"
	echo "   returned, and replay put those zeros on disk.  zpool status shows no"
	echo "   errors: nothing flags it."
	echo "RESULT BUG: $tot_z of $tot_w TX_WRITE records were logged as zeros; after replay $tot_rz acknowledged ranges in $tot_bf files read wrong"
	exit 0
fi
echo "-> every TX_WRITE carried its data, and every range came back after replay"
echo "RESULT OK: no zero TX_WRITE payloads in $tot_w records; all $tot_r acknowledged ranges intact after replay"
