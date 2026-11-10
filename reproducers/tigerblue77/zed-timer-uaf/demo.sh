#!/bin/bash
# demo.sh -- openzfs/zfs #19569 (PR #19629, @tigerblue77; also the
# fault/auto_spare_001_pos CI flake in #19341): ZED uses an fmd timer after
# freeing it.
#
# ZED emulates fmd timers with SIGEV_THREAD POSIX timers.  On master the
# timer's value is the fmd_timer_t pointer, and _timer_notify() runs on a
# thread of its own: it reads the fmd_timer_t and calls the module's timeout
# (zfs-diagnosis: zfs_fm_timeout) there.  Meanwhile the agents thread can
# remove the same timer (case closed, pool destroyed), which frees the
# fmd_timer_t at once; timer_delete() doesn't wait for a notification thread
# that has already started.  The PR passes only a timer id, and the agents
# thread runs the timeout itself, dropping ids of removed timers.
#
# The race window is small, so the demo makes it deterministic with gdb
# (non-stop mode: only the held thread stops, the rest of ZED keeps running):
#   1. a 3-way mirror; zinject read errors on one side, read the file: the
#      diagnosis engine opens a case and installs its 15 s remove timer;
#   2. when the timer expires, a breakpoint on libc's timer_sigev_thread holds
#      the timer thread before it calls _timer_notify();
#   3. zpool destroy: the agents thread closes the case, which removes the
#      timer (fmd_timer_remove: timer_delete + free);
#   4. the timer thread is released.
# ZED runs with glibc.malloc.perturb=165 and tcache off, so freed memory is
# filled with 0xa5 bytes and a read of it shows up (both builds alike).
#
#   master (bug):   the held thread's fmd_timer_t is freed memory (ft_arg =
#     0xa5a5a5a5a5a5a5a5); on release ZED logs "timer fired" and segfaults
#     in the module's timeout -> "RESULT BUG"
#   PR (fix):       the timer thread holds only an id (sival = 0x1); on
#     release nothing runs for the removed timer and ZED stays up -> "RESULT OK"
#
# Run as root:  /demo/demo.sh      about 60 s.
# Pool tuaf on the run disks $DEMO_DISKS (3), or files in /var/tmp/tuaf.
# The pool is destroyed by the demo (that is the trigger), not exported.
set -u
W=/var/tmp/tuaf; P=tuaf
pkill -x zed 2>/dev/null; zpool destroy -f $P 2>/dev/null
rm -rf $W; mkdir -p $W/zedlets
read -r -a V <<< "${DEMO_DISKS:-}"
if [ ${#V[@]} -lt 3 ]; then
	V=(); for i in 1 2 3; do truncate -s 256M $W/v$i; V+=($W/v$i); done
fi
cleanup() { pkill -x gdb 2>/dev/null; pkill -9 -x zed 2>/dev/null; zinject -c all >/dev/null 2>&1; }
step() { echo; echo "### $*"; }
run() { echo "# $*"; "$@"; }
st() { echo "# zpool status -v $P"; zpool status -v $P 2>&1 | sed 's/^/  /'; }
zedlog() { grep -E 'installing timer|removing timer|timer fired|solving|expiry|purging|segfault' $W/zed.log | sed 's/^/  zed.log: /'; }

step "1. pool $P: 3-way mirror, a 16 MiB file, uncached reads"
run zpool create -f -o cachefile=none $P mirror "${V[@]}" ||
    { echo "RESULT ERROR: could not create pool $P"; exit 2; }
run zfs create -o primarycache=none -o recordsize=16k $P/fs
dd if=/dev/urandom of=/$P/fs/file bs=1M count=16 status=none; zpool sync $P
zpool events -c >/dev/null
st

step "2. ZED under gdb (non-stop), breakpoint on libc's timer_sigev_thread"
echo "# GLIBC_TUNABLES=glibc.malloc.tcache_count=0:glibc.malloc.perturb=165 zed -F -v (log $W/zed.log)"
cat > $W/gdb.cmd <<G
set non-stop on
set pagination off
set confirm off
set breakpoint pending on
handle SIGPIPE SIGCHLD nostop noprint pass
set environment GLIBC_TUNABLES=glibc.malloc.tcache_count=0:glibc.malloc.perturb=165
set \$crashed = 0
break timer_sigev_thread
run -F -v -d $W/zedlets -p $W/zed.pid -s $W/zed.state 2>$W/zed.log >&2
python
import gdb
stopped = [t for t in gdb.selected_inferior().threads() if t.is_stopped()]
stopped[0].switch()
end
python
# arg is libc's struct thread_start_data { thrfunc; sival; }
sival = int(gdb.parse_and_eval("*(unsigned long *)(\$rdi + 8)"))
gdb.execute("set \$sival = %d" % sival)
print("HELD: the timer thread, before it calls _timer_notify(sival = 0x%x)" % sival)
def show(when):
    if sival < 0x10000:
        print("  %s: sival 0x%x is a timer id, not a pointer: the thread holds no fmd_timer_t" % (when, sival))
        return
    w = [int(gdb.parse_and_eval("((unsigned long *)%d)[%d]" % (sival, i))) for i in range(3)]
    print("  %s: fmd_timer_t at 0x%x = { ft_tid = 0x%x, ft_arg = 0x%x, ft_hdl = 0x%x }" % ((when, sival) + tuple(w)))
    if w[1] == 0xa5a5a5a5a5a5a5a5:
        print("  -> ft_arg reads 0xa5a5a5a5a5a5a5a5: this fmd_timer_t has been FREED")
show("now")
gdb.flush()
gdb.execute("shell touch $W/held")
gdb.execute("shell while [ ! -e $W/go ]; do sleep 0.2; done")
show("after zpool destroy")
print("RELEASE: the timer thread continues (gdb: finish, until timer_sigev_thread returns)")
gdb.flush()
end
finish
python
for t in gdb.selected_inferior().threads():
    if not t.is_valid() or not t.is_stopped():
        continue
    t.switch()
    try:
        signo = int(gdb.parse_and_eval("\$_siginfo.si_signo"))
    except gdb.error:
        continue
    if signo == 11:
        print("CRASH: thread %d got SIGSEGV" % t.num)
        gdb.execute("set \$crashed = 1")
        gdb.execute("x/i \$pc")
        for r in ("rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r12", "r13", "r14", "r15"):
            v = int(gdb.parse_and_eval("(unsigned long)\$" + r))
            if v == 0xa5a5a5a5a5a5a5a5:
                print("  %s = 0x%x (freed memory)" % (r, v))
        gdb.execute("bt 6")
gdb.flush()
end
if \$crashed == 0
shell sleep 8
shell pgrep -x zed >/dev/null && echo "ZED: process still there, 8 s after the release" || echo "ZED: process gone"
end
kill
G
gdb -q -batch -x $W/gdb.cmd "$(command -v zed)" > $W/gdb.out 2>&1 &
gp=$!
for i in $(seq 30); do grep -q 'Processing events' $W/zed.log 2>/dev/null && break; sleep 1; done
grep -q 'Processing events' $W/zed.log 2>/dev/null ||
    { cat $W/gdb.out $W/zed.log; cleanup; echo "RESULT ERROR: zed did not start under gdb"; exit 2; }
echo "# ZED is up: $(grep -m1 'ZFS Event Daemon' $W/zed.log)"

step "3. zinject read errors on ${V[0]}, read the file: zfs-diagnosis opens a case"
run zinject -d ${V[0]} -e io -T read $P >/dev/null
cat /$P/fs/file > /dev/null
sleep 2
st
zedlog
echo "# waiting for the case's 15 s remove timer to expire..."
for i in $(seq 90); do [ -e $W/held ] && break; sleep 1; done
[ -e $W/held ] || { cat $W/gdb.out; cleanup; echo "RESULT ERROR: the timer never expired"; exit 2; }
grep -E '^HELD|^  now' $W/gdb.out

step "4. while the timer thread is held: zpool destroy $P (closes the case, removes the timer)"
run zinject -c all >/dev/null
run zpool destroy $P
for i in $(seq 30); do grep -q 'removing timer' $W/zed.log && break; sleep 1; done
zedlog
st

step "5. release the timer thread"
touch $W/go
wait $gp
cleanup
grep -v '^\[New Thread\|^\[New LWP\|^\[LWP .* exited\|^\[Thread .* exited\|^\[Detaching\|^\[Inferior\|libthread_db\|^warning: \(could not convert\|Unable to find libthread\)\|This normally should not\|^Function "timer_sigev\|^Breakpoint 1 (timer_sigev_thread) pending\|^warning: [0-9]*\s.*No such file\|^Breakpoint 1 at\|^Thread .* hit Breakpoint\|^HELD\|^  now\|^\[Switching' $W/gdb.out | sed 's/^/  gdb: /'
echo "# ZED's log after the release:"
zedlog

echo
if grep -q '^CRASH: .*SIGSEGV' $W/gdb.out; then
	if grep -q 'timer fired' $W/zed.log; then
		echo "RESULT BUG: ZED segfaulted: the timer thread ran the timeout of a timer that zpool destroy had removed and freed (use after free)"
	else
		echo "RESULT BUG: ZED segfaulted on the timer thread after the timer was removed and freed (use after free)"
	fi
elif grep -q 'timer fired' $W/zed.log; then
	echo "RESULT BUG: no crash, but the timeout ran for the removed (freed) timer"
elif grep -q '^ZED: process still there' $W/gdb.out && grep -q 'is a timer id' $W/gdb.out; then
	echo "RESULT OK: no crash; the timer thread held only an id, and nothing ran for the removed timer (ZED up 8 s after the release)"
else
	echo "RESULT ERROR: inconclusive (see $W/gdb.out, $W/zed.log)"
fi
