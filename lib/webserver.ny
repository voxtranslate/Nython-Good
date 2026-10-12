# ═══════════════════════════════════════════════════════════════════════════════
# webserver.ny — Nython Web Server Library
# HTTP/1.1 server, routing, middleware, static files, sessions, templating,
# WebSockets, validation, health checks, signed webhooks.
# Usage: import "lib/webserver.ny"
#
#     var app = HttpServer("127.0.0.1", 8080)
#     app.use(LoggingMiddleware()).use(SessionMiddleware(app.sessions))
#     app.get("/users/:id", lambda req, res: res.send_json({"id": req.params["id"]}))
#     app.static("/static", "./public")
#     app.listen()                        # or app.start() for a background thread
#
# Round 77: a real server. It used to read each request with a raw receive
# that waited for the client to close, answer one connection at a time,
# never parse headers, fail on any route with a :param (an append written as
# an index store), let a 429 or 403 middleware fall through to the handler,
# accept every token and every webhook signature, and frame WebSocket
# messages without a handshake. Now: http.server underneath (keep-alive,
# a thread per connection, HEAD, 405 with Allow, 100-continue), middleware
# that can stop the chain, HMAC-signed bearer tokens and webhooks, sessions
# with unguessable ids over cookies, safe static files with 304s, escaping
# templates, and RFC 6455 WebSockets (lib/websocket.ny).
# ═══════════════════════════════════════════════════════════════════════════════
import nytorch
import net
import socket
import threading
import http.server
import urllib.parse
import websocket
import hmac
import hashlib
import base64

# ─── Request ─────────────────────────────────────────────────────────────────

class Request:
    # A parsed request. Request(raw_text) parses a whole HTTP request (tests,
    # proxies); the server builds one from the connection.
    def __init__(self, raw="", client_fd=none):
        self.raw = raw
        self.client_fd = client_fd
        self.method = "GET"
        self.path = "/"
        self.query_string = ""
        self.params = {}
        self.query_params = {}
        self.headers = {}
        self.body = ""
        self.raw_body = b""
        self.version = "HTTP/1.1"
        self.remote_addr = ""
        self.cookies = {}
        self.session = none
        self.parsed_json = none
        self.form = none
        self.user = none
        self.state = {}
        if raw != none and len(raw) > 0:
            self._parse(raw)

    def _parse(self, raw):
        if isinstance(raw, "bytes"):
            raw = raw.decode("utf-8", "replace")
        var cut = raw.find("\r\n\r\n")
        var sep = 4
        if cut < 0:
            cut = raw.find("\n\n")
            sep = 2
        var head = raw
        var body = ""
        if cut >= 0:
            head = raw[0:cut]
            body = raw[cut + sep:]
        var lines = head.replace("\r\n", "\n").split("\n")
        var parts = lines[0].strip().split(" ")
        if len(parts) >= 1:
            self.method = parts[0].upper()
        var target = "/"
        if len(parts) >= 2:
            target = parts[1]
        if len(parts) >= 3:
            self.version = parts[2]
        var hdrs = {}
        for line in lines[1:]:
            var c = line.find(":")
            if c > 0:
                hdrs[line[0:c].strip()] = line[c + 1:].strip()
        self._fill(self.method, target, hdrs, body.encode("utf-8"), "")

    def _fill(self, method, target, headers, body_bytes, remote_addr):
        self.method = method
        var q = target.find("?")
        if q >= 0:
            self.path = urllib.parse.unquote(target[0:q])
            self.query_string = target[q + 1:]
        else:
            self.path = urllib.parse.unquote(target)
        self.query_params = {}
        for kv in urllib.parse.parse_qsl(self.query_string, true):
            if not (kv[0] in self.query_params):
                self.query_params[kv[0]] = kv[1]
        self.headers = {}
        for k in headers:
            self.headers[string_lower(k)] = headers[k]
        self.raw_body = body_bytes
        self.body = body_bytes.decode("utf-8", "replace")
        self.remote_addr = remote_addr
        self.cookies = parse_cookies(self.header("cookie"))

    def query(self, key, default=""):
        return self.query_params.get(key, default)

    def json_body(self):
        if self.parsed_json == none and self.body != "":
            self.parsed_json = json_decode(self.body)
        return self.parsed_json

    def form_value(self, key, default=""):
        if self.form == none:
            self.form = {}
            for kv in urllib.parse.parse_qsl(self.body, true):
                if not (kv[0] in self.form):
                    self.form[kv[0]] = kv[1]
        return self.form.get(key, default)

    def query_params_from(self, s, key):
        for kv in urllib.parse.parse_qsl(s, true):
            if kv[0] == key:
                return kv[1]
        return ""

    def header(self, name, default=""):
        var val = self.headers.get(string_lower(name))
        if val == none:
            return default
        return val

    def cookie(self, name, default=none):
        return self.cookies.get(name, default)

    def is_json(self):
        return string_contains(self.header("content-type"), "application/json")

    def is_form(self):
        return string_contains(self.header("content-type"), "application/x-www-form-urlencoded")

    def bearer_token(self):
        var a = self.header("authorization")
        if a.lower().startswith("bearer "):
            return a[7:].strip()
        return ""

def parse_cookies(header):
    var out = {}
    if header == none or header == "":
        return out
    for part in header.split(";"):
        var p = part.strip()
        var eq = p.find("=")
        if eq > 0:
            var v = p[eq + 1:].strip()
            if len(v) >= 2 and v.startswith("\"") and v.endswith("\""):
                v = v[1:-1]
            out[p[0:eq].strip()] = v
    return out

# ─── Response Writer ──────────────────────────────────────────────────────────

_REASONS = http.responses

class ResponseWriter:
    # The response to one request. With a stream (the server's wfile) or a
    # socket (client_fd), send() writes it; without, it is kept (tests).
    def __init__(self, client_fd=none, stream=none, head_only=false, keep_alive=false):
        self.client_fd = client_fd
        self.stream = stream
        self.head_only = head_only
        self.keep_alive = keep_alive
        self.status = 200
        self.headers = {}
        self.headers["Content-Type"] = "text/html; charset=utf-8"
        self.headers["Server"] = "Nython/0.2.1"
        self.cookies = []
        self._sent = false
        self.body_sent = b""
        self.bytes_sent = 0

    def set_status(self, code):
        self.status = code
        return self

    def set_header(self, name, value):
        self.headers[name] = value
        return self

    def set_cookie(self, name, value, path="/", max_age=-1, http_only=true, secure=false, same_site="Lax", domain=none):
        var cookie = name + "=" + value + "; Path=" + path
        if max_age >= 0:
            cookie = cookie + "; Max-Age=" + str(max_age)
        if domain != none:
            cookie = cookie + "; Domain=" + domain
        if http_only:
            cookie = cookie + "; HttpOnly"
        if secure:
            cookie = cookie + "; Secure"
        if same_site != none:
            cookie = cookie + "; SameSite=" + same_site
        self.cookies.append(cookie)
        self.headers["Set-Cookie"] = cookie
        return self

    def delete_cookie(self, name, path="/"):
        return self.set_cookie(name, "", path, 0)

    def _status_text(self, code):
        return _REASONS.get(code, "Unknown")

    def _build_headers(self, body_len):
        var h = "HTTP/1.1 " + str(self.status) + " " + self._status_text(self.status) + "\r\n"
        if self.status != 204 and self.status != 304 and self.status >= 200:
            h = h + "Content-Length: " + str(body_len) + "\r\n"
        if self.keep_alive:
            h = h + "Connection: keep-alive\r\n"
        else:
            h = h + "Connection: close\r\n"
        h = h + "Date: " + http.server.formatdate() + "\r\n"
        for k in self.headers:
            if k == "Set-Cookie":
                continue
            h = h + k + ": " + str(self.headers[k]) + "\r\n"
        for c in self.cookies:
            h = h + "Set-Cookie: " + c + "\r\n"
        return h + "\r\n"

    def send(self, body=""):
        if self._sent:
            return
        self._sent = true
        var data = body
        if isinstance(body, "str"):
            data = body.encode("utf-8")
        elif body == none:
            data = b""
        var out = self._build_headers(len(data)).encode("iso-8859-1")
        if not self.head_only and self.status != 204 and self.status != 304:
            out = out + data
        self.body_sent = data
        self.bytes_sent = len(data)
        if self.stream != none:
            self.stream.write(out)
        elif self.client_fd != none:
            if isinstance(self.client_fd, "int"):
                tcp_send(self.client_fd, out.decode("iso-8859-1"))
            else:
                self.client_fd.sendall(out)

    def send_json(self, data):
        self.set_header("Content-Type", "application/json")
        var body = json_encode(data)
        if body == none:
            body = "{}"
        self.send(body)

    def send_text(self, text):
        self.set_header("Content-Type", "text/plain; charset=utf-8")
        self.send(text)

    def send_html(self, html):
        self.set_header("Content-Type", "text/html; charset=utf-8")
        self.send(html)

    def redirect(self, url, status=302):
        self.status = status
        self.set_header("Location", url)
        self.send("")

    def not_found(self):
        self.status = 404
        self.send_html("<h1>404 Not Found</h1>")

    def error(self, msg, status=500):
        self.status = status
        self.send_json({"error": msg})

    def forbidden(self):
        self.status = 403
        self.send_json({"error": "Forbidden"})

    def unauthorized(self, realm="api"):
        self.status = 401
        self.set_header("WWW-Authenticate", "Bearer realm=\"" + realm + "\"")
        self.send_json({"error": "Unauthorized"})

    def send_file(self, filepath, mime_type=none, request=none):
        # The file's bytes; 304 when the request's If-Modified-Since is not
        # older than the file.
        if not os_isfile(filepath):
            self.not_found()
            return
        if mime_type == none:
            mime_type = http.server.guess_type(filepath)
        var mtime = int(file_mtime(filepath) / 1000)
        if request != none:
            var ims = request.header("if-modified-since")
            if ims != "":
                var since = http.server.parsedate(ims)
                if since != none and mtime <= since:
                    self.status = 304
                    self.send("")
                    return
        var f = open(filepath, "rb")
        var content = f.read()
        f.close()
        self.set_header("Content-Type", mime_type)
        self.set_header("Last-Modified", http.server.formatdate(mtime))
        self.send(content)

# ─── Router ───────────────────────────────────────────────────────────────────

class Route:
    # "/users/:id" binds params["id"]; a final "*" (or "*name") takes the rest
    # of the path.
    def __init__(self, method, pattern, handler):
        self.method = method
        self.pattern = pattern
        self.handler = handler
        self.param_names = []
        self.param_count = 0
        self._parts = [p for p in pattern.split("/")]
        self._extract_params(pattern)

    def _extract_params(self, pattern):
        for p in pattern.split("/"):
            if len(p) > 0 and (p[0] == ":" or p[0] == "*"):
                var name = p[1:]
                if p[0] == "*" and name == "":
                    name = "*"
                self.param_names.append(name)
                self.param_count = self.param_count + 1

    def _bind(self, path):
        # the params when the path matches, else none
        var pparts = path.split("/")
        var params = {}
        var i = 0
        while i < len(self._parts):
            var rp = self._parts[i]
            if len(rp) > 0 and rp[0] == "*":
                var name = rp[1:]
                if name == "":
                    name = "*"
                params[name] = "/".join(pparts[i:])
                return params
            if i >= len(pparts):
                return none
            if len(rp) > 0 and rp[0] == ":":
                if pparts[i] == "":
                    return none
                params[rp[1:]] = pparts[i]
            elif rp != pparts[i]:
                return none
            i = i + 1
        if len(pparts) != len(self._parts):
            return none
        return params

    def path_matches(self, path):
        return self._bind(path) != none

    def match(self, method, path):
        if self.method != method and self.method != "*":
            return false
        return self._bind(path) != none

    def extract_params(self, path):
        var p = self._bind(path)
        if p == none:
            return {}
        return p

def _run_middleware(mw, req, res):
    # A middleware is a callable (req, res) or an object with handle(req, res);
    # returning false, or sending a response, ends the chain.
    var r = none
    if hasattr(mw, "handle") and not callable(mw):
        r = mw.handle(req, res)
    else:
        r = mw(req, res)
    return r != false and not res._sent

class Router:
    def __init__(self):
        self.routes = []
        self.route_count = 0
        self.middleware = []
        self.mw_count = 0
        self.not_found_handler = none
        self.error_handler = none

    def add(self, method, pattern, handler):
        var r = Route(method.upper(), pattern, handler)
        self.routes.append(r)
        self.route_count = self.route_count + 1
        return self

    def get(self, pattern, handler):
        return self.add("GET", pattern, handler)

    def post(self, pattern, handler):
        return self.add("POST", pattern, handler)

    def put(self, pattern, handler):
        return self.add("PUT", pattern, handler)

    def patch(self, pattern, handler):
        return self.add("PATCH", pattern, handler)

    def delete(self, pattern, handler):
        return self.add("DELETE", pattern, handler)

    def any(self, pattern, handler):
        return self.add("*", pattern, handler)

    def use(self, mw):
        self.middleware.append(mw)
        self.mw_count = self.mw_count + 1
        return self

    def mount(self, group):
        # a RouteGroup or ApiBuilder: its routes, behind its middleware
        var mws = getattr(group, "middlewares", [])
        for r in group.get_routes():
            if len(mws) > 0:
                self.add(r[0], r[1], _guarded(mws, r[2]))
            else:
                self.add(r[0], r[1], r[2])
        return self

    def on_not_found(self, handler):
        self.not_found_handler = handler

    def on_error(self, handler):
        self.error_handler = handler

    def find(self, method, path):
        # [route, params] for the request, [none, allowed methods] otherwise
        var allowed = []
        for r in self.routes:
            var params = r._bind(path)
            if params == none:
                continue
            if r.method == method or r.method == "*":
                return [r, params]
            if method == "HEAD" and r.method == "GET":
                return [r, params]
            if not (r.method in allowed):
                allowed.append(r.method)
        return [none, allowed]

    def handle(self, req, res):
        try:
            for mw in self.middleware:
                if not _run_middleware(mw, req, res):
                    return true
            var found = self.find(req.method, req.path)
            if found[0] != none:
                req.params = found[1]
                if found[0].handler != none:
                    found[0].handler(req, res)
                return true
            if len(found[1]) > 0:
                if req.method == "OPTIONS":
                    res.status = 204
                    res.set_header("Allow", ", ".join(found[1] + ["OPTIONS"]))
                    res.send("")
                    return true
                res.status = 405
                res.set_header("Allow", ", ".join(found[1]))
                res.send_json({"error": "Method Not Allowed"})
                return false
            if self.not_found_handler != none:
                self.not_found_handler(req, res)
            else:
                res.not_found()
            return false
        except Exception as e:
            if self.error_handler != none:
                self.error_handler(req, res, e)
            if not res._sent:
                res.status = 500
                res.send_json({"error": "Internal Server Error"})
            eprint("[webserver] " + req.method + " " + req.path + ": " + type(e).__name__ + ": " + str(e))
            return false

def _guarded(mws, handler):
    def run(req, res):
        for mw in mws:
            if not _run_middleware(mw, req, res):
                return
        if handler != none:
            handler(req, res)
    return run

# ─── Middleware ───────────────────────────────────────────────────────────────

class LoggingMiddleware:
    # One line per request, Common Log Format-like, to `out` (print by default).
    def __init__(self, out=none):
        self.out = out
        self.count = 0

    def handle(self, req, res):
        self.count = self.count + 1
        var line = req.remote_addr + " - [" + time_strftime("%d/%b/%Y:%H:%M:%S", time_localtime()) + "] \"" + req.method + " " + req.path + "\""
        if self.out != none:
            self.out(line)
        else:
            print line
        return true

class CorsMiddleware:
    # Access-Control-* headers; a preflight (OPTIONS with
    # Access-Control-Request-Method) is answered 204 here.
    def __init__(self, origin, methods="GET, POST, PUT, PATCH, DELETE, OPTIONS", headers="Content-Type, Authorization", max_age=600, credentials=false):
        self.origin = origin
        self.methods = methods
        self.allow_headers = headers
        self.max_age = max_age
        self.credentials = credentials

    def handle(self, req, res):
        var origin = self.origin
        if isinstance(origin, "list"):
            var o = req.header("origin")
            if not (o in origin):
                return true
            origin = o
            res.set_header("Vary", "Origin")
        res.set_header("Access-Control-Allow-Origin", origin)
        res.set_header("Access-Control-Allow-Methods", self.methods)
        res.set_header("Access-Control-Allow-Headers", self.allow_headers)
        if self.credentials:
            res.set_header("Access-Control-Allow-Credentials", "true")
        if req.method == "OPTIONS" and req.header("access-control-request-method") != "":
            res.set_header("Access-Control-Max-Age", str(self.max_age))
            res.status = 204
            res.send("")
            return false
        return true

class RateLimitMiddleware:
    # At most max_req requests per window_sec per client address (a sliding
    # window); over it: 429 with Retry-After, and the handler does not run.
    def __init__(self, max_req, window_sec, key_fn=none):
        self.max_req = max_req
        self.window = window_sec
        self.clients = {}
        self.key_fn = key_fn
        self._lock = threading.Lock()

    def handle(self, req, res):
        var ip = req.remote_addr
        if self.key_fn != none:
            ip = self.key_fn(req)
        if ip == none or ip == "":
            ip = "unknown"
        var now = monotonic()
        var retry_after = 0
        with self._lock:
            var stamps = self.clients.get(ip, [])
            stamps = [t for t in stamps if t > now - self.window]
            if len(stamps) >= self.max_req:
                retry_after = int(stamps[0] + self.window - now) + 1
                self.clients[ip] = stamps
            else:
                stamps.append(now)
                self.clients[ip] = stamps
        if retry_after > 0:
            res.set_header("Retry-After", str(retry_after))
            res.set_status(429).send_json({"error": "Too many requests"})
            return false
        return true

def _b64url(data):
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")

def _b64url_decode(text):
    var pad = (4 - len(text) % 4) % 4
    return base64.urlsafe_b64decode((text + "=" * pad).encode("ascii"))

class AuthMiddleware:
    # Bearer tokens signed with the secret: make_token(claims, ttl) gives
    # "<base64url JSON claims>.<base64url HMAC-SHA256>"; a request without a
    # valid, unexpired one gets 401. req.user is the claims. Paths in
    # `public` pass without a token.
    def __init__(self, secret, public=none, verify_fn=none):
        self.secret = secret
        self.public = public
        if public == none:
            self.public = []
        self.verify_fn = verify_fn

    def _sig(self, payload):
        return _b64url(hmac.new(self.secret.encode("utf-8"), payload.encode("ascii"), hashlib.sha256).digest())

    def make_token(self, claims, ttl=3600):
        var c = {}
        for k in claims:
            c[k] = claims[k]
        if ttl != none:
            c["exp"] = int(time_now()) + ttl
        var payload = _b64url(json_encode(c).encode("utf-8"))
        return payload + "." + self._sig(payload)

    def verify(self, token):
        # the claims of a valid token, else none
        if self.verify_fn != none:
            return self.verify_fn(token)
        var dot = token.rfind(".")
        if dot <= 0:
            return none
        var payload = token[0:dot]
        if not hmac.compare_digest(token[dot + 1:], self._sig(payload)):
            return none
        var claims = none
        try:
            claims = json_decode(_b64url_decode(payload).decode("utf-8"))
        except Exception:
            return none
        if "exp" in claims and claims["exp"] < time_now():
            return none
        return claims

    def handle(self, req, res):
        for p in self.public:
            if req.path == p or (p.endswith("*") and req.path.startswith(p[0:len(p) - 1])):
                return true
        var token = req.bearer_token()
        var claims = none
        if token != "":
            claims = self.verify(token)
        if claims == none:
            res.unauthorized()
            return false
        req.user = claims
        return true

class BodyParserMiddleware:
    # req.parsed_json for JSON bodies (400 when it does not parse), req.form
    # for form bodies.
    def handle(self, req, res):
        if req.is_json() and req.body != "":
            try:
                req.parsed_json = json_decode(req.body)
            except Exception:
                res.status = 400
                res.send_json({"error": "invalid JSON body"})
                return false
        elif req.is_form():
            req.form_value("")
        return true

class StaticFilesMiddleware:
    # Files under root_dir for paths under prefix. ".." and absolute parts
    # never leave root_dir; index.html for a folder.
    def __init__(self, prefix, root_dir):
        self.prefix = prefix
        self.root_dir = root_dir
        self.mime = {}
        self.mime[".html"] = "text/html"
        self.mime[".css"]  = "text/css"
        self.mime[".js"]   = "application/javascript"
        self.mime[".json"] = "application/json"
        self.mime[".png"]  = "image/png"
        self.mime[".jpg"]  = "image/jpeg"
        self.mime[".ico"]  = "image/x-icon"
        self.mime[".svg"]  = "image/svg+xml"
        self.mime[".txt"]  = "text/plain"
        self.mime[".woff2"]= "font/woff2"

    def resolve(self, path):
        # the file for a request path, or none
        if not string_startswith(path, self.prefix):
            return none
        var rel = path[len(self.prefix):]
        var parts = []
        for w in rel.replace("\\", "/").split("/"):
            if w == "" or w == ".":
                continue
            if w == ".." or (len(w) >= 2 and w[1] == ":"):
                return none
            parts.append(w)
        var fp = self.root_dir
        for w in parts:
            fp = os_path_join(fp, w)
        if os_isdir(fp):
            fp = os_path_join(fp, "index.html")
        if not os_isfile(fp):
            return none
        return fp

    def handle(self, req, res):
        if req.method != "GET" and req.method != "HEAD":
            return true
        var fp = self.resolve(req.path)
        if fp == none:
            return true
        var dot = fp.rfind(".")
        var mime = none
        if dot >= 0:
            mime = self.mime.get(fp[dot:].lower())
        res.send_file(fp, mime, req)
        return false

# ─── Session Store ────────────────────────────────────────────────────────────

class Session:
    def __init__(self, sid):
        self.sid = sid
        self.data = {}
        self.created_at = time_now()
        self.accessed_at = time_now()
        self.modified = false

    def set(self, key, value):
        self.data[key] = value
        self.accessed_at = time_now()
        self.modified = true

    def get(self, key, default=none):
        return self.data.get(key, default)

    def delete(self, key):
        if key in self.data:
            del self.data[key]
            self.modified = true

    def clear(self):
        self.data = {}
        self.modified = true

    def is_expired(self, ttl_seconds):
        return time_now() - self.accessed_at > ttl_seconds

class SessionStore:
    # Sessions by id; ids are 128 random bits ("sess_" + 32 hex digits).
    def __init__(self, ttl_seconds):
        self.sessions = {}
        self.ttl = ttl_seconds
        self._counter = 0
        self._lock = threading.Lock()

    def create(self):
        var sid = "sess_" + os_urandom(16).hex()
        with self._lock:
            self._counter = self._counter + 1
            self.sessions[sid] = Session(sid)
        return sid

    def get(self, sid):
        if sid == none:
            return none
        with self._lock:
            var s = self.sessions.get(sid)
            if s == none:
                return none
            if s.is_expired(self.ttl):
                del self.sessions[sid]
                return none
            s.accessed_at = time_now()
            return s

    def destroy(self, sid):
        with self._lock:
            if sid in self.sessions:
                del self.sessions[sid]

    def cleanup(self):
        with self._lock:
            for sid in list(self.sessions.keys()):
                if self.sessions[sid].is_expired(self.ttl):
                    del self.sessions[sid]

    def count(self):
        return len(self.sessions)

class SessionMiddleware:
    # req.session from the cookie (a new session when there is none or it
    # expired); the cookie is HttpOnly and SameSite=Lax.
    def __init__(self, store, cookie_name="sid", secure=false):
        self.store = store
        self.cookie_name = cookie_name
        self.secure = secure

    def handle(self, req, res):
        var s = self.store.get(req.cookie(self.cookie_name))
        if s == none:
            s = self.store.get(self.store.create())
            res.set_cookie(self.cookie_name, s.sid, "/", -1, true, self.secure)
        req.session = s
        return true

# ─── HTTP Server ──────────────────────────────────────────────────────────────

class _WebBridge(http.server.BaseHTTPRequestHandler):
    # Hands every request to its server's app (an HttpServer): self.server.app.
    protocol_version = "HTTP/1.1"
    server_version = "Nython/0.2.1"

    def log_message(self, format, *args):
        pass

    def _dispatch(self):
        var app = self.server.app
        var n = 0
        var cl = self.headers.get("Content-Length")
        if cl != none and cl.strip().isdigit():
            n = int(cl.strip())
        if n > app.max_body:
            self.send_error(413)
            self.close_connection = true
            return
        var body = b""
        if n > 0:
            body = self.rfile.read(n)
        var hdrs = {}
        for kv in self.headers.items():
            hdrs[kv[0]] = kv[1]
        var req = Request()
        req._fill(self.command, self.path, hdrs, body, str(self.client_address[0]))
        req.version = self.request_version
        var res = ResponseWriter(none, self.wfile, self.command == "HEAD", not self.close_connection)
        app.router.handle(req, res)
        if not res._sent:
            res.not_found()
        app.requests_served = app.requests_served + 1
        if app.on_request != none:
            app.on_request(req, res)

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_PUT(self):
        self._dispatch()

    def do_PATCH(self):
        self._dispatch()

    def do_DELETE(self):
        self._dispatch()

    def do_OPTIONS(self):
        self._dispatch()

class HttpServer:
    def __init__(self, host, port, ssl_context=none):
        self.host = host
        self.port = port
        self.router = Router()
        self.running = false
        self.server_fd = -1
        self.sessions = SessionStore(3600)
        self.ssl_context = ssl_context
        self.max_body = 10485760
        self.requests_served = 0
        self.on_request = none
        self._httpd = none
        self._thread = none

    def get(self, path, handler):
        self.router.get(path, handler)
        return self

    def post(self, path, handler):
        self.router.post(path, handler)
        return self

    def put(self, path, handler):
        self.router.put(path, handler)
        return self

    def patch(self, path, handler):
        self.router.patch(path, handler)
        return self

    def delete(self, path, handler):
        self.router.delete(path, handler)
        return self

    def use(self, mw):
        self.router.use(mw)
        return self

    def mount(self, group):
        self.router.mount(group)
        return self

    def static(self, prefix, root_dir):
        self.router.use(StaticFilesMiddleware(prefix, root_dir))
        return self

    def _handle_connection(self, client_fd):
        # one request from a connected socket (or a legacy handle), answered
        var raw = none
        if isinstance(client_fd, "int"):
            raw = tcp_recv(client_fd, 65536)
        else:
            raw = client_fd.recv(65536).decode("utf-8", "replace")
        if raw == none or len(raw) == 0:
            return
        var req = Request(raw, client_fd)
        var res = ResponseWriter(client_fd)
        self.router.handle(req, res)
        if res._sent == false:
            res.not_found()

    def bind(self):
        if self._httpd == none:
            self._httpd = http.server.ThreadingHTTPServer((self.host, self.port), _WebBridge)
            self._httpd.app = self
            if self.ssl_context != none:
                self._httpd.socket = self.ssl_context.wrap_socket(self._httpd.socket, server_side=true)
            self.port = self._httpd.server_address[1]
            self.server_fd = self._httpd.socket.fileno()
        return self

    def listen(self, quiet=false):
        try:
            self.bind()
        except OSError as e:
            print "ERROR: Cannot start server on " + self.host + ":" + str(self.port) + ": " + str(e)
            return false
        self.running = true
        if not quiet:
            var scheme = "http"
            if self.ssl_context != none:
                scheme = "https"
            print "Server running on " + scheme + "://" + self.host + ":" + str(self.port)
        try:
            self._httpd.serve_forever(0.1)
        finally:
            self.running = false
        return true

    def start(self):
        # listen() on a thread of its own; returns once the server is bound.
        self.bind()
        self._thread = threading.Thread(target=self.listen, args=(true,), daemon=true)
        self._thread.start()
        return self

    def url(self, path="/"):
        var scheme = "http"
        if self.ssl_context != none:
            scheme = "https"
        return scheme + "://" + self.host + ":" + str(self.port) + path

    def stop(self):
        self.running = false
        if self._httpd != none:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = none
        if self._thread != none and self._thread.ident != threading.get_ident():
            self._thread.join(5)
            self._thread = none

# ─── WebSocket Server ─────────────────────────────────────────────────────────

class WsConnection:
    def __init__(self, fd, id):
        self.fd = fd                 # the websocket connection (lib/websocket.ny)
        self.id = id
        self.alive = true
        self.data = {}
        self.path = "/"
        if fd != none and hasattr(fd, "request") and fd.request != none:
            self.path = fd.request.path

    def send(self, msg):
        if not self.alive or self.fd == none:
            return false
        try:
            self.fd.send(msg)
            return true
        except (websocket.ConnectionClosed, OSError):
            self.alive = false
            return false

    def close(self, code=1000, reason=""):
        if self.alive:
            self.alive = false
            if self.fd != none:
                self.fd.close(code, reason)

class WsServer:
    # RFC 6455 WebSockets with callbacks: on_connect(conn),
    # on_message(conn, message), on_close(conn). listen() blocks; start()
    # serves on a thread.
    def __init__(self, host, port, ssl_context=none, subprotocols=none):
        self.host = host
        self.port = port
        self.connections = {}
        self.conn_count = 0
        self.on_connect_handler = none
        self.on_message_handler = none
        self.on_close_handler = none
        self.ssl_context = ssl_context
        self.subprotocols = subprotocols
        self._server = none
        self._thread = none
        self._lock = threading.Lock()

    def on_connect(self, fn):
        self.on_connect_handler = fn

    def on_message(self, fn):
        self.on_message_handler = fn

    def on_close(self, fn):
        self.on_close_handler = fn

    def broadcast(self, msg, exclude=none):
        var conns = []
        with self._lock:
            conns = list(self.connections.values())
        var n = 0
        for c in conns:
            if c.alive and c is not exclude and c.send(msg):
                n = n + 1
        return n

    def _handle(self, ws):
        var conn = none
        with self._lock:
            self.conn_count = self.conn_count + 1
            conn = WsConnection(ws, self.conn_count)
            self.connections[str(conn.id)] = conn
        try:
            if self.on_connect_handler != none:
                self.on_connect_handler(conn)
            for msg in ws:
                if self.on_message_handler != none:
                    self.on_message_handler(conn, msg)
        except websocket.ConnectionClosed:
            pass
        finally:
            conn.alive = false
            with self._lock:
                if str(conn.id) in self.connections:
                    del self.connections[str(conn.id)]
            if self.on_close_handler != none:
                self.on_close_handler(conn)

    def bind(self):
        if self._server == none:
            self._server = websocket.serve(self._handle, self.host, self.port, ssl=self.ssl_context, subprotocols=self.subprotocols)
            self.port = self._server.port
        return self

    def listen(self, quiet=false):
        try:
            self.bind()
        except OSError:
            return false
        if not quiet:
            print "WsServer on ws://" + self.host + ":" + str(self.port)
        self._server.serve_forever()
        return true

    def start(self):
        self.bind()
        self._thread = threading.Thread(target=self.listen, args=(true,), daemon=true)
        self._thread.start()
        return self

    def stop(self):
        if self._server != none:
            self._server.shutdown()
            self._server = none
        if self._thread != none and self._thread.ident != threading.get_ident():
            self._thread.join(5)
            self._thread = none

# ─── HTTP API Builder ─────────────────────────────────────────────────────────

class ApiBuilder:
    def __init__(self, prefix):
        self.prefix = prefix
        self.routes = []
        self.route_count = 0

    def _add(self, method, path, handler):
        self.routes.append([method, self.prefix + path, handler])
        self.route_count = self.route_count + 1

    def get(self, path, handler):
        self._add("GET", path, handler)
        return self

    def post(self, path, handler):
        self._add("POST", path, handler)
        return self

    def put(self, path, handler):
        self._add("PUT", path, handler)
        return self

    def delete_route(self, path, handler):
        self._add("DELETE", path, handler)
        return self

    def patch(self, path, handler):
        self._add("PATCH", path, handler)
        return self

    def get_routes(self):
        return self.routes

    def mount_to(self, router):
        for r in self.routes:
            router.add(r[0], r[1], r[2])
        return router


# ─── RequestValidator ─────────────────────────────────────────────────────────

class ValidationRule:
    def __init__(self, field, rule_type, value, message):
        self.field = field
        self.rule_type = rule_type
        self.value = value
        self.message = message


class RequestValidator:
    def __init__(self):
        self.rules = []
        self.rule_count = 0
        self.errors = []
        self.error_count = 0

    def _rule(self, field, rule_type, value, message):
        self.rules.append(ValidationRule(field, rule_type, value, message))
        self.rule_count = self.rule_count + 1
        return self

    def required(self, field):
        return self._rule(field, "required", "", field + " is required")

    def min_length(self, field, min_len):
        return self._rule(field, "min_length", min_len, field + " must be at least " + str(min_len) + " characters")

    def max_length(self, field, max_len):
        return self._rule(field, "max_length", max_len, field + " must be at most " + str(max_len) + " characters")

    def min_value(self, field, min_v):
        return self._rule(field, "min_value", min_v, field + " must be at least " + str(min_v))

    def max_value(self, field, max_v):
        return self._rule(field, "max_value", max_v, field + " must be at most " + str(max_v))

    def pattern(self, field, regex_pat, msg):
        return self._rule(field, "pattern", regex_pat, msg)

    def email(self, field, msg=none):
        if msg == none:
            msg = field + " must be an email address"
        return self._rule(field, "pattern", "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", msg)

    def one_of(self, field, choices, msg=none):
        if msg == none:
            msg = field + " must be one of " + ", ".join([str(c) for c in choices])
        return self._rule(field, "one_of", choices, msg)

    def custom(self, field, fn, msg):
        return self._rule(field, "custom", fn, msg)

    def _number(self, v):
        try:
            return float(v)
        except Exception:
            return none

    def validate(self, data):
        self.errors = []
        self.error_count = 0
        for rule in self.rules:
            var val = data.get(rule.field)
            var failed = false
            var present = val != none and str(val) != ""
            if rule.rule_type == "required":
                failed = not present
            elif rule.rule_type == "min_length":
                failed = val == none or len(str(val)) < int(rule.value)
            elif rule.rule_type == "max_length":
                failed = val != none and len(str(val)) > int(rule.value)
            elif rule.rule_type == "min_value":
                var n = self._number(val)
                failed = n == none or n < float(rule.value)
            elif rule.rule_type == "max_value":
                var n2 = self._number(val)
                failed = present and (n2 == none or n2 > float(rule.value))
            elif rule.rule_type == "pattern":
                failed = present and not re_test(rule.value, str(val))
            elif rule.rule_type == "one_of":
                failed = present and not (val in rule.value)
            elif rule.rule_type == "custom":
                failed = not rule.value(val)
            if failed:
                self.errors.append({"field": rule.field, "message": rule.message})
                self.error_count = self.error_count + 1
        return self.error_count == 0

    def is_valid(self):
        return self.error_count == 0

    def first_error(self):
        if self.error_count == 0:
            return ""
        return self.errors[0]["message"]

    def all_errors(self):
        return self.errors


# ─── Template ────────────────────────────────────────────────────────────────

def html_escape(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#x27;")

class Template:
    # {{name}} (HTML-escaped), {{{name}}} (raw), {{a.b}} (nested),
    # {{#list}}...{{/list}} (repeated per item; an item map's keys and
    # {{.}} for the item itself; a true value shows the block once),
    # {{^name}}...{{/name}} (shown when name is missing/false/empty),
    # {{> partial}}.
    def __init__(self, tmpl, escape=false):
        self.tmpl = tmpl
        self.partials = {}
        self.escape = escape

    def register_partial(self, name, partial_tmpl):
        self.partials[name] = partial_tmpl
        return self

    def set(self, tmpl):
        self.tmpl = tmpl
        return self

    def _lookup(self, stack, name):
        if name == ".":
            return stack[len(stack) - 1]
        var parts = name.split(".")
        var i = len(stack) - 1
        while i >= 0:
            var ctx = stack[i]
            if isinstance(ctx, "map") and parts[0] in ctx:
                var v = ctx[parts[0]]
                for p in parts[1:]:
                    if isinstance(v, "map") and p in v:
                        v = v[p]
                    else:
                        return none
                return v
            i = i - 1
        return none

    def _truthy(self, v):
        if v == none or v == false:
            return false
        if (isinstance(v, "list") or isinstance(v, "str") or isinstance(v, "map")) and len(v) == 0:
            return false
        return true

    def _render(self, text, stack, depth):
        if depth > 20:
            return ""
        var out = []
        var i = 0
        while true:
            var o = text.find("{{", i)
            if o < 0:
                out.append(text[i:])
                break
            out.append(text[i:o])
            var triple = text[o:o + 3] == "{{{"
            var close = "}}"
            if triple:
                close = "}}}"
            var c = text.find(close, o + len(close))
            if c < 0:
                out.append(text[o:])
                break
            var tag = text[o + len(close):c].strip()
            i = c + len(close)
            if triple:
                var rv = self._lookup(stack, tag)
                if rv != none:
                    out.append(str(rv))
                continue
            if tag.startswith("#") or tag.startswith("^"):
                var name = tag[1:].strip()
                var end_tag = "{{/" + name + "}}"
                var e = text.find(end_tag, i)
                if e < 0:
                    continue
                var inner = text[i:e]
                i = e + len(end_tag)
                var v = self._lookup(stack, name)
                if tag.startswith("^"):
                    if not self._truthy(v):
                        out.append(self._render(inner, stack, depth + 1))
                elif isinstance(v, "list"):
                    for item in v:
                        out.append(self._render(inner, stack + [item], depth + 1))
                elif self._truthy(v):
                    out.append(self._render(inner, stack + [v], depth + 1))
                continue
            if tag.startswith(">"):
                var pn = tag[1:].strip()
                if pn in self.partials:
                    out.append(self._render(self.partials[pn], stack, depth + 1))
                continue
            if tag.startswith("!"):
                continue
            var val = self._lookup(stack, tag)
            if val == none:
                out.append("{{" + tag + "}}")
            elif self.escape:
                out.append(html_escape(val))
            else:
                out.append(str(val))
        return "".join(out)

    def render(self, data):
        return self._render(self.tmpl, [data], 0)

    def render_list(self, items, item_tmpl):
        var t = Template(item_tmpl, self.escape)
        t.partials = self.partials
        return "".join([t.render(item) for item in items])


# ─── ErrorHandler ─────────────────────────────────────────────────────────────

class HttpError:
    def __init__(self, status, code, message):
        self.status = status
        self.code = code
        self.message = message
        self.details = none


class ErrorHandler:
    def __init__(self):
        self.handlers = {}
        self.default_format = "json"
        self.log_errors = true

    def register(self, status_code, handler_fn):
        self.handlers[str(status_code)] = handler_fn
        return self

    def not_found(self, handler_fn):
        return self.register(404, handler_fn)

    def unauthorized(self, handler_fn):
        return self.register(401, handler_fn)

    def forbidden(self, handler_fn):
        return self.register(403, handler_fn)

    def server_error(self, handler_fn):
        return self.register(500, handler_fn)

    def handle(self, error):
        var h = self.handlers.get(str(error.status))
        if h != none:
            return h(error)
        if self.default_format == "json":
            var body = {}
            body["error"] = error.code
            body["message"] = error.message
            body["status"] = error.status
            if error.details != none:
                body["details"] = error.details
            return json_encode(body)
        return str(error.status) + " " + error.message

    def respond(self, res, error):
        # writes the error to a ResponseWriter
        res.status = error.status
        var out = self.handle(error)
        if self.default_format == "json" and not (str(error.status) in self.handlers):
            res.set_header("Content-Type", "application/json")
        res.send(out)

    def make_error(self, status, code, message):
        return HttpError(status, code, message)

    def not_found_error(self, path):
        return HttpError(404, "NOT_FOUND", "Resource not found: " + path)

    def auth_error(self):
        return HttpError(401, "UNAUTHORIZED", "Authentication required")

    def forbidden_error(self):
        return HttpError(403, "FORBIDDEN", "Access denied")

    def server_error_obj(self, message):
        return HttpError(500, "INTERNAL_ERROR", message)

    def bad_request(self, message):
        return HttpError(400, "BAD_REQUEST", message)


# ─── HealthCheck ──────────────────────────────────────────────────────────────

class HealthCheckResult:
    def __init__(self, name, healthy, message, latency_ms):
        self.name = name
        self.healthy = healthy
        self.message = message
        self.latency_ms = latency_ms
        self.timestamp = time_now()


class HealthCheck:
    # Named checks (a function returning true when healthy); an exception
    # counts as unhealthy, with its message.
    def __init__(self):
        self.checks = []
        self.check_count = 0
        self.last_results = []
        self.last_run = 0.0

    def add(self, name, check_fn):
        self.checks.append({"name": name, "fn": check_fn})
        self.check_count = self.check_count + 1
        return self

    def _run(self, check):
        var start = monotonic()
        var ok = false
        var msg = ""
        try:
            ok = check["fn"]() == true
            msg = "healthy" if ok else "unhealthy"
        except Exception as e:
            ok = false
            msg = type(e).__name__ + ": " + str(e)
        return HealthCheckResult(check["name"], ok, msg, (monotonic() - start) * 1000.0)

    def run_all(self):
        self.last_results = []
        self.last_run = time_now()
        for check in self.checks:
            self.last_results.append(self._run(check))
        return self.last_results

    def is_healthy(self):
        for r in self.last_results:
            if not r.healthy:
                return false
        return true

    def to_dict(self):
        var result = {}
        result["status"] = "healthy" if self.is_healthy() else "unhealthy"
        result["timestamp"] = self.last_run
        result["check_count"] = self.check_count
        result["checks"] = [{"name": r.name, "healthy": r.healthy, "message": r.message, "latency_ms": r.latency_ms} for r in self.last_results]
        return result

    def run_check(self, name):
        for check in self.checks:
            if check["name"] == name:
                return self._run(check)
        return none

    def handler(self):
        # a route handler: 200 with the report when healthy, else 503
        def h(req, res):
            self.run_all()
            res.status = 200 if self.is_healthy() else 503
            res.send_json(self.to_dict())
        return h


# ─── WebhookHandler ───────────────────────────────────────────────────────────

class WebhookHandler:
    # Receives signed webhooks (network.ny's WebhookSender format:
    # "t=<unix>,v1=<hex HMAC-SHA256 of '<t>.<body>'>", or GitHub's
    # "sha256=<hex HMAC-SHA256 of body>"). handle() refuses a delivery whose
    # signature does not verify (counted in failed).
    def __init__(self, secret, tolerance=300):
        self.secret = secret
        self.tolerance = tolerance
        self.handlers = {}
        self.received = 0
        self.failed = 0
        self.log = []
        self.log_size = 0
        self.max_log = 100

    def on(self, event_type, handler_fn):
        self.handlers[event_type] = handler_fn
        return self

    def _body(self, payload):
        if isinstance(payload, "str"):
            return payload
        if isinstance(payload, "bytes"):
            return payload.decode("utf-8")
        return json_encode(payload)

    def sign(self, payload, timestamp=none):
        if timestamp == none:
            timestamp = int(time_now())
        var body = self._body(payload)
        return "t=" + str(timestamp) + ",v1=" + hmac.new(self.secret.encode("utf-8"), (str(timestamp) + "." + body).encode("utf-8"), hashlib.sha256).hexdigest()

    def verify_signature(self, payload, signature):
        if self.secret == "":
            return true
        if signature == none or signature == "":
            return false
        var body = self._body(payload)
        if signature.startswith("sha256="):
            var mac = hmac.new(self.secret.encode("utf-8"), body.encode("utf-8"), hashlib.sha256).hexdigest()
            return hmac.compare_digest(signature[7:], mac)
        var t = none
        var sigs = []
        for part in signature.split(","):
            var kv = part.strip().split("=", 1)
            if len(kv) == 2 and kv[0] == "t" and kv[1].isdigit():
                t = int(kv[1])
            elif len(kv) == 2 and kv[0] == "v1":
                sigs.append(kv[1])
        if t == none or len(sigs) == 0:
            return false
        if self.tolerance != none and abs(time_now() - t) > self.tolerance:
            return false
        var expected = hmac.new(self.secret.encode("utf-8"), (str(t) + "." + body).encode("utf-8"), hashlib.sha256).hexdigest()
        for s in sigs:
            if hmac.compare_digest(s, expected):
                return true
        return false

    def handle(self, event_type, payload, signature):
        if not self.verify_signature(payload, signature):
            self.failed = self.failed + 1
            return false
        self.received = self.received + 1
        if self.log_size < self.max_log:
            self.log.append({"event": event_type, "at": time_now()})
            self.log_size = self.log_size + 1
        var h = self.handlers.get(event_type)
        if h != none:
            h(payload)
            return true
        var wildcard = self.handlers.get("*")
        if wildcard != none:
            wildcard(event_type, payload)
        return true

    def route(self):
        # a route handler for POSTed deliveries (X-Webhook-Event /
        # X-Webhook-Signature, or GitHub's X-GitHub-Event / X-Hub-Signature-256)
        def h(req, res):
            var event = req.header("x-webhook-event", req.header("x-github-event", "*"))
            var sig = req.header("x-webhook-signature", req.header("x-hub-signature-256", ""))
            if not self.verify_signature(req.body, sig):
                self.failed = self.failed + 1
                res.status = 401
                res.send_json({"error": "invalid signature"})
                return
            var payload = req.body
            try:
                payload = json_decode(req.body)
            except Exception:
                pass
            self.received = self.received + 1
            var fn = self.handlers.get(event)
            if fn != none:
                fn(payload)
            elif self.handlers.get("*") != none:
                self.handlers["*"](event, payload)
            res.send_json({"ok": true})
        return h

    def get_log(self):
        return self.log

    def stats(self):
        var s = {}
        s["received"] = self.received
        s["failed"] = self.failed
        s["log_entries"] = self.log_size
        return s


# ─── Router extensions ────────────────────────────────────────────────────────

class RouteGroup:
    def __init__(self, prefix):
        self.prefix = prefix
        self.routes = []
        self.route_count = 0
        self.middlewares = []
        self.mw_count = 0

    def use(self, middleware):
        self.middlewares.append(middleware)
        self.mw_count = self.mw_count + 1
        return self

    def _add(self, method, path, handler):
        self.routes.append([method, self.prefix + path, handler])
        self.route_count = self.route_count + 1
        return self

    def get(self, path, handler):
        return self._add("GET", path, handler)

    def post(self, path, handler):
        return self._add("POST", path, handler)

    def put(self, path, handler):
        return self._add("PUT", path, handler)

    def patch(self, path, handler):
        return self._add("PATCH", path, handler)

    def delete_route(self, path, handler):
        return self._add("DELETE", path, handler)

    def get_routes(self):
        return self.routes
