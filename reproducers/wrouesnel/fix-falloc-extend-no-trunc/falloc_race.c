/*
 * falloc_race FILE ITERATIONS
 *
 * openzfs/zfs#11797: race an appending write of the second 128 KiB block of
 * a new file against fallocate(mode 0) of its first block.  Either order
 * must leave a 256 KiB file whose second block holds the written bytes
 * (0xa5) and whose first block is zeros.  Prints progress, the first few
 * bad iterations, and a summary; the first bad file is kept as FILE.bad.
 * Exit status: 0 all correct, 1 some iterations lost data, 2 error.
 */
#define	_GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define	BS	(128 * 1024)

static int fd;
static pthread_barrier_t barrier;
static char wbuf[BS], rbuf[BS];

static void *
writer(void *arg)
{
	(void) arg;
	pthread_barrier_wait(&barrier);
	if (pwrite(fd, wbuf, BS, BS) != BS)
		perror("pwrite");
	return (NULL);
}

static void *
allocator(void *arg)
{
	(void) arg;
	pthread_barrier_wait(&barrier);
	if (fallocate(fd, 0, 0, BS) != 0)
		perror("fallocate");
	return (NULL);
}

/* 0 if the second block is all 0xa5 and the first all zeros */
static int
check_data(off_t size)
{
	if (size != 2 * BS)
		return (1);
	if (pread(fd, rbuf, BS, BS) != BS)
		return (1);
	for (int i = 0; i < BS; i++)
		if ((unsigned char)rbuf[i] != 0xa5)
			return (1);
	if (pread(fd, rbuf, BS, 0) != BS)
		return (1);
	for (int i = 0; i < BS; i++)
		if (rbuf[i] != 0)
			return (1);
	return (0);
}

int
main(int argc, char **argv)
{
	char bad_path[4096];
	int iters, bad = 0, kept = 0, recovered = 0;

	if (argc < 3) {
		fprintf(stderr, "usage: %s FILE ITERATIONS\n", argv[0]);
		return (2);
	}
	iters = atoi(argv[2]);
	snprintf(bad_path, sizeof (bad_path), "%s.bad", argv[1]);
	(void) unlink(bad_path);
	memset(wbuf, 0xa5, sizeof (wbuf));
	for (int i = 1; i <= iters; i++) {
		pthread_t a, b;
		struct stat st;

		(void) unlink(argv[1]);
		fd = open(argv[1], O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd < 0) {
			perror("open");
			return (2);
		}
		pthread_barrier_init(&barrier, NULL, 2);
		pthread_create(&a, NULL, writer, NULL);
		pthread_create(&b, NULL, allocator, NULL);
		pthread_join(a, NULL);
		pthread_join(b, NULL);
		pthread_barrier_destroy(&barrier);
		if (fstat(fd, &st) != 0) {
			perror("fstat");
			return (2);
		}
		if (check_data(st.st_size) != 0) {
			struct stat st2;
			int intact;

			bad++;
			(void) fsync(fd);
			if (fstat(fd, &st2) != 0)
				st2.st_size = -1;
			intact = check_data(st2.st_size) == 0;
			if (st2.st_size == 2 * BS && intact)
				recovered++;
			if (bad <= 5)
				printf("   iteration %d: WRONG SIZE: %lld right "
				    "after both calls returned (expected %d); "
				    "after fsync: size %lld, written block %s\n",
				    i, (long long)st.st_size, 2 * BS,
				    (long long)st2.st_size,
				    intact ? "intact" : "MISSING");
			if (!kept) {
				(void) close(fd);
				fd = -1;
				if (rename(argv[1], bad_path) == 0)
					kept = 1;
			}
		}
		if (fd >= 0)
			(void) close(fd);
		if (i % 500 == 0)
			printf("   ... %d iterations, %d wrong so far\n", i, bad);
	}
	printf("%d of %d iterations saw the wrong size; %d of them had the "
	    "right size and data after fsync\n", bad, iters, recovered);
	return (bad != 0);
}
