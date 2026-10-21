#!/bin/bash
# The demo of a ZTS reproducer (KIND=zts in reproducer.conf): it runs the
# OpenZFS test suite (ZTS) tests named in ZTS_TESTS, from this build's own
# commit, the way zfs-tests.sh and test-runner run them in openzfs/zfs CI:
# three 4 GiB sparse files on the run disk behind loop devices as DISKS,
# the group's setup (pre), the test, and the group's cleanup (post), each
# with the runfile's timeout.  The test's output is shown as it runs.
#   RESULT BUG    a test FAILED (or timed out) on this build, or the kernel
#                 logged a BUG, oops, SPL assertion or hung task meanwhile
#   RESULT OK     every test passed (ZTS_ITERATIONS times, for a flake)
#   RESULT ERROR  a setup failed, or a test was skipped or unresolved
# Run as root:  /demo/demo.sh   (Up, Enter on the console).  The tests'
# scripts are below the end of this runner; /demo/zts/LABEL/ has them all.
set -u
. /etc/demo-env 2>/dev/null
build=${DEMO_BUILD:-${1:-repro}}
S=/demo/zts/$build
cfg() { (. /demo/manifest >/dev/null 2>&1; eval "printf '%s' \"\${$1:-}\""); }	# a reproducer.conf value
ITER=$(cfg ZTS_ITERATIONS); ITER=${ITER:-1}
[ -f "$S/tests.list" ] || { echo "RESULT ERROR: no ZTS for build '$build' ($S)"; exit 2; }

zts_env() {
	# ksh93 and every command on one constrained path, as zfs-tests.sh does
	B=/run/zts/bin; rm -rf "$B"; mkdir -p "$B"
	for d in /demo/bin /usr/sbin /usr/bin; do
		for f in "$d"/*; do [ -e "$B/${f##*/}" ] || ln -s "$f" "$B/"; done
	done
	ln -sf /demo/bin/ksh /usr/bin/ksh
	# the test files on the run disk (ext2), like CI's /var/tmp on the VM disk
	FILEDIR=/var/tmp/zts
	umount "$FILEDIR" 2>/dev/null; mkdir -p "$FILEDIR"
	if [ -n "${DEMO_DISK:-}" ]; then
		mke2fs -q -F -b 4096 -N 8192 -m 0 "$DEMO_DISK" >/dev/null 2>&1 &&
		    mount -t ext4 "$DEMO_DISK" "$FILEDIR" ||
		    { echo "RESULT ERROR: could not make the file system on $DEMO_DISK"; exit 2; }
	fi
	DISKS=
	for i in 0 1 2; do
		losetup -d /dev/loop$i 2>/dev/null
		truncate -s 4G "$FILEDIR/file-vdev$i"
		losetup /dev/loop$i "$FILEDIR/file-vdev$i" || { echo "RESULT ERROR: losetup loop$i"; exit 2; }
		DISKS="$DISKS loop$i"
	done
	export DISKS=${DISKS# } FILEDIR TMPDIR=$FILEDIR KEEP= __ZFS_POOL_EXCLUDE= TESTFAIL_CALLBACKS=
	# a writable copy of the scripts: tests run in their directory, and
	# some write there (snapshot_006_pos makes ./mkdir), as in a source tree
	rm -rf /run/zts/suite; cp -a "$S" /run/zts/suite; S=/run/zts/suite
	# the end state of each test, for the console reviewer: just before a
	# test's cleanup runs, print the pools as the test left them (always on
	# a failure; on a pass only in the last iteration of a flake run), so
	# the break visibly ends bad and the fix visibly ends good
	cat >/run/zts/state <<'EOS'
#!/bin/bash
rc=$1 why=${2:-} cur=$(cat /run/zts/current 2>/dev/null)
[ -z "$why" ] && why=$(cat /run/zts/lasterror 2>/dev/null)
case ${cur##*/} in setup | cleanup) exit 0 ;; esac
[ "$rc" = 0 ] && [ "${ZR_SHOW_PASS:-1}" != 1 ] && exit 0
word=PASS
if [ "$rc" != 0 ]; then
	word="FAIL: $why"
	echo "${cur##*/}${ZR_ITER:+ (iteration $ZR_ITER)}: $why" >>/run/zts/reasons
fi
echo "--- end state of $cur ($word), as the test left it, before its cleanup ---"
pools=$(timeout 20 zpool list -H -o name 2>/dev/null)
if [ -z "$pools" ]; then
	echo "(no pools imported)"
else
	echo "# zpool list -o name,size,alloc,free,health,readonly"
	timeout 20 zpool list -o name,size,alloc,free,health,readonly 2>&1 | sed 's/^/    /'
	for p in $pools; do
		echo "# zpool status -v $p"
		timeout 20 zpool status -v "$p" 2>&1 | sed 's/^/    /'
	done
	echo "# zfs list -o name,used,avail,refer,mountpoint"
	timeout 20 zfs list -o name,used,avail,refer,mountpoint 2>&1 | head -30 | sed 's/^/    /'
fi
echo "--- end of the end state ---"
EOS
	chmod +x /run/zts/state; : >/run/zts/reasons
	L=$S/runner/include/logapi.shlib
	if grep -q '^	typeset stack=("${_CLEANUP\[@\]}")$' "$L"; then
		sed -i '/^	typeset stack=("${_CLEANUP\[@\]}")$/i\	[[ -x /run/zts/state ]] \&\& /run/zts/state "$exitcode" "$*"' "$L"
	else
		echo "# (this ZTS's logapi.shlib has no hook point: no end-state dump)"
	fi
	# log_must reports a failure as "ERROR: CMD exited N" and calls
	# log_fail without a message: keep the last ERROR as the reason
	sed -i '/^	_printline ERROR: "\$@"$/i\	print -r -- "$*" >/run/zts/lasterror 2>/dev/null' "$L"
	export STF_SUITE=$S STF_TOOLS=$S/runner STF_PATH=$B PATH=$B UNAME=Linux
	# shellcheck disable=SC1091
	. "$S/include/default.cfg"
	# an oops panics the VM: an oopsed task can wedge the guest (locks
	# held, a CPU left with interrupts off), and the launcher reports the
	# panic as PANIC (a reproducer whose bug oopses expects PANIC)
	echo 1 >/proc/sys/kernel/panic_on_oops
	[ -e /sys/module/zfs/parameters/zfs_dbgmsg_enable ] && echo 1 >/sys/module/zfs/parameters/zfs_dbgmsg_enable
	# the build's zed.rc and zedlets (TOOLS zed), where default.cfg's
	# ZEDLET_ETC_DIR and ZEDLET_LIBEXEC_DIR look
	if [ -d /zfs/zed ]; then
		mkdir -p /etc/zfs /usr/libexec/zfs
		[ -e /etc/zfs/zed.d ] || ln -s /zfs/zed/etc /etc/zfs/zed.d
		[ -e /usr/libexec/zfs/zed.d ] || ln -s /zfs/zed/libexec /usr/libexec/zfs/zed.d
	fi
	# udev's part: /dev/zfs for every user (90-zfs.rules, MODE 0666), and
	# the /dev/zvol links (zts-udevadm), kept up to date; the extended
	# userland (BASE=ext) runs udev itself
	chmod 0666 /dev/zfs
	if [ ! -S /run/udev/control ]; then
		( while :; do udevadm; sleep 0.3; done ) >/dev/null 2>&1 &
	elif ls /demo/udev/*.rules >/dev/null 2>&1; then
		# the reproducer's own udev rules (reproducers/ID/udev/*.rules),
		# e.g. a slower probe that widens a race udev takes part in
		mkdir -p /run/udev/rules.d
		cp /demo/udev/*.rules /run/udev/rules.d/
		udevadm control --reload
		echo "# udev rules added by this reproducer: $(cd /demo/udev && echo *.rules)"
	fi
	echo "# ZTS of $(cat "$S/commit")"
	echo "# DISKS=$DISKS (4 GiB sparse files on $FILEDIR${DEMO_DISK:+, $DEMO_DISK})"
}

# A kernel BUG, oops, SPL assertion (VERIFY/ASSERT ... PANIC at) or hung
# task is the bug showing even when the test can't finish: the watcher
# prints the RESULT at once (the launcher stops the VM on it).
OOPS_RE='BUG: |Oops|general protection fault|kernel BUG|PANIC at |VERIFY[0-9]*[(]|ASSERT[0-9]*[(]|blocked for more than [0-9]+ seconds|Kernel panic'
oops_watch() {
	local t0; t0=$(awk '{ printf "%.0f", $1 * 1000000 }' /proc/uptime)
	: >/run/zts/oops
	(
		# /dev/kmsg records: "prio,seq,usec,flags;text", one per read (cat);
		# mawk reads its input a line at a time only with -W interactive
		cat /dev/kmsg | awk -W interactive -F';' -v t0="$t0" -v re="$OOPS_RE" \
		    '{ split($1, a, ","); if (a[3] + 0 > t0 && $0 ~ re) { sub(/^[^;]*;/, ""); print; exit } }' >/run/zts/oops
		if [ -s /run/zts/oops ]; then
			sleep 2
			r="RESULT BUG: the kernel reported \"$(cut -c1-120 /run/zts/oops)\" during $(cat /run/zts/current 2>/dev/null) ($build build)"
			# also through the kernel's console: an oops in an interrupt
			# thread can leave the tty's output stuck (the CPU it died on
			# keeps interrupts off) while printk still reaches the
			# console; without the timestamp the line starts "RESULT "
			echo N >/sys/module/printk/parameters/time 2>/dev/null
			echo "<2>$r" >/dev/kmsg 2>/dev/null
			echo; echo "$r"
		fi
	) &
	WATCH=$!
}

stf() {	# test-runner's names for a script's exit status
	case $1 in
	0) echo PASS ;; 1) echo FAIL ;; 2) echo UNRESOLVED ;; 3) echo NOTINUSE ;;
	4) echo UNSUPPORTED ;; 5) echo UNTESTED ;; 6) echo UNINITIATED ;;
	7) echo NORESULT ;; 8) echo WARNING ;; 124 | 137 | 143) echo KILLED ;; *) echo "OTHER($1)" ;;
	esac
}
run_one() {	# DIR SCRIPT TIMEOUT: prints the result word, returns the status
	local d=$1 s=$2 to=$3 rc
	rm -f /run/zts/lasterror
	[ -x "$STF_SUITE/$d/$s.ksh" ] || { echo "(no $d/$s.ksh)"; return 0; }
	echo "$d/$s" >/run/zts/current
	echo; echo "=== $d/$s ($build build, timeout ${to}s)"
	# (no pipe: a daemon a script starts, such as ZED, keeps its output
	# open, and a reader would wait for it)
	({ set +x; } 2>/dev/null; cd "$STF_SUITE/$d" && exec timeout -s KILL "$to" ksh -p "./$s.ksh") 2>&1
	rc=$?
	echo "=== $s: [$(stf "$rc")]"
	return "$rc"
}

main() {
	zts_env
	oops_watch
	local fails= errs= n=0 i d t pre post to rc
	# as test-runner: a group's setup (pre) once before its tests, its
	# cleanup (post) once after them; the list is read on fd 3, so a test
	# that reads its stdin can't eat it
	local grp cur post0 to0 skip
	for ((i = 1; i <= ITER; i++)); do
		[ "$ITER" -gt 1 ] && echo && echo "##### iteration $i of $ITER"
		export ZR_SHOW_PASS=$([ "$i" -eq "$ITER" ] && echo 1 || echo 0) ZR_ITER=$([ "$ITER" -gt 1 ] && echo "$i")
		cur= skip=
		while read -r -u3 d t pre post to; do
			[ -n "$d" ] || continue
			n=$((n + 1)) grp="$d $pre $post"
			if [ "$grp" != "$cur" ]; then
				if [ -n "$cur" ] && [ "$post0" != - ]; then
					run_one "${cur%% *}" "$post0" "$to0" || errs="$errs ${cur%% *}(cleanup)"
				fi
				cur=$grp post0=$post to0=$to skip=
				if [ "$pre" != - ] && ! run_one "$d" "$pre" "$to"; then skip=1; fi
			fi
			[ -n "$skip" ] && { errs="$errs $t(setup)"; continue; }
			run_one "$d" "$t" "$to"; rc=$?
			case $(stf "$rc") in
			PASS) ;;
			FAIL | KILLED) fails="$fails $t$([ "$ITER" -gt 1 ] && echo "#$i")" ;;
			*) errs="$errs $t($(stf "$rc"))" ;;
			esac
		done 3<"$S/tests.list"
		if [ -n "$cur" ] && [ "$post0" != - ]; then
			run_one "${cur%% *}" "$post0" "$to0" || errs="$errs ${cur%% *}(cleanup)"
		fi
	done
	for i in 0 1 2; do losetup -d /dev/loop$i 2>/dev/null; done
	cd /; umount "$FILEDIR" 2>/dev/null
	sleep 1; kill "$WATCH" 2>/dev/null
	[ -s /run/zts/oops ] && { sleep 3; return 1; }	# the watcher printed the RESULT
	echo
	if [ -s /run/zts/reasons ]; then
		echo "# why each failing run failed:"
		sed 's/^/    /' /run/zts/reasons
	fi
	local note; note=$(cfg ZTS_NOTE_$build); [ -n "$note" ] || note=$(cfg ZTS_NOTE)
	[ -n "$note" ] && { echo "# note:"; echo "$note" | fold -s -w 76 | sed 's/^/    /'; }
	if [ -n "$fails" ]; then
		echo "RESULT BUG: ZTS failed:$fails ($build build; $(echo $fails | wc -w) of $n runs)"
	elif [ -n "$errs" ]; then
		echo "RESULT ERROR: ZTS did not run cleanly:$errs"; return 2
	else
		echo "RESULT OK: ZTS passed: $(cut -d' ' -f2 "$S/tests.list" | tr '\n' ' ')($build build$([ "$ITER" -gt 1 ] && echo ", $ITER iterations"))"
	fi
}
main "$@"
exit $?
