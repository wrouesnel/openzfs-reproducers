# Layer sizes

Measured 2026-10-15 with `builder/build.sh sizes` (podman, unpacked) and
`podman save | gzip -6` (compressed, about what a pull downloads).

## Before (one image per reproducer, both builds in it)

`pr19267` (ubuntu24), as published before this change:

| layer | unpacked | what |
|---|---|---|
| alpine base | 8.6 MB | |
| runtime (apk: qemu, tmux, ...) | 81.3 MB | all of qemu-system-x86_64's package and dependencies |
| base | 24.6 MB | root disk 9.6 MB + Ubuntu kernel 15.1 MB, one per base |
| reproducer | 12.3 MB | demo + both builds (modules and tools twice) |
| **total** | **~127 MB** | compressed ~45 MB |

## After (one image per build and target)

| layer | unpacked | compressed | shared by |
|---|---|---|---|
| alpine base | 8.6 MB | 3.6 MB | everything |
| runtime | 54 MB (was 81) | 18 MB (was 26) | everything: `runtime/prune.sh` drops qemu's helper tools, other machines' firmware, its modules, icons and GObject data, and the shared libraries only those needed |
| userland | 10.0 MB | 10.0 MB | every Linux target (one root disk, no kernel, no ZFS) |
| kernel: ubuntu22/24/26 | 15.1 MB (ubuntu24) | 15 MB | every image of that target; no initramfs (boot path built in) |
| kernel: debian13 | 12.2 + 1.5 MB initramfs | 13.7 MB | every image of that target |
| kernel: fedora44 | 19.0 + ~1.5 MB initramfs | 20.5 MB | " |
| kernel: almalinux9 | 15.2 + ~1.5 MB initramfs | 16.7 MB | " |
| demo | 0.35 MB | 0.35 MB | both images of a reproducer, on every target (the same bytes) |
| build | 6.4 MB | 6.4 MB | one image (zfs.ko 13 MB and the tools, debug info stripped, in a compressed qcow2) |
| **one image (ubuntu24)** | **~95 MB** | **~54 MB** | |
| **its pair** | +6.4 MB | +6.4 MB | |
| **another target** | +kernel +6.4 MB | | |

Disks are compressed qcow2 (zlib, 64 KiB clusters): small to download and
small on disk after the pull. Measured alternatives for the build disk (6.4
MB as qcow2/zlib): qcow2/zstd 6.2 MB; raw ext4 in a gzip layer 5.7 MB, in a
zstd-19 layer 4.4 MB, but unpacked 3-5 times larger on the user's disk; so
the disks stay qcow2. The kernels are the distributions' compressed vmlinuz
files, which don't compress further.

## The extended base (BASE='ext')

Measured 2026-10-21 (unpacked: the file tree in the guest; layer: the
compressed qcow2 the layer holds, about what a pull downloads, since qcow2
clusters are already zlib-compressed).

| layer | unpacked | layer | shared by |
|---|---|---|---|
| userland-ubuntu24-ext | 146 MB, 2105 files (the standard root is 10 MB of it) | 65 MB | every `BASE='ext'` image on every Linux target |
| kernel-ubuntu24-...-ext | 129 MB of modules (6472, zstd-compressed as Ubuntu ships them: `linux-modules` + `linux-modules-extra`) + vmlinuz 15 MB | 133 MB overlay + 15 MB vmlinuz | every `BASE='ext'` image on ubuntu24 |
| demo, build | as on the standard base (the demo disk is smaller: it doesn't carry what the ext userland has) | | |
| **one ext image (ubuntu24)** | | **~290 MB** (runtime 18 + 65 + 148 + build 6) | |

The extended userland's root file system has 3 GiB and 64k inodes of free
room (unused, so free in the qcow2) for a target's module tree; the kernel
layer's `base.qcow2` is a qcow2 overlay whose backing file is the ext
userland's disk (`userland-ubuntu24-ext.qcow2`, next to it in
`/zfs-repro/base`), holding only the clusters the module tree changed
(`builder/in/kernel-ext.sh`). So the tools cost one download for all ext
reproducers and targets, and each target's modules one download for all ext
reproducers on that target. The standard layers and their tags are
untouched. Booting takes about 5 s to the prompt instead of 2 (udev's
coldplug and settle).

## Further options (not done)

- A qemu built for this (`--target-list=x86_64-softmmu`, KVM + TCG, no
  graphics, TLS, audio or capstone) would replace about 40 MB of the runtime's
  libraries with a ~10 MB binary.
- `--disable-debug` builds are about a third smaller, but most demos need the
  ASSERTs (VERIFY/ASSERT panics are what they show).
