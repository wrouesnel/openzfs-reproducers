#!/usr/bin/python3
# nr.py: helpers for demo.sh (python3 on the extended base).
#   nr.py fill DIR N HELD
#       DIR gets N entries: HELD directories d0000000, d<step>, ... spread
#       evenly over the index range, and empty files f<i> for the rest, so
#       the directory has N entries but only HELD of them cost a mkdir
#   nr.py storm CLIENTDIR N HELD CLIENTS
#       one reconnect storm (as wrouesnel/fix-nfs-reconnect-name): CLIENTS
#       processes open the HELD directories of CLIENTDIR (the NFS mount of a
#       directory filled by `fill`) and keep them open; the server drops its
#       dentry and inode caches; then every client looks up a name in each
#       directory it holds, all clients at once.  Each lookup makes nfsd
#       reconnect a directory: find its name in its parent (zpl_get_name).
#       Prints shell assignments: per-lookup times (median, p90, max, ms),
#       nfsd CPU (s), wall time (s)
#   nr.py exchange A B
#       renameat2(A, B, RENAME_EXCHANGE)
#   nr.py handles MOUNTDIR PATH...
#       for each directory PATH (on the file system mounted at MOUNTDIR):
#       name_to_handle_at(); then, one at a time, drop the server's dentry
#       and inode caches and open_by_handle_at() the handle; print
#       "PATH<TAB>the path the kernel reconnected (/proc/self/fd)<TAB>how
#       ZFS found the names": the dirent_name kstat counts during the open
#       (cookie hits, stale cookies, missing cookies, searches), or "-" on
#       a build without that kstat
#   nr.py nfscheck CLIENTPATH...
#       NFS client side: open each directory, drop the server's caches, then
#       read the file "id" through each directory fd (nfsd reconnects the
#       directory) and print "CLIENTPATH<TAB>its id, or the error"
import ctypes, os, sys, time

libc = ctypes.CDLL(None, use_errno=True)

def drop_caches():
    os.sync()
    with open("/proc/sys/vm/drop_caches", "w") as f:
        f.write("2\n")
    time.sleep(1)

def held_idx(n, held):
    step = max(1, n // held)
    return list(range(0, n, step))[:held]

def fill(d, n, held):
    os.makedirs(d, exist_ok=True)
    hs = set(held_idx(n, held))
    t = time.monotonic()
    for i in range(n):
        if i in hs:
            os.mkdir("%s/d%07d" % (d, i))
        else:
            os.close(os.open("%s/f%07d" % (d, i), os.O_CREAT | os.O_WRONLY, 0o644))
        if (i + 1) % 100000 == 0 or i + 1 == n:
            print("   %8d entries (%.1f s)" % (i + 1, time.monotonic() - t), flush=True)

def nfsd_ticks():
    s = 0
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % p) as f:
                st = f.read()
        except OSError:
            continue
        if st[st.index("(") + 1:st.rindex(")")] == "nfsd":
            fl = st[st.rindex(")") + 2:].split()
            s += int(fl[11]) + int(fl[12])	# utime, stime
    return s

def q(v, p):
    return v[min(len(v) - 1, int(p * len(v)))]

def storm(cdir, n, held, par):
    idx = held_idx(n, held)
    groups = [idx[i::par] for i in range(par)]
    ready_r, ready_w = os.pipe()
    go_r, go_w = os.pipe()
    kids = []
    for g in range(par):
        lat_r, lat_w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(go_w); os.close(ready_r); os.close(lat_r)
            fds = [os.open("%s/d%07d" % (cdir, i), os.O_RDONLY) for i in groups[g]]
            os.write(ready_w, b"r")
            os.read(go_r, 1)	# EOF when the parent closes go_w
            lat = []
            for fd in fds:
                t = time.monotonic()
                try:
                    os.stat("x", dir_fd=fd)
                except FileNotFoundError:
                    pass
                lat.append(time.monotonic() - t)
            with os.fdopen(lat_w, "w") as f:
                f.write("\n".join("%.9f" % x for x in lat) + "\n")
            os._exit(0)
        os.close(lat_w)
        kids.append((pid, lat_r))
    os.close(ready_w); os.close(go_r)
    got = 0
    while got < par:
        got += len(os.read(ready_r, par))
    drop_caches()
    t0 = nfsd_ticks(); w0 = time.monotonic()
    os.close(go_w)
    lat = []
    for pid, r in kids:
        with os.fdopen(r) as f:
            lat += [float(x) for x in f.read().split()]
        os.waitpid(pid, 0)
    w1 = time.monotonic(); t1 = nfsd_ticks()
    lat.sort()
    print("OPS=%d MED=%.3f P90=%.3f MAX=%.3f CPU=%.2f WALL=%.2f" % (
        len(lat), q(lat, .5) * 1000, q(lat, .9) * 1000, lat[-1] * 1000,
        (t1 - t0) / os.sysconf("SC_CLK_TCK"), w1 - w0))

def exchange(a, b):
    AT_FDCWD, RENAME_EXCHANGE = -100, 2
    if libc.renameat2(AT_FDCWD, a.encode(), AT_FDCWD, b.encode(), RENAME_EXCHANGE) != 0:
        e = ctypes.get_errno()
        sys.exit("renameat2 %s %s: %s" % (a, b, os.strerror(e)))

class FH(ctypes.Structure):
    _fields_ = [("handle_bytes", ctypes.c_uint), ("handle_type", ctypes.c_int),
                ("f_handle", ctypes.c_ubyte * 128)]

KSTAT = "/proc/spl/kstat/zfs/dirent_name"

def kstats():
    try:
        with open(KSTAT) as f:
            k = {l.split()[0]: int(l.split()[2]) for l in f.read().splitlines()[2:]}
    except OSError:
        return None
    return [k[n] for n in ("cookie_hits", "cookie_stale", "cookie_missing", "searches")]

def handles(mnt, paths):
    AT_FDCWD = -100
    hs = []
    for p in paths:
        fh = FH(); fh.handle_bytes = 128
        mid = ctypes.c_int()
        if libc.name_to_handle_at(AT_FDCWD, p.encode(), ctypes.byref(fh), ctypes.byref(mid), 0) != 0:
            sys.exit("name_to_handle_at %s: %s" % (p, os.strerror(ctypes.get_errno())))
        hs.append(fh)
    # the mount fd: the file system's root (any fd on it would do)
    mfd = os.open(mnt, os.O_RDONLY)
    for p, fh in zip(paths, hs):
        drop_caches()
        k0 = kstats()
        fd = libc.open_by_handle_at(mfd, ctypes.byref(fh), os.O_RDONLY | os.O_DIRECTORY)
        if fd < 0:
            got = os.strerror(ctypes.get_errno())
        else:
            got = os.readlink("/proc/self/fd/%d" % fd)
            os.close(fd)
        k1 = kstats()
        how = "-" if k0 is None else " ".join(str(b - a) for a, b in zip(k0, k1))
        print("%s\t%s\t%s" % (p, got, how))

def nfscheck(paths):
    fds = [os.open(p, os.O_RDONLY) for p in paths]
    drop_caches()
    for p, fd in zip(paths, fds):
        try:
            nfd = os.open("id", os.O_RDONLY, dir_fd=fd)
            v = os.read(nfd, 200).decode().strip()
            os.close(nfd)
        except OSError as e:
            v = os.strerror(e.errno)
        print("%s\t%s" % (p, v))

cmd = sys.argv[1]
if cmd == "fill":
    fill(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
elif cmd == "storm":
    storm(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]))
elif cmd == "exchange":
    exchange(sys.argv[2], sys.argv[3])
elif cmd == "handles":
    handles(sys.argv[2], sys.argv[3:])
elif cmd == "nfscheck":
    nfscheck(sys.argv[2:])
else:
    sys.exit("usage: nr.py fill|storm|exchange|handles|nfscheck ...")
