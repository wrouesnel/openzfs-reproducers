#!/bin/bash
# scripts/results.sh RESULTS.tsv: the results matrix (markdown) from the CI
# check results (builder/build.sh check with RESULTS_FILE): one row per
# reproducer x target, with what the break (repro-) and the fix (fixed-)
# printed, and whether the pair is published (both as expected).
#   RESULTS.tsv: ID TARGET LABEL pass|fail|build-failed TAG RESULTLINE
set -euo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
f=${1:?results.tsv}
kernel() { (. "$T/bases/$1/base.conf"; echo "$KERNEL"); }
echo "| reproducer | target | kernel | repro- (the break) | fixed- (the fix) | published |"
echo "|---|---|---|---|---|---|"
cut -f1,2 "$f" | sort -u | while IFS=$'\t' read -r id t; do
	r=$(awk -F'\t' -v i="$id" -v t="$t" '$1 == i && $2 == t && $3 == "repro"' "$f" | tail -1)
	x=$(awk -F'\t' -v i="$id" -v t="$t" '$1 == i && $2 == t && $3 == "fixed"' "$f" | tail -1)
	cell() {
		[ -n "$1" ] || { echo "n/a"; return; }
		local st res; st=$(cut -f4 <<<"$1") res=$(cut -f6 <<<"$1")
		res=${res//|/\\|}; [ ${#res} -gt 90 ] && res="${res:0:87}..."
		case $st in pass) echo "as expected: $res" ;; fail) echo "**NOT as expected**: ${res:-no RESULT}" ;; *) echo "**$st**" ;; esac
	}
	pub=no
	if [ "$(cut -f4 <<<"$r")" = pass ] && { [ -z "$x" ] || [ "$(cut -f4 <<<"$x")" = pass ]; }; then pub=yes; fi
	echo "| $id | $t | $(kernel "$t") | $(cell "$r") | $(cell "$x") | $pub |"
done
