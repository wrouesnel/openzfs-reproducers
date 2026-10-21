#!/bin/bash
# demo.sh -- bug #194 / openzfs #15420: zdb -S (the simulated DDT histogram)
# ignores the error of its pool traversal.  The traversal stops at the first
# block it can't read, so zdb prints the histogram of only the blocks it
# visited before that (an empty one if the error came early) and exits 0: it
# looks like a complete answer for a pool with less data, or a different
# dedup ratio, than it really has.
#
# Steps (stdout, stderr and the exit status of every zdb -S are shown):
#   1. pool on a file vdev; a dataset with one copy of its metadata
#      (redundant_metadata=none), files a and b (8 MiB of random data each)
#      and b2 (a copy of b): 64 blocks with refcnt 1, 64 with refcnt 2
#   2. zdb -S on the healthy pool: the full histogram, exit 0
#   3. export, overwrite the L1 indirect block of file a on the vdev
#   4. zdb -e -S on the damaged pool
#        bug: a short histogram, nothing on stderr, exit 0
#        fix: the same partial histogram, then on stderr "traversing the pool
#             failed ...; the simulated DDT histogram is incomplete", exit != 0
#   5. import and scrub: zpool status -v shows the damage zdb ran into
#
# Builds:
#   bug  test commit 0c3fa4ea1b (the ZTS test, no fix)
#        -> "RESULT BUG: zdb -S exited 0 on a failed traversal ..."
#   fix  fix-zdb-simulated-ddt-errors a3b6f64a95
#        -> "RESULT OK: zdb -S exited N and said the histogram is incomplete"
# Run as root:  /demo/demo.sh       a few seconds.
set -u
P=demo194 D=/var/tmp/demo194 FS=demo194/fs
V=$D/vdev OUT=$D/zdb.out ERR=$D/zdb.err

run() { echo "# $*"; "$@"; }
st() { echo; echo "## zpool status -v $P"; zpool status -v $P | sed 's/^/   /'; echo; }
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
die() { echo "RESULT ERROR: $*"; exit 2; }
# zdb ARGS...: run it, show stdout, stderr and the exit status; sets $rc
zdbshow() {
	echo "# zdb $*"
	zdb "$@" >$OUT 2>$ERR; rc=$?
	echo "---- stdout ----"; sed 's/^/   /' $OUT
	echo "---- stderr ----"; if [ -s $ERR ]; then sed 's/^/   /' $ERR; else echo "   (empty)"; fi
	echo "---- exit status: $rc ----"
}
# the "Total" row's referenced blocks (column 6), or 0 if there is none
total() { awk '$1 == "Total" { print $6; f = 1 } END { if (!f) print 0 }' $OUT; }

zpool destroy -f $P 2>/dev/null
rm -rf $D; mkdir -p $D

step "1. pool $P on $V; $FS keeps one copy of its metadata"
truncate -s 256M $V
run zpool create -f -O compression=off $P $V || die "could not create $P"
run zfs create -o redundant_metadata=none -o recordsize=128k $FS || die "could not create $FS"
M=$(zfs get -H -o value mountpoint $FS)
run dd if=/dev/urandom of=$M/a bs=1M count=8 status=none
run dd if=/dev/urandom of=$M/b bs=1M count=8 status=none
run cp $M/b $M/b2
run zpool sync $P
ls -li $M
st

step "2. zdb -S on the healthy pool"
zdbshow -S $P
[ $rc -eq 0 ] || die "zdb -S failed on the healthy pool"
awk '$1 == "1" && $2 == "64"' $OUT | grep -q . && awk '$1 == "2" && $2 == "64"' $OUT | grep -q . ||
    die "the healthy histogram doesn't have 64 blocks with refcnt 1 and 64 with refcnt 2"
healthy=$(total)
echo "-> the full histogram: 64 unique blocks (refcnt 1: a), 64 duplicated (refcnt 2: b, b2), $healthy referenced"

step "3. export $P and overwrite the L1 indirect block of $M/a"
obj=$(ls -i $M/a | awk '{print $1}')
echo "# zdb -ddddd $FS $obj | awk '\$2 == \"L1\"'"
zdb -ddddd $FS $obj | awk '$2 == "L1"' | sed 's/^/   /'
dva=$(zdb -ddddd $FS $obj | awk '$2 == "L1" {print $3; exit}')
[ -n "$dva" ] || die "no L1 block found for object $obj"
offset=$(echo $dva | cut -d: -f2) asize=$(echo $dva | cut -d: -f3)
echo "-> L1 of a (object $obj): vdev:offset:asize = $dva"
run zpool export $P || die "export failed"
# the vdev's allocatable space starts after the 4 MiB of front labels
echo "# dd if=/dev/urandom of=$V bs=512 conv=notrunc seek=\$(( (0x$offset + 0x400000) / 512 )) count=\$(( 0x$asize / 512 ))"
dd if=/dev/urandom of=$V bs=512 conv=notrunc status=none \
    seek=$(( (0x$offset + 0x400000) / 512 )) count=$(( 0x$asize / 512 )) || die "dd failed"
echo "-> the only copy of a's L1 block is now garbage: the traversal can't read it"

step "4. zdb -S on the damaged pool"
zdbshow -e -p $D -S $P
damaged=$(total)
echo "-> healthy: $healthy blocks referenced; damaged: $damaged (the traversal stopped at a's L1 block)"
if grep -q incomplete $ERR; then said=1; else said=0; fi

step "5. import $P and scrub: what zdb ran into"
run zpool import -d $D $P || die "import failed"
run zpool scrub -w $P
st
run zpool export $P

echo
echo "zdb -S on the damaged pool: exit status $rc, $damaged of $healthy blocks in the histogram"
if [ $rc -eq 0 ]; then
	echo "RESULT BUG: zdb -S exited 0 on a failed traversal; its histogram counts $damaged of $healthy blocks and nothing says it is incomplete"
elif [ $said -eq 1 ]; then
	echo "RESULT OK: zdb -S exited $rc and said the histogram is incomplete"
else
	echo "RESULT FAIL: zdb -S exited $rc but didn't say the histogram is incomplete"
fi
