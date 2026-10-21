#!/usr/bin/env python3
"""scripts/aliases.py: PR and issue alias tags for the published images.

    python3 -I scripts/aliases.py [--dry-run] [--image ghcr.io/OWNER/openzfs-reproducers]

For every published pair (repro-USER-SLUG-TARGET-KERNEL and
fixed-USER-SLUG-TARGET-KERNEL; the registry is the source of truth) it finds:

  * PRs: openzfs/zfs pull requests whose head is the reproducer's branch
    (REPO + BRANCH in reproducers/USER/SLUG/reproducer.conf, or PRS there),
    open or merged.  A PR gets aliases only if its head commit is the commit
    the fixed- image was built from (and the repro- image is the build the
    reproducer names as the break):
        repro-pr<N>-TARGET-KERNEL   fixed-pr<N>-TARGET-KERNEL
  * Issues: ISSUES in reproducer.conf; the PR's closing issues (GraphQL
    closingIssuesReferences) and "Closes/Fixes/Resolves #N" in its body; and
    "Closes/Fixes/Resolves #N" or "Issue #N" in the fix branch's own commit
    messages (so they work before a PR exists).  N must be an issue, not a PR:
        repro-issue<N>-TARGET-KERNEL   fixed-issue<N>-TARGET-KERNEL
    When several reproducers name the same issue, the owner of the issue
    aliases is the one whose PR closes it; else the one whose fixed build
    has the newest commit; ties go to the id that sorts first.

An alias is the same manifest under another tag (skopeo copy within the
registry: no rebuild, same digest).  It is (re)pointed only at a published,
passing pair, so when a PR's head moves on, its aliases stay on the last
built head until that head's images are built and pass; the images' labels
(io.github.wrouesnel.zfs-repro.build) say which commit they hold.
Needs skopeo (logged in to push) and GITHUB_TOKEN for the API.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE = os.environ.get("ZFS_REPRO_IMAGE", "ghcr.io/wrouesnel/openzfs-reproducers")
DRY = "--dry-run" in sys.argv
if "--image" in sys.argv:
    IMAGE = sys.argv[sys.argv.index("--image") + 1]
UPSTREAM = "openzfs/zfs"
CLOSES = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s+(?:openzfs/zfs)?#(\d+)", re.I)
ISSUE_TRAILER = re.compile(r"^\s*(?:issue|closes|fixes|resolves|related)[ :]+(?:openzfs/zfs)?#(\d+)", re.I | re.M)


def api(path, data=None):
    req = urllib.request.Request("https://api.github.com/" + path if not path.startswith("http") else path,
                                 data=json.dumps(data).encode() if data else None)
    req.add_header("Accept", "application/vnd.github+json")
    tok = os.environ.get("GITHUB_TOKEN")
    if tok:
        req.add_header("Authorization", "Bearer " + tok)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def conf(path):
    """the KEY=VALUE lines of a shell-style conf file (values as the shell sees them)"""
    out = subprocess.run(["bash", "-c", 'set -a; . "$1" >/dev/null; env -0', "-", path],
                         capture_output=True, check=True).stdout.decode()
    return dict(kv.split("=", 1) for kv in out.split("\0") if "=" in kv)


def tags():
    out = subprocess.run(["skopeo", "list-tags", "docker://" + IMAGE], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)["Tags"]


def tag_of(label, uid, slug, rest):
    """the build.sh tag rule: at most 128 chars, the slug cut + hashed if longer"""
    import hashlib
    full = f"{label}-{uid}-{slug}-{rest}"
    if len(full) <= 128:
        return full
    h = hashlib.sha256(full.encode()).hexdigest()[:8]
    mx = 128 - len(label) - 1 - len(uid) - 1 - 9 - len(rest) - 1
    return f"{label}-{uid}-{slug[:mx].rstrip('-')}-{h}-{rest}"


def is_issue(n, cache={}):
    if n not in cache:
        try:
            cache[n] = "pull_request" not in api(f"repos/{UPSTREAM}/issues/{n}")
        except Exception:
            cache[n] = False
    return cache[n]


def prs_for(c):
    """PRs on openzfs/zfs whose head is the reproducer's branch (open or merged)"""
    repo = c["REPO"].rstrip("/").removesuffix(".git").split("github.com/")[-1]
    owner = repo.split("/")[0]
    found = {}
    for st in ("open", "closed"):
        try:
            for p in api(f"repos/{UPSTREAM}/pulls?state={st}&head={owner}:{c['BRANCH']}&per_page=20"):
                found[p["number"]] = p
        except Exception as e:
            print(f"  (PR lookup for {owner}:{c['BRANCH']} failed: {e})")
    for n in c.get("PRS", "").split():
        if int(n) not in found:
            try:
                found[int(n)] = api(f"repos/{UPSTREAM}/pulls/{n}")
            except Exception:
                pass
    return found


def closing_issues(pr):
    nums = set(int(n) for n in CLOSES.findall(pr.get("body") or ""))
    try:
        q = {"query": "query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){closingIssuesReferences(first:20){nodes{number}}}}}",
             "variables": {"o": "openzfs", "r": "zfs", "n": pr["number"]}}
        d = api("graphql", q)
        nums |= {n["number"] for n in d["data"]["repository"]["pullRequest"]["closingIssuesReferences"]["nodes"]}
    except Exception:
        pass
    return nums


def branch_issues(c, sha):
    """issue references in the commits the fix branch adds to openzfs/zfs master"""
    repo = c["REPO"].rstrip("/").removesuffix(".git").split("github.com/")[-1]
    try:
        d = api(f"repos/{repo}/compare/{UPSTREAM.split('/')[0]}:master...{sha}")
    except Exception:
        try:
            d = api(f"repos/{UPSTREAM}/compare/master...{repo.split('/')[0]}:{sha}")
        except Exception:
            return set(), ""
    msgs = [x["commit"]["message"] for x in d.get("commits", [])]
    date = d["commits"][-1]["commit"]["committer"]["date"] if d.get("commits") else ""
    nums = set()
    for m in msgs:
        nums |= {int(n) for n in CLOSES.findall(m)} | {int(n) for n in ISSUE_TRAILER.findall(m)}
    return nums, date


def built(label, uid, slug, rest, cache={}):
    """the commit a published image was built from: the sha of its build label
    (io.github.wrouesnel.zfs-repro.build, REPO@SHA; reproducer.conf names a
    spec such as a branch, resolved when the image was built)"""
    tag = tag_of(label, uid, slug, rest)
    if tag not in cache:
        out = subprocess.run(["skopeo", "inspect", "--no-tags", f"docker://{IMAGE}:{tag}"], capture_output=True, text=True)
        labels = (json.loads(out.stdout).get("Labels") or {}) if out.returncode == 0 else {}
        cache[tag] = labels.get("io.github.wrouesnel.zfs-repro.build", "").rsplit("@", 1)[-1]
    return cache[tag]


def merge_base(c, sha):
    repo = c["REPO"].rstrip("/").removesuffix(".git").split("github.com/")[-1]
    try:
        return api(f"repos/{UPSTREAM}/compare/master...{repo.split('/')[0]}:{sha}")["merge_base_commit"]["sha"]
    except Exception:
        return ""


def copy(src, dst):
    print(f"  {dst}  <- {src}")
    if not DRY:
        subprocess.run(["skopeo", "copy", "--all", "--preserve-digests", "-q",
                        f"docker://{IMAGE}:{src}", f"docker://{IMAGE}:{dst}"], check=True)


def main():
    have = set(tags())
    repros = {}
    for uid in sorted(os.listdir(os.path.join(ROOT, "reproducers"))):
        for slug in sorted(os.listdir(os.path.join(ROOT, "reproducers", uid))):
            p = os.path.join(ROOT, "reproducers", uid, slug, "reproducer.conf")
            if os.path.exists(p):
                repros[f"{uid}/{slug}"] = conf(p)
    issue_claims = {}   # issue -> [(closes, date, id)]
    plan = []
    for rid, c in repros.items():
        uid, slug = rid.split("/", 1)
        pre = f"fixed-{uid}-{slug}-"
        # the published pairs of this reproducer: TARGET-KERNEL suffixes with both tags
        rests = sorted(t[len(f"repro-{uid}-{slug}-"):] for t in have if t.startswith(f"repro-{uid}-{slug}-"))
        rests = [r for r in rests if not c.get("BUILD_fixed") or tag_of("fixed", uid, slug, r) in have]
        if not rests or not c.get("BUILD_fixed"):
            continue
        # what each target's pair was built from (targets can lag behind
        # while a moved branch is rebuilt); the newest build first
        builds = {r: (built("repro", uid, slug, r), built("fixed", uid, slug, r)) for r in rests}
        rests = [r for r in rests if all(builds[r])]
        if not rests:
            continue
        fixed_sha = builds[rests[0]][1]
        for r in rests:
            if r.startswith("ubuntu24-"):
                fixed_sha = builds[r][1]
        prs = prs_for(c)
        issues = {int(n) for n in c.get("ISSUES", "").split()}
        closes = set()
        for n, pr in sorted(prs.items()):
            ok = [r for r in rests if builds[r][1] == pr["head"]["sha"]]
            if not ok:
                print(f"{rid}: PR #{n} head {pr['head']['sha'][:12]} is not a built fix ({', '.join(sorted({b[1][:12] for b in builds.values()}))}): no PR aliases until it is built and passes")
                continue
            # the break must be the PR's own test commit or the master it is based on
            try:
                shas = {x["sha"] for x in api(f"repos/{UPSTREAM}/pulls/{n}/commits?per_page=100")}
            except Exception:
                shas = set()
            mb = merge_base(c, pr["head"]["sha"])
            good = [r for r in ok if builds[r][0] in shas or builds[r][0] in (pr["base"]["sha"], mb)]
            if good:
                plan.append((rid, f"pr{n}", good))
            else:
                print(f"{rid}: PR #{n}: the break is neither a PR commit nor its base: no PR aliases")
            cl = closing_issues(pr)
            closes |= cl
            issues |= cl
        bi, date = branch_issues(c, fixed_sha)
        issues |= bi
        for n in sorted(issues):
            if is_issue(n):
                issue_claims.setdefault(n, []).append((n in closes, date, rid, rests))
            else:
                print(f"{rid}: #{n} is a PR, not an issue: skipped")
    for n, claims in sorted(issue_claims.items()):
        # the owner: a reproducer whose PR closes the issue, else the newest
        # fixed build (commit date), else the id that sorts first
        claims.sort(key=lambda x: x[2])
        claims.sort(key=lambda x: x[1], reverse=True)
        claims.sort(key=lambda x: not x[0])
        best = claims[0]
        others = [x[2] for x in claims if x[2] != best[2]]
        print(f"issue #{n}: {best[2]}" + (f" (also: {', '.join(others)})" if others else ""))
        plan.append((best[2], f"issue{n}", best[3]))
    for rid, alias, rests in plan:
        uid, slug = rid.split("/", 1)
        print(f"{rid}: {alias}")
        for r in rests:
            for label in ("repro", "fixed"):
                src = tag_of(label, uid, slug, r)
                if src in have:
                    copy(src, f"{label}-{alias}-{r}")


if __name__ == "__main__":
    main()
