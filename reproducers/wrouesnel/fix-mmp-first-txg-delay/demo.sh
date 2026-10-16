#!/bin/bash
# demo.sh -- bug #138: an MMP uberblock with mmp_delay 0 makes another host
# skip the multihost activity check.  spa_activity_check_required() reads
# "MMP_MAGIC and ub_mmp_delay == 0" as "multihost is off", even when the
# uberblock carries a valid MMP config (interval, fail_intervals).  A host
# syncs such an uberblock for its first txg after importing a multihost pool
# (txg_sync_start() runs before the MMP thread sets mmp_delay), and for the
# txg that turns multihost back on.  While it is the best uberblock, another
# host's `zpool import -f` skips the activity check and the claim: only the
# hostid check is left, which -f overrides, so the pool is imported twice.
#
# Steps (each on screen):
#   1. the importer: mmp_zero_delay.dat (the ZTS blockfile of
#      mmp_zero_delay_import) is a multihost pool of hostid 01234567, copied
#      while imported (labels: state ACTIVE), whose uberblocks all have a
#      valid MMP config and mmp_delay 0.  As hostid 89abcdef,
#      `ZFS_LOAD_INFO_DEBUG=1 zpool import -f` it:
#        bug: "mmp: skipping check: feature is disabled", mmp_result 3, the
#             pool another host is using imports at once;
#        fix: the activity check runs (mmp_result 0, about 35 s: tryimport
#             waits ~23 s, the claim ~10 s), and the pool imports because
#             nobody is writing to it.
#   2. the writer: a pool with multihost=off on the run disk; multihost
#      on/off twice (letting the MMP thread see each change), on again,
#      export, then count with `zdb -luuuu` the txg-sync uberblocks (mmp_seq
#      0) that have an MMP config and mmp_delay 0:
#        bug: 8 (the two multihost=on txgs of the loop x 4 labels; the
#             last on-txg came out non-zero in every run);  fix: none.
#
# Builds (vm/mkdemo.sh 138 b-almalinux9 ..., debug, EXTRA=zgenhostid):
#   bug  test commit 32c2a4762d (master 22013c3917 + ZTS mmp_on_delay,
#        mmp_zero_delay_import)  -> "RESULT BUG: ..."
#   fix  fix-mmp-first-txg-delay 2bc4f47cd1  -> "RESULT OK: ..."
# Run as root:  /demo/demo.sh       about 15 s (bug), 50 s (fix).
# Pool demo138 on the run disk $DEMO_DISK (vm/demo-vm.sh), or on the file
# /var/tmp/demo138/vdev when DEMO_DISK is unset.  It is exported at the end
# with step 1's result in /demo138/summary (inspect.sh).
set -u
P=demo138 I=mmp_zero_delay D=/var/tmp/demo138
V=${DEMO_DISK:-$D/vdev}
IMG=$(dirname "$0")/$I.dat.bz2
zpool destroy -f $P 2>/dev/null; zpool destroy -f $I 2>/dev/null
rm -rf $D; mkdir -p $D
[ -n "${DEMO_DISK:-}" ] || truncate -s 256M $V
echo 1 >/sys/module/zfs/parameters/zfs_dbgmsg_enable 2>/dev/null

sethostid() {	# sethostid HEX: /etc/hostid, which the SPL reads on each use
	if command -v zgenhostid >/dev/null; then zgenhostid -f "$1"
	else printf "$(printf %08x "0x$1" | sed 's/\(..\)\(..\)\(..\)\(..\)/\\x\4\\x\3\\x\2\\x\1/')" >/etc/hostid; fi
	echo "  this host's hostid is now $(hostid)"
}
dbgclear() { echo 0 >/proc/spl/kstat/zfs/dbgmsg; }
dbgmmp() {	# the MMP lines of the debug log, without the timestamp and file:line
	grep -E 'mmp:|activity' /proc/spl/kstat/zfs/dbgmsg | sed 's/^.*[a-z_]*\.c:[0-9]*://; s/^/  dbgmsg: /' | uniq | awk '!/claiming uberblock/ || !c++' | head -${1:-8}
}

echo "# 1. import, as another host, a multihost pool whose best uberblock has mmp_delay 0"
bzcat "$IMG" >$D/$I.dat || { echo "RESULT ERROR: no image $IMG"; exit 2; }
zdb -l $D/$I.dat | awk '$1 == "name:" || $1 == "state:" || $1 == "hostid:" || $1 == "hostname:" {
	if (!seen[$1]++) printf "  label %s %s%s\n", $1, $2, ($1 == "state:" && $2 == "0") ? " (ACTIVE: imported on that host)" : "" }'
zdb -luuuu $D/$I.dat | awk '/Uberblock\[/ && !/invalid/ { n++ }
    /mmp_delay =/ && $3 != 0 { d++ } /mmp_valid =/ && $3 == 7 { c++ }
    END { printf "  uberblocks: %d valid; %d with a full MMP config (mmp_valid 7); %d with mmp_delay != 0\n", n, c, d }'
zdb -luuuu $D/$I.dat | grep -m1 -A12 'Uberblock\[' | grep -E 'txg =|mmp_' | sed 's/^\t*/    /'
sethostid 89abcdef
dbgclear
echo "  \$ ZFS_LOAD_INFO_DEBUG=1 zpool import -f -d $D $I"
t0=$(date +%s)
out=$(ZFS_LOAD_INFO_DEBUG=1 zpool import -f -d $D $I 2>&1); rc=$?
secs=$(( $(date +%s) - t0 ))
echo "$out" | grep -E 'mmp_(result|state|hostid|hostname)|cannot' | sed 's/^[ \t]*/  /'
dbgmmp
st=$(zpool list -H -o health $I 2>/dev/null)
echo "  -> exit $rc after $secs s; pool $I: ${st:-not imported}"
case $out in
*"mmp_result: 3"*) imp=skipped ;;
*"mmp_result: 0"*) imp=checked ;;
*) imp=other ;;
esac
if [ $imp = skipped ]; then
	echo "  ** NO activity check: mmp_delay 0 was read as 'multihost off', so -f imported a pool"
	echo "  ** whose labels say it is ACTIVE on hostid 01234567"
elif [ $imp = checked ]; then
	echo "  ** the activity check ran ($secs s) and saw no MMP writes, so the import went ahead"
fi
zpool export $I 2>/dev/null; rm -f $D/$I.dat

echo
echo "# 2. multihost off -> on, as the MMP thread sees it: is that txg's uberblock delay 0?"
zpool create -f -m /$P -o cachefile=none -O compression=off -o multihost=off $P $V ||
    { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
zpool sync $P
for i in 1 2; do
	echo "  multihost=on, sync, wait 3 s; multihost=off, sync, wait 3 s   ($i/2)"
	zpool set multihost=on $P; zpool sync $P; sleep 3
	zpool set multihost=off $P; zpool sync $P; sleep 3
done
echo "  multihost=on, sync"
zpool set multihost=on $P; zpool sync $P
{ echo "import=$imp secs=$secs rc=$rc health=${st:-none}"; } >/$P/summary
zpool sync $P
zpool export $P && echo "  pool $P exported (on $V), with step 1's result in /$P/summary"
echo "  \$ zdb -luuuu $V   (txg-sync uberblocks, mmp_seq 0, with an MMP config)"
cnt=$(zdb -luuuu $V | awk '
    /Uberblock\[/ { delay = -1; seq = -1 } $1 == "txg" { txg = $3 }
    /mmp_delay =/ { delay = $3 } /mmp_seq =/ { seq = $3 }
    /mmp_valid =/ { if ($3 != "0" && seq == 0) { valid++; if (delay == 0) { zero++; z[txg]++ } } }
    END { s = ""; for (t in z) s = s " " t; print valid + 0, zero + 0, s }')
set -- $cnt; valid=$1 zero=$2; shift 2; txgs="$*"
echo "  -> $valid with an MMP config, $zero of them with mmp_delay 0${txgs:+ (txgs $txgs, x 4 labels)}"
[ "$zero" -gt 0 ] && echo "  ** multihost=on txgs wrote MMP uberblocks that importers read as 'multihost off'"

echo
w=bad; [ "$valid" -gt 0 ] && { [ "$zero" -gt 0 ] && w=zero || w=ok; }
if [ $imp = skipped ] && [ $w = zero ]; then
	echo "RESULT BUG: zpool import -f of a pool ACTIVE on another host skipped the MMP activity check (mmp_result 3, imported in $secs s); multihost=on wrote $zero uberblocks with mmp_delay 0"
elif [ $imp = checked ] && [ $w = ok ]; then
	echo "RESULT OK: the MMP activity check ran before importing the ACTIVE pool (mmp_result 0, $secs s); multihost=on wrote no uberblock with mmp_delay 0 ($valid with an MMP config)"
else
	echo "RESULT ERROR: mixed result: import $imp (rc $rc, $secs s), delay-0 uberblocks $zero of $valid"; exit 2
fi
