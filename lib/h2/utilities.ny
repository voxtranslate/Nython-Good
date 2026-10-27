# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/utilities.ny - HTTP/2 field validation (RFC 9113 8.2, 8.3; round 86).
#
# validate_headers(headers, kind) raises ProtocolError for a malformed field
# block: kind is "request", "response", "informational", "trailers" or
# "push" (a PUSH_PROMISE's request). Checked: field names lowercase and
# made of token characters (a leading ":" for pseudo-headers), values
# without NUL/CR/LF and without leading or trailing whitespace; pseudo-
# headers before regular fields, defined for the kind, each at most once;
# no connection-specific fields (Connection, Keep-Alive, Proxy-Connection,
# Transfer-Encoding, Upgrade); TE only "trailers"; requests with :method,
# :scheme and a non-empty :path (CONNECT: :authority and neither :scheme nor
# :path, unless RFC 8441's :protocol), Host equal to :authority when both
# are there; responses with a three-digit :status that is not 101; no
# pseudo-headers in trailers.
from h2.exceptions import ProtocolError

_CONNECTION_HEADERS = frozenset([b"connection", b"proxy-connection", b"keep-alive", b"transfer-encoding", b"upgrade"])
_REQUEST_PSEUDO = frozenset([b":method", b":scheme", b":authority", b":path", b":protocol"])
_RESPONSE_PSEUDO = frozenset([b":status"])
# tchar (RFC 9110 5.6.2) minus the uppercase letters
_TOKEN = frozenset(b"!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz")
_UPPER = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ")


def to_bytes(v, encoding="utf-8"):
    if isinstance(v, bytes):
        return v
    if isinstance(v, (bytearray, memoryview)):
        return bytes(v)
    return str(v).encode(encoding)


def normalize_outbound(headers, split_cookies=False):
    """(name, value) pairs as bytes, names lowercased; HeaderTuple kinds
    (never-indexed fields) are kept."""
    import hpack
    out = []
    for h in headers:
        name = to_bytes(h[0]).lower()
        value = to_bytes(h[1])
        if split_cookies and name == b"cookie" and b"; " in value:
            for crumb in value.split(b"; "):
                out.append(hpack.HeaderTuple(name, crumb) if not isinstance(h, hpack.NeverIndexedHeaderTuple)
                           else hpack.NeverIndexedHeaderTuple(name, crumb))
            continue
        if isinstance(h, hpack.NeverIndexedHeaderTuple):
            out.append(hpack.NeverIndexedHeaderTuple(name, value))
        elif not isinstance(h, hpack.HeaderTuple) and len(h) > 2 and h[2]:
            out.append(hpack.NeverIndexedHeaderTuple(name, value))
        else:
            out.append((name, value))
    return out


def join_cookies(headers):
    """Cookie crumbs joined with "; " (RFC 9113 8.2.3), the first one's place kept."""
    crumbs = [h[1] for h in headers if h[0] == b"cookie"]
    if len(crumbs) < 2:
        return headers
    out = []
    done = False
    for h in headers:
        if h[0] == b"cookie":
            if not done:
                out.append(h.__class__(b"cookie", b"; ".join(crumbs)) if h.__class__ is not tuple else (b"cookie", b"; ".join(crumbs)))
                done = True
            continue
        out.append(h)
    return out


def validate_headers(headers, kind, connect_protocol=False):
    seen_regular = False
    pseudo = {}
    host = None
    for h in headers:
        name = h[0]
        value = h[1]
        if not name:
            raise ProtocolError("Received header name of length zero")
        if name[0] == 58:   # ':'
            if seen_regular:
                raise ProtocolError("Received pseudo-header in a field block after a regular header: %r" % (name,))
            if name in pseudo:
                raise ProtocolError("Received duplicate pseudo-header field %r" % (name,))
            if kind == "trailers":
                raise ProtocolError("Received pseudo-header in trailers: %r" % (name,))
            allowed = _REQUEST_PSEUDO if kind in ("request", "push") else _RESPONSE_PSEUDO
            if name not in allowed:
                if name in _REQUEST_PSEUDO or name in _RESPONSE_PSEUDO:
                    raise ProtocolError("Received unexpected pseudo-header %r in a %s" % (name, kind))
                raise ProtocolError("Received custom pseudo-header field %r" % (name,))
            pseudo[name] = value
            body = name[1:]
        else:
            seen_regular = True
            body = name
            if name in _CONNECTION_HEADERS:
                raise ProtocolError("Connection-specific header field present: %r." % (name,))
            if name == b"te" and value.lower() != b"trailers":
                raise ProtocolError("Invalid value for header te: %r" % (value,))
            if name == b"host":
                host = value
        for c in body:
            if c not in _TOKEN:
                if c in _UPPER:
                    raise ProtocolError("Received uppercase header name %r." % (name,))
                raise ProtocolError("Invalid character in header name %r" % (name,))
        if b"\x00" in value or b"\r" in value or b"\n" in value:
            raise ProtocolError("Invalid character in header value of %r" % (name,))
        if value and (value[0] in (32, 9) or value[-1] in (32, 9)):
            raise ProtocolError("Received header value surrounded by whitespace %r" % (value,))
    if kind in ("request", "push"):
        method = pseudo.get(b":method")
        if method is None:
            raise ProtocolError("Header block missing mandatory :method header")
        protocol = pseudo.get(b":protocol")
        if protocol is not None and (method != b"CONNECT" or not connect_protocol):
            raise ProtocolError("Received :protocol header without an extended CONNECT")
        if method == b"CONNECT" and protocol is None:
            if b":authority" not in pseudo:
                raise ProtocolError("Header block missing mandatory :authority header")
            if b":scheme" in pseudo or b":path" in pseudo:
                raise ProtocolError("A CONNECT request must not have :scheme or :path")
        else:
            for p in (b":scheme", b":path"):
                if p not in pseudo:
                    raise ProtocolError("Header block missing mandatory %s header" % p.decode())
            path = pseudo[b":path"]
            if not path:
                raise ProtocolError("An empty :path header is forbidden")
            if pseudo[b":scheme"] in (b"http", b"https") and path[0] != 47 and not (path == b"*" and method == b"OPTIONS"):
                raise ProtocolError("Invalid :path %r" % (path,))
        if host is not None and b":authority" in pseudo and host != pseudo[b":authority"]:
            raise ProtocolError("Request header block has a Host field that differs from :authority")
    elif kind in ("response", "informational"):
        status = pseudo.get(b":status")
        if status is None:
            raise ProtocolError("Header block missing mandatory :status header")
        if len(status) != 3 or not status.isdigit():
            raise ProtocolError("Invalid :status %r" % (status,))
        if status == b"101":
            raise ProtocolError("HTTP/2 does not allow a 101 (Switching Protocols) response")


def content_length(headers):
    """The Content-Length of a field block (None when absent); ProtocolError
    for an invalid one or several that differ."""
    found = None
    for h in headers:
        if h[0] == b"content-length":
            for part in h[1].split(b","):
                part = part.strip()
                if not part.isdigit():
                    raise ProtocolError("Invalid content-length header: %r" % (h[1],))
                n = int(part)
                if found is not None and found != n:
                    raise ProtocolError("Conflicting content-length headers")
                found = n
    return found


def header_value(headers, name):
    for h in headers:
        if h[0] == name:
            return h[1]
    return None


def is_informational(headers):
    s = header_value(headers, b":status")
    return s is not None and s[:1] == b"1"
