/*
 * ueventmon NAME STOPFILE
 *
 * Bug #129 / openzfs#19371: count the kernel's "change" uevents for block
 * device NAME (e.g. zd0) until STOPFILE exists, the way udev would see
 * them, and print the count.  The demo image has no udev, so this stands in
 * for checking that the /dev/zvol links would still be updated.
 */
#include <linux/netlink.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: ueventmon NAME STOPFILE\n");
		return (2);
	}
	int s = socket(AF_NETLINK, SOCK_DGRAM, NETLINK_KOBJECT_UEVENT);
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK, .nl_groups = 1 };
	if (s < 0 || bind(s, (struct sockaddr *)&sa, sizeof (sa)) != 0) {
		perror("netlink");
		return (2);
	}
	int rcv = 1 << 20;
	(void) setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof (rcv));
	char want[256], buf[8192];
	snprintf(want, sizeof (want), "change@/devices/virtual/block/%s", argv[1]);
	unsigned long n = 0;
	struct stat st;
	printf("ready\n");
	fflush(stdout);
	for (;;) {
		struct pollfd p = { .fd = s, .events = POLLIN };
		if (poll(&p, 1, 200) > 0) {
			ssize_t len = recv(s, buf, sizeof (buf) - 1, 0);
			if (len > 0) {
				buf[len] = '\0';
				if (strcmp(buf, want) == 0)
					n++;
			}
		} else if (stat(argv[2], &st) == 0) {
			break;
		}
	}
	printf("change uevents for %s: %lu\n", argv[1], n);
	return (0);
}
