# vm_audit49.ny - async / await, identical on both engines.
#
#   `async def` returns a coroutine; async_run(coro) runs an event loop in
#   which exactly one task runs at a time and the order is decided by the
#   program, never by the OS: ready tasks run first-in first-out, timers fire
#   in (deadline, creation) order, and a task woken by another task is queued
#   at the moment it is woken. Every blocking builtin (sleep, channel and queue
#   operations, locks, futures) suspends only the calling task.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit49.ny
#     ./build/nython-cli --vm examples/vm_audit49.ny

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

var log = []

# ── 1. coroutines are lazy ──────────────────────────────────────────────────
async def double(x):
    log.append("double " + str(x))
    return x * 2

var c = double(21)
check("calling an async def returns a coroutine", async_is_coroutine(c), true)
check("the body has not run yet", log, [])
check("await at top level runs it", await c, 42)
check("the body ran once", log, ["double 21"])
var reused = ""
try:
    await c
except e:
    reused = str(e)
check("a coroutine is awaited once", contains(reused, "already awaited"), true)
check("await of a plain value", await 7, 7)
check("async_run of a coroutine", async_run(double(5)), 10)

async def with_defaults(a, b=3, *rest):
    var t = a + b
    for r in rest:
        t = t + r
    return t
check("defaults", async_run(with_defaults(1)), 4)
check("*rest", async_run(with_defaults(1, 2, 3, 4)), 10)

class Service:
    def __init__(self, base):
        self.base = base
    async def get(self, n):
        await async_sleep(0)
        return self.base + n
check("async method", async_run(Service(100).get(5)), 105)

# ── 2. scheduling order ─────────────────────────────────────────────────────
async def tagged(tag, secs):
    log.append("start " + tag)
    await async_sleep(secs)
    log.append("end " + tag)
    return tag

async def order_main():
    var t1 = create_task(tagged("a", 0.3))
    var t2 = create_task(tagged("b", 0.1))
    var t3 = create_task(tagged("c", 0.2))
    log.append("main after create")
    return await gather(t1, t2, t3)

log = []
check("gather returns results in argument order", async_run(order_main()), ["a", "b", "c"])
check("tasks start in creation order, finish by deadline", log,
      ["main after create", "start a", "start b", "start c", "end b", "end c", "end a"])

async def tie(tag):
    await async_sleep(0.03)
    log.append(tag)
async def tie_main():
    await gather(tie("x"), tie("y"), tie("z"))
log = []
async_run(tie_main())
check("equal deadlines fire in creation order", log, ["x", "y", "z"])

async def yielder(tag, n):
    var i = 0
    while i < n:
        log.append(tag + str(i))
        await async_sleep(0)
        i = i + 1
async def yield_main():
    await gather(yielder("p", 3), yielder("q", 3))
log = []
async_run(yield_main())
check("sleep(0) round-robins", log, ["p0", "q0", "p1", "q1", "p2", "q2"])

async def concurrent_main():
    var t0 = time_ms()
    await gather(async_sleep(0.2), async_sleep(0.2), async_sleep(0.2))
    return time_ms() - t0
var elapsed = async_run(concurrent_main())
check("three 0.2 s sleeps run concurrently", elapsed >= 190 and elapsed < 500, true)

# ── 3. async queues (channels suspend only the task) ────────────────────────
async def producer(q, n):
    var i = 0
    while i < n:
        log.append("put" + str(i))
        chan_send(q, i)
        i = i + 1
async def consumer(q, n):
    var got = []
    var i = 0
    while i < n:
        var v = await chan_recv(q)
        log.append("got" + str(v))
        got.append(v)
        i = i + 1
    return got
async def queue_main():
    var q = chan_create(1)
    var tp = create_task(producer(q, 3))
    var tc = create_task(consumer(q, 3))
    var r = await gather(tp, tc)
    return r[1]
log = []
check("consumer received everything", async_run(queue_main()), [0, 1, 2])
check("bounded channel interleaving is deterministic", log, ["put0", "put1", "got0", "put2", "got1", "got2"])

async def ev_waiter(ev):
    event_wait(ev)
    log.append("event seen")
async def ev_setter(ev):
    await async_sleep(0.02)
    log.append("setting")
    event_set(ev)
async def ev_main():
    var ev = event_create()
    await gather(ev_waiter(ev), ev_setter(ev))
log = []
async_run(ev_main())
check("events suspend tasks", log, ["setting", "event seen"])

# ── 4. timeouts and cancellation ────────────────────────────────────────────
async def slow_op():
    try:
        await async_sleep(5)
        log.append("slow finished")
        return "slow"
    except e:
        log.append("slow cancelled")
        raise e
async def wait_for_main():
    var r1 = await wait_for(double(4), 1.0)
    var timeout_msg = ""
    try:
        await wait_for(slow_op(), 0.05)
    except e:
        timeout_msg = str(e)
    return [r1, contains(timeout_msg, "timed out")]
log = []
var t_wf = time_ms()
check("wait_for: result, then timeout", async_run(wait_for_main()), [8, true])
check("wait_for cancelled the slow task", log, ["double 4", "slow cancelled"])
check("wait_for did not wait for the slow task", time_ms() - t_wf < 2000, true)

async def cancel_main():
    var t = create_task(slow_op())
    await async_sleep(0.02)
    task_cancel(t)
    var msg = ""
    try:
        await t
    except e:
        msg = str(e)
    return [task_cancelled(t), contains(msg, "cancelled")]
log = []
check("task_cancel", async_run(cancel_main()), [true, true])

async def cancel_before_start():
    var t = create_task(double(1))
    task_cancel(t)
    return [task_done(t), task_cancelled(t)]
log = []
check("cancel before the task started", async_run(cancel_before_start()), [true, true])
check("a task cancelled before starting never ran", log, [])

# ── 5. exceptions ───────────────────────────────────────────────────────────
async def fails(msg, secs):
    await async_sleep(secs)
    raise ValueError(msg)
async def gather_fail_main():
    var msg = ""
    try:
        await gather(tagged("ok", 0.01), fails("late", 0.05), fails("early", 0.02))
    except e:
        msg = str(e)
    return msg
log = []
check("gather raises the first failure in time", contains(async_run(gather_fail_main()), "early"), true)

async def settled_main():
    return await gather_settled(double(3), fails("bad", 0))
var settled = async_run(settled_main())
check("gather_settled keeps going", settled[0], 6)
check("gather_settled reports the error", contains(settled[1], "bad"), true)

var run_err = ""
try:
    async_run(fails("from main", 0))
except ValueError as e:
    run_err = "ValueError"
check("async_run re-raises the main task's exception (typed)", run_err, "ValueError")

var outside = ""
try:
    create_task(double(1))
except e:
    outside = str(e)
check("create_task outside a loop", contains(outside, "no running event loop"), true)

async def nested():
    return async_run(double(1))
var nested_err = ""
try:
    async_run(nested())
except e:
    nested_err = str(e)
check("async_run inside a loop", contains(nested_err, "running event loop"), true)

async def waits_forever():
    await future_create()
var dl_err = ""
var t_dl = time_ms()
try:
    async_run(waits_forever())
except e:
    dl_err = str(e)
check("a loop that can never progress raises DeadlockError", contains(dl_err, "deadlock detected"), true)
check("... immediately", time_ms() - t_dl < 2000, true)

# ── 6. tasks, threads and pools together ────────────────────────────────────
def blocking_work(n):
    sleep_ms(50)
    return n * n
async def ticker(n):
    var i = 0
    while i < n:
        log.append("tick")
        await async_sleep(0.01)
        i = i + 1
async def pool_main():
    var pool = pool_create(2)
    var f = pool_submit(pool, blocking_work, 12)
    var r = await gather(f, ticker(3))
    pool_shutdown(pool)
    return r[0]
log = []
check("await a pool future while other tasks run", async_run(pool_main()), 144)
check("ticker ran while the pool worked", log, ["tick", "tick", "tick"])

async def from_thread_main():
    var ch = chan_create(0)
    thread_create(lambda: chan_send(ch, "hello from a thread"))
    return await chan_recv(ch)
check("a plain thread wakes a task", async_run(from_thread_main()), "hello from a thread")

var later = []
async def later_main():
    var t = async_call_later(0.02, lambda x: later.append(x), "fired")
    await t
    return later
check("async_call_later", async_run(later_main()), ["fired"])

async def current_task_main():
    return async_current_task() != 0
check("async_current_task inside a task", async_run(current_task_main()), true)
check("async_current_task outside", async_current_task(), 0)

# ── 7. async for / async with parse ─────────────────────────────────────────
class Ctx:
    def __enter__(self):
        log.append("enter")
        return self
    def __exit__(self, t=none, v=none, tb=none):
        log.append("exit")
async def syntax_main():
    var total = 0
    async for x in [1, 2, 3]:
        total = total + x
    async with Ctx():
        log.append("body")
    return total
log = []
check("async for", async_run(syntax_main()), 6)
check("async with", log, ["enter", "body", "exit"])

var await = "a name"
check("await is still usable as a name", str(await), "a name")

# ── 8. tasks are coroutines on the loop's thread (round 76) ─────────────────
# A task used to be an OS thread handed a baton through the GIL: every switch
# put one thread to sleep and woke another. Now it is a stack on the loop's
# thread and a switch is a stack switch.
# The process's OS threads, where the system says (Linux), else -1.
def os_threads():
    if not os_exists("/proc/self/status"):
        return -1
    for line in string_split(read_file("/proc/self/status"), "\n"):
        if string_find(line, "Threads:") == 0:
            return int(string_strip(string_replace(line, "Threads:", "")))
    return -1
var most_threads = [0]
async def leaf(i):
    await async_sleep(0)
    if i % 100 == 0:
        most_threads[0] = max(most_threads[0], os_threads())
    return i
async def many_main(n):
    var threads_during = thread_count()
    var cs = []
    for i in range(n):
        cs.append(leaf(i))
    var rs = await gather(*cs)
    var total = 0
    for r in rs:
        total = total + r
    return [total, threads_during, thread_count()]
var threads_before = thread_count()
var waits_before = thread_wait_count()
check("2000 tasks", async_run(many_main(2000)), [1999000, threads_before, threads_before])
check("no thread slept for them", thread_wait_count() - waits_before < 20, true)
if os_threads() > 0:
    # (each task used to be an OS thread: 2000 of them here)
    check("no OS thread per task (" + str(most_threads[0]) + " threads)", most_threads[0] < 10, true)

async def pinger(n, log2, name):
    for i in range(n):
        log2.append(name)
        await async_sleep(0)
    return n
async def ping_main():
    var log2 = []
    var rs = await gather(pinger(200, log2, "a"), pinger(200, log2, "b"), pinger(200, log2, "c"))
    return [rs, len(log2), log2[0:6]]
waits_before = thread_wait_count()
check("600 switches in program order", async_run(ping_main()), [[200, 200, 200], 600, ["a", "b", "c", "a", "b", "c"]])
check("switching is not sleeping", thread_wait_count() - waits_before < 20, true)

# A task that blocks inside a generator's body (a sleep, a lock, a queue)
# leaves through the generator: the other tasks run meanwhile, and the
# generator carries on where it was when the task comes back.
def ticking(n, log3, name):
    for i in range(n):
        thread_sleep(1)
        log3.append(name + str(i))
        yield i
def outer_ticks(n, log3, name):
    yield from ticking(n, log3, name)
async def consume(name, log3, nested):
    var total = 0
    var g = outer_ticks(3, log3, name) if nested else ticking(3, log3, name)
    for v in g:
        total = total + v
    return total
async def gen_main(nested):
    var log3 = []
    var rs = await gather(consume("a", log3, nested), consume("b", log3, nested))
    var order_a = [x for x in log3 if x[0] == "a"]
    return [rs, len(log3), order_a]
check("blocking inside a generator", async_run(gen_main(false)), [[3, 3], 6, ["a0", "a1", "a2"]])
check("inside yield from", async_run(gen_main(true)), [[3, 3], 6, ["a0", "a1", "a2"]])

# Each task has its own exception being handled (a bare raise), call depth
# and thread-local values, as each thread does.
async def handler(name):
    try:
        raise ValueError(name)
    except ValueError:
        await async_sleep(0.002)
        try:
            raise
        except ValueError as e:
            return str(e)
check("bare raise per task", async_run(gather(handler("first"), handler("second"))), ["first", "second"])

async def tls_task(v):
    thread_local_set("k", v)
    await async_sleep(0.001)
    return thread_local_get("k")
check("thread-local values per task", async_run(gather(tls_task(1), tls_task(2), tls_task(3))), [1, 2, 3])

def depth(n):
    if n == 0:
        return 0
    return 1 + depth(n - 1)
async def deep_task(n):
    await async_sleep(0)
    var d = depth(n)
    await async_sleep(0)
    return d
check("recursion inside tasks", async_run(gather(deep_task(400), deep_task(300))), [400, 300])

# A task waiting on a thread (a queue it fills) still lets the others run.
async def from_thread():
    var q = queue_create(0)
    var t = thread_create(lambda: queue_put(q, "from a thread"))
    var v = queue_get(q)
    thread_join(t)
    return v
async def meanwhile():
    var n = 0
    for i in range(5):
        await async_sleep(0)
        n = n + 1
    return n
check("a task blocked on a thread", async_run(gather(from_thread(), meanwhile())), ["from a thread", 5])

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT49 PASSED ===")
else:
    print("=== VM_AUDIT49 FAILED ===")
