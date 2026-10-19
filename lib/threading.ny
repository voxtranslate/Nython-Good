# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/threading.ny - Python's threading module (round 77) over the runtime's
# threads (src/NyConc.cpp): real OS threads under one GIL, blocking calls
# that release it. `import threading` binds this namespace and, as before,
# makes the thread_* / mutex_* / ... natives available.
#
#   Thread(target, args, kwargs, name, daemon), current_thread, main_thread,
#   active_count, enumerate, get_ident, get_native_id, Lock/allocate_lock,
#   RLock, Condition, Semaphore, BoundedSemaphore, Event, Timer, Barrier
#   (BrokenBarrierError), local, excepthook, TIMEOUT_MAX,
#   settrace/setprofile/gettrace/getprofile (round 79: the sys.settrace /
#   sys.setprofile functions each thread started afterwards gets),
#   _register_atexit (round 80: callbacks run at exit before the
#   non-daemon threads are joined, as CPython's threading._shutdown)
#
# lib/thread.ny is Nython's own threading library (channels, futures, pools,
# RWLock, atomics...); both run on the same runtime.

TIMEOUT_MAX = 9223372036.0

class BrokenBarrierError(RuntimeError):
    pass

class ThreadError(RuntimeError):
    pass

_threads = {}            # ident -> Thread, for current_thread()/enumerate()
_main = None

def _ms(timeout):
    if timeout == None or timeout < 0:
        return -1
    return timeout * 1000

class Thread:
    def __init__(self, group=None, target=None, name=None, args=(), kwargs=None, daemon=None):
        self._target = target
        self._args = args
        self._kwargs = kwargs
        if kwargs == None:
            self._kwargs = {}
        self._name = name
        self._daemon = daemon
        if daemon == None:
            self._daemon = False
        self._ident = None
        self._started = False
        self._result = None

    @property
    def name(self):
        if self._name == None:
            if self._ident != None:
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
        if self._target != None:
            self._target(*self._args, **self._kwargs)

    def _bootstrap(self):
        _threads[thread_id()] = self
        # threading.settrace / setprofile's functions (round 79)
        var hooked = _trace_hook is not None or _profile_hook is not None
        if hooked:
            _sys_hooks(_trace_hook, _profile_hook)
        try:
            self.run()
        except SystemExit:
            pass
        except BaseException as e:
            excepthook(_ExceptHookArgs(type(e), e, None, self))
        finally:
            if hooked:
                _sys_hooks(None, None)
            if thread_id() in _threads:
                del _threads[thread_id()]

    def start(self):
        if self._started:
            raise RuntimeError("threads can only be started once")
        # (round 86) as CPython 3.12's start(): _thread.start_new_thread's
        # audit event (a hook raising leaves the thread unstarted)
        _ny_sys_audit("_thread.start_new_thread", self._bootstrap, (), None)
        self._started = True
        if self._name != None:
            self._ident = thread_create_named(self._name, self._bootstrap)
        else:
            self._ident = thread_create(self._bootstrap)
        if self._daemon:
            thread_set_daemon(self._ident, True)

    def join(self, timeout=None):
        if not self._started:
            raise RuntimeError("cannot join thread before it is started")
        if self._ident == thread_os_id():
            raise RuntimeError("cannot join current thread")
        if timeout == None:
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
        Thread.__init__(self, None, None, "MainThread")
        self._ident = thread_main()
        self._started = True

    def is_alive(self):
        return True

class _DummyThread(Thread):
    def __init__(self, ident):
        Thread.__init__(self, None, None, "Dummy-" + str(ident))
        self._ident = ident
        self._started = True
        self._daemon = True

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
    if args.thread != None:
        who = args.thread.name
    eprint("Exception in thread " + who + ":")
    eprint(type(args.exc_value).__name__ + ": " + str(args.exc_value))

def main_thread():
    global _main
    if _main == None:
        _main = _MainThread()
    return _main

def current_thread():
    var i = thread_os_id()
    if i == thread_main():
        return main_thread()
    var t = _threads.get(i)
    if t == None:
        return _DummyThread(i)
    return t

def currentThread():
    return current_thread()

def get_ident():
    return thread_os_id()

def get_native_id():
    return thread_os_id()

def active_count():
    return thread_count()

def activeCount():
    return thread_count()

def enumerate():
    var out = [main_thread()]
    for t in _threads.values():
        out.append(t)
    return out

# The trace and profile functions threads started from now on get
# (round 79: sys.settrace / sys.setprofile are per thread, as CPython's).
_trace_hook = None
_profile_hook = None

def _sys_hooks(trace, profile):
    # this thread's sys.settrace / sys.setprofile
    _ny_settrace(trace)
    _ny_setprofile(profile)

def settrace(func):
    global _trace_hook
    _trace_hook = func

def setprofile(func):
    global _profile_hook
    _profile_hook = func

def gettrace():
    return _trace_hook

def getprofile():
    return _profile_hook

def stack_size(size=0):
    return 0

def _register_atexit(func, *arg, **kwargs):
    # round 80: CPython's private hook (concurrent.futures uses it) - func
    # runs when the program ends, before the engines wait for the non-daemon
    # threads (atexit's handlers run after them); last registered first
    if _ny_threading_atexit_done[0]:
        raise RuntimeError("can't register atexit after shutdown")
    def call():
        func(*arg, **kwargs)
    _ny_threading_atexits.append(call)

class Lock:
    # Python's primitive lock (round 82: a native lock with no owner,
    # pylock_create - any thread may release it, and acquiring it again
    # waits for that instead of raising DeadlockError)
    def __init__(self):
        self._id = pylock_create()

    def acquire(self, blocking=True, timeout=-1):
        if not blocking:
            if timeout != -1:
                raise ValueError("can't specify a timeout for a non-blocking call")
            return mutex_try_lock(self._id)
        if timeout != None and timeout != -1:
            if timeout < 0:
                raise ValueError("timeout value must be positive")
            return mutex_lock_timeout(self._id, timeout * 1000)
        mutex_lock(self._id)
        return True

    def release(self):
        mutex_unlock(self._id)

    def locked(self):
        return mutex_locked(self._id)

    def __enter__(self):
        mutex_lock(self._id)
        return True

    def __exit__(self, t=None, v=None, tb=None):
        mutex_unlock(self._id)
        return False

    def __repr__(self):
        return "<" + ("locked" if self.locked() else "unlocked") + " _thread.lock object at " + hex(id(self)) + ">"

    def _at_fork_reinit(self):
        # (round 85) in the child of os.fork (os.register_at_fork): a new,
        # unlocked lock - the parent's may be held by a thread the child
        # does not have
        self._id = pylock_create()

    def __del__(self):
        # round 82: the native lock goes with the object (sync_free frees
        # it only when no thread holds or waits for it)
        _free_native(self)

def _free_native(obj):
    var h = getattr(obj, "_id", None)
    if h is not None:
        try:
            sync_free(h)
        except BaseException:
            pass

def allocate_lock():
    return Lock()

class RLock(Lock):
    # owned and re-entrant, as CPython's (a native recursive mutex)
    def __init__(self):
        self._id = rmutex_create()

    def release(self):
        try:
            mutex_unlock(self._id)
        except RuntimeError:
            raise RuntimeError("cannot release un-acquired lock")

    def __exit__(self, t=None, v=None, tb=None):
        self.release()
        return False

    def _is_owned(self):
        return mutex_owner(self._id) == thread_id()

    def _at_fork_reinit(self):
        self._id = rmutex_create()   # (round 85)

    def __repr__(self):
        var o = mutex_owner(self._id)
        return "<" + ("locked" if o else "unlocked") + " _thread.RLock object owner=" + str(o) + " at " + hex(id(self)) + ">"

class Condition:
    def __init__(self, lock=None):
        if lock == None:
            lock = RLock()
        self._lock = lock
        self._id = cond_create()

    def acquire(self, *args):
        return self._lock.acquire(*args)

    def release(self):
        self._lock.release()

    def wait(self, timeout=None):
        if timeout == None:
            return cond_wait(self._id, self._lock._id)
        return cond_wait_timeout(self._id, self._lock._id, timeout * 1000)

    def wait_for(self, predicate, timeout=None):
        var deadline = None
        if timeout != None:
            deadline = monotonic() + timeout
        var ok = predicate()
        while not ok:
            if deadline == None:
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

    def _at_fork_reinit(self):
        # (round 85) os.register_at_fork's child: its lock and waiters anew
        self._lock._at_fork_reinit()
        self._id = cond_create()

    def __del__(self):
        _free_native(self)

    def __enter__(self):
        return self._lock.__enter__()

    def __exit__(self, t=None, v=None, tb=None):
        return self._lock.__exit__(t, v, tb)

class Semaphore:
    def __init__(self, value=1):
        if value < 0:
            raise ValueError("semaphore initial value must be >= 0")
        self._id = semaphore_create(value)

    def acquire(self, blocking=True, timeout=None):
        if not blocking:
            return semaphore_try_acquire(self._id)
        if timeout != None:
            return semaphore_acquire_timeout(self._id, timeout * 1000)
        semaphore_acquire(self._id)
        return True

    def release(self, n=1):
        semaphore_release(self._id, n)

    def __enter__(self):
        semaphore_acquire(self._id)
        return True

    def __exit__(self, t=None, v=None, tb=None):
        self.release()
        return False

    def __del__(self):
        _free_native(self)

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

    def _at_fork_reinit(self):
        # (round 85) os.register_at_fork's child: unset, no waiters
        self._id = event_create()

    def is_set(self):
        return event_is_set(self._id)

    def isSet(self):
        return event_is_set(self._id)

    def set(self):
        event_set(self._id)

    def clear(self):
        event_clear(self._id)

    def wait(self, timeout=None):
        if timeout == None:
            return event_wait(self._id)
        return event_wait_timeout(self._id, timeout * 1000)

    def __del__(self):
        _free_native(self)

class Timer(Thread):
    # Calls function(*args, **kwargs) after `interval` seconds unless
    # cancel() comes first.
    def __init__(self, interval, function, args=None, kwargs=None):
        Thread.__init__(self)
        self.interval = interval
        self.function = function
        self.args = args
        if args == None:
            self.args = []
        self.kwargs = kwargs
        if kwargs == None:
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
    def __init__(self, parties, action=None, timeout=None):
        if parties < 1:
            raise ValueError("parties must be > 0")
        self.parties = parties
        self._action = action
        self._timeout = timeout
        self._cond = Condition(Lock())
        self._count = 0
        self._generation = 0
        self.broken = False

    @property
    def n_waiting(self):
        return self._count

    def wait(self, timeout=None):
        if timeout == None:
            timeout = self._timeout
        with self._cond:
            if self.broken:
                raise BrokenBarrierError()
            var gen = self._generation
            var index = self._count
            self._count = self._count + 1
            if self._count == self.parties:
                if self._action != None:
                    self._action()
                self._count = 0
                self._generation = self._generation + 1
                self._cond.notify_all()
                return index
            var ok = self._cond.wait_for(lambda: self._generation != gen or self.broken, timeout)
            if self.broken or not ok:
                self.broken = True
                self._cond.notify_all()
                raise BrokenBarrierError()
            return index

    def reset(self):
        with self._cond:
            self.broken = False
            self._count = 0
            self._generation = self._generation + 1
            self._cond.notify_all()

    def abort(self):
        with self._cond:
            self.broken = True
            self._cond.notify_all()

class local:
    # Attributes per thread (round 77: it called natives that never
    # existed): each thread sees only what it set itself.
    def __init__(self):
        _ny_setattr_raw(self, "_ny_tl", {})

    def _mine(self, make):
        var tid = get_ident()
        var d = self._ny_tl.get(tid)
        if d == None and make:
            d = {}
            self._ny_tl[tid] = d
        return d

    def __getattr__(self, name):
        var d = self._mine(False)
        if d == None or not (name in d):
            raise AttributeError("'_thread._local' object has no attribute '" + name + "'")
        return d[name]

    def __setattr__(self, name, value):
        self._mine(True)[name] = value

    def __delattr__(self, name):
        var d = self._mine(False)
        if d == None or not (name in d):
            raise AttributeError(name)
        del d[name]
