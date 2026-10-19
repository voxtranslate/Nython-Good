# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
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
HAS_SNI = True
HAS_ALPN = True
HAS_TLSv1_2 = True
HAS_TLSv1_3 = True
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
        self.sni_callback = None

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

    def load_verify_locations(self, cafile=None, capath=None, cadata=None):
        _tls_ctx_load_verify(self._h, cafile, capath, cadata)

    def load_cert_chain(self, certfile, keyfile=None, password=None):
        if callable(password):
            password = password()
        _tls_ctx_load_cert_chain(self._h, certfile, keyfile, password)

    def set_alpn_protocols(self, protocols):
        _tls_ctx_set_alpn(self._h, list(protocols))

    def set_ciphers(self, ciphers):
        _tls_ctx_set_ciphers(self._h, ciphers)

    def wrap_socket(self, sock, server_side=False, do_handshake_on_connect=True, suppress_ragged_eofs=True, server_hostname=None, session=None):
        # A connected socket starts TLS now; an unconnected one when it
        # connects, and a listening one wraps each connection accept() returns.
        var s = SSLSocket(sock, self, server_side, server_hostname)
        s._handshake_now = do_handshake_on_connect
        var connected = True
        try:
            sock.getpeername()
        except OSError:
            connected = False
        if connected:
            s._start()
        return s

    def __repr__(self):
        return "<ssl.SSLContext protocol=" + str(self.protocol) + ">"

def create_default_context(purpose=Purpose.SERVER_AUTH, cafile=None, capath=None, cadata=None):
    var ctx = None
    if purpose == Purpose.SERVER_AUTH:
        ctx = SSLContext(PROTOCOL_TLS_CLIENT)
        if cafile == None and capath == None and cadata == None:
            ctx.load_default_certs(purpose)
    else:
        ctx = SSLContext(PROTOCOL_TLS_SERVER)
    if cafile != None or capath != None or cadata != None:
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
        self._tls = False
        self._handshake_now = True

    def _start(self):
        _tls_wrap(self._sock.fileno_handle(), self.context._h, self.server_side, self.server_hostname, self.context._check_hostname, self._handshake_now)
        self._tls = True

    def do_handshake(self, block=False):
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
            return e.errno if hasattr(e, "errno") and e.errno != None else 1

    def bind(self, address):
        self._sock.bind(address)

    def listen(self, backlog=128):
        self._sock.listen(backlog)

    def accept(self):
        # The connection, as an SSLSocket that has done its server handshake.
        var pair = self._sock.accept()
        var conn = self.context.wrap_socket(pair[0], True, self._handshake_now)
        return (conn, pair[1])

    def version(self):
        return _tls_info(self._sock.fileno_handle()).get("version")

    def cipher(self):
        var i = _tls_info(self._sock.fileno_handle())
        if not ("cipher" in i):
            return None
        return (i["cipher"], i["version"], i["bits"])

    def selected_alpn_protocol(self):
        return _tls_info(self._sock.fileno_handle()).get("alpn")

    def getpeercert(self, binary_form=False):
        var c = _tls_peer_cert(self._sock.fileno_handle(), binary_form)
        if c == None or binary_form:
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

    def makefile(self, mode="r", buffering=None, encoding=None, errors=None, newline=None):
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

    def wait_readable(self, timeout=None):
        return self._sock.wait_readable(timeout)

    def wait_writable(self, timeout=None):
        return self._sock.wait_writable(timeout)

    def close(self):
        self._sock.close()

    def detach(self):
        return self._sock.detach()

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return False

    def __repr__(self):
        return "<ssl.SSLSocket " + repr(self._sock)[1:]

import collections as _collections
DefaultVerifyPaths = _collections.namedtuple("DefaultVerifyPaths",
    "cafile capath openssl_cafile_env openssl_cafile openssl_capath_env openssl_capath")

def get_default_verify_paths():
    """Return paths to default cafile and capath (round 85: libcrypto's)."""
    import os
    var parts = _tls_rand("paths") if HAS_TLS else ["SSL_CERT_FILE", "", "SSL_CERT_DIR", ""]
    var cafile = os.environ.get(parts[0], parts[1])
    var capath = os.environ.get(parts[2], parts[3])
    return DefaultVerifyPaths(cafile if os.path.isfile(cafile) else None,
                              capath if os.path.isdir(capath) else None,
                              parts[0], parts[1], parts[2], parts[3])

def match_hostname(cert, hostname):
    # host name matching happens in the handshake (OpenSSL, RFC 6125)
    pass

# ── round 85: the rest of CPython's ssl module-level API ─────────────────
# RAND_bytes / RAND_status / RAND_add / RAND_pseudo_bytes over libcrypto
# (builtins/tls.cpp), DER/PEM conversion, cert_time_to_seconds,
# get_protocol_name, get_server_certificate, 3.11's deprecated wrap_socket,
# the OpenSSL version number, the
# OP_* / ALERT_DESCRIPTION_* / SSL_ERROR_* / VERIFY_* / PROTOCOL_* constants
# (OpenSSL 3's values; Nython loads OpenSSL 1.1.1 or 3 at run time), the
# HAS_* flags and the Options / VerifyMode / VerifyFlags / SSLErrorNumber /
# AlertDescription enums. Not here: MemoryBIO, SSLObject and SSLSession (the
# TLS layer drives OpenSSL on a socket only), NPN, SSLv2/v3.
from socket import SOCK_STREAM, SOL_SOCKET, SO_TYPE, create_connection, _GLOBAL_DEFAULT_TIMEOUT
socket_error = OSError

def RAND_bytes(n):
    """Generate n cryptographically strong pseudo-random bytes."""
    if isinstance(n, bool) or not isinstance(n, int):
        raise TypeError("'" + type(n).__name__ + "' object cannot be interpreted as an integer")
    return _tls_rand("bytes", n)

def RAND_pseudo_bytes(n):
    """Generate n pseudo-random bytes: (bytes, is_cryptographic)."""
    if isinstance(n, bool) or not isinstance(n, int):
        raise TypeError("'" + type(n).__name__ + "' object cannot be interpreted as an integer")
    import warnings
    warnings.warn("ssl.RAND_pseudo_bytes() is deprecated", DeprecationWarning, stacklevel=2)
    return tuple(_tls_rand("pseudo", n))

def RAND_status():
    """Returns True if the OpenSSL PRNG has been seeded with enough data."""
    return _tls_rand("status")

def RAND_add(string, entropy):
    """Mix string into the OpenSSL PRNG state."""
    if isinstance(string, str):
        string = string.encode("utf-8")
    elif not isinstance(string, (bytes, bytearray)):
        string = _ny_bytes_like(string)
    if isinstance(entropy, str) or not isinstance(entropy, (int, float)):
        raise TypeError("must be real number, not " + type(entropy).__name__)
    _tls_rand("add", bytes(string), float(entropy))

OPENSSL_VERSION_NUMBER = _tls_rand("version_num")
def _version_info(n):
    var status = n & 15
    n = n >> 4
    var patch = n & 255
    n = n >> 8
    var fix = n & 255
    n = n >> 8
    var minor = n & 255
    n = n >> 8
    return (n & 255, minor, fix, patch, status)
OPENSSL_VERSION_INFO = _version_info(OPENSSL_VERSION_NUMBER)
_OPENSSL_API_VERSION = OPENSSL_VERSION_INFO

PROTOCOL_SSLv23 = PROTOCOL_TLS
PROTOCOL_TLSv1 = 3
PROTOCOL_TLSv1_1 = 4
PROTOCOL_TLSv1_2 = 5
_PROTOCOL_NAMES = {2: "PROTOCOL_TLS", 3: "PROTOCOL_TLSv1", 4: "PROTOCOL_TLSv1_1", 5: "PROTOCOL_TLSv1_2",
                   16: "PROTOCOL_TLS_CLIENT", 17: "PROTOCOL_TLS_SERVER"}

def get_protocol_name(protocol_code):
    return _PROTOCOL_NAMES.get(protocol_code, "<unknown>")

HAS_ECDH = True
HAS_NEVER_CHECK_COMMON_NAME = True
HAS_NPN = False
HAS_SSLv2 = False
HAS_SSLv3 = False
HAS_TLSv1 = True
HAS_TLSv1_1 = True
CHANNEL_BINDING_TYPES = ["tls-unique"]

OP_ALL = 2147483728
OP_CIPHER_SERVER_PREFERENCE = 4194304
OP_ENABLE_KTLS = 8
OP_ENABLE_MIDDLEBOX_COMPAT = 1048576
OP_IGNORE_UNEXPECTED_EOF = 128
OP_LEGACY_SERVER_CONNECT = 4
OP_NO_COMPRESSION = 131072
OP_NO_RENEGOTIATION = 1073741824
OP_NO_SSLv2 = 0
OP_NO_SSLv3 = 33554432
OP_NO_TICKET = 16384
OP_NO_TLSv1 = 67108864
OP_NO_TLSv1_1 = 268435456
OP_NO_TLSv1_2 = 134217728
OP_NO_TLSv1_3 = 536870912
OP_SINGLE_DH_USE = 0
OP_SINGLE_ECDH_USE = 0

ALERT_DESCRIPTION_CLOSE_NOTIFY = 0
ALERT_DESCRIPTION_UNEXPECTED_MESSAGE = 10
ALERT_DESCRIPTION_BAD_RECORD_MAC = 20
ALERT_DESCRIPTION_RECORD_OVERFLOW = 22
ALERT_DESCRIPTION_DECOMPRESSION_FAILURE = 30
ALERT_DESCRIPTION_HANDSHAKE_FAILURE = 40
ALERT_DESCRIPTION_BAD_CERTIFICATE = 42
ALERT_DESCRIPTION_UNSUPPORTED_CERTIFICATE = 43
ALERT_DESCRIPTION_CERTIFICATE_REVOKED = 44
ALERT_DESCRIPTION_CERTIFICATE_EXPIRED = 45
ALERT_DESCRIPTION_CERTIFICATE_UNKNOWN = 46
ALERT_DESCRIPTION_ILLEGAL_PARAMETER = 47
ALERT_DESCRIPTION_UNKNOWN_CA = 48
ALERT_DESCRIPTION_ACCESS_DENIED = 49
ALERT_DESCRIPTION_DECODE_ERROR = 50
ALERT_DESCRIPTION_DECRYPT_ERROR = 51
ALERT_DESCRIPTION_PROTOCOL_VERSION = 70
ALERT_DESCRIPTION_INSUFFICIENT_SECURITY = 71
ALERT_DESCRIPTION_INTERNAL_ERROR = 80
ALERT_DESCRIPTION_USER_CANCELLED = 90
ALERT_DESCRIPTION_NO_RENEGOTIATION = 100
ALERT_DESCRIPTION_UNSUPPORTED_EXTENSION = 110
ALERT_DESCRIPTION_CERTIFICATE_UNOBTAINABLE = 111
ALERT_DESCRIPTION_UNRECOGNIZED_NAME = 112
ALERT_DESCRIPTION_BAD_CERTIFICATE_STATUS_RESPONSE = 113
ALERT_DESCRIPTION_BAD_CERTIFICATE_HASH_VALUE = 114
ALERT_DESCRIPTION_UNKNOWN_PSK_IDENTITY = 115

SSL_ERROR_SSL = 1
SSL_ERROR_WANT_READ = 2
SSL_ERROR_WANT_WRITE = 3
SSL_ERROR_WANT_X509_LOOKUP = 4
SSL_ERROR_SYSCALL = 5
SSL_ERROR_ZERO_RETURN = 6
SSL_ERROR_WANT_CONNECT = 7
SSL_ERROR_EOF = 8
SSL_ERROR_INVALID_ERROR_CODE = 10

VERIFY_DEFAULT = 0
VERIFY_CRL_CHECK_LEAF = 4
VERIFY_CRL_CHECK_CHAIN = 12
VERIFY_X509_STRICT = 32
VERIFY_ALLOW_PROXY_CERTS = 64
VERIFY_X509_TRUSTED_FIRST = 32768
VERIFY_X509_PARTIAL_CHAIN = 524288

PEM_HEADER = "-----BEGIN CERTIFICATE-----"
PEM_FOOTER = "-----END CERTIFICATE-----"

def DER_cert_to_PEM_cert(der_cert_bytes):
    """Takes a certificate in binary DER format and returns the
    PEM version of it as a string."""
    import base64
    var f = str(base64.standard_b64encode(der_cert_bytes), "ASCII", "strict")
    var ss = [PEM_HEADER]
    var i = 0
    while i < len(f):
        ss.append(f[i:i + 64])
        i += 64
    ss.append(PEM_FOOTER + "\n")
    return "\n".join(ss)

def PEM_cert_to_DER_cert(pem_cert_string):
    """Takes a certificate in ASCII PEM format and returns the
    DER-encoded version of it as a byte sequence"""
    import base64
    if not pem_cert_string.startswith(PEM_HEADER):
        raise ValueError("Invalid PEM encoding; must start with " + PEM_HEADER)
    if not pem_cert_string.strip().endswith(PEM_FOOTER):
        raise ValueError("Invalid PEM encoding; must end with " + PEM_FOOTER)
    var d = pem_cert_string.strip()[len(PEM_HEADER):-len(PEM_FOOTER)]
    return base64.decodebytes(d.encode("ASCII", "strict"))

def cert_time_to_seconds(cert_time):
    """Return the time in seconds since the Epoch, given the timestring
    representing the "notBefore" or "notAfter" date from a certificate
    in ``"%b %d %H:%M:%S %Y %Z"`` strptime format (C locale)."""
    from time import strptime
    from calendar import timegm
    var months = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    var time_format = " %d %H:%M:%S %Y GMT"
    var month_number = 0
    try:
        month_number = months.index(cert_time[:3].title()) + 1
    except ValueError:
        raise ValueError("time data " + repr(cert_time) + " does not match format \"%b" + time_format + "\"")
    var tt = strptime(cert_time[3:], time_format)
    return timegm((tt[0], month_number) + tuple(tt[2:6]))

def wrap_socket(sock, keyfile=None, certfile=None, server_side=False, cert_reqs=CERT_NONE, ssl_version=PROTOCOL_TLS,
                ca_certs=None, do_handshake_on_connect=True, suppress_ragged_eofs=True, ciphers=None):
    """3.11's module-level wrap_socket (deprecated; removed in 3.12)."""
    import warnings
    warnings.warn("ssl.wrap_socket() is deprecated, use SSLContext.wrap_socket()", category=DeprecationWarning, stacklevel=2)
    if server_side and not certfile:
        raise ValueError("certfile must be specified for server-side operations")
    if keyfile and not certfile:
        raise ValueError("certfile must be specified")
    var context = SSLContext(ssl_version)
    context.verify_mode = cert_reqs
    if ca_certs:
        context.load_verify_locations(ca_certs)
    if certfile:
        context.load_cert_chain(certfile, keyfile)
    if ciphers:
        context.set_ciphers(ciphers)
    return context.wrap_socket(sock, server_side=server_side, do_handshake_on_connect=do_handshake_on_connect,
                               suppress_ragged_eofs=suppress_ragged_eofs)

def get_server_certificate(addr, ssl_version=PROTOCOL_TLS_CLIENT, ca_certs=None, timeout=_GLOBAL_DEFAULT_TIMEOUT):
    """Retrieve the certificate from the server at the specified address,
    and return it as a PEM-encoded string."""
    var host = addr[0]
    var port = addr[1]
    var context = SSLContext(ssl_version)
    if ca_certs is not None:
        context.verify_mode = CERT_REQUIRED
        context.load_verify_locations(ca_certs)
    else:
        context.check_hostname = False
        context.verify_mode = CERT_NONE
    var sock = create_connection(addr, timeout=timeout)
    try:
        var sslsock = context.wrap_socket(sock, server_hostname=host)
        try:
            return DER_cert_to_PEM_cert(sslsock.getpeercert(True))
        finally:
            sslsock.close()
    finally:
        sock.close()

# the enums (CPython's _IntEnum._convert_ / _IntFlag._convert_): the
# constants stay ints here, the enums are made when first asked for
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
    _enums["Options"] = enum.IntFlag("Options", pick(lambda n: n.startswith("OP_")), module="ssl")
    _enums["AlertDescription"] = enum.IntEnum("AlertDescription",
        pick(lambda n: n.startswith("ALERT_DESCRIPTION_")), module="ssl")
    _enums["SSLErrorNumber"] = enum.IntEnum("SSLErrorNumber", pick(lambda n: n.startswith("SSL_ERROR_")), module="ssl")
    _enums["VerifyFlags"] = enum.IntFlag("VerifyFlags", pick(lambda n: n.startswith("VERIFY_")), module="ssl")
    _enums["VerifyMode"] = enum.IntEnum("VerifyMode", pick(lambda n: n.startswith("CERT_")), module="ssl")
    return _enums

def __getattr__(name):
    if name in ("Options", "AlertDescription", "SSLErrorNumber", "VerifyFlags", "VerifyMode"):
        return _make_enums()[name]
    raise AttributeError("module 'ssl' has no attribute '" + name + "'")

def __dir__():
    var names = list(globals())
    names.extend(["Options", "AlertDescription", "SSLErrorNumber", "VerifyFlags", "VerifyMode"])
    return sorted(names)
