# wrouesnel/fix-nfs-reconnect-hint-v6

v6 of [openzfs/zfs#19573](https://github.com/openzfs/zfs/pull/19573)
(directory entry cookies): v3-r1111 (the PR head 56415c63a8, on master
74215dc630), with @ixhamza's review of 2026-11-26 addressed and the longname
fix (`wrouesnel/fix-nfs-reconnect-longname`) stacked on top. The break is
the openzfs/zfs master commit the branch is based on, the fix its head.

The demo is the v3 one (`wrouesnel/fix-nfs-reconnect-hint-v3`, which
explains what it shows), unchanged: reconnecting NFS directories by file
handle costs the same in a directory of any size with the cookie, and grows
with the directory on master.
