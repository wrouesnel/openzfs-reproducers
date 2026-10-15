#!/bin/bash
# demo.sh -- bug #71 (test-only): ZTS fault/auto_replace_001_pos and _002_pos
# fail on every Linux CI run (hidden by zts-report's "maybe" list) before
# they test anything: since f330b463d their fill_fs writes 800 MiB of random
# data (4 dirs x 100 files x 512 writes of 4 KiB) into a raidz1 whose
# smallest device is the 256 MiB scsi_debug disk, and fill_fs fails with
# ENOSPC.  The fix (f1e3f9e3f) writes 100 MiB (64 writes per file).
#
# What this image can show: the failing step.  The rest of those tests
# (removing the scsi_debug disk and checking that ZED's autoreplace takes a
# new disk in its slot) needs the scsi_debug module, udev and vdev_id, which
# the demo image doesn't have.  So the demo builds the same raidz1 shape
# (4 x 256 MiB run disks, as the 256 MiB scsi_debug disk caps every raidz
# child) and runs fill_fs with the arguments from the booted build's own
# auto_replace_001_pos.ksh (/demo/zts/LABEL/, from `git show REF:...`).
# fill_fs is ZTS's function (libtest.shlib), with ZTS's file_write helper.
# Run as root:  /demo/demo.sh      about 10-40 seconds.
# What you will see:
#   bug build (4542a317e, the branch's parent = master's test):
#     "fill_fs /p71/fs 4 100 4096 512 R" -> file_write fails, ENOSPC
#     ("No space left on device"), "RESULT BUG"
#   fix build (f1e3f9e3f): "fill_fs /p71/fs 4 100 4096 64 R" -> 100 MiB
#     written, "RESULT OK"
# Pool p71 (raidz1 of the 4 run disks $DEMO_DISKS, or files in /var/tmp/p71d);
# exported at the end.
set -u
. /etc/demo-env 2>/dev/null
build=${DEMO_BUILD:-${1:-repro}}
T=/demo/zts/$build/auto_replace_001_pos.ksh
[ -f "$T" ] || { echo "RESULT ERROR: no test for build '$build' ($T)"; exit 2; }
pool=p71 TESTFILE=testfile
read -r -a V <<< "${DEMO_DISKS:-}"
if [ ${#V[@]} -lt 4 ]; then
	d=/var/tmp/p71d; rm -rf $d; mkdir -p $d
	V=(); for i in 0 1 2 3; do truncate -s 256M $d/v$i; V+=($d/v$i); done
fi
# ZTS's fill_fs (tests/zfs-tests/include/libtest.shlib), in bash
fill_fs() {	# destdir dirnum filenum bytes num_writes data
	local destdir=$1 dirnum=$2 filenum=$3 bytes=$4 num_writes=$5 data=$6 i j
	for i in $(seq $dirnum); do mkdir -p $destdir/$i; done
	for i in $(seq $dirnum); do for j in $(seq $filenum); do
		file_write -o create -f $destdir/$i/$TESTFILE$j -b $bytes -c $num_writes -d $data || return
	done; done
}
zpool destroy -f $pool 2>/dev/null
echo "# zpool create $pool raidz1 ${V[*]}   (4 x 256 MiB)"
zpool create -f -o cachefile=none $pool raidz1 "${V[@]}" && zfs create $pool/fs ||
    { echo "RESULT ERROR: could not create pool $pool"; exit 2; }
zfs list -o name,avail $pool
line=$(grep -m1 'log_must fill_fs' $T)
echo "# from $T:"
echo "#   $line"
args=$(echo "$line" | sed 's/.*fill_fs //')
set -- ${args//\$TESTPOOL/$pool}
mb=$(( $2 * $3 * $4 * $5 / 1048576 ))
echo "# fill_fs $*   ($mb MiB of random data)"
t0=$SECONDS
fill_fs "$@"; rc=$?
echo "fill_fs exit status $rc after $((SECONDS - t0)) s"
zfs list -o name,used,avail $pool
zpool export $pool && echo "# pool $pool exported (on ${V[*]})"
echo
if [ $rc = 0 ]; then
	echo "RESULT OK: the test's $mb MiB fit in the pool"
elif [ $mb -gt 600 ]; then
	echo "RESULT BUG: the test's $mb MiB don't fit in the pool, so the test fails before it tests autoreplace"
else
	echo "RESULT ERROR: fill_fs of $mb MiB failed (see above)"; exit 2
fi
