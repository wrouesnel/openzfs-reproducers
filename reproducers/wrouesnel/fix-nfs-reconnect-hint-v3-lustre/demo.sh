#!/bin/bash
# demo.sh -- Lustre (osd-zfs) on OpenZFS master and on the directory entry
# cookie branch fix-nfs-reconnect-hint-v3 (openzfs/zfs#16254), side by side.
#
# Lustre's osd-zfs is an out-of-tree consumer of the ZAP and SA interfaces,
# and the branch adds an SA attribute (ZPL_PARENT_COOKIE) and ZAP functions.
# This runs the Lustre checks of the zfs-bug-hunt spike against both builds
# in one VM and compares them:
#   build     both builds' records (made when the image was built): Lustre's
#             configure result, warnings, and the modversions CRCs osd_zfs.ko
#             imports from zfs.ko (they differ: osd-zfs is rebuilt per build)
#   sanity    llmount.sh (1 MDT + 2 OSTs, ZFS pools on file vdevs, client on
#             this node) and a sanity.sh subset (~230 subtests); per test
#   lfsck     LFSCK (scrub, layout, namespace) after it: what it repaired
#   scrub     the pools after unmounting: scrub and zdb -b (leaks)
#   nocookie  the branch must give no Lustre-created object a cookie
#   cross     format and fill with one build, mount with the other (and the
#             same-build controls): the tree, md5s, fid2path, LFSCK, pools
#   debugpanic   (opt-in) a --enable-debug build of master under Lustre
#             panics at the first target registration (not the branch)
# LUSTRE_TAGS (podman run -e LUSTRE_TAGS=sanity,lfsck IMAGE) picks the
# phases, comma separated (default: all but debugpanic); LUSTRE_ONLY sets
# sanity.sh's ONLY list (comma separated).
#
# Lustre master 2.17.60 runs in an AlmaLinux 9 chroot (payload: built with
# the image, /demo/payload) on the almalinux9 target's kernel.  Each build
# (repro = master, fixed = the branch) is its own chroot: the AlmaLinux root
# plus that build's OpenZFS and Lustre, with a writable layer on the run
# disk.  The two builds' Lustre targets live in /tmp of the chroots (shared,
# on the run disk).  The VM booted with this image's own build (as every
# image does); the demo unloads it and loads each build's zfs.ko in turn.
#
# RESULT OK: every phase gives the branch the same outcome as master (no
# regression).  RESULT BUG: a difference (named).  RESULT ERROR: the
# baseline itself didn't work (master's mount failed, unknown tag, ...).
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/demo/bin LANG=C
eval "$(zr env 2>/dev/null)"
ALL="build sanity lfsck scrub nocookie cross" OPT="debugpanic"
ONLY_DEFAULT="0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 28 29 30 31 32 33 34 39 51a 51b 51d 54a 54c 56a 102 103 129 154 230b 230c"
K=$(uname -r) W=/w
NAME_repro=master NAME_fixed=branch NAME_debug=master-debug
step() { echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }
note() { echo "   $*"; }
die() { echo "RESULT ERROR: $*"; exit 2; }
t0=$SECONDS
el() { local s=$((SECONDS - t0)); printf '%d:%02d' $((s / 60)) $((s % 60)); }

# ---- the tags ----------------------------------------------------------------
want=${LUSTRE_TAGS:-all}
TAGS=
for t in ${want//,/ }; do
	case " all $ALL $OPT " in *" $t "*) ;; *) die "LUSTRE_TAGS: unknown tag '$t'; valid: $ALL $OPT, all (= $ALL)" ;; esac
	[ "$t" = all ] && t=$ALL
	TAGS="$TAGS $t"
done
TAGS=$(for t in $ALL $OPT; do case " $TAGS " in *" $t "*) echo -n "$t " ;; esac; done); TAGS=${TAGS% }
[ -n "$TAGS" ] || die "LUSTRE_TAGS='$want' selects nothing; valid: $ALL $OPT, all"
has() { case " $TAGS " in *" $1 "*) return 0 ;; esac; return 1; }
ONLY=${LUSTRE_ONLY:-$ONLY_DEFAULT}; ONLY=${ONLY//,/ }

P=; for d in /demo/payload/*/; do [ -d "$d/repro/root/usr/lib/modules/$K" ] && P=${d%/}; done
[ -n "$P" ] || die "no payload for kernel $K in /demo/payload"
lay() { case $1 in debug) echo "$P/repro/debug/root" ;; *) echo "$P/$1/root" ;; esac; }
rec() { case $1 in debug) echo "$P/repro/debug/build" ;; *) echo "$P/$1/build" ;; esac; }

step "Lustre (osd-zfs) on OpenZFS master and on fix-nfs-reconnect-hint-v3 ($(el))"
note "tags:   $TAGS$([ -n "${LUSTRE_TAGS:-}" ] && echo "  (LUSTRE_TAGS=$LUSTRE_TAGS)")"
has sanity && note "sanity: ONLY=$ONLY$([ -n "${LUSTRE_ONLY:-}" ] && echo '  (LUSTRE_ONLY)')"
note "kernel: $K, $(nproc) CPUs, $(awk '/MemTotal/{printf "%d MiB", $2/1024}' /proc/meminfo)"
for l in repro fixed; do note "$l = $(eval echo \$NAME_$l): $(sed -n 1,2p "$(rec $l)/summary.txt" | tr -s ' ' | tr '\n' ' ')"; done
note "lustre: $(sed -n 's/^lustre: *//p' "$(rec fixed)/summary.txt")"
note "this VM booted with the image's own build: $(head -1 /etc/zfshunt-build) ($(sed -n 2p /etc/zfshunt-build))"

# ---- setup: the run disk, the chroots, the network ------------------------------
step "setup: run disk, AlmaLinux 9 chroots, a network interface for LNet ($(el))"
mkdir -p $W
mkfs.ext4 -q -F -L lustre-w "$DEMO_DISK" && mount "$DEMO_DISK" $W || die "cannot make the run disk"
mkdir -p $W/tmp/x $W/res $W/log; chmod 1777 $W/tmp
# ZFS opens file vdevs from kernel threads, which see the VM's root, not the
# chroot's: /tmp is the same directory in both (the targets' vdevs live there)
mount --bind $W/tmp /tmp || die "cannot bind $W/tmp on /tmp"
# /dev/fd and friends (made by udev or systemd on a distribution)
[ -e /dev/fd ] || ln -s /proc/self/fd /dev/fd
for i in 0:stdin 1:stdout 2:stderr; do [ -e /dev/${i#*:} ] || ln -s /proc/self/fd/${i%%:*} /dev/${i#*:}; done
modprobe overlay && modprobe dummy || die "modprobe overlay/dummy failed (extended base?)"
# the image's own build was loaded at boot: unload it, each chroot loads its build
if grep -q '^zfs ' /proc/modules; then rmmod zfs && rmmod spl || die "cannot unload the boot build's zfs"; fi
CUR=
mkch() {	# the chroot of build L at $W/ch-L
	local l=$1 c=$W/ch-$1
	mountpoint -q $c && return 0
	mkdir -p $c $W/up-$l $W/wk-$l $W/mup-$l $W/mwk-$l
	mount -t overlay overlay -o "lowerdir=$(lay $l):$P/common/root,upperdir=$W/up-$l,workdir=$W/wk-$l" $c || return 1
	# the kernel's module tree (the extended base) with the build's zfs and Lustre modules
	mount -t overlay overlay -o "lowerdir=$(lay $l)/usr/lib/modules/$K:/usr/lib/modules/$K,upperdir=$W/mup-$l,workdir=$W/mwk-$l" $c/usr/lib/modules/$K || return 1
	mount -t proc proc $c/proc; mount --rbind /sys $c/sys; mount --rbind /dev $c/dev
	mount --bind $W/tmp $c/tmp; mount -t tmpfs tmpfs $c/run
	mkdir -p $c/demo; mount --bind /demo $c/demo
	echo "lustre-demo" >$c/etc/hostname
	printf '127.0.0.1 localhost\n10.0.2.15 lustre-demo\n' >$c/etc/hosts
	echo 'options lnet networks="tcp0(eth0)"' >$c/etc/modprobe.d/lustre-demo.conf
	# the test framework installs a udev rule (lctl set_param on Lustre's
	# change events) and reloads udev: each chroot runs its own udevd
	mkdir -p $c/etc/udev/rules.d
	# sanity.sh runs as RUNAS_ID 500 (and 501) where it tests permissions
	ch $l "getent passwd 500 >/dev/null || { groupadd -g 500 sanityusr && useradd -u 500 -g 500 -M -d /tmp -s /bin/bash sanityusr; }
	       getent passwd 501 >/dev/null || { groupadd -g 501 sanityus2 && useradd -u 501 -g 501 -M -d /tmp -s /bin/bash sanityus2; }" || return 1
	ch $l "depmod -a $K && ldconfig" || return 1
}
ch() {	# run CMD in build L's chroot
	local l=$1; shift
	chroot $W/ch-$l /usr/bin/env -i HOME=/root TERM="${TERM:-vt100}" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C bash -c "$*"
}
L() { local l=$1; shift; ch $l "bash /demo/lustre.sh $*"; }
hostname lustre-demo
if [ ! -e /sys/class/net/eth0 ]; then
	mkch repro || die "cannot set up the master chroot"
	ch repro "ip link add eth0 type dummy && ip addr add 10.0.2.15/24 dev eth0 && ip link set eth0 up && ip -br addr show eth0" || die "no network interface for LNet"
fi
unload() {	# Lustre and zfs out of the kernel
	[ -n "$CUR" ] || return 0
	ch $CUR "lustre_rmmod >/dev/null 2>&1; rmmod zfs spl 2>/dev/null; true"
	if grep -qE '^(zfs|spl|lnet|osd_zfs|libcfs) ' /proc/modules; then
		echo "still loaded:"; grep -E '^(zfs|spl|lnet|osd_zfs|libcfs|obdclass|ptlrpc) ' /proc/modules; return 1
	fi
	CUR=
}
switch() {	# make build L the loaded one
	local l=$1
	[ "$CUR" = "$l" ] && return 0
	unload || return 1
	mkch $l || return 1
	echo "# [$(eval echo \$NAME_$l)] modprobe zfs; modprobe osd_zfs (unload: lustre_rmmod; rmmod zfs spl)"
	# udev: the chroot's own udevd (the base's is stopped), so that the
	# rules the test framework writes into the chroot's /etc/udev apply
	pkill -x systemd-udevd; sleep 1
	if [ -x $W/ch-$l/usr/lib/systemd/systemd-udevd ]; then
		ch $l "/usr/lib/systemd/systemd-udevd --daemon && udevadm trigger && udevadm settle -t 30" || note "udevd failed to start"
	else
		printf '#!/bin/sh\nexit 0\n' >$W/ch-$l/usr/local/sbin/udevadm; chmod 755 $W/ch-$l/usr/local/sbin/udevadm
		note "no udev in this chroot: udevadm is a no-op"
	fi
	# the kernel's upcalls (the MDT's identity upcall l_getidentity, ...)
	# run in the VM's root: wrappers there run the chroot's programs
	for u in l_getidentity lctl; do
		printf '#!/bin/sh\nexec chroot %s /usr/sbin/%s "$@"\n' "$W/ch-$l" "$u" >/usr/sbin/$u; chmod 755 /usr/sbin/$u
	done
	ch $l "modprobe zfs" || return 1
	CUR=$l
	note "loaded $(eval echo \$NAME_$l): zfs $(cat /sys/module/zfs/version) srcversion $(cat /sys/module/zfs/srcversion) (built: $(sed -n 's/.*zfs.ko .* srcversion //p' "$(rec $l)/summary.txt"))"
	ch $l "zfs version | tr '\n' ' '; echo"
}

# ---- build -------------------------------------------------------------------
if has build; then
	step "build: Lustre built against each OpenZFS build (when this image was built) ($(el))"
	for l in repro fixed; do
		echo "--- $(eval echo \$NAME_$l) ($l)"; sed 's/^/   /' "$(rec $l)/summary.txt"
		ko=$(find "$(lay $l)/usr/lib/modules/$K/extra" -name osd_zfs.ko | head -1)
		echo "   osd_zfs.ko installed: ${ko#"$(lay $l)"}"
		echo "@@R build ok=$([ -n "$ko" ] && echo yes || echo no) warnings=$(wc -l <"$(rec $l)/lustre-warnings.txt")" >$W/res/$l.build
	done
	echo "--- Lustre's configure result (config.h HAVE_*/ZFS_*/LUSTRE_* defines), master vs branch:"
	if cmp -s "$(rec repro)/lustre-config-defines.txt" "$(rec fixed)/lustre-config-defines.txt"; then
		note "IDENTICAL ($(wc -l <"$(rec fixed)/lustre-config-defines.txt") defines)"; echo same >$W/res/build.defines
	else
		diff "$(rec repro)/lustre-config-defines.txt" "$(rec fixed)/lustre-config-defines.txt" | sed 's/^/   /'; echo DIFFER >$W/res/build.defines
	fi
	echo "--- modversions: the ZFS symbols osd_zfs.ko imports, and their CRCs in each build"
	awk 'NR == FNR { a[$1] = $2; next } ($1 in a) { print $1, a[$1], $2 }' "$(rec repro)/osd_zfs.modversions" "$(rec fixed)/osd_zfs.modversions" >$W/tmp/x/mv
	n=$(wc -l <$W/tmp/x/mv) nd=$(awk '$2 != $3' $W/tmp/x/mv | wc -l)
	zfsn=$(awk 'NR == FNR { z[$2] = 1; next } ($1 in z)' "$(rec fixed)/zfs.Module.symvers" $W/tmp/x/mv | wc -l)
	zfsd=$(awk 'NR == FNR { z[$2] = 1; next } ($1 in z) && $2 != $3' "$(rec fixed)/zfs.Module.symvers" $W/tmp/x/mv | wc -l)
	note "$zfsn of osd_zfs.ko's $n imports are OpenZFS (zfs.ko, spl.ko) symbols; $zfsd of them have a different CRC on the branch:"
	awk 'NR == FNR { z[$2] = 1; next } ($1 in z) && $2 != $3 { printf "%s ", $1 }' "$(rec fixed)/zfs.Module.symvers" $W/tmp/x/mv | fold -s -w 74 | sed 's/^/     /'; echo
	if [ "$zfsd" -gt 0 ]; then
		note "(so an osd_zfs.ko built against master doesn't load on the branch's zfs.ko: Lustre"
		note " builds osd-zfs per OpenZFS version, as each build here does; zap_* CRCs changed:"
		note " $(awk 'NR == FNR { z[$2] = 1; next } ($1 in z) && $2 != $3 && $1 ~ /^zap_/' "$(rec fixed)/zfs.Module.symvers" $W/tmp/x/mv | wc -l))"
	fi
	echo "$zfsd/$zfsn" >$W/res/build.crc
fi

# ---- per build: llmount, sanity, lfsck, cleanup, pools --------------------------
suite() {
	local l=$1 n; n=$(eval echo \$NAME_$l)
	step "$n: switch to the $n build ($(el))"
	switch $l || { echo "@@R mount rc=switch-failed" >$W/res/$l.mount; return 1; }
	step "$n: llmount.sh (format: 1 MDT + 2 OSTs on ZFS, mount the client) ($(el))"
	L $l mount 2>&1 | tee $W/log/$l.mount.log | grep -vE '^(Loading modules|detected|subsystem_debug|debug=|gss|quota/lquota)' | tail -40
	grep '^@@R mount' $W/log/$l.mount.log >$W/res/$l.mount
	if ! grep -q 'rc=0' $W/res/$l.mount; then
		echo "LLMOUNT FAILED on $n; a pool like the test framework's, by hand:"
		ch $l "truncate -s 1G /tmp/x/probe; zpool create -f -o cachefile=none -o multihost=on probe /tmp/x/probe; zpool status probe; zpool destroy probe; rm -f /tmp/x/probe; cat /etc/hostid | od -An -tx4"
		grep -iE 'error|cannot|fatal|failed' $W/log/$l.mount.log | head -20
		return 1
	fi
	ch $l "lfs df; zfs list -o name,used,mountpoint" | sed 's/^/   /'
	L $l status
	if has sanity; then
		step "$n: sanity.sh ONLY=\"$ONLY\" ($(el))"
		note "(the full output is in $W/log/$l.sanity.log; the console shows each test and its outcome)"
		L $l sanity "\"$ONLY\"" 2>&1 | tee $W/log/$l.sanity.log |
		    awk '/^(== sanity test [^ ]+:|PASS |FAIL |SKIP | SKIP:|@@R)/ || /@@@@@@ FAIL/ { print substr($0, 1, 110); fflush() }'
		grep -E '^(PASS|FAIL|SKIP) ' $W/log/$l.sanity.log | awk '{ print $2, $1 }' >$W/res/$l.sanity
		note "$n sanity: $(awk '{ c[$2]++ } END { printf "%d PASS, %d SKIP, %d FAIL", c["PASS"], c["SKIP"], c["FAIL"] }' $W/res/$l.sanity)"
		L $l status
	fi
	if has lfsck; then
		step "$n: LFSCK (lctl lfsck_start -A -r -t all) ($(el))"
		L $l lfsck 2>&1 | tee $W/log/$l.lfsck.log
		grep '^@@R lfsck' $W/log/$l.lfsck.log >$W/res/$l.lfsck
	fi
	step "$n: llmountcleanup.sh (unmount; the pools stay in /tmp) ($(el))"
	L $l cleanup 2>&1 | tail -5
	if has scrub || has nocookie; then
		step "$n: pools: import, zpool status -v, scrub, export, zdb -b, SA registry, cookies ($(el))"
		L $l pools 2>&1 | tee $W/log/$l.pools.log
		grep '^@@R pool' $W/log/$l.pools.log >$W/res/$l.pools
	fi
}
if has sanity || has lfsck || has scrub || has nocookie; then
	for l in repro fixed; do suite $l; done
fi

# ---- cross-version: format with A, mount with B ---------------------------------
xone() {	# A B
	local a=$1 b=$2 na nb; na=$(eval echo \$NAME_$1) nb=$(eval echo \$NAME_$2)
	step "cross $na -> $nb: format and fill with $na ($(el))"
	switch $a || return 1
	L $a mount >$W/log/x-$a-$b.fmt.log 2>&1 || { echo "LLMOUNT FAILED ($na)"; tail -20 $W/log/x-$a-$b.fmt.log; return 1; }
	L $a status
	L $a populate $a
	L $a cleanup 2>&1 | tail -3
	step "cross $na -> $nb: mount with $nb without formatting (llmount.sh -n), compare, change ($(el))"
	switch $b || return 1
	L $b mountn >$W/log/x-$a-$b.mnt.log 2>&1 || { echo "LLMOUNT -n FAILED ($nb)"; tail -20 $W/log/x-$a-$b.mnt.log; echo "@@R verify ok=no mount=FAILED" >$W/res/x-$a-$b; return 1; }
	L $b status
	L $b verify $a 2>&1 | tee $W/log/x-$a-$b.verify.log
	ch $b "sync"
	L $b lfsck 2>&1 | tee $W/log/x-$a-$b.lfsck.log
	L $b cleanup 2>&1 | tail -3
	L $b pools 2>&1 | tee $W/log/x-$a-$b.pools.log
	cat $W/log/x-$a-$b.verify.log $W/log/x-$a-$b.lfsck.log $W/log/x-$a-$b.pools.log | grep '^@@R' >$W/res/x-$a-$b
}
if has cross; then
	# ordered so that the loaded build changes only twice
	for ab in "fixed fixed" "fixed repro" "repro repro" "repro fixed"; do xone $ab; done
fi

# ---- comparison ----------------------------------------------------------------
v() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" "$1" 2>/dev/null | head -1; }
BAD= ERR=
diffr() { BAD="$BAD $1"; }
row() { printf '   %-9s %-30s %-30s %s\n' "$1" "$2" "$3" "$4"; }
step "comparison: master vs branch ($(el))"
row phase master branch verdict
if has build; then
	a="built, $(v $W/res/repro.build warnings) warnings" b="built, $(v $W/res/fixed.build warnings) warnings"
	vd=same; [ "$(v $W/res/repro.build ok)" = yes ] || ERR="$ERR build"
	[ "$(v $W/res/fixed.build ok)" = yes ] && [ "$a" = "$b" ] && [ "$(cat $W/res/build.defines)" = same ] || { vd=DIFFERS; diffr build; }
	row build "$a" "$b" "$vd (configure defines $(cat $W/res/build.defines); CRCs of zfs symbols differing: $(cat $W/res/build.crc))"
fi
if has sanity || has lfsck || has scrub || has nocookie; then
	for l in repro fixed; do grep -q 'rc=0' $W/res/$l.mount 2>/dev/null || { [ $l = repro ] && ERR="$ERR mount(master)" || diffr mount; }; done
	row mount "$(v $W/res/repro.mount rc | sed 's/^/rc=/')" "$(v $W/res/fixed.mount rc | sed 's/^/rc=/')" ""
fi
if has sanity; then
	cnt() { awk '{ c[$2]++ } END { printf "%d PASS %d SKIP %d FAIL", c["PASS"], c["SKIP"], c["FAIL"] }' "$1" 2>/dev/null; }
	[ -s $W/res/repro.sanity ] || ERR="$ERR sanity(master: no results)"
	if cmp -s $W/res/repro.sanity $W/res/fixed.sanity; then vd="same per test ($(wc -l <$W/res/fixed.sanity) tests)"
	else vd=DIFFERS; diffr sanity; fi
	row sanity "$(cnt $W/res/repro.sanity)" "$(cnt $W/res/fixed.sanity)" "$vd"
	cmp -s $W/res/repro.sanity $W/res/fixed.sanity || awk 'NR == FNR { m[$1] = $2; o[++n] = $1; next } { b[$1] = $2; if (!($1 in m)) o[++n] = $1 }
	    END { for (i = 1; i <= n; i++) { t = o[i]; x = (t in m) ? m[t] : "-"; y = (t in b) ? b[t] : "-"; if (x != y) printf "     test %s: master %s, branch %s\n", t, x, y } }' $W/res/repro.sanity $W/res/fixed.sanity
	fails=$(awk '$2 == "FAIL" { printf "%s ", $1 }' $W/res/repro.sanity)
	[ -n "$fails" ] && note "  (FAIL on master too: $fails- the spike's single-node environment failures were 17o and 154d)"
fi
if has lfsck; then
	lfsum() { [ -s "$1" ] && echo "ns $(v "$1" namespace)/$(v "$1" namespace_repaired) lo $(v "$1" layout)/$(v "$1" layout_repaired)" || echo none; }
	a=$(lfsum $W/res/repro.lfsck) b=$(lfsum $W/res/fixed.lfsck)
	vd=same; [ "$a" = "$b" ] || { vd=DIFFERS; diffr lfsck; }
	row lfsck "$a" "$b" "$vd (status/repaired)"
fi
if has scrub; then
	poolsum() { [ -s "$1" ] && awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] } n++
	    if (f["scrub_errors"] != "0" || f["data_errors"] != "none" || f["leaks"] != "no") b++ }
	    END { printf "%d pools, %d with errors/leaks", n, b }' "$1" || echo none; }
	a=$(poolsum $W/res/repro.pools) b=$(poolsum $W/res/fixed.pools)
	vd=same; [ "$a" = "$b" ] || { vd=DIFFERS; diffr scrub; }
	case $a in "3 pools, 0 with"*) ;; *) ERR="$ERR scrub(master: $a)" ;; esac
	row scrub "$a" "$b" "$vd (scrub errors, zdb -b leaks)"
fi
if has nocookie; then
	cs() { awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] } o += f["objects"]; l += f["cookie_lines"]; s += f["cookies_set"] }
	    END { printf "%d objs, %d cookie, %d set", o, l, s }' "$1" 2>/dev/null; }
	a=$(cs $W/res/repro.pools) b=$(cs $W/res/fixed.pools)
	s=$(awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "cookies_set") s += kv[2] } } END { print s + 0 }' $W/res/fixed.pools 2>/dev/null)
	vd="ok: no Lustre object has a cookie"; [ "${s:-1}" = 0 ] && [ -s $W/res/fixed.pools ] || { vd="Lustre objects HAVE cookies"; diffr nocookie; }
	row nocookie "$a" "$b" "$vd"
	note "  (zdb's cookie line: the branch's zdb prints it for every object that has the attribute;"
	note "   'none' is the placeholder of the ZPL root that zfs create makes; master's zdb has no such line)"
fi
if has cross; then
	for ab in "repro fixed" "fixed repro" "repro repro" "fixed fixed"; do
		set -- $ab; f=$W/res/x-$1-$2
		okv=$(v $f ok) lf="$(v $f namespace)/$(v $f namespace_repaired) $(v $f layout)/$(v $f layout_repaired)"
		pe=$(grep -c '^@@R pool' $f 2>/dev/null) pb=$(grep '^@@R pool' $f 2>/dev/null | grep -vc 'scrub_errors=0 data_errors=none leaks=no')
		r=PASS; { [ "$okv" = yes ] && [ "$lf" = "completed/0 completed/0" ] && [ "$pe" = 3 ] && [ "$pb" = 0 ]; } || r=FAIL
		row "cross" "format $(eval echo \$NAME_$1), mount $(eval echo \$NAME_$2)" "$r" "tree/md5/fid2path/xattr/ops ${okv:-?}, lfsck $lf, pools $pe ($pb bad)"
		if [ $r = FAIL ]; then
			if [ "$1 $2" = "repro repro" ]; then ERR="$ERR cross(master->master)"; else diffr "cross:$(eval echo \$NAME_$1)->$(eval echo \$NAME_$2)"; fi
		fi
	done
fi
unload >/dev/null 2>&1
echo
note "tags run: $TAGS   (elapsed $(el))"
note "logs: $W/log (the run disk, kept with -v DIR:/runs)"
if has debugpanic && [ "$TAGS" != debugpanic ]; then
	note "debugpanic follows the RESULT line: the VM ends in a kernel panic there"
fi
if [ "$TAGS" != debugpanic ]; then
	if [ -n "$ERR" ]; then echo "RESULT ERROR: the master baseline failed:$ERR"
	elif [ -n "$BAD" ]; then echo "RESULT BUG: the branch differs from master:$BAD"
	else echo "RESULT OK: Lustre on the branch = Lustre on master ($TAGS)"; fi
fi

# ---- debugpanic (opt-in) ---------------------------------------------------------
if has debugpanic; then
	step "debugpanic: llmount.sh on a --enable-debug build of master ($(el))"
	[ -d "$(lay debug)" ] || { echo "RESULT ERROR: this image has no debug build (payload repro/debug)"; exit 2; }
	sed 's/^/   /' "$(rec debug)/summary.txt"
	note "expected (zfs-bug-hunt spike): the kernel panics with 'dirtying dbuf obj=... but"
	note "not tx_held' in dmu_tx_dirty_buf() <- dmu_write_by_dnode() <- osd_write() <-"
	note "llog_osd_write_rec() <- mgs_write_log_mdt0(): Lustre writes an llog block its tx"
	note "didn't hold, which ZFS_DEBUG builds check. It is master, not the branch. The VM ends"
	note "here (the launcher prints PANIC:); the stack is on the kernel log (serial1)."
	switch debug || { echo "RESULT ERROR: cannot load the debug build"; exit 2; }
	L debug mount 2>&1 | tail -20
	sleep 30
	echo "RESULT ERROR: the debug build of master did not panic"
fi
