# demo-common.sh: boot-time logic shared by the Linux and FreeBSD demo bases
# (docs/reproducer-format.md).  Installed as /etc/demo-common.sh and sourced
# by the base's rc (busybox ash on Linux, sh on FreeBSD) after it has set:
#   OSNAME  SER1 (the second serial port)  ZSBIN ZLIB (where the build's
#   tools and libraries are linked)  and the functions
#   disk_list (candidate disks), serial_of DEV, mount_repro DEV DIR,
#   run_dev DEV (the device a demo should use on run disk DEV),
#   load_zfs BUILDDIR (loads the module, sets LOADED to a description of
#   what is loaded and returns non-zero on a failure or a mismatch).
# It finds the disks the container's launcher attached by their serials:
#   zfsdemo-demo         the demo (demo.sh, helpers, /manifest), on /demo
#   zfsdemo-build-LABEL  the one OpenZFS build of this image (LABEL is repro
#                        or fixed): build.txt, modules/, sbin/, lib/, on /zfs
#   zfsdemo-runN         run disks for the demo (DEMO_DISKS, DEMO_DISK = first)
#   zfsdemo-inspN        the same disks from an earlier run, to inspect
# (Older images had one disk, zfsdemo-build-LABEL, with the demo and a
# directory per build; that layout still loads.)  Then it loads the build,
# links its tools and libraries, and writes /etc/demo-env, /etc/zfshunt-build,
# /etc/motd and root's bash history.

demo_setup() {
	REPRO= DEMOD= BUILD= DEMO_MODE=none
	r0= r1= r2= r3= r4= r5= r6= r7= r8= r9=
	for d in $(disk_list); do
		s=$(serial_of "$d")
		case $s in
		zfsdemo-demo) DEMOD=$d ;;
		zfsdemo-build-*) REPRO=$d BUILD=${s#zfsdemo-build-} ;;
		zfsdemo-run[0-9]) eval "r${s#zfsdemo-run}=$(run_dev $d)"; DEMO_MODE=run ;;
		zfsdemo-insp[0-9]) eval "r${s#zfsdemo-insp}=$(run_dev $d)"; DEMO_MODE=inspect ;;
		esac
	done
	DEMO_DISKS=$(echo $r0 $r1 $r2 $r3 $r4 $r5 $r6 $r7 $r8 $r9)
	DEMO_DISK=${DEMO_DISKS%% *}
	BUG=? warn= LOADED=
	B=
	if [ -z "$REPRO" ]; then
		warn="no build disk (serial zfsdemo-build-LABEL) attached"
	elif [ -n "$DEMOD" ]; then
		mount_repro "$DEMOD" /demo || warn="could not mount the demo disk $DEMOD"
		mkdir -p /zfs 2>/dev/null
		mount_repro "$REPRO" /zfs && B=/zfs || warn="could not mount the build disk $REPRO"
	elif mount_repro "$REPRO" /demo; then
		B=/demo/$BUILD
	else
		warn="could not mount the reproducer disk $REPRO"
	fi
	if [ -n "$B" ]; then
		BUG=$(sed -n 's/^ID=//p; s/^BUG=//p' /demo/manifest | head -1 | tr -d "'")
		if [ ! -f "$B/build.txt" ]; then
			warn="the reproducer image has no build '$BUILD'"
		else
			for f in "$B"/sbin/*; do ln -sf "$f" "$ZSBIN/"; done
			for f in "$B"/lib/* /demo/lib/*; do
				[ -e "$f" ] || continue
				[ -e "$ZLIB/${f##*/}" ] || [ -L "$ZLIB/${f##*/}" ] || ln -s "$f" "$ZLIB/"
			done
			cp "$B/build.txt" /etc/zfshunt-build
			load_zfs "$B" || warn="loading the $BUILD build's zfs module FAILED"
		fi
	fi
	{
		echo "BUG=$BUG"; echo "DEMO_BUILD=$BUILD"; echo "DEMO_MODE=$DEMO_MODE"
		echo "DEMO_DISK=$DEMO_DISK"; echo "DEMO_DISKS='$DEMO_DISKS'"
	} >/etc/demo-env

	imp="zpool import -f -d /dev -a; zpool status; zfs list -r"
	if [ $DEMO_MODE = inspect ]; then
		if [ -f /demo/inspect.sh ]; then
			up="bash -x /demo/inspect.sh 2>$SER1" upup=/demo/inspect.sh
			printf '%s\n' "$imp" "$upup" "$up"
		else
			up=$imp upup=; printf '%s\n' "$imp"
		fi >/root/.bash_history
	else
		up="bash -x /demo/demo.sh 2>$SER1" upup=/demo/demo.sh
		printf '%s\n' "$upup" "$up" >/root/.bash_history
	fi
	{
		echo
		if [ $DEMO_MODE = inspect ]; then
			echo "=== zfs-repro $BUG, $BUILD build ($OSNAME), INSPECTING run disks ==="
		else
			echo "=== zfs-repro $BUG, $BUILD build ($OSNAME) ==="
		fi
		[ -f /etc/zfshunt-build ] && sed 's/^/build:  /' /etc/zfshunt-build
		echo "kernel: $(uname -sr)"
		[ -n "$LOADED" ] && echo "loaded: $LOADED"
		echo "disks:  ${DEMO_DISKS:-none} ($DEMO_MODE); reproducer $REPRO on /demo"
		[ -n "$warn" ] && echo "*** $warn"
		echo
		[ $DEMO_MODE = inspect ] && echo "  The demo is not run here and the pool is not recreated."
		echo "  press Up, Enter     ->  $up"
		if [ $DEMO_MODE != inspect ]; then
			echo "                          (bash -x trace + kernel log on the second serial port)"
		fi
		[ -n "$upup" ] && echo "  press Up Up, Enter  ->  $upup"
		[ $DEMO_MODE = inspect ] && echo "  by hand:  $imp" &&
		    echo "            zdb -e -p /dev POOL ...  (exported pool), zdb POOL (imported)"
		echo "  less /demo/demo.sh  shows the script;  poweroff  exports the pools and ends the VM"
		echo
	} >/etc/motd
}
