#!/bin/bash
# demo.sh -- bug #237, fix-recv-write-compress-type: zfs recv accepts a
# compressed (zfs send -c) DRR_WRITE record whose compression type the
# receiver cannot read back.  recv_check_drr_write() only checks that the
# type is below ZIO_COMPRESS_FUNCTIONS, and the record's payload is stored
# as-is with that type in the block pointer.
#
# The streams are the ZTS fixtures of the branch's test
# (rsend/recv_write_compress_neg): a genuine `zfs send -c` stream of a
# 16384-byte text file (`seq 1 5000 | head -c 16384`) in an lz4 dataset,
# whose file record (lsize 16384, compressed size 13824, lz4 = 15) has had
# only its compression type changed, and the stream checksums recomputed:
#   write-compress-off   type OFF (2): payload smaller than the logical size
#   write-compress-on    type ON (1): a property value, not an algorithm
# No sender produces either record.
#
# Steps: make the same file in an lz4 dataset and receive its genuine
# zfs send -c stream (the control), then receive each crafted stream and
# read the file back after an export/import, printing zpool status -v
# after each step.
# Builds:
#   repro: the branch's test commit (master code)
#     -> both crafted streams are received; the OFF file reads back 16384
#        bytes that are not the file (wrong md5: the read runs past the
#        13824-byte payload, returning uninitialized/stale buffer
#        contents), the ON file fails with EIO: "RESULT BUG"
#   fixed: the branch head
#     -> zfs recv rejects both ("DRR_WRITE has invalid compression type
#        2" / "... 1"), no dataset is left, the control still receives
#        intact: "RESULT OK"
# Pool demo237 on the run disk $DEMO_DISK, or on /var/tmp/demo237/vdev.
set -u
D=/var/tmp/demo237; P=demo237
V=${DEMO_DISK:-$D/vdev}
S=$(cd "$(dirname "$0")" && pwd)
zpool destroy -f $P 2>/dev/null; rm -rf $D; mkdir -p $D
[ -n "${DEMO_DISK:-}" ] || truncate -s 1G $V
run() { echo "# $*"; "$@"; }
status() { echo "# zpool status -v $P"; zpool status -v $P | sed 's/^/    /'; }
reimport() {
	zpool export $P && zpool import -o cachefile=none -d "$(dirname $V)" $P 2>/dev/null ||
	    zpool import -o cachefile=none $P
}
zpool create -f -o cachefile=none $P $V && [ -d /$P ] ||
    { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
echo "pool $P on $V; build: $(cat /etc/zfshunt-build 2>/dev/null)"

echo
echo "== control: the genuine zfs send -c stream of the same file"
run zfs create -o compression=lz4 $P/src
seq 1 5000 | head -c 16384 >/$P/src/file
want=$(md5sum </$P/src/file | cut -d' ' -f1)
echo "source file: $(stat -c %s /$P/src/file) bytes, md5 $want"
run zfs snapshot $P/src@s
zfs send -c $P/src@s >$D/good.zsend
echo "# zstream dump -v good.zsend | grep 'WRITE object = 2 '"
zstream dump -v $D/good.zsend | grep -E '^WRITE .*object = 2 ' | sed 's/^/    /'
run zfs recv $P/good <$D/good.zsend
reimport
got=$(md5sum </$P/good/file | cut -d' ' -f1)
echo "received file: $(stat -c %s /$P/good/file) bytes, md5 $got"
status
ok=1; [ "$got" = "$want" ] || { ok=0; echo "control: md5 differs"; }

bug= rejected=
for t in off on; do
	f=write-compress-$t
	echo
	echo "== $f: compression type $( [ $t = off ] && echo 'OFF (2)' || echo 'ON (1)')"
	bzcat <$S/$f.zsend.bz2 >$D/$f.zsend
	echo "# zstream dump -v $f.zsend | grep 'WRITE object = 2 '"
	zstream dump -v $D/$f.zsend 2>&1 | grep -E '^WRITE .*object = 2 |invalid|rror' | sed 's/^/    /'
	echo "# zfs recv $P/$t <$f.zsend"
	if zfs recv $P/$t <$D/$f.zsend >$D/err 2>&1; then
		echo "    accepted"
		reimport
		echo "# cat /$P/$t/file | md5sum"
		if cat /$P/$t/file >$D/out 2>$D/rerr; then
			m=$(md5sum <$D/out | cut -d' ' -f1)
			echo "    read OK: $(stat -c %s $D/out) bytes, md5 $m (source $want)"
			if [ "$m" = "$want" ]; then
				echo "    (the data is right)"
			else
				echo "    first bytes read:"; head -c 64 $D/out | od -An -c | head -4 | sed 's/^/      /'
				bug="$bug $f: received, file reads back wrong data (md5 $m, source $want);"
			fi
		else
			echo "    read FAILED: $(head -1 $D/rerr)"
			bug="$bug $f: received, file read fails ($(head -1 $D/rerr | sed 's/.*: //'));"
		fi
	else
		echo "    rejected: $(head -1 $D/err)"
		zfs list $P/$t >/dev/null 2>&1 && { ok=0; echo "    but $P/$t exists"; } ||
		    echo "    no dataset $P/$t left behind"
		grep -q "invalid compression type" $D/err || { ok=0; echo "    unexpected message"; }
		rejected="$rejected $f"
	fi
	status
done

echo
run zfs list -r -o name,used,compression $P
zpool export $P
if [ -n "$bug" ]; then
	echo "RESULT BUG:$bug"
elif [ $ok = 1 ]; then
	echo "RESULT OK: zfs recv rejected$rejected (invalid compression type); the genuine stream received intact (md5 $got)"
else
	echo "RESULT ERROR: see above"
fi
