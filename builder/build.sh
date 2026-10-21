#!/bin/bash
# builder/build.sh: build the userland, the targets (kernels), the OpenZFS
# builds, the demo and build disks and the container images.  Needs podman;
# everything that compiles runs in a builder container (builder/Containerfile.*).
#
# A reproducer ID is USER/SLUG (reproducers/USER/SLUG/reproducer.conf): the
# GitHub owner of the fix branch and the branch name, slugified.  It has two
# builds, LABEL repro (the break: master or the test-only commit) and fixed
# (the fix branch head), named by specs that each build resolves to a commit
# ("build specs" below), and is built for TARGETS (bases/TARGET/base.conf:
# the kernels openzfs/zfs CI runs; default: every x86_64 Linux target).
#
#   builder/build.sh all ID [TARGET...]       everything for ID, then check
#   builder/build.sh userland USERLAND        the shared root (work/userlands/U)
#   builder/build.sh kernel TARGET            a target's kernel (work/targets/T)
#   builder/build.sh userland-ext U-ext       an extended userland (work/userlands/U-ext)
#   builder/build.sh kernel-ext TARGET        a target's extended kernel layer:
#                                             its full module tree (work/targets/T-ext)
#   builder/build.sh base ID TARGET           the base of ID's images ('' or ext-HASH)
#   builder/build.sh resolve ID [LABEL]       resolve the build specs now (below)
#   builder/build.sh zfs-user USERLAND REPO@SHA [CONFIGURE...]   OpenZFS tools
#   builder/build.sh zfs-kmod TARGET REPO@SHA [CONFIGURE...]     OpenZFS modules
#   builder/build.sh zfs-for ID TARGET...     the OpenZFS halves ID needs
#   builder/build.sh demo ID                  the demo disk (work/demos/ID)
#   builder/build.sh disks ID TARGET...       the build disks
#   builder/build.sh images ID TARGET...      runtime, userland, kernel, demo, build layers
#   builder/build.sh check ID TARGET [LABEL...]   podman run IMAGE --check (+ --disk)
#   builder/build.sh push ID TARGET [LABEL...]    push the images (after check)
#   builder/build.sh tag ID LABEL TARGET      an image's tag
#   builder/build.sh targets ID | ids | labels ID
#   builder/build.sh verify ID                the resolved commits are public (GitHub)
#   builder/build.sh plan                     the CI matrix (JSON; PREV_RESULTS=FILE
#                                             leaves out jobs with unchanged inputs)
#   builder/build.sh inputs ID TARGET         the hash of a job's inputs
#   builder/build.sh key KIND ARGS...         cache keys (userland U, kernel T,
#                                             builder T|u-U, zfs-user ..., zfs-kmod ...)
#   builder/build.sh zdir user|kmod U|T REPO@SHA CONFIGURE...   a build's dir under work/
#   builder/build.sh builder-load T|u-U       load (or build and save) a builder image
#   builder/build.sh sizes [ID TARGET]        layer sizes of the images
#
# Environment: ZFS_REPRO_IMAGE (default ghcr.io/wrouesnel/openzfs-reproducers),
# ZFS_REPRO_WORK (default ./work), PODMAN (default podman), CHECK_ARGS (extra
# --check arguments, e.g. --runs 20), RESULTS_FILE, VERBOSE, REUSE_RESOLVED.
set -euo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${ZFS_REPRO_IMAGE:-ghcr.io/wrouesnel/openzfs-reproducers}
WORK=${ZFS_REPRO_WORK:-$T/work}
PODMAN=${PODMAN:-podman}
SRCURL=https://github.com/wrouesnel/openzfs-reproducers
mkdir -p "$WORK"

conf() { (set +u; . "$1"; eval "printf '%s' \"\${$2:-}\""); }
tconf() { [ -f "$T/bases/$1/base.conf" ] || { echo "no target $1 (bases/$1/base.conf)" >&2; exit 1; }; conf "$T/bases/$1/base.conf" "$2"; }
uconf() { [ -f "$T/userlands/$1/userland.conf" ] || { echo "no userland $1" >&2; exit 1; }; conf "$T/userlands/$1/userland.conf" "$2"; }
rconf() { [ -f "$T/reproducers/$1/reproducer.conf" ] || { echo "no reproducer $1" >&2; exit 1; }; conf "$T/reproducers/$1/reproducer.conf" "$2"; }
cfgtag() { printf '%s' "$*" | cksum | cut -d' ' -f1; }
hashof() { (cd "$T" && cat "$@" | sha256sum | cut -c1-16); }
tarch() { local a; a=$(tconf "$1" ARCH); echo "${a:-x86_64}"; }
plat() { case $1 in x86_64) echo linux/amd64 ;; aarch64) echo linux/arm64 ;; *) echo "linux/$1" ;; esac; }
# OCI tags: [A-Za-z0-9_][A-Za-z0-9_.-]{0,127}
tagsafe() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }
kver() { tagsafe "$(tconf "$1" KERNEL)"; }
idtag() { printf '%s' "${1//\//-}"; }	# USER/SLUG -> USER-SLUG

all_ids() {	# every reproducer, or only ONLY_IDS (space separated) when set;
	# not those with BLOCKED='reason' in reproducer.conf (docs/coverage.md)
	# unless WITH_BLOCKED=1
	(cd "$T/reproducers" && for d in */*/reproducer.conf; do
		[ -z "${WITH_BLOCKED:-}" ] && grep -q '^BLOCKED=' "$d" && continue
		echo "${d%/reproducer.conf}"
	done) |
	    if [ -n "${ONLY_IDS:-}" ]; then grep -xF -f <(printf '%s\n' $ONLY_IDS); else cat; fi
}
all_targets() { (cd "$T/bases" && for d in */base.conf; do echo "${d%/base.conf}"; done); }
linux_targets() { local t; for t in $(all_targets); do [ "$(tconf "$t" OS)" = Linux ] && [ "$(tarch "$t")" = x86_64 ] && echo "$t"; done; }
targets_of() {	# the targets a reproducer is built for
	local t ts skip; ts=$(rconf "$1" TARGETS); skip=" $(rconf "$1" SKIP_TARGETS) "
	[ -n "$ts" ] || ts=$(linux_targets)
	# LOCAL_TARGETS: built outside CI (FreeBSD: scripts/freebsd-image.sh)
	ts="$ts $(rconf "$1" LOCAL_TARGETS)"
	for t in $ts; do case $skip in *" $t "*) ;; *) echo "$t" ;; esac; done
}
labels() { local l; for l in repro fixed; do [ -n "$(rconf "$1" "BUILD_$l")" ] && echo "$l"; done; }
userland_of() { tconf "$1" USERLAND; }
# BASE='ext' in reproducer.conf: the extended userland (userlands/U-ext,
# PARENT=U) and the targets' extended kernel layers (full module trees)
# instead of the standard ones (docs/reproducer-format.md).  The OpenZFS
# builds are the same either way (built with the parent userland).
rbase() {
	local b; b=$(rconf "$1" BASE)
	case $b in '' | ext) echo "$b" ;; *) echo "$1: BASE='$b': only 'ext' (or nothing) is known" >&2; exit 1 ;; esac
}
xuserland_of() { echo "$(userland_of "$1")-ext"; }	# TARGET: its extended userland
root_userland() {	# ID TARGET: the userland ID's images boot on TARGET
	if [ "$(rbase "$1")" = ext ]; then xuserland_of "$2"; else userland_of "$2"; fi
}
ubuilder() { local p; p=$(uconf "$1" PARENT); echo "u-${p:-$1}"; }	# an ext userland uses its parent's builder

# ---- build specs ----------------------------------------------------------------
# BUILD_repro and BUILD_fixed are specs (docs/reproducer-format.md, "Build
# specs"), resolved to one commit each per build:
#   URL@SHA                 a pin: that commit (40 hex digits), not resolved
#   URL@REF                 the head of branch (or tag) REF on URL
#   URL@REF~N               N commits below it (first parent): REF~1 is the
#                           test commit of a "test, then fix" branch
#   URL@merge-base(REF)     the merge base of branch REF of the reproducer's
#                           REPO with URL's master: the openzfs/zfs commit a
#                           fix branch is based on
# They are resolved with git ls-remote and a blobless fetch into
# $WORK/git/zfs (refs/zr/OWNER/REF), and the resolved URL@SHA is what the
# cache keys, build.conf, the image labels, verify and plan use.  `all` and
# `resolve` resolve afresh (REUSE_RESOLVED=1: keep what an earlier `resolve`
# saved) and save the result in $WORK/resolved/USER-SLUG.conf; the other
# commands use that file while the specs in it still match, so the steps of
# one build agree on the commits even if a branch moves meanwhile.
ZG=$WORK/git/zfs
issha() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }
zgit() { git -C "$ZG" "$@"; }
zrref() {	# URL REF: where the cache keeps REF of URL
	local u=${1%/}; u=${u%.git}; u=${u#https://github.com/}; u=${u#*://}; u=${u%/zfs}
	echo "refs/zr/$(printf '%s' "$u" | tr -c 'A-Za-z0-9_.-' '_')/$2"
}
fetch_ref() {	# URL REF: the commit REF (a branch, else a tag) of URL now, fetched into the cache
	local url=$1 ref=$2 ls sha src r
	[ -d "$ZG" ] || { git init -q --bare "$ZG"; zgit config gc.auto 0; }
	ls=$(git ls-remote "$url" "refs/heads/$ref" "refs/tags/$ref" "refs/tags/$ref^{}") || { echo "git ls-remote $url failed" >&2; return 1; }
	sha=$(awk -v r="refs/heads/$ref" '$2 == r { print $1 }' <<<"$ls") src=refs/heads/$ref
	[ -n "$sha" ] || sha=$(awk -v r="refs/tags/$ref^{}" '$2 == r { print $1 }' <<<"$ls") src=refs/tags/$ref
	[ -n "$sha" ] || sha=$(awk -v r="refs/tags/$ref" '$2 == r { print $1 }' <<<"$ls")
	[ -n "$sha" ] || { echo "$url has no branch or tag '$ref'" >&2; return 1; }
	r=$(zrref "$url" "$ref")
	if ! zgit cat-file -e "$sha^{commit}" 2>/dev/null; then
		# blobless: the history (for ~N and merge bases), not the files
		(flock 9; zgit fetch -q --filter=blob:none "$url" "+$src:$r") 9>"$ZG.lock" ||
		    { echo "git fetch $url $ref failed" >&2; return 1; }
	fi
	zgit update-ref "$r" "$sha"
	echo "$sha"
}
resolve_spec() {	# SPEC REPO: SPEC resolved to URL@SHA
	local spec=$1 repo=$2 url rev ref n sha a b
	[[ $spec == *@* ]] || { echo "build spec '$spec': not URL@REV" >&2; return 1; }
	url=${spec%@*} rev=${spec##*@}
	if issha "$rev"; then echo "$spec"; return; fi
	if [[ $rev =~ ^merge-base\(([^\)]+)\)$ ]]; then
		ref=${BASH_REMATCH[1]}
		a=$(fetch_ref "$repo" "$ref") && b=$(fetch_ref "$url" master) || return 1
		sha=$(zgit merge-base "$a" "$b") || { echo "build spec '$spec': no merge base" >&2; return 1; }
	elif [[ $rev =~ ^([A-Za-z0-9._/+-]+)(~([0-9]*))?$ ]]; then
		ref=${BASH_REMATCH[1]} n=${BASH_REMATCH[3]}
		[ -n "${BASH_REMATCH[2]}" ] && [ -z "$n" ] && n=1
		a=$(fetch_ref "$url" "$ref") || return 1
		sha=$(zgit rev-parse --verify -q "$a~${n:-0}^{commit}") || { echo "build spec '$spec': $ref has fewer than $n commits below its head" >&2; return 1; }
	else
		echo "build spec '$spec': REV must be a full sha, REF, REF~N or merge-base(REF)" >&2; return 1
	fi
	echo "$url@$sha"
}
declare -A RESOLVED=()
resfile() { echo "$WORK/resolved/$(idtag "$1").conf"; }
resolve_id() {	# ID [fresh]: resolve ID's builds into RESOLVED[ID/LABEL] (once per run)
	local id=$1 f l s r ok=1; f=$(resfile "$id")
	[ -n "${RESOLVED[$id]:-}" ] && return 0
	if [ "${2:-}" != fresh ] || [ -n "${REUSE_RESOLVED:-}" ]; then
		# an earlier step's resolution, while the specs are the same
		if [ -f "$f" ]; then
			for l in repro fixed; do [ "$(conf "$f" "SPEC_$l")" = "$(rconf "$id" "BUILD_$l")" ] || ok=; done
		else ok=; fi
		if [ -n "$ok" ]; then
			for l in repro fixed; do RESOLVED[$id/$l]=$(conf "$f" "BUILD_$l"); done
			RESOLVED[$id]=1; return 0
		fi
	fi
	mkdir -p "$WORK/resolved"
	{
		echo "# $id: BUILD_* resolved by builder/build.sh at $(date -u +%FT%TZ)"
		for l in repro fixed; do
			s=$(rconf "$id" "BUILD_$l") r=
			if [ -n "$s" ]; then r=$(resolve_spec "$s" "$(rconf "$id" REPO)") || { echo "$id: cannot resolve BUILD_$l" >&2; return 1; }; fi
			RESOLVED[$id/$l]=$r
			echo "SPEC_$l=$(q "$s")"
			echo "BUILD_$l=$(q "$r")"
		done
	} >"$f.tmp" || return 1
	mv "$f.tmp" "$f"
	RESOLVED[$id]=1
}
build_of() {	# ID LABEL: the resolved REPO@SHA of that build
	resolve_id "$1" || exit 1
	echo "${RESOLVED[$1/$2]}"
}
cmd_resolve() {	# ID [LABEL]: resolve afresh; print "LABEL URL@SHA SPEC" (or URL@SHA of LABEL)
	local id=$1 l
	resolve_id "$id" fresh || exit 1
	if [ -n "${2:-}" ]; then echo "${RESOLVED[$id/$2]}"; return; fi
	for l in $(labels "$id"); do echo "$l ${RESOLVED[$id/$l]} $(rconf "$id" "BUILD_$l")"; done
}

# the image tag of LABEL (repro|fixed) of ID on TARGET:
#   LABEL-USER-SLUG-TARGET-KERNEL, at most 128 characters.  Longer: the slug
#   is cut and 8 hex digits of the full tag's sha256 appended; LABEL, USER,
#   TARGET and KERNEL stay whole.
tag_of() {
	local id=$1 l=$2 t=$3 u s tail h max full
	u=${id%%/*} s=${id#*/}
	tail="-$t-$(kver "$t")"
	full="$l-$u-$s$tail"
	if [ ${#full} -le 128 ]; then echo "$full"; return; fi
	h=$(printf '%s' "$full" | sha256sum | cut -c1-8)
	max=$((128 - ${#l} - 1 - ${#u} - 1 - 9 - ${#tail}))
	s=${s:0:$max}; s=${s%-}
	echo "$l-$u-$s-$h$tail"
}
img_of() { echo "$IMAGE:$(tag_of "$@")"; }
tag_runtime() { echo "$IMAGE:runtime-$(hashof runtime/Containerfile runtime/prune.sh runtime/zfs-repro-vm | cut -c1-12)"; }
tag_userland() { echo "$IMAGE:userland-$1-$(cat "$WORK/userlands/$1/hash")"; }
tag_kernel() { echo "$IMAGE:kernel-$1-$(kver "$1")"; }
tag_kernel_ext() { echo "$IMAGE:kernel-$1-$(kver "$1")-ext-$(cat "$WORK/targets/$1-ext/hash")"; }
base_of() {	# ID TARGET: '' (standard) or ext-HASH (the extended kernel layer's
	# key), the image label io.github.wrouesnel.zfs-repro.base
	[ "$(rbase "$1")" = ext ] || return 0
	echo "ext-$(cmd_key kernel-ext "$2" | sed 's/.*-//' | cut -c1-12)"
}
tag_demo() { echo "localhost/zfs-repro-demo:$(idtag "$1")-$2"; }

# ---- builders -----------------------------------------------------------------
builder_img() { echo "localhost/zfs-repro-builder:$1"; }
cmd_builder() {	# T (a target) or u-U (a userland)
	local b=$1 cf a
	case $b in
	u-*) local u=${b#u-}
	     cf=$T/builder/Containerfile.$(uconf "$u" FAMILY) a=$(uconf "$u" ARCH)
	     $PODMAN build -q --platform "$(plat "${a:-x86_64}")" -t "$(builder_img "$b")" \
	         --build-arg IMAGE="$(uconf "$u" IMAGE)" --build-arg SNAPSHOT="$(uconf "$u" SNAPSHOT)" \
	         -f "$cf" "$T/builder" >/dev/null ;;
	*)   [ "$(tconf "$b" OS)" = Linux ] || { echo "target $b: only Linux targets are built here (scripts/freebsd-image.sh)" >&2; exit 1; }
	     cf=$T/builder/Containerfile.$(tconf "$b" FAMILY)
	     $PODMAN build -q --platform "$(plat "$(tarch "$b")")" -t "$(builder_img "$b")" \
	         --build-arg IMAGE="$(tconf "$b" IMAGE)" --build-arg SNAPSHOT="$(tconf "$b" SNAPSHOT)" \
	         --build-arg KERNEL="$(tconf "$b" KERNEL)" --build-arg KERNEL_RPMS="$(tconf "$b" KERNEL_RPMS)" \
	         --build-arg APKVER="$(tconf "$b" APKVER)" -f "$cf" "$T/builder" >/dev/null ;;
	esac
	echo "builder image $(builder_img "$b")"
}
# CI keeps the builder images in its cache as work/cache/builder-B.tar.zst
cmd_builder_load() {
	local f=$WORK/cache/builder-$1.tar.zst
	$PODMAN image exists "$(builder_img "$1")" && return 0
	if [ -f "$f" ]; then zstd -qdc "$f" | $PODMAN load -q >/dev/null && echo "builder image loaded from $f"; return; fi
	cmd_builder "$1"
	if [ -n "${CI:-}" ]; then
		mkdir -p "$WORK/cache"
		$PODMAN save -q "$(builder_img "$1")" | zstd -q -T0 -3 >"$f.tmp" && mv "$f.tmp" "$f"
	fi
}
inb() {	# inb T|u-U CMD...: run CMD in that builder container
	local b=$1 a k= s d=; shift
	cmd_builder_load "$b" >/dev/null
	case $b in
	u-*) a=$(uconf "${b#u-}" ARCH) s=$(uconf "${b#u-}" SNAPSHOT) ;;
	*) a=$(tarch "$b") k=$(tconf "$b" KERNEL) s=$(tconf "$b" SNAPSHOT) d=$(tconf "$b" DISTRO) ;;
	esac
	# BUILD_TMPFS=SIZE: the builder's /tmp (the OpenZFS source and objects)
	# in memory instead of on the container storage's disk
	$PODMAN run --rm --platform "$(plat "${a:-x86_64}")" --network=host -v "$T:/src:ro" -v "$WORK:/work" \
	    ${BUILD_TMPFS:+--tmpfs "/tmp:rw,exec,size=$BUILD_TMPFS"} \
	    -e KERNEL="$k" -e SOURCE_DATE_EPOCH=0 -e MAKEJOBS="${MAKEJOBS:-}" -e EXTRA="${EXTRA:-}" \
	    -e ARCH="${a:-x86_64}" -e DISTRO="$d" -e SNAPSHOT="$s" \
	    "$(builder_img "$b")" "$@"
}

# ---- userland, targets, OpenZFS ---------------------------------------------
cmd_userland() {
	local u=$1 o=$WORK/userlands/$1
	[ -f "$o/base.qcow2" ] && { echo "userland $u: cached"; return; }
	rm -rf "$o.tmp"
	inb "u-$u" bash /src/builder/in/userland.sh "$u" "/work/userlands/$u.tmp"
	cmd_key userland "$u" | sed 's/^userland-//' | cut -c1-12 >"$o.tmp/hash"
	rm -rf "$o"; mv "$o.tmp" "$o"
}
cmd_kernel() {
	local t=$1 u o=$WORK/targets/$1; u=$(userland_of "$t")
	[ -f "$o/base.conf" ] && { echo "target $t: cached"; return; }
	[ -f "$WORK/userlands/$u/busybox" ] || cmd_userland "$u"
	rm -rf "$o.tmp"
	inb "$t" bash /src/builder/in/kernel.sh "$t" "/work/targets/$t.tmp" "/work/userlands/$u/busybox"
	{
		echo "USERLAND='$u'"
		# another architecture: the qemu and machine the runtime uses for it
		for k in QEMU MACHINE; do [ -n "$(tconf "$t" $k)" ] && echo "$k='$(tconf "$t" $k)'"; done
	} >>"$o.tmp/base.conf"
	rm -rf "$o"; mv "$o.tmp" "$o"
}
# the extended userland and kernel layers (BASE=ext); cached by their keys,
# built under a lock (another build may want the same layer)
cmd_userland_ext() {
	local x=$1 p o=$WORK/userlands/$1 h
	p=$(uconf "$x" PARENT); [ -n "$p" ] || { echo "userland $x has no PARENT" >&2; exit 1; }
	h=$(cmd_key userland "$x" | sed 's/^userland-//' | cut -c1-12)
	[ -f "$o/userland.qcow2" ] && [ "$(cat "$o/hash" 2>/dev/null)" = "$h" ] && { echo "userland $x: cached"; return; }
	[ -f "$WORK/userlands/$p/base.qcow2" ] || cmd_userland "$p"
	mkdir -p "$WORK/userlands"
	(
		flock 9
		[ -f "$o/userland.qcow2" ] && [ "$(cat "$o/hash" 2>/dev/null)" = "$h" ] && { echo "userland $x: cached"; exit 0; }
		rm -rf "$o.tmp"
		inb "$(ubuilder "$x")" bash /src/builder/in/userland-ext.sh "$x" "/work/userlands/$x.tmp" "/work/userlands/$p" || exit 1
		echo "$h" >"$o.tmp/hash"
		rm -rf "$o"; mv "$o.tmp" "$o"
	) 9>"$o.lock"
}
cmd_kernel_ext() {
	local t=$1 x o=$WORK/targets/$1-ext h; x=$(xuserland_of "$t")
	h=$(cmd_key kernel-ext "$t" | sed 's/.*-//' | cut -c1-12)
	[ -f "$o/base.qcow2" ] && [ "$(cat "$o/hash" 2>/dev/null)" = "$h" ] && { echo "target $t (ext): cached"; return; }
	cmd_userland_ext "$x"
	[ -f "$WORK/targets/$t/base.conf" ] || cmd_kernel "$t"
	mkdir -p "$WORK/targets"
	(
		flock 9
		[ -f "$o/base.qcow2" ] && [ "$(cat "$o/hash" 2>/dev/null)" = "$h" ] && { echo "target $t (ext): cached"; exit 0; }
		rm -rf "$o.tmp"
		inb "$t" bash /src/builder/in/kernel-ext-modules.sh "$t" "/work/targets/$t-ext.tmp" || exit 1
		inb "$(ubuilder "$x")" bash /src/builder/in/kernel-ext.sh "$t" "/work/targets/$t-ext.tmp" "/work/userlands/$x" "/work/targets/$t" || exit 1
		echo "$h" >"$o.tmp/hash"
		rm -rf "$o"; mv "$o.tmp" "$o"
	) 9>"$o.lock"
}
zdir() {	# zdir user|kmod U|T REPO@SHA CONFIGURE...: the work dir of one OpenZFS half
	local m=$1 b=$2 rs=$3; shift 3
	case $m in
	user) echo "$WORK/zfs/user-$b/${rs##*@}-$(cfgtag "$EXTRA" "$@")" ;;
	kmod) echo "$WORK/zfs/kmod-$b-$(kver "$b")/${rs##*@}-$(cfgtag "$@")" ;;
	esac
}
cmd_zfs() {	# user|kmod U|T REPO@SHA CONFIGURE...
	local m=$1 b=$2 rs=$3 d; shift 3
	d=$(zdir "$m" "$b" "$rs" "$@")
	[ -f "$d/pkg/build.txt" ] && { echo "cached: ${d#"$WORK"/}"; return; }
	case $m in
	user) inb "u-$b" bash /src/builder/in/zfs.sh user "${rs%@*}" "${rs##*@}" "/work/${d#"$WORK"/}" "$@" ;;
	kmod) inb "$b" bash /src/builder/in/zfs.sh kmod "${rs%@*}" "${rs##*@}" "/work/${d#"$WORK"/}" "$@" ;;
	esac
}
rextra() {	# TOOLS, with @zts expanded (builder/zts-tools.txt)
	local w
	for w in $(rconf "$1" TOOLS); do
		if [ "$w" = @zts ]; then grep -v '^#' "$T/builder/zts-tools.txt" | tr -s ' \n' ' '; else printf '%s ' "$w"; fi
	done | sed 's/ $//'
}
cmd_zfs_for() {	# ID TARGET...: both halves of each build
	local id=$1 l t u; shift
	EXTRA=$(rextra "$id")
	resolve_id "$id" || exit 1
	for t in "$@"; do
		u=$(userland_of "$t")
		for l in $(labels "$id"); do
			# shellcheck disable=SC2046
			cmd_zfs user "$u" "$(build_of "$id" "$l")" $(rconf "$id" CONFIGURE)
			# shellcheck disable=SC2046
			cmd_zfs kmod "$t" "$(build_of "$id" "$l")" $(rconf "$id" CONFIGURE)
		done
	done
}
cmd_demo() {
	local id=$1 u f; u=${2:-$(root_userland "$id" "$(targets_of "$id" | head -1)")}; f=$(resfile "$id")
	if [ -n "$(uconf "$u" PARENT)" ]; then cmd_userland_ext "$u"
	else [ -f "$WORK/userlands/$u/files" ] || cmd_userland "$u"; fi
	resolve_id "$id" || exit 1
	inb "$(ubuilder "$u")" bash /src/builder/in/demo-disk.sh "$id" "/src/reproducers/$id" "/work/userlands/$u" "/work/demos/$id" "/work/${f#"$WORK"/}"
}
cmd_disks() {	# ID TARGET...: each label's build disk for each target
	local id=$1 t l u du dk o d; shift
	EXTRA=$(rextra "$id")
	resolve_id "$id" || exit 1
	for t in "$@"; do
		u=$(userland_of "$t")
		for l in $(labels "$id"); do
			# shellcheck disable=SC2046
			du=$(zdir user "$u" "$(build_of "$id" "$l")" $(rconf "$id" CONFIGURE))
			# shellcheck disable=SC2046
			dk=$(zdir kmod "$t" "$(build_of "$id" "$l")" $(rconf "$id" CONFIGURE))
			for d in "$du" "$dk"; do [ -f "$d/pkg/build.txt" ] || { echo "no build ${d#"$WORK"/}: builder/build.sh zfs-for $id $t" >&2; return 1; }; done
			o=$WORK/builds/$id/$t/$l
			mkdir -p "$o"
			inb "u-$u" bash /src/builder/in/build-disk.sh "$l" "/work/${du#"$WORK"/}/pkg" "/work/${dk#"$WORK"/}/pkg" "/work/${o#"$WORK"/}" "/work/targets/$t"
			write_build "$id" "$l" "$t" "$du" "$dk" >"$o/build.conf"
			build_sources "$id" "$l" "$t" "$du" "$dk" >"$o/SOURCES.txt"
			rm -rf "$o/patches"; [ -f "$du/build.patch" ] && { mkdir -p "$o/patches"; cp "$du/build.patch" "$o/patches/$l.patch"; }
		done
	done
}
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
write_build() {	# ID LABEL TARGET USERDIR KMODDIR: the image's build.conf
	local id=$1 l=$2 t=$3 du=$4 dk=$5 k
	echo "# the OpenZFS build of this image (builder/build.sh)"
	echo "LABEL=$(q "$l")"
	echo "TARGET=$(q "$t")"
	echo "KERNEL=$(q "$(tconf "$t" KERNEL)")"
	echo "BUILD=$(q "$(build_of "$id" "$l")")"
	echo "SPEC=$(q "$(rconf "$id" "BUILD_$l")")"
	echo "MARKER=$(q "$(head -1 "$dk/pkg/build.txt")")"
	echo "ZFS=$(q "$(sed -n 2p "$dk/pkg/build.txt")")"
	for k in EXPECT EXPECT_INSPECT RUNS MIN_MATCH; do echo "$k=$(q "$(rconf "$id" "${k}_$l")")"; done
	echo "TAG=$(q "$(tag_of "$id" "$l" "$t")")"
}
build_sources() {
	local id=$1 l=$2 t=$3 du=$4 dk=$5
	echo "SOURCES for the OpenZFS build '$l' of $id on target $t ($(tconf "$t" KERNEL))"
	echo
	sed 's/^/  /' "$dk/source.txt"
	[ -f "$du/build.patch" ] && echo "  patch: patches/$l.patch (the commits on top of openzfs/zfs master)"
	echo
	echo "OpenZFS is licensed under the CDDL-1.0 (a few files are BSD or dual-licensed); its"
	echo "source for this build is the commit above.  The userland tools and the modules are"
	echo "built from it unmodified (configure $(rconf "$id" CONFIGURE))."
}

# ---- images -------------------------------------------------------------------
lbl() { largs+=(--label "$1"); }
cmd_images() {	# ID TARGET...
	local id=$1 t u l o ctx D a; shift
	resolve_id "$id" || exit 1
	ctx=$(mktemp -d "$WORK/ctx.XXXXXX")
	$PODMAN image exists "$(tag_runtime)" ||
	    $PODMAN build -q -t "$(tag_runtime)" -f "$T/runtime/Containerfile" "$T/runtime" >/dev/null
	echo "image $(tag_runtime)"
	local ext kfrom; ext=$(rbase "$id")
	for t in "$@"; do
		u=$(userland_of "$t") from= kfrom=
		if [ "$(tconf "$t" OS)" = FreeBSD ]; then
			# a FreeBSD target is one disk (kernel and userland) built on
			# FreeBSD (scripts/freebsd-image.sh): no userland layer
			from=$(tag_runtime)
		fi
		if [ -z "$from" ] && [ "$ext" = ext ]; then
		# BASE=ext: the extended userland, then the target's extended
		# kernel layer (an overlay of the userland's disk: kernel-ext.sh)
		u=$(xuserland_of "$t")
		cmd_kernel_ext "$t" >/dev/null	# (cached: built by `all`)
		rm -rf "$ctx/u"; mkdir -p "$ctx/u/base"
		cp -p "$WORK/userlands/$u/userland.qcow2" "$ctx/u/base/userland-$u.qcow2"; cp -p "$WORK/userlands/$u/SOURCES.txt" "$ctx/u/"
		chmod 644 "$ctx/u/base/userland-$u.qcow2"
		$PODMAN build -q --timestamp 0 -t "$(tag_userland "$u")" --build-arg FROM="$(tag_runtime)" \
		    --label org.opencontainers.image.source="$SRCURL" \
		    --label org.opencontainers.image.description="zfs-repro extended userland $u (no kernel, no reproducer)" \
		    -f "$T/builder/Containerfile.userland" "$ctx/u" >/dev/null
		echo "image $(tag_userland "$u")"
		rm -rf "$ctx/k"; mkdir -p "$ctx/k/base"
		for f in vmlinuz initrd base.conf base.qcow2; do [ -f "$WORK/targets/$t-ext/$f" ] && cp -p "$WORK/targets/$t-ext/$f" "$ctx/k/base/" && chmod 644 "$ctx/k/base/$f"; done
		cp -p "$WORK/targets/$t-ext/SOURCES.txt" "$ctx/k/"
		$PODMAN build -q --timestamp 0 -t "$(tag_kernel_ext "$t")" --build-arg FROM="$(tag_userland "$u")" \
		    --label org.opencontainers.image.source="$SRCURL" \
		    --label org.opencontainers.image.description="zfs-repro target $t, extended: $(tconf "$t" DISTRO) kernel $(tconf "$t" KERNEL) and its full module tree (no reproducer)" \
		    --label io.github.wrouesnel.zfs-repro.target="$t" --label io.github.wrouesnel.zfs-repro.kernel="$(tconf "$t" KERNEL)" \
		    -f "$T/builder/Containerfile.kernel" "$ctx/k" >/dev/null
		echo "image $(tag_kernel_ext "$t")"
		kfrom=$(tag_kernel_ext "$t")
		elif [ -z "$from" ]; then
		# userland: the root disk every target shares
		rm -rf "$ctx/u"; mkdir -p "$ctx/u/base"
		cp -p "$WORK/userlands/$u/base.qcow2" "$ctx/u/base/"; cp -p "$WORK/userlands/$u/SOURCES.txt" "$ctx/u/"
		chmod 644 "$ctx/u/base/base.qcow2"
		$PODMAN build -q --timestamp 0 -t "$(tag_userland "$u")" --build-arg FROM="$(tag_runtime)" \
		    --label org.opencontainers.image.source="$SRCURL" \
		    --label org.opencontainers.image.description="zfs-repro userland $u (no kernel, no reproducer)" \
		    -f "$T/builder/Containerfile.userland" "$ctx/u" >/dev/null
		echo "image $(tag_userland "$u")"
		from=$(tag_userland "$u")
		fi
		if [ -z "$kfrom" ]; then
		# kernel: the target
		rm -rf "$ctx/k"; mkdir -p "$ctx/k/base"
		for f in vmlinuz initrd base.conf base.qcow2; do [ -f "$WORK/targets/$t/$f" ] && cp -p "$WORK/targets/$t/$f" "$ctx/k/base/" && chmod 644 "$ctx/k/base/$f"; done
		cp -p "$WORK/targets/$t/SOURCES.txt" "$ctx/k/"
		$PODMAN build -q --timestamp 0 -t "$(tag_kernel "$t")" --build-arg FROM="$from" \
		    --label org.opencontainers.image.source="$SRCURL" \
		    --label org.opencontainers.image.description="zfs-repro target $t: $(tconf "$t" DISTRO) kernel $(tconf "$t" KERNEL) (no reproducer)" \
		    --label io.github.wrouesnel.zfs-repro.target="$t" --label io.github.wrouesnel.zfs-repro.kernel="$(tconf "$t" KERNEL)" \
		    -f "$T/builder/Containerfile.kernel" "$ctx/k" >/dev/null
		echo "image $(tag_kernel "$t")"
		kfrom=$(tag_kernel "$t")
		fi
		# demo: the same layer content for every target and build
		rm -rf "$ctx/d"; mkdir -p "$ctx/d/repro" "$ctx/d/sources"
		D=$WORK/demos/$id
		cp -p "$D/repro.conf" "$D/demo.sh" "$ctx/d/repro/"
		for f in demo.qcow2 inspect.sh host.sh; do [ -f "$D/$f" ] && cp -p "$D/$f" "$ctx/d/repro/"; done
		cp -p "$D/SOURCES.txt" "$ctx/d/sources/"
		$PODMAN build -q --timestamp 0 -t "$(tag_demo "$id" "$t")" --build-arg FROM="$kfrom" \
		    -f "$T/builder/Containerfile.demo" "$ctx/d" >/dev/null
		for l in $(labels "$id"); do
			o=$WORK/builds/$id/$t/$l
			[ -f "$o/build.qcow2" ] || { echo "no build disk $l for $id on $t: builder/build.sh disks $id $t" >&2; return 1; }
			rm -rf "$ctx/b"; mkdir -p "$ctx/b/build" "$ctx/b/sources"
			cp -p "$o/build.qcow2" "$o/build.conf" "$ctx/b/build/"
			cp -p "$o/SOURCES.txt" "$ctx/b/sources/"
			[ -d "$o/patches" ] && cp -pR "$o/patches" "$ctx/b/sources/"
			largs=()
			lbl "org.opencontainers.image.source=$SRCURL"
			lbl "org.opencontainers.image.title=zfs-repro $id ($l) on $t"
			lbl "org.opencontainers.image.description=$( [ "$l" = repro ] && echo 'unfixed' || echo 'fixed'): $(rconf "$id" TITLE)"
			lbl "org.opencontainers.image.licenses=CDDL-1.0 AND GPL-2.0-only AND GPL-2.0-or-later AND GPL-3.0-or-later"
			lbl "org.opencontainers.image.revision=$(git -C "$T" rev-parse HEAD 2>/dev/null || echo unknown)"
			lbl "io.github.wrouesnel.zfs-repro.id=$id"
			lbl "io.github.wrouesnel.zfs-repro.label=$l"
			lbl "io.github.wrouesnel.zfs-repro.target=$t"
			lbl "io.github.wrouesnel.zfs-repro.kernel=$(tconf "$t" KERNEL)"
			lbl "io.github.wrouesnel.zfs-repro.branch=$(rconf "$id" REPO)/tree/$(rconf "$id" BRANCH)"
			lbl "io.github.wrouesnel.zfs-repro.build=$(build_of "$id" "$l")"
			lbl "io.github.wrouesnel.zfs-repro.build-spec=$(rconf "$id" "BUILD_$l")"
			lbl "io.github.wrouesnel.zfs-repro.expect=$(rconf "$id" "EXPECT_$l")"
			[ -n "$(rconf "$id" AUTHOR)" ] && lbl "io.github.wrouesnel.zfs-repro.author=$(rconf "$id" AUTHOR)"
			[ -n "$(rconf "$id" PRS)" ] && lbl "io.github.wrouesnel.zfs-repro.prs=$(rconf "$id" PRS)"
			[ -n "$(rconf "$id" ISSUES)" ] && lbl "io.github.wrouesnel.zfs-repro.issues=$(rconf "$id" ISSUES)"
			[ "$ext" = ext ] && lbl "io.github.wrouesnel.zfs-repro.base=$(base_of "$id" "$t")"
			aargs=(); for a in "${largs[@]}"; do [ "$a" = --label ] && aargs+=(--annotation) || aargs+=("$a"); done
			$PODMAN build -q --timestamp 0 -t "$(img_of "$id" "$l" "$t")" --build-arg FROM="$(tag_demo "$id" "$t")" \
			    -f "$T/builder/Containerfile.build" "${largs[@]}" "${aargs[@]}" "$ctx/b" >/dev/null
			echo "image $(img_of "$id" "$l" "$t")"
		done
	done
	rm -rf "$ctx"
}
cmd_sizes() {	# the layers of each image: size and what made them
	local imgs i l
	if [ $# -ge 2 ]; then imgs=$(for l in $(labels "$1"); do img_of "$1" "$l" "$2"; done)
	else imgs=$($PODMAN images --format '{{.Repository}}:{{.Tag}}' | grep -F "$IMAGE:" | grep -E ':(repro|fixed)-' || true); fi
	for i in $imgs; do
		echo "== $i ($($PODMAN image inspect -f '{{.Size}}' "$i" | numfmt --to=si) total)"
		$PODMAN history --format '{{.Size}}	{{.CreatedBy}}' "$i" | cut -c1-110 | grep -v '^0B'
	done
}

# ---- checks -------------------------------------------------------------------
kvm_args() {
	if [ -c /dev/kvm ]; then
		echo --device /dev/kvm
		[ "$(id -u)" = 0 ] || echo --group-add keep-groups
	fi
}
cmd_check() {	# ID TARGET [LABEL...]: --check every image; RESULTS_FILE gets one line per image
	local id=$1 t=$2 l rc=0 out runs disk lrc res; shift 2
	local ls=("$@"); [ ${#ls[@]} -gt 0 ] || read -ra ls <<<"$(labels "$id" | tr '\n' ' ')"
	runs=$WORK/runs/$(idtag "$id")/$t; mkdir -p "$runs"
	for l in "${ls[@]}"; do
		echo "== $(tag_of "$id" "$l" "$t") --check ${CHECK_ARGS:-}"
		lrc=0
		# shellcheck disable=SC2046,SC2086
		out=$($PODMAN run --rm $(kvm_args) -v "$runs:/runs" "$(img_of "$id" "$l" "$t")" --check ${CHECK_ARGS:-} ${VERBOSE:+--verbose} 2>&1) || lrc=1
		echo "$out"
		res=$(echo "$out" | grep -a -E '^(RESULT |PANIC: |no RESULT line|SUMMARY )' | tail -1)
		if [ "$lrc" = 0 ] && [ -n "$(rconf "$id" "EXPECT_INSPECT_$l")" ]; then
			disk=$(echo "$out" | sed -n 's|^   \(/runs/.*\.raw\)$|\1|p' | head -1)
			if [ -n "$disk" ]; then
				echo "== $(tag_of "$id" "$l" "$t") --disk $disk --check"
				# shellcheck disable=SC2046
				$PODMAN run --rm $(kvm_args) -v "$runs:/runs" "$(img_of "$id" "$l" "$t")" --disk "$disk" --check ${VERBOSE:+--verbose} 2>&1 || lrc=1
			fi
		fi
		[ -n "${RESULTS_FILE:-}" ] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$t" "$l" "$([ $lrc = 0 ] && echo pass || echo fail)" "$(tag_of "$id" "$l" "$t")" "$res" "$(cmd_inputs "$id" "$t")" >>"$RESULTS_FILE"
		[ "$lrc" = 0 ] || rc=1
	done
	return $rc
}

cmd_push() {	# ID TARGET [LABEL...]
	local id=$1 t=$2 l; shift 2
	local ls=("$@"); [ ${#ls[@]} -gt 0 ] || read -ra ls <<<"$(labels "$id" | tr '\n' ' ')"
	for l in "${ls[@]}"; do $PODMAN push -q "$(img_of "$id" "$l" "$t")"; echo "pushed $(img_of "$id" "$l" "$t")"; done
}

cmd_plan() {	# JSON for the CI matrix, with every cache key and work dir
	local id t l u rs cfg
	{
		for id in $(all_ids); do
			EXTRA=$(rextra "$id") cfg=$(rconf "$id" CONFIGURE)
			resolve_id "$id" || exit 1
			for t in $(targets_of "$id"); do
				[ "$(tconf "$t" OS)" = Linux ] || continue
				u=$(userland_of "$t")
				printf 'J\t%s\t%s\t%s\t%s\t%s\t%s' "$id" "$t" "$u" "$(cmd_key builder "$t")" "$(cmd_key kernel "$t")" "$(cmd_key builder "u-$u")"
				for l in repro fixed; do
					rs=$(build_of "$id" "$l")
					if [ -n "$rs" ]; then
						# shellcheck disable=SC2086
						printf '\t%s\t%s\t%s\t%s' "$(cmd_key zfs-user "$u" "$rs" $cfg)" "$(zdir user "$u" "$rs" $cfg | sed "s|^$WORK/||")" \
						    "$(cmd_key zfs-kmod "$t" "$rs" $cfg)" "$(zdir kmod "$t" "$rs" $cfg | sed "s|^$WORK/||")"
						printf 'Z\t%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "$rs" "$cfg" "$EXTRA" "$(cmd_key zfs-user "$u" "$rs" $cfg)" "$(zdir user "$u" "$rs" $cfg | sed "s|^$WORK/||")" >>"$WORK/.plan-z"
					else printf '\t\t\t\t'; fi
				done
				printf '\t%s\t%s\n' "$(cmd_inputs "$id" "$t")" "$(base_of "$id" "$t")"
				printf 'T\t%s\t%s\t%s\t%s\n' "$t" "$u" "$(cmd_key builder "$t")" "$(cmd_key kernel "$t")"
				printf 'U\t%s\t%s\t%s\n' "$u" "$(cmd_key builder "u-$u")" "$(cmd_key userland "$u")"
			done
		done
		cat "$WORK/.plan-z" 2>/dev/null; rm -f "$WORK/.plan-z"
	} | sort -u | python3 -c '
import json, sys
jobs, targets, users, zfs = [], {}, {}, {}
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    if f[0] == "J":
        j = {"id": f[1], "target": f[2], "userland": f[3], "builder_key": f[4], "kernel_key": f[5], "ubuilder_key": f[6],
             "name": f[1].replace("/", "-") + "-" + f[2]}
        for i, l in enumerate(("repro", "fixed")):
            k = f[7 + 4 * i: 11 + 4 * i]
            j[l] = {"user_key": k[0], "user_dir": k[1], "kmod_key": k[2], "kmod_dir": k[3]} if k and k[0] else None
        j["inputs"] = f[15]
        j["base"] = f[16] if len(f) > 16 else ""   # "" or ext-HASH (BASE=ext)
        jobs.append(j)
    elif f[0] == "T": targets[f[1]] = {"target": f[1], "userland": f[2], "builder_key": f[3], "kernel_key": f[4]}
    elif f[0] == "U": users[f[1]] = {"userland": f[1], "builder_key": f[2], "userland_key": f[3]}
    else: zfs[f[5]] = {"userland": f[1], "build": f[2], "configure": f[3], "extra": f[4], "key": f[5], "dir": f[6], "name": f[2].split("@")[1][:12]}
# incremental (PREV_RESULTS: the results.tsv of earlier runs, FULL unset):
# leave out the jobs whose every image has a result for the same inputs
import os
prev, skipped, keep = os.environ.get("PREV_RESULTS"), [], None
if prev and not os.environ.get("FULL") and os.path.exists(prev):
    have = {}
    for line in open(prev):
        r = line.rstrip("\n").split("\t")
        if len(r) >= 7:
            have.setdefault((r[0], r[1], r[6]), set()).add(r[2])
    keep = []
    for j in jobs:
        ls = {l for l in ("repro", "fixed") if j[l]}
        (skipped if ls <= have.get((j["id"], j["target"], j["inputs"]), set()) else keep).append(j)
    jobs = keep
# at most MAX_JOBS reproducer x target jobs per run (the rest wait for the
# next run): ubuntu24 first, the target every reviewer pulls
deferred = []
mx = int(os.environ.get("MAX_JOBS") or 0)
if mx:
    jobs.sort(key=lambda j: (j["target"] != "ubuntu24", j["target"], j["id"]))
    jobs, deferred = (jobs[:mx], jobs[mx:]) if mx > 0 else ([], jobs)
if skipped or deferred:
    need = {j["target"] for j in jobs}
    targets = {k: v for k, v in targets.items() if k in need}
    keys = {j[l]["user_key"] for j in jobs for l in ("repro", "fixed") if j[l]}
    zfs = {k: v for k, v in zfs.items() if k in keys}
print(json.dumps({"jobs": jobs, "targets": list(targets.values()), "userlands": list(users.values()), "zfs": list(zfs.values()),
                  "skipped": [j["name"] for j in skipped], "deferred": [j["name"] for j in deferred]}))'
}
# inputs ID TARGET: a hash of everything a reproducer x target job's images
# and checks are made of (its reproducer directory, its builds and their
# configuration, the kernel, userland and runtime keys, and the scripts that
# pack the disks).  CI skips a job whose inputs are unchanged since its last
# result (docs/ci.md); builder/build.sh itself (orchestration) is left out.
cmd_inputs() {
	local id=$1 t=$2 u l; u=$(userland_of "$t")
	resolve_id "$id" || exit 1
	{
		(cd "$T/reproducers/$id" && find . -type f | LC_ALL=C sort | while read -r f; do echo "$f"; cat "$f"; done)
		echo "EXTRA=$(rextra "$id")"
		for l in repro fixed; do echo "$l=$(build_of "$id" "$l")"; done
		cmd_key kernel "$t"; [ "$(tconf "$t" OS)" = Linux ] && cmd_key userland "$u"
		# BASE=ext: the extended layers (its key covers the ext userland's)
		[ "$(rbase "$id")" = ext ] && [ "$(tconf "$t" OS)" = Linux ] && cmd_key kernel-ext "$t"
		hashof runtime/Containerfile runtime/prune.sh runtime/zfs-repro-vm
		hashof builder/in/demo-disk.sh builder/in/zts-pack.sh builder/in/zts-run.sh builder/in/zts-udevadm builder/in/zts-sudo builder/in/zvol_name.c builder/in/build-disk.sh \
		    builder/in/demo-common.sh builder/in/python-stdlib.sh builder/in/fio.sh builder/in/zfs.sh builder/in/guest/zr builder/zts-tools.txt \
		    builder/Containerfile.demo builder/Containerfile.build builder/Containerfile.userland builder/Containerfile.kernel
	} | sha256sum | cut -c1-16
}
cmd_key() {	# cache keys: what each output depends on
	local u t rs
	case $1 in
	userland) if [ -n "$(uconf "$2" PARENT)" ]; then	# an extended userland: its own inputs and its parent's
	             echo "userland-$( { hashof builder/in/userland-ext.sh builder/in/fio.sh builder/in/zvol_name.c "userlands/$2/userland.conf"; cmd_key userland "$(uconf "$2" PARENT)"; } | sha256sum | cut -c1-16)"
	             return
	          fi
	     echo "userland-$(hashof builder/in/userland.sh builder/in/demo-common.sh "builder/Containerfile.$(uconf "$2" FAMILY)" "userlands/$2/userland.conf")" ;;
	kernel-ext) echo "kernel-ext-$2-$(kver "$2")-$( { hashof builder/in/kernel-ext.sh builder/in/kernel-ext-modules.sh; cmd_key kernel "$2"; cmd_key userland "$(xuserland_of "$2")"; } | sha256sum | cut -c1-16)" ;;
	kernel) echo "kernel-$2-$(kver "$2")-$(hashof builder/in/kernel.sh builder/in/kernel-stage.sh "builder/Containerfile.$(tconf "$2" FAMILY)" "bases/$2/base.conf")" ;;
	builder) case $2 in
	         u-*) echo "builder-$2-$(hashof "builder/Containerfile.$(uconf "${2#u-}" FAMILY)" builder/in/kernel-stage.sh "userlands/${2#u-}/userland.conf")" ;;
	         *) echo "builder-$2-$(hashof builder/in/kernel-stage.sh "builder/Containerfile.$(tconf "$2" FAMILY)" "bases/$2/base.conf")" ;;
	         esac ;;
	zfs-user) u=$2 rs=$3; shift 3
	     echo "zfs-user-$u-${rs##*@}-$(cfgtag "$EXTRA" "$@")-$(hashof builder/in/zfs.sh "userlands/$u/userland.conf")" ;;
	zfs-kmod) t=$2 rs=$3; shift 3
	     echo "zfs-kmod-$t-$(kver "$t")-${rs##*@}-$(cfgtag "$@")-$(hashof builder/in/zfs.sh "bases/$t/base.conf")" ;;
	*) echo "unknown key kind $1" >&2; exit 2 ;;
	esac
}

# verify ID: each build's resolved commit is public: reachable from the
# branch its spec names (a pin: BRANCH; on openzfs/zfs: master) on GitHub,
# per the GitHub compare API
gh_get() {
	curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"
}
cmd_verify() {
	local id=$1 l rs spec rev repo sha ref st rc=0
	resolve_id "$id" fresh || exit 1
	for l in $(labels "$id"); do
		rs=$(build_of "$id" "$l") spec=$(rconf "$id" "BUILD_$l"); repo=${rs%@*} sha=${rs##*@} rev=${spec##*@}
		case $repo in https://github.com/*) ;; *) echo "$id $l: $repo is not on GitHub: not public" >&2; rc=1; continue ;; esac
		repo=${repo#https://github.com/}; repo=${repo%.git}
		issha "$sha" || { echo "$id $l: $sha is not a full sha" >&2; rc=1; continue; }
		if [ "${repo%%/*}" = openzfs ]; then ref=master
		elif issha "$rev" || [[ $rev == merge-base\(* ]]; then ref=$(rconf "$id" BRANCH)
		else ref=${rev%%~*}; fi
		st=$(gh_get "repos/$repo/compare/$sha...$ref" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)
		case $st in
		ahead | identical) echo "$id $l: $repo@${sha:0:12} ($spec) is on $ref" ;;
		*) echo "$id $l: $repo@${sha:0:12} ($spec) is NOT reachable from $repo $ref (${st:-not found})" >&2; rc=1 ;;
		esac
	done
	return $rc
}

c=${1:?usage: see the header of builder/build.sh}; shift
EXTRA=${EXTRA:-}
case $c in
builder) cmd_builder "$@" ;;
builder-load) cmd_builder_load "$@" ;;
userland | kernel | demo | disks | images | push | plan | key | sizes | verify | inputs | resolve) "cmd_$c" "$@" ;;
userland-ext) cmd_userland_ext "$@" ;;
kernel-ext) cmd_kernel_ext "$@" ;;
base) base_of "$@" ;;
zfs-user) cmd_zfs user "$@" ;;
zfs-kmod) cmd_zfs kmod "$@" ;;
zfs-for) cmd_zfs_for "$@" ;;
zdir) d=$(zdir "$@"); echo "${d#"$WORK"/}" ;;
check) cmd_check "$@" ;;
tag) tag_of "$@" ;;
targets) targets_of "$@" ;;
ids) all_ids ;;
labels) labels "$@" ;;
all)
	id=$1; shift
	ts=("$@"); [ ${#ts[@]} -gt 0 ] || read -ra ts <<<"$(targets_of "$id" | tr '\n' ' ')"
	resolve_id "$id" fresh || exit 1
	echo "builds of $id:"; for l in $(labels "$id"); do echo "  $l: ${RESOLVED[$id/$l]}  ($(rconf "$id" "BUILD_$l"))"; done
	for t in "${ts[@]}"; do
		cmd_userland "$(userland_of "$t")"; cmd_kernel "$t"
		if [ "$(rbase "$id")" = ext ] && [ "$(tconf "$t" OS)" = Linux ]; then cmd_kernel_ext "$t"; fi
	done
	cmd_zfs_for "$id" "${ts[@]}"
	cmd_demo "$id"
	cmd_disks "$id" "${ts[@]}"
	cmd_images "$id" "${ts[@]}"
	rc=0; for t in "${ts[@]}"; do cmd_check "$id" "$t" || rc=1; done; exit $rc ;;
*) echo "unknown command $c" >&2; exit 2 ;;
esac
