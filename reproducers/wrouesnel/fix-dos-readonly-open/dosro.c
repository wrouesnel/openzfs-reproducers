/*
 * dosro -- bug #39 demo helper: the ZFS DOS read-only attribute on Linux.
 *   dosro get FILE                 print "readonly" or "-"
 *   dosro set|clear FILE           set or clear it (ZFS_IOC_SETDOSFLAGS on an
 *                                  O_RDONLY descriptor, as chattr does)
 *   dosro write UID append|trunc FILE TEXT
 *                                  as UID (0 = root), open FILE with
 *                                  O_WRONLY|O_APPEND or O_WRONLY|O_TRUNC and
 *                                  write TEXT; exit 0 if it was written,
 *                                  1 if the open failed
 * The ioctl numbers are ZFS's (include/sys/fs/zfs.h), so no ZFS headers
 * are needed.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define	ZFS_IOC_GETDOSFLAGS	_IOR(0x83, 1, uint64_t)
#define	ZFS_IOC_SETDOSFLAGS	_IOW(0x83, 2, uint64_t)
#define	ZFS_READONLY		0x0000000100000000ull

static const char *
ename(int e)
{
	switch (e) {
	case EPERM: return ("EPERM");
	case EACCES: return ("EACCES");
	case EROFS: return ("EROFS");
	default: return ("errno");
	}
}

int
main(int argc, char **argv)
{
	if (argc == 3) {
		int fd = open(argv[2], O_RDONLY | O_CLOEXEC);
		uint64_t f;
		if (fd < 0 || ioctl(fd, ZFS_IOC_GETDOSFLAGS, &f) < 0) {
			perror(argv[2]);
			return (2);
		}
		if (strcmp(argv[1], "get") == 0) {
			printf("%s\n", (f & ZFS_READONLY) ? "readonly" : "-");
			return (0);
		}
		if (strcmp(argv[1], "set") == 0)
			f |= ZFS_READONLY;
		else if (strcmp(argv[1], "clear") == 0)
			f &= ~ZFS_READONLY;
		else
			return (2);
		if (ioctl(fd, ZFS_IOC_SETDOSFLAGS, &f) < 0) {
			perror("ZFS_IOC_SETDOSFLAGS");
			return (2);
		}
		return (0);
	}
	if (argc != 6 || strcmp(argv[1], "write") != 0) {
		fprintf(stderr, "usage: dosro get|set|clear FILE | "
		    "dosro write UID append|trunc FILE TEXT\n");
		return (2);
	}
	uid_t uid = atoi(argv[2]);
	if (uid != 0 && (setgid(uid) != 0 || setuid(uid) != 0)) {
		perror("setuid");
		return (2);
	}
	int trunc = strcmp(argv[3], "trunc") == 0;
	int fd = open(argv[4], O_WRONLY | (trunc ? O_TRUNC : O_APPEND));
	const char *how = trunc ? "O_WRONLY|O_TRUNC" : "O_WRONLY|O_APPEND";
	if (fd < 0) {
		int e = errno;
		printf("open(%s) as uid %d: failed, %s (%s)\n", how, (int)uid,
		    strerror(e), ename(e));
		return (1);
	}
	ssize_t n = write(fd, argv[5], strlen(argv[5]));
	printf("open(%s) as uid %d: succeeded, write() = %zd\n", how,
	    (int)uid, n);
	close(fd);
	return (0);
}
