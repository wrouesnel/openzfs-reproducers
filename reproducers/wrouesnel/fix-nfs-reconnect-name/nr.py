#!/usr/bin/python3
# nr.py: helpers for demo.sh (python3 on the extended base).
#   nr.py mkdirs DIR N
#       create DIR/d0000000 ... DIR/d<N-1> (empty directories), with progress
#   nr.py storm CLIENTDIR SERVERDIR N HELD CLIENTS WRITER
#       one reconnect storm, as repros/nfs-reconnect/bench.sh in zfs-bug-hunt:
#       CLIENTS processes open HELD directories of CLIENTDIR (the NFS mount
#       of SERVERDIR), spread evenly over its N entries, and keep them open;
#       the server drops its dentry and inode caches (drop_caches = 2), so
#       nfsd's dentries for those directories are gone; then every client
#       looks up a name in each directory it holds, all clients at once.
#       Each lookup sends a file handle of a directory that nfsd has to
#       decode and reconnect: find the directory's name in SERVERDIR, a
#       search of its entries (zpl_get_name -> zap_value_search).
#       WRITER=1: meanwhile time server-side mkdirs in SERVERDIR (up to 20,
#       while the storm runs).
#       Prints shell assignments: per-lookup times (mean, median, p90, max,
#       ms), nfsd CPU (utime+stime of the nfsd threads, s), wall time (s),
#       and the mkdir times (median, max, ms; n).
import os, sys, time, threading

def mkdirs(d, n):
    os.makedirs(d, exist_ok=True)
    t = time.monotonic()
    for i in range(n):
        try:
            os.mkdir("%s/d%07d" % (d, i))
        except FileExistsError:
            pass
        if (i + 1) % 20000 == 0:
            print("   %7d directories (%.1f s)" % (i + 1, time.monotonic() - t), flush=True)

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
        comm = st[st.index("(") + 1:st.rindex(")")]
        if comm == "nfsd":
            fl = st[st.rindex(")") + 2:].split()
            s += int(fl[11]) + int(fl[12])	# utime, stime (fields 14, 15)
    return s

def q(v, p):
    return v[min(len(v) - 1, int(p * len(v)))]

def storm(cdir, sdir, n, held, par, writer):
    step = max(1, n // held)
    idx = list(range(0, n, step))[:held]
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
                    os.stat("f", dir_fd=fd)
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
    os.sync()
    with open("/proc/sys/vm/drop_caches", "w") as f:
        f.write("2\n")
    time.sleep(1)
    done = threading.Event()
    wl = []
    def wr():
        time.sleep(0.05)
        i = 0
        while not done.is_set() and len(wl) < 20:
            p = "%s/w%d_%d" % (sdir, os.getpid(), i)
            t = time.monotonic()
            os.mkdir(p)
            wl.append(time.monotonic() - t)
            os.rmdir(p)
            i += 1
            done.wait(0.05)
    t0 = nfsd_ticks(); w0 = time.monotonic()
    th = None
    if writer:
        th = threading.Thread(target=wr); th.start()
    os.close(go_w)
    lat = []
    for pid, r in kids:
        with os.fdopen(r) as f:
            lat += [float(x) for x in f.read().split()]
        os.waitpid(pid, 0)
    w1 = time.monotonic(); t1 = nfsd_ticks()
    done.set()
    if th:
        th.join()
    hz = os.sysconf("SC_CLK_TCK")
    lat.sort()
    print("OPS=%d MEAN=%.2f MED=%.2f P90=%.2f MAX=%.2f CPU=%.2f WALL=%.2f" % (
        len(lat), sum(lat) / len(lat) * 1000, q(lat, .5) * 1000, q(lat, .9) * 1000,
        lat[-1] * 1000, (t1 - t0) / hz, w1 - w0))
    if wl:
        wl.sort()
        print("WN=%d WMED=%.1f WMAX=%.1f" % (len(wl), q(wl, .5) * 1000, wl[-1] * 1000))
    else:
        print("WN=0 WMED=- WMAX=-")

cmd = sys.argv[1]
if cmd == "mkdirs":
    mkdirs(sys.argv[2], int(sys.argv[3]))
elif cmd == "storm":
    storm(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))
else:
    sys.exit("usage: nr.py mkdirs DIR N | storm CLIENTDIR SERVERDIR N HELD CLIENTS WRITER")
