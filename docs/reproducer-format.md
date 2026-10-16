# The reproducer format

Each reproducer is a directory `reproducers/USER/SLUG/`, named after the fix
branch it is built from: USER is the GitHub owner of the repository the
branch is fetched from (lowercase; `wrouesnel` for github.com/wrouesnel/zfs,
`openzfs` for an upstream branch), SLUG the branch name slugified (lowercase,
every run of characters other than `a-z0-9` becomes `-`, no leading or
trailing `-`). CI builds two images of it for every target:

- `repro-USER-SLUG-TARGET-KERNEL`: the break (`BUILD_repro`), which must print
  `EXPECT_repro`;
- `fixed-USER-SLUG-TARGET-KERNEL`: the fix (`BUILD_fixed`), which must print
  `EXPECT_fixed`;

and publishes them, as a pair, for the targets where both do.

| file | what it is |
|---|---|
| `reproducer.conf` | metadata, the two builds, expected results and VM settings (below) |
| `demo.sh` | the demo, run in the VM as root (bash). It prints one `RESULT ...` line |
| `inspect.sh` | optional: re-reads a run disk that an earlier run left, and prints `RESULT ... on disk` |
| `*.c` | optional helpers, compiled in the userland builder and installed as `/demo/<name>` |
| `bins` | optional: extra programs from the userland builder's distribution (`NAME` or `NAME=SOURCE`), installed in `/demo/bin` |
| `prep.sh` | optional: `bash prep.sh ROOT` runs in the builder on the demo disk's tree before the library scan |
| `host.sh` | optional: host-side triggers, run by the orchestrator in the container (see "External triggers") |
| anything else | copied to the demo disk as it is (data files, ZTS scripts, ...) |

The demo disk is ext4 and is mounted read-only on `/demo` in the VM. It holds
the demo files and `/demo/bin/zr` (the guest side of the host channel). It is
the same for every target and both builds. The build disk is mounted on `/zfs`:
that build's `zfs.ko` and `spl.ko` for the target's kernel, `zpool`, `zfs`,
`zdb`, `zinject`, `zhack`, `zstream` (and `TOOLS`) and its libraries. At boot
the userland loads the modules, links the tools into `/usr/sbin`, and writes
the motd and the shell history, so that Up, Enter runs the demo.
`DEMO_BUILD` (in the demo's environment) is `repro` or `fixed`.

## reproducer.conf

These are shell-style `KEY='value'` lines. The builder and the container both
read them.

| key | meaning |
|---|---|
| `TITLE` | one line: what goes wrong |
| `REPO`, `BRANCH` | the fix branch: `https://github.com/USER/zfs` and the branch name (its slug is the directory name) |
| `AUTHOR`, `REPORTER` | who wrote the fix (`@handle`) and who reported the bug (`@handle` or an issue); shown by `--info` and in the labels |
| `PRS`, `ISSUES` | optional openzfs/zfs PR and issue numbers (space separated): metadata, and hints for the alias tags (`scripts/aliases.py` also finds them itself) |
| `BUILD_repro` | the break: `REPO@SHA` (full 40-hex sha). Usually the branch's test commit (the test without the fix) or the openzfs/zfs master commit the branch is based on |
| `BUILD_fixed` | the fix: `REPO@SHA`, the branch head. Leave it out for a self-test with nothing to fix |
| `CONFIGURE` | OpenZFS configure arguments for both builds (usually `--enable-debug`) |
| `TOOLS` | more programs for the build disk: OpenZFS tools (`zgenhostid`, `zed`, ...) or ZTS helpers (`file_write`, ...) |
| `EXPECT_repro`, `EXPECT_fixed` | the start of the `RESULT` line each build must print (`PANIC` matches a kernel panic). `--check` and CI compare it |
| `EXPECT_INSPECT_repro`, `EXPECT_INSPECT_fixed` | the same for `inspect.sh` on that build's run disk |
| `RUNS_repro`, `RUNS_fixed` | a flaky reproducer: how many runs `--check` does (default 1) |
| `MIN_MATCH_repro`, `MIN_MATCH_fixed` | how many of those runs must match the expectation (default: all). For a flake, `MIN_MATCH_repro=1` with `RUNS_repro=20` means "the break fails at least once in 20 runs", and `RUNS_fixed=20` means "the fix passes 20 of 20" |
| `REPEAT_IN_VM` | `1`: `--runs` may run the demo again in the same booted VM (the demo recreates its pool), rebooting only after a panic |
| `TARGETS`, `SKIP_TARGETS` | the targets to build for (default: every x86_64 Linux target), and ones to leave out |
| `LOCAL_TARGETS` | targets built outside CI, for example FreeBSD (`scripts/freebsd-image.sh`) |
| `MEM`, `CPUS`, `TIMEOUT` | VM memory (MiB), vCPUs, and seconds to wait for RESULT |
| `DISKS`, `DISK_SIZE` | the number of sparse run disks per VM (or shared), and their size (`1G`) |
| `VMS` | the number of VMs (default 1). VM0 runs the demo. The others boot to a prompt and act only when typed at (host.sh `vm_type`) |
| `SHARED_DISKS` | `1`: every VM attaches the same run disks (no image locking, `share-rw`), for example two hosts on one pool (multihost/MMP) |
| `NETWORK` | `1`: a private point-to-point link between VM0 and VM1 (`VMS=2`), `10.99.0.1` and `10.99.0.2` after `zr setup`. There is no other network |
| `HOSTIDS` | one hex hostid per VM, set by `zr setup` (`/etc/hostid` and `spl_hostid`) |
| `RESULT_VM` | the VM whose console carries the RESULT line (default 0) |
| `KIND` | `zts`: a ZTS reproducer, see "ZTS reproducers" below (no demo.sh needed) |
| `ZTS_TESTS` | `KIND=zts`: the tests to run, as `tests/functional/GROUP/NAME` (space separated) |
| `ZTS_SCRIPTS` | `KIND=zts`: `fixed` runs the fix head's test scripts on both builds (the break has no test of its own); default: each build runs its own commit's |
| `ZTS_ITERATIONS` | `KIND=zts`: how many times one demo runs the tests (a flake: `RESULT BUG` if any run fails) |
| `BLOCKED` | why this reproducer doesn't show its bug yet (docs/coverage.md): `builder/build.sh ids` and CI leave it out (`WITH_BLOCKED=1` includes it) |
| `EXTRA_PKGS` | packages of the userland builder's distribution (at its snapshot) to unpack on the demo disk: their programs on `/demo/bin`, their libraries on `/demo/lib` |

Every commit must be public: CI runs `builder/build.sh verify ID`, which asks
GitHub whether each `BUILD_*` commit is reachable from `BRANCH` on its
repository (or from master on openzfs/zfs).

### Repeated runs (flaky bugs)

`--runs N` runs the demo N times, each on a fresh boot with fresh run disks
(or, with `REPEAT_IN_VM=1`, in the same VM), `--parallel P` runs P VMs at a
time (fewer if memory or CPUs are short), `--until-fail` stops at the first
run that isn't `RESULT OK`. Each run is classified OK, BUG, ERROR (`RESULT
ERROR` or no RESULT), PANIC or OTHER, and the summary gives the counts, the
failure rate and the time per run; the first failing run's logs are kept,
the others' are discarded unless `--keep`. With `--check`, the exit status is
0 when at least `MIN_MATCH` runs matched the image's expectation. Reproducers
with triggers (`host.sh`) work the same way: every run boots its own VMs.

### The VM

- **Linux targets:** the kernel boots directly; busybox init runs a root bash on
  serial0. There is no udev. Run disks get a GPT with one partition, and
  `DEMO_DISK` / `DEMO_DISKS` name the partitions (`/dev/vdd1 ...`; `vda` is
  the root, `vdb` the demo disk and `vdc` the build disk). Use the variables,
  not the names. The serial of run disk N is
  `zfsdemo-runN`, so a demo can find a disk again after a replug
  (`/sys/block/vd*/serial`).
- Serial ports: ttyS0 is the root shell. ttyS1 gets the kernel log, plus the
  `bash -x` trace of an Up, Enter run. ttyS2 is the host channel.
- A demo **exports** its pool at the end and doesn't destroy it, so
  `--disk` can inspect the run disk later.

## ZTS reproducers

Most fix branches carry their own reproducer: the ZTS test of their "test,
then fix" commits, or, for a test-only fix, the test itself. A reproducer
with `KIND='zts'` runs it, so it needs only a `reproducer.conf`
(`scripts/new-reproducer.sh` writes one from the branch):

```sh
KIND='zts'
ZTS_TESTS='tests/functional/zstream/zstream_decompress_007_pos'
TOOLS='file_write mkfile'      # ZTS helpers the tests use (builder/zts-tools.txt)
EXPECT_repro='RESULT BUG'
EXPECT_fixed='RESULT OK'
MEM=2048 TIMEOUT=1800 DISKS=1 DISK_SIZE=16G
```

- **The scripts.** `builder/in/zts-pack.sh` takes, from each build's own
  commit (a sparse, blobless fetch), `tests/zfs-tests/include` (with
  `default.cfg` made from `default.cfg.in` as configure would),
  `tests/test-runner/include`, the callbacks, and of each test's group the
  test, the group's setup and cleanup (as the runfiles name them: `pre`,
  `post`, `timeout`), its `.cfg`, `.kshlib` and `.shlib` files, and every
  file or directory any of these names under `$STF_SUITE`, transitively.
  They go to the demo disk as `/demo/zts/repro/` and `/demo/zts/fixed/`
  (a few hundred KB each), so a test-only fix runs master's test on the
  break and the fixed test on the fix, and a code fix runs its test commit's
  test against both builds.
- **The tools.** ZTS helpers (`file_write`, `mkfile`, ...) come with each
  OpenZFS build (`TOOLS`, built and cached with it); ksh93, `getconf`,
  `getent`, `lsblk`, `fallocate`, `blkid` come from the userland builder,
  and `xxhash` (`xxh128sum`, which the data checks need) and libaio from its
  distribution (`EXTRA_PKGS`). Everything goes on one constrained `PATH`,
  the way `zfs-tests.sh` sets `STF_PATH`. GNU `losetup`, `setpriv`,
  `unshare` and the shadow tools (`useradd`, ...) replace busybox's, and
  `sudo` is a small `setpriv` wrapper (`builder/in/zts-sudo`: the forms
  ZTS uses, `sudo -Eu USER` and `sudo -u '#UID'`). What only some tests
  need comes when their scripts name it: `python3` and its standard
  library, `jq`, `parted`, and `fio` (built from its release source by
  `builder/in/fio.sh`: Ubuntu's package pulls in the ceph and gluster
  libraries). ZED tests (`zed_setup` in the group) need `zed` in `TOOLS`:
  the build then carries its `zed.rc` and zedlets, linked where
  `default.cfg` looks (`scripts/new-reproducer.sh` adds it). A helper the
  branch itself adds to `tests/zfs-tests/cmd` goes in `TOOLS` by name
  (the scaffold finds those too).
- **The runner** (`builder/in/zts-run.sh`, which is the image's `demo.sh`,
  with the tests it runs appended for reading: `less /demo/demo.sh`, and the
  script pane of `--console`) does what `zfs-tests.sh` and `test-runner` do
  in openzfs/zfs CI: an ext2 file system on the run disk holds three 4 GiB
  sparse files behind loop devices (`DISKS="loop0 loop1 loop2"`,
  `FILEDIR`, `TMPDIR`), it sources `default.cfg`, and runs the group's setup,
  each test and the cleanup with ksh93, each under the runfile's timeout.
  The test's output appears on the console as it runs. It prints
  `RESULT BUG` when a test FAILs or is killed by its timeout, `RESULT OK`
  when every test PASSes, and `RESULT ERROR` when a setup fails or a test is
  skipped or unresolved. The tests run from a writable copy of the
  scripts (`/run/zts/suite`), as from a source tree.
- **Oopses.** The runner sets `panic_on_oops`: a task that oopses can
  wedge the guest (locks held, a CPU left with interrupts off), so the VM
  panics instead, and the launcher reports `PANIC`. A bug that oopses (a
  NULL dereference, `buffer modified while frozen`) has
  `EXPECT_repro='PANIC'`. An SPL `VERIFY`/`PANIC at`, a kernel `BUG:`
  warning or a hung task leaves the guest running: the runner prints
  `RESULT BUG` with the kernel's line at once.
- **Flakes.** `ZTS_ITERATIONS=N` runs the tests N times in one demo (one
  boot); the break prints `RESULT BUG` if any run failed. For rarer flakes
  add `RUNS_repro`/`MIN_MATCH_repro` (several boots), as for any reproducer.

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
  off and exits 0 if the RESULT matches the image's `EXPECT_repro` or
  `EXPECT_fixed`, or 1 if it doesn't (with `RUNS`: enough runs matched).
  `--verbose` prints every console and the host log.
- Interactive (`-it`) runs the same orchestrator. One VM: your terminal is
  VM0's console (Ctrl-] leaves). Several VMs, or `--console`: tmux with a pane
  per VM console, kernel logs, the host log and (one VM) the script.
- A reproducer whose demo needs a trigger works the same way in every mode,
  because the triggers come from the demo itself.

### Example

`reproducers/wrouesnel/selftest-triggers/` is not a bug (it has only a
`repro-` image, which expects `RESULT OK`, and is built for ubuntu24 only). It uses every kind of trigger:
two VMs sharing two disks over a private link, a throttle, EIO injection, a
hot-unplug and replug, a pause, a power cut that the demo survives (`zr
phase`), a host-side overwrite that a scrub repairs, an import on the other VM
with another hostid, and a disk copy. CI runs it on every change, so the
trigger path keeps working before any published reproducer needs it.

## Adding a reproducer

For a "test, then fix" branch, or a test-only fix, of ours on
github.com/wrouesnel/zfs, the reproducer is mechanical:

```sh
scripts/new-reproducer.sh fix-some-branch          # reproducers/wrouesnel/fix-some-branch/
scripts/new-reproducer.sh -t tests/functional/G/T fix-zts-branch   # when only a .kshlib changed
builder/build.sh verify wrouesnel/fix-some-branch
builder/build.sh all wrouesnel/fix-some-branch ubuntu24             # RESULT BUG / RESULT OK
```

It finds the break (the commit before the fix, or master for a test-only
fix; for a branch stacked on another fix of ours, set `BUILD_repro` to this
fix's own test commit and `ZTS_TESTS` to its test), the fix (the branch head), the tests the branch adds or changes, the
ZTS helpers they use and the openzfs/zfs PR the branch heads. Check the
result once on ubuntu24, set `ZTS_ITERATIONS` for a flake, and list the
branch in [coverage.md](coverage.md). A bug that a ZTS test can't show (a
console demo, host-side triggers) gets a `demo.sh` instead:

1. Push the fix branch (the test commit, then the fix) to a public GitHub
   repository, for example github.com/wrouesnel/zfs.
2. Create `reproducers/USER/SLUG/` with `reproducer.conf` (`REPO`, `BRANCH`,
   `BUILD_repro`, `BUILD_fixed` by full sha, the expected RESULT lines and the
   VM settings) and `demo.sh`. Someone else's branch works the same way: USER
   is their GitHub name, `AUTHOR` credits them, and the demo can be ours.
3. `builder/build.sh verify USER/SLUG` checks the commits are public;
   `builder/build.sh all USER/SLUG ubuntu24` builds and checks it locally.
4. Open a pull request: CI builds and checks every target. On merge to main,
   CI pushes the pairs where the break reproduces and the fix passes, and the
   results land in its `results-matrix` artifact (copied to docs/results.md).
5. When the branch gets an upstream PR, nothing needs to change: the alias job
   finds it and tags the images `repro-prN-...` / `fixed-prN-...` once the PR's
   head is the commit that was built. If the head moves, update `BUILD_fixed`.

## Targets and the userland

`bases/TARGET/base.conf` is a target: a kernel. `FAMILY` picks the builder
(`builder/Containerfile.FAMILY`: ubuntu, debian, rhel, fedora, alpine),
`IMAGE` pins the distribution's container image by digest, and `KERNEL`
(with `SNAPSHOT`, `KERNEL_RPMS` or `APKVER`) pins the kernel. The builder
fetches the kernel package, keeps the vmlinuz and the few modules the VM needs
(`builder/in/kernel-stage.sh`), and has the headers the OpenZFS modules are
built against. `builder/in/kernel.sh` packs the kernel and, if virtio or ext4
aren't built in, an initramfs. `userlands/NAME/userland.conf` is the root file
system every Linux target of that architecture boots
(`builder/in/userland.sh`). See docs/targets.md.
