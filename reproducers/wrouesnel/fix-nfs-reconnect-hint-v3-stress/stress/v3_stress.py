#!/usr/bin/env python3
# Stress and edge-case checks for fix-nfs-reconnect-hint-v3
# (SA_ZPL_PARENT_COOKIE, sa hint, zfs rewrite -N; #16254 / #18134).
# Run as root in a disposable Linux test VM with the branch installed.
# Each section creates its own pool (on a sparse file under /var/tmp/v3s,
# or on the device V3S_VDEV) and prints "CHECK <section> PASS|FAIL
# <detail>" lines; it ends with a summary and exits 0 if every check passed.
#   v3_stress.py SECTION...   (churn zapshape norm links sendrecv spill
#                              longname ctldir perm all)
# Environment:
#   V3S_VDEV=DEV    the pool's vdev (destroyed and recreated per section)
#   V3S_SCALE=F     scales the long parts: churn's 120 s and zapshape's
#                   100,000/400,000 entries and 20,000 removed/reused
#                   (default 1 = the full-length run of the v3 testing)
#   V3S_EXPORT_LAST=1  export the last section's pool instead of destroying it
# This is the script of the v3 testing record (zfs-bug-hunt
# repros/16254/v3_stress.py) with those three knobs, zpool status / zdb -b /
# scrub output after every section, a perm section (v3_perm.sh), and a
# longname section that checks its result.  Works on Python 3.6.
import ctypes, errno, json, os, random, re, subprocess, sys, threading, time

os.environ["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:" + \
    os.environ.get("PATH", "/usr/bin:/bin")
W = "/var/tmp/v3s"
POOL = "v3s"
libc = ctypes.CDLL(None, use_errno=True)
results = []
ZDBKEY = {}	# dataset -> passphrase, for zdb -K on encrypted datasets
VDEV = os.environ.get("V3S_VDEV", "")
SCALE = float(os.environ.get("V3S_SCALE", "1"))


def scaled(n, least=1):
    return max(least, int(n * SCALE))


def sh(*cmd, check=True, out=False):
    p = subprocess.run(list(cmd), stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True)
    if check and p.returncode != 0:
        raise RuntimeError("%s: %s" % (" ".join(cmd), p.stdout[-2000:]))
    return p.stdout if out else p.returncode


def result(sec, ok, detail):
    line = "CHECK %s %s %s" % (sec, "PASS" if ok else "FAIL", detail)
    print(line, flush=True)
    results.append(line)


def note(msg):
    print("  " + msg, flush=True)


def mkpool(extra=()):
    destroy_pool()
    os.makedirs(W, exist_ok=True)
    img = VDEV
    if not img:
        img = W + "/vdev.img"
        with open(img, "w") as f:
            f.truncate(20 << 30)
    print("# zpool create -f -O mountpoint=none %s %s %s" %
          (" ".join(extra), POOL, img), flush=True)
    sh("zpool", "create", "-f", "-O", "mountpoint=none", *extra, POOL, img)


def destroy_pool():
    if sh("zpool", "list", POOL, check=False) == 0:
        sh("zpool", "destroy", "-f", POOL, check=False)


def mkfs(name, *props):
    ds = POOL + "/" + name
    mnt = W + "/mnt/" + name
    args = []
    for p in props:
        args += ["-o", p]
    sh("zfs", "create", "-o", "mountpoint=" + mnt, *args, ds)
    return ds, mnt


def tunable(name, val):
    with open("/sys/module/zfs/parameters/" + name, "w") as f:
        f.write(str(val))


def kstats():
    lines = open("/proc/spl/kstat/zfs/dirent_name").read().splitlines()
    return {w[0]: int(w[2]) for w in (l.split() for l in lines[2:])}


def kdelta(k0, k1):
    return {n: k1[n] - k0[n] for n in k0}


def drop_caches():
    with open("/proc/sys/vm/drop_caches", "w") as f:
        f.write("2")


class FH(ctypes.Structure):
    _fields_ = [("handle_bytes", ctypes.c_uint), ("handle_type", ctypes.c_int),
                ("f_handle", ctypes.c_ubyte * 128)]


def handle(p):
    fh, mid = FH(handle_bytes=128), ctypes.c_int()
    if libc.name_to_handle_at(-100, p.encode(), ctypes.byref(fh),
                              ctypes.byref(mid), 0) != 0:
        raise OSError(ctypes.get_errno(), "name_to_handle_at " + p)
    return fh


def by_handle(mfd, fh):
    """(path the kernel reconnects the handle to, errno)"""
    fd = libc.open_by_handle_at(mfd, ctypes.byref(fh), os.O_RDONLY)
    if fd < 0:
        return None, ctypes.get_errno()
    try:
        return os.readlink("/proc/self/fd/%d" % fd), 0
    finally:
        os.close(fd)


def zdb_objs(ds, objs):
    """obj -> {"path":..., "cookie": "valid|stale|none|absent|inconsistent",
    "spill": bool}"""
    res = {}
    objs = sorted(set(objs))
    for i in range(0, len(objs), 300):
        key = ["-K", ZDBKEY[ds]] if ds in ZDBKEY else []
        out = sh("zdb", *key, "-ddddd", ds,
                 *[str(o) for o in objs[i:i + 300]], check=False, out=True)
        obj, hdr = None, False
        for l in out.splitlines():
            w = l.split()
            if hdr and w and w[0].isdigit():
                obj = int(w[0])
                res[obj] = {"cookie": "absent", "spill": False}
            hdr = len(w) > 1 and w[0] == "Object" and w[1] == "lvl"
            if obj is None:
                continue
            if "dnode flags:" in l and "SPILL_BLKPTR" in l:
                res[obj]["spill"] = True
            if l.startswith("\tpath\t"):
                res[obj]["path"] = l.split("\t", 2)[2]
            if l.startswith("\tcookie\t"):
                res[obj]["cookie"] = w[-1]
    return res


def walk(mnt):
    """ino -> set of relative paths (every link), plus ino -> is_dir"""
    paths, isdir = {}, {}
    for root, dirs, files in os.walk(mnt):
        for n in dirs + files:
            p = os.path.join(root, n)
            st = os.lstat(p)
            rel = os.path.relpath(p, mnt)
            paths.setdefault(st.st_ino, set()).add(rel)
            isdir[st.st_ino] = os.path.isdir(p) and not os.path.islink(p)
    return paths, isdir


def check_tree(sec, ds, mnt, allow=("valid",), sample=None):
    """zdb path and cookie state of every object; returns state counts.
    A path must be one of the object's links; "inconsistent" never.
    A file whose newest link was removed has no path (ZPL_PARENT still
    names that link's directory; the same on master): counted as
    "nopath-multilink", not as bad."""
    sh("zpool", "sync", POOL)
    paths, isdir = walk(mnt)
    inos = list(paths)
    if sample and len(inos) > sample:
        random.seed(1)
        inos = random.sample(inos, sample)
    z = zdb_objs(ds, inos)
    counts, bad = {}, []
    for ino in inos:
        f = z.get(ino)
        if f is None:
            bad.append("%s: no zdb output" % sorted(paths[ino])[0])
            continue
        counts[f["cookie"]] = counts.get(f["cookie"], 0) + 1
        p = f.get("path", "")
        if "path not found" in p and not isdir[ino]:
            counts["nopath-multilink"] = counts.get("nopath-multilink",
                                                    0) + 1
        elif p.lstrip("/") not in paths[ino]:
            bad.append("%s: zdb path %s" % (sorted(paths[ino])[0], p))
        if f["cookie"] not in allow:
            bad.append("%s: cookie %s" % (sorted(paths[ino])[0], f["cookie"]))
    for b in bad[:20]:
        note("BAD " + b)
    result(sec, not bad, "%s: %d objects, cookies %s, %d bad" %
           (ds, len(inos), json.dumps(counts, sort_keys=True), len(bad)))
    return counts


def check_handles(sec, ds, mnt, rels, expect_hits=True):
    """Open each directory by handle, one remount each; the path must be
    exact (bytes) and, if expect_hits, found without any search."""
    fhs = [(r, handle(mnt + "/" + r)) for r in rels]
    bad = 0
    tot = None
    for rel, fh in fhs:
        sh("zfs", "unmount", ds)
        sh("zfs", "mount", ds)
        mfd = os.open(mnt, os.O_RDONLY | os.O_DIRECTORY)
        k0 = kstats()
        got, err = by_handle(mfd, fh)
        k = kdelta(k0, kstats())
        os.close(mfd)
        tot = k if tot is None else {n: tot[n] + k[n] for n in k}
        want = mnt + "/" + rel
        if got != want or (expect_hits and k["searches"] != 0):
            bad += 1
            note("BAD handle %r: got %r errno %d kstats %s" %
                 (rel, got, err, k))
    result(sec, bad == 0, "%s: %d directories by handle, kstats %s" %
           (ds, len(fhs), tot))


def zdb_b(sec):
    """the pool's end state: zdb -b (leak check), a scrub, zpool status -v"""
    sh("zpool", "sync", POOL)
    print("# zdb -b %s" % POOL, flush=True)
    p = subprocess.run(["zdb", "-b", POOL], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True)
    out = p.stdout
    ok = p.returncode == 0 and "No leaks" in out
    # the verdict and the block totals
    for l in out.splitlines():
        if re.search(r"No leaks|leaked|Traversing|bp count|ganged count|"
                     r"bp logical|bp physical|bp allocated|bp deduped|"
                     r"Normal class|error", l):
            print("   " + l.strip(), flush=True)
    print("# zpool scrub -w %s" % POOL, flush=True)
    sh("zpool", "scrub", "-w", POOL)
    print("# zpool status -v %s" % POOL, flush=True)
    st = sh("zpool", "status", "-v", POOL, out=True)
    print(st, flush=True)
    ok2 = "errors: No known data errors" in st and "repaired 0B" in st
    result(sec, ok and ok2, "zdb -b %s, scrub %s" %
           ("clean" if ok else "NOT clean", "clean" if ok2 else "NOT clean"))
    if not ok:
        print(out[-3000:])


# ---------------------------------------------------------------- churn
def churn(secs=120):
    sec = "churn"
    secs = scaled(secs, 10)
    note("%d s of churn" % secs)
    mkpool()
    ds, mnt = mkfs("churn")
    A, B = mnt + "/A", mnt + "/B"
    os.mkdir(A)
    os.mkdir(B)
    for i in range(20000):
        os.mkdir("%s/d%05d" % (A, i))
    for i in range(50):
        os.mkdir("%s/s%02d" % (B, i))
    held = {}		# ino -> [fh, current path]
    for i in list(range(0, 20000, 100)) + list(range(20000, 20050)):
        p = "%s/d%05d" % (A, i) if i < 20000 else "%s/s%02d" % (B, i - 20000)
        held[os.lstat(p).st_ino] = [handle(p), p]
    gen = dict.fromkeys(held, 0)	# odd while a rename is in flight
    lock = threading.Lock()
    stop = time.time() + secs
    stats = {"ops": 0, "reconnects": 0, "raced": 0, "wrong": 0, "err": 0}
    seq = [0]

    def churner(tid):
        r = random.Random(tid)
        mine = []
        while time.time() < stop:
            op = r.random()
            with lock:
                seq[0] += 1
                n = seq[0]
            try:
                if op < 0.3:		# create a file or directory
                    d = r.choice((A, B))
                    p = "%s/c%d-%d" % (d, tid, n)
                    if r.random() < 0.5:
                        os.mkdir(p)
                    else:
                        os.close(os.open(p, os.O_CREAT | os.O_WRONLY))
                    mine.append(p)
                elif op < 0.5 and mine:	# remove one
                    p = mine.pop(r.randrange(len(mine)))
                    (os.rmdir if os.path.isdir(p) else os.unlink)(p)
                elif op < 0.6 and mine:	# hard link a file, drop a name
                    p = r.choice(mine)
                    if not os.path.isdir(p):
                        q = "%s/l%d-%d" % (r.choice((A, B)), tid, n)
                        os.link(p, q)
                        os.unlink(p)
                        mine[mine.index(p)] = q
                elif op < 0.65 and mine:	# rename over an existing entry
                    p = r.choice(mine)
                    q = [x for x in mine if x != p and
                         os.path.isdir(x) == os.path.isdir(p)]
                    if q and (not os.path.isdir(p) or
                              not os.listdir(q[0])):
                        os.rename(p, q[0])
                        mine.remove(q[0])
                        mine[mine.index(p)] = q[0]
                else:			# rename a held directory
                    with lock:
                        ino = r.choice([i for i in held if gen[i] % 2 == 0])
                        gen[ino] += 1
                        old = held[ino][1]
                    new = "%s/h%d-%d" % (r.choice((A, B)), tid, n)
                    os.rename(old, new)
                    with lock:
                        held[ino][1] = new
                        gen[ino] += 1
                stats["ops"] += 1
            except (FileNotFoundError, FileExistsError, OSError) as e:
                if e.errno not in (errno.ENOENT, errno.EEXIST,
                                   errno.ENOTEMPTY):
                    raise

    def reconnector(tid):
        r = random.Random(100 + tid)
        while time.time() < stop:
            drop_caches()
            mfd = os.open(mnt, os.O_RDONLY | os.O_DIRECTORY)
            for ino in r.sample(list(held), 40):
                with lock:
                    g0 = gen[ino]
                    fh = held[ino][0]
                got, err = by_handle(mfd, fh)
                stats["reconnects"] += 1
                if got is None:
                    stats["err"] += 1
                    note("BAD reconnect errno %d" % err)
                    continue
                try:
                    ok = os.lstat(got).st_ino == ino
                except OSError:
                    ok = False
                with lock:
                    g1 = gen[ino]
                if not ok and (g0 != g1 or g0 % 2):
                    stats["raced"] += 1
                elif not ok:
                    stats["wrong"] += 1
                    note("BAD reconnect of %d returned %s (now %s)" %
                         (ino, got, held[ino][1]))
            os.close(mfd)

    k0 = kstats()
    ts = [threading.Thread(target=churner, args=(i,)) for i in range(4)]
    ts += [threading.Thread(target=reconnector, args=(i,)) for i in range(2)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    k = kdelta(k0, kstats())
    lookups = k["cookie_hits"] + k["cookie_stale"] + k["cookie_missing"]
    sane = (k["searches"] == k["cookie_stale"] + k["cookie_missing"] and
            k["cookie_missing"] == 0 and lookups > 0 and
            k["cookie_hits"] >= 0.95 * lookups)
    result(sec, stats["wrong"] == 0 and stats["err"] == 0 and sane,
           "%d ops, %d reconnects (%d raced with a rename), %d wrong names, "
           "%d errors; kstats %s" % (stats["ops"], stats["reconnects"],
                                    stats["raced"], stats["wrong"],
                                    stats["err"], k))
    check_tree(sec, ds, mnt, allow=("valid", "stale"))
    check_handles(sec, ds, mnt, [os.path.relpath(held[i][1], mnt)
                                 for i in list(held)[::10]])
    zdb_b(sec)


# ---------------------------------------------------------------- zapshape
def zap_info(ds, obj):
    out = sh("zdb", "-dddd", ds, str(obj), check=False, out=True)
    m = re.search(r"(microzap|Fat ZAP)", out)
    pt = re.search(r"Pointer table:\s+(\d+) elements\s+zt_blk: (\d+)", out)
    leafs = re.search(r"Leaf blocks: (\d+)", out)
    return "%s ptrtbl %s leaves %s" % (
        m.group(1) if m else "?",
        ("%s ext=%s" % (pt.group(1), pt.group(2) != "0")) if pt else "-",
        leafs.group(1) if leafs else "-")


def zapshape():
    sec = "zapshape"
    mkpool()
    ds, mnt = mkfs("z")
    Z = mnt + "/Z"
    os.mkdir(Z)
    zobj = os.lstat(Z).st_ino
    early = ["Z/e%02d" % i for i in range(40)]
    for r in early:
        os.mkdir(mnt + "/" + r)
    sh("zpool", "sync", POOL)
    note("40 entries: " + zap_info(ds, zobj))
    check_tree(sec, ds, mnt)
    n = 40
    for target in (2100, scaled(100000, 3000), scaled(400000, 6000)):
        while n < target:
            os.mkdir("%s/n%07d" % (Z, n))
            n += 1
        sh("zpool", "sync", POOL)
        note("%d entries: %s" % (n, zap_info(ds, zobj)))
        check_tree(sec, ds, mnt, sample=3000)
        check_handles(sec, ds, mnt, early[::8] + ["Z/n%07d" % (target - 1)])
    # remove entries and reuse their space with other names
    reuse = min(scaled(20000, 1000), n - 1000)
    for i in range(40, 40 + reuse):
        os.rmdir("%s/n%07d" % (Z, i))
    for i in range(reuse):
        os.mkdir("%s/r%07d" % (Z, i))
    note("%d removed, %d new names: %s" % (reuse, reuse, zap_info(ds, zobj)))
    check_tree(sec, ds, mnt, sample=3000)
    check_handles(sec, ds, mnt, early[::8] + ["Z/r0000007",
                                             "Z/r%07d" % (reuse - 1)])
    zdb_b(sec)


# ---------------------------------------------------------------- norm
NAMES = ["Foo", "foo", "FOO", "été", "été", "Straße",
         "STRASSE", "Å", "Å", "Å", "ﬁle", "file"]


def norm():
    sec = "norm"
    mkpool()
    sets = [("cs", ()), ("ci", ("casesensitivity=insensitive",)),
            ("mixed", ("casesensitivity=mixed",)),
            ("mixedD", ("casesensitivity=mixed", "normalization=formD")),
            ("formD", ("normalization=formD",)),
            ("formC", ("normalization=formC",)),
            ("formKCci", ("normalization=formKC",
                          "casesensitivity=insensitive")),
            ("utf8", ("utf8only=on",))]
    for name, props in sets:
        ds, mnt = mkfs(name, *props)
        made = []
        for big in (False, True):
            d = "big" if big else "small"
            os.mkdir("%s/%s" % (mnt, d))
            if big:
                for i in range(3000):
                    os.mkdir("%s/%s/pad%05d" % (mnt, d, i))
            for nm in NAMES:
                try:
                    os.mkdir("%s/%s/%s" % (mnt, d, nm))
                    made.append("%s/%s" % (d, nm))
                except FileExistsError:
                    pass
        note("%s: created %d of %d names per directory" %
             (name, len(made) // 2, len(NAMES)))
        check_tree(sec, ds, mnt)
        check_handles(sec, ds, mnt, made)
    zdb_b(sec)


# ---------------------------------------------------------------- links
def links():
    sec = "links"
    mkpool()
    ds, mnt = mkfs("l", "xattr=on")
    for d in ("a", "b", "c"):
        os.mkdir(mnt + "/" + d)
        for i in range(2500 if d == "a" else 10):
            os.mkdir("%s/%s/pad%04d" % (mnt, d, i))
    r = random.Random(7)
    files = []
    for i in range(300):
        p = "%s/%s/f%03d" % (mnt, r.choice("abc"), i)
        with open(p, "w") as f:
            f.write("x")
        files.append([p])
    for _ in range(3000):
        f = r.choice(files)
        if r.random() < 0.6 or len(f) == 1:
            q = "%s/%s/L%d" % (mnt, r.choice("abc"), r.randrange(10 ** 9))
            os.link(f[0], q)
            f.append(q)
        else:
            q = f.pop(r.randrange(len(f)))
            os.unlink(q)
    # rename over existing entries (files and empty directories)
    for i in range(50):
        a, b = r.sample(files, 2)
        os.rename(a[0], b[0])
        files.remove(b)
        a[0] = b[0]
    os.mkdir(mnt + "/a/victim")
    os.mkdir(mnt + "/b/mover")
    os.rename(mnt + "/b/mover", mnt + "/a/victim")
    # rmdir and recreate a parent: its child moved out first
    os.mkdir(mnt + "/c/P")
    os.mkdir(mnt + "/c/P/child")
    os.rename(mnt + "/c/P/child", mnt + "/b/child")
    os.rmdir(mnt + "/c/P")
    os.mkdir(mnt + "/c/P")
    os.mkdir(mnt + "/c/P/new")
    # directory-based xattrs (xattr=on): xattr directories and their files
    for f in files[:20]:
        os.setxattr(f[0], "user.k", b"v" * 100)
    os.setxattr(mnt + "/a", "user.k", b"v")
    # "a" has xattrs: with a SELinux label they fill a legacy dnode's
    # bonus buffer, so its cookie may be left out (absent)
    check_tree(sec, ds, mnt, allow=("valid", "stale", "absent"))
    check_handles(sec, ds, mnt, ["a/victim", "b/child", "c/P", "c/P/new",
                                 "a/pad1234", "a", "b", "c"],
                  expect_hits=False)
    zdb_b(sec)


# ---------------------------------------------------------------- sendrecv
def tree(mnt, stale=False):
    os.mkdir(mnt + "/t")
    for i in range(3000):
        os.mkdir("%s/t/d%04d" % (mnt, i))
    for i in range(20):
        with open("%s/t/f%02d" % (mnt, i), "wb") as f:
            f.write(os.urandom(256 << 10))
    if stale:
        tunable("zfs_parent_cookie", 0)
        for i in range(0, 3000, 300):
            os.rename("%s/t/d%04d" % (mnt, i), "%s/t/s%04d" % (mnt, i))
        os.mkdir(mnt + "/t/nocookie")
        tunable("zfs_parent_cookie", 1)


def sendrecv():
    sec = "sendrecv"
    mkpool(("-o", "feature@large_blocks=enabled"))
    keyf = W + "/key"
    with open(keyf, "w") as f:
        f.write("passphrase-for-v3s\n")
    ds, mnt = mkfs("src", "recordsize=1M")
    eds, emnt = mkfs("enc", "encryption=on", "keyformat=passphrase",
                     "keylocation=file://" + keyf)
    ZDBKEY[eds] = ZDBKEY[POOL + "/rraw"] = "passphrase-for-v3s"
    for m in (mnt, emnt):
        tree(m, stale=True)
    sh("zfs", "snapshot", ds + "@a")
    sh("zfs", "snapshot", eds + "@a")
    src_states = check_tree(sec, ds, mnt, allow=("valid", "stale", "none"))
    variants = [("full", ds, [], []), ("c", ds, ["-c"], []),
                ("L", ds, ["-L"], []), ("cL", ds, ["-c", "-L"], []),
                ("raw", eds, ["-w"], [])]
    for tag, src, sflags, rflags in variants:
        dst = POOL + "/r" + tag
        rmnt = W + "/mnt/r" + tag
        sh("sh", "-c", "zfs send %s %s@a | zfs recv -o mountpoint=%s %s" %
           (" ".join(sflags), src, rmnt, dst))
        if tag == "raw":
            sh("zfs", "load-key", "-L", "file://" + keyf, dst)
            sh("zfs", "mount", dst)
        got = check_tree(sec, dst, rmnt, allow=("valid", "stale", "none"))
        result(sec, got == src_states if tag != "raw" else True,
               "%s: received cookie states %s (source %s)" %
               (tag, json.dumps(got, sort_keys=True),
                json.dumps(src_states, sort_keys=True)))
        check_handles(sec, dst, rmnt, ["t/d0001", "t/s0300", "t/nocookie"],
                      expect_hits=False)
    # incremental after renames, then repair the receiver with rewrite -N
    for m in (mnt, emnt):
        for i in range(1, 3000, 250):
            os.rename("%s/t/d%04d" % (m, i), "%s/t/m%04d" % (m, i))
    sh("zfs", "snapshot", ds + "@b")
    sh("zfs", "snapshot", eds + "@b")
    for tag, src, sflags in (("full", ds, []), ("raw", eds, ["-w"])):
        dst = POOL + "/r" + tag
        sh("sh", "-c", "zfs send %s -i @a %s@b | zfs recv -F %s" %
           (" ".join(sflags), src, dst))
        rmnt = W + "/mnt/r" + tag
        if tag == "raw" and sh("zfs", "mount", dst, check=False) != 0:
            pass
        check_tree(sec, dst, rmnt, allow=("valid", "stale", "none"))
        sh("zfs", "rewrite", "-N", "-r", rmnt + "/t")
        check_tree(sec, dst, rmnt)
        check_handles(sec, dst, rmnt, ["t/s0300", "t/m0001", "t/nocookie"])
    # clone, rename in the clone, rollback the source
    sh("zfs", "clone", "-o", "mountpoint=" + W + "/mnt/clone", ds + "@b",
       POOL + "/clone")
    cm = W + "/mnt/clone"
    os.rename(cm + "/t/d0002", cm + "/t/cloned")
    sh("zfs", "rewrite", "-N", "-r", cm + "/t")
    check_tree(sec, POOL + "/clone", cm)
    check_handles(sec, POOL + "/clone", cm, ["t/cloned", "t/s0300"])
    os.rename(mnt + "/t/d0003", mnt + "/t/gone")
    sh("zfs", "rollback", ds + "@b")
    check_tree(sec, ds, mnt, allow=("valid", "stale", "none"))
    check_handles(sec, ds, mnt, ["t/d0003", "t/m0001"], expect_hits=False)
    zdb_b(sec)


# ---------------------------------------------------------------- spill
def spill():
    sec = "spill"
    mkpool()
    r = random.Random(3)
    for dn in ("legacy", "1k", "auto"):
        ds, mnt = mkfs("x" + dn, "xattr=sa", "dnodesize=" + dn)
        os.mkdir(mnt + "/d")
        objs = []
        for i in range(800):
            p = "%s/d/f%03d" % (mnt, i)
            os.close(os.open(p, os.O_CREAT | os.O_WRONLY))
            objs.append(p)
        for _ in range(4000):
            p = r.choice(objs)
            k = r.random()
            if k < 0.7:
                os.setxattr(p, "user.a%d" % r.randrange(3),
                            b"z" * r.randrange(0, 700))
            elif k < 0.85:
                try:
                    os.removexattr(p, "user.a%d" % r.randrange(3))
                except OSError:
                    pass
            else:
                q = "%s/d/R%d" % (mnt, r.randrange(10 ** 9))
                os.rename(p, q)
                objs[objs.index(p)] = q
        c = check_tree(sec, ds, mnt, allow=("valid", "absent"))
        z = zdb_objs(ds, [os.lstat(p).st_ino for p in objs])
        spills = sum(1 for f in z.values() if f["spill"])
        absent_nospill = sum(1 for f in z.values()
                             if f["cookie"] == "absent" and not f["spill"])
        note("%s: %d with spill blocks, %d without a cookie and no spill"
             % (dn, spills, absent_nospill))
        sh("zfs", "rewrite", "-N", "-r", mnt + "/d")
        check_tree(sec, ds, mnt, allow=("valid", "absent"))
    zdb_b(sec)


# ---------------------------------------------------------------- longname
def longname():
    sec = "longname"
    mkpool(("-o", "feature@longname=enabled"))
    ds, mnt = mkfs("ln", "longname=on")
    os.mkdir(mnt + "/p")
    for i in range(3000):
        os.mkdir("%s/p/pad%04d" % (mnt, i))
    long = "L" * 300
    os.mkdir(mnt + "/p/" + long)
    os.mkdir(mnt + "/p/" + long + "/child")
    os.mkdir(mnt + "/p/short")
    check_tree(sec, ds, mnt)
    # A name longer than the kernel's 256-byte get_name buffer can't be
    # reconnected: master's search gives ESTALE; the branch returns
    # ENAMETOOLONG from the cookie (counted as a hit), so ESTALE or
    # ENAMETOOLONG is right, and no search.  Short names must be exact.
    bad = 0
    for rel in ("p/" + long, "p/" + long + "/child", "p/short"):
        fh = handle(mnt + "/" + rel)
        sh("zfs", "unmount", ds)
        sh("zfs", "mount", ds)
        mfd = os.open(mnt, os.O_RDONLY | os.O_DIRECTORY)
        k0 = kstats()
        got, err = by_handle(mfd, fh)
        k = kdelta(k0, kstats())
        os.close(mfd)
        if rel == "p/short":
            ok = got == mnt + "/" + rel and k["searches"] == 0
        else:
            ok = got is None and err in (errno.ESTALE, errno.ENAMETOOLONG) \
                and k["searches"] == 0
        bad += not ok
        note("%s %s: got %s errno %d (%s) kstats %s" %
             ("ok " if ok else "BAD", rel[:20] + "...", (got or "")[-30:],
              err, os.strerror(err) if err else "-", k))
    result(sec, bad == 0, "long-name reconnects: ESTALE/ENAMETOOLONG for "
           "names over 255 bytes, exact path for the short one, no search; "
           "%d bad" % bad)
    zdb_b(sec)


# ---------------------------------------------------------------- ctldir
def ctldir():
    sec = "ctldir"
    mkpool()
    ds, mnt = mkfs("c", "snapdir=visible")
    os.mkdir(mnt + "/d")
    for i in range(3000):
        os.mkdir("%s/d/x%04d" % (mnt, i))
    sh("zfs", "snapshot", ds + "@s")
    snap = mnt + "/.zfs/snapshot/s"
    os.listdir(snap)	# automount
    bad = 0
    for rel in ("d/x0007", "d/x2999", "d"):
        p = snap + "/" + rel
        fh = handle(p)
        drop_caches()
        mfd = os.open(snap, os.O_RDONLY | os.O_DIRECTORY)
        got, err = by_handle(mfd, fh)
        os.close(mfd)
        note("snapshot %s: %s errno %d" % (rel, got, err))
        if got != p:
            bad += 1
    result(sec, bad == 0, "%d snapshot directories by handle, %d wrong" %
           (3, bad))
    zdb_b(sec)


# ---------------------------------------------------------------- perm
def perm():
    """zfs rewrite -N records cookies only for a caller who may write the
    object (v3_perm.sh): a non-owner gets EACCES and the cookies stay
    "none"; the owner of a directory and root succeed; a read-only file
    system gives EROFS (cookies of objects made with zfs_parent_cookie=0
    are "none").  The unprivileged user is uid/gid 4242 (setpriv)."""
    sec = "perm"
    mkpool()
    ds, mnt = mkfs("d")
    os.chmod(mnt, 0o755)
    tunable("zfs_parent_cookie", 0)	# created without cookies
    os.mkdir(mnt + "/rootdir")
    os.mkdir(mnt + "/userdir")
    with open(mnt + "/rootfile", "w") as f:
        f.write("data\n")
    os.chmod(mnt + "/rootfile", 0o644)
    os.chown(mnt + "/userdir", 4242, 4242)
    tunable("zfs_parent_cookie", 1)

    def st(name):
        z = zdb_objs(ds, [os.lstat(mnt + "/" + name).st_ino])
        return list(z.values())[0]["cookie"] if z else "?"

    def rw(name, user):
        cmd = ["zfs", "rewrite", "-N", mnt + "/" + name]
        if user:
            cmd = ["setpriv", "--reuid=4242", "--regid=4242",
                   "--clear-groups"] + cmd
        p = subprocess.run(cmd, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, universal_newlines=True)
        note("%s: %s -> exit %d %s" % ("uid 4242" if user else "root",
                                       " ".join(cmd[-3:]), p.returncode,
                                       p.stdout.strip()))
        return p.returncode
    sh("zpool", "sync", POOL)
    before = {n: st(n) for n in ("rootdir", "rootfile", "userdir")}
    note("before: %s" % before)
    rc = {n: rw(n, True) for n in ("rootdir", "rootfile", "userdir")}
    sh("zpool", "sync", POOL)
    after = {n: st(n) for n in ("rootdir", "rootfile", "userdir")}
    note("after uid 4242: %s" % after)
    ok_user = (rc["rootdir"] == errno.EACCES and rc["rootfile"] == errno.EACCES and
               rc["userdir"] == 0 and after["rootdir"] == "none" and
               after["rootfile"] == "none" and after["userdir"] == "valid")
    result(sec, ok_user, "unprivileged: refused on root's dir and file "
           "(exit %d, %d; cookies %s, %s), own dir recorded (exit %d, %s)" %
           (rc["rootdir"], rc["rootfile"], after["rootdir"],
            after["rootfile"], rc["userdir"], after["userdir"]))
    r1, r2 = rw("rootfile", False), rw("rootdir", False)
    sh("zpool", "sync", POOL)
    a2 = {n: st(n) for n in ("rootdir", "rootfile")}
    result(sec, r1 == 0 and r2 == 0 and set(a2.values()) == {"valid"},
           "root: exit %d, %d, cookies %s" % (r1, r2, a2))
    sh("zfs", "set", "readonly=on", ds)
    r3 = rw("userdir", False)
    sh("zfs", "set", "readonly=off", ds)
    result(sec, r3 == errno.EROFS, "read-only file system: exit %d "
           "(EROFS is %d)" % (r3, errno.EROFS))
    zdb_b(sec)


SECTIONS = {"churn": churn, "zapshape": zapshape, "norm": norm,
            "links": links, "sendrecv": sendrecv, "spill": spill,
            "longname": longname, "ctldir": ctldir, "perm": perm}

if __name__ == "__main__":
    want = sys.argv[1:] or ["all"]
    if want == ["all"]:
        want = list(SECTIONS)
    bad = [s for s in want if s not in SECTIONS]
    if bad:
        print("unknown section(s) %s; valid: %s all" %
              (" ".join(bad), " ".join(SECTIONS)))
        sys.exit(2)
    try:
        print("build: " + open("/etc/zfshunt-build").read().strip(),
              flush=True)
    except OSError:
        print("build: zfs %s srcversion %s" % (
            open("/sys/module/zfs/version").read().strip(),
            open("/sys/module/zfs/srcversion").read().strip()), flush=True)
    print("scale: %g" % SCALE, flush=True)
    times = []
    for s in want:
        print("=== " + s, flush=True)
        t0 = time.time()
        try:
            SECTIONS[s]()
        except Exception as e:
            import traceback
            traceback.print_exc()
            result(s, False, "exception: %r" % (e,))
        finally:
            tunable("zfs_parent_cookie", 1)
            if s == want[-1] and os.environ.get("V3S_EXPORT_LAST") == "1" \
                    and sh("zpool", "list", POOL, check=False) == 0:
                print("# zpool export %s" % POOL, flush=True)
                sh("zpool", "export", POOL, check=False)
            else:
                destroy_pool()
        times.append((s, time.time() - t0))
        print("=== %s: %d s" % (s, times[-1][1]), flush=True)
    print("=== summary")
    for l in results:
        print(l)
    for s, t in times:
        n = [l for l in results if l.split()[1] == s]
        print("SECTION %-9s %-4s %3d checks, %d failed, %4d s" % (
            s, "PASS" if n and all(" PASS " in l for l in n) else "FAIL",
            len(n), sum(" PASS " not in l for l in n), t))
    sys.exit(0 if all(" PASS " in l for l in results) else 1)
