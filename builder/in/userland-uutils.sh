#!/bin/bash
# userland-uutils.sh NAME OUTDIR PARENTDIR   (in the parent userland's builder, root; needs network)
# Packs a uutils userland (userlands/NAME/userland.conf, PARENT=...): the
# parent's root as built (PARENTDIR/base.qcow2), with the programs named in
# UUTILS replaced by links to uutils coreutils' multi-call binary
# (/usr/lib/uutils/coreutils), from the pinned release (UUTILS_URL,
# UUTILS_SHA256: a static build, so it runs on any root).  For a bug that
# shows only with that implementation of a tool, such as Ubuntu 26.04's
# mkdir.  Otherwise it is the parent's root, file for file, so it is
# treated as a standard userland (the standard kernel layers boot it).
# Writes to OUTDIR, as builder/in/userland.sh does:
#   base.qcow2     compressed qcow2 of the ext4 root
#   files          every path in the root
#   userland.conf  NAME PARENT DISTRO ZLIB SNAPSHOT UUTILS_VERSION UUTILS
#   SOURCES.txt    uutils, then the parent's SOURCES.txt
set -euo pipefail
NAME=${1:?name} O=${2:?outdir} PD=${3:?parentdir}
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
conf() { (set +u; . "$1"; eval "printf '%s' \"\${$2:-}\""); }
UC=/src/userlands/$NAME/userland.conf
V=$(conf "$UC" UUTILS_VERSION) URL=$(conf "$UC" UUTILS_URL) SHA=$(conf "$UC" UUTILS_SHA256)
TOOLS=$(conf "$UC" UUTILS | tr -s ' \t\n' ' ')
[ -n "$V" ] && [ -n "$URL" ] && [ -n "$SHA" ] && [ -n "${TOOLS// /}" ] || { echo "$UC: UUTILS_VERSION, UUTILS_URL, UUTILS_SHA256 and UUTILS are needed" >&2; exit 1; }
W=$(mktemp -d /tmp/uutils.XXXXXX) P=$W/root
mkdir -p "$O"; rm -f "$O"/*

# ---- the parent's root, as built --------------------------------------------
qemu-img convert -q -f qcow2 -O raw "$PD/base.qcow2" "$W/parent.raw"
mkdir -p "$P"
debugfs -R "rdump / $P" "$W/parent.raw" >/dev/null 2>&1
[ -x "$P/usr/bin/busybox" ] && [ -f "$P/etc/rcS" ] || { echo "could not unpack $PD/base.qcow2" >&2; exit 1; }
rm -rf "$P/lost+found" "$W/parent.raw"

# ---- uutils ------------------------------------------------------------------
C=/work/cache; [ -d /work ] || C=$W
f=$C/${URL##*/}
if ! echo "$SHA  $f" | sha256sum -c --quiet 2>/dev/null; then
	curl -fsSL --retry 5 -o "$f.tmp" "$URL"
	echo "$SHA  $f.tmp" | sha256sum -c --quiet
	mv "$f.tmp" "$f"
fi
mkdir -p "$W/u"; tar -C "$W/u" -xzf "$f"
b=$(find "$W/u" -type f -name coreutils -perm -u+x | head -1)
[ -n "$b" ] || { echo "no coreutils binary in ${URL##*/}" >&2; exit 1; }
mkdir -p "$P/usr/lib/uutils" "$P/usr/share/doc/uutils"
install -m 755 "$b" "$P/usr/lib/uutils/coreutils"
cp "$(dirname "$b")/LICENSE" "$P/usr/share/doc/uutils/LICENSE"
got=$("$P/usr/lib/uutils/coreutils" --version 2>&1 | head -1)
case $got in *" $V "* | *" $V") ;; *) echo "uutils: expected $V, the binary says '$got'" >&2; exit 1 ;; esac
for t in $TOOLS; do
	rm -f "$P/usr/bin/$t"
	ln -s ../lib/uutils/coreutils "$P/usr/bin/$t"
	"$P/usr/bin/$t" --version 2>&1 | grep -q "uutils coreutils" || { echo "uutils: $t is not one of its programs" >&2; exit 1; }
done

# ---- image (as builder/in/userland.sh) ---------------------------------------
export E2FSPROGS_FAKE_TIME=${SOURCE_DATE_EPOCH:-0}
find "$P" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-0}" {} +
kb=$(du -sk --apparent-size "$P" | cut -f1)
echo "uutils userland tree: ${kb} KiB ($TOOLS-> uutils $V)"
truncate -s $(( (kb * 15 / 10 + 32768) * 1024 )) "$W/base.ext4"
mkfs.ext4 -q -F -L zfsdemo -m 0 -N 4096 -O ^has_journal -U clear -E root_owner=0:0,hash_seed=00000000-0000-0000-0000-000000000000 -d "$P" "$W/base.ext4"
qemu-img convert -q -c -o compression_type=zlib -f raw -O qcow2 "$W/base.ext4" "$O/base.qcow2"
(cd "$P" && find . | sed 's/^\.//' | sort) >"$O/files"
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
{
	echo "NAME=$(q "$NAME")"
	echo "PARENT=$(q "$(conf "$PD/userland.conf" NAME)")"
	echo "DISTRO=$(q "$(conf "$PD/userland.conf" DISTRO)")"
	echo "ZLIB=$(q "$(conf "$PD/userland.conf" ZLIB)")"
	echo "SNAPSHOT=$(q "$(conf "$PD/userland.conf" SNAPSHOT)")"
	echo "UUTILS_VERSION=$(q "$V")"
	echo "UUTILS=$(q "${TOOLS% }")"
} >"$O/userland.conf"

# ---- SOURCES.txt -------------------------------------------------------------
{
	echo "SOURCES for the zfs-repro uutils userland $NAME (the kernel: the target's SOURCES.txt)"
	echo
	echo "It is the userland $(conf "$PD/userland.conf" NAME) (its SOURCES.txt follows), with these programs"
	echo "linked to uutils coreutils $V (/usr/lib/uutils/coreutils, MIT, /usr/share/doc/uutils/LICENSE):"
	echo "  ${TOOLS% }"
	echo "  binary: $URL"
	echo "  sha256: $SHA"
	echo "  source: https://github.com/uutils/coreutils/tree/$V"
	echo
	echo "================================================================================"
	cat "$PD/SOURCES.txt"
} >"$O/SOURCES.txt"
rm -rf "$W"
ls -l "$O"
