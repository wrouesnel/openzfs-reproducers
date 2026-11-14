#!/bin/bash
# demo.sh -- wrouesnel/fix-freebsd-rename-flags (bug #259): on FreeBSD 16
# (and stable/15 since 1501501) renameat2(2) has AT_RENAME_EXCHANGE.  The
# kernel passes the flag to the filesystem in VOP_RENAME()'s a_flags and
# leaves the swap to it.  OpenZFS's zfs_freebsd_rename() never reads a_flags,
# so the exchange is done as a plain rename: the call returns 0, the source
# replaces the target, and the target's data is gone.  (FreeBSD's own copy
# of ZFS, the base zfs.ko, rejects it with EOPNOTSUPP.)
#
#   1. a pool on the run disk; files a ("AAAA a's data") and b ("BBBB b's
#      data"), contents and inode numbers shown;
#   2. renameat2(a, b, AT_RENAME_EXCHANGE)  (/demo/rn2 -x a b);
#   3. contents and inode numbers again;
#   4. AT_RENAME_NOREPLACE: a plain clobber attempt (EEXIST either way), then
#      20 s of NOREPLACE renames racing O_EXCL creates of the target
#      (/demo/rnrace): any created target that a NOREPLACE rename replaced
#      counts as lost.
#   bug   (the branch's test commit; zfs_freebsd_rename() as on master):
#         the exchange returns 0, a is gone, b holds a's data, "BBBB" is
#         lost; NOREPLACE loses targets in the race       -> RESULT BUG
#   fixed (the branch head): the exchange fails with EOPNOTSUPP, a and b are
#         unchanged; NOREPLACE never replaces a target    -> RESULT OK
# Run as root: /demo/demo.sh   (under a minute).  The pool is left exported.
set -u
P=demo259 D=/demo259/dir
V=${DEMO_DISK:-}
build=${DEMO_BUILD:-}
RACE=${RACE:-20}

say() { echo; echo "\$ $*"; }
files() {
	echo "  --- $D ---"
	for f in a b; do
		if [ -e $D/$f ]; then
			printf '  %s: inode %s, content "%s"\n' $f "$(stat -f %i $D/$f)" "$(cat $D/$f)"
		else
			printf '  %s: (no such file)\n' $f
		fi
	done
	echo "  -------------"
}

echo "# $(uname -sr) ($(sysctl -n kern.osreldate)); module $(sysctl -n vfs.zfs.version.module 2>/dev/null); build ${build:-?}"
echo "# zfs: $(command -v zfs) ($(zfs version 2>/dev/null | head -1))"
grep -q AT_RENAME_EXCHANGE /usr/include/sys/fcntl.h 2>/dev/null &&
    echo "# <sys/fcntl.h>: $(grep 'define.AT_RENAME_EXCHANGE' /usr/include/sys/fcntl.h | tr -s '\t ' ' ')"
zpool destroy -f $P 2>/dev/null
if [ -z "$V" ]; then mkdir -p /var/tmp/demo259; truncate -s 1g /var/tmp/demo259/vdev; V=/var/tmp/demo259/vdev; fi

say zpool create -f $P $V
zpool create -f $P "$V" || { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
zfs create -o mountpoint=$D $P/dir || { echo "RESULT ERROR: zfs create failed"; exit 2; }
zpool status -v $P | sed 's/^/  /'

# 1-3. the exchange
say "echo 'AAAA a'\''s data' > a; echo 'BBBB b'\''s data' > b"
echo "AAAA a's data" >$D/a
echo "BBBB b's data" >$D/b
ia=$(stat -f %i $D/a) ib=$(stat -f %i $D/b)
files
say "rn2 -x a b    (renameat2(a, b, AT_RENAME_EXCHANGE))"
(cd $D && /demo/rn2 -x a b) | sed 's/^/  /'
xrc=${PIPESTATUS[0]}
files
xa=$( [ -e $D/a ] && cat $D/a ) xb=$( [ -e $D/b ] && cat $D/b )
if [ $xrc = 0 ] && [ ! -e $D/a ] && [ "$xb" = "AAAA a's data" ]; then
	xres=bug
	echo "  ==> WRONG: the exchange returned success but did a plain rename: a replaced b, \"BBBB b's data\" is gone"
elif [ $xrc = 0 ] && [ "$xa" = "BBBB b's data" ] && [ "$xb" = "AAAA a's data" ]; then
	xres=ok
	echo "  ==> exchanged: a and b swapped"
elif [ $xrc != 0 ] && [ "$xa" = "AAAA a's data" ] && [ "$xb" = "BBBB b's data" ] &&
    [ "$(stat -f %i $D/a)" = $ia ] && [ "$(stat -f %i $D/b)" = $ib ]; then
	xres=ok
	echo "  ==> refused, a and b unchanged (same contents and inodes)"
else
	xres=error
	echo "  ==> unexpected result (see above)"
fi

# 4. NOREPLACE
say "rm -f a b; echo 'AAAA a'\''s data' > a; echo 'BBBB b'\''s data' > b    (fresh a and b)"
rm -f $D/a $D/b
echo "AAAA a's data" >$D/a
echo "BBBB b's data" >$D/b
files
say "rn2 -n a b    (renameat2(a, b, AT_RENAME_NOREPLACE); b exists)"
(cd $D && /demo/rn2 -n a b) | sed 's/^/  /'
nrc=${PIPESTATUS[0]}
files
mkdir -p $D/race
say "rnrace $D/race $RACE    (NOREPLACE renames of src -> dst racing O_EXCL creates of dst)"
rout=$(/demo/rnrace $D/race $RACE 2>&1); race_rc=$?
echo "$rout" | sed 's/^/  /'
rsum=$(echo "$rout" | tail -1)
race_note=
[ $race_rc != 0 ] && race_note="; AT_RENAME_NOREPLACE also replaced targets in the race ($rsum)"
say "zfs list; zpool status -v"
zfs list -r -o name,used,mountpoint $P | sed 's/^/  /'
zpool status -v $P | sed 's/^/  /'
say zpool export $P
zpool export $P && echo "  pool $P exported (on $V)"

echo
if [ $xres = bug ]; then
	echo "RESULT BUG: renameat2(a, b, AT_RENAME_EXCHANGE) returned 0 but replaced b with a: b's data is lost${race_note:-}"
	exit 1
fi
if [ $xres = error ]; then
	echo "RESULT ERROR: unexpected exchange result (exit $xrc, a=\"$xa\", b=\"$xb\")"
	exit 2
fi
if [ $nrc = 0 ]; then
	echo "RESULT BUG: renameat2(a, b, AT_RENAME_NOREPLACE) replaced an existing b"
	exit 1
fi
if [ "$race_rc" != 0 ]; then
	echo "RESULT BUG: AT_RENAME_NOREPLACE replaced targets created during the rename (rnrace above)"
	exit 1
fi
echo "RESULT OK: AT_RENAME_EXCHANGE refused with a and b intact; AT_RENAME_NOREPLACE never replaced a target"
exit 0
