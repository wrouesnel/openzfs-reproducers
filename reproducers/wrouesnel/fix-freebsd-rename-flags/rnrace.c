/*
 * rnrace DIR SECONDS : AT_RENAME_NOREPLACE race (FreeBSD renameat2(2)).
 * A child process loops: create DIR/src ("SRC"),
 * renameat2(src, dst, AT_RENAME_NOREPLACE).  The parent loops: create
 * DIR/dst exclusively (O_EXCL) with "DST-n", hold it open briefly, check it
 * is still linked, unlink it.  Only the parent unlinks dst while it holds
 * it, so if its O_EXCL file has st_nlink == 0 before that, a NOREPLACE
 * rename replaced an existing target ("lost").  Exit 1 if any was lost.
 */
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: rnrace DIR SECONDS\n");
		return (2);
	}
	int dfd = open(argv[1], O_RDONLY | O_DIRECTORY);
	if (dfd < 0) {
		perror(argv[1]);
		return (2);
	}
	int secs = atoi(argv[2]);
	int pfd[2];
	if (pipe(pfd) != 0)
		return (2);
	pid_t pid = fork();
	if (pid == 0) {
		long ok = 0, eexist = 0, other = 0;
		time_t end = time(NULL) + secs;
		close(pfd[0]);
		while (time(NULL) < end) {
			int fd = openat(dfd, "src", O_CREAT | O_TRUNC | O_WRONLY,
			    0644);
			if (fd >= 0) {
				(void) write(fd, "SRC", 3);
				close(fd);
			}
			if (renameat2(dfd, "src", dfd, "dst",
			    AT_RENAME_NOREPLACE) == 0)
				ok++;
			else if (errno == EEXIST)
				eexist++;
			else
				other++;
		}
		dprintf(pfd[1], "renames ok %ld eexist %ld other %ld", ok,
		    eexist, other);
		_exit(0);
	}
	close(pfd[1]);
	long n = 0, creates = 0, lost = 0;
	time_t end = time(NULL) + secs;
	while (time(NULL) < end) {
		int fd = openat(dfd, "dst", O_CREAT | O_EXCL | O_RDWR, 0644);
		if (fd < 0) {
			/* dst from a successful rename: clear it */
			unlinkat(dfd, "dst", 0);
			continue;
		}
		creates++;
		char w[32];
		snprintf(w, sizeof (w), "DST-%ld", n++);
		(void) write(fd, w, strlen(w));
		usleep(50);
		struct stat st;
		fstat(fd, &st);
		if (st.st_nlink == 0) {
			lost++;
			char r[32] = "";
			int f2 = openat(dfd, "dst", O_RDONLY);
			if (f2 >= 0) {
				(void) read(f2, r, sizeof (r) - 1);
				close(f2);
			}
			if (lost <= 3)
				printf("LOST: our O_EXCL file \"%s\" was replaced "
				    "by a NOREPLACE rename; dst now holds \"%s\"\n",
				    w, r);
		}
		close(fd);
		unlinkat(dfd, "dst", 0);
	}
	char buf[128] = "";
	(void) read(pfd[0], buf, sizeof (buf) - 1);
	waitpid(pid, NULL, 0);
	unlinkat(dfd, "src", 0);
	unlinkat(dfd, "dst", 0);
	printf("%s; creates %ld; lost %ld\n", buf, creates, lost);
	return (lost ? 1 : 0);
}
