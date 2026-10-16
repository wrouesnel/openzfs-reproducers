# Status and progress notes

Working notes for the maintainers: what is in the repository, what is
waiting, and why. The per-target outcomes are in [results.md](results.md).

## Reproducers in the repository (2026-10-15)

Every one is built from public commits (`builder/build.sh verify` checks each
build commit is reachable from the branch it names on GitHub).

| reproducer | upstream | repro (break) | fixed (fix) | demo from |
|---|---|---|---|---|
| wrouesnel/fix-mmap-eof-extend | PR #19267, issue #19220 | test c8b07a06f | head f1894abf5 | (pilot) |
| wrouesnel/fix-partial-read-redirty | PR #19299 | test 034df1e85 | head f5c2bea14 | zfs-bug-hunt 22 |
| wrouesnel/fix-partial-read-redirty-v2 | (v2 of #19299) | master c27dff0c3 | head 2d2cd4ca8 | 22 |
| wrouesnel/fix-hasrecvd-spa-open | PR #19306, issue #16988 | test 698970748 | head c99f45c9a | 32 |
| wrouesnel/fix-dos-readonly-open | PR #19313 | test 9b812a240 | head 2f9098489 | 39 |
| wrouesnel/fix-dyn-gang-header-import | PR #19314, issue #19189 | test 388a0de5d | head 00d906b32 (v2, force-pushed 2026-10-15) | 40 (Linux port) |
| wrouesnel/fix-dio-nopwrite-freed | PR #19336 | test ffd2b7540 | head 0c8fc6619 | 57 (release build) |
| wrouesnel/fix-snapdir-expire-stat | issue #19215 | test 17919a929 | head 6fde83e8f | 62 |
| wrouesnel/fix-resilver-detached-target | issues #13679, #16001 | test 129bc1125 | head c2451409c | 69 |
| wrouesnel/fix-raw-send-redact-bookmark-eacces | issue #18491 | test acff22fc2 | head 09190d4f6 | 70 |
| wrouesnel/fix-zts-dbufstats-mfu | #19341 (flake) | 68188d1ff (master test) | a1157c5e1 | 81 |
| wrouesnel/fix-zts-auto-replace-fill | #19341 (flake) | master 465d86a78 | 22cbe9e77 | 71 |
| wrouesnel/fix-zed-solved-case-peers | #19341 | test 63d0a952c | head b793018f6 | 72 |
| wrouesnel/fix-zts-refreserv-004 | #19341 (always fails) | master 465d86a78 | 838ed4396 | 114 |
| wrouesnel/fix-zts-crtime-001-flake | #19341 (flake) | master b060bcb1d | 956f6a607 | 120 |
| wrouesnel/fix-zts-import-parallel-admin | #19341 (flake) | master b060bcb1d | 7a93f90d6 | 125 |
| wrouesnel/fix-scrub-heal-stale-child-v2 | none yet | test 5bb2c5551 | head 2e661a806 | 127 |
| wrouesnel/fix-mmp-first-txg-delay | none yet | test 32c2a4762 | head 2bc4f47cd (reflowed 2026-10-16) | 138 |
| tigerblue77/zvol-rename-uevent | PR #19377 (@tigerblue77), issue #19371 | master c27dff0c3 | head 5c845323e | 129 (ours; the fix is theirs) |
| wrouesnel/selftest-triggers | (self-test, ubuntu24 only) | master b060bcb1d | none | - |

The test-only fixes (`fix-zts-*`) carry the affected ZTS test of each build
in the demo disk (`zts/repro/`, `zts/fixed/`) with a small stand-in for the
ZTS library, and the ZTS helpers they need come with the build (`TOOLS`).
The ZFS code of both builds is the same; the demo shows the test failing on
the break and passing with the fix, several times per run.

## ZTS reproducers (2026-10-16)

Most public fix branches have no console demo: their ZTS test is their
reproducer. `KIND=zts` (reproducer-format.md, "ZTS reproducers") runs it
from each build's own commit, and `scripts/new-reproducer.sh BRANCH`
scaffolds the reproducer from the branch's commits. Every fix branch of
ours on the fork, with what it has and what blocks the rest:
[coverage.md](coverage.md).

- Checked locally on ubuntu24 (`builder/build.sh all ID ubuntu24`: the
  break prints its RESULT BUG or panics, the fix prints RESULT OK) with
  the final runner: every reproducer coverage.md lists as "added now" with
  an ubuntu24 result.
- Bugs that oops expect `PANIC` (the runner sets `panic_on_oops`: an
  oopsed task can wedge the guest so that no RESULT line gets out).
- Flakes: zts-import-rewind-ckpt-txg (#136) shows with 8 vCPUs and 60
  runs per boot; flakes that need CI's load, udev, FreeBSD or low memory
  are kept with `BLOCKED='reason'`, which CI leaves out.
- Ported console demos: fix-zarcsummary-connreset (zfs-bug-hunt 124,
  Python from the userland builder), fix-zed-events-eintr (135).
- Blocked (coverage.md has each reason): single-commit fixes without a test
  (no demo yet), fix-initramfs-libcurl-symlink (needs initramfs-tools and a
  kernel module tree in the guest), tests that need scsi_debug or valgrind,
  FreeBSD-only fixes (no FreeBSD ZTS images yet), and flakes whose break
  doesn't fail on ubuntu24 in the repeated runs.
- The ZTS images are checked on ubuntu24 first (what console reviews
  pull); CI adds the other targets over its incremental runs (ci.md).
- Upstream finding while porting: zstream raw's `write_zeros()` VERIFYs
  that `pwritev()` wrote everything; in the guest (a file on ext4) it came
  back short (2.9 of 4 MiB) on both builds of fix-zstream-raw-free-ordering,
  so that reproducer is blocked until it is understood.

## Ready once on the fork

These branches are only in the local backup (~/git/will/zfs.git), so they
can't be built here yet; each has a demo in zfs-bug-hunt:

- fix-zio-batch-priority-v2 (bug 122, upstream #19360): demo repros/122/vm.
- fix-freebsd-fadvise-zos (bug 100, FreeBSD side of #19305): FreeBSD demo.
- fix-import-dryrun-no-import (65), fix-send-dryrun-relay (66),
  fix-freebsd-snapdir-readdir-eof (101): demos exist.
- zts-pr19364-xattr-sa-overflow (bug 123, FreeBSD): the fix is ryao's PR
  #19364 (public); the demo needs a FreeBSD build of master and of #19364's
  head: possible as `ryao/...` once built on FreeBSD (see FreeBSD below).

## FreeBSD

- All four CI FreeBSD targets have bases: zfs-bug-hunt's demo bases, made on
  FreeBSD from the CI images (`vm/mkdemo-base.sh`), imported with
  `scripts/freebsd-image.sh target`.
- wrouesnel/fix-dyn-gang-header-import on freebsd15-1r: the FreeBSD disk built
  on b-freebsd15-1r from the PR's first commits (cf9719c6e, d60260002) was
  wrapped and checked locally (repro RESULT BUG + inspect BUG, fixed RESULT OK
  + inspect OK), which proved the FreeBSD path end to end. The branch was
  then force-pushed to v2 (388a0de5d, 00d906b32), so those commits aren't
  public any more and the disk isn't published; it needs a rebuild on
  b-freebsd15-1r from v2 (`vm/mkdemo.sh 40@freebsd-15.1 b-freebsd15-1r
  bug=388a0de5d fix=00d906b32`), then `LOCAL_TARGETS='freebsd15-1r'`.
- Building FreeBSD disks in CI: GitHub has no FreeBSD runners; a FreeBSD VM
  action (vmactions/freebsd-vm, cross-platform-actions) could run the
  OpenZFS build and makefs, but the GENERIC kernel's module build needs the
  release's /usr/src and takes ~20 min per build in such a VM, so this stays
  local for now: build on the zfs-bug-hunt FreeBSD VMs (vm/mkdemo.sh, public
  commits only), wrap with `scripts/freebsd-image.sh`, check with
  `builder/build.sh check`, push by hand.

## Layer sizes

See [layers.md](layers.md).
