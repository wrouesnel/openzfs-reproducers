# wrouesnel/fix-zts-pool-state-rescan

A ZTS flake: `procfs/pool_state` left `testpool2` SUSPENDED in fork and
upstream CI (fork zfs-qemu 44973013373 and upstream 44962196233 on ubuntu24,
an almalinux8 run on 2026-10-09), and every later test whose cleanup touches
pools failed (175 in one run). The test builds `testpool2` on a scsi_debug
disk, removes the disk to suspend the pool, and its cleanup rescans the SCSI
host and asks `get_debug_device` for the disk's new name. Right after the
rescan, lsscsi can print `unexpected scan_for_first error` in the device
column (lsscsi.c prints it when the device's sysfs `block/` directory exists
but is still empty). `get_debug_device` retries only on `-`, so it returned
`unexpected`, `ln /dev/unexpected /dev/kstat-state-realdisk` failed, and the
cleanup stopped before `zpool clear` and `destroy`.

That window didn't open in 30 local runs, so the image opens it on every run
from inside the guest: `prep.sh` puts `flaky_lsscsi.sh` on the tests' `PATH`
as `lsscsi`. It runs the real lsscsi, and once the test has removed its
scsi_debug disk, the next 3 calls that list the disk print `unexpected
scan_for_first error` in its device column; its log shows the real line
beside each faked one. After the test (and its own cleanup), and again at
the end of the run, `after_test.sh` prints the pools' kernel state, `zpool
list`, `zpool status -v`, the scsi_debug disk and the trigger's log.
Hung-task warnings are turned off, since the test suspends `testpool2` for
200 s on purpose.

- repro (master's tests): `get_debug_device` returns `unexpected` on the
  first call, the cleanup's `ln` fails, pool_state FAILs, and `testpool2` is
  left SUSPENDED with scsi_debug still loaded. The group's cleanup then
  hangs on `testpool2` until its 600 s timeout KILLs it, as in CI.
- fixed ([fix-zts-pool-state-rescan](https://github.com/wrouesnel/zfs/tree/fix-zts-pool-state-rescan)):
  `get_debug_device` only returns a name once it is a block device, so it
  waits past the 3 bad answers for the real disk; the cleanup clears and
  destroys `testpool2`, pool_state PASSes and no pool is left.
