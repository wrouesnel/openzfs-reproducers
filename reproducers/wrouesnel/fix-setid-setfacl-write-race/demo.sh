#!/bin/bash
# demo.sh -- wrouesnel/fix-setid-setfacl-write-race (acltype=posix, Linux).
# A write by another user with write access clears S_ISUID/S_ISGID in the
# znode's mode (z_mode) in its transaction; the inode's copy (i_mode) only
# catches up when the write ends.  When the owner runs setfacl in between,
# master's zpl_set_posix_acl() computes the new mode from the stale i_mode
# and stores the set-id bits again: they are still on after the write has
# completed, and after export/import.
#
# The order is made deterministic the way the branch's ZTS test
# (acl/posix/posix_006_pos) does it: a 32 MiB + 1 byte write at offset 0 is
# two transactions (DMU_MAX_ACCESS / 2).  The first one (full records, no
# reads) clears the set-id bits and sets the mtime; the second, one byte,
# must read the last record, and zinject delays reads by 5 s.  Once the
# mtime moves, while the write is still running, the owner (root) runs
# `setfacl -m u::rw-,g::rw-,m::rw-,o::r--`.  zfs_write() only clears the
# set-id bits while an execute bit is set, so its second transaction leaves
# whatever setfacl stored.  Expected end state: 0664.
#
# For xattr=sa and xattr=dir, with a control file written the same way
# without setfacl (must end 0775 on both builds).
set -u
. /etc/demo-env 2>/dev/null
P=setidrace
W=65534			# another user with write access (u:65534:rwx)
REC=131072 CHUNK=$((32 * 1024 * 1024)) DELAY_MS=5000
x() { echo "# $*"; "$@"; }
state() {	# FILE: mode and ACL
	echo "  $(stat -c '%a %A' "$1")  $(basename "$1")  |  $(getfacl -cpn "$1" 2>&1 | paste -sd' ' -)"
}
mkfile() {	# FILE: 6775, two-chunk size, u:$W:rwx
	dd if=/dev/urandom of="$1" bs=$REC count=$((CHUNK / REC + 1)) status=none
	chmod 6775 "$1"
	setfacl -m u:$W:rwx "$1"
}
reimport() {
	x zpool export $P
	x zpool import -d /dev $P || { echo "RESULT ERROR: zpool import failed"; exit 2; }
}

echo "=== set-id bits, a write by another user with write access, and the owner's setfacl ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build))"
declare -A AFTER IMPORTED
for xa in sa dir; do
	echo; echo "=============== acltype=posix xattr=$xa ==============="
	zpool destroy $P 2>/dev/null
	x zpool create -f -o cachefile=none -O acltype=posix -O xattr=$xa \
	    -O recordsize=128k -O primarycache=metadata $P $DEMO_DISK ||
	    { echo "RESULT ERROR: zpool create failed"; exit 2; }
	f=/$P/f c=/$P/control
	mkfile $f; mkfile $c
	echo "# before: the owner (root) made both files 6775 with u:$W:rwx"
	state $f; state $c

	echo "# control: uid $W writes $((CHUNK + 1)) bytes to control, no setfacl"
	/demo/setidw write $W $c $((CHUNK + 1))
	state $c
	[ "$(stat -c %a $c)" = 775 ] || { echo "RESULT ERROR: xattr=$xa: the control write left mode $(stat -c %a $c), not 775"; exit 2; }

	# drop the cached data, load f's metadata and ACL, then delay reads
	reimport
	dd if=$f of=/dev/null bs=1 count=1 status=none
	getfacl $f >/dev/null
	m0=$(/demo/setidw mtime $f)
	x zinject -d $DEMO_DISK -D $DELAY_MS:1 -T read $P

	echo "# uid $W writes $((CHUNK + 1)) bytes to f; once f's mtime moves (first transaction done), the owner runs setfacl"
	t0=$SECONDS
	/demo/setidw write $W $f $((CHUNK + 1)) &
	wpid=$!
	i=0
	while [ "$(/demo/setidw mtime $f)" = "$m0" ] && kill -0 $wpid 2>/dev/null && [ $i -lt 100 ]; do
		sleep 0.05; i=$((i + 1))
	done
	if [ "$(/demo/setidw mtime $f)" = "$m0" ] || ! kill -0 $wpid 2>/dev/null; then
		zinject -c all >/dev/null; wait $wpid
		echo "RESULT ERROR: xattr=$xa: setfacl could not run during the write (mtime moved: $([ "$(/demo/setidw mtime $f)" = "$m0" ] && echo no || echo yes))"; exit 2
	fi
	echo "# mtime moved, the write is still running ($((SECONDS - t0)) s)"
	x setfacl -m u::rw-,g::rw-,m::rw-,o::r-- $f || { echo "RESULT ERROR: setfacl failed"; exit 2; }
	wait $wpid; rv=$?
	echo "# the write finished after $((SECONDS - t0)) s, exit $rv"
	x zinject -c all
	[ $rv = 0 ] || { echo "RESULT ERROR: xattr=$xa: the write failed"; exit 2; }
	echo "# after the write (expected 664, ACL user::rw- user:$W:rwx mask::rw- other::r--):"
	state $f
	AFTER[$xa]=$(stat -c %a $f)
	acl=$(getfacl -cpn $f | paste -sd' ' -)
	case "$acl " in *"user::rw- "*"user:$W:rwx"*"mask::rw- "*"other::r-- "*) ;;
	*) echo "RESULT ERROR: xattr=$xa: the ACL is not the one setfacl set: $acl"; exit 2 ;; esac

	reimport
	echo "# after export/import:"
	state $f
	IMPORTED[$xa]=$(stat -c %a $f)
	x zpool status -v $P
	[ $xa = dir ] || x zpool destroy $P
done
x zpool export $P
echo
bad=
for xa in sa dir; do
	echo "  xattr=$xa: after the write ${AFTER[$xa]}, after export/import ${IMPORTED[$xa]} (expected 664)"
	[ "${AFTER[$xa]}" = 664 ] && [ "${IMPORTED[$xa]}" = 664 ] || bad="$bad xattr=$xa ${AFTER[$xa]}/${IMPORTED[$xa]},"
done
if [ -n "$bad" ]; then
	echo "RESULT BUG: set-id bits are on after a completed write by another user with write access, when the owner ran setfacl during it:${bad%,} (after the write/after export/import; expected 664)"
else
	echo "RESULT OK: set-id bits stay cleared after a completed write by another user with write access, when the owner ran setfacl during it: 664 after the write and after export/import (xattr=sa and xattr=dir)"
fi
