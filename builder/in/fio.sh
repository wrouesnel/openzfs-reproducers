#!/bin/bash
# fio.sh BINDIR   (userland builder, by demo-disk.sh; needs network)
# fio for the ZTS tests that use it, built here from its release source:
# Ubuntu's fio package pulls in the ceph, gluster and RDMA libraries
# (tens of MB).  This build has the sync, psync, mmap, posixaio and libaio
# engines (the ones ZTS uses) and needs only libc and libaio, which ZTS
# reproducers carry anyway.  Cached in /work/cache.
set -euo pipefail
V=3.36 SHA=b34b8f3c5cd074c09ea487ffe3f444e95565c214b34a73042f35b00cbaab0e17
O=${1:?bindir}
C=/work/cache; [ -d /work ] || C=$(mktemp -d /tmp/fio.XXXXXX)
if [ ! -x "$C/fio-$V/fio" ]; then
	W=$(mktemp -d /tmp/fio-build.XXXXXX)
	curl -fsSL -o "$W/fio.tar.gz" "https://github.com/axboe/fio/archive/refs/tags/fio-$V.tar.gz"
	echo "$SHA  $W/fio.tar.gz" | sha256sum -c --quiet
	tar -C "$W" -xzf "$W/fio.tar.gz"
	(cd "$W/fio-fio-$V" && ./configure --disable-native --disable-optimizations \
	    --disable-rdma --disable-rados --disable-rbd --disable-gfapi --disable-numa \
	    --disable-pmem --disable-libnfs --disable-http --disable-dfs --disable-xnvme \
	    --disable-libblkio --disable-tcmalloc >/dev/null && make -s -j"$(nproc)" fio >/dev/null 2>&1)
	mkdir -p "$C/fio-$V"
	strip -o "$C/fio-$V/fio.tmp" "$W/fio-fio-$V/fio" && mv "$C/fio-$V/fio.tmp" "$C/fio-$V/fio"
	rm -rf "$W"
fi
cp "$C/fio-$V/fio" "$O/fio"
echo "fio $V: $(ldd "$O/fio" | awk '{ print $1 }' | tr '\n' ' ')"
