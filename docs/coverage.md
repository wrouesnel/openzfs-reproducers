# Coverage: our fix branches and their reproducers

Every fix branch of ours that zfs-bug-hunt tracks (its BUGS.md, or the
#19341 CI-flake table) and that is public on github.com/wrouesnel/zfs gets
a reproducer, `reproducers/wrouesnel/<branch>/`, with `repro-` and `fixed-`
images. A new branch on the fork gets one when it is pushed:
`scripts/new-reproducer.sh BRANCH` (see reproducer-format.md, "Adding a
reproducer"). This table is the inventory as of 2026-10-17; the per-target
outcomes of the published images are on the `results` branch.

Counts (2026-10-17): 94 fix branches eligible: 19 had a reproducer, 51 added now (all checked on ubuntu24), 24 blocked (14 of them with a reproducer kept out of CI by `BLOCKED`); 31 branches excluded (below; with master, the 126 branches of the fork).

Kind: *ZTS test* runs the branch's ZTS test(s) (`KIND=zts`); *console demo* is a
hand-written demo.sh. An "ubuntu24:" note means `builder/build.sh all ID ubuntu24`
printed the expected RESULT for both images on this machine.

| branch | bug (zfs-bug-hunt) | upstream | kind | status | notes |
|---|---|---|---|---|---|
| fix-dio-nopwrite-freed | #57 | PR #19336 (open) | console demo | has reproducer |  |
| fix-dos-readonly-open | #39 | PR #19313 (open) | console demo | has reproducer |  |
| fix-dyn-gang-header-import | #40 | PR #19314 (open) | console demo | has reproducer |  |
| fix-dyn-gang-header-import-v2 |  |  |  | has reproducer | the same commits as fix-dyn-gang-header-import (388a0de5d, 00d906b32): that reproducer covers it |
| fix-hasrecvd-spa-open | #32 | PR #19306 (open) | console demo | has reproducer |  |
| fix-mmap-eof-extend | #27 | PR #19267 (open) | console demo | has reproducer |  |
| fix-mmp-first-txg-delay |  |  | console demo | has reproducer |  |
| fix-partial-read-redirty | #22 | PR #19299 (open) | console demo | has reproducer |  |
| fix-partial-read-redirty-v2 |  |  | console demo | has reproducer |  |
| fix-raw-send-redact-bookmark-eacces | #70 |  | console demo | has reproducer |  |
| fix-resilver-detached-target | #69 |  | console demo | has reproducer |  |
| fix-scrub-heal-stale-child-v2 | #127 |  | console demo | has reproducer |  |
| fix-snapdir-expire-stat | #62 |  | console demo | has reproducer |  |
| fix-zed-solved-case-peers | #72 |  | console demo | has reproducer |  |
| fix-zts-auto-replace-fill | #71 |  | console demo | has reproducer |  |
| fix-zts-crtime-001-flake | #120 |  | console demo | has reproducer |  |
| fix-zts-dbufstats-mfu | #81 |  | console demo | has reproducer |  |
| fix-zts-import-parallel-admin | #125 |  | console demo | has reproducer |  |
| fix-zts-refreserv-004 | #74 |  | console demo | has reproducer |  |
| fix-alloc-class-fallback-loop | #29 | PR #19304 (closed) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-brt-checkpoint-free | #38 | PR #19312 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-brt-unload-stale-vdevs | #44 | PR #19318 (open) | ZTS test | added now | ubuntu24: repro PANIC, fixed OK |
| fix-claim-txg-import-T | #42 | PR #19317 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-corrective-recv-bp-copy | #23 |  | ZTS test | added now | ubuntu24: repro PANIC, fixed OK |
| fix-corrective-recv-recompress | #4 | PR #19281 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-ddt-override-copies | #28 | PR #19303 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-ddt-repair-entry-done | #25 | PR #19301 (open) | ZTS test | added now | ubuntu24: repro PANIC, fixed OK |
| fix-degraded-single-vdev-gang | #61 | PR #19351 (closed) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-dio-nopwrite-checksum-assert | #59 | PR #19335 (closed) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-errlog-list-io-deadlock | #56 | PR #19337 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-errorscrub-cursor-export | #5 | PR #19282 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-history-log-suspended | #63 |  | ZTS test | added now | ubuntu24: repro BUG, fixed OK (the fixed build failed 1 of 3 local runs: the pool suspended before `zpool set`'s own sync, a race in the test) |
| fix-import-reguid-paths | #41 | PR #19316 (closed) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-invalid-bp-free | #26 | PR #19302 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-l2arc-read-done-size | #24 | PR #19300 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-metaslab-verify-weight-race | #16 | PR #19325 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-mmp-suspend-txg-spin | #134 |  | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-raidz-expand-old-rows-recon | #73, #111, #137 |  | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-raidz-expand-replace-min-asize | #2 | PR #19279 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-raidz-expand-replace-min-asize-v2 |  |  | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-raw-send-fs-ivset | #36 | PR #19310 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-readonly-export-busy | #121 |  | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-rebuild-sm-load-deadlock | #141 |  | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-recv-embedded-blksz | #3 | PR #19280 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-recv-keylocation-missing | #35 | PR #19309 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-recv-promote-origin-lookup | #34 | PR #19308 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-removal-sm-load-deadlock-v2 | flake table #52 | PR #19332 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-removal-sm-load-deadlock-v3 | flake table #52 | PR #19332 (review follow-up; not its head yet) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-remove-resilvering-mirror | #1 | PR #19278 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-rewind-no-self-heal | #64 | PR #19353 (closed) | ZTS test | blocked | test passes on the break in the guest (127 dry runs, 0 sectors changed) (reproducer kept, left out of CI: BLOCKED) |
| fix-snapdir-readdir-ino | #11 | PR #19286 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-snapdir-stale-dentry | #10 | PR #19285 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-userquota-id-parse | #13 | PR #19292 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zap-shrink-prefix-diff | #17 | PR #19326 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zarcsummary-connreset | #124 |  | console demo | added now | ubuntu24: repro BUG, fixed OK |
| fix-zcp-clone-namecheck | #37 | PR #19311 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zcp-snapshot-namecheck | #33 | PR #19307 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zed-events-eintr | #135 | issue #14720 | console demo | added now | ubuntu24: repro BUG, fixed OK |
| fix-zed-retire-leaks | #18 | PR #19333 (open) | ZTS test | blocked | the test needs valgrind (Ubuntu’s package is about 80 MB) to see the leaks (reproducer kept, left out of CI: BLOCKED) |
| fix-zfs-bookmark-recursive-target | #14 | PR #19298 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zfs-vget-snapshot-ctldir | #6 | PR #19290 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zil-crash-keep-first | #46 | PR #19320 (closed) | ZTS test | blocked | the test needs the scsi_debug module; the targets’ kernels carry no module tree (reproducer kept, left out of CI: BLOCKED) |
| fix-zil-crash-stale-header | #126 |  | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zil-dmu-sync-alloc-hole | #58 | PR #19334 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zoned-uid-prop | #12 | PR #19297 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zpl-fadvise-zos | #30 | PR #19305 (open) | ZTS test | added now | ubuntu24: repro PANIC, fixed OK |
| fix-zpool-add-bias-replication | #9 | PR #19288 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zpool-status-errlog-output | #15 | PR #19293 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zstream-decompress-uncompressed | #8 | PR #19289 (open) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zstream-raw-free-ordering | #7 | PR #19284 (open) | ZTS test | blocked | the test’s step 5 makes the incremental stream free 0..16 GiB, and zstream raw zero-fills all of it (zfs-bug-hunt #148), filling the 16G run disk; the short write at ENOSPC then trips a VERIFY (#147). Same on both builds and master. Blocked until the branch carries the #148 fix or its test avoids an all-hole volume (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-autotrim-config-wait | #82 |  | ZTS test | blocked | a CI-load flake (#82: fedora43, almalinux8, ubuntu26 under load); passes on ubuntu24 here, as in zfs-bug-hunt’s 30 local runs (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-dev-removal-condense | #49 | PR #19291 (merged) | ZTS test | blocked | a flake (#49: 20 in 100 runs in zfs-bug-hunt’s VMs); 0 failures in 15 runs with 2 vCPUs and 20 with 8 on ubuntu24 here (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-dio-read-verify-decline | #80 |  | ZTS test | blocked | a CI-load flake (#80: 1 in 20 runs with 4 CPU hogs); 0 failures in 20 runs with 8 vCPUs on ubuntu24 here (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-errata3-busy | #130 |  | ZTS test | blocked | the flake needs udev’s watch rule opening the zvol after dd (#130); the demo VM has no udev (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-l2arc-dwpd-reimport-lowmem | flake table #54 | PR #19339 (merged) | ZTS test | blocked | a FreeBSD low-memory flake (flake table #54); passes on ubuntu24; FreeBSD ZTS images aren’t built yet (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-l2arc-l2miss-order | flake table #53 | PR #19338 (merged) | ZTS test | blocked | a FreeBSD flake (flake table #53); passes on ubuntu24; FreeBSD ZTS images aren’t built yet (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-mmp-zhack-import-wait | #138 |  | ZTS test | blocked | a race seen 1 in 20 runs under CPU load (#138), 4 minutes a run; passes on ubuntu24 (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-redacted-resume-cut | #132 |  | ZTS test | blocked | a flake (#132: about 1 in 4 in zfs-bug-hunt’s runs); 0 failures in 12 runs with 2 vCPUs and 20 with 8 on ubuntu24 here (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-rewind-draid-spare | #43 | PR #19287 (merged) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zts-snapshot-tar-root-mtime | flake table #51 | PR #19331 (merged) | ZTS test | blocked | FreeBSD bsdtar behaviour (flake table #51); GNU tar passes on ubuntu24; FreeBSD ZTS images aren’t built yet (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-zpool-wait-scan-txg | flake table #55 | PR #19340 (merged) | ZTS test | blocked | a FreeBSD flake (flake table #55); passes on ubuntu24; FreeBSD ZTS images aren’t built yet (reproducer kept, left out of CI: BLOCKED) |
| fix-zts-zstream-raw-001-cleanup | #20 | PR #19283 (merged) | ZTS test | added now | ubuntu24: repro BUG, fixed OK |
| fix-zvol-set-removing | #45 | PR #19319 (open) | ZTS test | added now | ubuntu24: repro PANIC, fixed OK |
| zts-import-rewind-ckpt-txg | #136 |  | ZTS test | added now | ubuntu24 with 8 vCPUs: repro BUG (5+ of 60 runs), fixed OK (60 of 60) |
| fix-corrective-recv-abd-lifetime | #21 | PR #19323 (open) |  | blocked | single fix commit, no test and no console demo (#21): needs a hand-written demo |
| fix-initramfs-libcurl-symlink | #67 |  |  | blocked | the test runs mkinitramfs with the build's initramfs-tools hook: needs a Debian/Ubuntu root with initramfs-tools, klibc and a kernel module tree, and the hook installed from the build; beyond the userland (a special userland is still to do) |
| fix-pyzfs-tempool-cleanup |  | PR #19327 (merged) |  | blocked | single fix commit (merged as #19327) to pyzfs's test cleanup; pyzfs needs Python bindings the userland lacks |
| fix-spl-cache-destroy-rcu | #47 |  |  | blocked | single fix commit, no test (#47: the race is in module unload, which ZTS can't drive); needs a hand-written demo |
| fix-zed-timer-uaf | #133 |  |  | blocked | single fix commit, no test (#133); needs a zed demo (use-after-free in a timer) |
| fix-zstd-dctx-overflow-type | #31 |  |  | blocked | single fix commit, no test (#31, a type change); no observable demo yet |
| fix-zstream-raw-blksszget | #19 | PR #19324 (open) |  | blocked | single fix commit, no test (#19); needs a hand-written demo |
| fix-zts-destroy-pool-root |  |  |  | blocked | libtest destroy_pool() one-liner; no test in the branch shows it (a pool mounted on /); needs a hand-written demo |
| fix-zts-share-011-mountd | #131 |  |  | blocked | FreeBSD-only (mountd reload in is_shared); FreeBSD ZTS images aren't built yet |
| zts-destroy-pool-root-mtpt | #60 | PR #19342 (merged) |  | blocked | merged (#19342); libtest one-liner, no test in the branch shows it; needs a hand-written demo |

## Not eligible

| branch | why |
|---|---|
| changed-tests-demo | CI workflow demo (fail-first CI), no ZFS fix |
| ci-changed-tests | CI workflow branch, no ZFS fix |
| ci-failfirst | CI workflow (merged as #19270), no ZFS fix |
| ci-failfirst-demo | CI workflow demo; its fix is fix-mmap-eof-extend's, covered there |
| ci-freebsd-no-periodic | CI workflow change (#83), no ZFS fix |
| ci-precheck-gate | CI workflow branch, no ZFS fix |
| ci-precheck-gating | CI workflow branch, no ZFS fix |
| ci-reuse-search | CI workflow branch (upstream CI reuse), no ZFS fix |
| ci-reuse-search-19412 | CI workflow branch (upstream CI reuse), no ZFS fix |
| ci-reuse-search-runs | CI workflow branch, no ZFS fix |
| ci-s390x-userspace | CI workflow branch, no ZFS fix |
| ci-s390x-userspace-fix19 | CI workflow branch, no ZFS fix |
| dedup-aware-send | feature prototype (send WRITE_BYREF/WRITE_DELTA), not a bug fix, not tracked |
| fix-removal-sm-load-deadlock | v1, superseded by fix-removal-sm-load-deadlock-v2 (PR #19332); a single code commit without a test |
| gate-demo-bad | CI gate demo (deliberately bad PR), not a fix |
| gate-demo-good | CI gate demo, not a fix |
| issue19144-repro | stress workload for upstream issue #19144, no fix |
| issue19197-repro | reproduction branch for upstream issue #19197, no fix |
| issue19215-repro | reproduction for #19215; the fix is fix-snapdir-expire-stat, covered |
| pr19262-review-repros | review of @rdmitry0911's PR #19262 (not our fix) |
| pr19262-zts | review of PR #19262 (not our fix) |
| pr19262-zts-r4 | review of PR #19262 (not our fix) |
| pr19262-zts-r5 | review of PR #19262 (not our fix) |
| send-delta-index | feature work (zfs send --refs/--delta), not a bug fix |
| send-refs-delta-2.4.4 | feature work on 2.4.4, not a bug fix |
| send-refs-delta-master | feature work (zfs send --refs/--delta), not a bug fix |
| zdb-delta-estimate | feature work, not a bug fix |
| zstream-resume-2.4.4 | feature on 2.4.4, not a bug fix |
| zstream_resume | feature (zstream resume), not a bug fix |
| zts-pr19046-selfwrite | our ZTS tests for @gmelikov's and @nexicturbo's fix commits (PR #19046 review); the fix isn't ours |
| zts-pr19315-readonly | our test for @peturingi's PR #19315 (review); the fix isn't ours |
