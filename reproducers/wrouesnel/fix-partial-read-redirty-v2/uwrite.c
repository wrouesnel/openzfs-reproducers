/*
 * uwrite.c: write or verify a file filled with a pattern, for the #19299 demo
 * (bug 22).  Prebuilt in the demo image as /demo/uwrite.
 *
 *   uwrite write  FILE MIB BS plain|direct|dontcache [fsync]
 *   uwrite verify FILE MIB
 *   uwrite fsync  FILE
 *
 * write: MIB MiB in BS-byte pwrite()s, in order:
 *   plain      buffered pwrite()
 *   direct     open(O_DIRECT) + pwrite()
 *   dontcache  pwritev2(RWF_DONTCACHE)  (exit 3 if the kernel or the
 *              filesystem refuses the flag: EOPNOTSUPP/EINVAL)
 *   fsync      fsync() at the end (commits the ZIL)
 * fsync: open the file and fsync() it.
 * verify: read the file back and compare with the pattern (exit 1 on a
 * mismatch).  The pattern depends only on the offset (splitmix64 of the
 * 8-byte word index), so no source file is needed.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

#ifndef RWF_DONTCACHE
#define RWF_DONTCACHE 0x00000080
#endif

static uint64_t
word(uint64_t i)
{
	uint64_t z = i + 0x9e3779b97f4a7c15ULL;
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return (z ^ (z >> 31));
}

static void
fill(uint64_t *buf, size_t len, uint64_t off)
{
	for (size_t i = 0; i < len / 8; i++)
		buf[i] = word(off / 8 + i);
}

int
main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "fsync") == 0) {
		int fd = open(argv[2], O_WRONLY);
		if (fd < 0 || fsync(fd) != 0) {
			perror(argv[2]);
			return (2);
		}
		return (close(fd) == 0 ? 0 : 2);
	}
	if (argc < 4) {
		fprintf(stderr, "usage: uwrite write FILE MIB BS plain|direct|"
		    "dontcache [fsync]\n       uwrite verify FILE MIB\n"
		    "       uwrite fsync FILE\n");
		return (2);
	}
	const char *file = argv[2];
	uint64_t size = strtoull(argv[3], NULL, 0) << 20;
	size_t bs = 131072;
	void *buf;

	if (strcmp(argv[1], "verify") == 0) {
		int fd = open(file, O_RDONLY);
		uint64_t *want = malloc(bs);
		if (fd < 0 || want == NULL || posix_memalign(&buf, 4096, bs)) {
			perror(file);
			return (2);
		}
		for (uint64_t off = 0; off < size; off += bs) {
			ssize_t n = pread(fd, buf, bs, off);
			fill(want, bs, off);
			if (n != (ssize_t)bs || memcmp(buf, want, bs) != 0) {
				fprintf(stderr, "%s: wrong data at offset %llu\n",
				    file, (unsigned long long)off);
				return (1);
			}
		}
		return (0);
	}
	if (strcmp(argv[1], "write") != 0 || argc < 6)
		return (2);
	bs = strtoul(argv[4], NULL, 0);
	const char *how = argv[5];
	int dosync = argc > 6 && strcmp(argv[6], "fsync") == 0;
	int flags = O_WRONLY | O_CREAT | O_TRUNC;
	int rwf = 0;
	if (strcmp(how, "direct") == 0)
		flags |= O_DIRECT;
	else if (strcmp(how, "dontcache") == 0)
		rwf = RWF_DONTCACHE;
	else if (strcmp(how, "plain") != 0)
		return (2);
	int fd = open(file, flags, 0644);
	if (fd < 0 || bs == 0 || posix_memalign(&buf, 4096, bs)) {
		perror(file);
		return (2);
	}
	for (uint64_t off = 0; off < size; off += bs) {
		ssize_t n;
		fill(buf, bs, off);
		if (rwf) {
			struct iovec iov = { buf, bs };
			n = pwritev2(fd, &iov, 1, off, rwf);
		} else {
			n = pwrite(fd, buf, bs, off);
		}
		if (n < 0 && off == 0 && rwf &&
		    (errno == EOPNOTSUPP || errno == EINVAL)) {
			fprintf(stderr, "%s: RWF_DONTCACHE not supported: %s\n",
			    file, strerror(errno));
			return (3);
		}
		if (n != (ssize_t)bs) {
			fprintf(stderr, "%s: write at %llu: %s\n", file,
			    (unsigned long long)off, strerror(errno));
			return (2);
		}
	}
	if (dosync && fsync(fd) != 0) {
		perror("fsync");
		return (2);
	}
	return (close(fd) == 0 ? 0 : 2);
}
