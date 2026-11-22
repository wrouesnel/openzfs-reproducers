# wrouesnel/fix-zts-mmap-ftruncate-alpine

A ZTS flake on slow runners: `mmap/mmap_ftruncate` failed on alpine3-24 in
fork and upstream CI (fork zfs-qemu 44962925233, upstream 44955633933 and
44965541552) after 140-221 s against its 90 s limit. Master's test times the
whole `mmap_ftruncate` program. Nearly all of that is dirtying 2G of
mmap()'d pages, which the kernel throttles to the pool's writeback speed. The
call the test is about, the final `ftruncate(fd, 0)`, stays near-instant
(it would block for the 180 s txg timeout if async writeback weren't ended
early).

The image runs `mmap_ftruncate` as the ZTS runner does (KIND=zts), with
`slow_pool.sh` beside it (started by `prep.sh`). Once the test's file exists,
every I/O to the pool is delayed 200 ms, one at a time (`zinject -D 200:1`),
which stands in for the slow runner. `slow_pool.sh` also times the program
from outside (it samples `/proc/PID/stat` and `/proc/PID/syscall` about every 10 ms). Just before the
RESULT it prints the whole run against an upper bound on the final
`ftruncate(fd, 0)`: from the last sample that saw the program dirtying
pages (or in `sync_file_range()`) to its exit.

- repro (master's test): the whole run takes about 123 s, so `test 123 -lt 90`
  fails and the test FAILs. The final `ftruncate(fd, 0)`, munmap and exit
  took about 0.2 s at most, and the call was never seen blocked in it.
- fixed ([fix-zts-mmap-ftruncate-alpine](https://github.com/wrouesnel/zfs/tree/fix-zts-mmap-ftruncate-alpine)):
  the test starts writeback of its 256M explicitly, times only
  `ftruncate(fd, 0)` (tens of ms) against 90000 ms, checks that the
  dataset's `nwritten` grew by the file size, and PASSes under the same delay.
