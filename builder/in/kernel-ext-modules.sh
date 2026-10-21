#!/bin/bash
# kernel-ext-modules.sh TARGET OUTDIR   (in the target's builder container, root)
# Fetches the target kernel's full module tree, which the standard target
# leaves out (kernel-stage.sh keeps only the boot path): the packages the
# distribution splits it into, at the target's pinned version:
#   ubuntu   linux-modules-K, linux-modules-extra-K (when there is one)
#   debian   linux-image-K (the modules are in it)
#   rhel, fedora   kernel-core, kernel-modules-core, kernel-modules,
#                  kernel-modules-extra (next to kernel-core in KERNEL_RPMS'
#                  repository; AlmaLinux: BaseOS or AppStream)
#   alpine   linux-stable=APKVER
# Writes OUTDIR/modules.tar (lib/modules/K/, without the distribution's own
# zfs and spl, and gzip-compressed modules unpacked: the userland's kmod has
# no zlib) and OUTDIR/modules-pkg.txt (the packages, for SOURCES.txt).
# kernel-ext.sh (in the userland builder) runs depmod and writes the tree
# into the extended root.
set -euo pipefail
NAME=${1:?target} O=${2:?outdir}
K=${KERNEL:?KERNEL}
# the target's pins (inb passes KERNEL, not these)
bconf() { (set +u; . "/src/bases/$NAME/base.conf"; eval "printf '%s' \"\${$1:-}\""); }
KERNEL_RPMS=$(bconf KERNEL_RPMS) APKVER=$(bconf APKVER)
W=$(mktemp -d /tmp/kmods.XXXXXX) R=$W/root
mkdir -p "$O" "$R"
retry() { local i; for i in 1 2 3 4 5 6; do "$@" && return 0; echo "retry $i: $*" >&2; sleep $((i * 10)); done; return 1; }
. /etc/os-release
cd "$W"
case " $ID ${ID_LIKE:-} " in
*" ubuntu "* | *" debian "*)
	case $ID in
	ubuntu) want="linux-modules-$K linux-modules-extra-$K" ;;
	*) want="linux-image-$K" ;;
	esac
	# the .debs are kept in /work/cache/kmods (a pinned kernel's packages
	# don't change); the archive (Ubuntu's snapshot service) is retried
	C=/work/cache/kmods; [ -d /work ] || C=$W/cache
	mkdir -p "$C"
	for p in $want; do
		ls "$C/${p}_"*.deb >/dev/null 2>&1 && continue
		got=
		for i in 1 2 3 4 5 6 7 8; do
			if apt-get update -qq >/dev/null 2>&1 && (cd "$C" && apt-get download -qq "$p") 2>"$W/err"; then got=1; break; fi
			# Ubuntu: not every kernel flavour has an -extra package
			case $p in linux-modules-extra-*)
				# (only when the index is there: it knows linux-modules-K)
				apt-cache show "linux-modules-$K" >/dev/null 2>&1 && grep -q 'Unable to locate\|No packages found\|has no installation candidate' "$W/err" && { got=-; break; } ;;
			esac
			echo "apt: retry $i ($p)" >&2; sleep $((i * 15))
		done
		[ -n "$got" ] || { cat "$W/err" >&2; exit 1; }
	done
	for p in $want; do f=$(ls "$C/${p}_"*.deb 2>/dev/null | tail -1) && [ -n "$f" ] && cp "$f" "$W/"; done
	for d in *.deb; do dpkg -x "$d" "$R"; dpkg-deb -W --showformat='${Package} ${Version} ${source:Package}\n' "$d"; done >"$O/modules-pkg.txt"
	;;
*" rhel "* | *" fedora "* | *" centos "*)
	core=$(printf '%s\n' $KERNEL_RPMS | grep '/kernel-core-' | head -1)
	[ -n "$core" ] || { echo "no kernel-core in KERNEL_RPMS" >&2; exit 1; }
	dir=${core%/*} v=${core##*/kernel-core-}
	for p in kernel-core kernel-modules-core kernel-modules kernel-modules-extra; do
		got=
		for d in "$dir" "${dir/\/BaseOS\//\/AppStream\/}" "${dir/\/AppStream\//\/BaseOS\/}"; do
			curl -fsSLO --retry 5 "$d/$p-$v" 2>/dev/null && { got=1; break; }
		done
		# kernel-modules-core is EL9 and later; EL8's kernel-core has those
		[ -n "$got" ] || { case $p in kernel-modules-core) continue ;; esac; echo "cannot fetch $p-$v" >&2; exit 1; }
	done
	for r in *.rpm; do
		(cd "$R" && rpm2cpio "$W/$r" | cpio -idm --quiet)
		rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE} %{SOURCERPM}\n' "$r"
	done >"$O/modules-pkg.txt"
	;;
*" alpine "*)
	retry apk fetch -q --update linux-stable
	[ -f "linux-stable-$APKVER.apk" ] || { echo "linux-stable is no longer $APKVER" >&2; exit 1; }
	apk extract -q --allow-untrusted --destination "$R" "linux-stable-$APKVER.apk"
	echo "linux-stable $APKVER aports:community/linux-stable" >"$O/modules-pkg.txt"
	;;
*) echo "kernel-ext-modules: no recipe for $ID" >&2; exit 1 ;;
esac
M=$R/lib/modules/$K; [ -d "$M" ] || M=$R/usr/lib/modules/$K
[ -d "$M" ] || { echo "no lib/modules/$K in the packages" >&2; exit 1; }
# the distribution's OpenZFS (Ubuntu ships one) must never load instead of
# the image's build
find "$M" \( -name 'zfs.ko*' -o -name 'spl.ko*' \) -print -delete | sed 's/^/left out: /'
find "$M" -type d -empty -delete
find "$M" -name '*.ko.gz' -exec gunzip {} +
# what modprobe needs: the modules and their index sources; not the build
# and source links, vmlinuz, System.map or the BTF and BPF bits
rm -f "$M/build" "$M/source" "$M/vmlinuz" "$M/System.map" "$M/config" "$M"/*.bin
mkdir -p "$W/t/lib/modules"; mv "$M" "$W/t/lib/modules/$K"
find "$W/t" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-0}" {} +
tar -C "$W/t" --sort=name --owner=0 --group=0 --numeric-owner -cf "$O/modules.tar" lib 2>/dev/null ||
    tar -C "$W/t" -cf "$O/modules.tar" lib
echo "kernel-ext-modules: $K: $(find "$W/t" -name '*.ko*' | wc -l) modules, $(du -sh --apparent-size "$W/t" | cut -f1) unpacked"
rm -rf "$W"
