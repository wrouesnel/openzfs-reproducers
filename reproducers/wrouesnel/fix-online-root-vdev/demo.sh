#!/bin/bash
# demo.sh -- openzfs/zfs#19659: `zpool online POOL <pool GUID>` (and
# `zpool detach POOL <pool GUID>`) hand the root vdev to the kernel, because
# zpool looks up a numeric name as a vdev GUID and the root vdev's GUID is
# the pool GUID.  vdev_online() reopens the root vdev's vdev_top (NULL), and
# spa_vdev_detach_enter() passes it to vdev_rebuild_stop_wait(): a NULL
# pointer dereference.  On Linux zpool is "Killed" with the pool's config
# locks (online) or the pool namespace lock (detach) still held, and the
# pool hangs until a reboot; on FreeBSD the host panics.
#
# Image version of the ZTS tests cli_root/zpool_online/zpool_online_003_neg
# and cli_root/zpool_detach/zpool_detach_002_neg (branch fix-online-root-vdev).
# Run as root:  /demo/demo.sh      about 10 s (fixed) or 40 s (unfixed).
# What you will see: a mirror of the first two run disks with 8 MiB of
# data, `zpool status` after every step, then
#   zpool online POOL <pool GUID>, zpool online -e POOL <pool GUID>,
#   zpool detach POOL <pool GUID>, each followed by a bounded `zpool sync`:
#     unfixed: the first command is "Killed" (exit 137), the kernel log
#       shows the NULL dereference in vdev_reopen(), and `zpool sync`
#       still hangs after 20 s: "RESULT BUG"
#     fixed: each is refused (online: exit 1, "operation not supported on
#       this type of pool"; detach: exit 255, "only applicable to mirror
#       and replacing vdevs"),
#       the pool stays ONLINE, a leaf offline/online and a scrub work, the
#       pool exports and imports, and the data checksum matches: "RESULT OK"
set -u
pool=p19659
read -r -a V <<< "${DEMO_DISKS:-}"
if [ ${#V[@]} -lt 2 ]; then
	d=/var/tmp/p19659d; mkdir -p $d
	V=(); for i in 0 1; do rm -f $d/v$i; truncate -s 512M $d/v$i; V+=($d/v$i); done
fi
v0=${V[0]} v1=${V[1]}
# bounded CMD...: run CMD for at most 20 s.  A command stuck in the kernel
# (D state) ignores signals, so `timeout` would wait for it forever: run it
# in the background and give up on it instead.
bounded() {
	local o; o=$(mktemp)
	"$@" >"$o" 2>&1 &
	local p=$! i
	for i in $(seq 40); do
		kill -0 $p 2>/dev/null || { wait $p; local rc=$?; cat "$o"; rm -f "$o"; return $rc; }
		sleep 0.5
	done
	cat "$o"; rm -f "$o"
	return 124
}
status() {
	echo "# zpool status -v $pool"
	bounded zpool status -v $pool | sed -n '/state:/p; /scan:/p; /config:/,/errors:/p' | grep -v '^$'
	[ "${PIPESTATUS[0]}" = 124 ] && echo "  (zpool status did not answer in 20 s)"
}
synced() { bounded zpool sync $pool; }
zpool destroy -f $pool 2>/dev/null
zpool create -f -o cachefile=none $pool mirror $v0 $v1 ||
    { echo "RESULT ERROR: could not create pool $pool"; exit 2; }
dd if=/dev/urandom of=/$pool/file bs=1M count=8 2>/dev/null; zpool sync $pool
sum=$(sha256sum </$pool/file)
guid=$(zpool get -H -o value guid $pool)
echo "# pool $pool: mirror $v0 $v1, 8 MiB file; pool GUID $guid"
status
dmesg -C 2>/dev/null
for cmd in "online" "online -e" "detach"; do
	echo
	echo "# zpool $cmd $pool $guid"
	bounded zpool $cmd $pool $guid; rc=$?
	echo "  exit status $rc"
	if ! synced; then
		echo "# zpool sync $pool did not return in 20 s: the pool is hung"
		echo "# kernel log:"
		dmesg | grep -aE 'BUG:|RIP: 0010|\]  [a-z_]+\+0x' | head -8 | sed 's/^/  /'
		echo
		echo "RESULT BUG: zpool $cmd with the pool GUID exited $rc and hung pool $pool"
		exit 1
	fi
	status
	# zpool online fails with 1, zpool detach with 255 (for any error)
	want=1; [ "$cmd" = detach ] && want=255
	[ $rc = $want ] || { echo "RESULT ERROR: zpool $cmd with the pool GUID exited $rc, not $want"; exit 2; }
done
echo
echo "# zpool offline $pool $v0; zpool online $pool $v0; zpool wait -t resilver $pool; zpool scrub -w $pool"
zpool offline $pool $v0 && zpool online $pool $v0 && zpool wait -t resilver $pool &&
    zpool scrub -w $pool || { echo "RESULT ERROR: leaf offline/online/scrub failed"; exit 2; }
status
echo "# zpool export $pool; zpool import $pool"
zpool export $pool && zpool import -o cachefile=none -d "$(dirname "$v0")" $pool 2>/dev/null ||
    zpool import -o cachefile=none $pool || { echo "RESULT ERROR: export/import failed"; exit 2; }
status
if [ "$(sha256sum </$pool/file)" = "$sum" ]; then
	echo "# data checksum matches"
	zpool export $pool
	echo
	echo "RESULT OK: zpool online, online -e and detach of the pool GUID were refused and the pool stayed healthy"
else
	echo "RESULT ERROR: data checksum mismatch"; exit 2
fi
