#!/bin/bash
# demo.sh -- bug #44 v2 (openzfs #18024, PR #19318): a retried import of a
# pool with cloned (BRT) and deduplicated blocks oopses in brt_get_dspace().
#
# When a load fails after brt_load() (here: spa_load_verify() finds a damaged
# block), spa_load() is retried on the same spa_t at an older txg.
# brt_vdevs_free() freed spa_brt_vdevs but left it and spa_brt_nvdevs set, and
# the retry's vdev_load() recomputes the pool's space (dedup history resets
# spa_dedup_dspace) through brt_get_dspace(), which walks the freed array
# before the retry's own brt_load().
#
# This is the ZTS test import_rewind_brt_retry of the v2 branch, step by step,
# with `zpool status -v` after each step:
#   1. a pool of 5 vdevs (run disks 1-5); a file and its clone (BRT), a dedup
#      dataset with two copies of a file, and the file we damage later
#   2. zpool checkpoint; goodtxg = the last synced txg
#   3. overwrite the file (a new L1 indirect block), zpool freeze, damage
#      that L1 on disk, export: the newest txg on disk references the damage
#   4. zpool import -f -T <newest txg> under a new name: the load of the
#      newest txg gets through brt_load() and fails spa_load_verify(), and
#      spa_load() retries at older txgs
#   repro (test commit f300de790e): the retry oopses in brt_get_dspace()
#                                    -> "RESULT BUG: the retried import oopsed"
#   fixed (branch head f10e79f235):  the import rewinds to a txg between the
#      checkpointed state and goodtxg, the file, clones, dedup copies and
#      their accounting are intact, checkpoint discarded, scrub clean
#                                    -> "RESULT OK: the retried import rewound"
# Pool demo44 on the run disks $DEMO_DISKS (5), or files in /var/tmp/demo44.
# On the fix it is exported at the end (as demo44_retry).  About 30 s.
set -u
P=demo44 NP=demo44_retry D=/var/tmp/demo44 PP=/sys/module/zfs/parameters
read -r -a V <<< "${DEMO_DISKS:-}"
if [ ${#V[@]} -ge 5 ]; then
	DIR=/dev
else
	mkdir -p $D; V=()
	for i in 0 1 2 3 4; do truncate -s 512M $D/vdev$i; V+=($D/vdev$i); done
	DIR=$D
fi
V=("${V[@]:0:5}")

run() { echo "\$ $*"; "$@"; }
st() {	# POOL [label]: the pool's state after a step
	echo "--- zpool status -v $1${2:+   ($2)}"
	zpool status -v "$1" 2>&1 | sed 's/^/    /'
}
prop() { zpool get -Hp -o value "$1" "$2"; }
digest() { sha256sum "$1" | cut -c1-16; }

OOPS_RE='BUG: |Oops|general protection fault|kernel BUG|PANIC at |VERIFY[0-9]*[(]|ASSERT[0-9]*[(]|blocked for more than [0-9]+ seconds|Kernel panic'
KLOG=/run/demo44.kmsg
result() {	# the RESULT line, also through the kernel's console (an oopsed
	# task can leave the tty's output stuck while printk still gets out)
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}

echo "# $(uname -sr); build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# vdevs: ${V[*]}"
zpool destroy -f $NP 2>/dev/null; zpool destroy -f $P 2>/dev/null
for v in "${V[@]}"; do zpool labelclear -f "$v" 2>/dev/null; done
mkdir -p /etc/zfs
txg0=$(cat $PP/zfs_txg_timeout)
echo 1 >$PP/zfs_dbgmsg_enable

echo; echo "## 1. a pool with cloned and deduplicated blocks"
run zpool create -f -o feature@block_cloning=enabled $P "${V[@]}" ||
    { result "RESULT ERROR: zpool create failed"; exit 2; }
st $P "created"
run dd if=/dev/urandom of=/$P/orig bs=128k count=8
run clonefile -f /$P/orig /$P/clone || { result "RESULT ERROR: clonefile failed"; exit 2; }
run zfs create -o dedup=on $P/dedup
run dd if=/dev/urandom of=/$P/dedup/a bs=128k count=8
run dd if=/$P/dedup/a of=/$P/dedup/b bs=128k
run dd if=/dev/urandom of=/$P/file bs=128k count=8
run zpool sync $P
dg=$(digest /$P/file)
bu=$(prop bcloneused $P) bs=$(prop bclonesaved $P) ds=$(prop dedupsaved $P)
echo "  file sha256 $dg; bcloneused $bu, bclonesaved $bs, dedupsaved $ds"
[ "$bs" -gt 0 ] && [ "$ds" -gt 0 ] ||
    { result "RESULT ERROR: no cloned ($bs) or deduplicated ($ds) blocks"; exit 2; }
zpool list -o name,size,alloc,bcloneused,bclonesaved,dedupratio $P | sed 's/^/    /'
st $P "data written"

echo; echo "## 2. checkpoint (only explicit syncs advance the txg from now on)"
run eval "echo 5000 >$PP/zfs_txg_timeout"
run zpool checkpoint $P
good=$(zdb -u $P | awk '$1 == "txg" { print $3 }' | sort -n | tail -1)
echo "  goodtxg (last synced before the overwrite): $good"
st $P "checkpointed"

echo; echo "## 3. overwrite the file, freeze the pool, damage the file's new L1"
run dd if=/dev/urandom of=/$P/file bs=128k count=8 conv=notrunc 2>/dev/null
run zpool freeze $P
run zpool sync $P
obj=$(stat -c %i /$P/file)
echo "\$ zdb -dddddd $P/ $obj | grep ' L1 '"
l1=$(zdb -dddddd "$P/" "$obj" | awk '/^Indirect blocks:/ { l = 1; next } /^$/ { l = 0 } l && $2 == "L1"')
echo "$l1" | sed 's/^ */    /'
# the L1 of a file's data has two copies (ditto): damage every DVA
dvas=$(echo "$l1" | awk '{ for (i = 3; split($i, d, ":") == 3; i++) print $i; exit }')
[ -n "$dvas" ] || { result "RESULT ERROR: no L1 block of $P/file"; exit 2; }
for dva in $dvas; do
	IFS=: read -r vd off len <<<"$dva"
	[ -n "${V[$vd]:-}" ] || { result "RESULT ERROR: DVA $dva: no vdev $vd"; exit 2; }
	# 4 MiB of labels and boot block precede the allocatable space
	seek=$(( (0x$off + (4 << 20)) / 512 )) cnt=$(( 0x$len / 512 ))
	run dd if=/dev/urandom of="${V[$vd]}" bs=512 seek=$seek count=$cnt conv=notrunc 2>/dev/null
done
st $P "frozen, the L1 ($(echo $dvas)) damaged on disk"
run zpool export $P
run eval "echo $txg0 >$PP/zfs_txg_timeout"
bad=$(zdb -e -p $DIR -u $P | awk '$1 == "txg" { print $3; exit }')
ckpt=$(zdb -e -p $DIR -k -u $P | awk '$1 == "bp" { for (i = 1; i <= NF; i++) if (sub(/^birth=/, "", $i)) { sub(/L.*/, "", $i); print $i }; exit }')
echo "  checkpointed state: txg $ckpt; goodtxg: $good; newest on disk (badtxg): $bad"
[ "${ckpt:-0}" -gt 0 ] && [ "$ckpt" -lt "$good" ] && [ "$good" -lt "${bad:-0}" ] ||
    { result "RESULT ERROR: unexpected txgs (checkpointed $ckpt, good $good, newest $bad)"; exit 2; }
echo "\$ zpool import -d $DIR    (what an import would find)"
zpool import -d $DIR 2>&1 | sed 's/^/    /'

echo; echo "## 4. import the newest txg: its load fails verification, spa_load retries"
cntmsg() { grep -c "spa_load($NP, .*$1" /proc/spl/kstat/zfs/dbgmsg; }
v0=$(cntmsg "FAILED: spa_load_verify failed") r0=$(cntmsg "spa_load_retry: rewind")
t0=$(awk '{ printf "%.0f", $1 * 1000000 }' /proc/uptime)
: >$KLOG
( cat /dev/kmsg | awk -W interactive -F';' -v t0="$t0" \
    '{ split($1, a, ","); if (a[3] + 0 > t0) { sub(/^[^;]*;/, ""); print; fflush() } }' >>$KLOG ) &
watch=$!
echo "\$ zpool import -f -d $DIR -T $bad $P $NP"
zpool import -f -d $DIR -T "$bad" $P $NP >/run/demo44.out 2>&1 &
imp=$!
oops=
for _ in $(seq 1 600); do
	if grep -qE "$OOPS_RE" $KLOG; then oops=1; break; fi
	kill -0 $imp 2>/dev/null || break
	sleep 0.2
done
if [ -z "$oops" ]; then wait $imp; irc=$?; sleep 1; grep -qE "$OOPS_RE" $KLOG && oops=1; fi
sed 's/^/    /' /run/demo44.out
if [ -n "$oops" ]; then
	for _ in $(seq 1 50); do grep -q 'end trace' $KLOG && break; sleep 0.2; done
	echo "--- kernel log (the oops: its first line, RIP and call trace)"
	awk -v re="$OOPS_RE" '!s && $0 ~ re { s = 1; print; next }
	    s && /RIP:|Comm:/ { print } s && /Call Trace/ { t = 1 } t { print } t && /<\/TASK>/ { exit }' $KLOG |
	    sed 's/^/    /'
	# reading the dbgmsg kstat doesn't take the namespace lock the oopsed
	# import still holds; in the background all the same
	( grep -E "spa_load\($NP, .*(FAILED|spa_load_retry)" /proc/spl/kstat/zfs/dbgmsg |
	    sed 's/^[0-9]* *//; s/^/    /' >/run/demo44.dbg ) &
	sleep 2
	echo "--- zfs dbgmsg: the failed verification and the retry before the oops"
	cat /run/demo44.dbg
	echo "# (no zpool commands now: the oopsed import holds spa_namespace_lock)"
	kill $watch 2>/dev/null
	result "RESULT BUG: the retried import oopsed: $(grep -m1 -E "$OOPS_RE" $KLOG | cut -c1-100)"
	exit 1
fi
kill $watch 2>/dev/null
[ "$irc" = 0 ] || { st $NP; result "RESULT ERROR: zpool import -T $bad failed (exit $irc)"; exit 2; }
v1=$(cntmsg "FAILED: spa_load_verify failed") r1=$(cntmsg "spa_load_retry: rewind")
echo "--- zfs dbgmsg: the loads of $NP that failed verification, and the retries"
grep -E "spa_load\($NP, .*(FAILED: spa_load_verify|spa_load_retry)" /proc/spl/kstat/zfs/dbgmsg |
    sed 's/^[0-9]* *//; s/^/    /'
echo "  $((v1 - v0)) loads failed their verification (after brt_load()), $((r1 - r0)) retries"
tgt=$(sed -n 's/.*(txg \([0-9][0-9]*\)).*/\1/p' /run/demo44.out | head -1)
echo "  rewound to txg ${tgt:-?} (checkpointed state $ckpt .. goodtxg $good)"
st $NP "imported at the rewind target"

echo; echo "## 5. the rewound pool: data, clones, dedup copies, accounting"
fail=
[ $((v1 - v0)) -gt 0 ] || fail+="no load failed its verification; "
[ $((r1 - r0)) -gt 0 ] || fail+="the failed load was not retried; "
[ -n "$tgt" ] && [ "$tgt" -ge "$ckpt" ] && [ "$tgt" -le "$good" ] || fail+="rewind target '$tgt' not in $ckpt..$good; "
ndg=$(digest /$NP/file)
echo "  file sha256 $ndg (before the overwrite: $dg)"
[ "$ndg" = "$dg" ] || fail+="the file was not restored; "
for p in bcloneused bclonesaved dedupsaved; do
	case $p in bcloneused) e=$bu ;; bclonesaved) e=$bs ;; dedupsaved) e=$ds ;; esac
	n=$(prop $p $NP); echo "  $p $n (before: $e)"
	[ "$n" = "$e" ] || fail+="$p $n, was $e; "
done
run cmp /$NP/orig /$NP/clone || fail+="clone differs; "
run cmp /$NP/dedup/a /$NP/dedup/b || fail+="dedup copies differ; "
cp=$(prop checkpoint $NP)
if [ "$tgt" -gt "$ckpt" ] 2>/dev/null; then
	[ "$cp" != - ] || fail+="checkpoint gone after a rewind to $tgt; "
	run zpool checkpoint -d -w $NP || fail+="checkpoint discard failed; "
	st $NP "checkpoint discarded"
fi
run zpool scrub -w $NP || fail+="scrub failed; "
st $NP "after the scrub"
s=$(zpool status -v $NP)
echo "$s" | awk -v p=$NP '$1 == p { print $2; exit }' | grep -qx ONLINE || fail+="pool not ONLINE; "
echo "$s" | grep -q 'errors: No known data errors' || fail+="data errors; "
echo "$s" | grep -q 'scrub repaired 0B .* with 0 errors' || fail+="the scrub found errors; "
# a CKSUM count already shows right after the import (step 4), while the
# loads of the newer txgs verified the pool; the rewound pool's own scrub
# above found nothing, so clear the counters for the final state
echo "# CKSUM counts (if any) date from the import's failed verification loads of the newer txgs; the scrub found 0 errors"
run zpool clear $NP
st $NP "the final state"
zpool status -x $NP | grep -q "is healthy" || fail+="pool not healthy after zpool clear; "
run zpool export $NP
if [ -n "$fail" ]; then
	result "RESULT ERROR: the import did not oops, but: ${fail%; }"
	exit 2
fi
result "RESULT OK: the retried import rewound to txg $tgt; file, clones, dedup and accounting intact, scrub clean"
