/*
 * diowrite -- bug #57 demo helper: copy the first LEN bytes of SRC over the
 * start of DST with one O_DIRECT pwrite() from a page-aligned buffer (what
 * ZTS's stride_dd -D does), so the write takes ZFS's Direct I/O path.
 *   diowrite SRC DST LEN
 */
#define	_GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "usage: diowrite SRC DST LEN\n");
		return (2);
	}
	size_t len = strtoul(argv[3], NULL, 0);
	void *buf;
	if (posix_memalign(&buf, 4096, len) != 0)
		return (2);
	int in = open(argv[1], O_RDONLY);
	if (in < 0 || read(in, buf, len) != (ssize_t)len) {
		perror(argv[1]);
		return (2);
	}
	int out = open(argv[2], O_WRONLY | O_DIRECT);
	if (out < 0) {
		perror(argv[2]);
		return (2);
	}
	ssize_t n = pwrite(out, buf, len, 0);
	if (n != (ssize_t)len) {
		perror("pwrite");
		return (1);
	}
	printf("O_DIRECT pwrite of %zu bytes at offset 0: done\n", len);
	return (0);
}
