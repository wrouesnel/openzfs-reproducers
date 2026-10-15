#!/bin/bash
# scripts/freebsd-image.sh: wrap FreeBSD base and reproducer disks built
# outside CI into the same container images as the Linux ones.  CI builds
# Linux only (see README, "FreeBSD"); a FreeBSD reproducer's disks are built
# on a FreeBSD VM (for example with zfs-bug-hunt's vm/mkdemo-base.sh and
# vm/mkdemo.sh, booted from openzfs CI's own FreeBSD images), then:
#
#   scripts/freebsd-image.sh base BASE BASE.qcow2 BASE.manifest SOURCES.txt
#       BASE: a directory bases/BASE/ with base.conf (OS=FreeBSD, KERNEL=);
#       the manifest's KERNEL must match.  Writes work/bases/BASE/.
#   scripts/freebsd-image.sh repro ID REPRO.qcow2 REPRO.manifest SOURCES.txt [PATCHDIR]
#       ID: reproducers/ID/ with reproducer.conf (BASE=a FreeBSD base); the
#       manifest's builds must be the BUILD_<label> commits (checked by sha
#       prefix).  Writes work/repros/ID/.
#   builder/build.sh images ID      the images, as for Linux
#   builder/build.sh check ID       podman run ... --check for every build
#   podman login ghcr.io -u wrouesnel      (a token with write:packages)
#   builder/build.sh push ID
#
# Only builds of public commits may be published: SOURCES.txt must name
# them (repo + sha) and any patch must be in PATCHDIR.  FreeBSD bases have
# no zr host channel (ttyS2/uart2) yet, so reproducers with host.sh are
# Linux only.
set -euo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
WORK=${ZFS_REPRO_WORK:-$T/work}
conf() { (set +u; . "$1"; eval "printf '%s' \"\${$2:-}\""); }
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
c=${1:?usage: see the header}; shift
case $c in
base)
	b=${1:?BASE} img=${2:?qcow2} man=${3:?manifest} src=${4:?SOURCES.txt}
	bc=$T/bases/$b/base.conf
	[ -f "$bc" ] || { echo "no $bc" >&2; exit 1; }
	[ "$(conf "$bc" OS)" = FreeBSD ] || { echo "$bc: OS is not FreeBSD" >&2; exit 1; }
	[ "$(conf "$man" KERNEL)" = "$(conf "$bc" KERNEL)" ] ||
	    { echo "the base image has kernel $(conf "$man" KERNEL), $bc says $(conf "$bc" KERNEL)" >&2; exit 1; }
	o=$WORK/bases/$b; rm -rf "$o"; mkdir -p "$o"
	cp "$img" "$o/base.qcow2"; cp "$src" "$o/SOURCES.txt"
	{
		echo "NAME=$(q "$b-$(conf "$bc" KERNEL)")"
		echo "OS=FreeBSD"
		echo "KERNEL=$(q "$(conf "$bc" KERNEL)")"
		echo "DISTRO=$(q "FreeBSD $(conf "$man" KERNEL_BUILD)")"
		echo "BOOT=disk"
		echo "CMDLINE=''"
		echo "RUN_DISK=whole"
	} >"$o/base.conf"
	ls -l "$o" ;;
repro)
	id=${1:?ID} img=${2:?qcow2} man=${3:?manifest} src=${4:?SOURCES.txt} pd=${5:-}
	rd=$T/reproducers/$id rc=$rd/reproducer.conf
	[ -f "$rc" ] || { echo "no $rc" >&2; exit 1; }
	b=$(conf "$rc" BASE)
	[ -f "$WORK/bases/$b/base.conf" ] || { echo "import base $b first" >&2; exit 1; }
	[ "$(conf "$man" KERNEL)" = "$(conf "$WORK/bases/$b/base.conf" KERNEL)" ] ||
	    { echo "the reproducer is for kernel $(conf "$man" KERNEL), base $b has $(conf "$WORK/bases/$b/base.conf" KERNEL)" >&2; exit 1; }
	for l in $(conf "$rc" BUILDS); do
		want=$(conf "$rc" "BUILD_$l"); want=${want##*@}
		have=$(conf "$man" "BUILD_$l" | cut -d' ' -f1)
		[ -n "$have" ] && [ "${want#"$have"}" != "$want" ] ||
		    { echo "build $l: the image has '$have', reproducer.conf wants $want" >&2; exit 1; }
	done
	o=$WORK/repros/$id; rm -rf "$o"; mkdir -p "$o"
	cp "$img" "$o/repro.qcow2"; cp "$src" "$o/SOURCES.txt"
	cp "$rd/demo.sh" "$o/"; [ -f "$rd/inspect.sh" ] && cp "$rd/inspect.sh" "$o/"
	[ -f "$rd/host.sh" ] && { echo "host.sh: FreeBSD bases have no host channel yet" >&2; exit 1; }
	[ -n "$pd" ] && { mkdir -p "$o/patches"; cp "$pd"/*.patch "$o/patches/"; }
	{
		grep -v -e '^#' -e '^$' "$rc"
		echo "ID=$(q "$id")"
		echo "BASE_NAME=$(q "$(conf "$WORK/bases/$b/base.conf" NAME)")"
		echo "KERNEL=$(q "$(conf "$man" KERNEL)")"
		for l in $(conf "$rc" BUILDS); do echo "BUILD_${l}_MARKER=$(q "$(conf "$man" "BUILD_$l")")"; done
		echo "DISK_BYTES=$(numfmt --from=iec "$(conf "$rc" DISK_SIZE)")"
	} >"$o/repro.conf"
	ls -l "$o" ;;
*) echo "unknown command $c" >&2; exit 2 ;;
esac
