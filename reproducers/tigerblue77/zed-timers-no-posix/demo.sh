#!/bin/bash
# demo.sh -- openzfs/zfs #19954 (@tigerblue77): ZED's FMD timers without
# POSIX timers.  The PR stacks #19629 (the timer use-after-free of #19569,
# reproducer tigerblue77/zed-timer-uaf) and adds 5d719f0fe3, which this
# demo is about.
#
# ZED emulates fmd's timers.  On master, and with #19629 alone, each FMD
# timer is a SIGEV_THREAD POSIX timer: fmd_timer_install() calls
# timer_create(), which the kernel refuses with EAGAIN once the process is at
# its RLIMIT_SIGPENDING (each POSIX timer preallocates a queued signal).
# Such a timer never expires.  zfs-diagnosis uses one to solve an I/O error
# case: after the vdev's I/O SERD engine fires it waits 15 s for a removal
# event, and only when the timer fires does it diagnose fault.fs.zfs.vdev.io,
# which zfs-retire turns into a FAULTED vdev.  Without the timer the case is
# never solved and the vdev stays ONLINE, however many errors it returns.
# (master doesn't even check timer_create(); #19629 logs "failed to create
# timer".)  5d719f0fe3 makes a timer a deadline that the agents thread waits
# for (pthread_cond_timedwait on CLOCK_MONOTONIC): nothing to create, nothing
# that can fail.
#
#   1. control: ZED with the usual limits; read errors on one side of a
#      3-way mirror.  The 15 s timer fires and the vdev is FAULTED, on both
#      builds.
#   2. the same with ZED started under `ulimit -i 0` (RLIMIT_SIGPENDING 0, so
#      timer_create() fails at once; a busy host that has used up its
#      pending-signal quota gets there too):
#        master (bug):  no timer fires, the vdev stays ONLINE -> RESULT BUG
#        PR (fix):      the timer fires, the vdev is FAULTED   -> RESULT OK
#
# Run as root:  /demo/demo.sh      about 90 s.
# Pool tmr on the run disks $DEMO_DISKS (3), or files in /var/tmp/tmr.
# The pool is exported at the end.
set -u
W=/var/tmp/tmr; P=tmr
[ -s $W/zed.pid ] && kill "$(cat $W/zed.pid)" 2>/dev/null; zinject -c all >/dev/null 2>&1; zpool destroy -f $P 2>/dev/null
rm -rf $W; mkdir -p $W/zedlets
read -r -a V <<< "${DEMO_DISKS:-}"
if [ ${#V[@]} -lt 3 ]; then
	V=(); for i in 1 2 3; do truncate -s 256M $W/v$i; V+=($W/v$i); done
fi
BAD=${V[0]} BADN=$(basename "${V[0]}")
step() { echo; echo "### $*"; }
run() { echo "# $*"; "$@"; }
st() { echo "# zpool status -v $P"; zpool status -v $P 2>&1 | sed 's/^/  /'; }
vstate() { zpool status $P 2>/dev/null | awk -v d="$BADN" '$1 == d { print $2 }'; }
zedlog() {	# LOG: ZED's lines about timers and the diagnosis
	grep -E 'installing timer|removing timer|timer fired|failed to (create|arm) timer|solving|fault\.fs|retire|segfault|SERD' "$1" |
	    grep -v 'ignoring' | sed 's/^/  zed.log: /'
}
zedup() { kill -0 "$ZPID" 2>/dev/null; }
stopzed() {
	kill "$ZPID" 2>/dev/null
	for i in $(seq 20); do zedup || break; sleep 0.5; done
	kill -9 "$ZPID" 2>/dev/null; wait "$ZPID" 2>/dev/null
}

# phase N LIMIT: one run; prints the state of $BAD 60 s after the errors
phase() {
	local n=$1 lim=$2 log=$W/zed$1.log state i
	run zpool create -f -o cachefile=none $P mirror "${V[@]}" ||
	    { echo "RESULT ERROR: could not create pool $P"; exit 2; }
	run zfs create -o primarycache=none -o recordsize=16k $P/fs
	dd if=/dev/urandom of=/$P/fs/file bs=1M count=16 status=none; zpool sync $P
	zpool events -c >/dev/null
	echo "# ( ulimit -i $lim; exec zed -F -v ... )   (log $log)"
	( ulimit -i "$lim" && exec zed -F -v -d $W/zedlets -p $W/zed.pid -s $W/zed$n.state ) 2>"$log" >&2 &
	ZPID=$!
	for i in $(seq 30); do grep -q 'Processing events' "$log" 2>/dev/null && break; sleep 1; done
	grep -q 'Processing events' "$log" 2>/dev/null ||
	    { cat "$log"; stopzed; echo "RESULT ERROR: zed did not start"; exit 2; }
	echo "# ZED is up: $(grep -m1 'ZFS Event Daemon' "$log")"
	echo "# ZED's /proc/PID/limits: $(grep 'pending signals' /proc/$ZPID/limits)"
	echo "# zinject -d $BAD -e io -T read $P; read the file (16 MiB, uncached)"
	zinject -d "$BAD" -e io -T read $P >/dev/null
	cat /$P/fs/file >/dev/null
	zinject -c all >/dev/null
	echo "# errors injected and cleared at $(date +%T); zfs-diagnosis waits 15 s for a removal event, then solves the case"
	sleep 2
	st
	for i in $(seq 60); do
		state=$(vstate)
		[ "$state" = FAULTED ] && break
		zedup || break
		sleep 1
	done
	echo "# $(date +%T): $BADN is ${state:-?}$(zedup || echo ', and ZED is no longer running')"
	st
	echo "# ZED's log:"
	zedlog "$log"
	eval "STATE$n=\${state:-?}"
	zedup; eval "ZEDUP$n=$?"
	stopzed
}

step "1. control: ZED with the usual limits ($(ulimit -i) pending signals), read errors on $BADN"
phase 1 "$(ulimit -i)"
run zpool destroy $P

step "2. ZED with RLIMIT_SIGPENDING 0 (ulimit -i 0: timer_create() fails with EAGAIN), read errors on $BADN"
phase 2 0
run zpool export $P

echo
if [ "$STATE1" != FAULTED ]; then
	echo "RESULT ERROR: the control did not fault $BADN either ($STATE1), so the run proves nothing (see $W/zed1.log)"
elif [ "$STATE2" = FAULTED ]; then
	echo "RESULT OK: with RLIMIT_SIGPENDING 0, ZED's diagnosis timer still fired and $BADN was FAULTED, as in the control"
else
	echo "RESULT BUG: with RLIMIT_SIGPENDING 0, ZED's diagnosis timer never fired: $BADN returned I/O errors and stayed $STATE2 (FAULTED in the control)$([ "$ZEDUP2" != 0 ] && echo '; ZED also died')"
fi
