/*
 * zvwrite DEV STOPFILE [O_DIRECT=1]
 *
 * Bug #129 / openzfs#19371: write 4 KiB blocks to a zvol in a loop until
 * STOPFILE exists, retrying after a failed write instead of stopping.
 * Prints the number of writes, and of failures per errno, at the end.
 */
#define	_GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: zvwrite DEV STOPFILE [direct]\n");
		return (2);
	}
	int direct = argc > 3 && atoi(argv[3]);
	int fd = open(argv[1], O_WRONLY | (direct ? O_DIRECT : 0));
	if (fd < 0) {
		perror(argv[1]);
		return (2);
	}
	off_t size = lseek(fd, 0, SEEK_END);
	void *buf;
	if (posix_memalign(&buf, 4096, 4096) != 0)
		return (2);
	memset(buf, 0xa5, 4096);
	unsigned long writes = 0, errs[256] = { 0 };
	struct stat st;
	off_t off = 0;
	while (stat(argv[2], &st) != 0) {
		for (int i = 0; i < 256; i++) {
			if (pwrite(fd, buf, 4096, off) != 4096)
				errs[errno & 0xff]++;
			writes++;
			off = (off + 4096) % size;
		}
	}
	printf("writes %lu", writes);
	unsigned long total = 0;
	for (int e = 0; e < 256; e++) {
		if (errs[e]) {
			printf(" %s %lu", strerror(e), errs[e]);
			total += errs[e];
		}
	}
	printf(" failed %lu\n", total);
	return (total != 0);
}
