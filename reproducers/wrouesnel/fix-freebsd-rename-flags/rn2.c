/*
 * rn2 [-n|-x] SRC DST: renameat2(AT_FDCWD, SRC, AT_FDCWD, DST, flags) on
 * FreeBSD; prints the return value and errno.  Exit 0 on success, 1 on
 * failure.  -x = AT_RENAME_EXCHANGE, -n = AT_RENAME_NOREPLACE.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	unsigned flags = 0;
	const char *fn = "0";
	int c;
	while ((c = getopt(argc, argv, "nx")) != -1) {
		if (c == 'n') {
			flags |= AT_RENAME_NOREPLACE;
			fn = "AT_RENAME_NOREPLACE";
		} else if (c == 'x') {
			flags |= AT_RENAME_EXCHANGE;
			fn = "AT_RENAME_EXCHANGE";
		} else
			return (2);
	}
	if (argc - optind != 2) {
		fprintf(stderr, "usage: rn2 [-n|-x] SRC DST\n");
		return (2);
	}
	errno = 0;
	int rc = renameat2(AT_FDCWD, argv[optind], AT_FDCWD, argv[optind + 1],
	    flags);
	int e = errno;
	if (rc == 0)
		printf("renameat2(%s, %s, %s) = 0 (success)\n", argv[optind],
		    argv[optind + 1], fn);
	else
		printf("renameat2(%s, %s, %s) = %d, errno %d (%s)\n",
		    argv[optind], argv[optind + 1], fn, rc, e, strerror(e));
	return (rc == 0 ? 0 : 1);
}
