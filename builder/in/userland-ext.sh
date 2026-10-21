#!/bin/bash
# userland-ext.sh NAME OUTDIR PARENTDIR   (in the parent userland's builder, root)
# Packs an extended userland (userlands/NAME/userland.conf, PARENT=...): the
# parent's root as built (PARENTDIR/base.qcow2, so the ext root is a
# superset of it, file for file), plus
#   - the files of EXT_PKGS (Ubuntu packages, at the parent's snapshot),
#     without documentation, headers or static libraries, and the shared
#     libraries they need that the root lacks.  ld.so and libc stay
#     unstripped and libc6-dbg is there, for valgrind;
#   - fio, built from its release source (builder/in/fio.sh);
#   - udev: /etc/rcS starts systemd-udevd before the build is loaded and
#     replays the kernel's events, so /dev/disk/*, /dev/zvol/* (our
#     60-zvol.rules, with zvol_name as zvol_id), udev's watch rule and
#     libzfs's whole-disk labelling work as on a distribution;
#   - /etc/modprobe.d/zfs-repro.conf: `modprobe zfs` / `modprobe -r zfs`
#     load and unload the image's build (/zfs/modules), never a zfs.ko of
#     the distribution's module tree (kernel-ext.sh leaves those out).
# The root file system has room (free blocks and inodes, sparse in the
# qcow2) for a target's full module tree: kernel-ext.sh writes one into a
# qcow2 overlay of this disk.  Writes to OUTDIR:
#   userland.qcow2  compressed qcow2 of the ext4 root
#   files           every path in the root
#   bins            the programs in /usr/bin and /usr/sbin that are real
#                   programs (not busybox applets): demo-disk.sh doesn't
#                   copy these onto the demo disk again
#   pkgs            the packages whose files are in the root (EXT_PKGS and
#                   the libraries' packages): demo-disk.sh skips them in
#                   EXTRA_PKGS
#   userland.conf   NAME PARENT DISTRO ZLIB SNAPSHOT
#   SOURCES.txt     the packages, with their sources
set -euo pipefail
NAME=${1:?name} O=${2:?outdir} PD=${3:?parentdir}
IN=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
conf() { (set +u; . "$1"; eval "printf '%s' \"\${$2:-}\""); }
UC=/src/userlands/$NAME/userland.conf
PKGS=$(conf "$UC" EXT_PKGS | tr -s ' \t\n' ' ')
W=$(mktemp -d /tmp/ext.XXXXXX) P=$W/root
mkdir -p "$O"; rm -f "$O"/*

# ---- the parent's root, as built --------------------------------------------
qemu-img convert -q -f qcow2 -O raw "$PD/base.qcow2" "$W/parent.raw"
mkdir -p "$P"
debugfs -R "rdump / $P" "$W/parent.raw" >/dev/null 2>&1
[ -x "$P/usr/bin/busybox" ] && [ -f "$P/etc/rcS" ] || { echo "could not unpack $PD/base.qcow2" >&2; exit 1; }
rm -rf "$P/lost+found"
rm -f "$W/parent.raw"

# ---- the packages ------------------------------------------------------------
# installed in this (throwaway) builder container first, so dpkg knows
# their files; the .debs are kept in /work/cache/apt-ext, and the snapshot
# service, which sometimes answers 50x, is retried
C=/work/cache/apt-ext; [ -d /work ] || C=$W/apt
mkdir -p "$C/partial"
rm -f /etc/apt/apt.conf.d/docker-clean
ok=
for i in 1 2 3 4 5 6 7 8; do
	if apt-get update -qq >/dev/null 2>&1 &&
	    apt-get install -y -qq --no-install-recommends -o Dir::Cache::archives="$C" $PKGS >"$W/apt.log" 2>&1; then
		ok=1; break
	fi
	echo "apt: retry $i ($(grep -m1 -oE '50[0-9] [A-Za-z ]+' "$W/apt.log" || tail -1 "$W/apt.log"))"; sleep $((i * 10))
done
[ -n "$ok" ] || { tail -20 "$W/apt.log" >&2; exit 1; }
# what goes in: regular files and symlinks, not documentation, headers,
# static or 32-bit libraries, other architectures' valgrind descriptions
skip() {
	case $1 in
	/usr/share/doc/* | /usr/share/man/* | /usr/share/info/* | /usr/share/locale/* | /usr/share/lintian/* | \
	    /usr/share/bug/* | /usr/share/bash-completion/* | /usr/share/zsh/* | /usr/share/fish/* | \
	    /usr/include/* | */pkgconfig/* | *.a | /usr/lib/i386-linux-gnu/* | /usr/lib32/* | \
	    /etc/init.d/* | /etc/cron* | /usr/lib/systemd/system/* | /lib/systemd/system/* | \
	    /usr/lib/python3*/test/* | /usr/lib/python3*/idlelib/* | /usr/lib/python3*/tkinter/* | \
	    /usr/lib/python3*/turtledemo/* | /usr/lib/python3*/ensurepip/* | /usr/lib/python3*/lib2to3/* | \
	    */__pycache__/*) return 0 ;;
	*/valgrind/*-x86-linux* | */valgrind/*.xml) case $1 in */amd64-* | */64bit-*) return 1 ;; esac; return 0 ;;
	esac
	return 1
}
: >"$W/list"
for p in $PKGS; do
	dpkg-query -W "$p" >/dev/null 2>&1 || { echo "package $p is not installed" >&2; exit 1; }
	dpkg -L "$p" | while read -r f; do
		[ -f "$f" ] || [ -L "$f" ] || continue
		[ -d "$f" ] && [ ! -L "$f" ] && continue
		skip "$f" && continue
		echo "$f"
	done >>"$W/list"
done
sort -u -o "$W/list" "$W/list"
# into the merged-/usr root (its /bin /sbin /lib /lib64 are symlinks into
# /usr): these replace busybox's applets of the same names
tar -C / -c --no-recursion -T "$W/list" 2>/dev/null | tar -C "$P" -x --keep-directory-symlink
# fio, from its release source (Ubuntu's package pulls in ceph and gluster)
bash "$IN/fio.sh" "$P/usr/bin" >/dev/null
# the shared libraries all of it needs that the root lacks
: >"$W/libs"
for pass in 1 2; do
	find "$P/usr" -path "$P/usr/lib/debug" -prune -o -type f -print | while read -r f; do
		cmp -s -n 4 "$f" <(printf '\177ELF') || continue
		case $f in */valgrind/*) continue ;; esac
		ldd "$f" 2>/dev/null | grep -o '/[^ ]*' || true
	done | sort -u | while read -r l; do
		case $l in "$P"/*) continue ;; esac
		r=$(readlink -f "$l")
		[ -e "$P$r" ] && { [ -e "$P$l" ] || [ -L "$P$l" ] || ln -s "$r" "$P$l"; continue; }
		mkdir -p "$P$(dirname "$r")"; cp -L "$r" "$P$r"; echo "$r" >>"$W/libs"
		[ "$r" = "$l" ] || { mkdir -p "$P$(dirname "$l")"; [ -e "$P$l" ] || ln -s "$r" "$P$l"; }
	done
done
# valgrind needs ld.so's symbols: the parent's root has it stripped, so it
# and libc come back as the distribution has them (libc6-dbg has their
# debug files, by build-id)
for l in ld-linux-x86-64.so.2 libc.so.6; do
	r=$(readlink -f "/usr/lib/x86_64-linux-gnu/$l"); cp -L "$r" "$P$r"
done

# ---- udev, modprobe, groups --------------------------------------------------
cc -O2 -s -w -o "$P/usr/lib/udev/zvol_id" "$IN/zvol_name.c"
mkdir -p "$P/etc/udev/rules.d" "$P/etc/modprobe.d"
cat >"$P/etc/udev/rules.d/60-zvol.rules" <<'EOF'
# zfs-repro (builder/in/userland-ext.sh): OpenZFS's 60-zvol.rules, with
# zvol_id from builder/in/zvol_name.c: /dev/zvol/POOL/VOL[-partN]
KERNEL=="zd*", SUBSYSTEM=="block", ACTION=="add|change", ENV{DEVTYPE}=="disk", PROGRAM=="/usr/lib/udev/zvol_id $devnode", SYMLINK+="zvol/%c"
KERNEL=="zd*", SUBSYSTEM=="block", ACTION=="add|change", ENV{DEVTYPE}=="partition", PROGRAM=="/usr/lib/udev/zvol_id $devnode", SYMLINK+="zvol/%c-part%n"
EOF
cat >"$P/etc/udev/rules.d/90-zfs.rules" <<'EOF'
# zfs-repro: OpenZFS's 90-zfs.rules (/dev/zfs for every user)
KERNEL=="zfs", MODE="0666"
EOF
cat >"$P/etc/modprobe.d/zfs-repro.conf" <<'EOF'
# zfs-repro (builder/in/userland-ext.sh): the image's OpenZFS build, never a
# zfs.ko of the distribution (the module tree has none)
install spl /sbin/insmod /zfs/modules/spl.ko $CMDLINE_OPTS
install zfs /sbin/modprobe spl && /sbin/insmod /zfs/modules/zfs.ko $CMDLINE_OPTS
remove zfs /sbin/rmmod zfs && /sbin/rmmod spl
remove spl /sbin/rmmod spl
EOF
# the groups udev's rules name
g=100; for n in tty disk kmem dialout cdrom floppy tape audio video input kvm render sgx lp users nogroup; do
	grep -q "^$n:" "$P/etc/group" || echo "$n:x:$g:" >>"$P/etc/group"; g=$((g + 1))
done
grep -q '^nobody:' "$P/etc/passwd" || echo 'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin' >>"$P/etc/passwd"
# rcS: udevd before the build is loaded (its coldplug replays the events),
# and udev's links settled once the module is in
awk '
/^\. \/etc\/demo-common\.sh$/ {
	print "# the extended userland: real udev (builder/in/userland-ext.sh)"
	print "if [ -x /usr/lib/systemd/systemd-udevd ]; then"
	print "\t/usr/lib/systemd/systemd-udevd --daemon --resolve-names=never >/dev/null 2>&1"
	print "\tudevadm trigger --type=subsystems --action=add >/dev/null 2>&1"
	print "\tudevadm trigger --type=devices --action=add >/dev/null 2>&1"
	print "\tudevadm settle -t 30 >/dev/null 2>&1"
	print "fi"
	print; next
}
/^demo_setup$/ { print; print "[ -S /run/udev/control ] && udevadm settle -t 30 >/dev/null 2>&1"; next }
{ print }' "$P/etc/rcS" >"$W/rcS"
grep -q systemd-udevd "$W/rcS" && grep -q 'udevadm settle -t 30 >/dev/null 2>&1$' "$W/rcS" || { echo "rcS: no hook point" >&2; exit 1; }
cat "$W/rcS" >"$P/etc/rcS"
# the module tree comes with the target (kernel-ext.sh)
mkdir -p "$P/usr/lib/modules"

# ---- lists -------------------------------------------------------------------
for d in usr/bin usr/sbin; do
	for f in "$P/$d"/*; do
		[ -e "$f" ] || [ -L "$f" ] || continue
		case $(readlink "$f") in */busybox | busybox) continue ;; esac
		echo "${f##*/}"
	done
done | sort -u >"$O/bins"
{
	printf '%s\n' $PKGS
	while read -r l; do dpkg-query -S "$l" 2>/dev/null | grep -v '^diversion' | head -1 | cut -d: -f1 || true; done <"$W/libs"
} | sort -u >"$O/pkgs"

# ---- image -------------------------------------------------------------------
export E2FSPROGS_FAKE_TIME=${SOURCE_DATE_EPOCH:-0}
find "$P" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-0}" {} +
kb=$(du -sk --apparent-size "$P" | cut -f1)
n=$(find "$P" | wc -l)
echo "ext userland tree: ${kb} KiB, $n files"
# room for a target's module tree: 3 GiB and 64k inodes more (unused
# blocks cost nothing in the qcow2)
truncate -s $(( (kb * 13 / 10 + 3 * 1024 * 1024) * 1024 )) "$W/root.ext4"
mkfs.ext4 -q -F -L zfsdemo -m 0 -N $((n + 65536)) -O ^has_journal -U clear \
    -E root_owner=0:0,hash_seed=00000000-0000-0000-0000-000000000000 -d "$P" "$W/root.ext4"
qemu-img convert -q -c -o compression_type=zlib -f raw -O qcow2 "$W/root.ext4" "$O/userland.qcow2"
(cd "$P" && find . | sed 's/^\.//' | sort) >"$O/files"
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
{
	echo "NAME=$(q "$NAME")"
	echo "PARENT=$(q "$(conf "$PD/userland.conf" NAME)")"
	echo "DISTRO=$(q "$(. /etc/os-release; echo "$PRETTY_NAME")")"
	echo "ZLIB=$(q "$(conf "$PD/userland.conf" ZLIB)")"
	echo "SNAPSHOT=$(q "${SNAPSHOT:-}")"
} >"$O/userland.conf"

# ---- SOURCES.txt -------------------------------------------------------------
{
	echo "SOURCES for the zfs-repro extended userland $NAME (the kernel and its modules: the target's SOURCES.txt)"
	echo
	echo "It is the userland $(conf "$PD/userland.conf" NAME) (its SOURCES.txt follows), plus the files of"
	echo "these packages and the libraries they need ($(. /etc/os-release; echo "$PRETTY_NAME"),"
	echo "the Ubuntu archive as of snapshot ${SNAPSHOT:-?}, https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT:-}):"
	echo
	while read -r p; do
		IFS=$'\t' read -r pv sp sv <<<"$(dpkg-query -W -f='${Version}\t${source:Package}\t${source:Version}' "$p")"
		echo "  $p $pv"
		echo "      source: $sp $sv"
		echo "      https://launchpad.net/ubuntu/+source/$sp/$sv"
	done <"$O/pkgs"
	echo
	echo "  fio: built from https://github.com/axboe/fio/archive/refs/tags/fio-3.36.tar.gz (GPL-2.0), builder/in/fio.sh"
	echo "  /usr/lib/udev/zvol_id: builder/in/zvol_name.c; /etc/udev/rules.d/60-zvol.rules, 90-zfs.rules,"
	echo "  /etc/modprobe.d/zfs-repro.conf and the udev lines in /etc/rcS: builder/in/userland-ext.sh"
	echo
	echo "================================================================================"
	cat "$PD/SOURCES.txt"
} >"$O/SOURCES.txt"
rm -rf "$W"
ls -l "$O"
