#!/bin/bash
# zfs-tree.sh user|kmod SRCDIR OUTDIR MARKER [configure args...]   (builder container, root)
# The OpenZFS build of `builder/build.sh try`: like zfs.sh, but from a source
# tree that builder/build.sh checked out (a snapshot of someone's working
# tree, not a public commit), built IN PLACE so that the next build of an
# edited tree only recompiles what changed.  SRCDIR keeps its objects between
# runs; autogen.sh and configure run again only when the configure arguments
# (or $EXTRA, the tools) differ from the last run's, or SRCDIR has no
# Makefile yet.  The package is the same as zfs.sh's:
#   user  OUTDIR/pkg/sbin/ lib/ [zed/] build.txt (MARKER)
#   kmod  OUTDIR/pkg/modules/ depends build.txt (MARKER + zfs VERSION srcversion X)
# OUTDIR/pkg is replaced on every run (it is not a cache, SRCDIR is).
set -euo pipefail
MODE=${1:?user|kmod} SRC=${2:?srcdir} O=${3:?outdir} MARKER=${4:?marker}; shift 4
[ -f "$SRC/autogen.sh" ] || { echo "zfs-tree: $SRC is not an OpenZFS source tree" >&2; exit 1; }
mkdir -p "$O"
W=$(mktemp -d /tmp/zfs.XXXXXX)
t0=$(date +%s)
cd "$SRC"
J=${MAKEJOBS:-$(nproc)}
Kp=$W/pkg
want="$MODE $* EXTRA=${EXTRA:-} KERNEL=${KERNEL:-}"
if [ ! -f Makefile ] || [ "$(cat .zr-configured 2>/dev/null)" != "$want" ]; then
	echo "zfs-tree $MODE: autogen.sh and configure (first build of this tree, or new configure arguments)"
	rm -f .zr-configured
	sh autogen.sh >"$O/autogen.log" 2>&1 || { tail -40 "$O/autogen.log"; exit 1; }
	if [ "$MODE" = user ]; then
		./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --with-config=user \
		    "$@" >"$O/configure.log" 2>&1 || { tail -40 "$O/configure.log"; exit 1; }
	else
		. /kernel/env
		./configure --with-config=kernel --with-linux="$KSRC" --with-linux-obj="$KOBJ" \
		    "$@" >"$O/configure.log" 2>&1 || { tail -40 "$O/configure.log"; exit 1; }
	fi
	echo "$want" >.zr-configured
fi
t1=$(date +%s)
make -s -j"$J" >"$O/make.log" 2>&1 || { grep -E 'error|Error' "$O/make.log" | head -60; exit 1; }
if [ "$MODE" = user ]; then
	make -s install DESTDIR="$W/stage" >"$O/install.log" 2>&1 || { tail -20 "$O/install.log"; exit 1; }
	S=$W/stage
	mkdir -p "$Kp"/{sbin,lib}
	for t in zpool zfs zdb zinject zhack zstream ${EXTRA:-}; do
		if [ -e "$S/usr/sbin/$t" ]; then cp -L "$S/usr/sbin/$t" "$Kp/sbin/"
		elif [ -e "$S/usr/bin/$t" ]; then cp -L "$S/usr/bin/$t" "$Kp/sbin/"
		elif [ -e "$S/usr/share/zfs/zfs-tests/bin/$t" ]; then cp -L "$S/usr/share/zfs/zfs-tests/bin/$t" "$Kp/sbin/"
		else echo "no $t in this build"; fi
	done
	L=$S/usr/lib
	for f in "$Kp"/sbin/*; do LD_LIBRARY_PATH=$L ldd "$f" 2>/dev/null | grep -o '/[^ ]*' || true; done |
	    grep "^$L/" | sort -u | while read -r l; do cp -L "$l" "$Kp/lib/${l##*/}"; done
	if [ -x "$Kp/sbin/zed" ] && [ -d "$S/etc/zfs/zed.d" ]; then
		mkdir -p "$Kp/zed"
		cp -a "$S/etc/zfs/zed.d" "$Kp/zed/etc"
		cp -a "$S/usr/libexec/zfs/zed.d" "$Kp/zed/libexec"
	fi
	file "$Kp"/sbin/* "$Kp"/lib/* | grep ELF >/dev/null
	strip --strip-unneeded "$Kp"/sbin/* "$Kp"/lib/* 2>/dev/null || true
	echo "$MARKER" >"$Kp/build.txt"
else
	K=${KERNEL:?KERNEL}
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
	{ echo "$MARKER"; echo "zfs $(modinfo -F version "$Kp/modules/zfs.ko") srcversion $(modinfo -F srcversion "$Kp/modules/zfs.ko")"; } >"$Kp/build.txt"
fi
echo "zfs-tree $MODE: built in $(( $(date +%s) - t0 ))s (make $(( $(date +%s) - t1 ))s)"
rm -rf "$O/pkg"; mv "$Kp" "$O/pkg"
cd /; rm -rf "$W"
cat "$O/pkg/build.txt"
