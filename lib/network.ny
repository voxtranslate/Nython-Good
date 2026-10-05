# ═══════════════════════════════════════════════════════════════════════════════
# network.ny — Nython Network Library
# HTTP client, REST client, WebSocket, Server-Sent Events, rate limiting,
# connection pool, retries, caching, OAuth2, GraphQL, signed webhooks.
# Usage: import "lib/network.ny"
#
# Round 77: every class talks to the network for real, over lib/http/client.ny,
# lib/websocket.ny and lib/socket.ny (it used to fake it: HttpClient answered
# "200 OK" for any reply and never sent its headers, EventSource and
# WebSocket only set flags, webhooks were not signed).
#
#   HttpClient     keep-alive connections per host, real status/reason/headers,
#                  redirects, query params, JSON bodies, timeouts, retries of
#                  idempotent requests with exponential backoff and
#                  Retry-After; a failed connection is Response(0, ...)
#   RestClient     JSON in, JSON out over HttpClient (none on failure;
#                  last_response keeps the details)
#   EventSource    the WHATWG Server-Sent Events client: event/data/id/retry
#                  fields, Last-Event-ID on reconnection, open/error events
#   WebSocket      RFC 6455 over lib/websocket.ny, with on_open/on_message/
#                  on_close/on_error callbacks
#   ConnectionPool reusable TCP connections, at most max_size open
#   HttpCache      TTL entries; honours Cache-Control max-age / no-store
#   WebhookSender  HMAC-SHA256 signed deliveries ("t=<unix>,v1=<hex>" over
#                  "<t>.<body>"); verify_webhook() checks one with a replay
#                  window
# ═══════════════════════════════════════════════════════════════════════════════
import nytorch
import net
import socket
import threading
import http.client
import urllib.parse
import websocket
import hmac
import hashlib

# ─── URL ─────────────────────────────────────────────────────────────────────

class URL:
    def __init__(self, raw):
        self.raw = raw
        self.scheme = "http"
        self.host = ""
        self.port = 80
        self.path = "/"
        self.query = ""
        self.fragment = ""
        self.username = none
        self.password = none
        self._parse(raw)

    def _parse(self, raw):
        var text = raw
        if not string_contains(text, "://"):
            text = "http://" + text
        var p = urllib.parse.urlsplit(text)
        self.scheme = p.scheme.lower()
        self.host = p.hostname or ""
        self.username = p.username
        self.password = p.password
        var port = p.port
        if port == none:
            port = 80
            if self.scheme == "https" or self.scheme == "wss":
                port = 443
        self.port = port
        self.path = p.path
        if self.path == "":
            self.path = "/"
        self.query = p.query
        self.fragment = p.fragment

    def target(self):
        # what a request line names: the path and the query
        if self.query != "":
            return self.path + "?" + self.query
        return self.path

    def to_str(self):
        var s = self.scheme + "://" + self.host
        if (self.scheme == "http" or self.scheme == "ws") and self.port != 80:
            s = s + ":" + str(self.port)
        elif (self.scheme == "https" or self.scheme == "wss") and self.port != 443:
            s = s + ":" + str(self.port)
        s = s + self.path
        if self.query != "":
            s = s + "?" + self.query
        if self.fragment != "":
            s = s + "#" + self.fragment
        return s

    def origin(self):
        return self.scheme + "://" + self.host

    def __str__(self):
        return self.to_str()

# ─── Headers ─────────────────────────────────────────────────────────────────

class Headers:
    # Case-insensitive; keeps the order and spelling names were first set in.
    def __init__(self):
        self.data = {}
        self._keys = []
        self._names = {}

    def set(self, name, value):
        var lower = string_lower(name)
        if not (lower in self.data):
            self._keys.append(lower)
            self._names[lower] = name
        self.data[lower] = value

    def get(self, name, default=""):
        var v = self.data.get(string_lower(name))
        if v == none:
            return default
        return v

    def has(self, name):
        return string_lower(name) in self.data

    def delete(self, name):
        var lower = string_lower(name)
        if lower in self.data:
            del self.data[lower]
            del self._names[lower]
            self._keys = [k for k in self._keys if k != lower]

    def count(self):
        return len(self._keys)

    def all(self):
        return self._keys

    def items(self):
        return [(self._names[k], str(self.data[k])) for k in self._keys]

    def to_dict(self):
        var d = {}
        for k in self._keys:
            d[self._names[k]] = str(self.data[k])
        return d

    def update(self, other):
        if other == none:
            return self
        if isinstance(other, Headers):
            for kv in other.items():
                self.set(kv[0], kv[1])
        else:
            for k in other:
                self.set(k, other[k])
        return self

    def copy(self):
        var h = Headers()
        h.update(self)
        return h

    def to_str(self):
        var result = ""
        for kv in self.items():
            result = result + kv[0] + ": " + kv[1] + "\r\n"
        return result

    def default_request(self):
        self.set("Content-Type", "application/json")
        self.set("Accept", "application/json")
        self.set("User-Agent", "Nython/0.2.1")

# ─── Response ────────────────────────────────────────────────────────────────

class Response:
    def __init__(self, status, reason, body, headers=none, content=none, url="", elapsed=0.0):
        self.status = status
        self.reason = reason
        self.body = body
        self.headers = headers
        if headers == none:
            self.headers = Headers()
        self.content = content
        if content == none:
            self.content = body.encode("utf-8") if isinstance(body, "str") else body
        self.url = url
        self.elapsed = elapsed
        self.error = none

    def is_ok(self):
        return self.status >= 200 and self.status < 300

    def is_success(self):
        return self.is_ok()

    def is_redirect(self):
        return self.status >= 300 and self.status < 400

    def is_client_error(self):
        return self.status >= 400 and self.status < 500

    def is_server_error(self):
        return self.status >= 500

    def is_error(self):
        return self.status >= 400 or self.status == 0

    def raise_for_status(self):
        if self.status == 0:
            raise ConnectionError(self.reason)
        if self.status >= 400:
            raise http.client.HTTPException(str(self.status) + " " + self.reason + " for " + self.url)
        return self

    def json(self):
        return json_decode(self.body)

    def text(self):
        return self.body

    def __repr__(self):
        return "<Response [" + str(self.status) + "]>"

def _charset(content_type):
    for part in content_type.split(";")[1:]:
        var kv = part.strip().split("=")
        if len(kv) == 2 and kv[0].strip().lower() == "charset":
            return kv[1].strip().strip("\"").lower()
    return "utf-8"

# ─── HttpClient ───────────────────────────────────────────────────────────────

_IDEMPOTENT = ["GET", "HEAD", "OPTIONS", "PUT", "DELETE", "TRACE"]

class HttpClient:
    def __init__(self, base_url="", timeout=30, retries=3, retry_delay=1.0, follow_redirects=true, max_redirects=10, context=none):
        self.base_url = base_url
        self.timeout = timeout
        self.retries = retries
        self.retry_delay = retry_delay
        self.follow_redirects = follow_redirects
        self.max_redirects = max_redirects
        self.auth_token = ""
        self.context = context
        self.default_headers = Headers()
        self.default_headers.default_request()
        self._conns = {}
        self._lock = threading.Lock()
        self.requests_sent = 0

    def set_base_url(self, url):
        self.base_url = url

    def set_timeout(self, secs):
        self.timeout = secs

    def set_auth(self, token):
        self.auth_token = token
        self.default_headers.set("Authorization", token)

    def set_header(self, name, value):
        self.default_headers.set(name, value)

    def _make_url(self, path):
        if string_startswith(path, "http://") or string_startswith(path, "https://"):
            return path
        return self.base_url + path

    def _connection(self, u):
        var key = u.scheme + "://" + u.host + ":" + str(u.port)
        with self._lock:
            var c = self._conns.get(key)
            if c != none:
                del self._conns[key]       # in use: one request at a time each
                return [key, c]
        if u.scheme == "https":
            return [key, http.client.HTTPSConnection(u.host, u.port, timeout=self.timeout, context=self.context)]
        return [key, http.client.HTTPConnection(u.host, u.port, timeout=self.timeout)]

    def _keep(self, key, conn):
        with self._lock:
            if key in self._conns:
                conn.close()
            else:
                self._conns[key] = conn

    def close(self):
        with self._lock:
            for k in self._conns:
                self._conns[k].close()
            self._conns = {}

    def _encode_body(self, body, headers):
        if body == none:
            return none
        if isinstance(body, "map") or isinstance(body, "list"):
            if not headers.has("Content-Type"):
                headers.set("Content-Type", "application/json")
            return json_encode(body).encode("utf-8")
        if isinstance(body, "str"):
            return body.encode("utf-8")
        return body

    def request(self, method, path, body=none, headers=none, params=none, timeout=none):
        method = method.upper()
        var url = self._make_url(path)
        if params != none:
            var qs = urllib.parse.urlencode(params, true)
            if string_contains(url, "?"):
                url = url + "&" + qs
            else:
                url = url + "?" + qs
        var hdrs = self.default_headers.copy()
        hdrs.update(headers)
        var data = self._encode_body(body, hdrs)
        if data == none and not (method in ["POST", "PUT", "PATCH"]):
            hdrs.delete("Content-Type")
        var started = monotonic()
        var redirects = 0
        var attempt = 0
        var delay = self.retry_delay
        while true:
            attempt = attempt + 1
            var u = URL(url)
            if u.scheme != "http" and u.scheme != "https":
                return self._failed("unsupported URL scheme: " + u.scheme, url, started)
            var kc = self._connection(u)
            var conn = kc[1]
            if timeout != none:
                conn.timeout = timeout
            var r = none
            var content = none
            try:
                conn.request(method, u.target(), data, hdrs.to_dict())
                r = conn.getresponse()
                content = r.read()
                self.requests_sent = self.requests_sent + 1
            except (OSError, http.client.HTTPException) as e:
                conn.close()
                if attempt <= self.retries and method in _IDEMPOTENT:
                    sleep(delay)
                    delay = delay * 2
                    continue
                return self._failed(type(e).__name__ + ": " + str(e), url, started)
            if r.will_close:
                conn.close()
            else:
                self._keep(kc[0], conn)
            var status = r.status
            if self.follow_redirects and (status == 301 or status == 302 or status == 303 or status == 307 or status == 308):
                var loc = r.getheader("Location")
                if loc != none and redirects < self.max_redirects:
                    redirects = redirects + 1
                    url = urllib.parse.urljoin(url, loc)
                    if status == 303 or ((status == 301 or status == 302) and method == "POST"):
                        if method != "HEAD":
                            method = "GET"
                        data = none
                        hdrs.delete("Content-Type")
                    continue
            if (status == 429 or status == 502 or status == 503 or status == 504) and attempt <= self.retries and method in _IDEMPOTENT:
                var wait = delay
                var ra = r.getheader("Retry-After")
                if ra != none and ra.strip().isdigit():
                    wait = min(float(int(ra.strip())), 60.0)
                sleep(wait)
                delay = delay * 2
                continue
            var rh = Headers()
            for kv in r.getheaders():
                if rh.has(kv[0]):
                    rh.set(kv[0], rh.get(kv[0]) + ", " + kv[1])
                else:
                    rh.set(kv[0], kv[1])
            var text = content.decode(_charset(rh.get("Content-Type", "")), "replace")
            return Response(status, r.reason, text, rh, content, url, monotonic() - started)

    def _failed(self, why, url, started):
        var resp = Response(0, "Connection Failed: " + why, "", none, b"", url, monotonic() - started)
        resp.error = why
        return resp

    def get(self, path, params=none, headers=none):
        return self.request("GET", path, none, headers, params)

    def head(self, path, headers=none):
        return self.request("HEAD", path, none, headers)

    def post(self, path, body=none, headers=none):
        return self.request("POST", path, body, headers)

    def put(self, path, body=none, headers=none):
        return self.request("PUT", path, body, headers)

    def patch(self, path, body=none, headers=none):
        return self.request("PATCH", path, body, headers)

    def delete_req(self, path, headers=none):
        return self.request("DELETE", path, none, headers)

    def delete(self, path, headers=none):
        return self.request("DELETE", path, none, headers)

# ─── RestClient ──────────────────────────────────────────────────────────────

class RestClient:
    # JSON resources: the decoded body, or none when the request failed (the
    # Response is in last_response).
    def __init__(self, base_url, timeout=30):
        self.base_url = base_url
        self.auth_token = ""
        self.headers = Headers()
        self.headers.default_request()
        self.client = HttpClient(base_url, timeout)
        self.last_response = none

    def set_auth(self, token):
        self.auth_token = token
        self.headers.set("Authorization", "Bearer " + token)

    def set_header(self, name, value):
        self.headers.set(name, value)

    def _call(self, method, path, data=none, params=none):
        self.client.default_headers = self.headers.copy()
        var r = self.client.request(method, path, data, none, params)
        self.last_response = r
        if not r.is_ok():
            return none
        if r.body == "":
            return none
        try:
            return json_decode(r.body)
        except Exception:
            return none

    def get(self, path, params=none):
        return self._call("GET", path, none, params)

    def post(self, path, data):
        return self._call("POST", path, data)

    def put(self, path, data):
        return self._call("PUT", path, data)

    def delete_req(self, path):
        return self._call("DELETE", path)

    def patch(self, path, data):
        return self._call("PATCH", path, data)

# ─── DNS ────────────────────────────────────────────────────────────────────

class DNS:
    def __init__(self):
        self.cache = {}

    def resolve(self, hostname):
        # The first address (IPv4 preferred), cached; none when it does not resolve.
        var cached = self.cache.get(hostname)
        if cached != none:
            return cached
        var all = self.resolve_all(hostname)
        if len(all) == 0:
            return none
        var ip = all[0]
        for a in all:
            if not string_contains(a, ":"):
                ip = a
                break
        self.cache[hostname] = ip
        return ip

    def resolve_all(self, hostname):
        var out = []
        try:
            for ai in socket.getaddrinfo(hostname, none, 0, socket.SOCK_STREAM):
                var a = ai[4][0]
                if not (a in out):
                    out.append(a)
        except OSError:
            pass
        return out

    def lookup(self, hostname):
        return self.resolve(hostname)

    def reverse(self, ip):
        try:
            return socket.gethostbyaddr(ip)[0]
        except OSError:
            return none

    def clear_cache(self):
        self.cache = {}

    def is_valid_ip(self, ip):
        return self.is_ipv4(ip) or self.is_ipv6(ip)

    def is_ipv4(self, ip):
        try:
            socket.inet_pton(socket.AF_INET, ip)
            return true
        except (OSError, ValueError):
            return false

    def is_ipv6(self, ip):
        try:
            socket.inet_pton(socket.AF_INET6, ip)
            return true
        except (OSError, ValueError):
            return false

# ─── RateLimiter ─────────────────────────────────────────────────────────────

class RateLimiter:
    # At most max_calls in any period_seconds (a sliding window).
    def __init__(self, max_calls, period_seconds):
        self.max_calls = max_calls
        self.period = period_seconds
        self.calls = []
        self.call_count = 0
        self._lock = threading.Lock()

    def _trim(self, now):
        var cutoff = now - self.period
        var i = 0
        while i < len(self.calls) and self.calls[i] <= cutoff:
            i = i + 1
        if i > 0:
            self.calls = self.calls[i:]
        self.call_count = len(self.calls)

    def allow(self):
        with self._lock:
            var now = monotonic()
            self._trim(now)
            if self.call_count < self.max_calls:
                self.calls.append(now)
                self.call_count = self.call_count + 1
                return true
            return false

    def wait(self):
        # Blocks until a call is allowed, then takes it.
        while true:
            var left = 0
            with self._lock:
                var now = monotonic()
                self._trim(now)
                if self.call_count < self.max_calls:
                    self.calls.append(now)
                    self.call_count = self.call_count + 1
                    return true
                left = self.calls[0] + self.period - now
            sleep(max(left, 0.001))

    def remaining(self):
        with self._lock:
            self._trim(monotonic())
            return self.max_calls - self.call_count

    def reset(self):
        with self._lock:
            self.calls = []
            self.call_count = 0

# ─── ConnectionPool ──────────────────────────────────────────────────────────

class ConnectionPool:
    # TCP connections to host:port, reused: acquire() hands out an idle one
    # or opens a new one while fewer than max_size exist, else waits.
    def __init__(self, host, port, max_size, timeout=10):
        self.host = host
        self.port = port
        self.max_size = max_size
        self.timeout = timeout
        self.connections = []        # idle, ready for reuse
        self.conn_count = 0          # open, idle or in use
        self.active = 0
        self._cond = threading.Condition(threading.Lock())

    def active_count(self):
        return self.active

    def available_count(self):
        return self.max_size - self.active

    def acquire(self, wait_timeout=none):
        var deadline = none
        if wait_timeout != none:
            deadline = monotonic() + wait_timeout
        with self._cond:
            while true:
                if len(self.connections) > 0:
                    var c = self.connections.pop()
                    self.active = self.active + 1
                    return c
                if self.conn_count < self.max_size:
                    self.conn_count = self.conn_count + 1
                    self.active = self.active + 1
                    break
                if deadline != none and monotonic() >= deadline:
                    return none
                var left = 1.0
                if deadline != none:
                    left = deadline - monotonic()
                self._cond.wait(max(left, 0.001))
        try:
            return socket.create_connection((self.host, self.port), self.timeout)
        except OSError:
            with self._cond:
                self.conn_count = self.conn_count - 1
                self.active = self.active - 1
                self._cond.notify()
            return none

    def release(self, conn, reusable=true):
        with self._cond:
            if self.active > 0:
                self.active = self.active - 1
            if reusable and conn != none:
                self.connections.append(conn)
            else:
                self.conn_count = self.conn_count - 1
                if conn != none:
                    conn.close()
            self._cond.notify()

    def close_all(self):
        with self._cond:
            for c in self.connections:
                c.close()
            self.conn_count = self.conn_count - len(self.connections)
            self.connections = []
            self._cond.notify_all()

# ─── MimeTypes ───────────────────────────────────────────────────────────────

class MimeTypes:
    def __init__(self):
        self.types = {}
        self.types[".html"] = "text/html"
        self.types[".htm"]  = "text/html"
        self.types[".css"]  = "text/css"
        self.types[".js"]   = "application/javascript"
        self.types[".json"] = "application/json"
        self.types[".xml"]  = "application/xml"
        self.types[".txt"]  = "text/plain"
        self.types[".md"]   = "text/markdown"
        self.types[".png"]  = "image/png"
        self.types[".jpg"]  = "image/jpeg"
        self.types[".jpeg"] = "image/jpeg"
        self.types[".gif"]  = "image/gif"
        self.types[".svg"]  = "image/svg+xml"
        self.types[".ico"]  = "image/x-icon"
        self.types[".webp"] = "image/webp"
        self.types[".mp3"]  = "audio/mpeg"
        self.types[".mp4"]  = "video/mp4"
        self.types[".pdf"]  = "application/pdf"
        self.types[".zip"]  = "application/zip"
        self.types[".wasm"] = "application/wasm"
        self.types[".ny"]   = "text/x-nython"
        self.types[".py"]   = "text/x-python"
        self.types[".ts"]   = "application/typescript"

    def get(self, ext):
        var m = self.types.get(ext.lower())
        if m == none:
            return "application/octet-stream"
        return m

    def get_for_path(self, path):
        var dot = path.rfind(".")
        var slash = max(path.rfind("/"), path.rfind("\\"))
        if dot < 0 or dot < slash:
            return "application/octet-stream"
        return self.get(path[dot:])

    def register(self, ext, mime):
        self.types[ext] = mime

# ─── EventSource (Server-Sent Events) ────────────────────────────────────────

class SSEEvent:
    def __init__(self, type, data, id, origin):
        self.type = type
        self.data = data
        self.id = id
        self.last_event_id = id
        self.origin = origin

    def __repr__(self):
        return "SSEEvent(" + repr(self.type) + ", " + repr(self.data) + ")"

class EventSource:
    # The WHATWG EventSource: connect() reads the stream on a thread and
    # calls on(type) handlers with each event's data (on_event handlers get
    # the whole SSEEvent). Reconnects after reconnect_delay seconds (the
    # stream's "retry:" field sets it) sending Last-Event-ID; a reply that is
    # not 200 text/event-stream ends it (state CLOSED, an "error" event).
    CONNECTING = 0
    OPEN = 1
    CLOSED = 2

    def __init__(self, url, headers=none, reconnect_delay=3.0, timeout=none, context=none):
        self.url = url
        self.handlers = {}
        self.event_handlers = []
        self.running = false
        self.connected = false
        self.reconnect_delay = reconnect_delay
        self.last_event_id = ""
        self.ready_state = 2
        self.headers = headers
        self.timeout = timeout
        self.context = context
        self.events_received = 0
        self._conn = none
        self._thread = none

    def on(self, event_type, handler):
        self.handlers[event_type] = handler

    def off(self, event_type):
        if event_type in self.handlers:
            del self.handlers[event_type]

    def on_event(self, handler):
        self.event_handlers.append(handler)

    def connect(self, background=true):
        if self.running:
            return true
        self.running = true
        self.ready_state = 0
        if background:
            self._thread = threading.Thread(target=self._run, daemon=true)
            self._thread.start()
        else:
            self._run()
        return true

    def disconnect(self):
        self.running = false
        self.connected = false
        self.ready_state = 2
        var c = self._conn
        if c != none:
            try:
                c.sock.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            c.close()
        if self._thread != none and self._thread.ident != threading.get_ident():
            self._thread.join(5)

    def close(self):
        self.disconnect()

    def _dispatch(self, event_type, data, ev=none):
        if ev == none:
            ev = SSEEvent(event_type, data, self.last_event_id, self.url)
        var h = self.handlers.get(event_type)
        if h != none:
            h(data)
        for eh in self.event_handlers:
            eh(ev)

    def _run(self):
        while self.running:
            var fatal = false
            try:
                fatal = self._stream()
            except (OSError, http.client.HTTPException, ValueError) as e:
                pass
            self.connected = false
            if not self.running:
                break
            if fatal:
                self.running = false
                self.ready_state = 2
                self._dispatch("error", none)
                break
            self.ready_state = 0
            self._dispatch("error", none)
            var waited = 0.0
            while self.running and waited < self.reconnect_delay:
                sleep(0.05)
                waited = waited + 0.05

    def _stream(self):
        # One connection: true when the reply ends the EventSource for good.
        var u = URL(self.url)
        var conn = none
        if u.scheme == "https":
            conn = http.client.HTTPSConnection(u.host, u.port, timeout=self.timeout, context=self.context)
        else:
            conn = http.client.HTTPConnection(u.host, u.port, timeout=self.timeout)
        self._conn = conn
        var hdrs = {"Accept": "text/event-stream", "Cache-Control": "no-cache"}
        if self.last_event_id != "":
            hdrs["Last-Event-ID"] = self.last_event_id
        if self.headers != none:
            for k in self.headers:
                hdrs[k] = self.headers[k]
        conn.request("GET", u.target(), none, hdrs)
        var r = conn.getresponse()
        var ct = (r.getheader("Content-Type") or "").split(";")[0].strip().lower()
        if r.status != 200 or ct != "text/event-stream":
            r.read()
            conn.close()
            return true
        self.connected = true
        self.ready_state = 1
        self._dispatch("open", none)
        var data = []
        var etype = ""
        var eid = self.last_event_id
        var first = true
        while self.running:
            var raw = r.readline()
            if len(raw) == 0:
                break
            var line = raw.decode("utf-8", "replace")
            if first:
                first = false
                if line.startswith("﻿"):
                    line = line[1:]
            line = line.rstrip("\n").rstrip("\r")
            if line == "":
                # dispatch (WHATWG 9.2.6)
                self.last_event_id = eid
                if len(data) > 0:
                    var t = etype
                    if t == "":
                        t = "message"
                    self.events_received = self.events_received + 1
                    var text = "\n".join(data)
                    self._dispatch(t, text, SSEEvent(t, text, eid, self.url))
                data = []
                etype = ""
                continue
            if line.startswith(":"):
                continue
            var field = line
            var value = ""
            var c = line.find(":")
            if c >= 0:
                field = line[0:c]
                value = line[c + 1:]
                if value.startswith(" "):
                    value = value[1:]
            if field == "event":
                etype = value
            elif field == "data":
                data.append(value)
            elif field == "id":
                if value.find("\0") < 0:
                    eid = value
            elif field == "retry":
                if value != "" and value.isdigit():
                    self.reconnect_delay = int(value) / 1000.0
        conn.close()
        return false

# ─── WebSocket ────────────────────────────────────────────────────────────────

class WebSocket:
    # A WebSocket client (RFC 6455, lib/websocket.ny) with callbacks. With
    # on_message set, connect() receives on a thread and calls it with each
    # message; otherwise recv() reads them.
    def __init__(self, url, protocols=none, headers=none, ping_interval=none):
        self.url = url
        self.conn = none
        self.on_message = none
        self.on_open = none
        self.on_close = none
        self.on_error = none
        self.connected = false
        self.protocols = protocols
        self.headers = headers
        self.ping_interval = ping_interval
        self.close_code = none
        self.close_reason = none
        self._thread = none

    def connect(self, timeout=10):
        try:
            self.conn = websocket.connect(self.url, subprotocols=self.protocols, additional_headers=self.headers,
                                          open_timeout=timeout, ping_interval=self.ping_interval)
        except Exception as e:
            self.conn = none
            if self.on_error != none:
                self.on_error(e)
            return false
        self.connected = true
        if self.on_open != none:
            self.on_open()
        if self.on_message != none:
            self._thread = threading.Thread(target=self._pump, daemon=true)
            self._thread.start()
        return true

    def _pump(self):
        try:
            for m in self.conn:
                self.on_message(m)
        except websocket.ConnectionClosed:
            pass
        except Exception as e:
            if self.on_error != none:
                self.on_error(e)
        self._closed()

    def _closed(self):
        if not self.connected:
            return
        self.connected = false
        if self.conn != none:
            self.close_code = self.conn.close_code
            self.close_reason = self.conn.close_reason
        if self.on_close != none:
            self.on_close()

    def send(self, message):
        if not self.connected or self.conn == none:
            return false
        try:
            self.conn.send(message)
            return true
        except (websocket.ConnectionClosed, OSError):
            self._closed()
            return false

    def recv(self, timeout=none):
        # The next message, or none once the connection is closed (or after
        # timeout seconds).
        if self.conn == none:
            return none
        try:
            return self.conn.recv(timeout)
        except TimeoutError:
            return none
        except websocket.ConnectionClosed:
            self._closed()
            return none

    def ping(self, data=none):
        if self.conn == none:
            return none
        return self.conn.ping(data)

    def run_forever(self):
        # Receives until the connection closes, calling on_message.
        while self.connected:
            var m = self.recv()
            if m == none:
                break
            if self.on_message != none:
                self.on_message(m)

    def close(self, code=1000, reason=""):
        if self.conn != none:
            self.conn.close(code, reason)
        if self._thread != none and self._thread.ident != threading.get_ident():
            self._thread.join(5)
        self._closed()

    def is_connected(self):
        return self.connected

# ─── Retry ───────────────────────────────────────────────────────────────────

class Retry:
    # Calls fn until it returns something other than none (or raises nothing),
    # waiting delay_ms, then delay_ms * backoff_factor, ... between attempts.
    def __init__(self, max_attempts, delay_ms, backoff_factor):
        self.max_attempts = max_attempts
        self.delay_ms = delay_ms
        self.backoff_factor = backoff_factor
        self.attempt_count = 0
        self.last_error = ""
        self._on_retry = none

    def on_retry(self, fn):
        self._on_retry = fn
        return self

    def execute(self, fn):
        self.attempt_count = 0
        var current_delay = self.delay_ms
        var i = 0
        while i < self.max_attempts:
            self.attempt_count = self.attempt_count + 1
            var result = none
            try:
                result = fn()
                if result != none:
                    return result
                self.last_error = "Attempt " + str(self.attempt_count) + " failed"
            except Exception as e:
                self.last_error = "Attempt " + str(self.attempt_count) + " failed: " + type(e).__name__ + ": " + str(e)
            if self._on_retry != none:
                self._on_retry(self.attempt_count, self.last_error)
            if i < self.max_attempts - 1:
                sleep(current_delay / 1000.0)
                current_delay = current_delay * self.backoff_factor
            i = i + 1
        return none

    def reset(self):
        self.attempt_count = 0
        self.last_error = ""
        return self

    def remaining(self):
        return self.max_attempts - self.attempt_count

# ─── HttpCache ────────────────────────────────────────────────────────────────

class CacheEntry:
    def __init__(self, response, ttl_seconds):
        self.response = response
        self.created_at = monotonic()
        self.ttl = ttl_seconds
        self.hit_count = 0

    def is_expired(self):
        return (monotonic() - self.created_at) > self.ttl

    def touch(self):
        self.hit_count = self.hit_count + 1

def _max_age(cache_control):
    # seconds from a Cache-Control value: none when absent, 0 for no-store/no-cache
    var cc = cache_control.lower()
    if cc.find("no-store") >= 0 or cc.find("no-cache") >= 0 or cc.find("private") >= 0:
        return 0
    for part in cc.split(","):
        var p = part.strip()
        if p.startswith("max-age="):
            var v = p[8:].strip()
            if v.isdigit():
                return int(v)
    return none

class HttpCache:
    def __init__(self, default_ttl):
        self.default_ttl = default_ttl
        self.entries = {}
        self.entry_count = 0
        self.hit_count = 0
        self.miss_count = 0
        self.max_entries = 1000

    def get(self, url):
        var entry = self.entries.get(url)
        if entry == none:
            self.miss_count = self.miss_count + 1
            return none
        if entry.is_expired():
            self.invalidate(url)
            self.miss_count = self.miss_count + 1
            return none
        entry.touch()
        self.hit_count = self.hit_count + 1
        return entry.response

    def set(self, url, response, ttl):
        var existing = self.entries.get(url)
        if existing == none and self.entry_count >= self.max_entries:
            self._evict()
        if existing == none:
            self.entry_count = self.entry_count + 1
        self.entries[url] = CacheEntry(response, ttl)

    def _evict(self):
        # the entry closest to expiring goes
        var victim = none
        var best = none
        for k in self.entries:
            var e = self.entries[k]
            var left = e.ttl - (monotonic() - e.created_at)
            if best == none or left < best:
                best = left
                victim = k
        if victim != none:
            self.invalidate(victim)

    def set_default(self, url, response):
        self.set(url, response, self.default_ttl)

    def store(self, url, response):
        # Caches a response for as long as its Cache-Control allows (the
        # default TTL when it says nothing); false when it may not be kept.
        var ttl = self.default_ttl
        if hasattr(response, "headers") and response.headers != none and response.headers.has("Cache-Control"):
            var ma = _max_age(response.headers.get("Cache-Control"))
            if ma != none:
                ttl = ma
        if ttl <= 0:
            return false
        self.set(url, response, ttl)
        return true

    def fetch(self, client, url):
        # The cached response, or one fetched with client (an HttpClient) and stored.
        var r = self.get(url)
        if r != none:
            return r
        r = client.get(url)
        if r.is_ok():
            self.store(url, r)
        return r

    def invalidate(self, url):
        if url in self.entries:
            del self.entries[url]
            self.entry_count = self.entry_count - 1

    def clear(self):
        self.entries = {}
        self.entry_count = 0

    def hit_rate(self):
        var total = self.hit_count + self.miss_count
        if total == 0:
            return 0.0
        return float(self.hit_count) / float(total)

    def stats(self):
        var s = {}
        s["entries"] = self.entry_count
        s["hits"] = self.hit_count
        s["misses"] = self.miss_count
        s["hit_rate"] = self.hit_rate()
        return s

# ─── OAuth2Client ──────────────────────────────────────────────────────────────

class OAuth2Client:
    # RFC 6749: the authorization-code URL, the client-credentials and
    # refresh-token grants (form-encoded, client_secret_post).
    def __init__(self, client_id, client_secret, token_url, authorize_url=none):
        self.client_id = client_id
        self.client_secret = client_secret
        self.token_url = token_url
        self.authorize_url = authorize_url
        if authorize_url == none:
            self.authorize_url = token_url
        self.access_token = ""
        self.refresh_token = ""
        self.token_type = "Bearer"
        self.expires_at = 0.0
        self.scope = ""
        self.last_error = none
        self.client = HttpClient()

    def is_expired(self):
        if self.expires_at == 0.0:
            return true
        return time_now() >= self.expires_at

    def set_token(self, access_token, expires_in, refresh_token):
        self.access_token = access_token
        self.expires_at = time_now() + float(expires_in)
        if refresh_token != "" and refresh_token != none:
            self.refresh_token = refresh_token

    def get_header(self):
        return self.token_type + " " + self.access_token

    def auth_code_url(self, redirect_uri, state, scopes):
        var q = urllib.parse.urlencode({"response_type": "code", "client_id": self.client_id, "redirect_uri": redirect_uri,
                                        "scope": " ".join(scopes), "state": state})
        var sep = "?"
        if string_contains(self.authorize_url, "?"):
            sep = "&"
        return self.authorize_url + sep + q

    def _token_request(self, fields):
        fields["client_id"] = self.client_id
        fields["client_secret"] = self.client_secret
        var body = urllib.parse.urlencode(fields)
        var r = self.client.request("POST", self.token_url, body, {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"})
        if not r.is_ok():
            self.last_error = r.reason
            return false
        var data = none
        try:
            data = json_decode(r.body)
        except Exception:
            self.last_error = "token response is not JSON"
            return false
        if not ("access_token" in data):
            self.last_error = data.get("error", "no access_token")
            return false
        self.token_type = data.get("token_type", "Bearer")
        if self.token_type.lower() == "bearer":
            self.token_type = "Bearer"
        self.scope = data.get("scope", self.scope)
        self.set_token(data["access_token"], data.get("expires_in", 3600), data.get("refresh_token", ""))
        return true

    def client_credentials(self, scopes=none):
        var f = {"grant_type": "client_credentials"}
        if scopes != none:
            f["scope"] = " ".join(scopes)
        return self._token_request(f)

    def exchange_code(self, code, redirect_uri):
        return self._token_request({"grant_type": "authorization_code", "code": code, "redirect_uri": redirect_uri})

    def refresh(self):
        if self.refresh_token == "":
            return false
        return self._token_request({"grant_type": "refresh_token", "refresh_token": self.refresh_token})

# ─── GraphQL Client ───────────────────────────────────────────────────────────

class GraphQLClient:
    def __init__(self, endpoint):
        self.endpoint = endpoint
        self.headers = Headers()
        self.headers.set("Content-Type", "application/json")
        self.headers.set("Accept", "application/json")
        self.client = HttpClient()
        self.last_errors = none

    def set_auth(self, token):
        self.headers.set("Authorization", "Bearer " + token)
        return self

    def set_header(self, name, value):
        self.headers.set(name, value)
        return self

    def query(self, gql_query, variables=none, operation_name=none):
        # The "data" of the reply (none on failure; GraphQL errors in last_errors).
        var payload = {"query": gql_query}
        if variables != none:
            payload["variables"] = variables
        if operation_name != none:
            payload["operationName"] = operation_name
        self.client.default_headers = self.headers.copy()
        var r = self.client.post(self.endpoint, payload)
        self.last_errors = none
        if r.status == 0:
            self.last_errors = [{"message": r.reason}]
            return none
        var result = none
        try:
            result = json_decode(r.body)
        except Exception:
            self.last_errors = [{"message": "HTTP " + str(r.status) + ": not JSON"}]
            return none
        self.last_errors = result.get("errors")
        return result.get("data")

    def mutation(self, gql_mutation, variables=none):
        return self.query(gql_mutation, variables)

    def introspect(self):
        return self.query("{ __schema { types { name } } }")

# ─── RequestQueue ─────────────────────────────────────────────────────────────

class QueuedRequest:
    _seq = 0

    def __init__(self, method, url, body, callback):
        self.method = method
        self.url = url
        self.body = body
        self.callback = callback
        self.priority = 0
        QueuedRequest._seq = QueuedRequest._seq + 1
        self.id = "req_" + str(int(time_ms())) + "_" + str(QueuedRequest._seq)
        self.response = none

class RequestQueue:
    # Queued requests, sent by flush() with at most max_concurrent in
    # flight; each callback gets its Response (on a worker thread).
    def __init__(self, max_concurrent):
        self.max_concurrent = max_concurrent
        self.queue = []
        self.queue_size = 0
        self.active = 0
        self.completed = 0
        self.failed = 0
        self._lock = threading.Lock()
        self.client = HttpClient()

    def enqueue(self, method, url, body, callback, priority=0):
        var req = QueuedRequest(method, url, body, callback)
        req.priority = priority
        with self._lock:
            var i = len(self.queue)
            while i > 0 and self.queue[i - 1].priority < priority:
                i = i - 1
            self.queue.insert(i, req)
            self.queue_size = len(self.queue)
        return req.id

    def enqueue_get(self, url, callback):
        return self.enqueue("GET", url, none, callback)

    def enqueue_post(self, url, body, callback):
        return self.enqueue("POST", url, body, callback)

    def _take(self):
        with self._lock:
            if len(self.queue) == 0:
                return none
            var req = self.queue.pop(0)
            self.queue_size = len(self.queue)
            self.active = self.active + 1
            return req

    def _send(self, req):
        var body = req.body
        if body == "":
            body = none
        var hc = HttpClient(timeout=self.client.timeout, retries=0)
        var r = hc.request(req.method, req.url, body)
        hc.close()
        req.response = r
        with self._lock:
            self.active = self.active - 1
            if r.status != 0:
                self.completed = self.completed + 1
            else:
                self.failed = self.failed + 1
        if req.callback != none:
            req.callback(r)

    def _worker(self):
        while true:
            var req = self._take()
            if req == none:
                return
            self._send(req)

    def _process_next(self):
        var req = self._take()
        if req != none:
            self._send(req)

    def flush(self):
        var n = min(self.max_concurrent, self.queue_size)
        var workers = []
        var i = 0
        while i < n:
            var t = threading.Thread(target=self._worker)
            t.start()
            workers.append(t)
            i = i + 1
        for t in workers:
            t.join()

    def pending(self):
        return self.queue_size

    def stats(self):
        var s = {}
        s["pending"] = self.queue_size
        s["active"] = self.active
        s["completed"] = self.completed
        s["failed"] = self.failed
        return s

# ─── Webhook ──────────────────────────────────────────────────────────────────

class WebhookPayload:
    def __init__(self, event_type, data, secret):
        self.event_type = event_type
        self.data = data
        self.secret = secret
        self.timestamp = int(time_now())
        self.id = "whk_" + str(self.timestamp) + "_" + os_urandom(6).hex()

    def to_json(self):
        var p = {}
        p["id"] = self.id
        p["event"] = self.event_type
        p["data"] = self.data
        p["timestamp"] = self.timestamp
        return json_encode(p)

    def signature(self, body=none):
        # "t=<unix seconds>,v1=<hex HMAC-SHA256 of '<t>.<body>'>"
        if body == none:
            body = self.to_json()
        var mac = hmac.new(self.secret.encode("utf-8"), (str(self.timestamp) + "." + body).encode("utf-8"), hashlib.sha256).hexdigest()
        return "t=" + str(self.timestamp) + ",v1=" + mac

def verify_webhook(secret, body, signature_header, tolerance=300, now=none):
    # Whether a delivery is genuine: the HMAC matches (compared in constant
    # time) and its timestamp is within tolerance seconds of now (a replay
    # of an old delivery fails).
    if signature_header == none or signature_header == "":
        return false
    var t = none
    var sigs = []
    for part in signature_header.split(","):
        var kv = part.strip().split("=", 1)
        if len(kv) != 2:
            continue
        if kv[0] == "t" and kv[1].isdigit():
            t = int(kv[1])
        elif kv[0] == "v1":
            sigs.append(kv[1])
    if t == none or len(sigs) == 0:
        return false
    if now == none:
        now = time_now()
    if tolerance != none and abs(now - t) > tolerance:
        return false
    if isinstance(body, "bytes"):
        body = body.decode("utf-8")
    var expected = hmac.new(secret.encode("utf-8"), (str(t) + "." + body).encode("utf-8"), hashlib.sha256).hexdigest()
    for s in sigs:
        if hmac.compare_digest(s, expected):
            return true
    return false

class WebhookSender:
    # Signed deliveries: X-Webhook-Id, X-Webhook-Event and
    # X-Webhook-Signature ("t=...,v1=..."); a 2xx reply is a success.
    def __init__(self, secret):
        self.secret = secret
        self.sent = 0
        self.failed = 0
        self.endpoints = []
        self.endpoint_count = 0
        self.client = HttpClient(retries=2, retry_delay=0.5)
        self.last_response = none

    def add_endpoint(self, url):
        self.endpoints.append(url)
        self.endpoint_count = self.endpoint_count + 1
        return self

    def send(self, url, event_type, data):
        var payload = WebhookPayload(event_type, data, self.secret)
        var body = payload.to_json()
        var r = self.client.request("POST", url, body, {"Content-Type": "application/json", "X-Webhook-Id": payload.id,
                                    "X-Webhook-Event": event_type, "X-Webhook-Signature": payload.signature(body)})
        self.last_response = r
        if r.is_ok():
            self.sent = self.sent + 1
            return true
        self.failed = self.failed + 1
        return false

    def broadcast(self, event_type, data):
        var success_count = 0
        var i = 0
        while i < self.endpoint_count:
            if self.send(self.endpoints[i], event_type, data):
                success_count = success_count + 1
            i = i + 1
        return success_count
