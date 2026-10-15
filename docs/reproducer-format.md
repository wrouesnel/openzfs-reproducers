# The reproducer format

Each reproducer is a directory `reproducers/<id>/`. CI builds it into the
image `ghcr.io/wrouesnel/openzfs-reproducers:<id>`. The id names the upstream
reference, for example `pr19267` for openzfs/zfs#19267.

| file | what it is |
|---|---|
| `reproducer.conf` | metadata, builds, expected results and VM settings (below) |
| `demo.sh` | the demo, run in the VM as root (bash). It prints one `RESULT ...` line |
| `inspect.sh` | optional: re-reads a run disk that an earlier run left, and prints `RESULT ... on disk` |
| `*.c` | optional helpers, compiled in the builder and installed as `/demo/<name>` |
| `bins` | optional: extra programs from the builder's distribution (`NAME` or `NAME=SOURCE`), installed in `/demo/bin` |
| `prep.sh` | optional: `bash prep.sh ROOT` runs in the builder on the reproducer disk's tree before the library scan |
| `host.sh` | optional: host-side triggers, run by the orchestrator in the container (see "External triggers") |

The reproducer disk is ext4 and is mounted read-only on `/demo` in the VM. It
holds the demo files, `/demo/bin/zr` (the guest side of the host channel) and
one directory per build (`/demo/<label>/`) with that build's `zfs.ko` and
`spl.ko`, `zpool`, `zfs`, `zdb` and its libraries. At boot the base loads the
build that the container selected, links its tools into `/usr/sbin`, and
writes the motd and the shell history, so that Up, Enter runs the demo.

## reproducer.conf

These are shell-style `KEY='value'` lines. The builder and the container both
read them.

| key | meaning |
|---|---|
| `TITLE` | one line: what goes wrong |
| `PRS`, `ISSUES` | upstream openzfs/zfs PR and issue numbers (space separated). **Only public ones**: this repository publishes nothing about bugs that aren't already public upstream |
| `BRANCH` | optional: where the fix branch lives (a URL) |
| `BASE` | the base system, `bases/<BASE>/base.conf` (`linux-ubuntu24`) |
| `BUILDS` | the build labels, normally `bug fix`. The first is the default |
| `BUILD_<label>` | `REPO@SHA`, for example `https://github.com/openzfs/zfs@c8b07a0...` (full 40-hex sha; the commit must be reachable from a ref of REPO, such as a PR head) |
| `CONFIGURE` | OpenZFS configure arguments for every build (usually `--enable-debug`) |
| `EXPECT_<label>` | the start of the `RESULT` line that build must print. `--check` and CI compare it |
| `EXPECT_INSPECT_<label>` | the same for `inspect.sh` on that build's run disk |
| `MEM`, `CPUS`, `TIMEOUT` | VM memory (MiB), vCPUs, and seconds to wait for RESULT |
| `DISKS`, `DISK_SIZE` | the number of sparse run disks per VM (or shared), and their size (`1G`) |
| `VMS` | the number of VMs (default 1). VM0 runs the demo. The others boot to a prompt and act only when typed at (host.sh `vm_type`) |
| `SHARED_DISKS` | `1`: every VM attaches the same run disks (no image locking, `share-rw`), for example two hosts on one pool (multihost/MMP) |
| `NETWORK` | `1`: a private point-to-point link between VM0 and VM1 (`VMS=2`), `10.99.0.1` and `10.99.0.2` after `zr setup`. There is no other network |
| `HOSTIDS` | one hex hostid per VM, set by `zr setup` (`/etc/hostid` and `spl_hostid`) |
| `RESULT_VM` | the VM whose console carries the RESULT line (default 0) |

### The VM

- **Linux bases:** the kernel boots directly; busybox init runs a root bash on
  serial0. There is no udev. Run disks get a GPT with one partition, and
  `DEMO_DISK` / `DEMO_DISKS` name the partitions (`/dev/vdc1 ...`; `vda` is
  the base and `vdb` the reproducer disk). The serial of run disk N is
  `zfsdemo-runN`, so a demo can find a disk again after a replug
  (`/sys/block/vd*/serial`).
- Serial ports: ttyS0 is the root shell. ttyS1 gets the kernel log, plus the
  `bash -x` trace of an Up, Enter run. ttyS2 is the host channel.
- A demo **exports** its pool at the end and doesn't destroy it, so
  `--disk` can inspect the run disk later.

## External triggers

The container is the VMs' host, so a reproducer can act from outside the VM:
cut the power, pause it, unplug a disk, make a disk fail, rewrite a disk image
between boots, or work a second VM. The demo asks for these synchronously:

```sh
zr trigger NAME [ARGS]    # the host does NAME, and answers when it is done
zr wait NAME [ARGS]       # the host waits for something, then answers
```

`zr` (`/demo/bin/zr`) writes `ZR <id> trigger NAME ARGS` to ttyS2. The
orchestrator calls the shell function `trigger_NAME VM ARGS...` and answers
`ZR <id> <rc> <text>`. `zr` prints the text and exits with rc, which is 127 if
there is no such trigger. The other guest commands are:

| guest command | what it does |
|---|---|
| `zr env` | prints `VM= VMS= HOSTID= IP= PEER=` for this VM (`eval "$(zr env)"`) |
| `zr setup` | sets this VM's hostid (from `HOSTIDS`) and network address |
| `zr log TEXT` | writes a line to the host log |
| `zr phase [N]` | prints the demo's phase, or sets it to N. The phase is kept in `/root/.zr-phase` and synced, so it survives a power cut |

### Built-in triggers

| trigger | what the host does |
|---|---|
| `pause [SECONDS]` | QMP `stop`, waits (default 2 s), then `cont`. The guest clock (kvmclock) does not see the gap; another VM does |
| `powercut` | QMP `quit` (power off at once: no export, no guest sync), boots the VM again with the same root overlay and run disks, waits for the prompt and runs the demo again. It never answers; the demo carries on from `zr phase` |
| `unplug N` / `plug N` | hot-unplugs run disk N (`device_del`, ACPI PCI hotplug) and plugs it back in (`device_add`, same serial) |
| `errors N read\|write\|rw [SECTOR]` | puts a qemu `blkdebug` filter under run disk N that fails every read, every write or both (optionally only I/O covering SECTOR) with EIO |
| `clear-errors N` | removes the filter |
| `throttle N IOPS [BPS]` / `unthrottle N` | `block_set_io_throttle` on run disk N, to widen a race |
| `zero N OFFSET LENGTH` | zeroes bytes of run disk N's image file on the host (export or pause first) |
| `copy N FILE` | copies run disk N's image to `/runs/FILE` while the VM runs (pause first for a consistent copy) |
| `type VM TEXT` | types TEXT on VM's console (`\r` is Enter) |
| `sleep SECONDS` | waits on the host |
| `wait output VM ERE [SECONDS]` | waits until VM's console prints ERE |

### host.sh

`host.sh` is bash. The orchestrator sources it, so it can define new
`trigger_NAME` and `wait_NAME` functions or replace the built-in ones. It can
also define `host_start`, which runs once after the VMs start booting, for
example to set up the other VMs. Each function gets the asking VM's index as
`$1`. Its output goes to the host log. A function can set `ZR_REPLY` to send
text back to the guest, and its return code becomes `zr`'s exit status.

The functions it can call:

| function | |
|---|---|
| `vm_type VM TEXT` | type on VM's console (`$'...\r'`) |
| `vm_wait VM ERE SECONDS [OFFSET]` | wait for ERE in VM's console log, after byte OFFSET (`logsize VM` before typing) |
| `vm_run_demo VM [OFFSET]` | wait for the prompt and press Up, Enter |
| `vm_pause VM`, `vm_resume VM` | QMP stop / cont |
| `vm_powercut VM`, `vm_start VM`, `vm_reboot VM` | power off at once; boot (again); both, then run the demo again |
| `vm_poweroff VM` | a clean poweroff at the prompt (exports the pools) |
| `vm_alive VM` | true while VM's qemu runs |
| `qmp VM JSON`, `hmp VM COMMAND` | any QMP or human-monitor command; prints the reply |
| `disk_path VM N` | run disk N's image file |
| `disk_unplug`, `disk_plug`, `disk_errors VM N RULES`, `disk_clear_errors`, `disk_throttle` | as the built-in triggers. RULES is a JSON list of blkdebug `inject-error` rules |
| `disk_zero FILE OFFSET LENGTH`, `disk_copy FILE DEST`, `disk_swap VM N FILE` | edit and copy images; `disk_swap` attaches FILE as disk N from the VM's next boot on |
| `hlog TEXT` | a line in the host log |

Remember that typed text is echoed. When `vm_wait` looks for a marker that
your typed command prints, quote part of it in the typed text
(`echo DONE-"OK"`), so the echo doesn't match.

### Modes

- `--check` boots every VM, presses Up, Enter on VM0, and waits for a RESULT
  line (or a kernel panic) on `RESULT_VM`'s console. It doesn't give up while
  a trigger runs, so power cuts and reboots are fine. Then it powers every VM
  off and exits 0 if the RESULT matches `EXPECT_<label>`, or 1 if it doesn't.
  `--verbose` prints every console and the host log.
- Interactive (`-it`) runs the same orchestrator. One VM: your terminal is
  VM0's console (Ctrl-] leaves). Several VMs, or `--console`: tmux with a pane
  per VM console, kernel logs, the host log and (one VM) the script.
- A reproducer whose demo needs a trigger works the same way in every mode,
  because the triggers come from the demo itself.

### Example

`reproducers/selftest-triggers/` is not a bug. It uses every kind of trigger:
two VMs sharing two disks over a private link, a throttle, EIO injection, a
hot-unplug and replug, a pause, a power cut that the demo survives (`zr
phase`), a host-side overwrite that a scrub repairs, an import on the other VM
with another hostid, and a disk copy. CI runs it on every change, so the
trigger path keeps working before any published reproducer needs it.

## Adding a reproducer

1. The bug must be public upstream (an open or merged openzfs/zfs PR or issue).
2. Create `reproducers/<id>/` with the files above, with the builds pinned by
   full sha.
3. `builder/build.sh all <id>` builds and checks it locally (podman, KVM),
   and CI does the same on the pull request.
4. On merge to main, CI pushes `ghcr.io/wrouesnel/openzfs-reproducers:<id>`.

## Bases

`bases/<name>/base.conf` pins the builder (Ubuntu image digest, a
snapshot.ubuntu.com date and the kernel package), so a rebuild gets the same
package versions. `builder/in/base-linux.sh` packs the base. Its
`SOURCES.txt`, which lists every file's package and source, ships in the image
at `/sources/base/SOURCES.txt`.

FreeBSD bases aren't built in CI yet. See the README.
