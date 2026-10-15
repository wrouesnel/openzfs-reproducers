#!/bin/bash
# demo.sh -- bug #32 (openzfs #16988, PR #19306): exporting a pool while
# `zfs recv` with properties runs into it.  What must happen, case by case:
#
#   1  full replication receive, held in the receive ioctl where it marks the
#      new file system as having received properties:
#        zpool export -f   fails, "pool is busy" (the receive holds it)
#        zfs recv          exit 0, properties received
#   2  full replication receive into POOL/fs2, held where ZFS_IOC_SET_PROP (a
#      second ioctl, issued by libzfs after the receive ioctl) marks the last
#      snapshot, @1:
#        zpool export -f   succeeds (nothing holds the pool between ioctls)
#        zfs recv          exit 1, "cannot receive properties on POOL/fs2@1"
#                          (with only the kernel fix: exit 0, @1's property
#                          silently missing)
#        zpool import      @1 there without its received property
#        incremental recv  sets it (and @2's)
#   3  incremental replication receive, held where ZFS_IOC_SET_PROP marks @2:
#        zpool export -f   succeeds (nothing holds the pool between ioctls)
#        zfs recv          exit 1, "cannot receive properties on POOL/fs@2"
#        zpool import      @2 is there without its received property,
#                          nothing held, no resume token
#        same zfs recv     exit 0, @2's property received
#   4  truncated incremental receive with properties into a file system that
#      never received any (its local properties are cleared first, as for
#      every first receive of properties), held on the error path where it
#      clears the mark again:
#        zpool export -f   fails, "pool is busy"
#        zfs recv          exit 1 (the truncated stream), no warning
#                          "failed to restore original properties"
#        state             test:local=orig (local) is back
#        complete zfs recv exit 0
#
# Builds (vm/demo-vm.sh 32 LABEL): both carry the test-only tunable
# zfs_recv_hasrecvd_suspend that holds the receive at those points.
#   bug  test commit on master: case 2 (and 3) panics the kernel
#        (Linux: "PANIC at dsl_prop.c:...:dsl_prop_set_hasrecvd_impl()", the
#        zfs recv hangs) -> RESULT BUG.  `demo.sh 4` runs case 4 alone:
#        the same panic on the error path.
#   fix  every line above holds -> RESULT OK
# Usage: /demo/demo.sh [CASE...]   (default: 1 2 3 4; about 15 s)
# Pools demo32src (a file) and demo32 (the run disk $DEMO_DISK, or a file);
# exported at the end.
set -u
cases=${*:-1 2 3 4}
P=demo32 S=demo32src D=/var/tmp/demo32
if [ "$(uname)" = FreeBSD ]; then
	tun() { sysctl -q vfs.zfs.recv.hasrecvd_suspend="$1" >/dev/null; }
	dbg() { sysctl -n kstat.zfs.misc.dbgmsg; }
	panicked() { false; }	# FreeBSD panics the whole kernel
else
	tun() { echo "$1" >/sys/module/zfs/parameters/zfs_recv_hasrecvd_suspend; }
	dbg() { cat /proc/spl/kstat/zfs/dbgmsg; }
	panicked() { dmesg | grep -q 'PANIC at dsl_prop.c'; }
fi
if panicked; then
	echo "this boot already hit the panic; power off and boot the demo again"; exit 1
fi
[ -w /sys/module/zfs/parameters/zfs_recv_hasrecvd_suspend ] || [ "$(uname)" = FreeBSD ] ||
    { echo "RESULT ERROR: this build has no zfs_recv_hasrecvd_suspend"; exit 2; }
echo "### openzfs $(cat /sys/module/zfs/version 2>/dev/null || sysctl -n vfs.zfs.version.module), cases: $cases"

bad=0
fail() { echo "  !! $*"; bad=$((bad + 1)); }
ok() { echo "  ok $*"; }
gen=0
hold_next() { gen=$((gen + 1)); tun $gen; }
resume() { gen=0; tun 0; }
holds=0
hold_at() {	# hold_at DATASET: release holds until the receive is held on DATASET
	local i h n
	for i in $(seq 200); do
		h=$(dbg | sed -n "s/.*hasrecvd suspended on \($P[^ ]*\)\$/\1/p")
		n=$(echo "$h" | grep -c .)
		if [ "$n" -gt "$holds" ]; then
			holds=$n
			[ "$(echo "$h" | tail -1)" = "$1" ] && { echo "  .. held on $1"; return 0; }
			echo "  .. held on $(echo "$h" | tail -1), released"
			hold_next; continue
		fi
		kill -0 $rpid 2>/dev/null || break
		sleep 0.1
	done
	echo "RESULT ERROR: zfs recv never held on $1: $(cat $D/out)"; resume; exit 2
}
recv_bg() {	# recv_bg STREAM DATASET
	echo "  # zfs recv -u $2 < ${1##*/} &"
	zfs recv -u "$2" <"$1" >$D/out 2>&1 &
	rpid=$!
}
recv_wait() {	# sets rc; detects the panic (the recv never returns)
	local i
	for i in $(seq 100); do
		kill -0 $rpid 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 $rpid 2>/dev/null; then
		if panicked; then
			dmesg | grep -A12 'PANIC at dsl_prop.c' | grep -E 'PANIC|VERIFY|dsl_prop|zfs_ioc|zfsdev' | sed 's/^/  KERNEL: /'
			echo "RESULT BUG: kernel PANIC in dsl_prop_set_hasrecvd_impl() (case $c); zfs recv hangs"
			exit 1
		fi
		echo "RESULT ERROR: zfs recv still running 10 s after resume"; exit 2
	fi
	wait $rpid; rc=$?
	echo "  zfs recv exit $rc"
	sed 's/^/    | /' $D/out
}
export_f() {	# export_f EXPECT(ok|busy)
	local out r
	out=$(zpool export -f $P 2>&1); r=$?
	echo "  # zpool export -f $P -> exit $r${out:+: $out}"
	case $1 in
	ok) [ $r = 0 ] && ok "export succeeded" || fail "export failed" ;;
	busy) if [ $r != 0 ] && echo "$out" | grep -q busy; then ok "export refused: busy"; else fail "export did not fail with 'busy'"; fi ;;
	esac
}
prop() {	# prop DATASET PROP VALUE SOURCE
	local got; got=$(zfs get -H -o value,source "$2" "$1" 2>&1 | tr '\t' ' ')
	[ "$got" = "$3 $4" ] && ok "$1 $2 = $got" || fail "$1 $2 = '$got', expected '$3 $4'"
}
reimport_check() {
	zpool export $P && zpool import -d $IMP $P || fail "export/import round trip"
	local s h
	for s in $(zfs list -H -o name -t snapshot -r $P); do
		h=$(zfs holds -H $s); [ -z "$h" ] || fail "$s held: $h"
	done
	for s in $(zfs list -H -o name -t filesystem -r $P); do
		[ "$(zfs get -H -o value receive_resume_token $s)" = - ] || fail "$s has a resume token"
	done
	ok "export/import round trip, no holds, no resume tokens"
}

# setup
resume
holds=$(dbg | grep -c "hasrecvd suspended on $P[^ ]*\$")	# earlier runs this boot
for p in $P $S; do zpool destroy -f $p 2>/dev/null; done
rm -rf $D; mkdir -p $D
truncate -s 128M $D/src
V=${DEMO_DISK:-$D/vdev}; [ -n "${DEMO_DISK:-}" ] || truncate -s 256M $V
IMP=$V
zpool create -f -o cachefile=none -O mountpoint=none $S $D/src &&
zpool create -f -o cachefile=none -O mountpoint=none $P $V ||
    { echo "RESULT ERROR: zpool create"; exit 2; }
zfs create -o test:fs=1 -o mountpoint=$D/srcfs $S/fs
zfs snapshot $S/fs@1; zfs set test:snap1=yes $S/fs@1
dd if=/dev/urandom of=$D/srcfs/file bs=1M count=4 2>/dev/null
zfs snapshot $S/fs@2; zfs set test:snap2=yes $S/fs@2
zfs send -R $S/fs@1 >$D/full
zfs send -R -I @1 $S/fs@2 >$D/incr
zfs send $S/fs@1 >$D/plain
zfs send -p -i @1 $S/fs@2 >$D/props
head -c $(( $(stat -c %s $D/props 2>/dev/null || stat -f %z $D/props) / 2 )) $D/props >$D/trunc
echo "source $S/fs: test:fs=1, @1 test:snap1=yes, @2 test:snap2=yes (+4 MiB)"

for c in $cases; do
	case $c in
	1)	echo; echo "## case 1: export while the receive ioctl marks $P/fs"
		hold_next; recv_bg $D/full $P/fs; hold_at $P/fs
		export_f busy
		resume; recv_wait
		[ $rc = 0 ] && ok "zfs recv exit 0" || fail "zfs recv exit $rc"
		prop $P/fs test:fs 1 received; prop $P/fs@1 test:snap1 yes received ;;
	2)	echo; echo "## case 2: export before setting the last snapshot's properties (full stream)"
		hold_next; recv_bg $D/full $P/fs2; hold_at $P/fs2@1
		export_f ok
		resume; recv_wait
		[ $rc != 0 ] && ok "zfs recv failed" || fail "zfs recv exit 0 with its pool exported"
		grep -q "cannot receive properties on $P/fs2@1" $D/out && ok "names $P/fs2@1" ||
		    fail "no 'cannot receive properties on $P/fs2@1'"
		zpool import -d $IMP $P && ok "zpool import" || fail "zpool import"
		zfs list $P/fs2@1 >/dev/null 2>&1 && ok "$P/fs2@1 exists" || fail "$P/fs2@1 missing"
		prop $P/fs2 test:fs 1 received; prop $P/fs2@1 test:snap1 - -
		reimport_check
		echo "  # zfs recv -u $P/fs2 < incr   (the next incremental replication)"
		zfs recv -u $P/fs2 <$D/incr && ok "incremental exit 0" || fail "incremental failed"
		prop $P/fs2@1 test:snap1 yes received; prop $P/fs2@2 test:snap2 yes received ;;
	3)	echo; echo "## case 3: export between the receive ioctl and setting @2's properties"
		zfs list $P/fs@1 >/dev/null 2>&1 || zfs recv -u $P/fs <$D/full
		hold_next; recv_bg $D/incr $P/fs; hold_at $P/fs@2
		export_f ok
		resume; recv_wait
		[ $rc != 0 ] && ok "zfs recv failed" || fail "zfs recv exit 0 with its pool exported"
		grep -q "cannot receive properties on $P/fs@2" $D/out && ok "names $P/fs@2" ||
		    fail "no 'cannot receive properties on $P/fs@2'"
		zpool import -d $IMP $P && ok "zpool import" || fail "zpool import"
		zfs list $P/fs@2 >/dev/null 2>&1 && ok "$P/fs@2 exists" || fail "$P/fs@2 missing"
		prop $P/fs@2 test:snap2 - -; prop $P/fs@1 test:snap1 yes received
		reimport_check
		echo "  # zfs recv -u $P/fs < incr   (the same receive again)"
		zfs recv -u $P/fs <$D/incr && ok "retry exit 0" || fail "retry failed"
		prop $P/fs@2 test:snap2 yes received ;;
	4)	echo; echo "## case 4: export while a failed receive restores $P/dst's properties"
		zfs recv -u $P/dst <$D/plain; zfs set test:local=orig $P/dst
		echo "  $P/dst: received without properties, then test:local=orig (local)"
		hold_next; recv_bg $D/trunc $P/dst; hold_at $P/dst
		hold_next; hold_at $P/dst
		export_f busy
		resume; recv_wait
		[ $rc != 0 ] && ok "zfs recv failed (truncated stream)" || fail "zfs recv exit 0"
		grep -q "failed to restore" $D/out && fail "original properties not restored"
		zpool list $P >/dev/null 2>&1 || { zpool import -d $IMP $P; fail "pool was exported"; }
		zfs list $P/dst@2 >/dev/null 2>&1 && fail "$P/dst@2 exists"
		prop $P/dst test:local orig local; prop $P/dst test:fs - -
		reimport_check
		echo "  # zfs recv -u $P/dst < props   (the complete stream)"
		zfs recv -u $P/dst <$D/props && ok "complete receive exit 0" || fail "complete receive failed"
		prop $P/dst test:fs 1 received
		prop $P/dst test:local - - ;;
	esac
done
resume
zpool export $P; zpool destroy $S
echo
if [ $bad -gt 0 ]; then
	echo "RESULT BUG: $bad of the expected outcomes did not hold"
else
	echo "RESULT OK: no panic, every expected outcome held (cases $cases)"
fi
