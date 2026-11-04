# wrouesnel/fix-resilver-unreadable-dtl-v2

v2 of bug #152 ([openzfs/zfs#19441](https://github.com/openzfs/zfs/issues/19441)):
[fix-resilver-unreadable-dtl-v2](https://github.com/wrouesnel/zfs/tree/fix-resilver-unreadable-dtl-v2)
is `fix-resilver-unreadable-dtl` rebased on openzfs/zfs master 2d1eb9281a.
The rebase changed only the context of the test commit's
`tests/runfiles/common.run` hunk (master added `rebuild_online_leaf` to the
same list); the fix commit has the same patch-id, the code is v1's.
The break is the branch's test commit (the test, no fix), the fix its head.

The demo (`demo.sh`) and its RESULT rules are those of
`wrouesnel/fix-resilver-unreadable-dtl`, unchanged apart from the
build names in a comment.
