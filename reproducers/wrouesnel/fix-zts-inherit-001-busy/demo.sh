#!/bin/bash
# demo.sh -- wrouesnel/fix-zts-inherit-001-busy (bug #249): on FreeBSD,
# `zfs unmount` fails with "pool or dataset is busy" when it collides with
# an update of the same mount (nmount(MNT_UPDATE)).  mountd(8) makes such
# updates whenever libzfs signals it to reload the exports, which libzfs does
# right before it unmounts an NFS-shared dataset; that is the
# inheritance/inherit_001_pos failure on the FreeBSD CI runners:
#   cannot unmount '/TESTPOOL/TESTCTR': pool or dataset is busy
#   ERROR: zfs set canmount=off TESTPOOL/TESTCTR exited 255
# FreeBSD's dounmount() returns EBUSY while MNT_UPDATE is set.
#
# This demo does what the branch's test (cli_root/zfs_unmount/
# zfs_unmount_remount_busy) does, with the state shown at every step:
#   1. a pool on the run disk and a file system demo249/fs1;
#   2. a background loop of `mount -u -o noatime|atime` on it, as mountd's
#      export updates do (much more often, so the race shows in seconds);
#   3. N (default 1000) `zfs unmount` / `zfs mount` cycles meanwhile,
#      counting every unmount that fails;
#   4. the updates stopped, a process holding the file system busy:
#      `zfs unmount` must still refuse with "busy" (not hang, not force),
#      and succeed once the process is gone.
#   bug   (the test commit; libzfs as on master): some unmounts fail with
#         "pool or dataset is busy"            -> RESULT BUG
#   fixed (libzfs retries unmount(2) on EBUSY for up to ~1.3 s): every
#         unmount succeeds, a really busy file system still refuses
#                                              -> RESULT OK
# Run as root: /demo/demo.sh   (a minute or two).  The pool is left exported
# on the run disk.
set -u
P=demo249 FS=demo249/fs1 MNT=/demo249/fs1
N=${N:-1000}
FLAG=/tmp/demo249.storm
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
el() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

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

# 2. mount updates in the background (what mountd does on an export reload)
say "while :; do mount -u -o noatime $MNT; mount -u -o atime $MNT; done &    (background mount updates)"
: >$FLAG
(
	while [ -e $FLAG ]; do
		mount -u -o noatime $MNT
		mount -u -o atime $MNT
	done >/dev/null 2>&1
) &
storm=$!
sleep 1

# 3. unmount/mount cycles while the updates run
say "$N x { zfs unmount $FS; zfs mount $FS }    (while the mount updates run)"
fails=0 first=() t0=$(now)
for ((i = 1; i <= N; i++)); do
	if ! out=$(zfs unmount $FS 2>&1); then
		fails=$((fails + 1))
		[ ${#first[@]} -lt 3 ] && first+=("cycle $i: $out")
		[ $fails -le 3 ] && echo "  cycle $i: zfs unmount $FS FAILED: $out"
		# (still mounted: the next cycle unmounts it again)
	else
		if zfs get -H -o value mounted $FS | grep -q yes; then
			echo "  cycle $i: $FS still mounted after a successful zfs unmount"
			fails=$((fails + 1))
		fi
		zfs mount $FS || { echo "  cycle $i: zfs mount $FS failed"; }
	fi
	[ $((i % 100)) = 0 ] && echo "  $i cycles: $fails unmount(s) failed so far ($(el "$t0" "$(now)") s)"
done
echo "  ==> $N cycles in $(el "$t0" "$(now)") s: $fails unmount(s) failed with the mount being updated"

say "stop the background mount updates"
rm -f $FLAG
wait $storm
zfs get -H -o value mounted $FS | grep -q yes || zfs mount $FS
show

# 4. a file system that is really in use must still refuse
say "(cd $MNT && sleep 300) &    (hold $FS busy)"
(cd $MNT && exec sleep 300) &
holder=$!
sleep 1
say zfs unmount $FS
t1=$(now)
busy_out=$(zfs unmount $FS 2>&1); busy_rc=$?
t2=$(now)
echo "  exit $busy_rc after $(el "$t1" "$t2") s: ${busy_out:-(no output)}"
busy_ok=0
if [ $busy_rc != 0 ] && [[ $busy_out == *busy* ]] && zfs get -H -o value mounted $FS | grep -q yes; then
	busy_ok=1
	echo "  ==> refused with \"busy\", still mounted (as it must be)"
else
	echo "  ==> WRONG: an in-use file system must refuse to unmount with \"busy\" and stay mounted"
fi
show
say "kill \$holder    (release $FS)"
kill $holder; wait $holder 2>/dev/null
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

echo
if [ $fails -gt 0 ]; then
	echo "# the first failures:"
	printf '    %s\n' "${first[@]}"
	echo "RESULT BUG: zfs unmount failed $fails of $N times with \"pool or dataset is busy\" while the mount was being updated"
	exit 1
fi
if [ $busy_ok = 0 ] || [ $rel_ok = 0 ]; then
	echo "RESULT ERROR: all $N unmounts succeeded, but the busy file system check went wrong (see above)"
	exit 2
fi
echo "RESULT OK: all $N zfs unmounts succeeded while the mount was being updated; an in-use file system still refused (\"busy\") and unmounted once released"
exit 0
