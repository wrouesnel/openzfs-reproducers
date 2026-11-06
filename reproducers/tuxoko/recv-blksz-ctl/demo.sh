#!/bin/bash
# demo.sh -- openzfs/zfs#18663 (@tuxoko, tuxoko/zfs recv_blksz): "Fix recv
# EINVAL/corruption when source has smaller recordsize setting".
#
# Two datasets replicate in both directions, fs0 with recordsize=64k and fs1
# with recordsize=128k.  After a reverse incremental (fs1 -> fs0) the same
# file can have 64K blocks on one side and 128K on the other.  The next
# forward incremental (fs0 -> fs1) carries an OBJECT record with
# blksz=64K for it; master's receive keeps the 128K block of a one-block
# file without freeing it, then writes only what the stream carries:
# zfs recv exits 0, the snapshot is made, the pool is clean, and the file
# on fs1 is not the file on fs0 (the loss survives export/import and scrub).
# A multi-block file gets EINVAL instead ("invalid backup stream").
#
# CONTROL PAIR (tuxoko/recv-blksz-ctl): the same demo as tuxoko/recv-blksz,
# defaulting to the embed4m case; repro = the PR without its commit
# 088fb7e3d3 ("Fix WRITE_EMBEDDED ..."), a6fad8b463, fixed = the PR head.
#
# Cases (CASES, space or comma separated; default here "embed4m"):
#   prbody2   the PR description's sequence 2, verbatim: 128K file, then
#             64K of it rewritten on fs0 (dd bs=64k count=1 conv=notrunc)
#   chmod     the same 128K file, but only `chmod 600` on fs0: the file's
#             data is not touched at all
#   multi     a 1M file, 64K rewritten at offset 0 (master: EINVAL)
#   embed4m   the -e gap from @tigerblue77's review on the PR: gzip-9, a
#             4M file (beyond the PR's lookahead), 64K of a compressible
#             pattern at 0, every send with -e, so the forward stream holds
#             WRITE_EMBEDDED lsize=64K for a 128K-block object
#             (master: EINVAL; the PR before 088fb7e3d3: VERIFY panic)
#   e.g. podman run --rm -it --device /dev/kvm -e CASES=embed4m IMAGE
# Each case recreates pool demo18663 on the run disk; every step echoes its
# command and prints `zpool status -v`.
#
# Builds:
#   repro  openzfs/zfs master at the PR's merge base
#          -> "RESULT BUG: silent data loss: ..." (recv exit 0, md5 differs)
#   fixed  the PR head (tuxoko/zfs recv_blksz)
#          -> "RESULT OK: every forward receive succeeded and fs1 matches fs0"
# A failed kernel assertion during the forward receive ends the demo with
# "RESULT BUG: kernel assertion in zfs recv (CASE): ..." (the dmesg lines).
# Run as root:  /demo/demo.sh       about a minute.
set -u
VALID="prbody2 chmod multi embed4m"
eval "$(zr env 2>/dev/null)"
CASES=${CASES:-embed4m}
P=demo18663 D=/var/tmp/demo18663
SPL_RE='PANIC at |VERIFY[0-9]*[A-Z]*[(].* failed|ASSERT[0-9]*[A-Z]*[(].* failed'
mkdir -p $D
V=${DEMO_DISK:-$D/vdev}

run() { echo "# $*"; eval "$@"; }
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
st() { echo "## zpool status -v $P"; zpool status -v $P | sed 's/^/   /'; }
die() { echo "RESULT ERROR: $*"; exit 2; }

blk() {	# blk DS: the test file's dnode (zdb): data block size, dsize, lsize
	local o; o=$(stat -c %i /$1/test 2>/dev/null) || { echo "(no file)"; return; }
	zdb -dddd "$1" "$o" 2>/dev/null | awk -v o="$o" '$1==o {print "object "o": dblk="$4" dsize="$5" lsize="$7; exit}'
}
files() {	# md5 and block size of test on both sides
	zpool sync $P
	for ds in fs0 fs1; do
		if [ -f /$P/$ds/test ]; then
			printf '   %-4s %s  size=%-8s %s\n' $ds "$(md5sum </$P/$ds/test | cut -c1-32)" "$(stat -c %s /$P/$ds/test)" "$(blk $P/$ds)"
		else
			printf '   %-4s (no file)\n' $ds
		fi
	done
}
newpool() {
	zpool destroy -f $P 2>/dev/null
	if [ -z "${DEMO_DISK:-}" ]; then rm -f $V; mkdir -p $D; truncate -s 2G $V; fi
	zpool create -f -o cachefile=none -O atime=off $P $V && [ -d /$P ] || die "could not create pool $P on $V"
}
reimport() {
	run "zpool export $P" && run "zpool import -o cachefile=none -d $(dirname $V) $P" || die "export/import failed"
}

for c in ${CASES//,/ }; do
	case " $VALID " in *" $c "*) ;; *) die "unknown case '$c' (valid: ${VALID// /,})" ;; esac
done

echo "build: ${DEMO_BUILD:-?} $(cat /etc/zfshunt-build 2>/dev/null)"
echo "cases: $CASES"
lost=() fail=() good=()

# forward NAME FLAGS: the forward incremental fs0@s01 -> fs0@s02 into fs1,
# then the comparison, export/import, scrub
forward() {
	local name=$1 fl=$2 o
	o=$(stat -c %i /$P/fs0/test)
	step "$name: forward incremental fs0@s01 -> fs0@s02 into fs1"
	echo "# zfs send $fl -i @s01 $P/fs0@s02 | zstream dump -v   (records for the file, object $o)"
	zfs send $fl -i @s01 $P/fs0@s02 | zstream dump -v 2>/dev/null |
	    grep -E "^(OBJECT|WRITE|WRITE_EMBEDDED|FREE) object = $o " | cut -c1-160 | head -8 | sed 's/^/    /'
	local out rc w=0 rp
	echo "# zfs send $fl -i @s01 $P/fs0@s02 | zfs recv $P/fs1"
	zfs send $fl -i @s01 $P/fs0@s02 >$D/fwd.zsend
	# a failed SPL assertion (VERIFY/ASSERT, "PANIC at") parks the receive
	# thread instead of panicking the kernel: watch the kernel log for it
	zfs recv $P/fs1 <$D/fwd.zsend >$D/recv.out 2>&1 &
	rp=$!
	while kill -0 $rp 2>/dev/null && [ $w -lt 300 ]; do
		if dmesg | grep -qE "$SPL_RE"; then
			sleep 2
			echo "-> the kernel hit a failed assertion during zfs recv (the receive never returns):"
			dmesg | grep -E -A12 "$SPL_RE" | head -24 | sed 's/^/   /'
			echo "RESULT BUG: kernel assertion in zfs recv ($name): $(dmesg | grep -E -m2 "$SPL_RE" | sed 's/^\[[^]]*\] //' | tr '\n' ' ')"
			exit 0
		fi
		sleep 1; w=$((w + 1))
	done
	kill -0 $rp 2>/dev/null && { dmesg | tail -30 | sed 's/^/   /'; echo "RESULT ERROR: $name: zfs recv did not finish in 300 s"; exit 2; }
	wait $rp; rc=$?
	out=$(cat $D/recv.out)
	echo "-> zfs recv exit status $rc${out:+: $out}"
	echo "# zfs list -t snapshot -o name $P/fs1"; zfs list -H -t snapshot -o name $P/fs1 | sed 's/^/   /'
	st
	local src live disk
	src=$(md5sum </$P/fs0/test | cut -c1-32)
	live=$(md5sum </$P/fs1/test 2>/dev/null | cut -c1-32)
	echo "# md5sum, size and zdb -dddd of the file on fs0 and fs1"
	files
	step "$name: export/import, scrub, compare again"
	reimport
	run "zpool scrub -w $P"
	st
	disk=$(md5sum </$P/fs1/test 2>/dev/null | cut -c1-32)
	files
	if [ $rc != 0 ]; then
		echo "-> $name: BUG: the forward receive failed (exit $rc): $out"
		fail+=("$name: zfs recv failed (exit $rc): $(echo "$out" | tail -1)")
	elif [ "$src" = "$live" ] && [ "$src" = "$disk" ]; then
		echo "-> $name: OK: zfs recv exited 0 and fs1/test is fs0/test (md5 $src)"
		good+=("$name")
	else
		local n; n=$(cmp -l /$P/fs0/test /$P/fs1/test 2>/dev/null | wc -l)
		echo "-> $name: BUG: zfs recv exited 0, the pool is clean, but fs1/test differs from fs0/test"
		echo "   ($n bytes differ; md5 fs0 $src, fs1 $live, fs1 after export/import $disk)"
		echo "# od -An -tx1 -N16 at offsets 0 and 65536 of fs1/test"
		for off in 0 65536; do echo "   @$off: $(od -An -tx1 -j$off -N16 /$P/fs1/test | tr -s ' ')"; done
		lost+=("$name: recv exit 0, md5 fs0 ${src:0:12} != fs1 ${disk:0:12}")
	fi
}

# reverse NAME FLAGS: the reverse incremental fs1@s00 -> fs1@s01 into fs0
reverse() {
	step "$1: reverse incremental fs1@s00 -> fs1@s01 into fs0"
	run "zfs send $2 -i @s00 $P/fs1@s01 | zfs recv $P/fs0" || die "$1: reverse receive failed"
	st
	files
	local b0 b1
	b0=$(blk $P/fs0 | sed -n 's/.*dblk=\([^ ]*\).*/\1/p'); b1=$(blk $P/fs1 | sed -n 's/.*dblk=\([^ ]*\).*/\1/p')
	if [ "$b0" != "$b1" ]; then
		echo "-> the same file now has $b0 blocks on fs0 and $b1 on fs1"
	else
		echo "-> both sides now keep the file in $b0 blocks (this receive gave fs0 the stream's block size)"
	fi
}

case_prbody2() {
	step "prbody2 (PR #18663 description, sequence 2): setup and full send"
	newpool
	run "zfs create -o recordsize=64k $P/fs0"
	run "zfs create -o recordsize=128k $P/fs1"
	run "dd if=/dev/urandom of=/$P/fs0/test bs=128k count=1 status=none"
	run "zfs snap $P/fs0@s00"
	run "zfs send $P/fs0@s00 | zfs recv -F $P/fs1" || die "prbody2: full receive failed"
	st
	files
	step "prbody2: rewrite the file on fs1 (it takes fs1's 128K block size)"
	run "dd if=/dev/urandom of=/$P/fs1/test bs=128k count=1 status=none"
	run "zfs snap $P/fs1@s01"
	files
	reverse prbody2 ""
	step "prbody2: on fs0, rewrite the first 64K of the file"
	run "dd if=/dev/urandom of=/$P/fs0/test bs=64k count=1 conv=notrunc status=none"
	run "zfs snap $P/fs0@s02"
	files
	forward prbody2 ""
	run "zpool export $P"
}

# onecase NAME SIZE MOD FLAGS [COMP]: fs0 rs=64k, fs1 received with
# recordsize=128k; file of SIZE; MOD on fs0 before the forward send
onecase() {
	local name=$1 size=$2 mod=$3 fl=$4 co=${5:+-o compression=$5}
	step "$name: setup and full send (file $size, sends '$fl'${5:+, compression=$5})"
	newpool
	run "zfs create -o recordsize=64k $co $P/fs0"
	run "dd if=/dev/urandom of=/$P/fs0/test bs=$size count=1 status=none"
	run "zfs snap $P/fs0@s00"
	run "zfs send $fl $P/fs0@s00 | zfs recv -o recordsize=128k $co $P/fs1" || die "$name: full receive failed"
	st
	files
	step "$name: rewrite the file on fs1 (it takes fs1's 128K block size)"
	run "dd if=/dev/urandom of=/$P/fs1/test bs=$size count=1 status=none"
	run "zfs snap $P/fs1@s01"
	files
	reverse $name "$fl"
	step "$name: on fs0: $mod"
	run "$mod"
	run "zfs snap $P/fs0@s02"
	files
	forward $name "$fl"
	run "zpool export $P"
}

for c in ${CASES//,/ }; do
	case $c in
	prbody2) case_prbody2 ;;
	chmod) onecase chmod 128k "chmod 600 /$P/fs0/test" "" ;;
	multi) onecase multi 1M "dd if=/dev/urandom of=/$P/fs0/test bs=64k count=1 conv=notrunc status=none" "" ;;
	embed4m) onecase embed4m 4M "yes A | tr -d '\\n' | head -c 65536 | dd of=/$P/fs0/test bs=64k conv=notrunc status=none" "-e" gzip-9 ;;
	esac
done

step "summary"
for g in "${good[@]}"; do echo "   OK   $g"; done
for b in "${lost[@]}"; do echo "   BUG  $b (silent data loss)"; done
for b in "${fail[@]}"; do echo "   BUG  $b"; done
if [ ${#lost[@]} -gt 0 ]; then
	echo "RESULT BUG: silent data loss: $(IFS=';'; echo "${lost[*]}")${fail[*]:+; also $(IFS=';'; echo "${fail[*]}")}"
elif [ ${#fail[@]} -gt 0 ]; then
	echo "RESULT BUG: $(IFS=';'; echo "${fail[*]}")"
else
	echo "RESULT OK: every forward receive succeeded and fs1 matches fs0 (${good[*]})"
fi
