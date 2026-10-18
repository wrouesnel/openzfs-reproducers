#!/bin/bash
# demo.sh -- bug #70 (openzfs/zfs#18491): a raw (`zfs send -w`) incremental
# from a redaction bookmark fails with "dataset key must be loaded" when the
# source's key is not loaded, although a raw send never needs the key.
# Looking up the block pointer under the bookmark's redaction list read an
# indirect block with decryption on; the fix reads it raw.
#
# Image version of the ZTS test send_xdr_encoding/xdr_bookmark_raw_with_write
# (test commit ddc09dc3c, which made it deterministic).
# Run as root:  /demo/demo.sh      about 5 seconds.
# What you will see: an encrypted filesystem, a clone with changes, `zfs
# redact` making a redaction bookmark, a write after it, a raw full send
# received into p70/recv; then the pool is exported and imported (cold
# cache; the key stays unloaded: keystatus unavailable) and
#   zfs send -w -i fs#redaction-bookmark fs@s1
#     unfixed (test commit ddc09dc3c): "dataset key must be loaded",
#       "RESULT BUG"
#     fixed (fix-raw-send-redact-bookmark-eacces ee2bc1017): the stream is
#       written and received: "RESULT OK"
#   if the setup fails or the key is loaded after the import: "RESULT ERROR".
# Pool p70 on the run disk $DEMO_DISK (vm/demo-vm.sh), or on the file
# /var/tmp/p70d/v0 when DEMO_DISK is unset; exported at the end.
set -u
d=/var/tmp/p70d; pool=p70
V=${DEMO_DISK:-$d/v0}; I=$(dirname $V)
src=$pool/src clone=$pool/clone recv=$pool/recv key=/$pool/key
zpool destroy -f $pool 2>/dev/null; rm -rf $d; mkdir -p $d
[ -n "${DEMO_DISK:-}" ] || truncate -s 512M $V
die() { echo "RESULT ERROR: $*"; exit 2; }
run() { echo "+ $*"; "$@" || die "$* failed"; }
zpool create -f -o cachefile=none $pool $V || die "could not create pool $pool on $V"
echo thisisapassphrase >$key
run zfs create -o encryption=on -o keyformat=passphrase -o keylocation=file://$key $src
dd if=/dev/urandom of=/$src/f1 bs=128k count=8 status=none
run zfs snapshot $src@s0
run zfs clone $src@s0 $clone
dd if=/dev/urandom of=/$clone/f1 bs=128k count=8 conv=notrunc status=none
run zfs snapshot $clone@s
run zfs redact $src@s0 redaction-bookmark $clone@s
dd if=/dev/urandom of=/$src/f3 bs=128k count=8 status=none
run zfs snapshot $src@s1
echo "+ zfs send -w $src@s0 | zfs receive $recv"
zfs send -w $src@s0 >$d/full && zfs receive $recv <$d/full || die "raw full send/receive failed"
run zpool export $pool
run zpool import -d $I $pool
ks=$(zfs get -H -o value keystatus $src)
echo "keystatus of $src: $ks"
[ "$ks" = unavailable ] || die "the key is loaded ($ks)"
echo
echo "# zfs send -w -i $src#redaction-bookmark $src@s1 > incr"
zfs send -w -i $src#redaction-bookmark $src@s1 >$d/incr 2>$d/err; src_rc=$?
sed 's/^/  /' $d/err
if [ $src_rc = 0 ]; then
	echo "  sent $(wc -c <$d/incr) bytes"
	echo "# zfs receive $recv < incr"
	zfs receive $recv <$d/incr 2>&1 && rc=ok || rc=recvfail
else
	rc=sendfail
fi
echo
echo "--- end state ---"
echo "# zfs get -H -o name,value keystatus $src   (the key was never loaded)"
zfs get -H -o name,value keystatus $src | sed 's/^/    /'
echo "# zfs list -t snapshot -o name -r $recv   (s1 arrives only if the raw incremental worked)"
zfs list -H -t snapshot -o name -r $recv | sed 's/^/    /'
echo "# zpool status -x $pool"
zpool status -x $pool | sed 's/^/    /'
echo "--- end of the end state ---"
zpool export $pool && echo "# pool $pool exported (on $V)"
echo
case $rc in
ok) echo "RESULT OK: the raw incremental from the redaction bookmark sent and received without the key" ;;
sendfail) echo "RESULT BUG: the raw send needed the key" ;;
*) echo "RESULT ERROR: the stream was sent but did not receive"; exit 2 ;;
esac
