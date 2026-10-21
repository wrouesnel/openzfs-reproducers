#!/bin/bash
# zts-pack.sh REPRODUCER.CONF ROOT [RESOLVED]   (userland builder, root; needs network)
# The ZTS part of a KIND=zts reproducer's demo disk.  For each build (repro,
# fixed) it takes, from that build's own commit, the ZTS pieces that the
# tests in ZTS_TESTS need, and writes them to ROOT/zts/LABEL/:
#   include/            tests/zfs-tests/include (default.cfg made from
#                       default.cfg.in as configure would, for /usr paths)
#   runner/include/     tests/test-runner/include (logapi.shlib, STF_TOOLS)
#   tests/functional/G/ each test, its group's setup/cleanup, .cfg, .kshlib
#                       and .shlib files, plus every file or directory any of
#                       them names under $STF_SUITE (closure)
#   callbacks/          tests/zfs-tests/callbacks (the failsafe)
#   tests.list          one line per test: DIR NAME PRE POST TIMEOUT, read
#                       from the runfiles (tests/runfiles/*.run) as
#                       test-runner reads them
# Each build runs its own commit's scripts: for a code fix the test commit
# and the fix both carry the new test; for a test-only fix, master's
# original test against the fixed one.  The tools (zfs-tests/bin helpers)
# come with each build (TOOLS: the ones the tests use, or '@zts' for all).
# RESOLVED: the file with the commits BUILD_repro and BUILD_fixed resolved to
# (builder/build.sh resolve); without it they must be pins (REPO@SHA).
set -euo pipefail
RC=${1:?reproducer.conf} R=${2:?root} RES=${3:-${1}}
conf() { (set +u; . "$1"; eval "printf '%s' \"\${$2:-}\""); }
TESTS=$(conf "$RC" ZTS_TESTS)
[ -n "$TESTS" ] || { echo "KIND=zts needs ZTS_TESTS" >&2; exit 1; }
W=$(mktemp -d /tmp/zts.XXXXXX)
for L in repro fixed; do
	rs=$(conf "$RES" "BUILD_$L"); [ -n "$rs" ] || continue
	# ZTS_SCRIPTS=fixed: both builds run the fix head's scripts (a branch
	# whose test came with, or after, the fix)
	[ "$(conf "$RC" ZTS_SCRIPTS)" = fixed ] && rs=$(conf "$RES" BUILD_fixed)
	repo=${rs%@*} sha=${rs##*@} G=$W/$L O=$R/zts/$L
	git init -q "$G"
	git -C "$G" remote add origin "$repo"
	git -C "$G" fetch -q --depth=1 --filter=blob:none origin "$sha"
	git -C "$G" sparse-checkout set --no-cone /tests/zfs-tests/include /tests/zfs-tests/callbacks \
	    /tests/zfs-tests/tests /tests/test-runner/include /tests/runfiles
	git -C "$G" -c advice.detachedHead=false checkout -q "$sha"
	Z=$G/tests/zfs-tests
	mkdir -p "$O/include" "$O/runner/include" "$O/tests"
	cp -p "$Z"/include/*.shlib "$Z"/include/*.cfg "$O/include/"
	sed -e 's|@sysconfdir@|/etc|g' -e 's|@zfsexecdir@|/usr/libexec/zfs|g' \
	    -e 's|@datadir@|/usr/share|g' -e 's|@[A-Z]*SAN_ENABLED@|no|g' \
	    "$Z/include/default.cfg.in" >"$O/include/default.cfg"
	cp -p "$G"/tests/test-runner/include/* "$O/runner/include/"
	[ -d "$Z/callbacks" ] && cp -pR "$Z/callbacks" "$O/"
	python3 -I - "$G" "$O" $TESTS <<'EOF'
import configparser, os, re, shutil, sys
g, o, tests = sys.argv[1], sys.argv[2], sys.argv[3:]
z = os.path.join(g, "tests/zfs-tests")
# the runfiles: section -> (pre, post, timeout), as test-runner reads them
sect = {}
for rf in sorted(os.listdir(os.path.join(g, "tests/runfiles"))):
    if not rf.endswith(".run"):
        continue
    cp = configparser.RawConfigParser()
    cp.read(os.path.join(g, "tests/runfiles", rf))
    d = cp.defaults()
    for s in cp.sections():
        names = re.findall(r"'([^']+)'", cp.get(s, "tests", fallback=""))
        for n in names:
            sect.setdefault((s, n), (cp.get(s, "pre", fallback=d.get("pre", "")),
                                     cp.get(s, "post", fallback=d.get("post", "")),
                                     cp.get(s, "timeout", fallback=d.get("timeout", "600"))))
need, lst = set(), []
for t in tests:
    t = t[:-4] if t.endswith(".ksh") else t
    d, n = os.path.split(t)
    if not os.path.exists(os.path.join(z, t + ".ksh")):
        sys.exit("zts-pack: %s.ksh is not in this commit" % t)
    pre, post, to = sect.get((d, n), ("setup", "cleanup", "600"))
    lst.append("%s %s %s %s %s" % (d, n, pre or "-", post or "-", to))
    # the test, its group's setup and cleanup, and every other file of
    # the group's directory (.cfg, .kshlib, .shlib, and data such as a
    # channel program's .zcp, which tests name through variables) but the
    # group's other tests; subdirectories only when referenced
    for f in os.listdir(os.path.join(z, d)):
        if os.path.isfile(os.path.join(z, d, f)) and f != "Makefile.am" and (
                f in (n + ".ksh", pre + ".ksh", post + ".ksh") or
                not f.endswith(".ksh")):
            need.add(os.path.join(d, f))
# everything sourced or used from $STF_SUITE, transitively
ref = re.compile(r"\$\{?STF_SUITE\}?/([A-Za-z0-9_./+-]+)")
# and the variables default.cfg sets to paths under $STF_SUITE
# (FIO_SCRIPTS=$STF_SUITE/tests/perf/fio, ...)
dvars = {}
for line in open(os.path.join(z, "include/default.cfg.in"), encoding="utf-8", errors="replace"):
    m = re.match(r"\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=\"?\$\{?STF_SUITE\}?/([A-Za-z0-9_./+-]+)", line)
    if m:
        dvars[m.group(1)] = m.group(2).rstrip("/")
vref = re.compile(r"\$\{?(" + "|".join(dvars) + r")\b\}?") if dvars else None
todo, seen = list(need), set()
while todo:
    f = todo.pop()
    if f in seen:
        continue
    seen.add(f)
    p = os.path.join(z, f)
    if os.path.isdir(p):
        for x in os.listdir(p):
            if os.path.isfile(os.path.join(p, x)):
                todo.append(os.path.join(f, x))
        continue
    if not os.path.isfile(p):
        continue
    need.add(f)
    try:
        txt = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    if vref:
        for v in vref.findall(txt):
            todo.append(dvars[v])
    for m in ref.findall(txt):
        m = m.rstrip(".")
        if m.startswith(("include/", "callbacks/")):
            continue
        todo.append(m)
for f in sorted(need):
    if f.startswith(("include/", "callbacks/")):
        continue
    dst = os.path.join(o, f)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(os.path.join(z, f), dst)
with open(os.path.join(o, "tests.list"), "w") as fh:
    fh.write("\n".join(lst) + "\n")
print("zts %s: %d files for %s" % (os.path.basename(o), len(need), " ".join(tests)))
EOF
	echo "$(git -C "$G" log -1 --format='%h %s' "$sha")" >"$O/commit"
	find "$O" -name '*.ksh' -exec chmod 755 {} +
done
rm -rf "$W"
du -sh "$R/zts" | sed 's/^/zts scripts: /'
