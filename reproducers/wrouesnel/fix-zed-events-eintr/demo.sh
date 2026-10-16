#!/bin/bash
# demo.sh -- bug #135 / openzfs #14720: ZED exits when a signal interrupts
# its wait for the next event.  An idle ZED sleeps in the ZFS_IOC_EVENTS_NEXT
# ioctl; any signal makes it return EINTR, and zed.c's main loop ends on any
# error, so ZED logs "Exiting" and exits with status 0, as if asked to stop.
#
# Steps (each on screen):
#   1. start ZED (zed -vF, a demo zedlet that logs every event with ZED_PID),
#      let it handle a scrub, show its PID;
#   2. kill -HUP: the documented "rescan the zedlets" reload (zed(8));
#   3. kill -STOP, kill -CONT: job control, a debugger, the suspend freezer.
#      (If step 2 killed it, a new ZED is started for this step.)
#   4. a new event (zpool scrub): the ZED from step 1 must run the zedlet.
#
# Builds (TOOLS=zed adds zed to each):
#   repro  test commit 9d0744264 (master 63c423aaa + ZTS events/zed_signal_eintr)
#        -> "RESULT BUG: zed (pid N) exited after SIGHUP ..."
#   fixed  fix-zed-events-eintr 3ab219f50
#        -> "RESULT OK: zed pid N survived SIGHUP and SIGSTOP/SIGCONT and
#           handled the next event"
# Run as root:  /demo/demo.sh       about 20 seconds.
# Pool demo135 on the run disk $DEMO_DISK (the container launcher), or on the file
# /var/tmp/demo135/vdev when DEMO_DISK is unset.  The ZED and zedlet logs are
# copied to /demo135/logs and the pool is exported at the end (inspect.sh).
set -u
P=demo135 D=/var/tmp/demo135
V=${DEMO_DISK:-$D/vdev}
Z=$D/zed.d ZLOG=$D/zed.log EVLOG=$D/zedlet.log
pkill -x zed 2>/dev/null; sleep 0.5
zpool destroy -f $P 2>/dev/null
rm -rf $D; mkdir -p $Z
[ -n "${DEMO_DISK:-}" ] || truncate -s 256M $V
zpool create -f -m /$P $P $V || { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
dd if=/dev/urandom of=/$P/file bs=1M count=8 status=none
# the zedlet: one line per event, naming the ZED process that ran it
cat >$Z/all-demo.sh <<EOF
#!/bin/bash
echo "eid=\$ZEVENT_EID \$ZEVENT_SUBCLASS handled by ZED_PID=\$ZED_PID" >>$EVLOG
EOF
chmod 755 $Z/all-demo.sh
: >$EVLOG; : >$ZLOG
zpool events -c >/dev/null

st() { awk '{print $3}' /proc/$1/stat 2>/dev/null || echo gone; }	# Z: exited
alive() { case $(st $1) in Z|gone) return 1 ;; esac; }
idle() {	# idle PID: wait until it sleeps (S) in the event ioctl
	local i
	for i in $(seq 50); do [ "$(st $1)" = S ] && return 0; sleep 0.2; done
	return 1
}
startzed() {	# sets zed to the new ZED's pid
	zed -vF -d $Z -P "$PATH" -p $D/zed.pid -s $D/zed.state -j 1 2>>$ZLOG &
	zed=$! exn=$(grep -c Exiting $ZLOG)
	sleep 1
	alive $zed || { echo "RESULT ERROR: zed did not start"; tail $ZLOG; exit 2; }
}
scrub_event() {	# scrub_event PID: a new scrub; did ZED PID run the zedlet for it?
	local i n new
	n=$(wc -l <$EVLOG)
	zpool scrub -w $P
	for i in $(seq 50); do
		new=$(tail -n +$((n + 1)) $EVLOG | grep scrub_finish)
		[ -n "$new" ] && break; sleep 0.2
	done
	if [ -n "$new" ]; then echo "$new" | sed 's/^/  zedlet log: /'
	else echo "  zedlet log: nothing for this scrub's scrub_finish event (waited 10 s)"; fi
	echo "$new" | grep -q "handled by ZED_PID=$1\$"
}
gone() {	# gone PID: report how it ended
	wait $1; local rc=$?
	how="status $rc$([ "$(grep -c Exiting $ZLOG)" -gt "$exn" ] && echo ', logged "Exiting"')"
	echo "  -> zed pid $1 is GONE ($how); its log:"
	grep -E 'Exiting|ZFS Event Daemon' $ZLOG | tail -2 | sed 's/^/     /'
}
saylog() { grep -c 'Registered zedlet' $ZLOG; }

echo "# pool $P on $V; zedlets in $Z"
echo
echo "# 1. start ZED and let it handle an event"
startzed; first=$zed
echo "  zed running, pid $zed:  $(tr '\0' ' ' </proc/$zed/cmdline)"
scrub_event $zed || { echo "RESULT ERROR: zed pid $zed did not handle the first scrub"; exit 2; }
idle $zed || { echo "RESULT ERROR: zed pid $zed did not go idle"; exit 2; }
echo "  zed pid $zed is idle (state $(st $zed)), waiting in the kernel for the next event"

echo
echo "# 2. kill -HUP $zed   (zed(8): SIGHUP = reload, rescan the zedlet directory)"
n=$(saylog)
kill -HUP $zed; sleep 2
if alive $zed; then
	hup=ok
	echo "  zed pid $zed still running (state $(st $zed)); 'Registered zedlet' log lines $n -> $(saylog)"
else
	hup=died; gone $zed; hhow=$how
	echo "  starting a new ZED for the next step"
	startzed; scrub_event $zed >/dev/null; idle $zed
	echo "  new zed pid $zed"
fi
second=$zed

echo
echo "# 3. kill -STOP $zed; kill -CONT $zed   (job control, a debugger, the suspend freezer)"
idle $zed
kill -STOP $zed; sleep 1
echo "  stopped: state $(st $zed)"
kill -CONT $zed; sleep 2
if alive $zed; then
	stop=ok; echo "  zed pid $zed still running (state $(st $zed))"
else
	stop=died; gone $zed
fi

echo
echo "# 4. a new event: zpool scrub $P"
if scrub_event $first; then ev=ok; echo "  -> handled by the ZED started in step 1, pid $first"
else ev=no; echo "  -> NOT handled by zed pid $first; running ZEDs: $(pgrep -x zed | tr '\n' ' ')"; fi

# stop ZED, keep the logs on the pool, export it
alive $zed && { kill -TERM $zed; wait $zed; }
mkdir -p /$P/logs; cp $ZLOG $EVLOG /$P/logs/
{ echo "first=$first second=$second hup=$hup stop=$stop event=$ev"; } >/$P/logs/summary
echo
zpool export $P && echo "# pool $P exported (on $V), with the ZED logs in /$P/logs"
if [ $hup = ok ] && [ $stop = ok ] && [ $ev = ok ]; then
	echo "RESULT OK: zed pid $first survived SIGHUP and SIGSTOP/SIGCONT and handled the next event"
elif [ $hup = died ]; then
	echo "RESULT BUG: zed (pid $first) exited after SIGHUP ($hhow)$([ $stop = died ] && echo "; a restarted zed (pid $second) exited after SIGSTOP/SIGCONT"); the next event was handled by no ZED"
elif [ $stop = died ]; then
	echo "RESULT BUG: zed (pid $first) survived SIGHUP but exited after SIGSTOP/SIGCONT; the next event was handled by no ZED"
else
	echo "RESULT ERROR: zed pid $first survived both signals but did not handle the next event"; exit 2
fi
