# wrouesnel/fix-nfs-reconnect-hint-v6

v6 of [openzfs/zfs#19573](https://github.com/openzfs/zfs/pull/19573)
(directory entry cookies): v3-r1111 (the PR head 56415c63a8) with
@ixhamza's review of 2026-11-26 addressed and the longname fix
(`wrouesnel/fix-nfs-reconnect-longname`) stacked on top, rebased onto
master 3b6d727ddd. `--check` 3/3 each on ubuntu24 at 3e1b13f5ea: master
75.57-91.79x (1M/10k), fix 1.03-1.19x. The break is
the openzfs/zfs master commit the branch is based on, the fix its head.

The demo is the v3 one (`wrouesnel/fix-nfs-reconnect-hint-v3`, which
explains what it shows), unchanged: reconnecting NFS directories by file
handle costs the same in a directory of any size with the cookie, and grows
with the directory on master.
