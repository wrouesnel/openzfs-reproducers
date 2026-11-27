# wrouesnel/fix-nfs-reconnect-longname

An NFS client's open file goes stale (`ESTALE`) when the server has to
reconnect the file and the first link it finds has a name longer than
NAME_MAX (255 bytes), although the file has a short name in the same
directory.

- The break: the openzfs/zfs master commit the branch is based on.
- The fix: the head of
  [fix-nfs-reconnect-longname](https://github.com/wrouesnel/zfs/tree/fix-nfs-reconnect-longname),
  which is [openzfs/zfs#19573](https://github.com/openzfs/zfs/pull/19573)
  (directory entry cookies) with the fix stacked on top as its last two
  commits: "ZTS: test reconnecting a file by a name that fits" and "Find a
  name that fits when searching a directory for an object".

## What it shows

With `subtree_check`, knfsd reconnects a file whose dentry it has
reclaimed: it asks the file system for the file's name in its parent
(`zpl_get_name()`), in a buffer of NAME_MAX + 1 bytes. With `longname=on` a
file can have a hard link longer than that. On master `zap_value_search()`
returns `ENAMETOOLONG` for the first entry it finds with the file's object
number and doesn't look further, so nfsd answers `ESTALE` when that entry is
the long link, even though the short one fits. With directory entry cookies
(#19573) the same happens when the cookie names the long link. The fix skips
matches whose names don't fit, and fails only if none does.

## Steps

1. A pool and a dataset with `longname=on`; `docs/report.txt` and a hard
   link to it with a 300-byte name, chosen so that it comes before
   `report.txt` in the directory's order (`ls -f`), the order master's
   search visits entries in.
2. An NFSv3 server on loopback, exported `rw,subtree_check`; the client
   mounts it with `actimeo=0,lookupcache=none`.
3. The client opens `docs/report.txt` and reads it. Once nfsd's file cache
   has let the file go (12 seconds), the server drops its dentry and inode
   caches. The client then stats and reads its open file again, so nfsd has
   to reconnect it.
4. `RESULT BUG` if the client gets `ESTALE`; `RESULT OK` if it reads the
   file. On the fix build the `dirent_name` kstat must show a name lookup,
   or the run is `RESULT ERROR` (the server didn't reconnect).

About 45 seconds per run.

## Results (2026-11-27, ubuntu24 6.8.0-142-generic, published images)

| build | RESULT | client |
|---|---|---|
| master 74215dc630 | `RESULT BUG` 3/3 (`--check`) | `[Errno 116] Stale file handle` |
| fix 0420243a61 | `RESULT OK` 3/3 (`--check`) | fstat and read succeed; `dirent_name`: cookie_hits +2, searches +1 |

The ZTS test on the branch (`exportfs_reconnect_file_longname`) checks the
same through `open_by_handle_at()` of an `AT_HANDLE_CONNECTABLE` handle
(Linux 6.13 and later), and the unit test `zap.zap_value_search_toolong`
checks `zap_value_search()` itself.
