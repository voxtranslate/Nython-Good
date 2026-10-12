# vm_audit101.ny - live debugging and profiling (round 81; Nython only).
#
# Part 1: lib/ide_debugserver.ny driven over its socket, as the IDE drives it:
# a program started with `nython --debug-port N prog.ny` (on the engine this
# test runs on), and a small Debug Adapter Protocol client written here -
# Content-Length framing, requests, responses and events. Checked:
# initialize's capabilities, breakpoints (moved to a statement, verified,
# conditions, hit counts, log messages), stopped events, stackTrace, scopes,
# variables and their children by reference, evaluate in a frame (and a
# statement in the debug console), setVariable on a module variable, a
# function's local (PEP 667 write-through) and an object's attribute, next /
# stepIn / stepOut, pause interrupting a running loop, raised and uncaught
# exception breakpoints with exceptionInfo, the exit code and the program's
# own output - and the ring buffer of recent statements: nython/history,
# stepBack / reverseContinue / seek through it and back to the present, and
# the Whyline questions (nython/whyValue, nython/whyNot) answered over it.
# Part 2: lib/ide_profile.ny reading real `nython -m cProfile -o` dumps -
# the table, callers/callees, and the flame graph from the calling context
# tree (--stacks) and derived from caller edges.
#
#     ./build/nython-cli examples/vm_audit101.ny
#     ./build/nython-cli --vm examples/vm_audit101.ny

import os
import sys
import socket
import subprocess
import tempfile
import time
import "lib/ide_profile.ny"

results = []

def check(name, got, want):
    var ok = repr(got) == repr(want)
    results.append([name, ok, repr(got), repr(want)])
    if not ok:
        # reported as it happens: a later step may depend on this one
        print("FAIL:", name)
        print("   got: ", repr(got))
        print("   want:", repr(want))

var exe = sys.executable
var engine = ["--vm"] if "--vm" in sys.orig_argv else []
var pid = os.getpid()
var tmpd = tempfile.gettempdir()

def tmp_file(tag, text):
    var p = os.path.realpath(os.path.join(tmpd, "ny_audit101_" + str(pid) + "_" + tag + ".ny"))
    write_file(p, text)
    return p

def free_port():
    var s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    var port = s.getsockname()[1]
    s.close()
    return port


# ── a DAP client ─────────────────────────────────────────────────────────────
class Dap:
    def __init__(self, prog, args=None, stdin_text=None):
        self.port = free_port()
        self.proc = subprocess.Popen([exe] + engine + ["--debug-port", str(self.port), prog] + (args or []),
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                     stdin=subprocess.PIPE if stdin_text is not None else None)
        if stdin_text is not None:
            self.proc.stdin.write(stdin_text)
            self.proc.stdin.close()
        self.sock = None
        var t0 = time.monotonic()
        while self.sock is None and time.monotonic() - t0 < 20:
            var s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if s.connect_ex(("127.0.0.1", self.port)) == 0:
                self.sock = s
            else:
                s.close()
                time.sleep(0.05)
        self.buf = b""
        self.seq = 0
        self.events = []
        self.out = ""
        self.err = ""
        self.code = None

    def send(self, cmd, args=None):
        self.seq = self.seq + 1
        var body = json_encode({"seq": self.seq, "type": "request", "command": cmd, "arguments": args or {}}).encode("utf-8")
        self.sock.sendall(("Content-Length: " + str(len(body)) + "\r\n\r\n").encode("ascii") + body)
        return self.seq

    def _read(self, timeout):
        var t0 = time.monotonic()
        while True:
            var end = self.buf.find(b"\r\n\r\n")
            if end >= 0:
                var n = int(self.buf[:end].decode("ascii").split(":")[1].strip())
                if len(self.buf) >= end + 4 + n:
                    var m = json_decode(self.buf[end + 4:end + 4 + n].decode("utf-8"))
                    self.buf = self.buf[end + 4 + n:]
                    return m
            var left = timeout - (time.monotonic() - t0)
            if left <= 0:
                return None
            self.sock.settimeout(left)
            try:
                var data = self.sock.recv(65536)
            except TimeoutError:
                return None
            if not data:
                return None
            self.buf = self.buf + data

    # the response to a request (events that arrive meanwhile are kept)
    def req(self, cmd, args=None, timeout=20):
        var s = self.send(cmd, args)
        while True:
            var m = self._read(timeout)
            if m is None:
                return {"success": False, "message": "timeout", "body": {}}
            if m["type"] == "event":
                self.events.append(m)
            elif m["type"] == "response" and m["request_seq"] == s:
                return m

    def event(self, name, timeout=20):
        var k = 0
        while k < len(self.events):
            if self.events[k]["event"] == name:
                var e = self.events.pop(k)
                return e.get("body", {})
            k = k + 1
        while True:
            var m = self._read(timeout)
            if m is None:
                return None
            if m["type"] == "event":
                if m["event"] == name:
                    return m.get("body", {})
                self.events.append(m)

    def outputs(self):
        # the output events seen so far, as text
        var o = []
        var rest = []
        for e in self.events:
            if e["event"] == "output":
                o.append(e["body"]["output"])
            else:
                rest.append(e)
        self.events = rest
        return o

    def stack(self):
        var r = self.req("stackTrace", {"threadId": 1})
        return [[f["name"], f["line"], os.path.basename(f["source"]["path"])] for f in r["body"].get("stackFrames", [])]

    def frame_ids(self):
        var r = self.req("stackTrace", {"threadId": 1})
        return [f["id"] for f in r["body"].get("stackFrames", [])]

    def scopes(self, frame_id=None):
        var a = {} if frame_id is None else {"frameId": frame_id}
        return self.req("scopes", a)["body"].get("scopes", [])

    def vars(self, ref):
        var r = self.req("variables", {"variablesReference": ref})
        var d = {}
        for v in r["body"].get("variables", []):
            d[v["name"]] = v
        return d

    def locals(self, frame_id=None):
        var sc = self.scopes(frame_id)
        if not sc:
            return {}
        return self.vars(sc[0]["variablesReference"])

    def values(self, frame_id=None):
        var d = self.locals(frame_id)
        var out = {}
        for k in d:
            out[k] = d[k]["value"]
        return out

    def ev(self, expr, frame_id=None, context="watch"):
        var a = {"expression": expr, "context": context}
        if frame_id is not None:
            a["frameId"] = frame_id
        var r = self.req("evaluate", a)
        if not r["success"]:
            return "error: " + r.get("message", "")
        return r["body"]["result"]

    def finish(self):
        var e = self.event("exited", 20)
        self.code = e["exitCode"] if e is not None else None
        self.event("terminated", 5)
        try:
            self.req("disconnect", {}, 2)
        except BaseException:
            pass
        try:
            self.sock.close()
        except BaseException:
            pass
        var oe = self.proc.communicate(timeout=30)
        self.out = oe[0]
        self.err = oe[1]
        return self.code

    def start(self, breaks=None, filters=None, stop_on_entry=False):
        var r = self.req("initialize", {"clientID": "audit101", "adapterID": "nython", "linesStartAt1": True})
        self.caps = r["body"]
        self.req("launch", {"stopOnEntry": stop_on_entry})
        self.event("initialized")
        self.bp = {}
        if breaks is not None:
            for path, bl in breaks.items():
                self.bp[path] = self.req("setBreakpoints", {"source": {"path": path}, "breakpoints": bl})["body"]["breakpoints"]
        self.req("setExceptionBreakpoints", {"filters": filters if filters is not None else []})
        return self.req("configurationDone")


# ── 1. breakpoints, stepping, variables, evaluate, setVariable ──────────────
var PROG1 = """def fact(n):
    if n <= 1:
        return 1
    r = n * fact(n - 1)
    return r

data = [1, 2, 3]
info = {"name": "x", "k": data}
total = 0
for i in range(4):
    total = total + i
print("total", total)
f = fact(4)
print("fact", f)
class P:
    def __init__(self):
        self.a = 1
        self.b = [5, 6]
p = P()
print("p.a", p.a)
print("done")
"""
var p1 = tmp_file("p1", PROG1)
var d = Dap(p1)
check("the client connected to the debug server", d.sock is not None, True)
var done = d.start({p1: [{"line": 6}, {"line": 11, "condition": "i == 2"}, {"line": 4, "hitCondition": "2"},
                         {"line": 20}, {"line": 21, "logMessage": "p.a is {p.a}, {len(p.b)} items"}, {"line": 99}]})
check("initialize: the capabilities", [d.caps.get("supportsStepBack"), d.caps.get("supportsSetVariable"),
      d.caps.get("supportsConditionalBreakpoints"), d.caps.get("supportsHitConditionalBreakpoints"),
      d.caps.get("supportsLogPoints"), d.caps.get("supportsExceptionInfoRequest"),
      [f["filter"] for f in d.caps.get("exceptionBreakpointFilters", [])]],
      [True, True, True, True, True, True, ["raised", "uncaught"]])
var bps = d.bp[p1]
check("setBreakpoints: a blank line moves to the next statement", [bps[0]["verified"], bps[0]["line"]], [True, 7])
check("setBreakpoints: the others verified where asked", [[b["verified"], b["line"]] for b in bps[1:5]],
      [[True, 11], [True, 4], [True, 20], [True, 21]])
check("setBreakpoints: a line past the end is not verified", [bps[5]["verified"], "not a statement" in bps[5].get("message", "")], [False, True])
check("configurationDone answered", done["success"], True)
var st = d.event("stopped")
check("stopped at the first breakpoint", [st["reason"], st["threadId"], st.get("hitBreakpointIds") == [bps[0]["id"]]], ["breakpoint", 1, True])
check("stackTrace at module level", d.stack(), [["<module>", 7, os.path.basename(p1)]])
var sc = d.scopes()
check("scopes at module level: one Locals scope", [s["name"] for s in sc], ["Locals"])
check("nothing assigned yet at line 7", "data" in d.locals(), False)
d.req("continue", {"threadId": 1})
st = d.event("stopped")
check("a conditional breakpoint stops when it holds", [st["reason"], d.stack()[0][1]], ["breakpoint", 11])
var lv = d.values()
check("the loop's variables", [lv["i"], lv["total"], lv["data"]], ["2", "1", "[1, 2, 3]"])
check("a function is not listed among module variables", "fact" in lv, False)
var dv = d.locals()["data"]
check("a list is expandable, with its length", [dv["variablesReference"] > 0, dv.get("indexedVariables"), dv["type"]], [True, 3, "list"])
var kids = d.vars(dv["variablesReference"])
check("a list's children by reference", [[k, kids[k]["value"], kids[k]["evaluateName"]] for k in ["0", "1", "2"]],
      [["0", "1", "data[0]"], ["1", "2", "data[1]"], ["2", "3", "data[2]"]])
var iv = d.vars(d.locals()["info"]["variablesReference"])
check("a dict's children: keys as reprs, a nested list expandable", [sorted(iv.keys()), iv["'name'"]["value"], iv["'k'"]["variablesReference"] > 0],
      [["'k'", "'name'"], "'x'", True])
check("evaluate an expression in the frame", d.ev("total + i * 10"), "21")
check("evaluate: an error is a failed response", "NameError" in d.ev("nosuch + 1"), True)
var loc_ref = sc[0]["variablesReference"]
sc = d.scopes()
var sv = d.req("setVariable", {"variablesReference": sc[0]["variablesReference"], "name": "total", "value": "1000"})
check("setVariable on a module variable", [sv["success"], sv["body"]["value"]], [True, "1000"])
check("the new value is what the frame reads", d.ev("total"), "1000")
check("a statement in the debug console binds in the frame", [d.ev("q = 7", None, "repl"), d.ev("q * 2")], ["", "14"])
d.req("continue", {"threadId": 1})
st = d.event("stopped")
check("a hit count: the second time line 4 runs", [st["reason"], d.stack()], ["breakpoint",
      [["fact", 4, os.path.basename(p1)], ["fact", 4, os.path.basename(p1)], ["<module>", 13, os.path.basename(p1)]]])
var fids = d.frame_ids()
check("each frame's own locals", [d.values(fids[0])["n"], d.values(fids[1])["n"]], ["3", "4"])
check("scopes in a function: Locals and Globals", [s["name"] for s in d.scopes(fids[0])], ["Locals", "Globals"])
var gl = d.vars(d.scopes(fids[0])[1]["variablesReference"])
check("the Globals scope holds the module's data", [gl["total"]["value"], "fact" in gl], ["1005", False])
check("evaluate in a caller's frame", d.ev("n * 100", fids[1]), "400")
sv = d.req("setVariable", {"variablesReference": d.scopes(fids[0])[0]["variablesReference"], "name": "n", "value": "5"})
check("setVariable on a function's local (PEP 667 write-through)", [sv["success"], d.values(fids[0])["n"]], [True, "5"])
d.req("stepIn", {"threadId": 1})
st = d.event("stopped")
check("stepIn enters the call with the new argument", [st["reason"], d.stack()[0], d.values()["n"]], ["step", ["fact", 2, os.path.basename(p1)], "4"])
d.req("stepOut", {"threadId": 1})
st = d.event("stopped")
check("stepOut returns to the caller's next line", [st["reason"], d.stack()[0][:2], d.values()["r"]], ["step", ["fact", 5], "120"])
d.req("next", {"threadId": 1})
st = d.event("stopped")
check("next at a return goes on in the caller", [d.stack()[0][:2], len(d.stack()), d.values()["r"]], [["fact", 5], 2, "480"])
d.req("next", {"threadId": 1})
d.event("stopped")
check("next out of the call: the module's next line", d.stack()[0][:2], ["<module>", 14])
d.req("next", {"threadId": 1})
d.event("stopped")
check("next steps over in the module", d.stack()[0][:2], ["<module>", 15])
d.req("continue", {"threadId": 1})
st = d.event("stopped")
check("the breakpoint at line 20", [st["reason"], d.stack()[0][1]], ["breakpoint", 20])
var pv = d.locals()["p"]
check("an object is expandable", [pv["variablesReference"] > 0, pv["type"]], [True, "P"])
var pk = d.vars(pv["variablesReference"])
check("an object's attributes", [sorted(pk.keys()), pk["a"]["value"], pk["b"]["value"], pk["b"]["evaluateName"]],
      [["a", "b"], "1", "[5, 6]", "p.b"])
var bk = d.vars(pk["b"]["variablesReference"])
check("nested children by reference", [bk["0"]["value"], bk["1"]["value"]], ["5", "6"])
sv = d.req("setVariable", {"variablesReference": pv["variablesReference"], "name": "a", "value": "6 * 7"})
check("setVariable on an attribute", [sv["success"], sv["body"]["value"], d.ev("p.a")], [True, "42", "42"])
sv = d.req("setVariable", {"variablesReference": pk["b"]["variablesReference"], "name": "1", "value": "60"})
check("setVariable on a list item", [sv["success"], d.ev("p.b")], [True, "[5, 60]"])
check("stackTrace paging", [len(d.req("stackTrace", {"threadId": 1, "startFrame": 0, "levels": 1})["body"]["stackFrames"]),
      d.req("stackTrace", {"threadId": 1})["body"]["totalFrames"]], [1, 1])
d.req("continue", {"threadId": 1})
check("the program ran to its end", d.finish(), 0)
check("a log point prints and does not stop", "p.a is 42, 2 items\n" in d.outputs(), True)
check("the program's own output, with the values set while paused", d.out.split("\n"),
      ["total 1005", "fact 480", "p.a 42", "done", ""])
check("no stop was left unconsumed", len([e for e in d.events if e["event"] == "stopped"]), 0)

# ── 2. pause, the history (ring buffer), step back, Why? ─────────────────────
var PROG2 = """stop = False
n = 0
k = 0
while not stop:
    n = n + 1
    if n % 3 == 0:
        k = k + n
print("stopped", n > 0, k >= 0)
"""
var p2 = tmp_file("p2", PROG2)
d = Dap(p2)
d.start({}, [])
time.sleep(0.4)
var pr = d.req("pause", {"threadId": 1})
st = d.event("stopped")
check("pause interrupts a running loop", [pr["success"], st["reason"], d.stack()[0][1] in [4, 5, 6, 7]], [True, "pause", True])
var nv = int(d.ev("n"))
check("the loop had run", nv > 3, True)
var h = d.req("nython/history")["body"]
check("the history: the last 2000 statements, oldest first", [h["capacity"], len(h["lines"]) == min(2000, h["total"]),
      h["lines"][-1].startswith("{\"f\":"), h["step"] == len(h["lines"]) - 1], [2000, True, True, True])
var line_now = d.stack()[0][1]
d.req("stepBack", {"threadId": 1})
st = d.event("stopped")
var back = d.stack()
check("stepBack: a step of the history", [st["reason"], "history step" in st.get("description", ""),
      st.get("nythonHistory", {}).get("step") == h["step"] - 1], ["step", True, True])
check("stepBack: the line before", back[0][1] != line_now or line_now == 4, True)
var bv = d.values()
check("stepBack: the recorded variables", ["n" in bv, "stop" in bv, bv.get("stop")], [True, True, repr(False)])
check("evaluate at a history step: a recorded name", d.ev("stop"), repr(False))
check("evaluate at a history step: nothing else", "only the recorded" in d.ev("n + 1"), True)
check("setVariable at a history step is refused",
      d.req("setVariable", {"variablesReference": d.scopes()[0]["variablesReference"], "name": "n", "value": "1"})["success"], False)
d.req("stepBack", {"threadId": 1})
d.event("stopped")
d.req("stepBack", {"threadId": 1})
d.event("stopped")
d.req("next", {"threadId": 1})
st = d.event("stopped")
check("next in the past moves forward in the history", "history step" in st.get("description", ""), True)
d.req("nython/seek", {"step": -1})
st = d.event("stopped")
check("seek -1: back to the present", [st.get("description"), d.stack()[0][1], int(d.ev("n")) == nv], ["the present", line_now, True])
var wv = d.req("nython/whyValue", {"name": "k"})["body"]["entries"]
check("whyValue over the live history: the question and its value", [wv[0]["kind"], wv[0]["value"] == d.ev("k")], ["value", True])
var kinds = [[e["kind"], e["line"]] for e in wv]
check("whyValue: the write, under its test", [["data", 7] in kinds, ["control", 6] in kinds], [True, True])
var wn = d.req("nython/whyNot", {"path": p2, "line": 8})["body"]["entries"]
check("whyNot: still in the loop - the last statement before line 8", [wn[0]["kind"], wn[1]["kind"], wn[1]["line"] in [4, 5, 6, 7]],
      ["question", "exit", True])
check("whyNot: a line that did run", d.req("nython/whyNot", {"path": p2, "line": 5})["body"]["entries"][0]["text"].startswith("line 5 did run"), True)
var sc2 = d.scopes()
d.req("setVariable", {"variablesReference": sc2[0]["variablesReference"], "name": "stop", "value": "True"})
d.req("continue", {"threadId": 1})
check("setting the loop's flag ends it", d.finish(), 0)
check("the loop's program printed its line", d.out, "stopped " + str(True) + " " + str(True) + "\n")

# reverseContinue to an earlier breakpoint hit, then forward to the present
var PROG3 = """def pick(xs, lim):
    best = 0
    for x in xs:
        if x > lim:
            best = best + x
    if best > 100:
        print("huge")
    return best

r = pick([3, 8, 1, 12], 5)
print("r", r)
"""
var p3 = tmp_file("p3", PROG3)
d = Dap(p3)
d.start({p3: [{"line": 8}]})
d.event("stopped")
check("stopped at return best", [d.stack()[0][:2], d.values()["best"]], [["pick", 8], "20"])
wv = d.req("nython/whyValue", {"name": "best"})["body"]["entries"]
check("why is best 20: the last write and its value", [wv[1]["kind"], wv[1]["line"], wv[1]["value"]], ["data", 5, "20"])
check("why is best 20: the test it ran under, the call that passed the data",
      [len([e for e in wv if e["kind"] == "control" and e["line"] == 4]) > 0, len([e for e in wv if e["kind"] == "call" and e["line"] == 10]) > 0],
      [True, True])
check("why is best 20: lines that did not matter are left out", 7 in [e["line"] for e in wv], False)
wn = d.req("nython/whyNot", {"path": p3, "line": 7})["body"]["entries"]
check("why didn't print(\"huge\") run: the test, with its value", [wn[1]["kind"], wn[1]["line"], "(last: best = 20)" in wn[1]["text"]],
      ["predicate", 6, True])
d.req("setBreakpoints", {"source": {"path": p3}, "breakpoints": [{"line": 5}, {"line": 8}]})
d.req("reverseContinue", {"threadId": 1})
st = d.event("stopped")
check("reverseContinue: back to the last hit of a breakpoint", [d.stack()[0][:2], d.values()["best"], d.values()["x"]], [["pick", 5], "8", "12"])
d.req("reverseContinue", {"threadId": 1})
d.event("stopped")
check("reverseContinue again: the hit before", [d.stack()[0][1], d.values()["best"], d.values()["x"]], [5, "0", "8"])
check("the history's stack is rebuilt from depths", [f[0] for f in d.stack()], ["pick", "<module>"])
d.req("continue", {"threadId": 1})
st = d.event("stopped")
check("continue in the past: the next breakpoint of the history", [st["reason"], d.stack()[0][1], d.values()["x"]], ["breakpoint", 5, "12"])
d.req("continue", {"threadId": 1})
st = d.event("stopped")
check("continue again: the present, itself a breakpoint", [st["reason"], st.get("description"), d.stack()[0][:2]], ["breakpoint", "the present", ["pick", 8]])
d.req("continue", {"threadId": 1})
check("continue from the present goes live to the end", d.finish(), 0)
check("its output", d.out, "r 20\n")

# ── 3. exceptions ────────────────────────────────────────────────────────────
var PROG4 = """def risky(x):
    if x > 2:
        raise ValueError("too big: " + str(x))
    return x

try:
    risky(5)
except ValueError:
    print("caught")
for j in range(3):
    risky(j)
risky(9)
print("never")
"""
var p4 = tmp_file("p4", PROG4)
d = Dap(p4)
d.start({}, ["raised", "uncaught"])
st = d.event("stopped")
check("raised: stops where it is raised", [st["reason"], st.get("text"), d.stack()[0][:2]],
      ["exception", "ValueError: too big: 5", ["risky", 3]])
var ei = d.req("exceptionInfo", {"threadId": 1})["body"]
check("exceptionInfo", [ei["exceptionId"], ei["description"], ei["breakMode"], "too big: 5" in ei["details"]["stackTrace"]],
      ["ValueError", "too big: 5", "always", True])
d.req("continue", {"threadId": 1})
st = d.event("stopped")
check("raised: once per exception, not again in each frame it leaves", [d.stack()[0][:2], d.values()["x"]], [["risky", 3], "9"])
d.req("continue", {"threadId": 1})
st = d.event("stopped")
check("uncaught: a stop after it left the program", [st["reason"], st.get("description")], ["exception", "Uncaught exception: ValueError"])
ei = d.req("exceptionInfo", {"threadId": 1})["body"]
check("uncaught: exceptionInfo says unhandled", [ei["breakMode"], ei["description"]], ["unhandled", "too big: 9"])
var fs = d.stack()
check("uncaught: the stack where it was raised", [[f[0], f[1]] for f in fs], [["risky", 3], ["<module>", 12]])
check("uncaught: the frames' last values", [d.ev("x", d.frame_ids()[0]), d.ev("j", d.frame_ids()[1])], ["9", "2"])
d.req("continue", {"threadId": 1})
check("uncaught: exit status 1", d.finish(), 1)
check("uncaught: Python's report on stderr", ["Traceback (most recent call last):" in d.err, "ValueError: too big: 9" in d.err], [True, True])
check("uncaught: the output before it", d.out, "caught\n")

# only uncaught: the caught one passes
d = Dap(p4)
d.start({}, ["uncaught"])
st = d.event("stopped")
check("uncaught only: the first stop is the uncaught one", [st.get("description"), d.stack()[0][1]], ["Uncaught exception: ValueError", 3])
d.req("disconnect", {"terminateDebuggee": True})
d.finish()
check("disconnect ends the program", d.out, "caught\n")

# stop on entry, and stepping into a function of another file
var lib_p = tmp_file("helper", "def twice(v):\n    w = v * 2\n    return w\n")
var PROG5 = "import sys\nsys.path.insert(0, " + repr(os.path.dirname(lib_p)) + ")\nimport ny_audit101_" + str(pid) + "_helper as hp\nv = hp.twice(21)\nprint(v)\n"
var p5 = tmp_file("p5", PROG5)
d = Dap(p5)
d.start({lib_p: [{"line": 2}]}, [], True)
st = d.event("stopped")
check("stopOnEntry: the first line", [st["reason"], d.stack()[0][1]], ["entry", 1])
d.req("continue", {"threadId": 1})
st = d.event("stopped")
check("a breakpoint in an imported module", [st["reason"], d.stack()[0], d.values()["v"]],
      ["breakpoint", ["twice", 2, os.path.basename(lib_p)], "21"])
d.req("next", {"threadId": 1})
d.event("stopped")
check("next in the module's function", d.stack()[0][:2], ["twice", 3])
d.req("next", {"threadId": 1})
d.event("stopped")
check("next out of the module's function, back in the program", d.stack()[0][:2], ["<module>", 5])
d.req("continue", {"threadId": 1})
check("its result", [d.finish(), d.out], [0, "42\n"])

# the program's own stdin and argv are its own: the protocol has a socket
var p7 = tmp_file("p7", "import sys\nname = input(\"Name? \")\nprint(\"hi\", name, sys.argv[1:])\n")
d = Dap(p7, ["a1", "b2"], "ada\n")
d.start({p7: [{"line": 3}]})
st = d.event("stopped")
check("a breakpoint after input()", [st["reason"], d.values()["name"]], ["breakpoint", "'ada'"])
d.req("continue", {"threadId": 1})
check("stdin, stdout and sys.argv under the debug server", [d.finish(), d.out], [0, "Name? hi ada ['a1', 'b2']\n"])

# ── 4. the profile view's reader ─────────────────────────────────────────────
var PROG6 = """def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

def work():
    s = 0
    for i in range(30):
        s = s + len(str(i))
    return s

print(fib(10), work())
"""
var p6 = tmp_file("p6", PROG6)
var out6 = os.path.join(tmpd, "ny_audit101_" + str(pid) + ".prof")
var r6 = subprocess.run([exe] + engine + ["-m", "cProfile", "--stacks", "-o", out6, p6], capture_output=True, text=True)
check("nython -m cProfile --stacks -o OUT ran", [r6.returncode, r6.stdout], [0, "55 50\n"])
var pd = ProfileData()
check("the dump loads", [pd.load(out6), pd.error], [True, ""])
var fi = pd.find("fib")
var ff = pd.funcs[fi]
check("fib's calls: total/primitive", [ff.s_calls, ff.nc, ff.cc], ["177/1", 177, 1])
check("fib's location and pstats label", [ff.line, ff.label.endswith(":1(fib)"), ff.short.startswith("fib  (")], [1, True, True])
var wi = pd.find("work")
check("work's builtins counted", [pd.funcs[pd.find("<built-in method builtins.len>")].nc, pd.funcs[wi].nc], [30, 1])
check("times are consistent", [ff.ct >= ff.tt, ff.tt >= 0.0, pd.total_tt > 0.0], [True, True, True])
check("the summary line", pd.summary.endswith(" seconds") and "function calls" in pd.summary, True)
var mi = pd.find("<module>")
check("callers of fib: itself and the module", sorted([pd.funcs[c[0]].name for c in pd.callers_of(fi)]), ["<module>", "fib"])
check("callees of the module", sorted([pd.funcs[c[0]].name for c in pd.callees_of(mi)]),
      sorted(["fib", "work", "<built-in method builtins.print>"]))
check("callees of work (calling a type makes no c_call, as in CPython)", [pd.funcs[c[0]].name for c in pd.callees_of(wi)], ["<built-in method builtins.len>"])
check("the call count on an edge", [c[1] for c in pd.callees_of(wi) if pd.funcs[c[0]].name == "<built-in method builtins.len>"], [30])
pd.sort("tottime")
var tts = [pd.funcs[i].tt for i in pd.order]
check("sort by tottime: descending", tts == sorted(tts, reverse=True), True)
pd.sort("tottime")
tts = [pd.funcs[i].tt for i in pd.order]
check("the same column again: ascending", tts == sorted(tts), True)
pd.sort("name")
var labels = [pd.funcs[i].label for i in pd.order]
check("sort by name", labels == sorted(labels), True)
pd.sort("ncalls")
check("sort by calls: fib first", pd.funcs[pd.order[0]].name, "fib")
check("the flame graph is exact (calling context tree)", pd.flame_exact, True)
def inside_all(flame):
    # every bar lies within a bar one level up
    for b in flame:
        if b[2] == 0:
            continue
        var ok = False
        for a in flame:
            if a[2] == b[2] - 1 and a[0] <= b[0] + 1e-9 and b[1] <= a[1] + 1e-9:
                ok = True
        if not ok:
            return False
    return True
check("flame: every bar under its caller", inside_all(pd.flame), True)
var fib_bars = [b for b in pd.flame if pd.funcs[b[3]].name == "fib"]
check("flame: fib's recursion is a tower of real paths", [len(fib_bars) > 5, max([b[2] for b in fib_bars]) - min([b[2] for b in fib_bars]) >= 5], [True, True])
var top_fib = [b for b in fib_bars if b[2] == min([x[2] for x in fib_bars])]
check("flame: the outermost fib bar holds one call and fib's whole time", [len(top_fib), top_fib[0][5], abs(top_fib[0][4] - ff.ct) < 0.01 + ff.ct * 0.05],
      [1, 1, True])
check("flame: tooltips per bar", [len(pd.flame_tips) == len(pd.flame), "fib  (" in pd.flame_tips[pd.flame.index(top_fib[0])]], [True, True])
var fold = pd.folded()
check("folded stacks (flamegraph.pl's input)", [len([l for l in fold if ";fib;fib;fib " in l]) > 0, all([l.split(" ")[-1].isdigit() for l in fold])], [True, True])
check("flame_at finds a bar", pd.flame_at((top_fib[0][0] + top_fib[0][1]) / 2, top_fib[0][2]) == pd.flame.index(top_fib[0]), True)
import pstats
var ps = pstats.Stats(out6)
check("pstats still reads a dump with the tree", ps.total_calls, pd.total_calls)

var r7 = subprocess.run([exe] + engine + ["-m", "cProfile", "-o", out6, p6], capture_output=True, text=True)
var pd2 = ProfileData()
pd2.load(out6)
check("without --stacks: the graph derived from caller edges", [r7.returncode, pd2.flame_exact, len(pd2.flame) > 3], [0, False, True])
check("derived: every bar under its caller", inside_all(pd2.flame), True)
var dfib = [b for b in pd2.flame if pd2.funcs[b[3]].name == "fib"]
check("derived: recursion folds into the call on the path", len(dfib), 1)
check("a file that is not a dump", [ProfileData().load(p6), ProfileData().load(p6 + ".missing")], [False, False])
os.remove(out6)

for pth in [p1, p2, p3, p4, p5, p6, p7, lib_p]:
    os.remove(pth)

# ── report ───────────────────────────────────────────────────────────────────
var npass = 0
var nfail = 0
for r in results:
    if r[1]:
        npass = npass + 1
    else:
        nfail = nfail + 1
print("Results: " + str(npass) + " passed, " + str(nfail) + " failed")
if nfail == 0:
    print("=== VM_AUDIT101 PASSED ===")
