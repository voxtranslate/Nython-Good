# vm_audit119.ny - Python's binding rule for Python-language source, both
# engines (round 85).
#
# nython: python    (this file is Python-language source: Python's rule)
#
# In a Python-language file - a .py file, one whose leading comments say
# `# nython: python` (this one), code compile()/exec()/eval() compile when
# called from such a file, an ast tree compiled - a name a function binds
# anywhere in its body is a local of the whole function unless declared
# global / nonlocal, and reading it unbound is UnboundLocalError, as in
# CPython. The static scope pass (src/NyScope.cpp) decides it and marks the
# tree; both engines follow the marks. Nython-language files (.ny without
# the marker) keep Nython's rule: a plain assignment rebinds the nearest
# existing binding - the Nython-only checks at the end run small .ny
# programs on both engines to show it, the def-line opt-in, the
# `-W nython-scope` / NY_SCOPE_WARN warnings and `--scope-report`.
#
# Everything but the Nython-only part runs under python3 unchanged
# (`python3 examples/vm_audit119.ny`); every expected value is CPython's.
#
#     ./build/nython-cli examples/vm_audit119.ny
#     ./build/nython-cli --vm examples/vm_audit119.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import sys

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(f, *a):
    try:
        f(*a)
        return "no error"
    except BaseException as e:
        return type(e).__name__ + ": " + str(e)

UNB = "UnboundLocalError: cannot access local variable '%s' where it is not associated with a value"

# ── 1. a plain assignment makes a local; the module's name is untouched ──────
x = "module x"
count = 0

def assigns():
    x = "local x"
    return x

check("assignment in a function is a local", [assigns(), x], ["local x", "module x"])

def reads():
    return x

check("a function that only reads sees the module's", reads(), "module x")

def read_then_assign():
    y = x
    x = "late"
    return y

check("read before the assignment: UnboundLocalError", err(read_then_assign), UNB % "x")
check("UnboundLocalError is a NameError",
      [issubclass(UnboundLocalError, NameError), isinstance(UnboundLocalError("m"), NameError)], [True, True])

def bump():
    count += 1
    return count

check("augmented assignment of a module name: UnboundLocalError", [err(bump), count], [UNB % "count", 0])

def bump_global():
    global count
    count += 1
    return count

check("global: the module's name", [bump_global(), bump_global(), count], [1, 2, 2])

def assign_in_dead_branch():
    if False:
        x = 1
    return x

check("bound in a branch that never runs: still a local", err(assign_in_dead_branch), UNB % "x")

def assign_after_return():
    return x
    x = 2

check("bound after a return: still a local", err(assign_after_return), UNB % "x")

def chained():
    a = b = "both"
    return a + b

a = "A"
b = "B"
check("chained assignment: both local", [chained(), a, b], ["bothboth", "A", "B"])

def unpacks():
    a, (b, *c) = 1, (2, 3, 4)
    return [a, b, c]

check("unpacking targets: local", [unpacks(), a, b], [[1, 2, [3, 4]], "A", "B"])

def annotated():
    x: int = 5
    return x

check("annotated assignment: local", [annotated(), x], [5, "module x"])

# ── 2. every binding form ─────────────────────────────────────────────────────
i = "module i"
e = "module e"
fh = "module fh"
json = "module json"
helper = "module helper"
K = "module K"
w = "module w"
cap = "module cap"

def for_target():
    for i in range(3):
        pass
    return i

check("for target", [for_target(), i], [2, "module i"])

def while_assign():
    n = 0
    while n < 3:
        i = n
        n += 1
    return i

check("assignment in a while body", [while_assign(), i], [2, "module i"])

def except_target():
    try:
        raise KeyError("k")
    except KeyError as e:
        got = repr(e)
    return got

check("except ... as target", [except_target(), e], ["KeyError('k')", "module e"])

def except_target_unbound():
    try:
        raise ValueError("v")
    except ValueError as e:
        pass
    return e

check("except ... as is unbound after the clause", err(except_target_unbound), UNB % "e")

class CM:
    def __enter__(self):
        return "entered"
    def __exit__(self, *a):
        return False

def with_target():
    with CM() as fh:
        pass
    return fh

check("with ... as target", [with_target(), fh], ["entered", "module fh"])

def imports():
    import json
    return json.dumps([1])

check("import in a function", [imports(), json], ["[1]", "module json"])

def from_imports():
    from json import dumps as helper
    return helper({"a": 1})

check("from-import in a function", [from_imports(), helper], ['{"a": 1}', "module helper"])

def defines():
    def helper():
        return "inner helper"
    class K:
        tag = "inner K"
    return [helper(), K.tag]

check("def and class in a function", [defines(), helper, K], [["inner helper", "inner K"], "module helper", "module K"])

def walrus():
    if (w := 10) > 5:
        return w

check("walrus", [walrus(), w], [10, "module w"])

def walrus_in_comprehension():
    data = [1, 2, 3]
    total = [w := w0 * 2 for w0 in data]
    return [total, w]

check("walrus in a comprehension binds in the function (PEP 572)", [walrus_in_comprehension(), w], [[[2, 4, 6], 6], "module w"])

def match_capture(v):
    match v:
        case [cap, 2]:
            return cap
        case {"k": cap}:
            return cap
        case cap:
            return cap

check("match captures", [match_capture([1, 2]), match_capture({"k": "kv"}), match_capture(9), cap], [1, "kv", 9, "module cap"])

def deletes():
    x = 1
    del x
    return x

check("del, then read: UnboundLocalError", err(deletes), UNB % "x")

def deletes_unbound():
    del x

check("del of an unbound local: UnboundLocalError", [err(deletes_unbound), x], [UNB % "x", "module x"])

def deletes_global():
    global gone
    del gone

gone = 1
deletes_global()
check("del of a global declared so", "gone" in globals(), False)

def builtin_shadow():
    n = len([1, 2])
    len = 5
    return n

check("a builtin's name the function binds is its local", err(builtin_shadow), UNB % "len")

def builtin_local():
    len = lambda s: 42
    return len("abc")

check("a builtin's name bound first", [builtin_local(), len("ab")], [42, 2])

# ── 3. closures and nonlocal ─────────────────────────────────────────────────
def outer_inner_local():
    v = "outer"
    def inner():
        v = "inner"
        return v
    r = inner()
    return [r, v]

check("an inner function's assignment is its own local", outer_inner_local(), ["inner", "outer"])

def inner_reads_before():
    v = "outer"
    def inner():
        r = v
        v = "inner"
        return r
    return err(inner)

check("an inner function reading its local before binding it", inner_reads_before(), UNB % "v")

def counter():
    n = 0
    def inc():
        nonlocal n
        n += 1
        return n
    return inc

c1 = counter()
c1()
c1()
check("nonlocal rebinds the enclosing function's", c1(), 3)

def late_binding():
    fs = []
    for k in range(3):
        def f():
            return k
        fs.append(f)
    return [f() for f in fs]

check("closures made in a loop see the last value", late_binding(), [2, 2, 2])

def early_binding():
    fs = []
    for k in range(3):
        def f(k=k):
            return k
        fs.append(f)
    return [f() for f in fs]

check("default arguments capture each value", early_binding(), [0, 1, 2])

def sees_later_rebinding():
    v = 1
    def get():
        return v
    v = 2
    return get()

check("a closure sees the enclosing variable's later value", sees_later_rebinding(), 2)

def nested_nonlocal():
    a = 1
    def mid():
        def inner():
            nonlocal a
            a = a * 10
        inner()
        return a
    return [mid(), a]

check("nonlocal through two levels", nested_nonlocal(), [10, 10])

def global_in_inner():
    def inner():
        global x
        x = "set by inner"
    inner()
    return x

check("global in a nested function", [global_in_inner(), x], ["set by inner", "set by inner"])
x = "module x"

lam = lambda q: [q, x]
check("lambda: its parameters, the module's other names", lam(1), [1, "module x"])

def lambda_closure():
    z = 7
    return (lambda: z)()

check("a lambda reads the enclosing function's", lambda_closure(), 7)

# ── 4. class bodies and comprehensions ───────────────────────────────────────
attr = "module attr"

class Body:
    attr = "class attr"
    seen = attr
    def method(self):
        return attr

check("class body: its own namespace; a method reads the module's",
      [Body.attr, Body.seen, Body().method(), attr], ["class attr", "class attr", "module attr", "module attr"])

ctr = 1

class Reads:
    ctr = ctr + 1

check("class body reads the module's name before binding its own", [Reads.ctr, ctr], [2, 1])

def class_in_function():
    y = "function y"
    class C:
        z = y
        def m(self):
            return y
    return [C.z, C().m()]

check("a class body in a function reads the function's locals", class_in_function(), ["function y", "function y"])

def method_local():
    class C:
        def m(self):
            x = "method local"
            self.x = x
            return x
    o = C()
    return [o.m(), o.x]

check("a method's assignment is its local", [method_local(), x], [["method local", "method local"], "module x"])

q = "module q"

def comprehension_scope():
    q = "function q"
    lst = [q + str(j) for j in range(2)]
    return [lst, q]

check("a comprehension reads the function's locals", comprehension_scope(), [["function q0", "function q1"], "function q"])

def comprehension_target_does_not_leak():
    j = "kept"
    [j for j in range(3)]
    return j

check("a comprehension's target does not leak", comprehension_target_does_not_leak(), "kept")

def genexp_reads_local():
    m = 3
    return sum(t * m for t in range(3))

check("a generator expression reads the function's", genexp_reads_local(), 9)

# ── 5. generators, decorators, recursion, functions made in loops ───────────
def gen():
    x = 0
    while x < 3:
        yield x
        x += 1

check("a generator's locals", [list(gen()), x], [[0, 1, 2], "module x"])

def gen_unbound():
    yield 1
    yield x
    x = 2

g = gen_unbound()
check("a generator reading its local unbound", [next(g), err(next, g)], [1, UNB % "x"])

calls = []

def deco(f):
    calls = "decorator local"
    def wrapper(*a):
        return ["wrapped", f(*a), calls]
    return wrapper

@deco
def decorated(v):
    return v * 2

check("a decorator's assignment is its local", [decorated(4), calls], [["wrapped", 8, "decorator local"], []])

def fact(n):
    acc = 1 if n <= 1 else n * fact(n - 1)
    return acc

acc = "module acc"
check("recursion with a local named as a module name", [fact(5), acc], [120, "module acc"])

def fib_memo(n, memo=None):
    if memo is None:
        memo = {}
    if n in memo:
        return memo[n]
    r = n if n < 2 else fib_memo(n - 1, memo) + fib_memo(n - 2, memo)
    memo[n] = r
    return r

check("recursion through a default argument", fib_memo(30), 832040)

made = []
for r in range(3):
    def made_in_loop(v, r=r):
        res = v + r
        return res
    made.append(made_in_loop)
res = "module res"
check("functions made in a loop", [[f(10) for f in made], res], [[10, 11, 12], "module res"])

import asyncio
av = "module av"

async def coro():
    av = "local av"
    await asyncio.sleep(0)
    return av

check("async def: its assignment is its local", [asyncio.run(coro()), av], ["local av", "module av"])

def lambda_reads_later_binding():
    get = lambda: later
    later = "bound after the lambda"
    return get()

check("a lambda reads the enclosing function's later binding", lambda_reads_later_binding(), "bound after the lambda")

global gx
gx = "module gx"
check("global at module level", gx, "module gx")

def try_finally():
    try:
        out = "try"
        return out
    finally:
        out = "finally"

out = "module out"
check("try/finally", [try_finally(), out], ["try", "module out"])

# ── 6. exec, eval and compile from a Python-language file ───────────────────
ex_global = "module ex_global"

def exec_in_function():
    v = 1
    exec("v = 99\nnew_name = 5")
    return [v, err(lambda: eval("new_name"))]

check("exec in a function cannot change or create its locals",
      exec_in_function(), [1, "NameError: name 'new_name' is not defined"])

def exec_reads_locals():
    v = 7
    out = []
    exec("out.append(v * 6)")
    return out

check("exec in a function reads its locals", exec_reads_locals(), [42])

def eval_reads_locals():
    v = 41
    return eval("v + 1")

check("eval in a function reads its locals", eval_reads_locals(), 42)

def exec_global_decl():
    exec("global ex_global\nex_global = 'set by exec'")
    return ex_global

check("exec'd `global` reaches the module", [exec_global_decl(), ex_global], ["set by exec", "set by exec"])

ns = {"x": 1}
exec("def setx():\n    x = 5\n    return x\ndef getx():\n    return x\n", ns)
check("exec'd code: functions follow Python's rule", [ns["setx"](), ns["getx"](), ns["x"]], [5, 1, 1])

ns2 = {"t": 0}
exec("def bad():\n    t += 1\n", ns2)
check("exec'd code: augmenting a global without `global`", err(ns2["bad"]), UNB % "t")

code = compile("def h():\n    x = 'from compile'\n    return x\nr = h()\n", "<vm119>", "exec")
ns3 = {"x": "kept"}
exec(code, ns3)
check("compile() then exec", [ns3["r"], ns3["x"]], ["from compile", "kept"])

exec("module_level_exec = 3")
check("exec at module level binds the module's", module_level_exec, 3)

import ast
tree = ast.parse("x = 1\ndef f():\n    x = 2\n    return x\nr = [f(), x]\n")
ns4 = {}
exec(compile(tree, "<ast>", "exec"), ns4)
check("an ast tree compiled: Python's rule", ns4["r"], [2, 1])

tree2 = ast.parse("n = 0\ndef inc():\n    n += 1\n")
ns5 = {}
exec(compile(tree2, "<ast>", "exec"), ns5)
check("an ast tree compiled: UnboundLocalError", err(ns5["inc"]), UNB % "n")

# ── 7. what the census found (tools/ny_scopecheck.py) ───────────────────────
# lib/email/_parseaddr.ny is CPython's code: AddrlistClass.getdelimited has a
# local `quote = False`. Under Nython's rule it rebound the module's function
# quote(), so the next quoted local part failed ("'bool' object is not
# callable"); marked Python-language, it is the local CPython means.
import email.utils
check("email: a quoted local part, twice",
      [email.utils.parseaddr('"a b"@example.com'), email.utils.parseaddr('"c d" <x@example.com>')],
      [("", '"a b"@example.com'), ("c d", "x@example.com")])
import timeit
check("timeit's module functions stay functions", [callable(timeit.repeat), callable(timeit.timeit)], [True, True])

# ── 8. Nython only: a .ny file keeps Nython's rule ──────────────────────────
if nython:
    import os
    import subprocess
    import tempfile
    tmp = tempfile.mkdtemp(prefix="vm119_")

    def prog(name, text):
        p = os.path.join(tmp, name)
        with open(p, "w") as f:
            f.write(text)
        return p

    def run(engine, args, env=None):
        e = dict(os.environ)
        e.pop("NY_SCOPE_WARN", None)
        if env:
            e.update(env)
        r = subprocess.run([sys.executable] + engine + args, capture_output=True, text=True, env=e, timeout=120)
        return [r.returncode, r.stdout, r.stderr]

    nyrule = prog("nyrule.ny", "x = 1\ndef f():\n    x = 2\n    return x\nf()\nprint(x)\n")
    pyrule = prog("pyrule.ny", "# nython: python\nx = 1\ndef f():\n    x = 2\n    return x\nf()\nprint(x)\n")
    pyfile = prog("pyrule.py", "x = 1\ndef f():\n    x = 2\n    return x\nf()\nprint(x)\n")
    optin = prog("optin.ny",
                 "x = 1\ny = 1\ndef f():  # nython: python\n    x = 2\n    def g():\n        y = 3\n    g()\n"
                 "def h():\n    y = 4\nf()\nprint(x, y)\nh()\nprint(x, y)\n")
    unbound = prog("unbound.ny", "# nython: python\nx = 1\ndef f():\n    print(x)\n    x = 2\ntry:\n    f()\n"
                   "except UnboundLocalError as e:\n    print(type(e).__name__, e)\n")
    ny_exec = prog("ny_exec.ny", "x = 1\nexec('def f():\\n    x = 2\\nf()')\nprint(x)\n")
    py_exec = prog("py_exec.ny", "# nython: python\nx = 1\nexec('def f():\\n    x = 2\\nf()')\nprint(x)\n")
    warned = prog("warned.ny", "total = 0\nlimit = 3\ndef add(v):\n    total += v\ndef reset():\n    limit = 9\n"
                  "def ok():\n    global total\n    total = 1\ndef local_ok():\n    var limit = 2\n    return limit\n"
                  "def outer():\n    n = 0\n    def inner():\n        n = 5\n    inner()\n    return n\n"
                  "reset()\nprint(limit, outer())\n")
    for engine in [[], ["--vm"]]:
        tag = "vm: " if engine else "interp: "
        check(tag + "a .ny file: an assignment rebinds the module's", run(engine, [nyrule]), [0, "2\n", ""])
        check(tag + "# nython: python: Python's rule", run(engine, [pyrule]), [0, "1\n", ""])
        check(tag + "a .py file: Python's rule", run(engine, [pyfile]), [0, "1\n", ""])
        check(tag + "a def line's `# nython: python` opts it (and its nested defs) in", run(engine, [optin]),
              [0, "1 1\n1 4\n", ""])
        check(tag + "UnboundLocalError's message", run(engine, [unbound]),
              [0, "UnboundLocalError cannot access local variable 'x' where it is not associated with a value\n", ""])
        check(tag + "exec from a .ny file: Nython's rule for its code", run(engine, [ny_exec]), [0, "2\n", ""])
        check(tag + "exec from a Python-language file: Python's rule", run(engine, [py_exec]), [0, "1\n", ""])
    wtext = (warned + ":4:5: warning: function 'add' augments 'total', rebinding the module's 'total' (line 1)"
             " without a declaration - Python's rule makes it a local of the function: declare 'global total' to"
             " keep rebinding it, or 'var total' for a local [nython-scope]\n"
             + warned + ":6:5: warning: function 'reset' assigns 'limit', rebinding the module's 'limit' (line 2)"
             " without a declaration - Python's rule makes it a local of the function: declare 'global limit' to"
             " keep rebinding it, or 'var limit' for a local [nython-scope]\n"
             + warned + ":16:9: warning: function 'outer.<locals>.inner' assigns 'n', rebinding 'n' of the enclosing"
             " function 'outer' (line 14) without a declaration - Python's rule makes it a local of the function:"
             " declare 'nonlocal n' to keep rebinding it, or 'var n' for a local [nython-scope]\n")
    check("-W nython-scope: the warnings", run([], ["-W", "nython-scope", warned]), [0, "9 5\n", wtext])
    check("NY_SCOPE_WARN=1: the same", run(["--vm"], [warned], {"NY_SCOPE_WARN": "1"}), [0, "9 5\n", wtext])
    check("no warnings by default", run([], [warned]), [0, "9 5\n", ""])
    check("no warnings for Python-language files", run([], ["-W", "nython-scope", pyrule]), [0, "1\n", ""])
    rep = run([], ["--scope-report", warned, pyrule])
    check("--scope-report", [rep[0], rep[2]] + [ln.split("\t")[1:] for ln in rep[1].splitlines()],
          [0, "",
           ["4", "5", "add", "total", "aug", "module", "1", "a", "1", "nython", "3", "4"],
           ["6", "5", "reset", "limit", "assign", "module", "2", "a", "0", "nython", "5", "6"],
           ["16", "9", "outer.<locals>.inner", "n", "assign", "function:outer", "14", "a", "0", "nython", "15", "16"],
           ["4", "5", "f", "x", "assign", "module", "2", "a", "0", "python", "3", "4"]])
    for p in [nyrule, pyrule, pyfile, optin, unbound, ny_exec, py_exec, warned]:
        os.remove(p)
    os.rmdir(tmp)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT119 PASSED ===")
