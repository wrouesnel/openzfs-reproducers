#!/bin/bash
# inspect.sh -- bug #39: read a demo run's files from its disk.
# vm/demo-vm.sh 39 LABEL --disk RUNDISK [--check]
set -u
P=demo39; H=${DOSRO_BIN:-/demo/dosro}
zpool import -f -d /dev $P || { echo "RESULT ERROR: no pool $P"; exit 2; }
bad=0
for f in append trunc; do
	echo "--- $f.txt ($($H get /$P/$f.txt)):"; cat /$P/$f.txt; echo
	grep -q owner /$P/$f.txt && bad=1
done
zpool export $P
if [ $bad = 1 ]; then
	echo "RESULT BUG on disk: the owner's writes are in the read-only files"
else
	echo "RESULT OK on disk: the read-only files hold no writes from their owner"
fi
