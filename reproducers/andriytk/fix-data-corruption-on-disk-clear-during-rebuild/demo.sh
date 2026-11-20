#!/bin/bash
# demo.sh -- openzfs/zfs#19936: on dRAID, a disk that is cleared while
# another disk's sequential rebuild runs loses its distributed spare when
# that rebuild finishes, although it is still missing data.
#
# A sequential rebuild excises the DTLs of the vdevs under the top-level
# vdev when it finishes.  On master that includes a leaf that was faulted,
# rebuilt onto a distributed spare and then cleared (`zpool clear`) during
# the rebuild: its DTL still covered the data written while it was out,
# but the excise empties it and the spare is detached.  The data on the
# cleared disk is stale and nothing says so until a scrub; if another disk
# fails first, there isn't enough redundancy left to read everything.
#
#   1. draid1:2d:10c:3s on 10 disks, zfs_rebuild_scrub_enabled=0 (as the
#      PR's test; with the default, the scrub queued by the rebuild repairs
#      the cleared disks right after it), set A written
#   2. d7 faulted (offline -f), rebuilt onto draid1-0-0 (replace -s)
#   3. d8 the same, onto draid1-0-1
#   4. set B written: d7 and d8 miss it, their spares hold it
#   5. d9 faulted and replace -s onto draid1-0-2, the rebuild held with
#      zfs_scan_suspend_progress=1; d7 and d8 cleared while it is held
#   6. the rebuild let go and finished
#      master: both spares detached (AVAIL) -> RESULT BUG
#      PR:     both spares still INUSE
#   7. the next disk, d0, fails (offline -f), before any scrub
#   8. export/import, every file read back and compared
#      master: files with set-B data on d7/d8 can't be reconstructed
#      PR:     every file intact -> RESULT OK
# Pool tdc on the 10 run disks $DEMO_DISKS (or files in /var/tmp/tdc).
# Exported at the end.  About 2 minutes.
set -u
P=tdc D=/var/tmp/tdc
mkdir -p $D
if [ -n "${DEMO_DISKS:-}" ]; then
	read -r -a V <<< "$DEMO_DISKS"
else
	V=(); for i in $(seq 0 9); do truncate -s 512M $D/d$i; V+=($D/d$i); done
fi
[ ${#V[@]} -ge 10 ] || { echo "RESULT ERROR: need 10 disks, have ${#V[@]}"; exit 2; }

step=0
st() {	# label: the pool's state after a step
	step=$((step+1))
	echo; echo "--- zpool status -v $P   (step $step: $1)"
	zpool status -v $P 2>&1 | sed '/^$/d; s/^/    /'
}
run() { echo "\$ $*"; "$@" 2>&1 | sed 's/^/  /'; return "${PIPESTATUS[0]}"; }
tun() { echo "# $1=$2"; echo "$2" > /sys/module/zfs/parameters/$1; }
result() {	# the RESULT line, also through the kernel's console
	tun zfs_scan_suspend_progress 0 >/dev/null
	echo 1 > /sys/module/zfs/parameters/zfs_rebuild_scrub_enabled
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}
# a sequential rebuild shows "resilver (TOPVDEV) in progress"
rebuilding() { zpool status $P | grep -qE 'resilver \(.*in progress'; }
spare() { zpool status $P | awk -v s=$1 '$1 == s && ($2 == "AVAIL" || $2 == "INUSE") { print $2; exit }'; }
leaf() { echo "${V[$1]}"; }
sums() { (cd /$P && for f in $(ls | sort -V); do echo "$f $(sha256sum < $f 2>/dev/null | cut -c1-16)"; done); }

echo "# $(uname -sr); build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# disks d0..d9: ${V[*]}"
zinject -c all >/dev/null 2>&1
echo 0 > /sys/module/zfs/parameters/zfs_scan_suspend_progress
zpool destroy -f $P 2>/dev/null
for v in "${V[@]}"; do zpool labelclear -f "$v" 2>/dev/null; done
mkdir -p /etc/zfs

echo; echo "## 1. a draid1:2d:10c:3s pool, set A (20 x 2 MiB)"
run zpool create -f -O compression=off -O recordsize=128K $P draid1:2d:10c:3s "${V[@]}" ||
    { result "RESULT ERROR: zpool create failed"; exit 2; }
tun zfs_rebuild_scrub_enabled 0
for i in $(seq 1 20); do dd if=/dev/urandom of=/$P/a$i bs=1M count=2 status=none; done
zpool sync $P
st "set A written"

echo; echo "## 2. d7 fails and is rebuilt onto the distributed spare draid1-0-0"
run zpool offline -f $P "$(leaf 7)"
run zpool replace -sw $P "$(leaf 7)" draid1-0-0
st "d7 faulted, rebuilt onto draid1-0-0"

echo; echo "## 3. d8 fails and is rebuilt onto draid1-0-1"
run zpool offline -f $P "$(leaf 8)"
run zpool replace -sw $P "$(leaf 8)" draid1-0-1
st "d8 faulted, rebuilt onto draid1-0-1"

echo; echo "## 4. set B (40 x 1 MiB): d7 and d8 miss it, their spares hold it"
for i in $(seq 1 40); do dd if=/dev/urandom of=/$P/b$i bs=1M count=1 status=none; done
zpool sync $P
sums > $D/sums
echo "  $(wc -l < $D/sums) files, checksums saved"
st "set B written"

echo; echo "## 5. d9 fails; its rebuild onto draid1-0-2 is held while d7 and d8 are cleared"
tun zfs_scan_suspend_progress 1
run zpool offline -f $P "$(leaf 9)"
run zpool replace -s $P "$(leaf 9)" draid1-0-2
rebuilding || { result "RESULT ERROR: the rebuild of d9 is not running before the clears"; exit 2; }
run zpool clear $P "$(leaf 7)"
run zpool clear $P "$(leaf 8)"
rebuilding || { result "RESULT ERROR: the rebuild of d9 is not running after the clears"; exit 2; }
echo "  the rebuild of d9 was in progress during both clears"
st "d9 rebuilding (held), d7 and d8 cleared"

echo; echo "## 6. the rebuild of d9 goes on and finishes"
tun zfs_scan_suspend_progress 0
run zpool wait -t resilver $P
sleep 3
s0=$(spare draid1-0-0) s1=$(spare draid1-0-1)
echo "  spares: draid1-0-0 $s0, draid1-0-1 $s1   (d7 and d8 still miss set B)"
st "rebuild of d9 finished"

echo; echo "## 7. the next disk, d0, fails before any scrub"
run zpool offline -f $P "$(leaf 0)"
st "d0 faulted"

echo; echo "## 8. export/import, read every file back"
run zpool export $P
run zpool import -d "$(dirname "${V[0]}")" $P 2>/dev/null || run zpool import $P
sums > $D/now
lost=$(diff $D/sums $D/now | sed -n 's/^> \([^ ]*\) .*/\1/p' | tr '\n' ' ')
nlost=$(echo $lost | wc -w)
for f in $lost; do echo "\$ cat /$P/$f"; cat /$P/$f > /dev/null 2>$D/err || sed 's/^/  /' $D/err; done
echo "  files that don't read back as written: $nlost of $(wc -l < $D/sums)${lost:+ ($lost)}"
st "after the import, files read"
run zpool export $P

echo "  spares after the rebuild: draid1-0-0 $s0, draid1-0-1 $s1; with d0 failed, $nlost of 60 files lost"
sleep 1
if [ "$s0" = AVAIL ] || [ "$s1" = AVAIL ]; then
	result "RESULT BUG: the spares of the cleared disks were detached; $nlost of 60 files lost"
elif [ "$s0" = INUSE ] && [ "$s1" = INUSE ] && [ "$nlost" = 0 ]; then
	result "RESULT OK: the spares stayed in use and every file read back intact"
else
	result "RESULT OTHER: spares $s0/$s1; $nlost of 60 files lost"
fi
sleep 2
