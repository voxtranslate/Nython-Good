# nython: module    (import it by name: it runs in a module scope of its own)
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
    def __init__(self, partial, expected=none):
        self.partial = partial
        self.expected = expected
        var tail = ""
        if expected != none:
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

    def get(self, name, failobj=none):
        var n = name.lower()
        for f in self._fields:
            if f[0].lower() == n:
                return f[1]
        return failobj

    def get_all(self, name, failobj=none):
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
        return self.get(name) != none

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

    def get_content_charset(self, failobj=none):
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
    var name = none
    var value = ""
    var count = 0
    while true:
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
        if (line.startswith(" ") or line.startswith("\t")) and name != none:
            value = value + " " + line.strip()
            continue
        if name != none:
            msg.add(name, value)
        var c = line.find(":")
        if c <= 0:
            name = none
            continue
        name = line[0:c].strip()
        value = line[c + 1:].strip()
    if name != none:
        msg.add(name, value)
    return msg

# ─── responses ──────────────────────────────────────────────────────────────

class HTTPResponse:
    def __init__(self, sock, reader=none, method=none, url=none, debuglevel=0):
        self.sock = sock
        self.fp = reader
        if reader == none:
            self.fp = _Reader(sock)
        self._method = method
        self.url = url
        self.debuglevel = debuglevel
        self.headers = none
        self.msg = none
        self.version = 11
        self.status = none
        self.code = none
        self.reason = none
        self.chunked = false
        self.chunk_left = none
        self.length = none
        self.will_close = true
        self._closed = false
        self._done = false
        self._on_done = none        # the connection's: keep it or drop it

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
        if self.headers != none:
            return
        var st = none
        while true:
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
        if te != none and te.lower().find("chunked") >= 0:
            self.chunked = true
            self.chunk_left = none
        self.will_close = self._check_close()
        self.length = none
        var cl = self.headers.get("content-length")
        if cl != none and not self.chunked:
            try:
                self.length = int(cl)
            except ValueError:
                self.length = none
            if self.length != none and self.length < 0:
                self.length = none
        if self.status == 204 or self.status == 304 or (self.status >= 100 and self.status < 200) or self._method == "HEAD":
            self.length = 0
        if not self.will_close and not self.chunked and self.length == none:
            self.will_close = true
        if self.length == 0:
            self._finish()

    def _check_close(self):
        var conn = self.headers.get("connection")
        if self.version == 11:
            return conn != none and conn.lower().find("close") >= 0
        if self.headers.get("keep-alive") != none:
            return false
        if conn != none and conn.lower().find("keep-alive") >= 0:
            return false
        return true

    def _finish(self):
        if self._done:
            return
        self._done = true
        if self._on_done != none:
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

    def _read_chunked(self, amt=none):
        var parts = []
        var got = 0
        while amt == none or got < amt:
            if self.chunk_left == none or self.chunk_left == 0:
                if self.chunk_left == 0:
                    self.fp.readline()          # CRLF after the chunk
                var n = self._read_chunk_size()
                if n == 0:
                    parse_headers(self.fp)      # trailers
                    self.chunk_left = none
                    self._finish()
                    break
                self.chunk_left = n
            var want = self.chunk_left
            if amt != none:
                want = min(want, amt - got)
            var d = self.fp.read(want)
            if len(d) < want:
                raise IncompleteRead(b"".join(parts) + d)
            parts.append(d)
            got = got + len(d)
            self.chunk_left = self.chunk_left - len(d)
        return b"".join(parts)

    def read(self, amt=none):
        if self._closed or self.headers == none:
            return b""
        if self._done and not self.chunked:
            return b""
        if self.chunked:
            if self._done:
                return b""
            return self._read_chunked(amt)
        if self.length != none:
            var n = self.length
            if amt != none and amt < n:
                n = amt
            var d = self.fp.read(n)
            self.length = self.length - len(d)
            if len(d) < n:
                self._done = true
                raise IncompleteRead(d, self.length)
            if self.length == 0:
                self._finish()
            return d
        # to the close
        var d2 = none
        if amt == none:
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
        if self.length != none:
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
        var parts = []
        while true:
            var c = self.read(1)
            if len(c) == 0:
                break
            parts.append(c)
            if c == b"\n" or (limit >= 0 and len(parts) >= limit):
                break
        return b"".join(parts)

    def readlines(self):
        var out = []
        var line = self.readline()
        while len(line) > 0:
            out.append(line)
            line = self.readline()
        return out

    def __iter__(self):
        return iter(self.readlines())

    def getheader(self, name, default=none):
        if self.headers == none:
            raise ResponseNotReady()
        var vals = self.headers.get_all(name)
        if vals == none:
            return default
        return ", ".join(vals)

    def getheaders(self):
        if self.headers == none:
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
        self._closed = true
        if not self._done:
            self.will_close = true
            self._finish()

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return false

    def __repr__(self):
        return "<http.client.HTTPResponse status=" + str(self.status) + ">"

# ─── connections ────────────────────────────────────────────────────────────

class HTTPConnection:
    default_port = HTTP_PORT
    debuglevel = 0

    def __init__(self, host, port=none, timeout=none, source_address=none, blocksize=8192):
        self.timeout = timeout
        self.source_address = source_address
        self.blocksize = blocksize
        self.sock = none
        self._reader = none
        self._buffer = []
        self._state = "idle"
        self._response = none
        self._method = none
        self._tunnel_host = none
        self._tunnel_port = none
        self._tunnel_headers = {}
        self._pending = none        # a response request() already began
        var hp = self._get_hostport(host, port)
        self.host = hp[0]
        self.port = hp[1]

    def _get_hostport(self, host, port):
        if port == none:
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

    def set_tunnel(self, host, port=none, headers=none):
        if self.sock != none:
            raise RuntimeError("Can't set up tunnel for established connection")
        var hp = self._get_hostport(host, port)
        self._tunnel_host = hp[0]
        self._tunnel_port = hp[1]
        if headers != none:
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
        var h = self.host
        var p = self.port
        self.sock = socket.create_connection((h, p), self.timeout, self.source_address)
        try:
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        if self._tunnel_host != none:
            self._tunnel()
        self._reader = _Reader(self.sock)

    def close(self):
        self._state = "idle"
        if self.sock != none:
            self.sock.close()
        self.sock = none
        self._reader = none
        self._response = none
        self._pending = none

    def send(self, data):
        if self.sock == none:
            self.connect()
        if self.debuglevel > 0:
            print("send:", repr(data))
        if isinstance(data, "str"):
            data = data.encode("utf-8")
        if hasattr(data, "read"):
            var chunk = data.read(self.blocksize)
            while len(chunk) > 0:
                if isinstance(chunk, "str"):
                    chunk = chunk.encode("utf-8")
                self.sock.sendall(chunk)
                chunk = data.read(self.blocksize)
            return
        if isinstance(data, "bytes") or isinstance(data, "bytearray"):
            self.sock.sendall(data)
            return
        for d in data:
            if isinstance(d, "str"):
                d = d.encode("utf-8")
            self.sock.sendall(d)

    def putrequest(self, method, url, skip_host=false, skip_accept_encoding=false):
        if self._response != none and not self._response._done:
            raise CannotSendRequest("Request-sent")
        if self._state != "idle":
            raise CannotSendRequest(self._state)
        self._state = "started"
        self._method = method
        if url == none or url == "":
            url = "/"
        for ch in url:
            if ord(ch) <= 32 or ord(ch) == 127:
                raise InvalidURL("URL can't contain control characters. " + repr(url))
        self._buffer = [method + " " + url + " HTTP/1.1"]
        if not skip_host:
            if self._tunnel_host != none:
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
        var line = str(header) + ": " + "\r\n\t".join(vs)
        if line.find("\n") >= 0 and line.find("\r\n\t") < 0:
            raise ValueError("Invalid header value " + repr(line))
        self._buffer.append(line)

    def endheaders(self, message_body=none, encode_chunked=false):
        if self._state != "started":
            raise CannotSendHeader()
        self._state = "sent"
        var head = ("\r\n".join(self._buffer) + "\r\n\r\n").encode("iso-8859-1")
        self._buffer = []
        if message_body == none:
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
        if body == none:
            return none
        if isinstance(body, "str"):
            return len(body.encode("utf-8"))
        if isinstance(body, "bytes") or isinstance(body, "bytearray"):
            return len(body)
        return none

    def request(self, method, url, body=none, headers=none, encode_chunked=false):
        if headers == none:
            headers = {}
        var tries = 0
        while true:
            tries = tries + 1
            var reused = self.sock != none
            try:
                self._send_request(method, url, body, headers, encode_chunked)
                if reused:
                    # The server may have closed an idle kept-alive connection:
                    # find out now (its status line), and retry once on a
                    # fresh connection. getresponse() returns this response.
                    var r = HTTPResponse(self.sock, self._reader, self._method, none, self.debuglevel)
                    r._on_done = self._response_done
                    r.begin()
                    self._pending = r
                return
            except (RemoteDisconnected, BrokenPipeError, ConnectionResetError) as e:
                if not reused or tries > 1 or (body != none and hasattr(body, "read")):
                    raise
                self.close()

    def _send_request(self, method, url, body, headers, encode_chunked):
        if self.sock == none:
            self.connect()
        var names = {}
        for k in headers:
            names[k.lower()] = true
        self.putrequest(method, url, "host" in names, "accept-encoding" in names)
        if body != none and not ("content-length" in names) and not ("transfer-encoding" in names):
            var n = self._body_length(body)
            if n != none:
                self.putheader("Content-Length", str(n))
            else:
                self.putheader("Transfer-Encoding", "chunked")
                encode_chunked = true
        elif body == none and (method == "POST" or method == "PUT" or method == "PATCH") and not ("content-length" in names):
            self.putheader("Content-Length", "0")
        for k in headers:
            self.putheader(k, headers[k])
        self.endheaders(body, encode_chunked)

    def _response_done(self, resp):
        self._state = "idle"
        if resp.will_close:
            if self.sock != none:
                self.sock.close()
            self.sock = none
            self._reader = none

    def getresponse(self):
        if self._pending != none:
            var p = self._pending
            self._pending = none
            self._response = p
            if not p._done:
                self._state = "response"
            return p
        if self._state != "sent" or self.sock == none:
            raise ResponseNotReady(self._state)
        var r = HTTPResponse(self.sock, self._reader, self._method, none, self.debuglevel)
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

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return false

class HTTPSConnection(HTTPConnection):
    default_port = HTTPS_PORT

    def __init__(self, host, port=none, timeout=none, source_address=none, context=none, blocksize=8192, **kwargs):
        HTTPConnection.__init__(self, host, port, timeout, source_address, blocksize)
        if context == none:
            import ssl
            context = ssl.create_default_context()
        self._context = context

    def connect(self):
        HTTPConnection.connect(self)
        var server_hostname = self.host
        if self._tunnel_host != none:
            server_hostname = self._tunnel_host
        self.sock = self._context.wrap_socket(self.sock, server_hostname=server_hostname)
        self._reader = _Reader(self.sock)
