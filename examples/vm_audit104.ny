# vm_audit104.ny - asyncio's missing half, both engines (round 82).
#
# The event loop API a program uses directly (run_until_complete,
# run_forever, stop, call_soon/call_later/call_at with Handle/TimerHandle,
# create_future, create_task, run_in_executor, the exception handler,
# debug, add_reader/add_writer, sock_*, getaddrinfo), transports and
# protocols (TCP, UDP and Unix echo servers, Server objects, flow control
# observed through pause_writing/resume_writing), the streams rebuilt on
# StreamReaderProtocol, subprocesses (communicate, pipelines, streaming
# output, SubprocessProtocol, signals to children), loop signal handlers
# and asyncio.run's Ctrl+C, TLS (ssl= on both ends, start_tls), 3.12's
# cancellation rules (Task.cancel(msg), cancelling/uncancel, wait_for and
# timeout as TimeoutError), eager tasks, Barrier, Queue.shutdown, and
# Nython's structured-concurrency reports.
#
# The shared part runs under python3 too (`python3 examples/vm_audit104.ny`);
# every expected value there is CPython's. POSIX-only parts (Unix sockets,
# add_signal_handler, signals to children) are skipped on Windows, as
# CPython has none of them there; parts that need a newer Python than the
# one running it (eager tasks 3.12, Queue.shutdown 3.13) are skipped and
# counted. TLS checks need the openssl command (a throwaway CA, as
# vm_audit70 makes one).
#
#     ./build/nython-cli examples/vm_audit104.ny
#     ./build/nython-cli --vm examples/vm_audit104.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import asyncio
import socket
import os
import sys
import time
import signal
import subprocess
import tempfile
import shutil
import concurrent.futures
import threading

results = []
skipped = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def skip(name):
    skipped.append(name)

POSIX = sys.platform != "win32"
PY = sys.executable
TMP = tempfile.mkdtemp(prefix="ny_audit104_")

def run(coro):
    return asyncio.run(coro)

# ── 1. the event loop object ──────────────────────────────────────────────────
loop = asyncio.new_event_loop()
order = []
loop.call_soon(order.append, 1)
h_cancelled = loop.call_soon(order.append, 99)
h_cancelled.cancel()
loop.call_later(0.03, order.append, 3)
loop.call_at(loop.time() + 0.015, order.append, 2)
loop.call_later(0.06, loop.stop)
loop.run_forever()
check("call_soon / call_at / call_later run in time order, a cancelled handle does not", order, [1, 2, 3])
check("Handle and TimerHandle", [isinstance(h_cancelled, asyncio.Handle), h_cancelled.cancelled(),
                                 isinstance(loop.call_later(5, print), asyncio.TimerHandle)], [True, True, True])
th = loop.call_later(10, order.append, 4)
check("TimerHandle.when() is loop time", [abs(th.when() - (loop.time() + 10)) < 0.5, th.cancelled()], [True, False])
th.cancel()
check("TimerHandle.cancel()", th.cancelled(), True)

fut = loop.create_future()
loop.call_soon(fut.set_result, "from a callback")
check("run_until_complete(future)", loop.run_until_complete(fut), "from a callback")

async def double(x):
    await asyncio.sleep(0.001)
    return x * 2

check("run_until_complete(coroutine)", loop.run_until_complete(double(21)), 42)
t_named = loop.create_task(double(5), name="named")
check("create_task before the loop runs", [t_named.get_name(), t_named.done()], ["named", False])
check("... runs in the next run", loop.run_until_complete(t_named), 10)
check("is_running / is_closed outside a run", [loop.is_running(), loop.is_closed()], [False, False])

async def probe():
    return [loop.is_running(), asyncio.get_running_loop() is loop, asyncio.get_event_loop() is loop]
check("inside a run", loop.run_until_complete(probe()), [True, True, True])

# a task left unfinished by one run goes on in the next
progress = []
async def ticker():
    for i in range(3):
        progress.append(i)
        await asyncio.sleep(0.01)
    return "ticked"
t_tick = loop.create_task(ticker())
loop.run_until_complete(asyncio.sleep(0.012))
mid = list(progress)
check("a task survives between runs", [len(mid) >= 1, len(mid) < 3, loop.run_until_complete(t_tick), progress],
      [True, True, "ticked", [0, 1, 2]])

pending = loop.create_future()
loop.call_soon(loop.stop)
stop_msg = "none"
try:
    loop.run_until_complete(pending)
except RuntimeError as e:
    stop_msg = str(e)
check("stop() before the future is done", stop_msg, "Event loop stopped before Future completed.")
pending.cancel()

async def nested_run():
    co = double(1)
    try:
        loop.run_until_complete(co)
    except RuntimeError as e:
        co.close()
        return str(e)
    return "ran"
check("a run inside a run", loop.run_until_complete(nested_run()), "This event loop is already running")

async def run_inside():
    co = double(1)
    try:
        asyncio.run(co)
    except RuntimeError as e:
        co.close()
        return str(e)
    return "ran"
check("asyncio.run inside a running loop", loop.run_until_complete(run_inside()),
      "asyncio.run() cannot be called from a running event loop")

# stop() from a callback: the batch that is ready still runs
batch = []
def first():
    batch.append("first")
    loop.stop()
loop.call_soon(first)
loop.call_soon(batch.append, "second")
loop.run_forever()
loop.run_until_complete(asyncio.sleep(0))
check("stop() lets the current batch finish", batch, ["first", "second"])

loop.set_debug(True)
dbg = loop.get_debug()
loop.set_debug(False)
check("set_debug / get_debug", [dbg, loop.get_debug()], [True, False])

# exception handlers
ctxs = []
def handler(lp, ctx):
    exc = ctx.get("exception")
    ctxs.append([lp is loop, ctx["message"].split(" ")[0:3], type(exc).__name__ if exc is not None else None,
                 "handle" in ctx])
loop.set_exception_handler(handler)
def boom():
    raise ValueError("callback boom")
loop.call_soon(boom)
loop.call_soon(loop.stop)
loop.run_forever()
loop.call_exception_handler({"message": "custom context"})
check("set_exception_handler gets a failing callback's context", ctxs,
      [[True, ["Exception", "in", "callback"], "ValueError", True], [True, ["custom", "context"], None, False]])
check("get_exception_handler", loop.get_exception_handler() is handler, True)
loop.set_exception_handler(None)
type_err = "none"
try:
    loop.set_exception_handler(5)
except TypeError as e:
    type_err = str(e)
check("set_exception_handler(non-callable)", type_err, "A callable object or None is expected, got 5")
seen_default = []
def via_default(lp, ctx):
    seen_default.append(ctx["message"])
    lp.default_exception_handler(ctx) if False else None
loop.set_exception_handler(via_default)
loop.call_exception_handler({"message": "x", "exception": KeyError("k")})
loop.set_exception_handler(None)
check("a context reaches the handler", seen_default, ["x"])

# executors
def slow_pow(a, b):
    time.sleep(0.01)
    return a ** b
check("run_in_executor (default executor)", loop.run_until_complete(loop.run_in_executor(None, slow_pow, 2, 10)), 1024)
with concurrent.futures.ThreadPoolExecutor(2) as ex:
    check("run_in_executor (a ThreadPoolExecutor)", loop.run_until_complete(loop.run_in_executor(ex, sum, [1, 2, 3])), 6)
def fails():
    raise KeyError("in a thread")
ex_err = "none"
try:
    loop.run_until_complete(loop.run_in_executor(None, fails))
except KeyError as e:
    ex_err = repr(e)
check("an executor's exception reaches the awaiter", ex_err, "KeyError('in a thread')")
async def executor_overlap():
    t0 = time.monotonic()
    rs = await asyncio.gather(*[loop.run_in_executor(None, time.sleep, 0.05) for i in range(4)])
    return [rs, time.monotonic() - t0 < 0.19]
check("executor calls overlap", loop.run_until_complete(executor_overlap()), [[None, None, None, None], True])

# task factory
made = []
def factory(lp, coro, **kw):
    t = asyncio.Task(coro, loop=lp, **kw)
    made.append(t)
    return t
loop.set_task_factory(factory)
check("set_task_factory", [loop.run_until_complete(double(4)), len(made), loop.get_task_factory() is factory], [8, 1, True])
loop.set_task_factory(None)
tf_err = "none"
try:
    loop.set_task_factory(1)
except TypeError as e:
    tf_err = str(e)
check("set_task_factory(non-callable)", tf_err, "task factory must be a callable or None")

loop.run_until_complete(loop.shutdown_asyncgens())
loop.run_until_complete(loop.shutdown_default_executor())
loop.close()
closed_err = "none"
try:
    loop.call_soon(print)
except RuntimeError as e:
    closed_err = str(e)
check("a closed loop", [loop.is_closed(), closed_err], [True, "Event loop is closed"])
close_twice = "ok"
try:
    loop.close()
except BaseException as e:
    close_twice = repr(e)
check("close() twice", close_twice, "ok")

# run_forever + a server made by run_until_complete (the classic pattern)
loop2 = asyncio.new_event_loop()
asyncio.set_event_loop(loop2)
async def handle_once(reader, writer):
    line = await reader.readline()
    writer.write(b"got " + line)
    await writer.drain()
    writer.close()
srv2 = loop2.run_until_complete(asyncio.start_server(handle_once, "127.0.0.1", 0))
port2 = srv2.sockets[0].getsockname()[1]
replies = []
def client_thread():
    s = socket.create_connection(("127.0.0.1", port2), 5)
    s.sendall(b"ping\n")
    data = b""
    while True:
        d = s.recv(100)
        if not d:
            break
        data += d
    s.close()
    replies.append(data)
    loop2.call_soon_threadsafe(loop2.stop)
th_c = threading.Thread(target=client_thread)
th_c.start()
loop2.run_forever()
th_c.join()
srv2.close()
loop2.run_until_complete(srv2.wait_closed())
asyncio.set_event_loop(None)
loop2.close()
check("run_forever serves a server made by run_until_complete", replies, [b"got ping\n"])

# ── 2. tasks: 3.12's cancellation rules ───────────────────────────────────────
async def cancellation():
    out = {}
    async def sleeper():
        await asyncio.sleep(10)
    t = asyncio.create_task(sleeper())
    await asyncio.sleep(0)
    t.cancel("stop now")
    try:
        await t
    except asyncio.CancelledError as e:
        out["msg"] = e.args
    out["cancelled"] = [t.cancelled(), t.done()]
    t2 = asyncio.create_task(sleeper())
    await asyncio.sleep(0)
    t2.cancel()
    t2.cancel()
    out["cancelling"] = t2.cancelling()
    out["uncancel"] = [t2.uncancel(), t2.uncancel(), t2.uncancel()]
    t2.cancel()
    try:
        await t2
    except asyncio.CancelledError:
        pass
    out["cancel done"] = t2.cancel()

    # a task that swallows the cancellation goes on
    async def stubborn():
        try:
            await asyncio.sleep(10)
        except asyncio.CancelledError:
            return "survived"
    t3 = asyncio.create_task(stubborn())
    await asyncio.sleep(0)
    t3.cancel()
    out["swallowed"] = [await t3, t3.cancelled()]

    # wait_for: TimeoutError from the inner CancelledError; the inner is cancelled
    inner_state = []
    async def slow():
        try:
            await asyncio.sleep(10)
        except asyncio.CancelledError:
            inner_state.append("inner cancelled")
            raise
    try:
        await asyncio.wait_for(slow(), 0.02)
    except asyncio.TimeoutError as e:
        out["wait_for"] = [type(e).__name__, type(e.__cause__).__name__, inner_state, isinstance(e, TimeoutError)]
    out["wait_for ok"] = await asyncio.wait_for(double(3), 1)
    out["wait_for None"] = await asyncio.wait_for(double(4), None)
    tw = asyncio.create_task(slow())
    try:
        await asyncio.wait_for(tw, 0)
    except TimeoutError:
        out["wait_for 0"] = tw.cancelled()

    # timeout(): expired(), when(), reschedule; an outer cancel is not a timeout
    try:
        async with asyncio.timeout(0.02) as cm:
            await asyncio.sleep(10)
    except TimeoutError:
        out["timeout"] = [cm.expired(), cm.when() is not None]
    async with asyncio.timeout(None) as cm2:
        cm2.reschedule(asyncio.get_running_loop().time() + 5)
        await asyncio.sleep(0.001)
    out["reschedule"] = [cm2.expired(), cm2.when() is not None]
    async def outer_cancelled():
        async with asyncio.timeout(10):
            await asyncio.sleep(10)
    to = asyncio.create_task(outer_cancelled())
    await asyncio.sleep(0.01)
    to.cancel()
    try:
        await to
        out["outer"] = "finished"
    except asyncio.CancelledError:
        out["outer"] = "CancelledError"
    except TimeoutError:
        out["outer"] = "TimeoutError"
    try:
        async with asyncio.timeout_at(asyncio.get_running_loop().time() + 0.01):
            await asyncio.sleep(10)
    except TimeoutError:
        out["timeout_at"] = "TimeoutError"
    return out

cr = run(cancellation())
check("Task.cancel(msg) gives CancelledError(msg)", [cr["msg"], cr["cancelled"]], [("stop now",), [True, True]])
check("cancelling() / uncancel()", [cr["cancelling"], cr["uncancel"], cr["cancel done"]], [2, [1, 0, 0], False])
check("a task may swallow its cancellation", cr["swallowed"], ["survived", False])
check("wait_for times out with TimeoutError from CancelledError",
      [cr["wait_for"], cr["wait_for ok"], cr["wait_for None"], cr["wait_for 0"]],
      [["TimeoutError", "CancelledError", ["inner cancelled"], True], 6, 8, True])
check("asyncio.timeout(), reschedule, timeout_at", [cr["timeout"], cr["reschedule"], cr["timeout_at"]],
      [[True, True], [False, True], "TimeoutError"])
check("an outer cancel inside timeout() stays a CancelledError", cr["outer"], "CancelledError")

async def task_api():
    out = {}
    loop = asyncio.get_running_loop()
    t = asyncio.create_task(double(1), name="api")
    out["repr"] = repr(t).startswith("<Task pending name='api' coro=<")
    out["isfuture"] = [asyncio.isfuture(t), asyncio.isfuture(loop.create_future()), asyncio.isfuture(1)]
    await t
    out["done"] = [t.done(), t.result(), t.exception(), t.get_loop() is loop]
    seen = []
    t.add_done_callback(lambda tt: seen.append(tt.result()))
    await asyncio.sleep(0.01)
    out["callback after done"] = seen
    cur = []
    def in_callback():
        cur.append(asyncio.current_task())
    loop.call_soon(in_callback)
    await asyncio.sleep(0.01)
    out["current_task in a callback"] = cur
    out["current_task in a task"] = asyncio.current_task().get_name() != ""
    me = asyncio.current_task()
    out["all_tasks"] = me in asyncio.all_tasks()
    g = asyncio.gather(double(1), double(2))
    out["gather is a future"] = asyncio.isfuture(g)
    out["gather"] = await g
    out["gather empty"] = await asyncio.gather()
    async def slow_child(tag, log):
        try:
            await asyncio.sleep(10)
        except asyncio.CancelledError:
            log.append(tag)
            raise
    log = []
    g2 = asyncio.gather(slow_child("a", log), slow_child("b", log))
    await asyncio.sleep(0.01)
    g2.cancel()
    try:
        await g2
    except asyncio.CancelledError:
        out["gather cancelled"] = sorted(log)
    rx = await asyncio.gather(double(1), asyncio.sleep(0, "slept"), return_exceptions=True)
    out["gather return_exceptions"] = rx
    inner = asyncio.create_task(asyncio.sleep(0.02, "inner"))
    sh = asyncio.shield(inner)
    sh.cancel()
    out["shield"] = [sh.cancelled(), await inner]
    ef = loop.run_in_executor(None, sum, [4, 5])
    out["executor future"] = await ef
    cf = concurrent.futures.Future()
    wf = asyncio.wrap_future(cf)
    cf.set_result("wrapped")
    out["wrap_future"] = await wf
    def from_thread(res):
        res.append(asyncio.run_coroutine_threadsafe(double(50), loop).result(5))
    res = []
    th = threading.Thread(target=from_thread, args=(res,))
    th.start()
    while not res:
        await asyncio.sleep(0.005)
    th.join()
    out["run_coroutine_threadsafe"] = res
    out["to_thread"] = await asyncio.to_thread(lambda a, b: a * b, 6, 7)
    out["iscoroutinefunction"] = [asyncio.iscoroutinefunction(double), asyncio.iscoroutinefunction(print)]
    co = double(1)
    out["iscoroutine"] = [asyncio.iscoroutine(co), asyncio.iscoroutine(double)]
    await co
    ws = await asyncio.wait([asyncio.create_task(double(1)), asyncio.create_task(asyncio.sleep(0.3))],
                            return_when=asyncio.FIRST_COMPLETED)
    out["wait"] = [len(ws[0]), len(ws[1])]
    for p in ws[1]:
        p.cancel()
    return out

ta = run(task_api())
check("Task repr and isfuture", [ta["repr"], ta["isfuture"]], [True, [True, True, False]])
check("Task result API", ta["done"], [True, 2, None, True])
check("add_done_callback on a finished task", ta["callback after done"], [2])
check("current_task() is None in a loop callback", ta["current_task in a callback"], [None])
check("current_task / all_tasks", [ta["current_task in a task"], ta["all_tasks"]], [True, True])
check("gather gives a future; empty gather", [ta["gather is a future"], ta["gather"], ta["gather empty"]], [True, [2, 4], []])
check("cancelling gather cancels its children", ta["gather cancelled"], ["a", "b"])
check("gather(return_exceptions=True)", ta["gather return_exceptions"], [2, "slept"])
check("shield", ta["shield"], [True, "inner"])
check("executor future, wrap_future, run_coroutine_threadsafe, to_thread",
      [ta["executor future"], ta["wrap_future"], ta["run_coroutine_threadsafe"], ta["to_thread"]], [9, "wrapped", [100], 42])
check("iscoroutinefunction / iscoroutine", [ta["iscoroutinefunction"], ta["iscoroutine"]], [[True, False], [True, False]])
check("wait(FIRST_COMPLETED)", ta["wait"], [1, 1])

# eager tasks (3.12)
if hasattr(asyncio, "eager_task_factory"):
    async def eager():
        loop = asyncio.get_running_loop()
        loop.set_task_factory(asyncio.eager_task_factory)
        trace = []
        async def quick():
            trace.append("quick ran")
            return "q"
        async def waits():
            trace.append("waits started")
            await asyncio.sleep(0.01)
            trace.append("waits finished")
            return "w"
        tq = asyncio.create_task(quick())
        trace.append("after create quick")
        tw = asyncio.create_task(waits())
        trace.append("after create waits")
        done_at_once = [tq.done(), tw.done()]
        r = [await tq, await tw]
        loop.set_task_factory(None)
        return [trace, done_at_once, r]
    check("eager_task_factory: the task runs up to its first wait inside create_task", run(eager()),
          [["quick ran", "after create quick", "waits started", "after create waits", "waits finished"], [True, False], ["q", "w"]])
else:
    skip("eager_task_factory (Python 3.12+)")

# Barrier (3.11)
async def barrier():
    b = asyncio.Barrier(3)
    arrived = []
    async def party(i):
        await asyncio.sleep(0.002 * i)
        arrived.append(i)
        idx = await b.wait()
        return [len(arrived), idx]
    rs = await asyncio.gather(party(0), party(1), party(2))
    out = [[r[0] for r in rs], sorted([r[1] for r in rs]), b.n_waiting, b.broken, b.parties]
    b2 = asyncio.Barrier(2)
    async def waiter():
        try:
            await b2.wait()
        except asyncio.BrokenBarrierError:
            return "broken"
    tw = asyncio.create_task(waiter())
    await asyncio.sleep(0.01)
    out.append(b2.n_waiting)
    await b2.abort()
    out.append(await tw)
    out.append(b2.broken)
    b3 = asyncio.Barrier(2)
    async def pair():
        async with b3 as pos:
            return pos
    out.append(sorted(await asyncio.gather(pair(), pair())))
    return out
check("Barrier", run(barrier()), [[3, 3, 3], [0, 1, 2], 0, False, 3, 1, "broken", True, [0, 1]])

# Queue.shutdown (3.13)
if hasattr(asyncio.Queue, "shutdown"):
    async def qshutdown():
        q = asyncio.Queue()
        await q.put(1)
        await q.put(2)
        q.shutdown()
        out = []
        try:
            await q.put(3)
        except asyncio.QueueShutDown:
            out.append("put refused")
        out.append(await q.get())
        out.append(q.get_nowait())
        try:
            await q.get()
        except asyncio.QueueShutDown:
            out.append("get refused when empty")
        q2 = asyncio.Queue()
        async def getter():
            try:
                await q2.get()
            except asyncio.QueueShutDown:
                return "woken"
        tg = asyncio.create_task(getter())
        await asyncio.sleep(0.01)
        q2.shutdown()
        out.append(await tg)
        q3 = asyncio.Queue()
        q3.put_nowait("a")
        q3.put_nowait("b")
        q3.shutdown(immediate=True)
        out.append(q3.qsize())
        await q3.join()
        out.append("joined")
        return out
    check("Queue.shutdown", run(qshutdown()), ["put refused", 1, 2, "get refused when empty", "woken", 0, "joined"])
else:
    skip("Queue.shutdown (Python 3.13+)")

# ── 3. transports and protocols over TCP ──────────────────────────────────────
class UpperEcho(asyncio.Protocol):
    def __init__(self, log):
        self.log = log
    def connection_made(self, transport):
        self.transport = transport
        self.log.append("server made")
    def data_received(self, data):
        self.transport.write(data.upper())
    def eof_received(self):
        self.log.append("server eof")
    def connection_lost(self, exc):
        self.log.append("server lost " + repr(exc))

class Collect(asyncio.Protocol):
    def __init__(self, done):
        self.done = done
        self.buf = b""
        self.log = []
    def connection_made(self, transport):
        self.transport = transport
        self.log.append("made")
        transport.write(b"hello, ")
        transport.writelines([b"proto", b"cols"])
        self.log.append(transport.can_write_eof())
        transport.write_eof()
    def data_received(self, data):
        self.buf += data
    def eof_received(self):
        self.log.append("eof")
    def connection_lost(self, exc):
        self.log.append("lost " + repr(exc))
        self.done.set_result(self.buf)

async def tcp_protocols():
    loop = asyncio.get_running_loop()
    slog = []
    server = await loop.create_server(lambda: UpperEcho(slog), "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    out = {"serving": server.is_serving(), "server loop": server.get_loop() is loop}
    done = loop.create_future()
    tr, pr = await loop.create_connection(lambda: Collect(done), "127.0.0.1", port)
    out["extra"] = [tr.get_extra_info("peername")[1] == port, tr.get_extra_info("sockname")[0],
                    tr.get_extra_info("socket") is not None, tr.get_extra_info("nonesuch", "dflt")]
    out["echo"] = await asyncio.wait_for(done, 5)
    await asyncio.sleep(0.02)
    out["client log"] = pr.log
    out["server log"] = slog
    out["closing"] = tr.is_closing()
    server.close()
    await server.wait_closed()
    out["closed"] = [server.is_serving(), server.sockets]
    refused = "none"
    try:
        await loop.create_connection(asyncio.Protocol, "127.0.0.1", port)
    except ConnectionRefusedError as e:
        refused = "ConnectionRefusedError"
    out["refused"] = refused
    try:
        await loop.create_connection(asyncio.Protocol, "127.0.0.1", 1, sock=socket.socket())
    except ValueError as e:
        out["both"] = str(e)
    try:
        await loop.create_connection(asyncio.Protocol)
    except ValueError as e:
        out["neither"] = str(e)
    # serve_forever, cancelled; start_serving later
    srv = await loop.create_server(lambda: UpperEcho([]), "127.0.0.1", 0, start_serving=False)
    out["not yet serving"] = srv.is_serving()
    await srv.start_serving()
    sf = asyncio.create_task(srv.serve_forever())
    await asyncio.sleep(0.01)
    out["serve_forever"] = srv.is_serving()
    sf.cancel()
    try:
        await sf
    except asyncio.CancelledError:
        out["serve_forever cancelled"] = srv.is_serving()
    async with await loop.create_server(lambda: UpperEcho([]), "127.0.0.1", 0) as srv3:
        out["async with"] = srv3.is_serving()
    out["after async with"] = srv3.is_serving()
    # an accepted socket handed to the loop
    lsock = socket.socket()
    lsock.bind(("127.0.0.1", 0))
    lsock.listen(1)
    csock = socket.create_connection(lsock.getsockname())
    asock, addr = lsock.accept()
    tr2, pr2 = await loop.connect_accepted_socket(lambda: UpperEcho([]), asock)
    csock.sendall(b"accepted")
    data = b""
    csock.setblocking(False)
    while len(data) < 8:
        try:
            data += await loop.sock_recv(csock, 100)
        except BlockingIOError:
            await asyncio.sleep(0.005)
    out["connect_accepted_socket"] = data
    tr2.close()
    csock.close()
    lsock.close()
    # abort
    done2 = loop.create_future()
    server4 = await loop.create_server(lambda: UpperEcho([]), "127.0.0.1", 0)
    class Aborter(asyncio.Protocol):
        def connection_made(self, t):
            t.abort()
        def connection_lost(self, exc):
            done2.set_result(repr(exc))
    await loop.create_connection(Aborter, "127.0.0.1", server4.sockets[0].getsockname()[1])
    out["abort"] = await asyncio.wait_for(done2, 5)
    server4.close()
    return out

tp = run(tcp_protocols())
check("Server object", [tp["serving"], tp["server loop"]], [True, True])
check("get_extra_info", tp["extra"], [True, "127.0.0.1", True, "dflt"])
check("TCP echo with a Protocol (write, writelines, write_eof)", tp["echo"], b"HELLO, PROTOCOLS")
check("the client's callbacks in order", tp["client log"], ["made", True, "eof", "lost None"])
check("the server's callbacks in order", tp["server log"], ["server made", "server eof", "server lost None"])
check("is_closing after connection_lost", tp["closing"], True)
check("Server.close / wait_closed", tp["closed"], [False, ()])
check("create_connection refused", tp["refused"], "ConnectionRefusedError")
check("create_connection argument errors", [tp["both"], tp["neither"]],
      ["host/port and sock can not be specified at the same time", "host and port was not specified and no sock specified"])
check("start_serving=False, start_serving(), serve_forever cancelled",
      [tp["not yet serving"], tp["serve_forever"], tp["serve_forever cancelled"]], [False, True, False])
check("async with server", [tp["async with"], tp["after async with"]], [True, False])
check("connect_accepted_socket", tp["connect_accepted_socket"], b"ACCEPTED")
check("abort() ends the connection at once", tp["abort"], "None")

# ── 4. flow control ───────────────────────────────────────────────────────────
async def flow_control():
    loop = asyncio.get_running_loop()
    got = []
    server_tr = loop.create_future()
    class SlowReader(asyncio.Protocol):
        def connection_made(self, t):
            t.pause_reading()
            got.append(t.is_reading())
            server_tr.set_result(t)
        def data_received(self, data):
            got.append(len(data))
    server = await loop.create_server(SlowReader, "127.0.0.1", 0)
    events = []
    resumed = loop.create_future()
    class Writer(asyncio.Protocol):
        def connection_made(self, t):
            t.set_write_buffer_limits(high=16384, low=4096)
        def pause_writing(self):
            events.append("pause_writing")
        def resume_writing(self):
            events.append("resume_writing")
            if not resumed.done():
                resumed.set_result(True)
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32768)
    sock.connect(server.sockets[0].getsockname())
    tr, pr = await loop.create_connection(Writer, sock=sock)
    st = await server_tr
    chunk = b"x" * 65536
    sent = 0
    n = 0
    while "pause_writing" not in events and n < 4000:
        tr.write(chunk)
        sent += len(chunk)
        n += 1
    buffered = tr.get_write_buffer_size()
    limits = tr.get_write_buffer_limits()
    st.resume_reading()
    await asyncio.wait_for(resumed, 10)
    while sum(got[1:]) < sent:
        await asyncio.sleep(0.01)
    tr.close()
    server.close()
    return [events, buffered > 16384, limits, got[0], sum(got[1:]) == sent, st.is_reading()]
check("flow control: pause_writing above the high mark, resume_writing at the low one", run(flow_control()),
      [["pause_writing", "resume_writing"], True, (4096, 16384), False, True, True])

async def drain_flow():
    # StreamWriter.drain() waits while the transport is paused
    loop = asyncio.get_running_loop()
    release = asyncio.Event()
    total = []
    async def lazy(reader, writer):
        await release.wait()
        n = 0
        while True:
            d = await reader.read(65536)
            if not d:
                break
            n += len(d)
        total.append(n)
        writer.close()
    server = await asyncio.start_server(lazy, "127.0.0.1", 0)
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32768)
    sock.connect(server.sockets[0].getsockname())
    reader, writer = await asyncio.open_connection(sock=sock)
    writer.transport.set_write_buffer_limits(high=8192)
    payload = b"y" * (4 * 1024 * 1024)
    writer.write(payload)
    blocked = []
    dr = asyncio.create_task(writer.drain())
    await asyncio.sleep(0.05)
    blocked.append(dr.done())
    release.set()
    await asyncio.wait_for(dr, 10)
    writer.write_eof()
    while not total:
        await asyncio.sleep(0.01)
    writer.close()
    await writer.wait_closed()
    server.close()
    return [blocked, total]
check("drain() waits for the buffer to empty", run(drain_flow()), [[False], [4 * 1024 * 1024]])

# ── 5. UDP ────────────────────────────────────────────────────────────────────
async def udp():
    loop = asyncio.get_running_loop()
    class Reverse(asyncio.DatagramProtocol):
        def connection_made(self, t):
            self.t = t
        def datagram_received(self, data, addr):
            self.t.sendto(data[::-1], addr)
    st, sp = await loop.create_datagram_endpoint(Reverse, local_addr=("127.0.0.1", 0))
    port = st.get_extra_info("sockname")[1]
    got = loop.create_future()
    lost = loop.create_future()
    class Client(asyncio.DatagramProtocol):
        def connection_made(self, t):
            t.sendto(b"ping")
        def datagram_received(self, data, addr):
            if not got.done():
                got.set_result([data, addr[1] == port])
        def connection_lost(self, exc):
            lost.set_result(exc)
    ct, cp = await loop.create_datagram_endpoint(Client, remote_addr=("127.0.0.1", port))
    out = [await asyncio.wait_for(got, 5)]
    bad = "none"
    try:
        ct.sendto(b"x", ("127.0.0.1", port + 1))
    except ValueError as e:
        bad = str(e).split(":")[0]
    out.append(bad)
    out.append(ct.get_write_buffer_size())
    ct.close()
    out.append(await asyncio.wait_for(lost, 5))
    out.append(ct.is_closing())
    # an unconnected endpoint talking to several peers
    replies = []
    done = loop.create_future()
    class Multi(asyncio.DatagramProtocol):
        def datagram_received(self, data, addr):
            replies.append(data)
            if len(replies) == 2:
                done.set_result(True)
    mt, mp = await loop.create_datagram_endpoint(Multi, local_addr=("127.0.0.1", 0))
    mt.sendto(b"one", ("127.0.0.1", port))
    mt.sendto(b"two", ("127.0.0.1", port))
    await asyncio.wait_for(done, 5)
    out.append(sorted(replies))
    mt.close()
    st.close()
    return out
check("UDP echo with DatagramProtocol", run(udp()), [[b"gnip", True], "Invalid address", 0, None, True, [b"eno", b"owt"]])

# ── 6. streams over the protocols ─────────────────────────────────────────────
async def streams():
    out = {}
    async def handle(reader, writer):
        out["server peer"] = writer.get_extra_info("peername")[0]
        async for line in reader:
            writer.write(b"echo:" + line)
            await writer.drain()
        writer.write(b"bye")
        writer.close()
        await writer.wait_closed()
    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    lines = []
    for i in range(3):
        writer.write(("line %d\n" % i).encode())
        await writer.drain()
        lines.append(await reader.readline())
    writer.write_eof()
    out["lines"] = lines
    out["rest"] = await reader.read()
    out["at_eof"] = reader.at_eof()
    writer.close()
    await writer.wait_closed()
    out["is_closing"] = writer.is_closing()
    out["transport"] = isinstance(writer.transport, asyncio.Transport)
    rd = asyncio.StreamReader()
    rd.feed_data(b"key=value;rest")
    rd.feed_eof()
    out["readuntil"] = await rd.readuntil(b";")
    try:
        await rd.readexactly(10)
    except asyncio.IncompleteReadError as e:
        out["incomplete"] = [e.partial, e.expected, str(e)]
    small = asyncio.StreamReader(limit=4)
    small.feed_data(b"abcdefgh\nxy\n")
    small.feed_eof()
    try:
        await small.readuntil(b"\n")
    except asyncio.LimitOverrunError as e:
        out["limit"] = [str(e), e.consumed]
    try:
        await small.readline()
    except ValueError as e:
        out["readline limit"] = str(e)
    out["after limit"] = await small.readline()
    try:
        asyncio.StreamReader(limit=0)
    except ValueError as e:
        out["limit 0"] = str(e)
    waiting = asyncio.StreamReader()
    async def feed_later():
        await asyncio.sleep(0.01)
        waiting.feed_data(b"late data")
        waiting.feed_eof()
    asyncio.create_task(feed_later())
    out["waits for data"] = await waiting.read(4)
    out["exactly"] = await waiting.readexactly(5)
    errd = asyncio.StreamReader()
    errd.set_exception(ConnectionResetError("gone"))
    try:
        await errd.read()
    except ConnectionResetError as e:
        out["exception"] = str(e)
    server.close()
    await server.wait_closed()
    return out

sr = run(streams())
check("stream echo over StreamReaderProtocol", [sr["lines"], sr["rest"], sr["at_eof"]],
      [[b"echo:line 0\n", b"echo:line 1\n", b"echo:line 2\n"], b"bye", True])
check("StreamWriter state", [sr["is_closing"], sr["transport"], sr["server peer"]], [True, True, "127.0.0.1"])
check("readuntil / IncompleteReadError", [sr["readuntil"], sr["incomplete"]],
      [b"key=value;", [b"rest", 10, "4 bytes read on a total of 10 expected bytes"]])
check("LimitOverrunError and readline's ValueError",
      [sr["limit"], sr["readline limit"], sr["after limit"], sr["limit 0"]],
      [["Separator is found, but chunk is longer than limit", 8], "Separator is found, but chunk is longer than limit", b"xy\n", "Limit cannot be <= 0"])
check("a read waits for data", [sr["waits for data"], sr["exactly"], sr["exception"]], [b"late", b" data", "gone"])

# ── 7. low-level socket operations, readers and writers ───────────────────────
async def lowlevel():
    loop = asyncio.get_running_loop()
    out = {}
    a, b = socket.socketpair()
    a.setblocking(False)
    b.setblocking(False)
    await loop.sock_sendall(a, b"over a socketpair")
    out["sock_recv"] = await loop.sock_recv(b, 100)
    buf = bytearray(8)
    await loop.sock_sendall(a, b"12345")
    out["sock_recv_into"] = [await loop.sock_recv_into(b, buf), bytes(buf[:5])]
    # add_reader / remove_reader
    got = []
    ready = asyncio.Event()
    def on_readable():
        got.append(b.recv(100))
        ready.set()
    loop.add_reader(b, on_readable)
    a.send(b"readable")
    await asyncio.wait_for(ready.wait(), 5)
    out["add_reader"] = [got, loop.remove_reader(b), loop.remove_reader(b)]
    writable = asyncio.Event()
    loop.add_writer(a, writable.set)
    await asyncio.wait_for(writable.wait(), 5)
    out["add_writer"] = [writable.is_set(), loop.remove_writer(a)]
    a.close()
    b.close()
    # accept and connect without transports
    ls = socket.socket()
    ls.bind(("127.0.0.1", 0))
    ls.listen(5)
    ls.setblocking(False)
    cs = socket.socket()
    cs.setblocking(False)
    acc = asyncio.create_task(loop.sock_accept(ls))
    await loop.sock_connect(cs, ls.getsockname())
    conn, addr = await acc
    await loop.sock_sendall(cs, b"via sock_*")
    out["sock_accept"] = [addr[0], await loop.sock_recv(conn, 100)]
    conn.close()
    cs.close()
    ls.close()
    # UDP
    u1 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u1.bind(("127.0.0.1", 0))
    u1.setblocking(False)
    u2 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u2.setblocking(False)
    await loop.sock_sendto(u2, b"datagram", u1.getsockname())
    data, frm = await loop.sock_recvfrom(u1, 100)
    out["sock_recvfrom"] = [data, frm[1] == u2.getsockname()[1]]
    u1.close()
    u2.close()
    infos = await loop.getaddrinfo("127.0.0.1", 80, type=socket.SOCK_STREAM)
    out["getaddrinfo"] = [infos[0][0] == socket.AF_INET, infos[0][4]]
    out["getnameinfo"] = (await loop.getnameinfo(("127.0.0.1", 80), socket.NI_NUMERICHOST | socket.NI_NUMERICSERV))
    return out

ll = run(lowlevel())
check("sock_sendall / sock_recv / sock_recv_into", [ll["sock_recv"], ll["sock_recv_into"]], [b"over a socketpair", [5, b"12345"]])
check("add_reader / remove_reader", ll["add_reader"], [[b"readable"], True, False])
check("add_writer / remove_writer", ll["add_writer"], [True, True])
check("sock_accept / sock_connect", ll["sock_accept"], ["127.0.0.1", b"via sock_*"])
check("sock_sendto / sock_recvfrom", ll["sock_recvfrom"], [b"datagram", True])
check("getaddrinfo / getnameinfo", [ll["getaddrinfo"], ll["getnameinfo"]], [[True, ("127.0.0.1", 80)], ("127.0.0.1", "80")])

# ── 8. Unix sockets ───────────────────────────────────────────────────────────
if POSIX and hasattr(socket, "AF_UNIX"):
    async def unix():
        loop = asyncio.get_running_loop()
        path = os.path.join(TMP, "s%d.sock" % os.getpid())
        async def handle(reader, writer):
            data = await reader.read(100)
            writer.write(data[::-1])
            await writer.drain()
            writer.close()
        server = await asyncio.start_unix_server(handle, path)
        out = [server.sockets[0].getsockname() == path, os.path.exists(path)]
        reader, writer = await asyncio.open_unix_connection(path)
        writer.write(b"unix stream")
        writer.write_eof()
        out.append(await reader.read())
        writer.close()
        server.close()
        await server.wait_closed()
        # a stale socket file is replaced; protocols over a Unix socket
        log = []
        server2 = await loop.create_unix_server(lambda: UpperEcho(log), path)
        done = loop.create_future()
        tr, pr = await loop.create_unix_connection(lambda: Collect(done), path)
        out.append(await asyncio.wait_for(done, 5))
        server2.close()
        await server2.wait_closed()
        try:
            await asyncio.open_unix_connection(os.path.join(TMP, "missing.sock"))
        except FileNotFoundError:
            out.append("FileNotFoundError")
        try:
            await loop.create_unix_server(asyncio.Protocol, path, sock=socket.socket(socket.AF_UNIX))
        except ValueError as e:
            out.append(str(e))
        return out
    check("Unix sockets: streams and protocols", run(unix()),
          [True, True, b"maerts xinu", b"HELLO, PROTOCOLS", "FileNotFoundError", "path and sock can not be specified at the same time"])
else:
    skip("Unix sockets (POSIX)")

# ── 9. subprocesses ───────────────────────────────────────────────────────────
UPPER = "import sys\ndata = sys.stdin.read()\nsys.stdout.write(data.upper())\nsys.stderr.write('read ' + str(len(data)))\nsys.exit(3)\n"
LINES = "import sys\nfor i in range(3):\n    print('line', i)\n    sys.stdout.flush()\n"
SLEEPER = "import time\ntime.sleep(10)\n"

async def subprocesses():
    out = {}
    P = asyncio.subprocess.PIPE
    out["constants"] = [asyncio.subprocess.PIPE, asyncio.subprocess.STDOUT, asyncio.subprocess.DEVNULL]
    p = await asyncio.create_subprocess_exec(PY, "-c", UPPER, stdin=P, stdout=P, stderr=P)
    o, e = await p.communicate(b"hello child")
    out["communicate"] = [o, e, p.returncode, p.pid > 0, isinstance(p.stdout, asyncio.StreamReader)]
    p2 = await asyncio.create_subprocess_exec(PY, "-c", LINES, stdout=P)
    got = []
    async for line in p2.stdout:
        got.append(line.strip())
    out["streaming"] = [got, await p2.wait()]
    # a pipeline: one child's output is the next one's input
    first = await asyncio.create_subprocess_exec(PY, "-c", LINES, stdout=P)
    first_out, _ = await first.communicate()
    second = await asyncio.create_subprocess_exec(PY, "-c", UPPER, stdin=P, stdout=P, stderr=asyncio.subprocess.DEVNULL)
    o2, e2 = await second.communicate(first_out)
    out["pipeline"] = [o2.replace(b"\r\n", b"\n"), e2, second.returncode]
    merged = await asyncio.create_subprocess_exec(PY, "-c", "import sys\nsys.stderr.write('E')\nsys.stderr.flush()\nsys.stdout.write('O')\n",
                                                 stdout=P, stderr=asyncio.subprocess.STDOUT)
    mo, me = await merged.communicate()
    out["stderr=STDOUT"] = [sorted(mo.decode()), me]
    sh = await asyncio.create_subprocess_shell("echo shell works", stdout=P)
    so, _ = await sh.communicate()
    out["shell"] = so.strip()
    # stdin written in pieces, read back as it comes
    cat = await asyncio.create_subprocess_exec(PY, "-c", "import sys\nfor line in sys.stdin:\n    sys.stdout.write('> ' + line)\n    sys.stdout.flush()\n",
                                              stdin=P, stdout=P)
    answers = []
    for w in [b"a\n", b"b\n"]:
        cat.stdin.write(w)
        await cat.stdin.drain()
        answers.append(await cat.stdout.readline())
    cat.stdin.close()
    out["interactive"] = [[x.replace(b"\r\n", b"\n") for x in answers], await cat.wait()]
    big = b"z" * 300000
    echo = await asyncio.create_subprocess_exec(PY, "-c", "import sys\nd = sys.stdin.buffer.read() if hasattr(sys.stdin, 'buffer') else sys.stdin.read().encode()\nsys.stdout.write(str(len(d)))\n",
                                               stdin=P, stdout=P)
    bo, _ = await echo.communicate(big)
    out["big input"] = bo
    # meanwhile the loop is not blocked
    ticks = []
    async def ticker():
        for i in range(5):
            ticks.append(i)
            await asyncio.sleep(0.01)
    slow = await asyncio.create_subprocess_exec(PY, "-c", "import time\ntime.sleep(0.2)\nprint('done')\n", stdout=P)
    tt = asyncio.create_task(ticker())
    so2, _ = await slow.communicate()
    await tt
    out["loop runs meanwhile"] = [ticks, so2.strip()]
    return out

sp = run(subprocesses())
check("asyncio.subprocess constants", sp["constants"], [-1, -2, -3])
check("communicate(input)", sp["communicate"], [b"HELLO CHILD", b"read 11", 3, True, True])
check("a child's output read line by line", sp["streaming"], [[b"line 0", b"line 1", b"line 2"], 0])
check("a pipeline", sp["pipeline"], [b"LINE 0\nLINE 1\nLINE 2\n", None, 3])
check("stderr=STDOUT", sp["stderr=STDOUT"], [["E", "O"], None])
check("create_subprocess_shell", sp["shell"], b"shell works")
check("stdin written and answered piece by piece", sp["interactive"], [[b"> a\n", b"> b\n"], 0])
check("a large input does not deadlock", sp["big input"], b"300000")
check("the loop runs while a child works", sp["loop runs meanwhile"], [[0, 1, 2, 3, 4], b"done"])

class Recorder(asyncio.SubprocessProtocol):
    def __init__(self, done):
        self.done = done
        self.data = {1: b"", 2: b""}
        self.events = []
    def connection_made(self, transport):
        self.events.append("connection_made")
    def pipe_data_received(self, fd, data):
        self.data[fd] += data
    def pipe_connection_lost(self, fd, exc):
        self.events.append("pipe_connection_lost %d" % fd)
    def process_exited(self):
        self.events.append("process_exited")
    def connection_lost(self, exc):
        self.events.append("connection_lost")
        self.done.set_result(True)

async def subprocess_protocol():
    loop = asyncio.get_running_loop()
    done = loop.create_future()
    tr, pr = await loop.subprocess_exec(lambda: Recorder(done), PY, "-c", "import sys\nprint('out')\nsys.stderr.write('err')\nsys.exit(7)\n",
                                        stdin=None)
    await asyncio.wait_for(done, 10)
    out = [pr.data[1].strip(), pr.data[2], tr.get_returncode(), tr.get_pid() > 0,
           tr.get_pipe_transport(1) is not None, tr.get_pipe_transport(0)]
    ev = pr.events
    out.append([ev[0], ev[-1], sorted(ev[1:-1])])
    tr.close()
    errs = []
    try:
        await loop.subprocess_exec(asyncio.SubprocessProtocol, PY, "-c", "pass", universal_newlines=True)
    except ValueError as e:
        errs.append(str(e))
    try:
        await loop.subprocess_shell(asyncio.SubprocessProtocol, ["ls"])
    except ValueError as e:
        errs.append(str(e))
    try:
        await loop.subprocess_exec(asyncio.SubprocessProtocol, PY, "-c", "pass", bufsize=1)
    except ValueError as e:
        errs.append(str(e))
    out.append(errs)
    return out
check("loop.subprocess_exec with a SubprocessProtocol", run(subprocess_protocol()),
      [b"out", b"err", 7, True, True, None,
       ["connection_made", "connection_lost", ["pipe_connection_lost 1", "pipe_connection_lost 2", "process_exited"]],
       ["universal_newlines must be False", "cmd must be a string", "bufsize must be 0"]])

if POSIX:
    async def child_signals():
        P = asyncio.subprocess.PIPE
        p = await asyncio.create_subprocess_exec(PY, "-c", SLEEPER, stdout=P)
        await asyncio.sleep(0.05)
        p.terminate()
        r1 = await asyncio.wait_for(p.wait(), 10)
        p2 = await asyncio.create_subprocess_exec(PY, "-c", SLEEPER, stdout=P)
        p2.kill()
        r2 = await asyncio.wait_for(p2.wait(), 10)
        p3 = await asyncio.create_subprocess_exec(PY, "-c", SLEEPER, stdout=P)
        p3.send_signal(signal.SIGUSR1)
        r3 = await asyncio.wait_for(p3.wait(), 10)
        return [r1, r2, r3, p.returncode]
    check("terminate / kill / send_signal", run(child_signals()), [-15, -9, -signal.SIGUSR1, -15])
else:
    skip("signals to children (POSIX)")

# ── 10. signals ───────────────────────────────────────────────────────────────
if POSIX:
    async def loop_signals():
        loop = asyncio.get_running_loop()
        got = []
        ev = asyncio.Event()
        def on_usr1(tag):
            got.append([tag, asyncio.current_task()])
            ev.set()
        loop.add_signal_handler(signal.SIGUSR1, on_usr1, "usr1")
        os.kill(os.getpid(), signal.SIGUSR1)
        await asyncio.wait_for(ev.wait(), 5)
        ev.clear()
        os.kill(os.getpid(), signal.SIGUSR1)
        await asyncio.wait_for(ev.wait(), 5)
        out = [got, loop.remove_signal_handler(signal.SIGUSR1), loop.remove_signal_handler(signal.SIGUSR1),
               signal.getsignal(signal.SIGUSR1) == signal.SIG_DFL]
        errs = []
        try:
            loop.add_signal_handler(signal.SIGKILL, print)
        except RuntimeError as e:
            errs.append(str(e))
        try:
            loop.add_signal_handler("x", print)
        except TypeError as e:
            errs.append(str(e))
        async def coro_handler():
            pass
        try:
            loop.add_signal_handler(signal.SIGUSR2, coro_handler)
        except TypeError as e:
            errs.append(str(e))
        try:
            loop.add_signal_handler(0, print)
        except ValueError as e:
            errs.append(str(e))
        out.append(errs)
        return out
    check("loop.add_signal_handler / remove_signal_handler", run(loop_signals()),
          [[["usr1", None], ["usr1", None]], True, False, True,
           ["sig %d cannot be caught" % signal.SIGKILL, "sig must be an int, not 'x'",
            "coroutines cannot be used with add_signal_handler()", "invalid signal number 0"]])

    trace = []
    async def interrupted():
        os.kill(os.getpid(), signal.SIGINT)
        try:
            await asyncio.sleep(5)
            trace.append("not interrupted")
        except asyncio.CancelledError:
            trace.append("main task cancelled")
            raise
    try:
        asyncio.run(interrupted())
    except KeyboardInterrupt:
        trace.append("KeyboardInterrupt")
    trace.append(signal.getsignal(signal.SIGINT) is signal.default_int_handler)
    check("asyncio.run and Ctrl+C: the main task is cancelled, then KeyboardInterrupt", trace,
          ["main task cancelled", "KeyboardInterrupt", True])
    trace2 = []
    async def survives_ctrl_c():
        os.kill(os.getpid(), signal.SIGINT)
        try:
            await asyncio.sleep(5)
        except asyncio.CancelledError:
            trace2.append("cancelled")
        return "returned"
    trace2.append(asyncio.run(survives_ctrl_c()))
    check("a main task that handles the cancellation returns normally", trace2, ["cancelled", "returned"])
else:
    skip("add_signal_handler and asyncio.run's Ctrl+C (POSIX)")

# ── 11. TLS ───────────────────────────────────────────────────────────────────
def make_certs():
    d = os.path.join(TMP, "tls")
    os.makedirs(d)
    ext = os.path.join(d, "ext.cnf")
    with open(ext, "w") as f:
        f.write("subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
    steps = [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", d + "/ca.key", "-out", d + "/ca.pem", "-days", "2", "-subj", "/CN=audit104 CA",
         "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"],
        ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", d + "/server.key", "-out", d + "/server.csr", "-subj", "/CN=localhost"],
        ["openssl", "x509", "-req", "-in", d + "/server.csr", "-CA", d + "/ca.pem", "-CAkey", d + "/ca.key", "-CAcreateserial", "-out", d + "/server.pem", "-days", "2", "-extfile", ext]]
    for s in steps:
        try:
            r = subprocess.run(s, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            if r.returncode != 0:
                return None
        except Exception:
            return None
    return d

ssl_mod = None
try:
    import ssl as ssl_mod
except ImportError:
    ssl_mod = None
TLS = None
if ssl_mod is not None and shutil.which("openssl") and getattr(ssl_mod, "HAS_TLS", True):
    TLS = make_certs()

if TLS is not None:
    def server_ctx():
        c = ssl_mod.SSLContext(ssl_mod.PROTOCOL_TLS_SERVER)
        c.load_cert_chain(TLS + "/server.pem", TLS + "/server.key")
        return c
    def client_ctx():
        return ssl_mod.create_default_context(cafile=TLS + "/ca.pem")

    async def tls():
        loop = asyncio.get_running_loop()
        out = {}
        async def handle(reader, writer):
            line = await reader.readline()
            writer.write(b"tls:" + line)
            await writer.drain()
            writer.close()
        server = await asyncio.start_server(handle, "127.0.0.1", 0, ssl=server_ctx())
        port = server.sockets[0].getsockname()[1]
        cctx = client_ctx()
        reader, writer = await asyncio.open_connection("127.0.0.1", port, ssl=cctx, server_hostname="localhost")
        writer.write(b"secret\n")
        await writer.drain()
        out["echo"] = await reader.read()
        out["extra"] = [writer.get_extra_info("sslcontext") is cctx, writer.get_extra_info("ssl_object") is not None,
                        writer.get_extra_info("peercert") is not None, writer.can_write_eof()]
        writer.close()
        # a Protocol over TLS
        done = loop.create_future()
        class Once(asyncio.Protocol):
            def connection_made(self, t):
                t.write(b"protocol\n")
            def data_received(self, d):
                if not done.done():
                    done.set_result(d)
        tr, pr = await loop.create_connection(Once, "127.0.0.1", port, ssl=cctx, server_hostname="localhost")
        out["protocol"] = await asyncio.wait_for(done, 5)
        tr.close()
        # an untrusted server
        try:
            await asyncio.open_connection("127.0.0.1", port, ssl=ssl_mod.create_default_context(), server_hostname="localhost")
            out["untrusted"] = "accepted"
        except ssl_mod.SSLCertVerificationError:
            out["untrusted"] = "SSLCertVerificationError"
        except ssl_mod.SSLError:
            out["untrusted"] = "SSLError"
        try:
            await loop.create_connection(asyncio.Protocol, "127.0.0.1", port, server_hostname="x")
        except ValueError as e:
            out["hostname without ssl"] = str(e)
        server.close()
        await server.wait_closed()
        # STARTTLS: plain first, then upgraded in place
        async def starttls_server(reader, writer):
            cmd = await reader.readline()
            writer.write(b"OK " + cmd)
            await writer.drain()
            await writer.start_tls(server_ctx())
            line = await reader.readline()
            writer.write(b"secure:" + line)
            await writer.drain()
            writer.close()
        server2 = await asyncio.start_server(starttls_server, "127.0.0.1", 0)
        r2, w2 = await asyncio.open_connection("127.0.0.1", server2.sockets[0].getsockname()[1])
        w2.write(b"STARTTLS\n")
        ok = await r2.readline()
        await w2.start_tls(client_ctx(), server_hostname="localhost")
        w2.write(b"after upgrade\n")
        await w2.drain()
        out["starttls"] = [ok, await r2.read(), w2.get_extra_info("ssl_object") is not None]
        w2.close()
        server2.close()
        await server2.wait_closed()
        return out
    tr_ = run(tls())
    check("TLS stream echo", tr_["echo"], b"tls:secret\n")
    check("TLS extra info; no half-close over TLS", tr_["extra"], [True, True, True, False])
    check("a Protocol over TLS (create_connection(ssl=))", tr_["protocol"], b"tls:protocol\n")
    check("an untrusted certificate is refused", tr_["untrusted"], "SSLCertVerificationError")
    check("server_hostname without ssl", tr_["hostname without ssl"], "server_hostname is only meaningful with ssl")
    check("StreamWriter.start_tls (STARTTLS)", tr_["starttls"], [b"OK STARTTLS\n", b"secure:after upgrade\n", True])
else:
    skip("TLS (needs the openssl command)")

# ── 12. Nython: structured-concurrency reports ────────────────────────────────
if nython:
    async def leaves_children():
        loop = asyncio.get_running_loop()
        seen = []
        loop.set_exception_handler(lambda lp, ctx: seen.append(ctx["message"]))
        async def kid():
            await asyncio.sleep(10)
        async def parent():
            asyncio.create_task(kid(), name="kid")
            await asyncio.sleep(0)
        await asyncio.create_task(parent(), name="parent")
        async with asyncio.TaskGroup() as tg:
            tg.create_task(asyncio.sleep(0.001))
        await asyncio.sleep(0.01)
        return seen
    with asyncio.Runner(orphans="warn") as r:
        msgs = r.run(leaves_children())
    check("orphans='warn': a task that outlives its creator, then the run",
          [len(msgs), msgs[0].startswith("Task 'kid' outlived the task that created it (parent) and is still running (created at "),
           msgs[1].startswith("Task 'kid' outlived the run of its main task"), [o.name for o in r.orphans],
           r.orphans[0].created_at is not None, r.orphans[0].parent],
          [2, True, True, ["kid", "kid"], True, "parent"])
    raised = "none"
    async def leaves_one():
        asyncio.create_task(asyncio.sleep(10), name="stray")
        await asyncio.sleep(0)
    try:
        asyncio.run(leaves_one(), orphans="raise")
    except asyncio.OrphanedTasksError as e:
        raised = [str(e), [o.name for o in e.orphans]]
    check("orphans='raise'", raised, ["1 task(s) left running: 'stray'", ["stray"]])
    async def tidy():
        async with asyncio.TaskGroup() as tg:
            tg.create_task(asyncio.sleep(0.001))
        return "tidy"
    with asyncio.Runner(orphans="raise") as r2:
        check("a run whose children all finish reports nothing", [r2.run(tidy()), r2.orphans], ["tidy", []])

try:
    asyncio.run(double)
except ValueError as e:
    check("asyncio.run(non-coroutine)", str(e).startswith("a coroutine was expected, got"), True)
with asyncio.Runner() as runner:
    check("Runner runs several coroutines on one loop", [runner.run(double(1)), runner.run(double(2)),
                                                        isinstance(runner.get_loop(), asyncio.AbstractEventLoop)], [2, 4, True])
closed_runner = "none"
late = double(1)
try:
    runner.run(late)
except RuntimeError as e:
    closed_runner = str(e)
    late.close()
check("a closed Runner", closed_runner, "Runner is closed")

shutil.rmtree(TMP, ignore_errors=True)

pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
if skipped:
    print("skipped: " + ", ".join(skipped))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT104 PASSED ===")
