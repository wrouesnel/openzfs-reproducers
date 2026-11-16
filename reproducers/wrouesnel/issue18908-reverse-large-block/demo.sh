#!/bin/bash
# demo.sh -- openzfs/zfs#18908 (@mminkus): after a first full send without
# -L, the replication can't be reversed with -L.
#
# Pool A has a file written with recordsize=1M (1M blocks).  A sends it to
# pool B without -L, so B's copy is split into 128K blocks.  Then the roles
# swap: B changes something and sends an incremental back to A, with -L.
# B's copy has no large blocks, so the -L stream doesn't carry the
# large_blocks feature (0x80000), and master's zfs recv on A refuses it
# ("destination contains large blocks, but the incremental stream does not
# carry them") rather than overwrite A's 1M blocks with 128K ones.
#
# Build: repro = openzfs/zfs master
#   -> "RESULT REFUSED: ..." (zfs recv refuses; A's file and snapshots are
#      unchanged).  "RESULT RECEIVED: ..." if a build accepts the stream and
#      A's file still matches B's; "RESULT BUG: ..." if it accepts it and
#      A's file no longer matches (silent damage).
# Pools pool_a and pool_b on the run disks $DEMO_DISKS (2), or files in
# /var/tmp/d18908.  Run as root:  /demo/demo.sh       a few seconds.
set -u
D=/var/tmp/d18908
read -r -a V <<< "${DEMO_DISKS:-}"
if [ ${#V[@]} -lt 2 ]; then
	mkdir -p $D; V=($D/a $D/b); truncate -s 1G "${V[@]}"
fi

run() { echo "# $*"; eval "$@"; }
step() { echo; echo "== $*"; }
die() { echo "RESULT ERROR: $*"; exit 2; }
bs() { stat -c %o "$1" 2>/dev/null || echo "(no file)"; }
sizes() {
	echo "   f's block size: A $(bs /pool_a/fs/f)  B $(bs /pool_b/fs/f)"
}

echo "build: ${DEMO_BUILD:-?} $(cat /etc/zfshunt-build 2>/dev/null)"
zpool destroy -f pool_a 2>/dev/null; zpool destroy -f pool_b 2>/dev/null

step "pool A: a file written with 1M blocks"
run "zpool create -f -o cachefile=none pool_a ${V[0]}" || die "zpool create pool_a"
run "zpool create -f -o cachefile=none pool_b ${V[1]}" || die "zpool create pool_b"
run "zfs create -o recordsize=1M pool_a/fs"
run "dd if=/dev/urandom of=/pool_a/fs/f bs=1M count=4 status=none"
run "zfs snapshot pool_a/fs@s1"
sizes

step "A -> B, full send WITHOUT -L: B's copy of f gets 128K blocks"
run "zfs send pool_a/fs@s1 | zfs recv pool_b/fs" || die "full receive into B failed"
sizes

step "swap roles: B changes something and sends back to A, WITH -L"
run "touch /pool_b/fs/new"
run "zfs snapshot pool_b/fs@s2"
run "zfs send -L -i @s1 pool_b/fs@s2 > $D.stream" || die "zfs send -L failed"
f=$(zstream dump $D.stream | awk '/features =/ {print $3; exit}')
echo "   stream features = $f; large_blocks (0x80000): $( (( 0x${f:-0} & 0x80000 )) && echo set || echo NOT set)"

step "zfs recv -F on A"
sum_a=$(md5sum </pool_a/fs/f | cut -c1-32)
sum_b=$(md5sum </pool_b/fs/f | cut -c1-32)
echo "# zfs recv -F pool_a/fs < $D.stream"
out=$(zfs recv -F pool_a/fs <$D.stream 2>&1); rc=$?
echo "$out" | sed 's/^/   /'
echo "-> zfs recv exit status $rc"
rm -f $D.stream

step "end state"
run "zfs list -t all -o name,used,recordsize -r pool_a pool_b"
sizes
now_a=$(md5sum </pool_a/fs/f | cut -c1-32)
echo "   md5 of f: A before $sum_a, A now $now_a, B $sum_b"
run "zpool status -x pool_a pool_b"
run "zpool export pool_a"; run "zpool export pool_b"

if [ $rc != 0 ]; then
	echo "RESULT REFUSED: zfs recv on A refused B's -L incremental (exit $rc): $(echo "$out" | head -1)"
elif [ "$now_a" = "$sum_b" ]; then
	echo "RESULT RECEIVED: zfs recv on A accepted B's -L incremental, and A's f matches B's"
else
	echo "RESULT BUG: zfs recv on A accepted B's -L incremental, but A's f differs from B's (md5 $now_a != $sum_b)"
fi
