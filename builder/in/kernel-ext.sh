#!/bin/bash
# kernel-ext.sh TARGET OUTDIR EXTUSERLANDDIR TARGETDIR   (userland builder, root)
# Packs a target's extended kernel layer: the standard target (TARGETDIR:
# vmlinuz, initrd, base.conf, modules) and its full module tree
# (OUTDIR/modules.tar from kernel-ext-modules.sh), written into the extended
# userland's root file system.  The tree goes in a qcow2 overlay whose
# backing file is the ext userland's disk, named relative to it
# (userland-NAME.qcow2: both are in /zfs-repro/base in the image), so the
# layer holds only the clusters the tree changed and every target shares
# the ext userland layer.  The launcher boots base.qcow2 as it always does.
# Writes to OUTDIR:
#   base.qcow2   the overlay (compressed), backing userland-NAME.qcow2
#   vmlinuz initrd modules   the standard target's
#   base.conf    the standard target's, plus BASE=ext and USERLAND
#   SOURCES.txt  the standard target's, plus the module packages
set -euo pipefail
NAME=${1:?target} O=${2:?outdir} XU=${3:?extuserlanddir} TD=${4:?targetdir}
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
conf() { (set +u; . "$1"; eval "printf '%s' \"\${$2:-}\""); }
K=$(conf "$TD/base.conf" KERNEL)
XN=$(conf "$XU/userland.conf" NAME)
BACK=userland-$XN.qcow2
[ -f "$O/modules.tar" ] || { echo "no $O/modules.tar (kernel-ext-modules.sh)" >&2; exit 1; }
W=$(mktemp -d /tmp/kext.XXXXXX)
export E2FSPROGS_FAKE_TIME=${SOURCE_DATE_EPOCH:-0}

# the tree, with its modules.dep made by the guest's own kmod
mkdir -p "$W/m/usr/lib"; ln -s usr/lib "$W/m/lib"
tar -C "$W/m/usr" -xf "$O/modules.tar"
depmod -b "$W/m" "$K"
n=$(find "$W/m/usr/lib/modules/$K" -name '*.ko*' | wc -l)
[ "$n" -gt 100 ] || { echo "only $n modules for $K" >&2; exit 1; }
for m in scsi_debug dm_mod; do
	modinfo -b "$W/m" -k "$K" -F filename "$m" >/dev/null 2>&1 || echo "kernel-ext: note: $K has no $m module (built in, or not built)"
done

# write it into a copy of the ext root (debugfs: no mount needed)
qemu-img convert -q -f qcow2 -O raw "$XU/userland.qcow2" "$W/root.raw"
{
	cd "$W/m"
	find usr/lib/modules/"$K" -mindepth 0 -type d | LC_ALL=C sort | while read -r d; do echo "mkdir /$d"; done
	find usr/lib/modules/"$K" -type f | LC_ALL=C sort | while read -r f; do echo "write $W/m/$f /$f"; done
	find usr/lib/modules/"$K" -type l | LC_ALL=C sort | while read -r f; do echo "symlink /$f $(readlink "$f")"; done
} >"$W/cmds"
debugfs -w -f "$W/cmds" "$W/root.raw" >"$W/debugfs.log" 2>&1
if grep -E 'No free space|Could not allocate|: Ext2 ' "$W/debugfs.log" | grep -v '^debugfs ' | head -5 | grep .; then
	echo "debugfs failed writing the module tree" >&2; exit 1
fi
e2fsck -fn "$W/root.raw" >"$W/fsck.log" 2>&1 || { tail -20 "$W/fsck.log" >&2; echo "the root file system is damaged after writing the modules" >&2; exit 1; }
got=$(debugfs -R "ls -p /usr/lib/modules/$K/kernel" "$W/root.raw" 2>/dev/null | wc -l)
[ "$got" -gt 2 ] || { echo "the modules aren't on the root file system" >&2; exit 1; }

# the overlay: only the clusters that differ from the ext root (qemu-img
# rebase, in safe mode, copies exactly those from the old backing file)
cd "$W"
ln -s "$XU/userland.qcow2" "$W/$BACK"
qemu-img convert -q -f raw -O qcow2 "$W/root.raw" "$W/full.qcow2"
qemu-img create -q -f qcow2 -b full.qcow2 -F qcow2 "$W/delta.qcow2"
qemu-img rebase -q -f qcow2 -b "$BACK" -F qcow2 "$W/delta.qcow2"
rm -f "$O/base.qcow2"
qemu-img convert -q -c -o compression_type=zlib -f qcow2 -O qcow2 -B "$BACK" -F qcow2 "$W/delta.qcow2" "$W/base.qcow2"
qemu-img compare -q -f qcow2 -F raw "$W/base.qcow2" "$W/root.raw" || { echo "the overlay doesn't read back as the root with the modules" >&2; exit 1; }
[ "$(qemu-img info --output=json "$W/base.qcow2" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("backing-filename",""))')" = "$BACK" ] ||
    { echo "the overlay's backing file isn't $BACK" >&2; exit 1; }
mv "$W/base.qcow2" "$O/base.qcow2"

for f in vmlinuz initrd modules; do [ -f "$TD/$f" ] && cp "$TD/$f" "$O/"; done
{ cat "$TD/base.conf"; echo "BASE=ext"; echo "EXT_USERLAND='$XN'"; } >"$O/base.conf"
{
	cat "$TD/SOURCES.txt"
	echo
	echo "Extended kernel layer (BASE=ext): the kernel's full module tree, unmodified (the"
	echo "distribution's own zfs and spl left out), in /usr/lib/modules/$K, from:"
	while read -r p v s; do echo "  $p $v"; echo "      source: $s"; done <"$O/modules-pkg.txt"
	echo "modules.dep and the other indexes: depmod (kmod) of the extended userland $XN."
} >"$O/SOURCES.txt"
rm -f "$O/modules.tar"
echo "kernel-ext $NAME: $n modules; overlay $(du -h --apparent-size "$O/base.qcow2" | cut -f1) on $BACK"
rm -rf "$W"
ls -l "$O"
