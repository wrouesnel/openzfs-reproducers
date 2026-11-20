#!/bin/bash
# inject_mmp_delay.sh [POOL [DELAY_MS [SECS]]] -- the stand-in for the CI
# stall behind this reproducer (fork zfs-qemu 43540734393, ubuntu22: one MMP
# write took 1.25 s).  The runner starts it beside the ZTS run (prep.sh of
# this reproducer).  It waits until MMP has started writing to POOL (its
# multihost kstat has entries, i.e. multihost=on), then delays every write to
# the pool's leaf by DELAY_MS (default 1500) for SECS (default 3), and clears
# the injection.  With master's mmp_on_off (zfs_multihost_interval=100, the
# default 10 fail intervals: suspend after 1 s without a successful MMP
# write) the pool suspends; the fixed test sets the fail intervals to 0.
P=${1:-testpool} DL=${2:-1500} S=${3:-3}
k=/proc/spl/kstat/zfs/$P/multihost
for _ in $(seq 3000); do
	[ -r $k ] && [ "$(wc -l <$k)" -gt 3 ] && break
	sleep 0.1
done
[ -r $k ] || { echo "inject: $P never wrote MMP"; exit 1; }
v=$(zpool list -vHP $P | awk 'NR==2 {print $1}')
echo "inject: MMP is writing to $P; delaying every write to $v by $DL ms for $S s"
zinject -d $v -D $DL:1 -T write $P >/dev/null
sleep $S
zinject -c all >/dev/null
sleep 1
echo "inject: done; $P is now $(cat /proc/spl/kstat/zfs/$P/state 2>/dev/null || echo gone)" \
    "(kernel state kstat)"
