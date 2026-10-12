# nython: module    (import it by name: it runs in a module scope of its own)
# lib/nyxai/facts.ny - a program model of a workspace from the real parser:
# per-function facts, the call graph and the import graph (round 82).
#
#     from nyxai.facts import ProgramModel
#     pm = ProgramModel("/path/to/workspace")
#     pm.add_file("/path/to/workspace/app.ny")       # or pm.scan()
#     f = pm.find("clamp")[0]                         # a FunctionInfo
#     f.signature()                                   # "clamp(x, lo=0, hi=10)"
#     f.raises, f.calls, f.complexity, f.globals_read
#     pm.callees(f), pm.callers(f)                    # resolved FunctionInfos
#     pm.import_graph()                               # {"app.ny": ["util.ny"], ...}
#
# The facts come from the native ny_facts(source) (src/builtins/text.cpp),
# which walks the AST the engines run: parameters with their kinds, defaults
# and annotations, returns, raises, calls, names read and written, `global`
# and `nonlocal`, except clauses, McCabe's cyclomatic complexity (McCabe,
# IEEE TSE 1976) and whether control can fall off the end. This module
# resolves names across files: a call "helper" is the function of that name
# in the same module, else the one a `from m import helper` brought in, else
# the only one so named in the workspace; "self.m" is the method m of the
# enclosing class or of a base class defined in the workspace; "mod.f" is f
# in the module `import mod` named; calling a class is calling its __init__.
#
# Not here: types (no inference beyond annotations and defaults), calls
# through variables holding functions, and dynamic imports.

__all__ = ["ProgramModel", "FunctionInfo", "ClassInfo", "ModuleInfo", "parse_facts",
           "PY_BUILTINS", "module_name_of"]

import os

# Python's builtin names (functions, types, constants, exceptions): what a
# name read from no module scope refers to, and what an assignment shadows.
PY_BUILTINS = set([
    "abs", "aiter", "all", "anext", "any", "ascii", "bin", "bool", "breakpoint", "bytearray", "bytes",
    "callable", "chr", "classmethod", "compile", "complex", "delattr", "dict", "dir", "divmod",
    "enumerate", "eval", "exec", "filter", "float", "format", "frozenset", "getattr", "globals",
    "hasattr", "hash", "help", "hex", "id", "input", "int", "isinstance", "issubclass", "iter", "len",
    "list", "locals", "map", "max", "memoryview", "min", "next", "object", "oct", "open", "ord", "pow",
    "print", "property", "range", "repr", "reversed", "round", "set", "setattr", "slice", "sorted",
    "staticmethod", "str", "sum", "super", "tuple", "type", "vars", "zip", "__import__",
    "True", "False", "None", "NotImplemented", "Ellipsis", "__name__", "__file__", "__doc__",
    "BaseException", "Exception", "ArithmeticError", "AssertionError", "AttributeError",
    "EOFError", "FloatingPointError", "GeneratorExit", "ImportError", "ModuleNotFoundError",
    "IndexError", "KeyError", "KeyboardInterrupt", "LookupError", "MemoryError", "NameError",
    "NotImplementedError", "OSError", "OverflowError", "RecursionError", "ReferenceError",
    "RuntimeError", "StopIteration", "StopAsyncIteration", "SyntaxError", "SystemError",
    "SystemExit", "TypeError", "UnboundLocalError", "UnicodeError", "UnicodeDecodeError",
    "UnicodeEncodeError", "ValueError", "ZeroDivisionError", "FileNotFoundError",
    "FileExistsError", "IsADirectoryError", "NotADirectoryError", "PermissionError",
    "TimeoutError", "ConnectionError", "BrokenPipeError", "LookupError", "Warning",
    "UserWarning", "DeprecationWarning", "RuntimeWarning", "ExceptionGroup",
    # Nython's spellings
    "true", "false", "none", "undefined", "self",
])

# The builtin exceptions' bases (CPython's hierarchy), for "does an except
# clause catch what this raises".
EXC_BASES = {
    "Exception": "BaseException", "KeyboardInterrupt": "BaseException", "SystemExit": "BaseException",
    "GeneratorExit": "BaseException", "ArithmeticError": "Exception", "ZeroDivisionError": "ArithmeticError",
    "OverflowError": "ArithmeticError", "FloatingPointError": "ArithmeticError", "AssertionError": "Exception",
    "AttributeError": "Exception", "EOFError": "Exception", "ImportError": "Exception",
    "ModuleNotFoundError": "ImportError", "LookupError": "Exception", "IndexError": "LookupError",
    "KeyError": "LookupError", "MemoryError": "Exception", "NameError": "Exception",
    "UnboundLocalError": "NameError", "OSError": "Exception", "FileNotFoundError": "OSError",
    "FileExistsError": "OSError", "IsADirectoryError": "OSError", "NotADirectoryError": "OSError",
    "PermissionError": "OSError", "TimeoutError": "OSError", "ConnectionError": "OSError",
    "BrokenPipeError": "ConnectionError", "RuntimeError": "Exception", "RecursionError": "RuntimeError",
    "NotImplementedError": "RuntimeError", "StopIteration": "Exception", "SyntaxError": "Exception",
    "TypeError": "Exception", "ValueError": "Exception", "UnicodeError": "ValueError",
    "UnicodeDecodeError": "UnicodeError", "UnicodeEncodeError": "UnicodeError", "Warning": "Exception",
    "UserWarning": "Warning", "DeprecationWarning": "Warning", "RuntimeWarning": "Warning",
}

# Calls that reach outside the program (for "pure").
IO_CALLS = set(["print", "open", "input", "read_file", "write_file", "os.remove", "os.system",
                "os_exec", "os_run", "os_remove", "subprocess.run", "socket", "http_get",
                "append_text", "sys.stdout.write", "sys.stderr.write", "time.sleep", "random",
                "random.random", "random.randint", "random.choice", "time.time", "time_now"])


def parse_facts(source):
    """The native facts of a source text (ny_facts), a dict."""
    return ny_facts(source)


def module_name_of(rel):
    """"src/util.ny" -> "src.util" (a package's __init__ is the package)."""
    r = rel.replace("\\", "/")
    for ext in [".ny", ".py", ".nyx"]:
        if r.endswith(ext):
            r = r[0:len(r) - len(ext)]
            break
    if r.endswith("/__init__"):
        r = r[0:len(r) - 9]
    return r.replace("/", ".")


class ParamInfo:
    def __init__(self, d):
        self.name = d["name"]
        self.kind = d["kind"]
        self.default = d["default"]
        self.default_kind = d["default_kind"]
        self.annotation = d["annotation"]

    def has_default(self):
        return self.default is not None

    def text(self):
        s = self.name
        if self.kind == "var_positional":
            s = "*" + s
        elif self.kind == "var_keyword":
            s = "**" + s
        if self.annotation is not None:
            s = s + ": " + self.annotation
        if self.default is not None:
            if self.annotation is not None:
                s = s + " = " + self.default
            else:
                s = s + "=" + self.default
        return s


class FunctionInfo:
    def __init__(self, d, mod):
        self.module = mod
        self.file = mod.path
        self.rel = mod.rel
        self.name = d["name"]
        self.qualname = d["qualname"]
        self.cls = d["class"]
        self.parent = d["parent"]
        self.line = d["line"]
        self.first = d["first"]
        self.end = d["end"]
        self.decorators = d["decorators"]
        self.is_async = d["is_async"]
        self.is_generator = d["is_generator"]
        self.doc = d["doc"]
        self.doc_line = d["doc_line"]
        self.params = [ParamInfo(p) for p in d["params"]]
        self.return_annotation = d["return_annotation"]
        self.returns = d["returns"]
        self.raises = d["raises"]
        self.calls = d["calls"]
        self.reads = d["reads"]
        self.writes = d["writes"]
        self.globals = d["globals"]
        self.nonlocals = d["nonlocals"]
        self.excepts = d["excepts"]
        self.complexity = d["complexity"]
        self.end_reachable = d["end_reachable"]
        self.globals_read = []
        self.globals_written = []
        self.key = mod.rel + "::" + self.qualname

    def is_method(self):
        return self.cls != ""

    def kind(self):
        if self.cls != "":
            if "staticmethod" in self.decorators:
                return "staticmethod"
            if "classmethod" in self.decorators:
                return "classmethod"
            if "property" in self.decorators:
                return "property"
            return "method"
        if self.parent != "":
            return "nested function"
        return "function"

    def explicit_params(self):
        """The parameters a caller passes (a method's self/cls left out)."""
        ps = self.params
        k = self.kind()
        if (k == "method" or k == "classmethod" or k == "property") and len(ps) > 0 and ps[0].kind != "var_positional":
            return ps[1:]
        return ps

    def signature(self):
        out = self.name + "(" + ", ".join(p.text() for p in self.params) + ")"
        if self.return_annotation is not None:
            out = out + " -> " + self.return_annotation
        return out

    def local_names(self):
        s = set(self.writes)
        for p in self.params:
            s.add(p.name)
        return s

    def where(self):
        return self.rel + ":" + str(self.line)

    def doc_summary(self):
        if self.doc is None:
            return ""
        for ln in self.doc.split("\n"):
            t = ln.strip()
            if t != "":
                return t
        return ""

    def __repr__(self):
        return "<FunctionInfo " + self.key + ">"


class ClassInfo:
    def __init__(self, d, mod):
        self.module = mod
        self.file = mod.path
        self.rel = mod.rel
        self.name = d["name"]
        self.qualname = d["qualname"]
        self.line = d["line"]
        self.end = d["end"]
        self.bases = d["bases"]
        self.doc = d["doc"]
        self.methods = d["methods"]
        self.decorators = d["decorators"]
        self.key = mod.rel + "::" + self.qualname

    def where(self):
        return self.rel + ":" + str(self.line)

    def __repr__(self):
        return "<ClassInfo " + self.key + ">"


class ModuleInfo:
    def __init__(self, path, rel, text):
        self.path = path
        self.rel = rel
        self.name = module_name_of(rel)
        self.short = self.name.split(".")[-1]
        self.text = text
        self.lines = text.split("\n")
        d = parse_facts(text)
        self.raw = d
        self.error = d["error"]
        self.doc = d["doc"]
        self.top = FunctionInfo(d["module"], self)
        self.functions = [FunctionInfo(f, self) for f in d["functions"]]
        self.classes = [ClassInfo(c, self) for c in d["classes"]]
        self.imports = d["imports"]
        self.unreachable = d["unreachable"]
        self.bare_excepts = d["bare_excepts"]
        self.none_compares = d["none_compares"]
        # module-level names: what a function's free reads refer to
        self.defined = set(self.top.writes)
        # name -> (module name it comes from, the name there or "" for the module)
        self.imported = {}
        for im in self.imports:
            if im["quoted"]:
                continue
            mod = im["module"]
            if len(im["names"]) > 0:
                for n in im["names"]:
                    src = n
                    as_ = n
                    if " as " in n:
                        parts = n.split(" as ")
                        src = parts[0].strip()
                        as_ = parts[1].strip()
                    if src != "*":
                        self.imported[as_] = [mod, src]
            elif im["alias"] != "":
                self.imported[im["alias"]] = [mod, ""]
            else:
                self.imported[mod.split(".")[0]] = [mod.split(".")[0], ""]
        for f in self.functions:
            loc = f.local_names()
            gr = []
            for n in f.reads:
                if n in f.globals or (n not in loc and n in self.defined):
                    gr.append(n)
            f.globals_read = sorted(gr)
            gw = []
            for n in f.writes:
                if n in f.globals:
                    gw.append(n)
            f.globals_written = sorted(gw)

    def function_at(self, line):
        """The innermost function whose lines hold `line` (None at module level)."""
        best = None
        for f in self.functions:
            if f.first <= line and line <= f.end:
                if best is None or f.first >= best.first:
                    best = f
        return best


class ProgramModel:
    def __init__(self, root=""):
        self.root = root
        self.modules = {}            # rel -> ModuleInfo
        self._dirty = True
        self._edges = {}
        self._redges = {}
        self._fid_dup = None

    # ── files ────────────────────────────────────────────────────────────────
    def rel_of(self, path):
        base = self.root.rstrip("/").rstrip("\\")
        if self.root != "" and (path.startswith(base + "/") or path.startswith(base + "\\")):
            r = path[len(base):]
            while r.startswith("/") or r.startswith("\\"):
                r = r[1:]
            return r
        if self.root == "":
            return path.replace("\\", "/")
        return os.path.basename(path)

    def add_file(self, path, text=None):
        if text is None:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        rel = self.rel_of(path)
        m = ModuleInfo(path, rel, text)
        self.modules[rel] = m
        self._dirty = True
        self._fid_dup = None
        return m

    def update_file(self, path, text=None):
        if not os.path.exists(path) and text is None:
            return self.remove_file(path)
        return self.add_file(path, text)

    def remove_file(self, path):
        rel = self.rel_of(path)
        if rel in self.modules:
            del self.modules[rel]
            self._dirty = True
            self._fid_dup = None
            return True
        return False

    def scan(self, exts=None, max_files=5000):
        if exts is None:
            exts = [".ny", ".py"]
        n = 0
        for rel in fs_list_files(self.root, max_files, [".git", "node_modules", "build", "__pycache__", ".nython"]):
            if any(rel.endswith(e) for e in exts):
                try:
                    self.add_file(os.path.join(self.root, rel))
                    n += 1
                except OSError:
                    pass
        return n

    # ── lookup ───────────────────────────────────────────────────────────────
    def functions(self):
        out = []
        for rel in sorted(self.modules):
            out.extend(self.modules[rel].functions)
        return out

    def classes(self):
        out = []
        for rel in sorted(self.modules):
            out.extend(self.modules[rel].classes)
        return out

    def module_named(self, name):
        """A workspace module by import name ("util", "src.util", "pkg.mod")."""
        best = None
        for rel in sorted(self.modules):
            m = self.modules[rel]
            if m.name == name:
                return m
            if best is None and (m.short == name or m.name.endswith("." + name)):
                best = m
        return best

    def find(self, symbol):
        """Functions and classes named `symbol`: "f", "C", "C.m", "mod.f" or
        "file.ny:f"; definitions first, in file order."""
        sym = symbol.strip()
        rel = None
        if ":" in sym:
            parts = sym.split(":")
            rel = parts[0]
            sym = parts[1]
        out = []
        for f in self.functions():
            if rel is not None and f.rel != rel and not f.rel.endswith("/" + rel):
                continue
            if f.qualname == sym or f.name == sym or (f.module.short + "." + f.qualname) == sym or (f.module.name + "." + f.qualname) == sym:
                out.append(f)
        for c in self.classes():
            if rel is not None and c.rel != rel and not c.rel.endswith("/" + rel):
                continue
            if c.qualname == sym or c.name == sym or (c.module.short + "." + c.qualname) == sym:
                out.append(c)
        return out

    def find_function(self, symbol):
        for x in self.find(symbol):
            if isinstance(x, FunctionInfo):
                return x
        # a class: its __init__
        for x in self.find(symbol):
            if isinstance(x, ClassInfo):
                for f in x.module.functions:
                    if f.cls == x.name and f.name == "__init__":
                        return f
        return None

    def function_by_key(self, key):
        parts = key.split("::")
        m = self.modules.get(parts[0])
        if m is None:
            return None
        for f in m.functions:
            if f.qualname == parts[1]:
                return f
        return None

    def class_of(self, mod, name):
        for c in mod.classes:
            if c.name == name:
                return c
        for c in self.classes():
            if c.name == name:
                return c
        return None

    def _method(self, cls, name, depth=0):
        """The method `name` of class info cls or of a base defined in the workspace."""
        if cls is None or depth > 20:
            return None
        for f in cls.module.functions:
            if f.cls == cls.name and f.name == name and f.parent == "":
                return f
        for b in cls.bases:
            bc = self.class_of(cls.module, b.split(".")[-1])
            if bc is not None and bc is not cls:
                r = self._method(bc, name, depth + 1)
                if r is not None:
                    return r
        return None

    # ── resolution ───────────────────────────────────────────────────────────
    def resolve_call(self, f, callee):
        """The FunctionInfo a call `callee` (its text) inside f (a FunctionInfo
        or a module's top) runs, or None (a builtin, a library function, or
        something dynamic)."""
        m = f.module
        if "(" in callee:
            return None
        parts = callee.split(".")
        if len(parts) == 1:
            name = parts[0]
            # a nested function of f's own, then the module's, then imports
            for g in m.functions:
                if g.name == name and g.parent == f.qualname and f.qualname != "<module>":
                    return g
            for g in m.functions:
                if g.name == name and g.parent == "" and g.cls == "":
                    return g
            c = self.class_of(m, name) if name in m.defined else None
            if c is not None and c.module is m:
                return self._method(c, "__init__")
            imp = m.imported.get(name)
            if imp is not None and imp[1] != "":
                tm = self.module_named(imp[0])
                if tm is not None:
                    for g in tm.functions:
                        if g.name == imp[1] and g.parent == "" and g.cls == "":
                            return g
                    tc = self.class_of(tm, imp[1])
                    if tc is not None:
                        return self._method(tc, "__init__")
            if name in PY_BUILTINS:
                return None
            # the only function so named anywhere
            cands = [g for g in self.functions() if g.name == name and g.parent == "" and g.cls == ""]
            if len(cands) == 1:
                return cands[0]
            return None
        head = parts[0]
        last = parts[-1]
        if (head == "self" or head == "cls") and len(parts) == 2 and f.cls != "":
            return self._method(self.class_of(m, f.cls), last)
        if head == "super" and f.cls != "":
            c = self.class_of(m, f.cls)
            if c is not None:
                for b in c.bases:
                    r = self._method(self.class_of(m, b.split(".")[-1]), last)
                    if r is not None:
                        return r
            return None
        imp = m.imported.get(head)
        if imp is not None and imp[1] == "" and len(parts) == 2:
            tm = self.module_named(imp[0])
            if tm is not None:
                for g in tm.functions:
                    if g.name == last and g.parent == "" and g.cls == "":
                        return g
                tc = self.class_of(tm, last)
                if tc is not None:
                    return self._method(tc, "__init__")
            return None
        if len(parts) == 2:
            c = self.class_of(m, head)
            if c is not None:
                return self._method(c, last)
        return None

    def _build(self):
        if not self._dirty:
            return
        self._edges = {}
        self._redges = {}
        for rel in sorted(self.modules):
            m = self.modules[rel]
            for f in [m.top] + m.functions:
                outs = []
                for c in f.calls:
                    g = self.resolve_call(f, c[1])
                    if g is not None and g.key not in outs:
                        outs.append(g.key)
                self._edges[f.key] = outs
                for k in outs:
                    lst = self._redges.get(k)
                    if lst is None:
                        lst = []
                        self._redges[k] = lst
                    if f.key not in lst:
                        lst.append(f.key)
        self._dirty = False

    def _info(self, key):
        parts = key.split("::")
        m = self.modules.get(parts[0])
        if m is None:
            return None
        if parts[1] == "<module>":
            return m.top
        for f in m.functions:
            if f.qualname == parts[1]:
                return f
        return None

    def call_graph(self):
        """{caller key: [callee keys]} over the workspace ("rel::qualname";
        a module's top-level code is "rel::<module>")."""
        self._build()
        return self._edges

    def callees(self, f):
        self._build()
        return [self._info(k) for k in self._edges.get(f.key, [])]

    def callers(self, f):
        self._build()
        return [self._info(k) for k in self._redges.get(f.key, [])]

    def import_graph(self):
        """{rel: [rels of the workspace modules it imports]} (a quoted import
        "lib/x.ny" is matched by path)."""
        out = {}
        for rel in sorted(self.modules):
            m = self.modules[rel]
            deps = []
            for im in m.imports:
                t = None
                if im["quoted"]:
                    target = im["module"]
                    for r2 in self.modules:
                        if r2 == target or r2.endswith("/" + target) or target.endswith("/" + r2):
                            t = self.modules[r2]
                else:
                    t = self.module_named(im["module"])
                    if t is None and len(im["names"]) > 0:
                        # from pkg import mod
                        for n in im["names"]:
                            t2 = self.module_named(im["module"] + "." + n.split(" as ")[0].strip())
                            if t2 is not None and t2.rel not in deps:
                                deps.append(t2.rel)
                if t is not None and t.rel != rel and t.rel not in deps:
                    deps.append(t.rel)
            out[rel] = deps
        return out

    def external_imports(self):
        """{rel: [modules imported from outside the workspace]}."""
        out = {}
        for rel in sorted(self.modules):
            m = self.modules[rel]
            ext = []
            for im in m.imports:
                if im["quoted"]:
                    continue
                if self.module_named(im["module"]) is None and im["module"] not in ext:
                    ext.append(im["module"])
            out[rel] = ext
        return out

    def reaches(self, f):
        """Every function f can end up calling (transitively)."""
        self._build()
        seen = set()
        stack = [f.key]
        while len(stack) > 0:
            k = stack.pop()
            for c in self._edges.get(k, []):
                if c not in seen:
                    seen.add(c)
                    stack.append(c)
        return [self._info(k) for k in sorted(seen)]

    def stats(self):
        nf = 0
        nc = 0
        for rel in self.modules:
            nf += len(self.modules[rel].functions)
            nc += len(self.modules[rel].classes)
        self._build()
        ne = 0
        for k in self._edges:
            ne += len(self._edges[k])
        return {"modules": len(self.modules), "functions": nf, "classes": nc, "call_edges": ne}

    # ── facts for the rule engine ────────────────────────────────────────────
    def fid(self, f):
        """A function's name in rule facts: its qualname, or "rel::qualname"
        when another module has a function of that qualname too."""
        if self._fid_dup is None:
            cnt = {}
            for g in self.functions():
                cnt[g.qualname] = cnt.get(g.qualname, 0) + 1
            self._fid_dup = cnt
        if self._fid_dup.get(f.qualname, 0) > 1:
            return f.key
        return f.qualname

    def rule_facts(self, eng):
        """Asserts the model as facts: function(f), calls(f, g), raises(f, E),
        catches(f, E), isa(E, Base), writes_global(f, x), io(f, call),
        entry(f) (called from a module's top level), method(f, C),
        param(f, p)."""
        self._build()
        for e in EXC_BASES:
            eng.fact("isa", e, EXC_BASES[e])
        for c in self.classes():
            for b in c.bases:
                eng.fact("isa", c.name, b.split(".")[-1])
        for rel in sorted(self.modules):
            m = self.modules[rel]
            for f in m.functions:
                q = self.fid(f)
                eng.fact("function", q)
                if f.cls != "":
                    eng.fact("method", q, f.cls)
                for r in f.raises:
                    if r[1] != "":
                        eng.fact("raises", q, r[1].split(".")[-1])
                for ex in f.excepts:
                    if len(ex[1]) == 0:
                        eng.fact("catches", q, "BaseException")
                    for t in ex[1]:
                        eng.fact("catches", q, t.split(".")[-1])
                for g in f.globals_written:
                    eng.fact("writes_global", q, g)
                for c in f.calls:
                    if c[1] in IO_CALLS or c[1].split(".")[0] in ["os", "sys", "socket", "subprocess"]:
                        eng.fact("io", q, c[1])
                for p in f.params:
                    eng.fact("param", q, p.name)
                for k in self._edges.get(f.key, []):
                    g = self._info(k)
                    if g is not None:
                        eng.fact("calls", q, self.fid(g))
            for k in self._edges.get(m.top.key, []):
                g = self._info(k)
                if g is not None:
                    eng.fact("entry", self.fid(g))
        return eng


def default_rules(eng):
    """NyxAI's rules over a program model's facts (rule_facts)."""
    eng.rule("calls-reach", [("calls", "?a", "?b")], [("reaches", "?a", "?b")])
    eng.rule("reach-trans", [("reaches", "?a", "?b"), ("calls", "?b", "?c")], [("reaches", "?a", "?c")])
    eng.rule("recursive", [("reaches", "?f", "?f")], [("recursive", "?f")])
    eng.rule("isa-trans", [("isa", "?a", "?b"), ("isa", "?b", "?c")], [("isa", "?a", "?c")])
    eng.rule("handles", [("catches", "?f", "?e")], [("handles", "?f", "?e")])
    eng.rule("handles-base", [("catches", "?f", "?c"), ("isa", "?e", "?c")], [("handles", "?f", "?e")])
    eng.rule("raises", [("raises", "?f", "?e")], [("may_raise", "?f", "?e")])
    eng.rule("raise-through", [("calls", "?f", "?g"), ("may_raise", "?g", "?e"), ("not", "handles", "?f", "?e")],
             [("may_raise", "?f", "?e"), ("raises_via", "?f", "?e", "?g")])
    eng.rule("impure-global", [("writes_global", "?f", "?x")], [("impure", "?f")])
    eng.rule("impure-io", [("io", "?f", "?c")], [("impure", "?f")])
    eng.rule("impure-call", [("calls", "?f", "?g"), ("impure", "?g")], [("impure", "?f")])
    eng.rule("pure", [("function", "?f"), ("not", "impure", "?f")], [("pure", "?f")])
    eng.rule("called", [("calls", "?a", "?b")], [("called", "?b")])
    eng.rule("called-entry", [("entry", "?f")], [("called", "?f")])
    eng.rule("unused", [("function", "?f"), ("not", "called", "?f"), ("not", "method", "?f", "?_")],
             [("unused", "?f")])
    return eng
