#!/bin/bash
# demo.sh -- bug #277: `zpool status -v` during a raw receive whose key is
# loaded leaks a hold on the received dataset, and `zpool export` then hangs
# forever (spa_evicting_os_wait()).
#
# `zpool status -v` turns each logged error into a path
# (ZFS_IOC_OBJ_TO_PATH -> zfs_obj_to_path() -> zfs_grab_sa_handle() ->
# sa_handle_get()).  While a dataset is being raw received its blocks stay
# raw, so with the key loaded the bonus buffer read there is still
# ciphertext and sa_build_index() fails ("Buffer Header ... != SA_MAGIC" in
# the debug log, EIO).  sa_handle_get() returned that error without freeing
# the new SA handle or releasing its hold on the bonus buffer: one leaked
# hold per failed lookup.  The objset can then never be evicted, so
# `zpool export` waits forever.  The fix frees the handle and releases the
# bonus buffer when sa_build_index() fails.  No pool suspension is involved.
#
#   1. a source pool: an encrypted dataset (200 files of 8 KiB, a 16 MiB
#      file), snapshot, a raw stream (zfs send -w) saved in a file
#   2. the destination pool; receive all but the last 8 MiB of the stream
#      (zfs receive -s -u), so the receive stays open
#   3. a logged error in the first small file: zinject a checksum error on
#      its block, scrub, zinject -c all ("Permanent errors")
#   4. load the received dataset's key (allowed during a receive), then
#      `zpool status -v` three times: each resolves that error's path
#   5. the rest of the stream: the receive finishes
#   6. zpool export, given 60 s
#   repro (BRANCH~3: master + the #277 test): the export is still waiting
#      after 60 s, in spa_evicting_os_wait()
#      -> "RESULT BUG: zpool export hung after zpool status -v during the raw receive"
#   fixed (BRANCH~2: the #277 fix): the export finishes at once
#   7. (fixed) import, load the key, mount, compare with the source; scrub
#      -> "RESULT OK: zpool export finished after zpool status -v during the raw receive"
# Pools demo277src on $DEMO_DISKS[0] and demo277 on $DEMO_DISKS[1] (or files
# in /var/tmp/demo277).  Exported at the end (not on the repro: the export
# never finishes).  About 1 minute (2 on the repro).
set -u
P=demo277 S=demo277src D=/var/tmp/demo277 PW=password W=60
RFS=$P/recv SFS=$S/enc
mkdir -p $D
read -r V0 V1 _ <<<"${DEMO_DISKS:-}"
if [ -z "${V1:-}" ]; then
	truncate -s 1G $D/src0 $D/dst0; V0=$D/src0 V1=$D/dst0
fi

run() { echo "\$ $*"; "$@"; }
st() {	# [label]: the destination pool's state after a step
	echo "--- zpool status -v $P${1:+   ($1)}"
	zpool status -v $P 2>&1 | sed 's/^/    /'
}
prop() { zfs get -H -o value "$1" "$2" 2>/dev/null; }
result() {	# the RESULT line, also through the kernel's console
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}
die() { result "RESULT ERROR: $*"; exit 2; }
samagic() { grep -c 'SA_MAGIC' /proc/spl/kstat/zfs/dbgmsg 2>/dev/null; }

echo "# $(uname -sr); build ${DEMO_BUILD:-?}: $(cat /sys/module/zfs/version)"
echo "# source vdev $V0, destination vdev $V1"
zinject -c all >/dev/null 2>&1
zpool destroy -f $P 2>/dev/null; zpool destroy -f $S 2>/dev/null
zpool labelclear -f "$V0" 2>/dev/null; zpool labelclear -f "$V1" 2>/dev/null
mkdir -p /etc/zfs
echo 0 >/proc/spl/kstat/zfs/dbgmsg 2>/dev/null

echo; echo "## 1. the source: an encrypted dataset, a raw stream of its snapshot"
run zpool create -f -O compression=off $S "$V0" || die "zpool create $S failed"
echo "\$ echo $PW | zfs create -o encryption=on -o keyformat=passphrase -o keylocation=prompt $SFS"
echo $PW | zfs create -o encryption=on -o keyformat=passphrase -o keylocation=prompt $SFS ||
    die "zfs create $SFS failed"
echo "\$ (200 files f1..f200 of 8 KiB)"
for i in $(seq 1 200); do
	dd if=/dev/urandom of=/$SFS/f$i bs=8k count=1 status=none || die "can't create /$SFS/f$i"
done
run dd if=/dev/urandom of=/$SFS/big bs=1M count=16 status=none
# the stream sends objects in order: the lowest-numbered small file is
# received long before the large file's last blocks
obj=$(ls -i /$SFS/ | awk '$2 ~ /^f/ { print $1 }' | sort -n | head -1)
fname=$(ls -i /$SFS/ | awk -v o=$obj '$1 == o { print $2 }')
run zfs snapshot $SFS@snap
echo "\$ zfs send -w $SFS@snap > /$S/stream"
zfs send -w $SFS@snap >/$S/stream || die "zfs send -w failed"
sz=$(stat -c %s /$S/stream) part1=$(($(stat -c %s /$S/stream) - 8 * 1048576))
echo "  raw stream: $sz bytes; fed as $part1 bytes, then (later) the last 8 MiB"
echo "  the file to log an error in: $fname, object $obj"

echo; echo "## 2. the destination pool; receive all but the last 8 MiB"
run zpool create -f -O compression=off $P "$V1" || die "zpool create $P failed"
rm -f $D/gate $D/recv.out
echo "\$ (stream in 2 parts) | zfs receive -s -u $RFS &"
{
	head -c $part1 /$S/stream
	while [ ! -f $D/gate ]; do sleep 0.1; done
	tail -c +$((part1 + 1)) /$S/stream
} 2>/dev/null | zfs receive -s -u $RFS >$D/recv.out 2>&1 &
rpid=$!
for _ in $(seq 60); do zfs list $RFS >/dev/null 2>&1 && break; sleep 1; done
zfs list $RFS >/dev/null 2>&1 || die "the receive didn't create $RFS"
ok=
for _ in $(seq 60); do
	zpool sync $P
	zdb -dd $RFS $obj 2>/dev/null | grep -q "ZFS plain file" && { ok=1; break; }
	sleep 1
done
[ -n "$ok" ] || die "object $obj wasn't received"
echo "  object $obj ($fname) is received and on disk; the receive waits for the rest"
echo "  keystatus of $RFS: $(prop keystatus $RFS)"
st "receiving"

echo; echo "## 3. a logged error in $fname (a checksum error injected on its read)"
objset=$(prop objsetid $RFS)
run zinject -b "$(printf "%x:%x:0:0" $objset $obj)" -e checksum -a $P
run zpool scrub -w $P
run zinject -c all
st "the scrub logged the error (the disk itself is intact)"
zpool status -v $P | grep -q 'Permanent errors' || die "no error was logged"

echo; echo "## 4. load the key while the receive runs; zpool status -v three times"
echo "\$ echo $PW | zfs load-key $RFS"
echo $PW | zfs load-key $RFS || die "zfs load-key during the receive failed"
echo "  keystatus of $RFS: $(prop keystatus $RFS)"
for i in 1 2 3; do
	echo "\$ zpool status -v $P    (run $i)"
	timeout 30 zpool status -v $P >$D/status.out 2>&1
done
st "run 3, as shown"
echo "  failed SA lookups in the debug log (\"Buffer Header ... != SA_MAGIC\", the bonus is still ciphertext): $(samagic)"
grep -m1 'SA_MAGIC' /proc/spl/kstat/zfs/dbgmsg 2>/dev/null | sed 's/^/    /'
kill -0 $rpid 2>/dev/null || die "the receive ended early: $(cat $D/recv.out)"

echo; echo "## 5. the rest of the stream"
touch $D/gate
wait $rpid; rc=$?
echo "  zfs receive finished: rc=$rc $(cat $D/recv.out)"
[ $rc = 0 ] || die "the receive failed (rc $rc)"
run zfs list -t snapshot $RFS@snap || die "no $RFS@snap"
st "received"

echo; echo "## 6. zpool export $P    (given $W s)"
zpool export $P >$D/export.out 2>&1 &
epid=$!
t0=$(date +%s)
for _ in $(seq $((W * 5))); do kill -0 $epid 2>/dev/null || break; sleep 0.2; done
if kill -0 $epid 2>/dev/null; then
	echo "  zpool export: STILL WAITING after $W s (process state $(awk '{ print $3 }' /proc/$epid/stat))"
	echo "  its kernel stack:"
	sed 's/^/    /' /proc/$epid/stack 2>/dev/null | head -12
	echo "  (any zpool command now waits behind it for the pool namespace lock;"
	echo "   the received dataset's objset can never be evicted: the pool can't be"
	echo "   exported until a reboot)"
	echo "  zpool list (from the kstat, without the namespace lock): state $(cat /proc/spl/kstat/zfs/$P/state 2>/dev/null)"
	result "RESULT BUG: zpool export hung after zpool status -v during the raw receive (still waiting after $W s in spa_evicting_os_wait; $(samagic) failed SA lookups leaked their holds)"
	exit 1
fi
wait $epid; erc=$?
echo "  zpool export: rc=$erc after $(($(date +%s) - t0)) s $(cat $D/export.out)"
[ $erc = 0 ] || die "zpool export failed (rc $erc)"

echo; echo "## 7. the received data after the export"
fail=
run zpool import -d "$(dirname "$V1")" $P || die "import failed"
echo "\$ echo $PW | zfs load-key $RFS"
echo $PW | zfs load-key $RFS || fail+="load-key failed; "
run zfs mount $RFS || fail+="mount failed; "
run diff -r /$SFS /$RFS && echo "  identical: $(ls /$RFS | wc -l) files" || fail+="data differs; "
run zfs unmount $RFS
echo "\$ zpool scrub -w $P; zpool scrub -w $P    (two clean scrubs drop the injected error from the log)"
zpool scrub -w $P && zpool scrub -w $P || fail+="scrub failed; "
st "the final state"
s=$(zpool status -v $P)
echo "$s" | awk -v p=$P '$1 == p { print $2; exit }' | grep -qx ONLINE || fail+="pool not ONLINE; "
echo "$s" | grep -q 'errors: No known data errors' || fail+="data errors; "
run zpool export $P || fail+="second export failed; "
run zpool export $S
if [ -n "$fail" ]; then
	result "RESULT ERROR: the export finished, but: ${fail%; }"
	exit 2
fi
result "RESULT OK: zpool export finished after zpool status -v during the raw receive; data identical after the import, scrub clean"
exit 0
