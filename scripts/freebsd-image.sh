#!/bin/bash
# scripts/freebsd-image.sh: wrap FreeBSD target and reproducer disks built
# on FreeBSD into the same images as the Linux ones.  CI builds Linux only
# (README, "FreeBSD"); a FreeBSD reproducer's disks are built on a FreeBSD
# VM (for example with zfs-bug-hunt's vm/mkdemo-base.sh and vm/mkdemo.sh,
# booted from openzfs CI's own FreeBSD images), from public commits only:
#
#   scripts/freebsd-image.sh target TARGET BASE.qcow2 BASE.manifest
#       TARGET: bases/TARGET/base.conf (OS=FreeBSD, KERNEL=); the manifest's
#       KERNEL must match.  The disk holds the GENERIC kernel and a minimal
#       userland of that release.  Writes work/targets/TARGET/.
#   scripts/freebsd-image.sh repro ID TARGET REPRO.qcow2 REPRO.manifest
#       ID: reproducers/USER/SLUG; the manifest's builds bug= and fix= must be
#       the commits its BUILD_repro and BUILD_fixed specs resolve to now
#       (builder/build.sh resolve; checked by sha prefix).  The
#       FreeBSD disk holds the demo and both builds; each image gets the whole
#       disk and boots its own build (LEGACY_LABEL).  Writes work/demos/ID and
#       work/builds/ID/TARGET/{repro,fixed}.
#   builder/build.sh images ID TARGET      the images, as for Linux
#   builder/build.sh check ID TARGET       podman run ... --check for both
#   builder/build.sh push ID TARGET        (podman login ghcr.io first)
#
# FreeBSD targets have no zr host channel (ttyS2/uart2) yet, so reproducers
# with host.sh are Linux only.
set -euo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
WORK=${ZFS_REPRO_WORK:-$T/work}
B=$T/builder/build.sh
conf() { (set +u; . "$1" >/dev/null; eval "printf '%s' \"\${$2:-}\""); }
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
c=${1:?usage: see the header}; shift
case $c in
target)
	t=${1:?TARGET} img=${2:?qcow2} man=${3:?manifest}
	bc=$T/bases/$t/base.conf
	[ "$(conf "$bc" OS)" = FreeBSD ] || { echo "$bc: OS is not FreeBSD" >&2; exit 1; }
	[ "$(conf "$man" KERNEL)" = "$(conf "$bc" KERNEL)" ] ||
	    { echo "the disk has kernel $(conf "$man" KERNEL), $bc says $(conf "$bc" KERNEL)" >&2; exit 1; }
	o=$WORK/targets/$t; rm -rf "$o"; mkdir -p "$o"
	cp "$img" "$o/base.qcow2"
	{
		echo "NAME=$(q "$t")"
		echo "TARGET=$(q "$t")"
		echo "OS=FreeBSD"
		echo "ARCH=x86_64"
		echo "KERNEL=$(q "$(conf "$bc" KERNEL)")"
		echo "DISTRO=$(q "$(conf "$man" KERNEL_BUILD)")"
		echo "BOOT=disk"
		echo "CMDLINE=''"
		echo "RUN_DISK=whole"
	} >"$o/base.conf"
	{
		echo "SOURCES for the zfs-repro target $t: $(conf "$man" KERNEL_BUILD)"
		echo
		echo "One disk with FreeBSD's GENERIC kernel and a minimal userland of that build, taken"
		echo "unmodified from the FreeBSD CI image openzfs/zfs CI boots for $t"
		echo "(https://download.freebsd.org/releases/CI-IMAGES/ and .../snapshots/CI-IMAGES/),"
		echo "plus the demo rc scripts (zfs-bug-hunt vm/mkdemo-base.sh).  There is no ZFS from"
		echo "the base system: the image's build is loaded from its own disk."
		echo "Source: https://download.freebsd.org/ (src.txz of the same release or snapshot),"
		echo "https://cgit.freebsd.org/src/ ($(conf "$man" KERNEL_BUILD | awk '{ print $3 }'))."
		echo "FreeBSD's base system is mostly BSD-licensed."
	} >"$o/SOURCES.txt"
	ls -l "$o" ;;
repro)
	id=${1:?ID} t=${2:?TARGET} img=${3:?qcow2} man=${4:?manifest}
	rd=$T/reproducers/$id rc=$rd/reproducer.conf
	[ -f "$rc" ] || { echo "no $rc" >&2; exit 1; }
	[ -f "$WORK/targets/$t/base.conf" ] || { echo "import target $t first" >&2; exit 1; }
	[ "$(conf "$man" KERNEL)" = "$(conf "$WORK/targets/$t/base.conf" KERNEL)" ] ||
	    { echo "the reproducer is for kernel $(conf "$man" KERNEL), $t has $(conf "$WORK/targets/$t/base.conf" KERNEL)" >&2; exit 1; }
	[ -f "$rd/host.sh" ] && { echo "host.sh: FreeBSD targets have no host channel yet" >&2; exit 1; }
	# the build specs, resolved (saved for builder/build.sh images too)
	"$B" resolve "$id" >/dev/null
	res=$WORK/resolved/${id//\//-}.conf
	for p in repro:bug fixed:fix; do
		l=${p%%:*} ll=${p#*:}
		want=$(conf "$res" "BUILD_$l"); want=${want##*@}
		have=$(conf "$man" "BUILD_$ll" | cut -d' ' -f1)
		[ -n "$have" ] && [ "${want#"$have"}" != "$want" ] ||
		    { echo "build $l: the disk has '$have' as $ll, reproducer.conf wants $want" >&2; exit 1; }
	done
	d=$WORK/demos/$id; rm -rf "$d"; mkdir -p "$d"
	cp "$rd/demo.sh" "$d/"; [ -f "$rd/inspect.sh" ] && cp "$rd/inspect.sh" "$d/"
	{
		echo "# reproducer $id (reproducers/$id/reproducer.conf)"
		grep -v -e '^#' -e '^$' "$rc"
		for l in repro fixed; do echo "SPEC_$l=$(q "$(conf "$rc" "BUILD_$l")")"; echo "BUILD_$l=$(q "$(conf "$res" "BUILD_$l")")"; done
		echo "ID=$(q "$id")"
		echo "DISK_BYTES=$(numfmt --from=iec "$(conf "$rc" DISK_SIZE)")"
	} >"$d/repro.conf"
	{
		echo "SOURCES for the zfs-repro reproducer $id"
		echo
		echo "Bug: $(conf "$rc" TITLE)"
		echo "Fix branch: $(conf "$rc" REPO)/tree/$(conf "$rc" BRANCH)"
		echo "Demo: demo.sh (reproducers/$id in https://github.com/wrouesnel/openzfs-reproducers)."
		echo "The FreeBSD disk was built on FreeBSD $(conf "$man" KERNEL) from the commits below."
	} >"$d/SOURCES.txt"
	for p in repro:bug fixed:fix; do
		l=${p%%:*} ll=${p#*:}
		o=$WORK/builds/$id/$t/$l; rm -rf "$o"; mkdir -p "$o"
		cp "$img" "$o/build.qcow2"
		{
			echo "# the OpenZFS build of this image (scripts/freebsd-image.sh)"
			echo "LABEL=$(q "$l")"
			echo "LEGACY_LABEL=$(q "$ll")"
			echo "TARGET=$(q "$t")"
			echo "KERNEL=$(q "$(conf "$man" KERNEL)")"
			echo "BUILD=$(q "$(conf "$res" "BUILD_$l")")"
			echo "SPEC=$(q "$(conf "$rc" "BUILD_$l")")"
			echo "MARKER=$(q "$(conf "$man" "BUILD_$ll")")"
			echo "ZFS=''"
			for k in EXPECT EXPECT_INSPECT RUNS MIN_MATCH; do echo "$k=$(q "$(conf "$rc" "${k}_$l")")"; done
			echo "TAG=$(q "$("$B" tag "$id" "$l" "$t")")"
		} >"$o/build.conf"
		{
			echo "SOURCES for the OpenZFS build '$l' of $id on target $t"
			echo
			echo "  commit: $(conf "$res" "BUILD_$l" | sed 's|@|/commit/|')"
			echo "  $(conf "$man" "BUILD_$ll")"
			echo "  configure: $(conf "$rc" CONFIGURE), built on FreeBSD $(conf "$man" KERNEL)"
			echo
			echo "OpenZFS is licensed under the CDDL-1.0; its source for this build is the commit above."
		} >"$o/SOURCES.txt"
	done
	ls -l "$d" "$WORK/builds/$id/$t"/* ;;
*) echo "unknown command $c" >&2; exit 2 ;;
esac
