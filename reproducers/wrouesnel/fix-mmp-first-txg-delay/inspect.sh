#!/bin/bash
# inspect.sh -- bug #138: what demo.sh left on its run disk.  Counts, before
# importing anything, the txg-sync uberblocks (mmp_seq 0) with an MMP config
# and mmp_delay 0 in the labels of pool demo138 (step 2); then imports it,
# shows step 1's result from /demo138/summary, exports it, and prints
# RESULT ... on disk.
set -u
P=demo138
[ -n "${DEMO_DISK:-}" ] || . /etc/demo-env
echo "# zdb -luuuu $DEMO_DISK (exported pool $P)"
cnt=$(zdb -luuuu $DEMO_DISK | awk '
    /Uberblock\[/ { delay = -1; seq = -1 } $1 == "txg" { txg = $3 }
    /mmp_delay =/ { delay = $3 } /mmp_seq =/ { seq = $3 }
    /mmp_valid =/ { if ($3 != "0" && seq == 0) { valid++; if (delay == 0) { zero++; z[txg]++ } } }
    END { s = ""; for (t in z) s = s " " t; print valid + 0, zero + 0, s }')
set -- $cnt; valid=$1 zero=$2; shift 2; txgs="$*"
echo "  txg-sync uberblocks with an MMP config: $valid, with mmp_delay 0: $zero${txgs:+ (txgs $txgs)}"
# multihost=on needs a hostid; the demo ran as 89abcdef
zgenhostid -f 89abcdef
zpool import -f -d /dev $P || { echo "RESULT ERROR: could not import $P"; exit 2; }
[ -f /$P/summary ] || { zpool export $P; echo "RESULT ERROR: no /$P/summary (demo did not finish)"; exit 2; }
echo "# /$P/summary (step 1, import of the delay-0 image): $(cat /$P/summary)"
. /$P/summary
zpool export $P
if [ "$import" = skipped ] && [ "$zero" -gt 0 ]; then
	echo "RESULT BUG on disk: step 1 imported the ACTIVE pool without an activity check ($secs s); $zero uberblocks with an MMP config and mmp_delay 0"
elif [ "$import" = checked ] && [ "$valid" -gt 0 ] && [ "$zero" -eq 0 ]; then
	echo "RESULT OK on disk: step 1 ran the activity check ($secs s); none of $valid MMP uberblocks has mmp_delay 0"
else
	echo "RESULT ERROR on disk: import=$import, delay-0 uberblocks $zero of $valid"; exit 2
fi
