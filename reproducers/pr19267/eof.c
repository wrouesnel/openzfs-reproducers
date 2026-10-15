/*
 * eof MODE FILE: store "STALE-DATA" past EOF through mmap, then extend it.
 *   truncate, write, fallocate (Linux): a 10-byte file, extended to 1034
 *   copy: a 4106-byte file (its last page starts at 4096), extended by
 *         copy_file_range() of FILE.src (4 KiB, on disk) to offset 8192,
 *         which clones the block when block cloning is enabled
 * The stored bytes are at offset 10 of the file's last page.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
int main(int argc, char **argv) {
	static char buf[4096 + 10], src[4096];
	off_t pg = strcmp(argv[1], "copy") ? 0 : 4096;  /* last page */
	int fd = open(argv[2], O_RDWR | O_CREAT | O_TRUNC, 0644);
	memset(buf, 'D', pg); memcpy(buf + pg, "0123456789", 10);
	write(fd, buf, pg + 10);                    /* file ends 10 bytes into its last page */
	char *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, pg);
	memcpy(p + 10, "STALE-DATA", 10);           /* past EOF, same page */
	munmap(p, 4096);
	if (!strcmp(argv[1], "truncate"))  ftruncate(fd, 1034);
	if (!strcmp(argv[1], "write"))     pwrite(fd, "X", 1, 1033);
#ifdef __linux__
	if (!strcmp(argv[1], "fallocate")) fallocate(fd, 0, 0, 1034);
#endif
	if (pg) {
		snprintf(src, sizeof (src), "%s.src", argv[2]);
		int s = open(src, O_RDONLY); off_t so = 0, d = 8192;
		if (copy_file_range(s, &so, fd, &d, 4096, 0) != 4096) perror("copy_file_range");
		close(s);
	}
	fsync(fd);
	return close(fd);
}
