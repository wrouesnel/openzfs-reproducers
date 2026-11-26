/*
 * cc14548.c: the reproducer from openzfs/zfs#14548, unchanged except that
 * FILE_SIZE is 16 MiB (64 MiB in the issue), to keep a run short.
 * One thread write()s 22-byte records to a file while another reads each
 * one back through a shared mapping (and then the reverse); it exits 2
 * with "data corrupt, offset: N" if a record reads back wrong.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <threads.h>

#define MODE_WRITE_FILE 0
#define MODE_WRITE_MMAP  1

#define FILE_SIZE   (16*1024*1024)

struct thread_info {
    int mode;
    atomic_int pos;
    int fd;
    char* base;
};

char data[] = "cache coherency test\n";

int reader(void* arg) {
    struct thread_info* ti = (struct thread_info*)arg;
    char buf[sizeof(data)];
    for (int i = 0, offset = 0; offset >= 0; offset = ti->pos) {
        if (offset == i) continue;
        char *ptr = buf;
        if (ti->mode == MODE_WRITE_FILE) ptr = ti->base+sizeof(data)*i;
        else if (read(ti->fd, buf, sizeof(data)) != sizeof(data)) {
            perror("read file error");
            exit(2);
        }
        if (memcmp(ptr, data, sizeof(data)) != 0) {
            printf("data corrupt, offset: %d\n", i*sizeof(data));
            exit(2);
        }
        i++;
    }
    return 0;
}

int test(int mode) {
    struct thread_info ti = {
        .pos = 0,
        .mode = mode,
    };
    if ((ti.fd = open("test-cc.bin", O_CREAT|O_RDWR, 0777)) < 0) {
        perror("open error");
        exit(1);
    } else if (fallocate(ti.fd, 0, 0, FILE_SIZE) < 0) {
        perror("fallocate error");
        exit(1);
    } else if ((ti.base = mmap(NULL, FILE_SIZE, ti.mode == MODE_WRITE_FILE ? PROT_READ : PROT_WRITE,MAP_SHARED, ti.fd, 0)) == MAP_FAILED) {
        perror("mmap error");
        exit(1);
    }
    thrd_t thr;
    thrd_create(&thr, reader, &ti);
    for (; ti.pos < FILE_SIZE/sizeof(data); ti.pos++) {
        if (ti.mode == MODE_WRITE_MMAP) memcpy((char*)ti.base+sizeof(data)*ti.pos, data, sizeof(data));
        else if (write(ti.fd, data, sizeof(data)) != sizeof(data)) {
            perror("write error");
            exit(1);
        }
    }
    ti.pos = -1;
    thrd_join(thr, NULL);
    return 0;
}

int main(int argc, char **argv) {
    test(MODE_WRITE_FILE);
    test(MODE_WRITE_MMAP);
    return 0;
}
