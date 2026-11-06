#!/bin/bash
# demo.sh -- ZTS block_device_wait() (tests/zfs-tests/include/blkdev.shlib)
# compares the `udevadm settle` time as a string.
#
#   typeset elapsed=$((SECONDS - start))
#   [[ $elapsed > 60 ]] && log_note udevadm settle time too long: $elapsed
#
# `>` inside [[ ]] compares text, and ksh93's $SECONDS is fractional, so
# elapsed is e.g. 7.60261983489990234: "7..." sorts after "60", so a 7.6 s
# settle gets a "too long" note, and anything starting with 1-5 (10-59 s,
# but also 100 s or more) gets none.  The fix (wrouesnel/zfs
# fix-zts-block-device-wait-compare) compares numbers:
#   if (( elapsed > 60 )); then log_note ...; fi
# Only the note is affected: the function's status is 0 either way.
#
# The demo sources this build's own blkdev.shlib (/demo/zts/LABEL, from the
# build's commit, as `make install` installs it) in ksh93 and calls the real
# block_device_wait with a stand-in `udevadm` first in PATH whose `settle`
# sleeps SETTLE seconds (is_linux, is_freebsd and log_note are stubs; no
# pool, no disks).  The settles run at once, so a run takes about 100 s.
# The note is due exactly when the settle took more than 60 s.
#
# Builds:
#   repro  the branch's parent (openzfs/zfs master's blkdev.shlib)
#          -> "RESULT BUG: block_device_wait ..." (note at 7.6 s, none at 100.3 s)
#   fixed  the branch head
#          -> "RESULT OK: block_device_wait ..." (notes only above 60 s)
# Run as root:  /demo/demo.sh
set -u
build=${DEMO_BUILD:-repro}
S=/demo/zts/$build/blkdev.shlib
SETTLES="0.2 7.6 30 61.5 100.3"
die() { echo "RESULT ERROR: $*"; exit 2; }
[ -f "$S" ] || die "no $S"
command -v ksh >/dev/null || die "no ksh"
W=$(mktemp -d /tmp/bdw.XXXXXX) || die "mktemp"
mkdir -p "$W/bin"

# the stand-in udevadm: "settle" takes $SETTLE seconds (ksh93's sleep takes
# fractions), anything else (trigger) does nothing
cat >"$W/bin/udevadm" <<'X'
#!/demo/bin/ksh
[[ $1 == settle ]] && sleep "${SETTLE:-0}"
exit 0
X
# the harness: ZTS's stubs, the shlib under test, the real block_device_wait
cat >"$W/bwait.ksh" <<'X'
#!/demo/bin/ksh -p
function is_linux { true; }
function is_freebsd { false; }
function log_note { echo "NOTE: $*"; }
. "$1"
PATH=$2:$PATH
typeset t0=$SECONDS
block_device_wait
typeset rc=$?
printf 'SETTLE=%s status=%d took=%.1f\n' "$SETTLE" $rc $((SECONDS - t0))
X
chmod 755 "$W/bin/udevadm" "$W/bwait.ksh"

echo "build: $build  $(sed -n 1p /demo/zts/$build/commit)"
echo "       $(sed -n 2p /demo/zts/$build/commit)"
echo "ksh:   $(ksh -c 'echo ${.sh.version}' 2>/dev/null)"
echo
echo "== the code under test: block_device_wait in $S"
grep -n -B3 -A2 'elapsed > 60' "$S" | sed 's/^/   /'
echo
echo "== block_device_wait with udevadm settle taking: $SETTLES s (all at once, ~100 s)"
for s in $SETTLES; do
	SETTLE=$s ksh "$W/bwait.ksh" "$S" "$W/bin" >"$W/out.$s" 2>&1 &
done
wait
bad=0 wrong=
rows=()
for s in $SETTLES; do
	sed 's/^/   /' "$W/out.$s"
	if grep -q '^NOTE: udevadm settle time too long' "$W/out.$s"; then got=yes; else got=no; fi
	if awk -v s="$s" 'BEGIN { exit !(s > 60) }'; then want=yes; else want=no; fi
	st=$(sed -n 's/.*status=\([0-9]*\).*/\1/p' "$W/out.$s")
	if [ "$got" = "$want" ]; then v=ok
	elif [ "$got" = yes ]; then v="WRONG: false note"; bad=$((bad + 1)); wrong="$wrong false note at ${s}s,"
	else v="WRONG: note missing"; bad=$((bad + 1)); wrong="$wrong no note at ${s}s,"
	fi
	[ -n "$st" ] || die "no result for settle ${s}s: $(cat "$W/out.$s")"
	rows+=("$(printf '   %8s s  %-6s  %-12s  %-10s  %s' "$s" "$st" "$got" "$want" "$v")")
done
rm -f "$W"/out.* "$W/bwait.ksh" "$W/bin/udevadm"; rmdir "$W/bin" "$W"

echo
echo "== $build: block_device_wait's \"udevadm settle time too long\" note ($(sed -n 2p /demo/zts/$build/commit | cut -d' ' -f1))"
printf '   %10s  %-6s  %-12s  %-10s  %s\n' settle status "note printed" "due (>60s)" verdict
printf '%s\n' "${rows[@]}"
echo
if [ "$bad" -gt 0 ]; then
	echo "RESULT BUG: block_device_wait notes the settle time wrongly in $bad of 5 cases:${wrong%,} (string compare)"
	exit 1
fi
echo "RESULT OK: block_device_wait notes the settle time exactly when it took more than 60 s (5 of 5 cases)"
