# wrouesnel/fix-raw-recv-resume-encrypt-v2

Bug #276 ([openzfs/zfs#18394](https://github.com/openzfs/zfs/issues/18394)):
a raw receive (`zfs send -w | zfs receive`) of an encrypted dataset whose key
is not loaded panics after the destination pool is suspended and resumed
with `zpool clear`:

```
VERIFY0(spa_do_crypt_abd(B_TRUE, spa, &zio->io_bookmark, ...)) failed (13)
PANIC at zio.c:...:zio_encrypt()
```

When the disk fails during a txg sync of the receive, the blocks that can't
be allocated reach `arc_write_ready()` with a hole bp, and it clears
`ARC_BUF_FLAG_ENCRYPTED` on ARC buffers that still hold raw blocks of dnodes.
After the clear, the next txg that dirties such a block writes it as
plaintext: `zio_encrypt()` needs the dataset's key, which a raw receive
doesn't have. The fix
([fix-raw-recv-resume-encrypt-v2](https://github.com/wrouesnel/zfs/tree/fix-raw-recv-resume-encrypt-v2))
changes the buffer's flags only when its write succeeded.

The demo receives most of a raw stream, fails the destination's disk with
`zinject` (writes EIO, probe ENXIO), feeds more of the stream so the pool
suspends, then clears it and feeds the rest, with `zpool status -v` after
each step. The break shows the VERIFY in the kernel log and a receive that
never finishes; the fix finishes the receive and checks the data against the
source (before and after an export/import) and with a scrub.

The branch carries two test-then-fix pairs on openzfs/zfs master cde5d598eb:
bug #277 (its test, then its fix), then bug #276 (its tests, then its fix).
This reproducer's break is `BRANCH~1` (the #276 tests on top of the #277
fix), its fix the head. Bug #277 has its own reproducer,
[wrouesnel/fix-raw-recv-resume-encrypt-v2-saleak](../fix-raw-recv-resume-encrypt-v2-saleak/).
