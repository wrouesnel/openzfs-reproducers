#!/bin/bash
# demo.sh -- bug #39 / PR #19313 (openzfs #16508): on Linux the DOS read-only
# attribute (ZFS_READONLY, set over SMB or with ZFS_IOC_SETDOSFLAGS) does not
# stop the file's owner from opening the file for writing.  FreeBSD enforces
# it (chflags rdonly: the owner gets EACCES, root may still write).
#
# A file owned by uid 1000 gets the attribute.  Its owner then appends to it
# and opens it with O_TRUNC; root appends to it too.  The dataset is
# remounted and the files are read back from disk.
#
# Demo-image copy (vm/mkdemo.sh): the helper dosro.c is prebuilt at
# /demo/dosro.  Run as root:  /demo/demo.sh       about 1 second.
# Builds:
#   bug: PR test commit (master's behaviour)
#     -> owner's append and O_TRUNC open "succeeded", the files change,
#        root's append succeeded,  "RESULT BUG"
#   fix: PR head (the rework: EPERM unless the caller has CAP_DAC_OVERRIDE)
#     -> owner's opens "failed, Operation not permitted (EPERM)", the files
#        are unchanged, root's append still succeeds,  "RESULT OK"
# Pool demo39 on the run disk $DEMO_DISK (vm/demo-vm.sh), or on the file
# /var/tmp/demo39/vdev when DEMO_DISK is unset.  It is exported at the end,
# so `vm/demo-vm.sh 39 LABEL --disk RUNDISK` can read the files back
# (/demo/inspect.sh).
set -u
D=/var/tmp/demo39; P=demo39
V=${DEMO_DISK:-$D/vdev}
H=${DOSRO_BIN:-/demo/dosro}
[ -x "$H" ] || { echo "no helper $H" >&2; exit 2; }
zpool destroy -f $P 2>/dev/null; rm -rf $D; mkdir -p $D
[ -n "${DEMO_DISK:-}" ] || truncate -s 256M $V
zpool create -f -o cachefile=none $P $V && [ -d /$P ] ||
    { echo "RESULT ERROR: could not create pool $P on $V"; exit 2; }
echo "pool $P on $V"
chmod 755 /$P
for f in append trunc; do
	echo "original contents" > /$P/$f.txt
	chown 1000:1000 /$P/$f.txt; chmod 644 /$P/$f.txt
	$H set /$P/$f.txt || { echo "RESULT ERROR: could not set the attribute"; exit 2; }
done
ls -ln /$P
echo "DOS attribute of append.txt and trunc.txt: $($H get /$P/append.txt) $($H get /$P/trunc.txt)"
echo
echo "== the owner (uid 1000) writes to its read-only files:"
ow=0
$H write 1000 append /$P/append.txt $'owner appended this\n' && ow=$((ow + 1))
$H write 1000 trunc /$P/trunc.txt $'owner replaced the contents\n' && ow=$((ow + 1))
echo "== root appends to append.txt (root may override the attribute):"
$H write 0 append /$P/append.txt $'root appended this\n' && rt=1 || rt=0
echo
zfs unmount $P && zfs mount $P
echo "== after a remount (read from disk):"
for f in append trunc; do echo "--- $f.txt ($($H get /$P/$f.txt)):"; cat /$P/$f.txt; echo; done
zpool export $P && echo "pool $P exported (on $V)"
if [ $rt = 0 ]; then
	echo "RESULT ERROR: root could not write the file (the attribute should not stop root)"
	exit 2
elif [ $ow = 2 ]; then
	echo "RESULT BUG: the owner wrote to a DOS read-only file (2/2 opens for write succeeded)"
elif [ $ow = 0 ]; then
	echo "RESULT OK: the owner's opens for write were refused; root may still write"
else
	echo "RESULT BUG: the owner wrote to a DOS read-only file ($ow/2 opens for write succeeded)"
fi
