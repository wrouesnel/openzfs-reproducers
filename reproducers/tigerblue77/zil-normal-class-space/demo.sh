#!/bin/bash
# demo.sh -- openzfs/zfs#20004 (@johnpwhite), fixed by openzfs/zfs#19755
# (@tigerblue77): synchronous writes to a pool without a log device fill it
# with log blocks and suspend it with ENOSPC.
#
# The reporter's pool: a mirror of two 128 MiB files on a tmpfs, sync=always,
# four writers each rewriting the start of its own file with
# `dd bs=8k count=8 conv=notrunc`, again and again.  The 8 KiB writes are
# logged WR_COPIED, so each one is a log block.  A vdev of 7 metaslabs gets
# no embedded log metaslab, so zio_alloc_zil() takes the blocks from the
# normal class, and nothing counts them against the free space: they stay
# allocated until the txg holding their records syncs.  Overwrites of 256 KiB
# dirty too little data to end the txg, so within a few seconds the log has
# all 112 MiB.  The first failed log allocation makes zil_commit() wait for a
# txg sync, and that txg's own data and metadata writes then fail with
# ENOSPC in syncing context: the pool suspends.
# The PR charges each normal-class log block to the pool's root dsl_dir for
# its txg, so the writers wait for a sync before the log fills the pool.
#
#   master -> "RESULT BUG: the pool suspended after ..."
#   PR     -> "RESULT OK: all ... synchronous writes completed ... ONLINE"
# Run as root:  /demo/demo.sh       2 minutes (the bug: usually under 30 s).
# Options (podman run -e NAME=VALUE): WRITE_SECONDS (default 120, as the
# reporter's script), TXG_TIMEOUT (zfs_txg_timeout, default: left at 5 s).
set -u
eval "$(/demo/bin/zr env 2>/dev/null)"
SECS=${WRITE_SECONDS:-120} BS=8k CNT=8 TXGT=${TXG_TIMEOUT:-}
P=testpool D=/var/tmp/zfs-small-mirror W=4

result() {	# the RESULT line, also through the kernel's console
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}
case $SECS in [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) result "RESULT ERROR: WRITE_SECONDS=$SECS (1-999)"; exit 2 ;; esac
case $TXGT in ''|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) result "RESULT ERROR: TXG_TIMEOUT=$TXGT (1-999)"; exit 2 ;; esac
run() { echo "\$ $*"; "$@" 2>&1 | sed 's/^/    /'; return "${PIPESTATUS[0]}"; }
kst() { awk -v k="$1" '$1 == k { print $3 }' /proc/spl/kstat/zfs/zil; }
health() { zpool list -Hp -o health $P 2>/dev/null || echo GONE; }

echo "# $(uname -sr); build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# writers: $W x dd bs=$BS count=$CNT conv=notrunc for $SECS s"
[ -n "$TXGT" ] && echo $TXGT >/sys/module/zfs/parameters/zfs_txg_timeout
echo "# zfs_txg_timeout=$(cat /sys/module/zfs/parameters/zfs_txg_timeout)"
echo 1 >/sys/module/zfs/parameters/zfs_dbgmsg_enable
echo 0 >/proc/spl/kstat/zfs/dbgmsg

echo; echo "## 1. the reporter's pool: a mirror of two 128 MiB files on a 256 MiB tmpfs"
mkdir -p $D /etc/zfs
mount -t tmpfs -o size=256m tmpfs $D || { result "RESULT ERROR: mount tmpfs failed"; exit 2; }
truncate -s 128m $D/leader $D/lagging
run zpool create -f -o cachefile=none $P mirror $D/leader $D/lagging ||
    { result "RESULT ERROR: zpool create failed"; exit 2; }
run zfs set sync=always $P
run zpool list -p $P
zil0=$(kst zil_itx_metaslab_normal_alloc) cerr0=$(kst zil_commit_error_count)

echo; echo "## 2. $W writers, each rewriting its own file with sync=always, for $SECS s"
echo "#    (each line: seconds, health, allocated and free bytes, open txg)"
writer() {	# N: loop dd until the deadline; count the runs, keep dd's errors
	local f=/$P/sync.$1 n=0 end=$((SECONDS + SECS))
	while ((SECONDS < end)); do
		dd if=/dev/urandom of=$f bs=$BS count=$CNT conv=notrunc 2>/run/dd.err.$1 ||
		    { echo FAIL >/run/dd.fail.$1; break; }
		n=$((n + 1)); echo $n >/run/dd.n.$1
	done
	echo done >/run/dd.done.$1
}
rm -f /run/dd.*
for i in $(seq 1 $W); do writer $i & done
t0=$SECONDS susp=
while :; do
	h=$(health)
	txg=$(tail -1 /proc/spl/kstat/zfs/$P/txgs 2>/dev/null | awk '{ print $1 }')
	printf '    %3d s  %-9s %s  txg %s\n' $((SECONDS - t0)) "$h" "$(zpool list -Hp -o alloc,free $P 2>/dev/null | tr '\t' ' ')" "$txg"
	[ "$h" = SUSPENDED ] && { susp=$((SECONDS - t0)); break; }
	n=0; for i in $(seq 1 $W); do [ -f /run/dd.done.$i ] && n=$((n + 1)); done
	[ $n -eq $W ] && break
	((SECONDS - t0 > SECS + 60)) && break
	sleep 1
done
runs=0; for i in $(seq 1 $W); do runs=$((runs + $(cat /run/dd.n.$i 2>/dev/null || echo 0))); done
fails=$(ls /run/dd.fail.* 2>/dev/null | wc -l)
done_w=$(ls /run/dd.done.* 2>/dev/null | wc -l)
zil=$(($(kst zil_itx_metaslab_normal_alloc) - zil0)) cerr=$(($(kst zil_commit_error_count) - cerr0))
zfail=$(grep -c 'zil block allocation failure' /proc/spl/kstat/zfs/dbgmsg)

echo; echo "## 3. the end state"
run zpool status -v $P
run zpool list -p $P
echo "\$ zpool events | grep ereport (class, count)"
zpool events -H 2>/dev/null | awk '/ereport/ { c[$NF]++ } END { for (k in c) print "    " c[k] " x " k; if (!length(c)) print "    none" }'
echo "\$ grep 'zil block allocation failure' /proc/spl/kstat/zfs/dbgmsg"
grep 'zil block allocation failure' /proc/spl/kstat/zfs/dbgmsg | head -3 | sed 's/^/    /'
[ "$zfail" -gt 3 ] && echo "    ... ($zfail in all)"
echo
echo "## summary"
echo "  dd runs completed: $runs ($((runs * CNT)) synchronous ${BS} writes); writers finished: $done_w of $W; dd failures: $fails"
echo "  log written to the normal class: $((zil / 1048576)) MiB (zil_itx_metaslab_normal_alloc); pool size: $(($(zpool list -Hp -o size $P 2>/dev/null || echo 0) / 1048576)) MiB"
echo "  zil block allocation failures: $zfail; zil_commit errors: $cerr; health: $(health)"

if [ -n "$susp" ]; then
	result "RESULT BUG: the pool suspended after $susp s of synchronous writes ($runs dd runs done, $zfail log block allocation failures, $(zpool list -Hp -o free $P 2>/dev/null) bytes still free)"
	exit 1
fi
if [ "$(health)" = ONLINE ] && [ "$done_w" -eq $W ] && [ "$fails" -eq 0 ]; then
	run zpool export $P
	result "RESULT OK: all $runs dd runs ($((runs * CNT)) synchronous ${BS} writes) completed in $SECS s and the pool stayed ONLINE"
	exit 0
fi
result "RESULT ERROR: unexpected end state (health $(health), writers done $done_w of $W, dd failures $fails, log block allocation failures $zfail)"
exit 2
