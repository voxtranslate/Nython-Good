# nython: module    (import it by name: it runs in a module scope of its own)
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
# What a call can carry: Nython has no pickle module yet, so calls, results
# and exceptions travel as JSON in a format of this module's own, which
# carries None, bools, ints of any size, floats (inf and nan too), complex,
# str, bytes, bytearray, lists, tuples, dicts (any of these as keys), sets
# and frozensets, nested; functions, classes and builtins by their module
# and qualified name (module-level ones, as pickle can send); instances of
# classes defined at module level, by class and __dict__ (pickle's default
# for plain objects); exceptions by class and args. Anything else - a
# lambda, a nested function, an open file, a lock - fails the future with
# PicklingError (pickle.PicklingError when a pickle module exists), as
# CPython's pool does for what pickle cannot send.
#
# Differences from CPython: mp_context is accepted and ignored (there is one
# way to start a process); the transport is the format above, not pickle.

import os
import sys
import json
import base64
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


_BUILTIN_CLASSES = set("""BaseException BaseExceptionGroup Exception ExceptionGroup ArithmeticError
AssertionError AttributeError BlockingIOError BrokenPipeError BufferError ChildProcessError
ConnectionAbortedError ConnectionError ConnectionRefusedError ConnectionResetError EOFError
EnvironmentError FileExistsError FileNotFoundError FloatingPointError GeneratorExit IOError
ImportError IndentationError IndexError InterruptedError IsADirectoryError KeyError
KeyboardInterrupt LookupError MemoryError ModuleNotFoundError NameError NotADirectoryError
NotImplementedError OSError OverflowError PermissionError ProcessLookupError RecursionError
ReferenceError RuntimeError StopAsyncIteration StopIteration SyntaxError SystemError SystemExit
TabError TimeoutError TypeError UnboundLocalError UnicodeDecodeError UnicodeEncodeError
UnicodeError UnicodeTranslateError ValueError ZeroDivisionError Warning UserWarning
DeprecationWarning PendingDeprecationWarning SyntaxWarning RuntimeWarning FutureWarning
ImportWarning UnicodeWarning BytesWarning ResourceWarning EncodingWarning""".split())


def _module_of(obj):
    var m = getattr(obj, "__module__", None)
    if m is None:
        m = "builtins"
    # (Nython reports the builtin exception classes as defined in __main__)
    if m == "__main__" and isinstance(obj, type) and getattr(obj, "__name__", "") in _BUILTIN_CLASSES:
        m = "builtins"
    return m


def _ref(obj):
    var q = _qualname(obj)
    if q is None or "<" in q:
        raise PicklingError("Can't pickle " + repr(obj) + ": it is not a module-level function or class")
    return [_module_of(obj), q]


def encode(obj):
    # a JSON-able form of obj (see the header)
    if obj is None or obj is True or obj is False:
        return obj
    var t = type(obj)
    if t is bool:
        return obj
    if t is int:
        if -9007199254740991 <= obj <= 9007199254740991:
            return obj
        return {"i": str(obj)}
    if t is str:
        return obj
    if t is float:
        return {"f": repr(obj)}
    if t is list:
        return [encode(x) for x in obj]
    if t is tuple:
        return {"t": [encode(x) for x in obj]}
    if t is dict:
        return {"d": [[encode(k), encode(obj[k])] for k in obj]}
    if t is bytes:
        return {"b": base64.b64encode(obj).decode("ascii")}
    if t is bytearray:
        return {"ba": base64.b64encode(bytes(obj)).decode("ascii")}
    if t is set:
        return {"s": [encode(x) for x in obj]}
    if t is frozenset:
        return {"fs": [encode(x) for x in obj]}
    if t is complex:
        return {"c": [repr(obj.real), repr(obj.imag)]}
    if isinstance(obj, BaseException):
        return {"e": _ref(type(obj)), "a": [encode(x) for x in obj.args]}
    if isinstance(obj, type) or type(obj).__name__ in ("function", "builtin_function_or_method"):
        return {"r": _ref(obj)}
    var cls = type(obj)
    var d = getattr(obj, "__dict__", None)
    if d is not None and "<" not in (_qualname(cls) or "<"):
        return {"o": _ref(cls), "v": encode(dict(d))}
    raise PicklingError("Can't pickle " + repr(obj) + ": no way to send it to a worker process")


def _resolve(ref, main_ns):
    var mod = ref[0]
    var qual = ref[1]
    var obj = None
    if mod == "__main__" or mod == "__mp_main__":
        if main_ns is None:
            raise PicklingError("Can't find " + qual + " in __main__")
        obj = main_ns
        var parts = qual.split(".")
        obj = main_ns[parts[0]]
        for p in parts[1:]:
            obj = getattr(obj, p)
        return obj
    if mod == "builtins":
        var parts = qual.split(".")
        obj = eval(parts[0])
        for p in parts[1:]:
            obj = getattr(obj, p)
        return obj
    var ns = {}
    exec("import " + mod + " as _m", ns)
    obj = ns["_m"]
    for p in qual.split("."):
        obj = getattr(obj, p)
    return obj


def decode(v, main_ns=None):
    if v is None or isinstance(v, (bool, int, str)):
        return v
    if isinstance(v, list):
        return [decode(x, main_ns) for x in v]
    if "i" in v:
        return int(v["i"])
    if "f" in v:
        return float(v["f"])
    if "t" in v:
        return tuple(decode(x, main_ns) for x in v["t"])
    if "d" in v:
        var d = {}
        for kv in v["d"]:
            d[decode(kv[0], main_ns)] = decode(kv[1], main_ns)
        return d
    if "b" in v:
        return base64.b64decode(v["b"])
    if "ba" in v:
        return bytearray(base64.b64decode(v["ba"]))
    if "s" in v:
        return set(decode(x, main_ns) for x in v["s"])
    if "fs" in v:
        return frozenset(decode(x, main_ns) for x in v["fs"])
    if "c" in v:
        return complex(float(v["c"][0]), float(v["c"][1]))
    if "e" in v:
        var cls = _resolve(v["e"], main_ns)
        var args = [decode(x, main_ns) for x in v["a"]]
        try:
            return cls(*args)
        except Exception:
            var e = Exception(*args)
            return e
    if "r" in v:
        return _resolve(v["r"], main_ns)
    if "o" in v:
        var cls = _resolve(v["o"], main_ns)
        var obj = object.__new__(cls)
        var fields = decode(v["v"], main_ns)
        for k in fields:
            setattr(obj, k, fields[k])
        return obj
    raise ValueError("bad message")


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
            self.send({"op": "init", "fn": encode(ex._initializer), "args": encode(tuple(ex._initargs))})
            var r = self.receive()
            if r is None or "initerr" in r:
                raise BrokenProcessPool("A child process terminated abruptly, the process pool is not usable anymore")

    def send(self, msg):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def receive(self):
        # the next reply; other lines the worker printed go to our stdout
        while True:
            var line = self.proc.stdout.readline()
            if not line:
                return None
            if line.startswith(_MARK):
                return json.loads(line[len(_MARK):])
            sys.stdout.write(line)

    def stop(self):
        if self.proc is not None:
            try:
                self.send({"op": "quit"})
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
                msg = {"op": "call", "fn": encode(item[1]), "args": encode(tuple(item[2])),
                       "kwargs": encode(dict(item[3])), "chunk": item[4]}
            except BaseException as e:
                f.set_exception(e)
                continue
            var r = None
            try:
                self.send(msg)
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
            # what the result names from __main__ is looked up where the
            # called function was defined
            var mns = None
            if _module_of(item[1]) == "__main__":
                mns = getattr(item[1], "__globals__", None)
            try:
                if "ok" in r:
                    f.set_result(decode(r["ok"], mns))
                else:
                    var exc = decode(r["err"], mns)
                    exc.__cause__ = _RemoteTraceback('\n"""\n' + r.get("tb", "") + '"""')
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
