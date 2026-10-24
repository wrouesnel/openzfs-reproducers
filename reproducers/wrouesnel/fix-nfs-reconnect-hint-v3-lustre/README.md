# wrouesnel/fix-nfs-reconnect-hint-v3-lustre

A compatibility check, not a bug: does the directory entry cookie branch
[fix-nfs-reconnect-hint-v3](https://github.com/wrouesnel/zfs/tree/fix-nfs-reconnect-hint-v3)
([openzfs/zfs#16254](https://github.com/openzfs/zfs/issues/16254)) change
anything for **Lustre's osd-zfs**, an out-of-tree consumer of the ZAP and SA
interfaces? The image runs Lustre's own tests against OpenZFS master (the
commit the branch is based on) and against the branch head, in one VM, and
compares the results. Companions: `wrouesnel/fix-nfs-reconnect-hint-v3` (the
console demo of the cookie) and `wrouesnel/fix-nfs-reconnect-hint-v3-stress`.

```sh
podman run --rm -it --device /dev/kvm ghcr.io/wrouesnel/openzfs-reproducers:fixed-wrouesnel-fix-nfs-reconnect-hint-v3-lustre-almalinux9-5.14.0-687.56.1.el9_8.x86_64
# only some phases (comma separated):
podman run --rm -it --device /dev/kvm -e LUSTRE_TAGS=sanity,lfsck IMAGE
```

Both images (`repro-...` and `fixed-...`) hold **both** builds and run the
same comparison; they differ only in which build the VM boots with before the
demo unloads it. Either one is the whole check.

## What is in the image

- Target `almalinux9` only: kernel 5.14.0-687.56.1.el9_8 (RHEL 9.8; Lustre's
  ChangeLog lists 5.14.0-687.x.el9 as a server kernel), with its full module
  tree (`BASE='ext'`).
- An **AlmaLinux 9 root file system** with what Lustre's test framework
  needs (`payload.sh common`: `dnf --installroot`, EPEL for pdsh and
  dbench). Lustre runs in a chroot of it, on the target's kernel.
- For each build, built on AlmaLinux 9 for that kernel when the image is
  built (`payload.sh repro|fixed`): OpenZFS (release build,
  `--enable-debuginfo`, stripped), and **Lustre master 2.17.60**
  (`v2_17_60`, 6325870717) configured `--enable-server --disable-ldiskfs
  --disable-gss --with-zfs=<that OpenZFS tree>`. osd-zfs has to be built per
  OpenZFS version (its modversions CRCs differ, see `build`). The repro
  payload also has a `--enable-debug` OpenZFS master with Lustre built
  against it, for `debugpanic`.
- Each build's chroot is the AlmaLinux root plus that build's install tree,
  with a writable layer on the run disk; `/tmp` (where the test framework
  puts the targets' file vdevs) is shared, so one build can format and the
  other mount. LNet uses a dummy interface `eth0` (10.0.2.15); the VM has no
  network.

The builds: repro = `https://github.com/openzfs/zfs@merge-base(fix-nfs-reconnect-hint-v3)`,
fixed = `https://github.com/wrouesnel/zfs@fix-nfs-reconnect-hint-v3`,
resolved when the image is built (`--info` and the image labels show the
commits). The Lustre test settings are those of the zfs-bug-hunt spike:
`FSTYPE=zfs MDSCOUNT=1 OSTCOUNT=2 MDSSIZE=1000000 OSTSIZE=2000000`,
`PDSH="pdsh -S -Rexec -w"`, one node (servers and client).

## Phases (LUSTRE_TAGS)

`LUSTRE_TAGS` is a comma separated list of these tags; the default is
`all` = every tag but `debugpanic`. An unknown tag ends in `RESULT ERROR`
with the valid list. The tags that ran are printed before the RESULT.

| tag | what it does, for master and for the branch | compared |
|---|---|---|
| `build` | prints each build's record from image build time: commits, configure, osd_zfs.ko, warnings; diffs Lustre's configure result (config.h `HAVE_*`/`ZFS_*`/`LUSTRE_*`); counts the zfs.ko symbols osd_zfs.ko imports whose modversions CRC differs on the branch (the spike: 32 of 301, dmu_tx_\*, sa_\*, dbuf_\*, zfs_attr_table; no zap_\*) | built, warnings, defines identical |
| `sanity` | `llmount.sh` (format: 1 MDT + 2 OSTs on ZFS pools, mount the client), `zpool status -v`, then `sanity.sh` with `ONLY=` the spike's subset (0-34, 39, 51a/b/d, 54a/c, 56a, 102, 103, 129, 154, 230b/c: about 230 subtests: create, unlink, rename, open-unlink, hard links, large directories, xattrs, ACLs, fid2path/linkEA, directory migration); each test's outcome on the console, the full log on the run disk | PASS/SKIP/FAIL per test identical |
| `lfsck` | `lctl lfsck_start -A -r -t all` (scrub, layout, namespace) on the mounted file system, waits, prints status and repaired counts | status and repaired counts identical |
| `scrub` | after `llmountcleanup.sh`: each pool imported, `zpool status -v`, `zpool scrub -w`, `zpool status -v`, exported, `zdb -b` | 3 pools, 0 scrub errors, no data errors, no leaks, on both |
| `nocookie` | the same pool pass lists, from `zdb -dddd` of each target dataset, every object with a `cookie` line (the branch's zdb prints one for each object that has `ZPL_PARENT_COOKIE`) | the branch: no object with a cookie set (`none` is the ZPL root's placeholder that `zfs create` makes) |
| `cross` | format and fill with one build (3000 files, 200 directories with data and hard links, 100 renames with user xattrs, 100 unlinks, a symlink, a 2-stripe file; lists and md5s), unmount, switch builds, `llmount.sh -n`, compare the tree (type, links, size, path) and every md5, fid2path, an xattr, then rename/link/unlink/create, LFSCK, unmount, the pool pass. master -> branch, branch -> master, and the controls master -> master, branch -> branch | all four pass |
| `debugpanic` | opt-in: `llmount.sh` on a `--enable-debug` build of **master**: the kernel panics at the first target registration, `dirtying dbuf ... but not tx_held` in `dmu_tx_dirty_buf()` from `osd_write()` <- `llog_osd_write_rec()`: Lustre writes an llog block its tx didn't hold, which ZFS_DEBUG checks. Runs after the RESULT line of the other tags; the VM ends in the panic (the launcher prints `PANIC:`). With `LUSTRE_TAGS=debugpanic` alone there is no RESULT line, only the panic (the launcher reports `PANIC:`, and `--check` fails, as expected) | - |

`LUSTRE_ONLY` replaces sanity.sh's `ONLY` list (comma separated, e.g.
`-e LUSTRE_ONLY=24,31,51b`).

`zpool status -v` is printed after each mount (the targets' pools while
Lustre has them), after sanity, and for each pool before and after its
scrub, so the end state of every pool is on the console.

## RESULT

- `RESULT OK`: every phase that ran gives the branch the same outcome as
  master (and `nocookie` finds no Lustre object with a cookie, every `cross`
  combination passes).
- `RESULT BUG`: the branch differs from master; the line names the phases.
- `RESULT ERROR`: master's own baseline failed (its mount, its sanity run,
  its pools, the master -> master cross control), or a bad `LUSTRE_TAGS`.

A sanity test that fails on master as well (on one node some tests can't
pass: the zfs-bug-hunt spike saw 17o, a failover stat, and 154d fail on both
builds) doesn't affect the verdict: only a difference between the builds
does. The comparison lists any test whose outcome differs.

## Sizes and time

`MEM=8192`, `CPUS=6` (the spike used 12 GiB and 8 vCPUs; `-e MEM=... -e
CPUS=...` override them; at least 6 GiB), one 24 GiB sparse run disk.
Default tags, KVM: about an hour (each build's llmount + sanity + LFSCK +
pool pass about 20 minutes, the four cross runs about 5 minutes each);
`TIMEOUT` is 3 hours for a busy host. `-e LUSTRE_TAGS=build` takes under a
minute, `nocookie` (one mount and the pool pass per build) about 5 minutes,
`sanity` alone about 40, `cross` alone about 20. `LUSTRE_ONLY` shortens
sanity. Under TCG it is roughly 10-50x slower.

The image build is long: OpenZFS and Lustre are compiled three times
(master, the branch, master with `--enable-debug`), about 10-20 minutes
each, plus the AlmaLinux root. The demo layer is about 140 MB compressed.

## The scripts

`demo.sh` (the VM side: chroots, module switching, comparison),
`lustre.sh` (inside each chroot: the test framework calls), `payload.sh`
(how the AlmaLinux root, OpenZFS and Lustre were built) and this README are
plain files in the image, `/zfs-repro/repro/files/` (`EXTRACT`). To extract
them without running anything:

```sh
IMG=ghcr.io/wrouesnel/openzfs-reproducers:fixed-wrouesnel-fix-nfs-reconnect-hint-v3-lustre-almalinux9-5.14.0-687.56.1.el9_8.x86_64
mkdir lustre-scripts && podman run --rm --entrypoint tar "$IMG" -C /zfs-repro/repro/files -cf - . | tar -C lustre-scripts -xf -
```

In the VM: `less /demo/demo.sh /demo/lustre.sh /demo/payload/payload.sh`;
the build records are `/demo/payload/almalinux9/{repro,fixed}/build/`.
