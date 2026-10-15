#!/bin/bash
# userland.sh NAME OUTDIR   (in the userland builder container, as root)
# Packs the shared userland: a minimal merged-/usr root from the builder's
# own distribution (busybox, bash, a few GNU tools, util-linux dmesg,
# terminfo, the shared libraries the OpenZFS tools need).  No kernel and no
# ZFS: every Linux target (a kernel, kernel.sh) boots this same root, so the
# image layer that holds it is shared by every target.  Writes to OUTDIR:
#   base.qcow2     compressed qcow2 of the ext4 root (booted with root=/dev/vda;
#                  s390x: a GPT whose partition is the root, root=PARTUUID=...)
#   busybox        the static busybox, for the targets' initramfs (kernel.sh)
#   files          every path in the root (reproducer disks leave these out)
#   userland.conf  NAME DISTRO ZLIB ARCH ROOT SNAPSHOT
#   SOURCES.txt    the packages every file came from, with their sources
# busybox init runs /etc/rcS: API filesystems and tmpfs, then
# /etc/demo-common.sh finds the demo disk and the build disk by their
# serials, mounts them on /demo and /zfs, insmods the build's spl.ko and
# zfs.ko and links its tools; `dmesg -w` goes to ttyS1 and a root bash runs
# on ttyS0.  An s390x userland (built under qemu-user) uses the SCLP console
# ttysclp0 instead, and the virtio consoles hvc0 (kernel log) and hvc1 (the
# zr channel), which runtime/zfs-repro-vm attaches for s390x targets; its
# root is a GPT partition (kernel.sh boots it by PARTUUID).
set -euo pipefail
NAME=${1:?name} O=${2:?outdir}
IN=$(cd "$(dirname "$0")" && pwd)
ARCH=$(uname -m)
case $ARCH in
x86_64) CON=ttyS0 SER1=/dev/ttyS1 ZRDEV=/dev/ttyS2 LDTAG=x86-64 ;;
s390x) CON=ttysclp0 SER1=/dev/hvc0 ZRDEV=/dev/hvc1 LDTAG=64bit ;;
*) echo "userland.sh: no support for $ARCH" >&2; exit 1 ;;
esac
W=$(mktemp -d /tmp/base.XXXXXX) P=$W/root
mkdir -p "$O" "$P"
mkdir -p "$P"/{usr/bin,usr/sbin,usr/lib,usr/lib64,proc,sys,dev,tmp,var/tmp,run,root,etc/zfs,demo,zfs,mnt}
for d in bin sbin lib lib64; do ln -s usr/$d "$P/$d"; done
chmod 1777 "$P/tmp" "$P/var/tmp"; chmod 700 "$P/root"
: >"$W/owned"	# source paths copied into the root, for SOURCES.txt

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
BB=$(readlink -f "$(command -v busybox)")
isbb() { [ "$(readlink -f "$1")" = "$BB" ]; }
DM=$(command -v dmesg)
put() {	# put SRC DEST: copy a file into the root, remember where it came from
	cp -L "$1" "$P$2"; echo "$1" >>"$W/owned"
}
put "$BB" /usr/bin/busybox
put "$(command -v bash)" /usr/bin/bash
put "$DM" /usr/bin/dmesg
for c in dd od truncate cmp diff find xargs stat seq sort uniq head tail wc tr cut \
    date sleep touch ls cp mv rm mkdir cat tee env hexdump strings awk=mawk; do
	src=${c#*=}; c=${c%%=*}
	p=$(command -v "$src") || { echo "skipping $src (not here)" >&2; continue; }
	isbb "$p" && continue
	put "$p" "/usr/bin/$c"
done

# shared libraries: those of the tools above, plus the system libraries the
# OpenZFS tools (zpool, zfs, zdb) link against.  glibc dlopens libgcc_s for
# pthread_exit (zpool needs it); ldd never lists it.
zlibs="libblkid.so.1 libuuid.so.1 libudev.so.1 libz.so.1 libcrypto.so.3 libssl.so.3
    libtirpc.so.3 libm.so.6 libgcc_s.so.1"
{
	for f in "$P"/usr/bin/*; do
		[ "$(head -c4 "$f" | tail -c3)" = ELF ] || continue
		ldd "$f" 2>/dev/null | grep -o '/[^ ]*' || true
	done
	for l in $zlibs; do
		r=$(ldconfig -p | awk -v l="$l" -v t=",$LDTAG" '$1 == l && index($0, t) { print $NF; exit }')
		[ -n "$r" ] || { echo "no $l in the builder" >&2; exit 1; }
		echo "$r"; ldd "$r" 2>/dev/null | grep -o '/[^ ]*' || true
	done
} | sort -u | while read -r l; do
	r=$(readlink -f "$l")
	mkdir -p "$P/$(dirname "$r")"; [ -e "$P$r" ] || put "$r" "$r"
	[ "$r" = "$l" ] || { mkdir -p "$P$(dirname "$l")"; [ -e "$P$l" ] || ln -s "$r" "$P$l"; }
done
find "$P/usr/lib" "$P/usr/lib64" -type f -name '*.so*' -exec strip --strip-unneeded {} + 2>/dev/null || true
find "$P/usr/bin" -type f ! -name busybox -exec strip --strip-unneeded {} + 2>/dev/null || true
"$BB" --list-full | while read -r a; do
	case $a in linuxrc) continue ;; esac
	[ -e "$P/$a" ] || [ -L "$P/$a" ] || ln -s /usr/bin/busybox "$P/$a"
done
for t in l/linux v/vt100 v/vt220 x/xterm x/xterm-256color d/dumb s/screen s/screen-256color t/tmux t/tmux-256color; do
	for base in /usr/share/terminfo /lib/terminfo; do
		[ -e "$base/$t" ] || continue
		mkdir -p "$P/usr/share/terminfo/${t%/*}"; put "$base/$t" "/usr/share/terminfo/$t"; break
	done
done

# /etc
printf 'root:x:0:0:root:/root:/bin/bash\n' >"$P/etc/passwd"
printf 'root:x:0:\n' >"$P/etc/group"
ln -s /proc/self/mounts "$P/etc/mtab"
cp "$IN/demo-common.sh" "$P/etc/demo-common.sh"
cat >"$P/etc/inittab" <<EOF
::sysinit:/etc/rcS
$CON::respawn:/etc/shell
::ctrlaltdel:/sbin/poweroff
::shutdown:/bin/sync
EOF
cat >"$P/etc/rcS" <<'EOF'
#!/bin/sh
# zfs-repro demo base: API filesystems and tmpfs, load the reproducer's
# selected build (demo-common.sh), and send the full kernel log to ttyS1.
mount -t proc proc /proc
mount -t sysfs sys /sys
grep -q ' /dev ' /proc/mounts || mount -t devtmpfs dev /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs -o mode=1777 tmpfs /tmp
mount -t tmpfs -o mode=1777 tmpfs /var/tmp
mount -t tmpfs tmpfs /run
OSNAME="Linux" SER1=/dev/ttyS1 ZSBIN=/usr/sbin ZLIB=/usr/lib
[ -f /etc/demo-base.conf ] && . /etc/demo-base.conf
# kernel modules the ZFS modules need that this kernel doesn't have built in
for m in $(cat /etc/demo-modules 2>/dev/null); do
	insmod "/usr/lib/demo-modules/$m" || echo "*** insmod $m failed"
done
disk_list() { ls /sys/block | sed -n 's|^vd|/dev/vd|p'; }
serial_of() { cat "/sys/block/${1#/dev/}/serial" 2>/dev/null; }
mount_repro() { mount -t ext4 -o ro "$1" "$2"; }
# the launcher gives Linux run disks a GPT with one ZFS partition: without
# udev, zpool can't label a whole disk (libzfs waits for udev to initialise
# the new partition and fails with ENODEV after 30 s)
run_dev() { if [ -b "${1}1" ]; then echo "${1}1"; else echo "$1"; fi; }
load_zfs() {	# BUILDDIR
	insmod "$1/modules/spl.ko" && insmod "$1/modules/zfs.ko" || return 1
	LOADED="zfs $(cat /sys/module/zfs/version) srcversion $(cat /sys/module/zfs/srcversion)"
	grep -q "srcversion $(cat /sys/module/zfs/srcversion)" "$1/build.txt" ||
	    { LOADED="$LOADED (NOT this build's)"; return 1; }
}
. /etc/demo-common.sh
demo_setup
hostname "demo-$BUILD"
stty -F /dev/ttyS1 115200 onlcr 2>/dev/null
# full path: busybox ash prefers its own applets, and its dmesg has no -w
/usr/bin/dmesg -w >/dev/ttyS1 2>&1 &
EOF
# s390x: the kernel log goes to $SER1 (hvc0, from /etc/demo-base.conf)
[ "$SER1" = /dev/ttyS1 ] || sed -i 's|^\(stty -F \)/dev/ttyS1|\1$SER1|; s|^\(/usr/bin/dmesg -w >\)/dev/ttyS1|\1$SER1|' "$P/etc/rcS"
chmod 755 "$P/etc/rcS"
printf '#!/bin/sh\ncd /root\nexport HOME=/root\nexec /bin/bash -l\n' >"$P/etc/shell"
chmod 755 "$P/etc/shell"
cat >"$P/root/.bash_profile" <<'EOF'
export PATH=/usr/sbin:/usr/bin:/demo/bin TERM=${TERM:-vt100} HISTFILE=/root/.bash_history
[ "$TERM" = vt102 ] || [ "$TERM" = linux ] && export TERM=xterm-256color
PS1='\h:\w# '
set -a; . /etc/demo-env; set +a
cat /etc/motd
# export the pools first, so the run disks keep clean pools
poweroff() { zpool export -a; echo "pools exported; powering off"; command poweroff; }
EOF
ZLIB=/usr/lib
case $(readlink -f /lib64/ld-linux-x86-64.so.2 2>/dev/null) in */lib64/*) ZLIB=/usr/lib64 ;; esac
echo "ZLIB=$ZLIB" >"$P/etc/demo-base.conf"
# the second serial port and the zr channel, where they aren't ttyS1/ttyS2
[ "$SER1" = /dev/ttyS1 ] || printf 'SER1=%s\nZR_DEV=%s\n' "$SER1" "$ZRDEV" >>"$P/etc/demo-base.conf"

# ---- image ------------------------------------------------------------------
cp -L "$BB" "$O/busybox"
# a fixed time, owner and UUID: the same inputs give the same image
export E2FSPROGS_FAKE_TIME=${SOURCE_DATE_EPOCH:-0}
find "$P" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-0}" {} +
kb=$(du -sk --apparent-size "$P" | cut -f1)
echo "userland tree: ${kb} KiB"
truncate -s $(( (kb * 15 / 10 + 32768) * 1024 )) "$W/base.ext4"
mkfs.ext4 -q -F -L zfsdemo -m 0 -N 4096 -O ^has_journal -U clear -E root_owner=0:0,hash_seed=00000000-0000-0000-0000-000000000000 -d "$P" "$W/base.ext4"
ROOT=/dev/vda
if [ "$ARCH" = s390x ]; then
	# virtio-ccw disks are probed in parallel, so the root disk isn't always
	# vda: the root is a GPT partition with a fixed PARTUUID (kernel.sh)
	ROOT=PARTUUID=5a465352-6f6f-7400-0000-000000000001
	sz=$(stat -c %s "$W/base.ext4")
	truncate -s $((sz + 2 * 1048576)) "$W/base.disk"
	printf 'label: gpt\nlabel-id: 5a465352-6f6f-7400-0000-000000000000\nstart=2048, size=%d, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=%s\n' \
	    $((sz / 512)) "${ROOT#PARTUUID=}" | sfdisk -q "$W/base.disk" >/dev/null
	dd if="$W/base.ext4" of="$W/base.disk" bs=1M seek=1 conv=notrunc status=none
	mv "$W/base.disk" "$W/base.ext4"
fi
qemu-img convert -q -c -o compression_type=zlib -f raw -O qcow2 "$W/base.ext4" "$O/base.qcow2"
(cd "$P" && find . | sed 's/^\.//' | sort) >"$O/files"
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
{
	echo "NAME=$(q "$NAME")"
	echo "DISTRO=$(q "$(. /etc/os-release; echo "$PRETTY_NAME")")"
	echo "ZLIB=$(q "$ZLIB")"
	echo "ARCH=$(q "$ARCH")"
	echo "ROOT=$(q "$ROOT")"
	echo "SNAPSHOT=$(q "${SNAPSHOT:-}")"
} >"$O/userland.conf"

# ---- SOURCES.txt ------------------------------------------------------------
owner() {
	local c o
	for c in "$1" "$(readlink -f "$1")" "/usr${1#/usr}" "${1#/usr}"; do
		o=$(dpkg-query -S "$c" 2>/dev/null | grep -v '^diversion' | head -1 | cut -d: -f1) || true
		[ -n "$o" ] && { echo "$o"; return; }
	done
	echo -
}
sort -u "$W/owned" | while read -r f; do printf '%s\t%s\n' "$f" "$(owner "$f")"; done >"$W/owners"
{
	echo "SOURCES for the zfs-repro userland $NAME (the kernel: the target's SOURCES.txt)"
	echo
	echo "Distribution: $(. /etc/os-release; echo "$PRETTY_NAME")"
	echo "Packages:     the Ubuntu archive as of snapshot ${SNAPSHOT:-?}"
	echo "              (https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT:-})"
	echo
	echo "Packages that contributed files, with their source packages and where to get the source:"
	echo
	cut -f2 "$W/owners" | grep -v '^-$' | sort -u | while read -r p; do
		IFS=$'\t' read -r pv sp sv <<<"$(dpkg-query -W -f='${Version}\t${source:Package}\t${source:Version}' "$p")"
		echo "  $p $pv"
		echo "      source: $sp $sv"
		echo "      https://launchpad.net/ubuntu/+source/$sp/$sv"
	done
	echo
	echo "Files written by builder/in/userland.sh (no package): /etc/rcS, /etc/inittab,"
	echo "/etc/shell, /etc/passwd, /etc/group, /etc/demo-common.sh, /etc/demo-base.conf,"
	echo "/root/.bash_profile."
	echo
	echo "File by file (source path in the builder, package):"
	sed 's/^/  /' "$W/owners"
} >"$O/SOURCES.txt"
rm -rf "$W"
ls -l "$O"
