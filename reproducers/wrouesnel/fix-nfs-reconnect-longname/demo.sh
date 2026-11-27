#!/bin/bash
# demo.sh -- an NFS client's file goes stale (ESTALE) when the server
# reconnects it by a link name longer than NAME_MAX, though the file has a
# short name in the same directory.
#
# With subtree_check, knfsd reconnects a file whose dentry it reclaimed: it
# asks the file system for the file's name in its parent (zpl_get_name), in
# a buffer of NAME_MAX + 1 (256) bytes.  With longname=on a file can have a
# link longer than that.  master's zap_value_search() returns ENAMETOOLONG
# for the first entry it finds with the file's object number, without
# looking further, so nfsd answers ESTALE when that entry is the long link,
# even though the short one fits.  The fix skips names that don't fit and
# fails only if none does.
#
# Steps:
#   1. pool, dataset /exp with longname=on; docs/report.txt and a hard link
#      to it with a 300-byte name; the long name is chosen so that it comes
#      before report.txt in the directory's order (ls -f), the order the
#      search visits entries in
#   2. NFSv3 server on loopback, exported rw,subtree_check; the client
#      mounts it with actimeo=0,lookupcache=none
#   3. the client opens docs/report.txt and reads it; once nfsd's file
#      cache has let the file go (about 10 seconds), the server drops its
#      caches (echo 2 > /proc/sys/vm/drop_caches); the client stats and
#      reads its open file again, which makes nfsd reconnect the file
#   4. RESULT BUG if the client gets ESTALE, OK if it reads the file
#
# Run as root:  /demo/demo.sh       about 45 seconds.
set -u
P=lndemo FS=lndemo/exp EXP=/exp MNT=/mnt/nfs
KSTAT=/proc/spl/kstat/zfs/dirent_name

run() { echo "# $*"; "$@"; }
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

nfs_start() {
	run modprobe nfsd || return 1
	run modprobe nfsv3 || return 1
	grep -q ' /proc/fs/nfsd ' /proc/mounts || run mount -t nfsd nfsd /proc/fs/nfsd || return 1
	ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 up
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
	run exportfs -o rw,no_root_squash,subtree_check,fsid=22 127.0.0.1:$EXP || return 1
	run rpc.mountd -N 4 || return 1
	run rpc.nfsd -N 4 4 || return 1
	run mount.nfs 127.0.0.1:$EXP $MNT -o vers=3,nolock,lookupcache=none,actimeo=0 || return 1
}

cleanup 2>/dev/null
zpool destroy -f $P 2>/dev/null

step "1. pool $P; $FS (longname=on): docs/report.txt and a 300-byte hard link to it"
run zpool create -f -O mountpoint=none $P $DEMO_DISK || die "could not create $P"
run zfs create -o mountpoint=$EXP -o longname=on $FS || die "could not create $FS"
run mkdir $EXP/docs
echo "quarterly numbers" >$EXP/docs/report.txt
pad=$(printf 'x%.0s' {1..290})
long=
for i in $(seq 1 200); do
	cand=$(printf 'long-%04d-%s' $i "$pad")
	ln $EXP/docs/report.txt "$EXP/docs/$cand" || die "ln failed"
	# the long link must come first in the directory's order
	first=$(ls -f $EXP/docs | grep -v '^\.\.\?$' | head -1)
	[ "$first" = "$cand" ] && { long=$cand; break; }
	rm "$EXP/docs/$cand"
done
[ -n "$long" ] || die "no long name came before report.txt in 200 tries"
note "docs/, in directory order (ls -f), with name lengths:"
ls -f $EXP/docs | grep -v '^\.\.\?$' | while read -r n; do printf '      %4d  %.40s%s\n' ${#n} "$n" "$([ ${#n} -gt 40 ] && echo ...)"; done
run stat -c '   inode %i, %h links: %n' $EXP/docs/report.txt
look "Both names are links to one file.  The long one is ${#long} bytes, more than"
look "NAME_MAX (255), and comes first in the directory."

step "2. NFSv3 server on loopback, exported with subtree_check; client mount"
nfs_start || die "could not start NFS"
run grep $MNT /proc/mounts

step "3. the client opens docs/report.txt; the server drops its caches; the client reads it again"
k0=$([ -r $KSTAT ] && awk '$1=="cookie_hits"{h=$3} $1=="searches"{s=$3} END{print h+0, s+0}' $KSTAT)
out=$(python3 - $MNT/docs/report.txt <<'PY'
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
print("   client: opened, read %r" % os.pread(fd, 64, 0).decode().strip())
sys.stdout.flush()
# nfsd keeps the files it read open for a few seconds (its file cache),
# which keeps their dentries; then drop the server's caches
time.sleep(12)
for i in range(2):
    with open("/proc/sys/vm/drop_caches", "w") as f:
        f.write("2")
    time.sleep(1)
print("   server: waited for nfsd's file cache, dropped its dentry and inode caches")
try:
    st = os.fstat(fd)
    data = os.pread(fd, 64, 0).decode().strip()
    print("   client: fstat ok (inode %d, %d links), read %r" %
          (st.st_ino, st.st_nlink, data))
    print("STATE ok")
except OSError as e:
    print("   client: %s" % e)
    print("STATE %s" % ("estale" if e.errno == 116 else "error %d" % e.errno))
PY
)
echo "$out" | grep -v '^STATE'
state=$(echo "$out" | sed -n 's/^STATE //p')
reconnected=unknown
if [ -n "$k0" ]; then
	k1=$(awk '$1=="cookie_hits"{h=$3} $1=="searches"{s=$3} END{print h+0, s+0}' $KSTAT)
	echo $k0 $k1 | awk '{ printf "   server: dirent_name kstat: cookie_hits +%d, searches +%d\n", $3 - $1, $4 - $2 }'
	# on a build with the kstat, a name lookup shows that nfsd reconnected
	reconnected=$(echo $k0 $k1 | awk '{ print ($3 - $1 + $4 - $2 > 0) ? "yes" : "no" }')
fi
look "nfsd had to reconnect report.txt (subtree_check) by asking ZFS for its name."
look "master returns ENAMETOOLONG for the first entry it finds, the long link, so"
look "nfsd answers ESTALE; the fix finds report.txt, the name that fits."
run ls -l $EXP/docs/report.txt

cleanup
echo
case $state in
estale)	echo "RESULT BUG: the open file went stale (ESTALE), though report.txt fits" ;;
ok)	if [ "$reconnected" = no ]; then
		echo "RESULT ERROR: the server didn't reconnect the file (no name lookup)"
	else
		echo "RESULT OK: the open file reconnected by its short name"
	fi ;;
*)	echo "RESULT ERROR: $state" ;;
esac
