#!/bin/bash
# demo.sh -- bug #173 / openzfs #11797: a mode 0 fallocate(2) that extends a
# file decides to extend from i_size read before any range lock.  An
# appending write that lands in between has already made the file bigger,
# and the "extend" then cuts the file back to the fallocated length.  The
# open file then reads back 128 KiB short, even after fsync.
#
# Steps (zpool status -v at the start and end):
#   1. pool demo173 on a file, dataset with recordsize=128k
#   2. what each iteration does, and what a correct result looks like
#   3. 2000 iterations of: new file; one thread appends 128 KiB at offset
#      128 KiB, the other fallocates the first 128 KiB.  Both orders must
#      leave a 256 KiB file holding the written bytes.
#   4. the first bad file (kept as f.bad), reopened: size and contents of
#      the second block, before and after export/import
#   5. data check
#
# Builds:
#   bug  test commit af63ff9555 (master 7c3d85aaf1 + the ZTS test)
#        -> "RESULT BUG: N of 2000 iterations left the file 128 KiB short"
#   fix  fix-falloc-extend-no-trunc e6091abb73
#        -> "RESULT OK: all 2000 iterations kept the appended 128 KiB"
# Run as root:  /demo/demo.sh       about a minute.
set -u
P=demo173 D=/var/tmp/demo173 N=2000
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

step "5. data check"
if [ "$lost" != 0 ]; then
	echo "-> $lost of $N iterations: once both calls had returned, the open file was"
	echo "   131072 bytes instead of 262144, and still was after fsync: the fallocate"
	echo "   'extend' cut the file back below the bytes the racing write had just added"
	echo "   (zpool status shows no errors: nothing flags it)"
	zpool destroy $P
	echo "RESULT BUG: $lost of $N iterations left the file 128 KiB short (131072 instead of 262144 bytes, also after fsync)"
	exit 0
fi
echo "-> every iteration left a 256 KiB file with the written block intact"
zpool destroy $P
echo "RESULT OK: all $N iterations kept the appended 128 KiB"
