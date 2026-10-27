# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
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

def select(rlist, wlist, xlist, timeout=None):
    if timeout is not None and timeout < 0:
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

    def poll(self, timeout=None):
        var rf = []
        var wf = []
        for f in self.fds:
            var m = self.fds[f]
            if m & (POLLIN | POLLPRI):
                rf.append(f)
            if m & POLLOUT:
                wf.append(f)
        var t = None
        if timeout is not None and timeout >= 0:
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

# ── round 85: select.epoll (Linux), the POLL*/EPOLL* constants, PIPE_BUF ─
# CPython's epoll object over epoll_create1/epoll_ctl/epoll_wait
# (builtins/os_posix.cpp): register/modify/unregister, poll(timeout,
# maxevents) - the GIL released while it waits, a signal's handler run and
# the wait resumed with the time left (PEP 475) -, close/closed/fileno/fromfd,
# a context manager. Not here: kqueue and devpoll (BSD, Solaris).
if os_platform() == "linux":
    def _load_epoll():
        var g = globals()
        for pair in _ny_os_call("select_constants"):
            g[pair[0]] = pair[1]
    _load_epoll()
    del _load_epoll

    class epoll:
        """select.epoll(sizehint=-1, flags=0)

        Returns an epolling object."""
        __module__ = "select"
        def __init__(self, sizehint=-1, flags=0, _fd=None):
            if _fd is not None:
                self._fd = _fd
                return
            if sizehint == -1:
                sizehint = 1023
            elif sizehint <= 0:
                raise ValueError("negative sizehint")
            self._fd = _ny_os_call("epoll_create", flags)

        @classmethod
        def fromfd(cls, fd):
            return cls(-1, 0, fd)

        @property
        def closed(self):
            return self._fd < 0

        def _check(self):
            if self._fd < 0:
                raise ValueError("I/O operation on closed epoll object")

        def fileno(self):
            self._check()
            return self._fd

        def close(self):
            if self._fd >= 0:
                var fd = self._fd
                self._fd = -1
                _ny_os_call("close", fd)

        def register(self, fd, eventmask=EPOLLIN | EPOLLPRI | EPOLLOUT):
            self._check()
            _ny_os_call("epoll_ctl", self._fd, 1, _fd(fd), eventmask)

        def modify(self, fd, eventmask):
            self._check()
            _ny_os_call("epoll_ctl", self._fd, 3, _fd(fd), eventmask)

        def unregister(self, fd):
            self._check()
            _ny_os_call("epoll_ctl", self._fd, 2, _fd(fd), 0)

        def poll(self, timeout=None, maxevents=-1):
            self._check()
            if maxevents == -1:
                maxevents = 1023
            elif maxevents < 1:
                raise ValueError("maxevents must be greater than 0, got " + str(maxevents))
            var t = None
            if timeout is not None and timeout >= 0:
                t = float(timeout)
            return [(e[0], e[1]) for e in _ny_os_call("epoll_wait", self._fd, t, maxevents)]

        def __enter__(self):
            self._check()
            return self

        def __exit__(self, *args):
            self.close()

        def __del__(self):
            try:
                self.close()
            except BaseException:
                pass

        def __repr__(self):
            return "<select.epoll object at 0x" + format(id(self), "x") + ">"
