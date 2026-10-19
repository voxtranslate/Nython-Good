# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/websocket_asyncio.ny - WebSockets for asyncio (RFC 6455 + RFC 7692;
# round 86), the shape of the websockets package's asyncio API.
#
#     import asyncio, websocket_asyncio as ws
#     async def echo(conn):
#         async for message in conn:
#             await conn.send(message)
#     async def main():
#         async with ws.serve(echo, "127.0.0.1", 8765) as server:
#             async with ws.connect("ws://127.0.0.1:8765/") as c:
#                 await c.send("hello")
#                 print(await c.recv())
#     asyncio.run(main())
#
# connect(uri, origin=None, subprotocols=None, additional_headers=None,
#     ssl=None, server_hostname=None, compression="deflate", extensions=None,
#     max_size=2**20, max_queue=16, open_timeout=10, close_timeout=10,
#     user_agent_header=...) - awaitable and an async context manager.
# serve(handler, host, port, ssl=None, subprotocols=None, origins=None,
#     process_request=None, compression="deflate", extensions=None, ...) ->
#     Server (async with; close(), wait_closed(), serve_forever(), port,
#     connections, broadcast()). handler(conn) is a coroutine per
#     connection; process_request(conn, request) may answer with an HTTP
#     Response instead of upgrading.
# Connection: send(str | bytes | iterable or async iterable of fragments),
#     recv(), async for, ping(data=None) -> a future resolved with the RTT on
#     pong, pong(data), close(code=1000, reason=""), wait_closed(), state,
#     close_code, close_reason, subprotocol, extension (PerMessageDeflate or
#     None), request, response, remote_address, latency.
# The protocol as lib/websocket.ny implements it (masking enforced, control
# frames <= 125 bytes and unfragmented, close codes validated, UTF-8 checked
# (1007), max_size (1009, after decompression), the closing handshake);
# permessage-deflate negotiated and applied by lib/permessage_deflate.ny.
# Exceptions: ConnectionClosed (ConnectionClosedOK / ConnectionClosedError,
# .rcvd/.sent Close frames), InvalidHandshake, InvalidURI, InvalidStatus,
# InvalidHeader, NegotiationError, ProtocolError, PayloadTooBig.
#
# Not here: the HTTP/2 extended CONNECT bootstrap (RFC 8441), keepalive pings
# on a timer (call ping() yourself), the sans-I/O protocol object the
# websockets package exposes.
#
# Written in the subset of the language CPython also runs (vm_audit123 runs it
# under python3 as well).
import asyncio
import base64
import hashlib
import os
import urllib.parse

import permessage_deflate as _pmd

__all__ = ["connect", "serve", "Connection", "Server", "ConnectionClosed", "ConnectionClosedOK",
           "ConnectionClosedError", "InvalidHandshake", "InvalidURI", "InvalidStatus", "InvalidHeader",
           "NegotiationError", "ProtocolError", "PayloadTooBig", "Close", "Request", "Response"]

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OP_CONT = 0
OP_TEXT = 1
OP_BINARY = 2
OP_CLOSE = 8
OP_PING = 9
OP_PONG = 10
CONNECTING = 0
OPEN = 1
CLOSING = 2
CLOSED = 3
USER_AGENT = "Nython-websocket-asyncio/0.1"


class Close:
    def __init__(self, code, reason=""):
        self.code = code
        self.reason = reason

    def __repr__(self):
        return "Close(code=%d, reason=%r)" % (self.code, self.reason)


class WebSocketException(Exception):
    pass


class ConnectionClosed(WebSocketException):
    def __init__(self, rcvd, sent):
        self.rcvd = rcvd
        self.sent = sent
        WebSocketException.__init__(self, "received %r; sent %r" % (rcvd, sent))

    @property
    def code(self):
        return 1006 if self.rcvd is None else self.rcvd.code

    @property
    def reason(self):
        return "" if self.rcvd is None else self.rcvd.reason


class ConnectionClosedOK(ConnectionClosed):
    pass


class ConnectionClosedError(ConnectionClosed):
    pass


class InvalidHandshake(WebSocketException):
    pass


class InvalidURI(InvalidHandshake):
    pass


class InvalidStatus(InvalidHandshake):
    def __init__(self, response):
        self.response = response
        InvalidHandshake.__init__(self, "server rejected WebSocket connection: HTTP %d" % response.status_code)


class InvalidHeader(InvalidHandshake):
    pass


class NegotiationError(InvalidHandshake):
    pass


class ProtocolError(WebSocketException):
    pass


class PayloadTooBig(ProtocolError):
    pass


class _Fail(Exception):
    def __init__(self, code, reason):
        Exception.__init__(self, reason)
        self.code = code
        self.reason = reason


class Request:
    def __init__(self, path, headers):
        self.path = path
        self.headers = headers


class Response:
    def __init__(self, status_code, reason_phrase, headers, body=b""):
        self.status_code = status_code
        self.reason_phrase = reason_phrase
        self.headers = headers
        self.body = body


class Headers:
    """Case-insensitive, ordered, repeatable header fields."""
    def __init__(self, items=()):
        self._items = [(str(k), str(v)) for k, v in items]

    def get(self, name, default=None):
        n = name.lower()
        for k, v in self._items:
            if k.lower() == n:
                return v
        return default

    def get_all(self, name):
        n = name.lower()
        return [v for k, v in self._items if k.lower() == n]

    def __getitem__(self, name):
        v = self.get(name)
        if v is None:
            raise KeyError(name)
        return v

    def __setitem__(self, name, value):
        self._items.append((name, str(value)))

    def __contains__(self, name):
        return self.get(name) is not None

    def items(self):
        return list(self._items)

    def serialize(self):
        return "".join("%s: %s\r\n" % kv for kv in self._items)


def accept_key(key):
    return base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")


def _mask(data, key):
    if not data:
        return b""
    # whole-message XOR through big integers (no per-byte loop)
    n = len(data)
    k = (key * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(k, "big")).to_bytes(n, "big")


def _frame(fin, opcode, payload, mask, rsv1=False):
    b0 = opcode | (0x80 if fin else 0) | (0x40 if rsv1 else 0)
    m = 0x80 if mask else 0
    n = len(payload)
    if n < 126:
        head = bytes([b0, m | n])
    elif n < 65536:
        head = bytes([b0, m | 126]) + n.to_bytes(2, "big")
    else:
        head = bytes([b0, m | 127]) + n.to_bytes(8, "big")
    if mask:
        key = os.urandom(4)
        return head + key + _mask(payload, key)
    return head + payload


def _close_payload(code, reason):
    if code == 1005:
        return b""
    r = reason.encode("utf-8")
    if len(r) > 123:
        raise ProtocolError("close reason too long")
    return code.to_bytes(2, "big") + r


def _valid_close_code(code):
    return 3000 <= code < 5000 or code in (1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014)


def _tokens(values):
    out = []
    for v in values:
        for t in v.split(","):
            t = t.strip().lower()
            if t:
                out.append(t)
    return out


async def _read_head(reader):
    line = await reader.readline()
    if not line:
        raise EOFError("connection closed while reading the HTTP head")
    first = line.decode("iso-8859-1").rstrip("\r\n")
    items = []
    while True:
        line = await reader.readline()
        if not line:
            raise EOFError("connection closed while reading the HTTP head")
        line = line.decode("iso-8859-1").rstrip("\r\n")
        if not line:
            break
        k, sep, v = line.partition(":")
        if not sep:
            raise InvalidHandshake("invalid header line %r" % line)
        items.append((k.strip(), v.strip()))
        if len(items) > 256:
            raise InvalidHandshake("too many headers")
    return first, Headers(items)


class Connection:
    """One open WebSocket, either end."""
    def __init__(self, reader, writer, is_client, extension=None, max_size=2 ** 20, max_queue=16,
                 close_timeout=10):
        self._reader = reader
        self._writer = writer
        self.is_client = is_client
        self.extension = extension
        self.max_size = max_size
        self.close_timeout = close_timeout
        self.state = OPEN
        self.subprotocol = None
        self.request = None
        self.response = None
        self.remote_address = writer.get_extra_info("peername")
        self.local_address = writer.get_extra_info("sockname")
        self.close_rcvd = None
        self.close_sent = None
        self.latency = 0.0
        self._queue = asyncio.Queue(maxsize=max_queue or 0)
        self._send_lock = asyncio.Lock()
        self._pings = {}
        self._closed = asyncio.Event()
        self._reader_task = asyncio.ensure_future(self._read_loop())

    # ── reading ──
    async def _read_frame(self):
        h = await self._reader.readexactly(2)
        fin = (h[0] & 0x80) != 0
        rsv1 = (h[0] & 0x40) != 0
        opcode = h[0] & 0x0F
        masked = (h[1] & 0x80) != 0
        n = h[1] & 0x7F
        if (h[0] & 0x30) or (rsv1 and self.extension is None):
            raise _Fail(1002, "reserved bits must be 0")
        if opcode not in (0, 1, 2, 8, 9, 10):
            raise _Fail(1002, "invalid opcode %d" % opcode)
        if n == 126:
            n = int.from_bytes(await self._reader.readexactly(2), "big")
        elif n == 127:
            n = int.from_bytes(await self._reader.readexactly(8), "big")
            if n >= 2 ** 63:
                raise _Fail(1002, "payload length uses the most significant bit")
        if opcode >= 8:
            if not fin:
                raise _Fail(1002, "fragmented control frame")
            if n > 125:
                raise _Fail(1002, "control frame too long")
        if masked == self.is_client:
            raise _Fail(1002, "incorrect masking")
        if opcode < 8 and self.max_size is not None and n > self.max_size:
            raise _Fail(1009, "frame with %d bytes exceeds limit of %d bytes" % (n, self.max_size))
        key = await self._reader.readexactly(4) if masked else None
        payload = await self._reader.readexactly(n)
        if masked:
            payload = _mask(payload, key)
        return fin, rsv1, opcode, payload

    async def _read_loop(self):
        frag_op = None
        frags = []
        size = 0
        try:
            while True:
                fin, rsv1, op, payload = await self._read_frame()
                if self.extension is not None:
                    limit = None if self.max_size is None else self.max_size - size
                    try:
                        payload = self.extension.decode_frame(op, fin, rsv1, payload, limit)
                    except _pmd.PayloadTooBig as e:
                        raise _Fail(1009, str(e))
                    except _pmd.ProtocolError as e:
                        raise _Fail(1002, str(e))
                if op == OP_PING:
                    if self.close_sent is None:
                        await self._write(_frame(True, OP_PONG, payload, self.is_client))
                elif op == OP_PONG:
                    self._on_pong(payload)
                elif op == OP_CLOSE:
                    await self._on_close(payload)
                    return
                else:
                    if op == OP_CONT:
                        if frag_op is None:
                            raise _Fail(1002, "unexpected continuation frame")
                    elif frag_op is not None:
                        raise _Fail(1002, "expected a continuation frame")
                    else:
                        frag_op = op
                    frags.append(payload)
                    size += len(payload)
                    if self.max_size is not None and size > self.max_size:
                        raise _Fail(1009, "message over %d bytes" % self.max_size)
                    if fin:
                        data = b"".join(frags)
                        if frag_op == OP_TEXT:
                            try:
                                data = data.decode("utf-8")
                            except UnicodeDecodeError:
                                raise _Fail(1007, "invalid UTF-8 in a text message")
                        frag_op = None
                        frags = []
                        size = 0
                        await self._queue.put(data)
        except _Fail as e:
            await self._fail(e.code, e.reason)
        except (asyncio.IncompleteReadError, ConnectionError, OSError, EOFError):
            self._finish()
        except asyncio.CancelledError:
            self._finish()

    def _on_pong(self, payload):
        fut = self._pings.pop(payload, None)
        if fut is not None and not fut[0].done():
            rtt = asyncio.get_running_loop().time() - fut[1]
            self.latency = rtt
            fut[0].set_result(rtt)

    async def _on_close(self, payload):
        if len(payload) == 1:
            await self._fail(1002, "close frame with a 1-byte payload")
            return
        code = 1005
        reason = ""
        if len(payload) >= 2:
            code = int.from_bytes(payload[:2], "big")
            if not _valid_close_code(code):
                await self._fail(1002, "invalid close code %d" % code)
                return
            try:
                reason = payload[2:].decode("utf-8")
            except UnicodeDecodeError:
                await self._fail(1007, "invalid UTF-8 in a close reason")
                return
        self.close_rcvd = Close(code, reason)
        if self.close_sent is None:
            self.close_sent = Close(code, reason) if code != 1005 else Close(1000, "")
            try:
                await self._write(_frame(True, OP_CLOSE, payload if code != 1005 else b"", self.is_client))
            except (ConnectionError, OSError):
                pass
        self.state = CLOSING
        # the server closes the TCP connection first (RFC 6455 7.1.1)
        if not self.is_client:
            self._finish()
        else:
            try:
                await asyncio.wait_for(self._reader.read(), self.close_timeout)
            except (asyncio.TimeoutError, ConnectionError, OSError):
                pass
            self._finish()

    async def _fail(self, code, reason):
        if self.close_sent is None and self.state == OPEN:
            self.close_sent = Close(code, reason)
            try:
                await self._write(_frame(True, OP_CLOSE, _close_payload(code, reason[:100]), self.is_client))
            except (ConnectionError, OSError):
                pass
        self._finish()

    def _finish(self):
        self.state = CLOSED
        try:
            self._writer.close()
        except Exception:
            pass
        for fut, t in self._pings.values():
            if not fut.done():
                fut.cancel()
        self._pings = {}
        self._closed.set()
        try:
            self._queue.put_nowait(None)         # wakes a waiting recv()
        except asyncio.QueueFull:
            pass

    def _closed_error(self):
        ok_codes = (1000, 1001, 1005)
        if (self.close_rcvd is not None and self.close_sent is not None
                and self.close_rcvd.code in ok_codes and self.close_sent.code in ok_codes):
            return ConnectionClosedOK(self.close_rcvd, self.close_sent)
        return ConnectionClosedError(self.close_rcvd, self.close_sent)

    async def recv(self):
        """The next message (str for text, bytes for binary)."""
        if self._queue.empty() and self.state == CLOSED:
            raise self._closed_error()
        msg = await self._queue.get()
        if msg is None:
            try:
                self._queue.put_nowait(None)
            except asyncio.QueueFull:
                pass
            raise self._closed_error()
        return msg

    def __aiter__(self):
        return self

    async def __anext__(self):
        try:
            return await self.recv()
        except ConnectionClosedOK:
            raise StopAsyncIteration

    # ── writing ──
    async def _write(self, data):
        async with self._send_lock:
            self._writer.write(data)
            await self._writer.drain()

    async def send(self, message):
        """str: a text message; bytes-like: binary; an iterable (or async
        iterable) of them: one fragmented message."""
        if self.state != OPEN:
            raise self._closed_error()
        if isinstance(message, (str, bytes, bytearray, memoryview)):
            op = OP_TEXT if isinstance(message, str) else OP_BINARY
            data = message.encode("utf-8") if isinstance(message, str) else bytes(message)
            await self._send_message(op, [data])
            return
        if isinstance(message, dict):
            raise TypeError("data must be str, bytes, or an iterable of them")
        parts = []
        if hasattr(message, "__aiter__"):
            async for p in message:
                parts.append(p)
        else:
            for p in message:
                parts.append(p)
        if not parts:
            return
        op = OP_TEXT if isinstance(parts[0], str) else OP_BINARY
        chunks = []
        for p in parts:
            if isinstance(p, str) != (op == OP_TEXT):
                raise TypeError("all fragments must be of the same type")
            chunks.append(p.encode("utf-8") if isinstance(p, str) else bytes(p))
        await self._send_message(op, chunks)

    async def _send_message(self, op, chunks):
        total = 0
        for c in chunks:
            total += len(c)
        async with self._send_lock:
            if self.state != OPEN:
                raise self._closed_error()
            out = []
            n = len(chunks)
            for i in range(n):
                fop = op if i == 0 else OP_CONT
                data = chunks[i]
                rsv1 = False
                if self.extension is not None:
                    rsv1, data = self.extension.encode_frame(fop, i == n - 1, data, total)
                out.append(_frame(i == n - 1, fop, data, self.is_client, rsv1))
            try:
                self._writer.write(b"".join(out))
                await self._writer.drain()
            except (ConnectionError, OSError):
                self._finish()
                raise self._closed_error()

    async def ping(self, data=None):
        """Send a PING; returns a future that resolves with the round-trip
        time when its PONG arrives."""
        if self.state != OPEN:
            raise self._closed_error()
        if data is None:
            data = os.urandom(4)
        elif isinstance(data, str):
            data = data.encode("utf-8")
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self._pings[bytes(data)] = (fut, loop.time())
        await self._write(_frame(True, OP_PING, bytes(data), self.is_client))
        return fut

    async def pong(self, data=b""):
        if isinstance(data, str):
            data = data.encode("utf-8")
        await self._write(_frame(True, OP_PONG, bytes(data), self.is_client))

    async def close(self, code=1000, reason=""):
        """The closing handshake (then the TCP connection goes)."""
        if self.state == OPEN:
            if not _valid_close_code(code):
                raise ProtocolError("invalid status code %d" % code)
            self.close_sent = Close(code, reason)
            self.state = CLOSING
            try:
                await self._write(_frame(True, OP_CLOSE, _close_payload(code, reason), self.is_client))
            except (ConnectionError, OSError):
                self._finish()
        try:
            await asyncio.wait_for(self._closed.wait(), self.close_timeout)
        except asyncio.TimeoutError:
            self._finish()
        if not self._reader_task.done():
            self._reader_task.cancel()
            try:
                await self._reader_task
            except BaseException:
                pass

    async def wait_closed(self):
        await self._closed.wait()

    @property
    def close_code(self):
        if self.state != CLOSED:
            return None
        return 1006 if self.close_rcvd is None else self.close_rcvd.code

    @property
    def close_reason(self):
        if self.state != CLOSED:
            return None
        return "" if self.close_rcvd is None else self.close_rcvd.reason

    async def __aenter__(self):
        return self

    async def __aexit__(self, a, b, c):
        await self.close()
        return False


def _client_factories(compression, extensions):
    out = list(extensions or [])
    if compression == "deflate":
        if not any(f.name == _pmd.EXTENSION_NAME for f in out):
            out.append(_pmd.ClientPerMessageDeflateFactory())
    elif compression is not None:
        raise ValueError("unsupported compression: %r" % (compression,))
    return out


def _server_factories(compression, extensions):
    out = list(extensions or [])
    if compression == "deflate":
        if not any(f.name == _pmd.EXTENSION_NAME for f in out):
            out.append(_pmd.ServerPerMessageDeflateFactory())
    elif compression is not None:
        raise ValueError("unsupported compression: %r" % (compression,))
    return out


class connect:
    """await connect(uri, ...) or async with connect(uri, ...) as conn."""
    def __init__(self, uri, origin=None, subprotocols=None, additional_headers=None, ssl=None,
                 server_hostname=None, compression="deflate", extensions=None, max_size=2 ** 20, max_queue=16,
                 open_timeout=10, close_timeout=10, user_agent_header=USER_AGENT):
        self.uri = uri
        self.kw = dict(origin=origin, subprotocols=subprotocols, additional_headers=additional_headers, ssl=ssl,
                       server_hostname=server_hostname, max_size=max_size, max_queue=max_queue,
                       close_timeout=close_timeout, user_agent_header=user_agent_header)
        self.factories = _client_factories(compression, extensions)
        self.open_timeout = open_timeout
        self.connection = None

    async def _create(self):
        if self.open_timeout is None:
            self.connection = await self._handshake(**self.kw)
        else:
            self.connection = await asyncio.wait_for(self._handshake(**self.kw), self.open_timeout)
        return self.connection

    def __await__(self):
        return self._create().__await__()

    async def __aenter__(self):
        return await self._create()

    async def __aexit__(self, a, b, c):
        if self.connection is not None:
            await self.connection.close()
        return False

    async def _handshake(self, origin, subprotocols, additional_headers, ssl, server_hostname, max_size,
                         max_queue, close_timeout, user_agent_header):
        u = urllib.parse.urlsplit(self.uri)
        if u.scheme not in ("ws", "wss"):
            raise InvalidURI("%s isn't a valid URI: scheme isn't ws or wss" % self.uri)
        if not u.hostname:
            raise InvalidURI("%s isn't a valid URI: hostname isn't provided" % self.uri)
        secure = u.scheme == "wss"
        port = u.port or (443 if secure else 80)
        path = (u.path or "/") + ("?" + u.query if u.query else "")
        if secure or ssl:
            import ssl as _ssl
            ctx = ssl
            if ctx is None or ctx is True:
                ctx = _ssl.create_default_context()
            reader, writer = await asyncio.open_connection(u.hostname, port, ssl=ctx,
                                                           server_hostname=server_hostname or u.hostname)
        else:
            reader, writer = await asyncio.open_connection(u.hostname, port)
        try:
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            host = u.hostname if ":" not in u.hostname else "[" + u.hostname + "]"
            if port != (443 if secure else 80):
                host += ":%d" % port
            h = Headers([("Host", host), ("Upgrade", "websocket"), ("Connection", "Upgrade"),
                         ("Sec-WebSocket-Key", key), ("Sec-WebSocket-Version", "13")])
            if origin is not None:
                h["Origin"] = origin
            if subprotocols:
                h["Sec-WebSocket-Protocol"] = ", ".join(subprotocols)
            if self.factories:
                h["Sec-WebSocket-Extensions"] = _pmd.build_extensions([(f.name, f.get_request_params()) for f in self.factories])
            if additional_headers:
                items = additional_headers.items() if isinstance(additional_headers, dict) else additional_headers
                for k, v in items:
                    h[k] = v
            if user_agent_header:
                h["User-Agent"] = user_agent_header
            writer.write(("GET %s HTTP/1.1\r\n%s\r\n" % (path, h.serialize())).encode("iso-8859-1"))
            await writer.drain()
            first, headers = await _read_head(reader)
            parts = first.split(" ", 2)
            if len(parts) < 2 or not parts[0].startswith("HTTP/1.") or not parts[1].isdigit():
                raise InvalidHandshake("did not receive a valid HTTP response: %r" % first)
            status = int(parts[1])
            resp = Response(status, parts[2] if len(parts) > 2 else "", headers)
            if status != 101:
                raise InvalidStatus(resp)
            if "websocket" not in _tokens(headers.get_all("Upgrade")):
                raise InvalidHeader("invalid Upgrade header: %r" % headers.get("Upgrade"))
            if "upgrade" not in _tokens(headers.get_all("Connection")):
                raise InvalidHeader("invalid Connection header: %r" % headers.get("Connection"))
            if headers.get("Sec-WebSocket-Accept") != accept_key(key):
                raise InvalidHeader("invalid Sec-WebSocket-Accept header")
            extension = None
            values = headers.get_all("Sec-WebSocket-Extensions")
            if values:
                try:
                    parsed = _pmd.parse_extensions(values)
                    accepted = []
                    for name, params in parsed:
                        f = None
                        for cand in self.factories:
                            if cand.name == name:
                                f = cand
                        if f is None:
                            raise NegotiationError("unsupported extension: " + name)
                        accepted.append(f.process_response_params(params, accepted))
                except _pmd.NegotiationError as e:
                    raise NegotiationError(str(e))
                if len(accepted) > 1:
                    raise NegotiationError("more than one extension accepted")
                extension = accepted[0] if accepted else None
            proto = headers.get("Sec-WebSocket-Protocol")
            if proto is not None and (not subprotocols or proto not in subprotocols):
                raise NegotiationError("unsupported subprotocol: " + proto)
        except BaseException:
            writer.close()
            raise
        c = Connection(reader, writer, True, extension, max_size, max_queue, close_timeout)
        c.subprotocol = proto
        c.request = Request(path, h)
        c.response = resp
        return c


class Server:
    def __init__(self, handler, ssl=None, subprotocols=None, origins=None, process_request=None,
                 compression="deflate", extensions=None, max_size=2 ** 20, max_queue=16, open_timeout=10,
                 close_timeout=10, server_header="Nython-websocket-asyncio/0.1"):
        self.handler = handler
        self.ssl = ssl
        self.subprotocols = subprotocols
        self.origins = origins
        self.process_request = process_request
        self.factories = _server_factories(compression, extensions)
        self.max_size = max_size
        self.max_queue = max_queue
        self.open_timeout = open_timeout
        self.close_timeout = close_timeout
        self.server_header = server_header
        self.connections = set()
        self.handshake_failures = 0
        self._server = None
        self._closed = asyncio.Event()

    @property
    def port(self):
        return self._server.sockets[0].getsockname()[1]

    @property
    def sockets(self):
        return self._server.sockets

    async def _start(self, host, port):
        self._server = await asyncio.start_server(self._client, host, port, ssl=self.ssl)
        return self

    async def _respond(self, writer, status, phrase, headers, body=b""):
        h = Headers([("Server", self.server_header)] + headers.items())
        writer.write(("HTTP/1.1 %d %s\r\n%s\r\n" % (status, phrase, h.serialize())).encode("iso-8859-1") + body)
        await writer.drain()

    async def _handshake(self, reader, writer):
        first, headers = await _read_head(reader)
        words = first.split(" ")
        req = Request(words[1] if len(words) >= 2 else "/", headers)
        problem = None
        status = 400
        if len(words) != 3 or words[0] != "GET" or words[2] != "HTTP/1.1":
            problem = "invalid request line"
            if len(words) == 3 and words[0] != "GET":
                status = 405
        elif "websocket" not in _tokens(headers.get_all("Upgrade")):
            problem, status = "missing or invalid Upgrade header", 426
        elif "upgrade" not in _tokens(headers.get_all("Connection")):
            problem, status = "missing or invalid Connection header", 426
        elif headers.get("Sec-WebSocket-Version") != "13":
            problem, status = "unsupported Sec-WebSocket-Version", 426
        else:
            key = headers.get("Sec-WebSocket-Key")
            try:
                raw = base64.b64decode(key.encode("ascii"), validate=True) if key else b""
            except Exception:
                raw = b""
            if len(raw) != 16:
                problem = "missing or invalid Sec-WebSocket-Key header"
        if problem is None and self.origins is not None and headers.get("Origin") not in self.origins:
            problem, status = "invalid Origin header", 403
        return req, problem, status

    async def _client(self, reader, writer):
        conn = None
        try:
            try:
                req, problem, status = await asyncio.wait_for(self._handshake(reader, writer), self.open_timeout)
            except (asyncio.TimeoutError, EOFError, InvalidHandshake, ConnectionError, OSError):
                self.handshake_failures += 1
                writer.close()
                return
            if self.process_request is not None:
                early = self.process_request(self, req)
                if asyncio.iscoroutine(early):
                    early = await early
                if early is not None:
                    await self._respond(writer, early.status_code, early.reason_phrase, early.headers, early.body)
                    writer.close()
                    return
            if problem is not None:
                self.handshake_failures += 1
                body = ("Failed to open a WebSocket connection: %s.\n" % problem).encode()
                eh = Headers([("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", str(len(body))),
                              ("Connection", "close")])
                if status == 426:
                    eh["Upgrade"] = "websocket"
                    eh["Sec-WebSocket-Version"] = "13"
                await self._respond(writer, status, {400: "Bad Request", 403: "Forbidden", 405: "Method Not Allowed",
                                                     426: "Upgrade Required"}[status], eh, body)
                writer.close()
                return
            offered = [t.strip() for v in req.headers.get_all("Sec-WebSocket-Protocol") for t in v.split(",") if t.strip()]
            proto = None
            if self.subprotocols:
                for p in self.subprotocols:
                    if p in offered:
                        proto = p
                        break
            hdrs = Headers([("Upgrade", "websocket"), ("Connection", "Upgrade"),
                            ("Sec-WebSocket-Accept", accept_key(req.headers.get("Sec-WebSocket-Key")))])
            extension = None
            offers = req.headers.get_all("Sec-WebSocket-Extensions")
            if offers:
                for f in self.factories:
                    answer, ext = f.negotiate(", ".join(offers))
                    if ext is not None:
                        hdrs["Sec-WebSocket-Extensions"] = answer
                        extension = ext
                        break
            if proto is not None:
                hdrs["Sec-WebSocket-Protocol"] = proto
            await self._respond(writer, 101, "Switching Protocols", hdrs)
            conn = Connection(reader, writer, False, extension, self.max_size, self.max_queue, self.close_timeout)
            conn.subprotocol = proto
            conn.request = req
            conn.response = Response(101, "Switching Protocols", hdrs)
            self.connections.add(conn)
            try:
                await self.handler(conn)
                await conn.close()
            except ConnectionClosed:
                pass
            except Exception:
                try:
                    await conn.close(1011)
                except Exception:
                    pass
        finally:
            if conn is not None:
                self.connections.discard(conn)

    async def broadcast(self, message):
        n = 0
        for c in list(self.connections):
            try:
                await c.send(message)
                n += 1
            except (ConnectionClosed, ConnectionError, OSError):
                pass
        return n

    async def close(self, code=1001, reason=""):
        if self._server is not None:
            self._server.close()
        await asyncio.gather(*[c.close(code, reason) for c in list(self.connections)], return_exceptions=True)
        self._closed.set()

    async def wait_closed(self):
        await self._closed.wait()

    async def serve_forever(self):
        await self._closed.wait()

    async def __aenter__(self):
        return self

    async def __aexit__(self, a, b, c):
        await self.close()
        return False


class serve:
    """await serve(handler, host, port, ...) or async with serve(...) as server."""
    def __init__(self, handler, host=None, port=None, **kw):
        self.host = host or "127.0.0.1"
        self.port = port or 0
        self.server = Server(handler, **kw)

    def __await__(self):
        return self.server._start(self.host, self.port).__await__()

    async def __aenter__(self):
        return await self.server._start(self.host, self.port)

    async def __aexit__(self, a, b, c):
        await self.server.close()
        return False
