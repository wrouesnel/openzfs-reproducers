# host.sh for wrouesnel/fix-zts-l2arc-dwpd-ratelimit: runs in the container
# (bash), sourced by the orchestrator (docs/reproducer-format.md).
#
# A slow CI runner, made deterministic: run disk 0 holds the ZTS file
# systems (/var/tmp/zts: the test's pool vdev and cache device files), and
# it is limited to 10 MB/s (qemu block_set_io_throttle, bps total) from the
# moment l2arc_dwpd_ratelimit_pos starts until it ends (PASS or KILLED).
# The next test then runs at full speed, so its result shows only what the
# first test left behind.
RL_START='=== tests/functional/l2arc/l2arc_dwpd_ratelimit_pos [(]'
RL_END='=== l2arc_dwpd_ratelimit_pos: \['
host_start() {
	# no timeout to speak of: in an interactive run the reviewer presses
	# Up, Enter when ready
	vm_wait 0 "$RL_START" 864000 || return 1
	disk_throttle 0 0 0 10000000
	hlog "run disk 0 limited to 10 MB/s while l2arc_dwpd_ratelimit_pos runs"
	vm_wait 0 "$RL_END" 864000 || return 1
	disk_throttle 0 0 0 0
	hlog "run disk 0 limit lifted (l2arc_dwpd_ratelimit_pos ended)"
}
