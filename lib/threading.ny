# nython: module    (import it by name: it runs in a module scope of its own)
# lib/threading.ny - Python's threading module (round 77) over the runtime's
# threads (src/NyConc.cpp): real OS threads under one GIL, blocking calls
# that release it. `import threading` binds this namespace and, as before,
# makes the thread_* / mutex_* / ... natives available.
#
#   Thread(target, args, kwargs, name, daemon), current_thread, main_thread,
#   active_count, enumerate, get_ident, get_native_id, Lock/allocate_lock,
#   RLock, Condition, Semaphore, BoundedSemaphore, Event, Timer, Barrier
#   (BrokenBarrierError), local, excepthook, TIMEOUT_MAX
#
# lib/thread.ny is Nython's own threading library (channels, futures, pools,
# RWLock, atomics...); both run on the same runtime.

TIMEOUT_MAX = 9223372036.0

class BrokenBarrierError(RuntimeError):
    pass

class ThreadError(RuntimeError):
    pass

_threads = {}            # ident -> Thread, for current_thread()/enumerate()
_main = none

def _ms(timeout):
    if timeout == none or timeout < 0:
        return -1
    return timeout * 1000

class Thread:
    def __init__(self, group=none, target=none, name=none, args=(), kwargs=none, daemon=none):
        self._target = target
        self._args = args
        self._kwargs = kwargs
        if kwargs == none:
            self._kwargs = {}
        self._name = name
        self._daemon = daemon
        if daemon == none:
            self._daemon = false
        self._ident = none
        self._started = false
        self._result = none

    @property
    def name(self):
        if self._name == none:
            if self._ident != none:
                return "Thread-" + str(self._ident)
            return "Thread"
        return self._name

    @name.setter
    def name(self, value):
        self._name = str(value)

    @property
    def ident(self):
        return self._ident

    @property
    def native_id(self):
        return self._ident

    @property
    def daemon(self):
        return self._daemon

    @daemon.setter
    def daemon(self, value):
        if self._started:
            raise RuntimeError("cannot set daemon status of active thread")
        self._daemon = bool(value)

    def run(self):
        if self._target != none:
            self._target(*self._args, **self._kwargs)

    def _bootstrap(self):
        _threads[thread_id()] = self
        try:
            self.run()
        except SystemExit:
            pass
        except BaseException as e:
            excepthook(_ExceptHookArgs(type(e), e, none, self))
        finally:
            if thread_id() in _threads:
                del _threads[thread_id()]

    def start(self):
        if self._started:
            raise RuntimeError("threads can only be started once")
        self._started = true
        if self._name != none:
            self._ident = thread_create_named(self._name, self._bootstrap)
        else:
            self._ident = thread_create(self._bootstrap)
        if self._daemon:
            thread_set_daemon(self._ident, true)

    def join(self, timeout=none):
        if not self._started:
            raise RuntimeError("cannot join thread before it is started")
        if self._ident == thread_id():
            raise RuntimeError("cannot join current thread")
        if timeout == none:
            thread_join(self._ident)
            return
        try:
            thread_join(self._ident, _ms(timeout))
        except Exception:
            pass

    def is_alive(self):
        return self._started and thread_is_alive(self._ident)

    def isDaemon(self):
        return self._daemon

    def setDaemon(self, d):
        self.daemon = d

    def getName(self):
        return self.name

    def setName(self, n):
        self.name = n

    def __repr__(self):
        var state = "initial"
        if self._started:
            state = "started"
            if not self.is_alive():
                state = "stopped"
        return "<Thread(" + self.name + ", " + state + ")>"

class _MainThread(Thread):
    def __init__(self):
        Thread.__init__(self, none, none, "MainThread")
        self._ident = thread_main()
        self._started = true

    def is_alive(self):
        return true

class _DummyThread(Thread):
    def __init__(self, ident):
        Thread.__init__(self, none, none, "Dummy-" + str(ident))
        self._ident = ident
        self._started = true
        self._daemon = true

    def is_alive(self):
        return thread_is_alive(self._ident)

class _ExceptHookArgs:
    def __init__(self, exc_type, exc_value, exc_traceback, thread):
        self.exc_type = exc_type
        self.exc_value = exc_value
        self.exc_traceback = exc_traceback
        self.thread = thread

def excepthook(args):
    var who = "<unknown>"
    if args.thread != none:
        who = args.thread.name
    eprint("Exception in thread " + who + ":")
    eprint(type(args.exc_value).__name__ + ": " + str(args.exc_value))

def main_thread():
    global _main
    if _main == none:
        _main = _MainThread()
    return _main

def current_thread():
    var i = thread_id()
    if i == thread_main():
        return main_thread()
    var t = _threads.get(i)
    if t == none:
        return _DummyThread(i)
    return t

def currentThread():
    return current_thread()

def get_ident():
    return thread_id()

def get_native_id():
    return thread_id()

def active_count():
    return thread_count()

def activeCount():
    return thread_count()

def enumerate():
    var out = [main_thread()]
    for t in _threads.values():
        out.append(t)
    return out

def settrace(func):
    pass

def setprofile(func):
    pass

def stack_size(size=0):
    return 0

class Lock:
    def __init__(self):
        self._id = mutex_create()

    def acquire(self, blocking=true, timeout=-1):
        if not blocking:
            return mutex_try_lock(self._id)
        if timeout != none and timeout >= 0:
            return mutex_lock_timeout(self._id, timeout * 1000)
        mutex_lock(self._id)
        return true

    def release(self):
        mutex_unlock(self._id)

    def locked(self):
        return mutex_locked(self._id)

    def __enter__(self):
        mutex_lock(self._id)
        return true

    def __exit__(self, t=none, v=none, tb=none):
        mutex_unlock(self._id)
        return false

def allocate_lock():
    return Lock()

class RLock(Lock):
    def __init__(self):
        self._id = rmutex_create()

class Condition:
    def __init__(self, lock=none):
        if lock == none:
            lock = RLock()
        self._lock = lock
        self._id = cond_create()

    def acquire(self, *args):
        return self._lock.acquire(*args)

    def release(self):
        self._lock.release()

    def wait(self, timeout=none):
        if timeout == none:
            return cond_wait(self._id, self._lock._id)
        return cond_wait_timeout(self._id, self._lock._id, timeout * 1000)

    def wait_for(self, predicate, timeout=none):
        var deadline = none
        if timeout != none:
            deadline = monotonic() + timeout
        var ok = predicate()
        while not ok:
            if deadline == none:
                cond_wait(self._id, self._lock._id)
            else:
                var left = deadline - monotonic()
                if left <= 0:
                    return predicate()
                cond_wait_timeout(self._id, self._lock._id, left * 1000)
            ok = predicate()
        return ok

    def notify(self, n=1):
        cond_notify(self._id, n)

    def notify_all(self):
        cond_notify_all(self._id)

    def notifyAll(self):
        cond_notify_all(self._id)

    def __enter__(self):
        return self._lock.__enter__()

    def __exit__(self, t=none, v=none, tb=none):
        return self._lock.__exit__(t, v, tb)

class Semaphore:
    def __init__(self, value=1):
        if value < 0:
            raise ValueError("semaphore initial value must be >= 0")
        self._id = semaphore_create(value)

    def acquire(self, blocking=true, timeout=none):
        if not blocking:
            return semaphore_try_acquire(self._id)
        if timeout != none:
            return semaphore_acquire_timeout(self._id, timeout * 1000)
        semaphore_acquire(self._id)
        return true

    def release(self, n=1):
        semaphore_release(self._id, n)

    def __enter__(self):
        semaphore_acquire(self._id)
        return true

    def __exit__(self, t=none, v=none, tb=none):
        self.release()
        return false

class BoundedSemaphore(Semaphore):
    def __init__(self, value=1):
        if value < 0:
            raise ValueError("semaphore initial value must be >= 0")
        self._id = semaphore_create(value, value)

    def release(self, n=1):
        if not semaphore_release(self._id, n):
            raise ValueError("Semaphore released too many times")

class Event:
    def __init__(self):
        self._id = event_create()

    def is_set(self):
        return event_is_set(self._id)

    def isSet(self):
        return event_is_set(self._id)

    def set(self):
        event_set(self._id)

    def clear(self):
        event_clear(self._id)

    def wait(self, timeout=none):
        if timeout == none:
            return event_wait(self._id)
        return event_wait_timeout(self._id, timeout * 1000)

class Timer(Thread):
    # Calls function(*args, **kwargs) after `interval` seconds unless
    # cancel() comes first.
    def __init__(self, interval, function, args=none, kwargs=none):
        Thread.__init__(self)
        self.interval = interval
        self.function = function
        self.args = args
        if args == none:
            self.args = []
        self.kwargs = kwargs
        if kwargs == none:
            self.kwargs = {}
        self.finished = Event()

    def cancel(self):
        self.finished.set()

    def run(self):
        self.finished.wait(self.interval)
        if not self.finished.is_set():
            self.function(*self.args, **self.kwargs)
        self.finished.set()

class Barrier:
    def __init__(self, parties, action=none, timeout=none):
        if parties < 1:
            raise ValueError("parties must be > 0")
        self.parties = parties
        self._action = action
        self._timeout = timeout
        self._cond = Condition(Lock())
        self._count = 0
        self._generation = 0
        self.broken = false

    @property
    def n_waiting(self):
        return self._count

    def wait(self, timeout=none):
        if timeout == none:
            timeout = self._timeout
        with self._cond:
            if self.broken:
                raise BrokenBarrierError()
            var gen = self._generation
            var index = self._count
            self._count = self._count + 1
            if self._count == self.parties:
                if self._action != none:
                    self._action()
                self._count = 0
                self._generation = self._generation + 1
                self._cond.notify_all()
                return index
            var ok = self._cond.wait_for(lambda: self._generation != gen or self.broken, timeout)
            if self.broken or not ok:
                self.broken = true
                self._cond.notify_all()
                raise BrokenBarrierError()
            return index

    def reset(self):
        with self._cond:
            self.broken = false
            self._count = 0
            self._generation = self._generation + 1
            self._cond.notify_all()

    def abort(self):
        with self._cond:
            self.broken = true
            self._cond.notify_all()

class local:
    # Attributes per thread (round 77: it called natives that never
    # existed): each thread sees only what it set itself.
    def __init__(self):
        _ny_setattr_raw(self, "_ny_tl", {})

    def _mine(self, make):
        var tid = get_ident()
        var d = self._ny_tl.get(tid)
        if d == none and make:
            d = {}
            self._ny_tl[tid] = d
        return d

    def __getattr__(self, name):
        var d = self._mine(false)
        if d == none or not (name in d):
            raise AttributeError("'_thread._local' object has no attribute '" + name + "'")
        return d[name]

    def __setattr__(self, name, value):
        self._mine(true)[name] = value

    def __delattr__(self, name):
        var d = self._mine(false)
        if d == none or not (name in d):
            raise AttributeError(name)
        del d[name]
