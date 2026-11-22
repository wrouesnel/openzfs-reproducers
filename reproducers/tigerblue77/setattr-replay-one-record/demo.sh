#!/bin/bash
# demo.sh -- openzfs/zfs#19985 (@tigerblue77): since #19706 (b306edf42f),
# replaying a TX_SETATTR record that carries ATTR_SIZE marks the record
# replayed twice: in zfs_freesp()'s transaction (its TX_TRUNCATE logging
# calls zil_replaying()) and again in zfs_setattr()'s.  If the first txg
# syncs and the system stops before the second, the next replay skips the
# record: the size is applied, the mode, owner and times it carries are lost
# (mtime = the time of the first replay).  On a debug build the second
# marking of the same record in a later txg also trips
# VERIFY(zh->zh_replay_seq < *replayed_seq) in zil_sync().
#
# Linux since #19706 never writes such a record (it logs TX_TRUNCATE); Linux
# before it does (every release), and FreeBSD does.  So the log is written
# by a module from before #19706, and replayed by this image's build.  Both
# images run exactly the same steps (the payload, /demo/payload/TARGET/):
#
#  1. WRITE (common: openzfs/zfs 9ac6648a22 = b306edf42f^, unchanged):
#     a pool on a file, frozen; `truncate -s 4096 a` as root (record: size,
#     mtime) and, as the owner (uid 1000), `truncate -s 8192 b` on a 4755
#     file (the kernel drops set-uid: record: size, mode 0755, mtime);
#     fsync both, record their state, export.  zdb shows the two records.
#  2. REPLAY (repro|fixed: this image's own commit + a test-only hook,
#     hook.diff): import a copy; the hook pauses the replay right after each
#     record's size change has synced, and the demo copies the pool's disk
#     at each pause: crash image N = a power cut after record N's size
#     change, before the rest of the record is on disk.  Then a power cut.
#  3. CHECK (after the reboot: this image's own build, no hook): import each
#     crash image, and compare a and b with the state fsynced in step 1.
#
# RESULT BUG if a crash image comes back without the fsynced mode, owner or
# mtime; RESULT OK if every crash image matches.
set -u
. /etc/demo-env 2>/dev/null
P=r85 M=/var/tmp/r85
PRM=/sys/module/zfs/parameters/zfs_hunt_replay_stop_ms
F=/demo/fsyncf
x() { echo "# $*"; "$@" 2>&1; }
say() { echo; echo "=== $*"; }
# the pool mounts under /run (tmpfs): an import writes nothing on the root disk
st() { (cd /run/$P/fs && for f in a b; do stat -c "%n mode=%a uid=%u size=%s mtime=%.9Y" $f; done); }
status() { echo "# zpool status -v $P"; zpool status -v $P 2>&1 | sed 's/^/    /'; }
# the payload for the running kernel
PL=
for d in /demo/payload/*/; do
	[ "$(cat "$d/common/kernel.txt" 2>/dev/null)" = "$(uname -r)" ] && PL=${d%/}
done
[ -n "$PL" ] || { echo "RESULT ERROR: no payload for kernel $(uname -r) on /demo/payload"; exit 2; }
# swap_to DIR: unload zfs and load DIR's modules
swap_to() {
	zpool export -a 2>/dev/null
	rmmod zfs && rmmod spl || { echo "RESULT ERROR: could not unload the modules"; exit 2; }
	insmod "$1/modules/spl.ko" && insmod "$1/modules/zfs.ko" || { echo "RESULT ERROR: insmod $1 failed"; exit 2; }
	grep -q "srcversion $(cat /sys/module/zfs/srcversion)" "$1/build.txt" ||
	    { echo "RESULT ERROR: the loaded zfs.ko is not $1's"; exit 2; }
	echo "# loaded $1: $(head -1 "$1/build.txt") (zfs $(cat /sys/module/zfs/version))"
}
# imp DIR [SECONDS]: import the pool from DIR, give up after SECONDS
imp() {
	zpool import -f -d "$1" $P & local ip=$! i
	for ((i = 0; i < ${2:-60} * 5; i++)); do kill -0 $ip 2>/dev/null || { wait $ip; return; }; sleep 0.2; done
	echo "*** zpool import -d $1 did not return in ${2:-60} s"; return 124
}

phase=$(zr phase)
[ "$phase" = 1 ] || phase=0
if [ $phase = 0 ]; then
	echo "=== openzfs/zfs#19985: a TX_SETATTR with ATTR_SIZE is marked replayed twice ($DEMO_BUILD build)"
	echo "    image build: $(head -1 /etc/zfshunt-build)"
	echo "    writer:      $(head -1 "$PL/common/build.txt")"
	echo "    replayer:    $(head -1 "$PL/$DEMO_BUILD/build.txt")"
	echo "    the hook (the whole change, $PL/$DEMO_BUILD/hook.diff):"
	sed -n '/^@@ -2/,$p' "$PL/$DEMO_BUILD/hook.diff" | sed 's/^/      /'
	umount $M 2>/dev/null; mkdir -p $M
	mke2fs -q -F -j -b 4096 -N 8192 -m 0 "$DEMO_DISK" >/dev/null 2>&1 && mount -t ext4 "$DEMO_DISK" $M ||
	    { echo "RESULT ERROR: no file system on $DEMO_DISK"; exit 2; }
	mkdir -p $M/pristine $M/work

	say "1. WRITE with the module from before #19706"
	swap_to "$PL/common"
	truncate -s 256M $M/pristine/v.img
	x zpool create -o cachefile=none -O mountpoint=/run/$P $P $M/pristine/v.img && x zfs create $P/fs || { echo "RESULT ERROR: zpool create"; exit 2; }
	cd /run/$P/fs
	dd if=/dev/zero of=seed bs=4k count=1 conv=fsync status=none
	dd if=/dev/urandom of=a bs=1M count=1 status=none
	dd if=/dev/urandom of=b bs=1M count=1 status=none
	chown 1000:1000 b; chmod 4755 b; chmod 0644 a
	touch -d '2001-01-01 00:00:00' a b
	cd /
	x zpool sync $P
	x zpool freeze $P
	sleep 1.2
	x truncate -s 4096 /run/$P/fs/a
	$F /run/$P/fs/a
	sleep 1.2
	x /demo/bin/setpriv --reuid=1000 --regid=1000 --clear-groups truncate -s 8192 /run/$P/fs/b
	$F /run/$P/fs/b
	echo "# the state fsynced before the crash:"
	st | tee $M/live.txt | sed 's/^/    /'
	status
	x zpool export $P
	echo "# the ZIL (zdb -ivv $P/fs): the records the replay must apply"
	zdb -e -p $M/pristine -ivv $P/fs 2>&1 | grep -E -A3 'TX_(SETATTR|TRUNCATE) +len' | tee $M/zil.txt | sed 's/^/    /'
	ns=$(grep -cE 'TX_SETATTR +len' $M/zil.txt) nt=$(grep -cE 'TX_TRUNCATE +len' $M/zil.txt)
	[ "$ns" = 2 ] && [ "$nt" = 0 ] ||
	    { echo "RESULT ERROR: expected 2 TX_SETATTR and no TX_TRUNCATE records, got $ns and $nt"; exit 2; }

	say "2. REPLAY with this image's build + the hook, copying the disk at each pause"
	swap_to "$PL/$DEMO_BUILD"
	[ -w $PRM ] || { echo "RESULT ERROR: no $PRM"; exit 2; }
	cp --sparse=always $M/pristine/v.img $M/work/v.img
	$F $M/live.txt $M/zil.txt
	zr phase 1	# (now, while zfs is healthy: zr syncs every file system)
	echo 4000 >$PRM
	n0=$(dmesg | grep -c 'zfs-hunt: replay window')
	echo "# zpool import -d $M/work $P   (replays the ZIL)"
	zpool import -d $M/work $P & ip=$!
	n=0 t=0 rc=
	while :; do
		c=$(( $(dmesg | grep -c 'zfs-hunt: replay window') - n0 ))
		if [ $c -gt $n ]; then
			n=$c; mkdir -p $M/crash$n
			cp --sparse=always $M/work/v.img $M/crash$n/v.img; $F $M/crash$n/v.img
			echo "# pause $n: $(dmesg | grep 'zfs-hunt: replay window' | tail -1 | sed 's/^\[[^]]*\] //') -> crash image $n"
		fi
		kill -0 $ip 2>/dev/null || { wait $ip; rc=$?; break; }
		dmesg | grep -qE 'PANIC at|VERIFY[0-9]*\(' && { sleep 2; rc=panic; break; }
		t=$((t + 1)); [ $t -gt 600 ] && { rc=timeout; break; }
		sleep 0.2
	done
	{
		echo "pauses=$n"
		case $rc in
		panic) echo "replay=PANIC"; dmesg | grep -E -A12 'VERIFY[0-9]*\(|PANIC at' | sed 's/^\[[^]]*\] //' | grep -v '^Kernel panic' | head -16 ;;
		timeout) echo "replay=TIMEOUT" ;;
		*) echo "replay=rc$rc"; st | sed 's/^/after: /' ;;
		esac
	} >$M/replay.txt
	$F $M/replay.txt
	if [ "$rc" = panic ]; then
		echo "# the replay hit an assertion (debug build):"
		sed -n '3,$p' $M/replay.txt | sed 's/^/    /'
	else
		echo "# zpool import: ${rc}"; [ "$rc" = 0 ] && { status; echo "# after the whole replay:"; st | sed 's/^/    /'; }
	fi
	# the run disk and the root disk to stable storage (syncfs of each: a
	# plain sync could wait on the wedged pool)
	sync -f $M/live.txt; sync -f /root
	echo "# power cut (the crash images are on $DEMO_DISK)"
	zr trigger powercut
	sleep 600; echo "RESULT ERROR: the power cut did not happen"; exit 2
fi

# ---- after the power cut: this image's own build, no hook -------------------
echo "=== openzfs/zfs#19985, after the power cut ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build))"
umount $M 2>/dev/null; mkdir -p $M
mount -t ext4 "$DEMO_DISK" $M || { echo "RESULT ERROR: cannot mount $DEMO_DISK"; exit 2; }
zr phase 0
say "3. CHECK: import each crash image on this image's own build (no hook)"
echo "# fsynced before the crash (step 1):"; sed 's/^/    /' $M/live.txt
echo "# the ZIL records:"; sed 's/^/    /' $M/zil.txt
np=$(sed -n 's/^pauses=//p' $M/replay.txt) rp=$(sed -n 's/^replay=//p' $M/replay.txt)
echo "# step 2: $np pause(s); the replay with the hook: $rp"
[ "$rp" = PANIC ] && sed -n '3,$p' $M/replay.txt | sed 's/^/    /'
bad= ok=0 tot=0 ctl=
for d in $M/crash*; do
	[ -f $d/v.img ] || continue
	c=${d##*/} tot=$((tot + 1))
	echo; echo "--- crash image ${c#crash}: a power cut after record ${c#crash}'s size change synced"
	echo "# zpool import -d $d $P"
	imp $d 90 || { bad="$bad $c(import failed)"; continue; }
	status
	st >$M/$c.txt
	for f in a b; do grep -q "^$f " $M/$c.txt || { echo "    $f: not readable"; bad="$bad $c:$f(missing)"; }; done
	while read -r l; do
		f=${l%% *}
		if grep -qxF "$l" $M/live.txt; then echo "    $l   (as fsynced)"
		else echo "    $l   DIFFERS, fsynced: $(grep "^$f " $M/live.txt | cut -d' ' -f2-)"; bad="$bad $c:$f"; fi
	done <$M/$c.txt
	cmp -s $M/live.txt $M/$c.txt && ok=$((ok + 1))
	x zpool export $P
done
echo; echo "--- control: the log replayed without a stop (a fresh copy of step 1's disk)"
rm -f $M/work/v.img; cp --sparse=always $M/pristine/v.img $M/work/v.img
if imp $M/work 90; then
	status; st | sed 's/^/    /'
	st | cmp -s - $M/live.txt && echo "# control: as fsynced" || { echo "# control: DIFFERS from the fsynced state"; ctl=differs; }
	x zpool export $P
fi
echo
[ "$rp" = PANIC ] && pn="; the replay with the test-only hook also hit VERIFY(zh->zh_replay_seq < *replayed_seq) in zil_sync() (debug build)" || pn=
if [ "$tot" = 0 ]; then
	echo "RESULT ERROR: no crash images (the hook never paused the replay: $rp)"; exit 2
elif [ -n "$ctl" ]; then
	echo "RESULT ERROR: the uninterrupted replay (control) does not match the fsynced state either"; exit 2
elif [ -n "$bad" ]; then
	echo "RESULT BUG: $((tot - ok)) of $tot crash images lost the fsynced attributes of a TX_SETATTR record:$bad (the record was skipped on the second replay)$pn"
elif [ "$rp" = PANIC ]; then
	echo "RESULT BUG: every crash image matches, but the replay hit VERIFY(zh->zh_replay_seq < *replayed_seq) in zil_sync() (debug build)"
else
	echo "RESULT OK: all $tot crash images replayed to the fsynced mode, owner, size and mtime"
fi
