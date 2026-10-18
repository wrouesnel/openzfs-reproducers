#!/bin/bash
# demo.sh -- bug #155 / openzfs #7633: on a normalization=formD file system
# that is case-sensitive (or mixed), Linux caches name lookups byte-for-byte,
# while ZFS matches names by their normalised form.  Two spellings of the same
# name (C = NFC, precomposed; D = NFD, decomposed) then go stale against each
# other in the dcache:
#   case 1  a failed lookup of D is cached; after C is created, D still says
#           ENOENT (rm D fails although the file exists)
#   case 2  reading C through D caches D as a second name for the file; after
#           rm C, D still opens the deleted file (old data readable) and a
#           write through D goes to the deleted file and is lost
#   case 3  rm C, then create D: reading C finds the new file?
#   case 4  rmdir C, then mkdir D: is C a directory?
# Each case runs on a fresh dataset and prints every step, the directory
# listing (ls -li: same inode number = same file) and the name bytes.
#
# Builds:
#   bug  test commit 3fece14921 (master 7c3d85aaf1 + the ZTS test)
#        -> "RESULT BUG: ..." naming the cases that went wrong
#   fix  fix-norm-dcache-alias 822195c6d6
#        -> "RESULT OK: all 4 cases correct"
# Run as root:  /demo/demo.sh       a few seconds.
set -u
P=demo155 D=/var/tmp/demo155 FS=demo155/normdc M=/var/tmp/demo155/mnt
C=$(printf 'F\xc3\xafL\xc3\xabN\xc3\x84m\xc3\xab')
N=$(printf 'Fi\xcc\x88Le\xcc\x88NA\xcc\x88me\xcc\x88')

step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
die() { echo "RESULT ERROR: $*"; exit 2; }
bad_cases=""
case_bad=0
# check LABEL EXPECTED CMD: run CMD, show its result, compare with EXPECTED
# (EXPECTED is "ok", "ok: <output>", or "ENOENT")
check() {
	local label=$1 want=$2 cmd=$3 out rc got xt=0
	# the image runs the demo under bash -x: keep the trace out of $out
	case $- in *x*) xt=1; set +x ;; esac
	echo "# $cmd"
	out=$(eval "$cmd" 2>&1); rc=$?
	[ $xt -eq 1 ] && set -x
	if [ $rc -eq 0 ]; then got="ok${out:+: $out}"
	elif echo "$out" | grep -q "No such file"; then got="ENOENT"
	else got="FAILED: $out"; fi
	if [ "$got" = "$want" ]; then
		printf '   %-44s -> %-22s  [as expected]\n' "$label" "$got"
	else
		printf '   %-44s -> %-22s  [WRONG: should be %s]\n' "$label" "$got" "$want"
		case_bad=1
	fi
}
listing() {
	echo "## ls -li $M   (same inode number = same file)"
	ls -li "$M" | sed 's/^/   /'
	echo "## names on disk (bytes)"
	ls -A "$M" | while IFS= read -r n; do
		printf '   %s\n' "$(printf '%s' "$n" | od -An -tx1 | tr -s ' ')"
	done
}
fresh() {
	zfs destroy -r $FS 2>/dev/null
	rm -rf $M
	zfs create -o casesensitivity=sensitive -o normalization=formD \
	    -o mountpoint=$M $FS || die "zfs create failed"
}
endcase() {
	if [ $case_bad -eq 0 ]; then echo "-> case $1: correct"
	else echo "-> case $1: WRONG ($2)"; bad_cases="$bad_cases case$1:$2"; fi
	case_bad=0
}

zpool destroy -f $P 2>/dev/null
rm -rf $D; mkdir -p $D
truncate -s 256M $D/disk
zpool create -f -m none $P $D/disk || die "could not create $P"
fresh
step "setup: $FS"
echo "# zfs get normalization,casesensitivity $FS"
zfs get -H -o property,value normalization,casesensitivity $FS | sed 's/^/   /'
echo "C (NFC) bytes: $(printf '%s' "$C" | od -An -tx1 | tr -s ' ')"
echo "D (NFD) bytes: $(printf '%s' "$N" | od -An -tx1 | tr -s ' ')"
echo "On this file system C and D are the same name."

step "case 1: a failed lookup of D, then create C"
fresh
check "stat D (nothing exists yet)"   "ENOENT"   "stat -c %n '$M/$N' >/dev/null"
check "create C"                      "ok"       "echo nfc > '$M/$C'"
check "read D (same name as C)"       "ok: nfc"  "cat '$M/$N'"
check "rm D"                          "ok"       "rm '$M/$N'"
listing
endcase 1 "stale ENOENT for an existing file"

step "case 2: read C through D, then remove C"
fresh
check "create C (contents: old)"      "ok"       "echo old > '$M/$C'"
check "read D"                        "ok: old"  "cat '$M/$N'"
check "rm C"                          "ok"       "rm '$M/$C'"
check "read D (file was removed)"     "ENOENT"   "cat '$M/$N'"
check "create C (contents: new)"      "ok"       "echo new > '$M/$C'"
check "read D (should be new)"        "ok: new"  "cat '$M/$N'"
check "append 'more' through D"       "ok"       "echo more >> '$M/$N'"
check "read C (should be new more)"   "ok: new more" "cat '$M/$C' | tr '\n' ' ' | sed 's/ \$//'"
listing
endcase 2 "deleted file readable through D, write through D lost"

step "case 3: create C, rm C, create D"
fresh
check "create C (contents: first)"    "ok"       "echo first > '$M/$C'"
check "rm C"                          "ok"       "rm '$M/$C'"
check "create D (contents: nfd)"      "ok"       "echo nfd > '$M/$N'"
check "read C (should be nfd)"        "ok: nfd"  "cat '$M/$C'"
listing
endcase 3 "C doesn't find the file created as D"

step "case 4: mkdir C, rmdir C, mkdir D"
fresh
check "mkdir C"                       "ok"       "mkdir '$M/$C'"
check "rmdir C"                       "ok"       "rmdir '$M/$C'"
check "mkdir D"                       "ok"       "mkdir '$M/$N'"
check "test -d C (should exist)"      "ok"       "test -d '$M/$C'"
listing
endcase 4 "C doesn't find the directory created as D"

zfs destroy -r $FS
zpool destroy $P
echo
if [ -z "$bad_cases" ]; then
	echo "RESULT OK: all 4 cases correct (no stale names, deleted data gone, writes land)"
else
	echo "RESULT BUG:$bad_cases"
fi
