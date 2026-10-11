# nython: module    (import it by name: it runs in a module scope of its own)
# lib/selectors.ny - Python's selectors module (round 77). `import selectors`.
# DefaultSelector over the socket layer's waits; like every wait there, a
# select() inside an async task parks the task instead of blocking the loop.

EVENT_READ = 1
EVENT_WRITE = 2

def _fd(x):
    if isinstance(x, "int"):
        return x
    return x.fileno()

class SelectorKey:
    def __init__(self, fileobj, fd, events, data):
        self.fileobj = fileobj
        self.fd = fd
        self.events = events
        self.data = data

    def __repr__(self):
        return "SelectorKey(fileobj=" + repr(self.fileobj) + ", fd=" + str(self.fd) + ", events=" + str(self.events) + ", data=" + repr(self.data) + ")"

class DefaultSelector:
    def __init__(self):
        self._keys = {}

    def register(self, fileobj, events, data=none):
        if events == 0 or (events & ~(EVENT_READ | EVENT_WRITE)) != 0:
            raise ValueError("Invalid events: " + repr(events))
        var fd = _fd(fileobj)
        if fd in self._keys:
            raise KeyError(repr(fileobj) + " (FD " + str(fd) + ") is already registered")
        var key = SelectorKey(fileobj, fd, events, data)
        self._keys[fd] = key
        return key

    def unregister(self, fileobj):
        var fd = _fd(fileobj)
        if fd not in self._keys:
            raise KeyError(repr(fileobj) + " is not registered")
        var key = self._keys[fd]
        del self._keys[fd]
        return key

    def modify(self, fileobj, events, data=none):
        self.unregister(fileobj)
        return self.register(fileobj, events, data)

    def select(self, timeout=none):
        var rf = []
        var wf = []
        for fd in self._keys:
            var k = self._keys[fd]
            if k.events & EVENT_READ:
                rf.append(fd)
            if k.events & EVENT_WRITE:
                wf.append(fd)
        var t = timeout
        if t is not none and t < 0:
            t = 0
        var r = _net_select(rf, wf, [], t)
        var ready = {}
        for fd in r[0]:
            ready[fd] = ready.get(fd, 0) | EVENT_READ
        for fd in r[1]:
            ready[fd] = ready.get(fd, 0) | EVENT_WRITE
        return [(self._keys[fd], ready[fd]) for fd in ready]

    def get_key(self, fileobj):
        var fd = _fd(fileobj)
        if fd not in self._keys:
            raise KeyError(repr(fileobj) + " is not registered")
        return self._keys[fd]

    def get_map(self):
        return dict(self._keys)

    def close(self):
        self._keys = {}

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return false

SelectSelector = DefaultSelector
PollSelector = DefaultSelector
