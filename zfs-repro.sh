#!/bin/sh
# zfs-repro.sh: a small wrapper around the reproducer images.
#
#   curl -fsSL https://raw.githubusercontent.com/wrouesnel/openzfs-reproducers/main/zfs-repro.sh | sh -s -- --list
#   sh zfs-repro.sh ID [LABEL] [--console | --check | --info | --sources ...]
#
# --list asks ghcr.io (anonymously) which reproducers are published.  Anything
# else runs the image ghcr.io/wrouesnel/openzfs-reproducers:ID with podman (or
# docker): --device /dev/kvm when there is one, -it when there is a terminal,
# and ~/.cache/zfs-repro/runs/ID mounted on /runs so the run disks and logs
# stay for inspection (--disk /runs/FILE.raw).  It only saves typing:
#   podman run --rm -it --device /dev/kvm ghcr.io/wrouesnel/openzfs-reproducers:ID [LABEL]
# does the same without the volume.
# Environment: ZFS_REPRO_IMAGE (the repository), ZFS_REPRO_ENGINE (podman|docker).
IMAGE=${ZFS_REPRO_IMAGE:-ghcr.io/wrouesnel/openzfs-reproducers}
die() { printf 'zfs-repro: %s\n' "$*" >&2; exit 2; }

list() {
	command -v curl >/dev/null 2>&1 || die "--list needs curl"
	reg=${IMAGE%%/*} repo=${IMAGE#*/}
	tok=$(curl -fsS "https://$reg/token?scope=repository:$repo:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
	[ -n "$tok" ] || die "no anonymous access to $IMAGE (is the package public?)"
	tags=$(curl -fsS -H "Authorization: Bearer $tok" "https://$reg/v2/$repo/tags/list" |
	    tr ',' '\n' | sed -n 's/.*"\([^"]*\)".*/\1/p' | grep -v -e '^tags$' -e '^name$' -e "^$repo\$" -e '^runtime$' -e '^base-' -e '^sha256-')
	printf '%-22s %s\n' ID TITLE
	for t in $tags; do
		d=$(curl -fsS -H "Authorization: Bearer $tok" \
		    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
		    "https://$reg/v2/$repo/manifests/$t" | tr ',' '\n' |
		    sed -n 's/.*"org.opencontainers.image.description": *"\(.*\)"$/\1/p' | head -1)
		printf '%-22s %s\n' "$t" "$d"
	done
	echo "Run one with: sh zfs-repro.sh ID [LABEL]   (podman run --rm IMAGE:ID --info shows its builds)"
}

[ $# -gt 0 ] || { echo "usage: zfs-repro.sh --list | ID [LABEL] [options]  (ID --help for the options)"; exit 2; }
[ "$1" = --list ] && { list; exit 0; }
id=$1; shift
eng=${ZFS_REPRO_ENGINE:-}
[ -n "$eng" ] || for e in podman docker; do command -v $e >/dev/null 2>&1 && { eng=$e; break; }; done
[ -n "$eng" ] || die "needs podman or docker"
set -- --rm "$IMAGE:$id" "$@"
runs=${XDG_CACHE_HOME:-$HOME/.cache}/zfs-repro/runs/$id
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
exec "$eng" run "$@"
