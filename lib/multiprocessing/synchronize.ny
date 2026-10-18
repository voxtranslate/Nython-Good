# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/multiprocessing/synchronize.ny - Lock, RLock, Semaphore,
# BoundedSemaphore, Condition, Event, Barrier across processes (round 80).
#
# Each object lives on the object server of the process that made it
# (lib/multiprocessing/managers.ny: a lock server, not named semaphores),
# and pickles as its address and id, so passing it to a Process (as an
# argument, in a Queue, ...) gives the child the same object. CPython's API
# and messages: acquire(block=True, timeout=None) / release / context
# manager; an RLock is released only by its owner (process and thread);
# Condition.wait/wait_for/notify/notify_all on its (R)Lock;
# Semaphore.get_value(); Event.is_set/set/clear/wait; Barrier.wait/reset/
# abort/parties/n_waiting/broken with threading.BrokenBarrierError.
# Difference: a Barrier's action runs in the process whose wait() returns
# index 0, after the barrier has opened (CPython runs it in the last
# process to arrive, before the others are released).

import threading
from multiprocessing import managers as _mg

__all__ = ["Lock", "RLock", "Semaphore", "BoundedSemaphore", "Condition", "Event", "Barrier"]


class SemLock(object):
    _kind = "Lock"

    def __init__(self, *args, ctx=None):
        self._ref = _mg._create(type(self)._kind, *args)

    def acquire(self, block=True, timeout=None):
        if timeout is not None and timeout < 0:
            timeout = 0
        return self._ref.ocall("acquire", block, timeout)

    def release(self):
        return self._ref.ocall("release")

    def __enter__(self):
        return self._ref.ocall("acquire", True, None)

    def __exit__(self, *args):
        return self._ref.ocall("release")

    def __reduce__(self):
        return (_rebuild, (type(self), self._ref))

    def _is_mine(self):
        return self._ref.ocall("is_mine")


def _rebuild(cls, ref):
    var obj = object.__new__(cls)
    obj._ref = ref
    if cls is Barrier:
        obj._action = None
        obj._parties = ref.ocall("state")[0]
    return obj


class Lock(SemLock):
    """A non-recursive lock shared between processes."""
    _kind = "Lock"

    def __init__(self, *, ctx=None):
        SemLock.__init__(self)

    def locked(self):
        return self._ref.ocall("locked")

    def __repr__(self):
        var name = "unknown"
        try:
            name = "SomeOtherThread" if self._ref.ocall("locked") else "None"
            if self._ref.ocall("is_mine"):
                from multiprocessing import process
                name = process.current_process().name
                if threading.current_thread().name != 'MainThread':
                    name += '|' + threading.current_thread().name
        except Exception:
            pass
        return '<%s(owner=%s)>' % (type(self).__name__, name)


class RLock(SemLock):
    """A recursive lock shared between processes."""
    _kind = "RLock"

    def __init__(self, *, ctx=None):
        SemLock.__init__(self)

    def __repr__(self):
        var name = "unknown"
        var count = 0
        try:
            count = self._ref.ocall("count_of")
            if self._ref.ocall("is_mine"):
                from multiprocessing import process
                name = process.current_process().name
                if threading.current_thread().name != 'MainThread':
                    name += '|' + threading.current_thread().name
            elif count == 0:
                name = "None"
            else:
                name = "SomeOtherThread"
        except Exception:
            pass
        return '<%s(%s, %s)>' % (type(self).__name__, name, count)


class Semaphore(SemLock):
    _kind = "Semaphore"

    def __init__(self, value=1, *, ctx=None):
        if value < 0:
            raise ValueError("semaphore initial value must be >= 0")
        SemLock.__init__(self, value)

    def get_value(self):
        return self._ref.ocall("get_value")

    def __repr__(self):
        var value = "unknown"
        try:
            value = self._ref.ocall("get_value")
        except Exception:
            pass
        return '<%s(value=%s)>' % (type(self).__name__, value)


class BoundedSemaphore(Semaphore):
    _kind = "BoundedSemaphore"

    def __init__(self, value=1, *, ctx=None):
        Semaphore.__init__(self, value)

    def __repr__(self):
        var value = "unknown"
        try:
            value = self._ref.ocall("get_value")
        except Exception:
            pass
        return '<%s(value=%s, maxvalue=%s)>' % (type(self).__name__, value, value)


class Condition(object):

    def __init__(self, lock=None, *, ctx=None):
        self._lock = lock or RLock()
        self._ref = _mg._create("Condition", self._lock._ref.oid, address=self._lock._ref.address)

    def __reduce__(self):
        return (_condition_from_ref, (self._ref, self._lock))

    def __enter__(self):
        return self._lock.__enter__()

    def __exit__(self, *args):
        return self._lock.__exit__(*args)

    def acquire(self, block=True, timeout=None):
        return self._lock.acquire(block, timeout)

    def release(self):
        return self._lock.release()

    def wait(self, timeout=None):
        return self._ref.ocall("wait", timeout)

    def notify(self, n=1):
        self._ref.ocall("notify", n)

    def notify_all(self):
        self._ref.ocall("notify_all")

    def wait_for(self, predicate, timeout=None):
        var result = predicate()
        if result:
            return result
        var endtime = None
        var waittime = None
        if timeout is not None:
            import time
            endtime = time.monotonic() + timeout
        else:
            waittime = None
        while not result:
            if endtime is not None:
                import time
                waittime = endtime - time.monotonic()
                if waittime <= 0:
                    break
            self.wait(waittime)
            result = predicate()
        return result

    def __repr__(self):
        return '<%s(%s)>' % (type(self).__name__, self._lock)


def _condition_from_ref(ref, lock):
    var c = object.__new__(Condition)
    c._ref = ref
    c._lock = lock
    return c


class Event(object):

    def __init__(self, *, ctx=None):
        self._ref = _mg._create("Event")

    def __reduce__(self):
        return (_rebuild, (Event, self._ref))

    def is_set(self):
        return self._ref.ocall("is_set")

    def set(self):
        self._ref.ocall("set")

    def clear(self):
        self._ref.ocall("clear")

    def wait(self, timeout=None):
        return self._ref.ocall("wait", timeout)

    def __repr__(self):
        var set_status = 'set' if self.is_set() else 'unset'
        return "<%s at %#x %s>" % (type(self).__name__, id(self), set_status)


class Barrier(object):

    def __init__(self, parties, action=None, timeout=None, *, ctx=None):
        if parties < 1:
            raise ValueError("parties must be > 0")
        self._ref = _mg._create("Barrier", parties, timeout)
        self._action = action
        self._parties = parties

    def __reduce__(self):
        return (_barrier_from_ref, (self._ref, self._parties, self._action, None))

    def wait(self, timeout=None):
        var index = self._ref.ocall("wait", timeout)
        if index == 0 and self._action is not None:
            self._action()
        return index

    def reset(self):
        self._ref.ocall("reset")

    def abort(self):
        self._ref.ocall("abort")

    @property
    def parties(self):
        return self._parties

    @property
    def n_waiting(self):
        return self._ref.ocall("state")[1]

    @property
    def broken(self):
        return self._ref.ocall("state")[2]


def _barrier_from_ref(ref, parties, action, timeout):
    var b = object.__new__(Barrier)
    b._ref = ref
    b._parties = parties
    b._action = action
    return b


def _from_ref(kind, ref):
    var cls = {"Lock": Lock, "RLock": RLock, "Semaphore": Semaphore, "BoundedSemaphore": BoundedSemaphore,
               "Event": Event}[kind]
    var obj = object.__new__(cls)
    obj._ref = ref
    return obj
