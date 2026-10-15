# host.sh for selftest-triggers: runs in the container (bash), sourced by the
# orchestrator.  See docs/reproducer-format.md for the API.

# once the VMs boot: VM1 sets its hostid and address, then idles at its prompt
host_start() {
	vm_wait 1 'press Up, Enter' 90 || return 1
	sleep 1
	vm_type 1 $'zr setup && echo VM1-"READY"\r'	# quoted: the echo of the typed line must not match
}
# zr wait peer-ready
wait_peer_ready() { vm_wait 1 'VM1-READY' 120; }
# zr trigger peer-import: VM1 imports the pool VM0 exported, checksums the
# file and exports it again; the checksum goes back to VM0
trigger_peer_import() {
	local o out
	o=$(logsize 1)
	vm_type 1 $'zpool import -d /dev st && md5sum /st/data && zpool export st && echo PEER-IMPORT-"OK" || echo PEER-IMPORT-"FAILED"\r'
	vm_wait 1 'PEER-IMPORT-(OK|FAILED)' 90 "$o" || return 1
	out=$(tail -c +$((o + 1)) "$(log0 1)" | tr -d '\r')
	printf '%s\n' "$out" | grep -aq '^PEER-IMPORT-OK' || return 1
	ZR_REPLY=$(printf '%s\n' "$out" | grep -aE '^[0-9a-f]{32} ' | head -1 | cut -d' ' -f1)
}
