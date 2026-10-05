# nython: module    (import it by name: it runs in a module scope of its own)
# lib/ssl.ny - Python's ssl module over the TLS layer (src/builtins/tls.cpp;
# round 77). `import ssl`.
#
#     import socket, ssl
#     ctx = ssl.create_default_context()
#     with socket.create_connection(("example.org", 443)) as raw:
#         with ctx.wrap_socket(raw, server_hostname="example.org") as s:
#             s.sendall(b"GET / HTTP/1.1\r\nHost: example.org\r\n\r\n")
#             print(s.version(), s.recv(100))
#
# OpenSSL is loaded when TLS is first used (libssl 1.1.1 or 3.x; NY_LIBSSL
# names a library to try first); HAS_TLS says whether it was found. A client
# context verifies the server's certificate and host name by default; TLS 1.2
# is the minimum. Reads and writes on a TLS socket wait like plain socket
# ones: within its timeout, releasing the GIL, parking an async task.
import socket

PROTOCOL_TLS = 2
PROTOCOL_TLS_CLIENT = 16
PROTOCOL_TLS_SERVER = 17
CERT_NONE = 0
CERT_OPTIONAL = 1
CERT_REQUIRED = 2
HAS_SNI = true
HAS_ALPN = true
HAS_TLSv1_2 = true
HAS_TLSv1_3 = true
OPENSSL_VERSION = _tls_version_text()
HAS_TLS = _tls_available()

SSLError = SSLError
SSLCertVerificationError = SSLCertVerificationError
CertificateError = SSLCertVerificationError
SSLEOFError = SSLEOFError
SSLZeroReturnError = SSLZeroReturnError
SSLWantReadError = SSLWantReadError
SSLWantWriteError = SSLWantWriteError
SSLSyscallError = SSLSyscallError

class TLSVersion:
    MINIMUM_SUPPORTED = -2
    TLSv1_2 = 771
    TLSv1_3 = 772
    MAXIMUM_SUPPORTED = -1

class Purpose:
    SERVER_AUTH = "SERVER_AUTH"
    CLIENT_AUTH = "CLIENT_AUTH"

def _version_code(v):
    if v == TLSVersion.MINIMUM_SUPPORTED or v == TLSVersion.MAXIMUM_SUPPORTED:
        return 0
    return v

class SSLContext:
    # PROTOCOL_TLS_CLIENT (the default) verifies the peer and its host name;
    # PROTOCOL_TLS_SERVER needs load_cert_chain() before it can accept.
    def __init__(self, protocol=PROTOCOL_TLS_CLIENT):
        if protocol == PROTOCOL_TLS:
            protocol = PROTOCOL_TLS_CLIENT
        self.protocol = protocol
        self._server = protocol == PROTOCOL_TLS_SERVER
        self._h = _tls_ctx_new(self._server)
        self._check_hostname = not self._server
        self._verify_mode = CERT_NONE
        if not self._server:
            self._verify_mode = CERT_REQUIRED
        self._minimum = TLSVersion.TLSv1_2
        self._maximum = TLSVersion.MAXIMUM_SUPPORTED
        self.sni_callback = none

    @property
    def check_hostname(self):
        return self._check_hostname

    @check_hostname.setter
    def check_hostname(self, value):
        self._check_hostname = bool(value)
        if self._check_hostname and self._verify_mode == CERT_NONE:
            self.verify_mode = CERT_REQUIRED

    @property
    def verify_mode(self):
        return self._verify_mode

    @verify_mode.setter
    def verify_mode(self, value):
        if value == CERT_NONE and self._check_hostname:
            raise ValueError("Cannot set verify_mode to CERT_NONE when check_hostname is enabled.")
        self._verify_mode = value
        _tls_ctx_set_verify(self._h, value)

    @property
    def minimum_version(self):
        return self._minimum

    @minimum_version.setter
    def minimum_version(self, v):
        self._minimum = v
        var code = _version_code(v)
        if code == 0:
            code = 771
        _tls_ctx_set_versions(self._h, code, -1)

    @property
    def maximum_version(self):
        return self._maximum

    @maximum_version.setter
    def maximum_version(self, v):
        self._maximum = v
        _tls_ctx_set_versions(self._h, -1, _version_code(v))

    def load_default_certs(self, purpose=Purpose.SERVER_AUTH):
        _tls_ctx_default_paths(self._h)

    def set_default_verify_paths(self):
        _tls_ctx_default_paths(self._h)

    def load_verify_locations(self, cafile=none, capath=none, cadata=none):
        _tls_ctx_load_verify(self._h, cafile, capath, cadata)

    def load_cert_chain(self, certfile, keyfile=none, password=none):
        if callable(password):
            password = password()
        _tls_ctx_load_cert_chain(self._h, certfile, keyfile, password)

    def set_alpn_protocols(self, protocols):
        _tls_ctx_set_alpn(self._h, list(protocols))

    def set_ciphers(self, ciphers):
        _tls_ctx_set_ciphers(self._h, ciphers)

    def wrap_socket(self, sock, server_side=false, do_handshake_on_connect=true, suppress_ragged_eofs=true, server_hostname=none, session=none):
        # A connected socket starts TLS now; an unconnected one when it
        # connects, and a listening one wraps each connection accept() returns.
        var s = SSLSocket(sock, self, server_side, server_hostname)
        s._handshake_now = do_handshake_on_connect
        var connected = true
        try:
            sock.getpeername()
        except OSError:
            connected = false
        if connected:
            s._start()
        return s

    def __repr__(self):
        return "<ssl.SSLContext protocol=" + str(self.protocol) + ">"

def create_default_context(purpose=Purpose.SERVER_AUTH, cafile=none, capath=none, cadata=none):
    var ctx = none
    if purpose == Purpose.SERVER_AUTH:
        ctx = SSLContext(PROTOCOL_TLS_CLIENT)
        if cafile == none and capath == none and cadata == none:
            ctx.load_default_certs(purpose)
    else:
        ctx = SSLContext(PROTOCOL_TLS_SERVER)
    if cafile != none or capath != none or cadata != none:
        ctx.load_verify_locations(cafile, capath, cadata)
    return ctx

class SSLSocket:
    # A socket speaking TLS: the socket's own methods (its send/recv now go
    # through TLS), plus the session's. wrap_socket() makes one.
    def __init__(self, sock, context, server_side, server_hostname):
        self._sock = sock
        self.context = context
        self.server_side = server_side
        self.server_hostname = server_hostname
        self.family = sock.family
        self.type = sock.type
        self._tls = false
        self._handshake_now = true

    def _start(self):
        _tls_wrap(self._sock.fileno_handle(), self.context._h, self.server_side, self.server_hostname, self.context._check_hostname, self._handshake_now)
        self._tls = true

    def do_handshake(self, block=false):
        if not self._tls:
            self._start()
        _tls_handshake(self._sock.fileno_handle())

    def connect(self, address):
        if self.server_side:
            raise ValueError("can't connect in server-side mode")
        self._sock.connect(address)
        self._start()

    def connect_ex(self, address):
        try:
            self.connect(address)
            return 0
        except OSError as e:
            return e.errno if hasattr(e, "errno") and e.errno != none else 1

    def bind(self, address):
        self._sock.bind(address)

    def listen(self, backlog=128):
        self._sock.listen(backlog)

    def accept(self):
        # The connection, as an SSLSocket that has done its server handshake.
        var pair = self._sock.accept()
        var conn = self.context.wrap_socket(pair[0], true, self._handshake_now)
        return (conn, pair[1])

    def version(self):
        return _tls_info(self._sock.fileno_handle()).get("version")

    def cipher(self):
        var i = _tls_info(self._sock.fileno_handle())
        if not ("cipher" in i):
            return none
        return (i["cipher"], i["version"], i["bits"])

    def selected_alpn_protocol(self):
        return _tls_info(self._sock.fileno_handle()).get("alpn")

    def getpeercert(self, binary_form=false):
        var c = _tls_peer_cert(self._sock.fileno_handle(), binary_form)
        if c == none or binary_form:
            return c
        if self.context.verify_mode == CERT_NONE:
            return {}
        return c

    def unwrap(self):
        _tls_unwrap(self._sock.fileno_handle())
        return self._sock

    def pending(self):
        return 0

    # the socket's own
    def send(self, data, flags=0):
        return self._sock.send(data, flags)

    def sendall(self, data, flags=0):
        return self._sock.sendall(data, flags)

    def recv(self, bufsize=1024, flags=0):
        return self._sock.recv(bufsize, flags)

    def read(self, n=1024):
        return self._sock.recv(n)

    def write(self, data):
        return self._sock.send(data)

    def recv_into(self, buffer, nbytes=0, flags=0):
        return self._sock.recv_into(buffer, nbytes, flags)

    def makefile(self, mode="r", buffering=none, encoding=none, errors=none, newline=none):
        return socket.SocketIO(self, mode, encoding)

    def fileno(self):
        return self._sock.fileno()

    def fileno_handle(self):
        return self._sock.fileno_handle()

    def settimeout(self, value):
        self._sock.settimeout(value)

    def gettimeout(self):
        return self._sock.gettimeout()

    def setblocking(self, flag):
        self._sock.setblocking(flag)

    def getpeername(self):
        return self._sock.getpeername()

    def getsockname(self):
        return self._sock.getsockname()

    def setsockopt(self, level, optname, value):
        self._sock.setsockopt(level, optname, value)

    def shutdown(self, how):
        self._sock.shutdown(how)

    def wait_readable(self, timeout=none):
        return self._sock.wait_readable(timeout)

    def wait_writable(self, timeout=none):
        return self._sock.wait_writable(timeout)

    def close(self):
        self._sock.close()

    def detach(self):
        return self._sock.detach()

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return false

    def __repr__(self):
        return "<ssl.SSLSocket " + repr(self._sock)[1:]

def get_default_verify_paths():
    return {"cafile": none, "capath": none}

def match_hostname(cert, hostname):
    # host name matching happens in the handshake (OpenSSL, RFC 6125)
    pass
