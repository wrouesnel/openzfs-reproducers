#!/bin/bash
# demo.sh -- openzfs #16254 / #18134: reconnecting NFS directories with a
# directory entry cookie.
#
# When nfsd gets a file handle for a directory whose dentry the server has
# reclaimed, the kernel reconnects it: it asks ZFS for the directory's name
# in its parent (zpl_get_name).  On master that is a search of the parent's
# entries (zap_value_search), so each reconnect costs time proportional to
# the size of the parent directory.  The fix branch (fix-nfs-reconnect-hint-v3)
# records in every object a hint, the system attribute ZPL_PARENT_COOKIE:
# the cookie (hash, collision differentiator) of the directory entry that
# last linked it into its parent.  get_name looks up that one entry, checks
# that it refers to the object, and only searches when it doesn't.  So a
# reconnect costs the same in any directory size.
#
# Steps:
#   1. pool on the run disk; dataset /exp with three directories of
#      10,000, 100,000 and 1,000,000 entries (HELD of them directories, the
#      rest empty files)
#   2. NFSv3 server on loopback; the client mounts /exp with
#      lookupcache=none,actimeo=0
#   3. scaling: in each directory, HELD reconnects from 1 client, then the
#      same HELD from 4 clients at once.  per reconnect = the median lookup
#      time seen by the client.  RATIO = per reconnect in the largest
#      directory / in the smallest, for 1 client and for 4 clients
#   4. correctness: renames (within and between directories, in the big
#      directories too), a RENAME_EXCHANGE, a hard link, a hint made stale
#      by an unlink whose name is then reused by another file, and a
#      directory renamed with zfs_parent_cookie=0 (as an implementation
#      that doesn't know the hint renames: its hint goes stale).  For each
#      object: zdb's path (zfs_obj_to_path) and `cookie` line (fixed build:
#      the cookie and "valid" or "stale", checked by zdb); for each
#      directory: the path the kernel reconnects from its file handle (on
#      the server) with the dirent_name kstat counts of that reconnect
#      (fixed build: names found by cookie, or searched for a stale
#      cookie), and the NFS client's view after a server cache drop
#   5. RESULT, from the ratios (not absolute times) and the paths:
#        bug: both ratios >= 10 (reconnects grow with the directory)
#        fix: both ratios < 3 (flat) and every path right, every cookie
#             valid except the two stale ones, and only those searched
#      in between: the scaling step once more, then RESULT ERROR
#      any wrong path: RESULT ERROR (on either build)
#
# Run as root:  /demo/demo.sh       about 2.5-3 minutes on master, 1-1.5 fixed.
set -u
P=nrdemo FS=nrdemo/exp EXP=/exp MNT=/mnt/nfs
SIZES="10000 100000 1000000" HELD=400
BUG_RATIO=10 OK_RATIO=3
NR=/demo/nr.py

KSTAT=/proc/spl/kstat/zfs/dirent_name
run() { echo "# $*"; "$@"; }
# names found by cookie and directory searches so far (zfs_dirent_name()),
# or nothing on a build without the dirent_name kstat (master)
kst() { [ -r $KSTAT ] && awk '$1 == "cookie_hits" { h = $3 } $1 == "searches" { s = $3 } END { print h, s }' $KSTAT; }
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
note() { echo "   $*"; }
look() { echo "   >> $*"; }
die() { echo "RESULT ERROR: $*"; cleanup; exit 2; }
cleanup() {
	umount -l $MNT 2>/dev/null
	exportfs -ua 2>/dev/null
	rpc.nfsd 0 2>/dev/null
	zpool export $P 2>/dev/null
}
dname() { case $1 in 10000) echo n10k ;; 100000) echo n100k ;; 1000000) echo n1m ;; *) echo "n$1" ;; esac; }

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

storm() {	# N CLIENTS: one storm in directory N; sets S_OPS S_MED ... S_KST
	local out k0 k1
	k0=$(kst)
	out=$(python3 $NR storm $MNT/"$(dname "$1")" "$1" $HELD "$2") || die "the storm in $(dname "$1") with $2 client(s) failed"
	k1=$(kst)
	S_KST=-
	[ -n "$k0" ] && S_KST=$(echo $k0 $k1 | awk '{ printf "%d/%d", $3 - $1, $4 - $2 }')
	eval "$(echo "$out" | sed 's/\([A-Z0-9]*\)=/S_\1=/g')"
	[ "$S_OPS" = "$HELD" ] || die "the storm made $S_OPS lookups, not $HELD"
}
scaling() {	# STEP: storms in every directory; sets R1 R4 (largest N / smallest N)
	local n c base1= base4= r
	step "$1. scaling: $HELD reconnects per storm, in each directory, from 1 client and from 4"
	note "Each storm: the clients hold $HELD directories spread over the directory,"
	note "the server drops its caches (echo 2 > /proc/sys/vm/drop_caches), then each"
	note "client looks up a name in every directory it holds; each lookup makes nfsd"
	note "reconnect a directory: find its name in its parent (zpl_get_name)."
	note "per reconnect = the median time of one lookup, seen by the client."
	look "Look at 'x smallest': per reconnect divided by the same column in the"
	look "10,000-entry directory.  master searches the parent's entries, so it grows"
	look "with the directory (about 100x from 10k to 1M); with the cookie it stays"
	look "about 1x (one entry lookup; the NFS round trip dominates)."
	look "'cookie/search' (fixed build): names ZFS found by cookie / by searching"
	look "the directory during the storm (dirent_name kstat); master has no such"
	look "kstat ('-') and searches every time."
	printf '\n %9s %7s %10s %13s %10s %9s %7s %10s %13s\n' entries clients reconnects "per reconnect" p90 "nfsd CPU" wall "x smallest" cookie/search
	printf ' %9s %7s %10s %13s %10s %9s %7s %10s %13s\n' --------- ------- ---------- ------------- ---------- --------- ------- ---------- -------------
	for n in $SIZES; do
		for c in 1 4; do
			storm "$n" "$c"
			if [ "$c" = 1 ]; then
				[ -n "$base1" ] || base1=$S_MED
				r=$(awk -v a="$S_MED" -v b="$base1" 'BEGIN { printf "%.2f", a / b }')
				R1=$r
			else
				[ -n "$base4" ] || base4=$S_MED
				r=$(awk -v a="$S_MED" -v b="$base4" 'BEGIN { printf "%.2f", a / b }')
				R4=$r
			fi
			printf ' %9s %7s %10s %10s ms %7s ms %7s s %5s s %9sx %13s\n' "$n" "$c" "$S_OPS" "$S_MED" "$S_P90" "$S_CPU" "$S_WALL" "$r" "$S_KST"
		done
	done
	echo
	note "largest / smallest directory, per reconnect: 1 client ${R1}x, 4 clients ${R4}x"
}
verdict() {	# bug | ok | mid, from R1 R4
	awk -v a="$R1" -v b="$R4" -v hi="$BUG_RATIO" -v lo="$OK_RATIO" 'BEGIN {
		if (a >= hi && b >= hi) print "bug"; else if (a < lo && b < lo) print "ok"; else print "mid" }'
}

cleanup 2>/dev/null
zpool destroy -f $P 2>/dev/null

step "1. pool $P on $DEMO_DISK; $FS with directories of $(echo $SIZES | sed 's/ /, /g') entries"
run zpool create -f -O mountpoint=none $P $DEMO_DISK || die "could not create $P"
run zfs create -o mountpoint=$EXP -o atime=off $FS || die "could not create $FS"
for n in $SIZES; do
	echo "# python3 $NR fill $EXP/$(dname "$n") $n $HELD"
	python3 $NR fill $EXP/"$(dname "$n")" "$n" $HELD || die "could not fill $(dname "$n")"
done
run zpool sync $P
zfs list -o name,used,mountpoint $FS | sed 's/^/   /'

step "2. NFSv3 server on loopback, client mount on $MNT"
nfs_start || die "could not start the NFS server or mount it"
note "$(grep " $MNT " /proc/mounts)"

scaling 3
V=$(verdict)
if [ "$V" = mid ]; then
	note "inconclusive (between ${OK_RATIO}x and ${BUG_RATIO}x): measuring once more"
	scaling 3b
	V=$(verdict)
fi

step "4. correctness: renames, RENAME_EXCHANGE, a hard link, stale hints"
C=$EXP/c
mkdir -p $C/a $C/b
for d in a/d1 a/d2 a/d3 a/d4 a/e1 b/e2; do mkdir $C/$d; echo "$d" >$C/$d/id; done
touch $C/a/f1 $C/a/f2
mv $EXP/n100k/d0000000 $C/a/from-100k-tmp
echo n100k/d0000000 >$C/a/from-100k-tmp/id
echo n1m/d0000000 >$EXP/n1m/d0000000/id
run mv $C/a/d1 $C/b/d1-moved
run mv $C/a/d2 $C/a/d2-renamed
echo "# renameat2 $C/a/e1 $C/b/e2 RENAME_EXCHANGE"
python3 $NR exchange $C/a/e1 $C/b/e2 || die "RENAME_EXCHANGE failed"
run ln $C/a/f1 $C/b/f1-link
run ln $C/a/f2 $C/a/f2-tmp
run rm $C/a/f2-tmp
run touch $C/a/f2-tmp
run mv $C/a/from-100k-tmp $C/b/from-100k
run mv $EXP/n1m/d0000000 $EXP/n1m/d-renamed
# zfs_parent_cookie=0: renames leave the hint as an implementation that
# doesn't know it does (fixed build only; master has no such parameter)
PC=/sys/module/zfs/parameters/zfs_parent_cookie
[ -w $PC ] && run sh -c "echo 0 > $PC"
run mv $C/a/d4 $C/b/d4-stale
[ -w $PC ] && run sh -c "echo 1 > $PC"
run zpool sync $P
note
note "a/d3          created, never renamed"
note "b/d1-moved    was a/d1 (renamed into another directory)"
note "a/d2-renamed  was a/d2 (renamed in its directory)"
note "a/e1, b/e2    exchanged (RENAME_EXCHANGE): a/e1 is the old b/e2 and back"
note "b/from-100k   was n100k/d0000000 (moved out of the 100,000-entry directory)"
note "n1m/d-renamed was n1m/d0000000 (renamed in the 1,000,000-entry directory)"
note "a/f1          file, hard-linked as b/f1-link: the newest link's name counts"
note "a/f2          file; a link a/f2-tmp made and removed, then a new file got"
note "              that name: the hint of a/f2 now names another object's entry"
note "b/d4-stale    was a/d4, renamed with zfs_parent_cookie=0: its hint still"
note "              names the removed a/d4 entry"
look "Look at 'ok': every object's path must be right on both builds.  'cookie'"
look "is zdb's new line (the fixed build only; master prints none: '-'): zdb"
look "looks up the entry at the cookie and prints 'valid' if it is the object's."
look "a/f2's cookie names the reused a/f2-tmp entry and b/d4-stale's a removed"
look "entry: both 'stale', rejected, and the names are found by searching."
look "'names by' (fixed build): how ZFS found the names while the server"
look "reconnected the directory and its parents: by cookie, or by a search."

# object  expected path (from /exp)  expected id (directories) | - (files)
#   expected cookie on the fixed build
OBJS="a/d3:c/a/d3:a/d3:valid b/d1-moved:c/b/d1-moved:a/d1:valid
a/d2-renamed:c/a/d2-renamed:a/d2:valid a/e1:c/a/e1:b/e2:valid b/e2:c/b/e2:a/e1:valid
b/from-100k:c/b/from-100k:n100k/d0000000:valid n1m/d-renamed:n1m/d-renamed:n1m/d0000000:valid
b/d4-stale:c/b/d4-stale:a/d4:stale a/f1:c/b/f1-link:-:valid a/f2:c/a/f2:-:stale
a/f2-tmp:c/a/f2-tmp:-:valid"
dirs=() cdirs=()
for o in $OBJS; do
	IFS=: read -r name path id cs <<<"$o"
	[ "$id" != - ] && dirs+=("$EXP/$path") cdirs+=("$MNT/$path")
done
FIXED=no
[ -r $KSTAT ] && FIXED=yes
H=$(python3 $NR handles $EXP "${dirs[@]}") || die "the file handle check failed"
K=$(python3 $NR nfscheck "${cdirs[@]}") || die "the NFS client check failed"
printf '\n %-14s %-18s %-16s %-30s %-16s %-16s %s\n' object "zdb path" "zdb cookie" "handle (server)" "names by" "NFS client: id" ok
printf ' %-14s %-18s %-16s %-30s %-16s %-16s %s\n' -------------- ------------------ ---------------- ------------------------------ ---------------- ---------------- --
BAD=0
for o in $OBJS; do
	IFS=: read -r name path id cs <<<"$o"
	if [ "$name" = n1m/d-renamed ]; then f=$EXP/n1m/d-renamed; else f=$EXP/c/$name; fi
	[ "$name" = a/f1 ] && f=$EXP/c/b/f1-link
	obj=$(stat -c %i "$f")
	z=$(zdb -ddddd $FS "$obj" 2>/dev/null)
	zp=$(echo "$z" | awk '$1 == "path" { print $2; exit }')
	zc=$(echo "$z" | awk '$1 == "cookie" { print $2 " " $3; exit }')
	zs=${zc#* }
	ok=yes
	[ "$zp" = "/$path" ] || ok=NO
	# the fixed build: zdb's verdict on the cookie
	[ $FIXED = yes ] && [ "$zs" != "$cs" ] && ok=NO
	hp=- kc=- how=-
	if [ "$id" != - ]; then
		hp=$(echo "$H" | awk -F'\t' -v p="$EXP/$path" '$1 == p { print $2 }')
		how=$(echo "$H" | awk -F'\t' -v p="$EXP/$path" '$1 == p { print $3 }')
		kc=$(echo "$K" | awk -F'\t' -v p="$MNT/$path" '$1 == p { print $2 }')
		[ "$hp" = "$EXP/$path" ] || ok=NO
		[ "$kc" = "$id" ] || ok=NO
		if [ "$how" != - ]; then
			# kstat counts: cookie hits, stale, missing, searches; a
			# valid cookie (and valid parents) must need no search,
			# a stale one exactly one
			read -r kh kstale kmiss ksearch <<<"$how"
			want=0; [ "$cs" = stale ] && want=1
			{ [ "$kstale" = "$want" ] && [ "$ksearch" = "$want" ] &&
			    [ "$kmiss" = 0 ] && [ "$kh" -ge 1 ]; } || ok=NO
			how="$kh cookie, $ksearch search"
		fi
	fi
	[ "$ok" = yes ] || BAD=$((BAD + 1))
	printf ' %-14s %-18s %-16s %-30s %-16s %-16s %s\n' "$name" "${zp:-?}" "${zc:--}" "${hp#$EXP/}" "$how" "$kc" "$ok"
done
echo
note "(zdb path: relative to $FS; zdb cookie: the hint and zdb's check of it;"
note " handle: the path the server kernel reconnected for the directory's file"
note " handle after a cache drop, relative to $EXP; names by: the dirent_name"
note " kstat during that reconnect (the directory and its parents); NFS client:"
note " the 'id' file read through the client's directory fd after a server"
note " cache drop)"
note "$BAD wrong of $(echo $OBJS | wc -w) objects"

cleanup
echo
echo "per reconnect, largest / smallest directory: 1 client ${R1}x, 4 clients ${R4}x"
echo "thresholds: both >= ${BUG_RATIO}x grows with the directory (bug); both < ${OK_RATIO}x flat (fixed)"
# (the RESULT line is kept short: the launcher reads the console while it
# is being written)
if [ "$BAD" -gt 0 ]; then
	echo "-> $BAD wrong path(s): neither build may get a path wrong"
	echo "RESULT ERROR: $BAD wrong paths"
elif [ "$V" = bug ]; then
	echo "-> reconnects grow with the directory size; all paths right"
	echo "RESULT BUG: 1M/10k ${R1}x"
elif [ "$V" = ok ]; then
	echo "-> reconnects cost the same in any directory size; all paths right"
	echo "RESULT OK: 1M/10k ${R1}x"
else
	echo "-> inconclusive twice: between ${OK_RATIO}x and ${BUG_RATIO}x"
	echo "RESULT ERROR: 1M/10k ${R1}x"
fi
