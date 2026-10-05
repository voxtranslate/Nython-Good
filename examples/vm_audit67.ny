# vm_audit67.ny - modules, the asynchronous protocols, closures and asyncio,
# both engines (round 77).
#
#   modules     `import m` runs m in a scope of its own: its names do not leak
#               into the importer (nor the importer's into it), `global` and
#               plain assignment in its functions stay in it; `from m import
#               a, b` / `*` (with __all__) / `import m as x`; its classes are
#               named "m.Class", so a program's class of the same name stays
#               distinct; `except m.Error` / an alias / `except m.error`
#               (a module variable naming a class) match what they name
#   async       async with (__aenter__/__aexit__), async for (__aiter__/
#               __anext__/StopAsyncIteration), async generators (asend,
#               aclose, anext with a default), async comprehensions, awaiting
#               an object with __await__, keyword-only and **kw parameters of
#               an async def, cancelling a task cancels the task it awaits,
#               gather_settled gives exception objects, CancelledError is a
#               BaseException, `with a, b:`
#   closures    the VM gave every call of a nested function one shared
#               environment, so closures made by different calls saw one x
#   names       `loop` and `block` can be variable names
#   asyncio     tasks, gather/wait/wait_for/as_completed/timeout/shield/race/
#               map_bounded, queues, Lock/Event/Condition/Semaphore/Barrier,
#               TaskGroup, Future, to_thread, call_soon_threadsafe,
#               run_coroutine_threadsafe, Runner, streams over TCP
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit67.ny
#     ./build/nython-cli --vm examples/vm_audit67.ny

import asyncio
import "lib/thread.ny"

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

def err(f):
    try:
        f()
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"

def defined(f):
    try:
        f()
        return true
    except NameError:
        return false

# ── modules ──────────────────────────────────────────────────────────────
class Queue:
    def kind(self):
        return "main.Queue"

var main_only_name = "main's"
var counter = 1000
import audit67_mod
check("module function", audit67_mod.helper(2), 42)
check("module functions see each other", audit67_mod.calls_helper(), 42)
check("module names do not leak", [defined(lambda: helper), defined(lambda: bump), defined(lambda: _hidden)], [false, false, false])
check("the builtin sleep is not replaced", audit67_mod.sleep(1) != sleep, true)
check("a module cannot see the program's names", audit67_mod.sees_main(), "NameError")
check("global in a module function is the module's", [audit67_mod.bump(), audit67_mod.bump(), counter], [1, 2, 1000])
check("plain assignment rebinds the module variable", [audit67_mod.bump_plain(), counter], [12, 1000])
check("private names are in the namespace", audit67_mod._hidden, "hidden")

var q = Queue()
var mq = audit67_mod.Queue()
var lq = audit67_mod.LifoQueue()
check("same-named classes stay distinct", [q.kind(), mq.kind(), lq.kind()], ["main.Queue", "audit67_mod.Queue", "audit67_mod.LifoQueue"])
check("a module class is named after its module", type(mq) == "audit67_mod.Queue", true)
check("isinstance across module classes", [isinstance(lq, audit67_mod.Queue), isinstance(q, audit67_mod.Queue), isinstance(mq, Queue)], [true, false, false])
check("except inside the module", audit67_mod.safe_take(mq), "caught inside")
var caught = []
try:
    audit67_mod.take(mq)
except audit67_mod.Empty as e:
    caught.append("dotted: " + str(e))
import audit67_mod as am
try:
    am.take(mq)
except am.Empty:
    caught.append("alias")
var MyEmpty = audit67_mod.Empty
try:
    am.take(mq)
except MyEmpty:
    caught.append("variable")
try:
    raise OSError("os")
except audit67_mod.error:
    caught.append("module variable naming OSError")
check("except finds the class it names", caught, ["dotted: empty queue", "alias", "variable", "module variable naming OSError"])
check("import as binds the same namespace", am is audit67_mod, true)

def from_import():
    from audit67_mod import helper, Empty
    return [helper(1), Empty.__name__ if false else "Empty bound"]
check("from m import a, b", from_import(), [21, "Empty bound"])
def star_import():
    from audit67_mod import *
    return [helper(3), defined(lambda: bump), defined(lambda: Empty)]
check("from m import * honours __all__", star_import(), [63, false, true])
def from_missing():
    from audit67_mod import nothing
check("from m import a missing name", err(lambda: from_missing()), "ImportError: cannot import name 'nothing' from 'audit67_mod'")
import audit67_mod2
check("a module importing a module", audit67_mod2.twice(1), [21, 21])

# ── async protocols ─────────────────────────────────────────────────────
class Manager:
    def __init__(self):
        self.log = []
    async def __aenter__(self):
        await async_sleep(0.001)
        self.log.append("enter")
        return self
    async def __aexit__(self, t, v, tb):
        self.log.append("exit " + str(t != none))
        return self.suppress
class Ticker:
    def __init__(self, n):
        self.i = 0
        self.n = n
    def __aiter__(self):
        return self
    async def __anext__(self):
        if self.i >= self.n:
            raise StopAsyncIteration()
        await async_sleep(0.001)
        self.i = self.i + 1
        return self.i
async def agen(n):
    for i in range(n):
        await async_sleep(0.001)
        yield i * 2
async def echo_gen():
    var got = []
    try:
        while true:
            var v = yield len(got)
            got.append(v)
    finally:
        got.append("closed")
class Awaitable:
    def __init__(self, coro):
        self.coro = coro
    def __await__(self):
        return self.coro
async def kw(a, *, k=5, **rest):
    return [a, k, rest]
async def value(x):
    await async_sleep(0.001)
    return x

async def protocols():
    var r = []
    var m = Manager()
    m.suppress = false
    async with m as mm:
        r.append(mm is m)
    try:
        async with m:
            raise ValueError("inside")
    except ValueError:
        r.append("propagated")
    m.suppress = true
    async with m:
        raise ValueError("suppressed")
    r.append(m.log)
    var t = []
    async for v in Ticker(3):
        t.append(v)
    r.append(t)
    var g = []
    async for v in agen(3):
        g.append(v)
    r.append(g)
    r.append([x async for x in agen(4) if x > 2])
    r.append({x: x * 10 async for x in Ticker(2)})
    var ag = agen(2)
    r.append([await ag.__anext__(), await anext(ag), await anext(ag, "default")])
    try:
        await anext(ag)
    except StopAsyncIteration:
        r.append("StopAsyncIteration")
    var eg = echo_gen()
    r.append([await eg.asend(none), await eg.asend("a"), await eg.asend("b")])
    await eg.aclose()
    r.append(await Awaitable(value(21)))
    r.append([await kw(1), await kw(1, k=2, extra=3)])
    return r

check("async protocols", async_run(protocols()), [true, "propagated", ["enter", "exit false", "enter", "exit true", "enter", "exit true"], [1, 2, 3], [0, 2, 4], [4, 6], {1: 10, 2: 20}, [0, 2, "default"], "StopAsyncIteration", [0, 1, 2], 21, [[1, 5, {}], [1, 2, {"extra": 3}]]])

var cancel_log = []
async def inner_task():
    try:
        await async_sleep(5)
    except CancelledError:
        cancel_log.append("inner cancelled")
        raise
async def outer_task():
    try:
        await create_task(inner_task())
    except CancelledError:
        cancel_log.append("outer cancelled")
async def cancel_main():
    var t = create_task(outer_task())
    await async_sleep(0.01)
    task_cancel(t)
    await async_sleep(0.01)
    var bad = []
    async def fails():
        raise KeyError("k")
    var settled = await gather_settled(fails(), value(1))
    return [sorted(cancel_log), type(settled[0]).__name__, settled[1]]
check("cancelling a task cancels the task it awaits", async_run(cancel_main()), [["inner cancelled", "outer cancelled"], "KeyError", 1])
var kind = "none"
try:
    raise CancelledError("c")
except Exception:
    kind = "Exception"
except BaseException:
    kind = "BaseException"
check("CancelledError is a BaseException", kind, "BaseException")
var p1 = os_path_join(os_gettempdir(), "ny_audit67_a_" + str(os_getpid()))
var p2 = os_path_join(os_gettempdir(), "ny_audit67_b_" + str(os_getpid()))
write_file(p1, "one\n")
write_file(p2, "two\n")
var both = none
with open(p1) as f1, open(p2) as f2:
    both = [f1.read(), f2.read()]
os_remove(p1)
os_remove(p2)
check("with a, b:", both, ["one\n", "two\n"])

# ── closures ─────────────────────────────────────────────────────────────
def per_call():
    def mk(x):
        return lambda: x
    var fs = [mk(i) for i in range(3)]
    return [f() for f in fs]
check("closures made by different calls", per_call(), [0, 1, 2])
def late_outer():
    var y = 100
    def mk(x):
        def inner():
            return x + y
        return inner
    var fs = [mk(0), mk(1)]
    y = 200
    return [f() for f in fs]
check("closures see later assignments to outer variables", late_outer(), [200, 201])
def three(a):
    def two(b):
        def one(c):
            return a + b + c
        return one
    return two
check("three levels", [three(1)(10)(100), three(2)(20)(200)], [111, 222])
def counter_pair():
    var n = 0
    def inc():
        n = n + 1
        return n
    return inc
var c1 = counter_pair()
var c2 = counter_pair()
check("independent counters", [c1(), c1(), c2()], [1, 2, 1])
def rebind_from_thread():
    var box = none
    def worker():
        box = "set by the thread"
    var th = Thread(worker)
    th.start()
    th.join()
    return box
check("a thread's closure rebinds the outer variable", rebind_from_thread(), "set by the thread")

# ── keywords as names ────────────────────────────────────────────────────
var loop = [1]
loop.append(2)
var block = {"a": 1}
block["b"] = 2
var spins = 0
loop:
    spins = spins + 1
    if spins == 3:
        break
check("loop and block as names", [loop, block, spins], [[1, 2], {"a": 1, "b": 2}, 3])

# ── asyncio ──────────────────────────────────────────────────────────────
async def work(n, d):
    await asyncio.sleep(d)
    return n * 10
async def boom(d, msg):
    await asyncio.sleep(d)
    raise ValueError(msg)

async def aio_main():
    var r = {}
    r["gather"] = await asyncio.gather(work(1, 0.02), work(2, 0.01))
    var t = asyncio.create_task(work(3, 0.01), name="w3")
    var before = [t.get_name(), t.done()]
    var res = await t
    r["task"] = before + [res, t.done(), t.result(), t.cancelled()]
    try:
        await asyncio.wait_for(work(4, 1), 0.02)
        r["wait_for"] = "no timeout"
    except asyncio.TimeoutError:
        r["wait_for"] = "TimeoutError"
    var dp = await asyncio.wait([work(5, 0.01), work(6, 0.3)], return_when=asyncio.FIRST_COMPLETED)
    r["wait"] = [len(dp[0]), len(dp[1])]
    for p in dp[1]:
        p.cancel()
    var order = []
    for c in asyncio.as_completed([work(7, 0.03), work(8, 0.01), work(9, 0.02)]):
        order.append(await c)
    r["as_completed"] = order
    try:
        async with asyncio.timeout(0.02):
            await asyncio.sleep(1)
        r["timeout"] = "not raised"
    except TimeoutError:
        r["timeout"] = "TimeoutError"
    r["race"] = await asyncio.race(work(10, 0.05), work(11, 0.01))
    r["map_bounded"] = await asyncio.map_bounded(lambda x: work(x, 0.002), [1, 2, 3, 4], 2)
    var sh = asyncio.create_task(work(12, 0.03))
    try:
        await asyncio.wait_for(asyncio.shield(sh), 0.005)
    except TimeoutError:
        pass
    r["shield"] = [sh.cancelled(), await sh]

    var q = asyncio.Queue()
    async def producer():
        for i in range(3):
            await q.put(i)
            await asyncio.sleep(0.001)
    async def consumer():
        var got = []
        for i in range(3):
            got.append(await q.get())
            q.task_done()
        return got
    var pc = await asyncio.gather(producer(), consumer())
    await q.join()
    var empty = "no"
    try:
        q.get_nowait()
    except asyncio.QueueEmpty:
        empty = "QueueEmpty"
    var pq = asyncio.PriorityQueue()
    await pq.put((3, "c"))
    await pq.put((1, "a"))
    await pq.put((2, "b"))
    var lq2 = asyncio.LifoQueue()
    for i in range(3):
        lq2.put_nowait(i)
    var full = asyncio.Queue(1)
    full.put_nowait("x")
    var full_err = "no"
    try:
        full.put_nowait("y")
    except asyncio.QueueFull:
        full_err = "QueueFull"
    r["queues"] = [pc[1], empty, [await pq.get(), await pq.get(), await pq.get()], [lq2.get_nowait(), lq2.get_nowait(), lq2.get_nowait()], full_err]

    var lock = asyncio.Lock()
    var trace = []
    async def critical(tag):
        async with lock:
            trace.append(tag + "+")
            await asyncio.sleep(0.003)
            trace.append(tag + "-")
    await asyncio.gather(critical("a"), critical("b"))
    var ev = asyncio.Event()
    async def setter():
        await asyncio.sleep(0.003)
        ev.set()
    asyncio.create_task(setter())
    var ev_res = await ev.wait()
    var cond = asyncio.Condition()
    var items = []
    async def cons():
        async with cond:
            await cond.wait_for(lambda: len(items) > 0)
            return items.pop(0)
    async def prod():
        await asyncio.sleep(0.003)
        async with cond:
            items.append("item")
            cond.notify()
    var cr = await asyncio.gather(cons(), prod())
    var sem = asyncio.Semaphore(2)
    var active = [0, 0]
    async def limited(i):
        async with sem:
            active[0] = active[0] + 1
            if active[0] > active[1]:
                active[1] = active[0]
            await asyncio.sleep(0.003)
            active[0] = active[0] - 1
    await asyncio.gather(*[limited(i) for i in range(6)])
    var bar = asyncio.Barrier(3)
    var arrived = []
    async def party(i):
        await asyncio.sleep(0.002 * i)
        arrived.append(i)
        var idx = await bar.wait()
        return len(arrived)
    var br = await asyncio.gather(party(0), party(1), party(2))
    r["sync"] = [trace, ev_res, cr[0], active[1], br]

    async with asyncio.TaskGroup() as tg:
        var t1 = tg.create_task(work(1, 0.01))
        var t2 = tg.create_task(work(2, 0.02))
    var tg_ok = [t1.result(), t2.result()]
    var cleaned = []
    async def slow():
        try:
            await asyncio.sleep(5)
        finally:
            cleaned.append("slow")
    var tg_fail = "none"
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(slow())
            tg.create_task(boom(0.01, "child failed"))
            await asyncio.sleep(5)
            tg_fail = "body ran on"
    except ValueError as e:
        tg_fail = str(e)
    async def stubborn():
        try:
            await asyncio.sleep(5)
        except asyncio.CancelledError:
            raise KeyError("second")
    var group = "none"
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(stubborn())
            tg.create_task(boom(0.01, "first"))
    except asyncio.ExceptionGroup as e:
        group = sorted([type(x).__name__ for x in e.exceptions])
    r["taskgroup"] = [tg_ok, tg_fail, cleaned, group]

    var loop = asyncio.get_running_loop()
    var fut = loop.create_future()
    loop.call_later(0.003, fut.set_result, "later")
    var fut2 = loop.create_future()
    def from_thread():
        sleep(0.005)
        loop.call_soon_threadsafe(fut2.set_result, "from a thread")
    var th = Thread(from_thread)
    th.start()
    var f2 = await fut2
    th.join()
    var tf = none
    def submit():
        tf = asyncio.run_coroutine_threadsafe(work(13, 0.003), loop)
    var th2 = Thread(submit)
    th2.start()
    th2.join()
    await asyncio.sleep(0.03)
    r["futures"] = [await fut, f2, tf.result(1), await asyncio.to_thread(lambda a, b: a + b, 2, 3)]

    var gr = await asyncio.gather(work(1, 0), boom(0, "g"), return_exceptions=true)
    var first = "none"
    try:
        await asyncio.gather(work(1, 0.01), boom(0, "first error"))
    except ValueError as e:
        first = str(e)
    var tc = asyncio.create_task(work(5, 1))
    await asyncio.sleep(0)
    tc.cancel()
    var tcr = "none"
    try:
        await tc
    except asyncio.CancelledError:
        tcr = "CancelledError"
    var cbs = []
    var t3 = asyncio.create_task(work(7, 0.003))
    t3.add_done_callback(lambda tt: cbs.append(tt.result()))
    await t3
    await asyncio.sleep(0.01)
    r["errors"] = [gr[0], type(gr[1]).__name__, first, tcr, tc.cancelled(), cbs, asyncio.current_task() != none]
    return r

var ar = asyncio.run(aio_main())
check("asyncio gather", ar["gather"], [10, 20])
check("asyncio Task", ar["task"], ["w3", false, 30, true, 30, false])
check("asyncio wait_for", ar["wait_for"], "TimeoutError")
check("asyncio wait FIRST_COMPLETED", ar["wait"], [1, 1])
check("asyncio as_completed", ar["as_completed"], [80, 90, 70])
check("asyncio timeout()", ar["timeout"], "TimeoutError")
check("asyncio race", ar["race"], 110)
check("asyncio map_bounded", ar["map_bounded"], [10, 20, 30, 40])
check("asyncio shield", ar["shield"], [false, 120])
check("asyncio queues", ar["queues"], [[0, 1, 2], "QueueEmpty", [(1, "a"), (2, "b"), (3, "c")], [2, 1, 0], "QueueFull"])
check("asyncio synchronisation", ar["sync"], [["a+", "a-", "b+", "b-"], true, "item", 2, [3, 3, 3]])
check("asyncio TaskGroup", ar["taskgroup"], [[10, 20], "child failed", ["slow"], ["KeyError", "ValueError"]])
check("asyncio futures and threads", ar["futures"], ["later", "from a thread", 130, 5])
check("asyncio errors and cancellation", ar["errors"], [10, "ValueError", "first error", "CancelledError", true, [70], true])

# ── asyncio streams over TCP ────────────────────────────────────────────
async def handle(reader, writer):
    while true:
        var line = await reader.readline()
        if len(line) == 0:
            break
        writer.write(b"echo:" + line)
        await writer.drain()
    writer.close()
async def client(port, n):
    var rw = await asyncio.open_connection("127.0.0.1", port)
    var got = []
    for i in range(n):
        rw[1].write(("msg" + str(i) + "\n").encode())
        got.append((await rw[0].readline()).decode().strip())
    rw[1].write_eof()
    var rest = await rw[0].read()
    rw[1].close()
    return [got, rest]
async def streams():
    var server = await asyncio.start_server(handle, "127.0.0.1", 0)
    var port = server.sockets[0].getsockname()[1]
    var res = await asyncio.gather(client(port, 3), client(port, 1))
    var rd = asyncio.StreamReader()
    rd.feed_data(b"abc\ndef\nxy")
    rd.feed_eof()
    var parts = [await rd.readline(), await rd.readexactly(2)]
    try:
        await rd.readexactly(10)
    except asyncio.IncompleteReadError as e:
        parts.append(e.partial)
    var refused = "no"
    try:
        await asyncio.open_connection("127.0.0.1", 1)
    except ConnectionRefusedError:
        refused = "ConnectionRefusedError"
    async with server:
        pass
    return [res, parts, refused, server.is_serving()]
check("asyncio streams", asyncio.run(streams()), [[[["echo:msg0", "echo:msg1", "echo:msg2"], b""], [["echo:msg0"], b""]], [b"abc\n", b"de", b"f\nxy"], "ConnectionRefusedError", false])
var runner_res = none
with asyncio.Runner() as runner:
    runner_res = runner.run(work(4, 0))
check("asyncio Runner", runner_res, 40)

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT67 PASSED ===")
