#!/bin/bash
# inspect.sh -- bug #135: the demo leaves no ZFS damage; it keeps what ZED did
# in /demo135/logs on the exported pool (zed -vF log, zedlet log, summary).
# Imports the pool, shows the logs, prints RESULT ... on disk, exports it.
set -u
P=demo135
zpool import -f -d /dev $P || { echo "RESULT ERROR: could not import $P"; exit 2; }
L=/$P/logs
[ -f $L/summary ] || { zpool export $P; echo "RESULT ERROR: no $L/summary (demo did not finish)"; exit 2; }
echo "# $L/summary: $(cat $L/summary)"
echo "# zed log (Exiting / start lines):"
grep -E 'ZFS Event Daemon|Exiting' $L/zed.log | sed 's/^/  /'
echo "# zedlet log:"; sed 's/^/  /' $L/zedlet.log
. $L/summary 2>/dev/null
zpool export $P
if [ "$hup" = ok ] && [ "$stop" = ok ] && [ "$event" = ok ]; then
	echo "RESULT OK on disk: the logs show zed pid $first survived SIGHUP and SIGSTOP/SIGCONT and handled the next event"
else
	echo "RESULT BUG on disk: the logs show zed pid $first exited (SIGHUP: $hup, SIGSTOP/SIGCONT: $stop, next event: $event)"
fi
