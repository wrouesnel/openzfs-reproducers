#!/bin/bash
# flaky_lsscsi.sh -- the stand-in for the CI flake behind this reproducer
# (procfs/pool_state: fork zfs-qemu 44973013373 and upstream 44962196233 on
# ubuntu24, an almalinux8 run on 2026-10-09).  Right after pool_state's
# cleanup rescans the SCSI host, lsscsi printed "unexpected scan_for_first
# error" in place of the scsi_debug disk's device node: lsscsi.c's
# one_sdev_entry() prints that when the device's sysfs block/ directory
# exists but scandir() finds no entry in it, as during the sd probe after a
# rescan.  The window is short and didn't open in 30 local runs, so this
# opens it every time.  Two modes:
#
#   flaky_lsscsi.sh arm [N]   (prep.sh starts it beside the tests) waits for
#       a scsi_debug disk to appear in sysfs, then for it to go away (the
#       test's remove_disk), and then arms the wrapper: the next N (default
#       3) lsscsi calls that list the scsi_debug disk print
#       "unexpected scan_for_first error" in its device column, as lsscsi
#       does in that window.
#   lsscsi [ARGS]   (prep.sh links this script as lsscsi on the tests' PATH)
#       runs the real /usr/bin/lsscsi; while armed, it replaces the
#       scsi_debug line's last column and logs the real line beside it.
#
# Nothing else changes: the disk itself comes back as usual, and the real
# lsscsi lists it.
ARM=/run/zts/lsscsi.arm LOG=/run/zts/lsscsi.log REAL=/usr/bin/lsscsi
ts() { date +%T.%N | cut -c1-12; }
sdebug_present() { grep -qs scsi_debug /sys/bus/scsi/devices/*/model; }

if [ "${1:-}" = arm ]; then
	n=${2:-3}
	for _ in $(seq 6000); do sdebug_present && break; sleep 0.1; done
	sdebug_present || { echo "$(ts) arm: no scsi_debug disk appeared" >>$LOG; exit 1; }
	echo "$(ts) arm: scsi_debug disk present ($(grep -ls scsi_debug /sys/bus/scsi/devices/*/model | cut -d/ -f6 | tr '\n' ' '))" >>$LOG
	for _ in $(seq 30000); do sdebug_present || break; sleep 0.1; done
	sdebug_present && { echo "$(ts) arm: the scsi_debug disk was never removed" >>$LOG; exit 1; }
	echo "$n" >$ARM
	echo "$(ts) arm: scsi_debug disk removed (remove_disk); the next $n lsscsi calls listing it print 'unexpected scan_for_first error'" >>$LOG
	exit 0
fi

out=$($REAL "$@"); rc=$?
n=$(cat $ARM 2>/dev/null); n=${n:-0}
if [ "$n" -gt 0 ] && grep -q scsi_debug <<<"$out"; then
	echo $((n - 1)) >$ARM
	real=$(grep -m1 scsi_debug <<<"$out" | sed 's/  */ /g; s/ $//')
	out=$(sed -E '/scsi_debug/ s#[^ ]+ *$#unexpected scan_for_first error#' <<<"$out")
	echo "$(ts) lsscsi call faked ($((n - 1)) left): real '$real' -> printed '$(grep -m1 scsi_debug <<<"$out" | sed 's/  */ /g')'" >>$LOG
fi
printf '%s\n' "$out"
exit $rc
