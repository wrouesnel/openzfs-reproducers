# wrouesnel/fix-nfs-reconnect-hint-v3-stress

The stress suite of the directory entry cookie PR, v3
([openzfs/zfs#16254](https://github.com/openzfs/zfs/issues/16254),
[#18134](https://github.com/openzfs/zfs/issues/18134); branch
[fix-nfs-reconnect-hint-v3](https://github.com/wrouesnel/zfs/tree/fix-nfs-reconnect-hint-v3)),
as an image that re-runs it on the PR head. It is not a bug reproducer:
`wrouesnel/fix-nfs-reconnect-hint-v3` is the bug/fix pair (reconnect
scaling and correctness, master against the branch). This image holds only
the branch head (`fixed-`), a **debug build** (`--enable-debug`, assertions
on) as the original testing ran, and expects `RESULT OK`.

```sh
podman run --rm -it --device /dev/kvm ghcr.io/wrouesnel/openzfs-reproducers:fixed-wrouesnel-fix-nfs-reconnect-hint-v3-stress-ubuntu24-6.8.0-142-generic
```

At the VM's prompt, Up, Enter runs the suite. `--check` runs it without a
terminal and exits 0 on `RESULT OK`.

## The tests

Select them with `STRESS_TAGS` (comma separated; default `all`, which runs
every test in this order):

| tag | what it checks |
|---|---|
| `churn` | 4 threads create, unlink, rename (within and across directories), hard link and rename over entries while 2 threads drop the dentry cache and reopen 250 held directories by file handle: no wrong name, no error, at least 95% of names found by cookie, searches only for stale cookies; then every object's zdb path and cookie, 25 directories by handle with no search |
| `zapshape` | one directory grows from 40 entries (microzap) to 2,100 (fat ZAP) to 100,000 and 400,000 (leaf splits, pointer table growth), then 20,000 entries are removed and 20,000 new names added: the first 40 entries' cookies stay valid, and their names are found by cookie with no search |
| `norm` | 8 datasets (casesensitivity sensitive, insensitive, mixed, mixed + formD; normalization formD, formC, formKC + insensitive; utf8only) with colliding and Unicode-variant names (`Foo`/`foo`/`FOO`, `été` composed and decomposed, `Straße`/`STRASSE`, `Å` three ways, the `ﬁ` ligature), in a microzap and a fat ZAP: every cookie valid, exact names (bytes) from reconnect |
| `links` | 300 files with 3,000 random hard link/unlink operations, 50 renames over existing files, a rename over an empty directory, rmdir and re-create of a parent, `xattr=on` xattr directories: zdb paths right, cookies valid or stale (never inconsistent), reconnects exact |
| `sendrecv` | full, `-c`, `-L`, `-c -L` and raw `-w` (encrypted) streams, then incrementals after renames: the received cookie states equal the source's (valid, stale, none), reconnects right; `zfs rewrite -N -r` on the receiver makes every cookie valid; a clone with a rename; a rollback |
| `spill` | `xattr=sa` with legacy, 1k and auto dnodes, 800 files, 4,000 random xattr set/remove/rename operations, then `zfs rewrite -N -r`: no object inconsistent; only objects whose other attributes fill the bonus buffer lack the cookie (the cookie never causes a spill block) |
| `longname` | `longname=on`, a 300-byte directory name: reconnect gives `ESTALE`/`ENAMETOOLONG` (the kernel's get_name buffer is 256 bytes; master's search gives `ESTALE` too) with no search; a short name is exact |
| `ctldir` | `.zfs/snapshot` directories reopened by file handle: exact paths |
| `perm` | `zfs rewrite -N` as uid 4242 (`setpriv`): `EACCES` on root's 0755 directory and 0644 file, whose cookies stay `none`; its own directory recorded (`valid`); root succeeds; `EROFS` on a read-only file system |

Every test creates its own pool on the run disk (and destroys it; the last
test exports it, so `--disk` can inspect it), prints a `CHECK <test>
PASS|FAIL ...` line per check, and ends with `zdb -b` (leak check), `zpool
scrub -w` and `zpool status -v`. After all of them the demo prints one
`SECTION` line per test (checks, failures, seconds), the tags that ran, and

- `RESULT OK: N checks passed (...)`: every check of every selected test passed;
- `RESULT BUG: F of N checks failed`, with the first failures;
- `RESULT ERROR: ...`: an unknown tag (the message lists the valid ones), a bad
  scale, or a build without cookies.

```sh
# two tests only
podman run --rm -it --device /dev/kvm -e STRESS_TAGS=churn,spill IMAGE
# the full-length run of the v3 testing (churn 120 s, zapshape to 400,000 entries)
podman run --rm -it --device /dev/kvm -e STRESS_SCALE=1 IMAGE
# the same without a terminal (raise the wait for RESULT for long runs)
podman run --rm --device /dev/kvm -e STRESS_SCALE=1 -e TIMEOUT=7200 IMAGE --check
```

`STRESS_SCALE` (default `0.25`) scales the long parts: churn's 120 s (30 s at
the default) and zapshape's 100,000 / 400,000 entries and 20,000 removed and
reused names (25,000 / 100,000 and 5,000). `1` is the full-length run of the
v3 testing. With rootless podman and a group-only `/dev/kvm`, add
`--group-add keep-groups`.

## The scripts

`/demo/stress/v3_stress.py` in the VM runs the tests (`python3
/demo/stress/v3_stress.py churn spill`, `V3S_VDEV`, `V3S_SCALE`: its
header); `demo.sh` (`/demo/demo.sh`) selects them and prints the summary. The
image also holds them as plain files, so they can be extracted without
booting anything:

```sh
IMAGE=ghcr.io/wrouesnel/openzfs-reproducers:fixed-wrouesnel-fix-nfs-reconnect-hint-v3-stress-ubuntu24-6.8.0-142-generic
podman run --rm --entrypoint cat $IMAGE /zfs-repro/repro/files/stress/v3_stress.py > v3_stress.py
podman run --rm --entrypoint cat $IMAGE /zfs-repro/repro/demo.sh > demo.sh
# or everything at once
podman run --rm --entrypoint tar $IMAGE -C /zfs-repro/repro/files -cf - . | tar -xvf -
```

The script runs on any Linux machine with the branch installed (as root, in
a disposable VM: it creates and destroys pools, by default on a 20 GB sparse
file under `/var/tmp/v3s`). It is the script of the v3 testing record with
three settings (`V3S_VDEV`, `V3S_SCALE`, `V3S_EXPORT_LAST`), `zpool status
-v`/`zdb -b`/scrub output after every test, the `perm` test (the testing's
`v3_perm.sh`, as Python), and a `longname` test that checks its result
instead of only printing it.

## Left out

- **The pool moved between master and the branch** (the testing's
  `v3_compat.sh`: branch, then master, then branch again, with `zfs rewrite
  -N -r` repairing the cookies master left stale). An image holds one
  OpenZFS build, and the move needs both in one run. It could be done with
  two images sharing a run disk (`-v ./runs:/runs`, `--disk`), but not as
  one `--check`; it isn't in this image.
- **NFS reconnect storms** (`v3_storms.sh`, with bpftrace timings): the
  pair `wrouesnel/fix-nfs-reconnect-hint-v3` measures reconnect scaling
  through a real NFS server and client on both builds.
- zloop and the ZTS runs: ZTS runs in openzfs/zfs CI.

## Results

2026-10-24, ubuntu24 image (6.8.0-142-generic, KVM, 6 vCPUs, 6 GiB), the
branch head 4bf201be78, debug build, on a 12-thread host shared with other
builds:

| run | RESULT | time |
|---|---|---|
| `--check` (all tests, scale 0.25), 3 runs | `RESULT OK: 154 checks passed` 3/3 | 418, 418, 379 s |
| `-e STRESS_TAGS=perm --check` | `RESULT OK: 8 checks passed (perm)` | 14 s |
| `-e STRESS_TAGS=churn,spill --check` | `RESULT OK: 22 checks passed (churn spill)` | 130 s |
| `-e STRESS_TAGS=churn,bogus --check` | `RESULT ERROR: unknown tag bogus (valid: churn,zapshape,...)`, exit 1 | 13 s |
| `-e STRESS_SCALE=1 -e TIMEOUT=7200 --check` (the full length) | `RESULT OK: 154 checks passed` | 971 s |

Per test at scale 0.25 (first run): churn 111 s (31,231 operations, 115,120
reconnects by handle, 13 raced with a rename of the same directory, 0 wrong,
cookie hits 110,990, 8 stale, 8 searches), zapshape 101 s, norm 54 s,
sendrecv 103 s, spill 16 s, links, longname, ctldir and perm 1-5 s each. At
scale 1: churn 200 s (72,162 operations, 372,520 reconnects, 0 wrong, hits
359,803, 19 stale and 19 searches), zapshape 569 s (microzap at 40 entries,
fat ZAP with 16 leaves at 2,100, 512 leaves at 100,000, 2,048 leaves and an
external pointer table at 400,000 and after the 20,000 removed and reused
names), the rest as at 0.25. Every test ended with `zdb -b` "No leaks", a
scrub that repaired 0B with 0 errors, and `errors: No known data errors`.
Long names: `ESTALE` from the kernel for the 300-byte name and its child,
counted as cookie hits with no search.
