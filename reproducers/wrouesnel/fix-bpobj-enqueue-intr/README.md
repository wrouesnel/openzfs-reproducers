# wrouesnel/fix-bpobj-enqueue-intr

Bug #278 ([openzfs/zfs#19945](https://github.com/openzfs/zfs/issues/19945),
reported by @ahrens from code reading): overwriting a cloned, dedup or gang
block makes the zio write-done (`z_wr_int`) thread read the pool's free
bpobj.

Since 46c4f2ce0b ([#16722](https://github.com/openzfs/zfs/pull/16722))
`dsl_dataset_block_kill()` puts such blocks on the free bpobj with
`bpobj_enqueue()` even when it is called from a write-done callback
(`dbuf_write_done()`, async). When the bpobj's last block isn't cached,
`bpobj_enqueue()` reads it there, and every write completion on that taskq
(the ZIL's too) waits for the read. With one `z_wr_int` thread and
`zfs_vdev_max_active=1` the read is never issued, because the vdev's only
slot is held by a write whose completion is queued behind the waiting
thread, and the txg never syncs. The fix
([fix-bpobj-enqueue-intr](https://github.com/wrouesnel/zfs/tree/fix-bpobj-enqueue-intr))
defers these enqueues to the txg sync (`dsl_dataset_sync_done()`), as the
deadlist case next to it already does.

The demo, for each kind of block (clone, dedup, gang): a pool with one
`z_wr_int` thread, a free bpobj filled with its processing off
(`zfs_free_bpobj_enabled=0`), an export and import so the bpobj isn't
cached, then `zfs_vdev_max_active=1`, writes delayed 100 ms, an overwrite of
64 blocks and a `zpool sync` given 45 s, with `zpool status -v` after each
step. The break shows the sync still waiting and the `z_wr_int` stack
(`bpobj_enqueue -> dmu_buf_hold -> dbuf_read -> zio_wait`), then restarts
the queue with a read that misses the ARC; the fix syncs in seconds. Both
then process the free bpobj and check freed space, data and a scrub.

The branch has three commits on openzfs/zfs master cde5d598eb: a
prerequisite (`zfs_free_bpobj_enabled=0` no longer treats the free bpobj as
finished), the ZTS test, the fix. The break is `BRANCH~1`, the fix the head.
