#!/bin/bash
# prep.sh ROOT -- bug #242 census pair, run in the userland builder by
# builder/in/demo-disk.sh after the ZTS scripts are packed (ROOT/zts/LABEL,
# from each build's own commit).
#
# For each build it makes tests/functional/raidz/raidz_expand_boundary_census.ksh
# from that build's own raidz_expand_boundary_repair.ksh: the same setup
# (pool, file, first pause, zeroing, import) and the same search loop, with
#   - the loop header (master: "for (( i = 0; i < 20 && straddling == 0; i++ ))",
#     the fix: "while (( straddling == 0 ))") replaced by "while :", and its
#     try budget (20, or none) passed on as census_budget;
#   - census_stop after the loop's "reflow offset ... after the second pause"
#     note (it ends the loop when the reflow is done, offset 0);
#   - census_judge after the loop's own check of the file's blocks;
#   - census_report after the loop, in place of the rest of the test (the
#     scrubs need the reflow still running).
# census.kshlib (this reproducer) has the hooks.  tests.list then names the
# census instead of the test, and the runner (ROOT/demo.sh, this image's
# copy of builder/in/zts-run.sh) prints the census again just before its
# RESULT line, so that the console's last screen shows it.  Any of these
# edits not applying exactly once fails the build.
set -euo pipefail
R=${1:?root}
T=tests/functional/raidz/raidz_expand_boundary_repair.ksh
C=tests/functional/raidz/raidz_expand_boundary_census.ksh
for L in repro fixed; do
	Z=$R/zts/$L
	[ -f "$Z/$T" ] || { echo "prep.sh: no $T in the $L build's ZTS" >&2; exit 1; }
	install -m 644 "$R/census.kshlib" "$Z/tests/functional/raidz/census.kshlib"
	awk '
	/^\. \$STF_SUITE\/include\/libtest\.shlib$/ && !inc {
		print
		print "# raidz_expand_boundary_census.ksh: made from this commit'"'"'s"
		print "# raidz_expand_boundary_repair.ksh by prep.sh of the reproducer"
		print "# wrouesnel/fix-zts-raidz-boundary-repair-skip (openzfs-reproducers)."
		print ". $STF_SUITE/tests/functional/raidz/census.kshlib"
		inc++; next
	}
	/^(for|while) .*straddling == 0.*; do$/ && !hdr {
		b = 0
		if (match($0, /< *[0-9]+/)) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); b = s + 0 }
		print "# (census) the loop was: " $0
		print "census_budget=" b
		print "while :; do"
		hdr++; inloop = 1; next
	}
	inloop && /log_note "reflow offset \$offset2 after the second pause"$/ {
		print
		print "\tif ! census_stop \"$offset2\"; then"
		print "\t\tlog_must zpool import -o cachefile=none -d $devdir $TESTPOOL"
		print "\t\tbreak"
		print "\tfi"
		st++; next
	}
	inloop && /^\tdone$/ { print; print "\tcensus_judge \"$offset2\""; jd++; next }
	inloop && /^done$/ { print; print "census_report"; out++; exit }
	{ print }
	END {
		if (inc != 1 || hdr != 1 || st != 1 || jd != 1 || out != 1) {
			printf "prep.sh: census edits applied %d %d %d %d %d times (want 1 each)\n", \
			    inc, hdr, st, jd, out > "/dev/stderr"
			exit 1
		}
	}' "$Z/$T" >"$Z/$C"
	chmod 755 "$Z/$C"
	grep -q ' raidz_expand_boundary_repair ' "$Z/tests.list" ||
	    { echo "prep.sh: the $L tests.list has no raidz_expand_boundary_repair" >&2; exit 1; }
	sed -i 's/ raidz_expand_boundary_repair / raidz_expand_boundary_census /' "$Z/tests.list"
	echo "prep.sh: $L ($(cat "$Z/commit")): $C, budget $(sed -n 's/^census_budget=//p' "$Z/$C")"
done
# the runner: the census again, just before the RESULT
n=$(grep -c '^	if \[ -n "\$fails" \]; then$' "$R/demo.sh" || true)
[ "$n" = 1 ] || { echo "prep.sh: the runner's RESULT block not found ($n)" >&2; exit 1; }
sed -i '/^	if \[ -n "\$fails" \]; then$/i\	[ -s /run/zts/census ] \&\& { echo; cat /run/zts/census; }	# (prep.sh of this reproducer: the census before the RESULT)' "$R/demo.sh"
# for reading (less /demo/demo.sh, the script pane): what the census changes
{
	echo
	echo "# ======== the census (prep.sh of this reproducer): each build's test, and its census"
	for L in repro fixed; do
		echo
		echo "# ---- $L ($(cat "$R/zts/$L/commit")): diff -u test census"
		diff -u "$R/zts/$L/$T" "$R/zts/$L/$C" | sed '1,2d' || true
	done
	echo
	echo "# ======== census.kshlib"
	cat "$R/census.kshlib"
} >>"$R/demo.sh"
