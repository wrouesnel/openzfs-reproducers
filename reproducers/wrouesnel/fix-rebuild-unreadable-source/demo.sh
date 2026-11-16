#!/bin/bash
# demo.sh -- sequential rebuild ("zpool attach -s") while the old drive's
# reads fail.
#
# Pool: data drive a + special drive s (metadata on s, so the pool stays
# usable), 20 files of 1 MiB.  Every read of a fails (zinject) while b is
# attached with "zpool attach -s" (the scrub that normally follows a rebuild
# is turned off, to show the rebuild's own result).  Then the read errors stop.
#   bug: the rebuild "copied" b's empty contents over a (a's reads failed, the
#        mirror fell back to b, which has no data yet, and wrote that back over
#        a) and reported no errors; b looks complete, so "zpool detach a" is
#        accepted -> every file is damaged
#   fix: the rebuild reports the read errors and leaves b's DTL alone: a still
#        has every file, "zpool detach a" is refused until a scrub has copied
#        the data to b, then b alone holds every file
# Builds:
#   bug  test commit (fix-rebuild-unreadable-source~2: master + the ZTS test)
#        -> "RESULT BUG: the rebuild overwrote the old drive; N of 20 files damaged"
#   fix  fix-rebuild-unreadable-source (the branch head)
#        -> "RESULT OK: the old drive kept its data; detach refused until a scrub copied it; all 20 files intact"
# Run as root:  /demo/demo.sh       under a minute.
set -u
P=demorb D=/var/tmp/demorb N=20

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

step "1. pool: data drive a + special drive s, $N files"
zinject -c all >/dev/null 2>&1
zpool destroy -f $P 2>/dev/null
rm -rf $D; mkdir -p $D
truncate -s 256M $D/a $D/b $D/s
run zpool create -f -o ashift=12 -O compression=off -O primarycache=metadata $P $D/a special $D/s ||
    die "could not create $P"
for i in $(seq $N); do dd if=/dev/urandom of=/$P/f$i bs=128k count=8 status=none; done
echo "# (wrote f1..f$N, 1 MiB each)"
for i in $(seq $N); do sha256sum /$P/f$i | cut -d' ' -f1; done >$D/sums
run zpool export $P
run zpool import -d $D $P || die "import failed"
st

step "2. every read of a fails; zpool attach -s $P a b (sequential rebuild)"
echo 0 > /sys/module/zfs/parameters/zfs_rebuild_scrub_enabled
run zinject -d $D/a -e io -T read -f 100 $P
run zpool attach -s $P $D/a $D/b || die "attach failed"
run zpool wait -t resilver $P
st

step "3. the read errors stop: does a still hold the files?"
run zinject -c all
check
abad=$bad
st

step "4. zpool detach $P a (b would be the only copy)"
if run zpool detach $P $D/a; then
	detached=1
	echo "-> detach accepted"
else
	detached=0
	echo "-> detach refused: b doesn't hold the data yet"
fi
st
if [ $detached = 0 ]; then
	step "5. scrub (a reads again: the data is copied to b), then detach a"
	run zpool scrub -w $P
	st
	run zpool detach $P $D/a || die "detach after the scrub failed"
fi
step "6. b alone: export, import, check every file"
run zpool export $P
run zpool import -d $D $P || die "import failed"
check
bbad=$bad
st
echo 1 > /sys/module/zfs/parameters/zfs_rebuild_scrub_enabled
zpool destroy -f $P

if [ $abad -gt 0 ]; then
	echo "RESULT BUG: the rebuild overwrote the old drive; $abad of $N files damaged"
	exit 1
fi
if [ $detached = 1 ] || [ $bbad -gt 0 ]; then
	echo "RESULT BUG: detach of the old drive was accepted after a rebuild that couldn't read it; $bbad of $N files damaged"
	exit 1
fi
echo "RESULT OK: the old drive kept its data; detach refused until a scrub copied it; all $N files intact"
