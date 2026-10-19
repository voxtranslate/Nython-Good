# ══════════════════════════════════════════════════════════════════════════════
#  lib/ide_debugclient.ny — the IDE's side of live debugging (round 81).
#
#  LiveDebugClient talks to lib/ide_debugserver.ny (the program runs as
#  `nython --debug-port N file.ny`) over a local socket, with the Debug
#  Adapter Protocol's framing and messages, without ever blocking the IDE:
#  poll() is called once per frame, reads what has arrived and sends what
#  follows from it. When the program stops, the client asks for its stack,
#  the selected frame's scopes and the Locals scope's variables by itself;
#  expanding a variable asks for its children (by reference) the first
#  time. Everything the painters show is kept here as plain lists, rebuilt
#  only when a response changes it (`gen` counts the changes).
#
#    var c = LiveDebugClient()
#    c.set_breakpoints(path, [{"line": 5, "condition": "i > 2"}])
#    c.exc_filters = ["uncaught"]
#    c.start(port)              then c.poll() every frame
#    c.state                    idle | connecting | running | paused | ended
#    c.frames                   [[frame id, function, path, line]]
#    c.rows                     the Variables tree, flattened:
#                               [depth, name, value, ref, open, type, evaluateName, parent ref]
#    c.cont() c.pause() c.next() c.step_in() c.step_out() c.step_back()
#    c.reverse_continue() c.seek(step) c.evaluate(expr, context, tag)
#    c.set_variable(parent_ref, name, value) c.toggle(row) c.select_frame(i)
#    c.why_value(name) c.why_not(path, line) c.stop()
#
#  Tested by tools/ide_e2e.py's `live` scenario (the server itself by
#  examples/vm_audit101.ny).
# ══════════════════════════════════════════════════════════════════════════════


def dap_encode(msg):
    var body = json_encode(msg).encode("utf-8")
    return ("Content-Length: " + str(len(body)) + "\r\n\r\n").encode("ascii") + body


# [message or none, rest of the buffer]
def dap_take(buf):
    var end = buf.find(b"\r\n\r\n")
    if end < 0:
        return [none, buf]
    var n = -1
    for line in buf[:end].decode("ascii").split("\r\n"):
        if line.lower().startswith("content-length:"):
            n = int(string_strip(line[15:]))
    if n < 0:
        return [none, b""]
    var start = end + 4
    if len(buf) < start + n:
        return [none, buf]
    return [json_decode(buf[start:start + n].decode("utf-8")), buf[start + n:]]


def dap_free_port():
    var consts = {}
    for pair in _net_constants():
        consts[pair[0]] = pair[1]
    var h = _net_socket(consts["AF_INET"], consts["SOCK_STREAM"], 0)
    _net_bind(h, ("127.0.0.1", 0))
    var port = _net_getsockname(h)[1]
    _net_close(h)
    return port


class LiveDebugClient:
    def __init__(self):
        self.bp_files = {}          # path -> [{line, condition, hitCondition, logMessage}]
        self.exc_filters = ["uncaught"]
        self.reset()

    def reset(self):
        self.active = false
        self.state = "idle"
        self.h = none
        self.port = 0
        self.t0 = 0
        self.last_try = 0
        self.buf = b""
        self.seq = 0
        self.pending = {}           # seq -> [command, tag]
        self.caps = {}
        self.frames = []
        self.frame_sel = 0
        self.scopes = []            # [[name, ref]]
        self.kids = {}              # ref -> [[name, value, type, ref, evaluateName]]
        self.open = {}              # ref -> true
        self.rows = []
        self.reason = ""
        self.description = ""
        self.exc_text = ""
        self.exc_info = none
        self.history = none         # [step, of] while travelling in the history
        self.watch_vals = {}        # expression -> [text, ok]
        self.logs = []              # [text, kind] for the debug console
        self.exit_code = none
        self.why_title = ""
        self.why = none             # the last Why? answer's entries
        self.why_steps = 0
        self.gen = 0
        self.stops = 0
        self.path = ""
        self.line = 0
        self.watches = []
        self.verified = {}          # path -> [lines the server verified]
        self.pid = 0
        self.error = ""

    # ── connection ───────────────────────────────────────────────────────────
    def start(self, port):
        self.reset()
        self.port = port
        self.active = true
        self.state = "connecting"
        self.t0 = time_ms()
        self.gen = self.gen + 1

    def _try_connect(self):
        var consts = {}
        for pair in _net_constants():
            consts[pair[0]] = pair[1]
        var h = _net_socket(consts["AF_INET"], consts["SOCK_STREAM"], 0)
        _net_settimeout(h, 0.5)
        var rc = _net_connect_ex(h, ("127.0.0.1", self.port))
        if rc != 0:
            _net_close(h)
            return false
        _net_settimeout(h, none)
        self.h = h
        return true

    def connected(self):
        return self.h != none

    # Called every frame: connects (retrying while the program starts), reads
    # and handles every whole message that has arrived. True when anything
    # the painters show changed.
    def poll(self):
        if not self.active:
            return false
        var g = self.gen
        if self.h == none:
            if self.state != "connecting":
                return false
            var now = time_ms()
            if now - self.last_try < 100:
                return false
            self.last_try = now
            if self._try_connect():
                self.state = "running"
                self.request("initialize", {"clientID": "nythonide", "adapterID": "nython", "linesStartAt1": true,
                                            "columnsStartAt1": true, "pathFormat": "path", "supportsVariableType": true})
                self.request("launch", {"stopOnEntry": false})
                self.gen = self.gen + 1
            elif now - self.t0 > 20000:
                self.error = "could not connect to the debug server on port " + str(self.port)
                self._ended()
            return self.gen != g
        var guard = 0
        while guard < 64 and self.h != none and _net_wait(self.h, 1, 0) != 0:
            guard = guard + 1
            var data = none
            try:
                data = _net_recv(self.h, 65536, 0)
            except:
                data = b""
            if data == none or len(data) == 0:
                self._closed()
                break
            self.buf = self.buf + data
            while true:
                var r = dap_take(self.buf)
                self.buf = r[1]
                if r[0] == none:
                    break
                self._on_message(r[0])
        return self.gen != g

    def _closed(self):
        if self.h != none:
            try:
                _net_close(self.h)
            except:
                pass
        self.h = none
        self._ended()

    def _ended(self):
        if self.state != "ended":
            self.state = "ended"
            self.gen = self.gen + 1

    def stop(self):
        # disconnect: the server ends the program
        if self.h != none:
            self.request("disconnect", {"terminateDebuggee": true})
        self.active = false
        self.state = "idle"
        self.gen = self.gen + 1

    def close(self):
        if self.h != none:
            try:
                _net_close(self.h)
            except:
                pass
        self.h = none
        self.active = false
        self.state = "idle"

    def request(self, command, args, tag=""):
        if self.h == none:
            return -1
        self.seq = self.seq + 1
        self.pending[self.seq] = [command, tag]
        try:
            _net_sendall(self.h, dap_encode({"seq": self.seq, "type": "request", "command": command, "arguments": args}), 0)
        except:
            self._closed()
            return -1
        return self.seq

    # ── messages ─────────────────────────────────────────────────────────────
    def _on_message(self, m):
        var t = m.get("type", "")
        if t == "event":
            self._on_event(m.get("event", ""), m.get("body", {}))
        elif t == "response":
            var p = self.pending.get(m.get("request_seq", 0))
            if p != none:
                self.pending.remove(m["request_seq"])
            else:
                p = [m.get("command", ""), ""]
            if not m.get("success", false):
                var msg = m.get("message", "")
                if msg == "" or msg == none:
                    msg = p[0] + " failed"
                if p[1] != "" and string_startswith(p[1], "watch:"):
                    self.watch_vals[string_slice(p[1], 6, len(p[1]))] = [msg, false]
                elif p[0] != "disconnect":
                    self.logs.append([msg, "err"])
                self.gen = self.gen + 1
                return
            self._on_response(p[0], p[1], m.get("body", {}))
            self.gen = self.gen + 1

    def _on_event(self, ev, body):
        if body == none:
            body = {}
        if ev == "initialized":
            for path in self.bp_files.keys():
                self.request("setBreakpoints", {"source": {"path": path}, "breakpoints": self.bp_files[path]}, path)
            self.request("setExceptionBreakpoints", {"filters": self.exc_filters})
            self.request("configurationDone", {})
        elif ev == "process":
            self.pid = body.get("systemProcessId", 0)
        elif ev == "stopped":
            self.state = "paused"
            self.stops = self.stops + 1
            self.reason = body.get("reason", "")
            self.description = body.get("description", "")
            self.exc_text = body.get("text", "") if self.reason == "exception" else ""
            self.exc_info = none
            var h = body.get("nythonHistory")
            self.history = [h["step"], h["of"]] if h != none else none
            self.kids = {}
            self.scopes = []
            self.rows = []
            self.request("stackTrace", {"threadId": 1, "startFrame": 0, "levels": 200}, "stop")
            if self.reason == "exception":
                self.request("exceptionInfo", {"threadId": 1})
        elif ev == "continued":
            self.state = "running"
        elif ev == "output":
            var cat = body.get("category", "console")
            var text = body.get("output", "")
            var kind = "out"
            if cat == "stderr" or cat == "important":
                kind = "err"
            for ln in text.rstrip("\n").split("\n"):
                self.logs.append([ln, kind])
        elif ev == "exited":
            self.exit_code = body.get("exitCode", 0)
        elif ev == "terminated":
            self._closed()
        self.gen = self.gen + 1

    def _on_response(self, cmd, tag, body):
        if body == none:
            body = {}
        if cmd == "initialize":
            self.caps = body
        elif cmd == "setBreakpoints":
            var lines = []
            for b in body.get("breakpoints", []):
                if b.get("verified"):
                    lines.append(b.get("line", 0))
            self.verified[tag] = lines
        elif cmd == "stackTrace":
            var fr = []
            for f in body.get("stackFrames", []):
                fr.append([f["id"], f["name"], f.get("source", {}).get("path", ""), f.get("line", 0)])
            self.frames = fr
            self.select_frame(0)
        elif cmd == "scopes":
            var sc = []
            for s in body.get("scopes", []):
                sc.append([s["name"], s["variablesReference"]])
            self.scopes = sc
            self.open = {}
            if len(sc) > 0:
                self.open[sc[0][1]] = true
                self.request("variables", {"variablesReference": sc[0][1]}, str(sc[0][1]))
            self._rebuild()
            self.refresh_watches()
        elif cmd == "variables":
            var out = []
            for v in body.get("variables", []):
                out.append([v.get("name", ""), v.get("value", ""), v.get("type", ""), v.get("variablesReference", 0),
                            v.get("evaluateName", "")])
            self.kids[int(tag)] = out
            self._rebuild()
        elif cmd == "evaluate":
            var res = body.get("result", "")
            if string_startswith(tag, "watch:"):
                self.watch_vals[string_slice(tag, 6, len(tag))] = [res, true]
            elif tag == "repl":
                if res != "":
                    self.logs.append([res, "ok"])
        elif cmd == "setVariable":
            # the parent's children again (other values may follow from it)
            var pref = int(tag)
            self.request("variables", {"variablesReference": pref}, str(pref))
            self.refresh_watches()
        elif cmd == "exceptionInfo":
            self.exc_info = body
        elif cmd == "nython/whyValue" or cmd == "nython/whyNot":
            self.why = body.get("entries", [])
            self.why_steps = body.get("steps", 0)
            self.why_title = tag
        elif cmd == "continue" or cmd == "next" or cmd == "stepIn" or cmd == "stepOut":
            if self.state == "paused" and self.history == none:
                self.state = "running"

    # ── the Variables tree ───────────────────────────────────────────────────
    def _rebuild(self):
        var rows = []
        for s in self.scopes:
            var o = self.open.get(s[1]) != none
            rows.append([0, s[0], "", s[1], o, "scope", "", 0])
            if o:
                self._add_rows(rows, s[1], 1)
        self.rows = rows

    def _add_rows(self, rows, ref, depth):
        var ks = self.kids.get(ref)
        if ks == none:
            rows.append([depth, "...", "", 0, false, "loading", "", ref])
            return
        for k in ks:
            var o = k[3] != 0 and self.open.get(k[3]) != none
            rows.append([depth, k[0], k[1], k[3], o, k[2], k[4], ref])
            if o and depth < 12:
                self._add_rows(rows, k[3], depth + 1)

    # Expand or collapse row i (a scope or an expandable value).
    def toggle(self, i):
        if i < 0 or i >= len(self.rows):
            return
        var ref = self.rows[i][3]
        if ref == 0:
            return
        if self.open.get(ref) != none:
            self.open.remove(ref)
        else:
            self.open[ref] = true
            if self.kids.get(ref) == none:
                self.request("variables", {"variablesReference": ref}, str(ref))
        self._rebuild()
        self.gen = self.gen + 1

    # The value of a variable of the selected frame's first scope, by name.
    def value_of(self, name):
        if len(self.scopes) == 0:
            return none
        var ks = self.kids.get(self.scopes[0][1])
        if ks == none:
            return none
        for k in ks:
            if k[0] == name:
                return k[1]
        return none

    def row_of(self, name):
        var i = 0
        while i < len(self.rows):
            if self.rows[i][1] == name and self.rows[i][5] != "scope":
                return i
            i = i + 1
        return -1

    # ── commands ─────────────────────────────────────────────────────────────
    def select_frame(self, i):
        if i < 0 or i >= len(self.frames):
            return
        self.frame_sel = i
        self.path = self.frames[i][2]
        self.line = self.frames[i][3]
        self.kids = {}
        self.scopes = []
        self.rows = []
        self.request("scopes", {"frameId": self.frames[i][0]})
        self.gen = self.gen + 1

    def frame_id(self):
        if self.frame_sel < len(self.frames):
            return self.frames[self.frame_sel][0]
        return 1

    def _resume(self, cmd):
        if self.state != "paused":
            return
        self.request(cmd, {"threadId": 1})
        if self.history == none:
            self.state = "running"
        self.gen = self.gen + 1

    def cont(self):
        self._resume("continue")

    def next(self):
        self._resume("next")

    def step_in(self):
        self._resume("stepIn")

    def step_out(self):
        self._resume("stepOut")

    def step_back(self):
        if self.state == "paused":
            self.request("stepBack", {"threadId": 1})

    def reverse_continue(self):
        if self.state == "paused":
            self.request("reverseContinue", {"threadId": 1})

    def seek(self, step):
        if self.state == "paused":
            self.request("nython/seek", {"step": step})

    def pause(self):
        if self.state == "running" and self.h != none:
            self.request("pause", {"threadId": 1})

    def evaluate(self, expr, context, tag):
        if self.state != "paused":
            return -1
        return self.request("evaluate", {"expression": expr, "frameId": self.frame_id(), "context": context}, tag)

    def refresh_watches(self):
        for w in self.watches:
            self.evaluate(w, "watch", "watch:" + w)

    def set_variable(self, ref, name, value):
        if self.state != "paused":
            return
        self.request("setVariable", {"variablesReference": ref, "name": name, "value": value}, str(ref))

    def set_breakpoints(self, path, bps):
        self.bp_files[path] = bps
        if self.h != none:
            self.request("setBreakpoints", {"source": {"path": path}, "breakpoints": bps}, path)

    def set_exception_filters(self, filters):
        self.exc_filters = filters
        if self.h != none:
            self.request("setExceptionBreakpoints", {"filters": filters})

    def why_value(self, name):
        if self.state == "paused":
            self.request("nython/whyValue", {"name": name}, "Why is " + name + " = " + str(self.value_of(name)) + "?")

    def why_not(self, path, line):
        if self.state == "paused":
            self.request("nython/whyNot", {"path": path, "line": line}, "Why didn't line " + str(line) + " run?")
