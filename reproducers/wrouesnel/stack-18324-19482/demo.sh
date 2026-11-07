#!/bin/bash
# demo.sh -- RAID-Z expansion space accounting (openzfs/zfs#18324) after an
# expansion by several disks at once (openzfs/zfs#19482).
#
# Question (@owlshrimp on #18324): does #19482 break #18324's accounting?
# #18324 charges each block at the deflate ratio of the width it was born
# with, and counts free space at the current width.  #19482 records one width
# step per added disk, in consecutive txgs, so blocks born in those txgs get
# the intermediate widths.
#
# Pools are raidz1 on 1G disks, ashift=12, recordsize=128k, compression off.
#   A  3 disks, file1, ONE `zpool attach` of 3 disks (3 -> 6), file2,
#      export/import, then delete everything (files and snapshot)
#   B  the same with three single attaches (3 -> 4 -> 5 -> 6)
#   C  a fresh 6-wide raidz1 with the same data (the target numbers)
#   D  as A, but raidz_expansion_accounting is enabled only after the
#      expansion (feature disabled at create)
#   E  as A, with blocks born during the reflow (paused with
#      raidz_expand_max_reflow_bytes) and small synced files written while
#      the expansion completes, so that some are born in the txgs of the
#      intermediate width steps (4 and 5 wide)
# After every step: zpool status -v, then the pool and dataset space and the
# vdev's accounting excess (org.openzfs:raidz_expand_acct_excess).
# Checks: A == B; the pool's used space follows the root dataset's; numbers
# survive export/import; in E every 16K file is charged at the ratio of the
# width it was born at (3, 4, 5 or 6: st_blocks); after deleting everything
# the excess is no more than the remaining metadata can hold, zdb -b finds no
# leaks, and the expanded pool's available space matches the fresh 6-wide
# pool's (C).  Without #18324 that last one is at the 3-wide ratio.  On the
# debug build, a block freed with more excess than it was charged trips an
# ASSERT (a panic).
# Images: repro = #19482 alone (no raidz_expansion_accounting: D is skipped
# and the free space stays at the 3-wide ratio -> RESULT BUG); fixed = the
# stack of #18324 and #19482 -> RESULT OK.
# Run disks: 6 (DEMO_DISKS), or files in /var/tmp/demoacct.
set -u
P=acct; FS=$P/fs; PP=/sys/module/zfs/parameters
MB=$((1 << 20))
read -r -a DISKS <<< "${DEMO_DISKS:-}"
FILEDIR=
if [ ${#DISKS[@]} -lt 6 ]; then
	FILEDIR=/var/tmp/demoacct; mkdir -p $FILEDIR
	DISKS=(); for i in 1 2 3 4 5 6; do truncate -s 1G $FILEDIR/d$i; DISKS+=($FILEDIR/d$i); done
fi
OLD=("${DISKS[@]:0:3}"); NEW=("${DISKS[@]:3:3}")
F1=${F1:-768} F2=${F2:-512}	# MiB written before / after the expansion
HAVE_ACCT=0
zpool upgrade -v 2>/dev/null | grep -q raidz_expansion_accounting && HAVE_ACCT=1
HAVE_MULTI=0
zpool upgrade -v 2>/dev/null | grep -q raidz_expansion_multi && HAVE_MULTI=1
fail=(); declare -A V

run() { echo "+ $*"; "$@"; }
status() { zpool status -v $P | grep -v '^$'; }
gp() { local v; v=$(zpool get -Hp -o value "$1" $P 2>/dev/null); [[ $v =~ ^[0-9]+$ ]] && echo "$v" || echo -; }
excess() {	# the raidz vdev's accounting excess, as synced (zdb), or -
	local zap
	zap=$(zdb -C $P 2>/dev/null | awk '/com.delphix:vdev_zap_top/ { print $2; exit }')
	[ -n "$zap" ] || { echo -; return; }
	zdb -dddd $P "$zap" 2>/dev/null | awk '/raidz_expand_acct_excess/ { print $NF; f=1 } END { if (!f) print 0 }'
}
settle() { local i; for i in 1 2 3 4; do zpool sync $P; done; }
row() {	# SCENARIO STEP: one table row, saved in V[SCENARIO/STEP/key]
	local s=$1 t=$2 k
	settle
	V[$s/$t/size]=$(gp size) V[$s/$t/alloc]=$(gp allocated) V[$s/$t/free]=$(gp free)
	V[$s/$t/usable]=$(gp usable) V[$s/$t/pused]=$(gp used)
	V[$s/$t/used]=$(zfs get -Hp -o value used $P) V[$s/$t/avail]=$(zfs get -Hp -o value available $P)
	V[$s/$t/excess]=$(excess)
	V[$s/$t/width]=$(zpool list -vHP $P | awk '$1 ~ /^raidz1/ { f=1; next } f { n++ } END { print n+0 }')
	echo ">>> $s $t: width ${V[$s/$t/width]}, $(for k in size alloc free usable pused used avail; do printf '%s %s  ' "$k" "$(mib "${V[$s/$t/$k]}")"; done)excess ${V[$s/$t/excess]}"
	TABLE+=("$(printf '| %-2s | %-28s | %5s | %9s | %9s | %9s | %9s | %9s | %9s | %9s | %12s |' "$s" "$t" "${V[$s/$t/width]}" \
	    "$(mib "${V[$s/$t/size]}")" "$(mib "${V[$s/$t/alloc]}")" "$(mib "${V[$s/$t/free]}")" "$(mib "${V[$s/$t/usable]}")" \
	    "$(mib "${V[$s/$t/pused]}")" "$(mib "${V[$s/$t/used]}")" "$(mib "${V[$s/$t/avail]}")" "${V[$s/$t/excess]}")")
}
ratio() {	# WIDTH: the deflate ratio (x512) of a 128K block on raidz1 WIDTH-wide, ashift 12
	awk -v w="$1" 'BEGIN { s = 32; rows = int((s + w - 2) / (w - 1)); t = s + rows; t += t % 2; print int(131072 / (t * 8)) }'
}
mib() { [[ $1 =~ ^-?[0-9]+$ ]] && awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }' || echo -; }
pct() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.2f", 100 * d / b }'; }
near() {	# NAME A B TOL_PCT: record a failure unless A is within TOL% of B
	local p; p=$(pct "$2" "$3")
	if awk -v p="$p" -v t="$4" 'BEGIN { exit !(p <= t) }'; then
		echo "    ok:   $1: $(mib "$2") vs $(mib "$3") MiB (${p}% <= $4%)"
	else
		echo "    FAIL: $1: $(mib "$2") vs $(mib "$3") MiB (${p}% > $4%)"; fail+=("$1")
	fi
}
check_used() {	# SCENARIO STEP: the pool's used space follows the root dataset's
	local s=$1 t=$2 d
	[ "${V[$s/$t/pused]}" = - ] && return
	d=$(( ${V[$s/$t/pused]} - ${V[$s/$t/used]} )); d=${d#-}
	if [ $d -le $((4 * MB)) ]; then echo "    ok:   $s $t: pool used - root used = $(mib $d) MiB"
	else echo "    FAIL: $s $t: pool used - root used = $(mib $d) MiB"; fail+=("$s $t used"); fi
}
check_zero() {	# SCENARIO: excess back to 0 after deleting everything, and zdb -b clean
	local s=$1 x out
	# What is left is the pool's own metadata; the excess of blocks born
	# since the boundary is at most (asize / 512) * (6-wide - 3-wide ratio).
	x=${V[$s/deleted/excess]} max=$(( ${V[$s/deleted/alloc]} / 512 * ($(ratio 6) - $(ratio 3)) ))
	[ "$x" = - ] && x=0
	if [ "$x" -le "$max" ]; then echo "    ok:   $s: excess after deleting everything $x <= $max (left: $(mib ${V[$s/deleted/alloc]}) MiB allocated)"
	else echo "    FAIL: $s: excess after deleting everything $x > $max (left: $(mib ${V[$s/deleted/alloc]}) MiB allocated)"; fail+=("$s excess"); fi
	run zpool export $P
	if [ -n "$FILEDIR" ]; then out=$(zdb -e -p $FILEDIR -b $P 2>&1); else out=$(zdb -e -b $P 2>&1); fi
	echo "$out" | grep -E 'leak|No leaks|block sum|space map|bp count' | sed 's/^/    zdb: /'
	if echo "$out" | grep -q 'No leaks'; then echo "    ok:   $s: zdb -b: no leaks"
	else echo "    FAIL: $s: zdb -b"; fail+=("$s zdb"); fi
	run zpool import $IMPORTDIR $P
}
IMPORTDIR=; [ -n "$FILEDIR" ] && IMPORTDIR="-d $FILEDIR"
fresh() {	# SCENARIO WIDTH [create options]: a new pool on the first WIDTH disks
	local s=$1 w=$2; shift 2
	echo; echo "=================== scenario $s ==================="
	zpool destroy -f $P 2>/dev/null
	for d in "${DISKS[@]}"; do zpool labelclear -f $d 2>/dev/null; done
	echo 0 > $PP/raidz_expand_max_reflow_bytes
	run zpool create -f -o ashift=12 "$@" -O compression=off -O recordsize=128k $P raidz1 "${DISKS[@]:0:$w}" ||
	    { echo "RESULT ERROR: zpool create"; exit 2; }
	run zfs create $FS
	status
	[ $HAVE_ACCT = 1 ] && zpool get -H -o property,value feature@raidz_expansion_accounting $P
	row $s created
}
write() {	# NAME MIB
	run dd if=/dev/urandom of=/$FS/$1 bs=1M count=$2 status=none
}
wait_size() {	# SIZE: wait for the pool to grow past SIZE (the new metaslabs come after zpool attach -w)
	local i; for i in $(seq 60); do [ "$(gp size)" -gt "$1" ] && return; sleep 1; done
}
expand_multi() {
	local sz; sz=$(gp size)
	run zpool attach -w $P raidz1-0 "${NEW[@]}" || { echo "RESULT ERROR: zpool attach (several disks)"; exit 2; }
	wait_size $sz; zpool wait -t scrub $P
}
expand_single() {
	local d sz
	for d in "${NEW[@]}"; do
		sz=$(gp size)
		run zpool attach -w $P raidz1-0 $d || { echo "RESULT ERROR: zpool attach"; exit 2; }
		wait_size $sz; zpool wait -t scrub $P
	done
}
delete_all() {
	run rm -rf /$FS/*
	for s in $(zfs list -H -t snapshot -o name -r $P); do run zfs destroy $s; done
}
TABLE=()

echo "build: ${DEMO_BUILD:-local} $(cat /sys/module/zfs/version 2>/dev/null)  raidz_expansion_accounting: $HAVE_ACCT  raidz_expansion_multi: $HAVE_MULTI"
[ $HAVE_MULTI = 1 ] || { echo "RESULT ERROR: this build has no raidz_expansion_multi (#19482)"; exit 2; }

# ---- C: a fresh 6-wide pool (the reference) ----
fresh C 6
write file1 $F1; run zfs snapshot $FS@s1; row C file1
write file2 $F2; row C file2
delete_all; row C deleted; check_zero C
status

# ---- A: one attach of three disks ----
fresh A 3
write file1 $F1; run zfs snapshot $FS@s1; row A file1
expand_multi; status; row A "expanded 3->6 (one attach)"
write file2 $F2; row A file2
run zpool export $P; run zpool import $IMPORTDIR $P; status; row A "export/import"
delete_all; row A deleted; check_zero A
status

# ---- B: three single attaches ----
fresh B 3
write file1 $F1; run zfs snapshot $FS@s1; row B file1
expand_single; status; row B "expanded 3->6 (3 attaches)"
write file2 $F2; row B file2
delete_all; row B deleted; check_zero B

# ---- D: feature enabled after the expansion ----
if [ $HAVE_ACCT = 1 ]; then
	fresh D 3 -o feature@raidz_expansion_accounting=disabled
	write file1 $F1; row D file1
	expand_multi; status; row D "expanded 3->6 (one attach)"
	write file2 256; row D "file2 (feature disabled)"
	run zpool set feature@raidz_expansion_accounting=enabled $P
	zpool get -H -o property,value feature@raidz_expansion_accounting $P
	echo "+ zpool sync x4   (blocks born up to the activation txg + 3 keep the 3-wide ratio)"
	settle
	write file3 256; row D "file3 (feature active)"
	run zpool export $P; run zpool import $IMPORTDIR $P; row D "export/import"
	delete_all; row D deleted; check_zero D
fi

# ---- E: blocks born during the reflow and in the width-step txgs ----
fresh E 3
write file1 $F1; row E file1
run zfs set recordsize=16k $FS
sz=$(gp size)
echo "+ echo $((64 * MB)) > $PP/raidz_expand_max_reflow_bytes   (pause the reflow)"
echo $((64 * MB)) > $PP/raidz_expand_max_reflow_bytes
run zpool attach $P raidz1-0 "${NEW[@]}" || { echo "RESULT ERROR: zpool attach (several disks)"; exit 2; }
sleep 3; status
write reflow 128; row E "written during the reflow"
mkdir -p /$FS/small
rm -f /tmp/acct.stop
# Three writers of 16K files and a `zpool sync` loop, so that every txg
# around the end of the expansion, including the width steps, has blocks.
for j in 1 2 3; do
	( i=0; while [ ! -e /tmp/acct.stop ] && [ $i -lt 4000 ]; do
		dd if=/dev/urandom of=/$FS/small/w$j.$i bs=16k count=1 status=none; i=$((i + 1)); done ) &
done
( while [ ! -e /tmp/acct.stop ]; do zpool sync $P; done ) &
echo "+ echo 0 > $PP/raidz_expand_max_reflow_bytes   (resume, while 16K files are written and every txg is synced)"
echo 0 > $PP/raidz_expand_max_reflow_bytes
run zpool wait -t raidz_expand $P
wait_size $sz; sleep 3; touch /tmp/acct.stop; wait; rm -f /tmp/acct.stop
zpool wait -t scrub $P
status; row E "expanded 3->6 (one attach)"
ACCT_TXG=999999999	# no raidz_expansion_accounting: every block at the legacy ratio
[ $HAVE_ACCT = 1 ] && ACCT_TXG=$(zdb -dddd $P 1 2>/dev/null | awk '/raidz_expand_acct_txg/ { print $NF }')
echo "    raidz_expansion_accounting boundary: txg ${ACCT_TXG}"
read -r -a STEPS <<< "$(zdb -C $P | awk '/raidz_expand_txgs\[/ { print $2 }' | tr '\n' ' ')"
echo "    width steps (raidz_expand_txgs): ${STEPS[*]}   (first: width 4, then 5, then 6)"
echo "    the deflate ratio (x512) of a 128K block at each width, raidz1 ashift=12: $(for w in 3 4 5 6; do printf 'w%s %s  ' $w "$(ratio $w)"; done)"
# Each 16K file is one L0 block in its dnode, so its st_blocks is that block's
# charged (deflated) size: (asize / 512) * the ratio it was charged at.
zdb -ddddd $FS 2>/dev/null | awk '
	/^ +Object +lvl/ { getline; obj = $1; seen = 0; next }
	/ L0 [0-9]+:[0-9a-f]+:[0-9a-f]+ / && !seen { split($3, d, ":"); split("", b)
		for (i = 1; i <= NF; i++) if ($i ~ /^B=/) split(substr($i, 3), b, "/")
		if (b[2] != "") print obj, b[2], d[3]; seen = 1 }' | while read -r o b h; do echo "$o $b $((16#$h))"; done > /tmp/acct.births
(cd /$FS/small && stat -c '%i %b' -- *) > /tmp/acct.blocks
# st_blocks is round(charged size / 512) + 1 (the dnode's slot).
awk -v steps="${STEPS[*]}" -v acct="$ACCT_TXG" -v r3="$(ratio 3)" -v r4="$(ratio 4)" -v r5="$(ratio 5)" -v r6="$(ratio 6)" '
	function blk(u, r) { return int((u * r + 256) / 512) + 1 }
	BEGIN { ns = split(steps, st, " "); r[3] = r3; r[4] = r4; r[5] = r5; r[6] = r6 }
	NR == FNR { birth[$1] = $2; asz[$1] = $3; next }
	($1 in birth) {
		w = 3; for (i = 1; i <= ns; i++) if (birth[$1] >= st[i]) w++
		u = asz[$1] / 512
		exp_r = (birth[$1] <= acct) ? r[3] : r[w]
		n[w]++; sb[w] += $2; eb[w] += blk(u, exp_r); fb[w] += blk(u, r[6])
		if ($2 != blk(u, exp_r)) bad[w]++
		if (!(w in lo) || birth[$1] < lo[w]) lo[w] = birth[$1]
		if (!(w in hi) || birth[$1] > hi[w]) hi[w] = birth[$1]
		e[w] = exp_r
	}
	END {
		print "    | width at birth | files | birth txgs | st_blocks (avg) | expected at birth ratio | ratio | at the 6-wide ratio | mismatches |"
		for (w = 3; w <= 6; w++) if (n[w])
			printf "    | %14d | %5d | %4d-%-5d | %15.2f | %23.2f | %5d | %19.2f | %10d |\n", w, n[w], lo[w], hi[w], sb[w] / n[w], eb[w] / n[w], e[w], fb[w] / n[w], bad[w] + 0
		for (w = 3; w <= 6; w++) tb += bad[w]
		exit tb > 0
	}' /tmp/acct.births /tmp/acct.blocks || { echo "    FAIL: E: a small file is charged at a ratio other than its birth width's"; fail+=("E birth ratio"); }
for w in 4 5; do
	awk -v steps="${STEPS[*]}" -v w=$w 'BEGIN { split(steps, st, " ") } { if ($2 >= st[w - 3] && $2 < st[w - 2]) n++ } END { exit !(n > 0) }' /tmp/acct.births ||
	    echo "    (no small file was born at width $w this run: the step txgs were missed)"
done
write file2 $F2; row E file2
run zpool export $P; run zpool import $IMPORTDIR $P; row E "export/import"
delete_all; row E deleted; check_zero E
status

# ---- checks ----
echo; echo "=================== space at each step (MiB) ==================="
echo "| sc | step                         | width |      size |     alloc |      free |    usable | pool used | zfs used  | zfs avail | acct excess  |"
echo "|----|------------------------------|-------|-----------|-----------|-----------|-----------|-----------|-----------|-----------|--------------|"
printf '%s\n' "${TABLE[@]}"
echo; echo "=================== checks ==================="
near "A vs B zfs avail after the expansion" "${V[A/expanded 3->6 (one attach)/avail]}" "${V[B/expanded 3->6 (3 attaches)/avail]}" 0.5
near "A vs B zfs avail after file2" "${V[A/file2/avail]}" "${V[B/file2/avail]}" 0.5
near "A vs B zfs used after file2" "${V[A/file2/used]}" "${V[B/file2/used]}" 0.5
near "A zfs avail across export/import" "${V[A/export\/import/avail]}" "${V[A/file2/avail]}" 0.1
near "A vs C (fresh 6-wide) zfs avail after deleting everything" "${V[A/deleted/avail]}" "${V[C/deleted/avail]}" 3
near "B vs C (fresh 6-wide) zfs avail after deleting everything" "${V[B/deleted/avail]}" "${V[C/deleted/avail]}" 3
near "E vs C (fresh 6-wide) zfs avail after deleting everything" "${V[E/deleted/avail]}" "${V[C/deleted/avail]}" 3
for s in A B E; do for t in "expanded 3->6 (one attach)" "expanded 3->6 (3 attaches)" file2 deleted; do
	[ -n "${V[$s/$t/used]:-}" ] && check_used $s "$t"; done; done
if [ $HAVE_ACCT = 1 ]; then
	near "D vs C (fresh 6-wide) zfs avail after deleting everything" "${V[D/deleted/avail]}" "${V[C/deleted/avail]}" 3
	check_used D "file3 (feature active)"
fi
run zpool export $P
echo
if [ ${#fail[@]} -eq 0 ]; then
	echo "RESULT OK (one expansion by 3 disks accounts like 3 single expansions and a fresh 6-wide pool; excess back to the metadata's, no leaks)"
elif [ $HAVE_ACCT = 0 ]; then
	echo "RESULT BUG (no raidz_expansion_accounting: after the expansion the free space stays at the 3-wide ratio: ${fail[*]})"
else
	echo "RESULT BUG (${fail[*]})"
fi
