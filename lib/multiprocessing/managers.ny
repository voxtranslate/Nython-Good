# nython: module    (import it by name: it runs in a module scope of its own)
# lib/multiprocessing/managers.ny - the object server every cross-process
# object of lib/multiprocessing lives in (round 80), and Python's managers
# API on top of it (BaseManager, SyncManager, BaseProxy, Namespace,
# Manager().dict()/list()/Namespace()/Queue()/Lock()/...).
#
# How it works (Nython's design, not CPython's fds and semaphores): each
# process that creates a Queue, Lock, Pipe, Event, ... starts one server
# thread (_local_server(); a Manager() starts it in a process of its own).
# Its objects stay there; the processes that use them talk to it over a
# socket - AF_UNIX in a private directory on POSIX, TCP on 127.0.0.1 on
# Windows - with CPython's HMAC challenge on the process tree's authkey
# (current_process().authkey, inherited by every spawned child) and
# length-prefixed pickles. Each client thread has its own connection and
# the server one thread per connection, so a blocking call (Queue.get,
# Lock.acquire, Condition.wait, Barrier.wait) blocks only its caller. What a
# Queue or Pipe carries stays pickled bytes on the server (it never needs
# the classes); a Manager's dict/list values are real objects there, as in
# CPython. An item a client did not live to receive (its socket failed on
# the reply) goes back to the queue, and a lock it acquired is released.
#
# A lock owner is the (process, thread) of the connection, so RLock and
# Condition work across processes as on threads.

import os
import sys
import socket
import threading
import pickle
import time
import hmac
import queue as _queue

__all__ = ["BaseManager", "SyncManager", "BaseProxy", "Token", "Namespace", "Server"]

_RETURN = "#RETURN"
_ERROR = "#ERROR"
_CHALLENGE = b"#CHALLENGE#"
_WELCOME = b"#WELCOME#"
_FAILURE = b"#FAILURE#"
_UNIX = getattr(socket, "AF_UNIX", None) is not None and os.name != "nt"


# ── framing ──────────────────────────────────────────────────────────────────
def _send_msg(sock, data):
    sock.sendall(len(data).to_bytes(4, "big") + data)


def _recv_exact(sock, n):
    var parts = []
    var got = 0
    while got < n:
        var chunk = sock.recv(n - got)
        if not chunk:
            raise EOFError("connection closed")
        parts.append(chunk)
        got += len(chunk)
    if len(parts) == 1:
        return parts[0]
    return b"".join(parts)


def _recv_msg(sock):
    var n = int.from_bytes(_recv_exact(sock, 4), "big")
    return _recv_exact(sock, n) if n else b""


def _digest(authkey, message):
    return hmac.new(authkey, message, "sha256").digest()


def _authkey():
    from multiprocessing import process
    return process.current_process().authkey


# ── addresses ────────────────────────────────────────────────────────────────
_tempdir = []


def _get_temp_dir():
    # a private directory of this process, removed when it exits
    if not _tempdir:
        import tempfile
        import atexit
        var base = None
        if os.name != "nt" and os.path.isdir("/dev/shm") and os.access("/dev/shm", os.W_OK):
            base = "/dev/shm"
        var d = tempfile.mkdtemp(prefix="pymp-", dir=base)
        _tempdir.append(d)

        def cleanup():
            import shutil
            try:
                shutil.rmtree(d, ignore_errors=True)
            except Exception:
                pass
        atexit.register(cleanup)
    return _tempdir[0]


def _new_listener():
    var s = None
    if _UNIX:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        var path = os.path.join(_get_temp_dir(), "srv-" + str(os.getpid()) + "-" + os.urandom(4).hex())
        s.bind(path)
        s.listen(64)
        return s, path
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    s.listen(64)
    return s, s.getsockname()


def _connect(address):
    var s = None
    if isinstance(address, str):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    else:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        address = tuple(address)
    s.connect(address)
    if not isinstance(address, str):
        try:
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except Exception:
            pass
    return s


# ── the server's objects ─────────────────────────────────────────────────────
class _SLock:
    # multiprocessing.Lock / RLock on the server: owner is the connection's
    # (pid, thread) - a Lock may be released by anyone, an RLock only by its
    # owner, as in CPython
    def __init__(self, recursive=False):
        self.cond = threading.Condition(threading.Lock())
        self.recursive = recursive
        self.owner = None
        self.count = 0

    def acquire(self, owner, block=True, timeout=None):
        var deadline = None if timeout is None else time.monotonic() + timeout
        with self.cond:
            if self.recursive and self.count and self.owner == owner:
                self.count += 1
                return True
            while self.count:
                if not block:
                    return False
                if deadline is None:
                    self.cond.wait()
                else:
                    var left = deadline - time.monotonic()
                    if left <= 0:
                        return False
                    self.cond.wait(left)
            self.owner = owner
            self.count = 1
            return True

    def release(self, owner):
        with self.cond:
            if self.recursive:
                if not self.count or self.owner != owner:
                    raise AssertionError("attempt to release recursive lock not owned by thread")
                self.count -= 1
                if self.count:
                    return None
            elif not self.count:
                raise ValueError("semaphore or lock released too many times")
            self.count = 0
            self.owner = None
            self.cond.notify()
        return None

    def _release_save(self, owner):
        with self.cond:
            if not self.count or (self.recursive and self.owner != owner):
                raise AssertionError("cannot wait on un-acquired lock")
            var saved = self.count
            self.count = 0
            self.owner = None
            self.cond.notify()
            return saved

    def _acquire_restore(self, owner, saved):
        with self.cond:
            while self.count:
                self.cond.wait()
            self.owner = owner
            self.count = saved

    def locked(self, owner):
        return self.count > 0

    def is_mine(self, owner):
        return self.count > 0 and self.owner == owner

    def count_of(self, owner):
        return self.count

    def _undo(self, owner, method, result):
        if method == "acquire" and result is True:
            try:
                self.release(owner)
            except Exception:
                pass


class _SSemaphore:
    def __init__(self, value=1, maxvalue=None):
        self.cond = threading.Condition(threading.Lock())
        self.value = value
        self.maxvalue = maxvalue

    def acquire(self, owner, block=True, timeout=None):
        var deadline = None if timeout is None else time.monotonic() + timeout
        with self.cond:
            while self.value == 0:
                if not block:
                    return False
                if deadline is None:
                    self.cond.wait()
                else:
                    var left = deadline - time.monotonic()
                    if left <= 0:
                        return False
                    self.cond.wait(left)
            self.value -= 1
            return True

    def release(self, owner, n=1):
        with self.cond:
            if self.maxvalue is not None and self.value + n > self.maxvalue:
                raise ValueError("semaphore or lock released too many times")
            self.value += n
            self.cond.notify(n)
        return None

    def get_value(self, owner):
        return self.value

    def locked(self, owner):
        return self.value == 0

    def _undo(self, owner, method, result):
        if method == "acquire" and result is True:
            self.release(owner)


class _SEvent:
    def __init__(self):
        self.cond = threading.Condition(threading.Lock())
        self.flag = False

    def is_set(self, owner):
        return self.flag

    def set(self, owner):
        with self.cond:
            self.flag = True
            self.cond.notify_all()

    def clear(self, owner):
        with self.cond:
            self.flag = False

    def wait(self, owner, timeout=None):
        var deadline = None if timeout is None else time.monotonic() + timeout
        with self.cond:
            while not self.flag:
                if deadline is None:
                    self.cond.wait()
                else:
                    var left = deadline - time.monotonic()
                    if left <= 0:
                        break
                    self.cond.wait(left)
            return self.flag


class _SCondition:
    # a condition variable over a server lock (its id): wait releases the
    # lock entirely (an RLock's whole count) and takes it back
    def __init__(self, server, lock_id):
        self.lock = server.objects[lock_id]
        self.m = threading.Condition(threading.Lock())
        self.waiters = []

    def wait(self, owner, timeout=None):
        if not self.lock.is_mine(owner) and not (not self.lock.recursive and self.lock.count):
            raise AssertionError("must acquire() condition before using wait()")
        var w = [False]
        with self.m:
            self.waiters.append(w)
        var saved = self.lock._release_save(owner)
        var deadline = None if timeout is None else time.monotonic() + timeout
        var ok = False
        with self.m:
            while not w[0]:
                if deadline is None:
                    self.m.wait()
                else:
                    var left = deadline - time.monotonic()
                    if left <= 0:
                        break
                    self.m.wait(left)
            ok = w[0]
            if not ok and w in self.waiters:
                self.waiters.remove(w)
        self.lock._acquire_restore(owner, saved)
        return ok

    def notify(self, owner, n=1):
        if not self.lock.is_mine(owner) and not (not self.lock.recursive and self.lock.count):
            raise AssertionError("lock is not owned")
        with self.m:
            var k = 0
            while self.waiters and k < n:
                self.waiters.pop(0)[0] = True
                k += 1
            self.m.notify_all()

    def notify_all(self, owner):
        self.notify(owner, len(self.waiters) + 1)


class _SBarrier:
    def __init__(self, parties, timeout=None):
        self.cond = threading.Condition(threading.Lock())
        self.parties = parties
        self.timeout = timeout
        self.count = 0
        self.generation = 0
        self.broken = False

    def wait(self, owner, timeout=None):
        if timeout is None:
            timeout = self.timeout
        var deadline = None if timeout is None else time.monotonic() + timeout
        with self.cond:
            if self.broken:
                raise threading.BrokenBarrierError()
            var gen = self.generation
            var index = self.count
            self.count += 1
            if self.count == self.parties:
                self.count = 0
                self.generation += 1
                self.cond.notify_all()
                return index
            while self.generation == gen and not self.broken:
                if deadline is None:
                    self.cond.wait()
                else:
                    var left = deadline - time.monotonic()
                    if left <= 0:
                        self.broken = True
                        self.cond.notify_all()
                        break
                    self.cond.wait(left)
            if self.generation == gen:
                raise threading.BrokenBarrierError()
            return index

    def reset(self, owner):
        with self.cond:
            if self.count:
                self.broken = True
                self.cond.notify_all()
            self.broken = False
            self.count = 0
            self.generation += 1
            self.cond.notify_all()

    def abort(self, owner):
        with self.cond:
            self.broken = True
            self.cond.notify_all()

    def state(self, owner):
        return (self.parties, self.count, self.broken)


class _SQueue:
    # items are pickled bytes; maxsize 0 is unbounded; task counting for
    # JoinableQueue
    def __init__(self, maxsize=0):
        self.cond = threading.Condition(threading.Lock())
        self.items = []
        self.head = 0
        self.maxsize = maxsize
        self.unfinished = 0
        self.closed = False
        self.writers = 1

    def add_writer(self, owner):
        # one more copy of a Pipe end writes here (it was pickled)
        with self.cond:
            self.writers += 1
        return None

    def drop_writer(self, owner):
        # a copy was closed: the reader sees EOF once none is left
        with self.cond:
            self.writers -= 1
            if self.writers <= 0:
                self.closed = True
                self.cond.notify_all()
        return None

    def _size(self):
        return len(self.items) - self.head

    def put(self, owner, blob, block=True, timeout=None):
        var deadline = None if timeout is None else time.monotonic() + timeout
        with self.cond:
            while self.maxsize > 0 and self._size() >= self.maxsize:
                if not block:
                    raise _queue.Full()
                if deadline is None:
                    self.cond.wait()
                else:
                    var left = deadline - time.monotonic()
                    if left <= 0:
                        raise _queue.Full()
                    self.cond.wait(left)
            self.items.append(blob)
            self.unfinished += 1
            self.cond.notify_all()
        return None

    def put_many(self, owner, blobs):
        with self.cond:
            for b in blobs:
                self.items.append(b)
                self.unfinished += 1
            self.cond.notify_all()
        return None

    def get(self, owner, block=True, timeout=None):
        var deadline = None if timeout is None else time.monotonic() + timeout
        with self.cond:
            while self._size() == 0:
                if not block:
                    raise _queue.Empty()
                if deadline is None:
                    self.cond.wait()
                else:
                    var left = deadline - time.monotonic()
                    if left <= 0:
                        raise _queue.Empty()
                    self.cond.wait(left)
            var b = self.items[self.head]
            self.items[self.head] = None
            self.head += 1
            if self.head > 64 and self.head * 2 > len(self.items):
                self.items = self.items[self.head:]
                self.head = 0
            self.cond.notify_all()
            return b

    def _undo(self, owner, method, result):
        if method == "get" and isinstance(result, bytes):
            with self.cond:
                if self.head > 0:
                    self.head -= 1
                    self.items[self.head] = result
                else:
                    self.items.insert(0, result)
                self.cond.notify_all()

    def qsize(self, owner):
        return self._size()

    def task_done(self, owner):
        with self.cond:
            if self.unfinished <= 0:
                raise ValueError("task_done() called too many times")
            self.unfinished -= 1
            if self.unfinished == 0:
                self.cond.notify_all()
        return None

    def join(self, owner):
        with self.cond:
            while self.unfinished:
                self.cond.wait()
        return None

    def poll(self, owner, timeout=None):
        # wait until an item is there (Connection.poll), without taking it
        var deadline = None if timeout is None else time.monotonic() + timeout
        with self.cond:
            while self._size() == 0 and not self.closed:
                if deadline is None:
                    self.cond.wait()
                else:
                    var left = deadline - time.monotonic()
                    if left <= 0:
                        return False
                    self.cond.wait(left)
            return self._size() > 0 or self.closed

    def recv(self, owner):
        # Connection.recv: EOFError once the other end is closed and empty
        with self.cond:
            while self._size() == 0:
                if self.closed:
                    raise EOFError()
                self.cond.wait()
            var b = self.items[self.head]
            self.items[self.head] = None
            self.head += 1
            return b

    def close(self, owner):
        with self.cond:
            self.closed = True
            self.cond.notify_all()
        return None


class _STaskPool:
    # Pool's tasks: one deque per worker, filled round-robin, and work
    # stealing for the worker whose deque runs dry (Blumofe & Leiserson):
    # it takes from the far end of the longest deque - half of what is
    # left there (steal-half), so a long tail of expensive tasks is spread
    # instead of waiting behind one worker. A get takes up to `batch`
    # tasks at once (fewer round trips); "fifo" is CPython's one shared
    # queue, kept to compare (Pool(_scheduler="fifo")).
    def __init__(self, nworkers, mode="steal"):
        self.cond = threading.Condition(threading.Lock())
        self.mode = mode
        self.deques = [[] for i in range(max(1, nworkers))]
        self.next = 0
        self.closed = False
        self.steals = 0
        self.stolen_tasks = 0

    def resize(self, owner, nworkers):
        with self.cond:
            while len(self.deques) < nworkers:
                self.deques.append([])
        return None

    def put_many(self, owner, blobs):
        with self.cond:
            var n = len(self.deques)
            if self.mode == "fifo":
                self.deques[0].extend(blobs)
            else:
                for b in blobs:
                    self.deques[self.next % n].append(b)
                    self.next += 1
            self.cond.notify_all()
        return None

    def get(self, owner, w, batch=1, timeout=None):
        var deadline = None if timeout is None else time.monotonic() + timeout
        with self.cond:
            while True:
                var mine = self.deques[0 if self.mode == "fifo" else w % len(self.deques)]
                if mine:
                    var k = min(batch, len(mine))
                    var out = mine[:k]
                    del mine[:k]
                    return out
                # steal: the longest deque, its far end, half of it
                var victim = None
                for d in self.deques:
                    if d and (victim is None or len(d) > len(victim)):
                        victim = d
                if victim is not None:
                    var take = max(1, len(victim) // 2)
                    var got = victim[len(victim) - take:]
                    del victim[len(victim) - take:]
                    got.reverse()
                    self.steals += 1
                    self.stolen_tasks += take
                    var k2 = min(batch, len(got))
                    mine.extend(got[k2:])
                    return got[:k2]
                if self.closed:
                    return None
                if deadline is None:
                    self.cond.wait()
                else:
                    var left = deadline - time.monotonic()
                    if left <= 0:
                        return []
                    self.cond.wait(left)

    def close(self, owner):
        with self.cond:
            self.closed = True
            self.cond.notify_all()
        return None

    def clear(self, owner):
        with self.cond:
            for d in self.deques:
                del d[:]
        return None

    def stats(self, owner):
        return (self.steals, self.stolen_tasks)


class Namespace:
    def __init__(self, **kwds):
        self.__dict__.update(kwds)

    def __repr__(self):
        var items = list(self.__dict__.items())
        var temp = []
        for kv in items:
            if not kv[0].startswith('_'):
                temp.append(str(kv[0]) + "=" + repr(kv[1]))
        temp.sort()
        return type(self).__name__ + "(" + ", ".join(temp) + ")"


class _SNamespace:
    def __init__(self, **kw):
        self.ns = dict(kw)

    def getattr_(self, name):
        if name not in self.ns:
            raise AttributeError("'Namespace' object has no attribute '" + name + "'")
        return self.ns[name]

    def setattr_(self, name, value):
        self.ns[name] = value

    def delattr_(self, name):
        if name not in self.ns:
            raise AttributeError(name)
        del self.ns[name]

    def items_(self):
        return dict(self.ns)


class _SValue:
    def __init__(self, typecode, value, lock=True):
        self.typecode = typecode
        self.value = value

    def get(self):
        return self.value

    def set(self, value):
        self.value = value


# the server-side types: owner-aware (a sync primitive's methods take the
# caller first) or plain (a Manager's dict, list ...)
_OWNER_TYPES = {"Lock": lambda srv, *a: _SLock(False), "RLock": lambda srv, *a: _SLock(True),
                "Semaphore": lambda srv, value=1: _SSemaphore(value),
                "BoundedSemaphore": lambda srv, value=1: _SSemaphore(value, value),
                "Event": lambda srv: _SEvent(), "Condition": lambda srv, lock_id: _SCondition(srv, lock_id),
                "Barrier": lambda srv, parties, timeout=None: _SBarrier(parties, timeout),
                "Queue": lambda srv, maxsize=0: _SQueue(maxsize),
                "TaskPool": lambda srv, n, mode="steal": _STaskPool(n, mode)}
_PLAIN_TYPES = {"dict": dict, "list": list, "Namespace": _SNamespace, "Value": _SValue}


# ── the server ───────────────────────────────────────────────────────────────
class Server:
    """Holds the objects; one thread per client connection."""

    def __init__(self, authkey, registry=None):
        self.authkey = bytes(authkey)
        self.objects = {}
        self.kinds = {}
        self.next_id = 1
        self.mutex = threading.Lock()
        self.registry = dict(registry) if registry else {}
        self.spawn_data = {}
        self.stop_event = threading.Event()
        var la = _new_listener()
        self.listener = la[0]
        self.address = la[1]
        self.connections = []

    def start(self):
        var t = threading.Thread(target=self._accept_loop, name="mp-server", daemon=True)
        t.start()
        return self

    def serve_forever(self):
        self._accept_loop()

    def _accept_loop(self):
        while not self.stop_event.is_set():
            var c = None
            try:
                c = self.listener.accept()[0]
            except OSError:
                break
            if self.stop_event.is_set():
                break
            var t = threading.Thread(target=self._serve_client, args=(c,), daemon=True)
            t.start()

    def shutdown(self):
        self.stop_event.set()
        try:
            self.listener.close()
        except Exception:
            pass
        if isinstance(self.address, str):
            try:
                os.unlink(self.address)
            except OSError:
                pass

    def _authenticate(self, c):
        var challenge = os.urandom(32)
        _send_msg(c, _CHALLENGE + challenge)
        var response = _recv_msg(c)
        if not hmac.compare_digest(response, _digest(self.authkey, challenge)):
            _send_msg(c, _FAILURE)
            return False
        _send_msg(c, _WELCOME)
        return True

    def _new(self, kind, obj):
        with self.mutex:
            var oid = self.next_id
            self.next_id += 1
            self.objects[oid] = obj
            self.kinds[oid] = kind
        return oid

    def _serve_client(self, c):
        var owner = None
        try:
            if not self._authenticate(c):
                c.close()
                return
            owner = pickle.loads(_recv_msg(c))
        except BaseException:
            try:
                c.close()
            except Exception:
                pass
            return
        while not self.stop_event.is_set():
            var req = None
            try:
                req = pickle.loads(_recv_msg(c))
            except BaseException:
                break
            var result = None
            var reply = None
            try:
                result = self._dispatch(owner, req)
                reply = (_RETURN, result)
            except BaseException as e:
                reply = (_ERROR, e)
            var data = None
            try:
                data = pickle.dumps(reply, 4)
            except BaseException as e:
                data = pickle.dumps((_ERROR, RuntimeError("cannot send the result back: " + repr(e))), 4)
            try:
                _send_msg(c, data)
            except BaseException:
                # the client is gone: what it took goes back
                if reply[0] == _RETURN and req[0] == "ocall":
                    var o = self.objects.get(req[1])
                    if o is not None and hasattr(o, "_undo"):
                        try:
                            o._undo(owner, req[2], result)
                        except BaseException:
                            pass
                break
            if req[0] == "shutdown":
                self.shutdown()
                break
        try:
            c.close()
        except Exception:
            pass

    def _dispatch(self, owner, req):
        var op = req[0]
        if op == "ocall":
            return getattr(self.objects[req[1]], req[2])(owner, *req[3])
        if op == "call":
            var obj = self.objects[req[1]]
            var name = req[2]
            var args = req[3]
            var kw = req[4] if len(req) > 4 else {}
            if self.kinds.get(req[1]) == "Namespace" and name in ("__getattr__", "__setattr__", "__delattr__"):
                name = {"__getattr__": "getattr_", "__setattr__": "setattr_", "__delattr__": "delattr_"}[name]
            return getattr(obj, name)(*args, **kw)
        if op == "create":
            var kind = req[1]
            var args = req[2]
            var kw = req[3] if len(req) > 3 else {}
            if kind in _OWNER_TYPES:
                return self._new(kind, _OWNER_TYPES[kind](self, *args, **kw))
            if kind in self.registry:
                return self._new(kind, self.registry[kind](*args, **kw))
            if kind in _PLAIN_TYPES:
                return self._new(kind, _PLAIN_TYPES[kind](*args, **kw))
            raise KeyError("unknown type " + repr(kind))
        if op == "spawn_get":
            return self.spawn_data.pop(req[1])
        if op == "ping":
            return os.getpid()
        if op == "decref":
            with self.mutex:
                self.objects.pop(req[1], None)
                self.kinds.pop(req[1], None)
            return None
        if op == "shutdown":
            return None
        raise ValueError("unknown request " + repr(op))


# ── the client side ──────────────────────────────────────────────────────────
_tls = threading.local()


def _owner():
    return (os.getpid(), threading.get_ident())


def _connection(address, authkey=None):
    var conns = getattr(_tls, "conns", None)
    if conns is None:
        conns = {}
        _tls.conns = conns
    var key = address if isinstance(address, str) else tuple(address)
    var s = conns.get(key)
    if s is not None:
        return s
    if authkey is None:
        authkey = _authkey()
    s = _connect(address)
    var msg = _recv_msg(s)
    if not msg.startswith(_CHALLENGE):
        s.close()
        raise _AuthenticationError("protocol error: no challenge")
    _send_msg(s, _digest(bytes(authkey), msg[len(_CHALLENGE):]))
    if _recv_msg(s) != _WELCOME:
        s.close()
        raise _AuthenticationError("digest received was wrong")
    _send_msg(s, pickle.dumps(_owner(), 4))
    conns[key] = s
    return s


def _drop_connection(address):
    var conns = getattr(_tls, "conns", None)
    if conns:
        var key = address if isinstance(address, str) else tuple(address)
        var s = conns.pop(key, None)
        if s is not None:
            try:
                s.close()
            except Exception:
                pass


def _request(address, req, authkey=None):
    var s = _connection(address, authkey)
    var reply = None
    try:
        _send_msg(s, pickle.dumps(req, 4))
        reply = pickle.loads(_recv_msg(s))
    except (OSError, EOFError):
        _drop_connection(address)
        raise
    if reply[0] == _ERROR:
        raise reply[1]
    return reply[1]


class _AuthenticationError(Exception):
    pass


AuthenticationError = _AuthenticationError

# this process's own server: where the Queues, Locks, Pipes ... it creates live
_local = []
_local_lock = threading.Lock()


def _local_server():
    if not _local:
        with _local_lock:
            if not _local:
                _local.append(Server(_authkey()).start())
    return _local[0]


class _Ref:
    # an object on a server: its address and id (pickled with them)
    def __init__(self, address, oid, kind):
        self.address = address
        self.oid = oid
        self.kind = kind

    def ocall(self, method, *args):
        return _request(self.address, ("ocall", self.oid, method, args))

    def call(self, method, *args, **kw):
        return _request(self.address, ("call", self.oid, method, args, kw))

    def __reduce__(self):
        return (_Ref, (self.address, self.oid, self.kind))

    def __eq__(self, other):
        return isinstance(other, _Ref) and self.address == other.address and self.oid == other.oid

    def __hash__(self):
        return hash((str(self.address), self.oid))


def _create(kind, *args, address=None, **kw):
    if address is None:
        address = _local_server().address
    return _Ref(address, _request(address, ("create", kind, args, kw)), kind)


# ── managers (Python's API) ──────────────────────────────────────────────────
class Token(object):
    """Type to uniquely identify a shared object"""
    __slots__ = ('typeid', 'address', 'id')

    def __init__(self, typeid, address, id):
        self.typeid = typeid
        self.address = address
        self.id = id

    def __getstate__(self):
        return (self.typeid, self.address, self.id)

    def __setstate__(self, state):
        self.typeid = state[0]
        self.address = state[1]
        self.id = state[2]

    def __repr__(self):
        return "%s(typeid=%r, address=%r, id=%r)" % (type(self).__name__, self.typeid, self.address, self.id)


class BaseProxy(object):
    """A base for proxies of shared objects"""

    def __init__(self, token, serializer=None, manager=None, authkey=None, exposed=None, incref=True,
                 manager_owned=False):
        self._token = token
        self._id = token.id
        self._manager = manager

    def _callmethod(self, methodname, args=(), kwds={}):
        return _request(self._token.address, ("call", self._token.id, methodname, tuple(args), dict(kwds)))

    def _getvalue(self):
        return self._callmethod("copy")

    def __reduce__(self):
        return (_rebuild_proxy, (type(self), self._token))

    def __repr__(self):
        return "<%s object, typeid %r at %#x>" % (type(self).__name__, self._token.typeid, id(self))

    def __str__(self):
        try:
            return self._callmethod("__repr__")
        except Exception:
            return repr(self)[:-1] + "; '__str__()' failed>"


def _rebuild_proxy(cls, token):
    return cls(token)


def _proxy_methods(cls, names):
    def make(name):
        def m(self, *args, **kw):
            return self._callmethod(name, args, kw)
        m.__name__ = name
        return m
    for n in names:
        setattr(cls, n, make(n))
    return cls


class ListProxy(BaseProxy):
    def __iadd__(self, value):
        self._callmethod("extend", (value,))
        return self

    def __imul__(self, value):
        self._callmethod("__imul__", (value,))
        return self

    def __iter__(self):
        return iter(self._callmethod("copy"))

    def _getvalue(self):
        return self._callmethod("copy")


_proxy_methods(ListProxy, ["__add__", "__contains__", "__delitem__", "__getitem__", "__len__", "__mul__",
                           "__reversed__", "__rmul__", "__setitem__", "append", "count", "extend", "index",
                           "insert", "pop", "remove", "reverse", "sort", "clear", "copy", "__repr__"])


class DictProxy(BaseProxy):
    def __iter__(self):
        return iter(list(self._callmethod("keys")))

    def keys(self):
        return list(self._callmethod("keys"))

    def values(self):
        return list(self._callmethod("values"))

    def items(self):
        return list(self._callmethod("items"))

    def _getvalue(self):
        return self._callmethod("copy")


_proxy_methods(DictProxy, ["__contains__", "__delitem__", "__getitem__", "__len__", "__setitem__", "clear",
                           "copy", "get", "pop", "popitem", "setdefault", "update", "__repr__"])


class NamespaceProxy(BaseProxy):
    def __getattr__(self, key):
        if key[0] == '_':
            return object.__getattribute__(self, key)
        return self._callmethod("getattr_", (key,))

    def __setattr__(self, key, value):
        if key[0] == '_':
            return object.__setattr__(self, key, value)
        return self._callmethod("setattr_", (key, value))

    def __delattr__(self, key):
        if key[0] == '_':
            return object.__delattr__(self, key)
        return self._callmethod("delattr_", (key,))

    def __repr__(self):
        var d = self._callmethod("items_")
        var parts = sorted([k + "=" + repr(d[k]) for k in d if not k.startswith("_")])
        return "Namespace(" + ", ".join(parts) + ")"


class ValueProxy(BaseProxy):
    def get(self):
        return self._callmethod("get")

    def set(self, value):
        return self._callmethod("set", (value,))

    @property
    def value(self):
        return self._callmethod("get")

    @value.setter
    def value(self, v):
        self._callmethod("set", (v,))


class BaseManager(object):
    """Base class for managers"""

    _registry = {}

    def __init__(self, address=None, authkey=None, serializer='pickle', ctx=None, *, shutdown_timeout=1.0):
        if authkey is None:
            authkey = _authkey()
        self._authkey = bytes(authkey)
        self._address = address
        self._process = None
        self._state = "initial"
        self._shutdown_timeout = shutdown_timeout

    @property
    def address(self):
        return self._address

    def start(self, initializer=None, initargs=()):
        """Spawn a server process for this manager object"""
        if self._state == "started":
            raise ProcessError("Already started server")
        if self._state == "shutdown":
            raise ProcessError("Manager has shut down")
        if initializer is not None and not callable(initializer):
            raise TypeError('initializer must be a callable')
        from multiprocessing import process as _process
        from multiprocessing import queues as _queues
        var reply = _queues.SimpleQueue()
        self._process = _process.Process(target=_run_server, args=(type(self)._registry, self._authkey, reply,
                                                                    initializer, initargs),
                                         name="SyncManager-" + str(id(self) % 100000))
        self._process.daemon = True
        self._process.start()
        self._address = reply.get()
        self._state = "started"

    def connect(self):
        """Connect manager object to the server process"""
        _request(self._address, ("ping",), self._authkey)
        self._state = "started"

    def get_server(self):
        if self._state != "initial":
            raise ProcessError("server already started")
        var srv = Server(self._authkey, type(self)._registry)
        self._address = srv.address
        return srv

    def shutdown(self):
        if self._state != "started":
            return
        try:
            _request(self._address, ("shutdown",), self._authkey)
        except Exception:
            pass
        _drop_connection(self._address)
        if self._process is not None:
            self._process.join(timeout=self._shutdown_timeout)
            if self._process.is_alive():
                self._process.terminate()
                self._process.join(timeout=self._shutdown_timeout)
        self._state = "shutdown"

    def join(self, timeout=None):
        if self._process is not None:
            self._process.join(timeout)

    def __enter__(self):
        if self._state == "initial":
            self.start()
        if self._state != "started":
            raise ProcessError("Unable to start server")
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.shutdown()

    def _create(self, typeid, *args, **kwds):
        return Token(typeid, self._address, _request(self._address, ("create", typeid, args, kwds), self._authkey))

    @classmethod
    def register(cls, typeid, callable=None, proxytype=None, exposed=None, method_to_typeid=None,
                 create_method=True):
        """Register a typeid with the manager type"""
        if '_registry' not in cls.__dict__:
            cls._registry = dict(cls._registry)
        if callable is not None:
            cls._registry[typeid] = callable
        if proxytype is None:
            proxytype = _auto_proxy(exposed)
        cls.__dict__.get("_proxies", None)
        if create_method:
            def temp(self, *args, **kwds):
                var token = self._create(typeid, *args, **kwds)
                return proxytype(token, manager=self)
            temp.__name__ = typeid
            setattr(cls, typeid, temp)


def _auto_proxy(exposed):
    class AutoProxy(BaseProxy):
        def __getattr__(self, name):
            if name.startswith("_"):
                raise AttributeError(name)

            def m(*args, **kw):
                return self._callmethod(name, args, kw)
            return m
    return AutoProxy


def _run_server(registry, authkey, reply, initializer, initargs):
    # a Manager's server process
    if initializer is not None:
        initializer(*initargs)
    var srv = Server(authkey, registry)
    reply.put(srv.address)
    srv.serve_forever()


class ProcessError(Exception):
    pass


class _SyncProxy(BaseProxy):
    # Lock / Queue / Event ... made by a SyncManager: the same server
    # objects as the module's, on the manager's server
    pass


class SyncManager(BaseManager):
    """Subclass of BaseManager which supports a number of shared object types."""

    def _sync(self, kind, *args):
        from multiprocessing import synchronize as _sync_mod
        from multiprocessing import queues as _queues
        var ref = _Ref(self._address, _request(self._address, ("create", kind, args, {}), self._authkey), kind)
        if kind in ("Queue", "JoinableQueue"):
            return _queues._from_ref(kind, ref, args[0] if args else 0)
        return _sync_mod._from_ref(kind, ref)

    def Queue(self, maxsize=0):
        var q = self._sync("Queue", maxsize)
        return q

    def JoinableQueue(self, maxsize=0):
        from multiprocessing import queues as _queues
        var ref = _Ref(self._address, _request(self._address, ("create", "Queue", (maxsize,), {}), self._authkey), "Queue")
        return _queues._from_ref("JoinableQueue", ref, maxsize)

    def Lock(self):
        return self._sync("Lock")

    def RLock(self):
        return self._sync("RLock")

    def Semaphore(self, value=1):
        return self._sync("Semaphore", value)

    def BoundedSemaphore(self, value=1):
        return self._sync("BoundedSemaphore", value)

    def Event(self):
        return self._sync("Event")

    def Condition(self, lock=None):
        from multiprocessing import synchronize as _sync_mod
        if lock is None:
            lock = self.RLock()
        var ref = _Ref(self._address, _request(self._address, ("create", "Condition", (lock._ref.oid,), {}),
                                                self._authkey), "Condition")
        return _sync_mod._condition_from_ref(ref, lock)

    def Barrier(self, parties, action=None, timeout=None):
        from multiprocessing import synchronize as _sync_mod
        var ref = _Ref(self._address, _request(self._address, ("create", "Barrier", (parties, timeout), {}),
                                                self._authkey), "Barrier")
        return _sync_mod._barrier_from_ref(ref, parties, action, timeout)

    def dict(self, *args, **kwds):
        return DictProxy(self._create("dict", *args, **kwds), manager=self)

    def list(self, *args):
        return ListProxy(self._create("list", *args), manager=self)

    def Namespace(self, **kwds):
        return NamespaceProxy(self._create("Namespace", **kwds), manager=self)

    def Value(self, typecode, value, lock=True):
        return ValueProxy(self._create("Value", typecode, value), manager=self)

    def Array(self, typecode, sequence, lock=True):
        return ListProxy(self._create("list", list(sequence)), manager=self)

    def Pool(self, processes=None, initializer=None, initargs=(), maxtasksperchild=None):
        from multiprocessing import pool as _pool
        return _pool.Pool(processes, initializer, initargs, maxtasksperchild)
