#!/bin/bash
# inspect.sh -- bug #69 run-disk inspection (vm/demo-vm.sh 69 LABEL --disk RUNDISK...).
# The bug is in the scan state, not the data: after either build the pool
# imports as a two-way mirror (the attached disk was detached again) and
# scrubs clean.  Exports it again.
set -u
P=p69
zpool import -d /dev $P || { echo "RESULT ERROR on disk: no exported pool $P"; exit 2; }
zpool scrub -w $P
zpool status $P | sed -n '/scan:/,/errors:/p' | grep -v '^$'
ok=$(zpool status $P | grep -c 'errors: No known data errors')
zpool export $P
[ "$ok" = 1 ] && echo "RESULT OK on disk: pool $P imports and scrubs clean" ||
    echo "RESULT BUG on disk: scrub found errors"
