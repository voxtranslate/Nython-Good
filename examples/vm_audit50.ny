# vm_audit50.ny - lib/thread.ny under real concurrency, on both engines.
#
#   The library's classes (Thread, Lock/RLock with `with`, Condition,
#   Semaphore, ThreadEvent, Barrier, CountDownLatch, atomics, Queue family,
#   Channel + select, ThreadPoolExecutor/Future, Timer, TaskGroup,
#   ThreadLocal, ConcurrentMap) are thin layers over the native runtime; this
#   checks them with several threads actually contending.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit50.ny
#     ./build/nython-cli --vm examples/vm_audit50.ny

import "../lib/thread.ny"

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

# ── Thread ──────────────────────────────────────────────────────────────────
def mul(a, b):
    return a * b
var t = Thread(mul, [6, 7])
t.start()
check("Thread target + args", t.join(5), 42)
check("Thread not alive after join", t.is_alive(), false)

class Worker(Thread):
    def __init__(self, n):
        self.n = n
        self.target = none
        self.args = none
        self.name = "worker-" + str(n)
        self.daemon = false
        self.id = -1
    def run(self):
        return [self.n * 10, thread_name()]
var wk = Worker(4)
wk.start()
check("Thread subclass overriding run()", wk.join(5), [40, "worker-4"])

var slow = Thread(lambda: sleep(0.3))
slow.start()
check("join with an expired timeout returns none", slow.join(0.02), none)
check("still alive", slow.is_alive(), true)
slow.join()
check("go() helper", thread_join(go(mul, 3, 5), 5000), 15)

# ── Lock / RLock with `with` ────────────────────────────────────────────────
var lock = Lock()
var total = [0]
def with_worker():
    var i = 0
    while i < 2000:
        with lock:
            total[0] = total[0] + 1
        i = i + 1
var ws = []
var wi = 0
while wi < 4:
    ws.append(Thread(with_worker).start())
    wi = wi + 1
for w in ws:
    w.join()
check("with lock: 4 x 2000", total[0], 8000)
check("lock free afterwards", lock.locked(), false)
check("acquire(blocking=false)", lock.acquire(false), true)
check("second acquire times out", Thread(lambda: lock.acquire(true, 0.02)).start().join(), false)
lock.release()

var rl = RLock()
def nested():
    var r = "not reached"
    with rl:
        with rl:
            r = "nested ok"
    return r
check("RLock re-entry", nested(), "nested ok")
check("RLock released", rl.locked(), false)

# ── Condition ───────────────────────────────────────────────────────────────
var cond = Condition()
var items = []
def cproducer():
    var i = 0
    while i < 10:
        with cond:
            items.append(i)
            cond.notify()
        i = i + 1
def cconsumer():
    var got = []
    while len(got) < 10:
        with cond:
            cond.wait_for(lambda: len(items) > 0, 2)
            if len(items) > 0:
                got.append(items.pop(0))
    return got
var cc = Thread(cconsumer).start()
var cp = Thread(cproducer).start()
cp.join()
check("Condition.wait_for consumer", cc.join(5), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
with cond:
    check("Condition.wait timeout", cond.wait(0.02), false)

# ── Semaphore limits concurrency ────────────────────────────────────────────
var sem = Semaphore(2)
var active = AtomicInt(0)
var peak = AtomicInt(0)
def limited():
    with sem:
        var now = active.inc()
        var done = false
        while not done:
            var p = peak.get()
            if now <= p:
                done = true
            else:
                done = peak.compare_and_swap(p, now)
        sleep(0.02)
        active.dec()
var ls = []
var li = 0
while li < 6:
    ls.append(Thread(limited).start())
    li = li + 1
for x in ls:
    x.join()
check("Semaphore(2): at most two inside", peak.get(), 2)
check("Semaphore value restored", sem.available(), 2)
var bs = BoundedSemaphore(1)
var over = ""
try:
    bs.release()
except e:
    over = str(e)
check("BoundedSemaphore over-release", contains(over, "too many"), true)
var bin = BinarySemaphore()
bin.wait()
check("BinarySemaphore taken", bin.try_acquire(), false)
bin.signal()

# ── ThreadEvent, Barrier, CountDownLatch ────────────────────────────────────
var ev = ThreadEvent()
var ev_order = []
def ev_waiter():
    ev.wait(5)
    ev_order.append("woken")
var evt = Thread(ev_waiter).start()
sleep(0.02)
ev_order.append("set")
ev.set()
evt.join()
check("ThreadEvent", ev_order, ["set", "woken"])
check("ThreadEvent.wait timeout", ThreadEvent().wait(0.01), false)

var bar = Barrier(3)
def bar_worker():
    return [bar.wait(5), bar.wait(5)]
var bws = [Thread(bar_worker).start(), Thread(bar_worker).start(), Thread(bar_worker).start()]
var bres = []
for b in bws:
    bres.append(b.join())
check("Barrier generations", bres, [[0, 1], [0, 1], [0, 1]])

var latch = CountDownLatch(2)
Thread(lambda: latch.count_down()).start()
Thread(lambda: latch.count_down()).start()
check("CountDownLatch.wait", latch.wait(5), true)
check("CountDownLatch count", latch.get_count(), 0)

# ── Atomics ─────────────────────────────────────────────────────────────────
var ab = AtomicBool(false)
check("AtomicBool flip", ab.flip(), true)
check("AtomicBool cas", ab.compare_and_swap(true, false), true)
check("AtomicBool get", ab.get(), false)

# ── Queues ──────────────────────────────────────────────────────────────────
var q = Queue(2)
def qproducer():
    var i = 0
    while i < 8:
        q.put(i)
        i = i + 1
    q.put(none)
var qp = Thread(qproducer).start()
var qgot = []
var v = q.get(5)
while v != none:
    qgot.append(v)
    v = q.get(5)
qp.join()
check("bounded Queue between threads", qgot, [0, 1, 2, 3, 4, 5, 6, 7])
var qe = ""
try:
    q.get(true, 0.02)
except e:
    qe = str(e)
check("Queue.get timeout raises", contains(qe, "empty"), true)
q.enqueue("a")
q.enqueue("b")
check("stdlib-compatible Queue API", [q.peek(), q.size, q.dequeue(), q.dequeue(), q.dequeue(), q.is_empty()], ["a", 2, "a", "b", none, true])
var pq = PriorityQueue()
pq.push(3, "low")
pq.push(1, "high")
pq.put([2, "mid"])
check("PriorityQueue", [pq.pop(), pq.get()[1], pq.pop(), pq.pop()], ["high", "mid", "low", none])
var lq = LifoQueue()
lq.put(1)
lq.put(2)
check("LifoQueue", [lq.get(), lq.get()], [2, 1])

# ── Channels and select ─────────────────────────────────────────────────────
var ch = Channel()
def chan_feed(c, n):
    var i = 0
    while i < n:
        c.send(i * 2)
        i = i + 1
    c.close()
Thread(chan_feed, [ch, 5]).start()
check("Channel.drain", ch.drain(), [0, 2, 4, 6, 8])
check("send on a closed Channel returns false", ch.send(1), false)
var c1 = Channel(1)
var c2 = Channel(1)
c2.send("two")
check("select with Channel objects", select([["recv", c1], ["recv", c2]], 1), [1, "two", true])
check("select default", select([["recv", c1]], 0), [-1, none, false])
var ub = UnboundedChannel()
var ui = 0
while ui < 100:
    ub.send(ui)
    ui = ui + 1
check("UnboundedChannel never blocks", ub.size(), 100)

# ── ThreadPoolExecutor / Future ─────────────────────────────────────────────
def square(x):
    return x * x
def nap(s):
    sleep(s)
    return s
var done_cb = []
var ordered = none
var mapped = none
with ThreadPoolExecutor(3) as ex:
    mapped = ex.map(square, [1, 2, 3, 4])
    var fa = ex.submit(nap, 0.12)
    var fb = ex.submit(nap, 0.02)
    var fc = ex.submit(nap, 0.06)
    fb.add_done_callback(lambda f: done_cb.append(f.result()))
    ordered = []
    for f in as_completed([fa, fb, fc], 5):
        ordered.append(f.result())
check("executor map", mapped, [1, 4, 9, 16])
check("as_completed with Future objects", ordered, [0.02, 0.06, 0.12])
check("done callback got the Future", done_cb, [0.02])
var pool = ThreadPool(2)
pool.submit(square, 5)
pool.submit(square, 6)
check("ThreadPool.get_result order", [pool.get_result(), pool.get_result(), pool.get_result()], [25, 36, none])
pool.stop()
var fut = Future()
Thread(lambda: fut.set_result("hello")).start()
check("Future set by another thread", fut.result(5), "hello")

# ── Timer ───────────────────────────────────────────────────────────────────
var fired = []
var tm = Timer(0.02, lambda x: fired.append(x), ["go"])
tm.start()
tm.join(5)
check("Timer fired", fired, ["go"])
var tm2 = Timer(5, lambda x: fired.append(x), ["never"])
tm2.start()
check("Timer.cancel", tm2.cancel(), true)
tm2.join(5)
check("cancelled Timer did not fire", fired, ["go"])
var sw = Timer()
sw.start()
sw.stop()
check("Timer() is still the stopwatch", sw.ms() >= 0.0, true)

# ── TaskGroup ───────────────────────────────────────────────────────────────
def tg_work(n):
    sleep(0.01 * n)
    return n * n
var g_results = none
with task_group() as g:
    g.spawn(tg_work, 3)
    g.spawn(tg_work, 1)
    g.spawn(tg_work, 2)
g_results = g.results
check("task_group results", g_results, [9, 1, 4])

var tg_log = []
def tg_sleeper():
    try:
        sleep(10)
    except e:
        tg_log.append("cancelled")
def tg_fail():
    sleep(0.02)
    raise ValueError("child boom")
var tg_err = ""
var t0 = time_ms()
try:
    with task_group() as g2:
        g2.spawn(tg_sleeper)
        g2.spawn(tg_fail)
except e:
    tg_err = str(e)
check("task_group propagates the child failure", contains(tg_err, "child boom"), true)
check("task_group cancelled the sibling", tg_log, ["cancelled"])
check("... promptly", time_ms() - t0 < 3000, true)

# ── ThreadLocal, ConcurrentMap ──────────────────────────────────────────────
var tl = ThreadLocal()
tl.set("who", "main")
def tl_worker(n):
    tl.set("who", "w" + str(n))
    sleep(0.01)
    return tl.get("who")
var tla = Thread(tl_worker, [1]).start()
var tlb = Thread(tl_worker, [2]).start()
check("ThreadLocal per thread", [tla.join(), tlb.join(), tl.get("who")], ["w1", "w2", "main"])

var cmap = ConcurrentMap()
def cm_worker():
    var i = 0
    while i < 500:
        cmap.update("hits", lambda old: old + 1, 0)
        i = i + 1
var cms = [Thread(cm_worker).start(), Thread(cm_worker).start(), Thread(cm_worker).start()]
for x in cms:
    x.join()
check("ConcurrentMap.update is atomic", cmap.get("hits"), 1500)

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT50 PASSED ===")
else:
    print("=== VM_AUDIT50 FAILED ===")
