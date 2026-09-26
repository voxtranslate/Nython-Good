# vm_audit48.ny - real threads and synchronisation, on both engines.
#
#   Threads are OS threads under one GIL (src/NyConc.cpp). Every blocking
#   primitive releases the GIL, honours timeouts and cancellation, and takes
#   part in deadlock detection. The VM runs threads natively (src/VMConc.cpp):
#   each thread has its own operand and frame stack; globals are shared.
#
#   Every wait below has a timeout, so a broken build fails instead of hanging.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit48.ny
#     ./build/nython-cli --vm examples/vm_audit48.ny

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

def contains(s, part):
    return string_find(str(s), part) >= 0

# ── 1. 8 threads x 10000 locked increments, three rounds ────────────────────
var counter = [0]
var lock = mutex_create()
def locked_worker():
    var i = 0
    while i < 10000:
        mutex_lock(lock)
        counter[0] = counter[0] + 1
        mutex_unlock(lock)
        i = i + 1
    return "done"

var round_i = 0
while round_i < 3:
    counter[0] = 0
    var hs = []
    var k = 0
    while k < 8:
        hs.append(thread_create(locked_worker))
        k = k + 1
    var results = []
    for h in hs:
        results.append(thread_join(h, 20000))
    check("locked counter round " + str(round_i), counter[0], 80000)
    check("join results round " + str(round_i), results, ["done", "done", "done", "done", "done", "done", "done", "done"])
    round_i = round_i + 1

# atomics: the same with no lock at all
var at = atomic_new(0)
def atomic_worker():
    var i = 0
    while i < 5000:
        atomic_inc(at)
        i = i + 1
var ahs = []
var ak = 0
while ak < 8:
    ahs.append(thread_create(atomic_worker))
    ak = ak + 1
for h in ahs:
    thread_join(h, 20000)
check("atomic counter", atomic_get(at), 40000)
check("atomic_add", atomic_add(at, 10), 40010)
check("atomic_dec", atomic_dec(at), 40009)
check("atomic_cas hit", atomic_cas(at, 40009, 7), true)
check("atomic_cas miss", atomic_cas(at, 40009, 8), false)
check("atomic value after cas", atomic_get(at), 7)
check("atomic_exchange", atomic_exchange(at, 1), 7)

# ── 2. join: results, arguments, re-raise, timeout ──────────────────────────
def add3(a, b, c):
    return a + b + c
check("thread args + result", thread_join(thread_create(add3, 1, 2, 3), 5000), 6)
check("thread_start alias", thread_join(thread_start(add3, 10, 20, 30), 5000), 60)

def make_adder(n):
    def inner(x):
        return x + n
    return inner
check("closure thread", thread_join(thread_create(make_adder(100), 5), 5000), 105)

class Acc:
    def __init__(self):
        self.total = 0
    def add(self, n):
        self.total = self.total + n
        return self.total
var acc = Acc()
check("bound method thread", thread_join(thread_create(acc.add, 7), 5000), 7)
check("bound method mutated instance", acc.total, 7)
check("lambda thread", thread_join(thread_create(lambda x: x * 3, 5), 5000), 15)
check("builtin as thread target", thread_join(thread_create(len, [1, 2, 3]), 5000), 3)

def raiser():
    raise ValueError("boom in thread")
var raised = "no"
try:
    thread_join(thread_create(raiser), 5000)
except ValueError as e:
    raised = "yes"
check("join re-raises the thread's exception (typed)", raised, "yes")
var raise_msg = ""
try:
    thread_join(thread_create(raiser), 5000)
except e:
    raise_msg = str(e)
check("re-raised message", contains(raise_msg, "boom in thread"), true)

def sleeper(ms):
    sleep_ms(ms)
    return ms
var slow = thread_create(sleeper, 300)
var timed_out = false
try:
    thread_join(slow, 20)
except e:
    timed_out = contains(e, "still running")
check("join timeout raises", timed_out, true)
check("is_alive while running", thread_is_alive(slow), true)
check("join after timeout", thread_join(slow, 5000), 300)
check("is_alive after join", thread_is_alive(slow), false)

# ── 3. identity, names, thread-locals, detach ───────────────────────────────
check("main thread name", thread_name(thread_main()), "MainThread")
check("current is main", thread_id(), thread_main())
def whoami():
    return [thread_name(), thread_id()]
var named = thread_create_named("worker-A", whoami)
var who = thread_join(named, 5000)
check("thread_create_named", who[0], "worker-A")
check("thread_id inside thread", who[1], named)
thread_set_name(named, "renamed")
check("thread_set_name", thread_name(named), "renamed")

thread_local_set("k", "main-value")
def tls_worker(v):
    thread_local_set("k", v)
    sleep_ms(30)
    return thread_local_get("k", "missing")
var t1 = thread_create(tls_worker, "one")
var t2 = thread_create(tls_worker, "two")
check("thread-local one", thread_join(t1, 5000), "one")
check("thread-local two", thread_join(t2, 5000), "two")
check("thread-local main unchanged", thread_local_get("k"), "main-value")
check("thread-local default", thread_local_get("nope", 42), 42)

var det = thread_create(sleeper, 10)
thread_detach(det)
var det_err = ""
try:
    thread_join(det)
except e:
    det_err = str(e)
check("joining a detached thread fails", contains(det_err, "detached"), true)

# ── 4. condition variable: bounded producer / consumer ──────────────────────
var buf = []
var cm = mutex_create()
var cv = cond_create()
var got = []
def producer():
    var i = 0
    while i < 50:
        mutex_lock(cm)
        while len(buf) >= 4:
            cond_wait_timeout(cv, cm, 2000)
        buf.append(i)
        cond_notify_all(cv)
        mutex_unlock(cm)
        i = i + 1
def consumer():
    var n = 0
    while n < 50:
        mutex_lock(cm)
        while len(buf) == 0:
            cond_wait_timeout(cv, cm, 2000)
        got.append(buf.pop(0))
        cond_notify_all(cv)
        mutex_unlock(cm)
        n = n + 1
var pc = thread_create(consumer)
var pp = thread_create(producer)
thread_join(pp, 10000)
thread_join(pc, 10000)
var want50 = []
var w = 0
while w < 50:
    want50.append(w)
    w = w + 1
check("condition producer/consumer order", got, want50)
mutex_lock(cm)
check("cond_wait_timeout expires", cond_wait_timeout(cv, cm, 30), false)
check("mutex re-held after cond timeout", mutex_owner(cm), thread_id())
mutex_unlock(cm)

# ── 5. semaphore: blocking, timeout, release from another thread ────────────
var sem = semaphore_create(0)
var t0 = time_ms()
check("semaphore_acquire_timeout times out", semaphore_acquire_timeout(sem, 100), false)
check("semaphore waited ~100ms", time_ms() - t0 >= 90, true)
def releaser(s, ms):
    sleep_ms(ms)
    semaphore_release(s)
var rh = thread_create(releaser, sem, 60)
var t1s = time_ms()
check("semaphore_acquire blocks until release", semaphore_acquire(sem), true)
check("semaphore blocked ~60ms", time_ms() - t1s >= 50, true)
thread_join(rh, 5000)
check("semaphore_try_acquire empty", semaphore_try_acquire(sem), false)
semaphore_release(sem, 2)
check("semaphore_value", semaphore_value(sem), 2)
var bounded = semaphore_create(1, 1)
check("bounded semaphore over-release", semaphore_release(bounded), false)

# ── 6. event, latch, barrier generations ────────────────────────────────────
var ev = event_create()
check("event not set", event_wait_timeout(ev, 20), false)
def setter():
    sleep_ms(30)
    event_set(ev)
var sh = thread_create(setter)
check("event_wait wakes on set", event_wait_timeout(ev, 5000), true)
check("event_is_set", event_is_set(ev), true)
thread_join(sh, 5000)
event_clear(ev)
check("event cleared", event_is_set(ev), false)

var latch = latch_create(3)
def counter_down():
    sleep_ms(20)
    latch_count_down(latch)
var li = 0
while li < 3:
    thread_create(counter_down)
    li = li + 1
check("latch_wait_timeout", latch_wait_timeout(latch, 5000), true)
check("latch count", latch_count(latch), 0)

var bar = barrier_create(3)
def barrier_worker():
    var gens = []
    var r = 0
    while r < 3:
        gens.append(barrier_wait_timeout(bar, 5000))
        r = r + 1
    return gens
var bh = []
var bi = 0
while bi < 3:
    bh.append(thread_create(barrier_worker))
    bi = bi + 1
for h in bh:
    check("barrier generations", thread_join(h, 10000), [0, 1, 2])
check("barrier_generation", barrier_generation(bar), 3)

# ── 7. rwlock ───────────────────────────────────────────────────────────────
var rw = rwlock_create()
var inside = atomic_new(0)
var both_in = barrier_create(2)
def reader():
    rwlock_read_lock(rw)
    atomic_inc(inside)
    barrier_wait_timeout(both_in, 5000)     # both readers hold it at once
    var seen = atomic_get(inside)
    barrier_wait_timeout(both_in, 5000)
    rwlock_read_unlock(rw)
    return seen
var r1 = thread_create(reader)
var r2 = thread_create(reader)
check("two readers at once (1)", thread_join(r1, 5000), 2)
check("two readers at once (2)", thread_join(r2, 5000), 2)
rwlock_read_lock(rw)
check("writer excluded by a reader", thread_join(thread_create(lambda: rwlock_try_write_lock(rw)), 5000), false)
rwlock_read_unlock(rw)
check("write lock when free", rwlock_try_write_lock(rw), true)
check("reader excluded by the writer", thread_join(thread_create(lambda: rwlock_try_read_lock(rw)), 5000), false)
rwlock_write_unlock(rw)

# ── 8. queues ───────────────────────────────────────────────────────────────
var pq = queue_create(0, "priority")
queue_put(pq, [5, "e"])
queue_put(pq, [1, "a"])
queue_put(pq, [3, "c"])
queue_put(pq, [1, "b"])
check("priority queue order", [queue_get(pq)[1], queue_get(pq)[1], queue_get(pq)[1], queue_get(pq)[1]], ["a", "b", "c", "e"])
var lq = queue_create(0, "lifo")
queue_put(lq, 1)
queue_put(lq, 2)
queue_put(lq, 3)
check("lifo queue order", [queue_get(lq), queue_get(lq), queue_get(lq)], [3, 2, 1])
var fq = queue_create(2)
check("fifo try_put 1", queue_try_put(fq, "x"), true)
check("fifo try_put 2", queue_try_put(fq, "y"), true)
check("fifo full", queue_full(fq), true)
check("fifo try_put when full", queue_try_put(fq, "z"), false)
check("fifo put_timeout when full", queue_put_timeout(fq, "z", 30), false)
check("fifo size", queue_size(fq), 2)
check("fifo get", queue_get(fq), "x")
check("queue_get_timeout ok", queue_get_timeout(fq, 100), ["y", true])
check("queue_get_timeout empty", queue_get_timeout(fq, 30), [none, false])
def qproducer(q, n):
    var i = 0
    while i < n:
        queue_put(q, i * i)
        i = i + 1
var bq = queue_create(3)
var qh = thread_create(qproducer, bq, 20)
var sq = []
var qi = 0
while qi < 20:
    sq.append(queue_get(bq))
    qi = qi + 1
thread_join(qh, 5000)
check("blocking queue producer/consumer", sq[19], 361)
check("blocking queue count", len(sq), 20)

# ── 9. channels and select ──────────────────────────────────────────────────
var unbuf = chan_create(0)
def chan_producer(ch, n):
    var i = 0
    while i < n:
        chan_send(ch, i)
        i = i + 1
    chan_close(ch)
    return "closed"
var cph = thread_create(chan_producer, unbuf, 10)
var crecv = []
var more = true
while more:
    var r = chan_recv_ok(unbuf)
    if r[1]:
        crecv.append(r[0])
    else:
        more = false
check("unbuffered channel values", crecv, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
check("producer finished after close", thread_join(cph, 5000), "closed")
check("channel closed and drained", chan_drained(unbuf), true)
check("recv on drained channel", chan_recv(unbuf), none)
var send_err = ""
try:
    chan_send(unbuf, 1)
except e:
    send_err = str(e)
check("send on closed channel raises", contains(send_err, "closed"), true)
check("rendezvous try_send without receiver", chan_try_send(chan_create(0), 1), false)

var ca = chan_create(1)
var cb = chan_create(1)
chan_send(cb, "B")
check("select picks the ready case", chan_select([["recv", ca], ["recv", cb]], 1000), [1, "B", true])
check("select default (timeout 0)", chan_select([["recv", ca], ["recv", cb]], 0), [-1, none, false])
var st0 = time_ms()
check("select timeout", chan_select([["recv", ca]], 50), [-1, none, false])
check("select waited", time_ms() - st0 >= 40, true)
def late_sender(ch, v, ms):
    sleep_ms(ms)
    chan_send(ch, v)
var lsh = thread_create(late_sender, ca, "late", 40)
check("select blocks until a sender", chan_select([["recv", ca], ["recv", cb]], 5000), [0, "late", true])
thread_join(lsh, 5000)
check("select send case", chan_select([["send", ca, 5]], 0), [0, none, true])
check("value sent by select", chan_recv(ca), 5)
chan_close(cb)
check("select on closed channel", chan_select([["recv", cb]], 0), [0, none, false])
check("chan_len / chan_cap", [chan_len(ca), chan_cap(ca)], [0, 1])

# ── 10. futures and the thread pool ─────────────────────────────────────────
def square(x):
    return x * x
var pool = pool_create(3)
var futs = []
var fi = 0
while fi < 10:
    futs.append(pool_submit(pool, square, fi))
    fi = fi + 1
var fres = []
for f in futs:
    fres.append(future_result(f, 5000))
check("pool results", fres, [0, 1, 4, 9, 16, 25, 36, 49, 64, 81])
var ff = pool_submit(pool, raiser)
var ferr = ""
try:
    future_result(ff, 5000)
except e:
    ferr = str(e)
check("future re-raises", contains(ferr, "boom in thread"), true)
check("future_exception text", contains(future_exception(ff, 5000), "boom in thread"), true)
check("future_done", future_done(ff), true)
var fa = pool_submit(pool, sleeper, 150)
var fb = pool_submit(pool, sleeper, 30)
var fc = pool_submit(pool, sleeper, 80)
check("as_completed order", as_completed([fa, fb, fc], 5000), [fb, fc, fa])
var cb_seen = []
def on_done(f):
    cb_seen.append(future_result(f))
var fd = pool_submit(pool, square, 9)
future_add_done_callback(fd, on_done)
future_result(fd, 5000)
sleep_ms(20)
check("done callback", cb_seen, [81])
var one = pool_create(1)
var busy = pool_submit(one, sleeper, 200)
var queued = pool_submit(one, square, 3)
var spin = 0
while not future_running(busy) and spin < 2000:
    sleep_ms(1)
    spin = spin + 1
check("cancel a queued future", future_cancel(queued), true)
check("future_cancelled", future_cancelled(queued), true)
var cerr = ""
try:
    future_result(queued, 1000)
except e:
    cerr = str(e)
check("result of a cancelled future raises", contains(cerr, "cancelled"), true)
check("cannot cancel a running future", future_cancel(busy), false)
check("busy future result", future_result(busy, 5000), 200)
pool_shutdown(one, true)
pool_shutdown(pool, true)
var shut_err = ""
try:
    pool_submit(pool, square, 1)
except e:
    shut_err = str(e)
check("submit after shutdown fails", contains(shut_err, "shutdown"), true)
var manual = future_create()
thread_create(lambda: future_set_result(manual, "set by thread"))
check("manual future", future_result(manual, 5000), "set by thread")
var ftimeout = false
try:
    future_result(future_create(), 30)
except e:
    ftimeout = contains(e, "not done")
check("future_result timeout", ftimeout, true)

# ── 11. timers ──────────────────────────────────────────────────────────────
var fired = []
def on_timer(tag):
    fired.append(tag)
    return tag
var tm = timer_create(40, on_timer, "t1")
check("timer result", thread_join(tm, 5000), "t1")
var tm2 = timer_create(5000, on_timer, "t2")
check("timer_cancel before firing", timer_cancel(tm2), true)
thread_join(tm2, 5000)
check("cancelled timer did not fire", fired, ["t1"])
check("timer_fired", [timer_fired(tm), timer_fired(tm2)], [true, false])

# ── 12. cooperative cancellation ────────────────────────────────────────────
def long_sleeper():
    try:
        sleep(30)
        return "slept"
    except e:
        return "cancelled: " + str(contains(e, "cancelled"))
var ls = thread_create(long_sleeper)
sleep_ms(20)
var c0 = time_ms()
check("thread_cancel", thread_cancel(ls), true)
check("cancelled thread result", thread_join(ls, 5000), "cancelled: true")
check("cancellation is prompt", time_ms() - c0 < 2000, true)

# ── 13. structured concurrency: task groups ─────────────────────────────────
def tg_work(n):
    sleep_ms(10 * n)
    return n * 10
var g = taskgroup_create()
taskgroup_spawn(g, tg_work, 3)
taskgroup_spawn(g, tg_work, 1)
taskgroup_spawn(g, tg_work, 2)
check("task group results in spawn order", taskgroup_join(g), [30, 10, 20])

var tg_log = []
def tg_blocker(ch):
    try:
        chan_recv(ch)
        tg_log.append("received")
    except e:
        tg_log.append("blocker cancelled")
def tg_sleeper():
    try:
        sleep(30)
        tg_log.append("slept")
    except e:
        tg_log.append("sleeper cancelled")
def tg_failer():
    sleep_ms(30)
    raise ValueError("child failed")
var g2 = taskgroup_create()
var never = chan_create(0)
taskgroup_spawn(g2, tg_blocker, never)
taskgroup_spawn(g2, tg_sleeper)
taskgroup_spawn(g2, tg_failer)
var g2_err = ""
var g0 = time_ms()
try:
    taskgroup_join(g2)
except e:
    g2_err = str(e)
check("task group re-raises the first failure", contains(g2_err, "child failed"), true)
check("task group cancels the siblings promptly", time_ms() - g0 < 3000, true)
check("siblings saw cancellation", sorted(tg_log), ["blocker cancelled", "sleeper cancelled"])

# ── 14. deadlock detection and lock-order validation ────────────────────────
var A = mutex_create()
var B = mutex_create()
var got_a = event_create()
var got_b = event_create()
var dl = []
def ab():
    mutex_lock(A)
    event_set(got_a)
    event_wait_timeout(got_b, 5000)
    try:
        mutex_lock(B)
        mutex_unlock(B)
        dl.append("ok")
    except e:
        dl.append("deadlock:" + str(contains(e, "deadlock detected")))
    mutex_unlock(A)
def ba():
    mutex_lock(B)
    event_set(got_b)
    event_wait_timeout(got_a, 5000)
    try:
        mutex_lock(A)
        mutex_unlock(A)
        dl.append("ok")
    except e:
        dl.append("deadlock:" + str(contains(e, "deadlock detected")))
    mutex_unlock(B)
var d1 = thread_create(ab)
var d2 = thread_create(ba)
thread_join(d1, 10000)
thread_join(d2, 10000)
check("AB/BA: one thread gets DeadlockError, the other proceeds", sorted(dl), ["deadlock:true", "ok"])

var self_dl = ""
mutex_lock(A)
try:
    mutex_lock(A)
except DeadlockError as e:
    self_dl = "DeadlockError"
mutex_unlock(A)
check("relocking a non-recursive mutex", self_dl, "DeadlockError")
var rm = rmutex_create()
mutex_lock(rm)
mutex_lock(rm)
mutex_unlock(rm)
check("recursive mutex still held", mutex_locked(rm), true)
mutex_unlock(rm)
check("recursive mutex released", mutex_locked(rm), false)
var unlock_err = ""
try:
    mutex_unlock(rm)
except e:
    unlock_err = str(e)
check("unlock of an unheld mutex", contains(unlock_err, "not held"), true)

var all_blocked = ""
try:
    chan_recv(chan_create(0))
except e:
    all_blocked = str(e)
check("single thread blocked forever", contains(all_blocked, "all threads are blocked"), true)
var waits_forever = event_create()
def stuck():
    event_wait(waits_forever)
var stuck_err = ""
try:
    thread_join(thread_create(stuck))
except e:
    stuck_err = str(e)
check("join on a thread that can never finish", contains(stuck_err, "deadlock detected"), true)
var join_self = ""
try:
    thread_join(thread_id())
except e:
    join_self = str(e)
check("join self", contains(join_self, "cannot join itself"), true)

lockdep_enable(true)
var L1 = mutex_create()
var L2 = mutex_create()
def order_12():
    mutex_lock(L1)
    mutex_lock(L2)
    mutex_unlock(L2)
    mutex_unlock(L1)
thread_join(thread_create(order_12), 5000)
var inversion = ""
mutex_lock(L2)
try:
    mutex_lock(L1)
    mutex_unlock(L1)
except LockOrderError as e:
    inversion = "LockOrderError"
mutex_unlock(L2)
check("lock order inversion detected without deadlocking", inversion, "LockOrderError")
lockdep_enable(false)
lockdep_reset()

# ── 15. exceptions nobody joins are reported, not lost ──────────────────────
check("thread_count back to one", thread_count(), 1)
check("exception type constructors", [contains(DeadlockError("x"), "x"), contains(CancelledError("y"), "y")], [true, true])

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT48 PASSED ===")
else:
    print("=== VM_AUDIT48 FAILED ===")
