#!/bin/bash
# demo.sh -- openzfs/zfs#20008: `zpool destroy` of a pool imported with
# -o readonly=on exits 0, but a read-only pool never writes its labels
# (spa_export_common() marks them destroyed only when spa_sync_on is set),
# so they keep the state they had at import.  `zpool import` then still
# lists the "destroyed" pool as an ordinary exported pool, `zpool import -D`
# does not list it, and it imports by name without -D or -f.
# The PR refuses the destroy: exit 1, "pool is imported read-only"; the
# pool stays imported and mounted.  Exported and imported read-write, it is
# destroyed normally and only `zpool import -D` lists it.
#
# Steps (pool tank on a 256 MiB file in /var/tmp/zdr):
#   1. zpool create tank, zfs create tank/fs with a file, zpool export
#   2. zpool import -o readonly=on tank; zpool destroy tank (exit status)
#   3. zpool list, mounts, zpool import, zpool import -D, zdb -l state
#   4. master: the pool is gone, so import it by name, without -D
#      PR: the pool is still imported, so export it, and import it
#      read-write
#   5. zpool destroy tank (read-write); zpool import, zpool import -D,
#      zdb -l state: DESTROYED, only -D lists it
#
#   master -> "RESULT BUG: zpool destroy of the read-only pool exited 0, ..."
#   PR     -> "RESULT OK: zpool destroy refused the read-only pool, ..."
# Run as root:  /demo/demo.sh       about 15 seconds.
set -u
P=tank D=/var/tmp/zdr M=/var/tmp/zdr-mnt
V=$D/disk

run() { echo "\$ $*"; "$@" 2>&1 | sed 's/^/  /'; local rc=${PIPESTATUS[0]}; echo "  (exit status $rc)"; return $rc; }
result() {	# the RESULT line, also through the kernel's console
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}
st() {
	echo "--- zpool status -v $P   ($1)"
	zpool status -v $P 2>&1 | sed '/^$/d; s/^/    /'
}
lst() {	# zpool list and mounts
	local l
	echo "--- zpool list -H -o name,health,readonly $P; grep $P /proc/mounts"
	if l=$(zpool list -H -o name,health,readonly $P 2>&1); then
		echo "    imported: $l"
	else
		echo "    not imported ($l)"
	fi
	if grep -q "^$P[ /]" /proc/mounts; then
		grep "^$P[ /]" /proc/mounts | sed 's/^/    mounted: /'
	else
		echo "    no $P file system mounted"
	fi
}
listed() {	# [-D]: does zpool import [-D] list the pool?
	zpool import "$@" -d $D 2>/dev/null | grep -q "pool: $P\$"
}
scan() {	# what zpool import and zpool import -D see
	echo "\$ zpool import -d $D"
	zpool import -d $D 2>&1 | sed '/^$/d; s/^/    /'
	echo "\$ zpool import -D -d $D"
	zpool import -D -d $D 2>&1 | sed '/^$/d; s/^/    /'
}
lstate() {	# the pool state in the device's labels (zdb -l)
	local s
	s=$(zdb -l $V 2>/dev/null | awk '$1 == "state:" { print $2; exit }')
	case $s in
	0) echo ACTIVE ;; 1) echo EXPORTED ;; 2) echo DESTROYED ;;
	'') echo NONE ;; *) echo "state $s" ;;
	esac
}
zdbl() {
	echo "\$ zdb -l $V | grep -E 'name:|state:|txg:' (labels 0-3)"
	zdb -l $V 2>&1 | grep -E "^ *(name|state|txg):|^LABEL" | sed 's/^/    /'
	echo "    => labels say: $(lstate)"
}

echo "# $(uname -sr); build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# $(zpool version 2>/dev/null | head -1)"
mkdir -p $D $M /etc/zfs
zpool destroy -f $P 2>/dev/null
rm -f $V

echo; echo "## 1. a pool with a file system, exported"
truncate -s 256M $V
run zpool create -f -O mountpoint=none $P $V || { result "RESULT ERROR: zpool create failed"; exit 1; }
run zfs create -o mountpoint=$M $P/fs
echo "important data" > $M/file
run zpool export $P
zdbl

echo; echo "## 2. import it read-only, then zpool destroy"
run zpool import -d $D -o readonly=on $P
run zpool get -H -o name,property,value readonly $P
st "imported read-only"
run zpool destroy $P; RC_RO=$?
echo "  => zpool destroy of the read-only pool: exit status $RC_RO"

echo; echo "## 3. after the destroy: is the pool still imported, and what does the scan see?"
lst
if zpool list $P >/dev/null 2>&1; then STILL=yes; else STILL=no; fi
if grep -q "^$P/fs " /proc/mounts; then MNT=yes; else MNT=no; fi
[ $STILL = yes ] && zpool export $P >/dev/null 2>&1 && EXPORTED_FOR_SCAN=yes || EXPORTED_FOR_SCAN=no
[ $EXPORTED_FOR_SCAN = yes ] && echo "# (exported it, to show what the scan sees)"
scan
listed && L1=yes || L1=no
listed -D && D1=yes || D1=no
zdbl
S1=$(lstate)
echo "  => zpool import lists it: $L1; zpool import -D lists it: $D1; labels: $S1"

echo; echo "## 4. import it again"
BYNAME=n/a
if [ $STILL = no ]; then
	echo "# the destroy said it succeeded; import the 'destroyed' pool by name, without -D or -f:"
	if run zpool import -d $D $P; then BYNAME=yes; else BYNAME=no; fi
	lst
	[ -f $M/file ] && echo "    $M/file: $(cat $M/file)"
else
	echo "# the pool was refused and kept; import it read-write:"
	run zpool import -d $D $P
fi
st "imported read-write"
run zpool get -H -o name,property,value readonly $P

echo; echo "## 5. zpool destroy of the read-write pool"
run zpool destroy $P; RC_RW=$?
lst
scan
listed && L2=yes || L2=no
listed -D && D2=yes || D2=no
zdbl
S2=$(lstate)
echo "  => exit status $RC_RW; zpool import lists it: $L2; zpool import -D lists it: $D2; labels: $S2"

echo
echo "## summary"
echo "  read-only destroy:  exit $RC_RO; still imported: $STILL; still mounted: $MNT"
echo "  after it:           zpool import lists it: $L1; -D lists it: $D1; labels: $S1"
echo "  imported by name without -D after the 'destroy': $BYNAME"
echo "  read-write destroy: exit $RC_RW; zpool import lists it: $L2; -D lists it: $D2; labels: $S2"

if [ $RC_RW -ne 0 ] || [ $L2 != no ] || [ $D2 != yes ]; then
	result "RESULT ERROR: the read-write destroy did not leave a destroyed pool (exit $RC_RW, import $L2, -D $D2, labels $S2)"
elif [ $RC_RO -eq 0 ] && [ $STILL = no ] && [ $L1 = yes ] && [ $D1 = no ]; then
	result "RESULT BUG: zpool destroy of the read-only pool exited 0, but its labels still say $S1: zpool import lists it as not destroyed, -D does not, and it imported by name without -D ($BYNAME)"
elif [ $RC_RO -ne 0 ] && [ $STILL = yes ] && [ $MNT = yes ] && [ $L1 = yes ] && [ $D1 = no ]; then
	result "RESULT OK: zpool destroy refused the read-only pool (exit $RC_RO), which stayed imported and mounted; exported and imported read-write it was destroyed, and only zpool import -D lists it"
else
	result "RESULT ERROR: unexpected state (read-only destroy exit $RC_RO, imported $STILL, mounted $MNT, import $L1, -D $D1, labels $S1)"
fi
rm -f $V
