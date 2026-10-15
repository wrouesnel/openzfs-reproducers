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
| wrouesnel/fix-dyn-gang-header-import | PR #19314, issue #19189 | test cf9719c6e | head d60260002 | 40 (Linux port + FreeBSD 15.1 disk) |
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
| wrouesnel/fix-mmp-first-txg-delay | none yet | test 378bf65ec | head 6a84e6765 | 138 |
| tigerblue77/zvol-rename-uevent | PR #19377 (@tigerblue77), issue #19371 | master c27dff0c3 | head 5c845323e | 129 (ours; the fix is theirs) |
| wrouesnel/selftest-triggers | (self-test, ubuntu24 only) | master b060bcb1d | none | - |

The test-only fixes (`fix-zts-*`) carry the affected ZTS test of each build
in the demo disk (`zts/repro/`, `zts/fixed/`) with a small stand-in for the
ZTS library, and the ZTS helpers they need come with the build (`TOOLS`).
The ZFS code of both builds is the same; the demo shows the test failing on
the break and passing with the fix, several times per run.

## Public fix branches without a demo yet

These are on github.com/wrouesnel/zfs and qualify, but there is no console
demo to port (zfs-bug-hunt has none, or it needs more than the userland has):

- fix-remove-resilvering-mirror (PR #19278): the demo (bug 1) answers a
  review question (DTL_PARTIAL vs ours) and has no break/fix pair; a demo of
  the bug itself is still to write.
- zts-import-rewind-ckpt-txg (#136, flake 13/200), fix-zts-mmp-zhack-import-wait
  (#138's test race): flake fixes; the tests need most of the ZTS library
  (`import_rewind_metadata_damaged`, `mmp_active_import`), so a stand-in demo
  is still to write. With `--runs` and `RUNS_repro`/`MIN_MATCH_repro=1` they
  fit the flake format.
- fix-zarcsummary-connreset (bug 124): its demo runs python3 (zarcsummary),
  which the userland doesn't have.
- fix-readonly-export-busy (bug 121): the demo is FreeBSD's; needs a FreeBSD
  build of the fork head.
- The other public fix-* and fix-zts-* branches (about 70) have no console
  demo in zfs-bug-hunt; their ZTS tests are their reproducers.

## Ready once on the fork

These branches are only in the local backup (~/git/will/zfs.git), so they
can't be built here yet; each has a demo in zfs-bug-hunt:

- fix-zed-events-eintr (bug 135, upstream #14720): demo repros/135/vm.
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
  on b-freebsd15-1r from the PR commits (cf9719c6e, d60260002), checked
  locally: repro RESULT BUG (+ inspect BUG), fixed RESULT OK (+ inspect OK).
- Building FreeBSD disks in CI: GitHub has no FreeBSD runners; a FreeBSD VM
  action (vmactions/freebsd-vm, cross-platform-actions) could run the
  OpenZFS build and makefs, but the GENERIC kernel's module build needs the
  release's /usr/src and takes ~20 min per build in such a VM, so this stays
  local for now: build on the zfs-bug-hunt FreeBSD VMs (vm/mkdemo.sh, public
  commits only), wrap with `scripts/freebsd-image.sh`, check with
  `builder/build.sh check`, push by hand.

## Layer sizes

See [layers.md](layers.md).
