#!/bin/bash
# demo.sh -- wrouesnel/fix-zts-inherit-001-busy-v2 (bug #249, openzfs/zfs#19817
# v2): on FreeBSD, `zfs unmount` fails with "pool or dataset is busy" when the
# file system is busy for a moment.  mountd(8) makes it so whenever libzfs
# signals it to reload the exports, which libzfs does right before it
# unmounts an NFS-shared dataset: mountd updates the mount
# (nmount(MNT_UPDATE)) and FreeBSD's dounmount() returns EBUSY meanwhile.
# That is the inheritance/inherit_001_pos failure on the FreeBSD CI runners:
#   cannot unmount '/TESTPOOL/TESTCTR': pool or dataset is busy
#   ERROR: zfs set canmount=off TESTPOOL/TESTCTR exited 255
#
# This demo does what the branch's test (cli_root/zfs_unmount/
# zfs_unmount_remount_busy, v2) does, with the state shown at every step:
#   1. a pool on the run disk and a file system demo249/fs1;
#   2. busy for a moment, deterministically: a process holds the file system
#      (its working directory is in it) until `zfs unmount` has had EBUSY and
#      is waiting to try again (asleep in nanosleep) or has exited; then it
#      lets go.  Without a retry the unmount fails at once, every time.
#   3. N (default 50) `zfs unmount` / `zfs mount` cycles while a background
#      loop updates the mount (`mount -u -o noatime|atime`), as mountd does;
#   4. a process holding the file system for good: `zfs unmount` must still
#      refuse with "busy" (not hang, not force), and succeed once it is gone.
#   bug   (the test commit; libzfs as on master): step 2 fails with "pool or
#         dataset is busy" (and step 3 may too)  -> RESULT BUG
#   fixed (libzfs retries unmount(2) on EBUSY for up to ~1.3 s): steps 2 and
#         3 succeed, step 4 still refuses        -> RESULT OK
# Run as root: /demo/demo.sh   (a few seconds).  The pool is left exported on
# the run disk.
set -u
P=demo249 FS=demo249/fs1 MNT=/demo249/fs1
N=${N:-50}
FLAG=/tmp/demo249.storm READY=/tmp/demo249.ready OUT=/tmp/demo249.out
V=${DEMO_DISK:-}
build=${DEMO_BUILD:-}

say() { echo; echo "\$ $*"; }
show() {
	echo "  --- state ---"
	zpool status -v $P 2>&1 | sed 's/^/  /'
	zfs list -o name,mounted,canmount,mountpoint -r $P 2>&1 | sed 's/^/  /'
	echo "  # mount | grep $P"
	mount | grep " /$P" | sed 's/^/  /'
	echo "  -------------"
}
now() { echo "${EPOCHREALTIME:-$(date +%s)}"; }
el() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }
mounted() { zfs get -H -o value mounted $FS | grep -q yes; }
# a process with its working directory in the file system
hold() {
	rm -f $READY
	(cd $MNT && touch $READY && exec sleep 300) &
	holder=$!
	while [ ! -e $READY ]; do sleep 0.01; done
}
release() { kill $holder; wait $holder 2>/dev/null; }

echo "# $(uname -sr); module $(sysctl -n vfs.zfs.version.module 2>/dev/null); build ${build:-?}"
echo "# zfs: $(command -v zfs) ($(zfs version 2>/dev/null | head -1))"
zpool destroy -f $P 2>/dev/null
if [ -z "$V" ]; then mkdir -p /var/tmp/demo249; truncate -s 1g /var/tmp/demo249/vdev; V=/var/tmp/demo249/vdev; fi

# 1. the pool and the file system
say zpool create -f $P $V
zpool create -f $P "$V" || { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
say zfs create $FS
zfs create $FS || { echo "RESULT ERROR: zfs create $FS failed"; exit 2; }
show

# 2. busy until zfs unmount has had EBUSY once
say "(cd $MNT && sleep 300) &    (hold $FS busy for now)"
hold
say "zfs unmount $FS &    (release $FS once zfs unmount waits to retry, or has exited)"
t1=$(now)
zfs unmount $FS >$OUT 2>&1 &
up=$!
polls=0 wchan=
while [ $polls -lt 2000 ]; do
	wchan=$(ps -o wchan= -p $up 2>/dev/null)
	[ -z "$wchan" ] || [ "$wchan" = nanslp ] && break
	sleep 0.005
	polls=$((polls + 1))
done
if [ -z "$wchan" ]; then
	echo "  zfs unmount exited before $FS was released"
else
	echo "  zfs unmount is asleep in '$wchan' after $(el "$t1" "$(now)") s: it had EBUSY and will try again"
fi
say "kill \$holder    (release $FS)"
release
wait $up; transient_rc=$?
t2=$(now)
transient_out=$(cat $OUT)
echo "  zfs unmount: exit $transient_rc after $(el "$t1" "$t2") s: ${transient_out:-(no output)}"
transient_ok=0
if [ $transient_rc = 0 ] && ! mounted; then
	transient_ok=1
	echo "  ==> unmounted: the retry got past a file system busy for a moment"
else
	echo "  ==> FAILED: a file system busy only until the first unmount attempt did not unmount"
fi
show
mounted || zfs mount $FS

# 3. unmount/mount cycles while the mount is being updated
say "while :; do mount -u -o noatime $MNT; mount -u -o atime $MNT; done &    (background mount updates)"
: >$FLAG
(
	while [ -e $FLAG ]; do
		mount -u -o noatime $MNT
		mount -u -o atime $MNT
	done >/dev/null 2>&1
) &
storm=$!
say "$N x { zfs unmount $FS; zfs mount $FS }    (while the mount updates run)"
fails=0 first=() t0=$(now)
for ((i = 1; i <= N; i++)); do
	if ! out=$(zfs unmount $FS 2>&1); then
		fails=$((fails + 1))
		[ ${#first[@]} -lt 3 ] && first+=("cycle $i: $out")
		[ $fails -le 3 ] && echo "  cycle $i: zfs unmount $FS FAILED: $out"
		# (still mounted: the next cycle unmounts it again)
	else
		if mounted; then
			echo "  cycle $i: $FS still mounted after a successful zfs unmount"
			fails=$((fails + 1))
		fi
		zfs mount $FS || { echo "  cycle $i: zfs mount $FS failed"; }
	fi
done
echo "  ==> $N cycles in $(el "$t0" "$(now)") s: $fails unmount(s) failed with the mount being updated"
say "stop the background mount updates"
rm -f $FLAG
wait $storm
mounted || zfs mount $FS
show

# 4. a file system that stays in use must still refuse
say "(cd $MNT && sleep 300) &    (hold $FS busy for good)"
hold
say zfs unmount $FS
t1=$(now)
busy_out=$(zfs unmount $FS 2>&1); busy_rc=$?
t2=$(now)
echo "  exit $busy_rc after $(el "$t1" "$t2") s: ${busy_out:-(no output)}"
busy_ok=0
if [ $busy_rc != 0 ] && [[ $busy_out == *busy* ]] && mounted; then
	busy_ok=1
	echo "  ==> refused with \"busy\", still mounted (as it must be)"
else
	echo "  ==> WRONG: an in-use file system must refuse to unmount with \"busy\" and stay mounted"
fi
show
say "kill \$holder    (release $FS)"
release
rel_ok=1
say zfs unmount $FS
zfs unmount $FS && echo "  unmounted" || rel_ok=0
zfs get -H -o value mounted $FS | grep -q no || rel_ok=0
show
say zfs mount $FS
zfs mount $FS && echo "  mounted" || rel_ok=0
show

say zpool export $P
zpool export $P && echo "  pool $P exported (on $V)"
rm -f $OUT $READY

echo
if [ $transient_ok = 0 ] || [ $fails -gt 0 ]; then
	msg=
	[ $transient_ok = 0 ] && msg="zfs unmount of a file system busy for a moment failed: ${transient_out:-exit $transient_rc}"
	if [ $fails -gt 0 ]; then
		echo "# the first failures during the mount updates:"
		printf '    %s\n' "${first[@]}"
		msg="${msg:+$msg; }$fails of $N unmounts failed while the mount was being updated"
	fi
	echo "RESULT BUG: $msg"
	exit 1
fi
if [ $busy_ok = 0 ] || [ $rel_ok = 0 ]; then
	echo "RESULT ERROR: the unmounts succeeded, but the busy file system check went wrong (see above)"
	exit 2
fi
echo "RESULT OK: zfs unmount got past a file system busy for a moment and all $N unmounts during mount updates succeeded; an in-use file system still refused (\"busy\") and unmounted once released"
exit 0
