#!/bin/sh
# kernel-stage.sh KERNEL ROOT KSRC KOBJ   (in a builder Containerfile, as root)
# Keeps what a target needs from its kernel package(s), unpacked in ROOT:
#   /kernel/vmlinuz            the kernel (booted directly by qemu)
#   /kernel/lib/modules/K/     modules.builtin*, modules.order and only the
#                              modules in WANT (plus what they depend on),
#                              uncompressed; modules.dep regenerated
#   /kernel/env                KSRC= KOBJ= (the headers OpenZFS configures against)
# so the builder image stays small and the base step (kernel.sh) has the
# kernel without the distribution's 100+ MB of modules.
set -eu
K=$1 R=$2
WANT="virtio_pci virtio_blk ext4 virtio_net virtio_rng loop zlib_deflate zlib_inflate
    libcrc32c crc32c_generic crc32c_intel"
# merged /usr (Debian 13, Fedora): depmod -b wants ROOT/lib/modules
[ ! -e "$R/lib" ] && [ -d "$R/usr/lib/modules" ] && ln -s usr/lib "$R/lib"
M=$R/lib/modules/$K
[ -d "$M" ] || { echo "kernel-stage: no modules dir for $K in $R" >&2; exit 1; }
O=/kernel/lib/modules/$K
mkdir -p "$O"
for v in "$R/boot/vmlinuz-$K" "$M/vmlinuz" "$R/boot/vmlinuz-${K##*-}"; do
	[ -f "$v" ] && { cp "$v" /kernel/vmlinuz; break; }
done
[ -f /kernel/vmlinuz ] || { echo "kernel-stage: no vmlinuz for $K" >&2; ls -R "$R/boot" >&2 || true; exit 1; }
for f in modules.builtin modules.builtin.modinfo modules.order; do
	[ -f "$M/$f" ] && cp "$M/$f" "$O/"
done
# module name -> path in modules.dep (names: '-' and '_' are the same)
[ -f "$M/modules.dep" ] || depmod -b "$R" "$K"
norm() { echo "$1" | sed 's|.*/||; s|\.ko.*$||; s|-|_|g'; }
seen=" "
add() {
	local n p d
	n=$(norm "$1")
	case $seen in *" $n "*) return 0 ;; esac
	seen="$seen$n "
	grep -q "^$n\$" /tmp/builtin 2>/dev/null && return 0
	p=$(awk -F: -v n="$n" '{ b = $1; sub(/.*\//, "", b); sub(/\.ko(\.[a-z]+)?$/, "", b); gsub(/-/, "_", b)
		if (b == n) { print $1; exit } }' "$M/modules.dep")
	[ -n "$p" ] || { echo "kernel-stage: $n: not in $K (skipped)"; return 0; }
	for d in $(awk -F': *' -v p="$p" '$1 == p { print $2 }' "$M/modules.dep"); do add "$d"; done
	mkdir -p "$O/$(dirname "${p%.ko*}.ko")"
	case $p in
	*.xz) xz -dc "$M/$p" ;; *.zst) zstd -qdc "$M/$p" ;; *.gz) gzip -dc "$M/$p" ;; *) cat "$M/$p" ;;
	esac >"$O/${p%.ko*}.ko"
}
[ -f "$M/modules.builtin" ] && norm_all=$(sed 's|.*/||; s|\.ko.*$||; s|-|_|g' "$M/modules.builtin") || norm_all=
printf '%s\n' "$norm_all" >/tmp/builtin
for m in $WANT; do add "$m"; done
depmod -b /kernel "$K"
printf 'KSRC=%s\nKOBJ=%s\n' "$3" "$4" >/kernel/env
echo "kernel-stage: $K: $(find "$O" -name '*.ko' | wc -l) modules kept; builtin: $(for m in $WANT; do grep -qx "$m" /tmp/builtin && printf '%s ' "$m"; done)"
rm -f /tmp/builtin
