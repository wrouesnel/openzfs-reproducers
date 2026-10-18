#!/bin/bash
# demo.sh -- bug #152 / openzfs #19441: a resilver that can't read some
# blocks still marks the new device complete, so the old device -- the only
# one holding those blocks -- can be detached (or is dropped by replace), and
# the blocks are lost even though the old device could still supply them.
#
# Steps (zpool status -v after each one):
#   1. one-device pool on file a, 64 files of 1 MiB, sha256 sums recorded
#   2. reads of 8 files' data fail on a (zinject), deterministically
#   3. zpool attach a b: the resilver can't copy those 8 files' blocks
#   4. zinject -c all: a reads fine again
#   5. zpool detach a
#        bug: accepted -> export/import, the 8 files fail their checksums
#        fix: refused ("no valid replicas") -> zpool clear, zpool scrub
#             copies the missing blocks from a, the detach then succeeds,
#             and every file verifies
#
# Builds:
#   bug  test commit 766534ea46 (master 7c3d85aaf1 + the ZTS test)
#        -> "RESULT BUG: detach accepted after a resilver with N errors; 8 of 64 files lost"
#   fix  fix-resilver-unreadable-dtl 931ff21aa1
#        -> "RESULT OK: pool repaired, all 64 files verified"
# Run as root:  /demo/demo.sh       about 30 seconds.
set -u
P=demo152 D=/var/tmp/demo152 N=64 NBAD=8
A=$D/a B=$D/b

run() { echo "# $*"; "$@"; }
st() { echo; echo "## zpool status -v $P"; zpool status -v $P | sed 's/^/   /'; echo; }
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
die() { echo "RESULT ERROR: $*"; exit 2; }
verify() {
	run zpool export $P && run zpool import -d $D $P || die "export/import failed"
	bad=0
	for i in $(seq $N); do
		s=$(sha256sum /$P/f$i 2>/dev/null | cut -d' ' -f1)
		[ "$s" = "$(sed -n "${i}p" $D/sums)" ] || { bad=$((bad + 1)); echo "   f$i: checksum mismatch or read error"; }
	done
	echo "-> $bad of $N files damaged"
}

zinject -c all >/dev/null 2>&1
zpool destroy -f $P 2>/dev/null
rm -rf $D; mkdir -p $D

step "1. pool $P on $A, $N files of 1 MiB, checksums recorded"
truncate -s 256M $A $B
run zpool create -f -O compression=off -O primarycache=metadata $P $A || die "could not create $P"
for i in $(seq $N); do dd if=/dev/urandom of=/$P/f$i bs=1M count=1 status=none; done
echo "# (wrote f1..f$N)"
for i in $(seq $N); do sha256sum /$P/f$i | cut -d' ' -f1; done >$D/sums
run zpool export $P && run zpool import -d $D $P || die "export/import failed"
st

step "2. make reads of $NBAD files' data fail on $A (the only copy)"
for i in $(seq $NBAD); do run zinject -t data -e io -f 100 /$P/f$i >/dev/null || die "zinject failed"; done
run zinject
st
echo "-> nothing has failed yet: zinject only makes those reads fail when they happen"

step "3. zpool attach: resilver $A onto $B"
run zpool attach $P $A $B || die "attach failed"
st
run zpool wait -t resilver $P
st
errors=$(zpool status $P | sed -n 's/.*resilvered.* with \([0-9]*\) errors.*/\1/p')
echo "-> the resilver finished with ${errors:-?} errors: those blocks never reached $B"

step "4. zinject -c all: $A can be read again"
run zinject -c all
st

step "5. zpool detach $P $A (the old device)"
echo "# zpool detach $P $A"
if out=$(zpool detach $P $A 2>&1); then
	echo "-> ACCEPTED"; [ -n "$out" ] && echo "   $out"
	st
	step "6. (bug) export/import and check the files"
	verify
	run zpool scrub -w $P
	st
	echo "RESULT BUG: detach accepted after a resilver with ${errors:-?} errors; $bad of $N files lost"
	exit 0
fi
echo "-> REFUSED: $out"
st

step "6. (fix) zpool clear + zpool scrub: copy the missing blocks from $A"
run zpool clear $P
run zpool scrub -w $P
st
echo "-> the scrub read the $NBAD files from $A and rewrote them on $B (the CKSUM count on $B)"
echo "# zpool detach $P $A"
out=$(zpool detach $P $A 2>&1) || die "detach still refused after the scrub: $out"
echo "-> ACCEPTED"
st

step "7. (fix) export/import and check the files"
verify
st
if [ "$bad" -eq 0 ] && zpool status -v $P | grep -q "errors: No known data errors"; then
	echo "RESULT OK: pool repaired, all $N files verified"
else
	echo "RESULT FAIL: detach refused, but after the scrub $bad of $N files are damaged"
fi
