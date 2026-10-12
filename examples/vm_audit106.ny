# vm_audit106.ny - asyncio behaviours round 82 left different from CPython,
# and the pieces it left out (round 82 follow-ups).
#
# TaskGroup raises every failure as a group (one included), children's
# errors before the body's; wait() refuses coroutines; a task cancelled
# without a message gets CancelledError() with empty args; the default
# executor is a ThreadPoolExecutor; create_server(host=None) listens on
# every wildcard address getaddrinfo gives; loop.sock_sendfile (the
# kernel's os.sendfile, or the fallback), loop.sendfile through a
# transport, connect_read_pipe / connect_write_pipe; os.sendfile.
#
# Every expected value is CPython's (3.11+); it runs under python3 too:
#
#     ./build/nython-cli examples/vm_audit106.ny
#     ./build/nython-cli --vm examples/vm_audit106.ny
#     python3 examples/vm_audit106.ny

import asyncio, os, socket, sys, tempfile, io

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

POSIX = os.name != "nt"
tmpdir = tempfile.mkdtemp()

async def fail_after(delay, exc):
    await asyncio.sleep(delay)
    raise exc

# ── TaskGroup ─────────────────────────────────────────────────────────────
async def tg_one():
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(fail_after(0.01, ValueError("only")))
            await asyncio.sleep(1)
    except BaseException as e:
        return [type(e).__name__, [type(x).__name__ for x in e.exceptions], str(e.exceptions[0])]

async def tg_order():
    # the body fails; the group cancels its child, which fails while being
    # cancelled: the child's error first, the body's last
    async def stubborn():
        try:
            await asyncio.sleep(5)
        except asyncio.CancelledError:
            raise KeyError("child")
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(stubborn())
            await asyncio.sleep(0.01)
            raise ZeroDivisionError("body")
    except BaseException as e:
        return [type(e).__name__, [type(x).__name__ for x in e.exceptions]]

async def tg_body_only():
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(asyncio.sleep(0.01))
            raise RuntimeError("body only")
    except BaseException as e:
        return [type(e).__name__, [str(x) for x in e.exceptions]]

async def tg_ok():
    async with asyncio.TaskGroup() as tg:
        a = tg.create_task(asyncio.sleep(0.01, result="a"))
        b = tg.create_task(asyncio.sleep(0.0, result="b"))
    return [a.result(), b.result()]

async def tg_except_star():
    got = []
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(fail_after(0.0, ValueError("v")))
            tg.create_task(fail_after(0.0, TypeError("t")))
    except* ValueError as eg:
        got.append(("value", len(eg.exceptions)))
    except* TypeError as eg:
        got.append(("type", len(eg.exceptions)))
    return sorted(got)

check("TaskGroup: one failure is a group of one", asyncio.run(tg_one()), ["ExceptionGroup", ["ValueError"], "only"])
check("TaskGroup: the children's errors, then the body's", asyncio.run(tg_order()), ["ExceptionGroup", ["KeyError", "ZeroDivisionError"]])
check("TaskGroup: the body's error alone, in a group", asyncio.run(tg_body_only()), ["ExceptionGroup", ["body only"]])
check("TaskGroup: results", asyncio.run(tg_ok()), ["a", "b"])
check("TaskGroup: except* takes the group apart", asyncio.run(tg_except_star()), [("type", 1), ("value", 1)])

# ── wait() ────────────────────────────────────────────────────────────────
async def wait_coro():
    c = asyncio.sleep(0)
    try:
        await asyncio.wait([c])
        return "accepted"
    except TypeError as e:
        return str(e)
    finally:
        c.close()

async def wait_tasks():
    t1 = asyncio.create_task(asyncio.sleep(0.0, result=1))
    t2 = asyncio.create_task(asyncio.sleep(0.5, result=2))
    done, pending = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
    for p in pending:
        p.cancel()
    return [len(done), len(pending), [t.result() for t in done], type(done).__name__]

async def wait_errors():
    out = []
    try:
        await asyncio.wait([])
    except ValueError as e:
        out.append(str(e))
    t = asyncio.create_task(asyncio.sleep(0))
    try:
        await asyncio.wait([t], return_when="bogus")
    except ValueError as e:
        out.append(str(e))
    await t
    return out

check("wait() refuses coroutines", asyncio.run(wait_coro()), "Passing coroutines is forbidden, use tasks explicitly.")
check("wait() on tasks", asyncio.run(wait_tasks()), [1, 1, [1], "set"])
check("wait() errors", asyncio.run(wait_errors()), ["Set of Tasks/Futures is empty.", "Invalid return_when value: bogus"])

# ── cancel() without a message ────────────────────────────────────────────
async def cancel_args():
    async def sleeper():
        try:
            await asyncio.sleep(5)
        except asyncio.CancelledError as e:
            return ["inner", e.args, str(e)]
    t = asyncio.create_task(sleeper())
    await asyncio.sleep(0.01)
    t.cancel()
    inner = await t
    t2 = asyncio.create_task(asyncio.sleep(5))
    await asyncio.sleep(0.01)
    t2.cancel()
    outer = none_val
    try:
        await t2
    except asyncio.CancelledError as e:
        outer = ["outer", e.args]
    t3 = asyncio.create_task(asyncio.sleep(5))
    await asyncio.sleep(0.01)
    t3.cancel("why")
    msg = none_val
    try:
        await t3
    except asyncio.CancelledError as e:
        msg = ["msg", e.args]
    return [inner, outer, msg]

none_val = None
check("cancel(): empty args; cancel(msg): the message", asyncio.run(cancel_args()),
      [["inner", (), ""], ["outer", ()], ["msg", ("why",)]])

# ── the default executor ──────────────────────────────────────────────────
async def executor():
    loop = asyncio.get_running_loop()
    r = await loop.run_in_executor(None, pow, 2, 10)
    rs = await asyncio.gather(*[loop.run_in_executor(None, abs, -i) for i in range(5)])
    kind = type(loop._default_executor).__name__
    return [r, list(rs), kind]

check("run_in_executor(None, ...) on a thread pool", asyncio.run(executor()), [1024, [0, 1, 2, 3, 4], "ThreadPoolExecutor"])

# ── create_server(host=None) ──────────────────────────────────────────────
async def wildcard_server():
    srv = await asyncio.start_server(lambda r, w: w.close(), None, 0)
    fams = sorted(set([int(s.family) for s in srv.sockets]))
    srv.close()
    await srv.wait_closed()
    return fams

if POSIX and socket.has_ipv6:
    def can_open(fam):
        try:
            socket.socket(fam, socket.SOCK_STREAM).close()
            return True
        except OSError:
            return False
    want = sorted(set([int(i[0]) for i in socket.getaddrinfo(None, 0, socket.AF_UNSPEC, socket.SOCK_STREAM, 0, socket.AI_PASSIVE)
                       if can_open(i[0])]))
    check("create_server(None): every wildcard address", asyncio.run(wildcard_server()), want)

# ── sendfile ──────────────────────────────────────────────────────────────
payload = bytes(range(256)) * 1200          # 307,200 bytes
fpath = os.path.join(tmpdir, "send.bin")
with open(fpath, "wb") as fh:
    fh.write(payload)

async def read_all(reader, n):
    got = b""
    while len(got) < n:
        chunk = await reader.read(65536)
        if not chunk:
            break
        got = got + chunk
    return got

async def sock_sendfile_test():
    loop = asyncio.get_running_loop()
    received = []
    done = asyncio.Event()
    async def handle(reader, writer):
        data = await read_all(reader, len(payload) + 1000)
        received.append(data)
        writer.close()
        done.set()
    srv = await asyncio.start_server(handle, "127.0.0.1", 0)
    port = srv.sockets[0].getsockname()[1]
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setblocking(False)
    await loop.sock_connect(sock, ("127.0.0.1", port))
    with open(fpath, "rb") as f:
        n1 = await loop.sock_sendfile(sock, f)
        pos1 = f.tell()
    with open(fpath, "rb") as f:
        n2 = await loop.sock_sendfile(sock, f, 100, 900)
        pos2 = f.tell()
    sock.close()
    await done.wait()
    srv.close()
    await srv.wait_closed()
    data = received[0]
    return [n1, pos1, n2, pos2, len(data), data == payload + payload[100:1000]]

check("sock_sendfile: whole file, then offset and count", asyncio.run(sock_sendfile_test()),
      [len(payload), len(payload), 900, 1000, len(payload) + 900, True])

async def sock_sendfile_bytesio():
    loop = asyncio.get_running_loop()
    a, b = socket.socketpair()
    a.setblocking(False)
    b.setblocking(False)
    bio = io.BytesIO(b"x" * 5000 + b"END")
    n = await loop.sock_sendfile(a, bio)
    a.close()
    got = b""
    while True:
        chunk = await loop.sock_recv(b, 65536)
        if not chunk:
            break
        got = got + chunk
    b.close()
    return [n, len(got), got[-3:], bio.tell()]

if POSIX:
    check("sock_sendfile: no file descriptor, the fallback", asyncio.run(sock_sendfile_bytesio()), [5003, 5003, b"END", 5003])

async def sendfile_params():
    loop = asyncio.get_running_loop()
    out = []
    a, b = socket.socketpair()
    a.setblocking(False)
    with open(fpath, "rb") as f:
        for args in [(-1, None), (0, 0), ("x", None)]:
            try:
                await loop.sock_sendfile(a, f, args[0], args[1])
                out.append("ok")
            except (ValueError, TypeError) as e:
                out.append(type(e).__name__)
    with open(fpath, "r") as ft:
        try:
            await loop.sock_sendfile(a, ft)
        except ValueError as e:
            out.append(str(e))
    a.close()
    b.close()
    return out

if POSIX:
    check("sock_sendfile: argument checks", asyncio.run(sendfile_params()),
          ["ValueError", "ValueError", "TypeError", "file should be opened in binary mode"])

class Collect(asyncio.Protocol):
    def __init__(self):
        self.data = b""
        self.lost = None
        self.closed = None
        self.eof = False
    def connection_made(self, transport):
        self.transport = transport
        self.closed = asyncio.get_running_loop().create_future()
    def data_received(self, data):
        self.data = self.data + data
    def eof_received(self):
        self.eof = True
    def connection_lost(self, exc):
        self.lost = exc
        if not self.closed.done():
            self.closed.set_result(True)

async def transport_sendfile():
    loop = asyncio.get_running_loop()
    server_proto = []
    def factory():
        p = Collect()
        server_proto.append(p)
        return p
    srv = await loop.create_server(factory, "127.0.0.1", 0)
    port = srv.sockets[0].getsockname()[1]
    tr, pr = await loop.create_connection(asyncio.Protocol, "127.0.0.1", port)
    tr.set_write_buffer_limits(high=4096)
    with open(fpath, "rb") as f:
        n = await loop.sendfile(tr, f, 0, 200000)
        pos = f.tell()
    restored = tr.get_protocol() is pr
    tr.close()
    while len(server_proto) == 0 or server_proto[0].closed is None:
        await asyncio.sleep(0.01)
    await asyncio.wait_for(server_proto[0].closed, 10)
    srv.close()
    await srv.wait_closed()
    got = server_proto[0].data
    return [n, pos, len(got), got == payload[:200000], restored]

check("loop.sendfile through a transport, paced by flow control", asyncio.run(transport_sendfile()),
      [200000, 200000, 200000, True, True])

# ── pipes ─────────────────────────────────────────────────────────────────
async def read_pipe():
    loop = asyncio.get_running_loop()
    r, w = os.pipe()
    pipe = os.fdopen(r, "rb", 0)
    tr, pr = await loop.connect_read_pipe(Collect, pipe)
    os.write(w, b"hello ")
    await asyncio.sleep(0.02)
    os.write(w, b"pipe")
    os.close(w)
    await asyncio.wait_for(pr.closed, 5)
    return [pr.data, pr.eof, pr.lost, tr.is_closing(), type(tr).__name__.endswith("ReadPipeTransport")]

async def write_pipe():
    loop = asyncio.get_running_loop()
    r, w = os.pipe()
    pipe = os.fdopen(w, "wb", 0)
    tr, pr = await loop.connect_write_pipe(Collect, pipe)
    big = b"z" * 200000          # more than a pipe holds: buffered, written as it drains
    tr.write(b"start:")
    tr.write(big)
    buffered = tr.get_write_buffer_size() > 0
    got = b""
    os.set_blocking(r, False)
    while len(got) < 6 + len(big):
        try:
            chunk = os.read(r, 65536)
        except BlockingIOError:
            await asyncio.sleep(0.005)
            continue
        if not chunk:
            break
        got = got + chunk
    tr.close()
    await asyncio.wait_for(pr.closed, 5)
    os.close(r)
    return [len(got), got[:6], buffered, tr.can_write_eof(), pr.lost]

async def write_pipe_peer_closed():
    loop = asyncio.get_running_loop()
    r, w = os.pipe()
    tr, pr = await loop.connect_write_pipe(Collect, os.fdopen(w, "wb", 0))
    os.close(r)                  # the reader goes: the transport sees it
    await asyncio.wait_for(pr.closed, 5)
    return [pr.lost, tr.is_closing()]

if POSIX:
    check("connect_read_pipe: data, eof, connection_lost", asyncio.run(read_pipe()), [b"hello pipe", True, None, True, True])
    check("connect_write_pipe: buffered writes drained to the reader", asyncio.run(write_pipe()),
          [200006, b"start:", True, True, None])
    check("connect_write_pipe: the reader closing ends the transport", asyncio.run(write_pipe_peer_closed()), [None, True])

# ── async generator hooks ─────────────────────────────────────────────────
def hooks_api():
    seen = []
    old = sys.get_asyncgen_hooks()
    def fi(ag):
        seen.append(("first", type(ag).__name__))
    def fn(ag):
        seen.append("final")
    sys.set_asyncgen_hooks(firstiter=fi, finalizer=fn)
    h = sys.get_asyncgen_hooks()
    try:
        sys.set_asyncgen_hooks(firstiter=5)
        bad = "accepted"
    except TypeError as e:
        bad = str(e)
    async def agen():
        yield 1
        yield 2
    g = agen()
    created = list(seen)
    v = None
    try:
        g.__anext__().send(None)
    except StopIteration as e:
        v = e.value
    after = list(seen)
    sys.set_asyncgen_hooks(*old)
    restored = sys.get_asyncgen_hooks() == old
    return [h.firstiter is fi, h.finalizer is fn, type(h).__name__, bad, created, v, after, restored]

check("sys.set_asyncgen_hooks / get_asyncgen_hooks, firstiter on the first step", hooks_api(),
      [True, True, "asyncgen_hooks", "callable firstiter expected, got int", [], 1, [("first", "async_generator")], True])

def finalizer_test():
    seen = []
    old = sys.get_asyncgen_hooks()
    sys.set_asyncgen_hooks(firstiter=None, finalizer=lambda ag: seen.append(ag.__name__))
    async def agen2():
        yield 1
        yield 2
    g = agen2()
    try:
        g.__anext__().send(None)
    except StopIteration:
        pass
    del g
    import gc
    gc.collect()
    async def agen3():
        yield 1
    g3 = agen3()
    try:
        g3.__anext__().send(None)
    except StopIteration:
        pass
    try:
        g3.__anext__().send(None)
    except StopAsyncIteration:
        pass
    del g3
    gc.collect()
    sys.set_asyncgen_hooks(*old)
    return seen

check("the finalizer: an unfinished generator collected (a finished one is not)", finalizer_test(), ["agen2"])

async def shutdown_test():
    closed = []
    async def gen():
        try:
            yield 1
            yield 2
        finally:
            closed.append("finally")
    g = gen()
    v = await g.__anext__()
    loop = asyncio.get_running_loop()
    n = len(loop._asyncgens)
    await loop.shutdown_asyncgens()
    return [v, n, closed, len(loop._asyncgens)]

check("loop.shutdown_asyncgens closes the started generators", asyncio.run(shutdown_test()), [1, 1, ["finally"], 0])

abandoned = []
async def main_abandon():
    async def gen():
        try:
            yield 1
            yield 2
        finally:
            abandoned.append("closed")
    g = gen()
    await g.__anext__()
    return "done"

check("asyncio.run closes a generator the program abandoned", [asyncio.run(main_abandon()), abandoned], ["done", ["closed"]])

async def async_for_hook():
    async def gen():
        yield 1
        yield 2
    out = []
    loop = asyncio.get_running_loop()
    g = gen()
    async for x in g:
        out.append(x)
        out.append(g in loop._asyncgens)
    return out

check("async for: the generator joins the loop's set", asyncio.run(async_for_hook()), [1, True, 2, True])

# ── the gc module ─────────────────────────────────────────────────────────
import gc
def gc_api():
    seen = []
    cb = lambda phase, info: seen.append((phase, sorted(info.keys())))
    gc.callbacks.append(cb)
    was = gc.isenabled()
    gc.disable()
    off = gc.isenabled()
    gc.enable()
    class Node:
        pass
    a = Node()
    b = Node()
    a.other = b
    b.other = a
    del a, b
    n = gc.collect()
    gc.callbacks.remove(cb)
    try:
        gc.collect(3)
        bad = "accepted"
    except ValueError as e:
        bad = str(e)
    old = gc.get_threshold()
    gc.set_threshold(1234)
    t = gc.get_threshold()[0]
    gc.set_threshold(*old)
    return [was, off, n >= 2, [x[0] for x in seen], seen[0][1], bad, t, gc.get_threshold() == old,
            len(gc.get_stats()), sorted(gc.get_stats()[2].keys()), len(gc.get_count()),
            gc.is_tracked(5), gc.is_tracked("s"), gc.is_tracked([]), gc.is_tracked(Node()), gc.garbage]

check("gc: enable/disable, collect with callbacks, thresholds, stats", gc_api(),
      [True, False, True, ["start", "stop"], ["collected", "generation", "uncollectable"], "invalid generation", 1234, True,
       3, ["collected", "collections", "uncollectable"], 3, False, False, True, True, []])

# ── exceptions nobody retrieved ───────────────────────────────────────────
async def unretrieved():
    loop = asyncio.get_running_loop()
    seen = []
    loop.set_exception_handler(lambda lp, ctx: seen.append((ctx["message"], type(ctx.get("exception")).__name__)))
    async def boom():
        raise ValueError("lost")
    t = asyncio.create_task(boom())
    await asyncio.sleep(0.01)
    del t
    gc.collect()
    await asyncio.sleep(0)
    t2 = asyncio.create_task(boom())          # awaited: not reported
    try:
        await t2
    except ValueError:
        pass
    del t2
    t3 = asyncio.create_task(boom())          # exception() asked: not reported
    await asyncio.sleep(0.01)
    t3.exception()
    del t3
    t4 = asyncio.create_task(asyncio.sleep(5))   # cancelled: not reported
    await asyncio.sleep(0)
    t4.cancel()
    await asyncio.sleep(0.01)
    del t4
    t5 = asyncio.create_task(boom())          # gathered: not reported
    await asyncio.gather(t5, return_exceptions=True)
    del t5
    f = loop.create_future()                  # a Future: reported too
    f.set_exception(KeyError("k"))
    del f
    gc.collect()
    await asyncio.sleep(0)
    loop.set_exception_handler(None)
    return seen

check("exceptions nobody retrieved are reported when their task/future goes", asyncio.run(unretrieved()),
      [("Task exception was never retrieved", "ValueError"), ("Future exception was never retrieved", "KeyError")])

# ── native objects under asyncio's primitives are freed (Nython-only) ─────
if sys.implementation.name == "nython":
    def freed(h):
        try:
            semaphore_value(h)
            return False
        except ValueError:
            return True
    lk = asyncio.Lock()
    h_lock = lk._sem
    sem = asyncio.Semaphore(3)
    h_sem = sem._sem
    alive_before = [freed(h_lock), freed(h_sem)]
    del lk, sem
    gc.collect()
    q = asyncio.Queue()
    hq = q._q
    ev = asyncio.Event()
    hev = ev._id
    del q, ev
    gc.collect()
    def gone_q(h):
        try:
            queue_size(h)
            return False
        except ValueError:
            return True
    def gone_ev(h):
        try:
            event_is_set(h)
            return False
        except ValueError:
            return True
    check("asyncio Lock/Semaphore/Queue/Event free their native objects", [alive_before, freed(h_lock), freed(h_sem), gone_q(hq), gone_ev(hev)],
          [[False, False], True, True, True, True])

# ── os.sendfile ───────────────────────────────────────────────────────────
if hasattr(os, "sendfile") and POSIX:
    a, b = socket.socketpair()
    fd = os.open(fpath, os.O_RDONLY)
    n = os.sendfile(a.fileno(), fd, 10, 20)
    got = b.recv(100)
    os.close(fd)
    a.close()
    b.close()
    check("os.sendfile(out, in, offset, count)", [n, got], [20, payload[10:30]])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT106 PASSED ===")
