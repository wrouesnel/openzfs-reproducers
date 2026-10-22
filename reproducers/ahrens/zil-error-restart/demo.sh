#!/bin/bash
# demo.sh -- openzfs/zfs #19481 / #19485 (@ahrens): after a ZIL log block
# (lwb) fails to write, a later fsync() returns success, yet the data is lost
# in a crash before the next txg syncs.
#
# Master only makes an lwb depend on the previous one while that one is still
# in flight.  An lwb issued after the failed one is done has no dependency on
# it, completes cleanly, and its fsync() returns.  On disk the log chain ends
# at the failed lwb (zil_parse() can't read it), so until the txg that frees
# it syncs, a crash loses everything after it.
#
# The same steps as the PRs' ZTS test slog/slog_replay_lwb_error:
#   1. pool with a slog; main vdevs slowed (zinject -D 3000:64) so a txg
#      sync takes many seconds
#   2. slog writes fail (io-prefail): write A + fsync; its lwb fails and the
#      fsync falls back to txg_wait_synced()
#   3. slog writes work again: write B + fsync, wait 1 s
#   4. "crash": every write to the pool fails (io-prefail), copy the vdevs
#   5. import the copy: if B's fsync returned before the crash, B must be there
# The zil kstats after each step show how each fix handles B: #19481 counts
# B's fallback in zil_commit_error_count, #19485 bypasses the ZIL (it is
# restarting) and counts it in zil_commit_crash_count.
#
# This demo is shared by reproducers/ahrens/zil-error-hole (#19481) and
# reproducers/ahrens/zil-error-restart (#19485): both fix the same bug.
# Builds:
#   repro: master (the PRs' base)  -> B's fsync returns, B is gone after
#          the import, "RESULT BUG"
#   fixed: a PR head -> B's fsync waits for the txg (or B survives),
#          "RESULT OK"
set -u
P=lwberr D=/var/tmp/lwberr D2=/var/tmp/lwberr-crash
K=/proc/spl/kstat/zfs/zil
V="$D/a $D/b $D/c" S=$D/d
show() { echo; echo "----- $*"; }
run() { echo "# $*"; "$@"; }
status() { echo "# zpool status -v $P"; zpool status -v $P; }
kst() { awk -v k="$1" '$1 == k { print $3 }' $K; }
kstats() {
	local k out=
	for k in zil_commit_count zil_commit_writer_count zil_commit_error_count \
	    zil_commit_stall_count zil_commit_suspend_count zil_commit_crash_count; do
		grep -q "^$k " $K && out="$out ${k#zil_commit_}=$(kst $k)"
	done
	echo "zil kstats:$out"
}
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f s", b - a }'; }

zinject -c all >/dev/null 2>&1
zpool destroy -f $P 2>/dev/null
rm -rf $D $D2; mkdir -p $D $D2
truncate -s 256M $V $S
dd if=/dev/urandom of=$D/src_a bs=128k count=1 status=none
dd if=/dev/urandom of=$D/src_b bs=128k count=1 status=none
echo "build: $(cat /etc/zfshunt-build 2>/dev/null | head -1)"
echo "pool $P: file vdevs $V, slog $S (on tmpfs)"

show "1. create the pool with a slog; slow the main vdevs"
run zpool create -f -o cachefile=none $P $V log $S ||
	{ echo "RESULT ERROR: could not create pool $P"; exit 2; }
run zfs create -o compression=off -o recordsize=128k $P/fs
M=/$P/fs
echo "# dd ... of=$M/sync conv=fsync   (gives the dataset a ZIL header)"
dd if=/dev/zero of=$M/sync conv=fsync bs=128k count=1 status=none
for v in $V; do
	echo "# zinject -d $v -D 3000:64 -T write $P"
	zinject -d $v -D 3000:64 -T write $P >/dev/null
done
status
kstats

show "2. slog writes fail; write file A and fsync it"
e0=$(kst zil_commit_error_count)
echo "# zinject -d $S -e io-prefail -T write $P"
h=$(zinject -d $S -e io-prefail -T write $P | sed -n 's/^Added handler \([0-9]*\).*/\1/p')
[ -n "$h" ] || { zinject -c all >/dev/null; echo "RESULT ERROR: zinject -e io-prefail failed"; exit 2; }
ta=$(now)
echo "# dd if=src_a of=$M/a bs=128k count=1 conv=fsync &"
( dd if=$D/src_a of=$M/a bs=128k count=1 conv=fsync status=none &&
	echo "  (fsync of A returned after $(since $ta))" ) &
for _ in $(seq 50); do
	[ "$(kst zil_commit_error_count)" -gt "$e0" ] && break
	sleep 0.1
done
if [ "$(kst zil_commit_error_count)" -le "$e0" ]; then
	zinject -c all >/dev/null; zpool clear $P; wait
	echo "RESULT ERROR: A's log block did not fail (zil_commit_error_count unchanged)"
	exit 2
fi
echo "A's lwb failed: zil_commit_error_count $e0 -> $(kst zil_commit_error_count);" \
    "A's fsync now waits for the (slow) txg sync"
run zinject -c $h >/dev/null
status
echo "(the slog's write errors and the 'Permanent errors' line are the failed log"
echo " block itself, in the error log; master shows the same.  No file data is damaged.)"
kstats

show "3. slog writes work again; write file B and fsync it, wait 1 s"
tb=$(now)
echo "# dd if=src_b of=$M/b bs=128k count=1 conv=fsync &"
( dd if=$D/src_b of=$M/b bs=128k count=1 conv=fsync status=none &&
	touch $D/b_done && echo "  (fsync of B returned after $(since $tb))" ) &
sleep 1
acked=no
[ -f $D/b_done ] && acked=yes
echo "fsync of B returned within 1 s: $acked"
kstats

show "4. crash: every write to the pool fails from now on; copy the vdevs"
for v in $V $S; do
	echo "# zinject -d $v -e io-prefail -T write $P"
	zinject -d $v -e io-prefail -T write $P >/dev/null
done
run cp --sparse=always $V $S $D2/
echo "crash image: $(ls $D2 | tr '\n' ' ')"
echo "(the txg holding A and B had not synced: only the ZIL can bring B back)"
run zinject -c all >/dev/null
run zpool clear $P
echo "waiting for the fsyncs to finish ..."
wait
run zpool destroy -f $P

show "5. import the crash image (replays the ZIL)"
run zpool import -o cachefile=none -d $D2 $P ||
	{ echo "RESULT ERROR: could not import the crash image"; exit 2; }
status
echo "# ls -l $M"
ls -l $M
b_ok=no
if [ -f $M/b ] && cmp -s $D/src_b $M/b; then b_ok=yes; fi
if [ $acked = yes ]; then
	echo "fsync of B returned before the crash; file B present with that data: $b_ok"
else
	echo "fsync of B had NOT returned before the crash; file B present: $b_ok" \
	    "(either way is correct)"
fi
if [ -f $M/a ] && cmp -s $D/src_a $M/a; then
	echo "file A present (its fsync had not returned; either way is correct)"
else
	echo "file A missing (its fsync had not returned; either way is correct)"
fi

show "end"
run zpool export $P
kstats
if [ $acked = yes ] && [ $b_ok = no ]; then
	echo "RESULT BUG: fsync of B returned before the crash, but B is lost after the import"
	exit 1
fi
if [ $acked = yes ]; then
	echo "RESULT OK: fsync of B returned before the crash and B survived it"
else
	echo "RESULT OK: fsync of B waited for the txg sync, so nothing acknowledged was lost"
fi
