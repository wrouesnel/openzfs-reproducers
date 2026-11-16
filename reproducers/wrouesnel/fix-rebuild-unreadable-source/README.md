# wrouesnel/fix-rebuild-unreadable-source

A sequential rebuild ("zpool attach -s" / "zpool replace -s") whose reads of
the old drive fail: on master the mirror falls back to the new drive, which
has no data yet, reads it without a checksum (rebuild reads have none) and,
as a resilver, writes that back over the old drive; the rebuild reports no
errors. Separately, a rebuild that does count errors still empties the new
drive's DTL, so "zpool detach" of the old drive is accepted.

Branch [fix-rebuild-unreadable-source](https://github.com/wrouesnel/zfs/tree/fix-rebuild-unreadable-source)
on openzfs/zfs master c913da8615: a ZTS test (replacement/rebuild_unreadable_source),
then the two fixes (vdev_mirror: no fallback to a child missing the data for a
rebuild read; vdev: no DTL excision after a rebuild with errors).

The demo uses a data drive plus a special drive (so the pool's metadata stays
readable) and makes every read of the data drive fail during the rebuild. The
break is the branch's test commit (master + the test), the fix its head.
