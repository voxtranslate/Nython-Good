# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/client.ny - an asyncio HTTP/2 client over h2.connection (round 86).
#
#     import asyncio, h2.client
#     async def main():
#         r = await h2.client.request("GET", "https://localhost:8443/", ssl=ctx)
#         print(r.status, r.headers, r.body)
#         async with await h2.client.connect("localhost", 8443, ssl=ctx) as c:
#             a, b = await asyncio.gather(c.request("GET", "/a"), c.request("GET", "/b"))
#     asyncio.run(main())
#
# connect(host, port, ssl=None, server_hostname=None, settings=None,
#         prior_knowledge=True) -> ClientConnection. With ssl (an SSLContext,
#         or True for the default one) TLS is negotiated with ALPN "h2" (RFC
#         9113 3.2) and a server that does not select it is refused
#         (NegotiationError); without, the connection preface is sent at once
#         ("prior knowledge" h2c, 3.3).
# ClientConnection.request(method, path, headers=(), body=b"", trailers=None,
#         priority=None, authority=None, scheme=None) -> Response: one stream,
#         multiplexed with the others the connection has open; priority
#         (urgency, incremental) adds RFC 9218's Priority header.
# ClientConnection.open_stream(method, path, headers=(), end_stream=False,
#         priority=None) -> ClientStream: write()/end()/response()/read()/
#         reset() for bodies streamed either way.
# ClientConnection.ping() -> RTT; .prioritize(stream_id, urgency, incremental)
#         (PRIORITY_UPDATE); .close() (GOAWAY NO_ERROR); async with.
# request(method, url, headers=None, body=None, ssl=None, ...) -> Response:
#         connect, one request, close.
# Response: status (int), headers (list of (name, value) str), body (bytes),
#         trailers, informational (the 1xx field blocks), stream_id;
#         header(name), text(), json().
# Errors: StreamResetError (RST_STREAM: .error_code, .remote; REFUSED_STREAM
#         after a GOAWAY is safe to retry), ConnectionClosedError,
#         NegotiationError.
import asyncio
import json as _json

import h2.config
import h2.connection
import h2.events
from h2.errors import ErrorCodes
from h2.settings import SettingCodes
from h2.priority import serialize_priority
from h2 import _aio
from h2._aio import StreamResetError, ConnectionClosedError, header

__all__ = ["connect", "request", "ClientConnection", "ClientStream", "Response", "StreamResetError",
           "ConnectionClosedError", "NegotiationError"]


class NegotiationError(ConnectionError):
    """TLS did not negotiate "h2" with ALPN."""


class Response:
    def __init__(self, stream_id, headers, body, trailers=None, informational=None):
        self.stream_id = stream_id
        self.headers = [h for h in headers if not h[0].startswith(":")]
        self.raw_headers = headers
        self.status = int(header(headers, ":status", "0"))
        self.body = body
        self.trailers = trailers
        self.informational = informational or []

    def header(self, name, default=None):
        return header(self.headers, name, default)

    def text(self, encoding="utf-8"):
        return self.body.decode(encoding)

    def json(self):
        return _json.loads(self.body.decode("utf-8"))

    def __repr__(self):
        return "<h2.client.Response [%d] stream %d, %d bytes>" % (self.status, self.stream_id, len(self.body))


class ClientStream(_aio.Stream):
    """A request stream: write()/end() the body, response() for the headers."""
    async def response_headers(self):
        while self.headers is None:
            self._check_reset()
            if self.driver.closed_error is not None and not self.ended:
                raise self.driver.closed_error
            if self.ended:
                break
            self._headers_ready.clear()
            await self._headers_ready.wait()
        self._check_reset()
        return self.headers

    async def response(self):
        """The whole response (headers, body, trailers)."""
        headers = await self.response_headers()
        body = await self.read()
        if headers is None:
            raise ConnectionClosedError("the stream ended without a response")
        return Response(self.stream_id, headers, body, self.trailers, self.informational)


class ClientConnection(_aio.Driver):
    def __init__(self, conn, reader, writer, host, port, scheme):
        _aio.Driver.__init__(self, conn, reader, writer)
        self.host = host
        self.port = port
        self.scheme = scheme
        default = 443 if scheme == "https" else 80
        self.authority = host if port == default else "%s:%d" % (host if ":" not in host else "[" + host + "]", port)
        self.alpn = None

    def on_event(self, ev, s):
        if s is None:
            return
        if isinstance(ev, h2.events.ResponseReceived):
            s.headers = _aio._str_headers(ev.headers)
            s._headers_ready.set()
        elif isinstance(ev, h2.events.InformationalResponseReceived):
            s.informational.append(_aio._str_headers(ev.headers))
        elif isinstance(ev, h2.events.TrailersReceived):
            s.trailers = _aio._str_headers(ev.headers)

    def on_goaway(self, ev):
        if ev.error_code != 0:
            self._fail_all(ConnectionClosedError("the server closed the connection: GOAWAY %s" % (
                _aio.code_name(ev.error_code),), ev.error_code, ev.last_stream_id))

    async def open_stream(self, method, path, headers=(), end_stream=False, priority=None,
                          authority=None, scheme=None):
        """Send a request's field block; the stream to write the body on."""
        if self.closed_error is not None:
            raise self.closed_error
        if self.terminated is not None:
            raise ConnectionClosedError("the server sent GOAWAY: no new streams", self.terminated.error_code,
                                        self.terminated.last_stream_id)
        fields = [(":method", method), (":scheme", scheme or self.scheme),
                  (":authority", authority or self.authority), (":path", path)]
        if method == "CONNECT":
            fields = [(":method", method), (":authority", authority or self.authority)]
        for h in headers:
            fields.append(h)
        if priority is not None:
            v = serialize_priority(priority[0], priority[1])
            if v:
                fields.append(("priority", v))
        sid = self.conn.get_next_available_stream_id()
        s = ClientStream(self, sid)
        self.streams[sid] = s
        self.conn.send_headers(sid, fields, end_stream=end_stream)
        if end_stream:
            s._out_end = True
            s._out_closed = True
            s._sent_all.set()
        self._flush()
        return s

    async def request(self, method, path, headers=(), body=b"", trailers=None, priority=None,
                      authority=None, scheme=None):
        """One request and its whole response."""
        if isinstance(body, str):
            body = body.encode("utf-8")
        body = body or b""
        hdrs = list(headers)
        if body and not any(h[0].lower() == "content-length" for h in hdrs):
            hdrs.append(("content-length", str(len(body))))
        no_body = not body and trailers is None
        s = await self.open_stream(method, path, hdrs, end_stream=no_body, priority=priority,
                                   authority=authority, scheme=scheme)
        if not no_body:
            if body:
                await s.write(body)
            s.end(trailers)
        return await s.response()

    def prioritize(self, stream_id, urgency=3, incremental=False):
        """Send an RFC 9218 PRIORITY_UPDATE for a stream."""
        self.conn.send_priority_update(stream_id, urgency, incremental)
        self._flush()

    async def close(self):
        await self.aclose(0)

    async def __aenter__(self):
        return self

    async def __aexit__(self, a, b, c):
        await self.close()
        return False


async def connect(host, port=None, ssl=None, server_hostname=None, settings=None, prior_knowledge=True,
                  header_table_size=None):
    """An HTTP/2 connection to host:port (see the module header)."""
    import ssl as _ssl
    scheme = "https" if ssl else "http"
    if port is None:
        port = 443 if ssl else 80
    ctx = None
    if ssl:
        ctx = ssl
        if ctx is True:
            ctx = _ssl.create_default_context()
        ctx.set_alpn_protocols(["h2"])
    if ctx is not None:
        reader, writer = await asyncio.open_connection(host, port, ssl=ctx, server_hostname=server_hostname or host)
    else:
        reader, writer = await asyncio.open_connection(host, port)
    alpn = None
    if ctx is not None:
        so = writer.get_extra_info("ssl_object")
        alpn = so.selected_alpn_protocol() if so is not None else None
        if alpn != "h2":
            writer.close()
            raise NegotiationError("the server did not select h2 with ALPN (got %r)" % (alpn,))
    conn = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True, header_encoding="utf-8"))
    if settings:
        for k in settings:
            conn.local_settings[k] = settings[k]
        conn.local_settings.acknowledge()
    conn.initiate_connection()
    c = ClientConnection(conn, reader, writer, host, port, scheme)
    c.alpn = alpn
    c._flush()
    c.start()
    return c


async def request(method, url, headers=None, body=None, ssl=None, trailers=None, priority=None, timeout=None):
    """One request on a connection of its own: the Response."""
    import urllib.parse
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https"):
        raise ValueError("unsupported URL scheme %r" % u.scheme)
    if u.scheme == "https" and not ssl:
        ssl = True
    if u.scheme == "http":
        ssl = None
    port = u.port or (443 if u.scheme == "https" else 80)
    path = u.path or "/"
    if u.query:
        path += "?" + u.query
    hdrs = []
    if headers:
        items = headers.items() if isinstance(headers, dict) else headers
        for k, v in items:
            hdrs.append((k.lower(), v))

    async def go():
        c = await connect(u.hostname, port, ssl=ssl)
        try:
            return await c.request(method, path, hdrs, body or b"", trailers=trailers, priority=priority)
        finally:
            await c.close()
    if timeout is not None:
        return await asyncio.wait_for(go(), timeout)
    return await go()
