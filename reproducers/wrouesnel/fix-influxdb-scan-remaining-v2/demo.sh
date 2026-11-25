#!/bin/bash
# demo.sh -- wrouesnel/fix-influxdb-scan-remaining-v2 (openzfs #16771).
# zpool_influxdb's remaining_t for a running scrub, against what `zpool
# status` prints as "to go".  zinject delays every I/O to the disk, so the
# scrub runs for about a minute; once zpool status gives an estimate, both
# are sampled five times.
set -u
. /etc/demo-env 2>/dev/null
P=influxscan
MIB=1200
x() { echo "# $*"; "$@"; }
die() { echo "RESULT ERROR: $*"; zinject -c all >/dev/null 2>&1; exit 2; }
field() { grep -o ",$1=[0-9]*" <<<"$LINE" | cut -d= -f2; }

echo "=== zpool_influxdb's remaining scan time ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build))"
zpool destroy $P 2>/dev/null
x zpool create -f -o cachefile=none -O recordsize=1M -O compression=off $P $DEMO_DISK || die "zpool create failed"
echo "# write $MIB MiB of random data to /$P/file"
dd if=/dev/urandom of=/$P/file bs=1M count=$MIB status=none || die "the write failed"
x zpool sync $P
x zinject -d $DEMO_DISK -D 40:1 $P || die "zinject failed"
x zpool scrub $P || die "zpool scrub failed"

n=0 bad=0 first= lastgood=
for ((i = 0; i < 90 && n < 5; i++)); do
	sleep 1
	st=$(zpool status $P)
	LINE=$(zpool_influxdb --no-histograms $P | grep '^zpool_scan_stats,')
	grep -q 'state=scanning ' <<<"$LINE" || break
	go=$(grep -o '[0-9:]* to go' <<<"$st" | cut -d' ' -f1)
	[ -n "$go" ] || continue
	IFS=: read -r h m s <<<"$go"
	want=$((10#$h * 3600 + 10#$m * 60 + 10#$s))
	[ $want -ge 8 ] || continue
	got=$(field remaining_t)
	[ -n "$got" ] || die "no remaining_t in: $LINE"
	d=$((got > want ? got - want : want - got))
	ok=yes; [ $d -le $((want / 4 + 2)) ] || { ok=NO; bad=$((bad + 1)); [ -n "$first" ] || first="remaining_t=$got while zpool status says $go to go"; }
	n=$((n + 1))
	lastgood="remaining_t=$got, zpool status $go"
	echo
	echo "--- sample $n: zpool status"
	grep -A2 'scan:' <<<"$st"
	echo "--- sample $n: zpool_influxdb (to_examine=$(field to_examine) examined=$(field examined) issued=$(field issued) pass_examined=$(field pass_examined) rate=$(field rate))"
	echo "remaining_t=$got   (zpool status: $want s; agree: $ok)"
done
x zinject -c all
x zpool scrub -s $P
x zpool status -v $P
x zpool export $P
echo
[ $n -ge 3 ] || die "only $n samples with an estimate in zpool status"
if [ $bad -gt 0 ]; then
	echo "RESULT BUG: zpool_influxdb printed $first ($bad of $n samples wrong)"
else
	echo "RESULT OK: zpool_influxdb and zpool status agree on the remaining time of the scrub ($n of $n samples; last: $lastgood)"
fi
