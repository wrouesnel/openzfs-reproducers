/*
 * zil_zero_race.c: natural-race probe for openzfs/zfs#19766 (no module hook).
 *
 * For each new file (O_CREAT|O_DSYNC, fsync'd so TX_CREATE is logged),
 * NTHREADS threads released together by a barrier each pwrite() LEN bytes
 * into L0 block 1 (offset BLK + i * BLK / NTHREADS; BLK = recordsize).  The
 * first thread to dirty block 1 publishes its dirty record before
 * dnode_new_blkid() raises dn_maxblkid; any other thread that takes the
 * already-dirty fast path and reads its data back for the log record
 * (zfs_log_write() for WR_COPIED, zfs_get_data() for WR_NEED_COPY) in that
 * window logs zeros.  Only a replay shows it.
 *
 *   zil_zero_race write  DIR NFILES NTHREADS LEN [BLK]
 *   zil_zero_race verify DIR NFILES NTHREADS LEN [BLK]
 *
 * verify prints one line per bad chunk (ZERO / MISMATCH / SHORT / MISSING)
 * and "VERIFY SUMMARY: files=N chunks=C zero=Z mismatch=M bad_files=F".
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int nthreads;
static size_t len;
static off_t blk = 1048576;
static pthread_barrier_t bar;

struct job {
	int fd, file, idx;
	char *buf;
	ssize_t rc;
	int err;
};

static off_t
chunk_off(int i)
{
	return (blk + (off_t)i * (blk / nthreads));
}

static void
fill(char *buf, int file, int i)
{
	memset(buf, 1 + (file * 31 + i * 7) % 251, len);
	snprintf(buf, len < 64 ? len : 64, "RACE file=%d thr=%d off=%lld",
	    file, i, (long long)chunk_off(i));
}

static void *
writer(void *arg)
{
	struct job *j = arg;
	pthread_barrier_wait(&bar);
	j->rc = pwrite(j->fd, j->buf, len, chunk_off(j->idx));
	j->err = errno;
	return (NULL);
}

static int
do_write(const char *dir, int nfiles)
{
	char path[4096];
	struct job *jobs = calloc(nthreads, sizeof (*jobs));
	pthread_t *tids = calloc(nthreads, sizeof (*tids));

	for (int i = 0; i < nthreads; i++)
		jobs[i].buf = malloc(len);
	for (int f = 0; f < nfiles; f++) {
		snprintf(path, sizeof (path), "%s/r%05d", dir, f);
		int fd = open(path, O_CREAT | O_TRUNC | O_RDWR | O_DSYNC, 0644);
		if (fd < 0) {
			perror(path);
			return (2);
		}
		fsync(fd);
		pthread_barrier_init(&bar, NULL, nthreads);
		for (int i = 0; i < nthreads; i++) {
			jobs[i].fd = fd;
			jobs[i].file = f;
			jobs[i].idx = i;
			fill(jobs[i].buf, f, i);
			pthread_create(&tids[i], NULL, writer, &jobs[i]);
		}
		for (int i = 0; i < nthreads; i++) {
			pthread_join(tids[i], NULL);
			if (jobs[i].rc != (ssize_t)len) {
				fprintf(stderr, "%s thr %d: pwrite %zd (%s)\n",
				    path, i, jobs[i].rc, strerror(jobs[i].err));
				return (2);
			}
		}
		pthread_barrier_destroy(&bar);
		close(fd);
	}
	printf("WRITE SUMMARY: files=%d threads=%d len=%zu\n", nfiles,
	    nthreads, len);
	return (0);
}

static int
do_verify(const char *dir, int nfiles)
{
	char path[4096], *want = malloc(len), *got = malloc(len);
	int zero = 0, mism = 0, badf = 0, chunks = 0;

	for (int f = 0; f < nfiles; f++) {
		snprintf(path, sizeof (path), "%s/r%05d", dir, f);
		int fd = open(path, O_RDONLY);
		if (fd < 0) {
			printf("%s MISSING\n", path);
			badf++;
			continue;
		}
		int bad = 0;
		for (int i = 0; i < nthreads; i++, chunks++) {
			fill(want, f, i);
			ssize_t rc = pread(fd, got, len, chunk_off(i));
			const char *st = "OK";
			if (rc != (ssize_t)len) {
				st = "SHORT";
			} else if (memcmp(got, want, len) != 0) {
				size_t k;
				for (k = 0; k < len && got[k] == 0; k++)
					;
				st = k == len ? "ZERO" : "MISMATCH";
			}
			if (strcmp(st, "OK") != 0) {
				size_t zb = 0, firstbad = len;
				for (size_t k = 0; rc == (ssize_t)len &&
				    k < len; k++) {
					zb += got[k] == 0;
					if (firstbad == len && got[k] != want[k])
						firstbad = k;
				}
				printf("%s thr=%d off=%lld %s zero_bytes=%zu "
				    "first_diff=%zu\n", path, i,
				    (long long)chunk_off(i), st, zb, firstbad);
				bad = 1;
				if (strcmp(st, "ZERO") == 0)
					zero++;
				else
					mism++;
			}
		}
		badf += bad;
		close(fd);
	}
	printf("VERIFY SUMMARY: files=%d chunks=%d zero=%d mismatch=%d "
	    "bad_files=%d\n", nfiles, chunks, zero, mism, badf);
	return (badf ? 1 : 0);
}

int
main(int argc, char **argv)
{
	if (argc < 6) {
		fprintf(stderr, "usage: %s write|verify DIR NFILES NTHREADS "
		    "LEN [BLK]\n", argv[0]);
		return (2);
	}
	int n = atoi(argv[3]);
	nthreads = atoi(argv[4]);
	len = strtoul(argv[5], NULL, 10);
	if (argc > 6)
		blk = strtoll(argv[6], NULL, 10);
	if (nthreads < 1 || len < 1 || (off_t)len > blk / nthreads) {
		fprintf(stderr, "need NTHREADS*LEN <= BLK\n");
		return (2);
	}
	if (strcmp(argv[1], "write") == 0)
		return (do_write(argv[2], n));
	if (strcmp(argv[1], "verify") == 0)
		return (do_verify(argv[2], n));
	return (2);
}
