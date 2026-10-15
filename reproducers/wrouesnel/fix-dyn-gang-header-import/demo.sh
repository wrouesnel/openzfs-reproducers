#!/bin/bash
# demo.sh -- bug #40 (openzfs #19189, PR #19314) in the FreeBSD reporter's
# shape: one ashift=12 vdev, compression=lz4, 1500 snapshots, and the MOS
# meta-dnode's level-1 indirect block (objset 0, object 0, level 1, blkid 0)
# written as a gang block with a 4 KB (dynamic) gang header.  The import reads
# that block before the feature refcounts are loaded, so on master it is read
# with a 512-byte header, fails its checksum, and the pool cannot be imported:
#   ereport.fs.zfs.data  zio_err = 0x61 (EINTEGRITY)
#   zio_objset = 0x0 zio_object = 0x0 zio_level = 0x1 zio_blkid = 0x0
#   "couldn't get 'config' value in MOS directory [error=5]"
# exactly as the reporter's 15.1-p3 system showed.
#
# The pool layout is common code, so it reproduces on Linux as well (the
# tunables are module parameters there).  Run as root: /demo/demo.sh
# (about a minute).  Builds:
#   repro: master 4542a317e + the test commit cf9719c6e -> "RESULT BUG"
#   fixed: PR #19314 head d60260002                      -> "RESULT OK"
# Pool demo40 on the run disk $DEMO_DISK (vm/demo-vm.sh), or on a file in
# /var/tmp/demo40.  It is left exported, so `IMAGE --disk
# RUNDISK` can try the import again (/demo/inspect.sh).
set -u
P=demo40 D=/var/tmp/demo40
V=${DEMO_DISK:-$D/vdev}
if [ "$(uname)" = FreeBSD ]; then
	tun() { sysctl -q vfs.zfs.metaslab.$1=$2 >/dev/null; }
	modver() { sysctl -n vfs.zfs.version.module; }
	dbgmsg() { sysctl -n kstat.zfs.misc.dbgmsg; }
	TUN='sysctl vfs.zfs.metaslab.force_ganging=4097 force_ganging_pct=100' DBG='sysctl kstat.zfs.misc.dbgmsg'
else
	tun() { echo "$2" >/sys/module/zfs/parameters/metaslab_$1; }
	modver() { cat /sys/module/zfs/version; }
	dbgmsg() { cat /proc/spl/kstat/zfs/dbgmsg; }
	echo 1 >/sys/module/zfs/parameters/zfs_dbgmsg_enable
	TUN='echo 4097 >/sys/module/zfs/parameters/metaslab_force_ganging; echo 100 >.../metaslab_force_ganging_pct' DBG='cat /proc/spl/kstat/zfs/dbgmsg'
fi

echo "# $(uname -sr); module $(modver)"
zpool destroy -f $P 2>/dev/null
mkdir -p $D
if [ -n "${DEMO_DISK:-}" ]; then dir=/dev; else truncate -s 2g $V; dir=$D; fi
zpool create -f -o ashift=12 -O compression=lz4 $P $V ||
    { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
echo "# pool $P on $V (ashift=12, compression=lz4)"

echo "\$ 50 filesystems, then 30 x zfs snapshot -r $P@sN   (grows the MOS)"
for i in $(seq 1 50); do zfs create $P/fs$i; done
for s in $(seq 1 30); do zfs snapshot -r $P@s$s; done
echo "  snapshots: $(zfs list -H -t snapshot -o name -r $P | wc -l | tr -d ' ')"

echo "\$ $TUN"
tun force_ganging 4097; tun force_ganging_pct 100
dd if=/dev/urandom of=/$P/fs1/file bs=128k count=8 2>/dev/null
zpool sync $P
echo "  feature@dynamic_gang_header: $(zpool get -H -o value feature@dynamic_gang_header $P)"
zfs snapshot -r $P@last; zfs destroy -r $P@s1; zpool sync $P
echo "\$ zpool export $P"
zpool export $P || { echo "RESULT ERROR: export failed"; exit 2; }
tun force_ganging 16777217; tun force_ganging_pct 3

echo "\$ zdb -e -p $dir -dddddd $P 0 | grep ' L1 '    (G = gang DVA)"
zdb -e -p $dir -dddddd $P 0 2>&1 | grep -E '^ +0 +L1 |^zdb:' | head -2 | sed 's/^ */  /'

sync
zpool events -c >/dev/null 2>&1
echo "\$ zpool import -d $dir $P"
if zpool import -d $dir $P; then
	zpool scrub -w $P
	zpool status $P | grep -E 'scan:|errors:' | sed 's/^ */  /'
	zpool export $P && echo "# pool $P exported (on $V)"
	echo "RESULT OK: the pool imports"
	exit 0
fi
echo "\$ zpool events -v    (the first ereport.fs.zfs.data)"
zpool events -v | awk 'BEGIN { RS = "" } /ereport\.fs\.zfs\.data/ { print; exit }' |
    grep -E 'class|zio_err|zio_flags|zio_objset|zio_object|zio_level|zio_blkid' | sed 's/^ */  /'
echo "\$ $DBG | grep FAILED"
dbgmsg | grep -E "spa_load\($P.*FAILED" | head -1 | sed "s/^[0-9]* *//; s/^/  /"
echo "RESULT BUG: the pool cannot be imported (MOS meta-dnode L1 gang block read with a 512-byte header)"
exit 1
