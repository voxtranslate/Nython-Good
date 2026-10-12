# nython: module    (import it by name: it runs in a module scope of its own)
# lib/websocket.ny - WebSockets, RFC 6455 (round 77): client and server, ws://
# and wss://, over lib/socket.ny and lib/ssl.ny.
#
#     import websocket
#     def echo(ws):
#         for message in ws:                  # str for text, bytes for binary
#             ws.send(message)
#     with websocket.serve(echo, "127.0.0.1", 8765) as server:
#         server.serve_forever()
#
#     with websocket.connect("ws://127.0.0.1:8765/") as ws:
#         ws.send("hello")
#         print(ws.recv())
#
# One API for threads and async tasks: the runtime's waits are colorless, so
# recv() inside an async task suspends that task, not its loop.
#
# The protocol, all of it: the opening handshake (Sec-WebSocket-Key/Accept,
# version 13, subprotocol negotiation, Origin checks, process_request hooks
# for plain HTTP answers such as health checks); masking (client frames
# masked, server frames not, both enforced); 7/16/64-bit payload lengths;
# fragmented messages in both directions (send() of an iterable, or
# fragment_size); ping/pong (pings answered automatically, ping() returns a
# waiter); the closing handshake with status codes and reasons (validated:
# 1005/1006/1015 never sent, the reason UTF-8 and the payload at most 125
# bytes); failing the connection on protocol errors (1002), invalid UTF-8 in
# text (1007), oversized messages (1009) and handler errors (1011). No
# extensions are negotiated (permessage-deflate needs zlib).
#
# Keepalive that adapts (new here): with ping_interval set, each pong is an
# RTT sample for RFC 6298's estimator (SRTT, RTTVAR), and a ping is declared
# lost after RTO = SRTT + 4*RTTVAR (within [min_ping_timeout, ping_timeout])
# instead of a fixed timeout - a dead peer on a fast link is detected in
# milliseconds-to-seconds, a slow but alive one is not dropped. `latency`,
# `srtt` and `rto` expose the estimate.
import socket
import threading
import base64
import hashlib
import http.client
import urllib.parse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OP_CONT = 0
OP_TEXT = 1
OP_BINARY = 2
OP_CLOSE = 8
OP_PING = 9
OP_PONG = 10
_DATA_OPS = [OP_CONT, OP_TEXT, OP_BINARY]
_CTRL_OPS = [OP_CLOSE, OP_PING, OP_PONG]

CONNECTING = 0
OPEN = 1
CLOSING = 2
CLOSED = 3

class State:
    CONNECTING = 0
    OPEN = 1
    CLOSING = 2
    CLOSED = 3

CLOSE_CODE_EXPLANATIONS = {
    1000: "OK", 1001: "going away", 1002: "protocol error", 1003: "unsupported data",
    1005: "no status received [internal]", 1006: "connection closed abnormally [internal]",
    1007: "invalid frame payload data", 1008: "policy violation", 1009: "message too big",
    1010: "mandatory extension", 1011: "internal error", 1012: "service restart",
    1013: "try again later", 1014: "bad gateway", 1015: "TLS handshake failure [internal]"}

USER_AGENT = "Nython-websocket/0.2"
SERVER = "Nython-websocket/0.2"

# ─── errors ─────────────────────────────────────────────────────────────────

class WebSocketException(Exception):
    pass

class Close:
    def __init__(self, code, reason=""):
        self.code = code
        self.reason = reason

    def __str__(self):
        var expl = CLOSE_CODE_EXPLANATIONS.get(self.code)
        if expl == none:
            if self.code >= 3000 and self.code < 4000:
                expl = "registered"
            elif self.code >= 4000 and self.code < 5000:
                expl = "private use"
            else:
                expl = "unknown"
        var s = str(self.code) + " (" + expl + ")"
        if self.reason != "":
            s = s + " " + self.reason
        return s

    def __repr__(self):
        return "Close(code=" + str(self.code) + ", reason=" + repr(self.reason) + ")"

class ConnectionClosed(WebSocketException):
    # rcvd / sent: the Close frames received and sent (none: there was none)
    def __init__(self, rcvd, sent, rcvd_then_sent=none):
        self.rcvd = rcvd
        self.sent = sent
        self.rcvd_then_sent = rcvd_then_sent
        var text = "no close frame received or sent"
        if rcvd != none and sent != none:
            if rcvd_then_sent:
                text = "received " + str(rcvd) + "; then sent " + str(sent)
            else:
                text = "sent " + str(sent) + "; then received " + str(rcvd)
        elif rcvd != none:
            text = "received " + str(rcvd) + "; then sent no close frame"
        elif sent != none:
            text = "sent " + str(sent) + "; no close frame received"
        WebSocketException.__init__(self, text)

    @property
    def code(self):
        if self.rcvd == none:
            return 1006
        return self.rcvd.code

    @property
    def reason(self):
        if self.rcvd == none:
            return ""
        return self.rcvd.reason

class ConnectionClosedOK(ConnectionClosed):
    pass

class ConnectionClosedError(ConnectionClosed):
    pass

class InvalidHandshake(WebSocketException):
    pass

class InvalidURI(InvalidHandshake):
    def __init__(self, uri, msg):
        self.uri = uri
        InvalidHandshake.__init__(self, uri + " isn't a valid URI: " + msg)

class InvalidStatus(InvalidHandshake):
    def __init__(self, response):
        self.response = response
        InvalidHandshake.__init__(self, "server rejected WebSocket connection: HTTP " + str(response.status_code))

class InvalidHeader(InvalidHandshake):
    def __init__(self, name, value=none):
        self.name = name
        self.value = value
        if value == none:
            InvalidHandshake.__init__(self, "missing " + name + " header")
        else:
            InvalidHandshake.__init__(self, "invalid " + name + " header: " + str(value))

class InvalidUpgrade(InvalidHeader):
    pass

class InvalidMessage(InvalidHandshake):
    pass

class NegotiationError(InvalidHandshake):
    pass

class InvalidOrigin(InvalidHeader):
    def __init__(self, origin):
        InvalidHeader.__init__(self, "Origin", origin)

class ProtocolError(WebSocketException):
    pass

class PayloadTooBig(ProtocolError):
    pass

class InvalidState(WebSocketException):
    pass

# ─── handshake ──────────────────────────────────────────────────────────────

def accept_key(key):
    # Sec-WebSocket-Accept for a Sec-WebSocket-Key (RFC 6455 4.2.2)
    return base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")

def generate_key():
    return base64.b64encode(os_urandom(16)).decode("ascii")

class Headers:
    # Case-insensitive, ordered, repeatable header fields.
    def __init__(self, items=none):
        self._items = []
        if items != none:
            if isinstance(items, "map"):
                for k in items:
                    self._items.append((str(k), str(items[k])))
            else:
                for kv in items:
                    self._items.append((str(kv[0]), str(kv[1])))

    def __getitem__(self, name):
        var v = self.get(name)
        if v == none:
            raise KeyError(name)
        return v

    def __setitem__(self, name, value):
        self._items.append((name, str(value)))

    def __delitem__(self, name):
        var n = name.lower()
        self._items = [kv for kv in self._items if kv[0].lower() != n]

    def __contains__(self, name):
        return self.get(name) != none

    def __iter__(self):
        return iter([kv[0] for kv in self._items])

    def __len__(self):
        return len(self._items)

    def get(self, name, default=none):
        var n = name.lower()
        for kv in self._items:
            if kv[0].lower() == n:
                return kv[1]
        return default

    def get_all(self, name):
        var n = name.lower()
        return [kv[1] for kv in self._items if kv[0].lower() == n]

    def items(self):
        return list(self._items)

    def raw_items(self):
        return list(self._items)

    def __str__(self):
        return "".join([kv[0] + ": " + kv[1] + "\r\n" for kv in self._items]) + "\r\n"

def _tokens(values):
    # The comma-separated tokens of every value, lowercased.
    var out = []
    for v in values:
        for t in v.split(","):
            t = t.strip().lower()
            if t != "":
                out.append(t)
    return out

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

def _read_head(reader):
    # (first line, Headers) of an HTTP/1.1 message head
    var line = reader.readline(8193)
    if len(line) == 0:
        raise EOFError("connection closed while reading HTTP message head")
    if len(line) > 8192:
        raise InvalidMessage("line too long")
    var first = line.decode("iso-8859-1").rstrip("\r\n")
    var msg = http.client.parse_headers(reader)
    return [first, Headers(msg.items())]

# ─── frames ─────────────────────────────────────────────────────────────────

def encode_frame(fin, opcode, payload, mask):
    # One frame, RFC 6455 5.2. mask: the client's side.
    var b0 = opcode
    if fin:
        b0 = b0 | 0x80
    var mbit = 0
    if mask:
        mbit = 0x80
    var n = len(payload)
    var head = none
    if n < 126:
        head = bytes([b0, mbit | n])
    elif n < 65536:
        head = bytes([b0, mbit | 126]) + n.to_bytes(2, "big")
    else:
        head = bytes([b0, mbit | 127]) + n.to_bytes(8, "big")
    if mask:
        var key = os_urandom(4)
        return head + key + _ws_mask(payload, key)
    return head + payload

def _close_payload(code, reason):
    if code == 1005:
        return b""
    var r = reason.encode("utf-8")
    if len(r) > 123:
        raise ProtocolError("close reason too long")
    return code.to_bytes(2, "big") + r

def _valid_close_code(code):
    if code >= 3000 and code < 5000:
        return true
    return code in [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014]

class _Failure(Exception):
    # Fail the connection with this close code (internal).
    def __init__(self, code, reason):
        Exception.__init__(self, reason)
        self.code = code
        self.reason = reason

# ─── connections ────────────────────────────────────────────────────────────

class _PingWaiter:
    def __init__(self, data, sent_at):
        self.data = data
        self.sent_at = sent_at
        self.event = threading.Event()
        self.latency = none

    def wait(self, timeout=none):
        return self.event.wait(timeout)

    def is_set(self):
        return self.event.is_set()

class Connection:
    # Both ends. Messages are received by a reader thread into a queue;
    # recv() takes from it. send() and the reader's automatic pongs share one
    # write lock, so frames never interleave.
    def __init__(self, sock, reader, is_client, max_size=1048576, max_queue=16, ping_interval=none,
                 ping_timeout=none, min_ping_timeout=0.05, close_timeout=10, fragment_size=none):
        self.socket = sock
        self._rf = reader
        self.is_client = is_client
        self.max_size = max_size
        self.max_queue = max_queue
        self.ping_interval = ping_interval
        self.ping_timeout = ping_timeout
        self.min_ping_timeout = min_ping_timeout
        self.close_timeout = close_timeout
        self.fragment_size = fragment_size
        self.state = OPEN
        self.subprotocol = none
        self.request = none
        self.response = none
        self.id = base64.b16encode(os_urandom(8)).decode().lower()
        self.remote_address = none
        self.local_address = none
        try:
            self.remote_address = sock.getpeername()
            self.local_address = sock.getsockname()
        except OSError:
            pass
        self.close_rcvd = none
        self.close_sent = none
        self.close_rcvd_then_sent = none
        self._send_lock = threading.Lock()
        self._cond = threading.Condition(threading.Lock())
        self._queue = []
        self._frag_op = none
        self._frags = []
        self._frag_size = 0
        self._pings = []
        self._closed = threading.Event()
        self.latency = 0
        self.srtt = none
        self.rttvar = none
        self._reader_thread = threading.Thread(target=self._read_loop, daemon=true)
        self._reader_thread.start()
        self._keepalive_thread = none
        if ping_interval != none:
            self._keepalive_thread = threading.Thread(target=self._keepalive, daemon=true)
            self._keepalive_thread.start()

    # ── the reader ──
    def _read_exact(self, n):
        var d = self._rf.read(n)
        if len(d) < n:
            raise EOFError("connection closed in the middle of a frame")
        return d

    def _read_frame(self):
        var h = self._read_exact(2)
        var b0 = h[0]
        var b1 = h[1]
        var fin = (b0 & 0x80) != 0
        var opcode = b0 & 0x0F
        var masked = (b1 & 0x80) != 0
        var n = b1 & 0x7F
        if (b0 & 0x70) != 0:
            raise _Failure(1002, "reserved bits must be 0")
        if not (opcode in _DATA_OPS) and not (opcode in _CTRL_OPS):
            raise _Failure(1002, "invalid opcode " + str(opcode))
        if n == 126:
            n = int.from_bytes(self._read_exact(2), "big")
        elif n == 127:
            n = int.from_bytes(self._read_exact(8), "big")
            if n >= 9223372036854775808:
                raise _Failure(1002, "payload length uses the most significant bit")
        if opcode >= 8:
            if not fin:
                raise _Failure(1002, "fragmented control frame")
            if n > 125:
                raise _Failure(1002, "control frame too long")
        if masked == self.is_client:
            raise _Failure(1002, "incorrect masking")
        if opcode < 8 and self.max_size != none and self._frag_size + n > self.max_size:
            raise _Failure(1009, "frame with " + str(self._frag_size + n) + " bytes exceeds limit of " + str(self.max_size) + " bytes")
        var key = none
        if masked:
            key = self._read_exact(4)
        var payload = self._read_exact(n)
        if masked:
            payload = _ws_mask(payload, key)
        return [fin, opcode, payload]

    def _deliver(self, opcode, data):
        var msg = data
        if opcode == OP_TEXT:
            try:
                msg = data.decode("utf-8")
            except UnicodeDecodeError:
                raise _Failure(1007, "invalid UTF-8 in a text message")
        with self._cond:
            # backpressure: the reader waits while max_queue messages are unread
            while self.max_queue != none and len(self._queue) >= self.max_queue and self.state == OPEN:
                self._cond.wait(0.5)
            self._queue.append(msg)
            self._cond.notify_all()

    def _read_loop(self):
        var abnormal = true
        try:
            while true:
                var f = self._read_frame()
                var op = f[1]
                var payload = f[2]
                if op == OP_PING:
                    if self.close_sent == none:
                        self._write(encode_frame(true, OP_PONG, payload, self.is_client))
                elif op == OP_PONG:
                    self._on_pong(payload)
                elif op == OP_CLOSE:
                    self._on_close_frame(payload)
                    abnormal = false
                    break
                elif op == OP_CONT:
                    if self._frag_op == none:
                        raise _Failure(1002, "unexpected continuation frame")
                    self._frags.append(payload)
                    self._frag_size = self._frag_size + len(payload)
                    if f[0]:
                        var whole = b"".join(self._frags)
                        var fop = self._frag_op
                        self._frag_op = none
                        self._frags = []
                        self._frag_size = 0
                        self._deliver(fop, whole)
                else:
                    if self._frag_op != none:
                        raise _Failure(1002, "expected a continuation frame")
                    if f[0]:
                        self._deliver(op, payload)
                    else:
                        self._frag_op = op
                        self._frags = [payload]
                        self._frag_size = len(payload)
        except _Failure as e:
            self._fail(e.code, e.reason)
        except (OSError, EOFError, ValueError):
            pass
        finally:
            self._finish(abnormal)

    def _on_close_frame(self, payload):
        var code = 1005
        var reason = ""
        if len(payload) == 1:
            raise _Failure(1002, "close frame too short")
        if len(payload) >= 2:
            code = int.from_bytes(payload[0:2], "big")
            if not _valid_close_code(code):
                raise _Failure(1002, "invalid status code " + str(code))
            try:
                reason = payload[2:].decode("utf-8")
            except UnicodeDecodeError:
                raise _Failure(1007, "invalid UTF-8 in the close reason")
        self.close_rcvd = Close(code, reason)
        with self._send_lock:
            if self.close_sent == none:
                # echo it (RFC 6455 5.5.1)
                self.close_rcvd_then_sent = true
                self.close_sent = Close(code, reason)
                self.state = CLOSING
                try:
                    self._write_locked(encode_frame(true, OP_CLOSE, _close_payload(code, reason), self.is_client))
                except OSError:
                    pass
        if self.is_client:
            # the server closes the TCP connection first; wait for it a little
            try:
                self.socket.settimeout(self.close_timeout)
                self._rf.read(1)
            except (OSError, ValueError):
                pass

    def _fail(self, code, reason):
        # Fail the WebSocket connection (RFC 6455 7.1.7): a close frame if one
        # can still be sent, then the TCP connection goes.
        with self._send_lock:
            if self.close_sent == none and self.state == OPEN:
                self.close_sent = Close(code, reason)
                self.close_rcvd_then_sent = false
                self.state = CLOSING
                try:
                    self._write_locked(encode_frame(true, OP_CLOSE, _close_payload(code, reason[0:100]), self.is_client))
                except OSError:
                    pass
        self._lingering_close()

    # Half-close, then read and discard what the peer still sends for a
    # moment before closing (a "lingering close", RFC 7230 6.6, as Apache
    # does): a socket closed with unread input makes TCP send a reset rather
    # than a FIN, and a reset discards what the peer has not read yet - the
    # Close frame just sent included. A failed connection has unread input
    # by nature (the rest of the bad frame); Windows lost the Close frame
    # every time (round 77).
    def _lingering_close(self):
        try:
            self.socket.shutdown(socket.SHUT_WR)
            var limit = 2.0
            if self.close_timeout != none and self.close_timeout < limit:
                limit = self.close_timeout
            var deadline = monotonic() + limit
            var drained = 0
            while drained < 1048576:
                var left = deadline - monotonic()
                if left <= 0:
                    break
                self.socket.settimeout(left)
                var chunk = self.socket.recv(65536)
                if len(chunk) == 0:
                    break
                drained = drained + len(chunk)
        except (OSError, ValueError):
            pass
        self._shutdown_socket()

    def _shutdown_socket(self):
        try:
            self.socket.shutdown(socket.SHUT_RDWR)
        except (OSError, ValueError):
            pass
        try:
            self.socket.close()
        except (OSError, ValueError):
            pass

    def _finish(self, abnormal):
        with self._cond:
            self.state = CLOSED
            self._cond.notify_all()
        self._closed.set()
        self._shutdown_socket()
        for w in self._pings:
            w.event.set()
        self._pings = []

    # ── pings and the RTT estimator ──
    def _on_pong(self, payload):
        var now = monotonic()
        var matched = -1
        var i = 0
        for w in self._pings:
            if w.data == payload:
                matched = i
                break
            i = i + 1
        if matched < 0:
            return
        # a pong acknowledges its ping and every earlier one
        var acked = self._pings[0:matched + 1]
        self._pings = self._pings[matched + 1:]
        var w2 = acked[len(acked) - 1]
        var rtt = now - w2.sent_at
        self.latency = rtt
        self._sample(rtt)
        for w3 in acked:
            w3.latency = now - w3.sent_at
            w3.event.set()

    def _sample(self, rtt):
        # RFC 6298 2.2-2.3 (alpha 1/8, beta 1/4)
        if self.srtt == none:
            self.srtt = rtt
            self.rttvar = rtt / 2
        else:
            self.rttvar = 0.75 * self.rttvar + 0.25 * abs(self.srtt - rtt)
            self.srtt = 0.875 * self.srtt + 0.125 * rtt

    @property
    def rto(self):
        # How long a ping may go unanswered before the peer counts as gone.
        var ceiling = self.ping_timeout
        if ceiling == none:
            ceiling = 20.0
        if self.srtt == none:
            return ceiling
        var r = self.srtt + max(0.01, 4 * self.rttvar)
        return max(self.min_ping_timeout, min(ceiling, r))

    def ping(self, data=none):
        # Sends a ping; the waiter is set when its pong arrives.
        if data == none:
            data = os_urandom(4)
        elif isinstance(data, "str"):
            data = data.encode("utf-8")
        if len(data) > 125:
            raise ProtocolError("ping payload too long")
        var w = _PingWaiter(bytes(data), monotonic())
        self._pings.append(w)
        self._send_frame(true, OP_PING, bytes(data))
        return w

    def pong(self, data=b""):
        if isinstance(data, "str"):
            data = data.encode("utf-8")
        self._send_frame(true, OP_PONG, bytes(data))

    def _keepalive(self):
        while not self._closed.wait(self.ping_interval):
            if self.state != OPEN:
                return
            var w = none
            try:
                w = self.ping()
            except (ConnectionClosed, OSError):
                return
            if not w.wait(self.rto) and self.state == OPEN:
                self._fail(1011, "keepalive ping timeout")
                return

    # ── sending ──
    def _write_locked(self, data):
        self.socket.sendall(data)

    def _write(self, data):
        with self._send_lock:
            self._write_locked(data)

    def _check_open(self):
        if self.state != OPEN:
            raise self._closed_error()

    def _send_frame(self, fin, opcode, payload):
        with self._send_lock:
            if self.state != OPEN:
                raise self._closed_error()
            try:
                self._write_locked(encode_frame(fin, opcode, payload, self.is_client))
            except OSError:
                raise self._closed_error()

    def send(self, message, text=none):
        # str -> a text message, bytes/bytearray -> binary (text=true/false
        # overrides); an iterable of those -> one fragmented message.
        if isinstance(message, "str") or isinstance(message, "bytes") or isinstance(message, "bytearray"):
            var op = OP_BINARY
            var data = message
            if isinstance(message, "str"):
                op = OP_TEXT
                data = message.encode("utf-8")
            if text == true:
                op = OP_TEXT
            elif text == false:
                op = OP_BINARY
            data = bytes(data)
            if self.fragment_size != none and len(data) > self.fragment_size:
                var parts = []
                var i = 0
                while i < len(data):
                    parts.append(data[i:i + self.fragment_size])
                    i = i + self.fragment_size
                self._send_fragments(op, parts)
                return
            self._send_frame(true, op, data)
            return
        if isinstance(message, "map"):
            raise TypeError("data must be str, bytes, or an iterable of them")
        # fragments
        var first_op = none
        var chunks = []
        for chunk in message:
            var cop = OP_BINARY
            if isinstance(chunk, "str"):
                cop = OP_TEXT
                chunk = chunk.encode("utf-8")
            elif not (isinstance(chunk, "bytes") or isinstance(chunk, "bytearray")):
                raise TypeError("message fragments must be str or bytes")
            if first_op == none:
                first_op = cop
            elif cop != first_op:
                raise TypeError("all fragments must be of the same type")
            chunks.append(bytes(chunk))
        if first_op == none:
            return
        if text == true:
            first_op = OP_TEXT
        elif text == false:
            first_op = OP_BINARY
        self._send_fragments(first_op, chunks)

    def _send_fragments(self, op, parts):
        with self._send_lock:
            if self.state != OPEN:
                raise self._closed_error()
            var n = len(parts)
            var i = 0
            try:
                while i < n:
                    var fop = OP_CONT
                    if i == 0:
                        fop = op
                    self._write_locked(encode_frame(i == n - 1, fop, parts[i], self.is_client))
                    i = i + 1
            except OSError:
                raise self._closed_error()

    # ── receiving ──
    def recv(self, timeout=none, decode=none):
        # The next message: str (text) or bytes (binary). TimeoutError after
        # timeout seconds; ConnectionClosedOK / ConnectionClosedError once the
        # connection is closed and every message was read.
        var deadline = none
        if timeout != none:
            deadline = monotonic() + timeout
        var msg = none
        with self._cond:
            while len(self._queue) == 0 and self.state != CLOSED:
                if deadline == none:
                    self._cond.wait(1.0)
                else:
                    var left = deadline - monotonic()
                    if left <= 0:
                        raise TimeoutError("timed out waiting for a message")
                    self._cond.wait(left)
            if len(self._queue) == 0:
                raise self._closed_error()
            msg = self._queue.pop(0)
            self._cond.notify_all()
        if decode == true and not isinstance(msg, "str"):
            return msg.decode("utf-8")
        if decode == false and isinstance(msg, "str"):
            return msg.encode("utf-8")
        return msg

    def __iter__(self):
        return self._messages()

    def _messages(self):
        while true:
            var m = none
            try:
                m = self.recv()
            except ConnectionClosedOK:
                return
            yield m

    def _closed_error(self):
        var ok = self.close_rcvd != none and self.close_sent != none and (self.close_rcvd.code == 1000 or self.close_rcvd.code == 1001 or self.close_rcvd.code == 1005) and (self.close_sent.code == 1000 or self.close_sent.code == 1001 or self.close_sent.code == 1005)
        if ok:
            return ConnectionClosedOK(self.close_rcvd, self.close_sent, self.close_rcvd_then_sent)
        return ConnectionClosedError(self.close_rcvd, self.close_sent, self.close_rcvd_then_sent)

    # ── closing ──
    def close(self, code=1000, reason=""):
        # The closing handshake: a Close frame, then wait (close_timeout) for
        # the peer's; the TCP connection goes either way.
        if not _valid_close_code(code) and code != 1000:
            raise ProtocolError("invalid status code " + str(code))
        var payload = _close_payload(code, reason)
        var sent = false
        with self._send_lock:
            if self.close_sent == none and self.state == OPEN:
                self.close_sent = Close(code, reason)
                self.close_rcvd_then_sent = false
                self.state = CLOSING
                try:
                    self._write_locked(encode_frame(true, OP_CLOSE, payload, self.is_client))
                    sent = true
                except OSError:
                    pass
        if threading.get_ident() != self._reader_thread.ident:
            if not self._closed.wait(self.close_timeout):
                self._shutdown_socket()
                self._closed.wait(self.close_timeout)
        else:
            self._shutdown_socket()

    @property
    def close_code(self):
        if self.state != CLOSED:
            return none
        if self.close_rcvd == none:
            return 1006
        return self.close_rcvd.code

    @property
    def close_reason(self):
        if self.state != CLOSED:
            return none
        if self.close_rcvd == none:
            return ""
        return self.close_rcvd.reason

    def wait_closed(self, timeout=none):
        return self._closed.wait(timeout)

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return false

    def __repr__(self):
        var side = "server"
        if self.is_client:
            side = "client"
        return "<websocket." + side + " connection " + self.id + " state=" + ["CONNECTING", "OPEN", "CLOSING", "CLOSED"][self.state] + ">"

class ClientConnection(Connection):
    def __init__(self, sock, reader, **kw):
        Connection.__init__(self, sock, reader, true, **kw)

class ServerConnection(Connection):
    def __init__(self, sock, reader, **kw):
        Connection.__init__(self, sock, reader, false, **kw)

    def respond(self, status, text):
        # A plain HTTP response for process_request hooks.
        var body = text.encode("utf-8")
        var phrase = http.client.responses.get(status, "")
        return Response(status, phrase, Headers([("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", str(len(body))), ("Connection", "close")]), body)

# ─── client ─────────────────────────────────────────────────────────────────

def parse_uri(uri):
    # -> [secure, host, port, resource name, user info or none]
    var p = urllib.parse.urlsplit(uri)
    if p.scheme != "ws" and p.scheme != "wss":
        raise InvalidURI(uri, "scheme isn't ws or wss")
    if p.hostname == none or p.hostname == "":
        raise InvalidURI(uri, "hostname isn't provided")
    if p.fragment != "":
        raise InvalidURI(uri, "fragment identifier is meaningless")
    var secure = p.scheme == "wss"
    var port = p.port
    if port == none:
        port = 443 if secure else 80
    var path = p.path
    if path == "":
        path = "/"
    if p.query != "":
        path = path + "?" + p.query
    var userinfo = none
    if p.username != none:
        userinfo = [urllib.parse.unquote(p.username), urllib.parse.unquote(p.password or "")]
    return [secure, p.hostname, port, path, userinfo]

def connect(uri, origin=none, subprotocols=none, additional_headers=none, user_agent_header=USER_AGENT,
            open_timeout=10, ssl=none, server_hostname=none, sock=none, max_size=1048576, max_queue=16,
            ping_interval=none, ping_timeout=none, close_timeout=10, fragment_size=none, compression=none):
    var u = parse_uri(uri)
    var secure = u[0]
    var host = u[1]
    var port = u[2]
    if sock == none:
        sock = socket.create_connection((host, port), open_timeout)
    else:
        sock.settimeout(open_timeout)
    try:
        if secure or ssl != none:
            import ssl as _ssl
            var ctx = ssl
            if ctx == none or ctx == true:
                ctx = _ssl.create_default_context()
            if server_hostname == none:
                server_hostname = host
            sock = ctx.wrap_socket(sock, server_hostname=server_hostname)
        var key = generate_key()
        var hosthdr = host
        if host.find(":") >= 0:
            hosthdr = "[" + host + "]"
        if port != (443 if secure else 80):
            hosthdr = hosthdr + ":" + str(port)
        var lines = ["GET " + u[3] + " HTTP/1.1", "Host: " + hosthdr, "Upgrade: websocket", "Connection: Upgrade",
                     "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13"]
        if u[4] != none:
            lines.append("Authorization: Basic " + base64.b64encode((u[4][0] + ":" + u[4][1]).encode()).decode())
        if origin != none:
            lines.append("Origin: " + origin)
        if subprotocols != none and len(subprotocols) > 0:
            lines.append("Sec-WebSocket-Protocol: " + ", ".join(subprotocols))
        if additional_headers != none:
            for kv in Headers(additional_headers).items():
                lines.append(kv[0] + ": " + kv[1])
        if user_agent_header != none:
            lines.append("User-Agent: " + user_agent_header)
        var request = Request(u[3], Headers([[l[0:l.find(":")], l[l.find(":") + 2:]] for l in lines[1:]]))
        sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("iso-8859-1"))
        var reader = socket.SocketIO(sock, "rb")
        var head = _read_head(reader)
        var status = head[0].split(" ", 2)
        if len(status) < 2 or not status[0].startswith("HTTP/1.") or not status[1].isdigit():
            raise InvalidMessage("did not receive a valid HTTP response: " + repr(head[0]))
        var code = int(status[1])
        var phrase = ""
        if len(status) > 2:
            phrase = status[2]
        var headers = head[1]
        if code != 101:
            var body = b""
            var cl = headers.get("Content-Length")
            if cl != none and cl.isdigit():
                body = reader.read(min(int(cl), 65536))
            raise InvalidStatus(Response(code, phrase, headers, body))
        if not ("websocket" in _tokens(headers.get_all("Upgrade"))):
            raise InvalidUpgrade("Upgrade", headers.get("Upgrade"))
        if not ("upgrade" in _tokens(headers.get_all("Connection"))):
            raise InvalidUpgrade("Connection", headers.get("Connection"))
        var acc = headers.get("Sec-WebSocket-Accept")
        if acc == none:
            raise InvalidHeader("Sec-WebSocket-Accept")
        if acc != accept_key(key):
            raise InvalidHeader("Sec-WebSocket-Accept", acc)
        if headers.get("Sec-WebSocket-Extensions") != none:
            raise NegotiationError("no extensions supported")
        var proto = headers.get("Sec-WebSocket-Protocol")
        if proto != none:
            if subprotocols == none or not (proto in subprotocols):
                raise NegotiationError("unsupported subprotocol: " + proto)
        sock.settimeout(none)
        var conn = ClientConnection(sock, reader, max_size=max_size, max_queue=max_queue, ping_interval=ping_interval,
                                    ping_timeout=ping_timeout, close_timeout=close_timeout, fragment_size=fragment_size)
        conn.subprotocol = proto
        conn.request = request
        conn.response = Response(code, phrase, headers)
        return conn
    except BaseException:
        try:
            sock.close()
        except OSError:
            pass
        raise

# ─── server ─────────────────────────────────────────────────────────────────

class Server:
    # Accepts connections on a socket; each one is handshaken and handled on
    # a thread of its own. serve_forever() until shutdown().
    def __init__(self, handler, sock, ssl=none, process_request=none, process_response=none, subprotocols=none,
                 select_subprotocol=none, origins=none, server_header=SERVER, open_timeout=10, max_size=1048576,
                 max_queue=16, ping_interval=none, ping_timeout=none, close_timeout=10, fragment_size=none, logger=none):
        self.handler = handler
        self.socket = sock
        self.ssl = ssl
        self.process_request = process_request
        self.process_response = process_response
        self.subprotocols = subprotocols
        self.select_subprotocol = select_subprotocol
        self.origins = origins
        self.server_header = server_header
        self.open_timeout = open_timeout
        self.conn_args = {"max_size": max_size, "max_queue": max_queue, "ping_interval": ping_interval,
                          "ping_timeout": ping_timeout, "close_timeout": close_timeout, "fragment_size": fragment_size}
        self.logger = logger
        self.connections = []
        self._lock = threading.Lock()
        self._stopping = false
        self._threads = []
        self._serving = threading.Event()
        self._stopped = threading.Event()
        self._stopped.set()

    @property
    def port(self):
        return self.socket.getsockname()[1]

    @property
    def address(self):
        return self.socket.getsockname()

    def fileno(self):
        return self.socket.fileno()

    def serve_forever(self, poll_interval=0.1):
        self._stopped.clear()
        self._serving.set()
        try:
            while not self._stopping:
                if not self.socket.wait_readable(poll_interval):
                    continue
                if self._stopping:
                    break
                var pair = none
                try:
                    pair = self.socket.accept()
                except OSError:
                    if self._stopping:
                        break
                    continue
                var t = threading.Thread(target=self._handle, args=(pair[0], pair[1]), daemon=true)
                self._threads.append(t)
                t.start()
        finally:
            self._serving.clear()
            self._stopped.set()

    def _log(self, text):
        if self.logger != none:
            self.logger(text)

    def _handshake(self, sock, conn_reader):
        # -> [Request, Response, subprotocol]; an HTTP error response instead
        # of a 101 is sent here and none returned.
        var head = _read_head(conn_reader)
        var words = head[0].split(" ")
        var headers = head[1]
        var req = Request(words[1] if len(words) >= 2 else "/", headers)
        var problem = none
        var status = 400
        if len(words) != 3 or words[0] != "GET" or words[2] != "HTTP/1.1":
            problem = "invalid request line: " + head[0]
            if len(words) == 3 and words[0] != "GET":
                status = 405
        elif not ("websocket" in _tokens(headers.get_all("Upgrade"))):
            problem = "missing or invalid Upgrade header"
            status = 426
        elif not ("upgrade" in _tokens(headers.get_all("Connection"))):
            problem = "missing or invalid Connection header"
            status = 426
        elif headers.get("Sec-WebSocket-Version") != "13":
            problem = "unsupported Sec-WebSocket-Version"
            status = 426
        else:
            var key = headers.get("Sec-WebSocket-Key")
            var raw = none
            try:
                raw = base64.b64decode(key.encode("ascii"), validate=true) if key != none else none
            except Exception:
                raw = none
            if raw == none or len(raw) != 16:
                problem = "missing or invalid Sec-WebSocket-Key header"
        if problem == none and self.origins != none:
            var o = headers.get("Origin")
            if not (o in self.origins):
                problem = "invalid Origin header: " + str(o)
                status = 403
        return [req, problem, status]

    def _handle(self, sock, addr):
        var conn = none
        try:
            sock.settimeout(self.open_timeout)
            if self.ssl != none:
                sock = self.ssl.wrap_socket(sock, server_side=true)
            var reader = socket.SocketIO(sock, "rb")
            var hs = self._handshake(sock, reader)
            var req = hs[0]
            var hdrs = Headers([("Date", _http_date()), ("Server", self.server_header)])
            if self.process_request != none:
                var early = self.process_request(_PendingConnection(self, sock, addr, req), req)
                if early != none:
                    self._send_response(sock, early)
                    sock.close()
                    return
            if hs[1] != none:
                var body = ("Failed to open a WebSocket connection: " + hs[1] + ".\n").encode()
                var eh = Headers([("Date", _http_date()), ("Server", self.server_header), ("Content-Type", "text/plain; charset=utf-8"),
                                  ("Content-Length", str(len(body))), ("Connection", "close")])
                if hs[2] == 426:
                    eh["Upgrade"] = "websocket"
                    eh["Sec-WebSocket-Version"] = "13"
                self._send_response(sock, Response(hs[2], http.client.responses.get(hs[2], ""), eh, body))
                sock.close()
                return
            var proto = none
            var offered = []
            for v in req.headers.get_all("Sec-WebSocket-Protocol"):
                for t in v.split(","):
                    if t.strip() != "":
                        offered.append(t.strip())
            if self.select_subprotocol != none:
                proto = self.select_subprotocol(offered)
            elif self.subprotocols != none:
                for p in self.subprotocols:
                    if p in offered:
                        proto = p
                        break
            hdrs["Upgrade"] = "websocket"
            hdrs["Connection"] = "Upgrade"
            hdrs["Sec-WebSocket-Accept"] = accept_key(req.headers.get("Sec-WebSocket-Key"))
            if proto != none:
                hdrs["Sec-WebSocket-Protocol"] = proto
            var resp = Response(101, "Switching Protocols", hdrs)
            if self.process_response != none:
                var r2 = self.process_response(none, req, resp)
                if r2 != none:
                    resp = r2
            self._send_response(sock, resp)
            if resp.status_code != 101:
                sock.close()
                return
            sock.settimeout(none)
            conn = ServerConnection(sock, reader, **self.conn_args)
            conn.subprotocol = proto
            conn.request = req
            conn.response = resp
            conn.remote_address = addr
            with self._lock:
                self.connections.append(conn)
            try:
                self.handler(conn)
                conn.close()
            except ConnectionClosed:
                pass
            except BaseException as e:
                self._log("connection handler failed: " + type(e).__name__ + ": " + str(e))
                try:
                    conn.close(1011)
                except Exception:
                    pass
        except (OSError, EOFError, InvalidMessage) as e:
            self._log("opening handshake failed: " + str(e))
            try:
                sock.close()
            except OSError:
                pass
        finally:
            if conn != none:
                with self._lock:
                    if conn in self.connections:
                        self.connections.remove(conn)

    def _send_response(self, sock, resp):
        var lines = "HTTP/1.1 " + str(resp.status_code) + " " + resp.reason_phrase + "\r\n" + str(resp.headers)
        sock.sendall(lines.encode("iso-8859-1") + resp.body)

    def broadcast(self, message):
        # Sends to every open connection; a connection that is closing is skipped.
        var conns = []
        with self._lock:
            conns = list(self.connections)
        var n = 0
        for c in conns:
            try:
                c.send(message)
                n = n + 1
            except (ConnectionClosed, OSError):
                pass
        return n

    def shutdown(self, close_connections=true, code=1001, reason=""):
        # Stops serve_forever(), closes the listening socket and (by default)
        # every connection with 1001 "going away".
        self._stopping = true
        if self._serving.is_set():
            self._stopped.wait(5)
        try:
            self.socket.close()
        except OSError:
            pass
        if close_connections:
            var conns = []
            with self._lock:
                conns = list(self.connections)
            for c in conns:
                try:
                    c.close(code, reason)
                except Exception:
                    pass

    def close(self):
        self.shutdown()

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.shutdown()
        return false

class _PendingConnection:
    # What process_request receives: the server's helpers before the upgrade.
    def __init__(self, server, sock, addr, request):
        self.server = server
        self.socket = sock
        self.remote_address = addr
        self.request = request

    def respond(self, status, text):
        var body = text.encode("utf-8")
        return Response(status, http.client.responses.get(status, ""), Headers([("Date", _http_date()), ("Server", self.server.server_header),
                        ("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", str(len(body))), ("Connection", "close")]), body)

def _http_date():
    var t = time_gmtime(time())
    var wd = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][t["weekday"]]
    var mo = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][t["month"] - 1]
    return time_strftime(wd + ", %d " + mo + " %Y %H:%M:%S GMT", t)

def serve(handler, host=none, port=none, sock=none, reuse_address=true, backlog=128, **kw):
    # A Server listening on host:port (or the given socket); call
    # serve_forever() on it.
    if sock == none:
        if host == none:
            host = "0.0.0.0"
        if port == none:
            port = 0
        var fam = socket.AF_INET
        if host.find(":") >= 0:
            fam = socket.AF_INET6
        sock = socket.socket(fam, socket.SOCK_STREAM)
        if reuse_address:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, port))
        sock.listen(backlog)
    return Server(handler, sock, **kw)
