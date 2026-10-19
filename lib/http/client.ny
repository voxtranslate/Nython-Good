# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/http/client.ny - Python's http.client (HTTP/1.1, RFC 9112; round 77).
#
#     import http.client
#     c = http.client.HTTPSConnection("example.org")
#     c.request("GET", "/", headers={"Accept": "text/html"})
#     r = c.getresponse()
#     print(r.status, r.reason, r.getheader("Content-Type"), r.read()[:80])
#
# Bodies: Content-Length, chunked (decoded), or read to the close; HEAD,
# 1xx/204/304 have none. A connection is kept alive between requests while
# the server allows it; a kept-alive connection the server closed meanwhile
# is reopened once, transparently. set_tunnel() goes through an HTTP proxy
# (CONNECT). HTTPS uses lib/ssl.ny (certificates verified by default).
#
# HTTP/2 (round 86, Nython's, opt-in): HTTPSConnection(..., http2=True)
# offers ALPN ["h2", "http/1.1"] and speaks HTTP/2 (lib/h2/sync.ny) when the
# server selects "h2", HTTP/1.1 otherwise; HTTPConnection(...,
# http2="prior_knowledge") speaks h2c from the first byte (RFC 9113 3.3).
# The API stays http.client's: request()/putrequest()... and getresponse(),
# whose HTTP2Response has status, reason, version (20), headers/msg,
# getheader(s), read(amt)/read1/readline/readinto/iteration, and .trailers;
# conn.http_version is "HTTP/2" or "HTTP/1.1" once connected. Requests on
# one HTTP/2 connection reuse it, one at a time as http.client allows (h2.sync
# multiplexes for callers that want more). Connection-specific header fields
# are dropped and Host becomes :authority.
import socket
import http

HTTP_PORT = 80
HTTPS_PORT = 443
responses = http.responses
_MAXLINE = 65536
_MAXHEADERS = 100

class HTTPException(Exception):
    pass

class NotConnected(HTTPException):
    pass

class InvalidURL(HTTPException):
    pass

class UnknownProtocol(HTTPException):
    pass

class UnknownTransferEncoding(HTTPException):
    pass

class ImproperConnectionState(HTTPException):
    pass

class CannotSendRequest(ImproperConnectionState):
    pass

class CannotSendHeader(ImproperConnectionState):
    pass

class ResponseNotReady(ImproperConnectionState):
    pass

class IncompleteRead(HTTPException):
    def __init__(self, partial, expected=None):
        self.partial = partial
        self.expected = expected
        var tail = ""
        if expected != None:
            tail = ", " + str(expected) + " more expected"
        super().__init__("IncompleteRead(" + str(len(partial)) + " bytes read" + tail + ")")

class BadStatusLine(HTTPException):
    def __init__(self, line):
        self.line = line
        super().__init__(repr(line))

class LineTooLong(HTTPException):
    def __init__(self, line_type):
        super().__init__("got more than " + str(_MAXLINE) + " bytes when reading " + line_type)

class RemoteDisconnected(ConnectionResetError, BadStatusLine):
    def __init__(self, msg):
        self.line = msg
        ConnectionResetError.__init__(self, msg)

# ─── reading ────────────────────────────────────────────────────────────────

class _Reader(socket.SocketIO):
    # Buffered binary reads over a socket (socket.SocketIO): lines, exact
    # counts, what is there, everything.
    def __init__(self, sock):
        socket.SocketIO.__init__(self, sock, "rb")

    def read_some(self, n):
        return self.read1(n)

    def read_all(self):
        return self.read(-1)

# ─── headers ────────────────────────────────────────────────────────────────

class HTTPMessage:
    # The header fields, in order; names are looked up case-insensitively.
    def __init__(self):
        self._fields = []

    def add(self, name, value):
        self._fields.append((name, value))

    def get(self, name, failobj=None):
        var n = name.lower()
        for f in self._fields:
            if f[0].lower() == n:
                return f[1]
        return failobj

    def get_all(self, name, failobj=None):
        var n = name.lower()
        var out = []
        for f in self._fields:
            if f[0].lower() == n:
                out.append(f[1])
        if len(out) == 0:
            return failobj
        return out

    def __getitem__(self, name):
        return self.get(name)

    def __setitem__(self, name, value):
        self._fields.append((name, value))

    def __delitem__(self, name):
        var n = name.lower()
        self._fields = [f for f in self._fields if f[0].lower() != n]

    def __contains__(self, name):
        return self.get(name) != None

    def __iter__(self):
        return iter([f[0] for f in self._fields])

    def __len__(self):
        return len(self._fields)

    def keys(self):
        return [f[0] for f in self._fields]

    def values(self):
        return [f[1] for f in self._fields]

    def items(self):
        return list(self._fields)

    def get_content_type(self):
        var ct = self.get("Content-Type", "text/plain")
        return ct.split(";")[0].strip().lower()

    def get_content_charset(self, failobj=None):
        var ct = self.get("Content-Type", "")
        for part in ct.split(";")[1:]:
            var kv = part.strip().split("=")
            if len(kv) == 2 and kv[0].strip().lower() == "charset":
                return kv[1].strip().strip("\"").lower()
        return failobj

    def as_string(self):
        var out = []
        for f in self._fields:
            out.append(f[0] + ": " + f[1] + "\n")
        return "".join(out) + "\n"

    def __str__(self):
        return self.as_string()

def parse_headers(fp):
    # Header lines up to the blank line: an HTTPMessage. fp: a reader with
    # readline() (a socket file, _Reader).
    var msg = HTTPMessage()
    var name = None
    var value = ""
    var count = 0
    while True:
        var line = fp.readline(_MAXLINE + 1)
        if len(line) > _MAXLINE:
            raise LineTooLong("header line")
        if isinstance(line, "bytes") or isinstance(line, "bytearray"):
            line = line.decode("iso-8859-1")
        if line == "" or line == "\r\n" or line == "\n":
            break
        count = count + 1
        if count > _MAXHEADERS:
            raise HTTPException("got more than " + str(_MAXHEADERS) + " headers")
        if (line.startswith(" ") or line.startswith("\t")) and name != None:
            value = value + " " + line.strip()
            continue
        if name != None:
            msg.add(name, value)
        var c = line.find(":")
        if c <= 0:
            name = None
            continue
        name = line[0:c].strip()
        value = line[c + 1:].strip()
    if name != None:
        msg.add(name, value)
    return msg

# ─── responses ──────────────────────────────────────────────────────────────

class HTTPResponse:
    def __init__(self, sock, reader=None, method=None, url=None, debuglevel=0):
        self.sock = sock
        self.fp = reader
        if reader == None:
            self.fp = _Reader(sock)
        self._method = method
        self.url = url
        self.debuglevel = debuglevel
        self.headers = None
        self.msg = None
        self.version = 11
        self.status = None
        self.code = None
        self.reason = None
        self.chunked = False
        self.chunk_left = None
        self.length = None
        self.will_close = True
        self._closed = False
        self._done = False
        self._on_done = None        # the connection's: keep it or drop it

    def _read_status(self):
        var line = self.fp.readline(_MAXLINE + 1).decode("iso-8859-1")
        if len(line) > _MAXLINE:
            raise LineTooLong("status line")
        if self.debuglevel > 0:
            print("reply:", repr(line))
        if line == "":
            raise RemoteDisconnected("Remote end closed connection without response")
        var parts = line.strip().split(" ", 2)
        if len(parts) < 2 or not parts[0].startswith("HTTP/"):
            raise BadStatusLine(line)
        var reason = ""
        if len(parts) > 2:
            reason = parts[2]
        var status = 0
        try:
            status = int(parts[1])
        except ValueError:
            raise BadStatusLine(line)
        if status < 100 or status > 999:
            raise BadStatusLine(line)
        return [parts[0], status, reason]

    def begin(self):
        if self.headers != None:
            return
        var st = None
        while True:
            st = self._read_status()
            if st[1] != 100 and not (st[1] >= 102 and st[1] < 200):
                break
            parse_headers(self.fp)        # an interim response: skip it
        self.status = st[1]
        self.code = st[1]
        self.reason = st[2].strip()
        if st[0] == "HTTP/1.0":
            self.version = 10
        elif st[0].startswith("HTTP/1."):
            self.version = 11
        else:
            raise UnknownProtocol(st[0])
        self.headers = parse_headers(self.fp)
        self.msg = self.headers
        var te = self.headers.get("transfer-encoding")
        if te != None and te.lower().find("chunked") >= 0:
            self.chunked = True
            self.chunk_left = None
        self.will_close = self._check_close()
        self.length = None
        var cl = self.headers.get("content-length")
        if cl != None and not self.chunked:
            try:
                self.length = int(cl)
            except ValueError:
                self.length = None
            if self.length != None and self.length < 0:
                self.length = None
        if self.status == 204 or self.status == 304 or (self.status >= 100 and self.status < 200) or self._method == "HEAD":
            self.length = 0
        if not self.will_close and not self.chunked and self.length == None:
            self.will_close = True
        if self.length == 0:
            self._finish()

    def _check_close(self):
        var conn = self.headers.get("connection")
        if self.version == 11:
            return conn != None and conn.lower().find("close") >= 0
        if self.headers.get("keep-alive") != None:
            return False
        if conn != None and conn.lower().find("keep-alive") >= 0:
            return False
        return True

    def _finish(self):
        if self._done:
            return
        self._done = True
        if self._on_done != None:
            self._on_done(self)

    def _read_chunk_size(self):
        var line = self.fp.readline(_MAXLINE + 1).decode("iso-8859-1")
        var semi = line.find(";")
        if semi >= 0:
            line = line[0:semi]
        try:
            return int(line.strip(), 16)
        except ValueError:
            raise IncompleteRead(b"")

    def _read_chunked(self, amt=None):
        var parts = []
        var got = 0
        while amt == None or got < amt:
            if self.chunk_left == None or self.chunk_left == 0:
                if self.chunk_left == 0:
                    self.fp.readline()          # CRLF after the chunk
                var n = self._read_chunk_size()
                if n == 0:
                    parse_headers(self.fp)      # trailers
                    self.chunk_left = None
                    self._finish()
                    break
                self.chunk_left = n
            var want = self.chunk_left
            if amt != None:
                want = min(want, amt - got)
            var d = self.fp.read(want)
            if len(d) < want:
                raise IncompleteRead(b"".join(parts) + d)
            parts.append(d)
            got = got + len(d)
            self.chunk_left = self.chunk_left - len(d)
        return b"".join(parts)

    def read(self, amt=None):
        if self._closed or self.headers == None:
            return b""
        if self._done and not self.chunked:
            return b""
        if self.chunked:
            if self._done:
                return b""
            return self._read_chunked(amt)
        if self.length != None:
            var n = self.length
            if amt != None and amt < n:
                n = amt
            var d = self.fp.read(n)
            self.length = self.length - len(d)
            if len(d) < n:
                self._done = True
                raise IncompleteRead(d, self.length)
            if self.length == 0:
                self._finish()
            return d
        # to the close
        var d2 = None
        if amt == None:
            d2 = self.fp.read_all()
            self._finish()
        else:
            d2 = self.fp.read(amt)
            if len(d2) < amt:
                self._finish()
        return d2

    def read1(self, n=-1):
        if n < 0:
            n = 65536
        if self.chunked:
            return self._read_chunked(n)
        if self.length != None:
            n = min(n, self.length)
            if n == 0:
                self._finish()
                return b""
            var d = self.fp.read_some(n)
            self.length = self.length - len(d)
            if self.length == 0:
                self._finish()
            return d
        var d2 = self.fp.read_some(n)
        if len(d2) == 0:
            self._finish()
        return d2

    def readline(self, limit=-1):
        # One line of the body (through b"\n"), at most limit bytes; read
        # from the buffer a line at a time, chunked bodies included.
        if self._closed or self.headers == None or self._done:
            return b""
        if self.chunked:
            var parts = []
            var got = 0
            while True:
                if self.chunk_left == None or self.chunk_left == 0:
                    if self.chunk_left == 0:
                        self.fp.readline()          # CRLF after the chunk
                    var n = self._read_chunk_size()
                    if n == 0:
                        parse_headers(self.fp)
                        self.chunk_left = None
                        self._finish()
                        break
                    self.chunk_left = n
                var want = self.chunk_left
                if limit >= 0:
                    want = min(want, limit - got)
                var piece = self.fp.readline(want)
                if len(piece) == 0:
                    raise IncompleteRead(b"".join(parts))
                parts.append(piece)
                got = got + len(piece)
                self.chunk_left = self.chunk_left - len(piece)
                if piece.endswith(b"\n") or (limit >= 0 and got >= limit):
                    break
            return b"".join(parts)
        if self.length != None:
            if self.length == 0:
                self._finish()
                return b""
            var want2 = self.length
            if limit >= 0:
                want2 = min(limit, self.length)
            var line = self.fp.readline(want2)
            self.length = self.length - len(line)
            if self.length == 0 or len(line) == 0:
                self._finish()
            return line
        var line2 = self.fp.readline(limit)
        if len(line2) == 0:
            self._finish()
        return line2

    def readlines(self):
        var out = []
        var line = self.readline()
        while len(line) > 0:
            out.append(line)
            line = self.readline()
        return out

    def __iter__(self):
        return iter(self.readlines())

    def getheader(self, name, default=None):
        if self.headers == None:
            raise ResponseNotReady()
        var vals = self.headers.get_all(name)
        if vals == None:
            return default
        return ", ".join(vals)

    def getheaders(self):
        if self.headers == None:
            raise ResponseNotReady()
        return self.headers.items()

    def info(self):
        return self.headers

    def geturl(self):
        return self.url

    def getcode(self):
        return self.status

    def fileno(self):
        return self.sock.fileno()

    def isclosed(self):
        return self._closed

    def close(self):
        if self._closed:
            return
        self._closed = True
        if not self._done:
            self.will_close = True
            self._finish()

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return False

    def __repr__(self):
        return "<http.client.HTTPResponse status=" + str(self.status) + ">"

# ─── connections ────────────────────────────────────────────────────────────

class HTTPConnection:
    default_port = HTTP_PORT
    debuglevel = 0

    def __init__(self, host, port=None, timeout=None, source_address=None, blocksize=8192, http2=False):
        self.http2 = http2
        self.http_version = None
        self._h2 = None             # an h2.sync.SyncConnection once HTTP/2 is agreed
        self._h2_req = None         # [method, url, headers, body chunks] being built
        self.timeout = timeout
        self.source_address = source_address
        self.blocksize = blocksize
        self.sock = None
        self._reader = None
        self._buffer = []
        self._state = "idle"
        self._response = None
        self._method = None
        self._tunnel_host = None
        self._tunnel_port = None
        self._tunnel_headers = {}
        self._pending = None        # a response request() already began
        var hp = self._get_hostport(host, port)
        self.host = hp[0]
        self.port = hp[1]

    def _get_hostport(self, host, port):
        if port == None:
            var i = host.rfind(":")
            var j = host.rfind("]")
            if i > j:
                var p = host[i + 1:]
                if p == "":
                    port = self.default_port
                else:
                    try:
                        port = int(p)
                    except ValueError:
                        raise InvalidURL("nonnumeric port: '" + p + "'")
                host = host[0:i]
            else:
                port = self.default_port
        if host.startswith("[") and host.endswith("]"):
            host = host[1:-1]
        return [host, port]

    def set_debuglevel(self, level):
        self.debuglevel = level

    def set_tunnel(self, host, port=None, headers=None):
        if self.sock != None:
            raise RuntimeError("Can't set up tunnel for established connection")
        var hp = self._get_hostport(host, port)
        self._tunnel_host = hp[0]
        self._tunnel_port = hp[1]
        if headers != None:
            self._tunnel_headers = headers

    def _host_header(self, host, port):
        var h = host
        if h.find(":") >= 0:
            h = "[" + h + "]"
        if port == self.default_port:
            return h
        return h + ":" + str(port)

    def _tunnel(self):
        var target = self._host_header(self._tunnel_host, self._tunnel_port)
        if target.find(":") < 0 or target.endswith("]"):
            target = target + ":" + str(self._tunnel_port)
        var lines = ["CONNECT " + target + " HTTP/1.1", "Host: " + target]
        for k in self._tunnel_headers:
            lines.append(k + ": " + str(self._tunnel_headers[k]))
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("iso-8859-1"))
        var r = HTTPResponse(self.sock, _Reader(self.sock), "CONNECT")
        r.begin()
        if r.status != 200:
            self.close()
            raise OSError("Tunnel connection failed: " + str(r.status) + " " + r.reason)

    def connect(self):
        _ny_sys_audit("http.client.connect", self, self.host, self.port)   # round 86: CPython's events
        var h = self.host
        var p = self.port
        self.sock = socket.create_connection((h, p), self.timeout, self.source_address)
        try:
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        if self._tunnel_host != None:
            self._tunnel()
        self._reader = _Reader(self.sock)
        self.http_version = "HTTP/1.1"
        if self.http2 == "prior_knowledge" and self.default_port == HTTP_PORT:
            self._start_h2("http")

    def _start_h2(self, scheme):
        import h2.sync
        var host = self._tunnel_host if self._tunnel_host != None else self.host
        var port = self._tunnel_port if self._tunnel_host != None else self.port
        self._h2 = h2.sync.SyncConnection(self.sock, self._host_header(host, port), scheme)
        self._reader = None
        self.http_version = "HTTP/2"

    def close(self):
        self._state = "idle"
        if self._h2 != None:
            try:
                self._h2.close()
            except Exception:
                pass
            self._h2 = None
        self._h2_req = None
        if self.sock != None:
            self.sock.close()
        self.sock = None
        self._reader = None
        self._response = None
        self._pending = None

    def send(self, data):
        if self.sock == None:
            self.connect()
        if self._h2 != None and self._h2_req != None:
            # HTTP/2: the request body, sent with the request by getresponse()
            if isinstance(data, "str"):
                data = data.encode("iso-8859-1")
            if hasattr(data, "read") or isinstance(data, "bytes") or isinstance(data, "bytearray"):
                self._h2_req[3].append(data)
            else:
                for d in data:
                    self._h2_req[3].append(d)
            return
        if self.debuglevel > 0:
            print("send:", repr(data))
        if isinstance(data, "str"):
            data = data.encode("utf-8")
        if hasattr(data, "read"):
            var chunk = data.read(self.blocksize)
            while len(chunk) > 0:
                if isinstance(chunk, "str"):
                    chunk = chunk.encode("utf-8")
                _ny_sys_audit("http.client.send", self, chunk)
                self.sock.sendall(chunk)
                chunk = data.read(self.blocksize)
            return
        _ny_sys_audit("http.client.send", self, data)
        if isinstance(data, "bytes") or isinstance(data, "bytearray"):
            self.sock.sendall(data)
            return
        for d in data:
            if isinstance(d, "str"):
                d = d.encode("utf-8")
            self.sock.sendall(d)

    def putrequest(self, method, url, skip_host=False, skip_accept_encoding=False):
        if self._response != None and not self._response._done:
            raise CannotSendRequest("Request-sent")
        if self._state != "idle":
            raise CannotSendRequest(self._state)
        self._state = "started"
        self._method = method
        if url == None or url == "":
            url = "/"
        for ch in url:
            if ord(ch) <= 32 or ord(ch) == 127:
                raise InvalidURL("URL can't contain control characters. " + repr(url))
        if self._h2 != None:
            self._h2_req = [method, url, [], []]
            if not skip_accept_encoding:
                self._h2_req[2].append(("accept-encoding", "identity"))
            return
        self._buffer = [method + " " + url + " HTTP/1.1"]
        if not skip_host:
            if self._tunnel_host != None:
                self.putheader("Host", self._host_header(self._tunnel_host, self._tunnel_port))
            else:
                self.putheader("Host", self._host_header(self.host, self.port))
        if not skip_accept_encoding:
            self.putheader("Accept-Encoding", "identity")

    def putheader(self, header, *values):
        if self._state != "started":
            raise CannotSendHeader()
        var vs = []
        for v in values:
            if isinstance(v, "bytes"):
                v = v.decode("iso-8859-1")
            vs.append(str(v))
        if self._h2_req != None:
            self._h2_req[2].append((str(header), ", ".join(vs)))
            return
        var line = str(header) + ": " + "\r\n\t".join(vs)
        if line.find("\n") >= 0 and line.find("\r\n\t") < 0:
            raise ValueError("Invalid header value " + repr(line))
        self._buffer.append(line)

    def endheaders(self, message_body=None, encode_chunked=False):
        if self._state != "started":
            raise CannotSendHeader()
        self._state = "sent"
        if self._h2_req != None:
            # HTTP/2: sent by getresponse() (send() may still add body data)
            if message_body != None:
                self.send(message_body)
            return
        var head = ("\r\n".join(self._buffer) + "\r\n\r\n").encode("iso-8859-1")
        self._buffer = []
        if message_body == None:
            self.send(head)
            return
        if isinstance(message_body, "str"):
            message_body = message_body.encode("utf-8")
        if encode_chunked:
            self.send(head)
            var items = message_body
            if hasattr(message_body, "read"):
                items = []
                var c = message_body.read(self.blocksize)
                while len(c) > 0:
                    items.append(c)
                    c = message_body.read(self.blocksize)
            for chunk in items:
                if isinstance(chunk, "str"):
                    chunk = chunk.encode("utf-8")
                if len(chunk) == 0:
                    continue
                self.send(("%X\r\n" % len(chunk)).encode("ascii") + chunk + b"\r\n")
            self.send(b"0\r\n\r\n")
            return
        if isinstance(message_body, "bytes") or isinstance(message_body, "bytearray"):
            self.send(head + message_body)
            return
        self.send(head)
        self.send(message_body)

    def _body_length(self, body):
        if body == None:
            return None
        if isinstance(body, "str"):
            return len(body.encode("utf-8"))
        if isinstance(body, "bytes") or isinstance(body, "bytearray"):
            return len(body)
        return None

    def request(self, method, url, body=None, headers=None, encode_chunked=False):
        if headers == None:
            headers = {}
        var tries = 0
        while True:
            tries = tries + 1
            var reused = self.sock != None
            try:
                self._send_request(method, url, body, headers, encode_chunked)
                if self._h2 != None:
                    return
                if reused:
                    # The server may have closed an idle kept-alive connection:
                    # find out now (its status line), and retry once on a
                    # fresh connection. getresponse() returns this response.
                    var r = HTTPResponse(self.sock, self._reader, self._method, None, self.debuglevel)
                    r._on_done = self._response_done
                    r.begin()
                    self._pending = r
                return
            except (RemoteDisconnected, BrokenPipeError, ConnectionResetError) as e:
                if not reused or tries > 1 or (body != None and hasattr(body, "read")):
                    raise
                self.close()

    def _send_request(self, method, url, body, headers, encode_chunked):
        if self.sock == None:
            self.connect()
        var names = {}
        for k in headers:
            names[k.lower()] = True
        self.putrequest(method, url, "host" in names, "accept-encoding" in names)
        if body != None and not ("content-length" in names) and not ("transfer-encoding" in names):
            var n = self._body_length(body)
            if n != None:
                self.putheader("Content-Length", str(n))
            else:
                self.putheader("Transfer-Encoding", "chunked")
                encode_chunked = True
        elif body == None and (method == "POST" or method == "PUT" or method == "PATCH") and not ("content-length" in names):
            self.putheader("Content-Length", "0")
        for k in headers:
            self.putheader(k, headers[k])
        self.endheaders(body, encode_chunked)

    def _response_done(self, resp):
        self._state = "idle"
        if resp.will_close:
            if self.sock != None:
                self.sock.close()
            self.sock = None
            self._reader = None

    def getresponse(self):
        if self._h2_req != None:
            return self._h2_response()
        if self._pending != None:
            var p = self._pending
            self._pending = None
            self._response = p
            if not p._done:
                self._state = "response"
            return p
        if self._state != "sent" or self.sock == None:
            raise ResponseNotReady(self._state)
        var r = HTTPResponse(self.sock, self._reader, self._method, None, self.debuglevel)
        r._on_done = self._response_done
        self._response = r
        try:
            r.begin()
        except BaseException:
            self.close()
            raise
        if not r._done:
            self._state = "response"
        return r

    def _h2_response(self):
        var req = self._h2_req
        self._h2_req = None
        if self._state != "sent":
            raise ResponseNotReady(self._state)
        var body = None
        if len(req[3]) > 0:
            body = req[3]
        var r = None
        try:
            var sid = self._h2.request(req[0], req[1], req[2], body)
            r = HTTP2Response(self, sid, req[0])
        except BaseException:
            self.close()
            raise
        self._response = r
        if r._done:
            self._state = "idle"
        else:
            self._state = "response"
        return r

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return False

class HTTP2Response:
    # http.client's HTTPResponse for a stream of an HTTP/2 connection (round 86)
    def __init__(self, conn, sid, method):
        self._conn = conn
        self._h2 = conn._h2
        self.sock = conn.sock
        self.stream_id = sid
        self._method = method
        self.version = 20
        self.debuglevel = 0
        self.will_close = False
        self.chunked = False
        self.url = None
        self._on_done = None
        self._done = False
        self.trailers = None
        var sh = self._h2.response_headers(sid)
        self.status = sh[0]
        self.code = self.status
        self.reason = responses.get(self.status, "")
        self.headers = HTTPMessage()
        for kv in sh[1]:
            self.headers.add(kv[0], kv[1])
        self.msg = self.headers
        self.length = None
        var cl = self.headers.get("content-length")
        if cl != None and cl.isdigit():
            self.length = int(cl)
        if method == "HEAD" or self.status == 204 or self.status == 304:
            self.length = 0
        if self._h2.ended(sid):
            self._finish()

    def _finish(self):
        if self._done:
            return
        self._done = True
        var t = self._h2.trailers(self.stream_id)
        if t != None:
            self.trailers = HTTPMessage()
            for kv in t:
                self.trailers.add(kv[0], kv[1])
        self._h2.release(self.stream_id)
        self._conn._state = "idle"
        if self._on_done != None:
            self._on_done(self)

    def read(self, amt=None):
        if self._done:
            return b""
        var data = self._h2.read(self.stream_id, amt)
        if self.length != None:
            self.length = max(0, self.length - len(data))
        if self._h2.ended(self.stream_id):
            self._finish()
        return data

    def read1(self, n=-1):
        if n == None or n < 0:
            n = 65536
        return self.read(n)

    def readinto(self, b):
        var data = self.read(len(b))
        b[0:len(data)] = data
        return len(data)

    def readline(self, limit=-1):
        var out = b""
        while not self._done:
            var c = self.read(1)
            if c == b"":
                break
            out = out + c
            if c == b"\n" or (limit >= 0 and len(out) >= limit):
                break
        return out

    def readlines(self):
        var out = []
        while True:
            var l = self.readline()
            if l == b"":
                return out
            out.append(l)

    def __iter__(self):
        return iter(self.readlines())

    def getheader(self, name, default=None):
        var v = self.headers.get_all(name)
        if v == None or len(v) == 0:
            return default
        return ", ".join(v)

    def getheaders(self):
        return list(self.headers.items())

    def info(self):
        return self.headers

    def geturl(self):
        return self.url

    def getcode(self):
        return self.status

    def fileno(self):
        return self.sock.fileno()

    def isclosed(self):
        return self._done

    def close(self):
        if not self._done:
            self._done = True
            self._conn._state = "idle"
            if self._on_done != None:
                self._on_done(self)

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return False

    def __repr__(self):
        return "<http.client.HTTP2Response [" + str(self.status) + "] stream " + str(self.stream_id) + ">"

class HTTPSConnection(HTTPConnection):
    default_port = HTTPS_PORT

    def __init__(self, host, port=None, timeout=None, source_address=None, context=None, blocksize=8192, http2=False, **kwargs):
        HTTPConnection.__init__(self, host, port, timeout, source_address, blocksize, http2)
        if context == None:
            import ssl
            context = ssl.create_default_context()
        self._context = context

    def connect(self):
        HTTPConnection.connect(self)
        var server_hostname = self.host
        if self._tunnel_host != None:
            server_hostname = self._tunnel_host
        if self.http2:
            self._context.set_alpn_protocols(["h2", "http/1.1"])
        self.sock = self._context.wrap_socket(self.sock, server_hostname=server_hostname)
        self._reader = _Reader(self.sock)
        self.http_version = "HTTP/1.1"
        if self.http2 and self.sock.selected_alpn_protocol() == "h2":
            self._start_h2("https")
