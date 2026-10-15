#!/bin/bash
# inspect.sh -- bug #40 run-disk inspection (vm/demo-vm.sh 40 LABEL --disk RUNDISK).
# Tries to import the pool demo.sh left: a bug run leaves it exported but
# with its MOS meta-dnode L1 ganged (the fix build imports it, the bug build
# does not); a fix run leaves an imported-and-exported pool.
set -u
P=demo40
echo "\$ zdb -e -p /dev -dddddd $P 0 | grep ' L1 '"
zdb -e -p /dev -dddddd $P 0 2>&1 | grep -E '^ +0 +L1 |^zdb:' | head -2 | sed 's/^ */  /'
echo "\$ zpool import -d /dev $P"
if zpool import -d /dev $P; then
	zpool status $P | grep -E 'errors:' | sed 's/^ */  /'
	zpool export $P
	echo "RESULT OK on disk: the pool imports"
else
	echo "RESULT BUG on disk: the pool cannot be imported"
fi
