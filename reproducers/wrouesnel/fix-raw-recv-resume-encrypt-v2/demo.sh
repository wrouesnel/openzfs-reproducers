#!/bin/bash
# demo.sh -- bug #276 (openzfs/zfs#18394): a raw receive of an encrypted
# dataset whose key is not loaded panics after the destination pool is
# suspended and resumed with `zpool clear`:
#   VERIFY0(spa_do_crypt_abd(B_TRUE, ...)) failed (13)
#   PANIC at zio.c:...:zio_encrypt()
#
# When the pool's disk fails during a txg sync of the receive, the blocks
# that can no longer be allocated reach arc_write_ready() with a hole bp,
# and its "hole" branch clears ARC_BUF_FLAG_ENCRYPTED on buffers that still
# hold the raw (encrypted) blocks of dnodes.  After `zpool clear` the next
# txg that dirties such a block of dnodes writes it as if it were plaintext:
# zio_encrypt() looks up the dataset's key, which a raw receive doesn't
# have (EACCES = 13), and the VERIFY0 fires.  The fix adjusts the buffer's
# flags only when its write succeeded.
#
#   1. a source pool: an encrypted dataset (1000 small files and a 64 MiB
#      file), snapshot, a raw stream (zfs send -w) saved in a file
#   2. the destination pool (failmode=wait) on its own disk
#   3. receive all but the last 40 MiB of the stream (zfs receive -s -u);
#      the key of the received dataset is not loaded
#   4. the destination's disk fails (writes fail with EIO, the probe with
#      ENXIO, zinject); 16 MiB more of the stream; the pool suspends
#   5. the disk is back: zinject -c all, zpool clear; the rest of the stream
#   6. wait for the receive, watching the kernel log
#   repro (BRANCH~1: the #276 tests on the #277 fix, without the #276 fix):
#      the kernel log shows the VERIFY0 in zio_encrypt(); the receive never
#      finishes -> "RESULT BUG: the raw receive hit VERIFY0 ... in zio_encrypt"
#   fixed (branch head): the receive finishes (rc 0), the pool is ONLINE
#   7. (fixed) load the key, mount, compare with the source; export, import,
#      compare again; scrub: "No known data errors"
#      -> "RESULT OK: the raw receive survived the suspend and clear"
#   Which blocks of dnodes fail with a hole bp depends on when the failed
#   probe stops allocations, so on the break a round misses about 1 time in 6:
#   steps 2-7 run up to 3 times, each on a new destination pool; the break
#   stops at the first VERIFY, the fix passes all 3 rounds.
# Pools demo276src on $DEMO_DISKS[0] and demo276 on $DEMO_DISKS[1] (or files
# in /var/tmp/demo276).  Exported at the end.  About 1 minute (2 on the fix).
set -u
P=demo276 S=demo276src D=/var/tmp/demo276 PW=password
RFS=$P/recv SFS=$S/enc
mkdir -p $D
read -r V0 V1 _ <<<"${DEMO_DISKS:-}"
if [ -z "${V1:-}" ]; then
	truncate -s 1G $D/src0 $D/dst0; V0=$D/src0 V1=$D/dst0
fi

run() { echo "\$ $*"; "$@"; }
st() {	# [label]: the destination pool's state after a step
	echo "--- zpool status -v $P${1:+   ($1)}"
	bg_out $D/st.out 15 zpool status -v $P || echo "    (zpool status -v is blocked after 15 s)"
	sed 's/^/    /' $D/st.out
}
# bg_out FILE SECS CMD...: run CMD with its output in FILE; false if it
# hasn't finished after SECS (it is left running: a hung pool can't be killed)
bg_out() {
	local f=$1 s=$2 pid i; shift 2
	"$@" >"$f" 2>&1 &
	pid=$!
	for i in $(seq $((s * 5))); do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
	kill -0 $pid 2>/dev/null && return 1
	wait $pid; return 0
}
state() { cat /proc/spl/kstat/zfs/$P/state 2>/dev/null; }
prop() { zfs get -H -o value "$1" "$2" 2>/dev/null; }
kmsg() { dmesg | tail -n +$((kmsg0 + 1)); }
result() {	# the RESULT line, also through the kernel's console
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}
die() { result "RESULT ERROR: $*"; exit 2; }

echo "# $(uname -sr); build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# source vdev $V0, destination vdev $V1"
zinject -c all >/dev/null 2>&1
zpool destroy -f $P 2>/dev/null; zpool destroy -f $S 2>/dev/null
zpool labelclear -f "$V0" 2>/dev/null; zpool labelclear -f "$V1" 2>/dev/null
mkdir -p /etc/zfs

echo; echo "## 1. the source: an encrypted dataset, a raw stream of its snapshot"
run zpool create -f -O compression=off $S "$V0" || die "zpool create $S failed"
echo "\$ echo $PW | zfs create -o encryption=on -o keyformat=passphrase -o keylocation=prompt $SFS"
echo $PW | zfs create -o encryption=on -o keyformat=passphrase -o keylocation=prompt $SFS ||
    die "zfs create $SFS failed"
echo "\$ (1000 small files f1..f1000, 4-10 KiB each: about 32 blocks of dnodes)"
for i in $(seq 1 1000); do
	dd if=/dev/urandom of=/$SFS/f$i bs=1k count=$((4 + i % 7)) status=none ||
	    die "can't create /$SFS/f$i"
done
run dd if=/dev/urandom of=/$SFS/big bs=1M count=64 status=none
run zfs snapshot $SFS@snap
echo "\$ zfs send -w $SFS@snap > /$S/stream"
zfs send -w $SFS@snap >/$S/stream || die "zfs send -w failed"
mib=$(( ($(stat -c %s /$S/stream) + 1048575) / 1048576 ))
part1=$((mib - 40)) part2=16
echo "  raw stream: $mib MiB; fed as $part1 MiB, then $part2 MiB, then the rest"

ROUNDS=3
echo
echo "# Which blocks of dnodes are hit depends on the timing of the failure, so"
echo "# the receive is done up to $ROUNDS times (steps 2-7), each time on a new"
echo "# destination pool.  The break usually panics in round 1."
for round in $(seq $ROUNDS); do
R="round $round/$ROUNDS"
echo; echo "################ $R ################"
echo; echo "## 2. ($R) the destination pool (failmode=wait)"
zpool destroy -f $P 2>/dev/null; zpool labelclear -f "$V1" 2>/dev/null
run zpool create -f -o failmode=wait -O compression=off $P "$V1" || die "zpool create $P failed"
st "created"

echo; echo "## 3. ($R) receive the first $part1 MiB of the raw stream (the key is not loaded)"
rm -f $D/gate1 $D/gate2 $D/recv.out
echo "\$ (stream in 3 parts) | zfs receive -s -u $RFS &"
{
	dd if=/$S/stream bs=1M count=$part1 status=none
	while [ ! -f $D/gate1 ]; do sleep 0.1; done
	dd if=/$S/stream bs=1M skip=$part1 count=$part2 status=none
	while [ ! -f $D/gate2 ]; do sleep 0.1; done
	dd if=/$S/stream bs=1M skip=$((part1 + part2)) status=none
} | zfs receive -s -u $RFS >$D/recv.out 2>&1 &
rpid=$!
for _ in $(seq 60); do zfs list $RFS >/dev/null 2>&1 && break; sleep 1; done
zfs list $RFS >/dev/null 2>&1 || die "the receive didn't create $RFS"
sleep 3
run zpool sync $P
echo "  keystatus of $RFS: $(prop keystatus $RFS)"
[ "$(prop keystatus $RFS)" = unavailable ] || die "the key of $RFS is loaded"
st "receiving, $part1 MiB in"

echo; echo "## 4. ($R) the destination's disk fails; $part2 MiB more of the stream"
kmsg0=$(dmesg | wc -l)
run zinject -d "$V1" -e io -T write $P
run zinject -d "$V1" -e nxio -T probe $P
touch $D/gate1
echo "  waiting for the pool to suspend..."
for _ in $(seq 300); do [ "$(state)" = SUSPENDED ] && break; sleep 0.2; done
echo "  pool state (kstat): $(state)"
[ "$(state)" = SUSPENDED ] || die "the pool did not suspend"
kill -0 $rpid 2>/dev/null || die "the receive ended early: $(cat $D/recv.out)"
st "suspended"

echo; echo "## 5. ($R) the disk is back: clear the pool and feed the rest of the stream"
run zinject -c all
run zpool clear $P
touch $D/gate2
st "after zpool clear"

echo; echo "## 6. ($R) waiting for the receive (up to 180 s), watching the kernel log"
t0=$(date +%s) verify=
while kill -0 $rpid 2>/dev/null && [ $(($(date +%s) - t0)) -lt 180 ]; do
	kmsg | grep -qE 'VERIFY|PANIC at' && { verify=1; break; }
	sleep 0.5
done
sleep 1
kmsg | grep -qE 'VERIFY|PANIC at' && verify=1
if [ -n "$verify" ]; then
	echo "  the kernel log, $(($(date +%s) - t0)) s after the clear:"
	kmsg | grep -E -A14 'VERIFY|PANIC at' | head -24 | sed 's/^/    /'
	kill -0 $rpid 2>/dev/null && echo "  zfs receive: still running (its txg can't sync)" ||
	    echo "  zfs receive: ended: $(cat $D/recv.out)"
	st "after the VERIFY"
	echo "  (the pool can't sync any more: not exported)"
	result "RESULT BUG: the raw receive hit VERIFY0(spa_do_crypt_abd(...)) failed (13) in zio_encrypt after zpool clear (key not loaded; round $round of $ROUNDS)"
	exit 1
fi
if kill -0 $rpid 2>/dev/null; then
	st "receive still running after 180 s"
	die "the receive didn't finish in 180 s (no VERIFY; $R)"
fi
wait $rpid; rc=$?
echo "  zfs receive finished: rc=$rc $(cat $D/recv.out)"
st "receive finished"
fail=
[ $rc = 0 ] || fail+="receive rc $rc; "
echo "  pool state (kstat): $(state); health: $(zpool list -H -o health $P)"
[ "$(state)" = ONLINE ] || fail+="pool state $(state); "
run zfs list -t snapshot $RFS@snap || fail+="no $RFS@snap; "
echo "  receive_resume_token: $(prop receive_resume_token $RFS)"
[ "$(prop receive_resume_token $RFS)" = - ] || fail+="a resume token is left; "
echo "  keystatus of $RFS: $(prop keystatus $RFS)"

echo; echo "## 7. ($R) the received data: load the key, mount, compare with the source"
echo "\$ echo $PW | zfs load-key $RFS"
echo $PW | zfs load-key $RFS || fail+="load-key failed; "
run zfs mount $RFS || fail+="mount failed; "
run diff -r /$SFS /$RFS && echo "  identical: $(ls /$RFS | wc -l) files" || fail+="data differs; "
run zpool export $P || fail+="export failed; "
run zpool import -d "$(dirname "$V1")" $P || die "import failed ($R)"
echo "\$ echo $PW | zfs load-key $RFS"
echo $PW | zfs load-key $RFS || fail+="load-key after import failed; "
run zfs mount $RFS || fail+="mount after import failed; "
run diff -r /$SFS /$RFS && echo "  identical after the import" || fail+="data differs after the import; "
run zfs unmount $RFS
run zpool scrub -w $P || fail+="scrub failed; "
st "$R: the final state"
s=$(zpool status -v $P)
echo "$s" | awk -v p=$P '$1 == p { print $2; exit }' | grep -qx ONLINE || fail+="pool not ONLINE; "
echo "$s" | grep -q 'errors: No known data errors' || fail+="data errors; "
if [ -n "$fail" ]; then
	result "RESULT ERROR: no VERIFY, but: ${fail%; } ($R)"
	exit 2
fi
echo "  $R: no VERIFY; received data intact"
done
run zpool export $P
run zpool export $S
result "RESULT OK: the raw receive survived the suspend and clear: no VERIFY in $ROUNDS rounds, receive rc 0, data identical before and after export/import, scrub clean"
exit 0
