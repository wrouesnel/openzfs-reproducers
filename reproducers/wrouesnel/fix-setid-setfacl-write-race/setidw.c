/*
 * setidw -- demo helper for wrouesnel/fix-setid-setfacl-write-race.
 *   setidw write UID FILE LEN   as UID:UID (no supplementary groups), open
 *                               FILE O_WRONLY and write LEN zero bytes at
 *                               offset 0 in one pwrite(); exit 0 if all of
 *                               them were written
 *   setidw mtime FILE           print FILE's mtime as SECONDS.NANOSECONDS
 */
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "mtime") == 0) {
		struct stat st;
		if (stat(argv[2], &st) != 0) {
			perror("stat");
			return (2);
		}
		printf("%lld.%09ld\n", (long long)st.st_mtim.tv_sec,
		    st.st_mtim.tv_nsec);
		return (0);
	}
	if (argc == 5 && strcmp(argv[1], "write") == 0) {
		uid_t uid = (uid_t)atol(argv[2]);
		size_t len = (size_t)atoll(argv[4]);
		char *buf;
		ssize_t n;
		int fd;

		if (setgroups(0, NULL) != 0 || setgid(uid) != 0 ||
		    setuid(uid) != 0) {
			perror("setuid");
			return (2);
		}
		if ((fd = open(argv[3], O_WRONLY)) < 0) {
			perror("open");
			return (2);
		}
		if ((buf = calloc(1, len)) == NULL) {
			perror("calloc");
			return (2);
		}
		n = pwrite(fd, buf, len, 0);
		if (n < 0) {
			perror("pwrite");
			return (1);
		}
		printf("uid %u wrote %zd of %zu bytes\n", (unsigned)uid, n, len);
		return (n == (ssize_t)len ? 0 : 1);
	}
	fprintf(stderr, "usage: setidw write UID FILE LEN | setidw mtime FILE\n");
	return (2);
}
