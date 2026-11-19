# wrouesnel/fix-raw-recv-resume-encrypt-v2-saleak

Bug #277: `zpool export` hangs forever after `zpool status -v` ran during a
raw receive whose key is loaded.

`zpool status -v` turns each logged error into a path
(`ZFS_IOC_OBJ_TO_PATH` -> `zfs_obj_to_path()` -> `sa_handle_get()`). While a
dataset is being raw received its blocks stay raw, so with the key loaded the
bonus buffer read there is still ciphertext, and `sa_build_index()` fails
(`Buffer Header ... != SA_MAGIC` in the debug log, EIO). Since fba33c3819
([#7487](https://github.com/openzfs/zfs/pull/7487), zfs-0.8)
`sa_handle_get()` returned that error without freeing the new SA handle or
releasing its hold on the bonus buffer. Each failed lookup leaks a hold, the
objset can never be evicted, and `zpool export` waits in
`spa_evicting_os_wait()` until a reboot. The fix frees the handle and
releases the bonus buffer when `sa_build_index()` fails. No pool suspension
is involved.

The demo pauses a raw receive, logs an error in one received file (an
injected checksum error and a scrub), loads the key, runs `zpool status -v`
three times, finishes the receive and gives `zpool export` 60 s, with
`zpool status -v` after each step. The break shows the export still waiting
and its kernel stack; the fix exports at once, imports, and checks the data
against the source and with a scrub.

This is a companion of
[wrouesnel/fix-raw-recv-resume-encrypt-v2](../fix-raw-recv-resume-encrypt-v2/)
(bug #276, [openzfs/zfs#18394](https://github.com/openzfs/zfs/issues/18394)):
the branch
[fix-raw-recv-resume-encrypt-v2](https://github.com/wrouesnel/zfs/tree/fix-raw-recv-resume-encrypt-v2)
carries the #277 pair first, so the break here is `BRANCH~3` (master
cde5d598eb + the #277 test) and the fix `BRANCH~2` (the #277 fix).
