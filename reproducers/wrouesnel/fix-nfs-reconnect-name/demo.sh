#!/bin/bash
# demo.sh -- openzfs #18134 / #16254: an NFS server reconnecting directories
# in one large ZFS directory.
#
# When nfsd gets a file handle for a directory whose dentry the server has
# reclaimed (memory pressure; here drop_caches), the kernel must reconnect
# it: find its name in its parent (zpl_get_name -> zap_value_search), a
# linear search of the parent's entries.  On master that search walks a ZAP
# cursor that takes and drops the ZAP and leaf locks for every entry, so
# several nfsd threads searching the same big directory fight over those
# locks: each search gets several times slower, and the server burns more
# CPU for the same work.  The fix (fix-nfs-reconnect-name) searches a whole
# ZAP leaf at a time with the locks taken once per leaf.  The search is
# still linear (as on ext4); what goes away is the contention.
#
# Steps:
#   1. pool on the run disk; a dataset /exp with 100,000 empty directories
#   2. NFSv3 server on loopback (rpcbind, mountd, nfsd); the client mounts
#      /exp with lookupcache=none,actimeo=0
#   3. three rounds of two storms, each 1000 reconnects:
#        1 client: it holds 1000 directories spread over /exp/big, the
#          server drops its caches, the client touches each directory, so
#          nfsd reconnects each one (1000 searches of the 100,000 entries)
#        4 clients: the same 1000 reconnects from 4 clients at once, while
#          the server times mkdir in /exp/big (it waits for the searches:
#          they hold the directory's lock shared)
#      per reconnect = the median lookup time seen by the client
#   4. RATIO = median over the rounds of (4 clients' per reconnect / 1 client's)
#        bug: >= 1.8 (the searches slow each other down)
#        fix: <  1.3 (flat)
#      in between: three more rounds, then RESULT ERROR (inconclusive)
#
# The RESULT compares the two storms of one run on one machine, never
# absolute times, so it doesn't depend on how fast the host is.
# Run as root:  /demo/demo.sh       about 2-3 minutes on master.
set -u
P=nrdemo FS=nrdemo/exp EXP=/exp BIG=/exp/big MNT=/mnt/nfs
N=100000 HELD=1000 ROUNDS=3
BUG_RATIO=1.8 OK_RATIO=1.3
NR=/demo/nr.py

run() { echo "# $*"; "$@"; }
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
note() { echo "   $*"; }
die() { echo "RESULT ERROR: $*"; cleanup; exit 2; }
cleanup() {
	umount -l $MNT 2>/dev/null
	exportfs -ua 2>/dev/null
	rpc.nfsd 0 2>/dev/null
	zpool export $P 2>/dev/null
}

nfs_start() {
	run modprobe nfsd || return 1
	run modprobe nfsv3 || return 1
	grep -q ' /proc/fs/nfsd ' /proc/mounts || run mount -t nfsd nfsd /proc/fs/nfsd || return 1
	ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 up
	# what a distribution's packages would set up: rpcbind's user, the
	# RPC transports (libtirpc's /etc/netconfig), nfs-utils' state files
	grep -q '^_rpc:' /etc/passwd || echo '_rpc:x:998:65534::/run/rpcbind:/bin/false' >>/etc/passwd
	[ -f /etc/netconfig ] || cat >/etc/netconfig <<'NC'
udp        tpi_clts      v     inet     udp     -       -
tcp        tpi_cots_ord  v     inet     tcp     -       -
udp6       tpi_clts      v     inet6    udp     -       -
tcp6       tpi_cots_ord  v     inet6    tcp     -       -
rawip      tpi_raw       -     inet      -      -       -
local      tpi_cots_ord  -     loopback  -      -       -
unix       tpi_cots_ord  -     loopback  -      -       -
NC
	mkdir -p /var/lib/nfs/sm /var/lib/nfs/sm.bak /run/rpcbind $MNT
	touch /var/lib/nfs/etab /var/lib/nfs/rmtab /etc/exports
	run rpcbind || return 1
	run exportfs -o rw,no_root_squash,no_subtree_check,fsid=21 127.0.0.1:$EXP || return 1
	run rpc.mountd -N 4 || return 1
	run rpc.nfsd -N 4 16 || return 1
	run mount.nfs 127.0.0.1:$EXP $MNT -o vers=3,nolock,lookupcache=none,actimeo=0 || return 1
}

hdr() {
	printf '\n %5s %7s %10s %13s %8s %7s %14s %6s\n' round clients reconnects "per reconnect" "nfsd CPU" wall "mkdir med/max" "4 : 1"
	printf ' %5s %7s %10s %13s %8s %7s %14s %6s\n' ----- ------- ---------- ------------- -------- ------- -------------- ------
}
row() {	# ROUND CLIENTS [RATIO]: the row of the last storm (S_*)
	local w=-
	[ "$S_WN" -gt 0 ] && w="$S_WMED/$S_WMAX ms"
	printf ' %5s %7s %10s %10s ms %6s s %5s s %14s %6s\n' "$1" "$2" "$S_OPS" "$S_MED" "$S_CPU" "$S_WALL" "$w" "${3:-}"
}
storm() {	# CLIENTS WRITER: one storm; sets S_OPS S_MED ... from nr.py
	local out
	out=$(python3 $NR storm $MNT/big $BIG $N $HELD "$1" "$2") || die "the storm with $1 client(s) failed"
	eval "$(echo "$out" | sed 's/\([A-Z0-9]*\)=/S_\1=/g')"
	[ "$S_OPS" = "$HELD" ] || die "the storm made $S_OPS lookups, not $HELD"
}
measure() {	# STEP: ROUNDS rounds of (1 client, 4 clients); sets RATIO (their median)
	local r m1 c1 ratios=
	CPU1= CPU4=
	step "$1. $ROUNDS rounds: $HELD reconnects from 1 client, then the same $HELD from 4 clients"
	note "Each storm: the clients hold $HELD directories spread over $BIG ($N"
	note "entries), the server drops its caches (echo 2 > /proc/sys/vm/drop_caches),"
	note "then each client looks up a name in every directory it holds.  Each lookup"
	note "makes nfsd reconnect a directory: search $BIG for its name (on average"
	note "half of its entries).  1 client: one search at a time.  4 clients: 4 at once"
	note "($((HELD / 4)) each), while the server times mkdir in $BIG (it waits for them)."
	note
	note "per reconnect: the median time of one lookup, seen by the client."
	note "Look at the '4 : 1' column (4 clients' per reconnect / 1 client's): on master"
	note "the concurrent searches fight over the ZAP's locks and each takes 2-3 times as"
	note "long as alone (nfsd CPU grows too, for the same work); with the fix it stays"
	note "about 1."
	hdr
	for r in $(seq $ROUNDS); do
		storm 1 0; m1=$S_MED c1=$S_CPU
		row "$r" 1
		storm 4 1
		R=$(awk -v a="$S_MED" -v b="$m1" 'BEGIN { printf "%.2f", a / b }')
		row "$r" 4 "${R}x"
		ratios="$ratios $R"
		CPU1="$CPU1 $c1" CPU4="$CPU4 $S_CPU"
	done
	RATIO=$(echo $ratios | tr ' ' '\n' | sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }')
	echo
	note "4 : 1 per round:$ratios  ->  median ${RATIO}x"
}

cleanup 2>/dev/null
zpool destroy -f $P 2>/dev/null

step "1. pool $P on $DEMO_DISK; $FS with $N empty directories in $BIG"
run zpool create -f -O mountpoint=none $P $DEMO_DISK || die "could not create $P"
run zfs create -o mountpoint=$EXP -o atime=off $FS || die "could not create $FS"
echo "# python3 $NR mkdirs $BIG $N"
python3 $NR mkdirs $BIG $N || die "could not create the directories"
run zpool sync $P
note "$(ls -f $BIG | wc -l) entries in $BIG (with . and ..)"
zfs list -o name,used,mountpoint $FS | sed 's/^/   /'

step "2. NFSv3 server on loopback, client mount on $MNT"
nfs_start || die "could not start the NFS server or mount it"
note "$(grep " $MNT " /proc/mounts)"
note "nfsd threads: $(cat /proc/fs/nfsd/threads)"

measure 3
if awk -v r="$RATIO" -v b="$BUG_RATIO" -v o="$OK_RATIO" 'BEGIN { exit !(r >= o && r < b) }'; then
	note "inconclusive: ${RATIO}x is between $OK_RATIO and $BUG_RATIO; measuring once more"
	measure 4
fi

cleanup
echo
CR=$(echo $CPU1 $CPU4 | awk '{ n = NF / 2; for (i = 1; i <= n; i++) { a += $i; b += $(i + n) } if (a > 0) printf "%.2f", b / a; else print "-" }')
echo "per reconnect, 4 clients / 1 client (median of $ROUNDS rounds): ${RATIO}x   (nfsd CPU for the same work: ${CR}x)"
echo "thresholds: >= ${BUG_RATIO}x the searches slow each other down (bug); < ${OK_RATIO}x flat (fixed)"
# (the RESULT line is kept short: the launcher reads the console while it
# is being written)
if awk -v r="$RATIO" -v b="$BUG_RATIO" 'BEGIN { exit !(r >= b) }'; then
	echo "-> the concurrent searches slow each other down"
	echo "RESULT BUG: 4 clients ${RATIO}x per reconnect"
elif awk -v r="$RATIO" -v o="$OK_RATIO" 'BEGIN { exit !(r < o) }'; then
	echo "-> flat: the concurrent searches don't slow each other down"
	echo "RESULT OK: 4 clients ${RATIO}x per reconnect"
else
	echo "-> inconclusive twice: between $OK_RATIO and $BUG_RATIO"
	echo "RESULT ERROR: 4 clients ${RATIO}x per reconnect"
fi
