# ═══════════════════════════════════════════════════════════════════════════════
import nytorch
import net
import socket
import select
import threading

# sockets.ny — Nython Sockets Library
# TCP/UDP/Unix sockets, servers, framing, selectors, proxies, TLS, pools,
# reachability probes, socket pairs, multicast.
# Usage: import "lib/sockets.ny"
#
# Round 77: rebuilt over lib/socket.ny (real socket objects: errors raised
# where they belong, IPv6, timeouts, the GIL released while blocked). It
# used to have a TlsSocket without TLS, a SocketPair of two unconnected
# sockets, a MulticastSocket that joined nothing, a SocketSelector whose
# wait() never returned, a TcpServer that served one client at a time and a
# TcpProxy that relayed one message each way per round trip. `fd` is the
# socket object (none when closed); data is bytes in and str/bytes out as
# given (str is sent as UTF-8; recv returns str unless binary=true).
# ═══════════════════════════════════════════════════════════════════════════════

def _out(data, binary):
    if binary:
        return data
    return data.decode("utf-8", "replace")

def _in(data):
    if isinstance(data, "str"):
        return data.encode("utf-8")
    return data

# ─── TCP Socket ──────────────────────────────────────────────────────────────

class TcpSocket:
    def __init__(self, binary=false):
        self.fd = none
        self.connected = false
        self.remote_host = ""
        self.remote_port = 0
        self.buffer_size = 4096
        self.binary = binary
        self.timeout = none
        self.last_error = none
        self._buf = b""

    def create(self, family=none):
        if family == none:
            family = socket.AF_INET
        self.fd = socket.socket(family, socket.SOCK_STREAM)
        if self.timeout != none:
            self.fd.settimeout(self.timeout)
        return true

    def connect(self, host, port, timeout=none):
        # true when connected (last_error says why not)
        if timeout == none:
            timeout = self.timeout
        try:
            if self.fd != none:
                self.fd.close()
            self.fd = socket.create_connection((host, port), timeout)
        except OSError as e:
            self.fd = none
            self.last_error = e
            return false
        self.connected = true
        self.remote_host = host
        self.remote_port = port
        return true

    def send(self, data):
        if self.fd == none or not self.connected:
            return false
        try:
            self.fd.sendall(_in(data))
            return true
        except OSError as e:
            self.last_error = e
            self.connected = false
            return false

    def send_line(self, data):
        return self.send(data + "\r\n")

    def recv(self, size=none):
        # up to size bytes (what is buffered first); "" at the end of the stream
        if self.fd == none:
            return _out(b"", self.binary)
        if size == none:
            size = self.buffer_size
        if len(self._buf) > 0:
            var part = self._buf[0:size]
            self._buf = self._buf[len(part):]
            return _out(part, self.binary)
        try:
            var d = self.fd.recv(size)
            if len(d) == 0:
                self.connected = false
            return _out(d, self.binary)
        except OSError as e:
            self.last_error = e
            return _out(b"", self.binary)

    def recv_exactly(self, n):
        # n bytes, or none when the stream ends first
        var parts = []
        var have = 0
        if len(self._buf) > 0:
            var take = self._buf[0:n]
            self._buf = self._buf[len(take):]
            parts.append(take)
            have = len(take)
        while have < n:
            var d = b""
            try:
                d = self.fd.recv(min(n - have, 65536))
            except OSError as e:
                self.last_error = e
                return none
            if len(d) == 0:
                return none
            parts.append(d)
            have = have + len(d)
        return _out(b"".join(parts), self.binary)

    def recv_all(self):
        # everything until the peer closes
        var parts = [self._buf]
        self._buf = b""
        if self.fd != none:
            while true:
                var d = b""
                try:
                    d = self.fd.recv(65536)
                except OSError as e:
                    self.last_error = e
                    break
                if len(d) == 0:
                    break
                parts.append(d)
        self.connected = false
        return _out(b"".join(parts), self.binary)

    def recv_line(self, max_len=65536):
        # one line without its "\r\n" / "\n"; "" at the end of the stream
        while true:
            var i = self._buf.find(b"\n")
            if i >= 0:
                var line = self._buf[0:i]
                self._buf = self._buf[i + 1:]
                if line.endswith(b"\r"):
                    line = line[0:len(line) - 1]
                return _out(line, self.binary)
            if len(self._buf) >= max_len or self.fd == none:
                var rest = self._buf
                self._buf = b""
                return _out(rest, self.binary)
            var d = b""
            try:
                d = self.fd.recv(65536)
            except OSError as e:
                self.last_error = e
            if len(d) == 0:
                var tail = self._buf
                self._buf = b""
                return _out(tail, self.binary)
            self._buf = self._buf + d

    def set_timeout(self, ms):
        self.timeout = ms / 1000.0
        if self.fd != none:
            self.fd.settimeout(self.timeout)

    def set_nodelay(self, on=true):
        if self.fd != none:
            self.fd.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1 if on else 0)

    def set_keepalive(self, on=true, idle=none, interval=none, count=none):
        if self.fd == none:
            return
        self.fd.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1 if on else 0)
        if idle != none and socket.TCP_KEEPIDLE != none:
            self.fd.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, idle)
        if interval != none and socket.TCP_KEEPINTVL != none:
            self.fd.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, interval)
        if count != none and socket.TCP_KEEPCNT != none:
            self.fd.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, count)

    def shutdown_write(self):
        if self.fd != none:
            self.fd.shutdown(socket.SHUT_WR)

    def close(self):
        if self.fd != none:
            self.fd.close()
            self.fd = none
        self.connected = false

    def peer_address(self):
        if self.fd == none:
            return none
        return self.fd.getpeername()

    def local_address(self):
        if self.fd == none:
            return none
        return self.fd.getsockname()

    def fileno(self):
        if self.fd == none:
            return -1
        return self.fd.fileno()

    def fileno_handle(self):
        return self.fd.fileno_handle()

    def is_connected(self):
        return self.connected and self.fd != none

    def __enter__(self):
        return self

    def __exit__(self, a=none, b=none, c=none):
        self.close()
        return false

def _wrap_conn(sock, addr, binary):
    var client = TcpSocket(binary)
    client.fd = sock
    client.connected = true
    client.remote_host = addr[0]
    client.remote_port = addr[1]
    return client

# ─── TCP Server Socket ────────────────────────────────────────────────────────

class TcpServer:
    # accept() a TcpSocket at a time, or serve(handler) - each client on a
    # thread of its own (threaded=false: one after another).
    def __init__(self, host, port, binary=false):
        self.host = host
        self.port = port
        self.fd = none
        self.backlog = 128
        self.running = false
        self.binary = binary
        self.threaded = true
        self.clients_served = 0
        self._threads = []

    def start(self):
        try:
            self.fd = socket.create_server((self.host, self.port), socket.AF_INET6 if self.host.find(":") >= 0 else socket.AF_INET, self.backlog)
        except OSError as e:
            self.fd = none
            self.last_error = e
            return false
        self.port = self.fd.getsockname()[1]
        self.running = true
        return true

    def accept(self, timeout=none):
        # the next client, or none (stopped, or nothing within timeout seconds)
        if self.fd == none:
            return none
        if timeout != none and not self.fd.wait_readable(timeout):
            return none
        try:
            var pair = self.fd.accept()
            self.clients_served = self.clients_served + 1
            return _wrap_conn(pair[0], pair[1], self.binary)
        except OSError:
            return none

    def stop(self):
        self.running = false
        if self.fd != none:
            self.fd.close()
            self.fd = none

    def _serve_one(self, handler, client):
        try:
            handler(client)
        finally:
            client.close()

    def serve(self, handler):
        if self.fd == none and self.start() == false:
            return false
        while self.running:
            var client = self.accept(0.2)
            if client == none:
                continue
            if self.threaded:
                var t = threading.Thread(target=self._serve_one, args=(handler, client), daemon=true)
                t.start()
            else:
                self._serve_one(handler, client)
        return true

    def serve_forever(self, handler):
        return self.serve(handler)

    def start_background(self, handler):
        # serve(handler) on a thread; returns once listening
        if self.fd == none and not self.start():
            return false
        var t = threading.Thread(target=self.serve, args=(handler,), daemon=true)
        t.start()
        self._threads.append(t)
        return true

# ─── UDP Socket ──────────────────────────────────────────────────────────────

class UdpSocket:
    def __init__(self, binary=false):
        self.fd = none
        self.bound = false
        self.buffer_size = 65507
        self.binary = binary
        self.family = socket.AF_INET

    def create(self, family=none):
        if family != none:
            self.family = family
        self.fd = socket.socket(self.family, socket.SOCK_DGRAM)
        return true

    def bind(self, host, port):
        if self.fd == none:
            self.create(socket.AF_INET6 if host.find(":") >= 0 else socket.AF_INET)
        try:
            self.fd.bind((host, port))
            self.bound = true
            return true
        except OSError as e:
            self.last_error = e
            return false

    def local_address(self):
        return self.fd.getsockname()

    def send_to(self, host, port, data):
        if self.fd == none:
            self.create()
        try:
            return self.fd.sendto(_in(data), (host, port))
        except OSError as e:
            self.last_error = e
            return -1

    def recv_from(self, timeout=none):
        # [data, [host, port]], or none (closed, or nothing within timeout)
        if self.fd == none:
            return none
        if timeout != none and not self.fd.wait_readable(timeout):
            return none
        try:
            var r = self.fd.recvfrom(self.buffer_size)
            return [_out(r[0], self.binary), [r[1][0], r[1][1]]]
        except OSError as e:
            self.last_error = e
            return none

    def broadcast(self, port, data):
        if self.fd == none:
            self.create()
        self.fd.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        return self.send_to("255.255.255.255", port, data)

    def set_timeout(self, ms):
        if self.fd == none:
            self.create()
        self.fd.settimeout(ms / 1000.0)

    def close(self):
        if self.fd != none:
            self.fd.close()
            self.fd = none
        self.bound = false

# ─── Unix Domain Socket (POSIX; Windows 10 1803+) ─────────────────────────────

class UnixSocket:
    def __init__(self, path, binary=false):
        self.path = path
        self.fd = none
        self.connected = false
        self.binary = binary

    def connect(self):
        if socket.AF_UNIX == none:
            return false
        try:
            self.fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.fd.connect(self.path)
        except OSError as e:
            self.last_error = e
            if self.fd != none:
                self.fd.close()
            self.fd = none
            return false
        self.connected = true
        return true

    def listen(self, backlog=16):
        # serve on the path (a stale socket file is replaced): accept() then
        if socket.AF_UNIX == none:
            return false
        if os_exists(self.path):
            os_remove(self.path)
        self.fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.fd.bind(self.path)
        self.fd.listen(backlog)
        return true

    def accept(self):
        var pair = self.fd.accept()
        var c = UnixSocket(self.path, self.binary)
        c.fd = pair[0]
        c.connected = true
        return c

    def send(self, data):
        if self.fd == none:
            return false
        try:
            self.fd.sendall(_in(data))
            return true
        except OSError:
            return false

    def recv(self, size):
        if self.fd == none:
            return _out(b"", self.binary)
        return _out(self.fd.recv(size), self.binary)

    def close(self):
        if self.fd != none:
            self.fd.close()
            self.fd = none
        self.connected = false

# ─── Packet Protocol (length-prefixed framing) ───────────────────────────────

class PacketSocket:
    # Messages over a stream: an 8-digit decimal length, then the payload
    # (bytes on the wire, so non-ASCII text keeps its length right).
    def __init__(self, sock, max_size=16777216):
        self.sock = sock
        self.max_size = max_size

    def send_packet(self, data):
        var b = _in(data)
        if len(b) > 99999999:
            raise ValueError("packet too large")
        var header = format(len(b), "08d").encode("ascii")
        return self.sock.send(header + b)

    def _exactly(self, n):
        if hasattr(self.sock, "recv_exactly"):
            var d = self.sock.recv_exactly(n)
            if d == none:
                return none
            return _in(d)
        var parts = []
        var have = 0
        while have < n:
            var chunk = _in(self.sock.recv(n - have))
            if len(chunk) == 0:
                return none
            parts.append(chunk)
            have = have + len(chunk)
        return b"".join(parts)

    def recv_packet(self, binary=false):
        var header = self._exactly(8)
        if header == none or not header.isdigit():
            return none
        var size = int(header)
        if size > self.max_size:
            return none
        var data = self._exactly(size)
        if data == none:
            return none
        return _out(data, binary)

# ─── Connection (high-level wrapper) ─────────────────────────────────────────

class Connection:
    def __init__(self, host, port, timeout=none):
        self.host = host
        self.port = port
        self.sock = TcpSocket()
        self.sock.timeout = timeout
        self.connected = false
        self.auto_reconnect = false
        self.reconnect_delay = 2.0

    def open(self):
        var ok = self.sock.connect(self.host, self.port)
        self.connected = ok
        return ok

    def close(self):
        self.sock.close()
        self.connected = false

    def send(self, data):
        if not self.sock.is_connected() and self.auto_reconnect:
            self.open()
        var ok = self.sock.send(data)
        if not ok and self.auto_reconnect:
            sleep(self.reconnect_delay)
            if self.open():
                ok = self.sock.send(data)
        return ok

    def recv(self, size):
        return self.sock.recv(size)

    def recv_line(self):
        return self.sock.recv_line()

    def request(self, data, until_close=false):
        # sends data; the reply line (or everything to the close)
        if not self.send(data):
            return none
        if until_close:
            return self.sock.recv_all()
        return self.sock.recv_line()

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, exc_type=none, exc_value=none, tb=none):
        self.close()

# ─── Socket Selector ─────────────────────────────────────────────────────────

class SocketSelector:
    # Which of several sockets have data (or a connection) waiting.
    def __init__(self):
        self.sockets = []
        self.count = 0

    def add(self, sock):
        self.sockets.append(sock)
        self.count = len(self.sockets)

    def remove(self, sock):
        self.sockets = [s for s in self.sockets if s is not sock]
        self.count = len(self.sockets)

    def _raw(self, s):
        if hasattr(s, "fd") and s.fd != none and not isinstance(s.fd, "int"):
            return s.fd
        return s

    def wait(self, timeout_ms=-1):
        # the readable ones (a list, possibly empty when the time ran out)
        if self.count == 0:
            return []
        var raws = [self._raw(s) for s in self.sockets]
        var t = none
        if timeout_ms != none and timeout_ms >= 0:
            t = timeout_ms / 1000.0
        var r = select.select(raws, [], [], t)
        var out = []
        var i = 0
        while i < len(raws):
            if raws[i] in r[0]:
                out.append(self.sockets[i])
            i = i + 1
        return out

# ─── Proxy ───────────────────────────────────────────────────────────────────

class TcpProxy:
    # Relays every client to target_host:target_port, both directions at once
    # (a thread per direction), until either side closes.
    def __init__(self, listen_port, target_host, target_port, listen_host="0.0.0.0"):
        self.listen_port = listen_port
        self.target_host = target_host
        self.target_port = target_port
        self.server = TcpServer(listen_host, listen_port, true)
        self.running = false
        self.bytes_up = 0
        self.bytes_down = 0
        self.connections = 0

    def _pipe(self, src, dst, up):
        try:
            while true:
                var d = src.fd.recv(65536)
                if len(d) == 0:
                    break
                dst.fd.sendall(d)
                if up:
                    self.bytes_up = self.bytes_up + len(d)
                else:
                    self.bytes_down = self.bytes_down + len(d)
        except (OSError, AttributeError):
            pass
        try:
            dst.fd.shutdown(socket.SHUT_WR)
        except (OSError, AttributeError):
            pass

    def _handle_client(self, client):
        var upstream = TcpSocket(true)
        if upstream.connect(self.target_host, self.target_port) == false:
            client.close()
            return
        self.connections = self.connections + 1
        var t = threading.Thread(target=self._pipe, args=(upstream, client, false), daemon=true)
        t.start()
        self._pipe(client, upstream, true)
        t.join()
        client.close()
        upstream.close()

    def start(self, background=false):
        self.running = true
        if not self.server.start():
            return false
        self.listen_port = self.server.port
        if background:
            var t = threading.Thread(target=self.server.serve, args=(self._handle_client,), daemon=true)
            t.start()
            return true
        return self.server.serve(self._handle_client)

    def stop(self):
        self.running = false
        self.server.stop()

# ─── Address Book ─────────────────────────────────────────────────────────────

class AddressBook:
    def __init__(self):
        self.entries = {}

    def add(self, name, host, port):
        self.entries[name] = {"host": host, "port": port}

    def remove(self, name):
        if name in self.entries:
            del self.entries[name]

    def get_host(self, name):
        var e = self.entries.get(name)
        if e == none:
            return ""
        return e["host"]

    def get_port(self, name):
        var e = self.entries.get(name)
        if e == none:
            return 0
        return e["port"]

    def connect(self, name):
        var e = self.entries.get(name)
        if e == none:
            return none
        var conn = Connection(e["host"], e["port"])
        conn.open()
        return conn

# ─── TlsSocket ────────────────────────────────────────────────────────────────

class TlsSocket:
    # A TCP connection speaking TLS (lib/ssl.ny over OpenSSL): the server's
    # certificate is verified against ca_file (or the system's roots) and its
    # name checked, unless set_verify(false); set_cert() presents a client
    # certificate.
    def __init__(self, binary=false):
        self.fd = none
        self.host = ""
        self.port = 443
        self.connected = false
        self.cert_file = ""
        self.key_file = ""
        self.ca_file = ""
        self.verify_peer = true
        self.timeout = 30
        self.binary = binary
        self.alpn = none
        self.last_error = none

    def set_cert(self, cert_file, key_file):
        self.cert_file = cert_file
        self.key_file = key_file
        return self

    def set_ca(self, ca_file):
        self.ca_file = ca_file
        return self

    def set_verify(self, verify):
        self.verify_peer = verify
        return self

    def context(self):
        import ssl
        var ctx = none
        if self.ca_file != "":
            ctx = ssl.create_default_context(cafile=self.ca_file)
        else:
            ctx = ssl.create_default_context()
        if not self.verify_peer:
            ctx.check_hostname = false
            ctx.verify_mode = ssl.CERT_NONE
        if self.cert_file != "":
            ctx.load_cert_chain(self.cert_file, self.key_file if self.key_file != "" else none)
        if self.alpn != none:
            ctx.set_alpn_protocols(self.alpn)
        return ctx

    def connect(self, host, port=443):
        self.host = host
        self.port = port
        var raw = none
        try:
            raw = socket.create_connection((host, port), self.timeout)
            self.fd = self.context().wrap_socket(raw, server_hostname=host)
        except OSError as e:
            self.last_error = e
            if raw != none:
                raw.close()
            self.fd = none
            return false
        self.connected = true
        return true

    def version(self):
        if self.fd == none:
            return none
        return self.fd.version()

    def peer_certificate(self):
        if self.fd == none:
            return none
        return self.fd.getpeercert()

    def send(self, data):
        if self.fd == none or not self.connected:
            return false
        try:
            self.fd.sendall(_in(data))
            return true
        except OSError as e:
            self.last_error = e
            return false

    def recv(self, size):
        if self.fd == none or not self.connected:
            return none
        try:
            return _out(self.fd.recv(size), self.binary)
        except OSError as e:
            self.last_error = e
            return none

    def close(self):
        if self.fd != none:
            self.fd.close()
        self.connected = false
        self.fd = none

    def is_connected(self):
        return self.connected


# ─── SocketPool ───────────────────────────────────────────────────────────────

class PooledSocket:
    def __init__(self, fd, host, port):
        self.fd = fd
        self.host = host
        self.port = port
        self.in_use = false
        self.created_at = time_now()
        self.last_used = time_now()
        self.use_count = 0

    def send(self, data):
        self.fd.sendall(_in(data))
        return true

    def recv(self, size):
        return self.fd.recv(size)


class SocketPool:
    # Connections to host:port kept for reuse (min_size opened by warm(),
    # at most max_size); idle ones older than idle_timeout are closed.
    def __init__(self, host, port, min_size, max_size, timeout=10):
        self.host = host
        self.port = port
        self.min_size = min_size
        self.max_size = max_size
        self.timeout = timeout
        self.sockets = []
        self.pool_size = 0
        self.active_count = 0
        self.idle_timeout = 60.0
        self._lock = threading.Lock()

    def _create_socket(self):
        var s = none
        try:
            s = socket.create_connection((self.host, self.port), self.timeout)
        except OSError:
            return none
        var ps = PooledSocket(s, self.host, self.port)
        self.sockets.append(ps)
        self.pool_size = self.pool_size + 1
        return ps

    def warm(self):
        with self._lock:
            while self.pool_size < self.min_size:
                if self._create_socket() == none:
                    break
        return self.pool_size

    def acquire(self):
        with self._lock:
            for ps in self.sockets:
                if not ps.in_use:
                    ps.in_use = true
                    ps.last_used = time_now()
                    ps.use_count = ps.use_count + 1
                    self.active_count = self.active_count + 1
                    return ps
            if self.pool_size < self.max_size:
                var ps2 = self._create_socket()
                if ps2 != none:
                    ps2.in_use = true
                    ps2.use_count = 1
                    self.active_count = self.active_count + 1
                return ps2
            return none

    def release(self, ps, broken=false):
        with self._lock:
            if ps.in_use and self.active_count > 0:
                self.active_count = self.active_count - 1
            ps.in_use = false
            ps.last_used = time_now()
            if broken:
                ps.fd.close()
                self.sockets = [s for s in self.sockets if s is not ps]
                self.pool_size = len(self.sockets)

    def idle_count(self):
        return self.pool_size - self.active_count

    def close_idle(self):
        with self._lock:
            var now = time_now()
            var kept = []
            for ps in self.sockets:
                if ps.in_use or (now - ps.last_used) < self.idle_timeout or len(kept) < self.min_size:
                    kept.append(ps)
                else:
                    ps.fd.close()
            self.sockets = kept
            self.pool_size = len(kept)

    def close_all(self):
        with self._lock:
            for ps in self.sockets:
                ps.fd.close()
            self.sockets = []
            self.pool_size = 0
            self.active_count = 0

    def stats(self):
        var s = {}
        s["pool_size"] = self.pool_size
        s["active"] = self.active_count
        s["idle"] = self.idle_count()
        s["max"] = self.max_size
        return s


# ─── PingClient ───────────────────────────────────────────────────────────────

class PingResult:
    def __init__(self, host, success, latency_ms, error):
        self.host = host
        self.success = success
        self.latency_ms = latency_ms
        self.error = error


class PingClient:
    # Reachability by TCP connect time (ICMP needs privileges): a refused
    # connection still proves the host is up, so it counts as reachable.
    def __init__(self, port=80):
        self.timeout = 5.0
        self.packet_size = 64
        self.port = port

    def ping(self, host, port=none):
        if port == none:
            port = self.port
        var start = monotonic()
        var s = none
        try:
            s = socket.create_connection((host, port), self.timeout)
            s.close()
            return PingResult(host, true, (monotonic() - start) * 1000.0, "")
        except ConnectionRefusedError:
            return PingResult(host, true, (monotonic() - start) * 1000.0, "port closed")
        except OSError as e:
            return PingResult(host, false, (monotonic() - start) * 1000.0, type(e).__name__ + ": " + str(e))

    def ping_many(self, hosts):
        # concurrently, a thread per host; results in the hosts' order
        var results = [none for h in hosts]
        var threads = []
        var i = 0
        while i < len(hosts):
            var t = threading.Thread(target=self._ping_into, args=(results, i, hosts[i]))
            t.start()
            threads.append(t)
            i = i + 1
        for t in threads:
            t.join()
        return results

    def _ping_into(self, results, i, host):
        results[i] = self.ping(host)

    def reachable(self, host):
        return self.ping(host).success

    def avg_latency(self, host, count):
        var total = 0.0
        var ok_count = 0
        var i = 0
        while i < count:
            var r = self.ping(host)
            if r.success:
                total = total + r.latency_ms
                ok_count = ok_count + 1
            i = i + 1
        if ok_count == 0:
            return -1.0
        return total / float(ok_count)


# ─── SocketPair ───────────────────────────────────────────────────────────────

class SocketPair:
    # Two connected sockets (socket.socketpair): what one sends the other
    # receives - a channel between threads, or to a child.
    def __init__(self):
        self.fd_a = none
        self.fd_b = none
        self.created = false

    def create(self):
        var p = socket.socketpair()
        self.fd_a = p[0]
        self.fd_b = p[1]
        self.created = true
        return true

    def close(self):
        if self.fd_a != none:
            self.fd_a.close()
        if self.fd_b != none:
            self.fd_b.close()
        self.fd_a = none
        self.fd_b = none
        self.created = false


# ─── MulticastSocket ──────────────────────────────────────────────────────────

class MulticastSocket:
    # A UDP socket in an IPv4 multicast group: join() binds group_ip's port
    # and joins the group on `interface` ("0.0.0.0": the system's choice);
    # send() reaches every member, with `ttl` hops.
    def __init__(self, group_ip, port, interface="0.0.0.0", binary=false):
        self.group_ip = group_ip
        self.port = port
        self.interface = interface
        self.fd = none
        self.joined = false
        self.ttl = 1
        self.loopback = true
        self.binary = binary
        self.last_error = none

    def join(self):
        try:
            self.fd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.fd.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if socket.SO_REUSEPORT != none:
                try:
                    self.fd.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                except OSError:
                    pass
            self.fd.bind(("", self.port))
            self.fd.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, self.ttl)
            self.fd.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1 if self.loopback else 0)
            var mreq = socket.inet_aton(self.group_ip) + socket.inet_aton(self.interface)
            self.fd.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
        except OSError as e:
            self.last_error = e
            if self.fd != none:
                self.fd.close()
            self.fd = none
            return false
        self.joined = true
        return true

    def leave(self):
        if self.fd != none:
            if self.joined:
                try:
                    var mreq = socket.inet_aton(self.group_ip) + socket.inet_aton(self.interface)
                    self.fd.setsockopt(socket.IPPROTO_IP, socket.IP_DROP_MEMBERSHIP, mreq)
                except OSError:
                    pass
            self.fd.close()
        self.joined = false
        self.fd = none

    def send(self, data):
        if self.fd == none or not self.joined:
            return false
        try:
            return self.fd.sendto(_in(data), (self.group_ip, self.port)) > 0
        except OSError as e:
            self.last_error = e
            return false

    def recv(self, size=65507, timeout=none):
        # [data, [host, port]], or none
        if self.fd == none:
            return none
        if timeout != none and not self.fd.wait_readable(timeout):
            return none
        var r = self.fd.recvfrom(size)
        return [_out(r[0], self.binary), [r[1][0], r[1][1]]]

    def is_joined(self):
        return self.joined
