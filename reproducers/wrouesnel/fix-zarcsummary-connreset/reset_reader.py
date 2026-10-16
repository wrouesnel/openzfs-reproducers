import fcntl, socket, struct, subprocess, sys, termios, time

r, w = socket.socketpair()
w.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1)
sndbuf = w.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)
p = subprocess.Popen(sys.argv[1:], stdout=w)

def blocked():
    outq = fcntl.ioctl(w, termios.TIOCOUTQ, b"\0" * 4)
    with open("/proc/%d/stat" % p.pid) as f:
        state = f.read().rpartition(")")[2].split()[0]
    return struct.unpack("i", outq)[0] >= sndbuf and state == "S"

deadline = time.monotonic() + 60
while not blocked():
    if p.poll() is not None:
        sys.exit("the command exited before filling the socket")
    if time.monotonic() > deadline:
        sys.exit("the command did not block writing")
    time.sleep(0.01)
r.close()
sys.exit(p.wait())
