/*
 * syncop -- bug #275 demo helper: one sync call, its result and how long it
 * took.
 *   syncop syncfs PATH    syncfs(2) on the file system holding PATH
 *   syncop fsync PATH     fsync(2) of PATH (opened O_RDONLY)
 *   syncop sync           sync(2) (returns nothing)
 * Prints e.g. "syncfs(/p/fs) = -1 EIO (Input/output error) after 0.01 s";
 * the exit status is 0 on success, 1 on an error.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static const char *
ename(int e)
{
	switch (e) {
	case EIO: return ("EIO");
	case ENXIO: return ("ENXIO");
	case EROFS: return ("EROFS");
	case EBUSY: return ("EBUSY");
	case EINTR: return ("EINTR");
	default: return ("errno");
	}
}

static double
now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (ts.tv_sec + ts.tv_nsec / 1e9);
}

int
main(int argc, char **argv)
{
	const char *op = argc > 1 ? argv[1] : "";
	int fd = -1, rc, e = 0;
	double t0;

	if (strcmp(op, "sync") == 0) {
		t0 = now();
		sync();
		printf("sync() returned after %.2f s\n", now() - t0);
		return (0);
	}
	if (argc != 3 || (strcmp(op, "syncfs") && strcmp(op, "fsync"))) {
		fprintf(stderr, "usage: syncop syncfs|fsync PATH | syncop sync\n");
		return (2);
	}
	if ((fd = open(argv[2], O_RDONLY)) < 0) {
		printf("open(%s) failed: %s\n", argv[2], strerror(errno));
		return (1);
	}
	t0 = now();
	rc = op[0] == 's' ? syncfs(fd) : fsync(fd);
	if (rc != 0)
		e = errno;
	if (rc == 0)
		printf("%s(%s) = 0 after %.2f s\n", op, argv[2], now() - t0);
	else
		printf("%s(%s) = -1 %s (%s) after %.2f s\n", op, argv[2],
		    ename(e), strerror(e), now() - t0);
	close(fd);
	return (rc == 0 ? 0 : 1);
}
