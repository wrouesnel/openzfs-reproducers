#!/bin/bash
# build-disk.sh LABEL USERPKG KMODPKG OUTDIR TARGETDIR   (userland builder, root)
# Packs the build disk of one image: one OpenZFS build (LABEL repro or
# fixed) for one target: the userland half (USERPKG: sbin/ lib/, built once
# per commit) and the target's modules (KMODPKG: modules/ build.txt).  The
# userland mounts it read-only on /zfs.  Writes OUTDIR/build.qcow2.
set -euo pipefail
L=${1:?label} U=${2:?userpkg} M=${3:?kmodpkg} O=${4:?outdir} TD=${5:?targetdir}
# the modules spl.ko and zfs.ko need must be built in or in the initramfs
for d in $(cat "$M/depends" 2>/dev/null); do
	grep -qx "${d//-/_}" "$TD/modules" || { echo "zfs.ko needs $d, which the target doesn't load (kernel-stage.sh WANT)" >&2; exit 1; }
done
W=$(mktemp -d /tmp/build.XXXXXX) R=$W/root
mkdir -p "$R" "$O"
cp -R "$U/sbin" "$U/lib" "$R/"
[ -d "$U/zed" ] && cp -R "$U/zed" "$R/"	# zed.rc and the zedlets (TOOLS zed)
cp -R "$M/modules" "$R/"
cp "$M/build.txt" "$R/build.txt"
[ "$(head -1 "$U/build.txt")" = "$(head -1 "$M/build.txt")" ] ||
    { echo "userland build '$(head -1 "$U/build.txt")' and modules '$(head -1 "$M/build.txt")' differ" >&2; exit 1; }
export E2FSPROGS_FAKE_TIME=${SOURCE_DATE_EPOCH:-0}
find "$R" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-0}" {} +
kb=$(du -sk --apparent-size "$R" | cut -f1)
truncate -s $(( (kb * 12 / 10 + 2048) * 1024 )) "$W/build.img"
mkfs.ext4 -q -F -L zfs-$L -m 0 -N 256 -O ^has_journal -U clear -E root_owner=0:0,hash_seed=00000000-0000-0000-0000-000000000000 -d "$R" "$W/build.img"
qemu-img convert -q -c -o compression_type=zlib -f raw -O qcow2 "$W/build.img" "$O/build.qcow2"
echo "build tree $L: $(du -sh "$R" | cut -f1), disk $(du -h "$O/build.qcow2" | cut -f1)"
rm -rf "$W"
