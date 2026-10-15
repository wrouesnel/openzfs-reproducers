# openzfs-reproducers

Container images that reproduce OpenZFS bugs in a tiny VM, for people
reviewing a fix. Each image has two (or more) builds of OpenZFS, usually
`bug` (unfixed) and `fix` (the proposed fix), plus a small Linux system that
boots in about two seconds. You get a root shell on the VM's serial console
and press **Up, Enter**; the demo then prints a `RESULT` line. Nothing is
built on your machine, nothing touches your own pools, and the VM has no
network.

```sh
podman run --rm -it --device /dev/kvm ghcr.io/wrouesnel/openzfs-reproducers:pr19267 bug
podman run --rm -it --device /dev/kvm ghcr.io/wrouesnel/openzfs-reproducers:pr19267 fix
```

(`docker run` takes the same arguments.)

## Reproducers

| image tag | upstream | what goes wrong | builds |
|---|---|---|---|
| `pr19267` | [openzfs/zfs#19267](https://github.com/openzfs/zfs/pull/19267) (issue [#19220](https://github.com/openzfs/zfs/issues/19220)) | Linux: data stored through mmap past EOF becomes file data when the file is extended | `bug` -> `RESULT BUG`, `fix` -> `RESULT OK` |
| `selftest-triggers` | none (not a bug) | self-test of the host trigger channel (two VMs, power cut, hot-unplug, I/O errors, ...) | `ok` -> `RESULT OK` |

Only bugs that are already public upstream (an open or merged openzfs/zfs PR
or issue) are published here. `sh zfs-repro.sh --list` (below) asks the
registry what is published right now.

## Quick start

```sh
# list what is published
curl -fsSL https://raw.githubusercontent.com/wrouesnel/openzfs-reproducers/main/zfs-repro.sh | sh -s -- --list

# what a reproducer is, its builds and the RESULT each one should print
podman run --rm ghcr.io/wrouesnel/openzfs-reproducers:pr19267 --info

# boot the unfixed build; at the root prompt press Up, Enter
podman run --rm -it --device /dev/kvm ghcr.io/wrouesnel/openzfs-reproducers:pr19267 bug
```

At the VM's root prompt:

- **Up, Enter** runs the demo with a `bash -x` trace. The trace and the kernel
  log go to the second serial port, which is logged in `/runs` in the
  container.
- **Up Up, Enter** runs the demo without the trace. `less /demo/demo.sh`
  shows the script.
- `poweroff` exports the demo's pool and ends the VM. **Ctrl-]** leaves at
  once.

Other modes (the arguments after the image):

| | |
|---|---|
| `LABEL --console` | tmux: the root shell, the kernel log + trace, and the script, side by side |
| `LABEL --check` | no terminal needed: boots, runs the demo, waits for RESULT, powers off, and exits 0 if the RESULT is the expected one (1 if not). `--verbose` prints the consoles |
| `LABEL --disk /runs/FILE.raw` | boots that build with the run disk of an earlier run, to inspect the pool it left (`inspect.sh`: `RESULT ... on disk`) |
| `--info`, `--sources` | the reproducer's metadata, and the SOURCES of everything in the image |
| `LABEL --dry-run` | prints the qemu command line(s) |

### Keeping the run disks

Each run makes new sparse run disks for the demo's pool. The demo exports the
pool at the end, so a disk holds a clean, importable pool. By default the
disks live in the container's writable layer and go away with `--rm`. To keep
them, mount a directory on `/runs`:

```sh
mkdir -p runs
podman run --rm -it --device /dev/kvm -v ./runs:/runs ghcr.io/wrouesnel/openzfs-reproducers:pr19267 bug
podman run --rm -it --device /dev/kvm -v ./runs:/runs ghcr.io/wrouesnel/openzfs-reproducers:pr19267 bug --disk /runs/bug-<time>.raw
```

On SELinux hosts add `:Z` to the volume, for example `-v ./runs:/runs:Z`.
`zfs-repro.sh ID ...` does this for you with `~/.cache/zfs-repro/runs/ID`.

## Requirements

- Linux on x86_64 with **podman** (rootless is fine) or **docker**.
- **/dev/kvm** that your user can open (you are in the `kvm` group, or the
  device has an ACL for you). Pass it with `--device /dev/kvm`. With rootless
  podman and a group-only `/dev/kvm` (mode 0660), add `--group-add keep-groups`.
  Without KVM the image falls back to software emulation (TCG), with a
  warning, about 10-50 times slower.
- The images are about 130 MB, and every reproducer shares the runtime and
  base layers.

The container needs no `--privileged` and no network for the VM. The VM's
only devices are its disks, a random number generator and serial ports. Some
reproducers also get a private link to a second VM; neither VM can reach
anything outside the container.

## What is in an image

The image is built in three layers, so reproducers share the large parts:

1. **runtime** (`:runtime`): Alpine with `qemu-system-x86_64`, `qemu-img`,
   tmux and the entrypoint `zfs-repro-vm` (an orchestrator in bash).
2. **base** (`:base-linux-ubuntu24-6.8.0-142-generic`): a compressed qcow2 of
   a minimal Ubuntu 24.04 userland (busybox, bash, a few GNU tools), and the
   Ubuntu kernel 6.8.0-142-generic, which openzfs CI also uses (`ubuntu24`).
   There is no ZFS in it.
3. **reproducer** (`:<id>`): one ext4 disk with each OpenZFS build (`zfs.ko`,
   `spl.ko`, `zpool`, `zfs`, `zdb`, its libraries), the demo, and
   `/sources` (SOURCES.txt and the patches).

At boot, the base finds the reproducer disk by its virtio serial, loads the
selected build's modules (it checks their srcversion), links its tools, and
starts a root shell. Each run boots from a throwaway overlay of the base, so
the image is never written.

### Reproducers that act from outside the VM

The container is the VMs' host, so a reproducer can do what a script inside
one VM can't. It can cut the power and boot again, pause the VM, hot-unplug a
disk, inject I/O errors, throttle a disk, rewrite a disk image between boots,
or run two VMs on shared disks or a private link (for example multihost
imports). The demo asks the host for these with `zr trigger NAME` on a
dedicated serial port. See [docs/reproducer-format.md](docs/reproducer-format.md),
and `selftest-triggers`, which CI runs on every change.

## Verification

- Every published image comes from `.github/workflows/build.yml` in this
  repository. It builds the base, every OpenZFS build (from the commits pinned
  in `reproducers/<id>/reproducer.conf`) and the images on GitHub's runners.
  It then runs every build in a VM with `--check`, and pushes only if each one
  prints its expected RESULT. The image's
  `org.opencontainers.image.revision` label is this repository's commit.
- The labels and annotations name the OpenZFS commit of each build
  (`io.github.wrouesnel.zfs-repro.build.<label>`), the PR, and the expected
  results: `podman inspect` or `skopeo inspect`.
- Inside the VM, `/etc/zfshunt-build` and the motd name the loaded build
  (`<short sha> <subject>`, `zfs <version> srcversion <x>`). The base refuses
  a module whose srcversion differs.
- You can rebuild everything yourself with podman: `builder/build.sh all
  pr19267` (see "Building" below). The base pins its Ubuntu image by digest and
  its packages with a snapshot.ubuntu.com date.

## Sources and licensing

Each image carries its sources list in `/sources` (`podman run --rm IMAGE
--sources`):

- `/sources/base/SOURCES.txt`: the distribution, the kernel, and every
  package that contributed a file to the base, with its version, its source
  package and the Launchpad URL of that source.
- `/sources/repro/SOURCES.txt`: the OpenZFS repository and commit of each
  build, its upstream base commit on openzfs/zfs master, and
  `/sources/repro/patches/<label>.patch` (the commits on top of upstream).

OpenZFS is licensed under the CDDL-1.0 (a few files are BSD or dual-licensed).
The Linux kernel, busybox, bash, coreutils and the other GPL userland in the
bases are GPL-2.0 or GPL-3.0, and FreeBSD's base system is mostly BSD-licensed.
Everything is redistributed unmodified, as built, for reproducing bugs. The
corresponding sources are the packages and commits listed above.

The scripts in this repository are under the MIT license ([LICENSE](LICENSE)).

## Building

Everything that compiles runs in a builder container, so you need podman and
KVM:

```sh
builder/build.sh all pr19267        # base, OpenZFS builds, disks, images, --check
builder/build.sh check pr19267      # the checks again
```

`builder/build.sh` has the individual steps (`base`, `zfs`, `repro`,
`images`, `check`, `push`); CI calls the same steps. The outputs go to
`work/` (gitignored), and OpenZFS builds are cached by commit.

## FreeBSD

CI builds Linux images only. FreeBSD bases boot through SeaBIOS, gptboot and
the loader from a GPT disk, and the runtime already supports them. They have
to be built on a FreeBSD system (the GENERIC kernel of the release,
`makefs`, an OpenZFS build per commit). `scripts/freebsd-image.sh` wraps such
locally built base and reproducer disks into the same images, which are then
checked and pushed with `builder/build.sh check|push`. The host trigger
channel (`zr`) is Linux-only for now.

## Adding a reproducer

See [docs/reproducer-format.md](docs/reproducer-format.md). In short: a
directory `reproducers/<id>/` with `reproducer.conf`, `demo.sh` and
optionally `inspect.sh`, helpers and `host.sh`, with the builds pinned to
public commits by full sha.
