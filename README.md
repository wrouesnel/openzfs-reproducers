# openzfs-reproducers

Container images that reproduce OpenZFS bugs in a tiny VM, for people
reviewing a fix. Every reproducer comes as a pair of images for each kernel
that openzfs/zfs CI tests on:

- `repro-USER-SLUG-TARGET-KERNEL`: the **break**, OpenZFS without the fix
  (the fix branch's test commit, or master). Its demo prints `RESULT BUG`.
- `fixed-USER-SLUG-TARGET-KERNEL`: the **fix**, the head of the fix branch.
  The same demo prints `RESULT OK`.

`USER/SLUG` names the fix branch: its GitHub owner and its name, slugified
(`wrouesnel/fix-mmap-eof-extend` is github.com/wrouesnel/zfs, branch
`fix-mmap-eof-extend`). `TARGET` is the openzfs CI platform (`ubuntu24`,
`debian13`, `fedora44`, `almalinux9`, `freebsd15-1r`, ...) and `KERNEL` its exact
kernel release (`+` becomes `_` in a tag).

```sh
podman run --rm -it --device /dev/kvm ghcr.io/wrouesnel/openzfs-reproducers:repro-wrouesnel-fix-mmap-eof-extend-ubuntu24-6.8.0-142-generic
podman run --rm -it --device /dev/kvm ghcr.io/wrouesnel/openzfs-reproducers:fixed-wrouesnel-fix-mmap-eof-extend-ubuntu24-6.8.0-142-generic
```

(`docker run` takes the same arguments.) You get a root shell on the VM's
serial console; press **Up, Enter** and the demo prints its `RESULT` line. The
VM boots in about two seconds. Nothing is built on your machine, nothing
touches your own pools, and the VM has no network.

When the fix branch heads an openzfs/zfs pull request, or names an issue, the
same images also have alias tags: `repro-pr19267-TARGET-KERNEL`,
`fixed-pr19267-...`, `repro-issue19220-...` (see "Tags" below).

## What is published

[docs/index.md](docs/index.md) lists every reproducer with its fork branch, upstream PR and published images, and every branch of [wrouesnel/zfs](https://github.com/wrouesnel/zfs) (`scripts/index.sh` regenerates it).

[docs/results.md](docs/results.md) is the matrix: every reproducer on every
target, what the break and the fix printed, and whether the pair is
published. A pair is published only when the break reproduces (`repro-` prints
its expected `RESULT BUG`) **and** the fix passes (`fixed-` prints `RESULT OK`)
on that kernel. A combination where the bug doesn't show, or where the fix
doesn't hold, is recorded there and not published.

```sh
# what is published, by reproducer (anonymous; needs curl)
curl -fsSL https://raw.githubusercontent.com/wrouesnel/openzfs-reproducers/main/zfs-repro.sh | sh -s -- --list
sh zfs-repro.sh --list --user wrouesnel

# run one by name: the break on ubuntu24 (default), or the fix on debian13
sh zfs-repro.sh wrouesnel/fix-mmap-eof-extend
sh zfs-repro.sh wrouesnel/fix-mmap-eof-extend fixed debian13

# what an image is, its build and the RESULT it should print
podman run --rm ghcr.io/wrouesnel/openzfs-reproducers:repro-wrouesnel-fix-mmap-eof-extend-ubuntu24-6.8.0-142-generic --info
```

Reproducers are built from public commits only: a branch on GitHub (our fork
github.com/wrouesnel/zfs, someone else's fork, or openzfs/zfs itself). CI
checks that every commit is reachable from the branch it names. A reproducer
doesn't need an upstream PR or issue, so its images can be linked from the PR
when it opens.

## In the VM

- **Up, Enter** runs the demo with a `bash -x` trace. The trace and the kernel
  log go to the second serial port, which is logged in `/runs` in the
  container.
- **Up Up, Enter** runs the demo without the trace. `less /demo/demo.sh`
  shows the script.
- `poweroff` exports the demo's pool and ends the VM. **Ctrl-]** leaves at
  once.

Options (after the image):

| | |
|---|---|
| `--console` | tmux: the root shell, the kernel log + trace, and the script, side by side |
| `--check` | no terminal needed: boots, runs the demo, waits for RESULT, powers off, and exits 0 if the RESULT is the image's expected one (1 if not). `--verbose` prints the consoles |
| `--runs N` | runs the demo N times, each on a fresh boot with fresh run disks, then prints a summary: counts of RESULT OK / BUG / ERROR, panics, the failure rate and the time per run. For flaky bugs |
| `--until-fail` | stops at the first run that isn't `RESULT OK` |
| `--parallel P` | P VMs at once (fewer if the host is short of memory or CPUs) |
| `--keep` | keeps every run's logs and disks; by default only the first failing run's are kept |
| `--disk /runs/FILE.raw` | boots the build with the run disk of an earlier run, to inspect the pool it left (`inspect.sh`: `RESULT ... on disk`) |
| `--info`, `--sources` | what the image is, and the SOURCES of everything in it |
| `--dry-run` | prints the qemu command line(s) |

`--check` with `--runs`: a reproducer can declare how many runs its check
needs and how many must match (a flaky bug: `repro-` passes if at least one
run of N shows the bug, `fixed-` only if none does). `--info` shows it.

### Keeping the run disks

Each run makes new sparse run disks for the demo's pool. The demo exports the
pool at the end, so a disk holds a clean, importable pool. By default the
disks live in the container's writable layer and go away with `--rm`. To keep
them, mount a directory on `/runs`:

```sh
mkdir -p runs
podman run --rm -it --device /dev/kvm -v ./runs:/runs IMAGE
podman run --rm -it --device /dev/kvm -v ./runs:/runs IMAGE --disk /runs/repro-<time>.raw
```

On SELinux hosts add `:Z` to the volume, for example `-v ./runs:/runs:Z`.
`zfs-repro.sh` does this for you with `~/.cache/zfs-repro/runs/TAG`.

## Requirements

- Linux on x86_64 with **podman** (rootless is fine) or **docker**.
- **/dev/kvm** that your user can open (you are in the `kvm` group, or the
  device has an ACL for you). Pass it with `--device /dev/kvm`. With rootless
  podman and a group-only `/dev/kvm` (mode 0660), add `--group-add keep-groups`.
  Without KVM the image falls back to software emulation (TCG), with a
  warning, about 10-50 times slower.
- Disk: the first pull is about 100-120 MB (most of it the runtime with
  qemu); another image of the same target adds only its build (about 6 MB),
  and another target adds its kernel. See [docs/layers.md](docs/layers.md).

The container needs no `--privileged` and no network for the VM. The VM's
only devices are its disks, a random number generator and serial ports. Some
reproducers also get a private link to a second VM; neither VM can reach
anything outside the container.

## Targets

The targets are the platforms of openzfs/zfs CI's `zfs-qemu` workflow, with
the kernel each one ran on 2026-10-15 (read from the CI job logs):

| target | kernel | from |
|---|---|---|
| `almalinux8` | 4.18.0-553.173.1.el8_10.x86_64 | AlmaLinux 8 repository |
| `almalinux9` | 5.14.0-687.56.1.el9_8.x86_64 | AlmaLinux 9 repository |
| `almalinux10` | 6.12.0-211.65.1.el10_2.x86_64 | AlmaLinux 10 repository |
| `alpine3-24` | 7.1.5-0-stable | Alpine 3.24 `linux-stable` |
| `debian12` | 6.1.0-53-amd64 | Debian 12 (security) |
| `debian13` | 6.12.111+deb13-amd64 | Debian 13 (security) |
| `fedora43` | 7.2.10-100.fc43.x86_64 | Fedora koji |
| `fedora44` | 7.2.10-200.fc44.x86_64 | Fedora koji |
| `ubuntu22` | 5.15.0-198-generic | Ubuntu snapshot 20261015 |
| `ubuntu24` | 6.8.0-142-generic | Ubuntu snapshot 20261015 |
| `ubuntu26` | 7.0.0-34-generic | Ubuntu snapshot 20261015 |
| `freebsd14-4r` | 14.4-RELEASE | FreeBSD CI image (built locally) |
| `freebsd15-1r` | 15.1-RELEASE | FreeBSD CI image (built locally) |
| `freebsd15-1s` | 15.1-STABLE | FreeBSD CI snapshot (built locally) |
| `freebsd16-0c` | 16.0-CURRENT | FreeBSD CI snapshot (built locally) |

Each Linux target is its distribution's own kernel package, unmodified, and
the OpenZFS modules for it are built in a container of that distribution, with
its compiler and kernel headers, as CI does in its VMs. All Linux targets boot
the same small userland (Ubuntu 24.04's busybox, bash and libraries), so the
OpenZFS tools are built once per commit. [docs/targets.md](docs/targets.md)
has the details and how to move a target to a newer kernel.

## Tags

| tag | what |
|---|---|
| `repro-USER-SLUG-TARGET-KERNEL` | the break of reproducer USER/SLUG on that target |
| `fixed-USER-SLUG-TARGET-KERNEL` | its fix |
| `repro-prN-TARGET-KERNEL`, `fixed-prN-...` | the same images, when openzfs/zfs PR N's head is the commit the `fixed-` image was built from |
| `repro-issueN-TARGET-KERNEL`, `fixed-issueN-...` | the same images, for openzfs/zfs issue N (named in the reproducer, closed by its PR, or referenced by `Closes #N` in the fix branch's commits) |
| `runtime-*`, `userland-*`, `kernel-TARGET-KERNEL` | the shared layers, on their own (no reproducer) |

A tag is at most 128 characters. When `repro-USER-SLUG-TARGET-KERNEL` would be
longer, the slug is cut and 8 hex digits of the full name's sha256 are
appended (`USER`, `TARGET` and `KERNEL` stay whole).

The alias tags are applied after each build on main and daily
(`.github/workflows/aliases.yml`, `scripts/aliases.py`). They are the same
manifests (same digests), never rebuilds. A PR's aliases move only when its
new head has been built and passes; until then they stay on the last built
head, and the image's labels say which commit it holds. When several
reproducers name the same issue, the issue's aliases go to the one whose PR
closes it, else to the newest fix; docs/results.md lists all of them.

## What is in an image

Five layers, so that images share the large parts:

1. **runtime**: Alpine with `qemu-system-x86_64`, `qemu-img`, tmux and the
   entrypoint `zfs-repro-vm` (an orchestrator in bash).
2. **userland** (Linux): a compressed qcow2 of a minimal Ubuntu 24.04 root
   (busybox, bash, a few GNU tools, the libraries the OpenZFS tools need).
   No kernel, no ZFS. Every Linux target boots it.
3. **kernel**: the target's kernel, and an initramfs that loads the virtio,
   ext4 and other modules it doesn't have built in. A FreeBSD target is one
   disk with its GENERIC kernel and userland instead of layers 2 and 3.
4. **demo**: the reproducer's demo disk (demo.sh, helpers, inspect.sh). The
   same layer, byte for byte, in every image of the reproducer.
5. **build**: one OpenZFS build: `zfs.ko` and `spl.ko` for this kernel, and
   `zpool`, `zfs`, `zdb`, `zinject`, ... with their libraries.

At boot, the userland finds the demo disk and the build disk by their virtio
serials, loads the build's modules (it checks their srcversion), links its
tools, and starts a root shell. Each run boots from a throwaway overlay, so
the image is never written.

### Reproducers that act from outside the VM

The container is the VMs' host, so a reproducer can do what a script inside
one VM can't. It can cut the power and boot again, pause the VM, hot-unplug a
disk, inject I/O errors, throttle a disk, rewrite a disk image between boots,
or run two VMs on shared disks or a private link (for example multihost
imports). The demo asks the host for these with `zr trigger NAME` on a
dedicated serial port. See [docs/reproducer-format.md](docs/reproducer-format.md),
and `wrouesnel/selftest-triggers`, which CI runs on every change. Repeated
runs (`--runs`) work for these too.

## Verification

- Every published image comes from `.github/workflows/build.yml` in this
  repository. It builds the userland, each target's kernel, every OpenZFS build
  (from the commits pinned in `reproducers/USER/SLUG/reproducer.conf`, checked
  to be public) and the images on GitHub's runners. It then runs both images
  of each pair in a VM with `--check`, and pushes only if both print their
  expected RESULT. The image's `org.opencontainers.image.revision` label is
  this repository's commit.
- The labels and annotations name the OpenZFS commit of the build
  (`io.github.wrouesnel.zfs-repro.build`), the fix branch, the target and
  kernel, and the expected result: `podman inspect` or `skopeo inspect`.
- Inside the VM, `/etc/zfshunt-build` and the motd name the loaded build
  (`<short sha> <subject>`, `zfs <version> srcversion <x>`). The base refuses
  a module whose srcversion differs.
- You can rebuild everything with podman: `builder/build.sh all USER/SLUG
  [TARGET...]` (see "Building").

## Sources and licensing

Each image carries its sources list in `/sources` (`podman run --rm IMAGE
--sources`):

- `/sources/userland/SOURCES.txt`: every package that contributed a file to
  the userland, with its version, its source package and the Launchpad URL.
- `/sources/kernel/SOURCES.txt`: the target's kernel packages and where their
  source is.
- `/sources/repro/SOURCES.txt` and `/sources/build/SOURCES.txt`: the demo, and
  the OpenZFS repository and commit of the build, its upstream base commit on
  openzfs/zfs master, and `/sources/build/patches/LABEL.patch` (the commits on
  top of upstream).

OpenZFS is licensed under the CDDL-1.0 (a few files are BSD or dual-licensed).
The Linux kernel, busybox, bash, coreutils and the other GPL userland are
GPL-2.0 or GPL-3.0, and FreeBSD's base system is mostly BSD-licensed.
Everything is redistributed unmodified, as built, for reproducing bugs. The
corresponding sources are the packages and commits listed above.

The scripts in this repository are under the MIT license ([LICENSE](LICENSE)).

## Building

Everything that compiles runs in a builder container, so you need podman and
KVM:

```sh
builder/build.sh all wrouesnel/fix-mmap-eof-extend ubuntu24 debian13   # build and check
builder/build.sh check wrouesnel/fix-mmap-eof-extend ubuntu24          # the checks again
CHECK_ARGS='--runs 20 --parallel 4' builder/build.sh check ID TARGET   # a flaky one
```

`builder/build.sh` has the individual steps (`userland`, `kernel`,
`zfs-user`, `zfs-kmod`, `demo`, `disks`, `images`, `check`, `push`); CI calls
the same steps. The outputs go to `work/` (gitignored), and everything is
cached by what it is made of.

## FreeBSD

CI builds Linux targets only. FreeBSD targets boot through SeaBIOS, gptboot
and the loader from one GPT disk, and the runtime supports them. The disks
have to be built on FreeBSD (the GENERIC kernel of the release, `makefs`, an
OpenZFS build per commit); `scripts/freebsd-image.sh` wraps such disks into
the same images, which are then checked and pushed with `builder/build.sh
check|push`. A reproducer lists the FreeBSD targets it has in `LOCAL_TARGETS`.
The host trigger channel (`zr`) is Linux-only for now. What is covered:
[docs/results.md](docs/results.md).

## Adding a reproducer

For a fix branch whose ZTS test shows the bug (a "test, then fix" branch,
or a test-only fix), `scripts/new-reproducer.sh BRANCH` writes the whole
reproducer: a `KIND=zts` `reproducer.conf` that runs the branch's test on
the break and on the fix. Check it with `builder/build.sh all ID ubuntu24`
and list it in [docs/coverage.md](docs/coverage.md), the inventory of our
fix branches.

Otherwise, push the fix branch to a public GitHub fork, then add `reproducers/USER/SLUG/`
with `reproducer.conf` (the branch, the break and fix commits, the expected
RESULT lines), `demo.sh` and optionally `inspect.sh`, helpers and `host.sh`.
CI does the rest: it builds the pair for every target, records the results,
and publishes the targets where the break reproduces and the fix passes. See
[docs/reproducer-format.md](docs/reproducer-format.md).
