#!/bin/bash
# demo.sh -- bug #275: sync(2) and syncfs(2) block forever on a pool that is
# already suspended.
#
# zfs_sync() (Linux sync_fs) commits the ZIL with ZIL_COMMIT_NOW so that a
# sync, syncfs or unmount does not block on a suspended pool (90a1e13df2,
# zfs-2.4.0, removed its explicit spa_suspended() check on that premise).
# But zil_commit_itx_assign() assigns the commit itx with
# dmu_tx_assign(DMU_TX_SUSPEND), which first waits for the pool to resume:
# only a pool that suspends *during* the commit gets the error.  So on a pool
# that is already suspended, sync(2) and syncfs(2) wait until a `zpool
# clear`, and forever when the pool can't be cleared (an MMP suspension,
# openzfs/zfs#19033).
#
#   1. a pool (failmode=wait, the default) on one disk; a file
#   2. suspend it: writes and the vdev probe fail, a txg sync suspends the
#      pool (through the txg, not the ZIL, so the ZIL is not crashed)
#   3. syncfs(2) on the file system, then sync(2), each given 20 s
#   repro (test commit, BRANCH~1): syncfs is still waiting after 20 s, in
#      zil_commit_itx_assign() -> "RESULT BUG: sync blocked on the suspended pool"
#   fixed (branch head): syncfs returns EIO at once, sync(2) returns
#      -> "RESULT OK: sync returned EIO"
#   4. zinject -c all; zpool clear: the pool resumes (anything still waiting
#      finishes)
#   5. the data written before and during the suspension is intact, after an
#      export/import and a scrub too
# Pool demo275 on the run disk $DEMO_DISK, or a file in /var/tmp/demo275.
# Exported at the end.  About 30 s (70 s on the repro).
set -u
P=demo275 FS=demo275/fs D=/var/tmp/demo275 W=20
H=${SYNCOP_BIN:-/demo/syncop}
mkdir -p $D
V=${DEMO_DISK:-}
[ -n "$V" ] || { truncate -s 1G $D/vdev0; V=$D/vdev0; }

run() { echo "\$ $*"; "$@"; }
st() {	# [label]: the pool's state after a step
	echo "--- zpool status -v $P${1:+   ($1)}"
	zpool status -v $P 2>&1 | sed 's/^/    /'
}
state() { cat /proc/spl/kstat/zfs/$P/state 2>/dev/null; }
digest() { sha256sum "$1" | cut -c1-16; }
result() {	# the RESULT line, also through the kernel's console
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}
# bounded NAME CMD...: start CMD in the background; report whether it
# returned within $W s.  Sets <NAME>_pid (still running) or <NAME>_rc.
bounded() {
	local n=$1 i pid; shift
	echo "\$ $*    (in the background, given $W s)"
	"$@" >$D/$n.out 2>&1 &
	pid=$!
	for i in $(seq $((W * 5))); do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
	if kill -0 $pid 2>/dev/null; then
		echo "  $n: STILL WAITING after $W s (process state $(awk '{ print $3 }' /proc/$pid/stat))"
		if [ -s /proc/$pid/stack ]; then
			echo "  its kernel stack:"; sed 's/^/    /' /proc/$pid/stack | head -14
		else
			echo "  waiting in $(cat /proc/$pid/wchan 2>/dev/null)"
		fi
		eval "${n}_pid=$pid ${n}_rc="
	else
		wait $pid; local rc=$?
		sed 's/^/  /' $D/$n.out
		eval "${n}_pid= ${n}_rc=$rc"
	fi
}

echo "# $(uname -sr); build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# vdev: $V"
zinject -c all >/dev/null 2>&1
zpool destroy -f $P 2>/dev/null
zpool labelclear -f "$V" 2>/dev/null
mkdir -p /etc/zfs
dd if=/dev/urandom of=$D/src bs=128k count=8 status=none
dd if=/dev/urandom of=$D/fillsrc bs=128k count=8 status=none

echo; echo "## 1. a pool (failmode=wait, the default) and a file"
run zpool create -f -o failmode=wait -O compression=off $P "$V" ||
    { result "RESULT ERROR: zpool create failed"; exit 2; }
run zfs create $FS
M=/$FS
run cp $D/src $M/file
run zpool sync $P
echo "  file sha256 $(digest $M/file); failmode=$(zpool get -H -o value failmode $P)"
st "created, file written"

echo; echo "## 2. suspend the pool: writes and the vdev probe fail, a txg sync"
run zinject -d "$V" -e io -T write $P
run zinject -d "$V" -e nxio -T probe $P
echo "\$ dd if=fillsrc of=$M/fill bs=128k count=8    (dirty data for the next txg)"
dd if=$D/fillsrc of=$M/fill bs=128k count=8 status=none
echo "\$ zpool sync $P &    (it waits for the pool; the txg sync fails and suspends it)"
zpool sync $P &
zs=$!
for _ in $(seq 150); do [ "$(state)" = SUSPENDED ] && break; sleep 0.2; done
echo "  pool state (kstat): $(state)"
if [ "$(state)" != SUSPENDED ]; then
	zinject -c all >/dev/null; zpool clear $P; wait
	result "RESULT ERROR: the pool did not suspend"; exit 2
fi
st "suspended"

echo; echo "## 3. sync on the suspended pool"
bounded syncfs $H syncfs $M
bounded sync $H sync
st "after the sync calls (pool still suspended)"
blocked=; [ -n "$syncfs_pid" ] && blocked=syncfs
[ -n "$sync_pid" ] && blocked="${blocked:+$blocked and }sync"
fs_err=$(grep -o -- '-1 [A-Z]*' $D/syncfs.out 2>/dev/null | cut -d' ' -f2)

echo; echo "## 4. resume the pool"
run zinject -c all
run zpool clear $P
for n in syncfs sync; do
	eval "pid=\$${n}_pid"
	[ -n "$pid" ] || continue
	wait $pid; eval "${n}_rc=$?"
	echo "  $n: finished after the clear:"; sed 's/^/    /' $D/$n.out
done
wait $zs; echo "  zpool sync: finished (exit $?)"
st "after zpool clear"

echo; echo "## 5. the data"
fail=
for f in file:src fill:fillsrc; do
	n=${f%%:*} s=${f#*:}
	echo "  $n sha256 $(digest $M/$n) (written: $(digest $D/$s))"
	cmp -s $D/$s $M/$n || fail+="$n differs; "
done
run zpool export $P || fail+="export failed; "
run zpool import -d "$(dirname "$V")" $P || { result "RESULT ERROR: import failed"; exit 2; }
run cmp $D/src $M/file || fail+="file differs after the import; "
run cmp $D/fillsrc $M/fill || fail+="fill differs after the import; "
run zpool scrub -w $P || fail+="scrub failed; "
st "the final state"
s=$(zpool status -v $P)
echo "$s" | awk -v p=$P '$1 == p { print $2; exit }' | grep -qx ONLINE || fail+="pool not ONLINE; "
echo "$s" | grep -q 'errors: No known data errors' || fail+="data errors; "
run zpool export $P
[ -z "$fail" ] && echo "  data intact: file and fill match what was written" ||
    echo "  DATA PROBLEMS: ${fail%; }"

if [ -n "$blocked" ]; then
	result "RESULT BUG: sync blocked on the suspended pool: $blocked still waiting after $W s, finished only after zpool clear${fail:+ (and: ${fail%; })}"
	exit 1
fi
if [ -n "$fail" ]; then
	result "RESULT ERROR: sync returned (syncfs ${fs_err:-rc $syncfs_rc}), but: ${fail%; }"
	exit 2
fi
if [ "$fs_err" = EIO ]; then
	result "RESULT OK: sync returned EIO on the suspended pool at once (syncfs EIO, sync(2) returned); after zpool clear the data is intact"
	exit 0
fi
result "RESULT ERROR: syncfs returned ${fs_err:-0}, not EIO, on the suspended pool"
exit 2
