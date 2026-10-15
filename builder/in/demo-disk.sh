#!/bin/bash
# demo-disk.sh ID REPRODIR USERLANDDIR OUTDIR   (userland builder, root)
# Packs the demo disk of reproducer ID (USER/SLUG): everything about it that
# doesn't depend on the OpenZFS build or the kernel, so every image of the
# reproducer (repro-/fixed-, every target) shares this layer.
#   /manifest  /demo.sh  /inspect.sh  and the other files of REPRODIR
#   /NAME      each REPRODIR/NAME.c, compiled here
#   /bin/      programs named in REPRODIR/bins (NAME or NAME=SOURCE) and zr
#   /lib/      shared libraries any of these need that the userland lacks
# The userland mounts it read-only on /demo.  Writes
#   OUTDIR/demo.qcow2  OUTDIR/repro.conf  OUTDIR/demo.sh [inspect.sh host.sh]
#   OUTDIR/SOURCES.txt
set -euo pipefail
ID=${1:?id} RD=${2:?reprodir} UD=${3:?userlanddir} O=${4:?outdir}
W=$(mktemp -d /tmp/demo.XXXXXX) R=$W/root
mkdir -p "$R"/{bin,lib} "$O"
rm -rf "$O"/*
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
conf() { (set +u; . "$1"; eval "printf '%s' \"\${$2:-}\""); }
RC=$RD/reproducer.conf
{
	echo "# reproducer $ID (reproducers/$ID/reproducer.conf)"
	grep -v -e '^#' -e '^$' "$RC"
	echo "ID=$(q "$ID")"
	echo "USERLAND=$(q "$(conf "$UD/userland.conf" NAME)")"
	echo "DISK_BYTES=$(numfmt --from=iec "$(conf "$RC" DISK_SIZE)")"
} >"$W/repro.conf"
{ echo "BUG=$ID"; cat "$W/repro.conf"; } >"$R/manifest"
for f in "$RD"/*; do
	case ${f##*/} in bins | prep.sh | host.sh | reproducer.conf | patches | SOURCES* | *.c | *.md) ;; *) cp -R "$f" "$R/" ;; esac
done
chmod 755 "$R"/*.sh 2>/dev/null || true
for c in "$RD"/*.c; do
	[ -e "$c" ] || continue
	n=${c##*/}; cc -O2 -s -w -o "$R/${n%.c}" "$c"
done
while read -r b; do
	case $b in '' | '#'*) continue ;; esac
	src=${b#*=}; b=${b%%=*}
	cp -L "$(command -v "$src")" "$R/bin/$b"; strip --strip-unneeded "$R/bin/$b" 2>/dev/null || true
done < <(cat "$RD/bins" 2>/dev/null)
cp "$(dirname "$0")/guest/zr" "$R/bin/zr"
[ -f "$RD/prep.sh" ] && bash "$RD/prep.sh" "$R"
# libraries the userland lacks
inbase() { grep -qxF "$1" "$UD/files"; }
find "$R" -type f | while read -r f; do
	[ "$(head -c4 "$f" | tail -c3)" = ELF ] || continue
	ldd "$f" 2>/dev/null | grep -o '/[^ ]*' || true
done | sort -u | while read -r l; do
	case $l in "$R"/*) continue ;; esac
	inbase "$l" || inbase "$(readlink -f "$l")" || { echo "adding $l (not in the userland)"; cp -L "$l" "$R/lib/"; echo "$l" >>"$W/extra"; }
done
rmdir "$R/bin" "$R/lib" 2>/dev/null || true
export E2FSPROGS_FAKE_TIME=${SOURCE_DATE_EPOCH:-0}
find "$R" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-0}" {} +
kb=$(du -sk --apparent-size "$R" | cut -f1)
truncate -s $(( (kb * 12 / 10 + 2048) * 1024 )) "$W/demo.img"
mkfs.ext4 -q -F -L zfsdemo -m 0 -N 1024 -O ^has_journal -U clear -E root_owner=0:0,hash_seed=00000000-0000-0000-0000-000000000000 -d "$R" "$W/demo.img"
qemu-img convert -q -c -o compression_type=zlib -f raw -O qcow2 "$W/demo.img" "$O/demo.qcow2"
cp "$W/repro.conf" "$O/repro.conf"
cp "$RD/demo.sh" "$O/"
for f in inspect.sh host.sh; do [ -f "$RD/$f" ] && cp "$RD/$f" "$O/"; done
{
	echo "SOURCES for the zfs-repro reproducer $ID"
	echo
	echo "Bug: $(conf "$RC" TITLE)"
	echo "Fix branch: $(conf "$RC" REPO)/tree/$(conf "$RC" BRANCH)"
	for n in $(conf "$RC" PRS); do echo "PR:    https://github.com/openzfs/zfs/pull/$n"; done
	for n in $(conf "$RC" ISSUES); do echo "Issue: https://github.com/openzfs/zfs/issues/$n"; done
	echo
	echo "Demo: demo.sh$([ -f "$RD/inspect.sh" ] && echo ", inspect.sh")$([ -f "$RD/host.sh" ] && echo ", host.sh")$(cd "$RD" && ls *.c 2>/dev/null | sed 's/^/, /' | tr -d '\n') (reproducers/$ID in https://github.com/wrouesnel/openzfs-reproducers; /demo in the VM)"
	echo "Distribution files the demo disk adds to the userland (packages: the userland's SOURCES.txt):"
	if [ -s "$W/extra" ]; then
		while read -r l; do echo "  $l ($(dpkg-query -S "$l" 2>/dev/null | head -1 | cut -d: -f1 || true))"; done <"$W/extra"
	else echo "  none"; fi
	while read -r b; do
		case $b in '' | '#'*) continue ;; esac
		echo "  /demo/bin/${b%%=*}: $(dpkg-query -S "$(readlink -f "$(command -v "${b#*=}")")" 2>/dev/null | head -1 | cut -d: -f1 || echo '?')"
	done < <(cat "$RD/bins" 2>/dev/null)
} >"$O/SOURCES.txt"
du -sh "$R" | sed 's/^/demo tree: /'
rm -rf "$W"
ls -l "$O"
