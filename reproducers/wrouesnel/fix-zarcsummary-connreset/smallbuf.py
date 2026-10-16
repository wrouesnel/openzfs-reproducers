# smallbuf.py CMD...: shrink the send buffer of fd 1 (when it is a socket, as
# in a ksh pipeline) to the minimum, then exec CMD.
import os, socket, sys
try:
    s = socket.socket(fileno=1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1)
    print("fd 1: a socket, SO_SNDBUF %d" %
          s.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF), file=sys.stderr)
    s.detach()
except OSError as e:
    print("fd 1: %s" % e.strerror, file=sys.stderr)
os.execvp(sys.argv[1], sys.argv[1:])
