# wrouesnel/fix-nfs-reconnect-hint-v4

v4 of the cookie PR ([openzfs/zfs#19573](https://github.com/openzfs/zfs/pull/19573)):
[fix-nfs-reconnect-hint-v4](https://github.com/wrouesnel/zfs/tree/fix-nfs-reconnect-hint-v4)
is v3 rebased on openzfs/zfs master 3028351741. The rebase conflicted only in
`tests/runfiles/common.run` (master added `zfs_rewrite_physical_raw_send` to
the same test list) and in the `.Dd` of `zfs-rewrite.8`; the code is v3's.
The break is the master commit the branch is based on, the fix its head.

The demo (`demo.sh`, `nr.py`) and its RESULT rules are those of
`wrouesnel/fix-nfs-reconnect-hint-v3` (see its README.md), unchanged apart
from the branch name in a comment.
