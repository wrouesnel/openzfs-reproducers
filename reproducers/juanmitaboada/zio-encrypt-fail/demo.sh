#!/bin/bash
# demo.sh -- openzfs/zfs#19996: a write that reaches zio_encrypt() without
# its dataset's key.  master VERIFY0s the keyed calls there:
#   VERIFY0(spa_do_crypt_abd(B_TRUE, ...)) failed (13)
#   PANIC at zio.c:...:zio_encrypt()
# and the pool's sync thread is gone.  The PR fails such a write with EACCES
# and, as the write can't fail, suspends the pool (as for ENOSPC).
#
# The trigger is #18394's (fixed at its cause by #19975, not in either build
# here): when the pool's disk fails during a txg sync of a raw receive, the
# blocks that can't be allocated reach arc_write_ready() with a hole bp, and
# it clears ARC_BUF_FLAG_ENCRYPTED on buffers that still hold raw (encrypted)
# blocks of dnodes.  After `zpool clear` the next txg that dirties such a
# block writes it as plaintext, so zio_encrypt() looks up the key, which a
# raw receive doesn't load (EACCES = 13).
#
#   1. a source pool: an encrypted dataset (1000 small files and a 64 MiB
#      file), snapshot, a raw stream (zfs send -w) saved in a file
#   2. the destination pool (failmode=wait) on its own disk
#   3. receive all but the last 40 MiB of the stream (zfs receive -s -u);
#      the key of the received dataset is not loaded
#   4. the destination's disk fails (writes EIO, probe ENXIO, zinject);
#      16 MiB more of the stream; the pool suspends
#   5. the disk is back: zinject -c all, zpool clear; the rest of the stream
#   6. wait for the receive, watching the kernel log and the pool state
#   repro (master, the PR's base): the VERIFY0 in zio_encrypt()
#      -> "RESULT BUG: ... VERIFY0 ... in zio_encrypt"
#   fixed (the PR head): no VERIFY; the pool suspends again, the dbgmsg has
#      "zio_encrypt failed: error 13", the error log and a data ereport
#      (zio_err 0xd) name the block.  A second `zpool clear` suspends it
#      again (the write fails the same way: the block stays plaintext in
#      memory), and `zfs load-key` is refused while the pool is suspended.
#   7. (fixed) the way out is a reboot: the host cuts the power, the VM boots
#      again, the pools are imported, the receive is resumed from its token
#      (zfs send -t), the key loaded, the data compared with the source, and
#      a scrub run -> "RESULT OK: ..."
#   Which blocks of dnodes fail with a hole bp depends on when the failed
#   probe stops allocations, so a round misses about 1 time in 6: steps 2-6
#   run up to 3 times, each on a new destination pool, until one hits.
# Pools demo19996src on $DEMO_DISKS[0] and demo19996 on $DEMO_DISKS[1].
# Exported at the end (fixed).  About 2 minutes.
set -u
P=demo19996 S=demo19996src D=/var/tmp/demo19996 PW=password
RFS=$P/recv SFS=$S/enc
mkdir -p $D
read -r V0 V1 _ <<<"${DEMO_DISKS:-}"
[ -n "${V1:-}" ] || { echo "RESULT ERROR: needs two run disks (DEMO_DISKS)"; exit 2; }

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
wait_state() {	# STATE SECS: wait for the pool's kstat state
	local i
	for i in $(seq $(($2 * 5))); do [ "$(state)" = "$1" ] && return 0; sleep 0.2; done
	return 1
}

echo "# $(uname -sr); build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# source vdev $V0, destination vdev $V1"
mkdir -p /etc/zfs

if [ "$(zr phase 2>/dev/null)" = 1 ]; then
	##################### after the power cut (fixed) #####################
	echo; echo "## 7. after the power cut: the VM booted again"
	run zpool import -f -d /dev $S || die "import of $S failed"
	run zpool import -f -d /dev $P || die "import of $P failed"
	echo "\$ echo $PW | zfs load-key $SFS; zfs mount $SFS   (the source, to compare)"
	echo $PW | zfs load-key $SFS && zfs mount $SFS || die "can't mount the source $SFS"
	st "imported after the power cut"
	fail=
	tok=$(prop receive_resume_token $RFS)
	echo "  receive_resume_token of $RFS: ${tok:0:40}..."
	if [ -n "$tok" ] && [ "$tok" != - ]; then
		echo "\$ zfs send -t <token> | zfs receive -s -u $RFS   (resume the receive)"
		zfs send -t "$tok" | zfs receive -s -u $RFS || fail+="resumed receive failed; "
	else
		echo "  (no resume token: the receive starts again)"
		run zfs destroy -r $RFS 2>/dev/null
		echo "\$ zfs receive -u $RFS < /$S/stream"
		zfs receive -u $RFS </$S/stream || fail+="receive failed; "
	fi
	run zfs list -t snapshot $RFS@snap || fail+="no $RFS@snap; "
	echo "\$ echo $PW | zfs load-key $RFS"
	echo $PW | zfs load-key $RFS || fail+="load-key failed; "
	run zfs mount $RFS || fail+="mount failed; "
	run diff -r /$SFS /$RFS && echo "  identical: $(ls /$RFS | wc -l) files" || fail+="data differs; "
	run zfs unmount $RFS
	run zpool scrub -w $P || fail+="scrub failed; "
	st "the final state, after the scrub"
	s=$(zpool status -v $P)
	echo "$s" | awk -v p=$P '$1 == p { print $2; exit }' | grep -qx ONLINE || fail+="pool not ONLINE; "
	run zpool export $P
	run zpool export $S
	zr phase 0
	[ -n "$fail" ] && { result "RESULT ERROR: no panic, but after the reboot: ${fail%; }"; exit 2; }
	result "RESULT OK: no panic: the keyless write failed with EACCES and suspended the pool (again after each zpool clear); after a reboot the pool imported, the receive resumed and the data matches the source"
	exit 0
fi

zinject -c all >/dev/null 2>&1
zpool destroy -f $P 2>/dev/null; zpool destroy -f $S 2>/dev/null
zpool labelclear -f "$V0" 2>/dev/null; zpool labelclear -f "$V1" 2>/dev/null

echo; echo "## 1. the source: an encrypted dataset, a raw stream of its snapshot"
run zpool create -f -o cachefile=none -O compression=off $S "$V0" || die "zpool create $S failed"
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
echo "# steps 2-6 run up to $ROUNDS times, each on a new destination pool,"
echo "# until one hits.  Round 1 usually does."
for round in $(seq $ROUNDS); do
R="round $round/$ROUNDS"
echo; echo "################ $R ################"
echo; echo "## 2. ($R) the destination pool (failmode=wait)"
zpool destroy -f $P 2>/dev/null; zpool labelclear -f "$V1" 2>/dev/null
run zpool create -f -o cachefile=none -o failmode=wait -O compression=off $P "$V1" ||
    die "zpool create $P failed"
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
# (zr phase syncs every file system, so set it now, while the pools are
# healthy: if this round ends in the power cut, the demo resumes at step 7)
zr phase 1
kmsg0=$(dmesg | wc -l)
run zinject -d "$V1" -e io -T write $P
run zinject -d "$V1" -e nxio -T probe $P
touch $D/gate1
echo "  waiting for the pool to suspend..."
wait_state SUSPENDED 60
echo "  pool state (kstat): $(state)"
[ "$(state)" = SUSPENDED ] || die "the pool did not suspend"
kill -0 $rpid 2>/dev/null || die "the receive ended early: $(cat $D/recv.out)"
st "suspended (the disk failed)"

echo; echo "## 5. ($R) the disk is back: clear the pool and feed the rest of the stream"
run zinject -c all
run zpool clear $P
touch $D/gate2
st "after zpool clear"

echo; echo "## 6. ($R) waiting for the receive (up to 180 s), watching the kernel log and the pool state"
t0=$(date +%s) verify= susp=
while kill -0 $rpid 2>/dev/null && [ $(($(date +%s) - t0)) -lt 180 ]; do
	kmsg | grep -qE 'VERIFY|PANIC at' && { verify=1; break; }
	[ "$(state)" = SUSPENDED ] && { susp=1; break; }
	sleep 0.5
done
sleep 1
kmsg | grep -qE 'VERIFY|PANIC at' && verify=1
if [ -n "$verify" ]; then
	echo "  the kernel log, $(($(date +%s) - t0)) s after the clear:"
	kmsg | grep -E -A14 'VERIFY|PANIC at' | head -24 | sed 's/^/    /'
	kill -0 $rpid 2>/dev/null && echo "  zfs receive: still running (its txg can't sync)" ||
	    echo "  zfs receive: ended: $(cat $D/recv.out)"
	echo "  pool state (kstat): $(state)"
	st "after the VERIFY"
	echo "  (the sync thread is stuck in the panic: the pool can't sync or be exported)"
	result "RESULT BUG: a write without its key hit VERIFY0(spa_do_crypt_abd(...)) failed (13) in zio_encrypt after zpool clear ($R)"
	exit 1
fi
if [ -n "$susp" ]; then
	echo "  the pool suspended again $(($(date +%s) - t0)) s after the clear; no VERIFY in the kernel log"
	echo "  pool state (kstat): $(state)"
	echo "--- the dbgmsg (zio_encrypt failures):"
	grep 'zio_encrypt failed' /proc/spl/kstat/zfs/dbgmsg | tail -5 | sed 's/^/    /'
	grep -q 'zio_encrypt failed: error 13' /proc/spl/kstat/zfs/dbgmsg ||
	    die "suspended, but not by a zio_encrypt failure (EACCES)"
	echo "--- zpool events -v $P: data ereports with zio_err 0xd (EACCES)"
	zpool events -v $P | awk '/^[A-Z][a-z][a-z] /{c=""} /class = /{c=$3} /zio_err = 0xd/ && c ~ /data/ {n++} END {print "    " n+0 " ereport.fs.zfs.data events with zio_err = 0xd"}'
	st "suspended: the write that can't be encrypted failed"

	echo; echo "## 6b. ($R) zpool clear again: the same write fails the same way"
	kmsg1=$(dmesg | wc -l)
	bg_out $D/clear.out 30 zpool clear $P; echo "\$ zpool clear $P"; sed 's/^/    /' $D/clear.out
	sleep 2
	wait_state SUSPENDED 30
	echo "  pool state (kstat): $(state)"
	[ "$(state)" = SUSPENDED ] || die "the pool didn't suspend again after the second clear"
	dmesg | tail -n +$((kmsg1 + 1)) | grep -qE 'VERIFY|PANIC at' && die "a VERIFY after the second clear"
	echo "  zio_encrypt failures in the dbgmsg so far: $(grep -c 'zio_encrypt failed' /proc/spl/kstat/zfs/dbgmsg)"
	st "suspended again after the second zpool clear"
	echo "\$ echo $PW | zfs load-key $RFS    (refused while the pool is suspended)"
	bg_out $D/lk.out 15 sh -c "echo $PW | zfs load-key $RFS"; sed 's/^/    /' $D/lk.out
	echo "  zfs receive: $(kill -0 $rpid 2>/dev/null && echo 'still running (its txg cannot sync)' || echo "ended: $(cat $D/recv.out)")"

	echo; echo "## 7. ($R) the way out is a reboot: the host cuts the power now"
	zr trigger powercut
	die "still running after the power cut"
fi
if kill -0 $rpid 2>/dev/null; then
	st "receive still running after 180 s"
	die "the receive didn't finish in 180 s (no VERIFY, no suspend; $R)"
fi
wait $rpid; rc=$?
echo "  zfs receive finished: rc=$rc $(cat $D/recv.out)"
st "receive finished"
zr phase 0
echo "  $R missed the trigger (no block of dnodes was hit): next round"
done
zpool export $P 2>/dev/null; zpool export $S 2>/dev/null
die "the trigger missed in all $ROUNDS rounds"
