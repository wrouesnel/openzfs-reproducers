#!/bin/bash
# payload.sh PART OUTDIR [REPO SHA CONFIGURE...]   (the target's builder, root)
# The build-time payload of wrouesnel/fix-nfs-reconnect-hint-v3-lustre
# (docs/reproducer-format.md, "Payloads"): builder/build.sh runs it in the
# almalinux9 builder (AlmaLinux 9, the target kernel's headers in
# /kernel/env) and puts OUTDIR on the demo disk as /demo/payload/TARGET/PART.
#   common   OUTDIR/root: an AlmaLinux 9 root file system with what Lustre's
#            test framework needs (dnf --installroot; EPEL for pdsh (its exec module), dbench).
#            The demo runs Lustre in a chroot of it, on the target's kernel.
#   repro | fixed   one OpenZFS build (REPO@SHA, configure CONFIGURE), the
#            whole of it (tools, libraries, modules) built on AlmaLinux 9
#            for the target kernel, and Lustre built against that tree
#            (osd-zfs is built per OpenZFS version: modversions differ),
#            installed into OUTDIR/root (to be layered over common's root).
#            OUTDIR/build/ keeps the build's record: summary.txt, Lustre's
#            configure result (config.h HAVE_*/ZFS_* defines), the warnings,
#            zfs's Module.symvers and the modversions osd_zfs.ko imports.
#            repro (OpenZFS master) also gets OUTDIR/debug/: the same, from a
#            --enable-debug OpenZFS build (the opt-in `debugpanic` tag).
# OUTDIR/SOURCES.txt says what went in.
set -euo pipefail
PART=${1:?part} O=${2:?outdir}
LUSTRE_REPO=https://github.com/lustre/lustre-release
LUSTRE_TAG=v2_17_60				# Lustre master "New tag 2.17.60"
LUSTRE_SHA=6325870717c7899f1ba545493ce2a07cb3834a6b	# (checked below)
K=${KERNEL:?KERNEL}
J=${MAKEJOBS:-$(nproc)}
retry() { local i; for i in 1 2 3 4 5; do "$@" && return 0; echo "retry $i: $*" >&2; sleep $((i * 15)); done; return 1; }
mkdir -p "$O"
W=$(mktemp -d /tmp/payload.XXXXXX)
DNF=(dnf -y -q --setopt=install_weak_deps=False --setopt=tsflags=nodocs)

# usr-merge: AlmaLinux 9's /lib, /lib64, /bin and /sbin are links into /usr,
# and an install tree layered over it must not have them as directories
usrmerge() {
	local r=$1 d
	for d in lib lib64 bin sbin; do
		[ -d "$r/$d" ] && [ ! -L "$r/$d" ] || continue
		mkdir -p "$r/usr/$d"; cp -a "$r/$d/." "$r/usr/$d/"; rm -rf "${r:?}/$d"
	done
}
slim() {	# an install tree: no docs, headers, static libraries; modules and programs stripped
	local r=$1
	rm -rf "$r"/usr/share/{doc,man,info,locale} "$r"/usr/include "$r"/usr/src "$r"/usr/lib64/pkgconfig "$r"/usr/share/pkgconfig
	# OpenZFS's test suite, and the old-format disk images of Lustre's
	# conf-sanity (neither is run here)
	rm -rf "$r"/usr/share/zfs/zfs-tests "$r"/usr/share/zfs/runfiles "$r"/usr/share/zfs/test-runner "$r"/usr/share/zfs/zfs-tests.sh
	rm -f "$r"/usr/lib64/lustre/tests/*.tar.bz2 "$r"/usr/lib64/lustre/tests/*.tar.xz
	find "$r" \( -name '*.a' -o -name '*.la' \) -delete
	find "$r" -name '*.ko' -exec strip --strip-debug {} +
	find "$r" -type f \( -perm -u+x -o -name '*.so*' \) -exec sh -c 'for f; do head -c4 "$f" | grep -q ELF && strip --strip-unneeded "$f" 2>/dev/null; done; true' sh {} +
}

if [ "$PART" = common ]; then
	retry "${DNF[@]}" install epel-release >/dev/null
	R=$O/root; mkdir -p "$R"
	# the packages the spike VM had for llmount.sh and sanity.sh (repros/16254
	# in zfs-bug-hunt): the test framework's tools, pdsh (exec), dbench, and
	# the libraries of Lustre's and OpenZFS's tools
	PKGS='setup filesystem basesystem bash coreutils util-linux procps-ng iproute kmod findutils
	    gawk sed grep diffutils which hostname file tar gzip xz bzip2 cpio attr acl bc lsof rsync
	    python3 perl-interpreter jq e2fsprogs iputils net-tools strace less sudo shadow-utils
	    libyaml libnl3 json-c keyutils-libs libmount libtirpc libuuid libblkid openssl-libs zlib
	    libaio systemd-libs systemd-udev libselinux krb5-libs libgcc libffi ncurses
	    pdsh dbench'
	# shellcheck disable=SC2086
	retry "${DNF[@]}" --installroot="$R" --releasever=9 --setopt=reposdir=/etc/yum.repos.d \
	    --setopt=cachedir=/var/cache/dnf install $PKGS >"$W/dnf.log" 2>&1 || { tail -30 "$W/dnf.log"; exit 1; }
	rpm --root "$R" -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH} %{SOURCERPM}\n' | sort >"$W/rpms.txt"
	rm -rf "$R"/var/cache/dnf "$R"/var/lib/dnf "$R"/var/log/* "$R"/usr/share/{doc,man,info} \
	    "$R"/usr/lib/locale/locale-archive* "$R"/usr/share/locale/*/LC_MESSAGES 2>/dev/null || true
	find "$R/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name 'en*' -exec rm -rf {} + 2>/dev/null || true
	# what the demo fills in at run time (hostname, hosts, modules)
	mkdir -p "$R/usr/lib/modules"
	: >"$R/etc/machine-id"
	{
		echo "AlmaLinux 9 root file system for the Lustre chroot (dnf --installroot, $(date -u +%F);"
		echo "AlmaLinux 9 BaseOS/AppStream and EPEL 9). Packages: NAME VERSION SOURCE-RPM"
		echo "(sources: https://vault.almalinux.org/ and https://dl.fedoraproject.org/pub/epel/9/):"
		sed 's/^/  /' "$W/rpms.txt"
	} >"$O/SOURCES.txt"
	du -sh "$R" | sed 's/^/common root: /'
	rm -rf "$W"; exit 0
fi

REPO=${3:?repo} SHA=${4:?sha}; shift 4
CONF=("$@")
. /kernel/env
retry "${DNF[@]}" install dnf-plugins-core epel-release >/dev/null
dnf config-manager -q --set-enabled crb
retry "${DNF[@]}" install libtool flex bison libyaml-devel libnl3-devel keyutils-libs-devel \
    libmount-devel json-c-devel libselinux-devel krb5-devel openssl-devel libuuid-devel \
    libblkid-devel libtirpc-devel zlib-devel libaio-devel systemd-devel libattr-devel \
    libffi-devel python3-devel ncurses-devel rpm-build >"$W/deps.log" 2>&1 || { tail -30 "$W/deps.log"; exit 1; }

git init -q "$W/lustre"
(cd "$W/lustre" && retry git fetch -q --depth 1 "$LUSTRE_REPO" "refs/tags/$LUSTRE_TAG:refs/tags/$LUSTRE_TAG" &&
    git -c advice.detachedHead=false checkout -q "$LUSTRE_TAG")
[ "$(git -C "$W/lustre" rev-parse HEAD)" = "$LUSTRE_SHA" ] || { echo "Lustre $LUSTRE_TAG is $(git -C "$W/lustre" rev-parse HEAD), not $LUSTRE_SHA" >&2; exit 1; }
git init -q "$W/zsrc"
(cd "$W/zsrc" && git remote add origin "$REPO" && retry git fetch -q --filter=blob:none origin "$SHA" &&
    git -c advice.detachedHead=false checkout -q "$SHA" && sh autogen.sh >/dev/null 2>&1)

# one OpenZFS + Lustre build: VARIANT (build|debug) into DEST, record in DEST/../build
one() {
	local v=$1 D=$2 B=$3 zs=$W/zfs-$1 ls=$W/lustre-$1 t0=$SECONDS zc
	shift 3; zc=("$@")
	mkdir -p "$D" "$B"
	cp -a "$W/zsrc" "$zs"; cp -a "$W/lustre" "$ls"
	cd "$zs"
	./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc --localstatedir=/var \
	    --with-linux="$KSRC" --with-linux-obj="$KOBJ" --disable-pyzfs --disable-sysvinit \
	    "${zc[@]}" >"$W/zconf-$v.log" 2>&1 || { tail -40 "$W/zconf-$v.log"; exit 1; }
	make -j"$J" >"$W/zmake-$v.log" 2>&1 || { grep -E 'error|Error' "$W/zmake-$v.log" | head -40; exit 1; }
	make install DESTDIR="$D" >"$W/zinst-$v.log" 2>&1 || { tail -30 "$W/zinst-$v.log"; exit 1; }
	cp module/Module.symvers "$B/zfs.Module.symvers"
	cd "$ls"
	sh autogen.sh >"$W/lauto-$v.log" 2>&1 || { tail -30 "$W/lauto-$v.log"; exit 1; }
	./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc --localstatedir=/var \
	    --disable-ldiskfs --enable-server --disable-gss --with-linux="$KSRC" --with-linux-obj="$KOBJ" \
	    --with-zfs="$zs" --with-zfs-obj="$zs" >"$W/lconf-$v.log" 2>&1 || { tail -60 "$W/lconf-$v.log"; exit 1; }
	make -j"$J" >"$W/lmake-$v.log" 2>&1 || { grep -E 'error|Error' "$W/lmake-$v.log" | head -60; exit 1; }
	make install DESTDIR="$D" >"$W/linst-$v.log" 2>&1 || { tail -30 "$W/linst-$v.log"; exit 1; }
	local osd; osd=$(find "$ls/lustre/osd-zfs" -name osd_zfs.ko | head -1)
	[ -n "$osd" ] || { echo "no osd_zfs.ko built" >&2; exit 1; }
	modprobe --dump-modversions "$osd" | awk '{ print $2, $1 }' | sort >"$B/osd_zfs.modversions"
	grep -E '^#define (HAVE_|ZFS_|LUSTRE_)' "$ls/config.h" | sort >"$B/lustre-config-defines.txt"
	grep -E 'warning:' "$W/lmake-$v.log" | sort -u >"$B/lustre-warnings.txt" || true
	grep -E 'warning:' "$W/zmake-$v.log" | sort -u >"$B/zfs-warnings.txt" || true
	tail -25 "$W/lconf-$v.log" >"$B/lustre-configure-tail.txt"
	{
		echo "openzfs:   ${REPO%.git}@$SHA"
		echo "           $(git -C "$zs" log -1 --format='%h %s')"
		echo "           configure ${zc[*]:-(defaults)}"
		echo "           zfs.ko $(modinfo -F version "$zs/module/zfs.ko") srcversion $(modinfo -F srcversion "$zs/module/zfs.ko")"
		echo "lustre:    $LUSTRE_REPO@$LUSTRE_SHA ($LUSTRE_TAG, $(cat "$ls/LUSTRE-VERSION-FILE" 2>/dev/null | sed 's/.*= *//'))"
		echo "           configure --disable-ldiskfs --enable-server --disable-gss --with-zfs=<this openzfs tree>"
		echo "kernel:    $K (headers $KSRC)"
		echo "osd_zfs.ko $(stat -c %s "$osd") bytes (with debug info), imports $(wc -l <"$B/osd_zfs.modversions") symbols with modversions"
		echo "warnings:  lustre $(wc -l <"$B/lustre-warnings.txt"), openzfs $(wc -l <"$B/zfs-warnings.txt") (make, unique lines)"
		echo "built in:  $((SECONDS - t0)) s on $(nproc) CPUs"
	} >"$B/summary.txt"
	usrmerge "$D"; slim "$D"
	# the modules must be where the chroot's modprobe looks
	ls "$D/usr/lib/modules/$K/extra" >/dev/null
	cd /; rm -rf "$zs" "$ls"
	cat "$B/summary.txt"
}
one build "$O/root" "$O/build" "${CONF[@]}"
if [ "$PART" = repro ] && [ "${LUSTRE_DEBUG_PAYLOAD:-1}" = 1 ]; then
	one debug "$O/debug/root" "$O/debug/build" "${CONF[@]}" --enable-debug
fi
{
	echo "OpenZFS ${REPO%.git}/commit/$SHA, built on AlmaLinux 9 for $K (CDDL-1.0)."
	echo "Lustre $LUSTRE_REPO/commit/$LUSTRE_SHA ($LUSTRE_TAG), built against it (GPL-2.0)."
	[ -d "$O/debug" ] && echo "debug/: the same two, from an OpenZFS --enable-debug build."
	echo "Both unmodified; the build records are in build/ (and debug/build/)."
} >"$O/SOURCES.txt"
du -sh "$O"/* | sed 's/^/payload: /'
rm -rf "$W"
