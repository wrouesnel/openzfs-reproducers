/*
 * zvol_name /dev/zdN: prints the dataset name of a zvol device, as the
 * OpenZFS udev helper zvol_id does (BLKZNAME).  The ZTS reproducers' VM has
 * no udev; zts-udevadm makes the /dev/zvol links with this.
 */
#include <fcntl.h>
#include <stdio.h>
#include <sys/ioctl.h>
#define	BLKZNAME	_IOR(0x12, 125, char[256])
int
main(int argc, char **argv)
{
	char name[256];
	int fd;

	if (argc != 2 || (fd = open(argv[1], O_RDONLY)) < 0 ||
	    ioctl(fd, BLKZNAME, name) != 0)
		return (1);
	(void) puts(name);
	return (0);
}
