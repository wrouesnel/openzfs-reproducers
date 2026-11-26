#!/bin/bash
# demo.sh -- openzfs/zfs#20038 (closes #14548): a thread reads a file through
# a shared mapping while another thread fills it with write().  On master a
# record that write() has already stored can read back wrong (zeros) through
# the mapping, and read() then returns the same wrong data from the page
# cache.  With the PR every record reads back as written.
#
# Steps (pool tank on the demo disk, file system tank/fs):
#   1. the PR's test program mmap_write_race (tests/zfs-tests/cmd), as its
#      ZTS test mmap/mmap_write_race runs it: an 8 MiB file extended up
#      front, one growing with each write, and one growing through O_APPEND,
#      SECS seconds each; it prints the first record that reads back wrong,
#      through the mapping and through read()
#   2. the program from #14548 (16 MiB), RUNS runs
#
#   master -> "RESULT BUG: records written with write() read back wrong data ..."
#   PR     -> "RESULT OK: records written with write() read back as written ..."
# Run as root:  /demo/demo.sh       about 2 to 4 minutes with the PR.
set -u
. /etc/demo-env 2>/dev/null
P=tank FS=tank/fs
SECS=${SECS:-10} RUNS=${RUNS:-3}

result() {	# the RESULT line, also through the kernel's console
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}

echo "# $(uname -sr); build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# $(zpool version 2>/dev/null | head -1)"
mkdir -p /etc/zfs
zpool destroy -f $P 2>/dev/null
echo "\$ zpool create -f -o cachefile=none $P ${DEMO_DISK:-?}; zfs create $FS"
zpool create -f -o cachefile=none $P "${DEMO_DISK:-}" ||
    { result "RESULT ERROR: zpool create failed"; exit 2; }
zfs create $FS || { result "RESULT ERROR: zfs create failed"; exit 2; }
M=$(zfs get -H -o value mountpoint $FS)

# 1. mmap_write_race, as the PR's ZTS test runs it
racebad=0
for opt in "" -a -A; do
	case $opt in
	'') what="extended up front" ;; -a) what="growing with each write" ;;
	-A) what="growing through O_APPEND" ;;
	esac
	echo
	echo "## mmap_write_race: 8 MiB file, $what, $SECS s"
	echo "\$ /demo/mmap_write_race $opt $M/race 8 $SECS"
	/demo/mmap_write_race $opt "$M/race" 8 "$SECS" 2>&1 | sed 's/^/  /'
	rc=${PIPESTATUS[0]}
	echo "  (exit status $rc)"
	case $rc in
	0) ;;
	1) racebad=$((racebad + 1)) ;;
	*) result "RESULT ERROR: mmap_write_race exited $rc"; exit 2 ;;
	esac
	rm -f "$M/race"
done

# 2. the program from #14548
ccbad=0
echo
echo "## the program from #14548 (16 MiB file), $RUNS runs"
for i in $(seq 1 "$RUNS"); do
	rm -f "$M/test-cc.bin"
	s=$(date +%s)
	out=$(cd "$M" && /demo/cc14548 2>&1); rc=$?
	echo "  run $i: exit status $rc after $(($(date +%s) - s)) s${out:+: $out}"
	case $rc in
	0) ;;
	2) case $out in *"data corrupt"*) ccbad=$((ccbad + 1)) ;;
	   *) result "RESULT ERROR: the #14548 program failed: $out"; exit 2 ;; esac ;;
	*) result "RESULT ERROR: the #14548 program exited $rc: $out"; exit 2 ;;
	esac
done
rm -f "$M/test-cc.bin"

echo
echo "--- zpool status -v $P"
zpool status -v $P 2>&1 | sed '/^$/d; s/^/    /'
zpool destroy $P

if [ $racebad -gt 0 ] || [ $ccbad -gt 0 ]; then
	result "RESULT BUG: records written with write() read back wrong data through a shared mapping: mmap_write_race in $racebad of 3 cases, the #14548 program in $ccbad of $RUNS runs"
	exit 1
fi
result "RESULT OK: records written with write() read back as written through a shared mapping: mmap_write_race in 3 of 3 cases ($SECS s each), the #14548 program in $RUNS of $RUNS runs"
