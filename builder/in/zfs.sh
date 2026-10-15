#!/bin/bash
# zfs.sh user|kmod REPO SHA OUTDIR [configure args...]   (builder container, root)
# One OpenZFS build of commit SHA of the git repository REPO (e.g.
# https://github.com/wrouesnel/zfs), half of it:
#   user  the userland tools, in the userland builder (--with-config=user):
#         OUTDIR/pkg/sbin/   zpool zfs zdb zinject zhack zstream (+ $EXTRA: more
#                            tools, or ZTS helpers such as file_write)
#         OUTDIR/pkg/lib/    the build's own shared libraries they use
#         OUTDIR/pkg/build.txt   "<short sha> <subject>"
#   kmod  the modules, in a target's builder (--with-config=kernel, against
#         the headers in /kernel/env):
#         OUTDIR/pkg/modules/   spl.ko zfs.ko (debug info stripped)
#         OUTDIR/pkg/build.txt  "<short sha> <subject>" + "zfs VERSION srcversion X"
#         OUTDIR/pkg/depends    kernel modules they need
# and in both: OUTDIR/source.txt (the commit, its upstream base) and
# OUTDIR/build.patch (the commits on top of openzfs/zfs master, if any).
# OUTDIR is a cache: an existing OUTDIR/pkg/build.txt is kept as it is.
set -euo pipefail
MODE=${1:?user|kmod} REPO=${2:?repo} SHA=${3:?sha} O=${4:?outdir}; shift 4
UPSTREAM=https://github.com/openzfs/zfs
if [ -f "$O/pkg/build.txt" ]; then echo "cached: $O"; cat "$O/pkg/build.txt"; exit 0; fi
mkdir -p "$O"
W=$(mktemp -d /tmp/zfs.XXXXXX)
t0=$(date +%s)
git init -q "$W/src"
cd "$W/src"
git remote add origin "$REPO"
git remote add upstream "$UPSTREAM"
# blobless: enough history for the merge base with upstream master
git fetch -q --filter=blob:none upstream master
git fetch -q --filter=blob:none origin "$SHA"
git -c advice.detachedHead=false checkout -q "$SHA"
mb=$(git merge-base "$SHA" upstream/master)
n=$(git rev-list --count "$mb..$SHA")
{
	echo "commit:   ${REPO%.git}/commit/$SHA"
	echo "          $(git log -1 --format='%s' "$SHA")"
	echo "upstream: $UPSTREAM/commit/$mb (openzfs/zfs master)"
	if [ "$n" -gt 0 ]; then
		echo "          plus $n commit(s) on top: build.patch (git am on the upstream commit)"
		git log --format='            %h %s' "$mb..$SHA"
	fi
	echo "configure: $*"
} >"$O/source.txt"
rm -f "$O/build.patch"
[ "$n" -gt 0 ] && git format-patch -q --stdout --no-signature "$mb..$SHA" >"$O/build.patch"
marker="$(git log -1 --format='%h %s' "$SHA")"
sh autogen.sh >"$W/autogen.log" 2>&1
J=${MAKEJOBS:-$(nproc)}
Kp=$W/pkg
if [ "$MODE" = user ]; then
	./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --with-config=user \
	    "$@" >"$W/configure.log" 2>&1 || { tail -40 "$W/configure.log"; exit 1; }
	make -s -j"$J" >"$W/make.log" 2>&1 || { grep -E 'error|Error' "$W/make.log" | head -40; exit 1; }
	make -s install DESTDIR="$W/stage" >"$W/install.log" 2>&1 || { tail -20 "$W/install.log"; exit 1; }
	S=$W/stage
	mkdir -p "$Kp"/{sbin,lib}
	for t in zpool zfs zdb zinject zhack zstream ${EXTRA:-}; do
		if [ -e "$S/usr/sbin/$t" ]; then cp -L "$S/usr/sbin/$t" "$Kp/sbin/"
		elif [ -e "$S/usr/bin/$t" ]; then cp -L "$S/usr/bin/$t" "$Kp/sbin/"
		elif [ -e "$S/usr/share/zfs/zfs-tests/bin/$t" ]; then cp -L "$S/usr/share/zfs/zfs-tests/bin/$t" "$Kp/sbin/"	# a ZTS helper
		else echo "no $t in this build"; fi
	done
	L=$S/usr/lib
	for f in "$Kp"/sbin/*; do LD_LIBRARY_PATH=$L ldd "$f" 2>/dev/null | grep -o '/[^ ]*' || true; done |
	    grep "^$L/" | sort -u | while read -r l; do cp -L "$l" "$Kp/lib/${l##*/}"; done
	file "$Kp"/sbin/* "$Kp"/lib/* | grep -q ELF
	strip --strip-unneeded "$Kp"/sbin/* "$Kp"/lib/* 2>/dev/null || true
	echo "$marker" >"$Kp/build.txt"
else
	. /kernel/env
	K=${KERNEL:?KERNEL}
	./configure --with-config=kernel --with-linux="$KSRC" --with-linux-obj="$KOBJ" \
	    "$@" >"$W/configure.log" 2>&1 || { tail -40 "$W/configure.log"; exit 1; }
	make -s -j"$J" >"$W/make.log" 2>&1 || { grep -E 'error|Error' "$W/make.log" | head -60; exit 1; }
	mkdir -p "$Kp/modules"
	for m in spl zfs; do
		f=$(find module -name "$m.ko" | head -1)
		[ -n "$f" ] || { echo "no $m.ko built" >&2; exit 1; }
		cp "$f" "$Kp/modules/"
	done
	[ "$(modinfo -F vermagic "$Kp/modules/zfs.ko" | cut -d' ' -f1)" = "$K" ] ||
	    { echo "zfs.ko is for $(modinfo -F vermagic "$Kp/modules/zfs.ko"), not $K" >&2; exit 1; }
	strip --strip-debug "$Kp"/modules/*.ko
	for m in spl zfs; do modinfo -F depends "$Kp/modules/$m.ko" | tr ',' '\n'; done | { grep -v -e "^$" -e "^spl$" || true; } | sort -u >"$Kp/depends"
	{ echo "$marker"; echo "zfs $(modinfo -F version "$Kp/modules/zfs.ko") srcversion $(modinfo -F srcversion "$Kp/modules/zfs.ko")"; } >"$Kp/build.txt"
	echo "kernel:   $K" >>"$O/source.txt"
fi
echo "built in $(( $(date +%s) - t0 ))s"
rm -rf "$O/pkg"; mv "$Kp" "$O/pkg"
cd /; rm -rf "$W"
du -sh "$O/pkg" | sed 's/^/package: /'
cat "$O/pkg/build.txt"
