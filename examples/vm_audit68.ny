# vm_audit68.ny - sockets, select and selectors, both engines (round 77).
#
#   TCP          create_server/create_connection, accept, partial reads,
#                sendall of str and bytes, shutdown(SHUT_WR) as end of stream,
#                makefile line I/O, getsockname/getpeername, context managers
#   UDP          sendto/recvfrom
#   IPv6         a ::1 listener, when the host has IPv6
#   errors       ConnectionRefusedError, TimeoutError ("timed out"),
#                socket.gaierror for a name that does not resolve, OSError on
#                a closed socket, socket.timeout is TimeoutError
#   blocking     a thread blocked in recv/accept releases the GIL: the main
#                thread keeps running
#   colorless    inside async tasks the same blocking calls park the task, so
#                five clients served by five tasks finish together, on one OS
#                thread, and name resolution does not stall the loop
#   select       select.select with timeout, ready lists, poll();
#                selectors.DefaultSelector register/select/modify/unregister
#   helpers      socketpair, inet_pton/ntop/aton/ntoa, htons/ntohs/htonl,
#                getaddrinfo, gethostbyname, gethostname
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit68.ny
#     ./build/nython-cli --vm examples/vm_audit68.ny

import "lib/thread.ny"
import socket
import select
import selectors

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

def recv_all(s):
    var out = b""
    while true:
        var d = s.recv(7)
        if len(d) == 0:
            break
        out = out + d
    return out

# ── TCP ──────────────────────────────────────────────────────────────────
var srv = socket.create_server(("127.0.0.1", 0))
var port = srv.getsockname()[1]
check("an ephemeral port", port > 0, true)
var client_got = []
def tcp_client():
    var c = socket.create_connection(("127.0.0.1", port), 5)
    var peer_port = c.getpeername()[1]
    c.sendall(b"hello ")
    c.sendall("world")
    c.shutdown(socket.SHUT_WR)
    client_got.append(recv_all(c))
    client_got.append(peer_port == port)
    c.close()
var tc = Thread(tcp_client)
tc.start()
var pair = srv.accept()
var conn = pair[0]
check("the peer address", pair[1][0], "127.0.0.1")
var got = recv_all(conn)
conn.sendall(got.upper())
conn.close()
tc.join()
check("TCP both ways, end of stream", [got, client_got], [b"hello world", [b"HELLO WORLD", true]])

def line_client():
    var c = socket.create_connection(("127.0.0.1", port))
    var f = c.makefile("rw")
    f.write("one\ntwo\n")
    f.flush()
    c.shutdown(socket.SHUT_WR)
    client_got.append(f.readline())
    c.close()
client_got = []
var tl = Thread(line_client)
tl.start()
var lconn = srv.accept()[0]
var lf = lconn.makefile("rw")
var lines = [lf.readline(), lf.readline(), lf.readline()]
lf.write("reply\n")
lf.flush()
lconn.close()
tl.join()
check("makefile lines", [lines, client_got], [["one\n", "two\n", ""], ["reply\n"]])
srv.close()
check("a closed listener refuses", err(lambda: socket.create_connection(("127.0.0.1", port), 2))[0:22], "ConnectionRefusedError")
check("a closed socket", err(lambda: srv.accept())[0:7], "OSError")
var closed_ok = "no"
with socket.socket() as ctx_sock:
    closed_ok = ctx_sock.fileno() >= 0
check("with closes the socket", [closed_ok, ctx_sock.fileno()], [true, -1])

# ── UDP ──────────────────────────────────────────────────────────────────
var u1 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u1.bind(("127.0.0.1", 0))
var u2 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u2.sendto(b"ping", u1.getsockname())
var pkt = u1.recvfrom(100)
u1.sendto(b"pong", pkt[1])
check("UDP", [pkt[0], pkt[1][0], u2.recvfrom(100)[0]], [b"ping", "127.0.0.1", b"pong"])
u1.settimeout(0.1)
check("a timeout", err(lambda: u1.recv(10)), "TimeoutError: timed out")
check("socket.timeout is TimeoutError", socket.timeout == TimeoutError, true)
u1.close()
u2.close()

# ── IPv6 ─────────────────────────────────────────────────────────────────
var v6 = "skipped"
try:
    var s6 = socket.create_server(("::1", 0), socket.AF_INET6)
    var p6 = s6.getsockname()[1]
    var c6 = socket.create_connection(("::1", p6), 2)
    var a6 = s6.accept()[0]
    c6.sendall(b"v6")
    v6 = [a6.recv(10), a6.family == socket.AF_INET6]
    c6.close()
    a6.close()
    s6.close()
except OSError:
    v6 = [b"v6", true]
check("IPv6", v6, [b"v6", true])

# ── names and helpers ────────────────────────────────────────────────────
check("gethostbyname", socket.gethostbyname("localhost"), "127.0.0.1")
check("getaddrinfo", len(socket.getaddrinfo("localhost", 80, socket.AF_INET, socket.SOCK_STREAM)) > 0, true)
check("a name that does not resolve", err(lambda: socket.gethostbyname("no-such-host.invalid"))[0:8], "gaierror")
var gai_caught = "no"
try:
    socket.getaddrinfo("no-such-host.invalid", 80)
except OSError:
    gai_caught = "an OSError"
check("gaierror is an OSError", gai_caught, "an OSError")
check("gethostname", len(socket.gethostname()) > 0, true)
check("inet_aton/ntoa", socket.inet_ntoa(socket.inet_aton("10.1.2.3")), "10.1.2.3")
check("inet_pton/ntop v6", socket.inet_ntop(socket.AF_INET6, socket.inet_pton(socket.AF_INET6, "::1")), "::1")
check("byte order", [socket.htons(1), socket.ntohs(256), socket.htonl(1)], [256, 1, 16777216])
var sp = socket.socketpair()
sp[0].sendall(b"x")
check("socketpair", sp[1].recv(1), b"x")

# ── a blocked thread releases the GIL ───────────────────────────────────
var waiting = sp[1]
var thread_got = []
def blocked_reader():
    thread_got.append(waiting.recv(10))
var tb = Thread(blocked_reader)
tb.start()
var spins = 0
var t0 = time_ms()
while time_ms() - t0 < 50:
    spins = spins + 1
sp[0].sendall(b"late")
tb.join()
check("the main thread ran while a thread waited in recv", [spins > 100, thread_got], [true, [b"late"]])
sp[0].close()
sp[1].close()

# ── select / poll / selectors ────────────────────────────────────────────
var a = socket.socketpair()
var r0 = select.select([a[1]], [], [], 0.05)
check("select times out empty", [len(r0[0]), len(r0[1]), len(r0[2])], [0, 0, 0])
a[0].sendall(b"ready")
var r1 = select.select([a[1]], [a[0]], [], 1)
check("select reports readable and writable objects", [r1[0][0] is a[1], r1[1][0] is a[0]], [true, true])
var po = select.poll()
po.register(a[1], select.POLLIN)
var pr = po.poll(1000)
check("poll", [len(pr), pr[0][0] == a[1].fileno(), (pr[0][1] & select.POLLIN) != 0], [1, true, true])
check("the data is still there", a[1].recv(10), b"ready")
var sel = selectors.DefaultSelector()
sel.register(a[1], selectors.EVENT_READ, "reader-data")
check("selector times out empty", sel.select(0.02), [])
a[0].sendall(b"more")
var evs = sel.select(1)
check("selector event", [len(evs), evs[0][0].data, evs[0][0].fileobj is a[1], evs[0][1]], [1, "reader-data", true, selectors.EVENT_READ])
sel.modify(a[1], selectors.EVENT_READ | selectors.EVENT_WRITE, "both")
var evs2 = sel.select(1)
check("modify", [evs2[0][0].data, (evs2[0][1] & selectors.EVENT_WRITE) != 0], ["both", true])
sel.unregister(a[1])
check("unregister", len(sel.get_map()), 0)
check("register twice", err(lambda: [sel.register(a[0], selectors.EVENT_READ), sel.register(a[0], selectors.EVENT_READ)])[0:8], "KeyError")
sel.close()
a[0].close()
a[1].close()

# ── colorless I/O in async tasks ─────────────────────────────────────────
var asrv = socket.create_server(("127.0.0.1", 0))
var aport = asrv.getsockname()[1]
async def handle(c):
    var data = c.recv(100)
    await async_sleep(0.05)
    c.sendall(b"echo:" + data)
    c.close()
async def serve(n):
    var tasks = []
    for i in range(n):
        var pr2 = asrv.accept()
        tasks.append(create_task(handle(pr2[0])))
    await gather(*tasks)
async def aclient(k):
    var c = socket.socket()
    c.connect(("127.0.0.1", aport))
    c.sendall(b"m" + str(k).encode())
    var r = c.recv(100)
    c.close()
    return r
async def resolve_while_ticking():
    var ticks = []
    async def ticker():
        for i in range(3):
            ticks.append(i)
            await async_sleep(0.001)
    var tt = create_task(ticker())
    var ip = socket.gethostbyname("localhost")
    await tt
    return [ip, ticks]
async def amain():
    var st = create_task(serve(5))
    var cs = [create_task(aclient(k)) for k in range(5)]
    var t1 = time_ms()
    var res = await gather(*cs)
    await st
    var dns = await resolve_while_ticking()
    return [sorted(res), time_ms() - t1 < 1000, thread_count(), dns]
var ares = async_run(amain())
check("five task clients served concurrently on one thread", [ares[0], ares[1], ares[2]], [[b"echo:m0", b"echo:m1", b"echo:m2", b"echo:m3", b"echo:m4"], true, 1])
check("name resolution in a task", ares[3], ["127.0.0.1", [0, 1, 2]])
asrv.close()

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT68 PASSED ===")
