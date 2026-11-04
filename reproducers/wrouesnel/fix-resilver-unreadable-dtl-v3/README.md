# wrouesnel/fix-resilver-unreadable-dtl-v3

v3 of bug #152 ([openzfs/zfs#19441](https://github.com/openzfs/zfs/issues/19441)):
[fix-resilver-unreadable-dtl-v3](https://github.com/wrouesnel/zfs/tree/fix-resilver-unreadable-dtl-v3),
on openzfs/zfs master a99330d3e2. It is v2 (rebased) (`fix-resilver-unreadable-dtl-v2`)
with one change to the fix and one to the test:
- the fix also drops the debug assertion
  `scn_min_txg < vdev_resilver_txg` in `vdev_dtl_should_excise()`, which
  ztest hit once a resilver with errors had left only txgs after the
  attach txg in the new device's DTL (v2 already dropped its partner,
  `vdev_resilver_txg <= scn_max_txg`);
- the ZTS test gains a third case for that state (blocks born just
  after the attach txg unreadable, then `zpool resilver`).

The break is the branch's test commit (the test, no fix), the fix its head.
The demo (`demo.sh`) and its RESULT rules are those of
`wrouesnel/fix-resilver-unreadable-dtl`, unchanged apart from the
build names in a comment.
