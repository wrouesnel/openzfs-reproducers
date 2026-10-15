#!/bin/bash
# builder/build.sh: build bases, OpenZFS builds, reproducer disks and the
# container images, locally or in CI (.github/workflows/build.yml runs the
# same steps).  Needs podman; everything that compiles runs in the builder
# container (builder/Containerfile.*), so the host needs nothing else.
#
#   builder/build.sh all ID...           everything for these reproducers, then check
#   builder/build.sh builder BASE        the builder image for a base
#   builder/build.sh base BASE           the base system (work/bases/BASE)
#   builder/build.sh zfs BASE REPO@SHA [CONFIGURE...]   one OpenZFS build
#   builder/build.sh zfs-for ID          the OpenZFS builds reproducer ID needs
#   builder/build.sh repro ID            the reproducer disk (needs the above)
#   builder/build.sh images ID...        runtime, base and reproducer images
#   builder/build.sh check ID [LABEL...] podman run IMAGE LABEL --check (+ --disk)
#   builder/build.sh push ID...          push the images (main branch CI only)
#   builder/build.sh plan                the CI matrix (JSON)
#   builder/build.sh key BASE|builder BASE|zfs BASE REPO@SHA CONFIGURE...   cache keys
#   builder/build.sh zdir BASE REPO@SHA CONFIGURE...   an OpenZFS build's dir (under work/)
#   builder/build.sh builder-load BASE   load (or build and save) the builder image
#
# Environment: ZFS_REPRO_IMAGE (default ghcr.io/wrouesnel/openzfs-reproducers),
# ZFS_REPRO_WORK (default ./work), PODMAN (default podman), CHECK_RUNS.
set -euo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${ZFS_REPRO_IMAGE:-ghcr.io/wrouesnel/openzfs-reproducers}
WORK=${ZFS_REPRO_WORK:-$T/work}
PODMAN=${PODMAN:-podman}
SRCURL=https://github.com/wrouesnel/openzfs-reproducers
mkdir -p "$WORK"

conf() { (set +u; . "$1"; eval "printf '%s' \"\${$2:-}\""); }
bconf() { [ -f "$T/bases/$1/base.conf" ] || { echo "no base $1" >&2; exit 1; }; conf "$T/bases/$1/base.conf" "$2"; }
rconf() { [ -f "$T/reproducers/$1/reproducer.conf" ] || { echo "no reproducer $1" >&2; exit 1; }; conf "$T/reproducers/$1/reproducer.conf" "$2"; }
# the published base name: config name + kernel (e.g. linux-ubuntu24-6.8.0-142-generic)
bname() { echo "$1-$(bconf "$1" KERNEL)"; }
cfgtag() { printf '%s' "$*" | cksum | cut -d' ' -f1; }
zdir() {	# zdir BASE REPO@SHA CONFIGURE...: the work dir of one OpenZFS build
	local b=$1 rs=$2; shift 2
	echo "$WORK/zfs/$(bconf "$b" KERNEL)/${rs##*@}-$(cfgtag "$@")"
}
hashof() { (cd "$T" && cat "$@" | sha256sum | cut -c1-16); }

builder_img() { echo "localhost/zfs-repro-builder:$1"; }
cmd_builder() {
	local b=$1
	case $(bconf "$b" OS) in Linux) ;; *) echo "base $b: only Linux bases are built here (see scripts/freebsd-image.sh)" >&2; exit 1 ;; esac
	$PODMAN build -q -t "$(builder_img "$b")" --build-arg IMAGE="$(bconf "$b" IMAGE)" \
	    --build-arg SNAPSHOT="$(bconf "$b" SNAPSHOT)" --build-arg KERNEL="$(bconf "$b" KERNEL)" \
	    -f "$T/builder/Containerfile.ubuntu" "$T/builder" >/dev/null
	echo "builder image $(builder_img "$b")"
}
# CI keeps the builder image in its cache as work/cache/builder-BASE.tar.zst
cmd_builder_load() {
	local f=$WORK/cache/builder-$1.tar.zst
	if [ -f "$f" ]; then zstd -qdc "$f" | $PODMAN load -q >/dev/null && echo "builder image loaded from $f"; return; fi
	cmd_builder "$1"
	mkdir -p "$WORK/cache"
	$PODMAN save -q "$(builder_img "$1")" | zstd -q -T0 -3 >"$f.tmp" && mv "$f.tmp" "$f"
}
inb() {	# inb BASE CMD...: run CMD in the base's builder container
	local b=$1; shift
	$PODMAN image exists "$(builder_img "$b")" || cmd_builder "$b"
	$PODMAN run --rm --network=host -v "$T:/src:ro" -v "$WORK:/work" \
	    -e KERNEL="$(bconf "$b" KERNEL)" -e SNAPSHOT="$(bconf "$b" SNAPSHOT)" -e SOURCE_DATE_EPOCH=0 -e MAKEJOBS="${MAKEJOBS:-}" \
	    "$(builder_img "$b")" "$@"
}
cmd_base() {
	local b=$1 n; n=$(bname "$1")
	[ -f "$WORK/bases/$b/base.qcow2" ] && { echo "base $n: cached"; return; }
	inb "$b" bash /src/builder/in/base-linux.sh "$n" "/work/bases/$b.tmp"
	rm -rf "$WORK/bases/$b"; mv "$WORK/bases/$b.tmp" "$WORK/bases/$b"
}
cmd_zfs() {
	local b=$1 rs=$2; shift 2
	local d; d=$(zdir "$b" "$rs" "$@")
	inb "$b" bash /src/builder/in/zfs.sh "${rs%@*}" "${rs##*@}" "/work/${d#"$WORK"/}" "$@"
}
labels() { rconf "$1" BUILDS; }
cmd_zfs_for() {
	local id=$1 l b; b=$(rconf "$id" BASE)
	for l in $(labels "$id"); do
		# shellcheck disable=SC2046
		cmd_zfs "$b" "$(rconf "$id" "BUILD_$l")" $(rconf "$id" CONFIGURE)
	done
}
cmd_repro() {
	local id=$1 b l args=(); b=$(rconf "$id" BASE)
	for l in $(labels "$id"); do
		# shellcheck disable=SC2046
		d=$(zdir "$b" "$(rconf "$id" "BUILD_$l")" $(rconf "$id" CONFIGURE))
		[ -f "$d/pkg/build.txt" ] || { echo "no build $l for $id ($d): builder/build.sh zfs-for $id" >&2; exit 1; }
		args+=("$l=/work/${d#"$WORK"/}")
	done
	[ -f "$WORK/bases/$b/base.qcow2" ] || { echo "no base $b: builder/build.sh base $b" >&2; exit 1; }
	inb "$b" bash /src/builder/in/repro.sh "$id" "/src/reproducers/$id" "/work/bases/$b" "/work/repros/$id" "${args[@]}"
}

# ---- images -------------------------------------------------------------------
tag_runtime() { echo "$IMAGE:runtime"; }
tag_base() { echo "$IMAGE:base-$(bname "$1")"; }
tag_repro() { echo "$IMAGE:$1"; }
cmd_images() {
	local id b ctx l lic
	ctx=$(mktemp -d "$WORK/ctx.XXXXXX")
	$PODMAN build -q -t "$(tag_runtime)" -f "$T/runtime/Containerfile" "$T/runtime" >/dev/null
	echo "image $(tag_runtime)"
	for b in $(for id in "$@"; do rconf "$id" BASE; echo; done | sort -u); do
		rm -rf "$ctx/b"; mkdir -p "$ctx/b/base"
		for f in base.qcow2 vmlinuz initrd base.conf; do
			[ -f "$WORK/bases/$b/$f" ] && cp -p "$WORK/bases/$b/$f" "$ctx/b/base/" && chmod 644 "$ctx/b/base/$f"
		done
		cp -p "$WORK/bases/$b/SOURCES.txt" "$ctx/b/"
		$PODMAN build -q --timestamp 0 -t "$(tag_base "$b")" --build-arg RUNTIME="$(tag_runtime)" \
		    --build-arg BASE_NAME="$(bname "$b")" -f "$T/builder/Containerfile.base" \
		    --label org.opencontainers.image.source="$SRCURL" \
		    --label org.opencontainers.image.description="zfs-repro base $(bname "$b") (no reproducer)" \
		    "$ctx/b" >/dev/null
		echo "image $(tag_base "$b")"
	done
	for id in "$@"; do
		b=$(rconf "$id" BASE) W=$WORK/repros/$id
		rm -rf "$ctx/r"; mkdir -p "$ctx/r/repro" "$ctx/r/sources"
		cp -p "$W/repro.qcow2" "$W/repro.conf" "$W/demo.sh" "$ctx/r/repro/"
		for f in inspect.sh host.sh; do [ -f "$W/$f" ] && cp -p "$W/$f" "$ctx/r/repro/"; done
		cp -p "$W/SOURCES.txt" "$ctx/r/sources/"
		[ -d "$W/patches" ] && cp -pR "$W/patches" "$ctx/r/sources/"
		lic="CDDL-1.0 AND GPL-2.0-only AND GPL-2.0-or-later AND GPL-3.0-or-later"
		largs=(--label "org.opencontainers.image.source=$SRCURL"
		    --label "org.opencontainers.image.title=zfs-repro $id"
		    --label "org.opencontainers.image.description=$(rconf "$id" TITLE)"
		    --label "org.opencontainers.image.licenses=$lic"
		    --label "org.opencontainers.image.revision=$(git -C "$T" rev-parse HEAD 2>/dev/null || echo unknown)"
		    --label "io.github.wrouesnel.zfs-repro.id=$id"
		    --label "io.github.wrouesnel.zfs-repro.base=$(bname "$b")"
		    --label "io.github.wrouesnel.zfs-repro.builds=$(labels "$id")")
		[ -n "$(rconf "$id" PRS)" ] && largs+=(--label "org.opencontainers.image.url=https://github.com/openzfs/zfs/pull/$(rconf "$id" PRS | cut -d' ' -f1)"
		    --label "io.github.wrouesnel.zfs-repro.prs=$(rconf "$id" PRS)")
		[ -n "$(rconf "$id" ISSUES)" ] && largs+=(--label "io.github.wrouesnel.zfs-repro.issues=$(rconf "$id" ISSUES)")
		for l in $(labels "$id"); do
			largs+=(--label "io.github.wrouesnel.zfs-repro.build.$l=$(rconf "$id" "BUILD_$l")"
			    --label "io.github.wrouesnel.zfs-repro.expect.$l=$(rconf "$id" "EXPECT_$l")")
		done
		# the same as manifest annotations (shown by registries and `skopeo inspect --raw`)
		aargs=(); for a in "${largs[@]}"; do [ "$a" = --label ] && aargs+=(--annotation) || aargs+=("$a"); done
		$PODMAN build -q --timestamp 0 -t "$(tag_repro "$id")" --build-arg BASE_IMAGE="$(tag_base "$b")" \
		    -f "$T/builder/Containerfile.repro" "${largs[@]}" "${aargs[@]}" "$ctx/r" >/dev/null
		echo "image $(tag_repro "$id")"
	done
	rm -rf "$ctx"
	$PODMAN images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep -F "$IMAGE:" || true
}

# ---- checks -------------------------------------------------------------------
kvm_args() {
	if [ -c /dev/kvm ]; then
		echo --device /dev/kvm
		# rootless podman: keep the kvm group (a 0660 /dev/kvm)
		[ "$(id -u)" = 0 ] || echo --group-add keep-groups
	fi
}
cmd_check() {
	local id=$1 l rc=0 out runs disk; shift
	local ls=("$@"); [ ${#ls[@]} -gt 0 ] || read -ra ls <<<"$(labels "$id")"
	runs=$WORK/runs/$id; mkdir -p "$runs"
	for l in "${ls[@]}"; do
		for i in $(seq "${CHECK_RUNS:-1}"); do
			echo "== $id $l --check (run $i)"
			# shellcheck disable=SC2046
			out=$($PODMAN run --rm $(kvm_args) -v "$runs:/runs" "$(tag_repro "$id")" "$l" --check ${VERBOSE:+--verbose} 2>&1) || rc=1
			echo "$out"
		done
		if [ -n "$(rconf "$id" "EXPECT_INSPECT_$l")" ]; then
			disk=$(echo "$out" | sed -n 's|^   \(/runs/.*\.raw\)$|\1|p' | head -1)
			echo "== $id $l --disk $disk --check"
			# shellcheck disable=SC2046
			$PODMAN run --rm $(kvm_args) -v "$runs:/runs" "$(tag_repro "$id")" "$l" --disk "$disk" --check ${VERBOSE:+--verbose} 2>&1 || rc=1
		fi
	done
	return $rc
}

cmd_push() {
	local id b
	$PODMAN push -q "$(tag_runtime)"
	for b in $(for id in "$@"; do rconf "$id" BASE; echo; done | sort -u); do $PODMAN push -q "$(tag_base "$b")"; done
	for id in "$@"; do $PODMAN push -q "$(tag_repro "$id")"; echo "pushed $(tag_repro "$id")"; done
}

all_ids() { (cd "$T/reproducers" && for d in */reproducer.conf; do echo "${d%/*}"; done); }
cmd_plan() {	# JSON for the CI matrix: bases, OpenZFS builds, reproducers
	local id l b
	{
		for id in $(all_ids); do
			b=$(rconf "$id" BASE)
			# FreeBSD bases and reproducers are built outside CI (scripts/freebsd-image.sh)
			[ "$(bconf "$b" OS)" = Linux ] || continue
			echo "B	$b"
			for l in $(labels "$id"); do printf 'Z\t%s\t%s\t%s\n' "$b" "$(rconf "$id" "BUILD_$l")" "$(rconf "$id" CONFIGURE)"; done
			echo "R	$id"
		done
	} | sort -u | python3 -c '
import json, sys
bases, zfs, repros = [], [], []
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    if f[0] == "B": bases.append(f[1])
    elif f[0] == "R": repros.append(f[1])
    else: zfs.append({"base": f[1], "build": f[2], "configure": f[3], "name": f[2].split("@")[1][:12]})
print(json.dumps({"bases": bases, "zfs": zfs, "repros": repros, "repros_str": " ".join(repros)}))'
}
cmd_key() {	# cache keys: what each output depends on
	case $1 in
	zfs) local b=$2 rs=$3; shift 3
	     echo "zfs-$(bconf "$b" KERNEL)-${rs##*@}-$(cfgtag "$@")-$(hashof builder/in/zfs.sh builder/Containerfile.ubuntu "bases/$b/base.conf")" ;;
	builder) echo "builder-$2-$(hashof builder/Containerfile.ubuntu "bases/$2/base.conf")" ;;
	*) echo "base-$(bname "$1")-$(hashof builder/in/base-linux.sh builder/in/demo-common.sh builder/Containerfile.ubuntu "bases/$1/base.conf")" ;;
	esac
}

c=${1:?usage: see the header of builder/build.sh}; shift
case $c in
builder | base) "cmd_$c" "$@" ;;
builder-load) cmd_builder_load "$@" ;;
zdir) d=$(zdir "$@"); echo "${d#"$WORK"/}" ;;
zfs) cmd_zfs "$@" ;;
zfs-for) cmd_zfs_for "$@" ;;
repro) cmd_repro "$@" ;;
images | push | plan | key) "cmd_$c" "$@" ;;
check) cmd_check "$@" ;;
all)
	for id in "$@"; do cmd_base "$(rconf "$id" BASE)"; cmd_zfs_for "$id"; cmd_repro "$id"; done
	cmd_images "$@"
	rc=0; for id in "$@"; do cmd_check "$id" || rc=1; done; exit $rc ;;
*) echo "unknown command $c" >&2; exit 2 ;;
esac
