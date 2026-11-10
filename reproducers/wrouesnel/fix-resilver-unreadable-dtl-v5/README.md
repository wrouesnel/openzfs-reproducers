# wrouesnel/fix-resilver-unreadable-dtl-v5

v5 of bug #152 ([openzfs/zfs#19441](https://github.com/openzfs/zfs/issues/19441)):
[fix-resilver-unreadable-dtl-v5](https://github.com/wrouesnel/zfs/tree/fix-resilver-unreadable-dtl-v5),
on openzfs/zfs master 74215dc630.

v3 kept unreadable blocks in the new device's DTL (so the old device stays
required), but that also held every replacement of a dead drive whose mirror
had an unreadable block. v5 lets a replacement complete when the old device
is gone (missing or removed) or misses those blocks too, as master does, and
keeps a faulted or offline old device that may still hold them. `zpool status`
then explains the held replacement (new status/action, the device marked
"(may hold missing data)"); `zpool clear` / `zpool online` lets the resilver
copy the data from it, `zpool detach` gives it up.

The demo shows the case that matters most: a mirror whose surviving disk has
three damaged blocks, and the old disk faulted but still attached. Master
detaches it and loses the three files; the fix holds the replacement, and
`zpool clear` recovers them. A second part replaces a dead (missing) disk the
same way, which completes on both builds.

The break is the branch's test commit (master + the ZTS tests), the fix its head.
