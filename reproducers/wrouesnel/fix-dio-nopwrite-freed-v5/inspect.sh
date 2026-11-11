#!/bin/bash
# inspect.sh -- bug #57: import a demo run's pool and check it.
# vm/demo-vm.sh 57 LABEL --disk RUNDISK [--check]
# After a fix run the pool was exported clean.  After a bug run it was hung
# at the VERIFY when the VM was destroyed: the import rolls back to the last
# synced txg, which does not have the Direct I/O write.
set -u
P=demo57
zpool import -f -d /dev $P || { echo "RESULT ERROR: no pool $P"; exit 2; }
zpool scrub -w $P
zpool status -v $P | grep -E 'scan:|errors:'
ls -l /$P/fs
bad=0
zpool status $P | grep -q 'No known data errors' || bad=1
zpool export $P
if [ $bad = 1 ]; then
	echo "RESULT BUG on disk: the pool has errors"
else
	echo "RESULT OK on disk: the pool imports and scrubs clean (after a bug run: the hung txg never reached the disk)"
fi
