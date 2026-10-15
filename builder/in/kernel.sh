#!/bin/bash
# kernel.sh TARGET OUTDIR BUSYBOX   (in the target's builder container, as root)
# Packs a target: the kernel the builder staged in /kernel (kernel-stage.sh)
# and a small initramfs.  The target boots the shared userland's root disk,
# so this is all that differs between targets.  Writes to OUTDIR:
#   vmlinuz      the kernel, booted directly by qemu (no bootloader)
#   initrd       busybox /init: insmods the modules the kernel doesn't have
#                built in (virtio, ext4, virtio_net, the zlib modules ZFS may
#                need, ...) and switch_roots to /dev/vda; only if needed
#   modules      the module names available at boot (built in or loaded)
#   base.conf    what the launcher needs (NAME OS KERNEL BOOT CMDLINE ...)
#   SOURCES.txt  the kernel's packages and their sources
set -euo pipefail
NAME=${1:?target} O=${2:?outdir} BB=${3:?busybox}
K=${KERNEL:?KERNEL}
MD=/kernel/lib/modules/$K
W=$(mktemp -d /tmp/kernel.XXXXXX)
mkdir -p "$O"; rm -f "$O"/*
cp /kernel/vmlinuz "$O/vmlinuz"; chmod 644 "$O/vmlinuz"
norm() { sed 's|.*/||; s|\.ko.*$||; s|-|_|g'; }
# load order: modules.dep lists dependencies; depth-first, dependencies first
order() {
	local m=$1 p d
	case " $SEEN " in *" $m "*) return ;; esac
	SEEN="$SEEN $m"
	p=$(awk -F: -v n="$m" '{ b = $1; sub(/.*\//, "", b); sub(/\.ko$/, "", b); gsub(/-/, "_", b); if (b == n) { print $1; exit } }' "$MD/modules.dep")
	[ -n "$p" ] || return 0
	for d in $(awk -F': *' -v p="$p" '$1 == p { print $2 }' "$MD/modules.dep"); do order "$(echo "$d" | norm)"; done
	echo "$p"
}
SEEN=
mods=()
# the boot path first (virtio_blk, ext4), then the rest
for m in virtio_pci virtio_blk ext4 $(find "$MD" -name '*.ko' | norm | sort); do
	for p in $(order "$m"); do mods+=("$p"); done
done
# order() runs in a subshell per module: drop the repeats (the first
# occurrence keeps dependencies before their users)
mapfile -t mods < <(printf '%s\n' "${mods[@]}" | awk 'NF && !s[$0]++')
# the boot path and virtio_net (a private link between VMs) all built in
# (Ubuntu's generic kernel): no initramfs; the other optional modules
# (virtio_rng, loop, ...) aren't worth one
bi=1
for m in virtio_pci virtio_blk ext4 virtio_net; do norm <"$MD/modules.builtin" | grep -qx "$m" || bi=0; done
[ $bi = 1 ] && { echo "boot path built in, no initramfs (optional modules left out: ${mods[*]##*/})"; mods=(); }
{ [ -f "$MD/modules.builtin" ] && norm <"$MD/modules.builtin"; for p in "${mods[@]}"; do echo "$p" | norm; done; } | sort -u >"$O/modules"
for m in virtio_pci virtio_blk ext4; do grep -qx "$m" "$O/modules" || { echo "$K has no $m" >&2; exit 1; }; done
INITRD=0
if [ ${#mods[@]} -gt 0 ]; then
	INITRD=1
	echo "initramfs: ${mods[*]##*/}"
	I=$W/initrd; mkdir -p "$I"/{bin,dev,proc,sys,newroot,lib/modules}
	cp "$BB" "$I/bin/busybox"
	i=10
	for p in "${mods[@]}"; do
		n=${p##*/}; n=$i-$n; i=$((i + 1))
		cp "$MD/$p" "$I/lib/modules/$n"; echo "$n" >>"$I/modules"
	done
	cat >"$I/init" <<'EOI'
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc
/bin/busybox --install -s /bin
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
for m in $(cat /modules); do insmod "/lib/modules/$m" 2>/dev/null || echo "initramfs: insmod $m failed"; done
i=0; while [ ! -b /dev/vda ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
mount -t ext4 -o rw /dev/vda /newroot || { echo "initramfs: cannot mount /dev/vda"; exec sh; }
umount /proc /sys
mount --move /dev /newroot/dev
exec switch_root /newroot /sbin/init
EOI
	chmod 755 "$I/init"
	find "$I" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-0}" {} +
	(cd "$I" && find . | LC_ALL=C sort | cpio -o -H newc --quiet --reproducible 2>/dev/null || find . | LC_ALL=C sort | cpio -o -H newc --quiet) |
	    xz -9 --check=crc32 >"$O/initrd"
fi
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
{
	echo "NAME=$(q "$NAME")"
	echo "TARGET=$(q "$NAME")"
	echo "OS=Linux"
	echo "ARCH=$(q "${ARCH:-$(uname -m)}")"
	echo "KERNEL=$(q "$K")"
	echo "DISTRO=$(q "${DISTRO:-}")"
	echo "BOOT=kernel"
	# the userland's root (s390x: a GPT partition by PARTUUID) and console
	root=$(sed -n "s/^ROOT='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$(dirname "$BB")/userland.conf" 2>/dev/null)
	case ${ARCH:-$(uname -m)} in
	s390x) echo "CMDLINE='console=ttysclp0 rootwait loglevel=4 panic=0 root=${root:-/dev/vda} rw rootfstype=ext4 init=/sbin/init'" ;;
	*) echo "CMDLINE='console=ttyS0,115200 loglevel=4 panic=0 root=${root:-/dev/vda} rw rootfstype=ext4 init=/sbin/init'" ;;
	esac
	echo "RUN_DISK=gpt-zfs"
	echo "INITRD=$INITRD"
} >"$O/base.conf"
{
	echo "SOURCES for the zfs-repro target $NAME: ${DISTRO:-} kernel $K"
	echo
	echo "The kernel (vmlinuz) and the modules in the initramfs, unmodified, from:"
	while read -r p v s; do
		echo "  $p $v"
		echo "      source: $s"
	done </kernel/pkg.txt
	case $(cat /etc/os-release) in
	*ID=ubuntu*) echo "  https://launchpad.net/ubuntu/+source/linux" ;;
	*ID=debian*) echo "  https://packages.debian.org/source/$(. /etc/os-release; echo "$VERSION_CODENAME")/linux (snapshot.debian.org has every version)" ;;
	*ID=fedora*) echo "  https://koji.fedoraproject.org/koji/packageinfo?packageID=8 (kernel source RPMs)" ;;
	*almalinux*) echo "  https://vault.almalinux.org/ (kernel source RPMs: Sources/ or the vault)" ;;
	*ID=alpine*) echo "  https://gitlab.alpinelinux.org/alpine/aports (community/linux-stable) and kernel.org" ;;
	esac
	echo
	echo "Modules in the initramfs: ${mods[*]##*/}"
	echo "The initramfs /init (builder/in/kernel.sh) and busybox (the userland's, see its SOURCES.txt)."
	echo "The Linux kernel is licensed under the GPL-2.0."
} >"$O/SOURCES.txt"
rm -rf "$W"
ls -l "$O"
