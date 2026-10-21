#!/bin/bash
# scripts/new-reproducer.sh [-u USER] [-t TEST]... [-f] BRANCH
# Scaffolds reproducers/USER/SLUG/reproducer.conf for a fix branch that is
# public on github.com/USER/zfs (default USER: wrouesnel), as a ZTS
# reproducer (KIND=zts): the demo runs the branch's ZTS test(s) on the
# break and on the fix (docs/reproducer-format.md, "ZTS reproducers").
#
# From the branch's commits on top of openzfs/zfs master it takes:
#   BUILD_fixed  the branch head (spec REPO@BRANCH)
#   BUILD_repro  the commit before the first commit that changes code
#                (the test-only commit of a "test, then fix" branch:
#                REPO@BRANCH~N), or the master commit the branch is based on
#                when every commit is test-only (a ZTS fix: master runs the
#                original test; openzfs/zfs@merge-base(BRANCH))
# (build specs: docs/reproducer-format.md; builder/build.sh resolves them)
#   ZTS_TESTS    the .ksh tests the branch adds or changes (setup/cleanup
#                and helpers excluded); -t TEST (tests/functional/G/NAME)
#                replaces them, e.g. when only a .kshlib changed
#   TOOLS        the ZTS helper programs (builder/zts-tools.txt) the tests,
#                their group's files and libtest.shlib name
#   PRS          the openzfs/zfs PR whose head is this branch (gh), if any
# When the branch's first commit changes code (no test-only commit first),
# the break is master and both builds run the fix head's test scripts
# (ZTS_SCRIPTS=fixed).  A test-only branch is a flake fix: the scaffold says
# so, and ZTS_ITERATIONS / RUNS_* are to be set from what the local check
# shows.  -f overwrites an existing reproducer.conf.
#
# Then:  builder/build.sh verify USER/SLUG; builder/build.sh all USER/SLUG ubuntu24
#
# ZFS_GIT: a git directory to use (default work/git/zfs, a blobless clone
# made on first use); it fetches the branch and upstream master.
set -euo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
GHUSER=wrouesnel TESTS=() FORCE=
while getopts u:t:f o; do
	case $o in u) GHUSER=$OPTARG ;; t) TESTS+=("$OPTARG") ;; f) FORCE=1 ;; *) exit 2 ;; esac
done
shift $((OPTIND - 1))
BR=${1:?usage: scripts/new-reproducer.sh [-u USER] [-t TEST]... [-f] BRANCH}
SLUG=$(printf '%s' "$BR" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
ID=$GHUSER/$SLUG D=$T/reproducers/$ID
[ -f "$D/reproducer.conf" ] && [ -z "$FORCE" ] && { echo "$D/reproducer.conf exists (-f to overwrite)" >&2; exit 1; }
REPO=https://github.com/$GHUSER/zfs
G=${ZFS_GIT:-$T/work/git/zfs}
if [ ! -d "$G" ]; then
	git init -q --bare "$G"
	git -C "$G" remote add upstream https://github.com/openzfs/zfs
	git -C "$G" config gc.auto 0
fi
git -C "$G" fetch -q --filter=blob:none upstream +master:refs/zr/upstream-master
git -C "$G" fetch -q --filter=blob:none "$REPO" "+refs/heads/$BR:refs/zr/$GHUSER/$BR"
head=$(git -C "$G" rev-parse "refs/zr/$GHUSER/$BR")
mb=$(git -C "$G" merge-base "$head" refs/zr/upstream-master)
commits=$(git -C "$G" rev-list --reverse "$mb..$head")
[ -n "$commits" ] || { echo "$BR has no commits on top of master" >&2; exit 1; }
files() { git -C "$G" diff-tree --no-commit-id --name-only -r "$1"; }
testonly() { ! files "$1" | grep -qv '^tests/'; }
addstest() { files "$1" | grep -q '^tests/zfs-tests/tests/'; }
codeish() { files "$1" | grep -v -e '^tests/' -e '^\.github/' -e '^man/' -e '^scripts/' | grep -q .; }
# the break: from the first commit that adds or changes a test, the last
# commit before the next one that changes code (the fix).  No test before
# a code change: master, with the fix head's test scripts on both builds.
# Only test commits: a ZTS fix, master with the original test.
repro= kind=flake scripts= seen= prev=$mb
for c in $commits; do
	if [ -z "$seen" ]; then
		if addstest "$c"; then seen=1
		elif codeish "$c"; then kind=fix
		fi
	elif codeish "$c" && ! testonly "$c"; then
		kind=fix repro=$prev; break
	fi
	prev=$c
done
if [ $kind = fix ] && [ -z "$repro" ]; then repro=$mb scripts=fixed; fi
[ -n "$repro" ] || repro=$mb
if [ ${#TESTS[@]} -eq 0 ]; then
	mapfile -t TESTS < <(git -C "$G" diff --name-only --diff-filter=AM "$mb" "$head" -- 'tests/zfs-tests/tests/*.ksh' |
	    sed 's|^tests/zfs-tests/||; s|\.ksh$||' | grep -v -E '/(setup|cleanup)$' | sort -u)
fi
[ ${#TESTS[@]} -gt 0 ] || { echo "no .ksh test changed on $BR: name the test(s) with -t tests/functional/GROUP/NAME" >&2; exit 1; }
# helpers: named in the tests, their groups' other scripts, or libtest
tools=$(for t in "${TESTS[@]}"; do
	d=tests/zfs-tests/${t%/*}
	git -C "$G" ls-tree --name-only "$head" "$d/" | grep -E '\.(ksh|kshlib|shlib|cfg)$' |
	    while read -r f; do git -C "$G" show "$head:$f"; done
done | { cat; git -C "$G" show "$head:tests/zfs-tests/include/libtest.shlib"; } |
    grep -owF -f <({ grep -v '^#' "$T/builder/zts-tools.txt" | tr ' ' '\n'
	# and the helpers of this commit's tests/zfs-tests/cmd (a new one the branch adds)
	git -C "$G" ls-tree -r --name-only "$head" tests/zfs-tests/cmd/ | sed -n 's|.*/\([^/]*\)\.c$|\1|p'; } | grep . | sort -u) |
    sort -u | tr '\n' ' ' | sed 's/ $//')
# ZED tests (zed_setup/zed_start in the group's scripts) need zed itself
for t in "${TESTS[@]}"; do
	d=tests/zfs-tests/${t%/*}
	git -C "$G" ls-tree --name-only "$head" "$d/" | grep -E '\.(ksh|kshlib|shlib|cfg)$' |
	    while read -r f; do git -C "$G" show "$head:$f"; done
done | grep -qwE 'zed_setup|zed_start' && tools="${tools:+$tools }zed"
pr=$(gh pr list -R openzfs/zfs --head "$BR" --author "$GHUSER" --state all --json number,headRefOid \
    --jq ".[] | select(.headRefOid == \"$head\") | .number" 2>/dev/null | head -1 || true)
if [ $kind = fix ]; then
	title=$(for c in $(git -C "$G" rev-list --reverse "$repro..$head"); do codeish "$c" && { git -C "$G" log -1 --format=%s "$c"; break; }; done)
	[ -n "$title" ] || title=$(git -C "$G" log -1 --format=%s "$head")
else
	title=$(git -C "$G" log -1 --format=%s "$head")
fi
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
mkdir -p "$D"
{
	echo "# Reproducer $ID (docs/reproducer-format.md); scaffolded by scripts/new-reproducer.sh"
	echo "TITLE=$(q "$title")"
	echo "REPO='$REPO'"
	echo "BRANCH=$(q "$BR")"
	echo "AUTHOR='@$GHUSER'"
	echo "REPORTER=''"
	echo "PRS='$pr'"
	echo "ISSUES=''"
	if [ $kind = fix ]; then
		if [ "$repro" = "$mb" ]; then
			echo "# repro = the openzfs/zfs master commit the branch is based on; fixed = the branch head"
			echo "BUILD_repro=$(q "https://github.com/openzfs/zfs@merge-base($BR)")"
		else
			echo "# repro = the branch's test commit (the test, no fix); fixed = the branch head"
			echo "BUILD_repro=$(q "$REPO@$BR~$(git -C "$G" rev-list --first-parent --count "$repro..$head")")"
		fi
	else
		echo "# a test-only (ZTS) fix: repro = master with the original test; fixed = the branch head"
		echo "BUILD_repro=$(q "https://github.com/openzfs/zfs@merge-base($BR)")"
	fi
	echo "BUILD_fixed=$(q "$REPO@$BR")"
	echo "CONFIGURE='--enable-debug'"
	echo "# KIND=zts: the demo runs these ZTS tests, from each build's own commit"
	echo "KIND='zts'"
	echo "ZTS_TESTS='${TESTS[*]}'"
	[ -n "$scripts" ] && echo "# the test came with the fix: both builds run the fix head's scripts" && echo "ZTS_SCRIPTS='fixed'"
	echo "TOOLS='$tools'"
	echo "EXPECT_repro='RESULT BUG'"
	echo "EXPECT_fixed='RESULT OK'"
	if [ $kind = flake ]; then
		echo "# a flake: set ZTS_ITERATIONS (runs per demo) and RUNS_repro/MIN_MATCH_repro"
		echo "# from what the local check shows"
		echo "ZTS_ITERATIONS=1"
	fi
	echo "MEM=2048"
	echo "CPUS=2"
	echo "TIMEOUT=1800"
	echo "DISKS=1"
	echo "DISK_SIZE=16G"
} >"$D/reproducer.conf"
echo "$ID: $kind; repro ${repro:0:10}$([ "$repro" = "$mb" ] && echo ' (master)'), fixed ${head:0:10}; tests: ${TESTS[*]}; tools: ${tools:-none}${pr:+; PR #$pr}"
