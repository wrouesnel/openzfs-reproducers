#!/bin/bash
# prep.sh ROOT -- run in the userland builder by builder/in/demo-disk.sh
# after the ZTS scripts are packed (ROOT/zts/LABEL, from each build's own
# commit).
#
# auto_spare_002_pos always faults file-1.  Whether the ZED then sees its
# 10 checksum ereports depends, with prefetch on, on how many of the dd's
# first two 1 MiB reads (the only demand reads; the prefetcher issues the
# rest, and speculative reads post no checksum ereport) that one leaf
# serves.  In the anymirror layouts each 64 MiB tile is on only 2-4 of the
# 5 leaves (fault/setup.ksh sets 64 MiB tiles), so a leaf may serve none of
# those reads and get no ereport at all.  With file-1 only, master's test
# fails now and then (1 in 60 runs on our VMs, 5 in 8 on @tigerblue77's);
# with every leaf faulted in turn, some anymirror leaf got 0.
#
# For each build this makes tests/functional/fault/auto_spare_002_every_leaf.ksh
# from that build's own auto_spare_002_pos.ksh, unchanged but for:
#   - an outer loop that runs the whole test once per leaf, faulting
#     file-1, then file-2, ... file-5 (FAULT_FILE), instead of file-1 only;
#   - a log_note after the read with the faulted leaf's checksum error
#     count (zpool status -p CKSUM), so the console shows what ZED had to
#     work with.
# tests.list then names it instead of the test, with a 1800 s timeout (five
# times the test).  Any edit not applying exactly once fails the build.
set -euo pipefail
R=${1:?root}
D=tests/functional/fault
T=$D/auto_spare_002_pos.ksh
V=$D/auto_spare_002_every_leaf.ksh
for L in repro fixed; do
	Z=$R/zts/$L
	[ -f "$Z/$T" ] || { echo "prep.sh: no $T in the $L build's ZTS" >&2; exit 1; }
	awk '
	/^for type in .*; do$/ && !hdr {
		print "# (prep.sh of this reproducer) every leaf in turn, not file-1 only"
		print "for FAULT_FILE in $VDEV_FILES; do"
		print "log_note \"======== faulted leaf: $FAULT_FILE\""
		print; hdr++; next
	}
	/^\tlog_must zinject$/ && !cnt {
		print
		print "\t# (prep.sh of this reproducer) what the read gave the faulted leaf"
		print "\tlog_note \"$type, faulted leaf $FAULT_FILE: $(zpool status -p $TESTPOOL | awk -v d=$FAULT_FILE '"'"'$1 == d { print $5 }'"'"') checksum errors (ZED needs 10 ereports)\""
		cnt++; next
	}
	/^done$/ { print; print "done"; out++; next }
	{ print }
	END {
		if (hdr != 1 || cnt != 1 || out != 1) {
			printf "prep.sh: edits applied %d %d %d times (want 1 each)\n", hdr, cnt, out > "/dev/stderr"
			exit 1
		}
	}' "$Z/$T" >"$Z/$V"
	chmod 755 "$Z/$V"
	n=$(grep -c ' auto_spare_002_pos ' "$Z/tests.list" || true)
	[ "$n" = 1 ] || { echo "prep.sh: the $L tests.list has $n auto_spare_002_pos lines" >&2; exit 1; }
	awk '$2 == "auto_spare_002_pos" { $2 = "auto_spare_002_every_leaf"; $5 = 1800 } { print }' \
	    "$Z/tests.list" >"$Z/tests.list.new" && mv "$Z/tests.list.new" "$Z/tests.list"
	echo "prep.sh: $L ($(head -1 "$Z/commit")): $(tr '\n' ' ' <"$Z/tests.list")"
done
# for reading (less /demo/demo.sh, the script pane): what the variant changes
{
	echo
	echo "# ======== the every-leaf variant (prep.sh of this reproducer)"
	for L in repro fixed; do
		echo
		echo "# ---- $L ($(head -1 "$R/zts/$L/commit")): diff -u auto_spare_002_pos auto_spare_002_every_leaf"
		diff -u "$R/zts/$L/$T" "$R/zts/$L/$V" | sed '1,2d' || true
	done
} >>"$R/demo.sh"
