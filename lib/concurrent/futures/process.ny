# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/concurrent/futures/process.ny - ProcessPoolExecutor: calls run in
# other Nython processes (round 79).
#
#     from concurrent.futures import ProcessPoolExecutor
#     def square(n):
#         return n * n
#     if __name__ == "__main__":
#         with ProcessPoolExecutor(max_workers=2) as ex:
#             print(list(ex.map(square, range(10))))
#
# The workers are real processes: each is this interpreter (sys.executable)
# running lib/concurrent/futures/_procworker.ny, driven by a thread of the
# parent over the child's stdin and stdout, one call at a time. As with
# CPython's "spawn" start method, a worker runs the main program again as
# the module __mp_main__ (so its `if __name__ == "__main__":` part does not
# run there) to find the functions and classes defined in it.
#
# ProcessPoolExecutor(max_workers=None, mp_context=None, initializer=None,
# initargs=(), *, max_tasks_per_child=None): submit, map(timeout=,
# chunksize=), shutdown(wait=True, *, cancel_futures=False), the with
# statement; workers started on demand up to max_workers (os.cpu_count() by
# default) and replaced after max_tasks_per_child calls; BrokenProcessPool
# when a worker dies (every pending future gets it, and the pool refuses new
# work) or when an initializer fails; a worker's exception is raised again
# in the parent with the same type and arguments, its traceback text kept as
# the __cause__ (CPython's _RemoteTraceback). A worker's prints reach this
# process's stdout.
#
# What a call can carry: anything pickle (lib/pickle.ny, CPython's format)
# can - calls, their arguments, results and exceptions are pickled (round
# 80; round 79 carried them in a JSON format of its own, before pickle
# existed). Functions and classes go by reference, so they must be defined
# at the top level of a module or of the main program; a lambda, a nested
# function, an open file or a lock fails the future with
# pickle.PicklingError, as CPython's pool does.
#
# Differences from CPython: mp_context is accepted and ignored (there is one
# way to start a process, spawn); the workers are driven over their stdin
# and stdout (each message a line: a marker and the base64 of its pickle).

import os
import sys
import base64
import pickle
import threading
import queue
import atexit
import weakref
import subprocess
from concurrent.futures import _base

try:
    from pickle import PicklingError
except ImportError:
    class PicklingError(Exception):
        pass


class BrokenProcessPool(_base.BrokenExecutor):
    pass


class _RemoteTraceback(Exception):
    def __init__(self, tb):
        self.tb = tb

    def __str__(self):
        return self.tb


EXTRA_QUEUED_CALLS = 1
_MARK = "\x00nypool\x00"
_WORKER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_procworker.ny")

# ── the transport ────────────────────────────────────────────────────────────
def _qualname(obj):
    var q = getattr(obj, "__qualname__", None)
    if q is None:
        q = getattr(obj, "__name__", None)
    return q


def _module_of(obj):
    var m = getattr(obj, "__module__", None)
    if m is None:
        m = "builtins"
    return m


def _pack(msg):
    # one line: the marker's line form of a pickled message
    return base64.b64encode(pickle.dumps(msg, 5)).decode("ascii")


def _unpack(text):
    return pickle.loads(base64.b64decode(text))


# ── the pool ─────────────────────────────────────────────────────────────────

_global_shutdown = False
_live_executors = weakref.WeakSet()


def _python_exit():
    global _global_shutdown
    _global_shutdown = True
    for ex in list(_live_executors):
        ex.shutdown(wait=True)


atexit.register(_python_exit)


def _main_path():
    var argv = getattr(sys, "argv", None)
    if argv and argv[0] and argv[0] not in ("-c", "-m", "-") and os.path.isfile(argv[0]):
        return os.path.abspath(argv[0])
    return ""


class _Worker:
    # one worker process and the parent thread that drives it
    def __init__(self, executor):
        self.executor = executor
        self.proc = None
        self.calls = 0

    def start_process(self):
        var ex = self.executor
        self.proc = subprocess.Popen([sys.executable, _WORKER, _main_path()],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.calls = 0
        if ex._initializer is not None:
            self.send(("init", ex._initializer, tuple(ex._initargs)))
            var r = self.receive()
            if r is None or r[0] == "initerr":
                raise BrokenProcessPool("A child process terminated abruptly, the process pool is not usable anymore")

    def send(self, msg):
        self.proc.stdin.write(_pack(msg) + "\n")
        self.proc.stdin.flush()

    def receive(self):
        # the next reply; other lines the worker printed go to our stdout
        while True:
            var line = self.proc.stdout.readline()
            if not line:
                return None
            if line.startswith(_MARK):
                return _unpack(line[len(_MARK):].rstrip("\n"))
            sys.stdout.write(line)

    def stop(self):
        if self.proc is not None:
            try:
                self.send(("quit",))
                self.proc.stdin.close()
            except Exception:
                pass
            try:
                self.proc.wait(timeout=10)
            except Exception:
                self.proc.kill()
            self.proc = None

    def run(self):
        var ex = self.executor
        try:
            self.start_process()
        except BaseException as e:
            ex._set_broken(str(e) if isinstance(e, BrokenProcessPool) else
                           "A child process terminated abruptly, the process pool is not usable anymore")
            self.stop()
            return
        while True:
            var item = ex._queue.get(block=True)
            if item is None:
                ex._queue.put(None)
                break
            var f = item[0]
            if not f.set_running_or_notify_cancel():
                continue
            var msg = None
            try:
                msg = _pack(("call", item[1], tuple(item[2]), dict(item[3]), item[4]))
            except BaseException as e:
                f.set_exception(e)
                continue
            var r = None
            try:
                self.proc.stdin.write(msg + "\n")
                self.proc.stdin.flush()
                r = self.receive()
            except OSError:
                r = None
            if r is None:
                var err = BrokenProcessPool("A process in the process pool was terminated abruptly "
                                            "while the future was running or pending.")
                f.set_exception(err)
                ex._set_broken("A child process terminated abruptly, the process pool is not usable anymore")
                self.stop()
                return
            try:
                if r[0] == "ok":
                    f.set_result(r[1])
                else:
                    var exc = r[1]
                    exc.__cause__ = _RemoteTraceback('\n"""\n' + r[2] + '"""')
                    f.set_exception(exc)
            except BaseException as e:
                f.set_exception(e)
            self.calls += 1
            if ex._max_tasks_per_child is not None and self.calls >= ex._max_tasks_per_child:
                self.stop()
                try:
                    self.start_process()
                except BaseException as e:
                    ex._set_broken(str(e))
                    return
            ex._idle.release()
        self.stop()


class ProcessPoolExecutor(_base.Executor):
    def __init__(self, max_workers=None, mp_context=None,
                 initializer=None, initargs=(), *, max_tasks_per_child=None):
        if max_workers is None:
            max_workers = os.cpu_count() or 1
            if os.name == "nt":
                max_workers = min(61, max_workers)
        elif max_workers <= 0:
            raise ValueError("max_workers must be greater than 0")
        if initializer is not None and not callable(initializer):
            raise TypeError("initializer must be a callable")
        if max_tasks_per_child is not None:
            if not isinstance(max_tasks_per_child, int):
                raise TypeError("max_tasks_per_child must be an integer")
            elif max_tasks_per_child <= 0:
                raise ValueError("max_tasks_per_child must be >= 1")
        self._max_workers = max_workers
        self._initializer = initializer
        self._initargs = initargs
        self._max_tasks_per_child = max_tasks_per_child
        self._queue = queue.SimpleQueue()
        self._idle = threading.Semaphore(0)
        self._threads = []
        self._broken = False
        self._shutdown_thread = False
        self._shutdown_lock = threading.Lock()
        _live_executors.add(self)

    def _set_broken(self, why):
        with self._shutdown_lock:
            if not self._broken:
                self._broken = why
        # every future still waiting fails
        while True:
            try:
                var item = self._queue.get_nowait()
            except queue.Empty:
                break
            if item is None:
                continue
            if item[0].set_running_or_notify_cancel():
                item[0].set_exception(BrokenProcessPool(why))
        self._queue.put(None)

    def _adjust_process_count(self):
        if self._idle.acquire(timeout=0):
            return
        if len(self._threads) < self._max_workers:
            var w = _Worker(self)
            var t = threading.Thread(target=w.run, name="ProcessPoolExecutor-worker-" + str(len(self._threads)),
                                     daemon=True)
            t.start()
            self._threads.append(t)

    def submit(self, fn, /, *args, **kwargs):
        return self._submit(fn, args, kwargs, False)

    def _submit(self, fn, args, kwargs, chunk):
        with self._shutdown_lock:
            if self._broken:
                raise BrokenProcessPool(self._broken)
            if self._shutdown_thread:
                raise RuntimeError('cannot schedule new futures after shutdown')
            if _global_shutdown:
                raise RuntimeError('cannot schedule new futures after interpreter shutdown')
            var f = _base.Future()
            self._queue.put((f, fn, args, kwargs, chunk))
            self._adjust_process_count()
            return f

    def map(self, fn, *iterables, timeout=None, chunksize=1):
        if chunksize < 1:
            raise ValueError("chunksize must be >= 1.")
        if chunksize == 1:
            return super().map(fn, *iterables, timeout=timeout)
        # chunks of argument tuples, each run by one worker in one call
        var it = zip(*iterables)
        var fs = []
        while True:
            var chunk = []
            for args in it:
                chunk.append(args)
                if len(chunk) == chunksize:
                    break
            if not chunk:
                break
            fs.append(self._submit(fn, (chunk,), {}, True))
            if len(chunk) < chunksize:
                break
        var end_time = None
        if timeout is not None:
            end_time = timeout + _base.time.monotonic()

        def result_iterator():
            try:
                fs.reverse()
                while fs:
                    var part = None
                    if end_time is None:
                        part = _base._result_or_cancel(fs.pop())
                    else:
                        part = _base._result_or_cancel(fs.pop(), end_time - _base.time.monotonic())
                    for x in part:
                        yield x
            finally:
                for future in fs:
                    future.cancel()
        return result_iterator()

    def shutdown(self, wait=True, *, cancel_futures=False):
        with self._shutdown_lock:
            self._shutdown_thread = True
        if cancel_futures:
            while True:
                try:
                    var item = self._queue.get_nowait()
                except queue.Empty:
                    break
                if item is not None:
                    item[0].cancel()
        self._queue.put(None)
        if wait:
            for t in list(self._threads):
                t.join()
        _live_executors.discard(self)
