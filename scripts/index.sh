#!/usr/bin/env bash
# index.sh: regenerate docs/index.md, the table of what this repository holds:
# each reproducer with its fork branch, zfs-bug-hunt bug number, upstream PR
# (and its state) and which images are published on GHCR, then every branch
# of github.com/wrouesnel/zfs with its reproducer and PR.
# Needs gh (authenticated) and network access; GHCR tags are read anonymously.
# Usage: scripts/index.sh [OUT]   (default docs/index.md)
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-docs/index.md}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

tok=$(curl -fsS "https://ghcr.io/token?scope=repository:wrouesnel/openzfs-reproducers:pull" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
# GHCR returns at most 1000 tags per request: follow the pages (last=)
last=; : >"$tmp/tags.txt"
while :; do
	page=$(curl -fsS -H "Authorization: Bearer $tok" \
	    "https://ghcr.io/v2/wrouesnel/openzfs-reproducers/tags/list?n=1000${last:+&last=$last}" |
	    python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("tags") or []))')
	[ -n "$page" ] || break
	printf '%s\n' "$page" >>"$tmp/tags.txt"
	[ "$(printf '%s\n' "$page" | wc -l)" -ge 1000 ] || break
	last=$(printf '%s\n' "$page" | tail -1)
done
python3 -c 'import json,sys; print(json.dumps({"tags": [l.strip() for l in open(sys.argv[1]) if l.strip()]}))' "$tmp/tags.txt" >"$tmp/tags.json"
for s in open merged closed; do
	gh pr list -R openzfs/zfs --author wrouesnel --state "$s" --limit 300 \
	    --json number,headRefName,state,title,url
done | python3 -c 'import json,sys; d=[]; [d.extend(json.loads(l)) for l in sys.stdin if l.strip()]; print(json.dumps(d))' >"$tmp/prs.json"
git ls-remote https://github.com/wrouesnel/zfs.git 'refs/heads/*' >"$tmp/branches.txt"
git ls-files 'reproducers/*/*/reproducer.conf' >"$tmp/confs.txt"

python3 - "$tmp" "$out" <<'EOF'
import json, os, re, shlex, sys, datetime, glob
tmp, out = sys.argv[1], sys.argv[2]
tags = json.load(open(f"{tmp}/tags.json")).get("tags") or []
prs = json.load(open(f"{tmp}/prs.json"))
branches = {}
for line in open(f"{tmp}/branches.txt"):
    sha, ref = line.split()
    branches[ref.removeprefix("refs/heads/")] = sha

def conf(path):
    d = {}
    for line in open(path):
        m = re.match(r"^([A-Z_a-z]+)=(.*)$", line.strip())
        if m:
            try:
                v = shlex.split(m.group(2))
                d[m.group(1)] = v[0] if v else ""
            except ValueError:
                d[m.group(1)] = m.group(2).strip("'\"")
    return d

# zfs-bug-hunt bug numbers from the coverage inventory (branch -> "#NN")
bugs = {}
for line in open("docs/coverage.md"):
    cols = [c.strip() for c in line.split("|")]
    if len(cols) > 3 and re.match(r"^[\w.-]+$", cols[1]) and cols[2].startswith("#"):
        bugs[cols[1]] = cols[2]

prs_by_branch = {}
for p in prs:
    prs_by_branch.setdefault(p["headRefName"], []).append(p)

def pr_cell(branch, listed):
    seen, cells = set(), []
    for p in sorted(prs_by_branch.get(branch, []), key=lambda p: p["number"]):
        seen.add(p["number"])
        cells.append(f"[#{p['number']}]({p['url']}) {p['state'].lower()}")
    for n in re.findall(r"\d+", listed or ""):
        if int(n) not in seen:
            cells.append(f"[#{n}](https://github.com/openzfs/zfs/pull/{n})")
    return "<br>".join(cells) or "–"

def issues_cell(listed):
    return ", ".join(f"[#{n}](https://github.com/openzfs/zfs/issues/{n})"
                     for n in re.findall(r"\d+", listed or "")) or "–"

TARGETS = set(os.listdir("bases"))

def images(user, slug, c):
    out = {}
    for label in ("repro", "fixed"):
        pre = f"{label}-{user}-{slug}-"
        # TARGET-KERNEL with a known TARGET: not a longer slug that starts
        # the same (fix-x-v3-lustre's tags also start with fix-x-)
        out[label] = sorted({t[len(pre):] for t in tags if t.startswith(pre)
                             and any(t[len(pre):].startswith(k + "-") for k in TARGETS)})
    # a pair; or, for a reproducer with one build (a stress suite: fixed-
    # only, a self-test: repro- only), that build's images
    ls = [l for l in ("repro", "fixed") if c.get(f"BUILD_{l}")]
    targets = sorted(set.intersection(*(set(out[l]) for l in ls))) if ls else []
    if not targets:
        return "not yet"
    names = sorted({re.sub(r"-\d.*$", "", t) for t in targets})
    return f"{len(targets)} target(s): " + ", ".join(names)

rows, have = [], {}
for path in sorted(l.strip() for l in open(f"{tmp}/confs.txt") if l.strip()):
    user, slug = path.split("/")[1:3]
    c = conf(path)
    br = c.get("BRANCH", slug)
    repo = c.get("REPO", f"https://github.com/{user}/zfs").removesuffix(".git")
    fixed = c.get("BUILD_fixed", "").rsplit("@", 1)[-1]
    if user == "wrouesnel":
        # the branch's own reproducer (named after it) wins over a
        # companion (SLUG-stress and the like)
        if br not in have or slug == re.sub(r"[^a-z0-9]+", "-", br.lower()).strip("-"):
            have[br] = f"{user}/{slug}"
        head = branches.get(br)
        branch = f"[{br}]({repo}/tree/{br})"
        if head is None:
            branch += " (not on the fork)"
        elif re.fullmatch(r"[0-9a-f]{40}", fixed) and head != fixed:
            # a pinned fix (the usual spec is the branch, which tracks the head)
            branch += f" (head {head[:10]}, image pins {fixed[:10]})"
    else:
        branch = f"[{user}:{br}]({repo}/tree/{br})"
    status = f"BLOCKED: {c['BLOCKED']}" if c.get("BLOCKED") else "in CI"
    rows.append("| " + " | ".join([
        f"[{user}/{slug}](../reproducers/{user}/{slug}/)",
        bugs.get(br, "–"), branch, pr_cell(br, c.get("PRS")),
        issues_cell(c.get("ISSUES")), images(user, slug, c), status,
        c.get("TITLE", "").replace("|", "\\|")]) + " |")

brows = []
for br in sorted(branches):
    if br in ("master", "main"):
        continue
    rep = have.get(br)
    brows.append("| " + " | ".join([
        f"[{br}](https://github.com/wrouesnel/zfs/tree/{br})",
        bugs.get(br, "–"),
        f"[{rep}](../reproducers/{rep}/)" if rep else "–",
        pr_cell(br, "")]) + " |")

pub = sum(1 for r in rows if "target(s)" in r)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
with open(out, "w") as f:
    f.write(f"""# Index: reproducers, fork branches and PRs

Generated by `scripts/index.sh` on {now}; rerun it to refresh. Images are
`ghcr.io/wrouesnel/openzfs-reproducers:repro-…` (the bug) and `fixed-…` (the
fix), built and published by CI from the pinned public commits; see the
[README](../README.md) for how to run one and [coverage.md](coverage.md) for
why a fork branch has no reproducer.

{len(rows)} reproducers, {pub} with published images. {len(brows)} branches on
[wrouesnel/zfs](https://github.com/wrouesnel/zfs).

## Reproducers

"Bug" is the zfs-bug-hunt tracker number. "Images" counts the targets that
have both a `repro-` and a `fixed-` image on GHCR (for a reproducer with one
build, such as a stress suite's `fixed-` only, that build's images). A branch note means the
fork branch has moved past the commit the images are built from.

| reproducer | bug | fork branch | upstream PR | issues | images | status | title |
|---|---|---|---|---|---|---|---|
""")
    f.write("\n".join(rows) + "\n")
    f.write("""
## Branches on wrouesnel/zfs

| branch | bug | reproducer | upstream PR |
|---|---|---|---|
""")
    f.write("\n".join(brows) + "\n")
print(f"{out}: {len(rows)} reproducers ({pub} published), {len(brows)} branches")
EOF
