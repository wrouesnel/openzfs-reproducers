#!/bin/bash
# demo.sh -- bug #173 / openzfs #11797: a mode 0 fallocate(2) that extends a
# file decides to extend from i_size read before any range lock.  When an
# appending write lands in between, the "extend" cuts i_size and the page
# cache back to the fallocated length, and it logs a TX_TRUNCATE outside the
# range lock, which the ZIL can order after the write.  So the open file
# reads back 128 KiB short, and after a crash ZIL replay truncates the file
# on disk and the fsynced block is lost.
#
# Steps (zpool status -v at the start and end):
#   1. pool demo173 on a file, dataset with recordsize=128k
#   2. what each iteration does, and what a correct result looks like
#   3. 2000 iterations of: new file; one thread appends 128 KiB at offset
#      128 KiB, the other fallocates the first 128 KiB.  Both orders must
#      leave a 256 KiB file holding the written bytes.
#   4. the first bad file (kept as f.bad), reopened, before and after
#      export/import
#   5. replay: pool demo173r on the run disk, frozen (zpool freeze: nothing
#      more reaches the main pool, as in a crash), 3000 raced files each
#      fsynced, then export/import, which replays the ZIL; every file checked
#   6. data check
#
# Builds:
#   bug  test commit 4f76e87f5e (master 1e9b428dca + the ZTS test)
#        -> "RESULT BUG: ..." (short open files, and files lost in replay)
#   fix  fix-falloc-extend-no-trunc f7d6b6229b
#        -> "RESULT OK: all 2000 iterations kept the appended 128 KiB, ..."
# Run as root:  /demo/demo.sh       a few minutes.
set -u
P=demo173 D=/var/tmp/demo173 N=2000
RP=demo173r RN=3000
F=/$P/fs/f

run() { echo "# $*"; "$@"; }
st() { echo; echo "## zpool status -v $P"; zpool status -v $P | sed 's/^/   /'; echo; }
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
die() { echo "RESULT ERROR: $*"; exit 2; }
show_file() {
	run ls -l "$1"
	sz=$(stat -c %s "$1")
	echo "   size $sz bytes, expected 262144 (two 128 KiB blocks)"
	echo "# od -A d -t x1 -j 131072 -N 32 $1    (start of the appended block: expect a5 a5 ...)"
	if [ "$sz" -gt 131072 ]; then
		od -A d -t x1 -j 131072 -N 32 "$1" | sed 's/^/   /'
	else
		echo "   (nothing there: the file ends at $sz, so the appended block was thrown away)"
	fi
}

zpool destroy -f $P 2>/dev/null
rm -rf $D; mkdir -p $D

step "1. pool $P on a file, dataset with recordsize=128k"
truncate -s 1G $D/a
run zpool create -f $P $D/a || die "could not create $P"
run zfs create -o recordsize=128k -o compression=off $P/fs || die "could not create $P/fs"
st

step "2. what each iteration does"
cat <<'TXT'
   new empty file; two threads start together:
     writer:    pwrite(fd, 128 KiB of 0xa5, offset 128 KiB)   (appends block 2)
     allocator: fallocate(fd, mode 0, offset 0, len 128 KiB)  (block 1)
   whichever runs first, the file must end up 256 KiB long, block 1 zeros,
   block 2 all 0xa5.  The helper checks size and data once both calls have
   returned, and again after fsync.
TXT

step "3. $N iterations: /demo/falloc_race $F $N"
echo "# /demo/falloc_race $F $N"
out=$(/demo/falloc_race $F $N); rc=$?
echo "$out"
[ $rc -le 1 ] || die "falloc_race failed"
lost=$(echo "$out" | tail -1 | awk '{print $1}')

step "4. the result on disk"
if [ -e $F.bad ]; then
	echo "-> the first bad iteration's file was kept as $F.bad (closed, renamed, now reopened)"
	show_file $F.bad
	echo
	echo "-> export and import the pool, so nothing comes from the cache"
	run zpool export $P && run zpool import -d $D $P || die "export/import failed"
	show_file $F.bad
	if [ "$(stat -c %s $F.bad)" = 262144 ]; then
		echo "-> once closed and reopened, this file is whole again: the written block"
		echo "   reached disk.  While it was open, after both calls had returned and"
		echo "   even after fsync, it read back as 128 KiB (step 3)."
	else
		echo "-> still short after import: the written block is gone from disk"
	fi
else
	echo "-> no iteration lost data; the last iteration's file:"
	show_file $F
	run zpool export $P && run zpool import -d $D $P || die "export/import failed"
	show_file $F
fi
st

step "5. replay: $RN raced, fsynced files on a frozen pool, then ZIL replay"
zpool destroy -f $RP 2>/dev/null
if [ -n "${DEMO_DISK:-}" ]; then
	RV=$DEMO_DISK RD=$(dirname $DEMO_DISK)
else
	RD=/var/tmp/demo173r RV=$RD/vdev
	rm -rf $RD; mkdir -p $RD; truncate -s 4G $RV
fi
run zpool create -f -O recordsize=128k -O compression=off $RP $RV || die "could not create $RP"
run zfs create $RP/fs || die "could not create $RP/fs"
run zpool sync $RP
echo "# dd if=/dev/zero of=/$RP/fs/sync conv=fdatasync,fsync bs=1 count=1    (start the ZIL)"
dd if=/dev/zero of=/$RP/fs/sync conv=fdatasync,fsync bs=1 count=1 status=none
echo "-> freeze the pool: from here on only the ZIL reaches disk, as after a crash"
run zpool freeze $RP || die "zpool freeze failed"
echo "# /demo/falloc_race keep /$RP/fs $RN"
/demo/falloc_race keep /$RP/fs $RN || die "falloc_race keep failed"
echo "-> every file was fsynced: each must come back 256 KiB with block 2 all 0xa5"
run zpool export $RP && run zpool import -d $RD $RP || die "export/import of $RP failed"
echo "# /demo/falloc_race check /$RP/fs $RN"
rout=$(/demo/falloc_race check /$RP/fs $RN); rrc=$?
echo "$rout"
[ $rrc -le 1 ] || die "falloc_race check failed"
rlost=$(echo "$rout" | tail -1 | awk '{print $1}')
first=$(echo "$rout" | awk '/^   \//{print $1; exit}' | tr -d :)
if [ -n "$first" ]; then
	echo "-> one of them, on disk after replay:"
	show_file $first
fi
zpool destroy $RP
[ -n "${DEMO_DISK:-}" ] || rm -rf $RD
st

step "6. data check"
zpool destroy $P
if [ "$lost" != 0 ] || [ "$rlost" != 0 ]; then
	[ "$lost" = 0 ] || {
	echo "-> $lost of $N iterations: once both calls had returned, the open file was"
	echo "   131072 bytes instead of 262144: the fallocate 'extend' cut i_size back"
	echo "   below the bytes the racing write had just added"; }
	[ "$rlost" = 0 ] || {
	echo "-> $rlost of $RN fsynced files came back from ZIL replay 128 KiB short: the"
	echo "   TX_TRUNCATE logged by the 'extend' replayed after the write, so the"
	echo "   fsynced block is gone from disk"; }
	echo "   (zpool status shows no errors: nothing flags it)"
	echo "RESULT BUG: $lost of $N live iterations left the file 128 KiB short; $rlost of $RN fsynced files lost 128 KiB in ZIL replay"
	exit 0
fi
echo "-> every iteration left a 256 KiB file with the written block intact,"
echo "   and every fsynced file came back whole from ZIL replay"
echo "RESULT OK: all $N iterations kept the appended 128 KiB, and all $RN files survived ZIL replay"
