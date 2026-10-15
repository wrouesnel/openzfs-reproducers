#!/bin/bash
# repro.sh ID REPRODIR BASEDIR OUTDIR LABEL=ZFSDIR...   (builder container, root)
# Packs the reproducer disk for reproducer ID:
#   /manifest  /demo.sh  /inspect.sh  and the other files of REPRODIR
#   /NAME      each REPRODIR/NAME.c, compiled here
#   /bin/      programs named in REPRODIR/bins (NAME or NAME=SOURCE)
#   /lib/      shared libraries any of these need that the base lacks
#   /LABEL/    each build's package (zfs.sh: build.txt, modules, sbin, lib)
# The base (BASEDIR: base.conf, files) mounts it read-only on /demo.  Writes
#   OUTDIR/repro.qcow2  OUTDIR/repro.conf (reproducer.conf + the build facts)
#   OUTDIR/demo.sh OUTDIR/inspect.sh  OUTDIR/SOURCES.txt  OUTDIR/patches/
set -euo pipefail
ID=${1:?id} RD=${2:?reprodir} BD=${3:?basedir} O=${4:?outdir}; shift 4
W=$(mktemp -d /tmp/repro.XXXXXX) R=$W/root
mkdir -p "$R"/{bin,lib} "$O"
rm -rf "$O/patches"; rm -f "$O"/*
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
conf() { (set +u; . "$1"; eval "printf '%s' \"\${$2:-}\""); }
RC=$RD/reproducer.conf

{
	echo "# reproducer $ID (reproducers/$ID/reproducer.conf + build facts)"
	grep -v -e '^#' -e '^$' "$RC"
	echo "ID=$(q "$ID")"
	echo "BASE_NAME=$(q "$(conf "$BD/base.conf" NAME)")"
	echo "KERNEL=$(q "$(conf "$BD/base.conf" KERNEL)")"
	for a in "$@"; do
		l=${a%%=*} z=${a#*=}
		echo "BUILD_${l}_MARKER=$(q "$(head -1 "$z/pkg/build.txt")")"
		echo "BUILD_${l}_ZFS=$(q "$(sed -n 2p "$z/pkg/build.txt")")"
	done
	echo "DISK_BYTES=$(numfmt --from=iec "$(conf "$RC" DISK_SIZE)")"
} >"$W/repro.conf"
# the image's /manifest: what demo-common.sh reads (BUG=)
{ echo "BUG=$ID"; cat "$W/repro.conf"; } >"$R/manifest"

for f in "$RD"/*; do
	case ${f##*/} in bins | prep.sh | host.sh | reproducer.conf | patches | SOURCES* | *.c | *.md) ;; *) cp -R "$f" "$R/" ;; esac
done
chmod 755 "$R"/*.sh 2>/dev/null || true
for c in "$RD"/*.c; do
	[ -e "$c" ] || continue
	n=${c##*/}; cc -O2 -w -o "$R/${n%.c}" "$c"
done
while read -r b; do
	case $b in '' | '#'*) continue ;; esac
	src=${b#*=}; b=${b%%=*}
	cp -L "$(command -v "$src")" "$R/bin/$b"
done < <(cat "$RD/bins" 2>/dev/null)
# the guest side of the host channel (zr trigger ...: docs/reproducer-format.md)
cp "$(dirname "$0")/guest/zr" "$R/bin/zr"
[ -f "$RD/prep.sh" ] && bash "$RD/prep.sh" "$R"
for a in "$@"; do
	l=${a%%=*} z=${a#*=}
	cp -R "$z/pkg" "$R/$l"
done

# libraries the base lacks (the build's own come with each package)
inbase() { grep -qxF "$1" "$BD/files"; }
find "$R" -type f | while read -r f; do
	[ "$(head -c4 "$f" | tail -c3)" = ELF ] || continue
	rel=${f#"$R"/} ll=
	[ "${rel%%/*}" != lib ] && [ -d "$R/${rel%%/*}/lib" ] && ll=$R/${rel%%/*}/lib
	LD_LIBRARY_PATH=$ll ldd "$f" 2>/dev/null | grep -o '/[^ ]*' || true
done | sort -u | while read -r l; do
	case $l in "$R"/*) continue ;; esac
	inbase "$l" || inbase "$(readlink -f "$l")" || { echo "adding $l (not in the base)"; cp -L "$l" "$R/lib/"; echo "$l" >>"$W/extra"; }
done
rmdir "$R/bin" "$R/lib" 2>/dev/null || true

export E2FSPROGS_FAKE_TIME=${SOURCE_DATE_EPOCH:-0}
find "$R" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-0}" {} +
kb=$(du -sk --apparent-size "$R" | cut -f1)
truncate -s $(( (kb * 12 / 10 + 4096) * 1024 )) "$W/repro.img"
mkfs.ext4 -q -F -L zfsrepro -m 0 -O ^has_journal -U clear -E root_owner=0:0,hash_seed=00000000-0000-0000-0000-000000000000 -d "$R" "$W/repro.img"
qemu-img convert -q -c -f raw -O qcow2 "$W/repro.img" "$O/repro.qcow2"
cp "$W/repro.conf" "$O/repro.conf"
cp "$RD/demo.sh" "$O/"
[ -f "$RD/inspect.sh" ] && cp "$RD/inspect.sh" "$O/"
[ -f "$RD/host.sh" ] && cp "$RD/host.sh" "$O/"

# SOURCES.txt and the patches
mkdir -p "$O/patches"
{
	echo "SOURCES for the zfs-repro reproducer $ID"
	echo
	echo "Bug: $(conf "$RC" TITLE)"
	for n in $(conf "$RC" PRS); do echo "PR:    https://github.com/openzfs/zfs/pull/$n"; done
	for n in $(conf "$RC" ISSUES); do echo "Issue: https://github.com/openzfs/zfs/issues/$n"; done
	echo "Base system: $(conf "$BD/base.conf" NAME) (its SOURCES.txt lists the distribution packages and their sources)"
	echo
	echo "OpenZFS builds (repository and commit; configure $(conf "$RC" CONFIGURE)):"
	for a in "$@"; do
		l=${a%%=*} z=${a#*=}
		echo "  $l:"
		sed 's/^/    /' "$z/source.txt"
		if [ -f "$z/build.patch" ]; then
			cp "$z/build.patch" "$O/patches/$l.patch"
			echo "    patch: patches/$l.patch"
		fi
	done
	echo
	echo "Demo: demo.sh$([ -f "$RD/inspect.sh" ] && echo ", inspect.sh")$([ -f "$RD/host.sh" ] && echo ", host.sh")$(cd "$RD" && ls *.c 2>/dev/null | sed 's/^/, /' | tr -d '\n') (reproducers/$ID in the repository; /demo in the VM)"
	echo "Distribution files the reproducer disk adds to the base (packages: see the base's SOURCES.txt):"
	if [ -s "$W/extra" ]; then
		while read -r l; do echo "  $l ($(dpkg-query -S "$l" 2>/dev/null | head -1 | cut -d: -f1 || true))"; done <"$W/extra"
	else echo "  none"; fi
	echo
	echo "Licenses: OpenZFS is licensed under the CDDL-1.0 (a few files are BSD or GPL-compatible"
	echo "dual-licensed); its source for each build is the commit above.  The Linux kernel,"
	echo "busybox, bash, coreutils and the other GPL userland in the Linux bases are GPL-2.0 or"
	echo "GPL-3.0; the exact source packages are listed in the base's SOURCES.txt.  Everything is"
	echo "redistributed unmodified, as built, for reproducing bugs."
} >"$O/SOURCES.txt"
rmdir "$O/patches" 2>/dev/null || true
du -sh "$R" | sed 's/^/reproducer tree: /'
rm -rf "$W"
ls -l "$O"
