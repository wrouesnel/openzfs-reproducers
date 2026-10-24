#!/bin/sh
# zfs-repro.sh: a small wrapper around the reproducer images.
#
#   curl -fsSL https://raw.githubusercontent.com/wrouesnel/openzfs-reproducers/main/zfs-repro.sh | sh -s -- --list
#   sh zfs-repro.sh --list [--user USER]      what is published, by reproducer
#   sh zfs-repro.sh TAG [options]             run that image
#   sh zfs-repro.sh USER/SLUG [repro|fixed] [TARGET] [options]
#                                             the same, by reproducer (default:
#                                             repro, on ubuntu24 or the first
#                                             published target)
#
# --list asks ghcr.io (anonymously) which images are published and GitHub
# which reproducers exist (reproducers/USER/SLUG in the repository).
# Anything else runs ghcr.io/wrouesnel/openzfs-reproducers:TAG with podman
# (or docker): --device /dev/kvm when there is one, -it when there is a
# terminal, and ~/.cache/zfs-repro/runs/TAG mounted on /runs so the run disks
# and logs stay for inspection (--disk /runs/FILE.raw).  It only saves typing:
#   podman run --rm -it --device /dev/kvm ghcr.io/wrouesnel/openzfs-reproducers:TAG
# does the same without the volume.  The options after the image are the
# image's own (TAG --help): --console, --check, --runs N, --until-fail,
# --parallel P, --keep, --disk, --info, --sources.
# Environment: ZFS_REPRO_IMAGE (the repository), ZFS_REPRO_ENGINE (podman|docker),
# ZFS_REPRO_SRC (the GitHub repository with reproducers/, default
# wrouesnel/openzfs-reproducers).
IMAGE=${ZFS_REPRO_IMAGE:-ghcr.io/wrouesnel/openzfs-reproducers}
SRC=${ZFS_REPRO_SRC:-wrouesnel/openzfs-reproducers}
die() { printf 'zfs-repro: %s\n' "$*" >&2; exit 2; }

registry_tags() {
	command -v curl >/dev/null 2>&1 || die "needs curl"
	reg=${IMAGE%%/*} repo=${IMAGE#*/}
	tok=$(curl -fsS "https://$reg/token?scope=repository:$repo:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
	[ -n "$tok" ] || die "no anonymous access to $IMAGE (is the package public?)"
	# at most 1000 tags per request: follow the pages (last=)
	last=
	while :; do
		page=$(curl -fsS -H "Authorization: Bearer $tok" "https://$reg/v2/$repo/tags/list?n=1000${last:+&last=$last}" |
		    tr ',' '\n' | sed -n 's/.*"\([^"]*\)".*/\1/p' | grep -v -x -e name -e tags -e "$repo")
		[ -n "$page" ] || break
		printf '%s\n' "$page"
		[ "$(printf '%s\n' "$page" | wc -l)" -ge 1000 ] || break
		last=$(printf '%s\n' "$page" | tail -n 1)
	done | grep -E '^(repro|fixed)-' || true
}
reproducer_ids() {	# USER/SLUG of every reproducer in the repository
	curl -fsS "https://api.github.com/repos/$SRC/git/trees/main?recursive=1" | tr ',' '\n' |
	    sed -n 's|.*"path": *"reproducers/\([^/"]*/[^/"]*\)/reproducer.conf".*|\1|p'
}
list() {
	user=$1
	tags=$(registry_tags)
	ids=$(reproducer_ids)
	[ -n "$ids" ] || die "cannot list the reproducers of github.com/$SRC"
	for id in $ids; do
		u=${id%%/*} s=${id#*/}
		[ -z "$user" ] || [ "$u" = "$user" ] || continue
		r=$(printf '%s\n' "$tags" | grep "^repro-$u-$s-" || true)
		printf '%s\n' "$id"
		if [ -z "$r" ]; then echo "    (nothing published: see docs/results.md)"; continue; fi
		for t in $r; do
			rest=${t#"repro-$u-$s-"}
			if printf '%s\n' "$tags" | grep -qx "fixed-$u-$s-$rest"; then w="repro- and fixed-"; else w="repro- only"; fi
			printf '    %-48s %s\n' "$rest" "$w"
		done
	done
	al=$(printf '%s\n' "$tags" | sed -n 's/^\(repro\|fixed\)-\(pr[0-9]*\|issue[0-9]*\)-.*/\2/p' | sort -u | tr '\n' ' ')
	echo
	[ -n "$al" ] && echo "PR and issue aliases (repro-prN-TARGET-KERNEL, fixed-issueN-...): $al"
	echo "Run one:  sh zfs-repro.sh USER/SLUG [repro|fixed] [TARGET]     or   sh zfs-repro.sh TAG"
	echo "          (podman run --rm $IMAGE:TAG --info shows what it is)"
}

if [ $# = 0 ]; then
	sed -n '3,10p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
	echo "usage: zfs-repro.sh --list [--user USER] | TAG [options] | USER/SLUG [repro|fixed] [TARGET] [options]"
	exit 2
fi
if [ "$1" = --list ]; then
	u=; [ "${2:-}" = --user ] && u=${3:?--user USER}
	list "$u"; exit 0
fi
tag=$1; shift
case $tag in
*/*)	# USER/SLUG [repro|fixed] [TARGET]
	u=${tag%%/*} s=${tag#*/} l=repro tgt=
	case ${1:-} in repro | fixed) l=$1; shift ;; esac
	case ${1:-} in '' | -*) ;; *) tgt=$1; shift ;; esac
	tags=$(registry_tags | grep "^$l-$u-$s-")
	[ -n "$tags" ] || die "nothing published for $tag ($l); sh zfs-repro.sh --list"
	if [ -n "$tgt" ]; then t=$(printf '%s\n' "$tags" | grep "^$l-$u-$s-$tgt-" | head -1)
	else t=$(printf '%s\n' "$tags" | grep "^$l-$u-$s-ubuntu24-" | head -1); [ -n "$t" ] || t=$(printf '%s\n' "$tags" | head -1); fi
	[ -n "$t" ] || die "$tag is not published for $tgt; published: $(printf '%s\n' "$tags" | sed "s/^$l-$u-$s-//" | tr '\n' ' ')"
	tag=$t ;;
esac
eng=${ZFS_REPRO_ENGINE:-}
[ -n "$eng" ] || for e in podman docker; do command -v $e >/dev/null 2>&1 && { eng=$e; break; }; done
[ -n "$eng" ] || die "needs podman or docker"
set -- --rm "$IMAGE:$tag" "$@"
runs=${XDG_CACHE_HOME:-$HOME/.cache}/zfs-repro/runs/$tag
mkdir -p "$runs" && set -- -v "$runs:/runs" "$@"
if [ -c /dev/kvm ]; then
	set -- --device /dev/kvm "$@"
	# rootless podman with a /dev/kvm that only its group may open (0660):
	# keep the caller's groups in the container
	if [ "$eng" = podman ] && [ "$(id -u)" != 0 ]; then
		case $(stat -c %a /dev/kvm 2>/dev/null) in *6) ;; *) set -- --group-add keep-groups "$@" ;; esac
	fi
fi
if [ -t 0 ] && [ -t 1 ]; then set -- -it "$@"
elif [ -e /dev/tty ] && (: </dev/tty) 2>/dev/null; then exec </dev/tty; set -- -it "$@"; fi	# curl | sh
echo "zfs-repro: $IMAGE:$tag" >&2
exec "$eng" run "$@"
