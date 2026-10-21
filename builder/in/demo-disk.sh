#!/bin/bash
# demo-disk.sh ID REPRODIR USERLANDDIR OUTDIR [RESOLVED]   (userland builder, root)
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
# RESOLVED (builder/build.sh: work/resolved/USER-SLUG.conf) holds the commits
# the build specs BUILD_repro and BUILD_fixed resolved to; repro.conf gets
# them (BUILD_*) after the specs (SPEC_*), and the ZTS scripts come from them.
set -euo pipefail
ID=${1:?id} RD=${2:?reprodir} UD=${3:?userlanddir} O=${4:?outdir} RES=${5:-}
W=$(mktemp -d /tmp/demo.XXXXXX) R=$W/root
mkdir -p "$R"/{bin,lib} "$O"
rm -rf "$O"/*
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
conf() { (set +u; . "$1"; eval "printf '%s' \"\${$2:-}\""); }
RC=$RD/reproducer.conf
{
	echo "# reproducer $ID (reproducers/$ID/reproducer.conf)"
	grep -v -e '^#' -e '^$' "$RC"
	if [ -n "$RES" ]; then
		for l in repro fixed; do
			echo "SPEC_$l=$(q "$(conf "$RC" "BUILD_$l")")"
			echo "BUILD_$l=$(q "$(conf "$RES" "BUILD_$l")")"
		done
	fi
	echo "ID=$(q "$ID")"
	echo "USERLAND=$(q "$(conf "$UD/userland.conf" NAME)")"
	echo "DISK_BYTES=$(numfmt --from=iec "$(conf "$RC" DISK_SIZE)")"
} >"$W/repro.conf"
{ echo "BUG=$ID"; cat "$W/repro.conf"; } >"$R/manifest"
for f in "$RD"/*; do
	case ${f##*/} in bins | prep.sh | host.sh | reproducer.conf | patches | SOURCES* | *.c | *.md) ;; *) cp -R "$f" "$R/" ;; esac
done
# KIND=zts: the ZTS scripts of both builds (zts-pack.sh), and the runner
# (zts-run.sh) as demo.sh, with the tests it runs appended for reading
KIND=$(conf "$RC" KIND) BINS=$(cat "$RD/bins" 2>/dev/null || true) PKGS=$(conf "$RC" EXTRA_PKGS)
if [ "$KIND" = zts ]; then
	bash "$(dirname "$0")/zts-pack.sh" "$RC" "$R" $RES
	{
		cat "$(dirname "$0")/zts-run.sh"
		l=fixed; [ -f "$R/zts/fixed/tests.list" ] || l=repro
		echo; echo "# The tests, as the $l build has them ($(cat "$R/zts/$l/commit"))."
		while read -r d t pre post to; do
			echo; echo "# ======== $d/$t.ksh (pre: $pre, post: $post, timeout ${to}s)"; echo
			cat "$R/zts/$l/$d/$t.ksh"
		done <"$R/zts/$l/tests.list"
	} >"$R/demo.sh"
	# ksh93 and the commands ZTS calls that the userland's busybox lacks
	# (and GNU versions where ZTS uses options busybox doesn't have)
	BINS=$(printf '%s\n' "ksh=ksh93" getconf getent lsblk fallocate blkid mkfs.ext4 newfs=mkfs.ext4 \
	    fsck.ext4 fsck=fsck.ext4 grep sed du df id sync mktemp readlink realpath basename dirname \
	    ln chmod chown md5sum sha256sum numfmt nproc base64 sum cksum split expr comm paste shuf \
	    useradd userdel usermod groupadd groupdel losetup setpriv unshare \
	    "$BINS")
	# no udev in the VM: the /dev/zvol links come from zts-udevadm
	mkdir -p "$R/bin"
	cc -O2 -s -w -o "$R/bin/zvol_name" "$(dirname "$0")/zvol_name.c"
	install -m 755 "$(dirname "$0")/zts-udevadm" "$R/bin/udevadm"
	install -m 755 "$(dirname "$0")/zts-sudo" "$R/bin/sudo"	# setpriv, for user_run
	PKGS="xxhash libaio1t64 procps libproc2-0 $PKGS"
	# tests that call python3 get it, and its standard library
	ZTS_PY=; grep -rqw python3 "$R"/zts/*/tests && ZTS_PY=1 BINS=$(printf '%s\n' "$BINS" python3)
	# and jq (zpool status -j / zfs list -j tests)
	grep -rqw jq "$R"/zts/*/tests && PKGS="$PKGS jq libjq1 libonig5"
	# and fio (built from source: builder/in/fio.sh)
	grep -rqw fio "$R"/zts/*/tests && bash "$(dirname "$0")/fio.sh" "$R/bin"
	# and parted (libtest's partition helpers: cleanup_devices, set_partition, ...)
	grep -rqwE 'parted|cleanup_devices|zero_partitions|set_partition|partition_disk|delete_partitions' "$R"/zts/*/tests &&
	    PKGS="$PKGS parted libparted2t64 libdevmapper1.02.1 libreadline8t64"
fi
chmod 755 "$R"/*.sh 2>/dev/null || true
# EXTRA_PKGS: packages of the builder's distribution (its snapshot) that the
# demo needs and the builder doesn't have: unpacked, their programs on
# /demo/bin and their libraries on /demo/lib
if [ -n "${PKGS// /}" ]; then
	# the .debs are kept in /work/cache/debs (the snapshot's packages don't
	# change); the snapshot service is retried, it sometimes answers 50x
	C=/work/cache/debs; [ -d /work ] || C=$W/debs
	mkdir -p "$C" "$W/pkgs"
	miss=; for p in $PKGS; do ls "$C/${p}_"*.deb >/dev/null 2>&1 || miss="$miss $p"; done
	if [ -n "$miss" ]; then
		for i in 1 2 3 4 5; do
			apt-get update -qq >/dev/null 2>&1 && (cd "$C" && apt-get download -qq $miss 2>/dev/null) && break
			echo "apt: retry $i"; sleep $((i * 10))
		done
	fi
	for p in $PKGS; do cp "$(ls "$C/${p}_"*.deb | tail -1)" "$W/pkgs/" || { echo "no package $p" >&2; exit 1; }; done
	(cd "$W/pkgs" && for d in *.deb; do dpkg -x "$d" "$W/pkgroot"; dpkg-deb -f "$d" Package Version Source | tr '\n' ' '; echo; done) >"$W/pkgs.txt"
	for d in usr/bin usr/sbin bin sbin; do
		[ -d "$W/pkgroot/$d" ] && find "$W/pkgroot/$d" -maxdepth 1 \( -type f -o -type l \) -exec cp -L {} "$R/bin/" \;
	done
	find "$W/pkgroot" -path '*/lib/*' -name '*.so*' \( -type f -o -type l \) -exec cp -L {} "$R/lib/" \; 2>/dev/null || true
	export PATH="$R/bin:$PATH" LD_LIBRARY_PATH="$R/lib"
fi
for c in "$RD"/*.c; do
	[ -e "$c" ] || continue
	n=${c##*/}; cc -O2 -s -w -o "$R/${n%.c}" "$c"
done
while read -r b; do
	case $b in '' | '#'*) continue ;; esac
	src=${b#*=}; b=${b%%=*}
	cp -L "$(command -v "$src")" "$R/bin/$b"; strip --strip-unneeded "$R/bin/$b" 2>/dev/null || true
done < <(printf '%s\n' "$BINS")
cp "$(dirname "$0")/guest/zr" "$R/bin/zr"
[ -f "$RD/prep.sh" ] && bash "$RD/prep.sh" "$R"
[ -n "${ZTS_PY:-}" ] && bash "$(dirname "$0")/python-stdlib.sh" "$R"
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
cp "$R/demo.sh" "$O/"
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
	done < <(printf '%s\n' "$BINS")
	[ -s "$W/pkgs.txt" ] && { echo "Packages unpacked onto the demo disk (EXTRA_PKGS; Ubuntu snapshot ${SNAPSHOT:-?}):"; sed 's/^/  /' "$W/pkgs.txt"; }
	[ -f "$R/zts/repro/tests.list" ] && echo "ZTS scripts: /demo/zts/LABEL, from each build's commit (CDDL-1.0): $(cat "$R"/zts/*/commit | tr '\n' ';')"
} >"$O/SOURCES.txt"
du -sh "$R" | sed 's/^/demo tree: /'
rm -rf "$W"
ls -l "$O"
