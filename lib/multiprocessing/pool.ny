# nython: module    (import it by name: it runs in a module scope of its own)
# lib/multiprocessing/pool.ny - Pool: a pool of worker processes (round 80),
# CPython's API: apply, apply_async(func, args, kwds, callback,
# error_callback), map, map_async, imap, imap_unordered, starmap,
# starmap_async (chunksize= everywhere, CPython's default for map), close,
# terminate, join, the with statement (terminate at exit), maxtasksperchild
# (a worker is replaced after that many tasks), initializer/initargs;
# AsyncResult.get(timeout)/wait/ready/successful; an exception raised in a
# worker is raised again by get() with the worker's traceback as its
# __cause__ (RemoteTraceback); a result that cannot be pickled fails as
# MaybeEncodingError.
#
# Scheduling (Nython's): the tasks wait on the pool's object server in one
# deque per worker, dealt round-robin; a worker takes up to a batch of its
# own at a time, and when its deque is empty it steals half of what is left
# at the far end of the longest one - randomized work stealing (Blumofe &
# Leiserson, "Scheduling multithreaded computations by work stealing",
# JACM 1999) with steal-half, the deterministic longest-victim variant.
# With uneven task costs a long tail no longer waits behind the one worker
# whose chunk it was dealt to, and chunks do not need to be small to
# balance. Pool(..., _scheduler="fifo") is CPython's single shared queue,
# kept for comparison; pool._steals() reports how much was stolen.

import os
import sys
import time
import threading
import pickle
import traceback
from multiprocessing import managers as _mg
from multiprocessing import process as _process

__all__ = ['Pool', 'ThreadPool', 'TimeoutError', 'AsyncResult', 'ApplyResult', 'MapResult', 'IMapIterator',
           'RemoteTraceback', 'MaybeEncodingError']

INIT = "INIT"
RUN = "RUN"
CLOSE = "CLOSE"
TERMINATE = "TERMINATE"

TimeoutError = TimeoutError


class RemoteTraceback(Exception):
    def __init__(self, tb):
        self.tb = tb

    def __str__(self):
        return self.tb


class ExceptionWithTraceback:
    def __init__(self, exc, tb):
        self.exc = exc
        self.tb = '\n"""\n%s"""' % tb

    def __reduce__(self):
        return rebuild_exc, (self.exc, self.tb)


def rebuild_exc(exc, tb):
    exc.__cause__ = RemoteTraceback(tb)
    return exc


class MaybeEncodingError(Exception):
    """Wraps possible unpickleable errors, so they can be safely sent through the socket."""

    def __init__(self, exc, value):
        self.exc = repr(exc)
        self.value = repr(value)
        super().__init__(self.exc, self.value)

    def __str__(self):
        return "Error sending result: '%s'. Reason: '%s'" % (self.value, self.exc)

    def __repr__(self):
        return "<%s: %s>" % (type(self).__name__, self)


def mapstar(args):
    return list(map(*args))


def starmapstar(args):
    return [args[0](*a) for a in args[1]]


class _Star(object):
    # mapstar / starmapstar bound to the mapped function: one callable,
    # pickled once per map call
    def __init__(self, mapper, func):
        self.mapper = mapper
        self.func = func

    def __call__(self, chunk):
        return self.mapper((self.func, chunk))


# ── the worker (runs in the child) ───────────────────────────────────────────
def worker(taskpool, outqueue, index, initializer=None, initargs=(), maxtasks=None, batch=1):
    if initializer is not None:
        initializer(*initargs)
    var completed = 0
    # the callables, unpickled once each (a task names its callable by the
    # pickle the pool made of it once per call - the rest of a task is
    # plain data, which pickles natively)
    var funcs = {}
    while maxtasks is None or completed < maxtasks:
        var want = batch if maxtasks is None else max(1, min(batch, maxtasks - completed))
        var blobs = None
        try:
            blobs = taskpool.ocall("get", index, want, None)
        except (EOFError, OSError):
            break
        if blobs is None:
            break
        var results = []
        for blob in blobs:
            var task = pickle.loads(blob)
            var job = task[0]
            var i = task[1]
            var func = funcs.get(task[2])
            if func is None:
                func = pickle.loads(task[2])
                if len(funcs) > 64:
                    funcs.clear()
                funcs[task[2]] = func
            var args = task[3]
            var kwds = task[4]
            var result = None
            try:
                result = (True, func(*args, **kwds))
            except Exception as e:
                result = (False, ExceptionWithTraceback(e, traceback.format_exc()))
            var data = None
            try:
                data = pickle.dumps((job, i, result), 5)
            except Exception as e:
                data = pickle.dumps((job, i, (False, MaybeEncodingError(e, result[1]))), 5)
            results.append(data)
            completed += 1
        if results:
            outqueue.ocall("put_many", results)
    # tell the pool this worker is gone (maxtasksperchild)
    try:
        outqueue.ocall("put", pickle.dumps(("exit", index, None), 5), True, None)
    except Exception:
        pass


# ── results ─────────────────────────────────────────────────────────────────
class ApplyResult(object):

    def __init__(self, pool, callback, error_callback):
        self._pool = pool
        self._event = threading.Event()
        self._job = pool._next_job()
        self._cache = pool._cache
        self._callback = callback
        self._error_callback = error_callback
        self._cache[self._job] = self

    def ready(self):
        return self._event.is_set()

    def successful(self):
        if not self.ready():
            raise ValueError("{0!r} not ready".format(self))
        return self._success

    def wait(self, timeout=None):
        self._event.wait(timeout)

    def get(self, timeout=None):
        self.wait(timeout)
        if not self.ready():
            raise TimeoutError
        if self._success:
            return self._value
        raise self._value

    def _set(self, i, obj):
        self._success = obj[0]
        self._value = obj[1]
        if self._callback and self._success:
            self._callback(self._value)
        if self._error_callback and not self._success:
            self._error_callback(self._value)
        self._event.set()
        self._cache.pop(self._job, None)
        self._pool = None


AsyncResult = ApplyResult


class MapResult(ApplyResult):

    def __init__(self, pool, chunksize, length, callback, error_callback):
        ApplyResult.__init__(self, pool, callback, error_callback)
        self._success = True
        self._value = [None] * length
        self._chunksize = chunksize
        if chunksize <= 0:
            self._number_left = 0
            self._event.set()
            self._cache.pop(self._job, None)
        else:
            self._number_left = length // chunksize + (1 if length % chunksize else 0)

    def _set(self, i, success_result):
        self._number_left -= 1
        var success = success_result[0]
        var result = success_result[1]
        if success and self._success:
            self._value[i * self._chunksize:(i + 1) * self._chunksize] = result
            if self._number_left == 0:
                if self._callback:
                    self._callback(self._value)
                self._cache.pop(self._job, None)
                self._event.set()
                self._pool = None
        else:
            if not success and self._success:
                # only store first exception
                self._success = False
                self._value = result
            if self._number_left == 0:
                if self._error_callback:
                    self._error_callback(self._value)
                self._cache.pop(self._job, None)
                self._event.set()
                self._pool = None


class IMapIterator(object):

    def __init__(self, pool):
        self._pool = pool
        self._cond = threading.Condition(threading.Lock())
        self._job = pool._next_job()
        self._cache = pool._cache
        self._items = {}
        self._unordered = []
        self._index = 0
        self._length = None
        self._received = 0
        self._cache[self._job] = self

    def __iter__(self):
        return self

    def next(self, timeout=None):
        var deadline = None if timeout is None else time.monotonic() + timeout
        with self._cond:
            while True:
                var got = self._take()
                if got is not None:
                    var success = got[0]
                    if success:
                        return got[1]
                    raise got[1]
                if self._length is not None and self._index >= self._length:
                    self._pool = None
                    raise StopIteration
                if deadline is None:
                    self._cond.wait()
                else:
                    var left = deadline - time.monotonic()
                    if left <= 0:
                        raise TimeoutError
                    self._cond.wait(left)

    __next__ = next

    def _take(self):
        if self._index in self._items:
            var v = self._items.pop(self._index)
            self._index += 1
            return v
        return None

    def _set(self, i, obj):
        with self._cond:
            self._items[i] = obj
            self._received += 1
            self._cond.notify()
            if self._length == self._received:
                self._cache.pop(self._job, None)

    def _set_length(self, length):
        with self._cond:
            self._length = length
            self._cond.notify()
            if self._length == self._received:
                self._cache.pop(self._job, None)


class IMapUnorderedIterator(IMapIterator):

    def _take(self):
        if self._unordered:
            self._index += 1
            return self._unordered.pop(0)
        return None

    def _set(self, i, obj):
        with self._cond:
            self._unordered.append(obj)
            self._received += 1
            self._cond.notify()
            if self._length == self._received:
                self._cache.pop(self._job, None)


# ── the pool ────────────────────────────────────────────────────────────────
class Pool(object):
    """Class which supports an async version of applying functions to arguments."""

    def __init__(self, processes=None, initializer=None, initargs=(), maxtasksperchild=None, context=None,
                 _scheduler="steal", _batch=None):
        self._state = INIT
        if processes is None:
            processes = os.cpu_count() or 1
        if processes < 1:
            raise ValueError("Number of processes must be at least 1")
        if maxtasksperchild is not None:
            if not isinstance(maxtasksperchild, int) or maxtasksperchild <= 0:
                raise ValueError("maxtasksperchild must be a positive int or None")
        if initializer is not None and not callable(initializer):
            raise TypeError('initializer must be a callable')
        self._processes = processes
        self._initializer = initializer
        self._initargs = initargs
        self._maxtasksperchild = maxtasksperchild
        self._scheduler = _scheduler
        self._batch = _batch if _batch is not None else (1 if _scheduler == "fifo" else 4)
        self._cache = {}
        self._job_counter = [0]
        self._mutex = threading.Lock()
        self._taskpool = _mg._create("TaskPool", processes, _scheduler)
        self._outqueue = _mg._create("Queue", 0)
        self._pool = [None] * processes
        for i in range(processes):
            self._start_worker(i)
        self._state = RUN
        self._result_thread = threading.Thread(target=self._handle_results, daemon=True,
                                               name="Pool-result-handler")
        self._result_thread.start()

    def _next_job(self):
        with self._mutex:
            self._job_counter[0] += 1
            return self._job_counter[0]

    def _start_worker(self, i):
        var w = _process.Process(target=worker, args=(self._taskpool, self._outqueue, i, self._initializer,
                                                     self._initargs, self._maxtasksperchild, self._batch))
        w.name = w.name.replace('Process', 'PoolWorker')
        w.daemon = True
        w.start()
        self._pool[i] = w

    def _handle_results(self):
        while True:
            var blob = None
            try:
                blob = self._outqueue.ocall("get", True, None)
            except Exception:
                break
            var task = pickle.loads(blob)
            if task is None:
                break
            if task[0] == "exit":
                var i = task[1]
                if self._state == RUN and self._maxtasksperchild is not None:
                    try:
                        self._pool[i].join()
                    except Exception:
                        pass
                    self._start_worker(i)
                continue
            var cache = self._cache.get(task[0])
            if cache is not None:
                try:
                    cache._set(task[1], task[2])
                except Exception:
                    traceback.print_exc()

    def _check_running(self):
        if self._state != RUN:
            raise ValueError("Pool not running")

    def _submit(self, tasks):
        # (job, i, func, args, kwds): func pickled once for all of them
        var fblobs = {}
        var blobs = []
        for t in tasks:
            var key = id(t[2])
            var fb = fblobs.get(key)
            if fb is None:
                fb = pickle.dumps(t[2], 5)
                fblobs[key] = fb
            blobs.append(pickle.dumps((t[0], t[1], fb, t[3], t[4]), 5))
        self._taskpool.ocall("put_many", blobs)

    def apply(self, func, args=(), kwds={}):
        """Equivalent of `func(*args, **kwds)`."""
        return self.apply_async(func, args, kwds).get()

    def apply_async(self, func, args=(), kwds={}, callback=None, error_callback=None):
        self._check_running()
        var result = ApplyResult(self, callback, error_callback)
        self._submit([(result._job, 0, func, tuple(args), dict(kwds))])
        return result

    def _get_chunks(self, func, iterable, chunksize, star):
        var it = list(iterable)
        var out = []
        var i = 0
        var k = 0
        while i < len(it):
            out.append((k, (func, tuple(it[i:i + chunksize]))))
            i += chunksize
            k += 1
        return it, out

    def _map_async(self, func, iterable, mapper, chunksize=None, callback=None, error_callback=None):
        self._check_running()
        if not hasattr(iterable, '__len__'):
            iterable = list(iterable)
        if chunksize is None:
            var q = divmod(len(iterable), len(self._pool) * 4)
            chunksize = q[0]
            if q[1]:
                chunksize += 1
        if len(iterable) == 0:
            chunksize = 0
        var result = MapResult(self, chunksize, len(iterable), callback, error_callback)
        var star = _Star(mapper, func)
        if chunksize:
            var tasks = []
            var items = list(iterable)
            var i = 0
            var k = 0
            while i < len(items):
                tasks.append((result._job, k, star, (tuple(items[i:i + chunksize]),), {}))
                i += chunksize
                k += 1
            self._submit(tasks)
        return result

    def map(self, func, iterable, chunksize=None):
        """Apply `func` to each element in `iterable`, collecting the results in a list that is returned."""
        return self._map_async(func, iterable, mapstar, chunksize).get()

    def starmap(self, func, iterable, chunksize=None):
        """Like `map()` method but the elements of the `iterable` are expected to be iterables as well."""
        return self._map_async(func, iterable, starmapstar, chunksize).get()

    def starmap_async(self, func, iterable, chunksize=None, callback=None, error_callback=None):
        return self._map_async(func, iterable, starmapstar, chunksize, callback, error_callback)

    def map_async(self, func, iterable, chunksize=None, callback=None, error_callback=None):
        return self._map_async(func, iterable, mapstar, chunksize, callback, error_callback)

    def _imap(self, cls, func, iterable, chunksize):
        self._check_running()
        if chunksize < 1:
            raise ValueError("Chunksize must be 1+, not {0:n}".format(chunksize))
        var result = cls(self)
        var items = list(iterable)
        var tasks = []
        if chunksize == 1:
            var i = 0
            for x in items:
                tasks.append((result._job, i, func, (x,), {}))
                i += 1
            self._submit(tasks)
            result._set_length(len(items))
            return result
        var j = 0
        var k = 0
        var star = _Star(mapstar, func)
        while j < len(items):
            tasks.append((result._job, k, star, (tuple(items[j:j + chunksize]),), {}))
            j += chunksize
            k += 1
        self._submit(tasks)
        result._set_length(k)

        def flat():
            for chunk in result:
                for x in chunk:
                    yield x
        return flat()

    def imap(self, func, iterable, chunksize=1):
        """Equivalent of `map()` -- can be MUCH slower than `Pool.map()`."""
        return self._imap(IMapIterator, func, iterable, chunksize)

    def imap_unordered(self, func, iterable, chunksize=1):
        """Like `imap()` method but ordering of results is arbitrary."""
        return self._imap(IMapUnorderedIterator, func, iterable, chunksize)

    def close(self):
        if self._state == RUN:
            self._state = CLOSE
            self._taskpool.ocall("close")

    def terminate(self):
        if self._state == TERMINATE:
            return
        self._state = TERMINATE
        try:
            self._taskpool.ocall("clear")
            self._taskpool.ocall("close")
        except Exception:
            pass
        for p in self._pool:
            if p is not None and p.exitcode is None:
                p.terminate()
        for p in self._pool:
            if p is not None:
                p.join(1.0)
        self._stop_results()

    def _stop_results(self):
        try:
            self._outqueue.ocall("put", pickle.dumps(None, 5), True, None)
        except Exception:
            pass
        if self._result_thread is not threading.current_thread():
            self._result_thread.join(5.0)

    def join(self):
        if self._state == RUN:
            raise ValueError("Pool is still running")
        elif self._state not in (CLOSE, TERMINATE):
            raise ValueError("In unknown state")
        if self._state == CLOSE:
            # wait for the outstanding work, then the workers
            while self._cache:
                time.sleep(0.005)
            for p in list(self._pool):
                if p is not None:
                    p.join()
            self._stop_results()

    def _steals(self):
        # (steal operations, tasks moved by them) so far
        return self._taskpool.ocall("stats")

    def __enter__(self):
        self._check_running()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.terminate()

    def __repr__(self):
        return "<%s.%s state=%s pool_size=%d>" % (type(self).__module__, type(self).__qualname__, self._state,
                                                 len(self._pool))

    def __reduce__(self):
        raise NotImplementedError('pool objects cannot be passed between processes or pickled')


class ThreadPool(Pool):
    """A Pool whose workers are threads of this process (CPython's
    multiprocessing.pool.ThreadPool)."""

    def _start_worker(self, i):
        var t = threading.Thread(target=worker, args=(self._taskpool, self._outqueue, i, self._initializer,
                                                     self._initargs, self._maxtasksperchild, self._batch),
                                 daemon=True)
        t.start()
        self._pool[i] = _ThreadWorker(t)

    def __init__(self, processes=None, initializer=None, initargs=()):
        Pool.__init__(self, processes, initializer, initargs)


class _ThreadWorker(object):
    def __init__(self, t):
        self.t = t

    @property
    def exitcode(self):
        return None if self.t.is_alive() else 0

    def terminate(self):
        pass

    def join(self, timeout=None):
        self.t.join(timeout)
