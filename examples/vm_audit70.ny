# vm_audit70.ny - the network stack and the library around it, both engines
# (round 77).
#
#   http        http.client (keep-alive, chunked, 100-continue, HEAD, 204,
#               reuse of a connection), http.server (BaseHTTPRequestHandler,
#               SimpleHTTPRequestHandler: files, folders, 304, no escape from
#               the root), https both ways with a certificate made here
#   urllib      urlopen: redirects (and loops), HTTPError, POST, basic auth,
#               cookies (http.cookiejar), an HTTP proxy, data: and file: URLs,
#               urlretrieve
#   websocket   RFC 6455: echo, binary, fragments, 70 KB frames, ping/pong,
#               the closing handshake and its codes, protocol errors closing
#               with 1002/1007/1009, subprotocols, process_request, wss,
#               keepalive dropping a silent peer
#   libraries   network.ny (HttpClient, RestClient, SSE EventSource,
#               WebSocket, signed webhooks), webserver.ny (routes with
#               params, middleware that stops the chain, sessions, signed
#               tokens, static files, templates, WsServer), sockets.ny
#               (TcpServer, PacketSocket, SocketSelector, TcpProxy, pools),
#               clientserver.ny (JSON-RPC 2.0, pub/sub with MQTT wildcards,
#               chat, file transfer, phi-accrual heartbeats, smooth weighted
#               round-robin), the native http_get/http_post/http_request
#   runtime     math (Python's, both engines), hashlib, int(bytes, base),
#               exception args are tuples, Exception.__init__ through a
#               class, type(x).__name__/__module__ of a module class, binary
#               files, string_format, a function held in an attribute is not
#               bound, isinstance(json map, "map")
#
# TLS checks need the openssl command (to make a throwaway CA); without it
# they are skipped and counted.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit70.ny
#     ./build/nython-cli --vm examples/vm_audit70.ny
import "lib/network.ny"
import "lib/webserver.ny"
import "lib/sockets.ny"
import "lib/clientserver.ny"
import http.client
import http.server
import http.cookiejar
import urllib.request
import urllib.error
import urllib.parse
import sys
import websocket
import hashlib
import math
import ssl

var pass_n = 0
var fail_n = 0
var skipped = 0

def check(name, got, want):
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

def wait_until(pred, seconds=5):
    var deadline = monotonic() + seconds
    while not pred() and monotonic() < deadline:
        sleep(0.01)
    return pred()

var TMP = os_path_join(os_gettempdir(), "ny_audit70_" + str(os_getpid()))
os_makedirs(os_path_join(TMP, "www/sub"), true)
write_file(os_path_join(TMP, "www/a.txt"), "hi there\n")
write_file(os_path_join(TMP, "www/sub/index.html"), "<p>idx</p>")

# ── a throwaway CA and a certificate for localhost ─────────────────────────
var TLS = none
def make_certs():
    var d = os_path_join(TMP, "tls")
    os_makedirs(d, true)
    var ext = os_path_join(d, "ext.cnf")
    write_file(ext, "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
    var steps = [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", d + "/ca.key", "-out", d + "/ca.pem", "-days", "2", "-subj", "/CN=audit70 CA"],
        ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", d + "/server.key", "-out", d + "/server.csr", "-subj", "/CN=localhost"],
        ["openssl", "x509", "-req", "-in", d + "/server.csr", "-CA", d + "/ca.pem", "-CAkey", d + "/ca.key", "-CAcreateserial", "-out", d + "/server.pem", "-days", "2", "-extfile", ext]]
    for s in steps:
        try:
            var r = os_run(s, timeout=60)
            if r["code"] != 0:
                return none
        except Exception:
            return none
    return d
if _tls_available():
    TLS = make_certs()

def server_ctx():
    var c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.load_cert_chain(TLS + "/server.pem", TLS + "/server.key")
    return c

def client_ctx():
    return ssl.create_default_context(cafile=TLS + "/ca.pem")

# ── http.server + http.client ──────────────────────────────────────────────
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, format, *args):
        pass
    def reply(self, code, body, headers=none):
        if isinstance(body, "str"):
            body = body.encode()
        self.send_response(code)
        if headers != none:
            for k in headers:
                self.send_header(k, headers[k])
        if code != 204:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and code != 204:
            self.wfile.write(body)
    def do_HEAD(self):
        self.do_GET()
    def do_GET(self):
        var p = self.path
        if p == "/chunked":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"4\r\nWiki\r\n5;x=1\r\npedia\r\n0\r\n\r\n")
        elif p == "/r1":
            self.reply(302, "", {"Location": "/r2"})
        elif p == "/r2":
            self.reply(301, "", {"Location": "/final?x=1"})
        elif p == "/loop":
            self.reply(302, "", {"Location": "/loop"})
        elif p == "/missing":
            self.reply(404, "nope", {"X-Why": "gone"})
        elif p == "/empty":
            self.reply(204, "")
        elif p == "/auth":
            if self.headers.get("Authorization") == "Basic " + base64_encode("bob:pw"):
                self.reply(200, "welcome")
            else:
                self.reply(401, "who?", {"WWW-Authenticate": "Basic realm=\"zone\""})
        elif p == "/setc":
            self.send_response(200)
            self.send_header("Set-Cookie", "a=1; Path=/")
            self.send_header("Set-Cookie", "b=2; Path=/sub")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif p.startswith("/sub") or p == "/getc":
            self.reply(200, "cookie=" + str(self.headers.get("Cookie")))
        elif p.startswith("http://"):
            self.reply(200, "proxied " + p)
        elif p == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.close_connection = true
            self.wfile.write(b": c\n\nretry: 50\nid: 1\ndata: first\n\nevent: tick\ndata: a\ndata: b\nid: 2\n\n")
        else:
            self.reply(200, "path=" + p + " ua=" + self.headers.get("User-Agent", ""), {"Cache-Control": "max-age=60"})
    def do_POST(self):
        var n = int(self.headers.get("Content-Length", "0"))
        var d = self.rfile.read(n)
        if self.path == "/pr":
            self.reply(303, "", {"Location": "/final?post"})
            return
        self.reply(201, self.headers.get("Content-Type", "") + "|" + d.decode())

def start_http(handler, ctx=none):
    var srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    if ctx != none:
        srv.socket = ctx.wrap_socket(srv.socket, server_side=true)
    var t = threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.05})
    t.start()
    return [srv, t]

def stop_http(st):
    st[0].shutdown()
    st[0].server_close()
    st[1].join()

def test_http_client():
    var st = start_http(H)
    var port = st[0].server_address[1]
    var c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request("GET", "/x?y=1", headers={"User-Agent": "t"})
    var r = c.getresponse()
    check("status/reason", [r.status, r.reason, r.version], [200, "OK", 11])
    check("body", r.read(), b"path=/x?y=1 ua=t")
    var s1 = c.sock
    c.request("GET", "/chunked")
    r = c.getresponse()
    check("chunked", [r.chunked, r.read()], [true, b"Wikipedia"])
    check("keep-alive reuses the socket", c.sock is s1, true)
    c.request("POST", "/p", body=b"zz", headers={"Expect": "100-continue", "Content-Type": "x/y"})
    r = c.getresponse()
    check("100-continue", [r.status, r.read()], [201, b"x/y|zz"])
    c.request("HEAD", "/x")
    r = c.getresponse()
    check("HEAD", [r.status, r.read()], [200, b""])
    c.request("GET", "/empty")
    r = c.getresponse()
    check("204", [r.status, r.read()], [204, b""])
    c.request("DELETE", "/x")
    r = c.getresponse()
    check("501", [r.status, r.getheader("Content-Type")], [501, "text/html;charset=utf-8"])
    r.read()
    c.close()
    var c2 = http.client.HTTPConnection("[::1]:8080")
    check("IPv6 host:port", [c2.host, c2.port], ["::1", 8080])
    try:
        http.client.HTTPConnection("h:x")
        check("bad port raises", false, true)
    except http.client.InvalidURL:
        check("bad port raises", true, true)
    stop_http(st)

class Static(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass
    def __init__(self, *a):
        http.server.SimpleHTTPRequestHandler.__init__(self, *a, directory=os_path_join(TMP, "www"))

def test_static():
    var st = start_http(Static)
    var port = st[0].server_address[1]
    var out = []
    for path in ["/a.txt", "/sub", "/sub/", "/../../etc/passwd", "/nope"]:
        var c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        c.request("GET", path)
        var r = c.getresponse()
        var b = r.read()
        out.append([r.status, r.getheader("Location"), b if r.status == 200 else len(b) > 0])
        c.close()
    check("static files", out, [[200, none, b"hi there\n"], [301, "/sub/", false], [200, none, b"<p>idx</p>"], [404, none, true], [404, none, true]])
    var c3 = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c3.request("GET", "/a.txt", headers={"If-Modified-Since": http.server.formatdate(time() + 100)})
    var r3 = c3.getresponse()
    check("304", [r3.status, r3.read()], [304, b""])
    c3.close()
    stop_http(st)

def test_urllib():
    var st = start_http(H)
    var base = "http://127.0.0.1:" + str(st[0].server_address[1])
    urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
    var r = urllib.request.urlopen(base + "/r1", timeout=5)
    check("redirects", [r.status, r.geturl().endswith("/final?x=1"), r.read()], [200, true, b"path=/final?x=1 ua=Nython-urllib/0.2"])
    try:
        urllib.request.urlopen(base + "/missing")
        check("HTTPError", "none", "raised")
    except urllib.error.HTTPError as e:
        check("HTTPError", [e.code, e.reason, e.headers["X-Why"], e.read(), isinstance(e, OSError)], [404, "Not Found", "gone", b"nope", true])
    try:
        urllib.request.urlopen(base + "/loop")
    except urllib.error.HTTPError as e:
        check("redirect loop", [e.code, "infinite loop" in e.reason], [302, true])
    check("POST", urllib.request.urlopen(base + "/p", urllib.parse.urlencode({"a": "1 2"}).encode()).read(), b"application/x-www-form-urlencoded|a=1+2")
    check("303 after POST", urllib.request.urlopen(urllib.request.Request(base + "/pr", data=b"q")).read(), b"path=/final?post ua=Nython-urllib/0.2")
    var mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    mgr.add_password(none, base + "/", "bob", "pw")
    check("basic auth", urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPBasicAuthHandler(mgr)).open(base + "/auth").read(), b"welcome")
    var jar = http.cookiejar.CookieJar()
    var cop = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar))
    cop.open(base + "/setc").read()
    check("cookies stored", sorted([c.name for c in jar]), ["a", "b"])
    check("cookie paths", [cop.open(base + "/getc").read(), cop.open(base + "/sub/x").read()], [b"cookie=a=1", b"cookie=b=2; a=1"])
    var pop = urllib.request.build_opener(urllib.request.ProxyHandler({"http": base}))
    check("http proxy", pop.open("http://example.invalid/thing").read(), b"proxied http://example.invalid/thing")
    check("proxy_bypass", [urllib.request.proxy_bypass("x.invalid:80", {"no": "localhost,.invalid"}), urllib.request.proxy_bypass("y.com", {"no": ".invalid"})], [true, false])
    check("data: URL", [urllib.request.urlopen("data:,Hello%2C%20World!").read(), urllib.request.urlopen("data:text/plain;base64,SGk=").read()], [b"Hello, World!", b"Hi"])
    # "file:" + pathname2url(path): "file://" + path is not a URL on Windows
    # (C: would be its host)
    var furl = "file:" + urllib.request.pathname2url(os_path_abspath(os_path_join(TMP, "www/a.txt")))
    check("file: URL", urllib.request.urlopen(furl).read(), b"hi there\n")
    var p0 = "C:\\a b\\c%d" if sys.platform.startswith("win") else "/a b/c%d"
    check("pathname2url round trip", urllib.request.url2pathname(urllib.request.pathname2url(p0)), p0)
    var dl = os_path_join(TMP, "dl.txt")
    urllib.request.urlretrieve(base + "/final?dl", dl)
    check("urlretrieve", read_file(dl), "path=/final?dl ua=Nython-urllib/0.2")
    stop_http(st)

def test_https():
    if TLS == none:
        skipped = skipped + 1
        return
    var st = start_http(H, server_ctx())
    var port = st[0].server_address[1]
    var c = http.client.HTTPSConnection("localhost", port, context=client_ctx(), timeout=5)
    c.request("GET", "/one")
    var r = c.getresponse()
    check("https", [r.status, r.read()], [200, b"path=/one ua="])
    c.close()
    var c2 = http.client.HTTPSConnection("localhost", port, context=ssl.create_default_context(), timeout=5)
    try:
        c2.request("GET", "/")
        check("untrusted certificate", "accepted", "refused")
    except ssl.SSLCertVerificationError:
        check("untrusted certificate", "refused", "refused")
    c2.close()
    check("urlopen https", urllib.request.urlopen("https://localhost:" + str(port) + "/u", context=client_ctx()).read(), b"path=/u ua=Nython-urllib/0.2")
    stop_http(st)

# ── websocket ──────────────────────────────────────────────────────────────
def ws_echo(ws):
    for m in ws:
        if m == "close-me":
            ws.close(4000, "bye")
            return
        ws.send(m)

def test_websocket():
    var srv = websocket.serve(ws_echo, "127.0.0.1", 0, subprotocols=["chat"], max_size=100000,
                              process_request=lambda conn, req: conn.respond(200, "OK\n") if req.path == "/health" else none)
    var t = threading.Thread(target=srv.serve_forever)
    t.start()
    var url = "ws://127.0.0.1:" + str(srv.port) + "/r"
    var ws = websocket.connect(url, subprotocols=["x", "chat"])
    check("subprotocol", ws.subprotocol, "chat")
    ws.send("héllo")
    ws.send(b"\x00\x01")
    ws.send(["frag", "ments"])
    ws.send("y" * 70000)
    check("messages", [ws.recv(timeout=5), ws.recv(timeout=5), ws.recv(timeout=5), len(ws.recv(timeout=5))], ["héllo", b"\x00\x01", "fragments", 70000])
    var w = ws.ping(b"p")
    check("ping/pong", [w.wait(5), ws.srtt != none], [true, true])
    try:
        ws.recv(timeout=0.1)
        check("recv timeout", "message", "TimeoutError")
    except TimeoutError:
        check("recv timeout", "TimeoutError", "TimeoutError")
    ws.close()
    check("closed", [ws.state, ws.close_code], [websocket.CLOSED, 1000])
    try:
        ws.send("late")
    except websocket.ConnectionClosedOK as e:
        check("send after close", e.code, 1000)
    var ws2 = websocket.connect(url)
    ws2.send("close-me")
    try:
        ws2.recv(timeout=5)
    except websocket.ConnectionClosedError as e:
        check("server close code", [e.code, e.reason], [4000, "bye"])
    var c = http.client.HTTPConnection("127.0.0.1", srv.port, timeout=5)
    c.request("GET", "/health")
    var r = c.getresponse()
    check("process_request", [r.status, r.read()], [200, b"OK\n"])
    c.close()
    try:
        websocket.connect("http://x/")
    except websocket.InvalidURI:
        check("InvalidURI", true, true)
    # protocol errors from a raw client
    def raw(path):
        var s = socket.create_connection(("127.0.0.1", srv.port), 5)
        s.sendall(("GET " + path + " HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + websocket.generate_key() + "\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        var f = s.makefile("rb")
        while f.readline() != b"\r\n":
            pass
        return [s, f]
    def close_code(pair, frame):
        pair[0].sendall(frame)
        var h = pair[1].read(2)
        var p = pair[1].read(h[1] & 0x7F)
        pair[0].close()
        return [h[0] & 0x0F, int.from_bytes(p[0:2], "big")]
    check("unmasked frame", close_code(raw("/a"), websocket.encode_frame(true, 1, b"hi", false)), [8, 1002])
    check("invalid UTF-8", close_code(raw("/b"), websocket.encode_frame(true, 1, b"\xff\xfe", true)), [8, 1007])
    check("too big", close_code(raw("/c"), websocket.encode_frame(true, 2, bytes(200000), true)), [8, 1009])
    check("reserved bits", close_code(raw("/d"), bytes([0xC1, 0x80]) + b"abcd"), [8, 1002])
    check("RFC 6455 accept key", websocket.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    srv.shutdown()
    t.join()
    # keepalive: a peer that never answers pings is dropped
    var srv2 = websocket.serve(ws_echo, "127.0.0.1", 0, ping_interval=0.05, ping_timeout=0.4)
    var t2 = threading.Thread(target=srv2.serve_forever)
    t2.start()
    var s = socket.create_connection(("127.0.0.1", srv2.port), 5)
    s.sendall(("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + websocket.generate_key() + "\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    var f = s.makefile("rb")
    while f.readline() != b"\r\n":
        pass
    var got = none
    var start = monotonic()
    while monotonic() - start < 5:
        var hh = f.read(2)
        if len(hh) < 2:
            break
        var pl = f.read(hh[1] & 0x7F)
        if (hh[0] & 0x0F) == 8:
            got = int.from_bytes(pl[0:2], "big")
            break
    check("silent peer dropped", got, 1011)
    s.close()
    srv2.shutdown()
    t2.join()
    if TLS == none:
        skipped = skipped + 1
        return
    var srv3 = websocket.serve(ws_echo, "127.0.0.1", 0, ssl=server_ctx())
    var t3 = threading.Thread(target=srv3.serve_forever)
    t3.start()
    var sw = websocket.connect("wss://localhost:" + str(srv3.port) + "/", ssl=client_ctx())
    sw.send("over tls")
    check("wss", sw.recv(timeout=5), "over tls")
    sw.close()
    srv3.shutdown()
    t3.join()

# ── network.ny / webserver.ny / sockets.ny / clientserver.ny ───────────────
def test_libraries():
    var app = HttpServer("127.0.0.1", 0)
    var auth = AuthMiddleware("k3y", ["/login", "/public/*"])
    app.use(SessionMiddleware(app.sessions))
    app.static("/static", os_path_join(TMP, "www"))
    app.use(auth)
    app.get("/users/:id", lambda req, res: res.send_json({"id": req.params["id"], "q": req.query("x"), "user": req.user["name"]}))
    app.post("/login", lambda req, res: res.send_json({"token": auth.make_token({"name": req.json_body()["name"]})}))
    def count(req, res):
        var n = req.session.get("n", 0) + 1
        req.session.set("n", n)
        res.send_text(str(n))
    app.get("/public/count", count)
    app.get("/public/page", lambda req, res: res.send_html(Template("<b>{{t}}</b>{{#xs}}<i>{{.}}</i>{{/xs}}", true).render({"t": "<x>", "xs": [1, 2]})))
    app.start()
    var c = HttpClient("http://127.0.0.1:" + str(app.port), retries=0)
    check("401 without a token", c.get("/users/7").status, 401)
    var tok = c.post("/login", {"name": "ann"}).json()["token"]
    c.set_auth("Bearer " + tok)
    var r = c.get("/users/7?x=1%202")
    check("route params + token", [r.status, r.json()], [200, {"id": "7", "q": "1 2", "user": "ann"}])
    c.set_auth("Bearer " + tok + "x")
    check("tampered token", c.get("/users/7").status, 401)
    c.default_headers.delete("Authorization")
    var r1 = c.get("/public/count")
    var cookie = r1.headers.get("Set-Cookie").split(";")[0]
    check("session", [r1.body, c.get("/public/count", headers={"Cookie": cookie}).body], ["1", "2"])
    check("template escapes", c.get("/public/page").body, "<b>&lt;x&gt;</b><i>1</i><i>2</i>")
    check("static", [c.get("/static/a.txt").body, c.get("/static/../../etc/passwd").status], ["hi there\n", 401])
    app.stop()
    c.close()
    # network.ny against http.server
    var st = start_http(H)
    var base = "http://127.0.0.1:" + str(st[0].server_address[1])
    var hc = HttpClient(base, retries=0)
    var rr = hc.get("/r1")
    check("HttpClient redirect", [rr.status, rr.url.endswith("/final?x=1")], [200, true])
    check("HttpClient 404", [hc.get("/missing").status, hc.get("/missing").is_error()], [404, true])
    check("HttpClient refused", HttpClient("http://127.0.0.1:1", retries=0).get("/").status, 0)
    var es = EventSource(base + "/events", reconnect_delay=0.05)
    var seen = []
    es.on("message", lambda d: seen.append(d))
    es.on("tick", lambda d: seen.append("tick:" + d))
    es.connect()
    wait_until(lambda: len(seen) >= 2)
    es.disconnect()
    check("server-sent events", [seen[0:2], es.last_event_id, es.reconnect_delay], [["first", "tick:a\nb"], "2", 0.05])
    var p = WebhookPayload("e", {"k": 1}, "s")
    check("webhook signature", [verify_webhook("s", p.to_json(), p.signature()), verify_webhook("x", p.to_json(), p.signature()), verify_webhook("s", p.to_json(), p.signature(), 300, time_now() + 1000)], [true, false, false])
    check("native http_get", http_get(base + "/chunked"), "Wikipedia")
    var nr = http_request("GET", base + "/r1")
    check("native http_request", [nr["status"], nr["url"].endswith("/final?x=1")], [200, true])
    check("native refused", http_request("GET", "http://127.0.0.1:1/"), none)
    stop_http(st)
    # sockets.ny
    var srv = TcpServer("127.0.0.1", 0)
    def echo(cl):
        while true:
            var line = cl.recv_line()
            if line == "":
                return
            cl.send_line("echo:" + line)
    srv.start_background(echo)
    var a = TcpSocket()
    var b = TcpSocket()
    a.connect("127.0.0.1", srv.port)
    b.connect("127.0.0.1", srv.port)
    a.send_line("one")
    b.send_line("two")
    check("TcpServer concurrent clients", [a.recv_line(), b.recv_line()], ["echo:one", "echo:two"])
    a.close()
    b.close()
    var px = TcpProxy(0, "127.0.0.1", srv.port, "127.0.0.1")
    px.start(true)
    var conn = Connection("127.0.0.1", px.listen_port, 5)
    conn.open()
    check("TcpProxy", conn.request("via\n"), "echo:via")
    conn.close()
    px.stop()
    var sp = SocketPair()
    sp.create()
    var t1 = TcpSocket()
    t1.fd = sp.fd_a
    t1.connected = true
    var t2 = TcpSocket()
    t2.fd = sp.fd_b
    t2.connected = true
    PacketSocket(t1).send_packet("héllo")
    PacketSocket(t1).send_packet("")
    check("PacketSocket", [PacketSocket(t2).recv_packet(), PacketSocket(t2).recv_packet()], ["héllo", ""])
    sp.close()
    var u1 = UdpSocket()
    u1.bind("127.0.0.1", 0)
    var sel = SocketSelector()
    sel.add(u1)
    check("selector timeout", len(sel.wait(30)), 0)
    UdpSocket().send_to("127.0.0.1", u1.local_address()[1], "dgram")
    var ready = sel.wait(2000)
    check("selector ready", [len(ready), u1.recv_from(1)[0]], [1, "dgram"])
    srv.stop()
    # clientserver.ny
    var rpc = RpcServer("127.0.0.1", 0)
    rpc.register("add", lambda q: q[0] + q[1])
    rpc.register("mul", lambda x, y: x * y, true)
    rpc.start()
    var rc = RpcClient("127.0.0.1", rpc.port)
    check("JSON-RPC", [rc.call("add", [2, 3]), rc.call("mul", {"x": 2, "y": 7}), rc.call("nope"), rc.last_error.code], [5, 14, none, -32601])
    check("JSON-RPC batch", rc.batch([["add", [1, 1]], ["nope", none]]), [2, none])
    rc.close()
    rpc.stop()
    var broker = PubSubBroker("127.0.0.1", 0)
    broker.start()
    var got = []
    var sub = PubSubClient("127.0.0.1", broker.port)
    sub.connect()
    sub.subscribe("sensors/+/temp", lambda m: got.append(m))
    sub.start()
    sleep(0.1)
    var pub = PubSubClient("127.0.0.1", broker.port)
    pub.connect()
    pub.publish("sensors/k/humidity", "40")
    pub.publish("sensors/k/temp", "21")
    wait_until(lambda: len(got) >= 1)
    check("pub/sub wildcards", got, ["21"])
    check("topic_matches", [topic_matches("a/#", "a"), topic_matches("a/+", "a/b/c")], [true, false])
    sub.close()
    pub.close()
    broker.stop()
    var d = PhiAccrualDetector()
    var tt = 0.0
    for i in range(20):
        d.beat(tt)
        tt = tt + 1.0
    check("phi accrual", [d.phi(tt) < 1, d.phi(tt + 3) > 8], [true, true])
    var lb = LoadBalancer("weighted")
    lb.add_backend("a", 1, 5).add_backend("b", 1, 1).add_backend("c", 1, 1)
    check("smooth weighted round-robin", "".join([lb.next().host for i in range(7)]), "aabacaa")

# ── runtime fixes ───────────────────────────────────────────────────────────
class E3(ConnectionResetError):
    def __init__(self, m):
        ConnectionResetError.__init__(self, m + "!")

class Holder:
    def __init__(self, f):
        self.f = f
        self.v = 2

class Maker:
    def __init__(self):
        self.v = 1
    def mk(self):
        def h(x):
            return [self.v, x]
        return h

def test_runtime():
    check("math", [math.log10(1000), math.log2(8), math.log(8, 2), math.floor(-2.5), math.isqrt(10**20), math.comb(10, 3), math.gcd(12, 18), math.fsum([0.1] * 10)], [3.0, 3.0, 3.0, -3, 10000000000, 120, 6, 1.0])
    var errs = []
    for f in [lambda: math.sqrt(-1), lambda: math.exp(1000), lambda: math.factorial(-1)]:
        try:
            f()
            errs.append("none")
        except Exception as e:
            errs.append(type(e).__name__)
    check("math errors", errs, ["ValueError", "OverflowError", "ValueError"])
    check("hashlib", [hashlib.sha256(b"abc").hexdigest()[0:16], hashlib.md5(b"").hexdigest()], ["ba7816bf8f01cfea", "d41d8cd98f00b204e9800998ecf8427e"])
    check("int(bytes, base)", [int(b"ff", 16), int(bytearray(b"10"), 2)], [255, 2])
    check("exception args", [ValueError("a", 1).args, E3("c").args, str(E3("c"))], [("a", 1), ("c!",), "c!"])
    check("module class names", [type(websocket.Close(1000)).__name__, websocket.Close.__module__], ["Close", "websocket"])
    var fp = os_path_join(TMP, "bin.dat")
    var f = open(fp, "wb")
    f.write(b"\x00\x01line\n\xff")
    f.close()
    f = open(fp, "rb")
    check("binary files", [f.readline(), f.read()], [b"\x00\x01line\n", b"\xff"])
    f.close()
    check("string_format", [string_format("{:03d}|{}", 7, "x"), string_format("{} {}", ["a", "b"])], ["007|x", "a b"])
    check("attribute function not bound", Holder(Maker().mk()).f(5), [1, 5])
    check("isinstance json map", isinstance(json_decode("{\"a\": 1}"), "map"), true)

test_http_client()
test_static()
test_urllib()
test_https()
test_websocket()
test_libraries()
test_runtime()
os_rmtree(TMP)
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed (" + str(skipped) + " TLS sections skipped)")
if fail_n == 0:
    print("=== VM_AUDIT70 PASSED ===")
