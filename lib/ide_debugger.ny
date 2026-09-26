# ══════════════════════════════════════════════════════════════════════════════
#  lib/ide_debugger.ny — a record-and-replay ("omniscient") debugger.
#
#  The program runs to completion (or to its uncaught error) under
#  `nython --trace OUT file.ny`, which records every statement executed in the
#  user's own files: file, line, call depth, enclosing function, that frame's
#  variables, program output and the uncaught exception. DebugSession then
#  replays the recording.
#
#  Why record rather than pause a live process: stepping over a recording is
#  exact in BOTH directions, so Step Back and Reverse Continue come for free
#  (time-travel debugging, after Lewis, "Debugging Backwards in Time", 2003,
#  and record/replay debuggers such as rr); the IDE never blocks on a paused
#  child process; and a program that loops forever is simply stopped, its
#  recording up to that point still fully steppable.
#
#  Memory: the interpreter never reclaims containers (GC_NOTES.md), so events
#  are NOT decoded into maps on load. Each event keeps its raw line plus three
#  parallel int arrays (line, depth, file id); only the event being inspected
#  is fully decoded.
#
#  Tested without a window by examples/vm_audit44.ny.
# ══════════════════════════════════════════════════════════════════════════════


class DebugSession:
    def __init__(self):
        self.active = false
        self.state = "idle"        # idle | recording | paused | ended
        self.raw = []              # raw JSON line per step event
        self.lines = []            # 1-based line per event
        self.depths = []
        self.files = []            # file id per event
        self.file_names = []
        self.out_before = []       # number of output lines emitted before each event
        self.outputs = []
        self.n = 0
        self.pos = -1
        self.exception = ""
        self.exception_at = ""
        self.capped = false
        self._cur_vars = none
        self._cur_pos = -2
        self._cur_fn = ""
        self.logs = []             # log-message breakpoints passed by continue_fwd
        self.logging = false
        self._hit_nos = none       # per step: how many times its line was reached so far

    def reset(self):
        self.__init__()

    # ── loading ──────────────────────────────────────────────────────────────
    def load(self, path):
        self.raw = []
        self.lines = []
        self.depths = []
        self.files = []
        self.file_names = []
        self.out_before = []
        self.outputs = []
        self.exception = ""
        self.exception_at = ""
        self.capped = false
        var text = read_file(path)
        if text == none:
            return false
        var rows = string_split(text, "\n")
        var i = 0
        while i < len(rows):
            var ln = rows[i]
            if string_startswith(ln, "{\"f\":"):
                self._add_step(ln)
            elif string_startswith(ln, "{\"o\":"):
                var o = json_decode(ln)
                if o != none:
                    self.outputs.append(o["o"])
            elif string_startswith(ln, "{\"x\":"):
                var x = json_decode(ln)
                if x != none:
                    self.exception = x["x"]
                    self.exception_at = x["at"]
            elif string_startswith(ln, "{\"cap\":"):
                self.capped = true
            i = i + 1
        self.n = len(self.raw)
        self.pos = -1
        self._cur_pos = -2
        return true

    # {"f":"<file>","l":<n>,"d":<n>,"fn":...} - read the three hot fields
    # without decoding the whole object.
    def _add_step(self, ln):
        var fe = string_find(ln, "\",\"l\":")
        if fe < 0:
            return
        var file = string_slice(ln, 6, fe)
        var rest = string_slice(ln, fe + 6, len(ln))
        var comma = string_find(rest, ",")
        var line = int(string_slice(rest, 0, comma))
        var rest2 = string_slice(rest, comma + 5, len(rest))
        var comma2 = string_find(rest2, ",")
        var depth = int(string_slice(rest2, 0, comma2))
        var fid = -1
        var k = 0
        while k < len(self.file_names):
            if self.file_names[k] == file:
                fid = k
            k = k + 1
        if fid < 0:
            self.file_names.append(file)
            fid = len(self.file_names) - 1
        self.raw.append(ln)
        self.lines.append(line)
        self.depths.append(depth)
        self.files.append(fid)
        self.out_before.append(len(self.outputs))

    # ── inspection of the current step ───────────────────────────────────────
    def file_at(self, i):
        if i < 0 or i >= self.n:
            return ""
        return self.file_names[self.files[i]]

    def line_at(self, i):
        if i < 0 or i >= self.n:
            return 0
        return self.lines[i]

    def _decode(self):
        if self._cur_pos == self.pos:
            return
        self._cur_pos = self.pos
        self._cur_vars = none
        self._cur_fn = ""
        if self.pos < 0 or self.pos >= self.n:
            return
        var ev = json_decode(self.raw[self.pos])
        if ev == none:
            return
        self._cur_fn = ev["fn"]
        self._cur_vars = ev["v"]

    # [[name, value], ...] sorted by name.
    def variables(self):
        self._decode()
        var out = []
        if self._cur_vars == none:
            return out
        var names = sorted(self._cur_vars.keys())
        var i = 0
        while i < len(names):
            out.append([names[i], self._cur_vars[names[i]]])
            i = i + 1
        return out

    def value_of(self, name):
        self._decode()
        if self._cur_vars == none:
            return none
        if self._cur_vars.has_key(name):
            return self._cur_vars[name]
        return none

    def function(self):
        self._decode()
        return self._cur_fn

    # Call stack at the current step, innermost first: [function, file, line].
    # Reconstructed from the recording: each caller's frame is the latest
    # earlier step at the next depth out.
    def stack(self):
        var out = []
        if self.pos < 0 or self.pos >= self.n:
            return out
        var d = self.depths[self.pos]
        out.append([self._fn_of(self.pos), self.file_at(self.pos), self.lines[self.pos]])
        var i = self.pos - 1
        var want = d - 1
        while i >= 0 and want >= 0:
            if self.depths[i] == want:
                out.append([self._fn_of(i), self.file_at(i), self.lines[i]])
                want = want - 1
            elif self.depths[i] < want:
                want = self.depths[i]
                out.append([self._fn_of(i), self.file_at(i), self.lines[i]])
                want = want - 1
            i = i - 1
        return out

    def _fn_of(self, i):
        var ln = self.raw[i]
        var a = string_find(ln, ",\"fn\":\"")
        if a < 0:
            return "?"
        var rest = string_slice(ln, a + 7, len(ln))
        var b = string_find(rest, "\",\"v\":")
        if b < 0:
            return "?"
        return string_slice(rest, 0, b)

    def output_so_far(self):
        if self.pos < 0:
            return 0
        if self.pos >= self.n:
            return len(self.outputs)
        return self.out_before[self.pos]

    # ── stepping ─────────────────────────────────────────────────────────────
    # Each returns true when the position moved. `breaks` maps "file:line"
    # (1-based) to true.
    def start(self, breaks):
        if self.n == 0:
            self.state = "ended"
            return false
        self.active = true
        self.state = "paused"
        self.pos = 0
        # Log points passed on the way to the first stop are reported too.
        self.logs = []
        self.logging = true
        if not self._is_break(0, breaks):
            var hit = self._next_break(0, breaks)
            if hit >= 0:
                self.pos = hit
        self.logging = false
        return true

    # A breakpoint is `true` or a map {cond, hits, log}. Hit counts: "5" stops
    # on the 5th time the line is reached, ">5", ">=5", "%5" (every fifth).
    # Conditions: `name op literal` (== != < > <= >=) or a bare name, on the
    # values recorded at that step. A log message never stops: with {name}
    # replaced by values it is added to self.logs while continuing forward.
    def _is_break(self, i, breaks):
        var key = self.file_at(i) + ":" + str(self.lines[i])
        if not breaks.has_key(key):
            return false
        var spec = breaks[key]
        if spec == true:
            return true
        var hits = spec["hits"]
        if hits != "" and not self._hits_ok(self._hit_no(i), hits):
            return false
        var cond = spec["cond"]
        if cond != "" and not self._cond_ok(i, cond):
            return false
        var log = spec["log"]
        if log != "":
            if self.logging:
                self.logs.append(self._interpolate(i, log))
            return false
        return true

    # How many times step i's line has been reached, counting step i.
    def _hit_no(self, i):
        if self._hit_nos == none:
            var counts = {}
            var out = []
            var k = 0
            while k < self.n:
                var key = str(self.files[k]) + ":" + str(self.lines[k])
                var c = counts.get(key)
                if c == none:
                    c = 0
                c = c + 1
                counts[key] = c
                out.append(c)
                k = k + 1
            self._hit_nos = out
        return self._hit_nos[i]

    def _hits_ok(self, n, spec):
        var s = string_strip(spec)
        if string_startswith(s, ">="):
            return n >= int_or_zero_dbg(string_slice(s, 2, len(s)))
        if string_startswith(s, ">"):
            return n > int_or_zero_dbg(string_slice(s, 1, len(s)))
        if string_startswith(s, "%"):
            var m = int_or_zero_dbg(string_slice(s, 1, len(s)))
            return m > 0 and n % m == 0
        if string_startswith(s, "=="):
            s = string_slice(s, 2, len(s))
        return n == int_or_zero_dbg(s)

    # Recorded value (its printed form) of `name` at step i, or none.
    def _value_at(self, i, name):
        var ev = json_decode(self.raw[i])
        if ev == none or ev["v"] == none:
            return none
        var vars = ev["v"]
        if vars.has_key(name):
            return vars[name]
        return none

    def _cond_ok(self, i, cond):
        var ops = ["==", "!=", ">=", "<=", ">", "<"]
        var k = 0
        while k < len(ops):
            var at = string_find(cond, ops[k])
            if at > 0:
                var name = string_strip(string_slice(cond, 0, at))
                var lit = string_strip(string_slice(cond, at + len(ops[k]), len(cond)))
                var v = self._value_at(i, name)
                if v == none:
                    return false
                return self._compare(self._unquote(str(v)), ops[k], self._unquote(lit))
            k = k + 1
        var bare = self._value_at(i, string_strip(cond))
        if bare == none:
            return false
        var t = self._unquote(str(bare))
        return t != "" and t != "0" and t != "false" and t != "none" and t != "[]" and t != "{}"

    def _unquote(self, s):
        if len(s) >= 2:
            var a = string_slice(s, 0, 1)
            if (a == "\"" or a == "'") and string_slice(s, len(s) - 1, len(s)) == a:
                return string_slice(s, 1, len(s) - 1)
        return s

    def _compare(self, a, op, b):
        var na = to_number_dbg(a)
        var nb = to_number_dbg(b)
        if na != none and nb != none:
            if op == "==":
                return na == nb
            if op == "!=":
                return na != nb
            if op == ">=":
                return na >= nb
            if op == "<=":
                return na <= nb
            if op == ">":
                return na > nb
            return na < nb
        if op == "==":
            return a == b
        if op == "!=":
            return a != b
        if op == ">=":
            return a >= b
        if op == "<=":
            return a <= b
        if op == ">":
            return a > b
        return a < b

    def _interpolate(self, i, msg):
        var out = ""
        var k = 0
        while k < len(msg):
            var ch = string_slice(msg, k, k + 1)
            if ch == "{":
                var close = string_find(string_slice(msg, k, len(msg)), "}")
                if close > 0:
                    var name = string_strip(string_slice(msg, k + 1, k + close))
                    var v = self._value_at(i, name)
                    if v == none:
                        out = out + "?"
                    else:
                        out = out + str(v)
                    k = k + close + 1
                    continue
            out = out + ch
            k = k + 1
        return os_path_basename(self.file_at(i)) + ":" + str(self.lines[i]) + ": " + out

    def _next_break(self, frm, breaks):
        var i = frm + 1
        while i < self.n:
            if self._is_break(i, breaks):
                return i
            i = i + 1
        return -1

    def _prev_break(self, frm, breaks):
        var i = frm - 1
        while i >= 0:
            if self._is_break(i, breaks):
                return i
            i = i - 1
        return -1

    # Stepping past the end lands on the last recorded step (where an
    # uncaught exception was raised, if there was one), like Continue does.
    def _run_off_end(self):
        self.pos = self.n - 1
        self.state = "ended"
        return false

    def step_into(self):
        if self.pos + 1 < self.n:
            self.pos = self.pos + 1
            return true
        return self._run_off_end()

    def step_over(self):
        var d = self.depths[self.pos]
        var i = self.pos + 1
        while i < self.n:
            if self.depths[i] <= d:
                self.pos = i
                return true
            i = i + 1
        return self._run_off_end()

    def step_out(self):
        var d = self.depths[self.pos]
        var i = self.pos + 1
        while i < self.n:
            if self.depths[i] < d:
                self.pos = i
                return true
            i = i + 1
        return self._run_off_end()

    # Reverse Step Over: the previous step in this frame or an outer one.
    def step_back(self):
        if self.pos <= 0:
            return false
        var d = self.depths[self.pos]
        var i = self.pos - 1
        while i >= 0:
            if self.depths[i] <= d:
                self.pos = i
                self.state = "paused"
                return true
            i = i - 1
        self.pos = 0
        return true

    def continue_fwd(self, breaks):
        self.logging = true
        var hit = self._next_break(self.pos, breaks)
        self.logging = false
        if hit >= 0:
            self.pos = hit
            return true
        self.pos = self.n - 1
        self.state = "ended"
        return false

    def continue_back(self, breaks):
        var hit = self._prev_break(self.pos, breaks)
        if hit >= 0:
            self.pos = hit
            self.state = "paused"
            return true
        self.pos = 0
        self.state = "paused"
        return false

    def seek(self, i):
        if i < 0:
            i = 0
        if i >= self.n:
            i = self.n - 1
        self.pos = i
        self.state = "paused"

    def stop(self):
        self.active = false
        self.state = "idle"
        self.pos = -1


def int_or_zero_dbg(s):
    var t = string_strip(s)
    if t == "":
        return 0
    var i = 0
    while i < len(t):
        var ch = string_slice(t, i, i + 1)
        if not (ch >= "0" and ch <= "9") and not (i == 0 and ch == "-"):
            return 0
        i = i + 1
    return int(t)


# A number from a recorded value's text, or none.
def to_number_dbg(s):
    var t = string_strip(s)
    if t == "":
        return none
    var dots = 0
    var i = 0
    while i < len(t):
        var ch = string_slice(t, i, i + 1)
        if ch == ".":
            dots = dots + 1
        elif not (ch >= "0" and ch <= "9") and not (i == 0 and ch == "-"):
            return none
        i = i + 1
    if dots > 1 or t == "-" or t == ".":
        return none
    if dots == 1:
        return float(t)
    return int(t)
