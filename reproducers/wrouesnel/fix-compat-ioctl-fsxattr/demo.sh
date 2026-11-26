#!/bin/bash
# demo.sh -- wrouesnel/fix-compat-ioctl-fsxattr (Linux).
# A 32-bit program on a 64-bit kernel reaches ZFS through zpl_compat_ioctl().
# master returns ENOTTY there for FS_IOC_FSGETXATTR/FS_IOC_FSSETXATTR (no
# case for them), and, on Linux 5.13 and later, for FS_IOC32_GETFLAGS and
# FS_IOC32_SETFLAGS too (the kernel hands the handler the native numbers).
#
# /demo/compat_ioctl issues each ioctl as a 32-bit system call ("int $0x80"
# from a 64-bit process), exactly as a 32-bit lsattr or chattr would.
# The file and directory are first set up with the ordinary (64-bit) chattr:
# nodump and project ID 7.  The demo then reads them through the 32-bit
# ioctls, sets project ID 9 and clears the flags through them, and shows the
# end state with the ordinary lsattr.
set -u
. /etc/demo-env 2>/dev/null
P=cioctl
x() { echo "# $*"; "$@"; }

echo "=== 32-bit file flag and project ID ioctls ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build), kernel $(uname -r))"
zpool destroy $P 2>/dev/null
x zpool create -f -o cachefile=none $P $DEMO_DISK ||
    { echo "RESULT ERROR: zpool create failed"; exit 2; }
f=/$P/file d=/$P/dir
touch $f; mkdir $d
x chattr +d -p 7 $f
x chattr +P -p 7 $d
echo "# before (64-bit lsattr):"
lsattr -p $f; lsattr -pd $d

declare -A RC
call() {	# NAME ARGS...: one 32-bit ioctl
	local name=$1; shift
	echo "# 32-bit $name: compat_ioctl $*"
	out=$(/demo/compat_ioctl "$@" 2>&1); rc=$?
	echo "    -> exit $rc${out:+: $out}"
	[ $rc -eq 2 ] && { echo "RESULT ERROR: no 32-bit system calls on this kernel"; exit 2; }
	RC[$name]=$rc
}
echo
call FS_IOC32_GETFLAGS getflags $f
call FS_IOC_FSGETXATTR fsgetxattr $f
call FS_IOC_FSSETXATTR fssetxattr $f 9
call FS_IOC32_SETFLAGS setflags $f 0
call FS_IOC_FSGETXATTR_dir fsgetxattr $d

echo
echo "# after, remounted (64-bit lsattr; expected: project 9 and no d flag on the file, 7 and P on the dir):"
x zfs umount $P && x zfs mount $P
lsattr -p $f; lsattr -pd $d
fp=$(lsattr -p $f | awk '{print $1}'); ff=$(lsattr $f | awk '{print $1}')

fail=""
for k in FS_IOC32_GETFLAGS FS_IOC_FSGETXATTR FS_IOC_FSSETXATTR FS_IOC32_SETFLAGS; do
	[ "${RC[$k]}" -ne 0 ] && fail="$fail $k"
done
zpool destroy $P
echo
if [ -n "$fail" ]; then
	echo "RESULT BUG: 32-bit file flag and project ID ioctls fail with ENOTTY:$fail (file still project $fp, flags $ff)"
elif [ "$fp" = 9 ] && [[ "$ff" != *d* ]]; then
	echo "RESULT OK: 32-bit programs read and set file flags and project IDs (file now project $fp, flags $ff)"
else
	echo "RESULT ERROR: the ioctls succeeded but the file is project $fp, flags $ff"
	exit 2
fi
