# ═══════════════════════════════════════════════════════════════════════════════
import nytorch
import net
import threading
import socket
import hashlib
import math

# clientserver.ny — Nython Client-Server Framework
# Message bus, JSON-RPC, pub/sub broker, chat server, file transfer,
# heartbeats, pipelines, load balancing, service registry, event log.
# Usage: import "lib/clientserver.ny"
#
# Round 77: the servers serve. Each used to handle one connection at a time
# (a pub/sub broker or chat room with one member), and RpcServer read the
# request "until the client closes" while RpcClient waited for the reply
# before closing - a deadlock on every call. Now every server runs a thread
# per client over lib/socket.ny with newline-delimited framing:
#   RpcServer/RpcClient   JSON-RPC 2.0 (errors -32700/-32600/-32601/-32602/
#                         -32603), one persistent connection, reconnects
#   PubSubBroker/Client   SUB/UNSUB/PUB lines; topic filters with MQTT's
#                         wildcards ("sensors/+/temp", "logs/#")
#   ChatServer            rooms, /join /rooms /who /msg /quit, history
#   FileServer/Client     GET and (when allowed) PUT, binary-safe, SHA-256
#                         checked, no path escapes the root
#   HeartbeatServer/Client  beats plus a phi-accrual failure detector
#                         (Hayashibara et al., 2004): suspicion grows with
#                         the silence measured against the observed beat
#                         intervals, not a fixed timeout
#   LoadBalancer          round_robin, weighted (nginx's smooth weighted
#                         round-robin), least_conn, random; TCP health probes
# ═══════════════════════════════════════════════════════════════════════════════

# ─── framing ─────────────────────────────────────────────────────────────────

class LineConn:
    # A socket read and written a line at a time (UTF-8 text, "\n"-ended).
    def __init__(self, sock):
        self.sock = sock
        self.reader = sock.makefile("rb")
        self._wlock = threading.Lock()
        self.closed = false

    def send_line(self, text):
        if self.closed:
            return false
        try:
            with self._wlock:
                self.sock.sendall((text + "\n").encode("utf-8"))
            return true
        except OSError:
            self.closed = true
            return false

    def read_line(self):
        # the next line without its ending, or none at the end of the stream
        try:
            var raw = self.reader.readline(16777216)
            if len(raw) == 0:
                return none
            return raw.decode("utf-8", "replace").rstrip("\n").rstrip("\r")
        except OSError:
            return none

    def read_exact(self, n):
        try:
            return self.reader.read(n)
        except OSError:
            return b""

    def send_bytes(self, data):
        try:
            with self._wlock:
                self.sock.sendall(data)
            return true
        except OSError:
            self.closed = true
            return false

    def close(self):
        self.closed = true
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except (OSError, ValueError):
            pass
        try:
            self.sock.close()
        except OSError:
            pass

class _ThreadedServer:
    # Accepts on host:port and runs handle(conn, addr) on a thread per client.
    def _setup_server(self, host, port):
        self.host = host
        self.port = port
        self.running = false
        self.server_fd = -1
        self._sock = none
        self._conns = []
        self._clock = threading.Lock()
        self._thread = none

    def bind(self):
        if self._sock == none:
            var fam = socket.AF_INET
            if self.host.find(":") >= 0:
                fam = socket.AF_INET6
            self._sock = socket.create_server((self.host, self.port), fam)
            self.port = self._sock.getsockname()[1]
            self.server_fd = self._sock.fileno()
        return self

    def _run_client(self, sock, addr):
        var conn = LineConn(sock)
        with self._clock:
            self._conns.append(conn)
        try:
            self.handle(conn, addr)
        except Exception as e:
            eprint("[" + type(self).__name__ + "] client " + str(addr) + ": " + type(e).__name__ + ": " + str(e))
        finally:
            conn.close()
            with self._clock:
                self._conns = [c for c in self._conns if c is not conn]

    def listen(self, quiet=true):
        try:
            self.bind()
        except OSError:
            return false
        self.running = true
        if not quiet:
            print type(self).__name__ + " on " + self.host + ":" + str(self.port)
        while self.running:
            if not self._sock.wait_readable(0.1):
                continue
            var pair = none
            try:
                pair = self._sock.accept()
            except OSError:
                if not self.running:
                    break
                continue
            var t = threading.Thread(target=self._run_client, args=(pair[0], pair[1]), daemon=true)
            t.start()
        return true

    def start(self):
        # listen() on a thread; returns once bound (self.port is the real port)
        self.bind()
        self.running = true
        self._thread = threading.Thread(target=self.listen, daemon=true)
        self._thread.start()
        return self

    def stop(self):
        self.running = false
        if self._thread != none and self._thread.ident != threading.get_ident():
            self._thread.join(2)
        if self._sock != none:
            self._sock.close()
            self._sock = none
        var cs = []
        with self._clock:
            cs = list(self._conns)
        for c in cs:
            c.close()

def _connect(host, port, timeout=10):
    return LineConn(socket.create_connection((host, port), timeout))

# ─── Message Protocol ─────────────────────────────────────────────────────────

class Message:
    _seq = 0

    def __init__(self, topic, payload, from_id):
        self.topic = topic
        self.type = topic
        self.payload = payload
        self.from_id = from_id
        self.to_id = ""
        Message._seq = Message._seq + 1
        self.id = str(int(time_ms())) + "-" + str(Message._seq)
        self.timestamp = time_now()

    def to_wire(self):
        return json_encode({"type": self.type, "payload": self.payload, "id": self.id, "from": self.from_id, "to": self.to_id, "ts": self.timestamp})

    def from_wire(self, wire):
        var data = none
        try:
            data = json_decode(wire)
        except Exception:
            return false
        if not isinstance(data, "map"):
            return false
        self.type = data.get("type", "")
        self.topic = self.type
        self.payload = data.get("payload")
        self.id = data.get("id", "")
        self.from_id = data.get("from", "")
        self.to_id = data.get("to", "")
        self.timestamp = data.get("ts", 0)
        return true

def topic_matches(filter, topic):
    # MQTT 3.1.1 topic filters: "+" one level, "#" every level below.
    var f = filter.split("/")
    var t = topic.split("/")
    var i = 0
    while i < len(f):
        if f[i] == "#":
            return true
        if i >= len(t):
            return false
        if f[i] != "+" and f[i] != t[i]:
            return false
        i = i + 1
    return len(f) == len(t)

class MessageBus:
    # In-process publish/subscribe; subscribe() filters may use + and #.
    def __init__(self):
        self.subscribers = {}
        self.sub_counts = {}
        self.history = []
        self.history_size = 1000
        self.hist_count = 0
        self._subs = []          # [filter, handler]
        self._lock = threading.Lock()

    def subscribe(self, topic, handler):
        with self._lock:
            self._subs.append([topic, handler])
            self.sub_counts[topic] = self.sub_counts.get(topic, 0) + 1
            self.subscribers[topic + "_" + str(self.sub_counts[topic] - 1)] = handler

    def unsubscribe(self, topic, handler=none):
        with self._lock:
            self._subs = [s for s in self._subs if not (s[0] == topic and (handler == none or s[1] is handler))]
            self.sub_counts[topic] = len([s for s in self._subs if s[0] == topic])

    def publish(self, msg):
        var handlers = []
        with self._lock:
            for s in self._subs:
                if topic_matches(s[0], msg.topic):
                    handlers.append(s[1])
            self.history.append(msg)
            if len(self.history) > self.history_size:
                self.history = self.history[len(self.history) - self.history_size:]
            self.hist_count = len(self.history)
        for h in handlers:
            h(msg)
        return len(handlers)

    def publish_raw(self, topic, payload):
        return self.publish(Message(topic, payload, ""))

    def get_history(self, topic=none):
        if topic == none:
            return list(self.history)
        return [m for m in self.history if topic_matches(topic, m.topic)]

# ─── RPC (JSON-RPC 2.0 over newline-delimited TCP) ───────────────────────────

class RpcError(Exception):
    def __init__(self, code, message, data=none):
        Exception.__init__(self, message)
        self.code = code
        self.message = message
        self.data = data

class RpcServer(_ThreadedServer):
    # register(name, fn): fn(params) gets the request's params as they came
    # (a list or a map); spread=true calls fn(*list) / fn(**map) instead.
    def __init__(self, host, port):
        self._setup_server(host, port)
        self.methods = {}
        self._spread = {}
        self.calls = 0

    def register(self, name, fn, spread=false):
        self.methods[name] = fn
        self._spread[name] = spread
        return self

    def _error(self, rid, code, message):
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}

    def dispatch(self, req):
        # one request map -> its response map (none for a notification)
        if not isinstance(req, "map") or not ("method" in req) or not isinstance(req["method"], "str"):
            return self._error(none, -32600, "Invalid Request")
        var rid = req.get("id")
        var is_notification = not ("id" in req)
        var fn = self.methods.get(req["method"])
        if fn == none:
            if is_notification:
                return none
            return self._error(rid, -32601, "Method not found: " + req["method"])
        var params = req.get("params")
        var result = none
        try:
            if self._spread.get(req["method"], false):
                if isinstance(params, "list"):
                    result = fn(*params)
                elif isinstance(params, "map"):
                    result = fn(**params)
                else:
                    result = fn()
            else:
                result = fn(params)
        except TypeError as e:
            return none if is_notification else self._error(rid, -32602, "Invalid params: " + str(e))
        except RpcError as e:
            return none if is_notification else self._error(rid, e.code, e.message)
        except Exception as e:
            return none if is_notification else self._error(rid, -32603, type(e).__name__ + ": " + str(e))
        self.calls = self.calls + 1
        if is_notification:
            return none
        return {"jsonrpc": "2.0", "id": rid, "result": result}

    def handle(self, conn, addr):
        while true:
            var line = conn.read_line()
            if line == none:
                return
            if line.strip() == "":
                continue
            var req = none
            try:
                req = json_decode(line)
            except Exception:
                conn.send_line(json_encode(self._error(none, -32700, "Parse error")))
                continue
            var out = none
            if isinstance(req, "list"):
                var rs = [self.dispatch(r) for r in req]
                rs = [r for r in rs if r != none]
                if len(req) == 0:
                    out = self._error(none, -32600, "Invalid Request")
                elif len(rs) > 0:
                    out = rs
            else:
                out = self.dispatch(req)
            if out != none:
                conn.send_line(json_encode(out))

class RpcClient:
    # call(method, params) -> the result; none on failure (last_error says
    # why), or raise=true for an RpcError. One connection, reopened if lost.
    def __init__(self, host, port, timeout=10):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._call_id = 0
        self._conn = none
        self._lock = threading.Lock()
        self.last_error = none

    def _ensure(self):
        if self._conn == none or self._conn.closed:
            self._conn = _connect(self.host, self.port, self.timeout)

    def _roundtrip(self, payload):
        var tries = 0
        while true:
            tries = tries + 1
            try:
                self._ensure()
                if not self._conn.send_line(payload):
                    raise ConnectionError("send failed")
                var line = self._conn.read_line()
                if line == none:
                    raise ConnectionError("connection closed")
                return json_decode(line)
            except OSError as e:
                if self._conn != none:
                    self._conn.close()
                self._conn = none
                if tries >= 2:
                    raise

    def call(self, method, params=none, raise_errors=false):
        with self._lock:
            self._call_id = self._call_id + 1
            var req = {"jsonrpc": "2.0", "id": self._call_id, "method": method}
            if params != none:
                req["params"] = params
            var resp = none
            try:
                resp = self._roundtrip(json_encode(req))
            except OSError as e:
                self.last_error = RpcError(-32000, "transport: " + str(e))
                if raise_errors:
                    raise self.last_error
                return none
            var err = resp.get("error")
            if err != none:
                self.last_error = RpcError(err.get("code", -32603), err.get("message", ""), err.get("data"))
                if raise_errors:
                    raise self.last_error
                return none
            self.last_error = none
            return resp.get("result")

    def notify(self, method, params=none):
        with self._lock:
            var req = {"jsonrpc": "2.0", "method": method}
            if params != none:
                req["params"] = params
            self._ensure()
            return self._conn.send_line(json_encode(req))

    def batch(self, calls):
        # [[method, params], ...] -> results in the same order (none for errors)
        with self._lock:
            var reqs = []
            for c in calls:
                self._call_id = self._call_id + 1
                reqs.append({"jsonrpc": "2.0", "id": self._call_id, "method": c[0], "params": c[1]})
            var resp = self._roundtrip(json_encode(reqs))
            var by_id = {}
            for r in resp:
                by_id[r.get("id")] = r
            return [by_id.get(q["id"], {}).get("result") for q in reqs]

    def close(self):
        if self._conn != none:
            self._conn.close()
            self._conn = none

# ─── Pub/Sub Broker ──────────────────────────────────────────────────────────

class PubSubBroker(_ThreadedServer):
    # Lines: "SUB <filter>", "UNSUB <filter>", "PUB <topic> <message>";
    # subscribers receive "<topic> <message>". Filters take + and #.
    def __init__(self, host, port, retain=false):
        self._setup_server(host, port)
        self.topics = {}             # filter -> [LineConn]
        self.topic_counts = {}
        self.clients = {}
        self.client_count = 0
        self.published = 0
        self.retain = retain
        self.retained = {}           # topic -> last message (retain=true)
        self._tlock = threading.Lock()

    def _subscribe(self, conn, topic):
        with self._tlock:
            var subs = self.topics.get(topic, [])
            if not (conn in subs):
                subs.append(conn)
            self.topics[topic] = subs
            self.topic_counts[topic] = len(subs)
        if self.retain:
            for t in list(self.retained.keys()):
                if topic_matches(topic, t):
                    conn.send_line(t + " " + self.retained[t])

    def _unsubscribe(self, conn, topic):
        with self._tlock:
            var subs = [c for c in self.topics.get(topic, []) if c is not conn]
            self.topics[topic] = subs
            self.topic_counts[topic] = len(subs)

    def _publish(self, topic, msg):
        var targets = []
        with self._tlock:
            for f in self.topics:
                if topic_matches(f, topic):
                    for c in self.topics[f]:
                        if not (c in targets):
                            targets.append(c)
            if self.retain:
                self.retained[topic] = msg
            self.published = self.published + 1
        var n = 0
        for c in targets:
            if c.send_line(topic + " " + msg):
                n = n + 1
        return n

    def handle(self, conn, addr):
        self.client_count = self.client_count + 1
        var cid = "client_" + str(self.client_count)
        self.clients[cid] = conn
        try:
            while true:
                var line = conn.read_line()
                if line == none:
                    break
                if line.startswith("SUB "):
                    var topic = line[4:].strip()
                    self._subscribe(conn, topic)
                    conn.send_line("SUBSCRIBED " + topic)
                elif line.startswith("UNSUB "):
                    var topic2 = line[6:].strip()
                    self._unsubscribe(conn, topic2)
                    conn.send_line("UNSUBSCRIBED " + topic2)
                elif line.startswith("PUB "):
                    var rest = line[4:]
                    var sp = rest.find(" ")
                    if sp >= 0:
                        self._publish(rest[0:sp], rest[sp + 1:])
                elif line == "PING":
                    conn.send_line("PONG")
        finally:
            with self._tlock:
                for f in self.topics:
                    self.topics[f] = [c for c in self.topics[f] if c is not conn]
                    self.topic_counts[f] = len(self.topics[f])
            del self.clients[cid]

class PubSubClient:
    def __init__(self, host, port):
        self.host = host
        self.port = port
        self.fd = none
        self._handlers = {}
        self._thread = none
        self.received = 0

    def connect(self, timeout=10):
        try:
            self.fd = _connect(self.host, self.port, timeout)
            self.fd.sock.settimeout(none)
            return true
        except OSError:
            self.fd = none
            return false

    def subscribe(self, topic, handler):
        self._handlers[topic] = handler
        return self.fd.send_line("SUB " + topic)

    def unsubscribe(self, topic):
        if topic in self._handlers:
            del self._handlers[topic]
        return self.fd.send_line("UNSUB " + topic)

    def publish(self, topic, msg):
        return self.fd.send_line("PUB " + topic + " " + str(msg))

    def _deliver(self, line):
        var sp = line.find(" ")
        if sp < 0:
            return
        var topic = line[0:sp]
        var msg = line[sp + 1:]
        if topic == "SUBSCRIBED" or topic == "UNSUBSCRIBED":
            return
        self.received = self.received + 1
        for f in list(self._handlers.keys()):
            if topic_matches(f, topic):
                var h = self._handlers.get(f)
                if h != none:
                    h(msg)

    def listen(self):
        while self.fd != none:
            var line = self.fd.read_line()
            if line == none:
                break
            self._deliver(line)

    def start(self):
        # listen() on a thread
        self._thread = threading.Thread(target=self.listen, daemon=true)
        self._thread.start()
        return self

    def close(self):
        if self.fd != none:
            self.fd.close()
            self.fd = none

# ─── Chat Server ─────────────────────────────────────────────────────────────

class ChatRoom:
    def __init__(self, name):
        self.name = name
        self.members = {}            # nick -> LineConn (or -1 for a member without one)
        self.member_count = 0
        self.history = []
        self.hist_count = 0
        self.max_history = 100
        self._lock = threading.Lock()

    def join(self, user_id, conn_fd):
        with self._lock:
            if not (user_id in self.members):
                self.member_count = self.member_count + 1
            self.members[user_id] = conn_fd if conn_fd != none else -1
        self.broadcast("SYSTEM", user_id + " joined")

    def is_member(self, user_id):
        return user_id in self.members

    def leave(self, user_id):
        with self._lock:
            if user_id in self.members:
                del self.members[user_id]
                self.member_count = self.member_count - 1
        self.broadcast("SYSTEM", user_id + " left")

    def broadcast(self, from_user, text):
        var msg = "[" + from_user + "] " + text
        var conns = []
        with self._lock:
            self.history.append(msg)
            if len(self.history) > self.max_history:
                self.history = self.history[len(self.history) - self.max_history:]
            self.hist_count = len(self.history)
            conns = [c for c in self.members.values() if isinstance(c, LineConn)]
        for c in conns:
            c.send_line(msg)

    def send_history(self, conn_fd):
        for line in list(self.history):
            conn_fd.send_line(line)

    def who(self):
        return sorted(list(self.members.keys()))

class ChatServer(_ThreadedServer):
    # Asks "NICK?", then lines are said in the current room; commands:
    # /join <room>, /rooms, /who, /msg <nick> <text>, /quit.
    def __init__(self, host, port):
        self._setup_server(host, port)
        self.rooms = {}
        self.clients = {}
        self.client_names = {}
        self._rlock = threading.Lock()

    def get_or_create_room(self, name):
        with self._rlock:
            var r = self.rooms.get(name)
            if r == none:
                r = ChatRoom(name)
                self.rooms[name] = r
            return r

    def handle(self, conn, addr):
        conn.send_line("NICK?")
        var nick = conn.read_line()
        if nick == none:
            return
        nick = nick.strip()
        if nick == "" or nick in self.clients:
            conn.send_line("ERROR nick unavailable")
            return
        self.clients[nick] = conn
        conn.send_line("Welcome " + nick + "!")
        var room = self.get_or_create_room("general")
        room.join(nick, conn)
        try:
            while true:
                var line = conn.read_line()
                if line == none:
                    break
                line = line.strip()
                if line == "":
                    continue
                if line.startswith("/join "):
                    room.leave(nick)
                    room = self.get_or_create_room(line[6:].strip())
                    room.send_history(conn)
                    room.join(nick, conn)
                elif line == "/rooms":
                    conn.send_line("ROOMS " + " ".join(sorted(list(self.rooms.keys()))))
                elif line == "/who":
                    conn.send_line("WHO " + " ".join(room.who()))
                elif line.startswith("/msg "):
                    var rest = line[5:]
                    var sp = rest.find(" ")
                    var target = self.clients.get(rest[0:sp] if sp >= 0 else rest)
                    if target == none or sp < 0:
                        conn.send_line("ERROR no such user")
                    else:
                        target.send_line("[" + nick + " -> you] " + rest[sp + 1:])
                elif line == "/quit":
                    break
                else:
                    room.broadcast(nick, line)
        finally:
            room.leave(nick)
            if nick in self.clients:
                del self.clients[nick]

# ─── File Transfer ────────────────────────────────────────────────────────────

class FileServer(_ThreadedServer):
    # "GET <name>" -> "SIZE:<n> SHA256:<hex>" and the bytes, or
    # "ERROR:NOT_FOUND"; "PUT <name> <n>" + bytes when allow_upload. Names
    # never leave root_dir.
    def __init__(self, host, port, root_dir, allow_upload=false, max_upload=104857600):
        self._setup_server(host, port)
        self.root_dir = root_dir
        self.allow_upload = allow_upload
        self.max_upload = max_upload
        self.served = 0

    def resolve(self, name):
        var parts = []
        for w in name.replace("\\", "/").split("/"):
            if w == "" or w == ".":
                continue
            if w == ".." or (len(w) >= 2 and w[1] == ":"):
                return none
            parts.append(w)
        if len(parts) == 0:
            return none
        var p = self.root_dir
        for w in parts:
            p = os_path_join(p, w)
        return p

    def handle(self, conn, addr):
        var line = conn.read_line()
        if line == none:
            return
        line = line.strip()
        if line.startswith("PUT "):
            var bits = line[4:].rsplit(" ", 1)
            if not self.allow_upload or len(bits) != 2 or not bits[1].isdigit():
                conn.send_line("ERROR:FORBIDDEN")
                return
            var n = int(bits[1])
            var target = self.resolve(bits[0])
            if target == none or n > self.max_upload:
                conn.send_line("ERROR:FORBIDDEN")
                return
            var data = conn.read_exact(n)
            if len(data) != n:
                return
            var dir = os_path_dirname(target)
            if dir != "" and not os_isdir(dir):
                os_makedirs(dir, true)
            var f = open(target, "wb")
            f.write(data)
            f.close()
            conn.send_line("OK SHA256:" + hashlib.sha256(data).hexdigest())
            return
        var name = line
        if line.startswith("GET "):
            name = line[4:].strip()
        var path = self.resolve(name)
        if path == none or not os_isfile(path):
            conn.send_line("ERROR:NOT_FOUND")
            return
        var fh = open(path, "rb")
        var content = fh.read()
        fh.close()
        conn.send_bytes(("SIZE:" + str(len(content)) + " SHA256:" + hashlib.sha256(content).hexdigest() + "\n").encode("ascii") + content)
        self.served = self.served + 1

class FileClient:
    def __init__(self, host, port, timeout=30):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.last_error = none

    def fetch(self, filename):
        # the file's bytes, or none (last_error says why)
        var conn = none
        try:
            conn = _connect(self.host, self.port, self.timeout)
            conn.send_line("GET " + filename)
            var head = conn.read_line()
            if head == none or head.startswith("ERROR"):
                self.last_error = head or "no reply"
                return none
            var fields = {}
            for part in head.split(" "):
                var c = part.find(":")
                if c > 0:
                    fields[part[0:c]] = part[c + 1:]
            var n = int(fields.get("SIZE", "0"))
            var data = conn.read_exact(n)
            if len(data) != n:
                self.last_error = "short transfer"
                return none
            if "SHA256" in fields and hashlib.sha256(data).hexdigest() != fields["SHA256"]:
                self.last_error = "checksum mismatch"
                return none
            return data
        except OSError as e:
            self.last_error = str(e)
            return none
        finally:
            if conn != none:
                conn.close()

    def download(self, filename, save_path):
        var data = self.fetch(filename)
        if data == none:
            return false
        var f = open(save_path, "wb")
        f.write(data)
        f.close()
        return true

    def upload(self, local_path, remote_name):
        var f = open(local_path, "rb")
        var data = f.read()
        f.close()
        var conn = none
        try:
            conn = _connect(self.host, self.port, self.timeout)
            conn.send_bytes(("PUT " + remote_name + " " + str(len(data)) + "\n").encode("utf-8") + data)
            var reply = conn.read_line()
            if reply == none or not reply.startswith("OK"):
                self.last_error = reply or "no reply"
                return false
            return reply == "OK SHA256:" + hashlib.sha256(data).hexdigest()
        except OSError as e:
            self.last_error = str(e)
            return false
        finally:
            if conn != none:
                conn.close()

# ─── Heartbeat with a phi-accrual failure detector ───────────────────────────

class PhiAccrualDetector:
    # Hayashibara, Defago, Yared, Katayama (2004): phi = -log10(P(a beat
    # arrives later than now)), with beat intervals modelled as a normal
    # distribution fitted to a sliding window of the observed ones. phi 1
    # means a 10% chance the peer is still alive and merely late, phi 8
    # one in 10^8.
    def __init__(self, window=100, min_std_ms=50.0, first_interval_ms=1000.0):
        self.window = window
        self.min_std = min_std_ms / 1000.0
        # until a real interval is seen, a guess (Akka's bootstrap)
        self.intervals = [first_interval_ms / 1000.0]
        self._guess = true
        self.last = none

    def beat(self, now=none):
        if now == none:
            now = monotonic()
        if self.last != none:
            if self._guess:
                self.intervals = []
                self._guess = false
            self.intervals.append(now - self.last)
            if len(self.intervals) > self.window:
                self.intervals = self.intervals[len(self.intervals) - self.window:]
        self.last = now

    def phi(self, now=none):
        if self.last == none:
            return 0.0
        if now == none:
            now = monotonic()
        var n = len(self.intervals)
        var mean = sum(self.intervals) / n
        var var_ = 0.0
        for x in self.intervals:
            var_ = var_ + (x - mean) * (x - mean)
        var std = max(math.sqrt(var_ / n), self.min_std)
        var t = now - self.last
        # 1 - CDF(t) of N(mean, std), by the logistic approximation of the
        # normal CDF Akka uses (accurate to ~1e-4 where it matters)
        var y = (t - mean) / std
        var e = math.exp(-y * (1.5976 + 0.070566 * y * y))
        var p_later = 0.0
        if t > mean:
            p_later = e / (1.0 + e)
        else:
            p_later = 1.0 - 1.0 / (1.0 + e)
        if p_later < 1e-300:
            return 300.0
        return -math.log10(p_later)

    def is_available(self, threshold=8.0, now=none):
        return self.phi(now) < threshold

class HeartbeatServer(_ThreadedServer):
    # Sends "PING <unix time>" to every connected client each interval_ms.
    def __init__(self, host, port, interval_ms):
        self._setup_server(host, port)
        self.interval_ms = interval_ms
        self.clients = {}
        self.client_count = 0
        self.beats_sent = 0
        self._beater = none

    def handle(self, conn, addr):
        self.client_count = self.client_count + 1
        var cid = "c_" + str(self.client_count)
        self.clients[cid] = conn
        while self.running:
            var line = conn.read_line()
            if line == none:
                break
        if cid in self.clients:
            del self.clients[cid]

    def _send_beats(self):
        while self.running:
            sleep(self.interval_ms / 1000.0)
            var ts = str(time_now())
            for cid in list(self.clients.keys()):
                var c = self.clients.get(cid)
                if c != none and not c.send_line("PING " + ts):
                    if cid in self.clients:
                        del self.clients[cid]
                else:
                    self.beats_sent = self.beats_sent + 1

    def start(self):
        _ThreadedServer.start(self)
        self._beater = threading.Thread(target=self._send_beats, daemon=true)
        self._beater.start()
        return self

class HeartbeatClient:
    def __init__(self, host, port, threshold=8.0):
        self.host = host
        self.port = port
        self.fd = none
        self.last_beat = 0.0
        self.alive = false
        self.beats = 0
        self.threshold = threshold
        self.detector = PhiAccrualDetector()
        self.on_beat_handler = none
        self._thread = none

    def on_beat(self, fn):
        self.on_beat_handler = fn

    def connect(self, timeout=10):
        try:
            self.fd = _connect(self.host, self.port, timeout)
            self.fd.sock.settimeout(none)
        except OSError:
            self.fd = none
            return false
        self.alive = true
        return true

    def listen(self):
        while self.alive and self.fd != none:
            var line = self.fd.read_line()
            if line == none:
                self.alive = false
                break
            if line.startswith("PING"):
                self.last_beat = time_now()
                self.beats = self.beats + 1
                self.detector.beat()
                if self.on_beat_handler != none:
                    self.on_beat_handler(self.last_beat)

    def start(self):
        self._thread = threading.Thread(target=self.listen, daemon=true)
        self._thread.start()
        return self

    def phi(self):
        return self.detector.phi()

    def suspected(self):
        # whether the server should be presumed dead now
        return not self.alive or not self.detector.is_available(self.threshold)

    def close(self):
        self.alive = false
        if self.fd != none:
            self.fd.close()
            self.fd = none

# ─── Pipeline ─────────────────────────────────────────────────────────────────

class PipelineStage:
    def __init__(self, name, fn):
        self.name = name
        self.fn = fn
        self.enabled = true
        self.processed = 0
        self.errors = 0


class Pipeline:
    # Stages applied in order; a stage returning none (or raising) stops it.
    def __init__(self, name):
        self.name = name
        self.stages = []
        self.stage_count = 0
        self.processed = 0
        self.failed = 0
        self.last_error = none
        self._on_error = none
        self._on_success = none

    def add_stage(self, name, fn):
        self.stages.append(PipelineStage(name, fn))
        self.stage_count = self.stage_count + 1
        return self

    def on_error(self, fn):
        self._on_error = fn
        return self

    def on_success(self, fn):
        self._on_success = fn
        return self

    def disable_stage(self, name):
        for s in self.stages:
            if s.name == name:
                s.enabled = false
        return self

    def enable_stage(self, name):
        for s in self.stages:
            if s.name == name:
                s.enabled = true
        return self

    def execute(self, data):
        var current = data
        for stage in self.stages:
            if not stage.enabled:
                continue
            var result = none
            try:
                result = stage.fn(current)
            except Exception as e:
                self.last_error = e
                result = none
            stage.processed = stage.processed + 1
            if result == none:
                stage.errors = stage.errors + 1
                self.failed = self.failed + 1
                if self._on_error != none:
                    self._on_error(stage.name, current)
                return none
            current = result
        self.processed = self.processed + 1
        if self._on_success != none:
            self._on_success(current)
        return current

    def stats(self):
        var s = {}
        s["name"] = self.name
        s["processed"] = self.processed
        s["failed"] = self.failed
        s["stages"] = self.stage_count
        return s


# ─── LoadBalancer ─────────────────────────────────────────────────────────────

class BackendServer:
    def __init__(self, host, port, weight):
        self.host = host
        self.port = port
        self.weight = weight
        self.current_weight = 0
        self.healthy = true
        self.active_connections = 0
        self.total_requests = 0
        self.failed_requests = 0

    def address(self):
        return self.host + ":" + str(self.port)


class LoadBalancer:
    # next() picks a healthy backend: round_robin, weighted (smooth weighted
    # round-robin: weights 5,1,1 give a,a,b,a,c,a,a - no bursts), least_conn,
    # random. acquire()/release() track active connections for least_conn.
    def __init__(self, strategy):
        self.strategy = strategy
        self.backends = []
        self.backend_count = 0
        self._rr_index = 0
        self.total_requests = 0
        self._lock = threading.Lock()

    def add_backend(self, host, port, weight=1):
        self.backends.append(BackendServer(host, port, weight))
        self.backend_count = self.backend_count + 1
        return self

    def remove_backend(self, host, port):
        self.backends = [b for b in self.backends if b.host != host or b.port != port]
        self.backend_count = len(self.backends)
        return self

    def mark_unhealthy(self, host, port):
        for b in self.backends:
            if b.host == host and b.port == port:
                b.healthy = false

    def mark_healthy(self, host, port):
        for b in self.backends:
            if b.host == host and b.port == port:
                b.healthy = true

    def _healthy_backends(self):
        return [b for b in self.backends if b.healthy]

    def next(self):
        with self._lock:
            var healthy = self._healthy_backends()
            if len(healthy) == 0:
                return none
            self.total_requests = self.total_requests + 1
            var pick = none
            if self.strategy == "least_conn":
                pick = healthy[0]
                for b in healthy:
                    if b.active_connections < pick.active_connections:
                        pick = b
            elif self.strategy == "weighted":
                var total = 0
                for b in healthy:
                    b.current_weight = b.current_weight + b.weight
                    total = total + b.weight
                    if pick == none or b.current_weight > pick.current_weight:
                        pick = b
                pick.current_weight = pick.current_weight - total
            elif self.strategy == "random":
                pick = healthy[random_int(0, len(healthy) - 1)]
            else:
                pick = healthy[self._rr_index % len(healthy)]
                self._rr_index = self._rr_index + 1
            pick.total_requests = pick.total_requests + 1
            return pick

    def acquire(self):
        var b = self.next()
        if b != none:
            b.active_connections = b.active_connections + 1
        return b

    def release(self, backend, failed=false):
        if backend.active_connections > 0:
            backend.active_connections = backend.active_connections - 1
        if failed:
            backend.failed_requests = backend.failed_requests + 1

    def health_check(self, timeout=1.0):
        # TCP-connects to every backend; marks each healthy or not
        for b in self.backends:
            try:
                var s = socket.create_connection((b.host, b.port), timeout)
                s.close()
                b.healthy = true
            except OSError:
                b.healthy = false
        return self.healthy_count()

    def healthy_count(self):
        return len(self._healthy_backends())

    def stats(self):
        var s = {}
        s["total_backends"] = self.backend_count
        s["healthy"] = self.healthy_count()
        s["total_requests"] = self.total_requests
        s["strategy"] = self.strategy
        return s


# ─── ServiceRegistry ──────────────────────────────────────────────────────────

class ServiceInstance:
    def __init__(self, name, host, port, metadata):
        self.name = name
        self.host = host
        self.port = port
        self.metadata = metadata
        self.registered_at = time_now()
        self.last_heartbeat = time_now()
        self.healthy = true
        self.id = name + "_" + host + "_" + str(port)


class ServiceRegistry:
    def __init__(self):
        self.services = {}
        self.instances = []
        self.instance_count = 0
        self.ttl = 30.0
        self._rr = {}

    def register(self, name, host, port, metadata=none):
        var svc = ServiceInstance(name, host, port, metadata)
        if svc.id in self.services:
            self.deregister(svc.id)
        self.services[svc.id] = svc
        self.instances.append(svc)
        self.instance_count = len(self.instances)
        return svc.id

    def deregister(self, service_id):
        if service_id in self.services:
            del self.services[service_id]
            self.instances = [s for s in self.instances if s.id != service_id]
            self.instance_count = len(self.instances)

    def heartbeat(self, service_id):
        var svc = self.services.get(service_id)
        if svc != none:
            svc.last_heartbeat = time_now()
            svc.healthy = true

    def get(self, name):
        return [s for s in self.instances if s.name == name and s.healthy]

    def get_one(self, name):
        # round-robin over the healthy instances
        var matches = self.get(name)
        if len(matches) == 0:
            return none
        var i = self._rr.get(name, 0)
        self._rr[name] = i + 1
        return matches[i % len(matches)]

    def expire_stale(self):
        var now = time_now()
        for s in self.instances:
            if now - s.last_heartbeat > self.ttl:
                s.healthy = false

    def all_services(self):
        var names = []
        for s in self.instances:
            if not (s.name in names):
                names.append(s.name)
        return names

    def count(self):
        return self.instance_count

    def healthy_count(self):
        return len([s for s in self.instances if s.healthy])


# ─── EventLog ─────────────────────────────────────────────────────────────────

class LogEntry:
    _seq = 0

    def __init__(self, level, source, message, data):
        self.level = level
        self.source = source
        self.message = message
        self.data = data
        self.timestamp = time_now()
        LogEntry._seq = LogEntry._seq + 1
        self.id = str(int(time_ms())) + "-" + str(LogEntry._seq)


class EventLog:
    def __init__(self, max_entries):
        self.entries = []
        self.entry_count = 0
        self.max_entries = max_entries
        self.level_counts = {}
        self._subscribers = []
        self._sub_count = 0
        self._lock = threading.Lock()

    def _log(self, level, source, message, data):
        var entry = LogEntry(level, source, message, data)
        var subs = []
        with self._lock:
            self.entries.append(entry)
            if len(self.entries) > self.max_entries:
                self.entries = self.entries[len(self.entries) - self.max_entries:]
            self.entry_count = len(self.entries)
            self.level_counts[level] = self.level_counts.get(level, 0) + 1
            subs = list(self._subscribers)
        for fn in subs:
            fn(entry)
        return entry

    def info(self, source, message):
        return self._log("INFO", source, message, none)

    def warn(self, source, message):
        return self._log("WARN", source, message, none)

    def error(self, source, message):
        return self._log("ERROR", source, message, none)

    def debug(self, source, message):
        return self._log("DEBUG", source, message, none)

    def event(self, source, message, data):
        return self._log("EVENT", source, message, data)

    def subscribe(self, fn):
        self._subscribers.append(fn)
        self._sub_count = len(self._subscribers)

    def filter_by_level(self, level):
        return [e for e in self.entries if e.level == level]

    def filter_by_source(self, source):
        return [e for e in self.entries if e.source == source]

    def last(self, n):
        if n >= self.entry_count:
            return list(self.entries)
        return self.entries[self.entry_count - n:]

    def clear(self):
        with self._lock:
            self.entries = []
            self.entry_count = 0
            self.level_counts = {}

    def stats(self):
        var s = {}
        s["total"] = self.entry_count
        s["info"] = self.level_counts.get("INFO", 0)
        s["warn"] = self.level_counts.get("WARN", 0)
        s["error"] = self.level_counts.get("ERROR", 0)
        s["debug"] = self.level_counts.get("DEBUG", 0)
        s["event"] = self.level_counts.get("EVENT", 0)
        return s
