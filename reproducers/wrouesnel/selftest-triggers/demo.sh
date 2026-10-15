#!/bin/bash
# demo.sh -- selftest-triggers: exercises every kind of host trigger
# (docs/reproducer-format.md) from VM0, with VM1 as the second host.
# Phase 0 (first boot):
#   network   ping VM1 over the private link
#   pool      mirror st on the two shared run disks, 32 MiB of random data
#   throttle  disk 0 at 20 IOPS: 50 synced 4k writes take over a second
#   errors    EIO on every read of disk 1: a scrub counts read errors there
#   unplug    disk 1 hot-unplugged: the pool degrades; plugged back in and
#             re-imported: the mirror is whole again
#   pause     VM0 paused for 2 s from the host, and resumed
#   powercut  the host cuts VM0's power with the pool imported, boots it
#             again and runs this script again, which carries on in phase 1
# Phase 1 (after the power cut):
#   import    the pool imports again (same hostid) with the data intact
#   overwrite the host zeroes 34 MiB of disk 1's image while the pool is
#             exported: a scrub repairs it from disk 0
#   peer      VM1 (another hostid) imports the exported pool and checksums it
#   copy      the host copies disk 0's image while VM0 runs
# RESULT OK if every step passed, RESULT FAIL with the failed steps if not.
set -u
P=st
fails= passed=
ok() { passed="$passed $1"; echo "== $1: ok"; }
bad() { fails="$fails $1"; echo "== $1: FAILED${2:+ ($2)}"; }
dev_of() {	# dev_of N: the partition of run disk N, by its serial
	local d
	for d in /sys/block/vd*; do
		[ "$(cat "$d/serial" 2>/dev/null)" = "zfsdemo-run$1" ] && { echo "/dev/${d##*/}1"; return 0; }
	done
	return 1
}
state_of() { zpool status -P $P | awk -v d="$1" '$1 == d { print $2 }'; }
summary() {
	if [ -z "$fails" ]; then echo "RESULT OK: zr self-test passed:$passed"
	else echo "RESULT FAIL: zr self-test failed:$fails (passed:$passed)"; fi
}

zr setup || { echo "RESULT ERROR: no host channel"; exit 2; }
phase=$(zr phase)
echo "== phase $phase"
if [ "$phase" = 0 ]; then
	zr wait peer-ready || bad wait-peer
	eval "$(zr env)"
	if ping -c 1 -W 5 "$PEER" >/dev/null; then ok network; else bad network "no reply from $PEER"; fi

	d0=$(dev_of 0) d1=$(dev_of 1)
	zpool create -f -o cachefile=none $P mirror "$d0" "$d1" || { echo "RESULT ERROR: zpool create"; exit 2; }
	dd if=/dev/urandom of=/$P/data bs=1M count=32 status=none
	sum=$(md5sum /$P/data | cut -d' ' -f1)
	echo "$sum" >/root/.zr-sum; sync
	ok pool

	zr trigger throttle 0 20 || bad throttle-set
	t=$EPOCHREALTIME
	dd if=/dev/zero of=/$P/sync bs=4k count=50 oflag=sync status=none
	el=$(awk -v a="$t" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.1f", b - a }')
	zr trigger unthrottle 0
	if awk -v e="$el" 'BEGIN { exit !(e >= 1.0) }'; then ok "throttle(${el}s)"; else bad throttle "50 sync writes took ${el}s"; fi

	zpool export $P && zpool import -d /dev $P	# empty the ARC: the scrub reads the disks
	zr trigger errors 1 read || bad errors-set
	zpool scrub -w $P
	re=$(zpool status -p $P | awk -v d="${d1##*/}" '$1 == d { print $3 }')
	zr trigger clear-errors 1
	zpool clear $P
	if [ "${re:-0}" -gt 0 ] 2>/dev/null; then ok "errors($re)"; else bad errors "no read errors counted on $d1"; zpool status $P; fi

	zr trigger unplug 1 || bad unplug-trigger
	i=0; while dev_of 1 >/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
	dd if=/dev/urandom of=/$P/more bs=1M count=4 status=none; sync
	zpool scrub -w $P 2>/dev/null
	st=$(zpool list -H -o health $P)
	zr trigger plug 1 || bad plug-trigger
	i=0; while ! dev_of 1 >/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
	zpool export $P && zpool import -d /dev $P
	zpool wait -t resilver $P
	st2=$(zpool list -H -o health $P)
	if [ "$st" = DEGRADED ] && [ "$st2" = ONLINE ]; then ok unplug; else bad unplug "health $st after the unplug, $st2 after the replug"; zpool status $P; fi

	if zr trigger pause 2; then ok pause; else bad pause; fi

	echo "$fails" >/root/.zr-fails; echo "$passed" >/root/.zr-passed
	zr phase 1
	echo "== powercut: the host cuts the power now (pool $P imported)"
	zr trigger powercut
	echo "RESULT ERROR: still running after the power cut"; exit 2
fi

fails=$(cat /root/.zr-fails) passed=$(cat /root/.zr-passed) sum=$(cat /root/.zr-sum)
ok powercut
if zpool import -d /dev $P && [ "$(md5sum /$P/data | cut -d' ' -f1)" = "$sum" ]; then ok import; else bad import; fi

d1=$(dev_of 1)
zpool export $P
zr trigger zero 1 $((6 << 20)) $((34 << 20)) || bad zero-trigger
zpool import -d /dev $P && zpool scrub -w $P
zpool status $P
ck=$(zpool status -p $P | awk -v d="${d1##*/}" '$1 == d { print $5 }')
if [ "${ck:-0}" -gt 0 ] 2>/dev/null && [ "$(md5sum /$P/data | cut -d' ' -f1)" = "$sum" ]; then ok "overwrite($ck)"; else bad overwrite "checksum errors ${ck:-?} on $d1"; fi
zpool clear $P

zpool export $P
psum=$(zr trigger peer-import)
if [ "$psum" = "$sum" ]; then ok peer; else bad peer "VM1 read '$psum'"; fi

zpool import -d /dev $P
if zr trigger copy 0 st-copy.raw >/dev/null; then ok copy; else bad copy; fi
zpool export $P
zr phase 0
summary
