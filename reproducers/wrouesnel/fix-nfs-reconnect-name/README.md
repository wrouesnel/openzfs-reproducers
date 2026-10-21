# wrouesnel/fix-nfs-reconnect-name

A timing demo for [openzfs/zfs#18134](https://github.com/openzfs/zfs/issues/18134)
(and the follow-up on [#16254](https://github.com/openzfs/zfs/issues/16254)):
an NFS server reconnecting many directories of one large ZFS directory at
once.

## What it shows

When nfsd gets a file handle for a directory whose dentry the server has
reclaimed, the kernel reconnects it: it looks for the directory's name in its
parent (`zpl_get_name()` -> `zap_value_search()`), a linear search of the
parent's entries. On master that search walks a ZAP cursor, which takes and
drops the ZAP's and the leaf's rwlocks for every entry, so several nfsd
threads searching the same large directory keep bouncing those locks between
CPUs: each search becomes several times slower and the server spends more CPU
on the same work (the `up_read`/`down_read` profile in #18134). The fix
(`da851ebdca` "Search a ZAP by value one leaf at a time") searches a whole
leaf with the locks taken once. The search is still linear, as it is on ext4;
what goes away is the contention.

The demo (`demo.sh`, helper `nr.py`) is the method of zfs-bug-hunt's
`repros/nfs-reconnect/bench.sh` without bpftrace: everything is measured from
the client and `/proc`.

1. A pool on the run disk; `/exp/big` holds 100,000 empty directories.
2. An NFSv3 server on loopback (`rpcbind`, `rpc.mountd`, `rpc.nfsd`, export
   `no_subtree_check`), mounted with `lookupcache=none,actimeo=0`.
3. Three rounds of two storms of 1000 reconnects each. In a storm the clients
   hold directory fds to 1000 directories spread evenly over `/exp/big`, the
   server drops its caches (`echo 2 > /proc/sys/vm/drop_caches`), then each
   client looks up a name in every directory it holds; every lookup makes
   nfsd reconnect a directory. First 1 client, then 4 clients at once (250
   each) while the server times `mkdir` in `/exp/big`.
4. Each row of the table: clients, reconnects, per reconnect (the median
   lookup time seen by the client), nfsd CPU (utime+stime of the nfsd
   threads), wall time, server-side mkdir median/max (4-client storms), and
   for the 4-client storm the ratio of its per-reconnect time to the 1-client
   storm's of the same round.

## RESULT

`RATIO` is the median of the three rounds' 4:1 ratios. Only ratios from the
same run on the same machine are compared, never absolute times, so the result
doesn't depend on the host's speed.

- `RESULT BUG` if `RATIO >= 1.8`: the concurrent searches slow each other down.
- `RESULT OK` if `RATIO < 1.3`: flat.
- Between them: three more rounds; still between them: `RESULT ERROR`
  (inconclusive).

### Why 1.8 and 1.3

Measured on the ubuntu24 images (6.8.0-142-generic, 6 vCPUs, 4 GiB) on
2026-10-21, on a 12-thread host busy with other builds and VMs (load 5-25):
the 4:1 ratio of each round, and the run's median (the RATIO) after the arrow.

| build | runs |
|---|---|
| repro (master a4d408b087) | 2.59 2.10 2.35 -> 2.35; 3.39 3.59 3.45 -> 3.45; 3.11 3.11 3.07 -> 3.11; 2.89 2.57 2.30 -> 2.57; 2.34 2.34 2.17 -> 2.34; 2.44 2.33 2.87 -> 2.44; 2.37 2.34 2.17 -> 2.34 |
| fixed (762da65a47) | 0.83 0.79 0.87 -> 0.83; 0.74 0.71 0.88 -> 0.74; 0.97 1.03 0.85 -> 0.97; 0.86 0.87 0.85 -> 0.86; 0.85 0.91 1.01 -> 0.91; 0.87 0.88 0.77 -> 0.87; 0.81 1.11 0.78 -> 0.81 |

No round of the break went below 2.10 and no round of the fix above 1.11;
the libvirt VM measurements behind the fix (zfs-bug-hunt
prs/followups-16254.md, release build) gave 2.4x for master and 1.0x for the
fix. 1.8 and 1.3 sit inside that gap with room on both sides for a slower or
noisier host, and the median of three rounds absorbs one disturbed round. On
the fix the 4-client storm is often a little faster per reconnect than the
1-client one.

nfsd CPU for the same work moves the same way (master 2.2-3.2x, fix 0.7-0.8x)
and is printed for information.

### Why a release build

`CONFIGURE='--disable-debug'`. With `--enable-debug` the fixed build's
4-client storm was still 2.5x its 1-client storm (zfs-bug-hunt
vm/nr_fix_dbg.log): debug builds add per-lock bookkeeping that is itself
contended, which hides the difference. Users run release builds.

### Why 6 vCPUs

Four concurrent clients mean four busy nfsd threads plus the clients; with
fewer vCPUs than runnable threads the 4-client storm measures the scheduler,
not the locks.

## The NFS tools

`nfs-kernel-server`, `nfs-common`, `rpcbind` and the libraries the extended
userland lacks (`libwrap0`, `libxml2` and its `libicu74`, most of the demo
disk's 35 MB) come from the Ubuntu snapshot via `EXTRA_PKGS`; the kernel's
`nfsd`/`nfs` modules from the extended base's module tree (`BASE='ext'`).
The demo writes the few files a distribution's packages would
(`/etc/netconfig`, rpcbind's `_rpc` user, `/var/lib/nfs`) and starts the
daemons by hand (no systemd). NFSv4 is off (`-N 4`) and the mount uses
`nolock`, so neither statd nor the v4 grace period is involved.
