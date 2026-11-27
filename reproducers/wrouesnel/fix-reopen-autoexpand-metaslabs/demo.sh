#!/bin/bash
# demo.sh -- wrouesnel/fix-reopen-autoexpand-metaslabs (openzfs/zfs#12501).
# A pool with a normal mirror and a special mirror on 512 MiB file vdevs.
# The special mirror's files grow to 1 GiB; `zpool reopen` with autoexpand
# off shows the space in EXPANDSZ.  Then autoexpand=on and another reopen:
#   master: mirror-1's SIZE stays at the old size and EXPANDSZ drops to 0
#           (the space is neither usable nor reported as expandable)
#   fix:    mirror-1's SIZE grows to the new size and EXPANDSZ is 0
# An export and import follows, to show the size the pool really has.
set -u
. /etc/demo-env 2>/dev/null
P=expreopen D=/var/tmp/expreopen T=mirror-1
x() { echo "# $*"; "$@"; }
die() { echo "RESULT ERROR: $*"; exit 2; }
prop() { zpool list -Hpv -o name,$1 $P | awk -v t=$T '$1 == t { print ($2 == "-" ? 0 : $2) }'; }
show() { echo "# zpool list -v $P"; zpool list -v -o name,size,alloc,free,expandsz,health $P; }

echo "=== reopen with autoexpand=on ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build), kernel $(uname -r))"
zpool destroy $P 2>/dev/null
mkdir -p $D; rm -f $D/n1 $D/n2 $D/s1 $D/s2
for f in n1 n2 s1 s2; do truncate -s 512M $D/$f; done
x zpool create -f -o cachefile=none -o autoexpand=off $P mirror $D/n1 $D/n2 special mirror $D/s1 $D/s2 ||
    die "zpool create failed"
size0=$(prop size)
show

echo; echo "## grow the special mirror's files to 1 GiB, reopen (autoexpand=off)"
x truncate -s 1G $D/s1 $D/s2
x zpool reopen $P
show
esize0=$(prop expandsize)
[ "$esize0" -gt 0 ] || die "EXPANDSZ is 0 after growing the members with autoexpand=off"

echo; echo "## autoexpand=on, reopen again"
x zpool set autoexpand=on $P
x zpool reopen $P
x zpool sync $P
for i in $(seq 20); do [ "$(prop size)" -gt "$size0" ] && break; sleep 0.5; done
size1=$(prop size) esize1=$(prop expandsize)
show

echo; echo "## export and import"
x zpool export $P && x zpool import -d $D $P || die "export/import failed"
size2=$(prop size)
echo "# zpool status -v $P"; zpool status -v $P
show
x zpool export $P
echo
if [ "$size1" -le "$size0" ] && [ "$esize1" = 0 ]; then
	echo "RESULT BUG: after zpool reopen with autoexpand=on, $T SIZE is stuck at $size1 bytes (was $size0) and EXPANDSZ reads 0 (was $esize0) (export/import, which reloads the vdevs, gives $size2)"
	exit 1
elif [ "$size1" -gt "$size0" ] && [ "$esize1" = 0 ] && [ "$size2" = "$size1" ]; then
	echo "RESULT OK: after zpool reopen with autoexpand=on, $T grew from $size0 to $size1 bytes, EXPANDSZ 0, same size after export/import"
else
	echo "RESULT ERROR: size $size0 -> $size1 (EXPANDSZ $esize1), after import $size2"; exit 2
fi
