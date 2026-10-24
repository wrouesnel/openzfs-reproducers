#!/bin/bash
# lustre.sh CMD [ARGS]: the Lustre side of the demo, run by demo.sh inside the
# AlmaLinux 9 chroot of one build (OpenZFS + Lustre installed from the
# payload), as root.  Lustre's own test framework (/usr/lib64/lustre/tests)
# with FSTYPE=zfs: 1 MDT and 2 OSTs, each a pool on a file vdev in /tmp, and
# the client, all on this node.  The same settings as the zfs-bug-hunt spike
# (repros/16254/lustre/run.sh).  Lines starting "@@R " are results that
# demo.sh collects.
#   mount | mountn     llmount.sh (format + mount) | llmount.sh -n (mount only)
#   sanity "ONLY"      sanity.sh with that ONLY list
#   lfsck              lctl lfsck_start -A -r -t all, wait, summary
#   cleanup            sync, llmountcleanup.sh (unmounts; the pools stay in /tmp)
#   status             zpool status -v of the imported pools
#   pools              each pool: import, status, scrub, export, zdb -b, the SA
#                      registry and the objects zdb shows with a cookie line
#   populate LABEL     a tree with data, hard links, renames, xattrs, a striped
#                      file; its list and md5s in /tmp/x/LABEL.*
#   verify LABEL       compare the tree with LABEL's lists, then change it
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C LC_ALL=C
T=/usr/lib64/lustre/tests
export FSTYPE=zfs MDSCOUNT=1 OSTCOUNT=2 MDSSIZE=1000000 OSTSIZE=2000000
export PDSH="pdsh -S -Rexec -w" LOAD_MODULES_REMOTE=false
run() { echo "# $*"; "$@"; }
pools_imported() { zpool list -H -o name 2>/dev/null; }

case ${1:?cmd} in
mount) bash $T/llmount.sh; rc=$?; echo "@@R mount rc=$rc"; exit $rc ;;
mountn) bash $T/llmount.sh -n; rc=$?; echo "@@R mount rc=$rc"; exit $rc ;;
sanity)
	ONLY="$2" timeout 5400 bash $T/sanity.sh; rc=$?
	echo "@@R sanity rc=$rc" ;;
lfsck)
	M=lustre-MDT0000
	run lctl lfsck_start -M $M -A -r -t all || { echo "@@R lfsck start=FAILED"; exit 1; }
	for _ in $(seq 1 180); do
		s=$(lctl get_param -n mdd.$M.lfsck_namespace | awk '/^status:/{print $2}')
		l=$(lctl get_param -n mdd.$M.lfsck_layout | awk '/^status:/{print $2}')
		case "$s $l" in *scanning*) sleep 5 ;; *) break ;; esac
	done
	echo "# lctl get_param mdd.$M.lfsck_namespace mdd.$M.lfsck_layout"
	lctl get_param -n mdd.$M.lfsck_namespace | grep -E "^(status|flags|checked_phase[12]|dirent_repaired|linkea_repaired|nlinks_repaired|lost_found|dangling_repaired|multiple_linked_checked|multiple_referenced_repaired|bad_file_type_repaired|name_hash_repaired|failed_phase[12]):" | sed 's/^/  namespace /'
	lctl get_param -n mdd.$M.lfsck_layout | grep -E "^(status|flags|checked_phase[12]|repaired_[a-z_]*|failed_phase[12]):" | sed 's/^/  layout    /'
	nr=$(lctl get_param -n mdd.$M.lfsck_namespace | awk -F': *' '/_repaired:|^lost_found:/{s+=$2} END{print s+0}')
	lr=$(lctl get_param -n mdd.$M.lfsck_layout | awk -F': *' '/^repaired_/{s+=$2} END{print s+0}')
	echo "@@R lfsck namespace=$s namespace_repaired=$nr layout=$l layout_repaired=$lr" ;;
cleanup)
	# llmountcleanup unmounts the client with -f, which drops dirty pages
	sync; sleep 5; sync
	bash $T/llmountcleanup.sh; rc=$?; echo "@@R cleanup rc=$rc"
	[ -z "$(pools_imported)" ] || { echo "pools still imported:"; pools_imported; } ;;
status)
	for p in $(pools_imported); do echo "# zpool status -v $p"; zpool status -v "$p"; done ;;
pools)
	for p in $(zpool import -d /tmp 2>/dev/null | awk '/pool:/{print $2}' | sort); do
		echo; echo "---- pool $p"
		run zpool import -d /tmp -o cachefile=none -N "$p" || { echo "@@R pool $p import=FAILED"; continue; }
		run zpool status -v "$p"
		run zpool scrub -w "$p"
		run zpool status -v "$p"
		errs=$(zpool status "$p" | sed -n 's/.*scrub repaired .* with \([0-9]*\) errors.*/\1/p')
		dataerr=$(zpool status "$p" | grep -q 'errors: No known data errors' && echo none || echo SOME)
		ds=$(zfs list -H -o name -r "$p" | sed -n 2p)
		run zpool export "$p"
		echo "# zdb -e -p /tmp -b $p"
		zdb -e -p /tmp -b "$p" 2>&1 | grep -E "leaked|No leaks|errors|Traversing|bp count" | head
		leaks=$(zdb -e -p /tmp -b "$p" 2>&1 | grep -q 'No leaks' && echo no || echo YES)
		zdb -e -p /tmp -dddd "$ds" >/tmp/x/zdb.$$ 2>&1
		names=$(awk '/SA attr registration/{f=1} f && /ZPL_/{print $1} f && /^$/ && n++ > 2 {exit}' /tmp/x/zdb.$$ | sort -u)
		echo "SA registry of $ds: $(echo $names | wc -w) ZPL names: $(echo $names)"
		objs=$(grep -c $'^\tparent' /tmp/x/zdb.$$) cl=$(grep -c $'^\tcookie' /tmp/x/zdb.$$)
		set=$(grep $'^\tcookie' /tmp/x/zdb.$$ | grep -vc $'cookie\tnone')
		echo "zdb -dddd $ds: $objs objects with a parent, $cl with a cookie line, $set with a cookie set (not 'none'):"
		awk '$1 ~ /^[0-9]+$/ && NF >= 9 { obj = $1; type = ""; for (i = 9; i <= NF; i++) type = type " " $i }
		     /^\tpath\t/ { path = $2 } /^\tparent\t/ { par = $2 }
		     /^\tcookie\t/ { sub(/^\t/, ""); printf "    object %s (%s) path %s parent %s: %s\n", obj, substr(type, 2), path, par, $0 }' /tmp/x/zdb.$$
		rm -f /tmp/x/zdb.$$
		pc=no; echo " $names " | grep -q ' ZPL_PARENT_COOKIE' && pc=yes
		echo "@@R pool $p scrub_errors=${errs:-?} data_errors=$dataerr leaks=$leaks objects=$objs cookie_lines=$cl cookies_set=$set zpl_names=$(echo $names | wc -w) parent_cookie_attr=$pc"
	done ;;
populate)
	L=$2 d=/mnt/lustre/x
	mkdir -p $d/big /tmp/x
	echo "# 3000 files, 200 directories with 256 KiB of data and a hard link each, 100 renames with a user xattr, 100 unlinks, a symlink, a 2-stripe 8 MiB file"
	for i in $(seq 1 3000); do echo "f$i" >$d/big/f$i; done
	for i in $(seq 1 200); do mkdir -p $d/t/d$i/s; dd if=/dev/urandom of=$d/t/d$i/s/data bs=64k count=4 status=none; ln $d/t/d$i/s/data $d/t/d$i/hl; done
	for i in $(seq 1 100); do mv $d/big/f$i $d/t/d$i/renamed; setfattr -n user.k$i -v "v$i" $d/t/d$i/renamed; done
	for i in $(seq 101 200); do rm $d/big/f$i; done
	ln -s ../big $d/t/link; lfs setstripe -c 2 $d/striped; dd if=/dev/urandom of=$d/striped bs=1M count=8 status=none
	(cd /mnt/lustre && find x -printf '%y %n %s %p\n' | sort >/tmp/x/$L.list && find x -type f -exec md5sum {} + | sort -k2 >/tmp/x/$L.md5)
	echo "tree: $(wc -l </tmp/x/$L.list) entries, $(wc -l </tmp/x/$L.md5) files (md5)"
	f=$(lfs path2fid $d/t/d7/renamed); echo "fid2path $f: $(lfs fid2path /mnt/lustre "$f" | tr '\n' ' ')"
	lfs getstripe -c $d/striped | sed 's/^/stripe count of x\/striped: /' ;;
verify)
	L=$2 d=/mnt/lustre/x ok=yes
	(cd /mnt/lustre && find x -printf '%y %n %s %p\n' | sort >/tmp/x/chk.list && find x -type f -exec md5sum {} + | sort -k2 >/tmp/x/chk.md5)
	if cmp -s /tmp/x/$L.list /tmp/x/chk.list; then tl=match; echo "tree list (type, links, size, path) MATCHES: $(wc -l </tmp/x/chk.list) entries"
	else tl=DIFFERS ok=no; echo "tree list DIFFERS:"; diff /tmp/x/$L.list /tmp/x/chk.list | head -20; fi
	if cmp -s /tmp/x/$L.md5 /tmp/x/chk.md5; then md=match; echo "md5 of every file MATCHES: $(wc -l </tmp/x/chk.md5) files"
	else md=DIFFERS ok=no; echo "md5 DIFFERS:"; diff /tmp/x/$L.md5 /tmp/x/chk.md5 | head -20; fi
	f=$(lfs path2fid $d/t/d7/renamed); p=$(lfs fid2path /mnt/lustre "$f" | tr '\n' ' ')
	echo "fid2path $f: $p"
	fp=no; [ "$p" = "/mnt/lustre/x/t/d7/renamed " ] && fp=yes || ok=no
	xa=$(getfattr -n user.k60 --only-values $d/t/d60/renamed 2>/dev/null); echo "user.k60 of x/t/d60/renamed: $xa"
	[ "$xa" = v60 ] || ok=no
	echo "# changes: 50 renames back with a new hard link each, 501 unlinks, 500 creates"
	orc=0
	for i in $(seq 1 50); do mv $d/t/d$i/renamed $d/big/back$i && ln $d/big/back$i $d/t/d$i/hl2 || orc=1; done
	for i in $(seq 1000 1500); do rm $d/big/f$i || orc=1; done
	for i in $(seq 1 500); do touch $d/big/n$i || orc=1; done
	n=$(ls $d/big | wc -l); echo "x/big now has $n entries (expected 2849)"
	[ "$n" = 2849 ] && [ $orc = 0 ] || ok=no
	echo "@@R verify tree=$tl md5=$md fid2path=$fp xattr=$xa ops_rc=$orc entries=$n ok=$ok" ;;
*) echo "lustre.sh: unknown command $1" >&2; exit 2 ;;
esac
