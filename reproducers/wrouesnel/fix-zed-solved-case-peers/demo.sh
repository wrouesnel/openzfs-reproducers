#!/bin/bash
# demo.sh -- bug #72: once ZED has faulted one leaf of a mirror (or raidz)
# and a hot spare has replaced it, ZED never faults a second failing leaf
# under the same parent: the first case stays open ("solved") while its vdev
# is faulted, and the diagnosis counts it as a peer, so it logs
#   pool ... is tracking 1 other io error cases -- skip faulting the vdev
# and the second disk gets no spare.  (Fails ZTS fault/auto_spare_multiple.)
#
# Image version of the mirror case of auto_spare_multiple; ZED runs in the
# foreground here (no udev or zedlets are needed for its diagnosis and
# retire agents), its log in /var/tmp/p72d/zed.log.
# Run as root:  /demo/demo.sh      about 50 s (unfixed) or 35 s (fixed).
# What you will see: a 3-way mirror (run disks 1-3) with spares (4, 5);
#   1. zinject I/O errors on disk 1, scrub: ZED faults it, spare 1 INUSE
#   2. zinject I/O errors on disk 2, scrub, wait up to 30 s:
#      unfixed (test commit e6f11aa9f): disk 2 stays ONLINE with errors, ZED
#        logs "tracking 1 other io error cases -- skip faulting": "RESULT BUG"
#      fixed (fix-zed-solved-case-peers 886e298ec): disk 2 FAULTED, spare 2
#        INUSE: "RESULT OK"
#   if step 1 doesn't fault disk 1 (ZED not working): "RESULT ERROR".
# Pool p72 on the run disks $DEMO_DISKS (5), or files in /var/tmp/p72d.  It
# is exported at the end (faults cleared).
set -u
d=/var/tmp/p72d; pool=p72
rm -rf $d; mkdir -p $d/zed.d
read -r -a V <<< "${DEMO_DISKS:-}"
if [ ${#V[@]} -lt 5 ]; then
	V=(); for i in 1 2 3 4 5; do truncate -s 256M $d/v$i; V+=($d/v$i); done
fi
f1=${V[0]} f2=${V[1]} s=${V[2]} sp1=${V[3]} sp2=${V[4]}
state() { zpool status -P $pool | awk -v d=$1 '$1 == d { print $2; exit }'; }
waitstate() {	# DEV STATE SECONDS
	for _ in $(seq $(( $3 * 2 ))); do [ "$(state $1)" = $2 ] && return 0; sleep 0.5; done
	return 1
}
cfg() { zpool status -P $pool | sed -n '/config:/,/errors:/p' | grep -v '^$\|config:\|errors:'; }
pkill -x zed 2>/dev/null
zpool destroy -f $pool 2>/dev/null
zpool create -f -o cachefile=none $pool mirror $f1 $f2 $s spare $sp1 $sp2 ||
    { echo "RESULT ERROR: could not create pool $pool"; exit 2; }
dd if=/dev/urandom of=/$pool/file bs=1M count=32 2>/dev/null; zpool sync $pool
zpool events -c >/dev/null
echo "# zed -F -v (log $d/zed.log)"
zed -F -v -d $d/zed.d -p $d/zed.pid -s $d/zed.state >$d/zed.log 2>&1 &
zpid=$!
sleep 1
kill -0 $zpid 2>/dev/null || { cat $d/zed.log; echo "RESULT ERROR: zed did not start"; exit 2; }
cfg
fin() {	# fin RESULT...
	zinject -c all >/dev/null
	zpool clear $pool 2>/dev/null
	kill $zpid; wait $zpid 2>/dev/null
	echo "# ZED's diagnosis log:"
	grep -E 'skip faulting|solve|fault|retire' $d/zed.log | grep -v '^Invoking' | tail -20 | uniq -c |
	    sed 's/^ *1 /  /; s/^ *\([0-9][0-9]*\) /  (x\1) /'
	zpool export $pool && echo "# pool $pool exported (on ${V[*]})"
	echo
	echo "$@"
}

echo
echo "# 1. zinject -d $f1 -e io -T all -f 100 $pool; zpool scrub $pool"
zinject -d $f1 -e io -T all -f 100 $pool >/dev/null
zpool scrub $pool
if ! waitstate $f1 FAULTED 30 || ! waitstate $sp1 ONLINE 30; then
	cfg; fin "RESULT ERROR: ZED did not fault $f1 and spare it in (is ZED working?)"; exit 2
fi
zpool wait -t scrub,resilver $pool
cfg

echo
echo "# 2. zinject -d $f2 -e io -T all -f 100 $pool; zpool scrub $pool; wait up to 30 s"
zinject -d $f2 -e io -T all -f 100 $pool >/dev/null
zpool scrub $pool
ok=no
waitstate $f2 FAULTED 30 && waitstate $sp2 ONLINE 30 && ok=yes
zpool wait -t scrub,resilver $pool
cfg
st2=$(state $f2)
if [ $ok = yes ]; then
	fin "RESULT OK: ZED faulted the second failing disk too and put the second spare in"
else
	fin "RESULT BUG: the second failing disk ($f2: $st2) was not faulted, no second spare"
fi
