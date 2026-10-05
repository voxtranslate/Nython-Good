# nython: module    (import it by name: it runs in a module scope of its own)
# lib/socket.ny - Python's socket module over the socket layer
# (src/builtins/net.cpp; round 77). `import socket`.
#
# The same calls work in a thread and in an async task: a socket that has to
# wait releases the GIL in a thread and parks the task in async code (the
# loop runs its other tasks meanwhile), so `data = sock.recv(1024)` inside
# an `async def` needs no separate async API (`await sock.recv(1024)` is the
# same thing). recv() returns bytes; send()/sendall() take bytes or str
# (UTF-8). settimeout(t): t seconds per call, then TimeoutError("timed out");
# none blocks; 0 makes it non-blocking (BlockingIOError).

def _consts():
    var d = {}
    for pair in _net_constants():
        d[pair[0]] = pair[1]
    return d
_C = _consts()

AF_INET = _C["AF_INET"]
AF_INET6 = _C["AF_INET6"]
AF_UNSPEC = _C["AF_UNSPEC"]
AF_UNIX = _C.get("AF_UNIX")
SOCK_STREAM = _C["SOCK_STREAM"]
SOCK_DGRAM = _C["SOCK_DGRAM"]
SOCK_RAW = _C["SOCK_RAW"]
SOL_SOCKET = _C["SOL_SOCKET"]
SO_REUSEADDR = _C["SO_REUSEADDR"]
SO_REUSEPORT = _C.get("SO_REUSEPORT")
SO_KEEPALIVE = _C["SO_KEEPALIVE"]
SO_BROADCAST = _C["SO_BROADCAST"]
SO_RCVBUF = _C["SO_RCVBUF"]
SO_SNDBUF = _C["SO_SNDBUF"]
SO_ERROR = _C["SO_ERROR"]
SO_TYPE = _C["SO_TYPE"]
SO_LINGER = _C["SO_LINGER"]
IPPROTO_TCP = _C["IPPROTO_TCP"]
IPPROTO_UDP = _C["IPPROTO_UDP"]
IPPROTO_IP = _C["IPPROTO_IP"]
IPPROTO_IPV6 = _C["IPPROTO_IPV6"]
IPV6_V6ONLY = _C.get("IPV6_V6ONLY")
TCP_NODELAY = _C["TCP_NODELAY"]
IP_TTL = _C["IP_TTL"]
IP_MULTICAST_TTL = _C["IP_MULTICAST_TTL"]
SHUT_RD = _C["SHUT_RD"]
SHUT_WR = _C["SHUT_WR"]
SHUT_RDWR = _C["SHUT_RDWR"]
MSG_PEEK = _C["MSG_PEEK"]
MSG_OOB = _C["MSG_OOB"]
MSG_DONTWAIT = _C.get("MSG_DONTWAIT")
MSG_WAITALL = _C.get("MSG_WAITALL")
AI_PASSIVE = _C["AI_PASSIVE"]
AI_CANONNAME = _C["AI_CANONNAME"]
AI_NUMERICHOST = _C["AI_NUMERICHOST"]
NI_NUMERICHOST = _C["NI_NUMERICHOST"]
NI_NUMERICSERV = _C["NI_NUMERICSERV"]
NI_NAMEREQD = _C["NI_NAMEREQD"]
INADDR_ANY = _C["INADDR_ANY"]
INADDR_LOOPBACK = _C["INADDR_LOOPBACK"]
INADDR_BROADCAST = _C["INADDR_BROADCAST"]
SOMAXCONN = _C["SOMAXCONN"]
has_ipv6 = true

# Python's names for the errors
error = OSError
timeout = TimeoutError

def _addr(a):
    # an address as Python gives it: a tuple for IP families, a str path
    if isinstance(a, "list"):
        return tuple(a)
    return a

class SocketIO:
    # sock.makefile(mode): read/read1/readline/readlines/write/flush/close over
    # the socket, in text ("r", "w", "rw") or binary ("rb", "wb") mode.
    # Buffered: `buf` from `pos` is what has been received and not yet read,
    # so a line or a small read costs what it returns, not the buffer's size.
    def __init__(self, sock, mode="r", encoding="utf-8"):
        self.sock = sock
        self.mode = mode
        self.binary = "b" in mode
        self.encoding = encoding
        self.buf = b""
        self.pos = 0
        self.eof = false
        self.closed = false

    def _fill(self):
        if self.eof:
            return false
        var chunk = self.sock.recv(65536)
        if len(chunk) == 0:
            self.eof = true
            return false
        if self.pos >= len(self.buf):
            self.buf = chunk
        else:
            self.buf = self.buf[self.pos:] + chunk
        self.pos = 0
        return true

    def _take(self, n):
        var part = self.buf[self.pos:self.pos + n]
        self.pos = self.pos + len(part)
        if self.pos >= len(self.buf):
            self.buf = b""
            self.pos = 0
        return part

    def _out(self, data):
        if self.binary:
            return data
        return data.decode(self.encoding, "replace")

    def read(self, n=-1):
        if n is none or n < 0:
            var parts = [self._take(len(self.buf))]
            while not self.eof:
                var d = self.sock.recv(1048576)
                if len(d) == 0:
                    self.eof = true
                    break
                parts.append(d)
            return self._out(b"".join(parts))
        var parts2 = [self._take(n)]
        var have = len(parts2[0])
        while have < n and not self.eof:
            var d2 = self.sock.recv(min(n - have, 1048576))
            if len(d2) == 0:
                self.eof = true
                break
            parts2.append(d2)
            have = have + len(d2)
        return self._out(b"".join(parts2))

    def read1(self, n=-1):
        # What is buffered, else one receive.
        if self.pos >= len(self.buf) and not self._fill():
            return self._out(b"")
        if n is none or n < 0:
            n = len(self.buf)
        return self._out(self._take(n))

    def peek(self, n=1):
        if self.pos >= len(self.buf):
            self._fill()
        return self.buf[self.pos:]

    def readline(self, limit=-1):
        var scanned = self.pos
        while true:
            var i = self.buf.find(b"\n", scanned)
            if i >= 0 and (limit < 0 or i + 1 - self.pos <= limit):
                return self._out(self._take(i + 1 - self.pos))
            if limit >= 0 and len(self.buf) - self.pos >= limit:
                return self._out(self._take(limit))
            scanned = len(self.buf)
            var before = self.pos
            if not self._fill():
                return self._out(self._take(len(self.buf)))
            scanned = scanned - before

    def readlines(self):
        var out = []
        while true:
            var line = self.readline()
            if len(line) == 0:
                return out
            out.append(line)

    def __iter__(self):
        return iter(self.readlines())

    def readable(self):
        return "r" in self.mode

    def writable(self):
        return "w" in self.mode

    def write(self, data):
        if isinstance(data, "str"):
            data = data.encode(self.encoding)
        self.sock.sendall(data)
        return len(data)

    def writelines(self, lines):
        for l in lines:
            self.write(l)

    def flush(self):
        pass

    def fileno(self):
        return self.sock.fileno()

    def close(self):
        self.closed = true

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return false

class socket:
    # _handle: an existing socket-layer handle (accept, socketpair)
    def __init__(self, family=AF_INET, type=SOCK_STREAM, proto=0, fileno=none, _handle=none):
        self.family = family
        self.type = type
        self.proto = proto
        self._closed = false
        if _handle is not none:
            self._h = _handle
        elif fileno is none:
            self._h = _net_socket(family, type, proto)
        else:
            self._h = _net_fromfd(fileno, family, type)

    # The socket layer's handle (lib/ssl.ny wraps it in TLS).
    def fileno_handle(self):
        return self._h

    def fileno(self):
        if self._closed:
            return -1
        return _net_fileno(self._h)

    def bind(self, address):
        _net_bind(self._h, address)

    def listen(self, backlog=128):
        _net_listen(self._h, backlog)

    def accept(self):
        var r = _net_accept(self._h)
        return (_from_handle(r[0], self.family, self.type), _addr(r[1]))

    def connect(self, address):
        _net_connect(self._h, address)

    def connect_ex(self, address):
        return _net_connect_ex(self._h, address)

    def send(self, data, flags=0):
        return _net_send(self._h, data, flags)

    def sendall(self, data, flags=0):
        _net_sendall(self._h, data, flags)

    def sendto(self, data, flags_or_address, address=none):
        if address is none:
            return _net_sendto(self._h, data, flags_or_address, 0)
        return _net_sendto(self._h, data, address, flags_or_address)

    def recv(self, bufsize, flags=0):
        return _net_recv(self._h, bufsize, flags)

    def recvfrom(self, bufsize, flags=0):
        var r = _net_recvfrom(self._h, bufsize, flags)
        return (r[0], _addr(r[1]))

    def recv_into(self, buffer, nbytes=0, flags=0):
        var n = nbytes if nbytes > 0 else len(buffer)
        var data = _net_recv(self._h, n, flags)
        buffer[0:len(data)] = data
        return len(data)

    def settimeout(self, value):
        _net_settimeout(self._h, value)

    def gettimeout(self):
        return _net_gettimeout(self._h)

    def setblocking(self, flag):
        _net_settimeout(self._h, none if flag else 0.0)

    def getblocking(self):
        return self.gettimeout() != 0.0

    def setsockopt(self, level, optname, value):
        if isinstance(value, "bool"):
            value = 1 if value else 0
        _net_setsockopt(self._h, level, optname, value)

    def getsockopt(self, level, optname, buflen=0):
        return _net_getsockopt(self._h, level, optname, buflen)

    def getsockname(self):
        return _addr(_net_getsockname(self._h))

    def getpeername(self):
        return _addr(_net_getpeername(self._h))

    def shutdown(self, how):
        _net_shutdown(self._h, how)

    def close(self):
        if not self._closed:
            self._closed = true
            _net_close(self._h)

    def detach(self):
        self._closed = true
        return _net_detach(self._h)

    def makefile(self, mode="r", buffering=none, encoding=none, errors=none, newline=none):
        return SocketIO(self, mode, encoding if encoding is not none else "utf-8")

    # Ready to read within timeout seconds (none: no limit)? The same wait a
    # recv would make: parks an async task, releases the GIL in a thread.
    def wait_readable(self, timeout=none):
        return _net_wait(self._h, 1, timeout) != 0

    def wait_writable(self, timeout=none):
        return _net_wait(self._h, 2, timeout) != 0

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return false

    def __repr__(self):
        if self._closed:
            return "<socket.socket [closed] fd=-1>"
        var s = "<socket.socket fd=" + str(self.fileno()) + ", family=" + str(self.family) + ", type=" + str(self.type)
        try:
            s = s + ", laddr=" + str(self.getsockname())
        except OSError:
            pass
        return s + ">"

def _from_handle(h, family, type):
    return socket(family, type, 0, none, h)

def socketpair(family=none, type=SOCK_STREAM, proto=0):
    var fam = family
    if fam is none:
        fam = AF_UNIX if AF_UNIX is not none else AF_INET
    var hs = _net_socketpair(fam, type)
    return (_from_handle(hs[0], fam, type), _from_handle(hs[1], fam, type))

def getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    var out = []
    for r in _net_getaddrinfo(host, port, family, type, proto, flags):
        out.append((r[0], r[1], r[2], r[3], _addr(r[4])))
    return out

def create_connection(address, timeout=none, source_address=none):
    # Python's: every address the name resolves to, in order, until one connects
    var host = address[0]
    var port = address[1]
    var last = none
    for ai in getaddrinfo(host, port, 0, SOCK_STREAM):
        var s = none
        try:
            s = socket(ai[0], ai[1], ai[2])
            if timeout is not none:
                s.settimeout(timeout)
            if source_address is not none:
                s.bind(source_address)
            s.connect(ai[4])
            return s        # the timeout stays: it applies to every operation, as in Python
        except OSError as e:
            last = e
            if s is not none:
                s.close()
    if last is not none:
        raise last
    raise OSError("getaddrinfo returns an empty list")

def create_server(address, family=AF_INET, backlog=none, reuse_port=false, dualstack_ipv6=false):
    var s = socket(family, SOCK_STREAM)
    try:
        if sys_platform() != "win32":
            s.setsockopt(SOL_SOCKET, SO_REUSEADDR, 1)
        if reuse_port and SO_REUSEPORT is not none:
            s.setsockopt(SOL_SOCKET, SO_REUSEPORT, 1)
        if family == AF_INET6 and IPV6_V6ONLY is not none:
            s.setsockopt(IPPROTO_IPV6, IPV6_V6ONLY, 0 if dualstack_ipv6 else 1)
        s.bind(address)
        s.listen(backlog if backlog is not none else 128)
    except OSError as e:
        s.close()
        raise e
    return s

def sys_platform():
    return os_platform() if os_platform() != "windows" else "win32"

def gethostname():
    return _net_gethostname()

def gethostbyname(name):
    return _net_gethostbyname(name)

def gethostbyaddr(ip):
    return _net_gethostbyaddr(ip)

def getnameinfo(sockaddr, flags=0):
    return _net_getnameinfo(sockaddr, flags)

def getfqdn(name=""):
    var n = name
    if n == "" or n == "0.0.0.0":
        n = gethostname()
    try:
        return gethostbyaddr(gethostbyname(n))[0]
    except OSError:
        return n

def inet_pton(family, ip):
    return _net_inet_pton(family, ip)

def inet_ntop(family, packed):
    return _net_inet_ntop(family, packed)

def inet_aton(ip):
    return _net_inet_pton(AF_INET, ip)

def inet_ntoa(packed):
    return _net_inet_ntop(AF_INET, packed)

def htons(x):
    return ((x & 255) << 8) | ((x >> 8) & 255)

def ntohs(x):
    return htons(x)

def htonl(x):
    return int.from_bytes((x & 4294967295).to_bytes(4, "big"), "little")

def ntohl(x):
    return htonl(x)

def getdefaulttimeout():
    return _net_getdefaulttimeout()

def setdefaulttimeout(t):
    _net_setdefaulttimeout(t)
