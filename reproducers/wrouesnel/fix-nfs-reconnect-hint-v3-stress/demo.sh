#!/bin/bash
# demo.sh -- the v3 stress suite of openzfs #16254 / #18134 (directory entry
# cookies, SA_ZPL_PARENT_COOKIE; branch fix-nfs-reconnect-hint-v3), on the
# PR head's debug build.  Not a bug reproducer: the evidence behind the
# PR's "Stress" testing bullets, re-run.  /demo/stress/v3_stress.py is the
# script; this wrapper picks the tests and prints the summary.
#
# Tests (STRESS_TAGS, comma separated; default: all, in this order):
#   churn     4 threads create/unlink/rename (within and across
#             directories)/link/rename-over while 2 threads reopen held
#             directories by file handle after drop_caches: no wrong name,
#             nearly every name found by cookie
#   zapshape  cookies stay valid from microzap to fat ZAP, through leaf
#             splits and pointer table growth, and removal/reuse of entries
#   norm      hash collisions and every normalization/case setting
#             (cs, ci, mixed, mixed+formD, formD, formC, formKC+ci, utf8only)
#   links     hard links, rename over files and empty directories,
#             rmdir/recreate of a parent, xattr directories
#   sendrecv  send/recv full, -c, -L, -c -L, raw -w (encrypted),
#             incremental, receiver repaired with zfs rewrite -N -r, clone,
#             rollback: received cookie states match the source
#   spill     legacy/1k/auto dnodes with random xattr=sa xattrs: the cookie
#             never causes a spill block, no object inconsistent
#   longname  names over 255 bytes (longname=on): ESTALE/ENAMETOOLONG, no
#             search; short names exact
#   ctldir    .zfs snapshot directories reopened by handle: exact paths
#   perm      zfs rewrite -N: EACCES for a user who can't write the object,
#             own directory recorded, root fine, EROFS on a read-only fs
# Every test makes its own pool on the run disk, checks every object's zdb
# path and cookie verdict (valid/stale/none/absent, never inconsistent),
# and ends with zdb -b, a scrub and zpool status -v.
#
# STRESS_SCALE (default 0.25): scales churn's 120 s and zapshape's
# 100,000/400,000 entries and 20,000 removed/reused names; 1 is the
# full-length run of the v3 testing (prs/16254-v3-testing.md rows 8-16).
#   podman run --rm -it --device /dev/kvm -e STRESS_TAGS=churn,spill IMAGE
#   podman run --rm -it --device /dev/kvm -e STRESS_SCALE=1 IMAGE
# RESULT OK when every check of every selected test passed, RESULT BUG when
# one failed, RESULT ERROR for an unknown tag or a bad scale.
set -u
VALID="churn zapshape norm links sendrecv spill longname ctldir perm"
eval "$(zr env 2>/dev/null)"
TAGS=${STRESS_TAGS:-all} SCALE=${STRESS_SCALE:-0.25}
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }

want=()
for t in ${TAGS//,/ }; do
	if [ "$t" = all ]; then want+=($VALID); continue; fi
	case " $VALID " in
	*" $t "*) want+=("$t") ;;
	*) echo "unknown STRESS_TAGS tag '$t'; valid tags: $VALID (or all)"
	   echo "RESULT ERROR: unknown tag $t (valid: ${VALID// /,})"; exit 2 ;;
	esac
done
# each once, in the suite's order
sel=()
for t in $VALID; do case " ${want[*]} " in *" $t "*) sel+=("$t") ;; esac; done
[ ${#sel[@]} -gt 0 ] || { echo "RESULT ERROR: STRESS_TAGS selects no test (valid: ${VALID// /,})"; exit 2; }
[[ $SCALE =~ ^[0-9]*\.?[0-9]+$ ]] && awk -v s="$SCALE" 'BEGIN { exit !(s > 0) }' ||
    { echo "RESULT ERROR: STRESS_SCALE=$SCALE is not a positive number"; exit 2; }

step "v3 stress suite: ${sel[*]} (STRESS_TAGS=$TAGS), scale $SCALE"
echo "   build: zfs $(cat /sys/module/zfs/version), srcversion $(cat /sys/module/zfs/srcversion)"
echo "   pool vdev: $DEMO_DISK (recreated by each test)"
echo "   script: /demo/stress/v3_stress.py ${sel[*]}"
grep -q . /proc/spl/kstat/zfs/dirent_name 2>/dev/null ||
    { echo "RESULT ERROR: no dirent_name kstat: this build has no directory entry cookies"; exit 2; }
t0=$(date +%s)
V3S_VDEV=$DEMO_DISK V3S_SCALE=$SCALE V3S_EXPORT_LAST=1 \
    python3 -u /demo/stress/v3_stress.py "${sel[@]}" 2>&1 | tee /tmp/stress.out
rc=${PIPESTATUS[0]}
el=$(( $(date +%s) - t0 ))

step "summary"
grep '^SECTION ' /tmp/stress.out
checks=$(grep -c '^CHECK [a-z]* \(PASS\|FAIL\) ' /tmp/stress.out)
failed=$(grep -c '^CHECK [a-z]* FAIL ' /tmp/stress.out)
echo
echo "tags run: ${sel[*]} (STRESS_TAGS=$TAGS, STRESS_SCALE=$SCALE); valid tags: $VALID"
echo "$checks checks, $failed failed, $el s; the last test's pool is exported on the run disk"
if [ "$failed" = 0 ] && [ "$rc" = 0 ] && [ "$checks" -gt 0 ]; then
	echo "RESULT OK: $checks checks passed (${sel[*]})"
elif [ "$failed" -gt 0 ]; then
	echo "failed:"; grep '^CHECK [a-z]* FAIL ' /tmp/stress.out | head -5 | sed 's/^/   /'
	echo "RESULT BUG: $failed of $checks checks failed"
else
	echo "RESULT ERROR: the suite exited $rc"
fi
