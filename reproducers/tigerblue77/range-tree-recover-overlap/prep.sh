#!/bin/bash
# prep.sh ROOT -- tigerblue77/range-tree-recover-overlap, run in the userland
# builder by builder/in/demo-disk.sh.  The PR's tests write a damaged space
# map with `zhack metaslab append`, which the PR adds in one commit that
# changes only cmd/zhack.c and its man page.  The repro build (the PR's base,
# openzfs/zfs master) has no such subcommand, so the test would fail there
# before it reaches the bug.  This builds ROOT/zhack-pr/zhack: the repro
# commit with cmd/zhack.c taken from the fixed commit (= the repro commit
# plus that one zhack commit; checked below), configured like the builds
# (CONFIGURE).  At run time it uses the image's own libzpool and libraries
# (the same commit, so the same ABI); /demo/bin/zhack runs it only when the
# build's own zhack lacks `metaslab append`.  Cached in /work/cache/prep-zhack.
set -euo pipefail
R=${1:?root}
m() { sed -n "s/^$1='\(.*\)'\$/\1/p" "$R/manifest" | tail -1; }
rep=$(m BUILD_repro) fix=$(m BUILD_fixed) repo=$(m REPO) conf=$(m CONFIGURE)
rs=${rep##*@} fs=${fix##*@}
[[ $rs =~ ^[0-9a-f]{40}$ && $fs =~ ^[0-9a-f]{40}$ ]] || { echo "prep.sh: unresolved builds ($rep, $fix)" >&2; exit 1; }
key=$( { cat "$0"; echo "$rs $fs $conf"; } | sha256sum | cut -c1-16)
C=/work/cache/prep-zhack/$key
if [ ! -f "$C/.done" ]; then
	W=$(mktemp -d /tmp/zhack.XXXXXX)
	git init -q "$W/src"; cd "$W/src"
	git remote add upstream "${rep%@*}"; git remote add origin "$repo"
	git fetch -q --filter=blob:none upstream "$rs"
	git fetch -q --filter=blob:none origin "$fs"
	# the fixed branch must sit on the repro commit, and only one of its
	# commits may touch cmd/zhack.c
	[ "$(git merge-base "$rs" "$fs")" = "$rs" ] || { echo "prep.sh: $fs is not based on $rs" >&2; exit 1; }
	zc=$(git rev-list "$rs..$fs" -- cmd/zhack.c)
	[ "$(echo "$zc" | wc -w)" = 1 ] || { echo "prep.sh: expected one zhack commit, got: $zc" >&2; exit 1; }
	git -c advice.detachedHead=false checkout -q "$rs"
	git checkout -q "$fs" -- cmd/zhack.c
	{
		echo "zhack for the repro image of tigerblue77/range-tree-recover-overlap (prep.sh):"
		echo "  ${rep%@*}/commit/$rs (the repro build's commit)"
		echo "  with cmd/zhack.c from $repo/commit/$fs (the PR head), that is, plus"
		echo "  $(git log -1 --format='%h %s' "$zc"), the only commit of the PR that"
		echo "  touches cmd/zhack.c. No kernel, libzpool or zdb change: those are the"
		echo "  image's own build.  configure --with-config=user $conf"
		echo "  diff against the repro commit: $(git diff --stat "$rs" | tail -1)"
	} >"$W/README"
	sh autogen.sh >"$W/autogen.log" 2>&1
	# shellcheck disable=SC2086
	./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --with-config=user $conf \
	    >"$W/configure.log" 2>&1 || { tail -40 "$W/configure.log"; exit 1; }
	make -s -j"${MAKEJOBS:-$(nproc)}" zhack >"$W/make.log" 2>&1 || { grep -E 'error|Error' "$W/make.log" | head -40; exit 1; }
	z=zhack; [ -f .libs/zhack ] && z=.libs/zhack
	head -c4 "$z" | grep -q ELF || { echo "prep.sh: $z is not a binary" >&2; exit 1; }
	u=$(./zhack 2>&1 || true)
	grep -q 'metaslab append' <<<"$u" || { echo "prep.sh: the built zhack has no metaslab append" >&2; exit 1; }
	rm -rf "$C.tmp"; mkdir -p "$C.tmp"
	cp "$z" "$C.tmp/zhack"; strip --strip-unneeded "$C.tmp/zhack"
	cp "$W/README" "$C.tmp/README"
	touch "$C.tmp/.done"; rm -rf "$C"; mv "$C.tmp" "$C"
	cd /; rm -rf "$W"
fi
mkdir -p "$R/zhack-pr"
cp "$C/zhack" "$C/README" "$R/zhack-pr/"
cat "$R/zhack-pr/README"
