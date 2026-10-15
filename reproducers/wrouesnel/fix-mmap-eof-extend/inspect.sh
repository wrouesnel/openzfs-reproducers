#!/bin/bash
# inspect.sh -- openzfs/zfs#19267 run-disk inspection (--disk RUNDISK).
# Imports the pool demo.sh left (exported) and prints bytes 10-19 of each
# file as stored on disk: "STALE-DATA" (the bytes stored through mmap past
# EOF) after the unfixed build, zeros after the fix.  Exports it again.
# Linux and FreeBSD: checks whichever of the demo's files exist (FreeBSD has
# no fallocate file; "copy" has its last page at 4096, so bytes 4106-4115).
set -u
P=demo27
echo "\$ zdb -e -p /dev -d $P     (zdb on the exported pool)"
zdb -e -p /dev -d $P 2>&1 | grep -E '^Dataset' | sed 's/^/  /'
echo "\$ zpool import -d /dev $P"
zpool import -d /dev $P || { echo "RESULT ERROR: no pool $P on the disk"; exit 2; }
zpool status -P $P | sed -n '/NAME/,/^$/p'
echo "\$ ls -l /$P"; ls -l /$P
bad=0 err=0
n=0
for m in truncate write fallocate copy; do
	[ -f /$P/$m ] || continue
	n=$((n + 1)); off=10; [ $m = copy ] && off=4106
	b=$(dd if=/$P/$m bs=1 skip=$off count=10 2>/dev/null | od -An -tx1 | tr -s ' ')
	c=$(dd if=/$P/$m bs=1 skip=$off count=10 2>/dev/null | tr -c '[:print:]' .)
	echo "  on disk $m: bytes $off-$((off + 9)):$b  $c"
	case $b in *"53 54 41 4c 45 2d 44 41 54 41"*) bad=$((bad + 1)) ;; *"00 00 00 00 00 00 00 00 00 00"*) ;; *) err=$((err + 1)) ;; esac
done
[ $n -gt 0 ] || err=1
echo "\$ od -c /$P/truncate | head -3"; od -c /$P/truncate | head -3
zpool export $P
if [ $err -gt 0 ]; then echo "RESULT ERROR on disk: $err files unreadable or unexpected"
elif [ $bad -gt 0 ]; then echo "RESULT BUG on disk: $bad/$n files hold STALE-DATA past the old EOF"
else echo "RESULT OK on disk: $n/$n files read zeros past the old EOF"; fi
