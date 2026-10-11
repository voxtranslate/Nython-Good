# nython: module    (import it by name: it runs in a module scope of its own)
# lib/asyncio.ny - Python's asyncio over Nython's event loop (round 77).
#
#     import asyncio
#     async def main():
#         reader, writer = await asyncio.open_connection("example.org", 80)
#         ...
#     asyncio.run(main())
#
# Tasks are coroutines on their loop's thread (src/NyConc.cpp), and every
# blocking primitive - a socket read, a lock, a queue, sleep - parks the task
# that calls it while the loop runs the others. So the streams here are plain
# socket calls, and asyncio's Lock/Event/Queue/Semaphore sit on the runtime's
# own (they never block the loop).
#
#   Running      run, Runner, get_running_loop, get_event_loop, new_event_loop
#   Tasks        create_task, Task, current_task, all_tasks, ensure_future,
#                gather, wait, wait_for, as_completed, shield, sleep,
#                timeout / timeout_at (Timeout), TaskGroup, to_thread,
#                run_coroutine_threadsafe, Future, iscoroutine, isfuture
#   Sync         Lock, Event, Condition, Semaphore, BoundedSemaphore, Barrier
#   Queues       Queue, LifoQueue, PriorityQueue, QueueEmpty, QueueFull
#   Streams      open_connection, start_server, StreamReader, StreamWriter,
#                Server, IncompleteReadError, LimitOverrunError
#   Beyond Python: race(*aws) - the first to finish wins, the others are
#                cancelled; map_bounded(fn, items, limit) - fn over items with
#                at most `limit` running at once, results in input order.
#
# Differences from Python, on purpose or for now:
#   - a TaskGroup whose children fail raises the error itself when one child
#     failed, an ExceptionGroup (the builtin; `except*` splits it) when
#     several did, so the common case stays catchable by type;
#   - wait() returns (done, pending) as sets of Task objects;
#   - the low-level transports/protocols API (loop.create_connection with a
#     protocol factory) is not provided: streams cover the same ground;
#   - cancelling a task is one-shot: it raises CancelledError once at the
#     task's current await, as Task.cancel() with Task.uncancel() would.
import socket

TimeoutError = TimeoutError
CancelledError = CancelledError

class InvalidStateError(Exception):
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
        self.partial = partial
        self.expected = expected
        var want = "undefined"
        if expected != none:
            want = str(expected)
        super().__init__(str(len(partial)) + " bytes read on a total of " + want + " expected bytes")

class LimitOverrunError(Exception):
    def __init__(self, message, consumed):
        self.consumed = consumed
        super().__init__(message)

# the builtin (the prelude's, round 77: `except*` takes it apart)
ExceptionGroup = ExceptionGroup

FIRST_COMPLETED = "FIRST_COMPLETED"
FIRST_EXCEPTION = "FIRST_EXCEPTION"
ALL_COMPLETED = "ALL_COMPLETED"

def _now():
    return monotonic()

def _running_task():
    var h = async_current_task()
    if h == 0:
        raise RuntimeError("no running event loop")
    return h

# ─── Tasks ───────────────────────────────────────────────────────────────────

_tasks = {}          # task handle -> Task
_task_count = 0

def _forget_done():
    var gone = []
    for h in _tasks:
        if task_done(h):
            gone.append(h)
    for h in gone:
        del _tasks[h]

class Task:
    # A task: awaitable, cancellable, with a result. create_task() makes one.
    def __init__(self, handle, name=none, coro=none):
        global _task_count
        _task_count = _task_count + 1
        self._h = handle
        self._name = name
        if name == none:
            self._name = "Task-" + str(_task_count)
        self._coro = coro
        self._callbacks = []
        self._cb_running = false

    def __await__(self):
        return self._h

    def cancel(self, msg=none):
        return task_cancel(self._h)

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
            raise CancelledError()
        try:
            task_result(self._h)
        except BaseException as e:
            return e
        return none

    def get_name(self):
        return self._name

    def set_name(self, value):
        self._name = str(value)

    def get_coro(self):
        return self._coro

    def add_done_callback(self, fn, context=none):
        self._callbacks.append(fn)
        if task_done(self._h):
            call_soon(_run_callbacks_now, self)
        elif not self._cb_running:
            self._cb_running = true
            async_create_task(_callback_watcher(self))

    def remove_done_callback(self, fn):
        var keep = []
        var n = 0
        for cb in self._callbacks:
            if cb == fn:
                n = n + 1
            else:
                keep.append(cb)
        self._callbacks = keep
        return n

    def __repr__(self):
        var state = "pending"
        if task_done(self._h):
            state = "finished"
            if task_cancelled(self._h):
                state = "cancelled"
        return "<Task " + state + " name='" + self._name + "'>"

def _run_callbacks_now(t):
    var cbs = t._callbacks
    t._callbacks = []
    for cb in cbs:
        cb(t)

async def _callback_watcher(t):
    try:
        await t._h
    except BaseException:
        pass
    t._cb_running = false
    _run_callbacks_now(t)

def _wrap(h, name=none, coro=none):
    var t = _tasks.get(h)
    if t == none:
        t = Task(h, name, coro)
        if len(_tasks) > 512:
            _forget_done()
        _tasks[h] = t
    return t

def create_task(coro, name=none, context=none):
    return _wrap(async_create_task(coro), name, coro)

def ensure_future(aw, loop=none):
    if isinstance(aw, Task) or isinstance(aw, Future):
        return aw
    return create_task(aw)

def current_task(loop=none):
    var h = async_current_task()
    if h == 0:
        return none
    return _wrap(h)

def all_tasks(loop=none):
    var out = set()
    for h in _tasks:
        if not task_done(h):
            out.add(_tasks[h])
    return out

def iscoroutine(obj):
    return async_is_coroutine(obj)

def isfuture(obj):
    return isinstance(obj, Future) or isinstance(obj, Task)

def run(main, debug=none, loop_factory=none):
    return async_run(main)

def sleep(delay, result=none):
    if result == none:
        return async_sleep(delay)
    return _sleep_result(delay, result)

async def _sleep_result(delay, result):
    await async_sleep(delay)
    return result

def gather(*aws, return_exceptions=false):
    if return_exceptions:
        return gather_settled(*aws)
    return async_gather(*aws)

async def wait_for(aw, timeout):
    if timeout == none:
        return await aw
    return await async_wait_for(aw, timeout)

async def wait(aws, timeout=none, return_when=ALL_COMPLETED):
    var tasks = [ensure_future(a) for a in aws]
    if len(tasks) == 0:
        raise ValueError("Set of Tasks/Futures is empty.")
    if return_when != FIRST_COMPLETED and return_when != FIRST_EXCEPTION and return_when != ALL_COMPLETED:
        raise ValueError("Invalid return_when value: " + str(return_when))
    var ev = Event()
    def check(_t=none):
        var n_done = 0
        for t in tasks:
            if t.done():
                n_done = n_done + 1
                if return_when == FIRST_COMPLETED:
                    ev.set()
                    return
                if return_when == FIRST_EXCEPTION and not t.cancelled() and t.exception() != none:
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
            if timeout == none:
                await ev.wait()
            else:
                await async_wait_for(ev.wait(), timeout)
        except TimeoutError:
            pass
    var done = set()
    var pending = set()
    for t in tasks:
        if t.done():
            done.add(t)
        else:
            pending.add(t)
    return (done, pending)

def as_completed(aws, timeout=none):
    # The awaitables in the order they finish: each item awaits to the next
    # result (or raises its error / TimeoutError past the deadline).
    var tasks = [ensure_future(a) for a in aws]
    var q = Queue()
    for t in tasks:
        t.add_done_callback(q.put_nowait)
    var deadline = none
    if timeout != none:
        deadline = _now() + timeout
    return [_next_done(q, deadline) for t in tasks]

async def _next_done(q, deadline):
    var t = none
    if deadline == none:
        t = await q.get()
    else:
        var left = deadline - _now()
        if left <= 0:
            raise TimeoutError()
        t = await async_wait_for(q.get(), left)
    return t.result()

def shield(aw):
    # Cancelling the awaiting task does not cancel aw.
    return _shield_wait(ensure_future(aw))

async def _shield_wait(t):
    if not t.done():
        var ev = Event()
        t.add_done_callback(lambda _: ev.set())
        await ev.wait()
    return t.result()

async def race(*aws):
    # The result of the first awaitable to finish (or its error); the others
    # are cancelled.
    var tasks = [ensure_future(a) for a in aws]
    if len(tasks) == 0:
        raise ValueError("race() needs at least one awaitable")
    var r = await wait(tasks, none, FIRST_COMPLETED)
    var winner = none
    for t in tasks:
        if t.done() and winner == none:
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

# ─── Futures ─────────────────────────────────────────────────────────────────

class Future:
    # A result that is set later, by any task or thread; awaiting it waits.
    def __init__(self, loop=none):
        self._state = "PENDING"
        self._result = none
        self._exc = none
        self._ev = event_create()
        self._callbacks = []

    def done(self):
        return self._state != "PENDING"

    def cancelled(self):
        return self._state == "CANCELLED"

    def result(self):
        if self._state == "CANCELLED":
            raise CancelledError()
        if self._state == "PENDING":
            raise InvalidStateError("Result is not set.")
        if self._exc != none:
            raise self._exc
        return self._result

    def exception(self):
        if self._state == "CANCELLED":
            raise CancelledError()
        if self._state == "PENDING":
            raise InvalidStateError("Exception is not set.")
        return self._exc

    def set_result(self, result):
        if self._state != "PENDING":
            raise InvalidStateError("invalid state")
        self._result = result
        self._finish("FINISHED")

    def set_exception(self, exception):
        if self._state != "PENDING":
            raise InvalidStateError("invalid state")
        if isinstance(exception, "class"):
            exception = exception()
        self._exc = exception
        self._finish("FINISHED")

    def cancel(self, msg=none):
        if self._state != "PENDING":
            return false
        self._finish("CANCELLED")
        return true

    def _finish(self, state):
        self._state = state
        event_set(self._ev)
        if len(self._callbacks) > 0:
            var cbs = self._callbacks
            self._callbacks = []
            for cb in cbs:
                call_soon_threadsafe(cb, self)

    def add_done_callback(self, fn, context=none):
        if self._state != "PENDING":
            call_soon_threadsafe(fn, self)
        else:
            self._callbacks.append(fn)

    def remove_done_callback(self, fn):
        var keep = []
        var n = 0
        for cb in self._callbacks:
            if cb == fn:
                n = n + 1
            else:
                keep.append(cb)
        self._callbacks = keep
        return n

    def get_loop(self):
        return get_event_loop()

    def __await__(self):
        return self._wait()

    async def _wait(self):
        if self._state == "PENDING":
            event_wait(self._ev)
        return self.result()

    def __repr__(self):
        return "<Future " + string_lower(self._state) + ">"

async def to_thread(func, *args, **kwargs):
    # func(*args, **kwargs) on a thread of its own; awaiting it lets the loop
    # run meanwhile.
    var fut = Future()
    def work():
        try:
            var r = func(*args, **kwargs)
            fut._result = r
            fut._state = "FINISHED"
        except BaseException as e:
            fut._exc = e
            fut._state = "FINISHED"
        event_set(fut._ev)
    thread_create(work)
    return await fut

# Callbacks from other threads reach the loop through an inbox that a pump
# task of the running loop drains (call_soon_threadsafe,
# run_coroutine_threadsafe).
_inbox = queue_create(0, "fifo")
_pump = none

def _ensure_pump():
    global _pump
    if async_current_task() == 0:
        return
    if _pump == none or task_done(_pump):
        _pump = async_create_task(_pump_loop())

async def _pump_loop():
    while true:
        var item = queue_get(_inbox)
        try:
            item[0](*item[1])
        except Exception as e:
            print("Exception in callback " + str(item[0]) + ": " + repr(e))

def call_soon(callback, *args):
    if async_current_task() == 0:
        return call_soon_threadsafe(callback, *args)
    return async_call_later(0, callback, *args)

def call_soon_threadsafe(callback, *args):
    queue_put(_inbox, [callback, args])
    _ensure_pump()

def run_coroutine_threadsafe(coro, loop=none):
    # From another thread: run coro on the loop; returns a thread Future
    # (result(timeout) blocks that thread).
    var fut = future_create()
    async def bridge():
        try:
            future_set_result(fut, await coro)
        except BaseException as e:
            future_set_exception(fut, type(e).__name__ + ": " + str(e))
    call_soon_threadsafe(lambda: async_create_task(bridge()))
    return _ThreadFuture(fut)

class _ThreadFuture:
    def __init__(self, h):
        self.id = h

    def result(self, timeout=none):
        var ms = -1
        if timeout != none:
            ms = timeout * 1000
        return future_result(self.id, ms)

    def done(self):
        return future_done(self.id)

    def cancel(self):
        return future_cancel(self.id)

    def cancelled(self):
        return future_cancelled(self.id)

# ─── Timeouts ────────────────────────────────────────────────────────────────

class Timeout:
    # async with asyncio.timeout(1.5): ... - the block is cancelled when the
    # deadline passes, and the cancellation leaves it as TimeoutError.
    def __init__(self, when):
        self._when = when
        self._task = 0
        self._timer = none
        self._expired = false

    def when(self):
        return self._when

    def expired(self):
        return self._expired

    def reschedule(self, when):
        self._disarm()
        self._when = when
        if self._task != 0:
            self._arm()

    def _arm(self):
        if self._when == none:
            return
        var delay = self._when - _now()
        if delay < 0:
            delay = 0
        self._timer = async_call_later(delay, self._fire)

    def _disarm(self):
        if self._timer != none:
            task_cancel(self._timer)
            self._timer = none

    def _fire(self):
        self._timer = none
        self._expired = true
        task_cancel(self._task)

    async def __aenter__(self):
        self._task = _running_task()
        self._arm()
        return self

    async def __aexit__(self, et, ev, tb):
        self._disarm()
        if self._expired and et != none and issubclass(et, CancelledError):
            raise TimeoutError()
        return false

def timeout(delay):
    if delay == none:
        return Timeout(none)
    return Timeout(_now() + delay)

def timeout_at(when):
    return Timeout(when)

# ─── Task groups ─────────────────────────────────────────────────────────────

class TaskGroup:
    # async with asyncio.TaskGroup() as tg: tg.create_task(...) - the block
    # ends when every child has; the first child to fail cancels the others
    # and the block.
    def __init__(self):
        self._tasks = []
        self._errors = []
        self._parent = 0
        self._in_body = false
        self._parent_cancelled = false
        self._closed = false

    async def __aenter__(self):
        self._parent = _running_task()
        self._in_body = true
        return self

    def create_task(self, coro, name=none, context=none):
        if self._closed:
            raise RuntimeError("TaskGroup is finished")
        var t = create_task(_tg_child(self, coro), name)
        self._tasks.append(t)
        return t

    def _abort(self):
        for t in self._tasks:
            if not t.done():
                t.cancel()
        if self._in_body and not self._parent_cancelled:
            self._parent_cancelled = true
            task_cancel(self._parent)

    async def __aexit__(self, et, ev, tb):
        self._in_body = false
        var body_error = none
        if et != none and not (self._parent_cancelled and issubclass(et, CancelledError)):
            body_error = ev
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
        if len(self._errors) == 1 and body_error == none:
            raise self._errors[0]
        if len(self._errors) > 0:
            var errs = self._errors
            if body_error != none:
                errs = [body_error] + errs
            raise ExceptionGroup("unhandled errors in a TaskGroup", errs)
        if self._parent_cancelled:
            return true
        return false

async def _tg_child(group, coro):
    try:
        return await coro
    except CancelledError:
        raise
    except BaseException as e:
        group._errors.append(e)
        group._abort()
        raise

# ─── Synchronisation ─────────────────────────────────────────────────────────

class Event:
    def __init__(self):
        self._id = event_create()

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
        if lock == none:
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
    # parties tasks call wait(); all return together, each with its index.
    def __init__(self, parties):
        if parties < 1:
            raise ValueError("parties must be > 0")
        self.parties = parties
        self.n_waiting = 0
        self.broken = false
        self._cond = Condition()
        self._round = 0

    async def wait(self):
        async with self._cond:
            if self.broken:
                raise BrokenBarrierError()
            var my_round = self._round
            var index = self.n_waiting
            self.n_waiting = self.n_waiting + 1
            if self.n_waiting == self.parties:
                self.n_waiting = 0
                self._round = self._round + 1
                self._cond.notify_all()
            else:
                while self._round == my_round and not self.broken:
                    await self._cond.wait()
                if self.broken:
                    raise BrokenBarrierError()
            return index

    async def abort(self):
        async with self._cond:
            self.broken = true
            self._cond.notify_all()

    async def reset(self):
        async with self._cond:
            if self.n_waiting > 0:
                self.broken = true
                self._cond.notify_all()
            self.broken = false
            self.n_waiting = 0

# ─── Queues ──────────────────────────────────────────────────────────────────

class Queue:
    # put()/get() wait (park the task) when the queue is full/empty;
    # task_done()/join() count the items consumers have finished.
    def __init__(self, maxsize=0):
        self.maxsize = maxsize
        self._q = queue_create(maxsize, self._kind())
        self._unfinished = 0
        self._all_done = Event()
        self._all_done.set()
        self._shutdown = false

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
        return self.maxsize > 0 and queue_size(self._q) >= self.maxsize

    def _count_in(self):
        self._unfinished = self._unfinished + 1
        self._all_done.clear()

    async def put(self, item):
        if self._shutdown:
            raise QueueShutDown()
        queue_put(self._q, self._prep(item))
        self._count_in()

    def put_nowait(self, item):
        if self._shutdown:
            raise QueueShutDown()
        if not queue_try_put(self._q, self._prep(item)):
            raise QueueFull()
        self._count_in()

    async def get(self):
        if self._shutdown and queue_empty(self._q):
            raise QueueShutDown()
        return self._unprep(queue_get(self._q))

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
        self._shutdown = true
        if immediate:
            var r = queue_try_get(self._q)
            while r[1]:
                self.task_done()
                r = queue_try_get(self._q)

class LifoQueue(Queue):
    def _kind(self):
        return "lifo"

class PriorityQueue(Queue):
    # Items are compared as they are: (priority, data) tuples, numbers, ...
    def _kind(self):
        return "priority"

    def _prep(self, item):
        if isinstance(item, "tuple") or isinstance(item, "list"):
            return [item[0], item]
        return [item, item]

    def _unprep(self, entry):
        return entry[1]

# ─── Event loop object ───────────────────────────────────────────────────────

class _TimerHandle:
    def __init__(self, h, when):
        self._h = h
        self._when = when
        self._cancelled = false

    def cancel(self):
        self._cancelled = true
        task_cancel(self._h)

    def cancelled(self):
        return self._cancelled

    def when(self):
        return self._when

class AbstractEventLoop:
    def __init__(self):
        self._debug = false
        self._exception_handler = none
        self._signals = {}

    def time(self):
        return _now()

    def is_running(self):
        return async_current_task() != 0

    def is_closed(self):
        return false

    def close(self):
        pass

    def stop(self):
        pass

    def get_debug(self):
        return self._debug

    def set_debug(self, enabled):
        self._debug = enabled

    def create_task(self, coro, name=none, context=none):
        return create_task(coro, name)

    def create_future(self):
        return Future()

    def call_soon(self, callback, *args, context=none):
        return _TimerHandle(call_soon(callback, *args), _now())

    def call_later(self, delay, callback, *args, context=none):
        return _TimerHandle(async_call_later(delay, callback, *args), _now() + delay)

    def call_at(self, when, callback, *args, context=none):
        var delay = when - _now()
        if delay < 0:
            delay = 0
        return _TimerHandle(async_call_later(delay, callback, *args), when)

    def call_soon_threadsafe(self, callback, *args, context=none):
        call_soon_threadsafe(callback, *args)

    def run_until_complete(self, future):
        return async_run(future)

    def run_in_executor(self, executor, func, *args):
        if executor != none:
            return _executor_await(executor.submit(func, *args))
        return to_thread(func, *args)

    def set_exception_handler(self, handler):
        self._exception_handler = handler

    def get_exception_handler(self):
        return self._exception_handler

    def default_exception_handler(self, context):
        print("Exception in event loop: " + str(context.get("message", "")))

    def call_exception_handler(self, context):
        if self._exception_handler != none:
            self._exception_handler(self, context)
        else:
            self.default_exception_handler(context)

    def add_signal_handler(self, sig, callback, *args):
        import signal
        signal.signal(sig, lambda s, f: callback(*args))
        self._signals[sig] = callback

    def remove_signal_handler(self, sig):
        import signal
        if sig not in self._signals:
            return false
        del self._signals[sig]
        signal.signal(sig, signal.SIG_DFL)
        return true

    async def sock_recv(self, sock, nbytes):
        return sock.recv(nbytes)

    async def sock_sendall(self, sock, data):
        sock.sendall(data)

    async def sock_connect(self, sock, address):
        sock.connect(address)

    async def sock_accept(self, sock):
        return sock.accept()

    async def getaddrinfo(self, host, port, family=0, type=0, proto=0, flags=0):
        return socket.getaddrinfo(host, port, family, type, proto, flags)

    async def getnameinfo(self, sockaddr, flags=0):
        return socket.getnameinfo(sockaddr, flags)

    async def shutdown_asyncgens(self):
        pass

    async def shutdown_default_executor(self, timeout=none):
        pass

async def _executor_await(f):
    # A concurrent Future (lib/thread.ny's or any with done()/result()).
    while not f.done():
        await async_sleep(0.005)
    return f.result()

_loop = AbstractEventLoop()

def get_running_loop():
    _running_task()
    _ensure_pump()
    return _loop

def get_event_loop():
    if async_current_task() != 0:
        _ensure_pump()
    return _loop

def new_event_loop():
    return AbstractEventLoop()

def set_event_loop(loop):
    global _loop
    if loop != none:
        _loop = loop

class Runner:
    # with asyncio.Runner() as r: r.run(main())
    def __init__(self, debug=none, loop_factory=none):
        self._closed = false

    def run(self, coro, context=none):
        if self._closed:
            raise RuntimeError("Runner is closed")
        return async_run(coro)

    def close(self):
        self._closed = true

    def get_loop(self):
        return _loop

    def __enter__(self):
        return self

    def __exit__(self, et, ev, tb):
        self.close()
        return false

# ─── Streams ─────────────────────────────────────────────────────────────────

_LIMIT = 65536

class StreamReader:
    def __init__(self, sock=none, limit=_LIMIT):
        self._sock = sock
        self._buf = b""
        self._eof = false
        self._limit = limit
        self._exc = none

    def _fill(self):
        # One more chunk from the socket; false at end of stream.
        if self._exc != none:
            raise self._exc
        if self._eof or self._sock == none:
            return false
        var data = self._sock.recv(self._limit)
        if len(data) == 0:
            self._eof = true
            return false
        self._buf = self._buf + data
        return true

    def _take(self, n):
        var out = self._buf[0:n]
        self._buf = self._buf[n:]
        return out

    def feed_data(self, data):
        self._buf = self._buf + bytes(data)

    def feed_eof(self):
        self._eof = true

    def at_eof(self):
        return self._eof and len(self._buf) == 0

    def exception(self):
        return self._exc

    def set_exception(self, exc):
        self._exc = exc

    async def read(self, n=-1):
        if n == 0:
            return b""
        if n < 0:
            while self._fill():
                pass
            return self._take(len(self._buf))
        if len(self._buf) == 0:
            self._fill()
        return self._take(n)

    async def readline(self):
        try:
            return await self.readuntil(b"\n")
        except IncompleteReadError as e:
            return e.partial
        except LimitOverrunError as e:
            var line = self._buf
            var cut = self._buf.find(b"\n")
            if cut >= 0:
                self._take(cut + 1)
            else:
                self._buf = b""
            raise ValueError(str(e))

    async def readuntil(self, separator=b"\n"):
        if len(separator) == 0:
            raise ValueError("Separator should be at least one-byte string")
        var start = 0
        while true:
            var at = self._buf.find(separator, start)
            if at >= 0:
                var end = at + len(separator)
                if end > self._limit:
                    raise LimitOverrunError("Separator is found, but chunk is longer than limit", at)
                return self._take(end)
            if len(self._buf) > self._limit:
                raise LimitOverrunError("Separator is not found, and chunk exceed the limit", len(self._buf))
            start = len(self._buf) - len(separator) + 1
            if start < 0:
                start = 0
            if not self._fill():
                var partial = self._take(len(self._buf))
                raise IncompleteReadError(partial, none)

    async def readexactly(self, n):
        if n < 0:
            raise ValueError("readexactly size can not be less than zero")
        while len(self._buf) < n:
            if not self._fill():
                var partial = self._take(len(self._buf))
                raise IncompleteReadError(partial, n)
        return self._take(n)

    def __aiter__(self):
        return self

    async def __anext__(self):
        var line = await self.readline()
        if len(line) == 0:
            raise StopAsyncIteration()
        return line

class StreamWriter:
    def __init__(self, sock, reader=none):
        self._sock = sock
        self._reader = reader
        self._closing = false
        self.transport = self

    def write(self, data):
        if self._closing:
            raise ConnectionResetError("writing to a closed stream")
        self._sock.sendall(bytes(data))

    def writelines(self, data):
        for d in data:
            self.write(d)

    async def drain(self):
        pass

    def can_write_eof(self):
        return true

    def write_eof(self):
        self._sock.shutdown(socket.SHUT_WR)

    def close(self):
        if not self._closing:
            self._closing = true
            self._sock.close()

    def is_closing(self):
        return self._closing

    async def wait_closed(self):
        pass

    def get_extra_info(self, name, default=none):
        try:
            if name == "peername":
                return self._sock.getpeername()
            if name == "sockname":
                return self._sock.getsockname()
            if name == "socket":
                return self._sock
        except OSError:
            return default
        return default

    def __repr__(self):
        return "<StreamWriter " + repr(self._sock) + ">"

async def open_connection(host=none, port=none, limit=_LIMIT, ssl=none, server_hostname=none, **kwargs):
    # (reader, writer) for a TCP connection; resolving the name and
    # connecting park the task, not the loop.
    var timeout = kwargs.get("timeout", none)
    var sock = socket.create_connection((host, port), timeout)
    sock.settimeout(none)
    if ssl != none and ssl != false:
        import ssl as _ssl
        var ctx = ssl
        if ssl == true:
            ctx = _ssl.create_default_context()
        if server_hostname == none:
            server_hostname = host
        try:
            sock = ctx.wrap_socket(sock, server_hostname=server_hostname)
        except BaseException:
            sock.close()
            raise
    return (StreamReader(sock, limit), StreamWriter(sock))

class Server:
    def __init__(self, sock, client_connected_cb, limit, ssl=none):
        self.sockets = [sock]
        self._sock = sock
        self._cb = client_connected_cb
        self._limit = limit
        self._ssl = ssl
        self._accept_task = none
        self._serving = false
        self._clients = []

    def _start(self):
        if self._accept_task == none:
            self._serving = true
            self._accept_task = create_task(self._accept_loop())

    async def _accept_loop(self):
        while self._serving:
            var pair = self._sock.accept()
            var conn = pair[0]
            conn.settimeout(none)
            self._clients.append(create_task(self._serve_client(conn)))
            if len(self._clients) > 64:
                var live = []
                for t in self._clients:
                    if not t.done():
                        live.append(t)
                self._clients = live

    # One client: the TLS handshake (in its own task, so a slow client does
    # not hold up the others), then the callback.
    async def _serve_client(self, conn):
        if self._ssl != none:
            try:
                conn = self._ssl.wrap_socket(conn, server_side=true, do_handshake_on_connect=false)
                conn.do_handshake()
            except Exception:
                conn.close()
                return
        var r = self._cb(StreamReader(conn, self._limit), StreamWriter(conn))
        if async_is_coroutine(r):
            await r

    def is_serving(self):
        return self._serving

    async def start_serving(self):
        self._start()

    async def serve_forever(self):
        self._start()
        await self._accept_task

    def close(self):
        if self._serving:
            self._serving = false
            if self._accept_task != none:
                self._accept_task.cancel()
            self._sock.close()

    async def wait_closed(self):
        for t in self._clients:
            if not t.done():
                try:
                    await t
                except BaseException:
                    pass

    def get_loop(self):
        return _loop

    async def __aenter__(self):
        return self

    async def __aexit__(self, et, ev, tb):
        self.close()
        await self.wait_closed()
        return false

async def start_server(client_connected_cb, host=none, port=none, limit=_LIMIT, family=0, backlog=100, reuse_address=none, start_serving=true, **kwargs):
    # client_connected_cb(reader, writer), a function or a coroutine function,
    # for each connection; port 0 picks a free port (server.sockets[0]).
    if host == none:
        host = "0.0.0.0"
    var sock = socket.create_server((host, port), socket.AF_INET, backlog)
    var server = Server(sock, client_connected_cb, limit, kwargs.get("ssl", none))
    if start_serving:
        server._start()
    return server
