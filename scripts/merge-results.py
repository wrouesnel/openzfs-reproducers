# scripts/merge-results.py NEW.tsv PREV.tsv CURRENT.tsv: the results matrix
# after a CI run: NEW's rows, plus PREV's rows for the reproducer x target
# pairs NEW has no row for and that CURRENT (ID TARGET lines: the pairs the
# repository builds now) still lists.  Rows: ID TARGET LABEL STATUS TAG
# RESULT INPUTS (builder/build.sh check with RESULTS_FILE).
import sys
new = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
prev = [l.rstrip("\n").split("\t") for l in open(sys.argv[2]) if l.strip()]
cur = {tuple(l.rstrip("\n").split("\t")[:2]) for l in open(sys.argv[3]) if l.strip()}
done = {(r[0], r[1]) for r in new}
rows = new + [r for r in prev if (r[0], r[1]) not in done and (r[0], r[1]) in cur]
for r in sorted(rows, key=lambda r: (r[0], r[1], r[2])):
    print("\t".join(r))
