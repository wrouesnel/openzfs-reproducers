# wrouesnel/fix-zts-mmp-suspend-hang

Bug #274, a ZTS test bug: `mmp/mmp_on_off` runs with
`zfs_multihost_interval=100` and the default 10 fail intervals, so one MMP
write slower than 1 s suspends its pool. A pool suspended by MMP can't be
cleared on its own host ([openzfs/zfs#19033](https://github.com/openzfs/zfs/issues/19033)),
so the test's cleanup fails at `zpool clear` and leaves the suspended pool
imported. In fork CI the next mmp tests then failed, and `mmp_on_zdb`'s
cleanup destroyed the pool, whose unmount waited forever: the job ran into its
300-minute limit.

The image runs `mmp_on_off` as the ZTS runner does (KIND=zts), with
`inject_mmp_delay.sh` beside it (started by `prep.sh`): once MMP writes to
the pool, every write to its disk is delayed 1.5 s for 3 s, the stall CI hit.

- repro (master's test): the cleanup's `zpool clear` is refused, the test
  FAILs, and the pool is left SUSPENDED.
- fixed ([fix-zts-mmp-suspend-hang](https://github.com/wrouesnel/zfs/tree/fix-zts-mmp-suspend-hang)):
  the test sets `zfs_multihost_fail_intervals=0`, the stall doesn't suspend
  the pool, it is ONLINE at the end, and nothing is left imported.
