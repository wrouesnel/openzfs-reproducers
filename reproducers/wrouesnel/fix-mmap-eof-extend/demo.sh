#!/bin/bash
# demo.sh -- openzfs/zfs#19267 (issue #19220): bytes stored through a shared
# mmap past the end of a file, in its last page, become file data when the
# file is extended.  POSIX says they must never be written out; ext4, xfs and
# btrfs read zeros there.
#
# For each way of extending a file a small C helper (eof.c, prebuilt at
# /demo/eof) writes a file that ends 10 bytes into its last page, stores
# "STALE-DATA" at bytes 10-19 of that page through a MAP_SHARED mapping, and
# extends the file:
#   truncate   ftruncate() to 1034 bytes
#   write      pwrite() of one byte at 1033
#   fallocate  fallocate() to 1034 bytes (Linux only: ZFS on FreeBSD has no
#              posix_fallocate())
#   copy       copy_file_range() of a 4 KiB block to offset 8192 of a
#              4106-byte file (a block clone: block cloning is enabled)
# The bytes past the old end of file are then read back, and read again from
# disk after a remount.
#
# Builds (reproducer.conf):
#   repro: the PR's test commit, without the fix
#     -> each line shows "53 54 41 4c 45 2d 44 41 54 41  STALE-DATA",
#        both after extending and after the remount,  "RESULT BUG"
#   fixed: the PR's fix commit
#     -> every line shows "00 00 00 00 00 00 00 00 00 00", "RESULT OK"
# Pool demo27 on the run disk $DEMO_DISK, or on the file /var/tmp/demo27/vdev
# when DEMO_DISK is unset.  It is exported at the end, not destroyed, so the
# run disk can be re-read later (--disk RUNDISK runs /demo/inspect.sh).
set -u
D=/var/tmp/demo27; P=demo27
V=${DEMO_DISK:-$D/vdev}
zpool destroy -f $P 2>/dev/null; rm -rf $D; mkdir -p $D

EOF_BIN=${EOF_BIN:-/demo/eof}
[ -x "$EOF_BIN" ] || { echo "no helper $EOF_BIN" >&2; exit 2; }

if [ "$(uname -s)" = FreeBSD ]; then
	MODES="truncate write copy"
	sysctl -q vfs.zfs.bclone_enabled=1 >/dev/null
else
	MODES="truncate write fallocate copy"
	echo 1 > /sys/module/zfs/parameters/zfs_bclone_enabled
fi

[ -n "${DEMO_DISK:-}" ] || truncate -s 256M $V
zpool create -f -o cachefile=none -O recordsize=4k $P $V && [ -d /$P ] ||
    { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
echo "pool $P on $V ($(zpool list -H -v -P $P | awk 'NR == 2 { print $1 }'))"
# bytes FILE: bytes 10-19 of the file's last page before it was extended
bytes() {
	local off=10; case $1 in */copy) off=4106 ;; esac
	dd if=$1 bs=1 skip=$off count=10 2>/dev/null | od -An -c -tx1 |
	    awk 'NR == 2 { x = $0; gsub(/ +/, " ", x) } NR == 1 { gsub(/ +/, ""); c = $0 } END { print x "  " c }'
}
check() {
	case $1 in *STALE*) [ $bad = 2 ] || bad=1 ;; *" 00 00 00 00 00 00 00 00 00 00 "*) ;; *) bad=2 ;; esac
}
bad=0
echo "bytes 10-19 of each file's last page, past the old end of file (should be zeros):"
for m in $MODES; do
	[ $m = copy ] && { dd if=/dev/urandom of=/$P/$m.src bs=4k count=1 2>/dev/null; zpool sync $P; }
	$EOF_BIN $m /$P/$m
	b=$(bytes /$P/$m); echo "  after $m:	$b"; check "$b"
done
zfs unmount $P; zfs mount $P
echo "after a remount (read from disk):"
for m in $MODES; do
	b=$(bytes /$P/$m); echo "  $m:	$b"; check "$b"
done
zpool export $P && echo "pool $P exported (on $V)"
if [ $bad = 2 ]; then
	echo "RESULT ERROR: a file could not be read (see above)"; exit 2
elif [ $bad = 1 ]; then
	echo "RESULT BUG: data stored past EOF through mmap became file data"
else
	echo "RESULT OK: the extended range reads as zeros"
fi
