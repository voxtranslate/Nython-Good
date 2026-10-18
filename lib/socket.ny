# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
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
#
# Round 85: sendmsg/recvmsg with ancillary data, send_fds/recv_fds
# (SCM_RIGHTS), CMSG_LEN/CMSG_SPACE, close/dup/fromfd, gethostbyname_ex,
# getprotobyname, has_dualstack_ipv6, if_nameindex/if_nametoindex/
# if_indextoname, sethostname, error/timeout/gaierror/herror, every integer
# constant CPython has where this platform's headers define it, and the
# AddressFamily / SocketKind / MsgFlag / AddressInfo enums (made on first
# use; the constants stay ints). Bluetooth's are the Linux kernel's values
# (its headers are not installed with the C library). Not here: sendmsg's
# destination address, CAPI, socket objects' family/type as enum members.

def _consts():
    var d = {}
    for pair in _net_constants():
        d[pair[0]] = pair[1]
    return d
_C = _consts()

AF_INET = _C["AF_INET"]
AF_INET6 = _C["AF_INET6"]
AF_UNSPEC = _C["AF_UNSPEC"]
# round 84: absent where the platform has no Unix sockets (Windows), as in
# CPython - code tests hasattr(socket, "AF_UNIX"); it was None there
_AF_UNIX = _C.get("AF_UNIX")
if _AF_UNIX is not None:
    AF_UNIX = _AF_UNIX
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
IP_MULTICAST_IF = _C.get("IP_MULTICAST_IF")
IP_MULTICAST_LOOP = _C.get("IP_MULTICAST_LOOP")
IP_ADD_MEMBERSHIP = _C.get("IP_ADD_MEMBERSHIP")
IP_DROP_MEMBERSHIP = _C.get("IP_DROP_MEMBERSHIP")
IPV6_JOIN_GROUP = _C.get("IPV6_JOIN_GROUP")
IPV6_LEAVE_GROUP = _C.get("IPV6_LEAVE_GROUP")
IPV6_MULTICAST_HOPS = _C.get("IPV6_MULTICAST_HOPS")
IPV6_MULTICAST_LOOP = _C.get("IPV6_MULTICAST_LOOP")
TCP_KEEPIDLE = _C.get("TCP_KEEPIDLE")
TCP_KEEPINTVL = _C.get("TCP_KEEPINTVL")
TCP_KEEPCNT = _C.get("TCP_KEEPCNT")
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

def _bl(data):
    # a bytes-like argument (round 84: any buffer - memoryview, array ...);
    # a str stays as it is (Nython's send() takes str as UTF-8)
    if isinstance(data, bytes) or isinstance(data, bytearray) or isinstance(data, str):
        return data
    return _ny_bytes_like(data)

def _recv_into(sock, buffer, nbytes, flags, what):
    # recv_into / recvfrom_into: the bytes received written into the
    # caller's buffer in place (round 84: any writable buffer)
    if nbytes < 0:
        raise ValueError("negative buffersize in " + what)
    var view = _ny_writable_view(buffer, what + "() argument 1")
    try:
        var n = nbytes if nbytes > 0 else len(view)
        if n > len(view):
            raise ValueError("buffer too small for requested bytes")
        if what == "recvfrom_into":
            var r = _net_recvfrom(sock._h, n, flags)
            view[0:len(r[0])] = r[0]
            return (len(r[0]), _addr(r[1]))
        # straight into the buffer's memory (no bytes object in between)
        return _net_recv_into(sock._h, view._ny_a, n, flags)
    finally:
        view.release()

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
        return _net_send(self._h, _bl(data), flags)

    def sendall(self, data, flags=0):
        _net_sendall(self._h, _bl(data), flags)

    def sendto(self, data, flags_or_address, address=none):
        if address is none:
            return _net_sendto(self._h, _bl(data), flags_or_address, 0)
        return _net_sendto(self._h, _bl(data), address, flags_or_address)

    def recv(self, bufsize, flags=0):
        return _net_recv(self._h, bufsize, flags)

    def recvfrom(self, bufsize, flags=0):
        var r = _net_recvfrom(self._h, bufsize, flags)
        return (r[0], _addr(r[1]))

    def recv_into(self, buffer, nbytes=0, flags=0):
        return _recv_into(self, buffer, nbytes, flags, "recv_into")

    def recvfrom_into(self, buffer, nbytes=0, flags=0):
        return _recv_into(self, buffer, nbytes, flags, "recvfrom_into")

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

    # (round 85) sendmsg / recvmsg with ancillary data (SCM_RIGHTS ...):
    # the call is made non-blocking and waited for as send/recv are (the
    # timeout, a parked async task); POSIX only. sendmsg's address (an
    # unconnected datagram socket's destination) is not supported.
    def sendmsg(self, buffers, ancdata=(), flags=0, address=none):
        if address is not none:
            raise NotImplementedError("sendmsg(): a destination address is not supported here")
        var data = b"".join([bytes(_bl(b)) if not isinstance(b, str) else b.encode() for b in buffers])
        var anc = []
        for item in ancdata:
            anc.append((item[0], item[1], bytes(_bl(item[2]))))
        var t = self.gettimeout()
        while true:
            try:
                return _ny_os_call("sendmsg", self.fileno(), data, anc, flags)
            except BlockingIOError:
                if t == 0.0:
                    raise
                if not self.wait_writable(t):
                    raise TimeoutError("timed out")

    def recvmsg(self, bufsize, ancbufsize=0, flags=0):
        var t = self.gettimeout()
        while true:
            try:
                var r = _ny_os_call("recvmsg", self.fileno(), bufsize, ancbufsize, flags)
                return (r[0], list(r[1]), r[2], none)
            except BlockingIOError:
                if t == 0.0:
                    raise
                if not self.wait_readable(t):
                    raise TimeoutError("timed out")

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
        fam = _AF_UNIX if _AF_UNIX is not none else AF_INET
    var hs = _net_socketpair(fam, type)
    return (_from_handle(hs[0], fam, type), _from_handle(hs[1], fam, type))

def getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    var out = []
    for r in _net_getaddrinfo(host, port, family, type, proto, flags):
        out.append((r[0], r[1], r[2], r[3], _addr(r[4])))
    return out

# round 83: the "no timeout given" sentinel of Python's socket module
# (smtplib, ftplib, poplib ... take timeout=socket._GLOBAL_DEFAULT_TIMEOUT)
_GLOBAL_DEFAULT_TIMEOUT = object()

def create_connection(address, timeout=_GLOBAL_DEFAULT_TIMEOUT, source_address=none):
    # Python's: every address the name resolves to, in order, until one connects
    var host = address[0]
    var port = address[1]
    var last = none
    for ai in getaddrinfo(host, port, 0, SOCK_STREAM):
        var s = none
        try:
            s = socket(ai[0], ai[1], ai[2])
            if timeout is not none and timeout is not _GLOBAL_DEFAULT_TIMEOUT:
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

# round 83: the services database (/etc/services where there is one, else
# the well-known ports), as getservbyname/getservbyport read it
_services = none
_WELL_KNOWN = [("ftp-data", 20, "tcp"), ("ftp", 21, "tcp"), ("ssh", 22, "tcp"), ("telnet", 23, "tcp"),
               ("smtp", 25, "tcp"), ("domain", 53, "tcp"), ("domain", 53, "udp"), ("http", 80, "tcp"),
               ("pop3", 110, "tcp"), ("nntp", 119, "tcp"), ("ntp", 123, "udp"), ("imap", 143, "tcp"),
               ("snmp", 161, "udp"), ("ldap", 389, "tcp"), ("https", 443, "tcp"), ("submissions", 465, "tcp"),
               ("submission", 587, "tcp"), ("ldaps", 636, "tcp"), ("imaps", 993, "tcp"), ("pop3s", 995, "tcp")]

def _services_table():
    global _services
    if _services is not none:
        return _services
    var table = []
    try:
        var f = open("/etc/services")
        for line in f:
            line = line.split("#")[0].split()
            if len(line) < 2 or "/" not in line[1]:
                continue
            var pp = line[1].split("/")
            try:
                var port = int(pp[0])
            except ValueError:
                continue
            for name in [line[0]] + line[2:]:
                table.append((name, port, pp[1]))
        f.close()
    except OSError:
        pass
    if not table:
        table = list(_WELL_KNOWN)
    _services = table
    return table

def getservbyname(servicename, protocolname=none):
    for e in _services_table():
        if e[0] == servicename and (protocolname is none or e[2] == protocolname):
            return e[1]
    raise OSError("service/proto not found")

def getservbyport(port, protocolname=none):
    if not (0 <= port <= 65535):
        raise OverflowError("getservbyport: port must be 0-65535.")
    for e in _services_table():
        if e[1] == port and (protocolname is none or e[2] == protocolname):
            return e[0]
    raise OSError("port/proto not found")

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

# ── round 85: the rest of CPython's socket module ────────────────────────
# the exception aliases, close/dup/fromfd on descriptors, CMSG_LEN/
# CMSG_SPACE, send_fds/recv_fds (SCM_RIGHTS over sendmsg/recvmsg),
# gethostbyname_ex, getprotobyname, has_dualstack_ipv6, the interface
# index calls, sethostname, every integer constant CPython has where the
# platform's headers define it (builtins/os_posix.cpp), and the
# AddressFamily / SocketKind / MsgFlag / AddressInfo enums.
error = OSError
timeout = TimeoutError
gaierror = gaierror
herror = herror
SocketType = socket
if _C.get("AF_BLUETOOTH") is not none or sys_platform() == "linux":
    BDADDR_ANY = "00:00:00:00:00:00"
    BDADDR_LOCAL = "00:00:00:FF:FF:FF"

def _sint(v):
    if isinstance(v, int):
        return int(v)
    if hasattr(type(v), "__index__"):
        return v.__index__()
    raise TypeError("'" + type(v).__name__ + "' object cannot be interpreted as an integer")

def close(fd):
    _ny_os_call("close", _sint(fd))

def dup(fd):
    return _ny_os_call("dup", _sint(fd))

def fromfd(fd, family, type, proto=0):
    return socket(family, type, proto, dup(fd))

def gethostbyname_ex(hostname):
    return _ny_os_call("gethostbyname_ex", hostname)

def getprotobyname(protocolname):
    return _ny_os_call("getprotobyname", protocolname)

def has_dualstack_ipv6():
    if not has_ipv6 or IPV6_V6ONLY is none:
        return false
    try:
        var s = socket(AF_INET6, SOCK_STREAM)
        try:
            s.setsockopt(IPPROTO_IPV6, IPV6_V6ONLY, 0)
            return true
        finally:
            s.close()
    except OSError:
        return false

def if_nameindex():
    return list(_ny_os_call("if_nameindex"))

def if_nametoindex(oname):
    return _ny_os_call("if_nametoindex", oname)

def if_indextoname(index):
    return _ny_os_call("if_indextoname", _sint(index))

def sethostname(name):
    _ny_sys_audit("socket.sethostname", name)
    _ny_os_call("sethostname", name)

def CMSG_LEN(length):
    return _ny_os_call("CMSG_LEN", _sint(length))

def CMSG_SPACE(length):
    return _ny_os_call("CMSG_SPACE", _sint(length))

def send_fds(sock, buffers, fds, flags=0, address=none):
    """send_fds(sock, buffers, fds[, flags[, address]]) -> integer

    Send the list of file descriptors fds over an AF_UNIX socket.
    """
    import struct
    return sock.sendmsg(buffers, [(SOL_SOCKET, SCM_RIGHTS, struct.pack(str(len(fds)) + "i", *fds))], flags, address)

def recv_fds(sock, bufsize, maxfds, flags=0):
    """recv_fds(sock, bufsize, maxfds[, flags]) -> (data, list of file
    descriptors, msg_flags, address)

    Receive up to maxfds file descriptors returning the message
    data and a list containing the descriptors.
    """
    import struct
    var r = sock.recvmsg(bufsize, CMSG_LEN(maxfds * 4), flags)
    var fds = []
    for item in r[1]:
        if item[0] == SOL_SOCKET and item[1] == SCM_RIGHTS:
            var d = item[2][:len(item[2]) - (len(item[2]) % 4)]
            fds.extend(struct.unpack(str(len(d) // 4) + "i", d))
    return (r[0], fds, r[2], r[3])

if sys_platform() != "win32":
    def _load_more():
        var g = globals()
        for pair in _ny_os_call("socket_constants"):
            if pair[0] not in g:
                g[pair[0]] = pair[1]
    _load_more()
    del _load_more

# the enums (CPython's IntEnum._convert_ / IntFlag._convert_ over the
# constants): the constants stay ints here (socket.AF_INET == 2 ==
# AddressFamily.AF_INET); made the first time one is asked for
_enums = {}
def _make_enums():
    if _enums:
        return _enums
    import enum
    var g = globals()
    def pick(test):
        var out = []
        for n in list(g):
            var v = g[n]
            if isinstance(v, int) and not isinstance(v, bool) and test(n):
                out.append((n, v))
        out.sort(key=lambda kv: (kv[1], kv[0]))
        return out
    _enums["AddressFamily"] = enum.IntEnum("AddressFamily",
        pick(lambda n: n.isupper() and (n.startswith("AF_") or (n.startswith("PF_") and false))), module="socket")
    _enums["SocketKind"] = enum.IntEnum("SocketKind", pick(lambda n: n.isupper() and n.startswith("SOCK_")), module="socket")
    _enums["MsgFlag"] = enum.IntFlag("MsgFlag", pick(lambda n: n.isupper() and n.startswith("MSG_")), module="socket")
    _enums["AddressInfo"] = enum.IntFlag("AddressInfo", pick(lambda n: n.isupper() and n.startswith("AI_")), module="socket")
    return _enums

def __getattr__(name):
    if name in ("AddressFamily", "SocketKind", "MsgFlag", "AddressInfo"):
        return _make_enums()[name]
    raise AttributeError("module 'socket' has no attribute '" + name + "'")

def __dir__():
    var names = list(globals())
    names.extend(["AddressFamily", "SocketKind", "MsgFlag", "AddressInfo"])
    return sorted(names)
