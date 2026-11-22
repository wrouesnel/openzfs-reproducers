#!/bin/bash
# slow_pool.sh [DELAY_MS [POOL [FILE]]] -- the stand-in for the slow
# alpine3-24 CI runners behind this reproducer (fork zfs-qemu 44962925233,
# upstream 44955633933 and 44965541552: mmap_ftruncate took 140-221 s against
# its 90 s limit).  prep.sh of this reproducer starts it beside the ZTS run.
#
# It waits for mmap_ftruncate's file (FILE, default /testpool/truncfile),
# then delays every I/O to each of POOL's leaves by DELAY_MS (default 200),
# one at a time (zinject -D DELAY_MS:1), which slows the pool's writeback the
# way a slow runner does.  Meanwhile it watches the mmap_ftruncate program
# from outside, sampling /proc/PID/stat (its page-fault count) and
# /proc/PID/syscall (the syscall it is blocked in) about every 10 ms, and
# times its phases:
#   - the whole run (as master's test does, against TIMEOUT/2 = 90 s);
#   - everything before the final ftruncate(fd, 0): creating the file,
#     mapping it, dirtying every page (throttled by writeback), and in the
#     fixed helper starting writeback with sync_file_range();
#   - the final ftruncate(fd, 0) itself, the call the test is about: at most
#     the time from the last sample before it (the last page fault, or the
#     end of sync_file_range()) to the program's exit, and whether it was
#     ever seen blocked in it (master's bug: blocked for the txg timeout).
# When the program exits it clears the injection, so the test's cleanup runs
# at full speed, and writes one summary line per run.
D=${1:-200} P=${2:-testpool} F=${3:-/testpool/truncfile}
NR_FTRUNCATE=77 NR_SYNC_FILE_RANGE=277	# x86_64
now() { echo "${EPOCHREALTIME/./}"; }	# microseconds
sec() { printf '%d.%03d' $(($1 / 1000000)) $(($1 % 1000000 / 1000)); }
while :; do
	until [ -e "$F" ]; do sleep 0.05; done
	tf=$(now) pid=
	for ((i = 0; i < 200; i++)); do
		for c in /proc/[0-9]*/comm; do
			[ "$(cat "$c" 2>/dev/null)" = mmap_ftruncate ] && { pid=${c#/proc/}; pid=${pid%/comm}; break; }
		done
		[ -n "$pid" ] && break
		sleep 0.01
	done
	devs=$(zpool list -vHP "$P" 2>/dev/null | awk '$1 ~ /^\// {print $1}')
	for d in $devs; do zinject -d "$d" -D "$D:1" "$P" >/dev/null; done
	echo "slow_pool: $F created; every I/O to $(echo $devs) delayed by $D ms, one at a time (zinject -D $D:1)"
	[ -n "$pid" ] || { echo "slow_pool: no mmap_ftruncate process found"; }
	n=0 nfr=0 fr0= fr1= sfr0= sfr1= flt= tlf=$tf
	# each sample's time is taken before it reads the state, so the state
	# it reads is at least that recent (and no fork for it)
	while t=${EPOCHREALTIME/./} && [ -n "$pid" ] &&
	    { read -r nr a1 a2 _ <"/proc/$pid/syscall"; read -r -a st <"/proc/$pid/stat"; } 2>/dev/null; do
		n=$((n + 1))
		# its page faults (minflt + majflt): one per page it dirties, many
		# per sample while it dirties; the one or two after the final
		# ftruncate() (printf's buffer, exit) don't count
		f=$((st[9] + st[11])); [ -n "$flt" ] && [ $((f - flt)) -ge 8 ] && tlf=$t; flt=$f
		# a task on a CPU reads as "running": a syscall shows here only
		# while the task is blocked in it
		case $nr in
		"$NR_FTRUNCATE") [ "$a2" = 0x0 ] && { [ -n "$fr0" ] || fr0=$t; fr1=$t nfr=$((nfr + 1)); } ;;
		"$NR_SYNC_FILE_RANGE") [ -n "$sfr0" ] || sfr0=$t; sfr1=$t ;;
		esac
		sleep 0.01
	done
	te=${EPOCHREALTIME/./}	# after the read that found the program gone
	zinject -c all >/dev/null 2>&1
	[ -n "$pid" ] || continue
	# the final ftruncate(fd, 0) comes after the last sample that saw it
	# dirtying pages (and, in the fixed helper, after sync_file_range());
	# from that sample to the program's exit is an upper bound on the call
	tb=$tlf; [ -n "$sfr1" ] && [ "$sfr1" -gt "$tb" ] && tb=$sfr1
	iv=$(((te - tf) / n / 1000))
	if [ -n "$fr0" ]; then
		blk="blocked in it for $(sec $((fr1 - fr0))) s or more ($nfr samples)"
	else
		blk="never seen blocked in it"
	fi
	sf=; [ -n "$sfr0" ] && sf=" (sync_file_range() blocked $(sec $((sfr1 - sfr0))) s of it)"
	echo "slow_pool: mmap_ftruncate (pid $pid), sampled every ~$iv ms ($n samples):" \
	    "whole run $(sec $((te - tf))) s;" \
	    "creating, mapping and dirtying its pages$([ -n "$sfr0" ] && echo ", starting writeback") $(sec $((tb - tf))) s$sf;" \
	    "the final ftruncate(fd, 0), munmap and exit at most $(sec $((te - tb))) s, $blk"
	echo "slow_pool: the limits: master's test, the whole run under 90 s;" \
	    "the fixed test, ftruncate(fd, 0) under 90000 ms"
	echo "slow_pool: injection cleared"
	while [ -e "$F" ]; do sleep 0.1; done
done
