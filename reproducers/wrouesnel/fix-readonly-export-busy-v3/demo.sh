#!/bin/bash
# demo.sh -- bug #121: `zpool export` / `zpool destroy` of a pool imported
# read-only fails with "pool is busy" right after it unmounts the pool's
# file systems, although nothing uses the pool; a retry a moment later works.
# Each closed dataset is evicted asynchronously, and its dsl_dir holds a
# reference on the pool until then.  spa_export_common() waits for those
# evictions only when the pool has a sync thread, which a read-only pool
# never has.  The more the file system has cached, the longer the window.
#
# Steps (zpool status / zpool list after each one):
#   1. pool demo121 on the run disk, file system demo121/fs with 10000 files
#   2-4. zpool import -o readonly=on, ls -l of the files, zpool export
#   5. zpool import -o readonly=on, ls -l, zpool destroy
#   Every export/destroy is run once; if it fails, the demo shows that the
#   pool is still imported and has nothing mounted, waits 1 s and runs it
#   again (which succeeds: the race is transient).
#
# Builds:
#   bug  test commit of fix-readonly-export-busy-v3 (master + the ZTS test)
#        -> "RESULT BUG: 4 of 4 read-only exports/destroys failed with 'pool is busy'"
#   fix  fix-readonly-export-busy-v3 head
#        -> "RESULT OK: 4 of 4 read-only exports/destroys succeeded at once"
# Run as root:  /demo/demo.sh       about 30 seconds.
set -u
P=demo121 D=/var/tmp/demo121 M=/var/tmp/demo121/mnt N=10000
V=${DEMO_DISK:-$D/vdev}

run() { echo "# $*"; "$@"; }
st() { echo; echo "## zpool status $P"; zpool status $P 2>&1 | sed 's/^/   /'; echo; }
lst() {
	local l m
	echo "## zpool list -H -o name,health,readonly $P; grep $P /proc/mounts"
	if l=$(zpool list -H -o name,health,readonly $P 2>&1); then
		echo "   imported: $l"
	else
		echo "   not imported ($l)"
	fi
	m=$(grep "^$P[ /]" /proc/mounts)
	if [ -n "$m" ]; then echo "$m" | sed 's/^/   mounted: /'; else echo "   no $P file system mounted"; fi
	echo
}
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
die() { echo "RESULT ERROR: $*"; exit 2; }

zpool destroy -f $P 2>/dev/null
rm -rf $D; mkdir -p $D
[ -n "${DEMO_DISK:-}" ] || truncate -s 512M $V

step "1. pool $P on $V, file system $P/fs with $N empty files"
run zpool create -f -o cachefile=none -O mountpoint=none $P $V || die "could not create $P"
run zfs create -o mountpoint=$M $P/fs || die "could not create $P/fs"
echo "# (cd $M && seq $N | xargs touch)"
(cd $M && seq $N | xargs touch) || die "could not create the files"
echo "-> $(ls $M | wc -l) files in $M"
run zpool export $P || die "export of the read-write pool failed"
lst

busy=0 total=0
attempt() {	# attempt ROUND export|destroy
	local r=$1 cmd=$2 out
	total=$((total + 1))
	echo "# zpool $cmd $P"
	if out=$(zpool $cmd $P 2>&1); then
		echo "-> zpool $cmd $P: OK (exit 0)"
		lst
		zpool list $P >/dev/null 2>&1 && die "zpool $cmd returned 0 but $P is still imported"
		return 0
	fi
	busy=$((busy + 1))
	echo "-> zpool $cmd $P FAILED: $out"
	echo "   (the file systems are already unmounted; the pool is still imported:)"
	lst
	st
	echo "# sleep 1; zpool $cmd $P    (the same command again)"
	sleep 1
	if out=$(zpool $cmd $P 2>&1); then
		echo "-> retry OK (exit 0): a second later the same command works"
	else
		echo "-> retry FAILED too: $out"
		zpool $cmd -f $P 2>/dev/null
	fi
	lst
}

for r in 1 2 3; do
	step "$((r + 1)). round $r: import read-only, ls -l the files, export"
	run zpool import -d $V -o readonly=on $P || die "read-only import failed"
	lst
	st
	echo "# ls -l $M >/dev/null"
	ls -l $M >/dev/null
	attempt $r export
done

step "5. import read-only, ls -l the files, destroy"
run zpool import -d $V -o readonly=on $P || die "read-only import failed"
lst
st
echo "# ls -l $M >/dev/null"
ls -l $M >/dev/null
attempt 4 destroy

echo
if [ $busy -gt 0 ]; then
	echo "RESULT BUG: $busy of $total read-only exports/destroys failed with 'pool is busy'"
else
	echo "RESULT OK: $total of $total read-only exports/destroys succeeded at once"
fi
