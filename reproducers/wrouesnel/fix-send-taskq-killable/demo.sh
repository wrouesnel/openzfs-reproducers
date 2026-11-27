#!/bin/bash
# demo.sh -- wrouesnel/fix-send-taskq-killable (openzfs/zfs#12500).
# Both builds have the small-stack send path forced on (USE_SEND_TASKQ: the
# stream is written on a "z_send" taskq thread).  A 32 MiB snapshot is sent
# into a FIFO whose reader never reads, so the send blocks on the full pipe.
# The send gets SIGKILL:
#   master: it stays in D state (taskq_wait) and its snapshot can't be
#           destroyed ("dataset is busy") while the reader is there
#   fix:    it exits within moments, and the snapshot can be destroyed
#           while the reader is still there
set -u
. /etc/demo-env 2>/dev/null
P=sendkill F=/var/tmp/sendkill.fifo
x() { echo "# $*"; "$@"; }
die() { echo "RESULT ERROR: $*"; exit 2; }
alive() { [ -e /proc/$1/stat ] && [ "$(awk '{ print $3 }' /proc/$1/stat)" != Z ]; }
state() { alive $1 && echo "state $(awk '{ print $3 }' /proc/$1/stat) in $(cat /proc/$1/wchan 2>/dev/null)" || echo "exited"; }

echo "=== killing a blocked zfs send ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build), kernel $(uname -r))"
zpool destroy $P 2>/dev/null
x zpool create -f -o cachefile=none $P $DEMO_DISK || die "zpool create failed"
x zfs create $P/fs
x dd if=/dev/urandom of=/$P/fs/file bs=1M count=32 status=none
x zfs snapshot $P/fs@snap
rm -f $F; x mkfifo $F
echo "# sleep 600 < $F &      (a reader that never reads)"
sleep 600 <$F & reader=$!
echo "# zfs send $P/fs@snap > $F &"
zfs send $P/fs@snap >$F & send=$!
sleep 3
alive $send || die "zfs send exited before it blocked"
tq=no; ls /proc/spl/kstat/taskq 2>/dev/null | grep -q '^z_send\.' && tq=yes
echo "  send pid $send: $(state $send); z_send taskq in use: $tq"
[ -r /proc/$send/stack ] && sed 's/^/    /' /proc/$send/stack | head -8

echo; echo "## SIGKILL the send"
x kill -9 $send
for i in $(seq 10); do alive $send || break; sleep 1; done
after=$(state $send)
echo "  10 s later: $after"
[ -r /proc/$send/stack ] && alive $send && sed 's/^/    /' /proc/$send/stack | head -8
echo "# zfs destroy $P/fs@snap   (the reader is still there)"
dout=$(zfs destroy $P/fs@snap 2>&1); drc=$?
echo "  -> exit $drc${dout:+: $dout}"

echo; echo "## end the reader"
x kill $reader
for i in $(seq 10); do alive $send || break; sleep 1; done
echo "  send: $(state $send)"
wait 2>/dev/null
zfs list -t snapshot -H -o name $P/fs@snap >/dev/null 2>&1 && x zfs destroy $P/fs@snap
echo "# zpool status -v $P"; zpool status -v $P
x zpool export $P
rm -f $F
echo
if [ "$after" != exited ]; then
	echo "RESULT BUG: zfs send survived SIGKILL ($after, 10 s later; z_send taskq: $tq) and its snapshot could not be destroyed: ${dout:-exit $drc}"
	exit 1
elif [ $drc = 0 ]; then
	echo "RESULT OK: zfs send exited after SIGKILL (z_send taskq: $tq), and its snapshot was destroyed with the reader still there"
else
	echo "RESULT ERROR: zfs send exited, but zfs destroy failed: $dout"; exit 2
fi
