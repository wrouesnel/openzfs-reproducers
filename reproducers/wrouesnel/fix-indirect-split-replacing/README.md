# wrouesnel/fix-indirect-split-replacing

Bug #265: [fix-indirect-split-replacing](https://github.com/wrouesnel/zfs/tree/fix-indirect-split-replacing),
on openzfs/zfs master 1e6c7a1d42. Found by zloop in our fork's CI
([job 130025330429](https://github.com/wrouesnel/zfs/actions/runs/42871997209/job/130025330429)).

After a top-level vdev is removed, a block can sit on its new vdev in several
segments. A scrub of such a split block reads every copy of every segment and
tries combinations until one matches the block's checksum. Only the children
of a mirror count as copies: a `spare` or `replacing` vdev under the mirror is
one copy, and when its old and new device differ, reading it returns a
checksum error. So a good copy on the old device is never used, the scrub
reports a permanent error, and a replace that finishes then detaches the only
device holding the block.

The demo builds that state deterministically with a hot spare: the file's
first block is split into 4 or 5 segments on mirror-1 (`spare-0` = b0 + the
spare, and b1), and the block is zeroed on the spare and on b1, so b0 holds
the only good copy. Master's scrub reports a permanent error, b0 alone still
reads the file correctly, and after `zpool detach b0` (what a finished
replace does) the file is lost. The fix's scrub repairs the block from b0,
with checksum errors only on the two damaged devices, and the file survives
the detach.

The break is the branch's test commit (master + the ZTS test
removal_split_spare_repair), the fix its head.
