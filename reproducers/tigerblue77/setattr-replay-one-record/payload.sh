#!/bin/bash
# payload.sh PART OUTDIR [REPO SHA CONFIGURE...]   (the target's builder, root)
# The build-time payload of tigerblue77/setattr-replay-one-record
# (docs/reproducer-format.md, "Payloads"): OpenZFS kernel modules for the
# target's kernel, put on the demo disk as /demo/payload/TARGET/PART.
#   common         the WRITER: spl.ko and zfs.ko of openzfs/zfs 9ac6648a22,
#                  the parent of b306edf42f (#19706), unchanged.  Linux
#                  before #19706 logs a truncate as one TX_SETATTR record
#                  with ATTR_SIZE (as FreeBSD still does); since #19706 it
#                  logs TX_TRUNCATE instead, so the image's own build can't
#                  write the record that the bug needs.
#   repro | fixed  the REPLAYER: spl.ko and zfs.ko of that image's own build
#                  (REPO@SHA, CONFIGURE) with one test-only hook added to
#                  zfs_setattr() (OUTDIR/hook.diff, the whole change): with
#                  the module parameter zfs_hunt_replay_stop_ms > 0, while
#                  the ZIL is replayed, right after zfs_freesp() has changed
#                  the size, wait for that txg to sync and sleep that long,
#                  so that the demo can copy the pool's disk exactly where a
#                  power cut would leave it.  At 0 (the default) it does
#                  nothing.  Both images get the same hook.
# Each PART: OUTDIR/modules/{spl,zfs}.ko (debug info stripped),
# OUTDIR/build.txt (commit, zfs version and srcversion), OUTDIR/kernel.txt,
# OUTDIR/SOURCES.txt.
set -euo pipefail
PART=${1:?part} O=${2:?outdir}
WRITER_REPO=https://github.com/openzfs/zfs
WRITER_SHA=9ac6648a22fa003f6e7adc7bc8eac16e7a59362f	# b306edf42f^ (openzfs/zfs master, 2026-11-11)
WRITER_CONF=--enable-debug
K=${KERNEL:?KERNEL}
J=${MAKEJOBS:-$(nproc)}
retry() { local i; for i in 1 2 3 4 5; do "$@" && return 0; echo "retry $i: $*" >&2; sleep $((i * 15)); done; return 1; }
mkdir -p "$O"
W=$(mktemp -d /tmp/payload.XXXXXX)
. /kernel/env

# the hook, inserted after the zfs_freesp() call of zfs_setattr()'s size
# change (the call's last argument differs between master and the PR)
hook() {
	local f=module/os/linux/zfs/zfs_vnops_os.c
	awk '
	{ print }
	/^#include <linux\/mm_compat.h>$/ && !h {
		print "#include <linux/moduleparam.h>"
		print "#include <linux/delay.h>"
		print ""
		print "/* openzfs-reproducers (test-only): pause replay after the size change */"
		print "static int zfs_hunt_replay_stop_ms = 0;"
		print "module_param(zfs_hunt_replay_stop_ms, int, 0644);"
		h = 1
	}
	/^\t\terr = zfs_freesp\(zp, vap->va_size, 0, 0, / { s = 1; next }
	s == 1 && /^\t\tif \(err\)$/ { s = 2; next }
	s == 2 && /^\t\t\tgoto out3;$/ {
		print "\t\tif (zfsvfs->z_replay && zfs_hunt_replay_stop_ms > 0) {"
		print "\t\t\ttxg_wait_synced(dmu_objset_pool(zfsvfs->z_os), 0);"
		print "\t\t\tprintk(KERN_NOTICE \"zfs-hunt: replay window open obj %llu \""
		print "\t\t\t    \"(size change synced, setattr txg not assigned)\\n\","
		print "\t\t\t    (u_longlong_t)zp->z_id);"
		print "\t\t\tmsleep(zfs_hunt_replay_stop_ms);"
		print "\t\t}"
		n++; s = 0; next
	}
	{ s = 0 }
	END { if (!h || n != 1) exit 1 }
	' "$f" >"$f.new" || { echo "payload.sh: the hook's insertion points are not in $f" >&2; exit 1; }
	mv "$f.new" "$f"
	git diff >"$O/hook.diff"
	[ "$(git diff --numstat | cut -f1,2 | tr '\t' ' ')" = "13 0" ] || { echo "payload.sh: unexpected hook diff" >&2; cat "$O/hook.diff" >&2; exit 1; }
}

# kmod REPO SHA HOOK CONFIGURE...: the modules of REPO@SHA into OUTDIR
kmod() {
	local repo=$1 sha=$2 hk=$3 t0=$SECONDS; shift 3
	git init -q "$W/src"; cd "$W/src"
	git remote add origin "$repo"
	retry git fetch -q --filter=blob:none origin "$sha"
	git -c advice.detachedHead=false checkout -q "$sha"
	[ "$hk" = 1 ] && hook
	sh autogen.sh >"$W/autogen.log" 2>&1
	./configure --with-config=kernel --with-linux="$KSRC" --with-linux-obj="$KOBJ" \
	    "$@" >"$W/configure.log" 2>&1 || { tail -40 "$W/configure.log"; exit 1; }
	make -s -j"$J" >"$W/make.log" 2>&1 || { grep -E 'error|Error' "$W/make.log" | head -60; exit 1; }
	mkdir -p "$O/modules"
	for m in spl zfs; do
		f=$(find module -name "$m.ko" | head -1)
		[ -n "$f" ] || { echo "no $m.ko built" >&2; exit 1; }
		cp "$f" "$O/modules/"
	done
	[ "$(modinfo -F vermagic "$O/modules/zfs.ko" | cut -d' ' -f1)" = "$K" ] ||
	    { echo "zfs.ko is for $(modinfo -F vermagic "$O/modules/zfs.ko"), not $K" >&2; exit 1; }
	strip --strip-debug "$O"/modules/*.ko
	if [ "$hk" = 1 ]; then
		pt=$(modinfo -F parmtype "$O/modules/zfs.ko")
		grep -q '^zfs_hunt_replay_stop_ms:' <<<"$pt" ||
		    { echo "zfs.ko has no zfs_hunt_replay_stop_ms" >&2; exit 1; }
	fi
	{
		echo "$(git log -1 --format='%h %s' "$sha")$([ "$hk" = 1 ] && echo ' + the test-only replay hook (hook.diff)')"
		echo "zfs $(modinfo -F version "$O/modules/zfs.ko") srcversion $(modinfo -F srcversion "$O/modules/zfs.ko")"
	} >"$O/build.txt"
	echo "$K" >"$O/kernel.txt"
	{
		echo "OpenZFS kernel modules (spl.ko, zfs.ko) for $K, configure $*:"
		echo "  ${repo%.git}/commit/$sha"
		echo "  $(git log -1 --format='%s' "$sha")"
		[ "$hk" = 1 ] && echo "  plus a test-only hook in zfs_setattr() (hook.diff, 13 lines added)"
		echo "  built in $((SECONDS - t0)) s"
	} >"$O/SOURCES.txt"
	cd /; rm -rf "$W/src"
	cat "$O/build.txt"
}

if [ "$PART" = common ]; then
	kmod "$WRITER_REPO" "$WRITER_SHA" 0 $WRITER_CONF
else
	REPO=${3:?repo} SHA=${4:?sha}; shift 4
	kmod "$REPO" "$SHA" 1 "$@"
fi
rm -rf "$W"
