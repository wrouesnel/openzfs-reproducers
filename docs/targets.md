# Targets

A target is one kernel that openzfs/zfs CI's `zfs-qemu` workflow tests on.
`bases/TARGET/base.conf` names it after the CI platform and pins it. Every
reproducer is built for every x86_64 Linux target unless its
`reproducer.conf` says otherwise (`TARGETS`, `SKIP_TARGETS`), and FreeBSD
targets are added per reproducer (`LOCAL_TARGETS`).

## Where the kernel versions come from

openzfs/zfs CI boots each platform's cloud image
(`.github/workflows/scripts/qemu-2-start.sh` on upstream master) and then
updates it (`qemu-3-deps-vm.sh`: `dnf update`, `apt-get upgrade`, Alpine's
`linux-stable` instead of `linux-virt`), so the kernel is the distribution's
newest at the time of the run. The versions here are the `uname -r` of the
test VMs (`vm1`, `vm2`) in upstream run 38670952121 (2026-10-15, all 15
platforms):

| target | CI name | kernel (`uname -r`) | package source | builder image |
|---|---|---|---|---|
| ubuntu22 | ubuntu22 | 5.15.0-198-generic | snapshot.ubuntu.com 20261015T000000Z: `linux-image-`, `linux-modules-`, `linux-headers-` | ubuntu:22.04 (digest) |
| ubuntu24 | ubuntu24 | 6.8.0-142-generic | the same | ubuntu:24.04 (digest) |
| ubuntu26 | ubuntu26 | 7.0.0-34-generic | the same | ubuntu:26.04 (digest) |
| debian12 | debian12 | 6.1.0-53-amd64 | deb.debian.org / security.debian.org: `linux-image-` (signed), `linux-headers-` | debian:12 (digest) |
| debian13 | debian13 | 6.12.111+deb13-amd64 | the same | debian:13 (digest) |
| almalinux8 | almalinux8 | 4.18.0-553.173.1.el8_10.x86_64 | repo.almalinux.org BaseOS: `kernel-core`, `kernel-devel` (by URL) | almalinux:8 (digest) |
| almalinux9 | almalinux9 | 5.14.0-687.56.1.el9_8.x86_64 | BaseOS/AppStream: `kernel-core`, `kernel-modules-core`, `kernel-devel` | almalinux:9 (digest) |
| almalinux10 | almalinux10 | 6.12.0-211.65.1.el10_2.x86_64 | the same | almalinux:10 (digest) |
| fedora43 | fedora43 | 7.2.10-100.fc43.x86_64 | kojipkgs.fedoraproject.org: `kernel-core`, `kernel-modules-core`, `kernel-devel` | fedora:43 (digest) |
| fedora44 | fedora44 | 7.2.10-200.fc44.x86_64 | the same | fedora:44 (digest) |
| alpine3-24 | alpine3-24 | 7.1.5-0-stable | dl-cdn.alpinelinux.org v3.24: `linux-stable=7.1.5-r0`, `linux-stable-dev` | alpine:3.24 (digest) |
| freebsd14-4r | freebsd14-4r | 14.4-RELEASE (releng/14.4-n273675-a456f852d145) | FreeBSD CI image (download.freebsd.org CI-IMAGES) | built on FreeBSD |
| freebsd15-1r | freebsd15-1r | 15.1-RELEASE (releng/15.1-n283562-96841ea08dcf) | the same | built on FreeBSD |
| freebsd15-1s | freebsd15-1s | 15.1-STABLE (stable/15-n285872-a689dd9f2b17, 2026-10-08 snapshot) | FreeBSD CI snapshot | built on FreeBSD |
| freebsd16-0c | freebsd16-0c | 16.0-CURRENT (main-n289844-a52c50b4b7c2, 2026-10-05 snapshot) | the same | built on FreeBSD |

Not in the matrix: upstream's optional platforms (`centos-stream9/10`,
`debian11`, `freebsd14-5s`, `archlinux`, `tumbleweed`), which the default
`zfs-qemu` run doesn't use.

## How a target is built

- `builder/Containerfile.FAMILY` (ubuntu, debian, rhel, fedora = rhel, alpine)
  makes the target's builder from the distribution's container image (pinned
  by digest): the compiler and build tools, the kernel headers, and the
  kernel package unpacked. `builder/in/kernel-stage.sh` keeps only the
  vmlinuz and the modules the VM needs (virtio_pci, virtio_blk, ext4,
  virtio_net, virtio_rng, loop, the zlib and crc32c modules, and their
  dependencies), uncompressed, so the builder image stays small.
- `builder/in/kernel.sh` packs the target: the vmlinuz, and an initramfs
  (the userland's static busybox and those modules) when the boot path
  (virtio_pci, virtio_blk, ext4) isn't built in. Ubuntu's generic kernels have
  it built in and get no initramfs; the others do (about 1.5 MB, xz).
- Each OpenZFS commit's modules are built in the target's builder
  (`builder/in/zfs.sh kmod`, `--with-config=kernel` against the target's
  headers, with the distribution's compiler); the tools are built once per
  commit in the userland builder (`zfs.sh user`). A build fails if `zfs.ko`
  needs a kernel module the target doesn't load.
- The packages that aren't on a dated snapshot service (Debian, AlmaLinux,
  Alpine) are pinned by exact version; the distribution's toolchain is what
  its repositories have when the builder is made. Fedora's kernels come from
  koji, which keeps every build, so they stay fetchable. Debian keeps a kernel
  ABI (`6.1.0-53`) until the next one, AlmaLinux keeps the kernels of the
  current minor release, and Alpine keeps only the latest `linux-stable`: when
  one of them goes, CI's builder for that target fails until the target is
  moved on (the cached builder keeps working meanwhile).

## Moving a target to a newer kernel

1. Read the kernel from a recent upstream run: `gh run view -R openzfs/zfs
   --job JOB --log | grep -aE '^.*Linux vm1 '` (or FreeBSD's `FreeBSD vm1`).
2. Change `KERNEL` (and `KERNEL_RPMS`, `APKVER` or `SNAPSHOT`) in
   `bases/TARGET/base.conf`, and `IMAGE` if the distribution's image moved.
3. CI rebuilds that target's builder, kernel and modules (their cache keys
   include base.conf) and checks every reproducer on it. The new images get
   new tags (the kernel is in the tag); the old ones stay.

## Adding a target

Add `bases/NAME/base.conf` with `OS`, `ARCH`, `DISTRO`, `USERLAND`, `FAMILY`,
`IMAGE`, `KERNEL` and the family's pins. A new distribution family needs a
`builder/Containerfile.FAMILY` that installs a compiler, autotools, the
kernel headers and the kernel package, and ends with `kernel-stage.sh KERNEL
ROOT KSRC KOBJ`. Another architecture needs a userland for it
(`userlands/NAME/userland.conf` with `ARCH`) and, in the base.conf, `QEMU`
and `MACHINE` for the runtime (see the s390x target).
