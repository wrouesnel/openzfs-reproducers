#!/bin/bash
# after_test.sh WHEN -- prints what is left once a test (or the group's
# cleanup) has finished: the pools' kernel state (the state kstat, which
# never blocks), `zpool list` and `zpool status -v` (each under a timeout:
# a suspended pool can make them wait), the scsi_debug disk and
# pool_state's device link and image, and the lsscsi trigger's log.
echo "--- $1 ---"
echo "# pools imported, kernel state (/proc/spl/kstat/zfs/POOL/state):"
ls /proc/spl/kstat/zfs/*/state >/dev/null 2>&1 || echo "    (none)"
for k in /proc/spl/kstat/zfs/*/state; do
	[ -e "$k" ] && echo "    $(basename "$(dirname "$k")"): $(cat "$k")"
done
echo "# zpool list"
timeout 20 zpool list 2>&1 | sed 's/^/    /'; [ "${PIPESTATUS[0]}" = 124 ] && echo "    (zpool list: no answer in 20 s)"
for p in $(timeout 20 zpool list -H -o name 2>/dev/null); do
	echo "# zpool status -v $p"
	timeout 20 zpool status -v "$p" 2>&1 | sed 's/^/    /'; [ "${PIPESTATUS[0]}" = 124 ] && echo "    (zpool status: no answer in 20 s)"
done
echo "# scsi_debug: $(grep -qw scsi_debug /proc/modules && echo "module loaded" || echo "module not loaded"); lsscsi:"
/usr/bin/lsscsi 2>&1 | sed 's/^/    /'
echo "# pool_state's files: $(ls -d /dev/kstat-state-realdisk /var/tmp/zts/kstat-state* 2>/dev/null | tr '\n' ' ')"
echo "# the lsscsi trigger (flaky_lsscsi.sh):"
sed 's/^/    /' /run/zts/lsscsi.log 2>/dev/null || echo "    (no log)"
echo "--- end ---"
