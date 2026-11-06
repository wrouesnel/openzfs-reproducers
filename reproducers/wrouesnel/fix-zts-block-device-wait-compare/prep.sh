#!/bin/bash
# prep.sh ROOT -- run in the userland builder by builder/in/demo-disk.sh.
# For each build (repro, fixed) it takes tests/zfs-tests/include/blkdev.shlib
# from that build's own resolved commit (BUILD_repro / BUILD_fixed in
# ROOT/manifest; `make install` installs the file as it is, to
# /usr/share/zfs/zfs-tests/include/blkdev.shlib) and puts it on the demo disk
# as /demo/zts/LABEL/blkdev.shlib, with the commit in /demo/zts/LABEL/commit.
set -euo pipefail
R=${1:?root}
conf() { (set +u; . "$R/manifest"; eval "printf '%s' \"\${$1:-}\""); }
W=$(mktemp -d /tmp/b243.XXXXXX)
for L in repro fixed; do
	rs=$(conf "BUILD_$L"); [ -n "$rs" ] || continue
	repo=${rs%@*} sha=${rs##*@} G=$W/$L O=$R/zts/$L
	case $sha in *[!0-9a-f]* | '') echo "prep.sh: BUILD_$L is not resolved: $rs" >&2; exit 1 ;; esac
	git init -q "$G"
	git -C "$G" remote add origin "$repo"
	git -C "$G" fetch -q --depth=1 --filter=blob:none origin "$sha"
	mkdir -p "$O"
	git -C "$G" show "$sha:tests/zfs-tests/include/blkdev.shlib" >"$O/blkdev.shlib"
	echo "$rs" >"$O/commit"
	git -C "$G" log -1 --format='%h %s' "$sha" >>"$O/commit"
	echo "blkdev.shlib ($L): $rs"
done
# (W is in the builder container's /tmp, which goes with the container)
