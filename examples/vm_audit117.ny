# vm_audit117.ny - the functions CPython implements in C are builtins here
# too (round 84).
#
# time.time, operator.add, heapq.heappush, zlib.crc32, os.fspath ... are
# written in Nython; once their module has run the engines make each one a
# builtin function (include/NyBuiltinFns.hpp, generated from CPython, names
# them; the prelude's _ny_seal_cmodule marks them): type
# builtin_function_or_method, <built-in function name>, not bound when read
# through a class or an instance (a class attribute `converter =
# time.gmtime` is called with the seconds alone), C.__dict__ holds the
# function itself, __self__ is the module. The natives a module exposes
# carry the module's names: math.sqrt is "sqrt" of math (it was
# "math_sqrt" of builtins), sys.getrefcount "getrefcount" of sys. A
# program's own functions, and the library's that CPython writes in Python
# (os.walk, json.dumps), stay functions.
#
# The checks pass under python3 too:
#
#     ./build/nython-cli examples/vm_audit117.ny
#     ./build/nython-cli --vm examples/vm_audit117.ny
#     python3 examples/vm_audit117.ny

import sys, os, math, time, operator, heapq, bisect, zlib, binascii, struct, types, inspect
import json, copy, pickle, logging, functools, itertools

NYTHON = sys.implementation.name == "nython"
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

BF = types.BuiltinFunctionType

# ── the library's builtins written in Nython ──────────────────────────────
check("their type", [type(f).__name__ for f in (time.time, time.sleep, time.gmtime, operator.add,
      heapq.heappush, bisect.insort, zlib.crc32, binascii.hexlify, struct.pack, os.fspath, os.scandir,
      functools.reduce)], ["builtin_function_or_method"] * 12)
check("isinstance BuiltinFunctionType", [isinstance(f, BF) for f in (time.monotonic, operator.itemgetter(1).__class__,
      heapq.heappop, len)], [True, False, True, True])
check("type(f) is type(len)", type(heapq.heappush) is type(len), True)
check("their repr", [repr(f) for f in (time.time, operator.add, heapq.heappush, zlib.crc32, os.fspath)],
      ["<built-in function time>", "<built-in function add>", "<built-in function heappush>",
       "<built-in function crc32>", "<built-in function fspath>"])
check("inspect predicates", [inspect.isbuiltin(time.sleep), inspect.isfunction(time.sleep),
      inspect.isroutine(time.sleep), callable(time.sleep)], [True, False, True, True])
check("their names", [(f.__name__, f.__qualname__, f.__module__) for f in (time.sleep, heapq.heappush)],
      [("sleep", "sleep", "time"), ("heappush", "heappush", "_heapq" if not NYTHON else "heapq")])
check("a private def under a public name takes it", (os.fspath.__name__, os.fspath.__qualname__, os.scandir.__name__),
      ("fspath", "fspath", "scandir"))

# ── not bound through a class ─────────────────────────────────────────────
class C:
    now = time.time
    add = operator.add
    push = heapq.heappush
    insort = bisect.insort
    crc = zlib.crc32
    sq = math.sqrt
    rd = functools.reduce

c = C()
h = []
c.push(h, 3)
c.push(h, 1)
xs = [1, 5]
c.insort(xs, 3)
check("called through an instance", [type(c.now()).__name__, c.add(2, 3), h, xs, c.crc(b"abc"), c.sq(16.0),
      c.rd(operator.add, [1, 2, 3])], ["float", 5, [1, 3], [1, 3, 5], 891568578, 4.0, 6])
check("called through the class", [C.add(4, 5), C.crc(b"")], [9, 0])
check("C.__dict__ holds the function itself", [C.__dict__["now"] is time.time, C.__dict__["add"] is operator.add,
      C.add is operator.add, c.add is operator.add], [True, True, True, True])

class F(logging.Formatter):
    converter = time.gmtime
rec = logging.LogRecord("n", logging.INFO, "p", 1, "m", None, None)
rec.created = 86400.0 * 366
rec.msecs = 0
check("logging.Formatter.converter = time.gmtime", F("%(asctime)s").formatTime(rec, "%Y-%m-%d"), "1971-01-02")

# ── __self__ is the module ────────────────────────────────────────────────
check("__self__", [time.time.__self__ is time, heapq.heappush.__self__.__name__ in ("_heapq", "heapq"),
      math.sqrt.__self__ is math, len.__self__.__name__, type(len.__self__).__name__],
      [True, True, True, "builtins", "module"])

# ── the natives a module exposes carry its names ──────────────────────────
check("math's natives", [(f.__name__, f.__qualname__, f.__module__, repr(f)) for f in (math.sqrt, math.floor)],
      [("sqrt", "sqrt", "math", "<built-in function sqrt>"), ("floor", "floor", "math", "<built-in function floor>")])
check("sys's natives", [(f.__name__, f.__module__, repr(f)) for f in (sys.getrefcount, sys.settrace, sys.exception)],
      [("getrefcount", "sys", "<built-in function getrefcount>"), ("settrace", "sys", "<built-in function settrace>"),
       ("exception", "sys", "<built-in function exception>")])
check("os's natives", [os.getcwd.__name__, os.getpid.__name__, repr(os.getcwd)], ["getcwd", "getpid", "<built-in function getcwd>"])
check("builtins' own", [(len.__name__, len.__module__, repr(len)), (abs.__qualname__, abs.__module__)],
      [("len", "builtins", "<built-in function len>"), ("abs", "builtins")])

# ── they still copy, pickle and work as values ────────────────────────────
check("copy keeps them", [copy.copy(time.time) is time.time, copy.deepcopy(operator.add) is operator.add], [True, True])
check("pickle by reference", [pickle.loads(pickle.dumps(time.time)) is time.time,
      pickle.loads(pickle.dumps(heapq.heappush, 0)) is heapq.heappush], [True, True])
check("as keys and in sorted/map", [{time.time: 1}[time.time], list(map(operator.neg, [1, -2])),
      sorted([3, 1, 2], key=operator.neg)], [1, [-1, 2], [3, 2, 1]])
check("functools.partial over one", functools.partial(operator.mul, 3)(4), 12)

# ── what stays a function ─────────────────────────────────────────────────
def own(x):
    return x

def sleep(x):
    return x

class D:
    s = sleep
    o = own

check("a program's own functions", [type(own).__name__, type(sleep).__name__, inspect.isfunction(sleep),
      isinstance(D().s(), D), isinstance(D().o(), D)], ["function", "function", True, True, True])
check("CPython's Python-written functions", [type(os.walk).__name__, type(os.fsencode).__name__,
      type(json.dumps).__name__, type(functools.wraps).__name__, type(inspect.signature).__name__], ["function"] * 5)
check("a staticmethod still wraps", [type(staticmethod(own)).__name__, type(C.__dict__.get("missing", own)).__name__],
      ["staticmethod", "function"])

# ── PEP 562: a module's own __getattr__ and __dir__ ───────────────────────
import tempfile
_d = tempfile.mkdtemp()
with open(os.path.join(_d, "_ny_m562.py"), "w") as _f:
    _f.write("""
calls = []
def __getattr__(name):
    calls.append(name)
    if name == "magic":
        return 42
    if name == "twice":
        return lambda x: 2 * x
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
def __dir__():
    return ["x", "magic", "twice"]
x = 1
__all__ = ["x", "magic"]
""")
sys.path.insert(0, _d)
import _ny_m562 as m562

def _err(f):
    try:
        f()
        return "no error"
    except BaseException as e:
        return type(e).__name__ + ": " + str(e)

check("module __getattr__ supplies what it lacks", [m562.magic, m562.x, m562.twice(5), getattr(m562, "nope", "dflt"),
      hasattr(m562, "magic"), hasattr(m562, "nope")], [42, 1, 10, "dflt", True, False])
check("its AttributeError propagates", _err(lambda: m562.nope), "AttributeError: module '_ny_m562' has no attribute 'nope'")
check("it is not asked for what the module has", "x" in m562.calls, False)
check("module __dir__", dir(m562), ["magic", "twice", "x"])
def _from_import():
    from _ny_m562 import magic, x
    return [magic, x]
def _from_missing():
    from _ny_m562 import nope
check("from m import name", [_from_import(), _err(_from_missing)],
      [[42, 1], "ImportError: cannot import name 'nope' from '_ny_m562' (" + m562.__file__ + ")"])
_ns = {}
exec("from _ny_m562 import *", _ns)
check("from m import * through __all__", [_ns["x"], _ns["magic"]], [1, 42])

# ── int() through __index__ / __trunc__; float() of an int too large ───────
import warnings
class _Idx:
    def __index__(self):
        return 7
class _Tr:
    def __trunc__(self):
        return 3
class _BadIdx:
    def __index__(self):
        return "x"
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    _tr = int(_Tr())
check("int() through __index__ and __trunc__", [int(_Idx()), _tr, _err(lambda: int(_BadIdx())), float(_Idx())],
      [7, 3, "TypeError: __index__ returned non-int (type str)", 7.0])
check("float() of an int too large", [_err(lambda: float(2**1100)), _err(lambda: float(-(2**1100))), float(2**1023) > 0],
      ["OverflowError: int too large to convert to float", "OverflowError: int too large to convert to float", True])

# ── an unbound name is a NameError whatever methods share it ───────────────
class _HasResult:
    def result(self):
        return 1
    def total(self):
        return 2
_bm = _HasResult().result      # a bound method alive at run time
def _outer():
    def nested_only():         # a nested function's name is no global name
        return 3
    return nested_only
_nf = _outer()
def _read_unbound():
    try:
        return result
    except NameError:
        return "NameError"
def _read_unbound2():
    try:
        return nested_only
    except NameError:
        return "NameError"
check("an unbound name with a method of that name", [_read_unbound(), _read_unbound2(), _err(lambda: eval("total", {}, {}))],
      ["NameError", "NameError", "NameError: name 'total' is not defined"])

# ── PEP 701: an f-string's fields may use its own quotes (3.12) ────────────
if NYTHON or sys.version_info >= (3, 12):
    _ns = {"xs": ["a", "b"], "d": {"k": 1}}
    exec('''
r1 = f"<{', '.join(xs)}>"
r2 = f"{d["k"]} and {", ".join(xs)}"
r3 = f"{'x' + "y"}"
r4 = f"{f"{1+1}"}"
r5 = f"{"\\n".join(xs)!r}"
r6 = f"{d["k"]:>4}|{len("ab"):03d}"
r7 = f"""{
    xs[0]  # a comment inside a field
}"""
''', _ns)
    check("PEP 701 f-strings", [_ns[k] for k in ("r1", "r2", "r3", "r4", "r5", "r6", "r7")],
          ["<a, b>", "1 and a, b", "xy", "2", "'a\\nb'", "   1|002", "a"])

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
    print("=== VM_AUDIT117 PASSED ===")
