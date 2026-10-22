# wrouesnel/fix-nfs-reconnect-hint

A timing and correctness demo for the directory entry cookie
(`SA_ZPL_PARENT_COOKIE`) proposed on
[openzfs/zfs#16254](https://github.com/openzfs/zfs/issues/16254) (and
[#18134](https://github.com/openzfs/zfs/issues/18134)): reconnecting NFS
directories costs the same in any directory size.

**Private until the user's review**: the branch is only on the private
Forgejo backup, so `REPO` and `BUILD_fixed` point there; both become
`https://github.com/wrouesnel/zfs` when the branch is published.

## What it shows

When nfsd gets a file handle for a directory whose dentry the server has
reclaimed, the kernel reconnects it by asking the file system for the
directory's name in its parent (`zpl_get_name()`). On master that is
`zap_value_search()`, a search of the parent's entries, so each reconnect
costs time proportional to the parent's size (about 100 ms per reconnect
at 1M entries). The branch (on top of `fix-nfs-reconnect-name`) records in
each object the cookie of the directory entry that last linked it into its
parent (`ZPL_PARENT_COOKIE`, written with `ZPL_PARENT` in the same SA
update); `zfs_dirent_name()` looks up that one entry, checks that its value
is the object, and searches only when it isn't. zdb prints the cookie as a
new `cookie` line.

The demo (`demo.sh`, helper `nr.py`) measures everything from the NFS client
and `/proc`, as `wrouesnel/fix-nfs-reconnect-name` does:

1. A pool on the run disk; `/exp` holds three directories of 10,000, 100,000
   and 1,000,000 entries: 400 directories spread evenly over each, the rest
   empty files (the directory's size is what the search walks; files are
   cheaper to create).
2. An NFSv3 server on loopback, mounted with `lookupcache=none,actimeo=0`.
3. **Scaling**: in each directory a storm of 400 reconnects from 1 client,
   then the same 400 from 4 clients at once (the server drops its dentry and
   inode caches before each storm). The table shows per reconnect (median
   client lookup), p90, nfsd CPU, wall time, and `x smallest`: per reconnect
   divided by the same client count's value in the 10,000-entry directory.
4. **Correctness**, in `/exp/c` and the big directories: a directory never
   renamed, a rename into another directory, a rename within a directory, a
   `RENAME_EXCHANGE` (renameat2) between two directories, moves out of the
   100,000-entry and within the 1,000,000-entry directory, a hard link (the
   parent and the cookie follow the newest link), and a stale cookie: a link
   `a/f2-tmp` of `a/f2` made and removed, then a new file named `a/f2-tmp`,
   so `a/f2`'s cookie names an entry that now holds another object (the same
   hash and collision differentiator, so the same cookie: zdb shows `a/f2`
   and `a/f2-tmp` with the same cookie). For each object: zdb's `path`
   (`zfs_obj_to_path()` in libzpool) and `cookie`; for each directory also
   the path the server kernel reconnects for its file handle
   (`name_to_handle_at`, cache drop, `open_by_handle_at`, `/proc/self/fd`)
   and the NFS client's view (the `id` file read through a directory fd held
   across a server cache drop). Every path must be right on both builds; on
   master the `cookie` column is `-` (zdb has no such line).

## RESULT

`R1` and `R4` = per reconnect in the 1,000,000-entry directory / in the
10,000-entry one, for 1 client and for 4 clients. Only ratios from the same
run are compared, never absolute times.

- `RESULT BUG` if `R1 >= 10` and `R4 >= 10`: reconnects grow with the directory.
- `RESULT OK` if `R1 < 3` and `R4 < 3`, and every path is right.
- Otherwise the scaling step runs once more; still in between: `RESULT ERROR`.
- Any wrong path: `RESULT ERROR` on either build (master is slow, not
  wrong; a wrong path on the fixed build would be a bug in the change).

### Why 10 and 3

Measured on the ubuntu24 images (6.8.0-142-generic, 6 vCPUs, 8 GiB) on
2026-10-22, on a 12-thread host also running a FreeBSD ZTS VM and other
sessions' VMs (load 10-12):

| build | R1 / R4 per run |
|---|---|
| repro (master a4d408b087) | 100.8/116.3, 87.3/80.4, 59.3/60.3, 64.7/112.6, 94.7/110.8, 78.0/62.4, 74.9/101.3, 59.5/99.0, 118.8/108.1, 82.2/99.9 |
| fixed (ebec825938) | 0.96/0.86, 1.15/1.96 then 1.94/0.86, 0.77/1.44, 1.01/0.95, 1.16/1.11, 1.02/1.40, 0.87/1.14, 0.91/1.22, 0.89/0.92, 0.59/1.16 |

master's per reconnect grows with N as the search predicts (10k -> 100k
about 7-10x, 100k -> 1M about 10-14x): 59x to 119x from 10k to 1M. With the
cookie it is flat: one entry lookup, the rest is the NFS round trip and the
handle decode. But a fixed-build reconnect is only 0.3-0.9 ms, and on a busy
host its median flips between a ~0.3 ms and a ~0.6 ms mode independently of
the directory size, so a single storm's ratio ranges 0.59x-1.96x (the
second fixed run above measured 1.15/1.96 and then 1.94/0.86, which with a
first threshold of 1.5 was inconclusive twice: that is why OK is < 3, not
1.5). 3 is 1.5x above the worst fixed ratio seen; 10 is 6x below the lowest
master ratio, and still above the 7-10x master shows for a single factor of
10 in N. The 10 + 10 runs above, in order: the first pair (before a zdb
verbosity fix, so its paths were not printed; its ratios are valid), three
`--check` pairs with the first thresholds (5 and 1.5), three with the final
ones, and the `--check` 3/3 of the final images (whose demo.sh differs only
in a comment).

### Why these sizes

10k, 100k and 1M keep the whole run at about 2.5-3 minutes on master (the
1M storms take about 43 s and 32 s) and about 1-1.5 minutes with the cookie;
creating the 1.11M entries takes about 45 s. 400 reconnects per storm give
a stable median (100 per client with 4 clients).

### Why a release build, 6 vCPUs, the NFS tools

As `wrouesnel/fix-nfs-reconnect-name`: `CONFIGURE='--disable-debug'`
(debug builds add contended lock bookkeeping), 6 vCPUs for 4 clients plus
their nfsd threads, and the NFS server and client from `EXTRA_PKGS` with
the kernel's nfsd/nfs modules from the extended base (`BASE='ext'`, which
also has python3 with ctypes for renameat2 and the file handle calls).
`MEM=8192` keeps the 1.11M entries in the ARC.
