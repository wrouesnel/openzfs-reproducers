#!/bin/bash
# zfs.sh REPO SHA OUTDIR [configure args...]   (in the builder container, as root)
# One OpenZFS build for the builder's kernel ($KERNEL): fetches commit SHA of
# the git repository REPO (e.g. https://github.com/openzfs/zfs), builds it,
# stages it with make install DESTDIR, and packages
#   OUTDIR/pkg/build.txt   "<short sha> <subject>" + "zfs VERSION srcversion X"
#   OUTDIR/pkg/modules/    spl.ko zfs.ko (debug info stripped)
#   OUTDIR/pkg/sbin/       zpool zfs zdb (+ the staged tools named in EXTRA)
#   OUTDIR/pkg/lib/        the build's own shared libraries they use
#   OUTDIR/source.txt      where the source is: the commit, its upstream base
#   OUTDIR/build.patch     the commits on top of openzfs/zfs master (if any)
# OUTDIR is a cache: an existing OUTDIR/pkg/build.txt is kept as it is.
set -euo pipefail
REPO=${1:?repo} SHA=${2:?sha} O=${3:?outdir}; shift 3
K=${KERNEL:?KERNEL}
UPSTREAM=https://github.com/openzfs/zfs
if [ -f "$O/pkg/build.txt" ]; then echo "cached: $O"; cat "$O/pkg/build.txt"; exit 0; fi
mkdir -p "$O"
W=$(mktemp -d /tmp/zfs.XXXXXX)
t0=$(date +%s)
# a blobless clone: enough history for the merge base with upstream master
git init -q "$W/src"
cd "$W/src"
git remote add origin "$REPO"
git remote add upstream "$UPSTREAM"
git fetch -q --filter=blob:none upstream master
git fetch -q --filter=blob:none origin "$SHA"
git -c advice.detachedHead=false checkout -q "$SHA"
mb=$(git merge-base "$SHA" upstream/master)
n=$(git rev-list --count "$mb..$SHA")
{
	echo "commit:   $REPO/commit/$SHA"
	echo "          $(git log -1 --format='%s' "$SHA")"
	echo "upstream: $UPSTREAM/commit/$mb (openzfs/zfs master)"
	if [ "$n" -gt 0 ]; then
		echo "          plus $n commit(s) on top: build.patch (git am on the upstream commit)"
		git log --format='            %h %s' "$mb..$SHA"
	fi
	echo "configure: $*"
	echo "kernel:   $K"
} >"$O/source.txt"
rm -f "$O/build.patch"
[ "$n" -gt 0 ] && git format-patch -q --stdout --no-signature "$mb..$SHA" >"$O/build.patch"
marker="$(git log -1 --format='%h %s' "$SHA")"

sh autogen.sh >"$W/autogen.log" 2>&1
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --with-config=all \
    --with-linux="/usr/src/linux-headers-$K" --with-linux-obj="/usr/src/linux-headers-$K" \
    "$@" >"$W/configure.log" 2>&1 || { tail -40 "$W/configure.log"; exit 1; }
make -s -j"${MAKEJOBS:-$(nproc)}" >"$W/make.log" 2>&1 || { grep -E 'error|Error' "$W/make.log" | head -40; exit 1; }
make -s install DESTDIR="$W/stage" >"$W/install.log" 2>&1 || { tail -20 "$W/install.log"; exit 1; }
echo "built and staged in $(( $(date +%s) - t0 ))s"

S=$W/stage Kp=$W/pkg
mkdir -p "$Kp"/{modules,sbin,lib}
find "$S/lib/modules" "$S/usr/lib/modules" -name '*.ko' -exec cp {} "$Kp/modules/" \; 2>/dev/null || true
{ find "$S/lib/modules" "$S/usr/lib/modules" -name '*.ko.*' 2>/dev/null || true; } | while read -r m; do
	nm=${m##*/}; nm=${nm%.*}
	case $m in *.zst) zstd -qdc "$m" ;; *.xz) xz -dc "$m" ;; *.gz) gzip -dc "$m" ;; *) continue ;; esac >"$Kp/modules/$nm"
done
ls "$Kp"/modules/spl.ko "$Kp"/modules/zfs.ko >/dev/null
zid="zfs $(modinfo -F version "$Kp/modules/zfs.ko") srcversion $(modinfo -F srcversion "$Kp/modules/zfs.ko")"
[ "$(modinfo -F vermagic "$Kp/modules/zfs.ko" | cut -d' ' -f1)" = "$K" ] ||
    { echo "zfs.ko is for $(modinfo -F vermagic "$Kp/modules/zfs.ko"), not $K" >&2; exit 1; }
strip --strip-debug "$Kp"/modules/*.ko
for t in zpool zfs zdb ${EXTRA:-}; do cp "$S/usr/sbin/$t" "$Kp/sbin/"; done
L=$S/usr/lib
for f in "$Kp"/sbin/*; do LD_LIBRARY_PATH=$L ldd "$f" | grep -o '/[^ ]*'; done 2>/dev/null |
    grep "^$L/" | sort -u | while read -r l; do cp -L "$l" "$Kp/lib/${l##*/}"; done
strip --strip-unneeded "$Kp"/sbin/* "$Kp"/lib/* 2>/dev/null || true
{ echo "$marker"; echo "$zid"; } >"$Kp/build.txt"
rm -rf "$O/pkg"; mv "$Kp" "$O/pkg"
cd /; rm -rf "$W"
du -sh "$O/pkg" | sed 's/^/package: /'
cat "$O/pkg/build.txt"
