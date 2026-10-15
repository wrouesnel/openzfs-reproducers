#!/bin/bash
# demo.sh -- bug #62 / openzfs #19215: an automounted .zfs/snapshot mount
# never expires while something stats or statfses it.  df(1), monitoring
# agents and desktop free-space checks do that to every mounted filesystem
# every so often, so a snapshot that was looked at once stays mounted for good.
#
# zfs_expire_snapshot is set to 30 s.  The snapshot is automounted twice:
#   1. control: nothing touches it; it must expire after about 30 s
#      (reading /proc/mounts to check doesn't count as use);
#   2. `df` (all filesystems) and `stat` of the snapshot's mountpoint every
#      5 s for 90 s (3 expiry periods).  Neither automounts an expired
#      snapshot again (df only lists what is mounted, stat doesn't trigger
#      automounts), so once it has expired it stays unmounted.
# Then reading a file in the snapshot must automount it again (expiry only
# takes the mount out of view).
#
# Builds (vm/mkdemo.sh 62 b-fedora44 ...):
#   bug  test commit 17919a929 (master 465d86a78 + the ZTS test):
#        -> "RESULT BUG: df+stat every 5 s kept the snapshot mounted for 90 s ..."
#   fix  fix-snapdir-expire-stat-v2 6fde83e8f:
#        -> "RESULT OK: the snapshot expired after N s of df+stat polling ..."
# Run as root:  /demo/demo.sh       about 2 minutes.
# Pool demo62 on the run disk $DEMO_DISK (vm/demo-vm.sh), or on the file
# /var/tmp/demo62/vdev when DEMO_DISK is unset.  Exported at the end.
set -u
P=demo62 D=/var/tmp/demo62
V=${DEMO_DISK:-$D/vdev}
EXP=30 POLL=5 WATCH=90 QUIET_MAX=75
FS=/$P/fs MP=/$P/fs/.zfs/snapshot/s1
T=/sys/module/zfs/parameters/zfs_expire_snapshot
zpool destroy -f $P 2>/dev/null; mkdir -p $D
[ -n "${DEMO_DISK:-}" ] || truncate -s 256M $V
zpool create -f -m /$P $P $V || { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
zfs create -o snapdir=visible $P/fs
echo hello >$FS/file
zfs snapshot $P/fs@s1
old=$(cat $T); echo $EXP >$T
echo "# pool $P on $V; snapshot $P/fs@s1; zfs_expire_snapshot $old -> $(cat $T)"
mounted() { awk -v ds=$P/fs@s1 '$1 == ds { f = 1 } END { exit !f }' /proc/mounts; }
state() { mounted && echo "MOUNTED" || echo "not mounted"; }

echo
echo "# 1. control: automount it (ls $MP), then leave it alone"
ls $MP >/dev/null
mounted || { echo "RESULT ERROR: ls did not automount $MP"; exit 2; }
t0=$(date +%s) quiet=
while [ $(($(date +%s) - t0)) -lt $QUIET_MAX ]; do
	sleep $POLL
	el=$(($(date +%s) - t0))
	printf '  t=%3ss  (no access)       @s1 %s\n' $el "$(state)"
	mounted || { quiet=$el; break; }
done
[ -n "$quiet" ] || { echo "RESULT ERROR: the unused snapshot did not expire in $QUIET_MAX s (zfs_expire_snapshot=$EXP)"; exit 2; }
echo "  -> expired after ${quiet} s with nothing looking at it"

echo
echo "# 2. automount it again, then run 'df' and 'stat $MP' every $POLL s for $WATCH s"
ls $MP >/dev/null
mounted || { echo "RESULT ERROR: ls did not automount $MP again"; exit 2; }
t0=$(date +%s) gone=
while [ $(($(date +%s) - t0)) -lt $WATCH ]; do
	sleep $POLL
	# plain df: with a path argument it would statfs that path, which
	# automounts an expired snapshot again
	line=$(df -h 2>/dev/null | awk -v ds=$P/fs@s1 '$1 == ds { print "listed, size", $2 }')
	stat $MP >/dev/null
	el=$(($(date +%s) - t0))
	printf '  t=%3ss  df + stat          @s1 %-11s %s\n' $el "$(state)" "${line:+(df: $line)}"
	mounted || { [ -n "$gone" ] || gone=$el; }
done
mounted && still=1 || still=0

echo
echo "# 3. cat $MP/file: the next access must automount it again"
cat $MP/file >/dev/null && mounted && back=1 || back=0
echo "  @s1 $(state); file reads: $(cat $MP/file 2>&1)"

echo $old >$T
echo
zpool export $P && echo "# pool $P exported (on $V); zfs_expire_snapshot back to $old"
if [ $back = 0 ]; then
	echo "RESULT ERROR: the snapshot did not automount again after expiring"; exit 2
elif [ $still = 1 ]; then
	echo "RESULT BUG: df+stat every $POLL s kept the snapshot mounted for $WATCH s ($((WATCH / EXP))x zfs_expire_snapshot=$EXP); unwatched it expired after $quiet s"
else
	echo "RESULT OK: the snapshot expired after $gone s of df+stat polling (zfs_expire_snapshot=$EXP; unwatched: $quiet s), and automounted again on the next access"
fi
