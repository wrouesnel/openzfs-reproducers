#!/bin/bash
# demo.sh -- wrouesnel/fix-rollback-stale-mountpoint-v2 (follow-up to
# openzfs/zfs#12460, Linux).
# POOL/par is snapshotted, then POOL/par/child is created (its mountpoint
# directory is not in the snapshot) and gets a file.  POOL/par is rolled
# back while the child is mounted; the child stays mounted and readable.
# Then the child is destroyed and created again:
#   master: /POOL/par/child still resolves to the stale inode: stat fails
#           with EIO, and the new child fails to mount ("failed to create
#           mountpoint: File exists"), until the parent is remounted
#   fix:    the stale name is gone after the destroy; the new child mounts
#           and is writable
set -u
. /etc/demo-env 2>/dev/null
P=rbmnt
x() { echo "# $*"; "$@"; }
die() { echo "RESULT ERROR: $*"; exit 2; }
mnt() { echo "# mounts:"; grep " /$P" /proc/self/mountinfo | awk '{ print "  " $5 " <- " $(NF-1) }'; }
M=/$P/par/child

echo "=== child across a parent's rollback ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build), kernel $(uname -r))"
zpool destroy $P 2>/dev/null
x zpool create -f -o cachefile=none $P $DEMO_DISK || die "zpool create failed"
x zfs create $P/par
x zfs snapshot $P/par@before
x zfs create $P/par/child
echo 1 >$M/file.1; echo "# echo 1 > $M/file.1"
echo; echo "## roll the parent back while the child is mounted"
x zfs rollback $P/par@before
mnt
x zfs get -H -o name,property,value mounted $P/par/child
echo "# cat $M/file.1: $(cat $M/file.1 2>&1)"
echo; echo "## destroy the child"
x zfs destroy -rf $P/par/child || die "zfs destroy failed (the old #12460 'unmount failed')"
mnt
echo "# stat $M:"; stat -c '  %F inode %i' $M 2>&1 | sed 's/^/  /'
staterr=$(stat $M 2>&1 >/dev/null)
echo; echo "## create the child again"
echo "# zfs create $P/par/child"
out=$(zfs create $P/par/child 2>&1); crc=$?
echo "  -> exit $crc${out:+: $out}"
mounted=$(zfs get -H -o value mounted $P/par/child 2>/dev/null)
x zfs get -H -o name,property,value mounted $P/par/child
mnt
wrc=1; echo 2 >$M/file.2 2>/dev/null && [ "$(cat /proc/self/mountinfo | grep -c " $M ")" -gt 0 ] && wrc=0
echo "# echo 2 > $M/file.2 on the child: $([ $wrc = 0 ] && echo ok || echo failed)"
echo; echo "## the parent remounted (export/import) shows what is on disk"
x zpool export $P && x zpool import -d $DEMO_DISK $P || die "export/import failed"
mnt
echo "# zpool status -v $P"; zpool status -v $P
x zfs list -r -o name,mounted,mountpoint $P
x zpool export $P
echo
if [ "$mounted" != yes ] || [ $wrc != 0 ]; then
	echo "RESULT BUG: after the rollback and destroy, $M is a stale name (stat: ${staterr:-ok}) and the new child did not mount: ${out:-mounted=$mounted}"
	exit 1
elif ! echo "$staterr" | grep -q "I/O error"; then
	echo "RESULT OK: after the rollback and destroy, the old name is gone (${staterr:-stat ok}), and the new child mounted and is writable"
else
	echo "RESULT ERROR: new child mounted, but stat of the old name gave '$staterr'"; exit 2
fi
