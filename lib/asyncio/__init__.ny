# nython: module    (import it by name: it runs in a module scope of its own)
# lib/asyncio/__init__.ny - Python's asyncio (3.12) over Nython's event loop
# (round 77; the event-loop API, transports and protocols, subprocesses, Unix
# sockets, signals, TLS and the 3.12 cancellation rules: round 82).
#
#     import asyncio
#     async def main():
#         reader, writer = await asyncio.open_connection("example.org", 80)
#         ...
#     asyncio.run(main())
#
# Tasks are coroutines on their loop's thread (src/NyConc.cpp), and every
# blocking primitive - a socket read, a lock, a queue, sleep - parks the task
# that calls it while the loop runs the others. An event loop object
# (new_event_loop, get_running_loop) is a persistent native loop
# (async_loop_new): callbacks and tasks can be put on it before it runs and
# from any thread, run_until_complete/run_forever run it on the calling
# thread and leave what is unfinished for the next run.
#
#   Running      run, Runner, get_running_loop, get_event_loop, set_event_loop,
#                new_event_loop, the policies (get/set_event_loop_policy,
#                DefaultEventLoopPolicy)
#   Loop         run_until_complete, run_forever, stop, close, is_running,
#                is_closed, time, call_soon(_threadsafe), call_later, call_at
#                (Handle, TimerHandle), create_future, create_task(name=,
#                context=), set/get_task_factory, run_in_executor (the default
#                executor, or any concurrent.futures one),
#                set_default_executor, shutdown_default_executor,
#                shutdown_asyncgens, set/get/call/default_exception_handler,
#                set/get_debug (slow callbacks are logged), add/remove_reader,
#                add/remove_writer, sock_recv/recv_into/recvfrom/
#                recvfrom_into/sendall/sendto/connect/accept, getaddrinfo,
#                getnameinfo, create_connection, create_server,
#                create_datagram_endpoint, connect_accepted_socket,
#                create_unix_connection, create_unix_server, start_tls,
#                subprocess_exec, subprocess_shell, add/remove_signal_handler
#   Transports   BaseTransport, ReadTransport, WriteTransport, Transport,
#                DatagramTransport, SubprocessTransport: write, writelines,
#                write_eof, can_write_eof, close, abort, is_closing,
#                get_extra_info, pause/resume_reading, is_reading,
#                set/get_write_buffer_limits, get_write_buffer_size; flow
#                control calls the protocol's pause_writing/resume_writing at
#                the high/low water marks
#   Protocols    BaseProtocol, Protocol, BufferedProtocol, DatagramProtocol,
#                SubprocessProtocol
#   Tasks        create_task, Task (cancel(msg), cancelling, uncancel,
#                get_coro, get_context, ...), current_task, all_tasks,
#                ensure_future, gather, wait, wait_for, as_completed, shield,
#                sleep, timeout / timeout_at (Timeout), TaskGroup, to_thread,
#                run_coroutine_threadsafe, Future, wrap_future, iscoroutine,
#                iscoroutinefunction, isfuture, eager_task_factory,
#                create_eager_task_factory
#   Sync         Lock, Event, Condition, Semaphore, BoundedSemaphore, Barrier
#   Queues       Queue, LifoQueue, PriorityQueue, QueueEmpty, QueueFull,
#                QueueShutDown (Queue.shutdown, 3.13)
#   Streams      open_connection, start_server, open_unix_connection,
#                start_unix_server, StreamReader, StreamWriter (drain,
#                start_tls, wait_closed), StreamReaderProtocol, Server
#                (serve_forever, start_serving, close, wait_closed, sockets,
#                async with), IncompleteReadError, LimitOverrunError
#   Subprocess   create_subprocess_exec, create_subprocess_shell, Process
#                (stdin/stdout/stderr streams, communicate, wait, returncode,
#                pid, send_signal/terminate/kill), asyncio.subprocess.PIPE /
#                STDOUT / DEVNULL
#   Signals      loop.add_signal_handler/remove_signal_handler (the handler
#                runs as a loop callback); asyncio.run's Ctrl+C: the main
#                task is cancelled, then KeyboardInterrupt is raised
#   TLS          ssl= on create_connection/create_server/open_connection/
#                start_server, loop.start_tls, StreamWriter.start_tls
#   Beyond Python: race(*aws) - the first to finish wins, the others are
#                cancelled; map_bounded(fn, items, limit) - fn over items with
#                at most `limit` running at once, results in input order;
#                structured-concurrency reports (orphans= on run/Runner, and
#                debug mode): a task still running when asyncio.run's main
#                coroutine ends, or when the task that created it ends, is
#                reported with where it was made (Runner.orphans,
#                OrphanedTasksError) - after Smith's "Notes on structured
#                concurrency" and Trio's nurseries, which forbid both.
#
# How the I/O works: a transport's reads run in a task of the loop that waits
# for its socket on the loop's reactor and calls the protocol
# (data_received, eof_received, ...); write() sends at once what the socket
# takes and buffers the rest, which a writer task sends as the socket drains
# (the protocol is paused above the high-water mark and resumed below the
# low one). A subprocess's pipes are waited for the same way: os_proc_fds
# gives their descriptors and the reactor wakes the task when one is
# readable (stdin is written non-blocking, the task waiting while the pipe
# is full) - so the loop never blocks on a child; on Windows, whose pipes
# cannot be polled, a task polls them with a backoff (1 to 50 ms) and stdin
# is written from a worker thread. TLS sockets are wrapped by lib/ssl.ny and
# the transport reads and writes them as plain ones (the TLS layer is the
# socket's).
#
# Coroutines are objects (round 78): calling an async def gives a coroutine
# (type `coroutine`, send/throw/close, cr_frame ...) that run(), create_task,
# gather and await take as they are; sleep() returns one too. An __await__
# that is a generator is run as a coroutine runner runs it: a bare yield
# lets the loop's other tasks run, a yielded awaitable is awaited.
#
# Differences from Python, on purpose or for now:
#   - an SSL transport sends close_notify when it closes but does not wait
#     for the peer's; can_write_eof() is false for them (as for CPython's);
#   - the child watchers are not provided; add_reader/add_writer take
#     sockets everywhere and other descriptors on POSIX only, so
#     connect_read_pipe/connect_write_pipe are POSIX only (NotImplementedError
#     on Windows); loop.sendfile always takes the fallback (a transport's
#     buffer and flow control), sock_sendfile the kernel's os.sendfile on
#     Linux/macOS;
#   - a callback or task that raises KeyboardInterrupt/SystemExit stops the
#     loop and the exception leaves run_until_complete/run_forever, as in
#     CPython, but only for loop callbacks and the task being run;
#   - nothing more listed here: the native objects under Event, Lock,
#     Semaphore and Queue are freed with them (round 82).
import socket
import os
import sys

_subprocess_mod = none

def _ny_weakset():
    # the loop's set of started async generators (round 82): weak, as
    # CPython's - a generator dropped by the program is not kept alive
    import weakref
    return weakref.WeakSet()

def _sp():
    # lib/subprocess.ny, loaded when the first child is started
    global _subprocess_mod
    if _subprocess_mod is none:
        import subprocess as sp_mod
        _subprocess_mod = sp_mod
    return _subprocess_mod

TimeoutError = TimeoutError
CancelledError = CancelledError
# the builtin (the prelude's, round 77: `except*` takes it apart)
ExceptionGroup = ExceptionGroup

class InvalidStateError(Exception):
    pass

class SendfileNotAvailableError(RuntimeError):
    pass

class QueueEmpty(Exception):
    pass

class QueueFull(Exception):
    pass

class QueueShutDown(Exception):
    pass

class BrokenBarrierError(RuntimeError):
    pass

class IncompleteReadError(EOFError):
    def __init__(self, partial, expected):
        var want = "undefined"
        if expected is not none:
            want = repr(expected)
        super().__init__(str(len(partial)) + " bytes read on a total of " + want + " expected bytes")
        self.partial = partial
        self.expected = expected

class LimitOverrunError(Exception):
    def __init__(self, message, consumed):
        super().__init__(message)
        self.consumed = consumed

# Nython: the structured-concurrency report (orphans="raise")
class OrphanedTasksError(RuntimeError):
    def __init__(self, message, orphans):
        super().__init__(message)
        self.orphans = orphans

FIRST_COMPLETED = "FIRST_COMPLETED"
FIRST_EXCEPTION = "FIRST_EXCEPTION"
ALL_COMPLETED = "ALL_COMPLETED"

_DEFAULT_LIMIT = 65536
_LIMIT = _DEFAULT_LIMIT
_LOG_THRESHOLD_FOR_CONNLOST_WRITES = 5
_SSL_HANDSHAKE_TIMEOUT = 60.0
_HAS_UNIX = socket.AF_UNIX is not none
_WINDOWS = os_platform() == "windows"

def _now():
    return monotonic()

def _running_task():
    var h = async_current_task()
    if h == 0:
        raise RuntimeError("no running event loop")
    return h

# ─── Logging (CPython logs through the "asyncio" logger) ────────────────────

class _LoggerProxy:
    # logging is loaded on the first message
    def _real(self):
        import logging
        return logging.getLogger("asyncio")

    def error(self, msg, *args, **kw):
        self._real().error(msg, *args, **kw)

    def warning(self, msg, *args, **kw):
        self._real().warning(msg, *args, **kw)

    def info(self, msg, *args, **kw):
        self._real().info(msg, *args, **kw)

    def debug(self, msg, *args, **kw):
        self._real().debug(msg, *args, **kw)

logger = _LoggerProxy()

# ─── Coroutines ─────────────────────────────────────────────────────────────

_CO_COROUTINE = 128

def iscoroutine(obj):
    # a coroutine object (round 78), or one of the runtime's coroutine handles
    return async_is_coroutine(obj)

def iscoroutinefunction(func):
    var f = getattr(func, "__func__", func)
    if getattr(f, "_is_coroutine", none) is _is_coroutine:
        return true
    var code = getattr(f, "__code__", none)
    if code is none:
        return false
    return (getattr(code, "co_flags", 0) & _CO_COROUTINE) != 0

_is_coroutine = object()

def _callback_name(func):
    var q = getattr(func, "__qualname__", none)
    if q:
        return q
    var n = getattr(func, "__name__", none)
    if n:
        return n
    return repr(func)

def _format_args(args):
    if args is none:
        return "()"
    var parts = []
    for a in args:
        var r = repr(a)
        if len(r) > 30:
            r = r[:13] + "..." + r[len(r) - 14:]
        parts.append(r)
    return "(" + ", ".join(parts) + ")"

def _function_source(func):
    var f = getattr(func, "__func__", func)
    var code = getattr(f, "__code__", none)
    if code is none:
        return none
    try:
        return (code.co_filename, code.co_firstlineno)
    except AttributeError:
        return none

def _format_callback_source(func, args):
    var s = _callback_name(func) + _format_args(args)
    var src = _function_source(func)
    if src is not none:
        s = s + " at " + str(src[0]) + ":" + str(src[1])
    return s

def _format_coroutine(coro):
    var name = getattr(coro, "__qualname__", none) or getattr(coro, "__name__", none) or "coroutine"
    var fr = none
    try:
        fr = coro.cr_frame
    except BaseException:
        fr = none
    var code = getattr(coro, "cr_code", none)
    if fr is not none:
        try:
            return name + "() running at " + str(fr.f_code.co_filename) + ":" + str(fr.f_lineno)
        except BaseException:
            pass
    if code is not none:
        try:
            return name + "() done, defined at " + str(code.co_filename) + ":" + str(code.co_firstlineno)
        except BaseException:
            pass
    return name + "()"

# ─── Event loop policy and the running loop ─────────────────────────────────

_loops = {}              # native loop handle -> its loop object
_foreign = none          # stands for async_run's private loops

def _get_running_loop():
    if async_current_task() == 0:
        return none
    var lh = async_current_loop()
    if lh != 0:
        var lo = _loops.get(lh)
        if lo is not none:
            return lo
    global _foreign
    if _foreign is none:
        _foreign = _ForeignLoop()
    return _foreign

def get_running_loop():
    var lo = _get_running_loop()
    if lo is none:
        raise RuntimeError("no running event loop")
    return lo

class AbstractEventLoopPolicy:
    def get_event_loop(self):
        raise NotImplementedError

    def set_event_loop(self, loop):
        raise NotImplementedError

    def new_event_loop(self):
        raise NotImplementedError

class BaseDefaultEventLoopPolicy(AbstractEventLoopPolicy):
    _loop_factory = none

    def __init__(self):
        self._local = {}           # thread id -> loop
        self._set_called = {}

    def get_event_loop(self):
        var tid = thread_os_id()
        var lo = self._local.get(tid)
        if lo is none and not self._set_called.get(tid, false) and tid == thread_main():
            lo = self.new_event_loop()
            self._local[tid] = lo
        if lo is none:
            raise RuntimeError("There is no current event loop in thread " + repr(_thread_name()) + ".")
        return lo

    def set_event_loop(self, loop):
        var tid = thread_os_id()
        self._set_called[tid] = true
        if loop is not none and not isinstance(loop, AbstractEventLoop):
            raise TypeError("loop must be an instance of AbstractEventLoop or None, not '" + type(loop).__name__ + "'")
        self._local[tid] = loop

    def new_event_loop(self):
        return self._loop_factory()

def _thread_name():
    try:
        import threading
        return threading.current_thread().name
    except BaseException:
        return "MainThread"

_policy = none

def _init_policy():
    global _policy
    if _policy is none:
        _policy = DefaultEventLoopPolicy()

def get_event_loop_policy():
    _init_policy()
    return _policy

def set_event_loop_policy(policy):
    global _policy
    if policy is not none and not isinstance(policy, AbstractEventLoopPolicy):
        raise TypeError("policy must be an instance of AbstractEventLoopPolicy or None, not '" + type(policy).__name__ + "'")
    _policy = policy

def get_event_loop():
    var lo = _get_running_loop()
    if lo is not none:
        return lo
    return get_event_loop_policy().get_event_loop()

def set_event_loop(loop):
    get_event_loop_policy().set_event_loop(loop)

def new_event_loop():
    return get_event_loop_policy().new_event_loop()

# ─── Runtime events, pooled ─────────────────────────────────────────────────
# A future, a paused transport, an executor call wait on one of the
# runtime's events while something is waiting; the runtime never frees an
# event, so they are taken from a pool and given back (cleared) when the
# wait is over, instead of one per future for the life of the process.
_ev_pool = []

def _free_native(h):
    # a runtime event/semaphore/queue nothing waits on is freed (round 82)
    if h:
        try:
            sync_free(h)
        except BaseException:
            pass

def _ev_get():
    if len(_ev_pool) > 0:
        return _ev_pool.pop()
    return event_create()

def _ev_put(ev):
    event_clear(ev)
    if len(_ev_pool) < 256:
        _ev_pool.append(ev)

# ─── Handles ────────────────────────────────────────────────────────────────

_cb_task = 0             # the native task running a loop callback (current_task() is None there)

class Handle:
    # A callback scheduled with call_soon: cancel() before it runs and it
    # does not.
    def __init__(self, callback, args, loop, context=none):
        self._callback = callback
        self._args = args
        self._loop = loop
        self._context = context
        self._cancelled = false
        self._repr = none
        self._h = 0
        self._ran = false
        self._source_traceback = none
        if loop is not none and loop._debug:
            self._source_traceback = _caller_site(2)

    def _repr_info(self):
        var info = [self.__class__.__name__]
        if self._cancelled:
            info.append("cancelled")
        if self._callback is not none:
            info.append(_format_callback_source(self._callback, self._args))
        if self._source_traceback is not none:
            info.append("created at " + str(self._source_traceback[0]) + ":" + str(self._source_traceback[1]))
        return info

    def __repr__(self):
        if self._repr is not none:
            return self._repr
        return "<" + " ".join(self._repr_info()) + ">"

    def get_context(self):
        return self._context

    def cancel(self):
        if not self._cancelled:
            self._cancelled = true
            if self._loop is not none and self._loop._debug:
                self._repr = repr(self)
            self._callback = none
            self._args = none
            if self._h != 0 and not self._ran:
                try:
                    task_cancel(self._h)
                except ValueError:
                    pass

    def cancelled(self):
        return self._cancelled

    def _run(self):
        if self._cancelled:
            return
        self._ran = true
        global _cb_task
        var prev = _cb_task
        _cb_task = async_current_task()
        var t0 = 0
        var lo = self._loop
        if lo._debug:
            t0 = monotonic()
        try:
            if self._context is none:
                self._callback(*self._args)
            else:
                self._context.run(self._callback, *self._args)
        except (SystemExit, KeyboardInterrupt) as e:
            lo._interrupt(e)
        except BaseException as exc:
            # a callback parked in a blocking call (time.sleep parks the
            # task) is cancelled when its loop closes: not an error then
            if not (lo._closed and isinstance(exc, CancelledError)):
                var ctx = {"message": "Exception in callback " + _format_callback_source(self._callback, self._args),
                           "exception": exc, "handle": self}
                if self._source_traceback is not none:
                    ctx["source_traceback"] = [self._source_traceback]
                lo.call_exception_handler(ctx)
        finally:
            _cb_task = prev
        if lo._debug:
            var dt = monotonic() - t0
            if dt >= lo.slow_callback_duration:
                logger.warning("Executing %s took %.3f seconds", repr(self), dt)

class TimerHandle(Handle):
    # A callback scheduled with call_later/call_at.
    def __init__(self, when, callback, args, loop, context=none):
        super().__init__(callback, args, loop, context)
        self._when = when
        self._scheduled = false

    def _repr_info(self):
        var info = super()._repr_info()
        var pos = 1
        if self._cancelled:
            pos = 2
        info.insert(pos, "when=" + str(self._when))
        return info

    def when(self):
        return self._when

    def __hash__(self):
        return hash(self._when)

    def __lt__(self, other):
        if isinstance(other, TimerHandle):
            return self._when < other._when
        return NotImplemented

    def __le__(self, other):
        if isinstance(other, TimerHandle):
            return self._when < other._when or self.__eq__(other)
        return NotImplemented

    def __gt__(self, other):
        if isinstance(other, TimerHandle):
            return self._when > other._when
        return NotImplemented

    def __ge__(self, other):
        if isinstance(other, TimerHandle):
            return self._when > other._when or self.__eq__(other)
        return NotImplemented

    def __eq__(self, other):
        if isinstance(other, TimerHandle):
            return self._when == other._when and self._callback == other._callback and self._args == other._args and self._cancelled == other._cancelled
        return NotImplemented

    def cancel(self):
        if not self._cancelled and self._loop is not none:
            self._loop._timer_handle_cancelled(self)
        super().cancel()

def _caller_site(depth):
    # (file, line, function) of a caller, for debug-mode reports
    try:
        var f = sys._getframe(depth + 1)
        return (f.f_code.co_filename, f.f_lineno, f.f_code.co_name)
    except BaseException:
        return none

# ─── Futures ────────────────────────────────────────────────────────────────

_PENDING = "PENDING"
_CANCELLED = "CANCELLED"
_FINISHED = "FINISHED"

def isfuture(obj):
    if isinstance(obj, Future):
        return true
    return getattr(type(obj), "_asyncio_future_blocking", none) is not none

class Future:
    # A result set later, by any task or thread; awaiting it waits. Its done
    # callbacks are scheduled on its loop.
    _asyncio_future_blocking = false

    def __init__(self, *, loop=none):
        if loop is none:
            loop = get_event_loop()
        self._loop = loop
        self._state = _PENDING
        self._result = none
        self._exception = none
        self._cancel_message = none
        self._callbacks = []
        self._ev = none           # taken from the pool by the first waiter
        self._waiters = 0
        self._log_traceback = false

    def __del__(self):
        # an exception nobody retrieved, reported when the future goes, as
        # CPython's Future.__del__ (round 82)
        if not getattr(self, "_log_traceback", false):
            return
        self._log_traceback = false
        _report_unretrieved(self, self.__class__.__name__, self._exception)

    def _repr_info(self):
        var info = [string_lower(self._state)]
        if self._state == _FINISHED:
            if self._exception is not none:
                info.append("exception=" + repr(self._exception))
            else:
                var r = repr(self._result)
                if len(r) > 60:
                    r = r[:28] + "..." + r[len(r) - 29:]
                info.append("result=" + r)
        if len(self._callbacks) > 0:
            info.append("cb=[" + ", ".join([_format_callback_source(c[0], ()) for c in self._callbacks]) + "]")
        return info

    def __repr__(self):
        return "<" + self.__class__.__name__ + " " + " ".join(self._repr_info()) + ">"

    def get_loop(self):
        return self._loop

    def _make_cancelled_error(self):
        if self._cancel_message is none:
            return CancelledError()
        return CancelledError(self._cancel_message)

    def done(self):
        return self._state != _PENDING

    def cancelled(self):
        return self._state == _CANCELLED

    def result(self):
        if self._state == _CANCELLED:
            raise self._make_cancelled_error()
        if self._state != _FINISHED:
            raise InvalidStateError("Result is not set.")
        self._log_traceback = false
        if self._exception is not none:
            raise self._exception
        return self._result

    def exception(self):
        if self._state == _CANCELLED:
            raise self._make_cancelled_error()
        if self._state != _FINISHED:
            raise InvalidStateError("Exception is not set.")
        self._log_traceback = false
        return self._exception

    def set_result(self, result):
        if self._state != _PENDING:
            raise InvalidStateError(self._state + ": " + repr(self))
        self._result = result
        self._state = _FINISHED
        self._schedule_callbacks()

    def set_exception(self, exception):
        if self._state != _PENDING:
            raise InvalidStateError(self._state + ": " + repr(self))
        if isinstance(exception, type):
            exception = exception()
        if type(exception) is StopIteration:
            raise TypeError("StopIteration interacts badly with generators and cannot be raised into a Future")
        self._exception = exception
        self._state = _FINISHED
        self._log_traceback = true
        self._schedule_callbacks()

    def cancel(self, msg=none):
        if self._state != _PENDING:
            return false
        self._state = _CANCELLED
        self._cancel_message = msg
        self._schedule_callbacks()
        return true

    def _schedule_callbacks(self):
        var ev = self._ev
        if ev is not none:
            event_set(ev)
        if len(self._callbacks) == 0:
            return
        var cbs = self._callbacks
        self._callbacks = []
        for c in cbs:
            self._loop.call_soon(c[0], self, context=c[1])

    def add_done_callback(self, fn, *, context=none):
        if self._state != _PENDING:
            self._loop.call_soon(fn, self, context=context)
        else:
            self._callbacks.append((fn, context))

    def remove_done_callback(self, fn):
        var keep = []
        var n = 0
        for c in self._callbacks:
            if c[0] == fn:
                n = n + 1
            else:
                keep.append(c)
        self._callbacks = keep
        return n

    def __await__(self):
        return self._wait()

    __iter__ = __await__

    async def _wait(self):
        if self._state == _PENDING:
            if self._ev is none:
                self._ev = _ev_get()
            self._waiters = self._waiters + 1
            self._asyncio_future_blocking = true
            try:
                # (state checked again: a thread may have set the result
                # while the event was being taken)
                if self._state == _PENDING:
                    event_wait(self._ev)
            except CancelledError as e:
                # the task awaiting it was cancelled: so is the future (as
                # Task.cancel() cancels the future its task waits for)
                self.cancel(_cancel_text(e))
                raise
            finally:
                self._asyncio_future_blocking = false
                self._waiters = self._waiters - 1
                if self._waiters == 0 and self._state != _PENDING and self._ev is not none:
                    var ev = self._ev
                    self._ev = none
                    _ev_put(ev)
        return self.result()

def _cancel_text(e):
    # the message a CancelledError carries, none for the runtime's own text
    var a = getattr(e, "args", ())
    if len(a) == 0:
        return none
    var m = a[0]
    if isinstance(m, str) and (" was cancelled" in m):
        return none
    return m

def _report_unretrieved(fut, kind, exc):
    var loop = getattr(fut, "_loop", none)
    if loop is none:
        return
    var ctx = {"message": kind + " exception was never retrieved", "exception": exc, "future": fut}
    var tb = getattr(fut, "_source_traceback", none) or getattr(fut, "_created_at", none)
    if tb is not none:
        ctx["source_traceback"] = tb if isinstance(tb, list) else [tb]
    try:
        loop.call_exception_handler(ctx)
    except BaseException:
        pass

def _set_result_unless_cancelled(fut, result):
    if fut.cancelled():
        return
    fut.set_result(result)

def _copy_future_state(source, dest):
    # source: a concurrent.futures.Future (or an asyncio one), dest: asyncio's
    if dest.cancelled():
        return
    if source.cancelled():
        dest.cancel()
    else:
        var exc = source.exception()
        if exc is not none:
            dest.set_exception(exc)
        else:
            dest.set_result(source.result())

def _chain_future(source, dest):
    # When source finishes, dest gets its outcome (on dest's loop); a
    # cancelled dest cancels source.
    var dest_loop = none
    if isfuture(dest):
        dest_loop = dest._loop
    var source_loop = none
    if isfuture(source):
        source_loop = source._loop
    def _set_state(fut, other):
        if isfuture(fut):
            _copy_future_state(other, fut)
        else:
            if fut.done():
                return
            if other.cancelled():
                fut.cancel()
                return
            var exc = other.exception()
            if exc is not none:
                fut.set_exception(exc)
            else:
                fut.set_result(other.result())
    def _call_check_cancel(d):
        if d.cancelled():
            if source_loop is none or source_loop is dest_loop:
                source.cancel()
            else:
                source_loop.call_soon_threadsafe(source.cancel)
    def _call_set_state(s):
        if dest.cancelled() and dest_loop is not none and dest_loop.is_closed():
            return
        if dest_loop is none or dest_loop is source_loop:
            _set_state(dest, s)
        else:
            if dest_loop.is_closed():
                return
            dest_loop.call_soon_threadsafe(_set_state, dest, s)
    dest.add_done_callback(_call_check_cancel)
    source.add_done_callback(_call_set_state)

def wrap_future(future, *, loop=none):
    # An asyncio Future for a concurrent.futures one.
    if isfuture(future):
        return future
    if loop is none:
        loop = get_event_loop()
    var new_future = loop.create_future()
    _chain_future(future, new_future)
    return new_future

# ─── Tasks ──────────────────────────────────────────────────────────────────

_tasks = {}          # native task handle -> Task
_task_count = 0
_prune_at = 512

def _forget_done():
    var gone = []
    for h in _tasks:
        var finished = true
        try:
            finished = task_done(h)
        except ValueError:
            pass               # freed already
        if finished:
            gone.append(h)
    for h in gone:
        del _tasks[h]

async def _forget_when_done(box, body):
    try:
        return await body
    finally:
        if box[0] != 0:
            _tasks.pop(box[0], none)

def _register(t):
    # Tasks are kept here until they are done (the loop holds them, as
    # CPython's does); finished ones are dropped as the table doubles.
    global _prune_at
    if len(_tasks) > _prune_at:
        _forget_done()
        _prune_at = max(512, 2 * len(_tasks))
    _tasks[t._h] = t

def _cancel_handle(h):
    # cancel one of the loop's internal tasks (it may be gone already)
    if h != 0 and h != async_current_task():
        try:
            task_cancel(h)
        except ValueError:
            pass

def _spawn_internal(lo, coro):
    # a task of the loop's own (a transport's reader, a watcher): nothing
    # asks about it once it has finished, so its records go then
    var h = lo._spawn(coro, false)
    async_task_detach(h)
    return h

async def _in_context(ctx, coro):
    # create_task(context=ctx): the task's steps run in ctx, and what they
    # set is seen there afterwards (contextvars.Context.run's rule)
    var prev_obj = thread_local_get("__ny_ctx_obj", none)
    thread_local_set("__ny_ctx_obj", ctx)
    ctx._entered = true
    thread_local_set("__ny_ctx_data", ctx._data)
    try:
        return await coro
    finally:
        ctx._data = thread_local_get("__ny_ctx_data", ctx._data)
        ctx._entered = false

class Task(Future):
    # A coroutine running on the loop: awaitable, cancellable, with a result.
    # create_task() makes one; the loop runs it as one of its native tasks.
    def __init__(self, coro, *, loop=none, name=none, context=none, eager_start=false, _handle=none):
        global _task_count
        if _handle is none and not iscoroutine(coro):
            raise TypeError("a coroutine was expected, got " + repr(coro))
        if loop is none:
            loop = get_event_loop()
        self._loop = loop
        self._coro = coro
        self._context = context
        self._num_cancels_requested = 0
        self._callbacks = []
        self._cb_watch = false
        self._created_at = none
        self._parent = none
        self._children = none
        self._run_main = false
        if name is none:
            _task_count = _task_count + 1
            self._name = "Task-" + str(_task_count)
        else:
            self._name = str(name)
        if _handle is not none:
            self._h = _handle
            _register(self)
            return
        var body = coro
        if context is not none:
            body = _in_context(context, coro)
        if loop._tracking():
            # structured concurrency (debug / orphans=): where it was made,
            # by which task, and a check when it ends
            self._created_at = _caller_site(2)
            var parent = current_task()
            if parent is not none:
                self._parent = parent
                if parent._children is none:
                    parent._children = []
                parent._children.append(self)
            body = _tracked(self, body)
        # the registry lets go of it when its body ends (round 82): a
        # finished task the program dropped is collected, as CPython's,
        # and an error nobody retrieved is reported then
        var box = [0]
        self._h = loop._spawn(_forget_when_done(box, body), eager_start)
        box[0] = self._h
        _register(self)
        if task_done(self._h):
            _tasks.pop(self._h, none)

    def __repr__(self):
        var info = []
        var st = "pending"
        if task_done(self._h):
            st = "finished"
            if task_cancelled(self._h):
                st = "cancelled"
        elif self._num_cancels_requested > 0:
            st = "cancelling"
        info.append(st)
        info.append("name=" + repr(self._name))
        if self._coro is not none:
            info.append("coro=<" + _format_coroutine(self._coro) + ">")
        if st == "finished":
            try:
                var r = task_result(self._h)
                var rr = repr(r)
                if len(rr) > 60:
                    rr = rr[:28] + "..." + rr[len(rr) - 29:]
                info.append("result=" + rr)
            except BaseException as e:
                info.append("exception=" + repr(e))
        return "<" + self.__class__.__name__ + " " + " ".join(info) + ">"

    def __await__(self):
        return self._h

    __iter__ = __await__

    def __del__(self):
        # nothing can ask the runtime about this task any more: its records
        # are freed once it has finished - after reporting an error nobody
        # awaited or asked for (round 82: "Task exception was never
        # retrieved", as CPython's Future.__del__)
        var h = getattr(self, "_h", 0)
        if h:
            if task_error_unseen(h):
                var exc = none
                try:
                    task_result(h)
                except BaseException as e:
                    exc = e
                _report_unretrieved(self, "Task", exc)
            async_task_detach(h)

    def get_coro(self):
        return self._coro

    def get_context(self):
        return self._context

    def get_name(self):
        return self._name

    def set_name(self, value):
        self._name = str(value)

    def get_stack(self, *, limit=none):
        var fr = getattr(self._coro, "cr_frame", none)
        if fr is none:
            return []
        return [fr]

    def print_stack(self, *, limit=none, file=none):
        if file is none:
            file = sys.stderr
        var frames = self.get_stack(limit=limit)
        if len(frames) == 0:
            print("No stack for " + repr(self), file=file)
        else:
            print("Stack for " + repr(self) + " (most recent call last):", file=file)
            for f in frames:
                print("  File \"" + str(f.f_code.co_filename) + "\", line " + str(f.f_lineno) + ", in " + str(f.f_code.co_name), file=file)

    def set_result(self, result):
        raise RuntimeError("Task does not support set_result operation")

    def set_exception(self, exception):
        raise RuntimeError("Task does not support set_exception operation")

    def cancel(self, msg=none):
        # One cancellation request more (cancelling()); the task gets
        # CancelledError(msg) at its current or next wait.
        if task_done(self._h):
            return false
        self._num_cancels_requested = self._num_cancels_requested + 1
        task_cancel(self._h, msg)
        return true

    def cancelling(self):
        return self._num_cancels_requested

    def uncancel(self):
        if self._num_cancels_requested > 0:
            self._num_cancels_requested = self._num_cancels_requested - 1
        return self._num_cancels_requested

    def cancelled(self):
        return task_cancelled(self._h)

    def done(self):
        return task_done(self._h)

    def result(self):
        if not task_done(self._h):
            raise InvalidStateError("Result is not set.")
        return task_result(self._h)

    def exception(self):
        if not task_done(self._h):
            raise InvalidStateError("Exception is not set.")
        if task_cancelled(self._h):
            task_result(self._h)          # raises the CancelledError
        try:
            task_result(self._h)
        except BaseException as e:
            return e
        return none

    def add_done_callback(self, fn, *, context=none):
        self._callbacks.append((fn, context))
        if task_done(self._h):
            self._loop.call_soon(_run_task_callbacks, self)
        elif not self._cb_watch:
            self._cb_watch = true
            _spawn_internal(self._loop, _task_watcher(self))

    def remove_done_callback(self, fn):
        var keep = []
        var n = 0
        for c in self._callbacks:
            if c[0] == fn:
                n = n + 1
            else:
                keep.append(c)
        self._callbacks = keep
        return n

def _run_task_callbacks(t):
    var cbs = t._callbacks
    t._callbacks = []
    for c in cbs:
        Handle(c[0], (t,), t._loop, c[1])._run()

async def _task_watcher(t):
    # the task's done callbacks run once it has finished
    try:
        await t._h
    except BaseException:
        pass
    t._cb_watch = false
    _run_task_callbacks(t)

async def _tracked(t, body):
    try:
        return await body
    finally:
        var kids = t._children
        # a run's main task: what it leaves is reported when the run ends
        if kids is not none and not t._run_main:
            for k in kids:
                if not task_done(k._h):
                    t._loop._report_orphan(k, "outlived the task that created it (" + t._name + ")")

class _GatheringFuture(Task):
    # gather()'s result: a task over the runtime's gather; cancel() cancels
    # the children.
    pass

def _wrap(h, name=none, coro=none):
    var t = _tasks.get(h)
    if t is none:
        t = Task(coro, loop=_get_running_loop() or get_event_loop(), name=name, _handle=h)
    return t

def create_task(coro, *, name=none, context=none):
    var lo = get_running_loop()
    return lo.create_task(coro, name=name, context=context)

def ensure_future(coro_or_future, *, loop=none):
    if isinstance(coro_or_future, Future):
        if loop is not none and loop is not coro_or_future._loop:
            raise ValueError("The future belongs to a different loop than the one specified as the loop argument")
        return coro_or_future
    var should_close = true
    if iscoroutine(coro_or_future):
        if loop is none:
            loop = get_event_loop()
        return loop.create_task(coro_or_future)
    if isfuture(coro_or_future):
        return coro_or_future
    if hasattr(coro_or_future, "__await__"):
        if loop is none:
            loop = get_event_loop()
        return loop.create_task(_wrap_awaitable(coro_or_future))
    raise TypeError("An asyncio.Future, a coroutine or an awaitable is required")

async def _wrap_awaitable(aw):
    return await aw

def current_task(loop=none):
    # none in a loop callback or the loop's own machinery (a transport's
    # reader calling the protocol), as CPython's callbacks
    var h = async_current_task_user()
    if h == 0 or h == _cb_task:
        return none
    if loop is not none and _get_running_loop() is not loop:
        return none
    return _wrap(h)

def all_tasks(loop=none):
    if loop is none:
        loop = get_running_loop()
    var out = set()
    for h in list(_tasks.keys()):
        var t = _tasks.get(h)
        if t is not none and t._loop is loop:
            try:
                if not task_done(h):
                    out.add(t)
            except ValueError:
                pass
    return out

def _eager_task(loop, coro, *, name=none, context=none):
    return Task(coro, loop=loop, name=name, context=context, eager_start=true)

def eager_task_factory(loop, coro, *, name=none, context=none):
    # 3.12: the task starts running in create_task(), until its first wait;
    # one that finishes without waiting is done before create_task returns.
    return Task(coro, loop=loop, name=name, context=context, eager_start=true)

def create_eager_task_factory(custom_task_constructor):
    def factory(loop, coro, *, name=none, context=none):
        return custom_task_constructor(coro, loop=loop, name=name, context=context, eager_start=true)
    return factory

async def sleep(delay, result=none):
    # a coroutine, as Python's (round 78: coroutine objects are objects now,
    # not the runtime's int handles)
    await async_sleep(delay)
    return result

def gather(*aws, return_exceptions=false):
    # A future over the awaitables' results, in their order; cancelling it
    # cancels them.
    var lo = _get_running_loop()
    if lo is none:
        # the loop of the first future given, as CPython's gather
        for a in aws:
            if isfuture(a) and getattr(a, "_loop", none) is not none:
                lo = a._loop
                break
    if lo is none:
        lo = get_event_loop()
    if len(aws) == 0:
        var outer = lo.create_future()
        outer.set_result([])
        return outer
    var h = none
    if return_exceptions:
        h = gather_settled(*aws)
    else:
        h = async_gather(*aws)
    return _GatheringFuture(none, loop=lo, _handle=lo._spawn(h, false))

async def wait_for(fut, timeout):
    # 3.12: an `async with timeout(...)` around the await - the awaitable is
    # cancelled at the deadline and TimeoutError raised from its
    # CancelledError; cancelling the caller cancels it too.
    if timeout is not none and timeout <= 0:
        fut = ensure_future(fut)
        if fut.done():
            return fut.result()
        await _cancel_and_wait(fut)
        try:
            return fut.result()
        except CancelledError as exc:
            raise TimeoutError() from exc
    async with Timeout(none if timeout is none else _now() + timeout):
        return await fut

async def _cancel_and_wait(fut):
    var ev = Event()
    fut.add_done_callback(lambda _f: ev.set())
    fut.cancel()
    await ev.wait()

async def wait(fs, *, timeout=none, return_when=ALL_COMPLETED):
    if isfuture(fs) or iscoroutine(fs):
        raise TypeError("expect a list of futures, not " + type(fs).__name__)
    var items = list(fs)
    if len(items) == 0:
        raise ValueError("Set of Tasks/Futures is empty.")
    if return_when != FIRST_COMPLETED and return_when != FIRST_EXCEPTION and return_when != ALL_COMPLETED:
        raise ValueError("Invalid return_when value: " + str(return_when))
    # 3.11+: coroutines are refused (round 82; they were wrapped in tasks)
    for a in items:
        if iscoroutine(a):
            raise TypeError("Passing coroutines is forbidden, use tasks explicitly.")
    var tasks = [ensure_future(a) for a in set(items)]
    var ev = Event()
    def check(_t=none):
        var n_done = 0
        for t in tasks:
            if t.done():
                n_done = n_done + 1
                if return_when == FIRST_COMPLETED:
                    ev.set()
                    return
                if return_when == FIRST_EXCEPTION and not t.cancelled() and t.exception() is not none:
                    ev.set()
                    return
        if n_done == len(tasks):
            ev.set()
    check()
    if not ev.is_set():
        for t in tasks:
            if not t.done():
                t.add_done_callback(check)
        try:
            if timeout is none:
                await ev.wait()
            else:
                await async_wait_for(ev.wait(), timeout)
        except TimeoutError:
            pass
        for t in tasks:
            t.remove_done_callback(check)
    var done = set()
    var pending = set()
    for t in tasks:
        if t.done():
            done.add(t)
        else:
            pending.add(t)
    return (done, pending)

def as_completed(fs, *, timeout=none):
    # The awaitables in the order they finish: each item awaits to the next
    # result (or raises its error / TimeoutError past the deadline).
    if isfuture(fs) or iscoroutine(fs):
        raise TypeError("expect an iterable of futures, not " + type(fs).__name__)
    var tasks = [ensure_future(a) for a in set(fs)] if isinstance(fs, set) else [ensure_future(a) for a in fs]
    var q = Queue()
    for t in tasks:
        t.add_done_callback(q.put_nowait)
    var deadline = none
    if timeout is not none:
        deadline = _now() + timeout
    return [_next_done(q, deadline) for t in tasks]

async def _next_done(q, deadline):
    var t = none
    if deadline is none:
        t = await q.get()
    else:
        var left = deadline - _now()
        if left <= 0:
            raise TimeoutError()
        try:
            t = await async_wait_for(q.get(), left)
        except TimeoutError:
            raise TimeoutError() from none
    return t.result()

def shield(arg):
    # Cancelling the awaiting task does not cancel arg.
    var inner = ensure_future(arg)
    if inner.done():
        return inner
    var lo = inner._loop
    var outer = lo.create_future()
    def _inner_done_callback(inn):
        if outer.cancelled():
            if not inn.cancelled():
                inn.exception()
            return
        if inn.cancelled():
            outer.cancel()
        else:
            var exc = inn.exception()
            if exc is not none:
                outer.set_exception(exc)
            else:
                outer.set_result(inn.result())
    def _outer_done_callback(out):
        if not inner.done():
            inner.remove_done_callback(_inner_done_callback)
    inner.add_done_callback(_inner_done_callback)
    outer.add_done_callback(_outer_done_callback)
    return outer

async def race(*aws):
    # The result of the first awaitable to finish (or its error); the others
    # are cancelled.
    var tasks = [ensure_future(a) for a in aws]
    if len(tasks) == 0:
        raise ValueError("race() needs at least one awaitable")
    var r = await wait(tasks, return_when=FIRST_COMPLETED)
    var winner = none
    for t in tasks:
        if t.done() and winner is none:
            winner = t
    for t in tasks:
        if not t.done():
            t.cancel()
    return winner.result()

async def map_bounded(fn, items, limit=8):
    # [await fn(x) for x in items] with at most `limit` running at once.
    var sem = Semaphore(limit)
    async def one(x):
        async with sem:
            return await fn(x)
    return await async_gather(*[one(x) for x in items])

async def to_thread(func, *args, **kwargs):
    # func(*args, **kwargs) in the default executor (a thread); awaiting it
    # lets the loop run meanwhile. It runs in a copy of the caller's context.
    var lo = get_running_loop()
    var ctx_data = thread_local_get("__ny_ctx_data", none)
    def in_context():
        if ctx_data is not none:
            thread_local_set("__ny_ctx_data", ctx_data)
        return func(*args, **kwargs)
    return await lo.run_in_executor(none, in_context)

def run_coroutine_threadsafe(coro, loop):
    # From another thread: run coro on the loop; returns a
    # concurrent-style future (result(timeout) blocks that thread).
    if not iscoroutine(coro):
        raise TypeError("A coroutine object is required")
    var fut = _ThreadFuture()
    def callback():
        try:
            _chain_future(ensure_future(coro, loop=loop), fut)
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            if fut.set_running_or_notify_cancel():
                fut.set_exception(exc)
            raise
    loop.call_soon_threadsafe(callback)
    return fut

_tf_lock = mutex_create()     # one for every _ThreadFuture

class _ThreadFuture:
    # concurrent.futures.Future's surface (result(timeout), exception,
    # done, cancel, add_done_callback), safe to complete from any thread
    def __init__(self):
        self._ev = none
        self._lock = _tf_lock
        self._state = "PENDING"
        self._result = none
        self._exc = none
        self._cbs = []
        self._waiters = 0

    def __repr__(self):
        return "<Future at 0x" + format(id(self), "x") + " state=" + string_lower(self._state) + ">"

    def _wait(self, timeout):
        mutex_lock(self._lock)
        if self._state == "FINISHED" or self._state == "CANCELLED":
            mutex_unlock(self._lock)
            return
        if self._ev is none:
            self._ev = _ev_get()
        var ev = self._ev
        self._waiters = self._waiters + 1
        mutex_unlock(self._lock)
        var ok = true
        try:
            if timeout is none:
                event_wait(ev)
            else:
                ok = event_wait_timeout(ev, timeout * 1000)
        finally:
            mutex_lock(self._lock)
            self._waiters = self._waiters - 1
            var give_back = self._waiters == 0 and self.done() and self._ev is not none
            if give_back:
                self._ev = none
            mutex_unlock(self._lock)
            if give_back:
                _ev_put(ev)
        if not ok:
            raise TimeoutError()

    def result(self, timeout=none):
        self._wait(timeout)
        if self._state == "CANCELLED":
            raise CancelledError()
        if self._exc is not none:
            raise self._exc
        return self._result

    def exception(self, timeout=none):
        self._wait(timeout)
        if self._state == "CANCELLED":
            raise CancelledError()
        return self._exc

    def done(self):
        return self._state == "FINISHED" or self._state == "CANCELLED"

    def running(self):
        return self._state == "RUNNING"

    def cancelled(self):
        return self._state == "CANCELLED"

    def cancel(self):
        mutex_lock(self._lock)
        if self._state == "RUNNING" or self._state == "FINISHED":
            mutex_unlock(self._lock)
            return false
        if self._state == "CANCELLED":
            mutex_unlock(self._lock)
            return true
        self._state = "CANCELLED"
        var ev = self._ev
        mutex_unlock(self._lock)
        if ev is not none:
            event_set(ev)
        self._fire()
        return true

    def set_running_or_notify_cancel(self):
        mutex_lock(self._lock)
        var ok = self._state != "CANCELLED"
        if ok:
            self._state = "RUNNING"
        mutex_unlock(self._lock)
        return ok

    def _finish(self, result, exc):
        mutex_lock(self._lock)
        if self._state == "FINISHED" or self._state == "CANCELLED":
            mutex_unlock(self._lock)
            raise InvalidStateError(self._state + ": " + repr(self))
        self._result = result
        self._exc = exc
        self._state = "FINISHED"
        var ev = self._ev
        mutex_unlock(self._lock)
        if ev is not none:
            event_set(ev)
        self._fire()

    def set_result(self, result):
        self._finish(result, none)

    def set_exception(self, exception):
        self._finish(none, exception)

    def add_done_callback(self, fn):
        mutex_lock(self._lock)
        if not self.done():
            self._cbs.append(fn)
            mutex_unlock(self._lock)
            return
        mutex_unlock(self._lock)
        try:
            fn(self)
        except Exception:
            pass

    def _fire(self):
        mutex_lock(self._lock)
        var cbs = self._cbs
        self._cbs = []
        mutex_unlock(self._lock)
        for fn in cbs:
            try:
                fn(self)
            except Exception:
                pass

# ─── Timeouts ───────────────────────────────────────────────────────────────

class Timeout:
    # async with asyncio.timeout(1.5): ... - the block is cancelled when the
    # deadline passes, and the cancellation leaves it as TimeoutError
    # (3.12's asyncio.timeouts, with cancelling()/uncancel() so an outer
    # cancellation is not mistaken for the timeout).
    def __init__(self, when):
        self._state = "created"
        self._timeout_handler = none
        self._task = none
        self._when = when
        self._cancelling = 0

    def when(self):
        return self._when

    def reschedule(self, when):
        if self._state != "active":
            if self._state == "created":
                raise RuntimeError("Timeout has not been entered")
            raise RuntimeError("Cannot change state of " + self._state + " Timeout")
        self._when = when
        if self._timeout_handler is not none:
            self._timeout_handler.cancel()
        if when is none:
            self._timeout_handler = none
        else:
            var lo = get_running_loop()
            if when <= lo.time():
                self._timeout_handler = lo.call_soon(self._on_timeout)
            else:
                self._timeout_handler = lo.call_at(when, self._on_timeout)

    def expired(self):
        return self._state == "expiring" or self._state == "expired"

    def __repr__(self):
        var info = ""
        if self._state == "active":
            var w = none if self._when is none else round(self._when, 3)
            info = " when=" + str(w)
        return "<Timeout [" + self._state + "]" + info + ">"

    async def __aenter__(self):
        if self._state != "created":
            raise RuntimeError("Timeout has already been entered")
        var task = current_task()
        if task is none:
            raise RuntimeError("Timeout should be used inside a task")
        self._state = "active"
        self._task = task
        self._cancelling = task.cancelling()
        self.reschedule(self._when)
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self._timeout_handler is not none:
            self._timeout_handler.cancel()
            self._timeout_handler = none
        if self._state == "expiring":
            self._state = "expired"
            if self._task.uncancel() <= self._cancelling and exc_type is not none:
                if issubclass(exc_type, CancelledError):
                    raise TimeoutError() from exc_val
        elif self._state == "active":
            self._state = "finished"
        return none

    def _on_timeout(self):
        self._task.cancel()
        self._state = "expiring"
        self._timeout_handler = none

def timeout(delay):
    var lo = get_running_loop()
    return Timeout(none if delay is none else lo.time() + delay)

def timeout_at(when):
    return Timeout(when)

# ─── Task groups ────────────────────────────────────────────────────────────

class TaskGroup:
    # async with asyncio.TaskGroup() as tg: tg.create_task(...) - the block
    # ends when every child has; the first child to fail cancels the others
    # and the block.
    def __init__(self):
        self._tasks = []
        self._errors = []
        self._base_error = none   # a child's SystemExit/KeyboardInterrupt, raised as itself
        self._parent = none
        self._loop = none
        self._in_body = false
        self._parent_cancel_requested = false
        self._entered = false
        self._closed = false

    def __repr__(self):
        var info = []
        if len(self._tasks) > 0:
            info.append("tasks=" + str(len(self._tasks)))
        if len(self._errors) > 0:
            info.append("errors=" + str(len(self._errors)))
        if self._parent_cancel_requested:
            info.append("cancelling")
        elif self._entered:
            info.append("entered")
        return "<TaskGroup" + ("" if len(info) == 0 else " " + " ".join(info)) + ">"

    async def __aenter__(self):
        if self._entered:
            raise RuntimeError("TaskGroup " + repr(self) + " has already been entered")
        self._entered = true
        self._loop = get_running_loop()
        self._parent = current_task()
        if self._parent is none:
            raise RuntimeError("TaskGroup " + repr(self) + " cannot determine the parent task")
        self._in_body = true
        return self

    def create_task(self, coro, *, name=none, context=none):
        if not self._entered:
            raise RuntimeError("TaskGroup " + repr(self) + " has not been entered")
        if self._closed:
            raise RuntimeError("TaskGroup " + repr(self) + " is finished")
        var t = self._loop.create_task(_tg_child(self, coro), name=name, context=context)
        self._tasks.append(t)
        return t

    def _abort(self):
        for t in self._tasks:
            if not t.done():
                t.cancel()
        if self._in_body and not self._parent_cancel_requested:
            self._parent_cancel_requested = true
            self._parent.cancel()

    async def __aexit__(self, et, ev, tb):
        self._in_body = false
        var body_error = none
        var propagate_cancel = none
        if et is not none and issubclass(et, CancelledError):
            if not self._parent_cancel_requested:
                propagate_cancel = ev
            self._abort()
        elif et is not none:
            body_error = ev
            if self._base_error is none and isinstance(ev, (SystemExit, KeyboardInterrupt)):
                self._base_error = ev
            self._abort()
        var i = 0
        while i < len(self._tasks):
            var t = self._tasks[i]
            if not t.done():
                try:
                    await t
                except BaseException:
                    pass
            i = i + 1
        self._closed = true
        if self._parent_cancel_requested:
            self._parent.uncancel()
        # CPython 3.11+: a child's SystemExit/KeyboardInterrupt as itself;
        # otherwise every error - the children's in the order they failed,
        # then the body's - in one group, even a single one (round 82: one
        # failure was raised bare, the body's error first)
        if self._base_error is not none:
            raise self._base_error
        if propagate_cancel is not none and len(self._errors) == 0:
            raise propagate_cancel
        var errs = list(self._errors)
        if body_error is not none:
            errs.append(body_error)
        if len(errs) > 0:
            raise BaseExceptionGroup("unhandled errors in a TaskGroup", errs)
        if self._parent_cancel_requested and et is not none and issubclass(et, CancelledError):
            return true
        return false

async def _tg_child(group, coro):
    try:
        return await coro
    except CancelledError:
        raise
    except BaseException as e:
        group._errors.append(e)
        if group._base_error is none and isinstance(e, (SystemExit, KeyboardInterrupt)):
            group._base_error = e
        # the abort runs from the loop, after the tasks already ready in
        # this step (CPython aborts from the child's done callback): two
        # children failing in one step both report their errors (round 82)
        group._loop.call_soon(group._abort)
        raise

# ─── Synchronisation ────────────────────────────────────────────────────────

class Event:
    def __init__(self):
        self._id = event_create()

    def __del__(self):
        # its native object goes with it (round 82: kept for the process)
        _free_native(getattr(self, "_id", 0))

    def __repr__(self):
        return "<asyncio.locks.Event object [" + ("set" if self.is_set() else "unset") + "]>"

    def is_set(self):
        return event_is_set(self._id)

    def set(self):
        event_set(self._id)

    def clear(self):
        event_clear(self._id)

    async def wait(self):
        event_wait(self._id)
        return true

class Lock:
    # Not reentrant, no owner: any task may release it (as in Python).
    def __init__(self):
        self._sem = semaphore_create(1, 1)

    def __del__(self):
        # its native object goes with it (round 82: kept for the process)
        _free_native(getattr(self, "_sem", 0))

    def __repr__(self):
        return "<asyncio.locks.Lock object [" + ("locked" if self.locked() else "unlocked") + "]>"

    def locked(self):
        return semaphore_value(self._sem) == 0

    async def acquire(self):
        semaphore_acquire(self._sem)
        return true

    def release(self):
        if semaphore_value(self._sem) != 0:
            raise RuntimeError("Lock is not acquired.")
        semaphore_release(self._sem)

    async def __aenter__(self):
        semaphore_acquire(self._sem)
        return none

    async def __aexit__(self, et, ev, tb):
        self.release()
        return false

class Semaphore:
    def __init__(self, value=1):
        if value < 0:
            raise ValueError("Semaphore initial value must be >= 0")
        self._sem = semaphore_create(value)

    def __del__(self):
        # its native object goes with it (round 82: kept for the process)
        _free_native(getattr(self, "_sem", 0))

    def locked(self):
        return semaphore_value(self._sem) == 0

    async def acquire(self):
        semaphore_acquire(self._sem)
        return true

    def release(self):
        semaphore_release(self._sem)

    async def __aenter__(self):
        semaphore_acquire(self._sem)
        return none

    async def __aexit__(self, et, ev, tb):
        self.release()
        return false

class BoundedSemaphore(Semaphore):
    def __init__(self, value=1):
        if value < 0:
            raise ValueError("Semaphore initial value must be >= 0")
        self._sem = semaphore_create(value, value)

    def release(self):
        if not semaphore_release(self._sem):
            raise ValueError("BoundedSemaphore released too many times")

class Condition:
    def __init__(self, lock=none):
        if lock is none:
            lock = Lock()
        self._lock = lock
        self._waiters = []

    def locked(self):
        return self._lock.locked()

    async def acquire(self):
        return await self._lock.acquire()

    def release(self):
        self._lock.release()

    async def __aenter__(self):
        await self._lock.acquire()
        return none

    async def __aexit__(self, et, ev, tb):
        self._lock.release()
        return false

    async def wait(self):
        if not self.locked():
            raise RuntimeError("cannot wait on un-acquired lock")
        var ev = Event()
        self._waiters.append(ev)
        self.release()
        try:
            await ev.wait()
        finally:
            # back under the lock, even when cancelled
            var again = true
            while again:
                try:
                    await self._lock.acquire()
                    again = false
                except CancelledError:
                    pass
            var keep = []
            for w in self._waiters:
                if w is not ev:
                    keep.append(w)
            self._waiters = keep
        return true

    async def wait_for(self, predicate):
        var r = predicate()
        while not r:
            await self.wait()
            r = predicate()
        return r

    def notify(self, n=1):
        if not self.locked():
            raise RuntimeError("cannot notify on un-acquired lock")
        var k = 0
        while k < n and len(self._waiters) > 0:
            var ev = self._waiters.pop(0)
            ev.set()
            k = k + 1

    def notify_all(self):
        self.notify(len(self._waiters))

class Barrier:
    # parties tasks call wait(); all return together, each with its index
    # (3.11's state machine: filling, draining, resetting, broken).
    def __init__(self, parties):
        if parties < 1:
            raise ValueError("parties must be > 0")
        self._cond = Condition()
        self._parties = parties
        self._state = "filling"
        self._count = 0

    def __repr__(self):
        var extra = self._state
        if not self.broken:
            extra = extra + ", waiters:" + str(self.n_waiting) + "/" + str(self.parties)
        return "<asyncio.locks.Barrier object [" + extra + "]>"

    async def __aenter__(self):
        return await self.wait()

    async def __aexit__(self, *args):
        pass

    async def wait(self):
        async with self._cond:
            await self._block()
            try:
                var index = self._count
                self._count = self._count + 1
                if index + 1 == self._parties:
                    await self._release()
                else:
                    await self._wait()
                return index
            finally:
                self._count = self._count - 1
                self._exit()

    async def _block(self):
        await self._cond.wait_for(lambda: self._state != "draining" and self._state != "resetting")
        if self._state == "broken":
            raise BrokenBarrierError("Barrier aborted")

    async def _release(self):
        self._state = "draining"
        self._cond.notify_all()

    async def _wait(self):
        await self._cond.wait_for(lambda: self._state != "filling")
        if self._state == "broken" or self._state == "resetting":
            raise BrokenBarrierError("Abort or reset of barrier")

    def _exit(self):
        if self._count == 0:
            if self._state == "resetting" or self._state == "draining":
                self._state = "filling"
            self._cond.notify_all()

    async def reset(self):
        async with self._cond:
            if self._count > 0:
                if self._state != "resetting":
                    self._state = "resetting"
            else:
                self._state = "filling"
            self._cond.notify_all()

    async def abort(self):
        async with self._cond:
            self._state = "broken"
            self._cond.notify_all()

    @property
    def parties(self):
        return self._parties

    @property
    def n_waiting(self):
        if self._state == "filling":
            return self._count
        return 0

    @property
    def broken(self):
        return self._state == "broken"

# ─── Queues ─────────────────────────────────────────────────────────────────

class Queue:
    # put()/get() wait (park the task) when the queue is full/empty;
    # task_done()/join() count the items consumers have finished;
    # shutdown() (3.13) ends it: put raises QueueShutDown, get once empty.
    def __init__(self, maxsize=0):
        self._maxsize = maxsize
        self._q = queue_create(maxsize, self._kind())
        self._unfinished = 0
        self._all_done = Event()
        self._all_done.set()
        self._shutdown = false

    def __del__(self):
        # its native object goes with it (round 82: kept for the process)
        _free_native(getattr(self, "_q", 0))

    def _format(self):
        var s = "maxsize=" + repr(self._maxsize)
        if self._unfinished > 0:
            s = s + " tasks=" + str(self._unfinished)
        if self._shutdown:
            s = s + " shutdown"
        return s

    def __repr__(self):
        return "<" + type(self).__name__ + " at 0x" + format(id(self), "x") + " " + self._format() + ">"

    def __str__(self):
        return "<" + type(self).__name__ + " " + self._format() + ">"

    @property
    def maxsize(self):
        return self._maxsize

    def _kind(self):
        return "fifo"

    def _prep(self, item):
        return item

    def _unprep(self, item):
        return item

    def qsize(self):
        return queue_size(self._q)

    def empty(self):
        return queue_empty(self._q)

    def full(self):
        return self._maxsize > 0 and queue_size(self._q) >= self._maxsize

    def _count_in(self):
        self._unfinished = self._unfinished + 1
        self._all_done.clear()

    async def put(self, item):
        if self._shutdown:
            raise QueueShutDown()
        try:
            queue_put(self._q, self._prep(item))
        except ChannelClosedError:
            raise QueueShutDown() from none
        self._count_in()

    def put_nowait(self, item):
        if self._shutdown:
            raise QueueShutDown()
        if not queue_try_put(self._q, self._prep(item)):
            raise QueueFull()
        self._count_in()

    async def get(self):
        var r = chan_recv_ok(self._q)
        if not r[1]:
            raise QueueShutDown()
        return self._unprep(r[0])

    def get_nowait(self):
        var r = queue_try_get(self._q)
        if not r[1]:
            if self._shutdown:
                raise QueueShutDown()
            raise QueueEmpty()
        return self._unprep(r[0])

    def task_done(self):
        if self._unfinished <= 0:
            raise ValueError("task_done() called too many times")
        self._unfinished = self._unfinished - 1
        if self._unfinished == 0:
            self._all_done.set()

    async def join(self):
        if self._unfinished > 0:
            await self._all_done.wait()

    def shutdown(self, immediate=false):
        # Waiting getters are woken (QueueShutDown once the queue is empty),
        # waiting putters raise; immediate=True also drops what is queued.
        self._shutdown = true
        if immediate:
            var r = queue_try_get(self._q)
            while r[1]:
                if self._unfinished > 0:
                    self.task_done()
                r = queue_try_get(self._q)
        queue_close(self._q)

class LifoQueue(Queue):
    def _kind(self):
        return "lifo"

class PriorityQueue(Queue):
    # Items are compared as they are: (priority, data) tuples, numbers, ...
    def _kind(self):
        return "priority"

    def _prep(self, item):
        if isinstance(item, tuple) or isinstance(item, list):
            return [item[0], item]
        return [item, item]

    def _unprep(self, entry):
        return entry[1]

# ─── Protocols (CPython's asyncio.protocols) ────────────────────────────────

class BaseProtocol:
    # connection_made(transport) / connection_lost(exc); pause_writing() /
    # resume_writing() when the transport's write buffer passes its marks.
    def connection_made(self, transport):
        pass

    def connection_lost(self, exc):
        pass

    def pause_writing(self):
        pass

    def resume_writing(self):
        pass

class Protocol(BaseProtocol):
    # data_received(data) for each chunk; eof_received() at the peer's
    # end of stream (a true result keeps the connection half-open).
    def data_received(self, data):
        pass

    def eof_received(self):
        pass

class BufferedProtocol(BaseProtocol):
    # get_buffer(sizehint) gives the buffer the transport reads into,
    # buffer_updated(nbytes) says how much it put there.
    def get_buffer(self, sizehint):
        pass

    def buffer_updated(self, nbytes):
        pass

    def eof_received(self):
        pass

class DatagramProtocol(BaseProtocol):
    def datagram_received(self, data, addr):
        pass

    def error_received(self, exc):
        pass

class SubprocessProtocol(BaseProtocol):
    def pipe_data_received(self, fd, data):
        pass

    def pipe_connection_lost(self, fd, exc):
        pass

    def process_exited(self):
        pass

# ─── Transports (CPython's asyncio.transports) ──────────────────────────────

class BaseTransport:
    def __init__(self, extra=none):
        if extra is none:
            extra = {}
        self._extra = extra

    def get_extra_info(self, name, default=none):
        return self._extra.get(name, default)

    def is_closing(self):
        raise NotImplementedError

    def close(self):
        raise NotImplementedError

    def set_protocol(self, protocol):
        raise NotImplementedError

    def get_protocol(self):
        raise NotImplementedError

class ReadTransport(BaseTransport):
    def is_reading(self):
        raise NotImplementedError

    def pause_reading(self):
        raise NotImplementedError

    def resume_reading(self):
        raise NotImplementedError

class WriteTransport(BaseTransport):
    def set_write_buffer_limits(self, high=none, low=none):
        raise NotImplementedError

    def get_write_buffer_size(self):
        raise NotImplementedError

    def get_write_buffer_limits(self):
        raise NotImplementedError

    def write(self, data):
        raise NotImplementedError

    def writelines(self, list_of_data):
        self.write(b"".join([bytes(d) for d in list_of_data]))

    def write_eof(self):
        raise NotImplementedError

    def can_write_eof(self):
        raise NotImplementedError

    def abort(self):
        raise NotImplementedError

class Transport(ReadTransport, WriteTransport):
    pass

class DatagramTransport(BaseTransport):
    def sendto(self, data, addr=none):
        raise NotImplementedError

    def abort(self):
        raise NotImplementedError

class SubprocessTransport(BaseTransport):
    def get_pid(self):
        raise NotImplementedError

    def get_returncode(self):
        raise NotImplementedError

    def get_pipe_transport(self, fd):
        raise NotImplementedError

    def send_signal(self, signal):
        raise NotImplementedError

    def terminate(self):
        raise NotImplementedError

    def kill(self):
        raise NotImplementedError

class _FlowControlMixin(Transport):
    # The write side's flow control: the protocol is paused above the high
    # water mark (64 KB by default) and resumed at or below the low one.
    def __init__(self, extra=none, loop=none):
        super().__init__(extra)
        self._loop = loop
        self._protocol_paused = false
        self._set_write_buffer_limits()

    def _maybe_pause_protocol(self):
        var size = self.get_write_buffer_size()
        if size <= self._high_water:
            return
        if not self._protocol_paused:
            self._protocol_paused = true
            try:
                self._protocol.pause_writing()
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException as exc:
                self._loop.call_exception_handler({"message": "protocol.pause_writing() failed", "exception": exc,
                                                   "transport": self, "protocol": self._protocol})

    def _maybe_resume_protocol(self):
        if self._protocol_paused and self.get_write_buffer_size() <= self._low_water:
            self._protocol_paused = false
            try:
                self._protocol.resume_writing()
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException as exc:
                self._loop.call_exception_handler({"message": "protocol.resume_writing() failed", "exception": exc,
                                                   "transport": self, "protocol": self._protocol})

    def get_write_buffer_limits(self):
        return (self._low_water, self._high_water)

    def _set_write_buffer_limits(self, high=none, low=none):
        if high is none:
            if low is none:
                high = 64 * 1024
            else:
                high = 4 * low
        if low is none:
            low = high // 4
        if not (high >= low and low >= 0):
            raise ValueError("high (" + repr(high) + ") must be >= low (" + repr(low) + ") must be >= 0")
        self._high_water = high
        self._low_water = low

    def set_write_buffer_limits(self, high=none, low=none):
        self._set_write_buffer_limits(high=high, low=low)
        self._maybe_pause_protocol()

    def get_write_buffer_size(self):
        raise NotImplementedError

def _check_data(data):
    if not (isinstance(data, bytes) or isinstance(data, bytearray) or type(data).__name__ == "memoryview"):
        raise TypeError("data argument must be a bytes-like object, not " + repr(type(data).__name__))

class _SocketTransport(_FlowControlMixin):
    _sendfile_compatible = "fallback"   # loop.sendfile (round 82)
    # A stream socket (TCP, Unix, or TLS over either) driven by the loop: a
    # reader task feeds the protocol, write() sends what the socket takes at
    # once and a writer task the rest.
    max_size = 256 * 1024
    _start_tls_compatible = true

    def __init__(self, loop, sock, protocol, waiter=none, extra=none, server=none, call_connection_made=true):
        super().__init__(extra, loop)
        self._extra["socket"] = sock
        try:
            self._extra["sockname"] = sock.getsockname()
        except OSError:
            self._extra["sockname"] = none
        if "peername" not in self._extra:
            try:
                self._extra["peername"] = sock.getpeername()
            except OSError:
                self._extra["peername"] = none
        self._sock = sock
        self._protocol = none
        self._protocol_connected = false
        self.set_protocol(protocol)
        self._server = server
        self._buffer = bytearray()
        self._conn_lost = 0
        self._closing = false
        self._eof = false
        self._paused = false
        self._read_done = false
        self._reader_h = 0
        self._writer_h = 0
        self._resume_ev = none       # pooled events, while paused / draining for start_tls
        self._flushed_ev = none
        self._detached = false
        self._is_tls = getattr(sock, "context", none) is not none and hasattr(sock, "server_side")
        if self._server is not none:
            self._server._attach()
        try:
            if sock.family != socket.AF_UNIX:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except BaseException:
            pass
        loop.call_soon(self._start, waiter, call_connection_made)

    def __repr__(self):
        var info = [self.__class__.__name__]
        if self._sock is none:
            info.append("closed")
        elif self._closing:
            info.append("closing")
        if self._sock is not none:
            try:
                info.append("fd=" + str(self._sock.fileno()))
            except BaseException:
                pass
            info.append("read=" + ("polling" if self.is_reading() else "idle"))
            info.append("write=<" + ("polling" if len(self._buffer) > 0 else "idle") + ", bufsize=" + str(len(self._buffer)) + ">")
        return "<" + " ".join(info) + ">"

    def _start(self, waiter, call_connection_made):
        # connection_made, then reading, then the waiter (as CPython's
        # three call_soon's: a failing connection_made is reported to the
        # exception handler and the connection still goes on)
        try:
            if not self._conn_lost:
                if call_connection_made:
                    try:
                        self._protocol.connection_made(self)
                    except (SystemExit, KeyboardInterrupt):
                        raise
                    except BaseException as exc:
                        self._loop.call_exception_handler({"message": "Exception in callback " + _callback_name(self._protocol.connection_made) + "()",
                                                           "exception": exc, "transport": self, "protocol": self._protocol})
                if not self._closing:
                    self._reader_h = _spawn_internal(self._loop, self._read_loop())
        finally:
            if waiter is not none:
                _set_result_unless_cancelled(waiter, none)

    def set_protocol(self, protocol):
        self._protocol = protocol
        self._protocol_connected = true

    def get_protocol(self):
        return self._protocol

    def is_closing(self):
        return self._closing

    def is_reading(self):
        return not self.is_closing() and not self._paused and not self._read_done

    def pause_reading(self):
        if not self.is_reading():
            return
        self._paused = true
        if self._resume_ev is none:
            self._resume_ev = _ev_get()
        event_clear(self._resume_ev)
        if self._loop._debug:
            logger.debug("%r pauses reading", self)

    def resume_reading(self):
        if self._closing or not self._paused:
            return
        self._paused = false
        if self._resume_ev is not none:
            event_set(self._resume_ev)
        if self._loop._debug:
            logger.debug("%r resumes reading", self)

    async def _read_loop(self):
        var buffered = isinstance(self._protocol, BufferedProtocol)
        var me = async_current_task()
        try:
            while not self._closing and not self._read_done and not self._detached:
                if self._paused:
                    var rev = self._resume_ev
                    if rev is not none:
                        event_wait(rev)
                    continue
                self._sock.wait_readable()
                if self._paused or self._closing or self._detached:
                    continue
                if buffered:
                    if not self._read_buffered():
                        return
                    continue
                var data = none
                try:
                    data = self._sock.recv(self.max_size)
                except (BlockingIOError, InterruptedError):
                    continue
                except (SystemExit, KeyboardInterrupt):
                    raise
                except CancelledError:
                    raise
                except BaseException as exc:
                    self._fatal_error(exc, "Fatal read error on socket transport")
                    return
                if len(data) == 0:
                    self._read_ready_on_eof()
                    return
                try:
                    self._protocol.data_received(data)
                except (SystemExit, KeyboardInterrupt):
                    raise
                except BaseException as exc:
                    self._fatal_error(exc, "Fatal error: protocol.data_received() call failed.")
                    return
        except CancelledError:
            return
        except (SystemExit, KeyboardInterrupt) as e:
            self._loop._interrupt(e)
        finally:
            if self._reader_h == me:
                self._reader_h = 0

    def _read_buffered(self):
        # BufferedProtocol: read into the protocol's buffer
        var buf = none
        try:
            buf = self._protocol.get_buffer(-1)
            if len(buf) == 0:
                raise RuntimeError("get_buffer() returned an empty buffer")
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            self._fatal_error(exc, "Fatal error: protocol.get_buffer() call failed.")
            return false
        var nbytes = 0
        try:
            nbytes = self._sock.recv_into(buf)
        except (BlockingIOError, InterruptedError):
            return true
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            self._fatal_error(exc, "Fatal read error on socket transport")
            return false
        if nbytes == 0:
            self._read_ready_on_eof()
            return false
        try:
            self._protocol.buffer_updated(nbytes)
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            self._fatal_error(exc, "Fatal error: protocol.buffer_updated() call failed.")
            return false
        return true

    def _read_ready_on_eof(self):
        if self._loop._debug:
            logger.debug("%r received EOF", self)
        var keep_open = none
        try:
            keep_open = self._protocol.eof_received()
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            self._fatal_error(exc, "Fatal error: protocol.eof_received() call failed.")
            return
        if keep_open and not self._is_tls:
            # the protocol may still write; nothing more is read
            self._read_done = true
        else:
            self.close()

    def _stop_reader(self):
        self._read_done = true
        var h = self._reader_h
        self._reader_h = 0
        _cancel_handle(h)

    def _stop_writer(self):
        var h = self._writer_h
        self._writer_h = 0
        _cancel_handle(h)

    def write(self, data):
        _check_data(data)
        if self._eof:
            raise RuntimeError("Cannot call write() after write_eof()")
        if len(data) == 0:
            return
        if self._conn_lost:
            if self._conn_lost >= _LOG_THRESHOLD_FOR_CONNLOST_WRITES:
                logger.warning("socket.send() raised exception.")
            self._conn_lost = self._conn_lost + 1
            return
        if len(self._buffer) == 0:
            # try to send it now
            var n = 0
            try:
                n = self._sock.send(data)
            except (BlockingIOError, InterruptedError):
                n = 0
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException as exc:
                self._fatal_error(exc, "Fatal write error on socket transport")
                return
            if n >= len(data):
                return
            self._buffer.extend(data[n:])
            self._start_writer()
        else:
            self._buffer.extend(data)
        self._maybe_pause_protocol()

    def writelines(self, list_of_data):
        if self._eof:
            raise RuntimeError("Cannot call writelines() after write_eof()")
        for d in list_of_data:
            self.write(d)

    def _flush_done(self):
        if self._flushed_ev is not none:
            event_set(self._flushed_ev)

    def _start_writer(self):
        if self._writer_h == 0:
            self._writer_h = _spawn_internal(self._loop, self._write_loop())

    async def _write_loop(self):
        try:
            while len(self._buffer) > 0 and self._sock is not none:
                self._sock.wait_writable()
                if self._conn_lost or self._sock is none:
                    return
                var n = 0
                try:
                    n = self._sock.send(bytes(self._buffer))
                except (BlockingIOError, InterruptedError):
                    continue
                except (SystemExit, KeyboardInterrupt):
                    raise
                except CancelledError:
                    raise
                except BaseException as exc:
                    self._buffer = bytearray()
                    self._flush_done()
                    self._fatal_error(exc, "Fatal write error on socket transport")
                    return
                if n > 0:
                    del self._buffer[:n]
                self._maybe_resume_protocol()
            self._flush_done()
            if self._closing and not self._detached:
                if not self._conn_lost:
                    self._conn_lost = self._conn_lost + 1
                    self._call_connection_lost(none)
            elif self._eof:
                try:
                    self._sock.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
        except CancelledError:
            return
        finally:
            self._writer_h = 0

    def get_write_buffer_size(self):
        return len(self._buffer)

    def can_write_eof(self):
        return not self._is_tls

    def write_eof(self):
        if self._is_tls:
            raise NotImplementedError("SSL doesn't support half-closes")
        if self._closing or self._eof:
            return
        self._eof = true
        if len(self._buffer) == 0:
            try:
                self._sock.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def close(self):
        if self._closing:
            return
        self._closing = true
        self._stop_reader()
        if len(self._buffer) == 0:
            self._conn_lost = self._conn_lost + 1
            self._loop.call_soon(self._call_connection_lost, none)

    def abort(self):
        self._force_close(none)

    def _fatal_error(self, exc, message="Fatal error on transport"):
        if isinstance(exc, OSError):
            if self._loop._debug:
                logger.debug("%r: %s", self, message, exc_info=true)
        else:
            self._loop.call_exception_handler({"message": message, "exception": exc,
                                               "transport": self, "protocol": self._protocol})
        self._force_close(exc)

    def _force_close(self, exc):
        if self._conn_lost:
            return
        if len(self._buffer) > 0:
            self._buffer = bytearray()
            self._flush_done()
            self._stop_writer()
        if not self._closing:
            self._closing = true
            self._stop_reader()
        self._conn_lost = self._conn_lost + 1
        self._loop.call_soon(self._call_connection_lost, exc)

    def _call_connection_lost(self, exc):
        try:
            if self._protocol_connected:
                self._protocol.connection_lost(exc)
        finally:
            if self._sock is not none:
                if self._is_tls:
                    # close_notify (not waiting for the peer's), so the peer
                    # sees a clean end of stream
                    try:
                        self._sock.unwrap()
                    except BaseException:
                        pass
                try:
                    self._sock.close()
                except OSError:
                    pass
            self._sock = none
            self._protocol = none
            self._release_events()
            var srv = self._server
            if srv is not none:
                srv._detach()
                self._server = none

    def _release_events(self):
        if self._resume_ev is not none:
            var ev = self._resume_ev
            self._resume_ev = none
            if self._reader_h == 0:
                _ev_put(ev)
            else:
                event_set(ev)      # a reader still waiting there goes on (and ends); not pooled

    async def _drain_for_tls(self):
        if len(self._buffer) == 0:
            return
        self._flushed_ev = _ev_get()
        try:
            while len(self._buffer) > 0 and not self._conn_lost:
                event_wait(self._flushed_ev)
                event_clear(self._flushed_ev)
        finally:
            var ev = self._flushed_ev
            self._flushed_ev = none
            _ev_put(ev)

    def _detach_for_tls(self):
        # start_tls: this transport hands its socket over to a TLS one
        self._detached = true
        self._stop_reader()
        self._stop_writer()
        self._closing = true
        self._conn_lost = self._conn_lost + 1
        var srv = self._server
        self._server = none
        return srv

class _DatagramTransport(DatagramTransport, _FlowControlMixin):
    max_size = 256 * 1024

    def __init__(self, loop, sock, protocol, address=none, waiter=none, extra=none):
        _FlowControlMixin.__init__(self, extra, loop)
        self._extra["socket"] = sock
        try:
            self._extra["sockname"] = sock.getsockname()
        except OSError:
            self._extra["sockname"] = none
        try:
            self._extra["peername"] = sock.getpeername()
        except OSError:
            self._extra["peername"] = none
        self._sock = sock
        self._protocol = protocol
        self._address = address
        self._buffer = []
        self._buffer_size = 0
        self._conn_lost = 0
        self._closing = false
        self._reader_h = 0
        self._writer_h = 0
        loop.call_soon(self._start, waiter)

    def __repr__(self):
        return "<_SelectorDatagramTransport" + (" closing" if self._closing else "") + ">"

    def _start(self, waiter):
        try:
            if not self._conn_lost:
                try:
                    self._protocol.connection_made(self)
                except (SystemExit, KeyboardInterrupt):
                    raise
                except BaseException as exc:
                    self._loop.call_exception_handler({"message": "Exception in callback " + _callback_name(self._protocol.connection_made) + "()",
                                                       "exception": exc, "transport": self, "protocol": self._protocol})
                if not self._closing:
                    self._reader_h = _spawn_internal(self._loop, self._read_loop())
        finally:
            if waiter is not none:
                _set_result_unless_cancelled(waiter, none)

    def get_protocol(self):
        return self._protocol

    def set_protocol(self, protocol):
        self._protocol = protocol

    def is_closing(self):
        return self._closing

    def get_write_buffer_size(self):
        return self._buffer_size

    async def _read_loop(self):
        try:
            while not self._closing:
                self._sock.wait_readable()
                if self._closing:
                    return
                var pair = none
                try:
                    pair = self._sock.recvfrom(self.max_size)
                except (BlockingIOError, InterruptedError):
                    continue
                except CancelledError:
                    raise
                except OSError as exc:
                    self._protocol.error_received(exc)
                    continue
                except (SystemExit, KeyboardInterrupt):
                    raise
                except BaseException as exc:
                    self._fatal_error(exc, "Fatal read error on datagram transport")
                    return
                self._protocol.datagram_received(pair[0], pair[1])
        except CancelledError:
            return

    def sendto(self, data, addr=none):
        _check_data(data)
        if self._address:
            if addr is not none and addr != self._address:
                raise ValueError("Invalid address: must be None or " + repr(self._address))
            addr = self._address
        if self._conn_lost and self._address:
            if self._conn_lost >= _LOG_THRESHOLD_FOR_CONNLOST_WRITES:
                logger.warning("socket.send() raised exception.")
            self._conn_lost = self._conn_lost + 1
            return
        if len(self._buffer) == 0:
            try:
                if self._extra["peername"]:
                    self._sock.send(data)
                else:
                    self._sock.sendto(data, addr)
                return
            except (BlockingIOError, InterruptedError):
                pass
            except OSError as exc:
                self._protocol.error_received(exc)
                return
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException as exc:
                self._fatal_error(exc, "Fatal write error on datagram transport")
                return
        self._buffer.append((bytes(data), addr))
        self._buffer_size = self._buffer_size + len(data)
        if self._writer_h == 0:
            self._writer_h = _spawn_internal(self._loop, self._write_loop())
        self._maybe_pause_protocol()

    async def _write_loop(self):
        try:
            while len(self._buffer) > 0 and self._sock is not none:
                self._sock.wait_writable()
                var item = self._buffer[0]
                try:
                    if self._extra["peername"]:
                        self._sock.send(item[0])
                    else:
                        self._sock.sendto(item[0], item[1])
                except (BlockingIOError, InterruptedError):
                    continue
                except CancelledError:
                    raise
                except OSError as exc:
                    self._protocol.error_received(exc)
                    return
                except (SystemExit, KeyboardInterrupt):
                    raise
                except BaseException as exc:
                    self._fatal_error(exc, "Fatal write error on datagram transport")
                    return
                self._buffer.pop(0)
                self._buffer_size = self._buffer_size - len(item[0])
                self._maybe_resume_protocol()
            if self._closing and not self._conn_lost:
                self._conn_lost = self._conn_lost + 1
                self._call_connection_lost(none)
        except CancelledError:
            return
        finally:
            self._writer_h = 0

    def close(self):
        if self._closing:
            return
        self._closing = true
        var h = self._reader_h
        self._reader_h = 0
        _cancel_handle(h)
        if len(self._buffer) == 0:
            self._conn_lost = self._conn_lost + 1
            self._loop.call_soon(self._call_connection_lost, none)

    def abort(self):
        self._force_close(none)

    def _fatal_error(self, exc, message="Fatal error on transport"):
        if not isinstance(exc, OSError):
            self._loop.call_exception_handler({"message": message, "exception": exc,
                                               "transport": self, "protocol": self._protocol})
        self._force_close(exc)

    def _force_close(self, exc):
        if self._conn_lost:
            return
        self._buffer = []
        self._buffer_size = 0
        _cancel_handle(self._writer_h)
        self._writer_h = 0
        if not self._closing:
            self._closing = true
            _cancel_handle(self._reader_h)
            self._reader_h = 0
        self._conn_lost = self._conn_lost + 1
        self._loop.call_soon(self._call_connection_lost, exc)

    def _call_connection_lost(self, exc):
        try:
            self._protocol.connection_lost(exc)
        finally:
            if self._sock is not none:
                self._sock.close()
            self._sock = none

# ─── Servers ────────────────────────────────────────────────────────────────

class AbstractServer:
    def close(self):
        raise NotImplementedError

    def get_loop(self):
        raise NotImplementedError

    def is_serving(self):
        raise NotImplementedError

    async def start_serving(self):
        raise NotImplementedError

    async def serve_forever(self):
        raise NotImplementedError

    async def wait_closed(self):
        raise NotImplementedError

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        self.close()
        await self.wait_closed()

class Server(AbstractServer):
    # Listening sockets accepting connections for a protocol factory
    # (loop.create_server, start_server, start_unix_server).
    def __init__(self, loop, sockets, protocol_factory, ssl_context, backlog, ssl_handshake_timeout, ssl_shutdown_timeout=none):
        self._loop = loop
        self._sockets = sockets
        self._active_count = 0
        self._waiters = []
        self._protocol_factory = protocol_factory
        self._backlog = backlog
        self._ssl_context = ssl_context
        self._ssl_handshake_timeout = ssl_handshake_timeout
        self._ssl_shutdown_timeout = ssl_shutdown_timeout
        self._serving = false
        self._serving_forever_fut = none
        self._accept_tasks = []

    def __repr__(self):
        return "<Server sockets=" + repr(self.sockets) + ">"

    def _attach(self):
        self._active_count = self._active_count + 1

    def _detach(self):
        self._active_count = self._active_count - 1
        if self._active_count == 0 and self._sockets is none:
            self._wakeup()

    def _wakeup(self):
        var waiters = self._waiters
        self._waiters = none
        if waiters is none:
            return
        for w in waiters:
            if not w.done():
                w.set_result(w)

    def _start_serving(self):
        if self._serving:
            return
        self._serving = true
        for s in self._sockets:
            s.listen(self._backlog)
            self._accept_tasks.append(_spawn_internal(self._loop, self._loop._accept_loop(self, s)))

    def get_loop(self):
        return self._loop

    def is_serving(self):
        return self._serving

    @property
    def sockets(self):
        if self._sockets is none:
            return ()
        return tuple(self._sockets)

    def close(self):
        var socks = self._sockets
        if socks is none:
            return
        self._sockets = none
        for h in self._accept_tasks:
            _cancel_handle(h)
        self._accept_tasks = []
        for s in socks:
            try:
                s.close()
            except OSError:
                pass
        self._serving = false
        if self._serving_forever_fut is not none and not self._serving_forever_fut.done():
            self._serving_forever_fut.cancel()
            self._serving_forever_fut = none
        if self._active_count == 0:
            self._wakeup()

    async def start_serving(self):
        self._start_serving()
        await sleep(0)

    async def serve_forever(self):
        if self._serving_forever_fut is not none:
            raise RuntimeError("server " + repr(self) + " is already being awaited on serve_forever()")
        if self._sockets is none:
            raise RuntimeError("server " + repr(self) + " is closed")
        self._start_serving()
        self._serving_forever_fut = self._loop.create_future()
        try:
            await self._serving_forever_fut
        except CancelledError:
            try:
                self.close()
                await self.wait_closed()
            finally:
                raise
        finally:
            self._serving_forever_fut = none

    async def wait_closed(self):
        # until the server is closed and its connections are gone
        if self._waiters is none:
            return
        var waiter = self._loop.create_future()
        self._waiters.append(waiter)
        await waiter

# ─── The event loop ─────────────────────────────────────────────────────────

class AbstractEventLoop:
    # The interface (asyncio.events.AbstractEventLoop); BaseEventLoop is the
    # implementation.
    pass

def _ipaddr_info(host, port):
    # a numeric host needs no resolver
    if host is none or port is none:
        return none
    try:
        socket.inet_pton(socket.AF_INET, host)
        return (socket.AF_INET, (host, port))
    except BaseException:
        pass
    try:
        socket.inet_pton(socket.AF_INET6, host)
        return (socket.AF_INET6, (host, port, 0, 0))
    except BaseException:
        pass
    return none

class BaseEventLoop(AbstractEventLoop):
    slow_callback_duration = 0.1

    def __init__(self):
        self._h = async_loop_new()
        _loops[self._h] = self
        self._closed = false
        self._running = false
        self._thread_id = none
        self._debug = _env_debug()
        self._exception_handler = none
        self._default_executor = none
        self._executor_shutdown_called = false
        self._asyncgens_shutdown_called = false
        self._asyncgens = _ny_weakset()
        self._task_factory = none
        self._signal_handlers = {}
        self._readers = {}
        self._writers = {}
        self._pending_exc = none
        self._orphan_policy = none
        self._orphans = []

    def __repr__(self):
        return "<" + self.__class__.__name__ + " running=" + str(self.is_running()) + " closed=" + str(self.is_closed()) + " debug=" + str(self.get_debug()) + ">"

    # ── internals ──
    def _spawn(self, aw, eager=false):
        # a native task of this loop for aw (a coroutine or awaitable handle)
        if eager and async_current_task() != 0 and async_current_loop() == self._h:
            return async_create_task_eager(aw)
        return async_loop_spawn(self._h, aw)

    def _schedule(self, delay, fn):
        return async_loop_call(self._h, delay, fn)

    def _check_closed(self):
        if self._closed:
            raise RuntimeError("Event loop is closed")

    def _check_running(self):
        if self.is_running():
            raise RuntimeError("This event loop is already running")
        if _get_running_loop() is not none:
            raise RuntimeError("Cannot run the event loop while another loop is running")

    def _interrupt(self, e):
        # a KeyboardInterrupt/SystemExit in a callback: stop the loop, the
        # run_* call raises it
        if self._pending_exc is none:
            self._pending_exc = e
        self.stop()

    def _raise_pending(self):
        var e = self._pending_exc
        if e is not none:
            self._pending_exc = none
            raise e

    def _tracking(self):
        return self._debug or (self._orphan_policy is not none and self._orphan_policy != "ignore")

    def _report_orphan(self, t, why):
        var rep = _OrphanReport(t, why)
        self._orphans.append(rep)
        if self._orphan_policy == "ignore" or self._orphan_policy == "raise":
            return          # "raise": OrphanedTasksError is the report
        var ctx = {"message": "Task " + repr(t.get_name()) + " " + why + " and is still running" + rep.where(), "task": t}
        if t._created_at is not none:
            ctx["source_traceback"] = [t._created_at]
        self.call_exception_handler(ctx)

    def _timer_handle_cancelled(self, handle):
        pass

    # ── running ──
    def _install_agen_hooks(self):
        # while the loop runs, async generators report to it (round 82, as
        # CPython's run_forever): first stepped, they join _asyncgens;
        # collected unfinished, their aclose() is scheduled here
        var old = sys.get_asyncgen_hooks()
        sys.set_asyncgen_hooks(firstiter=self._asyncgen_firstiter_hook, finalizer=self._asyncgen_finalizer_hook)
        return old

    def _asyncgen_firstiter_hook(self, agen):
        if self._asyncgens_shutdown_called:
            import warnings
            warnings.warn("asynchronous generator " + repr(agen) + " was scheduled after loop.shutdown_asyncgens() call",
                          ResourceWarning, source=self)
        self._asyncgens.add(agen)

    def _asyncgen_finalizer_hook(self, agen):
        self._asyncgens.discard(agen)
        if not self.is_closed():
            self.call_soon_threadsafe(self.create_task, agen.aclose())

    def run_forever(self):
        self._check_closed()
        self._check_running()
        var old_hooks = self._install_agen_hooks()
        self._running = true
        self._thread_id = thread_os_id()
        try:
            async_loop_run(self._h, none)
        finally:
            self._running = false
            self._thread_id = none
            sys.set_asyncgen_hooks(*old_hooks)
        self._raise_pending()

    def run_until_complete(self, future):
        self._check_closed()
        self._check_running()
        future = ensure_future(future, loop=self)
        var target = 0
        if isinstance(future, Task) and future._loop is self:
            target = future._h
        else:
            target = self._spawn(_wait_quietly(future), false)
        var old_hooks = self._install_agen_hooks()
        self._running = true
        self._thread_id = thread_os_id()
        try:
            async_loop_run(self._h, target)
        finally:
            self._running = false
            self._thread_id = none
            sys.set_asyncgen_hooks(*old_hooks)
            if not isinstance(future, Task) or future._loop is not self:
                async_task_detach(target)
        self._raise_pending()
        if not future.done():
            raise RuntimeError("Event loop stopped before Future completed.")
        return future.result()

    def stop(self):
        async_loop_stop(self._h)

    def is_running(self):
        return self._running

    def is_closed(self):
        return self._closed

    def close(self):
        if self.is_running():
            raise RuntimeError("Cannot close a running event loop")
        if self._closed:
            return
        if self._debug:
            logger.debug("Close %r", self)
        for sig in list(self._signal_handlers.keys()):
            try:
                self.remove_signal_handler(sig)
            except BaseException:
                pass
        self._closed = true
        var ex = self._default_executor
        self._default_executor = none
        if ex is not none:
            ex.shutdown(wait=false)
        async_loop_close(self._h)
        if self._h in _loops:
            del _loops[self._h]

    def time(self):
        return monotonic()

    def get_debug(self):
        return self._debug

    def set_debug(self, enabled):
        self._debug = bool(enabled)

    # ── callbacks ──
    def _check_callback(self, callback, method):
        if iscoroutine(callback) or iscoroutinefunction(callback):
            raise TypeError("coroutines cannot be used with " + method + "()")
        if not callable(callback):
            raise TypeError("a callable object was expected by " + method + "(), got " + repr(callback))

    def call_soon(self, callback, *args, context=none):
        self._check_closed()
        if self._debug:
            self._check_callback(callback, "call_soon")
        var h = Handle(callback, args, self, context)
        h._h = self._schedule(none, h._run)
        return h

    def call_soon_threadsafe(self, callback, *args, context=none):
        self._check_closed()
        if self._debug:
            self._check_callback(callback, "call_soon_threadsafe")
        var h = Handle(callback, args, self, context)
        h._h = self._schedule(none, h._run)
        return h

    def call_later(self, delay, callback, *args, context=none):
        if delay is none:
            raise TypeError("delay must not be None")
        return self.call_at(self.time() + delay, callback, *args, context=context)

    def call_at(self, when, callback, *args, context=none):
        if when is none:
            raise TypeError("when cannot be None")
        self._check_closed()
        if self._debug:
            self._check_callback(callback, "call_at")
        var th = TimerHandle(when, callback, args, self, context)
        th._h = self._schedule(when - self.time(), th._run)
        th._scheduled = true
        return th

    # ── futures and tasks ──
    def create_future(self):
        return Future(loop=self)

    def create_task(self, coro, *, name=none, context=none):
        self._check_closed()
        if self._task_factory is none:
            return Task(coro, loop=self, name=name, context=context)
        var task = none
        if context is none:
            task = self._task_factory(self, coro)
        else:
            task = self._task_factory(self, coro, context=context)
        if name is not none:
            try:
                task.set_name(name)
            except AttributeError:
                pass
        return task

    def set_task_factory(self, factory):
        if factory is not none and not callable(factory):
            raise TypeError("task factory must be a callable or None")
        self._task_factory = factory

    def get_task_factory(self):
        return self._task_factory

    # ── executors ──
    def run_in_executor(self, executor, func, *args):
        self._check_closed()
        if self._debug:
            self._check_callback(func, "run_in_executor")
        if executor is none:
            executor = self._default_executor
            if self._executor_shutdown_called:
                raise RuntimeError("Executor shutdown has been called")
            if executor is none:
                # CPython's: a thread pool, made on first use (round 82; it
                # was a thread per call)
                import concurrent.futures
                executor = concurrent.futures.ThreadPoolExecutor(thread_name_prefix="asyncio")
                self._default_executor = executor
        return wrap_future(executor.submit(func, *args), loop=self)

    def set_default_executor(self, executor):
        import concurrent.futures
        if not isinstance(executor, concurrent.futures.ThreadPoolExecutor):
            raise TypeError("executor must be ThreadPoolExecutor instance")
        self._default_executor = executor

    async def shutdown_default_executor(self, timeout=none):
        self._executor_shutdown_called = true
        if self._default_executor is none:
            return
        var ex = self._default_executor
        var fut = self.create_future()
        def do_shutdown():
            try:
                ex.shutdown(wait=true)
                if not self.is_closed():
                    self.call_soon_threadsafe(_set_result_unless_cancelled, fut, none)
            except BaseException as e:
                if not self.is_closed() and not fut.cancelled():
                    self.call_soon_threadsafe(fut.set_exception, e)
        var th = thread_create(do_shutdown)
        try:
            if timeout is none:
                await fut
            else:
                await wait_for(shield(fut), timeout)
        except TimeoutError:
            import warnings
            warnings.warn("The executor did not finishing joining its threads within " + str(timeout) + " seconds.", RuntimeWarning, stacklevel=2)
            ex.shutdown(wait=false)
        else:
            thread_join(th)

    async def shutdown_asyncgens(self):
        # every async generator started on this loop and not finished is
        # closed (round 82: it closed nothing)
        self._asyncgens_shutdown_called = true
        if len(self._asyncgens) == 0:
            return
        var closing = list(self._asyncgens)
        self._asyncgens.clear()
        var results = await gather(*[ag.aclose() for ag in closing], return_exceptions=true)
        var i = 0
        while i < len(closing):
            var r = results[i]
            if isinstance(r, Exception):
                self.call_exception_handler({"message": "an error occurred during closing of asynchronous generator " + repr(closing[i]),
                                             "exception": r, "asyncgen": closing[i]})
            i = i + 1

    # ── errors ──
    def get_exception_handler(self):
        return self._exception_handler

    def set_exception_handler(self, handler):
        if handler is not none and not callable(handler):
            raise TypeError("A callable object or None is expected, got " + repr(handler))
        self._exception_handler = handler

    def default_exception_handler(self, context):
        var message = context.get("message")
        if not message:
            message = "Unhandled exception in event loop"
        var exception = context.get("exception")
        var exc_info = false
        if exception is not none:
            exc_info = (type(exception), exception, getattr(exception, "__traceback__", none))
        var lines = [message]
        for key in sorted(context):
            if key == "message" or key == "exception":
                continue
            var value = context[key]
            if key == "source_traceback":
                var tb = ""
                for fr in value:
                    tb = tb + "  File \"" + str(fr[0]) + "\", line " + str(fr[1]) + ", in " + str(fr[2]) + "\n"
                value = "Object created at (most recent call last):\n" + tb.rstrip()
            else:
                value = repr(value)
            lines.append(key + ": " + value)
        logger.error("\n".join(lines), exc_info=exc_info)

    def call_exception_handler(self, context):
        if self._exception_handler is none:
            try:
                self.default_exception_handler(context)
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException:
                print("Exception in default exception handler", file=sys.stderr)
        else:
            try:
                self._exception_handler(self, context)
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException as exc:
                try:
                    self.default_exception_handler({"message": "Unhandled error in exception handler",
                                                    "exception": exc, "context": context})
                except (SystemExit, KeyboardInterrupt):
                    raise
                except BaseException:
                    print("Exception in default exception handler while handling an unexpected error in custom exception handler", file=sys.stderr)

    # ── readers and writers ──
    def _watch_fd(self, table, fd, callback, args, writing):
        var key = fd
        if not isinstance(fd, int):
            key = fd.fileno()
        self._unwatch_fd(table, key)
        var h = Handle(callback, args, self, none)
        var w = _FdWatch(self, fd, h, writing)
        table[key] = w
        w._task = _spawn_internal(self, w._watch())
        return h

    def _unwatch_fd(self, table, fd):
        var key = fd
        if not isinstance(fd, int):
            key = fd.fileno()
        var w = table.get(key)
        if w is none:
            return false
        del table[key]
        w._stop()
        return true

    def add_reader(self, fd, callback, *args):
        self._check_closed()
        self._watch_fd(self._readers, fd, callback, args, false)

    def remove_reader(self, fd):
        if self.is_closed():
            return false
        return self._unwatch_fd(self._readers, fd)

    def add_writer(self, fd, callback, *args):
        self._check_closed()
        self._watch_fd(self._writers, fd, callback, args, true)

    def remove_writer(self, fd):
        if self.is_closed():
            return false
        return self._unwatch_fd(self._writers, fd)

    # ── sendfile (round 82; after CPython's base_events) ──
    def _check_sendfile_params(self, sock, file, offset, count):
        if "b" not in getattr(file, "mode", "b"):
            raise ValueError("file should be opened in binary mode")
        if not sock.type == socket.SOCK_STREAM:
            raise ValueError("only SOCK_STREAM type sockets are supported")
        if count is not none:
            if not isinstance(count, int):
                raise TypeError("count must be a positive integer (got " + repr(count) + ")")
            if count <= 0:
                raise ValueError("count must be a positive integer (got " + repr(count) + ")")
        if not isinstance(offset, int):
            raise TypeError("offset must be a non-negative integer (got " + repr(offset) + ")")
        if offset < 0:
            raise ValueError("offset must be a non-negative integer (got " + repr(offset) + ")")

    async def sock_sendfile(self, sock, file, offset=0, count=none, *, fallback=true):
        # the kernel's os.sendfile where there is one (Linux, macOS), else
        # (or when it is refused) the file read in blocks and sent
        if self._debug and sock.gettimeout() != 0:
            raise ValueError("the socket must be non-blocking")
        self._check_sendfile_params(sock, file, offset, count)
        try:
            return await self._sock_sendfile_native(sock, file, offset, count)
        except SendfileNotAvailableError:
            if not fallback:
                raise
        return await self._sock_sendfile_fallback(sock, file, offset, count)

    async def _sock_sendfile_native(self, sock, file, offset, count):
        if not hasattr(os, "sendfile"):
            raise SendfileNotAvailableError("os.sendfile() is not available")
        var fileno = none
        try:
            fileno = file.fileno()
        except BaseException:
            raise SendfileNotAvailableError("not a regular file")
        var blocksize = 0
        try:
            var size = os.fstat(fileno).st_size
            blocksize = (count if count else size) if size > 0 else 0
        except OSError:
            raise SendfileNotAvailableError("not a regular file")
        if blocksize == 0:
            return 0
        if count:
            blocksize = min(blocksize, count)
        var total_sent = 0
        var pos = offset
        try:
            while true:
                var left = blocksize - total_sent
                if count:
                    left = count - total_sent
                if left <= 0:
                    break
                var sent = 0
                try:
                    sent = os.sendfile(sock.fileno(), fileno, pos, min(left, 0x7fff0000))
                except (BlockingIOError, InterruptedError):
                    sock.wait_writable()
                    continue
                except OSError as exc:
                    if total_sent == 0:
                        # nothing went yet: let the fallback try (EINVAL on
                        # odd files, ENOTSOCK ...), as CPython does
                        raise SendfileNotAvailableError("os.sendfile call failed") from exc
                    raise
                if sent == 0:
                    break
                total_sent = total_sent + sent
                pos = pos + sent
            return total_sent
        finally:
            if total_sent > 0 and hasattr(file, "seek"):
                file.seek(offset + total_sent)

    async def _sock_sendfile_fallback(self, sock, file, offset, count):
        if offset:
            file.seek(offset)
        var blocksize = min(count, 256 * 1024) if count else 256 * 1024
        var total_sent = 0
        try:
            while true:
                if count:
                    blocksize = min(count - total_sent, blocksize)
                    if blocksize <= 0:
                        break
                var data = await self.run_in_executor(none, file.read, blocksize)
                if not data:
                    break
                await self.sock_sendall(sock, data)
                total_sent = total_sent + len(data)
            return total_sent
        finally:
            if total_sent > 0 and hasattr(file, "seek"):
                file.seek(offset + total_sent)

    async def sendfile(self, transport, file, offset=0, count=none, *, fallback=true):
        # through a transport: its write buffer and the protocol's flow
        # control (the fallback CPython uses for every transport but plain
        # sockets with a native sendfile)
        if transport.is_closing():
            raise RuntimeError("Transport is closing")
        var mode = getattr(transport, "_sendfile_compatible", _SENDFILE_UNSUPPORTED)
        if mode == _SENDFILE_UNSUPPORTED:
            raise RuntimeError("sendfile is not supported for transport " + repr(transport))
        if not fallback:
            raise RuntimeError("fallback is disabled and native sendfile is not supported for transport " + repr(transport))
        self._check_sendfile_params(transport.get_extra_info("socket") or _SendfileStreamProbe(), file, offset, count)
        return await self._sendfile_fallback(transport, file, offset, count)

    async def _sendfile_fallback(self, transp, file, offset, count):
        if offset:
            file.seek(offset)
        var blocksize = min(count, 16384) if count else 16384
        var total_sent = 0
        var proto = _SendfileFallbackProtocol(transp)
        try:
            while true:
                if count:
                    blocksize = min(count - total_sent, blocksize)
                    if blocksize <= 0:
                        return total_sent
                var data = await self.run_in_executor(none, file.read, blocksize)
                if not data:
                    return total_sent
                await proto.drain()
                transp.write(data)
                total_sent = total_sent + len(data)
        finally:
            if total_sent > 0 and hasattr(file, "seek"):
                file.seek(offset + total_sent)
            await proto.restore()

    # ── pipes (round 82; after CPython's unix_events) ──
    async def connect_read_pipe(self, protocol_factory, pipe):
        if _WINDOWS:
            raise NotImplementedError("connect_read_pipe is not supported on Windows")
        var protocol = protocol_factory()
        var waiter = self.create_future()
        var transport = _UnixReadPipeTransport(self, pipe, protocol, waiter)
        try:
            await waiter
        except BaseException:
            transport.close()
            raise
        return (transport, protocol)

    async def connect_write_pipe(self, protocol_factory, pipe):
        if _WINDOWS:
            raise NotImplementedError("connect_write_pipe is not supported on Windows")
        var protocol = protocol_factory()
        var waiter = self.create_future()
        var transport = _UnixWritePipeTransport(self, pipe, protocol, waiter)
        try:
            await waiter
        except BaseException:
            transport.close()
            raise
        return (transport, protocol)

    # ── low-level socket operations ──
    async def sock_recv(self, sock, n):
        while true:
            try:
                return sock.recv(n)
            except (BlockingIOError, InterruptedError):
                sock.wait_readable()

    async def sock_recv_into(self, sock, buf):
        while true:
            try:
                return sock.recv_into(buf)
            except (BlockingIOError, InterruptedError):
                sock.wait_readable()

    async def sock_recvfrom(self, sock, bufsize):
        while true:
            try:
                return sock.recvfrom(bufsize)
            except (BlockingIOError, InterruptedError):
                sock.wait_readable()

    async def sock_recvfrom_into(self, sock, buf, nbytes=0):
        if not nbytes:
            nbytes = len(buf)
        var pair = await self.sock_recvfrom(sock, nbytes)
        buf[0:len(pair[0])] = pair[0]
        return (len(pair[0]), pair[1])

    async def sock_sendall(self, sock, data):
        var view = bytes(data)
        var off = 0
        while off < len(view):
            try:
                off = off + sock.send(view[off:])
            except (BlockingIOError, InterruptedError):
                sock.wait_writable()
        return none

    async def sock_sendto(self, sock, data, address):
        while true:
            try:
                return sock.sendto(data, address)
            except (BlockingIOError, InterruptedError):
                sock.wait_writable()

    async def sock_connect(self, sock, address):
        if sock.family == socket.AF_INET or sock.family == socket.AF_INET6:
            var resolved = await self._ensure_resolved(address, sock.family, sock.type, sock.proto)
            address = resolved[0][4]
        var err = sock.connect_ex(address)
        if err == 0:
            return none
        if err not in _CONNECT_PENDING:
            raise _connect_error(err, address)
        while true:
            sock.wait_writable()
            err = sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
            if err == 0:
                return none
            if err not in _CONNECT_PENDING:
                raise _connect_error(err, address)

    async def sock_accept(self, sock):
        while true:
            try:
                var pair = sock.accept()
                pair[0].setblocking(false)
                return pair
            except (BlockingIOError, InterruptedError):
                sock.wait_readable()

    async def getaddrinfo(self, host, port, *, family=0, type=0, proto=0, flags=0):
        return await self.run_in_executor(none, socket.getaddrinfo, host, port, family, type, proto, flags)

    async def getnameinfo(self, sockaddr, flags=0):
        return await self.run_in_executor(none, socket.getnameinfo, sockaddr, flags)

    async def _ensure_resolved(self, address, family=0, type=socket.SOCK_STREAM, proto=0, flags=0):
        var host = address[0]
        var port = address[1]
        var info = _ipaddr_info(host, port)
        if info is not none and (family == 0 or family == info[0]):
            return [(info[0], type, proto, "", info[1])]
        return await self.getaddrinfo(host, port, family=family, type=type, proto=proto, flags=flags)

    # ── connections ──
    async def create_connection(self, protocol_factory, host=none, port=none, *, ssl=none, family=0, proto=0,
                                flags=0, sock=none, local_addr=none, server_hostname=none,
                                ssl_handshake_timeout=none, ssl_shutdown_timeout=none,
                                happy_eyeballs_delay=none, interleave=none, all_errors=false):
        if server_hostname is not none and not ssl:
            raise ValueError("server_hostname is only meaningful with ssl")
        if server_hostname is none and ssl:
            if not host:
                raise ValueError("You must set server_hostname when using ssl without a host")
            server_hostname = host
        if ssl_handshake_timeout is not none and not ssl:
            raise ValueError("ssl_handshake_timeout is only meaningful with ssl")
        if ssl_shutdown_timeout is not none and not ssl:
            raise ValueError("ssl_shutdown_timeout is only meaningful with ssl")
        if host is not none or port is not none:
            if sock is not none:
                raise ValueError("host/port and sock can not be specified at the same time")
            var infos = await self._ensure_resolved((host, port), family, socket.SOCK_STREAM, proto, flags)
            if len(infos) == 0:
                raise OSError("getaddrinfo() returned empty list")
            var errors = []
            for info in infos:
                var s = socket.socket(info[0], info[1], info[2])
                try:
                    s.setblocking(false)
                    if local_addr is not none:
                        s.bind(local_addr)
                    await self.sock_connect(s, info[4])
                    sock = s
                    break
                except OSError as exc:
                    errors.append(exc)
                    s.close()
                except BaseException:
                    s.close()
                    raise
            if sock is none:
                if all_errors:
                    raise ExceptionGroup("create_connection failed", errors)
                if len(errors) == 1:
                    raise errors[0]
                var model = str(errors[0])
                var same = true
                for e in errors:
                    if str(e) != model:
                        same = false
                if same:
                    raise errors[0]
                raise OSError("Multiple exceptions: " + ", ".join([str(e) for e in errors]))
        else:
            if sock is none:
                raise ValueError("host and port was not specified and no sock specified")
            if sock.type != socket.SOCK_STREAM:
                raise ValueError("A Stream Socket was expected, got " + repr(sock))
        return await self._create_connection_transport(sock, protocol_factory, ssl, server_hostname,
                                                       ssl_handshake_timeout=ssl_handshake_timeout)

    async def _create_connection_transport(self, sock, protocol_factory, sslcontext, server_hostname,
                                           server_side=false, ssl_handshake_timeout=none, extra=none):
        sock.setblocking(false)
        if sslcontext:
            sock = await self._tls_handshake(sock, sslcontext, server_side, server_hostname, ssl_handshake_timeout)
        var protocol = protocol_factory()
        var waiter = self.create_future()
        var ex = {} if extra is none else dict(extra)
        if sslcontext:
            ex["sslcontext"] = sock.context
            ex["ssl_object"] = sock
            ex["peercert"] = sock.getpeercert()
            ex["cipher"] = sock.cipher()
            ex["compression"] = none
        var transport = _SocketTransport(self, sock, protocol, waiter, ex)
        try:
            await waiter
        except BaseException:
            transport.close()
            raise
        return (transport, protocol)

    async def _tls_handshake(self, sock, sslcontext, server_side, server_hostname, handshake_timeout):
        import ssl as _ssl
        if sslcontext is true:
            sslcontext = _ssl.create_default_context()
        if not isinstance(sslcontext, _ssl.SSLContext):
            raise TypeError("sslcontext is expected to be an instance of ssl.SSLContext, got " + repr(sslcontext))
        if handshake_timeout is none:
            handshake_timeout = _SSL_HANDSHAKE_TIMEOUT
        elif handshake_timeout <= 0:
            raise ValueError("ssl_handshake_timeout should be a positive number, got " + str(handshake_timeout))
        sock.settimeout(handshake_timeout)
        var ssock = none
        try:
            if server_side:
                ssock = sslcontext.wrap_socket(sock, server_side=true)
            else:
                ssock = sslcontext.wrap_socket(sock, server_hostname=server_hostname)
        except TimeoutError:
            sock.close()
            raise ConnectionAbortedError("SSL handshake is taking longer than " + str(handshake_timeout) + " seconds: aborting the connection") from none
        except BaseException:
            sock.close()
            raise
        ssock.setblocking(false)
        return ssock

    async def connect_accepted_socket(self, protocol_factory, sock, *, ssl=none, ssl_handshake_timeout=none, ssl_shutdown_timeout=none):
        if sock.type != socket.SOCK_STREAM:
            raise ValueError("A Stream Socket was expected, got " + repr(sock))
        if ssl_handshake_timeout is not none and not ssl:
            raise ValueError("ssl_handshake_timeout is only meaningful with ssl")
        return await self._create_connection_transport(sock, protocol_factory, ssl, "", server_side=true,
                                                       ssl_handshake_timeout=ssl_handshake_timeout)

    async def create_server(self, protocol_factory, host=none, port=none, *, family=socket.AF_UNSPEC,
                            flags=socket.AI_PASSIVE, sock=none, backlog=100, ssl=none, reuse_address=none,
                            reuse_port=none, ssl_handshake_timeout=none, ssl_shutdown_timeout=none,
                            start_serving=true):
        if isinstance(ssl, bool):
            raise TypeError("ssl argument must be an SSLContext or None")
        if ssl_handshake_timeout is not none and ssl is none:
            raise ValueError("ssl_handshake_timeout is only meaningful with ssl")
        if ssl_shutdown_timeout is not none and ssl is none:
            raise ValueError("ssl_shutdown_timeout is only meaningful with ssl")
        var sockets = []
        if host is not none or port is not none:
            if sock is not none:
                raise ValueError("host/port and sock can not be specified at the same time")
            if reuse_address is none:
                reuse_address = not _WINDOWS
            var hosts = [none]
            if host == "":
                hosts = [none]
            elif isinstance(host, str):
                hosts = [host]
            elif host is not none:
                hosts = list(host)
            var seen = set()
            for hst in hosts:
                # every address getaddrinfo gives - for host None the
                # wildcards of both families, as CPython (round 82: IPv4 only)
                var infos = await self._ensure_resolved((hst, port), family, socket.SOCK_STREAM, 0, flags)
                for info in infos:
                    var key = (info[0], tuple(info[4]))
                    if key in seen:
                        continue
                    seen.add(key)
                    var s = none
                    try:
                        s = socket.socket(info[0], info[1], info[2])
                    except OSError:
                        # a family this host cannot open (no IPv6): skipped,
                        # as CPython assumes a bad family/type combination
                        if self._debug:
                            logger.warning("create_server() failed to create socket.socket(%r, %r, %r)", info[0], info[1], info[2])
                        continue
                    sockets.append(s)
                    try:
                        if reuse_address:
                            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                        if reuse_port and socket.SO_REUSEPORT is not none:
                            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                        if info[0] == socket.AF_INET6 and socket.IPV6_V6ONLY is not none:
                            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                        s.bind(info[4])
                    except OSError as err:
                        for x in sockets:
                            x.close()
                        var msg = "error while attempting to bind on address " + repr(info[4]) + ": " + str(getattr(err, "strerror", none) or err)
                        raise OSError(getattr(err, "errno", none), msg) from none
            if len(sockets) == 0:
                raise OSError("getaddrinfo() returned empty list")
        else:
            if sock is none:
                raise ValueError("Neither host/port nor sock were specified")
            if sock.type != socket.SOCK_STREAM:
                raise ValueError("A Stream Socket was expected, got " + repr(sock))
            sockets = [sock]
        for s in sockets:
            s.setblocking(false)
        var server = Server(self, sockets, protocol_factory, ssl, backlog, ssl_handshake_timeout, ssl_shutdown_timeout)
        if start_serving:
            server._start_serving()
            await sleep(0)
        return server

    async def _accept_loop(self, server, sock):
        try:
            while true:
                var pair = none
                try:
                    pair = sock.accept()
                except (BlockingIOError, InterruptedError, ConnectionAbortedError):
                    sock.wait_readable()
                    continue
                except CancelledError:
                    raise
                except OSError as exc:
                    if server._sockets is none:
                        return
                    var en = getattr(exc, "errno", none)
                    if en == 24 or en == 23 or en == 105 or en == 12:
                        self.call_exception_handler({"message": "socket.accept() out of system resource",
                                                     "exception": exc, "socket": sock})
                        await sleep(1)
                        continue
                    raise
                var conn = pair[0]
                conn.setblocking(false)
                var extra = {"peername": pair[1]}
                if server._ssl_context is not none:
                    _spawn_internal(self, self._accept_tls(server, conn, extra))
                else:
                    try:
                        _SocketTransport(self, conn, server._protocol_factory(), none, extra, server)
                    except (SystemExit, KeyboardInterrupt):
                        raise
                    except BaseException as exc:
                        conn.close()
                        self.call_exception_handler({"message": "Error on transport creation for incoming connection",
                                                     "exception": exc})
        except CancelledError:
            return

    async def _accept_tls(self, server, conn, extra):
        try:
            await self._create_connection_transport(conn, server._protocol_factory, server._ssl_context, none,
                                                    server_side=true,
                                                    ssl_handshake_timeout=server._ssl_handshake_timeout,
                                                    extra=extra)
        except (SystemExit, KeyboardInterrupt):
            raise
        except CancelledError:
            pass
        except BaseException as exc:
            if self._debug:
                self.call_exception_handler({"message": "Error on transport creation for incoming connection",
                                             "exception": exc})

    async def start_tls(self, transport, protocol, sslcontext, *, server_side=false, server_hostname=none,
                        ssl_handshake_timeout=none, ssl_shutdown_timeout=none):
        import ssl as _ssl
        if not isinstance(sslcontext, _ssl.SSLContext):
            raise TypeError("sslcontext is expected to be an instance of ssl.SSLContext, got " + repr(sslcontext))
        if not getattr(transport, "_start_tls_compatible", false):
            raise TypeError("transport " + repr(transport) + " is not supported by start_tls()")
        transport.pause_reading()
        await transport._drain_for_tls()
        var raw = transport._sock
        var srv = transport._detach_for_tls()
        var ssock = await self._tls_handshake(raw, sslcontext, server_side, server_hostname, ssl_handshake_timeout)
        var extra = dict(transport._extra)
        extra["socket"] = ssock
        extra["sslcontext"] = sslcontext
        extra["ssl_object"] = ssock
        extra["peercert"] = ssock.getpeercert()
        extra["cipher"] = ssock.cipher()
        var waiter = self.create_future()
        var nt = _SocketTransport(self, ssock, protocol, waiter, extra, srv, false)
        if srv is not none:
            srv._detach()          # the new transport attached itself
        await waiter
        return nt

    async def create_datagram_endpoint(self, protocol_factory, local_addr=none, remote_addr=none, *, family=0,
                                       proto=0, flags=0, reuse_port=none, allow_broadcast=none, sock=none):
        if sock is not none:
            if sock.type != socket.SOCK_DGRAM:
                raise ValueError("A UDP Socket was expected, got " + repr(sock))
            if local_addr or remote_addr or family or proto or flags or reuse_port or allow_broadcast:
                raise ValueError("socket modifier keyword arguments can not be used when sock is specified.")
            sock.setblocking(false)
            var r_addr = none
        else:
            if not (local_addr or remote_addr):
                if family == 0:
                    raise ValueError("unexpected address family")
            if family == socket.AF_UNIX or (_HAS_UNIX and ((isinstance(local_addr, str) or isinstance(local_addr, bytes)) or (isinstance(remote_addr, str) or isinstance(remote_addr, bytes)))):
                if not _HAS_UNIX:
                    raise NotImplementedError("Unix domain sockets are not supported on this platform")
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM, proto)
                if local_addr:
                    try:
                        if os.path.exists(local_addr) and not os.path.isdir(local_addr):
                            os.remove(local_addr)
                    except OSError:
                        pass
                    sock.bind(local_addr)
                if remote_addr:
                    await self.sock_connect(sock, remote_addr)
                r_addr = remote_addr
            else:
                var fam = family
                var laddr = none
                var raddr = none
                if local_addr is not none:
                    var li = await self._ensure_resolved(tuple(local_addr), family, socket.SOCK_DGRAM, proto, flags)
                    fam = li[0][0]
                    laddr = li[0][4]
                if remote_addr is not none:
                    var ri = await self._ensure_resolved(tuple(remote_addr), fam, socket.SOCK_DGRAM, proto, flags)
                    fam = ri[0][0]
                    raddr = ri[0][4]
                if fam == 0:
                    fam = socket.AF_INET
                sock = socket.socket(fam, socket.SOCK_DGRAM, proto)
                try:
                    if reuse_port and socket.SO_REUSEPORT is not none:
                        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                    if allow_broadcast:
                        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                    sock.setblocking(false)
                    if laddr is not none:
                        sock.bind(laddr)
                    if raddr is not none:
                        if not allow_broadcast:
                            await self.sock_connect(sock, raddr)
                except BaseException:
                    sock.close()
                    raise
                r_addr = raddr
            sock.setblocking(false)
        var protocol = protocol_factory()
        var waiter = self.create_future()
        var transport = _DatagramTransport(self, sock, protocol, r_addr, waiter)
        try:
            await waiter
        except BaseException:
            transport.close()
            raise
        return (transport, protocol)

    # ── Unix sockets ──
    async def create_unix_connection(self, protocol_factory, path=none, *, ssl=none, sock=none, server_hostname=none,
                                     ssl_handshake_timeout=none, ssl_shutdown_timeout=none):
        if not _HAS_UNIX:
            raise NotImplementedError
        if ssl:
            if server_hostname is none:
                raise ValueError("you have to pass server_hostname when using ssl")
        else:
            if server_hostname is not none:
                raise ValueError("server_hostname is only meaningful with ssl")
            if ssl_handshake_timeout is not none:
                raise ValueError("ssl_handshake_timeout is only meaningful with ssl")
        if path is not none:
            if sock is not none:
                raise ValueError("path and sock can not be specified at the same time")
            path = os.fspath(path)
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0)
            try:
                sock.setblocking(false)
                await self.sock_connect(sock, path)
            except BaseException:
                sock.close()
                raise
        else:
            if sock is none:
                raise ValueError("no path and sock were specified")
            if sock.family != socket.AF_UNIX or sock.type != socket.SOCK_STREAM:
                raise ValueError("A UNIX Domain Stream Socket was expected, got " + repr(sock))
        return await self._create_connection_transport(sock, protocol_factory, ssl, server_hostname,
                                                       ssl_handshake_timeout=ssl_handshake_timeout)

    async def create_unix_server(self, protocol_factory, path=none, *, sock=none, backlog=100, ssl=none,
                                 ssl_handshake_timeout=none, ssl_shutdown_timeout=none, start_serving=true):
        if not _HAS_UNIX:
            raise NotImplementedError
        if isinstance(ssl, bool):
            raise TypeError("ssl argument must be an SSLContext or None")
        if ssl_handshake_timeout is not none and not ssl:
            raise ValueError("ssl_handshake_timeout is only meaningful with ssl")
        if path is not none:
            if sock is not none:
                raise ValueError("path and sock can not be specified at the same time")
            path = os.fspath(path)
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            if len(path) > 0 and path[0] != "\0":
                try:
                    import stat as _stat
                    if _stat.S_ISSOCK(os.stat(path).st_mode):
                        os.remove(path)
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
            try:
                sock.bind(path)
            except OSError as exc:
                sock.close()
                if getattr(exc, "errno", none) == 98:
                    raise OSError(98, "Address " + repr(path) + " is already in use") from none
                raise
            except BaseException:
                sock.close()
                raise
        else:
            if sock is none:
                raise ValueError("path was not specified, and no sock specified")
            if sock.family != socket.AF_UNIX or sock.type != socket.SOCK_STREAM:
                raise ValueError("A UNIX Domain Stream Socket was expected, got " + repr(sock))
        sock.setblocking(false)
        var server = Server(self, [sock], protocol_factory, ssl, backlog, ssl_handshake_timeout, ssl_shutdown_timeout)
        if start_serving:
            server._start_serving()
            await sleep(0)
        return server

    # ── subprocesses ──
    async def subprocess_exec(self, protocol_factory, program, *args, stdin=-1, stdout=-1, stderr=-1,
                              universal_newlines=false, shell=false, bufsize=0, encoding=none, errors=none,
                              text=none, **kwargs):
        if universal_newlines:
            raise ValueError("universal_newlines must be False")
        if shell:
            raise ValueError("shell must be False")
        if bufsize != 0:
            raise ValueError("bufsize must be 0")
        if text:
            raise ValueError("text must be False")
        if encoding is not none:
            raise ValueError("encoding must be None")
        if errors is not none:
            raise ValueError("errors must be None")
        var popen_args = [program] + list(args)
        var protocol = protocol_factory()
        var transport = await _SubprocessTransport._start_new(self, protocol, popen_args, false, stdin, stdout, stderr, kwargs)
        return (transport, protocol)

    async def subprocess_shell(self, protocol_factory, cmd, *, stdin=-1, stdout=-1, stderr=-1,
                               universal_newlines=false, shell=true, bufsize=0, encoding=none, errors=none,
                               text=none, **kwargs):
        if not (isinstance(cmd, str) or isinstance(cmd, bytes)):
            raise ValueError("cmd must be a string")
        if universal_newlines:
            raise ValueError("universal_newlines must be False")
        if not shell:
            raise ValueError("shell must be True")
        if bufsize != 0:
            raise ValueError("bufsize must be 0")
        if text:
            raise ValueError("text must be False")
        if encoding is not none:
            raise ValueError("encoding must be None")
        if errors is not none:
            raise ValueError("errors must be None")
        var protocol = protocol_factory()
        var transport = await _SubprocessTransport._start_new(self, protocol, cmd, true, stdin, stdout, stderr, kwargs)
        return (transport, protocol)

    # ── signals ──
    def _check_signal(self, sig):
        if not isinstance(sig, int):
            raise TypeError("sig must be an int, not " + repr(sig))
        import signal
        if sig not in signal.valid_signals():
            raise ValueError("invalid signal number " + str(sig))

    def add_signal_handler(self, sig, callback, *args):
        # callback(*args) runs as a loop callback when sig arrives
        if _WINDOWS:
            raise NotImplementedError
        if iscoroutine(callback) or iscoroutinefunction(callback):
            raise TypeError("coroutines cannot be used with add_signal_handler()")
        self._check_signal(sig)
        self._check_closed()
        import signal
        var handle = Handle(callback, args, self, none)
        self._signal_handlers[sig] = handle
        try:
            signal.signal(sig, self._on_signal)
        except OSError as exc:
            del self._signal_handlers[sig]
            if getattr(exc, "errno", none) == 22:
                raise RuntimeError("sig " + str(sig) + " cannot be caught")
            raise

    def _on_signal(self, signum, frame):
        var handle = self._signal_handlers.get(signum)
        if handle is none:
            return
        if handle._cancelled:
            self.remove_signal_handler(signum)
            return
        if not self._closed:
            handle._ran = false
            handle._h = self._schedule(none, handle._run)

    def remove_signal_handler(self, sig):
        if _WINDOWS:
            raise NotImplementedError
        self._check_signal(sig)
        if sig not in self._signal_handlers:
            return false
        del self._signal_handlers[sig]
        import signal
        var handler = signal.SIG_DFL
        if sig == signal.SIGINT:
            handler = signal.default_int_handler
        try:
            signal.signal(sig, handler)
        except OSError as exc:
            if getattr(exc, "errno", none) == 22:
                raise RuntimeError("sig " + str(sig) + " cannot be caught")
            raise
        return true

class SelectorEventLoop(BaseEventLoop):
    # the event loop of new_event_loop() (asyncio.SelectorEventLoop)
    pass

_UnixSelectorEventLoop = SelectorEventLoop

class _ForeignLoop(BaseEventLoop):
    # what get_running_loop() gives inside async_run (the runtime's own
    # entry point, without a loop object): it can schedule on the running
    # loop, not run it
    def __init__(self):
        self._h = 0
        self._closed = false
        self._running = true
        self._thread_id = none
        self._debug = false
        self._exception_handler = none
        self._default_executor = none
        self._executor_shutdown_called = false
        self._asyncgens_shutdown_called = false
        self._asyncgens = _ny_weakset()
        self._task_factory = none
        self._signal_handlers = {}
        self._readers = {}
        self._writers = {}
        self._pending_exc = none
        self._orphan_policy = none
        self._orphans = []

    def _spawn(self, aw, eager=false):
        if eager:
            return async_create_task_eager(aw)
        return async_create_task(aw)

    def _schedule(self, delay, fn):
        if async_current_task() == 0:
            raise RuntimeError("no running event loop")
        return async_call_later(0 if delay is none or delay < 0 else delay, fn)

    def is_running(self):
        return async_current_task() != 0

    def run_forever(self):
        raise RuntimeError("This event loop is already running")

    def run_until_complete(self, future):
        raise RuntimeError("This event loop is already running")

    def stop(self):
        pass

    def close(self):
        raise RuntimeError("Cannot close a running event loop")

class DefaultEventLoopPolicy(BaseDefaultEventLoopPolicy):
    _loop_factory = SelectorEventLoop

def _env_debug():
    var v = os.environ.get("PYTHONASYNCIODEBUG", "")
    return v != "" and not getattr(sys.flags, "ignore_environment", false)

async def _wait_quietly(fut):
    try:
        await fut
    except BaseException:
        pass

_CONNECT_PENDING = (115, 114, 11, 10035, 10036, 4)

def _connect_error(err, address):
    var e = OSError(err, "Connect call failed " + repr(address))
    if err == 111 or err == 10061:
        e = ConnectionRefusedError(err, "Connect call failed " + repr(address))
    elif err == 104:
        e = ConnectionResetError(err, "Connect call failed " + repr(address))
    elif err == 110 or err == 10060:
        e = TimeoutError(err, "Connect call failed " + repr(address))
    return e

class _FdWatch:
    # add_reader/add_writer: a task waits for the descriptor and runs the
    # callback each time it is ready (level-triggered, as a selector)
    def __init__(self, loop, fd, handle, writing):
        self._loop = loop
        self._fd = fd
        self._handle = handle
        self._writing = writing
        self._task = 0
        self._stopped = false

    async def _watch(self):
        var fd = self._fd
        if not isinstance(fd, int):
            fd = fd.fileno()
        try:
            while not self._stopped:
                if self._writing:
                    _net_select([], [fd], [], none)
                else:
                    _net_select([fd], [], [], none)
                if self._stopped or self._handle._cancelled:
                    return
                self._handle._ran = false
                self._handle._run()
                await sleep(0)
        except CancelledError:
            return

    def _stop(self):
        self._stopped = true
        self._handle.cancel()
        var h = self._task
        self._task = 0
        _cancel_handle(h)

class _OrphanReport:
    # one structured-concurrency finding: a task left running
    def __init__(self, t, why):
        self.task = t
        self.name = t.get_name()
        self.why = why
        self.created_at = t._created_at
        self.parent = none if t._parent is none else t._parent.get_name()
        self.coro = none if t._coro is none else (getattr(t._coro, "__qualname__", none) or getattr(t._coro, "__name__", none))

    def where(self):
        if self.created_at is none:
            return ""
        return " (created at " + str(self.created_at[0]) + ":" + str(self.created_at[1]) + ")"

    def __repr__(self):
        return "<orphan " + repr(self.name) + " " + self.why + self.where() + ">"

# ─── Streams (CPython's asyncio.streams, over the protocols) ────────────────

class FlowControlMixin(Protocol):
    # The write side of a stream protocol: drain() waits while the
    # transport has paused it.
    def __init__(self, loop=none):
        if loop is none:
            loop = get_event_loop()
        self._loop = loop
        self._paused = false
        self._drain_waiters = []
        self._connection_lost = false

    def pause_writing(self):
        self._paused = true

    def resume_writing(self):
        self._paused = false
        var ws = self._drain_waiters
        self._drain_waiters = []
        for w in ws:
            if not w.done():
                w.set_result(none)

    def connection_lost(self, exc):
        self._connection_lost = true
        if not self._paused:
            return
        var ws = self._drain_waiters
        self._drain_waiters = []
        for w in ws:
            if not w.done():
                if exc is none:
                    w.set_result(none)
                else:
                    w.set_exception(exc)

    async def _drain_helper(self):
        if self._connection_lost:
            raise ConnectionResetError("Connection lost")
        if not self._paused:
            return
        var waiter = self._loop.create_future()
        self._drain_waiters.append(waiter)
        try:
            await waiter
        finally:
            if waiter in self._drain_waiters:
                self._drain_waiters.remove(waiter)

    def _get_close_waiter(self, stream):
        raise NotImplementedError

class StreamReaderProtocol(FlowControlMixin):
    # Adapts the protocol callbacks to a StreamReader (and, for a server,
    # calls client_connected_cb(reader, writer)).
    def __init__(self, stream_reader, client_connected_cb=none, loop=none):
        super().__init__(loop=loop)
        self._stream_reader = stream_reader
        self._stream_writer = none
        self._task = none
        self._transport = none
        self._client_connected_cb = client_connected_cb
        self._over_ssl = false
        self._closed = self._loop.create_future()

    def _replace_writer(self, writer):
        var transport = writer.transport
        self._stream_writer = writer
        self._transport = transport
        self._over_ssl = transport.get_extra_info("sslcontext") is not none
        # start_tls made a new transport: the reader's flow control is its
        if self._stream_reader is not none:
            self._stream_reader.set_transport(transport)

    def connection_made(self, transport):
        var reader = self._stream_reader
        if reader is not none:
            reader.set_transport(transport)
        self._over_ssl = transport.get_extra_info("sslcontext") is not none
        if self._client_connected_cb is not none:
            self._stream_writer = StreamWriter(transport, self, reader, self._loop)
            var res = self._client_connected_cb(reader, self._stream_writer)
            if iscoroutine(res):
                var tr = transport
                var lo = self._loop
                def on_done(task):
                    if task.cancelled():
                        tr.close()
                        return
                    var exc = task.exception()
                    if exc is not none:
                        lo.call_exception_handler({"message": "Unhandled exception in client_connected_cb",
                                                   "exception": exc, "transport": tr})
                        tr.close()
                self._task = self._loop.create_task(res)
                self._task.add_done_callback(on_done)
            self._strong_reader = none
        self._transport = transport

    def connection_lost(self, exc):
        var reader = self._stream_reader
        if reader is not none:
            if exc is none:
                reader.feed_eof()
            else:
                reader.set_exception(exc)
        if not self._closed.done():
            if exc is none:
                self._closed.set_result(none)
            else:
                self._closed.set_exception(exc)
                self._closed._log_traceback = false
        super().connection_lost(exc)
        self._stream_reader = none
        self._stream_writer = none
        self._task = none
        self._transport = none

    def data_received(self, data):
        var reader = self._stream_reader
        if reader is not none:
            reader.feed_data(data)

    def eof_received(self):
        var reader = self._stream_reader
        if reader is not none:
            reader.feed_eof()
        if self._over_ssl:
            return false
        return true

    def _get_close_waiter(self, stream):
        return self._closed

class StreamWriter:
    # The writing half of a stream: write()/writelines(), then
    # `await drain()` to wait while the transport's buffer is full.
    def __init__(self, transport, protocol, reader, loop):
        self._transport = transport
        self._protocol = protocol
        self._reader = reader
        self._loop = loop
        self._complete_fut = self._loop.create_future()
        self._complete_fut.set_result(none)

    def __repr__(self):
        var info = [self.__class__.__name__, "transport=" + repr(self._transport)]
        if self._reader is not none:
            info.append("reader=" + repr(self._reader))
        return "<" + " ".join(info) + ">"

    @property
    def transport(self):
        return self._transport

    def write(self, data):
        self._transport.write(data)

    def writelines(self, data):
        self._transport.writelines(data)

    def write_eof(self):
        return self._transport.write_eof()

    def can_write_eof(self):
        return self._transport.can_write_eof()

    def close(self):
        return self._transport.close()

    def is_closing(self):
        return self._transport.is_closing()

    async def wait_closed(self):
        await self._protocol._get_close_waiter(self)

    def get_extra_info(self, name, default=none):
        return self._transport.get_extra_info(name, default)

    async def drain(self):
        if self._reader is not none:
            var exc = self._reader.exception()
            if exc is not none:
                raise exc
        if self._transport.is_closing():
            await sleep(0)
        await self._protocol._drain_helper()

    async def start_tls(self, sslcontext, *, server_hostname=none, ssl_handshake_timeout=none, ssl_shutdown_timeout=none):
        var server_side = self._protocol._client_connected_cb is not none
        var protocol = self._protocol
        await self.drain()
        var new_transport = await self._loop.start_tls(self._transport, protocol, sslcontext, server_side=server_side,
                                                       server_hostname=server_hostname,
                                                       ssl_handshake_timeout=ssl_handshake_timeout)
        self._transport = new_transport
        protocol._replace_writer(self)

class StreamReader:
    # The reading half of a stream: read(n), readline(), readexactly(n),
    # readuntil(sep), `async for line in reader`.
    def __init__(self, limit=_DEFAULT_LIMIT, loop=none):
        if limit <= 0:
            raise ValueError("Limit cannot be <= 0")
        self._limit = limit
        if loop is none:
            loop = get_event_loop()
        self._loop = loop
        self._buffer = bytearray()
        self._eof = false
        self._waiter = none
        self._exception = none
        self._transport = none
        self._paused = false

    def __repr__(self):
        var info = ["StreamReader"]
        if len(self._buffer) > 0:
            info.append(str(len(self._buffer)) + " bytes")
        if self._eof:
            info.append("eof")
        if self._limit != _DEFAULT_LIMIT:
            info.append("limit=" + str(self._limit))
        if self._waiter is not none:
            info.append("waiter=" + repr(self._waiter))
        if self._exception is not none:
            info.append("exception=" + repr(self._exception))
        if self._transport is not none:
            info.append("transport=" + repr(self._transport))
        if self._paused:
            info.append("paused")
        return "<" + " ".join(info) + ">"

    def exception(self):
        return self._exception

    def set_exception(self, exc):
        self._exception = exc
        var waiter = self._waiter
        if waiter is not none:
            self._waiter = none
            if not waiter.cancelled():
                waiter.set_exception(exc)

    def _wakeup_waiter(self):
        var waiter = self._waiter
        if waiter is not none:
            self._waiter = none
            if not waiter.cancelled():
                waiter.set_result(none)

    def set_transport(self, transport):
        self._transport = transport

    def _maybe_resume_transport(self):
        if self._paused and len(self._buffer) <= self._limit:
            self._paused = false
            self._transport.resume_reading()

    def feed_eof(self):
        self._eof = true
        self._wakeup_waiter()

    def at_eof(self):
        return self._eof and len(self._buffer) == 0

    def feed_data(self, data):
        if len(data) == 0:
            return
        self._buffer.extend(data)
        self._wakeup_waiter()
        if self._transport is not none and not self._paused and len(self._buffer) > 2 * self._limit:
            try:
                self._transport.pause_reading()
            except NotImplementedError:
                self._transport = none
            else:
                self._paused = true

    async def _wait_for_data(self, func_name):
        if self._waiter is not none:
            raise RuntimeError(func_name + "() called while another coroutine is already waiting for incoming data")
        if self._paused:
            self._paused = false
            self._transport.resume_reading()
        self._waiter = self._loop.create_future()
        try:
            await self._waiter
        finally:
            self._waiter = none

    async def readline(self):
        var sep = b"\n"
        var seplen = len(sep)
        try:
            return await self.readuntil(sep)
        except IncompleteReadError as e:
            return e.partial
        except LimitOverrunError as e:
            if self._buffer.startswith(sep, e.consumed):
                del self._buffer[:e.consumed + seplen]
            else:
                self._buffer = bytearray()
            self._maybe_resume_transport()
            raise ValueError(e.args[0])

    async def readuntil(self, separator=b"\n"):
        var seplen = len(separator)
        if seplen == 0:
            raise ValueError("Separator should be at least one-byte string")
        if self._exception is not none:
            raise self._exception
        var offset = 0
        var isep = -1
        while true:
            var buflen = len(self._buffer)
            if buflen - offset >= seplen:
                isep = self._buffer.find(separator, offset)
                if isep != -1:
                    break
                offset = buflen + 1 - seplen
                if offset > self._limit:
                    raise LimitOverrunError("Separator is not found, and chunk exceed the limit", offset)
            if self._eof:
                var chunk = bytes(self._buffer)
                self._buffer = bytearray()
                raise IncompleteReadError(chunk, none)
            await self._wait_for_data("readuntil")
        if isep > self._limit:
            raise LimitOverrunError("Separator is found, but chunk is longer than limit", isep)
        var out = bytes(self._buffer[:isep + seplen])
        del self._buffer[:isep + seplen]
        self._maybe_resume_transport()
        return out

    async def read(self, n=-1):
        if self._exception is not none:
            raise self._exception
        if n == 0:
            return b""
        if n < 0:
            var blocks = []
            while true:
                var block = await self.read(self._limit)
                if len(block) == 0:
                    break
                blocks.append(block)
            return b"".join(blocks)
        if len(self._buffer) == 0 and not self._eof:
            await self._wait_for_data("read")
        var data = bytes(self._buffer[:n])
        del self._buffer[:n]
        self._maybe_resume_transport()
        return data

    async def readexactly(self, n):
        if n < 0:
            raise ValueError("readexactly size can not be less than zero")
        if self._exception is not none:
            raise self._exception
        if n == 0:
            return b""
        while len(self._buffer) < n:
            if self._eof:
                var incomplete = bytes(self._buffer)
                self._buffer = bytearray()
                raise IncompleteReadError(incomplete, n)
            await self._wait_for_data("readexactly")
        var data = bytes(self._buffer[:n])
        del self._buffer[:n]
        self._maybe_resume_transport()
        return data

    def __aiter__(self):
        return self

    async def __anext__(self):
        var val = await self.readline()
        if val == b"":
            raise StopAsyncIteration()
        return val

async def open_connection(host=none, port=none, *, limit=_DEFAULT_LIMIT, **kwds):
    # (reader, writer) for a TCP connection (ssl=, server_hostname=, ... as
    # loop.create_connection)
    var lo = get_running_loop()
    var reader = StreamReader(limit=limit, loop=lo)
    var protocol = StreamReaderProtocol(reader, loop=lo)
    var pair = await lo.create_connection(lambda: protocol, host, port, **kwds)
    var writer = StreamWriter(pair[0], protocol, reader, lo)
    return (reader, writer)

async def start_server(client_connected_cb, host=none, port=none, *, limit=_DEFAULT_LIMIT, **kwds):
    # client_connected_cb(reader, writer), a function or a coroutine function,
    # for each connection; port 0 picks a free port (server.sockets[0]).
    var lo = get_running_loop()
    def factory():
        var reader = StreamReader(limit=limit, loop=lo)
        return StreamReaderProtocol(reader, client_connected_cb, loop=lo)
    return await lo.create_server(factory, host, port, **kwds)

if _HAS_UNIX:
    async def open_unix_connection(path=none, *, limit=_DEFAULT_LIMIT, **kwds):
        var lo = get_running_loop()
        var reader = StreamReader(limit=limit, loop=lo)
        var protocol = StreamReaderProtocol(reader, loop=lo)
        var pair = await lo.create_unix_connection(lambda: protocol, path, **kwds)
        var writer = StreamWriter(pair[0], protocol, reader, lo)
        return (reader, writer)

    async def start_unix_server(client_connected_cb, path=none, *, limit=_DEFAULT_LIMIT, **kwds):
        var lo = get_running_loop()
        def factory():
            var reader = StreamReader(limit=limit, loop=lo)
            return StreamReaderProtocol(reader, client_connected_cb, loop=lo)
        return await lo.create_unix_server(factory, path, **kwds)

# ─── Subprocesses ───────────────────────────────────────────────────────────

PIPE = -1
STDOUT = -2
DEVNULL = -3

class _PipeTransport(BaseTransport):
    # One of a child's pipes as a transport (get_pipe_transport(fd)).
    def __init__(self, proc, fd):
        super().__init__({"pipe": fd})
        self._proc = proc
        self._fd = fd
        self._closing = false

    def __repr__(self):
        return "<" + ("WritePipeTransport" if self._fd == 0 else "ReadPipeTransport") + " fd=" + str(self._fd) + (" closing" if self._closing else "") + ">"

    def get_protocol(self):
        return self._proc._protocol

    def set_protocol(self, protocol):
        pass

    def is_closing(self):
        return self._closing

    def close(self):
        if self._closing:
            return
        self._closing = true
        self._proc._pipe_closed_by_us(self._fd)

    def abort(self):
        self.close()

    # read side
    def is_reading(self):
        return not self._closing and not self._proc._paused

    def pause_reading(self):
        var pr = self._proc
        pr._paused = true
        if pr._resume_ev is none:
            pr._resume_ev = _ev_get()
        event_clear(pr._resume_ev)

    def resume_reading(self):
        var pr = self._proc
        if pr._paused:
            pr._paused = false
            if pr._resume_ev is not none:
                event_set(pr._resume_ev)

class _WritePipeTransport(_PipeTransport, _FlowControlMixin):
    def __init__(self, proc):
        _PipeTransport.__init__(self, proc, 0)
        self._loop = proc._loop
        self._protocol_paused = false
        self._set_write_buffer_limits()
        self._protocol = proc._protocol

    def get_write_buffer_size(self):
        return len(self._proc._in_buf)

    def write(self, data):
        _check_data(data)
        if self._closing:
            return
        if len(data) == 0:
            return
        self._proc._in_buf.extend(data)
        self._proc._start_stdin_writer()
        self._maybe_pause_protocol()

    def writelines(self, list_of_data):
        for d in list_of_data:
            self.write(d)

    def can_write_eof(self):
        return true

    def write_eof(self):
        self.close()

    def _maybe_pause_protocol(self):
        if len(self._proc._in_buf) > self._high_water and not self._protocol_paused:
            self._protocol_paused = true
            try:
                self._proc._protocol.pause_writing()
            except BaseException:
                pass

    def _maybe_resume_protocol(self):
        if self._protocol_paused and len(self._proc._in_buf) <= self._low_water:
            self._protocol_paused = false
            try:
                self._proc._protocol.resume_writing()
            except BaseException:
                pass

# ─── sendfile through a transport, and pipe transports (round 82) ──────────

_SENDFILE_UNSUPPORTED = "unsupported"
_SENDFILE_FALLBACK = "fallback"

class _SendfileStreamProbe:
    # stands for a transport without a socket in _check_sendfile_params
    type = socket.SOCK_STREAM

class _SendfileFallbackProtocol(Protocol):
    # Takes the transport's protocol's place while a file is sent through
    # it: reading paused, writing paced by pause_writing/resume_writing
    # (CPython's base_events._SendfileFallbackProtocol).
    def __init__(self, transp):
        self._transport = transp
        self._proto = transp.get_protocol()
        self._should_resume_reading = transp.is_reading()
        self._should_resume_writing = getattr(transp, "_protocol_paused", false)
        transp.pause_reading()
        transp.set_protocol(self)
        if self._should_resume_writing:
            self._write_ready_fut = transp._loop.create_future()
        else:
            self._write_ready_fut = none

    async def drain(self):
        if self._transport.is_closing():
            raise ConnectionError("Connection closed by peer")
        var fut = self._write_ready_fut
        if fut is none:
            return
        await fut

    def connection_made(self, transport):
        raise RuntimeError("Invalid state: connection should have been established already.")

    def connection_lost(self, exc):
        if self._write_ready_fut is not none:
            if exc is none:
                self._write_ready_fut.set_exception(ConnectionError("Connection is closed by peer"))
            else:
                self._write_ready_fut.set_exception(exc)
        self._proto.connection_lost(exc)

    def pause_writing(self):
        if self._write_ready_fut is not none:
            return
        self._write_ready_fut = self._transport._loop.create_future()

    def resume_writing(self):
        if self._write_ready_fut is none:
            return
        self._write_ready_fut.set_result(false)
        self._write_ready_fut = none

    def data_received(self, data):
        raise RuntimeError("Invalid state: reading should be paused")

    def eof_received(self):
        raise RuntimeError("Invalid state: reading should be paused")

    async def restore(self):
        self._transport.set_protocol(self._proto)
        if self._should_resume_reading:
            self._transport.resume_reading()
        if self._write_ready_fut is not none:
            # Cancel the future; the transport is either fine (and
            # resume_writing will not be called) or closing.
            self._write_ready_fut.cancel()
        if self._should_resume_writing:
            self._proto.resume_writing()

def _pipe_mode_ok(fileno):
    import stat
    var mode = os.fstat(fileno).st_mode
    return stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode) or stat.S_ISCHR(mode)

class _UnixReadPipeTransport(ReadTransport):
    # The read end of a pipe (or a socket / character device) as a
    # transport: data_received with each read, eof_received then
    # connection_lost at end of file (CPython's unix_events).
    max_size = 256 * 1024

    def __init__(self, loop, pipe, protocol, waiter=none, extra=none):
        super().__init__(extra)
        self._extra["pipe"] = pipe
        self._loop = loop
        self._pipe = pipe
        self._fileno = pipe.fileno()
        self._protocol = protocol
        self._closing = false
        self._paused = false
        if not _pipe_mode_ok(self._fileno):
            self._pipe = none
            self._fileno = none
            self._protocol = none
            raise ValueError("Pipe transport is for pipes/sockets only.")
        os.set_blocking(self._fileno, false)
        self._loop.call_soon(self._protocol.connection_made, self)
        self._loop.call_soon(self._add_reader, self._fileno, self._read_ready)
        if waiter is not none:
            self._loop.call_soon(_set_result_unless_cancelled, waiter, none)

    def __repr__(self):
        var info = [type(self).__name__]
        if self._pipe is none:
            info.append("closed")
        elif self._closing:
            info.append("closing")
        info.append("fd=" + str(self._fileno))
        return "<" + " ".join(info) + ">"

    def _add_reader(self, fd, callback):
        if not self.is_reading():
            return
        self._loop.add_reader(fd, callback)

    def is_reading(self):
        return not self._paused and not self._closing

    def _read_ready(self):
        var data = none
        try:
            data = os.read(self._fileno, self.max_size)
        except (BlockingIOError, InterruptedError):
            return
        except OSError as exc:
            self._fatal_error(exc, "Fatal read error on pipe transport")
            return
        if data:
            self._protocol.data_received(data)
        else:
            self._closing = true
            self._loop.remove_reader(self._fileno)
            self._loop.call_soon(self._protocol.eof_received)
            self._loop.call_soon(self._call_connection_lost, none)

    def pause_reading(self):
        if not self.is_reading():
            return
        self._paused = true
        self._loop.remove_reader(self._fileno)

    def resume_reading(self):
        if self._closing or not self._paused:
            return
        self._paused = false
        self._loop.add_reader(self._fileno, self._read_ready)

    def set_protocol(self, protocol):
        self._protocol = protocol

    def get_protocol(self):
        return self._protocol

    def is_closing(self):
        return self._closing

    def close(self):
        if not self._closing:
            self._close(none)

    def _fatal_error(self, exc, message="Fatal error on pipe transport"):
        if not isinstance(exc, OSError):
            self._loop.call_exception_handler({"message": message, "exception": exc,
                                               "transport": self, "protocol": self._protocol})
        self._close(exc)

    def _close(self, exc):
        self._closing = true
        self._loop.remove_reader(self._fileno)
        self._loop.call_soon(self._call_connection_lost, exc)

    def _call_connection_lost(self, exc):
        try:
            self._protocol.connection_lost(exc)
        finally:
            self._pipe.close()
            self._pipe = none
            self._protocol = none
            self._loop = none

class _UnixWritePipeTransport(_FlowControlMixin):
    # The write end of a pipe as a transport: os.write at once, the rest
    # buffered and written when the pipe is writable, flow control at the
    # water marks; the peer closing its end is seen as the pipe becoming
    # readable (CPython's unix_events).
    def __init__(self, loop, pipe, protocol, waiter=none, extra=none):
        super().__init__(extra, loop)
        self._extra["pipe"] = pipe
        self._pipe = pipe
        self._fileno = pipe.fileno()
        self._protocol = protocol
        self._buffer = bytearray()
        self._conn_lost = 0
        self._closing = false
        if not _pipe_mode_ok(self._fileno):
            self._pipe = none
            self._fileno = none
            self._protocol = none
            raise ValueError("Pipe transport is only for pipes, sockets and character devices")
        os.set_blocking(self._fileno, false)
        self._loop.call_soon(self._protocol.connection_made, self)
        self._loop.call_soon(self._loop.add_reader, self._fileno, self._read_ready)
        if waiter is not none:
            self._loop.call_soon(_set_result_unless_cancelled, waiter, none)

    def __repr__(self):
        var info = [type(self).__name__]
        if self._pipe is none:
            info.append("closed")
        elif self._closing:
            info.append("closing")
        info.append("fd=" + str(self._fileno))
        info.append("bufsize=" + str(self.get_write_buffer_size()))
        return "<" + " ".join(info) + ">"

    def get_write_buffer_size(self):
        return len(self._buffer)

    def _read_ready(self):
        # the pipe was closed by the peer
        if self._buffer:
            self._close(BrokenPipeError())
        else:
            self._close()

    def write(self, data):
        _check_data(data)
        data = bytes(data)
        if not data:
            return
        if self._conn_lost or self._closing:
            if self._conn_lost >= 5:
                logger.warning("pipe closed by peer or os.write(pipe, data) raised exception.")
            self._conn_lost = self._conn_lost + 1
            return
        if not self._buffer:
            var n = 0
            try:
                n = os.write(self._fileno, data)
            except (BlockingIOError, InterruptedError):
                n = 0
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException as exc:
                self._conn_lost = self._conn_lost + 1
                self._fatal_error(exc, "Fatal write error on pipe transport")
                return
            if n == len(data):
                return
            elif n > 0:
                data = data[n:]
            self._loop.add_writer(self._fileno, self._write_ready)
        self._buffer.extend(data)
        self._maybe_pause_protocol()

    def writelines(self, list_of_data):
        self.write(b"".join([bytes(d) for d in list_of_data]))

    def _write_ready(self):
        var n = 0
        try:
            n = os.write(self._fileno, bytes(self._buffer))
        except (BlockingIOError, InterruptedError):
            return
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            self._buffer.clear()
            self._conn_lost = self._conn_lost + 1
            self._loop.remove_writer(self._fileno)
            self._fatal_error(exc, "Fatal write error on pipe transport")
            return
        if n == len(self._buffer):
            self._buffer.clear()
            self._loop.remove_writer(self._fileno)
            self._maybe_resume_protocol()   # may append to the buffer
            if self._closing:
                self._loop.remove_reader(self._fileno)
                self._call_connection_lost(none)
            return
        elif n > 0:
            del self._buffer[:n]

    def can_write_eof(self):
        return true

    def write_eof(self):
        if self._closing:
            return
        self._closing = true
        if not self._buffer:
            self._loop.remove_reader(self._fileno)
            self._loop.call_soon(self._call_connection_lost, none)

    def set_protocol(self, protocol):
        self._protocol = protocol

    def get_protocol(self):
        return self._protocol

    def is_closing(self):
        return self._closing

    def close(self):
        if self._pipe is not none and not self._closing:
            self.write_eof()

    def abort(self):
        self._close(none)

    def _fatal_error(self, exc, message="Fatal error on pipe transport"):
        if not isinstance(exc, OSError):
            self._loop.call_exception_handler({"message": message, "exception": exc,
                                               "transport": self, "protocol": self._protocol})
        self._close(exc)

    def _close(self, exc=none):
        self._closing = true
        if self._buffer:
            self._loop.remove_writer(self._fileno)
        self._buffer.clear()
        self._loop.remove_reader(self._fileno)
        self._loop.call_soon(self._call_connection_lost, exc)

    def _call_connection_lost(self, exc):
        try:
            self._protocol.connection_lost(exc)
        finally:
            self._pipe.close()
            self._pipe = none
            self._protocol = none
            self._loop = none

class _SubprocessTransport(SubprocessTransport):
    # A child started by os_spawn: one task reads its pipes (on the
    # reactor), one writes its stdin, and the exit is noticed when the
    # pipes have closed.
    @staticmethod
    async def _start_new(loop, protocol, args, shell, stdin, stdout, stderr, kwargs):
        var t = _SubprocessTransport(loop, protocol, args, shell, stdin, stdout, stderr, kwargs)
        var waiter = loop.create_future()
        loop.call_soon(t._connect, waiter)
        try:
            await waiter
        except BaseException:
            t.close()
            await t._wait()
            raise
        return t

    def __init__(self, loop, protocol, args, shell, stdin, stdout, stderr, kwargs):
        super().__init__(none)
        self._loop = loop
        self._protocol = protocol
        self._returncode = none
        self._closed = false
        self._exit_waiters = []
        self._paused = false
        self._resume_ev = none        # pooled, while a pipe reader is paused
        self._in_buf = bytearray()
        self._in_writer = 0
        self._in_closing = false
        self._pump_h = 0
        self._pipes = {}
        self._open = {}
        self._finished = false
        var cwd = kwargs.get("cwd")
        var env = kwargs.get("env")
        for k in kwargs:
            if k not in ("cwd", "env", "close_fds", "start_new_session", "process_group", "preexec_fn",
                         "restore_signals", "pass_fds", "user", "group", "extra_groups", "umask",
                         "startupinfo", "creationflags", "executable"):
                raise TypeError("subprocess_exec() got an unexpected keyword argument '" + k + "'")
        var spm = _sp()
        var plan = spm._SubprocessPlan(stdin, stdout, stderr, false)
        var cmd = spm._native_cmd(args, shell)
        var kw = spm._native_opts(plan, cwd, env)
        if plan.keep_stdin:
            kw["stdin"] = true
        elif plan.input is not none:
            kw["input"] = plan.input
        self._plan = plan
        self._pid = os_spawn(cmd, **kw)
        self._extra["subprocess"] = self
        var fds = os_proc_fds(self._pid)
        if plan.keep_stdin:
            self._pipes[0] = _WritePipeTransport(self)
            if fds[0] >= 0:
                try:
                    os.set_blocking(fds[0], false)
                except BaseException:
                    pass
        if plan.out_capture:
            self._pipes[1] = _PipeTransport(self, 1)
            self._open[1] = true
        if plan.err_capture:
            self._pipes[2] = _PipeTransport(self, 2)
            self._open[2] = true
        self._forward = {1: plan.out_forward, 2: plan.err_forward}

    def __repr__(self):
        var info = [self.__class__.__name__]
        if self._closed:
            info.append("closed")
        info.append("pid=" + str(self._pid))
        if self._returncode is not none:
            info.append("returncode=" + str(self._returncode))
        else:
            info.append("running")
        return "<" + " ".join(info) + ">"

    def _connect(self, waiter):
        try:
            self._protocol.connection_made(self)
        except BaseException as exc:
            if not waiter.done():
                waiter.set_exception(exc)
            return
        self._pump_h = _spawn_internal(self._loop, self._pump())
        _set_result_unless_cancelled(waiter, none)

    def get_protocol(self):
        return self._protocol

    def set_protocol(self, protocol):
        self._protocol = protocol

    def is_closing(self):
        return self._closed

    def get_pid(self):
        return self._pid

    def get_returncode(self):
        return self._returncode

    def get_pipe_transport(self, fd):
        return self._pipes.get(fd)

    def _check_proc(self):
        if self._closed and self._returncode is not none:
            raise ProcessLookupError()

    def send_signal(self, signal):
        self._check_proc()
        if self._returncode is not none:
            return
        os_kill(self._pid, signal)

    def terminate(self):
        self.send_signal(15)

    def kill(self):
        self.send_signal(9)

    def close(self):
        if self._closed:
            return
        self._closed = true
        for fd in list(self._pipes.keys()):
            var p = self._pipes[fd]
            if not p._closing:
                p._closing = true
                if fd == 0:
                    self._close_stdin()
        if self._returncode is none:
            # as CPython: a transport closed while its child runs kills it
            try:
                os_kill(self._pid, 9)
            except BaseException:
                pass

    async def _wait(self):
        if self._returncode is not none:
            return self._returncode
        var waiter = self._loop.create_future()
        self._exit_waiters.append(waiter)
        return await waiter

    def _call(self, cb, *data):
        self._loop.call_soon(cb, *data)

    def _pipe_closed_by_us(self, fd):
        if fd == 0:
            self._in_closing = true
            if len(self._in_buf) == 0:
                self._close_stdin()

    def _close_stdin(self):
        try:
            os_proc_close_stdin(self._pid)
        except BaseException:
            pass
        if 0 in self._pipes and not getattr(self._pipes[0], "_lost", false):
            self._pipes[0]._lost = true
            self._call(self._protocol.pipe_connection_lost, 0, none)

    # ── stdin ──
    def _start_stdin_writer(self):
        if self._in_writer == 0:
            self._in_writer = _spawn_internal(self._loop, self._write_stdin())

    async def _write_stdin(self):
        var wp = self._pipes.get(0)
        try:
            while len(self._in_buf) > 0:
                var fds = os_proc_fds(self._pid)
                var fd = fds[0]
                var chunk = bytes(self._in_buf[:65536])
                var n = 0
                if fd >= 0:
                    try:
                        n = os.write(fd, chunk)
                    except (BlockingIOError, InterruptedError):
                        _net_select([], [fd], [], none)
                        continue
                elif fd == -2:
                    await self._loop.run_in_executor(none, os_proc_write, self._pid, chunk)
                    n = len(chunk)
                else:
                    raise BrokenPipeError(32, "Broken pipe")
                del self._in_buf[:n]
                if wp is not none:
                    wp._maybe_resume_protocol()
            if self._in_closing:
                self._close_stdin()
        except CancelledError:
            return
        except (BrokenPipeError, ConnectionResetError) as exc:
            self._in_buf = bytearray()
            if wp is not none:
                wp._maybe_resume_protocol()
                if not getattr(wp, "_lost", false):
                    wp._lost = true
                    self._call(self._protocol.pipe_connection_lost, 0, exc)
        except OSError as exc:
            self._in_buf = bytearray()
            if wp is not none and not getattr(wp, "_lost", false):
                wp._lost = true
                self._call(self._protocol.pipe_connection_lost, 0, exc)
        finally:
            self._in_writer = 0

    # ── output and exit ──
    def _deliver(self, fd, data):
        if len(data) == 0:
            return
        if fd in self._pipes and not self._pipes[fd]._closing:
            self._protocol.pipe_data_received(fd, data)
        elif self._forward.get(fd):
            var dest = self._plan.out_dest if fd == 1 else self._plan.err_dest
            if dest is none or dest == 1:
                sys.stdout.write(data.decode("utf-8", "replace"))
            elif dest == 2:
                sys.stderr.write(data.decode("utf-8", "replace"))
            else:
                try:
                    dest.write(data)
                except TypeError:
                    dest.write(data.decode("utf-8", "replace"))

    async def _pump(self):
        var pid = self._pid
        var delay = 0.001
        try:
            while true:
                var fds = os_proc_fds(pid)
                var pollable = []
                var unpollable = false
                for k in (1, 2):
                    if fds[k] >= 0:
                        pollable.append(fds[k])
                    elif fds[k] == -2:
                        unpollable = true
                if len(pollable) == 0 and not unpollable:
                    break
                if self._paused:
                    var rev = self._resume_ev
                    if rev is not none:
                        event_wait(rev)
                    continue
                if len(pollable) > 0:
                    _net_select(pollable, [], [], none if not unpollable else 0.05)
                else:
                    await sleep(delay)
                    delay = min(delay * 2, 0.05)
                var r = os_proc_read(pid)
                var out = r["stdout"].encode("utf-8")
                var err = r["stderr"].encode("utf-8")
                if len(out) > 0 or len(err) > 0:
                    delay = 0.001
                self._deliver(1, out)
                self._deliver(2, err)
                var after = os_proc_fds(pid)
                for k in (1, 2):
                    if self._open.get(k) and after[k] == -1:
                        self._open[k] = false
                        self._protocol.pipe_connection_lost(k, none)
            for k in (1, 2):
                if self._open.get(k):
                    self._open[k] = false
                    self._protocol.pipe_connection_lost(k, none)
            var code = os_poll(pid)
            var d2 = 0.001
            while code is none:
                await sleep(d2)
                d2 = min(d2 * 2, 0.05)
                code = os_poll(pid)
            self._process_exited(code)
        except CancelledError:
            return

    def _process_exited(self, returncode):
        self._returncode = returncode
        if self._resume_ev is not none:
            var ev = self._resume_ev
            self._resume_ev = none
            _ev_put(ev)
        if 0 in self._pipes and not getattr(self._pipes[0], "_lost", false):
            self._in_buf = bytearray()
            self._pipes[0]._lost = true
            self._protocol.pipe_connection_lost(0, none)
        self._protocol.process_exited()
        self._try_finish()
        var ws = self._exit_waiters
        self._exit_waiters = []
        for w in ws:
            if not w.cancelled():
                w.set_result(returncode)

    def _try_finish(self):
        if self._finished or self._returncode is none:
            return
        self._finished = true
        self._call(self._call_connection_lost, none)

    def _call_connection_lost(self, exc):
        try:
            self._protocol.connection_lost(exc)
        finally:
            self._closed = true

class SubprocessStreamProtocol(FlowControlMixin, SubprocessProtocol):
    # Like StreamReaderProtocol, for a child's three pipes.
    def __init__(self, limit, loop):
        FlowControlMixin.__init__(self, loop=loop)
        self._limit = limit
        self.stdin = none
        self.stdout = none
        self.stderr = none
        self._transport = none
        self._process_exited = false
        self._pipe_fds = []
        self._stdin_closed = self._loop.create_future()

    def __repr__(self):
        var info = []
        if self.stdin is not none:
            info.append("stdin=" + repr(self.stdin))
        if self.stdout is not none:
            info.append("stdout=" + repr(self.stdout))
        if self.stderr is not none:
            info.append("stderr=" + repr(self.stderr))
        return "<SubprocessStreamProtocol " + " ".join(info) + ">"

    def connection_made(self, transport):
        self._transport = transport
        var out_t = transport.get_pipe_transport(1)
        if out_t is not none:
            self.stdout = StreamReader(limit=self._limit, loop=self._loop)
            self.stdout.set_transport(out_t)
            self._pipe_fds.append(1)
        var err_t = transport.get_pipe_transport(2)
        if err_t is not none:
            self.stderr = StreamReader(limit=self._limit, loop=self._loop)
            self.stderr.set_transport(err_t)
            self._pipe_fds.append(2)
        var in_t = transport.get_pipe_transport(0)
        if in_t is not none:
            self.stdin = StreamWriter(in_t, self, none, self._loop)

    def pipe_data_received(self, fd, data):
        var reader = none
        if fd == 1:
            reader = self.stdout
        elif fd == 2:
            reader = self.stderr
        if reader is not none:
            reader.feed_data(data)

    def pipe_connection_lost(self, fd, exc):
        if fd == 0:
            var pipe = self.stdin
            if pipe is not none:
                pipe.close()
            self.connection_lost(exc)
            if not self._stdin_closed.done():
                if exc is none:
                    self._stdin_closed.set_result(none)
                else:
                    self._stdin_closed.set_exception(exc)
                    self._stdin_closed._log_traceback = false
            return
        var reader = none
        if fd == 1:
            reader = self.stdout
        elif fd == 2:
            reader = self.stderr
        if reader is not none:
            if exc is none:
                reader.feed_eof()
            else:
                reader.set_exception(exc)
        if fd in self._pipe_fds:
            self._pipe_fds.remove(fd)
        self._maybe_close_transport()

    def process_exited(self):
        self._process_exited = true
        self._maybe_close_transport()

    def _maybe_close_transport(self):
        if len(self._pipe_fds) == 0 and self._process_exited and self._transport is not none:
            self._transport.close()
            self._transport = none

    def _get_close_waiter(self, stream):
        if stream is self.stdin:
            return self._stdin_closed

class Process:
    # A child started by create_subprocess_exec/_shell: its stdin (a
    # StreamWriter), stdout/stderr (StreamReaders), pid, returncode.
    def __init__(self, transport, protocol, loop):
        self._transport = transport
        self._protocol = protocol
        self._loop = loop
        self.stdin = protocol.stdin
        self.stdout = protocol.stdout
        self.stderr = protocol.stderr
        self.pid = transport.get_pid()

    def __repr__(self):
        return "<Process " + str(self.pid) + ">"

    @property
    def returncode(self):
        return self._transport.get_returncode()

    async def wait(self):
        return await self._transport._wait()

    def send_signal(self, signal):
        self._transport.send_signal(signal)

    def terminate(self):
        self._transport.terminate()

    def kill(self):
        self._transport.kill()

    async def _feed_stdin(self, input):
        try:
            if input is not none:
                self.stdin.write(input)
            await self.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.stdin.close()

    async def _noop(self):
        return none

    async def _read_stream(self, fd):
        var transport = self._transport.get_pipe_transport(fd)
        var stream = self.stderr if fd == 2 else self.stdout
        var output = await stream.read()
        transport.close()
        return output

    async def communicate(self, input=none):
        var a = self._feed_stdin(input) if self.stdin is not none else self._noop()
        var b = self._read_stream(1) if self.stdout is not none else self._noop()
        var c = self._read_stream(2) if self.stderr is not none else self._noop()
        var res = await gather(a, b, c)
        await self.wait()
        return (res[1], res[2])

async def create_subprocess_shell(cmd, stdin=none, stdout=none, stderr=none, limit=_DEFAULT_LIMIT, **kwds):
    var lo = get_running_loop()
    var pair = await lo.subprocess_shell(lambda: SubprocessStreamProtocol(limit=limit, loop=lo), cmd,
                                         stdin=stdin, stdout=stdout, stderr=stderr, **kwds)
    return Process(pair[0], pair[1], lo)

async def create_subprocess_exec(program, *args, stdin=none, stdout=none, stderr=none, limit=_DEFAULT_LIMIT, **kwds):
    var lo = get_running_loop()
    var pair = await lo.subprocess_exec(lambda: SubprocessStreamProtocol(limit=limit, loop=lo), program, *args,
                                        stdin=stdin, stdout=stdout, stderr=stderr, **kwds)
    return Process(pair[0], pair[1], lo)

# ─── Runners ────────────────────────────────────────────────────────────────

class Runner:
    # with asyncio.Runner() as r: r.run(main()) - one loop for several runs;
    # close() cancels what is left, shuts the executor and closes the loop.
    # orphans= (Nython): "ignore" (CPython's behaviour, the default),
    # "warn" (the default in debug mode: each task still running when a run
    # ends, or when the task that made it ends, is reported to the loop's
    # exception handler, with where it was created) or "raise" (reported,
    # cancelled, then OrphanedTasksError). Runner.orphans lists the reports.
    def __init__(self, *, debug=none, loop_factory=none, orphans=none):
        self._state = "created"
        self._debug = debug
        self._loop_factory = loop_factory
        self._loop = none
        self._interrupt_count = 0
        self._set_event_loop = false
        self._orphan_policy = orphans
        if orphans is not none and orphans not in ("ignore", "warn", "raise"):
            raise ValueError("orphans must be 'ignore', 'warn' or 'raise', not " + repr(orphans))
        self.orphans = []

    def __enter__(self):
        self._lazy_init()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()

    def close(self):
        if self._state != "initialized":
            return
        var lo = self._loop
        try:
            _cancel_all_tasks(lo)
            lo.run_until_complete(lo.shutdown_asyncgens())
            lo.run_until_complete(lo.shutdown_default_executor())
        finally:
            if self._set_event_loop:
                set_event_loop(none)
            lo.close()
            self._loop = none
            self._state = "closed"

    def get_loop(self):
        self._lazy_init()
        return self._loop

    def run(self, coro, *, context=none):
        if not iscoroutine(coro):
            raise ValueError("a coroutine was expected, got " + repr(coro))
        if _get_running_loop() is not none:
            raise RuntimeError("Runner.run() cannot be called from a running event loop")
        self._lazy_init()
        var lo = self._loop
        var task = lo.create_task(coro, context=context)
        try:
            task._run_main = true
        except AttributeError:
            pass
        var sigint_handler = none
        if thread_os_id() == thread_main() and not _WINDOWS:
            import signal
            if signal.getsignal(signal.SIGINT) is signal.default_int_handler:
                var runner = self
                def on_sigint(signum, frame):
                    runner._interrupt_count = runner._interrupt_count + 1
                    if runner._interrupt_count == 1 and not task.done():
                        task.cancel()
                        return
                    raise KeyboardInterrupt()
                sigint_handler = on_sigint
                try:
                    signal.signal(signal.SIGINT, sigint_handler)
                except ValueError:
                    sigint_handler = none
        self._interrupt_count = 0
        var failed = true
        try:
            var result = lo.run_until_complete(task)
            failed = false
            return result
        except CancelledError:
            if self._interrupt_count > 0:
                if task.uncancel() == 0:
                    raise KeyboardInterrupt()
            raise
        finally:
            if sigint_handler is not none:
                import signal
                if signal.getsignal(signal.SIGINT) is sigint_handler:
                    signal.signal(signal.SIGINT, signal.default_int_handler)
            self._check_orphans(lo, failed)

    def _check_orphans(self, lo, failed):
        # the structured-concurrency report for what the run left behind
        if lo._orphan_policy is none or lo._orphan_policy == "ignore":
            if not lo._debug:
                return
        var left = []
        for t in all_tasks(lo):
            if not t.done():
                left.append(t)
        var found = []
        for t in left:
            lo._report_orphan(t, "outlived the run of its main task")
            found.append(lo._orphans[len(lo._orphans) - 1])
        self.orphans = list(lo._orphans)
        if lo._orphan_policy == "raise" and len(lo._orphans) > 0 and not failed:
            var reps = list(lo._orphans)
            lo._orphans = []
            _cancel_all_tasks(lo)
            var names = []
            for rp in reps:
                if repr(rp.name) not in names:
                    names.append(repr(rp.name))
            raise OrphanedTasksError(str(len(names)) + " task(s) left running: " + ", ".join(names), reps)

    def _lazy_init(self):
        if self._state == "closed":
            raise RuntimeError("Runner is closed")
        if self._state == "initialized":
            return
        if self._loop_factory is none:
            self._loop = new_event_loop()
            if not self._set_event_loop:
                set_event_loop(self._loop)
                self._set_event_loop = true
        else:
            self._loop = self._loop_factory()
        if self._debug is not none:
            self._loop.set_debug(self._debug)
        var pol = self._orphan_policy
        if pol is none and self._loop._debug:
            pol = "warn"
        self._loop._orphan_policy = pol
        self._state = "initialized"

def _cancel_all_tasks(lo):
    var to_cancel = all_tasks(lo)
    if len(to_cancel) == 0:
        return
    for t in to_cancel:
        t.cancel()
    lo.run_until_complete(gather(*to_cancel, return_exceptions=true))
    for t in to_cancel:
        if t.cancelled():
            continue
        var exc = none
        try:
            exc = t.exception()
        except BaseException:
            exc = none
        if exc is not none:
            lo.call_exception_handler({"message": "unhandled exception during asyncio.run() shutdown",
                                       "exception": exc, "task": t})

def run(main, *, debug=none, loop_factory=none, orphans=none):
    # Run the coroutine main on a new loop and return its result; the loop
    # is closed after (tasks left running are cancelled).
    if _get_running_loop() is not none:
        raise RuntimeError("asyncio.run() cannot be called from a running event loop")
    with Runner(debug=debug, loop_factory=loop_factory, orphans=orphans) as runner:
        return runner.run(main)

# ─── Submodules ─────────────────────────────────────────────────────────────
# asyncio.subprocess, asyncio.events, ... as CPython's package has them (each
# re-exports from here, so `asyncio.subprocess.PIPE` and
# `from asyncio.subprocess import PIPE` work after `import asyncio`).
from . import exceptions
from . import events
from . import futures
from . import tasks
from . import locks
from . import queues
from . import protocols
from . import transports
from . import streams
from . import subprocess
from . import runners
from . import timeouts
from . import base_events
from . import coroutines
from . import taskgroups
