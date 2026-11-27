#!/bin/bash
# demo.sh -- tigerblue77/libzfs-parallel-mount-props-race (openzfs/zfs#19385,
# PR #19605).
# A pool with an unencrypted root and 8 encrypted children (raw keys in a
# file) is exported and imported with `zpool import -l` under valgrind's
# helgrind.  The import loads the keys and mounts the children in parallel.
#   master: helgrind reports data races between a mount task reading a
#           handle's properties (zfs_prop_get, from zfs_mount_task) and the
#           task mounting that handle replacing them (zfs_mount_at ->
#           zfs_refresh_properties -> put_stats_zhdl: nvlist_free of
#           zfs_props).  Rarely, without valgrind, that is a crash.
#   fix:    no such race (helgrind's usual taskq_tsd pthread_once report,
#           on both builds, is not counted)
set -u
. /etc/demo-env 2>/dev/null
P=ihg D=/var/tmp/ihg KIDS=8 LOG=/var/tmp/ihg.helgrind.log
x() { echo "# $*"; "$@"; }
die() { echo "RESULT ERROR: $*"; exit 2; }
RE='put_stats_zhdl|zfs_mount_task|zfs_prop_get|zfs_refresh_properties|zfs_mount_at'

echo "=== zpool import -l under helgrind ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build), kernel $(uname -r))"
command -v valgrind >/dev/null || die "no valgrind (needs the extended base)"
zpool destroy -f $P 2>/dev/null
mkdir -p $D; rm -f $D/key $LOG
dd if=/dev/urandom of=$D/key bs=32 count=1 status=none
x zpool create -f -o cachefile=none $P $DEMO_DISK || die "zpool create failed"
echo "# zfs create -o encryption=on -o keyformat=raw -o keylocation=file://$D/key $P/k1 ... $P/k$KIDS"
for i in $(seq 1 $KIDS); do
	zfs create -o encryption=on -o keyformat=raw -o keylocation=file://$D/key $P/k$i || die "zfs create $P/k$i failed"
done
x zpool export $P || die "export failed"
echo
echo "# valgrind --tool=helgrind --max-threads=1500 --num-callers=30 --log-file=$LOG zpool import -l -d $DEMO_DISK $P"
t0=$(date +%s)
valgrind --tool=helgrind --max-threads=1500 --num-callers=30 --log-file=$LOG zpool import -l -d $DEMO_DISK $P; rc=$?
echo "  -> exit $rc after $(($(date +%s) - t0)) s"
# one helgrind report per block between "----" separator lines
awk -v re="$RE" '
	function flush() { if (blk ~ /Possible data race/) { all++; if (blk ~ re) { n++; if (!first) first = blk } } blk = "" }
	/^==[0-9]+== -+$/ { flush(); next }
	{ blk = blk $0 "\n" }
	END { flush(); printf "%d %d\n", all + 0, n + 0; printf "%s", first > "/var/tmp/ihg.first" }' $LOG >$D/counts
read -r races propraces <$D/counts
echo "  helgrind: $races data race report(s), $propraces involving the props swap / zfs_prop_get in the mount"
grep -E 'ERROR SUMMARY' $LOG | tail -1 | sed 's/^/  /'
if [ "$propraces" -gt 0 ]; then
	echo; echo "# the first of them:"
	sed 's/^==[0-9]*== /  /' /var/tmp/ihg.first | grep -vE '^\s*$' | head -45
fi
echo
x zfs list -r -o name,encryption,keystatus,mounted $P
echo "# zpool status -v $P"; zpool status -v $P
mounted=$(zfs list -H -o mounted -r $P | grep -c yes)
x zpool export $P
echo
if [ $rc != 0 ]; then
	echo "RESULT ERROR: zpool import -l under helgrind exited $rc"; exit 2
elif [ "$propraces" -gt 0 ]; then
	echo "RESULT BUG: helgrind reported $propraces data race(s) on a dataset handle's zfs_props between parallel mount tasks (zfs_prop_get vs put_stats_zhdl) in zpool import -l ($mounted of $((KIDS + 1)) mounted)"
	exit 1
elif [ "$mounted" = $((KIDS + 1)) ]; then
	echo "RESULT OK: helgrind reported no race on zfs_props in zpool import -l ($races other race report(s)); all $mounted file systems mounted"
else
	echo "RESULT ERROR: no race, but only $mounted of $((KIDS + 1)) file systems mounted"; exit 2
fi
