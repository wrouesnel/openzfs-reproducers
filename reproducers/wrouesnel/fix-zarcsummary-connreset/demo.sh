#!/bin/bash
# demo.sh -- bug #124: the ZTS test cli_user/misc/zarcsummary_001_pos flakes in
# CI with an unhandled "ConnectionResetError: [Errno 104] Connection reset by
# peer" from `zarcsummary | head`.  ksh93 builds its pipelines from
# socketpair(2), not pipe(2).  zarcsummary writes unbuffered (it reexecutes
# itself with python3 -u), so when head starts late it fills the socket and
# blocks; head then exits with output unread, which resets the socket, and the
# blocked write fails with ECONNRESET instead of EPIPE.  zarcsummary's
# exception hook only exits quietly on BrokenPipeError (EPIPE).
#
# The image carries each commit's zarcsummary (/demo/zts/LABEL/zarcsummary,
# `git show REF:cmd/zarcsummary`), Python and ksh93.  Builds:
#   repro: fix-zarcsummary-connreset~1 (the test commit; zarcsummary = master)
#   fixed: fix-zarcsummary-connreset (zarcsummary handles ConnectionResetError)
# Run as root:  /demo/demo.sh      about 15 seconds.
# What you will see:
#   1. what each shell's pipeline is made of: ksh "socket:[N]", bash "pipe:[N]"
#   2. 3 runs of a ksh pipeline whose writer is zarcsummary with the smallest
#      send buffer and whose reader (sleep 1) exits without reading: the CI
#      failure every time on the bug build (traceback, exit 1)
#   3. 3 runs of the check the new ZTS test makes (reset_reader.py: its own
#      socketpair, waits until zarcsummary is blocked writing, closes unread)
#   repro build: ConnectionResetError in 6/6, "RESULT BUG"
#   fixed build: exit 0 in 6/6, "RESULT OK"
#   "RESULT ERROR" if ksh's pipe was not a socket or zarcsummary never blocked.
# Pool p124 on the run disk $DEMO_DISK (the container launcher), or on the file
# /var/tmp/p124d/v0 when DEMO_DISK is unset, so the ARC has something in it;
# exported at the end.
set -u
. /etc/demo-env 2>/dev/null
build=${DEMO_BUILD:-${1:-repro}}
Z=/demo/zts/$build/zarcsummary
[ -f "$Z" ] || { echo "RESULT ERROR: no zarcsummary for build '$build' ($Z)"; exit 2; }
d=/var/tmp/p124d; pool=p124
V=${DEMO_DISK:-$d/v0}
zpool destroy -f $pool 2>/dev/null; rm -rf $d; mkdir -p $d/bin
[ -n "${DEMO_DISK:-}" ] || truncate -s 256M $V
zpool create -f -o cachefile=none $pool $V ||
    { echo "RESULT ERROR: could not create pool $pool on $V"; exit 2; }
dd if=/dev/urandom of=/$pool/f bs=1M count=16 status=none; cat /$pool/f >/dev/null
ln -s $Z $d/bin/zarcsummary
export PATH=$d/bin:$PATH PYTHONHOME=/demo PYTHONDONTWRITEBYTECODE=1
echo "# the $build build's zarcsummary: $(grep -c ConnectionResetError $Z) mention(s) of ConnectionResetError"
grep -n -A1 'BrokenPipeError' $Z | sed 's/^/  /'

echo
echo "# 1. what a pipeline's writer has as its stdout"
echo "ksh:  $(ksh -c 'readlink /proc/self/fd/1 | cat')"
echo "bash: $(bash -c 'readlink /proc/self/fd/1 | cat')"
ksh -c 'readlink /proc/self/fd/1 | cat' | grep -q '^socket:' ||
    { echo "RESULT ERROR: ksh's pipe is not a socket here"; exit 2; }

bad=0 good=0 err=0
run() {	# run LABEL CMD...: one run, scored by exit status and stderr
	"$@" 2>$d/err; rc=$?
	if [ $rc = 0 ]; then good=$((good + 1)); echo "  run $i: exit 0"
	elif grep -q ConnectionResetError $d/err; then bad=$((bad + 1))
		echo "  run $i: exit $rc: $(grep -m1 '^ConnectionResetError' $d/err)"
	else err=$((err + 1)); echo "  run $i: exit $rc: $(tail -1 $d/err)"; fi
}
echo
echo "# 2. ksh -c 'python3 /demo/smallbuf.py zarcsummary | sleep 1'"
echo "#    (writer: smallest send buffer; reader: exits after 1 s without reading)"
for i in 1 2 3; do
	run ksh -c 'set -o pipefail; python3 /demo/smallbuf.py zarcsummary | sleep 1'
done
echo
echo "# 3. the new test's check: python3 /demo/reset_reader.py zarcsummary"
for i in 1 2 3; do run python3 /demo/reset_reader.py zarcsummary; done

zpool export $pool && echo "# pool $pool exported (on $V)"
echo
if [ $err -gt 0 ]; then
	echo "RESULT ERROR: $err/6 runs failed for another reason"; exit 2
elif [ $bad -gt 0 ]; then
	echo "RESULT BUG: zarcsummary died with ConnectionResetError in $bad/6 runs"
else
	echo "RESULT OK: zarcsummary exited 0 in $good/6 runs"
fi
