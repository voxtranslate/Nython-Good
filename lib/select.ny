# nython: module    (import it by name: it runs in a module scope of its own)
# lib/select.ny - Python's select module over the socket layer's waits
# (src/builtins/net.cpp: _net_select; round 77). `import select`.
#
#   select(rlist, wlist, xlist, timeout=none) -> (r, w, x)
#       the items are ints (descriptors) or objects with fileno(); the ready
#       ones come back as given. On an async task it parks the task (the
#       loop runs the others), in a thread it releases the GIL.
#   poll() -> an object with register(fd, events)/modify/unregister/
#       poll(timeout_ms) -> [(fd, events)], Python's select.poll.

POLLIN = 1
POLLPRI = 2
POLLOUT = 4
POLLERR = 8
POLLHUP = 16
POLLNVAL = 32

error = OSError

def _fd(x):
    if isinstance(x, "int"):
        return x
    return x.fileno()

def select(rlist, wlist, xlist, timeout=none):
    if timeout is not none and timeout < 0:
        raise ValueError("timeout must be non-negative")
    var rm = {}
    var wm = {}
    var xm = {}
    var rf = []
    var wf = []
    var xf = []
    for o in rlist:
        var f = _fd(o)
        rm[f] = o
        rf.append(f)
    for o in wlist:
        var f2 = _fd(o)
        wm[f2] = o
        wf.append(f2)
    for o in xlist:
        var f3 = _fd(o)
        xm[f3] = o
        xf.append(f3)
    var r = _net_select(rf, wf, xf, timeout)
    return ([rm[f] for f in r[0]], [wm[f] for f in r[1]], [xm[f] for f in r[2]])

class _Poll:
    def __init__(self):
        self.fds = {}

    def register(self, fd, eventmask=7):
        self.fds[_fd(fd)] = eventmask

    def modify(self, fd, eventmask):
        var f = _fd(fd)
        if f not in self.fds:
            raise FileNotFoundError("[Errno 2] No such file or directory")
        self.fds[f] = eventmask

    def unregister(self, fd):
        var f = _fd(fd)
        if f not in self.fds:
            raise KeyError(f)
        del self.fds[f]

    def poll(self, timeout=none):
        var rf = []
        var wf = []
        for f in self.fds:
            var m = self.fds[f]
            if m & (POLLIN | POLLPRI):
                rf.append(f)
            if m & POLLOUT:
                wf.append(f)
        var t = none
        if timeout is not none and timeout >= 0:
            t = timeout / 1000.0
        var r = _net_select(rf, wf, [], t)
        var out = {}
        for f in r[0]:
            out[f] = out.get(f, 0) | POLLIN
        for f in r[1]:
            out[f] = out.get(f, 0) | POLLOUT
        return [(f, out[f]) for f in out]

def poll():
    return _Poll()
