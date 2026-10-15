#!/bin/bash
# inspect.sh -- bug #62 run-disk inspection (vm/demo-vm.sh 62 LABEL --disk RUNDISK).
# The bug leaves nothing on disk (it only keeps a read-only snapshot mounted);
# this checks that the pool demo.sh left is exported cleanly and still holds
# snapshot demo62/fs@s1 with its file, then exports it again.
set -u
P=demo62
echo "\$ zpool import -d /dev    (lists the exported pool)"; zpool import -d /dev
echo "\$ zpool import -d /dev $P"
zpool import -d /dev $P || { echo "RESULT ERROR: no pool $P on the disk (or not exported cleanly)"; exit 2; }
zpool status -x $P
zfs list -t snapshot -r $P
c=$(cat /$P/fs/.zfs/snapshot/s1/file 2>&1)
echo "\$ cat /$P/fs/.zfs/snapshot/s1/file   -> $c"
zpool export $P
[ "$c" = hello ] && echo "RESULT OK on disk: pool $P imported cleanly, snapshot s1 reads back" ||
    echo "RESULT ERROR on disk: snapshot file read '$c'"
