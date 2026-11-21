#!/bin/bash
# demo.sh -- openzfs/zfs#19978: zinject's match and injection counts lose
# updates, and a listing can see a handler between its two counts.
#
# The I/O hooks in zio_inject.c count a handler's matches and injections
# (zi_match_count, zi_inject_count) with a plain ++ while holding
# inject_lock only as a reader, so hooks running at once on different CPUs
# can lose an increment; and `zinject` (zio_inject_list_next()) copies the
# record under the same reader lock, so it can catch a hook between counting
# a match and counting its injection.  At frequency 100% every match is an
# injection, so the two counts must be equal.  This is what makes ZTS
# cli_root/zinject/zinject_counts fail now and then ("freq=100 match=55
# inject=54").  The PR counts with atomic_inc_64() and lists handlers with
# inject_lock held as a writer.
#
# Each round: a 3-way mirror (pool zic, 256 MiB files in /var/tmp/zic), a
# `zinject -d d0 -e io -T write -f 100` handler, eight parallel writers,
# `zinject` listed ten times while they write (mid-I/O listings) and once
# after `zpool sync` (final counts).  Any listing with MATCH != INJECT is
# the bug.  ROUNDS rounds (default 30), about 20 seconds with 8 CPUs.
set -u
P=zic D=/var/tmp/zic ROUNDS=${ROUNDS:-30} W=8

run() { echo "\$ $*"; "$@" 2>&1 | sed 's/^/  /'; return "${PIPESTATUS[0]}"; }
result() {	# the RESULT line, also through the kernel's console
	echo N >/sys/module/printk/parameters/time 2>/dev/null
	echo "<2>$1" >/dev/kmsg 2>/dev/null
	echo; echo "$1"
}
counts() { zinject | awk '/^ *[0-9]/ { print $(NF-1), $NF }'; }

echo "CPUs: $(nproc)"
mkdir -p $D
for i in 0 1 2; do truncate -s 256M $D/d$i; done
run zpool create -f -o cachefile=none $P mirror $D/d0 $D/d1 $D/d2 || {
	result "RESULT ERROR: zpool create failed"; exit 1; }
run zfs set primarycache=none compression=off recordsize=16k $P
echo "--- zpool status -v $P"; zpool status -v $P | sed '/^$/d; s/^/    /'

final=0 mid=0 total=0 shown=0
for n in $(seq 1 $ROUNDS); do
	zinject -d $D/d0 -e io -T write -f 100 $P >/dev/null
	[ $n = 1 ] && { echo "\$ zinject -d $D/d0 -e io -T write -f 100 $P"; zinject | sed 's/^/  /'; }
	for j in $(seq 1 $W); do
		dd if=/dev/urandom of=/$P/f$j bs=16k count=256 2>/dev/null &
	done
	m=0
	for k in 1 2 3 4 5 6 7 8 9 10; do
		set -- $(counts)
		if [ "${1:-0}" != "${2:-0}" ]; then
			m=$((m + 1))
			[ $shown -lt 5 ] && { shown=$((shown + 1))
			    echo "  round $n, listing during the writes: MATCH=$1 INJECT=$2  <-- differ"; }
		fi
	done
	wait
	zpool sync $P
	set -- $(counts)
	total=$((total + $1)); mid=$((mid + m))
	if [ "$1" != "$2" ]; then
		final=$((final + 1))
		echo "round $n: after zpool sync MATCH=$1 INJECT=$2  <-- differ (a count was lost)"
	else
		[ $m -gt 0 ] && x=" ($m mid-write listings differed)" || x=""
		echo "round $n: after zpool sync MATCH=$1 INJECT=$2$x"
	fi
	zinject -c all >/dev/null
	zpool clear $P
	rm -f /$P/f*
done
echo "--- zpool status -v $P   (end)"; zpool status -v $P | sed '/^$/d; s/^/    /'
run zpool export $P
echo
echo "$ROUNDS rounds, $total matches at freq=100: $final final counts differ," \
    "$mid of $((ROUNDS * 10)) mid-write listings differ"
if [ $final -gt 0 ] || [ $mid -gt 0 ]; then
	result "RESULT BUG: zinject counts differ at freq=100 ($final of $ROUNDS final, $mid of $((ROUNDS * 10)) mid-write listings)"
else
	result "RESULT OK: zinject counts equal at freq=100 in every listing ($ROUNDS rounds, $total matches)"
fi
