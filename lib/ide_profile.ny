# ══════════════════════════════════════════════════════════════════════════════
#  lib/ide_profile.ny — the IDE's Profile view: a cProfile dump read back as a
#  sortable table, callers/callees, and a flame graph (round 81).
#
#  The IDE runs `nython -m cProfile --stacks -o OUT file.ny` (lib/cProfile.ny,
#  round 79) and loads OUT here. What dump_stats writes (lib/pstats.ny's
#  _dump): a first line "NYPSTATS 1", then one JSON array per function
#      [[file, line, name], primitive calls, calls, tottime, cumtime,
#       [[[caller file, line, name], [calls, primitive, tottime, cumtime]], ...]]
#  (builtins are ["~", 0, "<built-in method builtins.len>"]) and, with
#  --stacks, one {"cct": {"keys": [...], "nodes": [[parent, key, calls,
#  inline, total], ...]}} line - the calling context tree.
#
#    var p = ProfileData()
#    p.load(path)                  true when the dump was read
#    p.funcs[i]                    ProfFunc: file, line, name, nc, cc, tt, ct,
#                                  callers / callees ([[j, nc, cc, tt, ct]]),
#                                  label (pstats' "file:line(name)"), s_* strings
#    p.sort("tottime")             ncalls | tottime | percall | cumtime |
#                                  cumpercall | name; again flips the order;
#                                  p.order is the table's rows
#    p.callers_of(i), p.callees_of(i)   sorted by cumulative time
#    p.flame                       [[x0, x1, depth, func, seconds, calls]]
#                                  x as fractions of the whole run, root first
#    p.flame_exact                 true: from real stacks; false: derived
#    p.folded()                    Gregg's folded stacks ("a;b;c 1234" in us)
#
#  The flame graph (Gregg, "The Flame Graph", CACM 59(6), 2016) is drawn as
#  an icicle: the root at the top, each call path a bar as wide as its share
#  of the run, children sorted by name under their caller. From the calling
#  context tree it is exact (every bar is a real call path and its total
#  time). Without it - a dump made without --stacks - cProfile has only one
#  aggregate per caller->callee edge, and the graph is derived as gprof's
#  call graph is (Graham, Kessler & McKusick, "gprof: a Call Graph
#  Execution Profiler", SIGPLAN 1982): a function's subtree under each
#  caller is its whole subtree scaled by that edge's share of its cumulative
#  time, i.e. every call is assumed to cost the same whoever made it, and a
#  recursive edge folds into the call already on the path. Bars thinner
#  than 1/2000 of the run are left out.
# ══════════════════════════════════════════════════════════════════════════════


class ProfFunc:
    def __init__(self, file, line, name):
        self.file = file
        self.line = line
        self.name = name
        self.cc = 0
        self.nc = 0
        self.tt = 0.0
        self.ct = 0.0
        self.callers = []
        self.callees = []
        self.builtin = file == "~"
        self.label = ""
        self.short = ""
        self.color = 0
        self.s_calls = ""
        self.s_tt = ""
        self.s_pc = ""
        self.s_ct = ""
        self.s_pc2 = ""


def prof_fmt(x):
    return "%.3f" % x


def prof_std_string(file, line, name):
    # pstats' func_std_string
    if file == "~" and line == 0:
        if string_startswith(name, "<") and string_endswith(name, ">"):
            return "{" + string_slice(name, 1, len(name) - 1) + "}"
        return name
    return file + ":" + str(line) + "(" + name + ")"


class ProfileData:
    def __init__(self):
        self.reset()

    def reset(self):
        self.funcs = []
        self.index = {}
        self.order = []
        self.sort_key = "cumtime"
        self.sort_desc = true
        self.total_tt = 0.0
        self.total_calls = 0
        self.prim_calls = 0
        self.flame = []
        self.flame_tips = []
        self.flame_depth = 0
        self.flame_total = 0.0
        self.flame_exact = false
        self.cct = none
        self.error = ""
        self.path = ""
        self.summary = ""

    def _key(self, file, line, name):
        return file + "\x00" + str(line) + "\x00" + name

    def _func(self, k):
        var key = self._key(k[0], k[1], k[2])
        var i = self.index.get(key)
        if i == none:
            i = len(self.funcs)
            self.index[key] = i
            self.funcs.append(ProfFunc(k[0], k[1], k[2]))
        return i

    def load(self, path):
        self.reset()
        self.path = path
        var text = read_file(path)
        if text == none:
            self.error = "cannot read " + path
            return false
        return self.load_text(text)

    def load_text(self, text):
        var rows = string_split(text, "\n")
        if len(rows) == 0 or string_strip(rows[0]) != "NYPSTATS 1":
            self.error = "not a Nython profile dump (no NYPSTATS header)"
            return false
        var edges = []
        var i = 1
        while i < len(rows):
            var row = string_strip(rows[i])
            i = i + 1
            if row == "":
                continue
            var e = json_decode(row)
            if e == none:
                continue
            if type(e) == "map":
                if e.has_key("cct"):
                    self.cct = e["cct"]
                continue
            var fi = self._func(e[0])
            var f = self.funcs[fi]
            f.cc = e[1]
            f.nc = e[2]
            f.tt = e[3] * 1.0
            f.ct = e[4] * 1.0
            for c in e[5]:
                var v = c[1]
                edges.append([self._func(c[0]), fi, v[0], v[1], v[2] * 1.0, v[3] * 1.0])
        for ed in edges:
            # caller ed[0] -> callee ed[1]: (calls, primitive, tottime, cumtime)
            self.funcs[ed[1]].callers.append([ed[0], ed[2], ed[3], ed[4], ed[5]])
            self.funcs[ed[0]].callees.append([ed[1], ed[2], ed[3], ed[4], ed[5]])
        for f in self.funcs:
            self.total_tt = self.total_tt + f.tt
            self.total_calls = self.total_calls + f.nc
            self.prim_calls = self.prim_calls + f.cc
            f.label = prof_std_string(f.file, f.line, f.name)
            if f.builtin:
                f.short = f.label
            else:
                f.short = f.name + "  (" + os_path_basename(f.file) + ":" + str(f.line) + ")"
            f.s_calls = str(f.nc) if f.nc == f.cc else str(f.nc) + "/" + str(f.cc)
            f.s_tt = prof_fmt(f.tt)
            f.s_pc = prof_fmt(f.tt / f.nc) if f.nc > 0 else "-"
            f.s_ct = prof_fmt(f.ct)
            f.s_pc2 = prof_fmt(f.ct / f.cc) if f.cc > 0 else "-"
            var h = 0
            var k = 0
            var nm = f.name
            while k < len(nm):
                h = (h * 31 + ord(string_slice(nm, k, k + 1))) % 1000003
                k = k + 1
            f.color = h
        self.summary = str(self.total_calls) + " function calls"
        if self.prim_calls != self.total_calls:
            self.summary = self.summary + " (" + str(self.prim_calls) + " primitive calls)"
        self.summary = self.summary + " in " + prof_fmt(self.total_tt) + " seconds"
        self.sort_desc = true
        self.sort_key = ""
        self.sort("cumtime")
        self.build_flame()
        return true

    # ── the table ────────────────────────────────────────────────────────────
    def _sort_val(self, f, key):
        if key == "ncalls":
            return f.nc
        if key == "tottime":
            return f.tt
        if key == "percall":
            return f.tt / f.nc if f.nc > 0 else 0.0
        if key == "cumtime":
            return f.ct
        if key == "cumpercall":
            return f.ct / f.cc if f.cc > 0 else 0.0
        return f.label

    # The same key again flips the direction; a new one starts descending
    # (ascending for the name).
    def sort(self, key, desc=none):
        if desc != none:
            self.sort_desc = desc
        elif key == self.sort_key:
            self.sort_desc = not self.sort_desc
        else:
            self.sort_desc = key != "name"
        self.sort_key = key
        var vals = []
        var i = 0
        while i < len(self.funcs):
            vals.append([self._sort_val(self.funcs[i], key), self.funcs[i].label, i])
            i = i + 1
        vals = sorted(vals, key=lambda v: [v[0], v[1]], reverse=self.sort_desc)
        self.order = [v[2] for v in vals]

    def find(self, name):
        var i = 0
        while i < len(self.funcs):
            if self.funcs[i].name == name:
                return i
            i = i + 1
        return -1

    def callers_of(self, i):
        return sorted(self.funcs[i].callers, key=lambda c: c[4], reverse=true)

    def callees_of(self, i):
        return sorted(self.funcs[i].callees, key=lambda c: c[4], reverse=true)

    # ── the flame graph ──────────────────────────────────────────────────────
    def build_flame(self, max_depth=48, min_frac=0.0005):
        self.flame = []
        self.flame_depth = 0
        self.flame_total = 0.0
        if self.cct != none and len(self.cct.get("nodes", [])) > 1:
            self.flame_exact = true
            self._flame_cct(max_depth, min_frac)
        else:
            self.flame_exact = false
            self._flame_derived(max_depth, min_frac)
        var tips = []
        for n in self.flame:
            var f = self.funcs[n[3]]
            var pct = 0.0
            if self.flame_total > 0.0:
                pct = n[4] * 100.0 / self.flame_total
            var t = f.short + "  -  " + prof_fmt(n[4] * 1000.0) + " ms (" + ("%.1f" % pct) + "%)"
            if n[5] > 0:
                t = t + ", " + str(n[5]) + " call" + ("s" if n[5] != 1 else "")
            tips.append(t)
        self.flame_tips = tips

    def _flame_cct(self, max_depth, min_frac):
        var keys = self.cct["keys"]
        var nodes = self.cct["nodes"]
        var fidx = []
        for k in keys:
            fidx.append(self._func(k))
        var kids = []
        var i = 0
        while i < len(nodes):
            kids.append([])
            i = i + 1
        i = 1
        while i < len(nodes):
            kids[nodes[i][0]].append(i)
            i = i + 1
        var total = nodes[0][4] * 1.0
        if total <= 0.0:
            for c in kids[0]:
                total = total + nodes[c][4]
        self.flame_total = total
        if total <= 0.0:
            return
        var min_w = total * min_frac
        # depth first, each node's children by name
        var stack = [[0, 0.0, -1]]
        while len(stack) > 0:
            var top = stack.pop()
            var ni = top[0]
            var x = top[1]
            var depth = top[2]
            var w = nodes[ni][4] * 1.0
            if ni == 0:
                w = total
            else:
                self.flame.append([x / total, (x + w) / total, depth, fidx[nodes[ni][1]], w, nodes[ni][2]])
                if depth + 1 > self.flame_depth:
                    self.flame_depth = depth + 1
            if depth + 1 >= max_depth or len(self.flame) > 6000:
                continue
            var ch = sorted(kids[ni], key=lambda c: self.funcs[fidx[nodes[c][1]]].name)
            var cx = x
            var limit = x + w
            var todo = []
            for c in ch:
                var cw = nodes[c][4] * 1.0
                if cx + cw > limit:
                    cw = limit - cx
                if cw >= min_w:
                    todo.append([c, cx, depth + 1])
                cx = cx + cw
            var k = len(todo) - 1
            while k >= 0:
                stack.append(todo[k])
                k = k - 1

    def _flame_derived(self, max_depth, min_frac):
        var roots = []
        var total = 0.0
        var i = 0
        while i < len(self.funcs):
            if len(self.funcs[i].callers) == 0:
                roots.append(i)
                total = total + self.funcs[i].ct
            i = i + 1
        if total <= 0.0:
            total = self.total_tt
        self.flame_total = total
        if total <= 0.0:
            return
        roots = sorted(roots, key=lambda r: self.funcs[r].name)
        var x = 0.0
        for r in roots:
            var w = self.funcs[r].ct
            if w >= total * min_frac:
                self._derive(r, w, 0, x, {}, total, max_depth, total * min_frac)
            x = x + w

    def _derive(self, i, t, depth, x0, path, total, max_depth, min_w):
        self.flame.append([x0 / total, (x0 + t) / total, depth, i, t, 0])
        if depth + 1 > self.flame_depth:
            self.flame_depth = depth + 1
        var f = self.funcs[i]
        if depth + 1 >= max_depth or f.ct <= 0.0 or len(self.flame) > 6000:
            return
        var scale = t / f.ct
        path[i] = true
        var x = x0
        var ch = sorted(f.callees, key=lambda c: self.funcs[c[0]].name)
        for c in ch:
            if path.get(c[0]) != none:
                continue
            var w = c[4] * scale
            if x + w > x0 + t:
                w = x0 + t - x
            if w >= min_w:
                self._derive(c[0], w, depth + 1, x, path, total, max_depth, min_w)
            x = x + w
        path.remove(i)

    # Gregg's folded stacks (flamegraph.pl's input): "a;b;c N" per call path,
    # N its self time in microseconds; from the flame graph's bars.
    def folded(self):
        var out = []
        var path = []
        for n in self.flame:
            var d = n[2]
            while len(path) > d:
                path.pop()
            path.append(self.funcs[n[3]].name)
            var kids = 0.0
            for m in self.flame:
                if m[2] == d + 1 and m[0] >= n[0] and m[1] <= n[1]:
                    kids = kids + m[4]
            var own = n[4] - kids
            if own > 0.0:
                out.append(string_join(path, ";") + " " + str(int(own * 1000000.0 + 0.5)))
        return out

    # The bar at a fraction fx of the width and a depth, or -1.
    def flame_at(self, fx, depth):
        var i = 0
        while i < len(self.flame):
            var n = self.flame[i]
            if n[2] == depth and fx >= n[0] and fx < n[1]:
                return i
            i = i + 1
        return -1
