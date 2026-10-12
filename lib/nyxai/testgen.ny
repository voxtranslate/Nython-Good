# nython: module    (import it by name: it runs in a module scope of its own)
# lib/nyxai/testgen.ny - writes a unittest module for a function: from its
# signature and defaults, its docstring's examples, and what it was observed
# to do on boundary and random inputs, run in a subprocess with a timeout
# (round 82).
#
#     from nyxai.facts import ProgramModel
#     from nyxai.testgen import TestGenerator
#     pm = ProgramModel(root); pm.add_file(root + "/mathx.ny")
#     tg = TestGenerator()
#     res = tg.generate(pm.find_function("clamp"))     # a TestGenResult
#     res.path, res.source                              # test_mathx_clamp.ny, its text
#     tg.run(res)                                       # [ok, output]: it runs and passes
#
# How the inputs are chosen:
#   - each parameter's domain comes from its annotation (int, float, str,
#     bool, list/dict/tuple/set, list[int]..., Optional[X] / X | None), else
#     its default's type, else by probing: the function is called with every
#     unannotated parameter an int, then a str, a list, a float, and the
#     first type that raises neither TypeError nor AttributeError is taken
#     (type probing, as Pynguin does for untyped Python - Lukasczyk, Kroiss &
#     Fraser 2020);
#   - boundary values of each domain (0, 1, -1, "", [], ...) are tried one
#     parameter at a time, the others at a typical value;
#   - the docstring's doctest examples (">>> f(2)" then "4") are run too;
#   - random inputs from the same domains (a seeded generator: the same
#     function gives the same tests) check properties after QuickCheck
#     (Claessen & Hughes, ICFP 2000): the function returns the same result
#     for the same arguments, and raises nothing but what its body (or a
#     boundary input) raises. A counterexample is shrunk to a minimal one, as
#     QuickCheck does, and reported.
# Every run happens in a child process (the interpreter, sys.executable) with
# a timeout, so a function that loops forever or exits cannot hang or end
# the agent. The observed outputs become assertEqual expectations (a value
# whose repr evaluates back to it), assertAlmostEqual (a float),
# assertRaises (an exception) or a type check (anything else) - tests that
# characterise what the code does now (Feathers' characterisation tests),
# runnable with `nython test_x.ny`, `nython -m unittest test_x` and, for a
# .py module, `python -m unittest test_x`.
#
# Not here: methods of classes whose constructor needs arguments, generators
# and async functions (reported as not testable), and inputs of user-defined
# types.

__all__ = ["TestGenerator", "TestGenResult", "domain_of", "doctest_examples"]

import os
import sys
import json
import subprocess

MARK = "@@NYX "

BOUNDARY = {
    "int": ["0", "1", "-1", "2", "10", "-7"],
    "float": ["0.0", "1.0", "-1.0", "0.5", "2.5", "-3.75"],
    "str": ["''", "'a'", "'abc'", "' '", "'Hello, World'", "'123'"],
    "bool": ["True", "False"],
    "list": ["[]", "[0]", "[1, 2, 3]", "[-1, 5, 2]"],
    "dict": ["{}", "{'a': 1}", "{'a': 1, 'b': 2}"],
    "tuple": ["()", "(1,)", "(1, 2)"],
    "set": ["set()", "{1, 2}"],
    "None": ["None"],
}
TYPICAL = {"int": "3", "float": "1.5", "str": "'abc'", "bool": "True", "list": "[1, 2, 3]",
           "dict": "{'a': 1}", "tuple": "(1, 2)", "set": "{1, 2}", "None": "None"}
PROBE_ORDER = ["int", "str", "list", "float"]


def _py_name(t):
    t = t.strip()
    low = {"List": "list", "Dict": "dict", "Tuple": "tuple", "Set": "set", "Sequence": "list",
           "Iterable": "list", "Mapping": "dict", "Text": "str", "string": "str", "Optional": "Optional"}
    return low.get(t, t)


def domain_of(annotation):
    """[kind, element kind or None, optional?] for an annotation's text."""
    if annotation is None:
        return None
    a = annotation.strip().strip("'\"")
    optional = False
    if " | " in a:
        parts = [p.strip() for p in a.split("|")]
        if "None" in parts:
            optional = True
            parts = [p for p in parts if p != "None"]
        a = parts[0] if len(parts) > 0 else "None"
    if a.startswith("Optional[") and a.endswith("]"):
        optional = True
        a = a[9:len(a) - 1]
    elem = None
    if "[" in a and a.endswith("]"):
        head = a[0:a.index("[")]
        inner = a[a.index("[") + 1:len(a) - 1]
        a = head
        e = _py_name(inner.split(",")[0])
        if e in BOUNDARY:
            elem = e
    a = _py_name(a)
    if a not in BOUNDARY:
        return None
    return [a, elem, optional]


def _kind_of_literal(src):
    s = src.strip()
    if s == "None" or s == "none":
        return "None"
    if s == "True" or s == "False" or s == "true" or s == "false":
        return "bool"
    if s.startswith("'") or s.startswith('"'):
        return "str"
    if s.startswith("["):
        return "list"
    if s.startswith("{"):
        return "dict"
    if s.startswith("("):
        return "tuple"
    t = s.lstrip("-+")
    if t != "" and t.replace("_", "").isdigit():
        return "int"
    if t != "" and t.replace(".", "", 1).replace("e", "", 1).replace("-", "").isdigit() and "." in t:
        return "float"
    return None


def _elem_values(kind, elem):
    if elem is None or kind not in ["list", "set", "tuple"]:
        return BOUNDARY[kind]
    vals = BOUNDARY[elem]
    out = []
    if kind == "list":
        out = ["[]", "[" + vals[1] + "]", "[" + ", ".join(vals[0:3]) + "]"]
    elif kind == "tuple":
        out = ["()", "(" + vals[1] + ",)", "(" + ", ".join(vals[0:2]) + ")"]
    else:
        out = ["set()", "{" + vals[1] + "}"]
    return out


def doctest_examples(doc):
    """[[source, expected output lines]] of a docstring's >>> examples."""
    out = []
    if doc is None:
        return out
    lines = doc.split("\n")
    i = 0
    while i < len(lines):
        t = lines[i].strip()
        if t.startswith(">>> "):
            src = t[4:]
            i += 1
            while i < len(lines) and lines[i].strip().startswith("... "):
                src = src + "\n" + lines[i].strip()[4:]
                i += 1
            want = []
            while i < len(lines):
                u = lines[i].strip()
                if u == "" or u.startswith(">>> "):
                    break
                want.append(u)
                i += 1
            out.append([src, want])
        else:
            i += 1
    return out


class _Rand:
    """A seeded linear congruential generator (same seed, same tests)."""
    def __init__(self, seed):
        self.s = seed % 2147483647
        if self.s <= 0:
            self.s += 2147483646

    def next(self):
        self.s = (self.s * 48271) % 2147483647
        return self.s

    def below(self, n):
        return self.next() % n

    def value(self, kind, elem):
        if kind == "int":
            r = self.below(10)
            if r == 0:
                return str(self.below(2000) - 1000)
            return str(self.below(41) - 20)
        if kind == "float":
            return repr((self.below(4001) - 2000) / 100.0)
        if kind == "bool":
            return "True" if self.below(2) == 0 else "False"
        if kind == "str":
            alpha = "abcXYZ 09-_."
            n = self.below(7)
            s = ""
            for _ in range(n):
                s = s + alpha[self.below(len(alpha))]
            return repr(s)
        if kind == "None":
            return "None"
        e = elem if elem is not None else "int"
        n = self.below(5)
        items = [self.value(e, None) for _ in range(n)]
        if kind == "list":
            return "[" + ", ".join(items) + "]"
        if kind == "tuple":
            if n == 1:
                return "(" + items[0] + ",)"
            return "(" + ", ".join(items) + ")"
        if kind == "set":
            if n == 0:
                return "set()"
            return "{" + ", ".join(items) + "}"
        if kind == "dict":
            return "{" + ", ".join(repr("k" + str(i)) + ": " + items[i] for i in range(n)) + "}"
        return "None"


# Smaller versions of a literal argument (QuickCheck's shrink: an int
# towards 0 by halving the distance - 0, v - v/2, v - v/4, ..., v - 1 - a
# string or list shorter, or with one element fewer). The same source runs
# in the child process that shrinks a counterexample, so it is kept as text
# and executed here too.
_SHRINK_SRC = """
def _shrink_cands(src):
    out = []
    try:
        v = eval(src)
    except Exception:
        return out
    if isinstance(v, bool) or v is None:
        return out
    if isinstance(v, int):
        if v != 0:
            out.append("0")
            d = abs(v) // 2
            while d > 0:
                out.append(str(v - d if v > 0 else v + d))
                d = d // 2
    elif isinstance(v, float):
        if v != 0.0:
            out.append("0.0")
            out.append(repr(float(int(v))))
            out.append(repr(v / 2))
    elif isinstance(v, str):
        if len(v) > 0:
            out.append("''")
            out.append(repr(v[0:len(v) // 2]))
            out.append(repr(v[1:]))
            out.append(repr(v[0:len(v) - 1]))
    elif isinstance(v, list):
        if len(v) > 0:
            out.append("[]")
            out.append(repr(v[0:len(v) // 2]))
            for i in range(len(v)):
                out.append(repr(v[0:i] + v[i + 1:]))
    elif isinstance(v, tuple):
        if len(v) > 0:
            out.append("()")
            out.append(repr(v[0:len(v) - 1]))
    elif isinstance(v, dict):
        if len(v) > 0:
            out.append("{}")
    res = []
    for c in out:
        if c != src and c not in res:
            res.append(c)
    return res
"""

_shrink_ns = {}
exec(_SHRINK_SRC, _shrink_ns)


def shrink_candidates(src):
    return _shrink_ns["_shrink_cands"](src)


class TestGenResult:
    def __init__(self, fn):
        self.function = fn
        self.qualname = fn.qualname if fn is not None else ""
        self.path = ""            # the test module written
        self.source = ""
        self.cases = []           # [{"call", "kind", "outcome", ...}]
        self.findings = []        # strings: counterexamples, hangs, wrong doc examples
        self.domains = {}         # parameter -> kind
        self.probe_runs = 0
        self.ok = False
        self.error = ""
        self.tests = 0

    def summary(self):
        if not self.ok:
            return "no tests for " + self.qualname + ": " + self.error
        return str(self.tests) + " tests for " + self.qualname + " in " + os.path.basename(self.path)


class TestGenerator:
    def __init__(self, exe=None, timeout=10.0, seed=1729, random_cases=24, engine_args=None):
        self.exe = exe if exe is not None else sys.executable
        self.timeout = timeout
        self.seed = seed
        self.random_cases = random_cases
        self.engine_args = engine_args if engine_args is not None else []
        self.max_restarts = 6
        self.ext = ".ny"

    # ── the probe: runs calls in a child process ─────────────────────────────
    # How a child or a generated test loads the module: by name for a .ny
    # file; a .py file by its path through importlib.util (Nython imports
    # .ny files by name, CPython .py files - this works under both).
    def _import_line(self, mod_dir, mod_name, alias):
        if self.ext == ".py":
            return ("import importlib.util as _ilu\n_spec = _ilu.spec_from_file_location(" + repr(mod_name) + ", " +
                    repr(os.path.join(mod_dir, mod_name + ".py")) + ")\n" + alias + " = _ilu.module_from_spec(_spec)\n" +
                    "_spec.loader.exec_module(" + alias + ")")
        return "import " + mod_name + " as " + alias

    def _probe_source(self, mod_dir, mod_name, target, cases_path, log_path):
        # The child imports the module, finds the function and runs each
        # case, logging {"start": id} before it and its outcome after (one
        # JSON line each, flushed), so a case that never returns costs only
        # itself. It is written in the subset Nython and Python share.
        return "\n".join([
            "import sys", "import json",
            "sys.path.insert(0, " + repr(mod_dir) + ")",
            self._import_line(mod_dir, mod_name, "_m"),
            "_parts = " + repr(target.split(".")),
            "_f = getattr(_m, _parts[0])",
            "if len(_parts) > 1:",
            "    _f = getattr(_f(), _parts[1])",
            "_ns = dict(vars(_m))",
            "with open(" + repr(cases_path) + ") as _fh:",
            "    _cases = json.loads(_fh.read())",
            "_log = open(" + repr(log_path) + ", 'a')",
            "def _lit(r):",
            "    try:",
            "        back = eval(repr(r))",
            "        return back == r and type(back) is type(r)",
            "    except Exception:",
            "        return False",
            "def _one(c):",
            "    if 'expr' in c:",
            "        return eval(c['expr'], _ns)",
            "    args = [eval(a) for a in c['args']]",
            "    return _f(*args)",
            "for _c in _cases:",
            "    _log.write(json.dumps({'start': _c['id']}) + '\\n')",
            "    _log.flush()",
            "    _out = {'id': _c['id']}",
            "    try:",
            "        _r = _one(_c)",
            "        _out['ok'] = True",
            "        _out['repr'] = repr(_r)",
            "        _out['type'] = type(_r).__name__",
            "        _out['literal'] = _lit(_r)",
            "        _out['float'] = isinstance(_r, float) and not isinstance(_r, bool)",
            "        try:",
            "            _out['det'] = repr(_one(_c)) == repr(_r)",
            "        except Exception:",
            "            _out['det'] = False",
            "    except BaseException as _e:",
            "        if isinstance(_e, SystemExit) or isinstance(_e, KeyboardInterrupt):",
            "            _out['ok'] = False",
            "            _out['exc'] = type(_e).__name__",
            "            _out['msg'] = 'exits'",
            "        else:",
            "            _out['ok'] = False",
            "            _out['exc'] = type(_e).__name__",
            "            _out['msg'] = str(_e)[0:200]",
            "    _log.write(json.dumps(_out) + '\\n')",
            "    _log.flush()",
            "_log.close()",
            ""])

    # A child that shrinks a counterexample: tries the smaller candidates of
    # each argument and keeps the first that still raises the same exception,
    # until none does (QuickCheck's greedy shrinking).
    def _shrink_source(self, mod_dir, mod_name, target, args, exc, max_steps):
        return "\n".join([
            "import sys", "import json",
            "sys.path.insert(0, " + repr(mod_dir) + ")",
            self._import_line(mod_dir, mod_name, "_m"),
            "_parts = " + repr(target.split(".")),
            "_f = getattr(_m, _parts[0])",
            "if len(_parts) > 1:",
            "    _f = getattr(_f(), _parts[1])",
            _SHRINK_SRC,
            "def _fails(a):",
            "    try:",
            "        _f(*[eval(x) for x in a])",
            "        return None",
            "    except Exception as e:",
            "        if type(e).__name__ == " + repr(exc) + ":",
            "            return str(e)[0:200]",
            "        return None",
            "_cur = " + repr(list(args)),
            "_msg = _fails(_cur)",
            "_steps = 0",
            "_more = _msg is not None",
            "while _more and _steps < " + str(max_steps) + ":",
            "    _more = False",
            "    for _i in range(len(_cur)):",
            "        for _c in _shrink_cands(_cur[_i]):",
            "            _a = list(_cur)",
            "            _a[_i] = _c",
            "            _m2 = _fails(_a)",
            "            if _m2 is not None:",
            "                _cur = _a",
            "                _msg = _m2",
            "                _steps = _steps + 1",
            "                _more = True",
            "                break",
            "        if _more:",
            "            break",
            "print(" + repr(MARK) + " + json.dumps({'id': 'shrink', 'args': _cur, 'ok': False, 'exc': " + repr(exc) + ", 'msg': _msg if _msg is not None else '', 'steps': _steps}))",
            ""])

    def _run_cases(self, work, mod_dir, mod_name, target, cases):
        """Runs cases in a child process; {id: outcome}. A case that does not
        return within the timeout is {"id", "hung": True}; the cases after it
        run in a fresh child."""
        out = {}
        todo = list(cases)
        restarts = 0
        slow_starts = 0
        extra = 1.0
        while len(todo) > 0 and restarts <= self.max_restarts:
            self._seq = getattr(self, "_seq", 0) + 1
            cp = os.path.join(work, "cases_" + str(self._seq) + ".json")
            pp = os.path.join(work, "probe_" + str(self._seq) + ".ny")
            lp = os.path.join(work, "log_" + str(self._seq) + ".jsonl")
            with open(cp, "w") as fh:
                fh.write(json.dumps(todo))
            with open(pp, "w") as fh:
                fh.write(self._probe_source(mod_dir, mod_name, target, cp, lp))
            self.runs += 1
            timed_out = False
            r = None
            try:
                r = subprocess.run([self.exe] + self.engine_args + [pp], capture_output=True, text=True,
                                   timeout=self.timeout * extra, cwd=mod_dir)
            except subprocess.TimeoutExpired:
                timed_out = True
            started = None
            if os.path.exists(lp):
                with open(lp) as fh:
                    for ln in fh.read().split("\n"):
                        if ln.strip() == "":
                            continue
                        try:
                            d = json.loads(ln)
                        except ValueError:
                            continue
                        if "start" in d:
                            started = d["start"]
                        else:
                            out[d["id"]] = d
                            started = None
            if not timed_out:
                if len(out) == 0 and r is not None and r.returncode != 0:
                    self.last_error = (r.stderr or r.stdout).strip().split("\n")[-1]
                break
            # no case running when time ran out: the child was slow to start
            # (a loaded machine) or to finish - the cases not done yet run
            # again, with twice the time
            if started is None:
                todo = [c for c in todo if c["id"] not in out]
                if slow_starts < 2:
                    slow_starts += 1
                    extra = extra * 2.0
                    continue
                break
            # the case that was running when time ran out
            out[started] = {"id": started, "hung": True}
            rest = []
            seen_hung = False
            for c in todo:
                if seen_hung:
                    rest.append(c)
                elif c["id"] == started:
                    seen_hung = True
            todo = rest
            restarts += 1
        return out

    # ── generation ───────────────────────────────────────────────────────────
    def generate(self, fn, out_dir=None, expected=None, write=True):
        """A unittest module for FunctionInfo fn; `expected` lists exception
        names the function is known to raise (its own and its callees')."""
        res = TestGenResult(fn)
        self.runs = 0
        self.last_error = ""
        if fn is None:
            res.error = "no such function"
            return res
        if fn.is_generator or fn.is_async:
            res.error = "generators and async functions are not supported"
            return res
        if fn.parent != "":
            res.error = "a nested function cannot be imported"
            return res
        kind = fn.kind()
        if kind == "property":
            res.error = "a property is not called"
            return res
        target = fn.name if fn.cls == "" else fn.cls + "." + fn.name
        mod = fn.module
        mod_dir = os.path.dirname(os.path.abspath(mod.path))
        mod_name = os.path.splitext(os.path.basename(mod.path))[0]
        ext = ".py" if mod.path.endswith(".py") else ".ny"
        self.ext = ext
        work = os.path.join(mod_dir, ".nyx_probe_" + str(os.getpid()))
        os.makedirs(work, exist_ok=True)
        try:
            self._generate(res, fn, target, mod_dir, mod_name, work, expected)
        finally:
            for f in os.listdir(work):
                try:
                    os.remove(os.path.join(work, f))
                except OSError:
                    pass
            try:
                os.rmdir(work)
            except OSError:
                pass
        res.probe_runs = self.runs
        if not res.ok:
            return res
        if out_dir is None:
            out_dir = mod_dir
        res.path = os.path.join(out_dir, "test_" + mod_name + "_" + fn.name.strip("_") + ext)
        res.source = self._render(res, fn, target, mod_dir, mod_name, out_dir)
        if write:
            with open(res.path, "w") as fh:
                fh.write(res.source)
        return res

    def _params(self, fn):
        ps = fn.explicit_params()
        if fn.kind() == "staticmethod":
            ps = fn.params
        return [p for p in ps if p.kind != "var_positional" and p.kind != "var_keyword"]

    def _generate(self, res, fn, target, mod_dir, mod_name, work, expected):
        params = self._params(fn)
        # required parameters are passed; defaulted ones get their default,
        # except when they are the one being varied
        doms = {}
        unknown = []
        for p in params:
            d = domain_of(p.annotation)
            if d is None and p.default is not None:
                k = _kind_of_literal(p.default)
                if k is not None and k != "None":
                    d = [k, None, False]
                elif k == "None":
                    d = None
            if d is None:
                unknown.append(p.name)
            else:
                doms[p.name] = d
        # type probing for the rest: one child process tries each type
        if len(unknown) > 0:
            cases = []
            for ti in range(len(PROBE_ORDER)):
                t = PROBE_ORDER[ti]
                args = []
                for p in params:
                    if p.name in unknown:
                        args.append(TYPICAL[t])
                    else:
                        args.append(self._typical(p, doms[p.name]))
                cases.append({"id": ti, "args": args})
            got = self._run_cases(work, mod_dir, mod_name, target, cases)
            if len(got) == 0:
                res.error = "the module could not be run: " + self.last_error
                return
            chosen = "int"
            for ti in range(len(PROBE_ORDER)):
                o = got.get(ti)
                if o is not None and (o.get("hung", False) or o["ok"] or o["exc"] not in ["TypeError", "AttributeError"]):
                    chosen = PROBE_ORDER[ti]
                    break
            for n in unknown:
                doms[n] = [chosen, None, False]
        for p in params:
            res.domains[p.name] = doms[p.name][0] + ("[" + doms[p.name][1] + "]" if doms[p.name][1] is not None else "") + (" | None" if doms[p.name][2] else "")
        # the cases: all typical, then each parameter over its boundary values
        cases = []
        seen = set()

        def add(kind, args, label):
            key = "(" + ", ".join(args) + ")"
            if key in seen:
                return
            seen.add(key)
            cases.append({"id": len(cases), "args": args, "kind": kind, "label": label})

        base = [self._typical(p, doms[p.name]) for p in params]
        add("typical", base, "typical values")
        for i in range(len(params)):
            p = params[i]
            d = doms[p.name]
            vals = list(_elem_values(d[0], d[1]))
            if d[2]:
                vals.append("None")
            if p.default is not None and p.default not in vals and _kind_of_literal(p.default) is not None:
                vals.insert(0, p.default)
            for v in vals:
                a = list(base)
                a[i] = v
                add("boundary", a, p.name + " = " + v)
        nb = len(cases)
        # docstring examples
        exs = doctest_examples(fn.doc)
        for e in exs:
            cases.append({"id": len(cases), "expr": e[0], "want": e[1], "kind": "example", "label": e[0]})
        # random cases for the properties
        rnd = _Rand(self.seed + len(fn.qualname) * 7919)
        for _ in range(self.random_cases):
            a = [rnd.value(doms[p.name][0], doms[p.name][1]) for p in params]
            add("random", a, "random")
        got = self._run_cases(work, mod_dir, mod_name, target, cases)
        if len(got) == 0:
            res.error = "the function could not be run: " + self.last_error
            return
        hung = []
        for c in cases:
            o = got.get(c["id"])
            if o is not None and o.get("hung", False):
                hung.append(c["id"])
                res.findings.append(self._call_text(fn, c) + " did not return within " + str(self.timeout) + "s")
        for k in hung:
            del got[k]
        allowed = set(expected if expected is not None else [])
        for r in fn.raises:
            if r[1] != "":
                allowed.add(r[1].split(".")[-1])
        for c in cases:
            o = got.get(c["id"])
            if o is None:
                continue
            c["outcome"] = o
            if c["kind"] == "boundary" or c["kind"] == "typical":
                if not o["ok"]:
                    allowed.add(o["exc"])
        # properties over the random cases
        counter = None
        for c in cases:
            o = c.get("outcome")
            if o is None or c["kind"] != "random":
                continue
            if o["ok"] and not o.get("det", True):
                res.findings.append(self._call_text(fn, c) + " gives different results for the same arguments")
            if not o["ok"] and o["exc"] not in allowed and counter is None:
                counter = c
        if counter is not None:
            small = self._shrink(work, mod_dir, mod_name, target, fn, counter)
            res.findings.append(self._call_text(fn, small) + " raises " + small["outcome"]["exc"] + ": " +
                                small["outcome"]["msg"] + "  (shrunk from " + self._call_text(fn, counter) + ")")
            small["kind"] = "counterexample"
            cases.append(small)
        # wrong docstring examples
        for c in cases:
            if c["kind"] != "example" or c.get("outcome") is None:
                continue
            o = c["outcome"]
            want = "\n".join(c["want"])
            if o["ok"] and want != "" and o["repr"] != want:
                res.findings.append("the docstring says " + c["expr"] + " gives " + want + ", it gives " + o["repr"])
        res.cases = cases
        res.ok = True

    def _shrink(self, work, mod_dir, mod_name, target, fn, case):
        exc = case["outcome"]["exc"]
        self._seq = getattr(self, "_seq", 0) + 1
        pp = os.path.join(work, "shrink_" + str(self._seq) + ".ny")
        with open(pp, "w") as fh:
            fh.write(self._shrink_source(mod_dir, mod_name, target, case["args"], exc, 400))
        self.runs += 1
        out = None
        try:
            r = subprocess.run([self.exe] + self.engine_args + [pp], capture_output=True, text=True,
                               timeout=self.timeout, cwd=mod_dir)
            for ln in r.stdout.split("\n"):
                if ln.startswith(MARK):
                    out = json.loads(ln[len(MARK):])
        except subprocess.TimeoutExpired:
            out = None
        if out is None or out["msg"] == "":
            return case
        return {"id": 100000 + len(case["args"]), "args": out["args"], "kind": "shrink", "label": "shrunk",
                "outcome": {"ok": False, "exc": exc, "msg": out["msg"]}, "steps": out["steps"]}

    def _typical(self, p, d):
        if p.default is not None and _kind_of_literal(p.default) is not None:
            return p.default
        if d[1] is not None and d[0] in ["list", "tuple", "set"]:
            return _elem_values(d[0], d[1])[2] if len(_elem_values(d[0], d[1])) > 2 else _elem_values(d[0], d[1])[-1]
        return TYPICAL[d[0]]

    def _call_text(self, fn, c):
        if "expr" in c:
            return c["expr"]
        return fn.name + "(" + ", ".join(c["args"]) + ")"

    # ── the test module ──────────────────────────────────────────────────────
    def _render(self, res, fn, target, mod_dir, mod_name, out_dir):
        cls = "Test" + "".join(p[0:1].upper() + p[1:] for p in fn.name.strip("_").split("_") if p != "")
        if fn.cls != "":
            cls = "Test" + fn.cls + cls[4:]
        imp_dir = os.path.relpath(mod_dir, out_dir) if out_dir != mod_dir else ""
        call = fn.name if fn.cls == "" else (fn.cls + "()." + fn.name if fn.kind() == "method" else fn.cls + "." + fn.name)
        L = []
        L.append("# Tests for " + fn.qualname + " (" + fn.rel + ":" + str(fn.line) + "), generated by NyxAI (lib/nyxai/testgen.ny).")
        L.append("# From its signature, its docstring's examples and what it did when run on")
        L.append("# boundary inputs: they pin down what the code does now. Review them.")
        dom = ", ".join(n + ": " + res.domains[n] for n in res.domains)
        if dom != "":
            L.append("# Parameter domains: " + dom)
        for f in res.findings:
            L.append("# Found: " + f)
        L.append("import os")
        L.append("import sys")
        L.append("import unittest")
        L.append("")
        if imp_dir == "":
            L.append("sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))")
        else:
            L.append("sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), " + repr(imp_dir) + "))")
        top = fn.name if fn.cls == "" else fn.cls
        if self.ext == ".py":
            # by path: Nython and CPython both run this (Nython imports a
            # module by name only from a .ny file)
            L.append("import importlib.util")
            L.append("_spec = importlib.util.spec_from_file_location(" + repr(mod_name) + ", os.path.join(sys.path[0], " + repr(mod_name + ".py") + "))")
            L.append(mod_name + " = importlib.util.module_from_spec(_spec)")
            L.append("_spec.loader.exec_module(" + mod_name + ")")
            L.append(top + " = " + mod_name + "." + top)
            if any(c["kind"] == "example" for c in res.cases):
                L.append("globals().update({k: v for k, v in vars(" + mod_name + ").items() if not k.startswith('_')})")
        else:
            L.append("from " + mod_name + " import " + top)
            if any(c["kind"] == "example" for c in res.cases):
                # the docstring's examples may name anything the module defines
                L.append("from " + mod_name + " import *")
        L.append("")
        L.append("")
        L.append("class " + cls + "(unittest.TestCase):")
        n = 0
        names = {}
        det = []
        for c in res.cases:
            o = c.get("outcome")
            if o is None:
                continue
            if c["kind"] == "random":
                if o["ok"] and o.get("det", False) and o["literal"] and len(det) < 5:
                    det.append(c)
                continue
            if c["kind"] == "shrink":
                continue
            expr = c["expr"] if "expr" in c else call + "(" + ", ".join(c["args"]) + ")"
            base = {"typical": "typical", "boundary": "boundary", "example": "doc_example",
                    "counterexample": "counterexample"}[c["kind"]]
            if c["kind"] == "boundary":
                base = "boundary_" + c["label"].split(" = ")[0]
            k = names.get(base, 0) + 1
            names[base] = k
            mname = "test_" + base + "_" + str(k)
            body = []
            if c["kind"] == "example":
                want = "\n".join(c["want"])
                if want.startswith("Traceback"):
                    last = c["want"][-1]
                    en = last.split(":")[0].strip().split(".")[-1]
                    body.append("with self.assertRaises(" + en + "):")
                    body.append("    " + expr)
                elif want == "":
                    body.append(expr)
                else:
                    body.append("self.assertEqual(repr(" + expr + "), " + repr(want) + ")")
            elif not o["ok"]:
                if o["msg"] == "exits":
                    continue
                body.append("with self.assertRaises(" + o["exc"] + "):")
                body.append("    " + expr)
            elif o["float"]:
                body.append("self.assertAlmostEqual(" + expr + ", " + o["repr"] + ", places=7)")
            elif o["literal"]:
                body.append("self.assertEqual(" + expr + ", " + o["repr"] + ")")
            else:
                body.append("self.assertEqual(type(" + expr + ").__name__, " + repr(o["type"]) + ")")
            L.append("    def " + mname + "(self):")
            if c["kind"] == "counterexample":
                L.append("        # shrunk counterexample: is raising " + o.get("exc", "") + " here intended?")
            for b in body:
                L.append("        " + b)
            L.append("")
            n += 1
        if len(det) > 0:
            L.append("    def test_property_deterministic(self):")
            L.append("        # the same arguments give the same result (random inputs, seed " + str(self.seed) + ")")
            L.append("        for args in [" + ", ".join("(" + ", ".join(c["args"]) + ("," if len(c["args"]) == 1 else "") + ")" for c in det) + "]:")
            L.append("            self.assertEqual(" + call + "(*args), " + call + "(*args))")
            L.append("")
            n += 1
        if n == 0:
            L.append("    def test_nothing_observed(self):")
            L.append("        pass")
            L.append("")
        L.append("")
        L.append("if __name__ == \"__main__\":")
        L.append("    unittest.main()")
        L.append("")
        res.tests = n
        return "\n".join(L)

    def run(self, res, use_m=False):
        """Runs a generated test module; [passed?, output]."""
        if res.path == "":
            return [False, res.error]
        d = os.path.dirname(res.path)
        if use_m:
            args = [self.exe] + self.engine_args + ["-m", "unittest", os.path.splitext(os.path.basename(res.path))[0]]
        else:
            args = [self.exe] + self.engine_args + [res.path]
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=max(self.timeout, 30.0), cwd=d)
        except subprocess.TimeoutExpired:
            return [False, "timed out"]
        text = (r.stdout or "") + (r.stderr or "")
        return [r.returncode == 0, text]
