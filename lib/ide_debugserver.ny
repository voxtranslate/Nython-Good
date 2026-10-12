# nython: module    (import it by name: it runs in a module scope of its own)
# lib/ide_debugserver.ny - live debugging: a debug server inside the running
# program, over bdb.Bdb and sys.settrace, speaking a small JSON protocol
# modelled on Microsoft's Debug Adapter Protocol (round 81).
#
#     nython --debug-port 5678 prog.ny args ...     listen on 127.0.0.1:5678,
#     nython --vm --debug-port 5678 prog.ny            wait for the client, run
#     nython -m ide_debugserver [--host H] [--port N] [--ring N] [--no-ring]
#                               [--connect H:P] prog.ny args ...
#
# --port 0 picks a free port and prints "debug server listening on H:P" to
# stderr. --connect makes the server connect to a client that listens (the
# reverse of --port, as debugpy's --connect). The program's own stdin,
# stdout and stderr are left alone (the IDE's Run panel and its input line
# keep working); the protocol has its own socket.
#
# Wire format (DAP's): each message is "Content-Length: N\r\n\r\n" and N
# bytes of UTF-8 JSON, {"seq", "type": "request"|"response"|"event", ...}.
#
# Requests (DAP's names and shapes):
#   initialize -> capabilities (+ "initialized" and "process" events);
#   launch / attach (stopOnEntry); setBreakpoints {source: {path}, breakpoints:
#   [{line, condition, hitCondition, logMessage}]} (each moved to the next
#   statement and verified with text_defuse; hit conditions "5", "==5", ">5",
#   ">=5", "<5", "<=5", "%5"; a log message's {expr} parts are evaluated in
#   the frame and sent as an "output" event, it never stops);
#   setExceptionBreakpoints {filters: ["raised", "uncaught"]};
#   configurationDone (the program starts); threads; continue; next; stepIn;
#   stepOut; pause (a running loop stops at its next line: the trace function
#   tests one flag the socket thread sets); stackTrace {threadId, startFrame,
#   levels}; scopes {frameId} (Locals, Globals); variables
#   {variablesReference, start, count} (children made lazily: a list, tuple,
#   dict, set or object gets a reference that lists its items when asked);
#   evaluate {expression, frameId, context} (an expression in the frame; in
#   the "repl" context a statement too, whose bindings reach the frame -
#   PEP 667's write-through f_locals); setVariable {variablesReference, name,
#   value} (a local through f_locals, an item, a key or an attribute);
#   exceptionInfo; stepBack and reverseContinue (below); source;
#   disconnect / terminate.
# Events: initialized, process, stopped {reason: entry | breakpoint | step |
#   pause | exception, hitBreakpointIds, description, text}, continued,
#   output {category: console | important | stderr}, exited {exitCode},
#   terminated.
#
# Step back - back-in-time debugging of a live program (the innovation).
# The trace function keeps the last N statements it saw (2000 by default,
# --ring N) in a ring buffer: per statement its file, line, call depth,
# function and a short rendering of that frame's variables - the events
# `nython --trace` writes, in its JSON-lines form - so while paused,
# stepBack / reverseContinue / next / stepIn / stepOut travel through that
# recent history (lib/ide_debugger.ny's DebugSession replays it), and the
# Whyline questions of round 79 (dynamic backward slicing) are answered over
# it about the live program, without recording the whole run:
#   nython/history {}            the ring as --trace lines (oldest first)
#   nython/whyValue {name, step}  why does `name` have its value (now, or at
#                                 a history step)
#   nython/whyNot {path, line}    why didn't `line` run (within the history)
#   nython/seek {step}            travel to a history step (-1: the present)
# After omniscient debugging (Lewis, "Debugging Backwards in Time",
# AADEBUG 2003) and the Trace-Oriented Debugger (Pothier, Tanter & Piquer,
# "Scalable Omniscient Debugging", OOPSLA 2007). What is approximated: only
# the last N statements are kept (a question whose answer lies further back
# says the variable "was not set by a recorded statement"); values are
# recorded as short renderings (8 items of a list, 6 of a dict, an object's
# class name), so a change deep inside a structure is not seen; the
# history's frames are rebuilt from depths, and nothing there can be
# changed or evaluated beyond a recorded variable's rendering. Travelling
# forward again reaches the present, where the live program waits.
# Cost: measured on a loop in examples/vm_audit101.ny's notes and HANDOFF.
#
# DebugServer(ring=2000) is the server; serve(path, args, host, port,
# connect) runs a program under it and returns its exit status; main() is
# the command line. Only the main thread is debugged (other threads run
# untraced); frames in the library (lib/, the prelude) are stepped over
# (VS Code's "just my code"). Not here: DAP's attach to a running process,
# goto/restartFrame (Nython's frames cannot jump), data breakpoints,
# function breakpoints, completions, modules/loadedSources requests,
# variable paging beyond start/count, stepping granularity, multiple
# threads; pause takes effect at the next line a user frame runs (not
# inside a long native call such as time.sleep).

import sys
import os
import bdb
import threading
import queue
import socket
import time

__all__ = ["DebugServer", "main", "RING_SIZE", "encode_message", "take_message"]

RING_SIZE = 2000
_LIBDIR = os.path.dirname(os.path.realpath(__file__))
_SKIP_EXC = {"StopIteration": True, "StopAsyncIteration": True, "GeneratorExit": True, "SystemExit": True}
# requests the socket thread answers itself; the others go to the program's
# thread, which answers them while paused
_IMMEDIATE = {"initialize": True, "launch": True, "attach": True, "setBreakpoints": True,
              "setExceptionBreakpoints": True, "configurationDone": True, "threads": True,
              "pause": True, "disconnect": True, "terminate": True, "nython/ping": True}
_RESUME = {"continue": True, "next": True, "stepIn": True, "stepOut": True, "stepBack": True,
           "reverseContinue": True, "nython/seek": True}


def encode_message(msg):
    """One DAP message as bytes: the Content-Length header and the JSON body."""
    body = json_encode(msg).encode("utf-8")
    return ("Content-Length: " + str(len(body)) + "\r\n\r\n").encode("ascii") + body


def take_message(buf):
    """(message, rest) from the front of buf, or (None, buf) when it is not
    all there yet."""
    end = buf.find(b"\r\n\r\n")
    if end < 0:
        return None, buf
    n = -1
    for line in buf[:end].decode("ascii").split("\r\n"):
        if line.lower().startswith("content-length:"):
            n = int(line[15:].strip())
    if n < 0:
        raise ValueError("a message without Content-Length")
    start = end + 4
    if len(buf) < start + n:
        return None, buf
    return json_decode(buf[start:start + n].decode("utf-8")), buf[start + n:]


def _hit_ok(n, spec):
    s = spec.strip()
    for op in (">=", "<=", "==", ">", "<", "%"):
        if s.startswith(op):
            try:
                k = int(s[len(op):].strip())
            except ValueError:
                return True
            if op == ">=":
                return n >= k
            if op == "<=":
                return n <= k
            if op == "==":
                return n == k
            if op == ">":
                return n > k
            if op == "<":
                return n < k
            return k > 0 and n % k == 0
    try:
        return n == int(s)
    except ValueError:
        return True


class _BP:
    def __init__(self, id, line, cond, hit, log):
        self.id = id
        self.line = line
        self.cond = cond
        self.hit = hit
        self.log = log
        self.hits = 0


def _short(s, n):
    if len(s) > n:
        return s[:n - 3] + "..."
    return s


def _safe_repr(v, n=300):
    try:
        return _short(repr(v), n)
    except BaseException as e:
        return "<repr failed: " + type(e).__name__ + ">"


def _type_name(v):
    try:
        return type(v).__name__
    except BaseException:
        return "object"


class DebugServer(bdb.Bdb):
    def __init__(self, ring=RING_SIZE):
        bdb.Bdb.__init__(self)
        self.conn = None
        self._send_lock = threading.Lock()
        self._seq = 0
        self._q = queue.Queue()
        self._configured = threading.Event()
        self._attn = False          # set by the socket thread: look at the queue
        self._pause_req = False
        self._quit_req = False
        self._detached = False
        self.state = "init"         # init | running | paused | ended
        self.stop_on_entry = False
        self.exc_raised = False
        self.exc_uncaught = True
        self._bps = {}              # canonical file -> {line: _BP}
        self._bp_next = 1
        self._canon = {}            # co_filename -> canonical path
        self._user = {}             # co_filename -> is it the user's code
        self._fn_stack = []         # the traced calls, outermost first: (file, function, depth)
        self._top = ("", "<module>", 0)
        self._td = self.trace_dispatch  # one bound method, returned on every event
        self._start_continue = False
        self._first_stop = True
        self._seen_exc = None
        self._exc = None            # (type, value, tb) of the stop on an exception
        self._exc_mode = ""         # "always" | "unhandled"
        self._pm = False            # post-mortem: the frames have ended
        self._frames = []           # the stopped stack, innermost first
        self._refs = {}
        self._ref_n = 0
        self.exit_code = 0
        self._ns = None             # the program's namespace (its live globals)
        # the ring buffer of recent statements
        self._ring_n = ring if ring and ring > 0 else 0
        self._ring = [None] * self._ring_n
        self._ring_i = 0
        self._ring_total = 0
        self._hist = None           # a DebugSession over the ring while travelling
        self._hist_on = False
        self._hist_present = 0
        self._dbg_mod = None

    # ── the wire ─────────────────────────────────────────────────────────
    def _send(self, msg):
        if self.conn is None or self._detached:
            return
        self._send_lock.acquire()
        try:
            self._seq = self._seq + 1
            msg["seq"] = self._seq
            self.conn.sendall(encode_message(msg))
        except OSError:
            self._detached = True
        finally:
            self._send_lock.release()

    def _event(self, name, body=None):
        self._send({"type": "event", "event": name, "body": body if body is not None else {}})

    def _reply(self, req, body=None, ok=True, message=None):
        r = {"type": "response", "request_seq": req.get("seq", 0), "success": ok,
             "command": req.get("command", ""), "body": body if body is not None else {}}
        if message is not None:
            r["message"] = message
        self._send(r)

    def _fail(self, req, message):
        self._reply(req, {"error": {"id": 1, "format": message}}, False, message)

    # the socket thread: reads messages, answers the immediate ones, queues
    # the rest for the program's thread and raises the attention flag
    def _reader(self):
        buf = b""
        while True:
            try:
                data = self.conn.recv(65536)
            except OSError:
                data = b""
            if not data:
                break
            buf = buf + data
            while True:
                try:
                    msg, buf = take_message(buf)
                except BaseException:
                    msg = None
                    buf = b""
                if msg is None:
                    break
                self._on_message(msg)
        # the client went away: the program runs on without the debugger
        self._detached = True
        self._q.put({"type": "request", "command": "disconnect", "seq": 0, "_gone": True})
        self._attn = True
        self._configured.set()

    def _on_message(self, msg):
        if msg.get("type") != "request":
            return
        cmd = msg.get("command", "")
        if _IMMEDIATE.get(cmd):
            try:
                getattr(self, "_req_" + cmd.replace("/", "_"))(msg)
            except BaseException as e:
                self._fail(msg, type(e).__name__ + ": " + str(e))
            return
        self._q.put(msg)
        self._attn = True

    # ── immediate requests (socket thread) ──────────────────────────────
    def _req_initialize(self, req):
        self._reply(req, {
            "supportsConfigurationDoneRequest": True,
            "supportsConditionalBreakpoints": True,
            "supportsHitConditionalBreakpoints": True,
            "supportsLogPoints": True,
            "supportsEvaluateForHovers": True,
            "supportsSetVariable": True,
            "supportsExceptionInfoRequest": True,
            "supportsStepBack": True,
            "supportsTerminateRequest": True,
            "supportsDelayedStackTraceLoading": True,
            "supportsValueFormattingOptions": False,
            "exceptionBreakpointFilters": [
                {"filter": "raised", "label": "Raised Exceptions", "default": False},
                {"filter": "uncaught", "label": "Uncaught Exceptions", "default": True}],
            "nythonHistory": self._ring_n})
        self._event("initialized")
        self._event("process", {"name": getattr(self, "mainpyfile", ""), "systemProcessId": os.getpid(),
                                "isLocalProcess": True, "startMethod": "launch"})

    def _req_launch(self, req):
        a = req.get("arguments", {})
        self.stop_on_entry = bool(a.get("stopOnEntry", False))
        self._reply(req)

    def _req_attach(self, req):
        self._req_launch(req)

    def _req_nython_ping(self, req):
        self._reply(req, {"state": self.state})

    def _req_configurationDone(self, req):
        self._reply(req)
        self._configured.set()

    def _req_threads(self, req):
        self._reply(req, {"threads": [{"id": 1, "name": "MainThread"}]})

    def _req_pause(self, req):
        self._reply(req)
        if self.state == "running":
            self._pause_req = True
            self._attn = True

    def _req_disconnect(self, req):
        self._reply(req)
        if self.state == "ended":
            self._q.put({"type": "request", "command": "disconnect", "seq": 0, "_gone": True})
            return
        a = req.get("arguments", {})
        if req.get("command") == "terminate" or a.get("terminateDebuggee", True):
            self._quit_req = True
        else:
            self._detached = True
        self._q.put({"type": "request", "command": "disconnect", "seq": 0, "_gone": True})
        self._attn = True
        self._configured.set()

    def _req_terminate(self, req):
        self._req_disconnect(req)

    def _req_setExceptionBreakpoints(self, req):
        f = req.get("arguments", {}).get("filters", [])
        self.exc_raised = "raised" in f
        self.exc_uncaught = "uncaught" in f
        self._reply(req, {"breakpoints": [{"verified": True} for x in f]})

    def _req_setBreakpoints(self, req):
        a = req.get("arguments", {})
        src = a.get("source", {})
        path = src.get("path", "")
        canon = self._canonical(path)
        want = a.get("breakpoints", None)
        if want is None:
            want = [{"line": n} for n in a.get("lines", [])]
        du = None
        text = read_file(canon) if os.path.exists(canon) else None
        if text is not None:
            du = text_defuse(text)
        table = {}
        out = []
        for b in want:
            line = int(b.get("line", 0))
            info = {"id": self._bp_next, "verified": False, "line": line, "source": {"path": path}}
            self._bp_next = self._bp_next + 1
            at = self._statement_line(du, line)
            if at > 0:
                bp = _BP(info["id"], at, b.get("condition", "") or "", b.get("hitCondition", "") or "",
                         b.get("logMessage", "") or "")
                table[at] = bp
                info["verified"] = True
                info["line"] = at
            elif du is None:
                info["message"] = "No such file: " + path
            else:
                info["message"] = "Line " + str(line) + " is not a statement of " + os.path.basename(path)
            out.append(info)
        # one assignment: the program's thread sees the old or the new table
        nb = dict(self._bps)
        if table:
            nb[canon] = table
        elif canon in nb:
            del nb[canon]
        self._bps = nb
        self._reply(req, {"breakpoints": out})

    # the first line at or after `line` that starts a statement (0: none)
    def _statement_line(self, du, line):
        if du is None or line < 1:
            return 0
        if len(du) > 0 and du[0] is not None and "error" in du[0]:
            return line if line <= len(du) else 0
        ln = line
        while ln <= len(du):
            e = du[ln - 1]
            if e is not None and e.get("stmt"):
                return ln
            ln = ln + 1
        return 0

    # ── files ────────────────────────────────────────────────────────────
    def _canonical(self, fname):
        c = self._canon.get(fname)
        if c is None:
            if fname.startswith("<") and fname.endswith(">"):
                c = fname
            else:
                c = os.path.realpath(fname)
            self._canon[fname] = c
        return c

    def _is_user(self, fname):
        u = self._user.get(fname)
        if u is None:
            c = self._canonical(fname)
            u = not (c.startswith("<") or c.startswith(_LIBDIR + os.sep) or c.startswith(_LIBDIR + "/"))
            self._user[fname] = u
        return u

    # ── the trace function ──────────────────────────────────────────────
    # The hot path: every line a user frame runs. The frame's file and
    # function come from the call event (self._top: [canonical file,
    # function, depth] of the innermost traced call); its line and a fresh
    # dict of its variables from one native call - _ny_frame_sync, the
    # engines' frame protocol behind f_lineno / f_locals (round 78), without
    # the property and proxy layers. A ring entry is that dict, unrendered.
    def trace_dispatch(self, frame, event, arg):
        if event == "line":
            if self.quitting:
                return None
            if self._attn and self._attend(frame):
                return self._td
            top = self._top
            bps = self._bps.get(top[0])
            sf = self.stopframe
            if self._ring_n:
                _ny_frame_sync(frame)
                line = frame._ny_line
                i = self._ring_i
                self._ring[i] = (top, line, frame._ny_locals)
                i = i + 1
                if i == self._ring_n:
                    i = 0
                self._ring_i = i
                self._ring_total = self._ring_total + 1
            elif bps or sf is None or frame is sf:
                _ny_frame_sync(frame)
                line = frame._ny_line
            else:
                return self._td
            if bps:
                b = bps.get(line)
                if b is not None:
                    b = self._break_check(b, frame)
                    if b is not None:
                        self._stop(frame, "breakpoint", b)
                        if self.quitting:
                            raise bdb.BdbQuit
                        return self._td
            if sf is None or (frame is sf and self.stoplineno != -1 and line >= self.stoplineno):
                self._stop(frame, "entry" if self._first_stop else "step", None)
                if self.quitting:
                    raise bdb.BdbQuit
            return self._td
        if self.quitting:
            return None
        if event == "call":
            return self._on_call(frame)
        if event == "return":
            return self._on_return(frame, arg)
        if event == "exception":
            return self._on_exception(frame, arg)
        return self.trace_dispatch

    def _on_call(self, frame):
        code = frame.f_code
        fname = code.co_filename
        if not self._is_user(fname):
            return None
        if self.botframe is None:
            self.botframe = frame.f_back
            if self._start_continue:
                self._set_stopinfo(self.botframe, None, -1)
        top = (self._canonical(fname), code.co_name, len(self._fn_stack))
        self._fn_stack.append(top)
        self._top = top
        return self._td

    def _on_return(self, frame, arg):
        st = self._fn_stack
        if st:
            st.pop()
            self._top = st[-1] if st else ("", "<module>", 0)
        # bdb's dispatch_return: a next/until in this frame ends with it
        # (not in a generator, which is resumed later)
        if self.stop_here(frame) or frame is self.returnframe:
            if self.stopframe and bdb._co_flags(frame) & bdb.GENERATOR_AND_COROUTINE_FLAGS:
                return self.trace_dispatch
            if self.stopframe is frame and self.stoplineno != -1:
                self._set_stopinfo(None, None)
        return self.trace_dispatch

    def _on_exception(self, frame, arg):
        if not self.exc_raised:
            return self.trace_dispatch
        et, ev = arg[0], arg[1]
        if ev is self._seen_exc or _SKIP_EXC.get(getattr(et, "__name__", "")):
            return self.trace_dispatch
        self._seen_exc = ev
        self._exc = arg
        self._exc_mode = "always"
        self._stop(frame, "exception", None)
        if self.quitting:
            raise bdb.BdbQuit
        return self.trace_dispatch

    def set_continue(self):
        # bdb stops tracing when there are no breakpoints; the live debugger
        # keeps tracing: a pause must reach a running loop, and the history
        # keeps recording
        self._set_stopinfo(self.botframe, None, -1)

    # a breakpoint's condition, hit count and log message: the breakpoint
    # when it stops here
    def _break_check(self, bp, frame):
        if bp.cond:
            try:
                if not self._eval(bp.cond, frame):
                    return None
            except BaseException as e:
                self._event("output", {"category": "important",
                                       "output": "Breakpoint condition " + repr(bp.cond) + " raised "
                                       + type(e).__name__ + ": " + str(e) + "\n"})
        bp.hits = bp.hits + 1
        if bp.hit and not _hit_ok(bp.hits, bp.hit):
            return None
        if bp.log:
            self._event("output", {"category": "console", "output": self._interpolate(bp.log, frame) + "\n",
                                   "source": {"path": self._canonical(frame.f_code.co_filename)},
                                   "line": bp.line})
            return None
        return bp

    def _interpolate(self, msg, frame):
        out = []
        i = 0
        n = len(msg)
        while i < n:
            c = msg[i]
            if c == "{":
                j = msg.find("}", i)
                if j > i:
                    expr = msg[i + 1:j]
                    try:
                        out.append(str(self._eval(expr, frame)))
                    except BaseException as e:
                        out.append("<" + type(e).__name__ + ">")
                    i = j + 1
                    continue
            out.append(c)
            i = i + 1
        return "".join(out)

    # the socket thread raised the flag: queued requests, pause, quit
    def _attend(self, frame):
        self._attn = False
        while True:
            try:
                msg = self._q.get_nowait()
            except queue.Empty:
                break
            self._handle_running(msg)
        if self._quit_req:
            self.set_quit()
            raise bdb.BdbQuit
        if self._detached:
            self._detach()
            return True
        if self._pause_req:
            self._pause_req = False
            self._stop(frame, "pause", None)
            return True
        return False

    def _detach(self):
        # the client left: no more stops (tracing goes on, cheaply)
        self._bps = {}
        self.exc_raised = False
        self.exc_uncaught = False
        self._ring_n = 0
        self._set_stopinfo(self.botframe, None, -1)

    def _handle_running(self, msg):
        cmd = msg.get("command", "")
        if msg.get("_gone"):
            return
        if cmd == "continue":
            self._reply(msg, {"allThreadsContinued": True})
        else:
            self._fail(msg, "notStopped: the program is running")

    # ── stopping ─────────────────────────────────────────────────────────
    def _stop(self, frame, reason, bp):
        self._first_stop = False
        self._frames = self._user_stack(frame)
        self._refs = {}
        self._ref_n = 0
        self._hist = None
        self._hist_on = False
        body = {"reason": reason, "threadId": 1, "allThreadsStopped": True}
        if bp is not None:
            body["hitBreakpointIds"] = [bp.id]
        if reason == "exception" and self._exc is not None:
            ev = self._exc[1]
            body["description"] = "Exception has occurred: " + _type_name(ev)
            body["text"] = _type_name(ev) + ": " + str(ev)
        self.state = "paused"
        self._event("stopped", body)
        self._loop()
        if reason == "exception":
            self._exc = None

    # the command loop while paused: until a request resumes the program
    def _loop(self):
        while True:
            msg = self._q.get()
            cmd = msg.get("command", "")
            if msg.get("_gone"):
                if self._quit_req:
                    self.set_quit()
                else:
                    self._detach()
                break
            try:
                done = self._handle_paused(msg)
            except BaseException as e:
                self._fail(msg, type(e).__name__ + ": " + str(e))
                done = False
            if done:
                break
        self._refs = {}
        self._hist = None
        self._hist_on = False
        if not self.quitting:
            self.state = "running"

    def _handle_paused(self, msg):
        cmd = msg.get("command", "")
        a = msg.get("arguments", {})
        if _RESUME.get(cmd):
            return self._resume(msg, cmd, a)
        fn = getattr(self, "_p_" + cmd.replace("/", "_"), None)
        if fn is None:
            self._fail(msg, "unsupported request: " + cmd)
            return False
        fn(msg, a)
        return False

    def _resume(self, msg, cmd, a):
        if self._hist_on or cmd in ("stepBack", "reverseContinue", "nython/seek"):
            r = self._travel(msg, cmd, a)
            if r is not None:
                return r
        if self._pm:
            self._reply(msg, {"allThreadsContinued": True})
            return True
        top = self._frames[0] if self._frames else None
        if cmd == "continue":
            self.set_continue()
            self._reply(msg, {"allThreadsContinued": True})
        elif cmd == "next":
            if top is None:
                self.set_continue()
            else:
                self.set_next(top)
            self._reply(msg)
        elif cmd == "stepIn":
            self.set_step()
            self._reply(msg)
        elif cmd == "stepOut":
            if top is None:
                self.set_continue()
            else:
                self.set_return(top)
            self._reply(msg)
        return True

    # ── history (the ring buffer) ────────────────────────────────────────
    # A ring entry's variables, rendered when the history is read: the
    # bindings are as they were at that step; an object they point to that
    # changed since (a list appended to) shows how it is now.
    def _snap(self, loc, module):
        out = {}
        for k in sorted(loc.keys()):
            if type(k) is not str or k.startswith("__"):
                continue
            v = loc[k]
            t = type(v)
            if t is int or t is float or t is bool or v is None:
                out[k] = repr(v)
            elif t is str:
                out[k] = repr(v) if len(v) <= 60 else repr(v[:57]) + "..."
            elif module and (callable(v) or t.__name__ == "module" or isinstance(v, type)):
                continue
            else:
                out[k] = self._brief(v, 0)
        return out

    # a short rendering that calls no user code
    def _brief(self, v, depth):
        t = type(v)
        if t is int or t is float or t is bool or v is None:
            return repr(v)
        if t is str:
            return repr(v) if len(v) <= 60 else repr(v[:57]) + "..."
        if t is list or t is tuple:
            if depth > 0:
                return "[...]" if t is list else "(...)"
            parts = []
            n = len(v)
            k = 0
            while k < n and k < 8:
                parts.append(self._brief(v[k], 1))
                k = k + 1
            if n > 8:
                parts.append("... (" + str(n) + ")")
            if t is list:
                return "[" + ", ".join(parts) + "]"
            return "(" + ", ".join(parts) + ("," if n == 1 else "") + ")"
        if t is dict:
            if depth > 0:
                return "{...}"
            parts = []
            k = 0
            for key in v:
                if k >= 6:
                    parts.append("...")
                    break
                parts.append(self._brief(key, 1) + ": " + self._brief(v[key], 1))
                k = k + 1
            return "{" + ", ".join(parts) + "}"
        if t is set or t is frozenset:
            return t.__name__ + "(" + str(len(v)) + ")"
        if callable(v) and not hasattr(v, "__dict__"):
            return "<" + t.__name__ + ">"
        return "<" + t.__name__ + " object>"

    def _ring_rows(self):
        n = self._ring_n
        if n == 0:
            return []
        if self._ring_total < n:
            return self._ring[:self._ring_i]
        return self._ring[self._ring_i:] + self._ring[:self._ring_i]

    def history_lines(self):
        """The ring's statements, oldest first, as `nython --trace` writes
        them (one JSON object per line)."""
        out = []
        for r in self._ring_rows():
            top = r[0]
            out.append("{\"f\":" + json_encode(top[0]) + ",\"l\":" + str(r[1]) + ",\"d\":" + str(top[2])
                       + ",\"fn\":" + json_encode(top[1]) + ",\"v\":" + json_encode(self._snap(r[2], top[1] == "<module>")) + "}")
        return out

    def _session(self):
        if self._hist is not None:
            return self._hist
        if self._dbg_mod is None:
            import ide_debugger
            self._dbg_mod = ide_debugger
        s = self._dbg_mod.DebugSession()
        s.load_lines(self.history_lines())
        s.active = True
        s.state = "paused"
        s.pos = s.n - 1
        self._hist = s
        self._hist_present = s.n - 1
        return s

    def _break_map(self):
        m = {}
        for path, table in self._bps.items():
            for line, bp in table.items():
                if bp.cond or bp.hit or bp.log:
                    m[path + ":" + str(line)] = {"cond": bp.cond, "hits": bp.hit, "log": bp.log}
                else:
                    m[path + ":" + str(line)] = True
        return m

    # stepBack, reverseContinue, seek - and forward steps while in the past.
    # None: carry on live (the present was reached by a forward step)
    def _travel(self, msg, cmd, a):
        if self._ring_n == 0:
            if cmd in ("stepBack", "reverseContinue", "nython/seek"):
                self._fail(msg, "no history: the ring buffer is off")
                return False
            return None
        s = self._session()
        if s.n == 0:
            self._fail(msg, "no history yet")
            return False
        present = self._hist_present
        hit = False
        if cmd == "stepBack":
            s.step_back()
        elif cmd == "reverseContinue":
            hit = s.continue_back(self._break_map())
        elif cmd == "nython/seek":
            k = int(a.get("step", -1))
            s.seek(present if k < 0 or k > present else k)
        elif cmd == "next":
            s.step_over()
        elif cmd == "stepIn":
            s.step_into()
        elif cmd == "stepOut":
            s.step_out()
        elif cmd == "continue":
            hit = s.continue_fwd(self._break_map())
            if not hit:
                s.pos = present
        if s.pos >= present:
            # back in the present: the live program waits here (a continue
            # that met no breakpoint on the way goes on live)
            s.pos = present
            self._hist_on = False
            if cmd == "continue" and not hit:
                return None
            self._reply(msg)
            self._refs = {}
            self._event("stopped", {"reason": "breakpoint" if hit else "step", "threadId": 1, "allThreadsStopped": True,
                                    "description": "the present"})
            return False
        self._hist_on = True
        self._refs = {}
        self._reply(msg)
        self._event("stopped", {"reason": "breakpoint" if hit else "step", "threadId": 1, "allThreadsStopped": True,
                                "description": "history step " + str(s.pos + 1) + " of " + str(s.n),
                                "nythonHistory": {"step": s.pos, "of": s.n}})
        return False

    # ── paused requests ──────────────────────────────────────────────────
    def _user_stack(self, frame):
        out = []
        f = frame
        while f is not None and f is not self.botframe:
            if self._is_user(f.f_code.co_filename):
                out.append(f)
            f = f.f_back
        return out

    def _ref(self, kind, obj, extra=None):
        self._ref_n = self._ref_n + 1
        self._refs[self._ref_n] = (kind, obj, extra)
        return self._ref_n

    def _frame_of(self, a):
        fid = a.get("frameId", None)
        if fid is None:
            return self._frames[0] if self._frames else None
        fid = int(fid)
        if fid < 1 or fid > len(self._frames):
            raise ValueError("no frame " + str(fid))
        return self._frames[fid - 1]

    def _p_stackTrace(self, msg, a):
        start = int(a.get("startFrame", 0) or 0)
        levels = int(a.get("levels", 0) or 0)
        out = []
        if self._hist_on:
            st = self._hist.stack()
            k = 0
            while k < len(st):
                out.append({"id": 1000 + k, "name": st[k][0], "line": st[k][2], "column": 1,
                            "source": {"path": st[k][1], "name": os.path.basename(st[k][1])},
                            "presentationHint": "subtle" if k > 0 else "normal"})
                k = k + 1
        else:
            k = 0
            for f in self._frames:
                k = k + 1
                fname = self._canonical(f.f_code.co_filename)
                out.append({"id": k, "name": f.f_code.co_name, "line": f.f_lineno, "column": 1,
                            "source": {"path": fname, "name": os.path.basename(fname)}})
        total = len(out)
        if start > 0:
            out = out[start:]
        if levels > 0:
            out = out[:levels]
        self._reply(msg, {"stackFrames": out, "totalFrames": total})

    def _p_scopes(self, msg, a):
        if self._hist_on:
            self._reply(msg, {"scopes": [{"name": "Locals (recorded)", "variablesReference": self._ref("hist", None),
                                          "expensive": False, "presentationHint": "locals"}]})
            return
        f = self._frame_of(a)
        sc = []
        module = f.f_code.co_name == "<module>"
        sc.append({"name": "Locals", "presentationHint": "locals", "expensive": False,
                   "variablesReference": self._ref("scope", f, "globals" if module else "locals")})
        if not module:
            sc.append({"name": "Globals", "expensive": True,
                       "variablesReference": self._ref("scope", f, "globals")})
        self._reply(msg, {"scopes": sc})

    def _var(self, name, value, expr):
        ref = 0
        if self._expandable(value):
            ref = self._ref("value", value, expr)
        v = {"name": name, "value": _safe_repr(value), "type": _type_name(value), "variablesReference": ref}
        if expr is not None:
            v["evaluateName"] = expr
        if ref:
            try:
                n = len(value)
                if isinstance(value, (list, tuple)):
                    v["indexedVariables"] = n
                else:
                    v["namedVariables"] = n
            except BaseException:
                pass
        return v

    def _expandable(self, v):
        t = type(v)
        if t is int or t is float or t is bool or t is str or v is None or t is bytes:
            return False
        if isinstance(v, (list, tuple, dict, set, frozenset)):
            return len(v) > 0
        if isinstance(v, type) or callable(v) and not hasattr(v, "__dict__"):
            return False
        d = getattr(v, "__dict__", None)
        return d is not None and len(d) > 0

    # [(name, value, evaluateName, key)] of a container or object
    def _children(self, obj, expr):
        out = []
        if isinstance(obj, (list, tuple)):
            k = 0
            for x in obj:
                out.append((str(k), x, (expr + "[" + str(k) + "]") if expr else None, k))
                k = k + 1
        elif isinstance(obj, dict):
            for key in list(obj.keys()):
                kr = _safe_repr(key, 120)
                out.append((kr, obj[key], (expr + "[" + kr + "]") if expr else None, key))
        elif isinstance(obj, (set, frozenset)):
            items = sorted([_safe_repr(x) for x in obj])
            k = 0
            for x in items:
                out.append((str(k), x, None, None))
                k = k + 1
            return [(c[0], _Text(c[1]), None, None) for c in out]
        else:
            d = getattr(obj, "__dict__", {})
            for key in sorted(list(d.keys())):
                if key.startswith("__"):
                    continue
                out.append((key, d[key], (expr + "." + key) if expr else None, key))
        return out

    # A frame's globals, live: f_globals is a copy on both engines (as is
    # globals()), so the program's own namespace - the dict it was exec'd
    # in, which the running code reads - stands for the main program's
    # frames, and a module's attributes for an imported module's.
    def _globals(self, f):
        g = f.f_globals
        if self._ns is not None and g.get("__name__") == "__main__":
            return self._ns
        return g

    # an expression (text or code) evaluated in frame f
    def _eval(self, code, f):
        g = self._globals(f)
        if g is self._ns and f.f_code.co_name == "<module>":
            return eval(code, g)
        return eval(code, g, dict(f.f_locals))

    def _set_global(self, f, name, val):
        g = f.f_globals
        mod = g.get("__name__")
        if self._ns is not None and mod == "__main__":
            self._ns[name] = val
            return
        m = sys.modules.get(mod)
        if m is not None:
            setattr(m, name, val)
        else:
            g[name] = val

    def _scope_items(self, f, which):
        if which == "globals":
            src = self._globals(f)
            out = []
            for k in sorted(list(src.keys())):
                v = src[k]
                if type(k) is not str or k.startswith("__") or type(v).__name__ == "module":
                    continue
                # functions and classes are not listed (as the --trace
                # recording leaves them out)
                if isinstance(v, type) or (callable(v) and not hasattr(v, "__dict__")) or type(v).__name__ in ("function", "builtin_function_or_method"):
                    continue
                out.append((k, v, k, k))
            return out
        out = []
        loc = f.f_locals
        for k in sorted(list(loc.keys())):
            if k.startswith("__") and k.endswith("__"):
                continue
            out.append((k, loc[k], k, k))
        return out

    def _p_variables(self, msg, a):
        ref = int(a.get("variablesReference", 0))
        r = self._refs.get(ref)
        if r is None:
            self._fail(msg, "no variables reference " + str(ref))
            return
        kind = r[0]
        if kind == "hist":
            vs = []
            for nv in self._hist.variables():
                vs.append({"name": nv[0], "value": nv[1], "variablesReference": 0, "evaluateName": nv[0]})
            self._reply(msg, {"variables": vs})
            return
        if kind == "scope":
            items = self._scope_items(r[1], r[2])
        else:
            items = self._children(r[1], r[2])
        start = int(a.get("start", 0) or 0)
        count = int(a.get("count", 0) or 0)
        if start > 0:
            items = items[start:]
        if count > 0:
            items = items[:count]
        elif len(items) > 1000:
            items = items[:1000]
        vs = []
        for it in items:
            if isinstance(it[1], _Text):
                vs.append({"name": it[0], "value": it[1].s, "variablesReference": 0})
            else:
                vs.append(self._var(it[0], it[1], it[2]))
        self._reply(msg, {"variables": vs})

    def _value_of(self, text, f, statement):
        ns = dict(f.f_locals)
        return self._eval(text, f)

    def _p_setVariable(self, msg, a):
        if self._hist_on:
            self._fail(msg, "a recorded step cannot be changed (step forward to the present)")
            return
        ref = int(a.get("variablesReference", 0))
        name = a.get("name", "")
        text = a.get("value", "")
        r = self._refs.get(ref)
        if r is None:
            self._fail(msg, "no variables reference " + str(ref))
            return
        f = self._frames[0] if self._frames else None
        if r[0] == "scope":
            f = r[1]
        val = self._value_of(text, f, False)
        if r[0] == "scope":
            if r[2] == "globals":
                self._set_global(f, name, val)
            else:
                f.f_locals[name] = val
        else:
            obj = r[1]
            key = None
            for c in self._children(obj, None):
                if c[0] == name:
                    key = c[3]
            if isinstance(obj, list):
                obj[int(name)] = val
            elif isinstance(obj, dict):
                if key is None:
                    raise KeyError(name)
                obj[key] = val
            elif isinstance(obj, (tuple, set, frozenset)):
                raise TypeError("'" + type(obj).__name__ + "' object does not support item assignment")
            else:
                setattr(obj, name, val)
        v = self._var(name, val, None)
        self._reply(msg, {"value": v["value"], "type": v["type"], "variablesReference": v["variablesReference"]})

    def _p_evaluate(self, msg, a):
        expr = a.get("expression", "")
        ctx = a.get("context", "repl")
        if self._hist_on:
            v = self._hist.value_of(expr.strip())
            if v is None:
                self._fail(msg, "only the recorded variables are known at a history step")
            else:
                self._reply(msg, {"result": v, "variablesReference": 0})
            return
        f = self._frame_of(a)
        if f is None:
            self._fail(msg, "no frame")
            return
        try:
            code = compile(expr, "<debug>", "eval")
        except SyntaxError:
            code = None
        if code is not None:
            val = self._eval(code, f)
            v = self._var("", val, expr)
            self._reply(msg, {"result": v["value"], "type": v["type"], "variablesReference": v["variablesReference"]})
            return
        if ctx != "repl":
            raise SyntaxError("invalid syntax")
        # a statement in the debug console: what it binds reaches the frame
        ns = dict(f.f_locals)
        before = dict(ns)
        module = f.f_code.co_name == "<module>"
        if module and self._globals(f) is self._ns:
            exec(compile(expr, "<debug>", "exec"), self._ns)
        elif module:
            exec(compile(expr, "<debug>", "exec"), f.f_globals, ns)
            for k in ns:
                if k not in before or ns[k] is not before[k]:
                    self._set_global(f, k, ns[k])
        else:
            exec(compile(expr, "<debug>", "exec"), self._globals(f), ns)
            for k in ns:
                if k not in before or ns[k] is not before[k]:
                    f.f_locals[k] = ns[k]
        self._reply(msg, {"result": "", "variablesReference": 0})

    def _p_exceptionInfo(self, msg, a):
        if self._exc is None:
            self._fail(msg, "not stopped on an exception")
            return
        et, ev, tb = self._exc
        import traceback
        st = "".join(traceback.format_exception(et, ev, tb))
        name = getattr(et, "__qualname__", _type_name(ev))
        mod = getattr(et, "__module__", "builtins")
        full = name if mod in (None, "builtins", "__main__") else mod + "." + name
        self._reply(msg, {"exceptionId": name, "description": str(ev), "breakMode": self._exc_mode,
                          "details": {"message": str(ev), "typeName": name, "fullTypeName": full,
                                      "stackTrace": st}})

    def _p_source(self, msg, a):
        p = a.get("source", {}).get("path", "")
        text = read_file(p) if p else None
        if text is None:
            self._fail(msg, "no source for " + str(p))
        else:
            self._reply(msg, {"content": text})

    def _p_threads(self, msg, a):
        self._req_threads(msg)

    def _p_nython_history(self, msg, a):
        lines = self.history_lines()
        self._reply(msg, {"lines": lines, "capacity": self._ring_n, "total": self._ring_total,
                          "dropped": max(0, self._ring_total - len(lines)),
                          "step": self._hist.pos if self._hist_on else len(lines) - 1})

    def _why_rows(self, entries):
        return entries

    def _p_nython_whyValue(self, msg, a):
        if self._ring_n == 0:
            self._fail(msg, "no history: the ring buffer is off")
            return
        s = self._session()
        at = a.get("step", None)
        if at is None or at < 0:
            at = s.pos
        self._reply(msg, {"entries": s.why_value(a.get("name", ""), at, int(a.get("limit", 40) or 40)),
                          "steps": s.n, "dropped": max(0, self._ring_total - s.n)})

    def _p_nython_whyNot(self, msg, a):
        if self._ring_n == 0:
            self._fail(msg, "no history: the ring buffer is off")
            return
        s = self._session()
        self._reply(msg, {"entries": s.why_not(self._canonical(a.get("path", "")), int(a.get("line", 0)), s.pos),
                          "steps": s.n})

    # ── running a program ────────────────────────────────────────────────
    def _listen(self, host, port, connect):
        if connect:
            h, p = connect.rsplit(":", 1)
            c = socket.create_connection((h, int(p)))
            return c
        ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        ls.bind((host, port))
        ls.listen(1)
        if port == 0:
            print("debug server listening on " + host + ":" + str(ls.getsockname()[1]), file=sys.stderr, flush=True)
        c, addr = ls.accept()
        ls.close()
        return c

    def serve(self, path, args=None, host="127.0.0.1", port=0, connect=None):
        """Run the program in `path` under the debugger once a client has
        connected and sent configurationDone; its exit status."""
        self.mainpyfile = os.path.realpath(path)
        self.conn = self._listen(host, port, connect)
        try:
            self.conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        t = threading.Thread(target=self._reader, name="nython-debug-server", daemon=True)
        t.start()
        self._configured.wait()
        code = 0
        if not self._quit_req:
            code = self._run_program(self.mainpyfile, args or [])
        self._finish(code)
        return code

    def _run_program(self, path, args):
        text = read_file(path)
        if text is None:
            self._event("output", {"category": "stderr", "output": "can't open file " + repr(path) + "\n"})
            return 2
        try:
            code = compile(text, path, "exec")
        except SyntaxError as e:
            import traceback
            msg = "".join(traceback.format_exception_only(type(e), e))
            sys.stderr.write(msg)
            self._event("output", {"category": "stderr", "output": msg})
            return 1
        ns = {"__name__": "__main__", "__file__": path, "__package__": None, "__spec__": None,
              "__cached__": None}
        self._ns = ns
        sys.argv[:] = [path] + list(args)
        self.reset()
        self.botframe = None
        self._start_continue = not self.stop_on_entry
        self._first_stop = True
        self.state = "running"
        status = 0
        sys.settrace(self.trace_dispatch)
        try:
            exec(code, ns)
        except bdb.BdbQuit:
            status = 0
        except SystemExit as e:
            c = e.code
            if c is None:
                status = 0
            elif isinstance(c, int):
                status = c
            else:
                sys.stderr.write(str(c) + "\n")
                status = 1
        except BaseException as e:
            sys.settrace(None)
            status = 1
            self._uncaught(e)
        finally:
            self.quitting = True
            sys.settrace(None)
        return status

    # an exception left the program: stop on it, post mortem, then report
    # it as Python would
    def _uncaught(self, e):
        tb = e.__traceback__
        if self.exc_uncaught and not self._detached and not self._quit_req:
            frames = []
            t = tb
            while t is not None:
                f = t.tb_frame
                if self._is_user(f.f_code.co_filename):
                    frames.append(f)
                t = t.tb_next
            frames.reverse()
            self._frames = frames
            self._exc = (type(e), e, tb)
            self._exc_mode = "unhandled"
            self._pm = True
            self._refs = {}
            self.state = "paused"
            self._event("stopped", {"reason": "exception", "threadId": 1, "allThreadsStopped": True,
                                    "description": "Uncaught exception: " + _type_name(e),
                                    "text": _type_name(e) + ": " + str(e)})
            self.quitting = False
            self._loop()
            self._pm = False
        import traceback
        sys.stdout.flush()
        txt = "".join(traceback.format_exception(type(e), e, tb))
        sys.stderr.write(txt)
        sys.stderr.flush()
        self._event("output", {"category": "stderr", "output": txt})

    def _finish(self, code):
        try:
            sys.stdout.flush()
        except BaseException:
            pass
        self.exit_code = code
        self.state = "ended"
        self._event("exited", {"exitCode": code})
        self._event("terminated")
        # the client says disconnect (or closes) - at most a second
        t0 = time.monotonic()
        while not self._detached and time.monotonic() - t0 < 1.0:
            try:
                msg = self._q.get(timeout=0.05)
            except queue.Empty:
                continue
            if msg.get("_gone") or msg.get("command") in ("disconnect", "terminate"):
                break
            if not msg.get("_gone"):
                self._fail(msg, "the program has ended")
        try:
            self.conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.conn.close()
        except OSError:
            pass


class _Text:
    # a value already rendered (a set's items are listed as their reprs)
    def __init__(self, s):
        self.s = s


_USAGE = ("usage: nython -m ide_debugserver [--host HOST] [--port PORT] [--connect HOST:PORT] "
          "[--ring N] [--no-ring] [--stop-on-entry] prog.ny [arg] ...")


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    host = "127.0.0.1"
    port = 0
    connect = None
    ring = RING_SIZE
    entry = False
    while args and args[0].startswith("-"):
        a = args.pop(0)
        if a == "--host":
            host = args.pop(0)
        elif a == "--port":
            port = int(args.pop(0))
        elif a == "--connect":
            connect = args.pop(0)
        elif a == "--ring":
            ring = int(args.pop(0))
        elif a == "--no-ring":
            ring = 0
        elif a == "--stop-on-entry":
            entry = True
        elif a in ("-h", "--help"):
            print(_USAGE)
            return 0
        elif a == "--":
            break
        else:
            print(_USAGE, file=sys.stderr)
            print("ide_debugserver: unknown option " + a, file=sys.stderr)
            return 2
    if not args:
        print(_USAGE, file=sys.stderr)
        return 2
    srv = DebugServer(ring)
    srv.stop_on_entry = entry
    return srv.serve(args[0], args[1:], host, port, connect)


if __name__ == "__main__":
    sys.exit(main())
