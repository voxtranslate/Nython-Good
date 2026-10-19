# vm_audit116.ny - the semantic gaps rounds 82-83 found (round 84).
#
# Reading a missing attribute of a module says "module 'm' has no attribute
# 'x'" (it said "'dict' object"); a dict has no list or set methods
# ({}.append(x) made the dict a list on the interpreter); an exception's own
# __init__/__str__/__repr__ are values (e.__str__(), ValueError.__init__,
# getattr(e, "__repr__")); an instance has its class's __module__ and a
# __weakref__; builtins have CPython's docstrings (int.__doc__, len.__doc__,
# [].append.__doc__, (5).__doc__, ValueError.__doc__, math.sqrt.__doc__) and
# the prelude's builtin classes are builtins' (range.__module__); a finally
# body run while an exception propagates sees it (sys.exc_info(), the
# __context__ of one raised there); comprehension targets unpack as Python
# unpacks (exactly that many values, starred targets); sys.audit and
# sys.addaudithook (PEP 578) with the exec, compile, import, open and
# builtins.input events; on the VM a comprehension's targets go with it.
#
# The checks pass under python3 too:
#
#     ./build/nython-cli examples/vm_audit116.ny
#     ./build/nython-cli --vm examples/vm_audit116.ny
#     python3 examples/vm_audit116.ny

import sys, os, math, json, tempfile, subprocess

NYTHON = sys.implementation.name == "nython"
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(f):
    try:
        f()
        return "no error"
    except BaseException as e:
        return type(e).__name__ + ": " + str(e)

# ── a module's missing attribute ──────────────────────────────────────────
check("module attribute errors", [err(lambda: sys.no_such_attr_116), err(lambda: os.no_such_attr_116),
      err(lambda: math.no_such_attr_116), err(lambda: json.no_such_attr_116)],
      ["AttributeError: module 'sys' has no attribute 'no_such_attr_116'",
       "AttributeError: module 'os' has no attribute 'no_such_attr_116'",
       "AttributeError: module 'math' has no attribute 'no_such_attr_116'",
       "AttributeError: module 'json' has no attribute 'no_such_attr_116'"])
check("getattr of a module with a default", getattr(math, "no_such_attr_116", "dflt"), "dflt")

# ── a dict has no list methods ────────────────────────────────────────────
def dict_list_methods():
    d = {}
    out = [err(lambda: d.append(1)), err(lambda: d.add(1)), err(lambda: d.extend([1])),
           err(lambda: d.insert(0, 1)), err(lambda: d.sort())]
    out.append(d)
    return out
check("{}.append and friends raise AttributeError", dict_list_methods(),
      ["AttributeError: 'dict' object has no attribute 'append'", "AttributeError: 'dict' object has no attribute 'add'",
       "AttributeError: 'dict' object has no attribute 'extend'", "AttributeError: 'dict' object has no attribute 'insert'",
       "AttributeError: 'dict' object has no attribute 'sort'", {}])

# ── exceptions' own members ───────────────────────────────────────────────
e = ValueError("x", 2)
class E(Exception):
    def __str__(self):
        return "custom"
class F(KeyError):
    pass
check("e.__str__() / e.__repr__()", [e.__str__(), e.__repr__(), KeyError("k").__str__(), F("k").__str__()],
      ["('x', 2)", "ValueError('x', 2)", "'k'", "'k'"])
check("BaseException's __str__ under a subclass's own", [str(E("a")), Exception.__str__(E("a")), BaseException.__repr__(E("a"))],
      ["custom", "a", "E('a')"])
check("the members are callables", [callable(e.__init__), callable(ValueError.__init__), callable(getattr(e, "__repr__")),
      hasattr(OSError, "__str__"), hasattr(e, "__init__")], [True, True, True, True, True])
def exc_init():
    x = ValueError("a")
    ValueError.__init__(x, "b", "c")
    y = KeyError("k")
    Exception.__init__(y, "j")
    return [x.args, str(x), y.args, str(y)]
check("ValueError.__init__(e, ...) sets args", exc_init(), [("b", "c"), "('b', 'c')", ("j",), "'j'"])
def exc_init_bound():
    x = KeyError("a")
    x.__init__("z")
    return [x.args, str(x)]
check("e.__init__(...) as a bound method", exc_init_bound(), [("z",), "'z'"])

# ── instances' __module__ and __weakref__ ─────────────────────────────────
class P:
    pass
p = P()
check("an instance's __module__ is its class's", [p.__module__, P.__module__], ["__main__", "__main__"])
check("__weakref__ of an instance without weak references", p.__weakref__, None)
check("a builtin class's __module__", [range.__module__, property.__module__, object.__module__, ValueError.__module__],
      ["builtins", "builtins", "builtins", "builtins"])

# ── docstrings of the builtins ────────────────────────────────────────────
def first(d):
    return d.split("\n")[0] if isinstance(d, str) else d
check("builtin docstrings", [first(len.__doc__), first(print.__doc__), first(int.__doc__), first(str.upper.__doc__),
      first([].append.__doc__), first(dict.get.__doc__), first((5).__doc__), first("s".__doc__), first(None.__doc__)],
      ["Return the number of items in a container.", "Prints the values to a stream, or to sys.stdout by default.",
       "int([x]) -> integer", "Return a copy of the string converted to uppercase.", "Append object to the end of the list.",
       "Return the value for key if key is in the dictionary, else default.", "int([x]) -> integer",
       "str(object='') -> str", None])
check("exceptions' and classes' docstrings", [first(ValueError.__doc__), first(KeyError("k").__doc__), first(object.__doc__),
      first(range.__doc__), first(math.sqrt.__doc__)],
      ["Inappropriate argument value (of correct type).", "Mapping key not found.", "The base class of the class hierarchy.",
       "range(stop) -> range object", "Return the square root of x."])
class Q:
    "doc q"
class R(ValueError):
    pass
check("a user class's docstring stays its own", [P.__doc__, Q.__doc__, Q().__doc__, R.__doc__], [None, "doc q", "doc q", None])

# ── a finally body sees the exception that runs it ────────────────────────
def fin_exc_info():
    try:
        try:
            raise KeyError("k")
        finally:
            info = sys.exc_info()[0]
    except KeyError:
        return info
check("sys.exc_info() inside a finally run by an exception", fin_exc_info(), KeyError)
def fin_context():
    try:
        try:
            raise KeyError("k")
        finally:
            try:
                raise ValueError("v")
            except ValueError as e:
                ctx = e.__context__
    except KeyError:
        return repr(ctx)
check("an exception raised in such a finally has it as __context__", fin_context(), "KeyError('k')")
def fin_plain():
    try:
        x = 1
    finally:
        info = sys.exc_info()
    return info
check("a finally run normally sees none", fin_plain(), (None, None, None))
def fin_loop():
    out = []
    for i in range(3):
        try:
            try:
                raise ValueError(i)
            finally:
                out.append(sys.exc_info()[1].args[0])
                if i == 1:
                    continue
        except ValueError:
            out.append("caught")
    out.append(sys.exc_info())
    return out
check("a continue out of such a finally leaves nothing behind", fin_loop(), [0, "caught", 1, 2, "caught", (None, None, None)])

# ── comprehension targets ─────────────────────────────────────────────────
check("too many values in a comprehension target", err(lambda: [a for a, b in [(1, 2, 3)]]),
      "ValueError: too many values to unpack (expected 2)")
check("not enough values", err(lambda: [a for a, b in [(1,)]]), "ValueError: not enough values to unpack (expected 2, got 1)")
check("a non-iterable item", err(lambda: [a for a, b in [5]]), "TypeError: cannot unpack non-iterable int object")
check("strings, dicts and nested targets", [[a + b for a, b in ["xy", "zw"]], {k: v for k, (v, w) in [(1, (2, 3))]},
      [a for a, b in [{"p": 1, "q": 2}]]], [["xy", "zw"], {1: 2}, ["p"]])
check("starred targets", [[(a, b) for a, *b in [(1, 2, 3), (4,)]], [(a, c) for a, *b, c in ["xyz"]],
      [b for *b, c in [[1, 2, 3]]], [(a, b, c) for (a, *b), c in [((1, 2, 3), 4)]]],
      [[(1, [2, 3]), (4, [])], [("x", "z")], [[1, 2]], [(1, [2, 3], 4)]])
check("starred target errors", [err(lambda: [b for a, *b, c in [(1,)]])],
      ["ValueError: not enough values to unpack (expected at least 2, got 1)"])
check("a starred target in a generator expression and a set", [list(b for a, *b in [(1, 2)]), {a for a, *b in [(1, 2), (1, 3)]}],
      [[[2]], {1}])

# ── sys.audit / sys.addaudithook (PEP 578) ────────────────────────────────
# run in a child: a hook cannot be removed
script = os.path.join(tempfile.mkdtemp(), "audit_116.py")
with open(script, "w") as f:
    f.write("""import sys
seen = []
mode = ["all"]
def hook(event, args):
    if mode[0] == "import":
        if event == "import" and args[0] == "colorsys":
            seen.append((event, args[0], args[1], type(args[2]).__name__, type(args[3]).__name__))
    elif event == "compile":
        seen.append((event, args[1]))
    elif event == "exec":
        seen.append((event, len(args)))
    elif event == "open":
        if str(args[0]).endswith(".txt"):
            seen.append((event, args[1], args[2] if sys.platform == "linux" else 0))
    elif event in ("my.event", "sys.addaudithook", "builtins.input"):
        seen.append((event, args))
sys.addaudithook(hook)
sys.audit("my.event", 1, "two")
exec("x = 1")
eval("3")
compile("2", "fname", "eval")
mode[0] = "import"
import colorsys
mode[0] = "all"
p = __file__ + ".txt"
f = open(p, "w"); f.close()
f = open(p, "rb"); f.close()
f = open(p, "a+"); f.close()
def veto(event, args):
    if event == "sys.addaudithook":
        raise RuntimeError("no more hooks")
sys.addaudithook(veto)
sys.addaudithook(lambda e, a: seen.append("never"))
try:
    sys.audit(5)
except TypeError as e:
    seen.append(str(e))
for s in seen:
    print(s)
""")
out = subprocess.run([sys.executable, script], capture_output=True, text=True)
lin = sys.platform == "linux"
check("audit events in order", [out.stdout.strip().split("\n"), out.returncode],
      [["('my.event', (1, 'two'))", "('compile', '<string>')", "('exec', 1)",
        "('compile', '<string>')", "('exec', 1)", "('compile', 'fname')", "('import', 'colorsys', None, 'list', 'list')",
        "('open', 'w', %d)" % (524865 if lin else 0), "('open', 'r', %d)" % (524288 if lin else 0),
        "('open', 'a+', %d)" % (525378 if lin else 0), "('sys.addaudithook', ())", "('sys.addaudithook', ())",
        "expected str for argument 'event', not int"], 0])

# ── True/False/None spelled as the program's language spells them ────────
# (Nython: Python's in a .py program or one marked `# nython: python`,
# Nython's true/none in a .ny one; NYTHON_SPELLING overrides)
sdir = tempfile.mkdtemp()
body = "x = [True, None, False]\nprint(True, None, x, str(False), repr(None), f'{True}', '%s' % (None,), {1: True})\n"
def run_spell(name, text, env=None):
    path = os.path.join(sdir, name)
    with open(path, "w") as f:
        f.write(text)
    e = dict(os.environ)
    if env:
        e.update(env)
    return subprocess.run([sys.executable, path], capture_output=True, text=True, env=e).stdout.strip()
py_line = "True None [True, None, False] False None True None {1: True}"
ny_line = "true none [true, none, false] false none true none {1: true}" if NYTHON else py_line
check("a .py program prints Python's spelling", run_spell("sp.py", body), py_line)
check("a .ny program Nython's", run_spell("sp.ny", body), ny_line)
check("# nython: python marks a .ny file as Python", run_spell("sp2.ny", "# nython: python\n" + body), py_line)
check("NYTHON_SPELLING=nython overrides a .py file", run_spell("sp3.py", body, {"NYTHON_SPELLING": "nython"}), ny_line)
check("json keeps true/false/null", run_spell("sp4.py", "import json\nprint(json.dumps([True, False, None]))\n"), "[true, false, null]")

# ── the VM's comprehension targets go with it (both engines) ─────────────
def comp_names():
    def f():
        xs = [i * 2 for i in range(3)]
        ys = {k: v for k, v in [(1, 2)]}
        return sorted(n for n in locals() if not n.startswith("_") or n.startswith("__c"))
    return f()
check("a comprehension leaves no names in the function", comp_names(), ["xs", "ys"])
class CB:
    vals = [i for i in range(3)]
check("nor in a class body", sorted(n for n in vars(CB) if n.startswith("__c") or n == "i"), [])
def late():
    fs = [lambda: i for i in range(3)]
    return [f() for f in fs]
check("a lambda made in a comprehension still reads its target", late(), [2, 2, 2])

pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT116 PASSED ===")
