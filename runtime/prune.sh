#!/bin/sh
# runtime/prune.sh: drop what the runtime never uses from the qemu install:
# qemu's helper tools, firmware for other machines, its loadable modules,
# icons and GObject data, and every shared library that no remaining
# program links against.
set -eu
# firmware: SeaBIOS, the direct kernel boot ROMs and virtio-net's option ROM
# are all the pc machine needs here (-nodefaults, no display)
cd /usr/share/qemu
for f in *; do
	case $f in bios-256k.bin | kvmvapic.bin | linuxboot_dma.bin | linuxboot.bin | efi-virtio.rom | pxe-virtio.rom) ;;
	*) rm -rf "$f" ;; esac
done
rm -rf /usr/lib/qemu /usr/share/icons /usr/lib/girepository-1.0 /usr/lib/gio \
    /usr/share/applications /usr/share/doc /usr/share/man /usr/share/info \
    /usr/bin/qemu-nbd /usr/bin/qemu-io /usr/bin/qemu-storage-daemon /usr/bin/qemu-vmsr-helper \
    /usr/bin/qemu-pr-helper /usr/bin/qemu-edid /usr/bin/qemu-ga /usr/bin/elf2dmp \
    /usr/libexec/qemu-bridge-helper /usr/libexec/virtiofsd
need=$(for f in $(find /bin /sbin /usr/bin /usr/sbin /usr/libexec /lib/apk -type f 2>/dev/null); do
	[ "$(head -c4 "$f" | tail -c3)" = ELF ] || continue
	ldd "$f" 2>/dev/null | awk '/=>/ { print $3 } !/=>/ && /^\t\// { print $1 }'
done | sort -u | while read -r l; do readlink -f "$l"; done | sort -u)
n=0
for l in $(find /usr/lib /lib -maxdepth 1 -name '*.so*' -type f); do
	case $l in /lib/ld-musl*) continue ;; esac
	echo "$need" | grep -qx "$(readlink -f "$l")" || { rm -f "$l"; n=$((n + 1)); }
done
find /usr/lib /lib -maxdepth 1 -type l ! -exec test -e {} \; -delete
echo "prune: removed $n unused shared libraries; /usr $(du -sh /usr | cut -f1)"
