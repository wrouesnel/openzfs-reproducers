#!/bin/bash
# demo.sh -- bug #152 / openzfs #19441 v5: replacing a FAULTED drive whose
# mirror partner can't supply some blocks.
#
# ZFS faults a drive for write errors or for read errors elsewhere on it; such
# a drive can often still be read.  Here the faulted drive a holds the only
# good copy of three blocks (b's copies are damaged on disk).
#
# Part A (the bug): mirror a,b; b's copy of one block of f3, f7, f11
# overwritten; a faulted ("zpool offline -f", still attached); zpool replace a c.
#   bug: the replacement completes and detaches a -> f3, f7, f11 are lost
#   fix: the replacement is held, zpool status says why and what to do
#        (status/action, a marked "(may hold missing data)"); zpool clear
#        brings a back, the resilver copies the blocks, the replacement
#        completes, every file verifies
# Part B (unchanged behaviour): the same, but a is missing (its file gone):
#   a dead drive can't help, so the replacement completes on both builds and
#   f3, f7, f11 are listed as permanent errors.
#
# Builds:
#   bug  test commit (fix-resilver-unreadable-dtl-v5~1: master + the ZTS tests)
#        -> "RESULT BUG: replace detached the faulted drive; 3 of 20 files lost"
#   fix  fix-resilver-unreadable-dtl-v5 (the branch head)
#        -> "RESULT OK: replacement held for the faulted drive, zpool clear recovered all 20 files; dead drive replaced as before"
# Run as root:  /demo/demo.sh       about a minute.
set -u
P=demo152 D=/var/tmp/demo152 G=/var/tmp/demo152-gone N=20 BAD="3 7 11"

run() { echo "# $*"; "$@"; }
st() { echo; echo "## zpool status -v $P"; zpool status -v $P | sed 's/^/   /'; echo; }
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
die() { echo "RESULT ERROR: $*"; exit 2; }
check() {
	bad=0
	for i in $(seq $N); do
		s=$(sha256sum /$P/f$i 2>/dev/null | cut -d' ' -f1)
		[ "$s" = "$(sed -n "${i}p" $D/sums)" ] || { bad=$((bad + 1)); echo "   f$i: checksum mismatch or read error"; }
	done
	echo "-> $bad of $N files damaged"
}
has_a() { zpool status -g $P | grep -qw "$AGUID"; }

# setup MODE: mirror a,b with N files; b's copy of one block of each BAD file
# overwritten; a faulted (MODE=faulted) or missing (MODE=dead).
setup() {
	zpool destroy -f $P 2>/dev/null
	rm -rf $D $G; mkdir -p $D $G
	truncate -s 256M $D/a $D/b $D/c
	run zpool create -f -o ashift=12 -O compression=off -O primarycache=metadata $P mirror $D/a $D/b ||
	    die "could not create $P"
	for i in $(seq $N); do dd if=/dev/urandom of=/$P/f$i bs=128k count=8 status=none; done
	echo "# (wrote f1..f$N, 1 MiB each)"
	for i in $(seq $N); do sha256sum /$P/f$i | cut -d' ' -f1; done >$D/sums
	run zpool sync $P
	AGUID=$(zdb -l $D/a | awk '$1 == "guid:" { print $2; exit }')
	declare -gA OFF ASZ
	for i in $BAD; do
		dva=$(zdb -dddddd $P/ $(stat -c %i /$P/f$i) | awk '$2 == "L0" { print $3; exit }')
		OFF[$i]=$((16#$(echo $dva | cut -d: -f2))); ASZ[$i]=$((16#$(echo $dva | cut -d: -f3)))
	done
	st
	run zpool export $P
	for i in $BAD; do
		echo "# overwrite b's copy of the first block of f$i (offset ${OFF[$i]}, ${ASZ[$i]} bytes)"
		dd if=/dev/urandom of=$D/b bs=4096 conv=notrunc status=none \
		    seek=$(( ${OFF[$i]} / 4096 + 1024 )) count=$(( ${ASZ[$i]} / 4096 ))
	done
	if [ "$1" = dead ]; then
		run mv $D/a $G/a
		echo "-> a is gone (dead drive)"
	fi
	run zpool import -d $D $P || die "import failed"
	if [ "$1" = faulted ]; then
		run zpool offline -f $P $AGUID
		echo "-> a is FAULTED but still attached: it still has good copies of f3, f7, f11"
	fi
	st
}

replace() {
	run zpool replace $P $AGUID $D/c || die "replace failed"
	run zpool wait -t resilver $P
	sleep 5
	st
}

zpool destroy -f $P 2>/dev/null

step "A1. mirror a,b; b's copies of f3, f7, f11 damaged; a faulted (still attached)"
setup faulted

step "A2. zpool replace $P a c: the resilver can't read f3, f7, f11 from b"
replace
if ! has_a; then
	echo "-> the replacement completed and a is gone from the pool"
	step "A3. (bug) check the files"
	check
	run zpool export $P && run zpool import -d $D $P
	st
	echo "-> a, the faulted drive that still had good copies, was detached"
	echo "RESULT BUG: replace detached the faulted drive; $bad of $N files lost"
	exit 0
fi
echo "-> the replacement is held: a stays in replacing-0"
zpool status $P | grep -q 'cannot finish replacing' || die "no REPLACE_HELD status for the held replacement"
zpool status $P | grep -q 'may hold missing data' || die "a isn't marked as holding missing data"

step "A3. (fix) zpool clear: bring a back so the resilver can copy the blocks from it"
run zpool clear $P
run zpool wait -t resilver $P
timeout 60 zpool wait -t replace $P || die "the replacement didn't complete after zpool clear"
st
has_a && die "a is still in the pool after the replacement completed"

step "A4. (fix) export/import, check every file, scrub twice (clears the error log)"
run zpool export $P && run zpool import -d $D $P || die "export/import failed"
check
abad=$bad
run zpool scrub -w $P
run zpool scrub -w $P
st
[ "$abad" -eq 0 ] || { echo "RESULT FAIL: the replacement was held, but after zpool clear $abad of $N files are damaged"; exit 0; }
zpool status -v $P | grep -q "errors: No known data errors" ||
    { echo "RESULT FAIL: files verify, but the pool still reports errors"; exit 0; }

step "B1. dead drive: the same, but a is missing"
setup dead

step "B2. zpool replace $P a c: a can't help, so the replacement completes (as on master)"
replace
has_a && { echo "RESULT FAIL: the replacement of a dead drive didn't complete"; exit 0; }
check
zpool status -v $P | grep -q "/$P/f3" ||
    { echo "RESULT FAIL: the lost files aren't listed as permanent errors"; exit 0; }
echo "-> completed; the $bad unrecoverable files are listed as permanent errors"
zpool destroy -f $P

echo "RESULT OK: replacement held for the faulted drive, zpool clear recovered all $N files; dead drive replaced as before"
