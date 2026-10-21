#!/bin/bash
# scripts/build-local.sh [TARGET...]: build, check and push every committed
# reproducer locally (docs/ci.md), one reproducer x target job at a time,
# TARGETs in the order given (default: ubuntu24, then every other Linux
# target).  A pair is pushed only when both images print their expected
# RESULT.  The build specs are resolved first (builder/build.sh resolve): a
# job is skipped when every image's tag is on GHCR and its build label
# (io.github.wrouesnel.zfs-repro.build, read with skopeo inspect) is the
# commit its spec resolves to now.  Otherwise it is built, checked and
# pushed, replacing the tags.  FORCE=1 builds every job.
# Logs: work/local/LOG and work/local/ID/TARGET.log; results rows (as the
# old CI wrote them) go to work/local/results.tsv.
# ONLY_IDS limits the reproducers, as for builder/build.sh; FIRST_IDS (space
# separated, in order) are built before the rest on each target.
set -uo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
cd "$T"
B=builder/build.sh
OUT=${ZFS_REPRO_WORK:-$T/work}/local
IMAGE=${ZFS_REPRO_IMAGE:-ghcr.io/wrouesnel/openzfs-reproducers}
mkdir -p "$OUT"
export RESULTS_FILE=$OUT/results.tsv
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$OUT/LOG"; }

ts=("$@")
if [ ${#ts[@]} -eq 0 ]; then
	ts=(ubuntu24)
	for d in bases/*/base.conf; do
		t=${d#bases/}; t=${t%/base.conf}
		[ "$t" = ubuntu24 ] && continue
		grep -q '^OS=.\?Linux' "$d" && ts+=("$t")
	done
fi
# committed reproducers only: an untracked directory isn't public yet
ids=$($B ids | while read -r id; do
	[ -n "$(git ls-tree HEAD "reproducers/$id/reproducer.conf")" ] && echo "$id"
done)
if [ -n "${FIRST_IDS:-}" ]; then
	ids=$( { for id in $FIRST_IDS; do grep -qxF "$id" <<<"$ids" && echo "$id"; done; echo "$ids"; } | awk '!seen[$0]++')
fi
published=$(skopeo list-tags "docker://$IMAGE" 2>/dev/null | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["Tags"]))')
# the build label of a published tag ("" if none)
pub_build() {
	grep -qxF "$1" <<<"$published" || return 0
	skopeo inspect --no-tags "docker://$IMAGE:$1" 2>/dev/null |
	    python3 -c 'import json,sys; print((json.load(sys.stdin).get("Labels") or {}).get("io.github.wrouesnel.zfs-repro.build", ""))'
}

for t in "${ts[@]}"; do
	for id in $ids; do
		$B targets "$id" | grep -qx "$t" || continue
		# resolve the specs once for this job; `all` builds what this saved
		if ! res=$($B resolve "$id" 2>&1); then
			log "not built $id $t: cannot resolve: $(echo "$res" | tr '\n' ' ' | cut -c1-200)"
			continue
		fi
		need= why=
		while read -r l want _; do
			tag=$($B tag "$id" "$l" "$t")
			have=$(pub_build "$tag")
			[ "$have" = "$want" ] || { need=1; why="$why $l: ${have:-not on GHCR} -> ${want#https://github.com/}"; }
		done <<<"$res"
		[ -n "$need" ] || [ -n "${FORCE:-}" ] || { log "skip $id $t (on GHCR, builds$(awk '{ printf " %s %s", $1, substr($2, length($2) - 39, 10) }' <<<"$res"))"; continue; }
		mkdir -p "$OUT/$id"
		log "build $id $t${why:+ ($why )}"
		if REUSE_RESOLVED=1 $B all "$id" "$t" >"$OUT/$id/$t.log" 2>&1; then
			if $B push "$id" "$t" >>"$OUT/$id/$t.log" 2>&1; then
				log "pushed $id $t"
			else
				log "PUSH FAILED $id $t"
			fi
		else
			log "not pushed $id $t: $(grep -a -E '^(RESULT |PANIC: |no RESULT line|SUMMARY )' "$OUT/$id/$t.log" | tr '\n' ' ' | cut -c1-200)"
		fi
	done
done
log "done ${ts[*]}"
