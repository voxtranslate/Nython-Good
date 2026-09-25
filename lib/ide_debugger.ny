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
        if not self._is_break(0, breaks):
            var hit = self._next_break(0, breaks)
            if hit >= 0:
                self.pos = hit
        return true

    def _is_break(self, i, breaks):
        return breaks.has_key(self.file_at(i) + ":" + str(self.lines[i]))

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

    def step_into(self):
        if self.pos + 1 < self.n:
            self.pos = self.pos + 1
            return true
        self.state = "ended"
        return false

    def step_over(self):
        var d = self.depths[self.pos]
        var i = self.pos + 1
        while i < self.n:
            if self.depths[i] <= d:
                self.pos = i
                return true
            i = i + 1
        self.state = "ended"
        return false

    def step_out(self):
        var d = self.depths[self.pos]
        var i = self.pos + 1
        while i < self.n:
            if self.depths[i] < d:
                self.pos = i
                return true
            i = i + 1
        self.state = "ended"
        return false

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
        var hit = self._next_break(self.pos, breaks)
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
