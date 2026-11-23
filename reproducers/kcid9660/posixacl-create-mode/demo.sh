#!/bin/bash
# demo.sh -- openzfs/zfs#19958: with acltype=posix, modes that the ZPL sets
# without a ZIL record are lost on replay.  The reporter's (@kcid9660)
# zpool-freeze script, for xattr=sa and xattr=dir, with an acltype=off
# control.  Two PRs fix one half each:
#   #19959 (kcid9660/posixacl-create-mode): the mode set at create by the
#          umask or a parent's default ACL (zpl_init_acl): file, dir,
#          inherit/file
#   #19960 (kcid9660/posixacl-setfacl-mode): the mode setfacl sets on an
#          existing file (zpl_set_posix_acl): acl
# The same demo is in both reproducers; /demo/focus says which half this
# image's RESULT is about (create or setfacl; both: #19959 now carries
# #19960's fix too, so its RESULT covers both).  The other half is reported
# on its own line.
#
# Per case: a pool on a file, umask 022, a file "acl" and a directory
# "inherit" (default ACL u::rwx,g::rwx,o::r-x) made and synced; then
# `zpool freeze` (nothing more reaches the pool except through the ZIL),
# and, each followed by an fsync, creating "file" (open mode 0666), "dir"
# (mkdir mode 0777), "inherit/file" (0666), and `setfacl -m
# u:65534:r--,m::r--,o::--- acl`.  Export (the frozen pool keeps only the
# ZIL), import (ZIL replay), compare the modes.
set -u
. /etc/demo-env 2>/dev/null
FOCUS=$(cat /demo/focus 2>/dev/null)
case $FOCUS in create | setfacl | both) ;; *) echo "RESULT ERROR: /demo/focus is '$FOCUS'"; exit 2 ;; esac
P=aclrepro IMG=/var/tmp/aclrepro.img
NAMES="file dir inherit/file acl"
# what each case asks for, and the mode it must have (umask 022; the
# default ACL gives inherit/file g::rw-; setfacl's mask r-- and o::--- give 640)
declare -A REQ=([file]="open 0666" [dir]="mkdir 0777" [inherit/file]="open 0666, default ACL" [acl]="0644, then setfacl")
declare -A WANT_posix=([file]=644 [dir]=755 [inherit/file]=664 [acl]=640)
declare -A WANT_off=([file]=644 [dir]=755 [inherit/file]=644 [acl]=644)
half() { [ "$FOCUS" = both ] && { echo both; return; }; case $1 in acl) echo setfacl ;; *) echo create ;; esac; }
x() { echo "# $*"; "$@"; }
modes() { local n; for n in $NAMES; do printf '%s=%s ' "$n" "$(stat -c %a "/$P/$n")"; done; }
mode_of() { local w; for w in $1; do [ "${w%%=*}" = "$2" ] && echo "${w#*=}"; done; return 0; }

echo "=== openzfs/zfs#19958: acltype=posix modes after ZIL replay ($DEMO_BUILD build: $(head -1 /etc/zfshunt-build))"
echo "    this image's RESULT is about $([ "$FOCUS" = both ] && echo 'both halves' || echo "the $FOCUS half") ($(case $FOCUS in create) echo '#19959: modes set at create' ;; setfacl) echo '#19960: the mode setfacl sets' ;; both) echo '#19959: modes set at create and the mode setfacl sets' ;; esac))"
declare -A BAD OTHER
ctl_bad= setup_bad=
for xa in sa dir; do
	for acl in posix off; do
		echo; echo "=============== acltype=$acl xattr=$xa ==============="
		zpool destroy $P 2>/dev/null; rm -f $IMG
		truncate -s 256M $IMG
		x zpool create -f -o cachefile=none -O acltype=$acl -O xattr=$xa $P $IMG || { echo "RESULT ERROR: zpool create failed"; exit 2; }
		cd /$P || exit 2
		umask 022
		dd if=/dev/zero of=seed bs=1 count=1 conv=fsync status=none
		dd if=/dev/zero of=acl bs=1 count=1 conv=fsync status=none
		mkdir inherit
		[ $acl = posix ] && { x setfacl -d -m u::rwx,g::rwx,o::r-x inherit 2>&1 || { echo "RESULT ERROR: setfacl -d failed"; exit 2; }; }
		x zpool sync $P
		x zpool freeze $P
		echo "# (frozen) create file, mkdir dir, create inherit/file, setfacl acl; fsync each"
		dd if=/dev/zero of=file bs=1 count=1 conv=fsync status=none
		mkdir dir
		dd if=/dev/zero of=inherit/file bs=1 count=1 conv=fsync status=none
		[ $acl = posix ] && { setfacl -m u:65534:r--,m::r--,o::--- acl 2>&1 || { echo "RESULT ERROR: setfacl -m failed"; exit 2; }; }
		/demo/fsyncf acl
		b=$(modes)
		[ $acl = posix ] && echo "# getfacl acl: $(getfacl -cpn acl 2>&1 | grep -E '^user:[^:]|^mask' | paste -sd' ' -)"
		cd /
		x zpool export $P
		x zpool import -d $IMG $P || { echo "RESULT ERROR: import failed"; exit 2; }
		x zpool status -v $P
		a=$(modes)
		[ $acl = posix ] && echo "# getfacl acl after replay: $(getfacl -cpn /$P/acl 2>&1 | grep -E '^user:[^:]|^mask' | paste -sd' ' -)"
		echo
		printf '  %-13s %-24s %-6s %-14s %-13s %s\n' case requested expect "before export" "after replay" ""
		for n in $NAMES; do
			w=WANT_$acl; w=${w}[$n]; w=${!w}
			mb=$(mode_of "$b" "$n") ma=$(mode_of "$a" "$n")
			v=kept; [ "$ma" != "$mb" ] && v=CHANGED
			[ "$mb" != "$w" ] && v="$v (before export: not $w)"
			printf '  %-13s %-24s %-6s %-14s %-13s %s\n' "$n" "${REQ[$n]}" "$w" "$mb" "$ma" "$v"
			[ "$mb" != "$w" ] && setup_bad="$setup_bad $acl/$xa:$n"
			if [ "$ma" != "$mb" ]; then
				if [ $acl = off ]; then ctl_bad="$ctl_bad xattr=$xa:$n"
				elif [ "$(half "$n")" = "$FOCUS" ]; then BAD[$xa]="${BAD[$xa]:-}$n $mb->$ma, "
				else OTHER[$xa]="${OTHER[$xa]:-}$n $mb->$ma, "
				fi
			fi
		done
		x zpool export $P
	done
done
rm -f $IMG
echo
if [ "$FOCUS" = create ]; then what="modes set at create (file, dir, inherit/file)" other="the setfacl mode (acl, #19960's half)"
elif [ "$FOCUS" = both ]; then what="modes set at create (file, dir, inherit/file) and the mode setfacl sets (acl)"
else what="the mode setfacl sets (acl)" other="the modes set at create (file, dir, inherit/file, #19959's half)"; fi
ostate="kept"; [ -n "${OTHER[sa]:-}${OTHER[dir]:-}" ] && ostate="CHANGED: xattr=sa ${OTHER[sa]:-kept, }xattr=dir ${OTHER[dir]:-kept, }" && ostate=${ostate%, }
[ "$FOCUS" = both ] || echo "# other half, $other: $ostate"
if [ -n "$setup_bad" ]; then
	echo "RESULT ERROR: a mode was not what the case sets before the export:$setup_bad"; exit 2
elif [ -n "$ctl_bad" ]; then
	echo "RESULT ERROR: the acltype=off control changed:$ctl_bad"; exit 2
elif [ -n "${BAD[sa]:-}${BAD[dir]:-}" ]; then
	d="xattr=sa ${BAD[sa]:-kept, }xattr=dir ${BAD[dir]:-kept, }"
	echo "RESULT BUG: acltype=posix: $what came back wrong after ZIL replay: ${d%, } $( [ "$FOCUS" = both ] || { [ "$ostate" = kept ] && echo '(other half: kept)' || echo '(other half: CHANGED)'; })"
else
	echo "RESULT OK: acltype=posix: $what came back after ZIL replay (xattr=sa and xattr=dir; acltype=off control kept) $( [ "$FOCUS" = both ] || { [ "$ostate" = kept ] && echo '(other half: kept)' || echo '(other half: still CHANGED, fixed by the other PR)'; })"
fi
