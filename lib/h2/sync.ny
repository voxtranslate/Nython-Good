# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/sync.ny - a blocking HTTP/2 client session over a socket (round 86):
# what http.client.HTTPConnection / HTTPSConnection(http2=...) and
# urllib.request use once a server has agreed to speak HTTP/2.
#
#     s = SyncConnection(sock, "example.org", "https")      sock: connected
#     sid = s.request("GET", "/", [("accept", "*/*")])
#     status, headers = s.response_headers(sid)
#     body = s.read(sid)
#
# request(method, path, headers, body=None) -> stream id: the body (bytes,
# str, a file object or an iterable of chunks) is sent as the peer's flow
# control allows, waiting for its WINDOW_UPDATEs; several requests may be
# open at once (they are multiplexed, read them in any order).
# response_headers(sid) -> (status, [(name, value)]) (1xx skipped, kept in
# informational(sid)); read(sid, amt=None) -> bytes (b"" at the end);
# trailers(sid); ended(sid); release(sid) forgets a stream read to its end;
# close() sends GOAWAY.
# Header names and values are str (latin-1 on the wire as HTTP/1.1 has it);
# connection-specific fields (Connection, Keep-Alive, Proxy-Connection,
# Transfer-Encoding, Upgrade) are dropped and Host becomes :authority (RFC
# 9113 8.2.2, 8.3.1). Errors: h2._aio's StreamResetError (RST_STREAM) and
# ConnectionClosedError (GOAWAY with an error, EOF), ProtocolError.
import h2.config
import h2.connection
import h2.events
import h2.exceptions
from h2._aio import StreamResetError, ConnectionClosedError

_DROP = frozenset(["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "host"])


class _S:
    def __init__(self):
        self.headers = None
        self.informational = []
        self.chunks = []
        self.ended = False
        self.reset = None
        self.trailers = None


class SyncConnection:
    def __init__(self, sock, authority, scheme="https", settings=None):
        self.sock = sock
        self.authority = authority
        self.scheme = scheme
        self.conn = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True, header_encoding="iso-8859-1"))
        if settings:
            for k in settings:
                self.conn.local_settings[k] = settings[k]
            self.conn.local_settings.acknowledge()
        self.conn.initiate_connection()
        self.streams = {}
        self.closed_error = None
        self.terminated = None
        self.blocked = 0
        self._flush()

    def _flush(self):
        data = self.conn.data_to_send()
        if data:
            try:
                self.sock.sendall(data)
            except OSError as e:
                self.closed_error = ConnectionClosedError("connection lost: %s" % e)
                raise self.closed_error

    def _pump(self):
        if self.closed_error is not None:
            raise self.closed_error
        try:
            data = self.sock.recv(65536)
        except OSError as e:
            self.closed_error = ConnectionClosedError("connection lost: %s" % e)
            raise self.closed_error
        if not data:
            self.closed_error = ConnectionClosedError("the server closed the connection")
            raise self.closed_error
        try:
            events = self.conn.receive_data(data)
        except h2.exceptions.ProtocolError as e:
            self._flush()
            self.closed_error = ConnectionClosedError("protocol error: %s" % e, e.error_code)
            raise self.closed_error
        for ev in events:
            s = self.streams.get(getattr(ev, "stream_id", None) or -1)
            if isinstance(ev, h2.events.ResponseReceived):
                if s is not None:
                    s.headers = list(ev.headers)
            elif isinstance(ev, h2.events.InformationalResponseReceived):
                if s is not None:
                    s.informational.append(list(ev.headers))
            elif isinstance(ev, h2.events.TrailersReceived):
                if s is not None:
                    s.trailers = list(ev.headers)
            elif isinstance(ev, h2.events.DataReceived):
                if s is not None:
                    s.chunks.append([ev.data, ev.flow_controlled_length])
                else:
                    self.conn.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
            elif isinstance(ev, h2.events.StreamEnded):
                if s is not None:
                    s.ended = True
            elif isinstance(ev, h2.events.StreamReset):
                if s is not None:
                    s.reset = (ev.error_code, ev.remote_reset)
            elif isinstance(ev, h2.events.ConnectionTerminated):
                self.terminated = ev
                if ev.error_code != 0:
                    self.closed_error = ConnectionClosedError("the server sent GOAWAY %s" % ev.error_code, ev.error_code,
                                                              ev.last_stream_id)
        self._flush()

    def _check(self, sid, s):
        if s.reset is not None:
            raise StreamResetError(sid, s.reset[0], s.reset[1])

    def request(self, method, path, headers=(), body=None):
        """Open a stream for a request; the body is sent before this returns."""
        if self.closed_error is not None:
            raise self.closed_error
        authority = self.authority
        fields = []
        for name, value in headers:
            n = str(name).lower()
            if n == "host":
                authority = str(value)
                continue
            if n in _DROP:
                continue
            if n == "te" and str(value).lower() != "trailers":
                continue
            fields.append((n, str(value)))
        pseudo = [(":method", method), (":scheme", self.scheme), (":authority", authority), (":path", path or "/")]
        if method == "CONNECT":
            pseudo = [(":method", method), (":authority", authority)]
        chunks = _chunks(body)
        sid = self.conn.get_next_available_stream_id()
        self.streams[sid] = _S()
        self.conn.send_headers(sid, pseudo + fields, end_stream=chunks is None)
        self._flush()
        if chunks is not None:
            for chunk in chunks:
                self._send_body(sid, chunk)
            self.conn.end_stream(sid)
            self._flush()
        return sid

    def _send_body(self, sid, data):
        s = self.streams[sid]
        view = memoryview(data)
        while len(view):
            self._check(sid, s)
            w = self.conn.local_flow_control_window(sid)
            if w <= 0:
                self.blocked += 1
                self._pump()
                continue
            n = min(len(view), w, self.conn.max_outbound_frame_size)
            self.conn.send_data(sid, bytes(view[:n]))
            view = view[n:]
            self._flush()

    def response_headers(self, sid):
        """(status, headers) of a stream's final response."""
        s = self.streams[sid]
        while s.headers is None:
            self._check(sid, s)
            if s.ended:
                raise ConnectionClosedError("the stream ended without a response")
            self._pump()
        status = 0
        out = []
        for n, v in s.headers:
            if n == ":status":
                status = int(v)
            elif not n.startswith(":"):
                out.append((n, v))
        return status, out

    def informational(self, sid):
        return self.streams[sid].informational

    def trailers(self, sid):
        return self.streams[sid].trailers

    def ended(self, sid):
        s = self.streams.get(sid)
        return s is None or (s.ended and not s.chunks)

    def read(self, sid, amt=None):
        """Up to amt octets of the body (all of the rest without amt); b"" at its end."""
        s = self.streams.get(sid)
        if s is None:
            return b""
        out = []
        n = 0
        while amt is None or n < amt:
            if s.chunks:
                c = s.chunks[0]
                if c[1]:
                    # a frame is acknowledged once the application takes from it
                    self.conn.acknowledge_received_data(c[1], sid)
                    c[1] = 0
                    self._flush()
                data = c[0]
                if amt is not None and n + len(data) > amt:
                    take = amt - n
                    c[0] = data[take:]
                    data = data[:take]
                else:
                    s.chunks.pop(0)
                if data:
                    out.append(data)
                    n += len(data)
                continue
            if s.ended:
                break
            self._check(sid, s)
            self._pump()
        return b"".join(out)

    def release(self, sid):
        """Forget a finished stream (its trailers and the rest)."""
        self.streams.pop(sid, None)

    def close(self):
        if self.closed_error is None:
            try:
                self.conn.close_connection()
                self._flush()
            except (h2.exceptions.ProtocolError, ConnectionClosedError, OSError):
                pass
        self.closed_error = self.closed_error or ConnectionClosedError("the connection was closed")


def _chunks(body):
    if body is None:
        return None
    if isinstance(body, str):
        body = body.encode("iso-8859-1")
    if isinstance(body, (bytes, bytearray, memoryview)):
        return [bytes(body)] if len(body) else None
    if hasattr(body, "read"):
        out = []
        while True:
            c = body.read(65536)
            if not c:
                break
            out.append(c.encode("iso-8859-1") if isinstance(c, str) else bytes(c))
        return out
    out = []
    for c in body:
        out.append(c.encode("iso-8859-1") if isinstance(c, str) else bytes(c))
    return out
