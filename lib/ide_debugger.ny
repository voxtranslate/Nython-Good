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
        # Why? questions (round 79): per-file text_defuse, decoded variables,
        # the call each step belongs to and each call's caller step
        self._defuse_cache = none
        self._vars_cache = none
        self._acts = none
        self._act_parent = []

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
        self._defuse_cache = none
        self._vars_cache = none
        self._acts = none
        self._act_parent = []
        self._hit_nos = none
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
        if ev == none or ev.get("v") == none:
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

    # ── Why? questions (round 79) ────────────────────────────────────────────
    # The Whyline (Ko & Myers, "Debugging Reinvented: Asking and Answering
    # Why and Why Not Questions about Program Output", ICSE 2008) answered
    # by dynamic backward slicing over the recording (Agrawal & Horgan,
    # "Dynamic Program Slicing", PLDI 1990; Korel & Laski 1988): a step
    # depends on the last earlier step of its own call that wrote a
    # variable it reads (data dependence), and on the last evaluation of
    # the predicate that decided whether it ran (control dependence, from
    # the program dependence graph of Ferrante, Ottenstein & Warren, 1987).
    # The static half - each line's read and write sets and its controlling
    # predicates - comes from the real parser (text_defuse); the dynamic
    # half from the recording.
    #
    # Approximations: a step "writes" x when its line's static write set
    # holds x or the recorded value of x differs at the next step of the
    # same call (heap and attribute writes are seen only through the
    # recorded variables' printed values: obj.f = v writes obj, xs.append(v)
    # writes xs); calls are told apart by depth and function name, so two
    # calls of one function from one statement merge; a parameter's value
    # is traced to the call's line in the caller (its argument expressions
    # are that line's reads); a global read inside a function is followed
    # in the module's steps.
    #
    #   why_value(name, at=None, limit=40)   why does `name` have the value
    #       it has at step `at` (the current step): the slice, depth first,
    #       as entries {step, file, line, fn, level, kind, var, value, text};
    #       kind "value" (the question), "data" (wrote the variable),
    #       "control" (the predicate it ran under), "call" (a parameter's
    #       call), "param", "note"
    #   why_not(file, line, at=None)   why did `line` not run (up to step
    #       `at`, the whole recording by default): the controlling
    #       predicates' last evaluations with the values they read and
    #       their outcome, or "never called" for a function nobody called;
    #       kind "never", "predicate", "exit", "note"
    #   defuse(file)   text_defuse of the file's source (cached)

    def defuse(self, file):
        if self._defuse_cache == none:
            self._defuse_cache = {}
        var d = self._defuse_cache.get(file)
        if d == none:
            var text = read_file(file)
            d = text_defuse(text) if text != none else []
            self._defuse_cache[file] = d
        return d

    def _du(self, file, line):
        var d = self.defuse(file)
        if line < 1 or line > len(d):
            return none
        return d[line - 1]

    def _vars_at(self, i):
        if self._vars_cache == none:
            self._vars_cache = {}
        var v = self._vars_cache.get(i)
        if v == none:
            var ev = json_decode(self.raw[i])
            v = ev.get("v") if ev != none else none
            if v == none:
                v = {}
            if len(self._vars_cache) > 4096:
                self._vars_cache = {}
            self._vars_cache[i] = v
        return v

    # The call each step belongs to: steps at one depth between a call and
    # its return; a change of function name at the same depth starts another.
    def _activations(self):
        if self._acts != none and len(self._acts) == self.n:
            return self._acts
        var acts = []
        var stack = []          # [depth, act id, fn] innermost last
        var next_id = 0
        var parent = []         # act id -> the caller's step before it began (-1)
        var i = 0
        while i < self.n:
            var d = self.depths[i]
            var fn = self._fn_of(i)
            while len(stack) > 0 and stack[-1][0] > d:
                stack.pop()
            if len(stack) > 0 and stack[-1][0] == d and stack[-1][2] == fn and not (i > 0 and self.depths[i - 1] > d and fn != "<module>" and self._starts_call(i)):
                acts.append(stack[-1][1])
            else:
                if len(stack) > 0 and stack[-1][0] == d:
                    stack.pop()
                var caller = -1
                var k = i - 1
                while k >= 0:
                    if self.depths[k] < d:
                        caller = k
                        break
                    k = k - 1
                stack.append([d, next_id, fn])
                parent.append(caller)
                acts.append(next_id)
                next_id = next_id + 1
            i = i + 1
        self._acts = acts
        self._act_parent = parent
        return acts

    # step i is the first statement of a new call of its function (its line
    # is the first statement of the function's body)
    def _starts_call(self, i):
        var du = self._du(self.file_at(i), self.lines[i])
        if du == none or du.get("func_line", 0) == 0:
            return false
        var first = self._first_body_line(self.file_at(i), du["func_line"])
        return first == self.lines[i]

    def _first_body_line(self, file, def_line):
        var d = self.defuse(file)
        var ln = def_line + 1
        while ln <= len(d):
            var e = d[ln - 1]
            if e != none and e.get("stmt") and e.get("func_line", 0) == def_line:
                return ln
            ln = ln + 1
        return -1

    # the step after i in the same call, or -1
    def _next_in_act(self, i):
        var acts = self._activations()
        var a = acts[i]
        var k = i + 1
        while k < self.n:
            if acts[k] == a:
                return k
            if self.depths[k] < self.depths[i]:
                return -1
            k = k + 1
        return -1

    def _writes(self, i, name):
        var du = self._du(self.file_at(i), self.lines[i])
        if du != none and name in du.get("writes", []):
            return true
        var nx = self._next_in_act(i)
        if nx < 0:
            return false
        var before = self._vars_at(i).get(name)
        var after = self._vars_at(nx).get(name)
        return after != none and after != before

    # the last step before i, in i's call, that wrote `name`; -1 if none
    def _producer(self, i, name):
        var acts = self._activations()
        var a = acts[i]
        var k = i - 1
        while k >= 0:
            if acts[k] == a and self._writes(k, name):
                return k
            k = k - 1
        return -1

    # the last step before i, in i's call, on line `line`
    def _last_eval(self, i, line):
        var acts = self._activations()
        var a = acts[i]
        var f = self.files[i]
        var k = i - 1
        while k >= 0:
            if acts[k] == a and self.lines[k] == line and self.files[k] == f:
                return k
            k = k - 1
        return -1

    def _src(self, i):
        var file = self.file_at(i)
        var text = read_file(file)
        if text == none:
            return ""
        var rows = string_split(text, "\n")
        var ln = self.lines[i]
        if ln < 1 or ln > len(rows):
            return ""
        return string_strip(rows[ln - 1])

    def _entry(self, i, level, kind, var_name, text):
        var e = {"step": i, "file": self.file_at(i), "line": self.lines[i], "fn": self._fn_of(i),
                 "level": level, "kind": kind, "var": var_name, "value": none, "text": text}
        if var_name != "" and i >= 0:
            var nx = self._next_in_act(i) if kind == "data" else i
            if nx >= 0:
                e["value"] = self._vars_at(nx).get(var_name)
        return e

    def why_value(self, name, at=none, limit=40):
        var out = []
        if self.n == 0:
            return out
        var i = self.pos if at == none else at
        if i < 0 or i >= self.n:
            i = self.n - 1
        var cur = self._vars_at(i).get(name)
        var q = self._entry(i, 0, "value", name, name + " = " + str(cur) + " at line " + str(self.lines[i]))
        q["value"] = cur
        out.append(q)
        var seen = {}
        self._why_data(i, name, 1, out, seen, limit)
        return out

    # why `name` read at step i has its value: its producer, recursively
    def _why_data(self, i, name, level, out, seen, limit):
        if len(out) >= limit:
            return
        var j = self._producer(i, name)
        if j < 0:
            self._why_param(i, name, level, out, seen, limit)
            return
        var key = str(j) + ":" + name
        if seen.get(key) != none:
            return
        seen[key] = true
        out.append(self._entry(j, level, "data", name, self._src(j)))
        self._why_step(j, level + 1, out, seen, limit)

    # why step j ran with what it read: its reads' producers and the
    # predicate it ran under
    def _why_step(self, j, level, out, seen, limit):
        if len(out) >= limit:
            return
        var du = self._du(self.file_at(j), self.lines[j])
        if du == none:
            return
        for r in du.get("reads", []):
            if self._vars_at(j).get(r) != none:
                self._why_data(j, r, level, out, seen, limit)
        var ctrl = du.get("ctrl", [])
        var branch = du.get("branch", [])
        if len(ctrl) > 0:
            var p = self._last_eval(j, ctrl[0])
            if p >= 0:
                var key = "c" + str(p)
                if seen.get(key) == none:
                    seen[key] = true
                    var how = branch[0] if len(branch) > 0 else ""
                    out.append(self._entry(p, level, "control", "", self._src(p) + "   (" + how + ")"))
                    self._why_step(p, level + 1, out, seen, limit)

    # `name` has no producer in its call: a parameter (from the call's line
    # in the caller) or a variable bound before the recording saw it
    def _why_param(self, i, name, level, out, seen, limit):
        var acts = self._activations()
        var a = acts[i]
        var caller = self._act_parent[a] if a < len(self._act_parent) else -1
        var du = self._du(self.file_at(i), self.lines[i])
        var fn = self._fn_of(i)
        if caller >= 0 and fn != "<module>":
            var key = "p" + str(caller) + ":" + name
            if seen.get(key) != none:
                return
            seen[key] = true
            out.append(self._entry(caller, level, "call", "", self._src(caller) + "   (" + name + " passed to " + fn + ")"))
            self._why_step(caller, level + 1, out, seen, limit)
            return
        out.append(self._entry(i, level, "note", name, name + " was not set by a recorded statement"))

    def why_not(self, file, line, at=none):
        var out = []
        var upto = self.n if at == none else min(self.n, at + 1)
        var du = self._du(file, line)
        if du == none or not du.get("stmt"):
            out.append({"step": -1, "file": file, "line": line, "fn": "", "level": 0, "kind": "note", "var": "",
                        "value": none, "text": "line " + str(line) + " is not the start of a statement"})
            return out
        # did it run?
        var k = 0
        while k < upto:
            if self.lines[k] == line and self.file_at(k) == file:
                out.append({"step": k, "file": file, "line": line, "fn": self._fn_of(k), "level": 0, "kind": "note", "var": "",
                            "value": none, "text": "line " + str(line) + " did run (step " + str(k) + ")"})
                return out
            k = k + 1
        out.append({"step": -1, "file": file, "line": line, "fn": du.get("func", ""), "level": 0, "kind": "question", "var": "",
                    "value": none, "text": "why didn't line " + str(line) + " run?"})
        var func = du.get("func", "")
        var fline = du.get("func_line", 0)
        if fline > 0:
            var called = -1
            k = 0
            while k < upto:
                if self.file_at(k) == file and self._fn_of(k) == func:
                    var e2 = self._du(file, self.lines[k])
                    if e2 != none and e2.get("func_line", 0) == fline:
                        called = k
                        break
                k = k + 1
            if called < 0:
                out.append({"step": -1, "file": file, "line": fline, "fn": func, "level": 1, "kind": "never", "var": "",
                            "value": none, "text": func + "() was never called"})
                return out
        var ctrl = du.get("ctrl", [])
        var branch = du.get("branch", [])
        # outermost first: the first predicate that never chose L's branch
        var c = len(ctrl) - 1
        while c >= 0:
            var p = ctrl[c]
            var how = branch[c] if c < len(branch) else ""
            var evals = []
            k = 0
            while k < upto:
                if self.lines[k] == p and self.file_at(k) == file:
                    evals.append(k)
                k = k + 1
            if len(evals) == 0:
                out.append({"step": -1, "file": file, "line": p, "fn": func, "level": 1, "kind": "never", "var": "",
                            "value": none, "text": "line " + str(p) + " never ran either"})
                return out
            var taken = false
            for s in evals:
                var nx = self._next_in_act(s)
                if nx >= 0 and nx < upto:
                    var e3 = self._du(file, self.lines[nx])
                    if e3 != none and self._ctrl_has(e3, p, how):
                        taken = true
            if not taken:
                var last = evals[-1]
                var reads = self._du(file, p).get("reads", [])
                var vals = []
                var vv = self._vars_at(last)
                for r in reads:
                    if vv.get(r) != none:
                        vals.append(r + " = " + str(vv[r]))
                var outcome = "false" if how == "then" or how == "body" or how == "case" else "true"
                if how == "except":
                    outcome = "no matching exception"
                if how == "loop-else":
                    outcome = "the loop was left by break"
                var txt = self._src(last) + "   was " + outcome + " each of " + str(len(evals)) + " time" + ("s" if len(evals) != 1 else "")
                if len(vals) > 0:
                    txt = txt + " (last: " + string_join(vals, ", ") + ")"
                out.append({"step": last, "file": file, "line": p, "fn": self._fn_of(last), "level": 1, "kind": "predicate",
                            "var": "", "value": outcome, "text": txt})
                for s in evals[:-1][-4:]:
                    out.append({"step": s, "file": file, "line": p, "fn": self._fn_of(s), "level": 2, "kind": "predicate",
                                "var": "", "value": outcome, "text": "earlier evaluation"})
                return out
            c = c - 1
        # every predicate chose L's way at least once: execution left the
        # block before reaching L (break / return / an exception)
        var last_in = -1
        k = 0
        while k < upto:
            if self.file_at(k) == file:
                var e4 = self._du(file, self.lines[k])
                if e4 != none and e4.get("func", "") == func and self._same_block(e4, du) and self.lines[k] < line:
                    last_in = k
            k = k + 1
        if last_in >= 0:
            out.append({"step": last_in, "file": file, "line": self.lines[last_in], "fn": self._fn_of(last_in), "level": 1,
                        "kind": "exit", "var": "", "value": none,
                        "text": self._src(last_in) + "   ran last before line " + str(line) + " (execution left the block)"})
        else:
            out.append({"step": -1, "file": file, "line": line, "fn": func, "level": 1, "kind": "note", "var": "", "value": none,
                        "text": "execution never reached line " + str(line)})
        if self.exception != "":
            out.append({"step": self.n - 1, "file": self.file_at(self.n - 1), "line": self.lines[self.n - 1],
                        "fn": self._fn_of(self.n - 1), "level": 1, "kind": "exit", "var": "", "value": none,
                        "text": "the program ended with " + self.exception})
        return out

    def _ctrl_has(self, du, p, how):
        var ctrl = du.get("ctrl", [])
        var br = du.get("branch", [])
        var i = 0
        while i < len(ctrl):
            if ctrl[i] == p and (i >= len(br) or br[i] == how):
                return true
            i = i + 1
        return false

    def _same_block(self, a, b):
        return a.get("ctrl", []) == b.get("ctrl", [])


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
