/* fsyncf PATH...: open each PATH read-only and fsync(2) it (the reporter's
 * python3 -c 'os.fsync(os.open(PATH, os.O_RDONLY))'). */
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	int i, fd, rc = 0;

	for (i = 1; i < argc; i++) {
		if ((fd = open(argv[i], O_RDONLY)) < 0 || fsync(fd) != 0) {
			perror(argv[i]);
			rc = 1;
		}
		if (fd >= 0)
			close(fd);
	}
	return (rc);
}
