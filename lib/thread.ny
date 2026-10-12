# ═══════════════════════════════════════════════════════════════════════════════
# thread.ny — threads and synchronisation for Nython
#
# Every class here is a thin layer over the native runtime (src/NyConc.cpp),
# which behaves the same on the interpreter and the VM: real OS threads under
# one GIL, blocking primitives that release it, timeouts, cooperative
# cancellation and deadlock detection.
#
#   Threads      Thread, go(), ThreadLocal, TaskGroup / task_group()
#   Locks        Lock, Mutex, RLock, RWLock, Condition
#   Signalling   Semaphore, BoundedSemaphore, BinarySemaphore, ThreadEvent,
#                Barrier, CountDownLatch
#   Atomics      AtomicInt, AtomicBool
#   Queues       Queue, LifoQueue, PriorityQueue (they also answer
#                lib/stdlib.ny's API: enqueue/dequeue/peek/is_empty/length/size,
#                push/pop, so importing both libraries keeps working)
#   Channels     Channel, UnboundedChannel, select()
#   Futures      Future, ThreadPoolExecutor, ThreadPool, as_completed()
#   Timers       Timer (a thread timer given interval + function; without them
#                it is lib/stdlib.ny's stopwatch), Scheduler (cooperative)
#   Maps         ConcurrentMap
#
# Timeouts are in SECONDS here (Python's convention); the natives take ms.
# The event class is ThreadEvent, not Event: lib/gui.ny already defines Event.
#
# Usage: import "lib/thread.ny"      (or: import threads)
# ═══════════════════════════════════════════════════════════════════════════════
import threading

def _ms(timeout):
    if timeout == none:
        return -1
    return timeout * 1000

def _handle(x):
    if type(x) == "int":
        return x
    return x.id

# ─── Threads ─────────────────────────────────────────────────────────────────

class Thread:
    # Thread(target, args=[], name=none, daemon=false). A subclass may override
    # run() instead of passing a target. Thread(fn) + start() is the old API.
    def __init__(self, target=none, args=none, name=none, daemon=false):
        self.target = target
        self.fn = target
        self.args = args
        self.name = name
        self.daemon = daemon
        self.id = -1
        self.running = false

    def run(self):
        var a = self.args
        if a == none:
            a = []
        return self.target(*a)

    def start(self, arg=none):
        var fn = self.target
        var a = self.args
        if fn == none:
            fn = self.run
            a = []
        if a == none:
            a = []
        if self.name != none:
            self.id = thread_create_named(self.name, fn, *a)
        else:
            self.id = thread_create(fn, *a)
        if self.daemon:
            thread_set_daemon(self.id, true)
        self.running = true
        return self

    # Waits for the thread and returns its result; re-raises its exception.
    # With a timeout (seconds) that expires, returns none (check is_alive()).
    def join(self, timeout=none):
        if timeout == none:
            return thread_join(self.id)
        try:
            return thread_join(self.id, timeout * 1000)
        except e:
            if thread_is_alive(self.id):
                return none
            return thread_join(self.id)

    def result(self):
        return thread_join(self.id)

    def is_alive(self):
        if self.id < 0:
            return false
        return thread_is_alive(self.id)

    def is_running(self):
        return self.is_alive()

    def cancel(self):
        return thread_cancel(self.id)

    def get_name(self):
        return thread_name(self.id)

    def ident(self):
        return self.id

    def sleep(self, ms):
        thread_sleep(ms)

# Go-style: start fn(*args) on a new thread, return its handle.
def go(fn, *args):
    return thread_create(fn, *args)

def current_thread():
    return thread_id()

def main_thread():
    return thread_main()

var _tl_counter = atomic_new(0)

class ThreadLocal:
    # Per-thread values: tl.set("x", 1) in one thread is invisible to others.
    def __init__(self):
        self.key = "tl" + str(atomic_inc(_tl_counter)) + ":"

    def get(self, name, default=none):
        return thread_local_get(self.key + name, default)

    def set(self, name, value):
        thread_local_set(self.key + name, value)

    def has(self, name):
        return thread_local_has(self.key + name)

    def delete(self, name):
        return thread_local_del(self.key + name)

# Structured concurrency (Trio's nursery / Python's TaskGroup):
#     with task_group() as g:
#         g.spawn(work, 1)
#         g.spawn(work, 2)
#     # every child has finished here; the first failure is re-raised and the
#     # other children were cancelled at their next blocking call.
class TaskGroup:
    def __init__(self):
        self.id = taskgroup_create()
        self.results = none

    def spawn(self, fn, *args):
        return taskgroup_spawn(self.id, fn, *args)

    def cancel(self):
        taskgroup_cancel(self.id)

    def join(self):
        self.results = taskgroup_join(self.id)
        return self.results

    def size(self):
        return taskgroup_size(self.id)

    def __enter__(self):
        return self

    def __exit__(self, t=none, v=none, tb=none):
        if t != none:
            # The body failed: stop the children and let the body's error win.
            taskgroup_cancel(self.id)
            try:
                taskgroup_join(self.id)
            except e:
                pass
            return false
        self.results = taskgroup_join(self.id)

def task_group():
    return TaskGroup()

# ─── Locks ───────────────────────────────────────────────────────────────────

class Lock:
    def __init__(self):
        self.id = mutex_create()

    def acquire(self, blocking=true, timeout=none):
        if not blocking:
            return mutex_try_lock(self.id)
        if timeout != none:
            return mutex_lock_timeout(self.id, timeout * 1000)
        return mutex_lock(self.id)

    def release(self):
        mutex_unlock(self.id)

    def locked(self):
        return mutex_locked(self.id)

    def lock(self):
        mutex_lock(self.id)

    def unlock(self):
        mutex_unlock(self.id)

    def try_lock(self):
        return mutex_try_lock(self.id)

    def __enter__(self):
        mutex_lock(self.id)
        return self

    def __exit__(self, t=none, v=none, tb=none):
        mutex_unlock(self.id)

class Mutex(Lock):
    def __init__(self):
        self.id = mutex_create()

class RLock(Lock):
    def __init__(self):
        self.id = rmutex_create()

class _RWRead:
    def __init__(self, rw):
        self.rw = rw
    def __enter__(self):
        rwlock_read_lock(self.rw)
        return self
    def __exit__(self, t=none, v=none, tb=none):
        rwlock_read_unlock(self.rw)

class _RWWrite:
    def __init__(self, rw):
        self.rw = rw
    def __enter__(self):
        rwlock_write_lock(self.rw)
        return self
    def __exit__(self, t=none, v=none, tb=none):
        rwlock_write_unlock(self.rw)

class RWLock:
    # Many readers or one writer; a waiting writer holds back new readers.
    #     with rw.reading(): ...        with rw.writing(): ...
    def __init__(self):
        self.id = rwlock_create()

    def read_lock(self):
        rwlock_read_lock(self.id)

    def read_unlock(self):
        rwlock_read_unlock(self.id)

    def write_lock(self):
        rwlock_write_lock(self.id)

    def write_unlock(self):
        rwlock_write_unlock(self.id)

    def acquire_read(self, timeout=none):
        if timeout == none:
            return rwlock_read_lock(self.id)
        return rwlock_read_lock_timeout(self.id, timeout * 1000)

    def acquire_write(self, timeout=none):
        if timeout == none:
            return rwlock_write_lock(self.id)
        return rwlock_write_lock_timeout(self.id, timeout * 1000)

    def release_read(self):
        rwlock_read_unlock(self.id)

    def release_write(self):
        rwlock_write_unlock(self.id)

    def readers(self):
        return rwlock_readers(self.id)

    def reading(self):
        return _RWRead(self.id)

    def writing(self):
        return _RWWrite(self.id)

class Condition:
    # Condition(lock=RLock()). wait() releases the lock while waiting and holds
    # it again on return; wait(timeout) returns false when it timed out.
    def __init__(self, lock=none):
        if lock == none:
            lock = RLock()
        self.lock = lock
        self.id = cond_create()

    def acquire(self, blocking=true, timeout=none):
        return self.lock.acquire(blocking, timeout)

    def release(self):
        self.lock.release()

    def wait(self, timeout=none):
        if timeout == none:
            return cond_wait(self.id, self.lock.id)
        return cond_wait_timeout(self.id, self.lock.id, timeout * 1000)

    def wait_for(self, predicate, timeout=none):
        var deadline = none
        if timeout != none:
            deadline = time_ms() + timeout * 1000
        var ok = predicate()
        while not ok:
            if deadline == none:
                cond_wait(self.id, self.lock.id)
            else:
                var left = deadline - time_ms()
                if left <= 0:
                    return predicate()
                cond_wait_timeout(self.id, self.lock.id, left)
            ok = predicate()
        return ok

    def notify(self, n=1):
        return cond_notify(self.id, n)

    def notify_all(self):
        return cond_notify_all(self.id)

    def __enter__(self):
        self.lock.acquire()
        return self

    def __exit__(self, t=none, v=none, tb=none):
        self.lock.release()

# ─── Signalling ──────────────────────────────────────────────────────────────

class Semaphore:
    def __init__(self, count=1):
        self.id = semaphore_create(count)
        self.max_count = count

    def acquire(self, blocking=true, timeout=none):
        if not blocking:
            return semaphore_try_acquire(self.id)
        if timeout != none:
            return semaphore_acquire_timeout(self.id, timeout * 1000)
        return semaphore_acquire(self.id)

    def try_acquire(self):
        return semaphore_try_acquire(self.id)

    def release(self, n=1):
        return semaphore_release(self.id, n)

    def available(self):
        return semaphore_value(self.id)

    def value(self):
        return semaphore_value(self.id)

    def __enter__(self):
        semaphore_acquire(self.id)
        return self

    def __exit__(self, t=none, v=none, tb=none):
        semaphore_release(self.id)

class BoundedSemaphore(Semaphore):
    # Releasing more than the initial count raises ValueError.
    def __init__(self, count=1):
        self.id = semaphore_create(count, count)
        self.max_count = count

    def release(self, n=1):
        if not semaphore_release(self.id, n):
            raise ValueError("BoundedSemaphore released too many times")
        return true

class BinarySemaphore(Semaphore):
    def __init__(self):
        self.id = semaphore_create(1, 1)
        self.max_count = 1

    def wait(self):
        semaphore_acquire(self.id)

    def signal(self):
        semaphore_release(self.id)

class ThreadEvent:
    def __init__(self):
        self.id = event_create()

    def set(self):
        event_set(self.id)

    def clear(self):
        event_clear(self.id)

    def is_set(self):
        return event_is_set(self.id)

    def wait(self, timeout=none):
        if timeout == none:
            return event_wait(self.id)
        return event_wait_timeout(self.id, timeout * 1000)

class Barrier:
    # wait() returns the generation that completed (0, 1, 2, ...); with a
    # timeout that expires it withdraws and returns -1.
    def __init__(self, n):
        self.n = n
        self.id = barrier_create(n)

    def wait(self, timeout=none):
        if timeout == none:
            return barrier_wait(self.id)
        return barrier_wait_timeout(self.id, timeout * 1000)

    def parties(self):
        return barrier_parties(self.id)

    def n_waiting(self):
        return barrier_waiting(self.id)

class CountDownLatch:
    def __init__(self, count):
        self.id = latch_create(count)

    def count_down(self):
        latch_count_down(self.id)

    def await(self):
        latch_wait(self.id)

    def wait(self, timeout=none):
        if timeout == none:
            return latch_wait(self.id)
        return latch_wait_timeout(self.id, timeout * 1000)

    def get_count(self):
        return latch_count(self.id)

# ─── Atomics ─────────────────────────────────────────────────────────────────

class AtomicInt:
    def __init__(self, initial=0):
        self.id = atomic_new(initial)

    def get(self):
        return atomic_get(self.id)

    def set(self, val):
        atomic_set(self.id, val)

    def inc(self):
        return atomic_inc(self.id)

    def dec(self):
        return atomic_dec(self.id)

    def add(self, n):
        return atomic_add(self.id, n)

    def exchange(self, val):
        return atomic_exchange(self.id, val)

    def compare_and_swap(self, expected, new_val):
        return atomic_cas(self.id, expected, new_val)

class AtomicBool:
    def __init__(self, initial=false):
        var v = 0
        if initial:
            v = 1
        self.id = atomic_new(v)

    def get(self):
        return atomic_get(self.id) == 1

    def set(self, val):
        if val:
            atomic_set(self.id, 1)
        else:
            atomic_set(self.id, 0)

    def flip(self):
        var done = false
        while not done:
            var cur = atomic_get(self.id)
            done = atomic_cas(self.id, cur, 1 - cur)
        return atomic_get(self.id) == 1

    def compare_and_swap(self, expected, new_val):
        var e = 0
        var n = 0
        if expected:
            e = 1
        if new_val:
            n = 1
        return atomic_cas(self.id, e, n)

# ─── Queues ──────────────────────────────────────────────────────────────────

class Queue:
    # Queue(maxsize=0): blocking FIFO (maxsize <= 0: unbounded). put/get block;
    # with a timeout (seconds) that expires, put returns false and get raises
    # TimeoutError. Also answers lib/stdlib.ny's Queue API.
    def __init__(self, maxsize=0):
        self.id = queue_create(maxsize, "fifo")
        self.maxsize = maxsize
        self.size = 0

    def put(self, item, block=true, timeout=none):
        var ok = true
        if not block:
            ok = queue_try_put(self.id, item)
        elif timeout != none:
            ok = queue_put_timeout(self.id, item, timeout * 1000)
        else:
            queue_put(self.id, item)
        self.size = queue_size(self.id)
        return ok

    def get(self, block=true, timeout=none):
        var r = none
        if not block:
            r = queue_try_get(self.id)
        elif timeout != none:
            r = queue_get_timeout(self.id, timeout * 1000)
        else:
            var v = queue_get(self.id)
            self.size = queue_size(self.id)
            return v
        self.size = queue_size(self.id)
        if not r[1]:
            raise TimeoutError("queue is empty")
        return r[0]

    def put_nowait(self, item):
        return self.put(item, false)

    def get_nowait(self):
        return self.get(false)

    def qsize(self):
        return queue_size(self.id)

    def empty(self):
        return queue_empty(self.id)

    def full(self):
        return queue_full(self.id)

    def close(self):
        return queue_close(self.id)

    # lib/stdlib.ny compatibility (non-blocking)
    def enqueue(self, val):
        queue_put(self.id, val)
        self.size = queue_size(self.id)

    def dequeue(self):
        var r = queue_try_get(self.id)
        self.size = queue_size(self.id)
        return r[0]

    def peek(self):
        return queue_peek(self.id)[0]

    def front(self):
        return self.peek()

    def is_empty(self):
        return queue_empty(self.id)

    def length(self):
        return queue_size(self.id)

class LifoQueue(Queue):
    def __init__(self, maxsize=0):
        self.id = queue_create(maxsize, "lifo")
        self.maxsize = maxsize
        self.size = 0

class PriorityQueue(Queue):
    # Items are numbers or [priority, value] lists; lowest priority first, ties
    # in insertion order. push(priority, value)/pop() is lib/stdlib.ny's API.
    def __init__(self, maxsize=0):
        self.id = queue_create(maxsize, "priority")
        self.maxsize = maxsize
        self.size = 0

    def push(self, priority, value):
        queue_put(self.id, [priority, value])
        self.size = queue_size(self.id)

    def pop(self):
        var r = queue_try_get(self.id)
        self.size = queue_size(self.id)
        if not r[1]:
            return none
        return r[0][1]

# ─── Channels ────────────────────────────────────────────────────────────────

class Channel:
    # Channel(capacity=0): 0 is unbuffered (a send waits for a receiver, as in
    # Go), n > 0 buffers n values, -1 is unbounded. recv() returns none once the
    # channel is closed and drained; recv_ok() returns [value, ok].
    def __init__(self, capacity=0):
        self.capacity = capacity
        self.id = chan_create(capacity)

    def send(self, val, timeout=none):
        if chan_closed(self.id):
            return false
        if timeout == none:
            return chan_send(self.id, val)
        return chan_send_timeout(self.id, val, timeout * 1000)

    def try_send(self, val):
        if chan_closed(self.id):
            return false
        return chan_try_send(self.id, val)

    def recv(self, timeout=none):
        if timeout == none:
            return chan_recv(self.id)
        return chan_recv_timeout(self.id, timeout * 1000)[0]

    def recv_ok(self):
        return chan_recv_ok(self.id)

    def try_recv(self):
        return chan_try_recv(self.id)[0]

    def close(self):
        return chan_close(self.id)

    def is_closed(self):
        return chan_closed(self.id)

    def is_drained(self):
        return chan_drained(self.id)

    def size(self):
        return chan_len(self.id)

    def cap(self):
        return chan_cap(self.id)

    def is_full(self):
        return self.capacity > 0 and chan_len(self.id) >= self.capacity

    def is_empty(self):
        return chan_len(self.id) == 0

    # Receive until the channel is closed and drained.
    def drain(self):
        var out = []
        var r = chan_recv_ok(self.id)
        while r[1]:
            out.append(r[0])
            r = chan_recv_ok(self.id)
        return out

class UnboundedChannel(Channel):
    def __init__(self):
        self.capacity = -1
        self.id = chan_create(-1)

# select([["recv", ch], ["send", ch, value], ...], timeout=none) ->
#   [index, value, ok]; index -1 when the timeout expired. timeout=0 is Go's
#   `default:` (return at once if nothing is ready). The first ready case in
#   list order wins, so the choice is deterministic. ch: Channel or handle.
def select(cases, timeout=none):
    var hs = []
    for c in cases:
        if len(c) > 2:
            hs.append([c[0], _handle(c[1]), c[2]])
        else:
            hs.append([c[0], _handle(c[1])])
    return chan_select(hs, _ms(timeout))

# ─── Futures and pools ───────────────────────────────────────────────────────

def _future_cb(fut, fn):
    def cb(h):
        fn(fut)
    return cb

class Future:
    def __init__(self, handle=none):
        if handle == none:
            handle = future_create()
        self.id = handle

    def result(self, timeout=none):
        return future_result(self.id, _ms(timeout))

    def exception(self, timeout=none):
        return future_exception(self.id, _ms(timeout))

    def done(self):
        return future_done(self.id)

    def running(self):
        return future_running(self.id)

    def cancel(self):
        return future_cancel(self.id)

    def cancelled(self):
        return future_cancelled(self.id)

    def set_result(self, value):
        future_set_result(self.id, value)

    def set_exception(self, message):
        future_set_exception(self.id, message)

    def add_done_callback(self, fn):
        future_add_done_callback(self.id, _future_cb(self, fn))

# Futures (objects or handles) in the order they finish; waits for all.
def as_completed(futures, timeout=none):
    var hs = []
    var by_id = {}
    for f in futures:
        var h = _handle(f)
        hs.append(h)
        by_id[str(h)] = f
    var out = []
    for h in futures_as_completed(hs, _ms(timeout)):
        out.append(by_id[str(h)])
    return out

class ThreadPoolExecutor:
    def __init__(self, max_workers=4):
        self.max_workers = max_workers
        self.id = pool_create(max_workers)

    def submit(self, fn, *args):
        return Future(pool_submit(self.id, fn, *args))

    def map(self, fn, items):
        var futs = []
        for it in items:
            futs.append(Future(pool_submit(self.id, fn, it)))
        var out = []
        for f in futs:
            out.append(f.result())
        return out

    def shutdown(self, wait=true, cancel_futures=false):
        return pool_shutdown(self.id, wait, cancel_futures)

    def __enter__(self):
        return self

    def __exit__(self, t=none, v=none, tb=none):
        pool_shutdown(self.id, true, false)

class ThreadPool(ThreadPoolExecutor):
    # Old API: submit(fn) then get_result() returns results in submission order.
    def __init__(self, num_workers=4):
        self.num_workers = num_workers
        self.max_workers = num_workers
        self.id = pool_create(num_workers)
        self.pending = []
        self.running = true

    def submit(self, fn, *args):
        var f = Future(pool_submit(self.id, fn, *args))
        self.pending.append(f)
        return f

    def get_result(self, timeout=none):
        if len(self.pending) == 0:
            return none
        var f = self.pending.pop(0)
        return f.result(timeout)

    def stop(self):
        self.running = false
        pool_shutdown(self.id, false, false)

# ─── Timers ──────────────────────────────────────────────────────────────────

class Timer:
    # Timer(interval_seconds, function, args=[]): start() runs function(*args)
    # on its own thread after the interval unless cancel() comes first;
    # join() returns its result. Timer() without a function is lib/stdlib.ny's
    # stopwatch (start/stop/reset/seconds/ms).
    def __init__(self, interval=none, function=none, args=none):
        self.interval = interval
        self.function = function
        self.args = args
        self.handle = -1
        self.start_time = 0.0
        self.elapsed = 0.0
        self.running = false

    def start(self):
        if self.function != none:
            var a = self.args
            if a == none:
                a = []
            self.handle = timer_create(self.interval * 1000, self.function, *a)
            return self
        self.start_time = time_now()
        self.running = true
        return self

    def cancel(self):
        if self.handle < 0:
            return false
        return timer_cancel(self.handle)

    def fired(self):
        return self.handle >= 0 and timer_fired(self.handle)

    def join(self, timeout=none):
        return thread_join(self.handle, _ms(timeout))

    def stop(self):
        if self.running:
            self.elapsed = self.elapsed + time_now() - self.start_time
            self.running = false

    def reset(self):
        self.elapsed = 0.0
        self.running = false

    def seconds(self):
        if self.running:
            return self.elapsed + time_now() - self.start_time
        return self.elapsed

    def ms(self):
        return self.seconds() * 1000.0

class ScheduledTask:
    def __init__(self, interval_ms, fn):
        self.interval_ms = interval_ms
        self.fn = fn
        self.running = false
        self.count = 0

    def tick(self):
        if self.running:
            self.fn()
            self.count = self.count + 1

    def start(self):
        self.running = true

    def stop(self):
        self.running = false

class Scheduler:
    # Cooperative: tick() (or run(duration_ms)) calls every due task on the
    # calling thread; run_in_background(duration_ms) runs that loop on a thread.
    def __init__(self):
        self.tasks = []
        self.task_count = 0
        self.running = false
        self.last_tick = []

    def every(self, interval_ms, fn):
        var task = ScheduledTask(interval_ms, fn)
        task.start()
        self.tasks.append(task)
        self.last_tick.append(0.0)
        self.task_count = self.task_count + 1
        return task

    def tick(self):
        var now = time_now() * 1000.0
        var i = 0
        while i < self.task_count:
            var t = self.tasks[i]
            if t.running:
                var elapsed = now - self.last_tick[i]
                if elapsed >= t.interval_ms:
                    t.tick()
                    self.last_tick[i] = now
            i = i + 1

    def run(self, duration_ms):
        self.running = true
        var start = time_now() * 1000.0
        while self.running:
            self.tick()
            thread_sleep(1)
            var elapsed = time_now() * 1000.0 - start
            if duration_ms > 0 and elapsed >= duration_ms:
                break
        self.running = false

    def run_in_background(self, duration_ms):
        return thread_create(self.run, duration_ms)

    def stop(self):
        self.running = false

# ─── ConcurrentMap ───────────────────────────────────────────────────────────

class ConcurrentMap:
    def __init__(self):
        self._data = {}
        self._keylist = []
        self._lock = RLock()

    def set(self, key, value):
        self._lock.acquire()
        if not self.contains(key):
            self._keylist.append(key)
        self._data[key] = value
        self._lock.release()

    def get(self, key, default=none):
        self._lock.acquire()
        var val = default
        if self.contains(key):
            val = self._data[key]
        self._lock.release()
        return val

    # Atomically replace the value with fn(old_value); returns the new value.
    def update(self, key, fn, default=none):
        self._lock.acquire()
        var old = default
        if self.contains(key):
            old = self._data[key]
        else:
            self._keylist.append(key)
        var nv = fn(old)
        self._data[key] = nv
        self._lock.release()
        return nv

    def delete(self, key):
        self._lock.acquire()
        self._data[key] = none
        var new_keys = []
        var i = 0
        while i < len(self._keylist):
            if self._keylist[i] != key:
                new_keys.append(self._keylist[i])
            i = i + 1
        self._keylist = new_keys
        self._lock.release()

    def contains(self, key):
        var i = 0
        while i < len(self._keylist):
            if self._keylist[i] == key:
                return true
            i = i + 1
        return false

    def get_keys(self):
        self._lock.acquire()
        var k = []
        for x in self._keylist:
            k.append(x)
        self._lock.release()
        return k

    def size(self):
        return len(self._keylist)
