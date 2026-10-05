# vm_audit63.ny - round 76: static scope checks, lambda closures, print's
# argument order and error columns.
#
#   lambdas      capture their scope by reference, as `def` does: a lambda
#                calls itself through the name it is assigned to, and sees
#                a later rebinding (Python's late binding)
#   global       a walrus, `except ... as` and `with ... as` of a name the
#                function declared global bind the module's variable
#   nonlocal     needs a binding in an enclosing function (SyntaxError
#                otherwise, and at module level)
#   const        assigning, augmenting, deleting or re-declaring a const is
#                a SyntaxError, found before the program runs
#   print        evaluates all its arguments before printing any
#   columns      a syntax error names the column where its token starts
#                (it said column 2 for every error)
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit63.ny
#     ./build/nython-cli --vm examples/vm_audit63.ny

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

# The first diagnostic of a source text, as [row, column, message] (0-based
# row and column), or none when it parses.
def diag(src):
    var d = ny_check_syntax(src)
    if len(d) == 0:
        return none
    return d[0]

def diag_msg(src):
    var d = diag(src)
    if d is none:
        return "ok"
    return d[2]

# ── lambdas ──────────────────────────────────────────────────────────────
fact = lambda n: 1 if n <= 1 else n * fact(n - 1)
check("lambda calls itself", fact(5), 120)

def local_fib():
    var fib = lambda n: n if n < 2 else fib(n - 1) + fib(n - 2)
    return fib(15)
check("local lambda calls itself", local_fib(), 610)

var fs = [lambda: i for i in range(3)]
check("comprehension lambdas bind late", [g() for g in fs], [2, 2, 2])

def loop_lambdas():
    var out = []
    for i in range(3):
        out.append(lambda: i)
    return [g() for g in out]
check("loop lambdas bind late", loop_lambdas(), [2, 2, 2])

var made = [(lambda v: lambda: v)(i) for i in range(3)]
check("a factory captures each value", [g() for g in made], [0, 1, 2])
var dflt = [lambda i=i: i for i in range(3)]
check("a default captures each value", [g() for g in dflt], [0, 1, 2])

var base = 10
var add_base = lambda x: x + base
base = 20
check("lambda sees a rebinding", add_base(1), 21)

def counter():
    var n = 0
    def bump():
        nonlocal n
        n += 1
    var get = lambda: n
    bump()
    bump()
    return get()
check("lambda reads an updated enclosing variable", counter(), 2)

def adder_chain():
    var k = 1
    var f = lambda x: lambda y: x + y + k
    k = 100
    return f(2)(3)
check("nested lambdas share the scope", adder_chain(), 105)

# ── global with the binding forms ────────────────────────────────────────
gx = 10
def walrus_global():
    global gx
    if (gx := 5) > 0:
        pass
    return gx
check("walrus of a global", [walrus_global(), gx], [5, 5])

wl = 1
def walrus_local():
    if (wl := 7) > 0:
        pass
    return wl
check("walrus without global is local", [walrus_local(), wl], [7, 1])

gy = 1
def read_gy():
    return gy
def except_global():
    global gy
    try:
        raise ValueError("v")
    except ValueError as gy:
        return type(read_gy()).__name__
check("except-as of a global", except_global(), "ValueError")

ly = 1
def except_local():
    try:
        raise KeyError("k")
    except KeyError as ly:
        return read_ly()
def read_ly():
    return ly
check("except-as without global is local", except_local(), 1)

class Enter:
    def __enter__(self):
        return "entered"
    def __exit__(self, a, b, c):
        return false

gw = 0
def with_global():
    global gw
    with Enter() as gw:
        pass
with_global()
check("with-as of a global", gw, "entered")

lw = 0
def with_local():
    with Enter() as lw:
        pass
    return lw
check("with-as without global is local", [with_local(), lw], ["entered", 0])

# ── nonlocal ─────────────────────────────────────────────────────────────
def nl_ok():
    var a = 1
    def inner():
        nonlocal a
        a = a + 41
    inner()
    return a
check("nonlocal rebinds", nl_ok(), 42)

def nl_param(p):
    def inner():
        nonlocal p
        p = p * 2
    inner()
    return p
check("nonlocal of a parameter", nl_param(21), 42)

def nl_two_up():
    var a = 1
    def mid():
        def inner():
            nonlocal a
            a = 9
        inner()
    mid()
    return a
check("nonlocal two functions up", nl_two_up(), 9)

var nl_none = "def outer():\n    def inner():\n        nonlocal zz\n        zz = 3\n    inner()\n"
check("nonlocal with no binding", diag(nl_none), [2, 17, "no binding for nonlocal 'zz' found"])
check("nonlocal at module level", diag_msg("nonlocal q\n"), "nonlocal declaration not allowed at module level")
check("nonlocal of a module variable", diag_msg("m = 1\ndef f():\n    nonlocal m\n    m = 2\n"), "no binding for nonlocal 'm' found")
check("nonlocal and global", diag_msg("def o():\n    var a = 1\n    def f():\n        global a\n        nonlocal a\n"), "name 'a' is nonlocal and global")
check("nonlocal skips a class body", diag_msg("def o():\n    var a = 1\n    class C:\n        def m(self):\n            nonlocal a\n            a = 2\n    return a\n"), "ok")
check("nonlocal of a later binding", diag_msg("def o():\n    def f():\n        nonlocal a\n        a = 2\n    var a = 1\n    f()\n"), "ok")

# ── const ────────────────────────────────────────────────────────────────
const LIMIT = 64
def read_limit():
    return LIMIT * 2
check("const reads", read_limit(), 128)

def const_in_loop():
    var out = []
    for i in range(3):
        const SQ = i * i
        out.append(SQ)
    return out
check("a const statement that runs again", const_in_loop(), [0, 1, 4])

check("assign a const", diag("const K = 5\nK = 6\n"), [1, 0, "cannot assign to constant 'K' (declared on line 1)"])
check("augment a const", diag_msg("const K = 5\nK += 1\n"), "cannot assign to constant 'K' (declared on line 1)")
check("delete a const", diag_msg("const K = 5\ndel K\n"), "cannot delete constant 'K' (declared on line 1)")
check("redeclare a const", diag_msg("const K = 5\nvar K = 6\n"), "cannot redeclare constant 'K' (declared on line 1)")
check("const over a var", diag_msg("var K = 5\nconst K = 6\n"), "cannot redeclare 'K' as a constant (declared on line 1)")
check("loop over a const", diag_msg("const K = 5\nfor K in range(3):\n    pass\n"), "cannot assign to constant 'K' (declared on line 1)")
check("unpack into a const", diag_msg("const K = 5\na, K = 1, 2\n"), "cannot assign to constant 'K' (declared on line 1)")
check("assign a module const in a function", diag_msg("const K = 5\ndef f():\n    K = 6\n"), "cannot assign to constant 'K' (declared on line 1)")
check("global of a const", diag_msg("const K = 5\ndef f():\n    global K\n    K = 6\n"), "cannot assign to constant 'K' (declared on line 1)")
check("nonlocal of a const", diag_msg("def o():\n    const K = 1\n    def f():\n        nonlocal K\n        K = 2\n"), "cannot assign to constant 'K' (declared on line 2)")
check("a local shadows a const", diag_msg("const K = 5\ndef f():\n    var K = 6\n    K = 7\n    return K\n"), "ok")
check("a parameter shadows a const", diag_msg("const K = 5\ndef f(K):\n    K = 7\n"), "ok")
check("a const's attributes are not the const", diag_msg("const P = [1]\nP.append(2)\nP[0] = 3\n"), "ok")
check("a class attribute of the same name", diag_msg("const K = 5\nclass C:\n    K = 6\n"), "ok")

# ── print evaluates every argument first ─────────────────────────────────
import sys
var exe = sys.executable
if os_exists(exe):
    var pf = os_path_join(os_gettempdir(), "ny_audit63_" + str(os_getpid()) + ".ny")
    write_file(pf, "def a():\n    print(\"in a\")\n    return 1\ndef b():\n    print(\"in b\")\n    return 2\nprint(a(), b())\nprint(a(), b(), sep=\"-\")\n")
    var want = "in a\nin b\n1 2\nin a\nin b\n1-2\n"
    check("print order, interpreter", string_replace(os_run([exe, pf])["stdout"], "\r\n", "\n"), want)
    check("print order, VM", string_replace(os_run([exe, "--vm", pf])["stdout"], "\r\n", "\n"), want)

    # the command line's report: file:row:column and a caret under the token
    write_file(pf, "x = 1\nif x:\n    y = (x + )\n")
    var err = string_replace(os_run([exe, pf])["stderr"], "\r\n", "\n")
    check("reported column", string_find(err, pf + ":3:14: syntax error") >= 0, true)
    # the line, indented by two, then the caret under its 14th character
    check("caret under the token", string_find(err, "      y = (x + )\n" + " " * 15 + "^\n") >= 0, true)
    os_remove(pf)

# ── error columns ────────────────────────────────────────────────────────
check("column of the token", diag("y = )\n")[0:2], [0, 4])
check("column after a tab", diag("if 1:\n\tz = 1 + )\n")[0:2], [1, 9])
check("column after UTF-8", diag("s = \"\u00e9\u00e9\" + )\n")[0:2], [0, 11])
check("column on a later line", diag("a = 1\nb = [1, 2,, 3]\n")[0:2], [1, 10])

# ── lazy iterators ───────────────────────────────────────────────────────
# zip/map/filter/enumerate/islice over a generator are iterators: they print
# as Python prints them and have no send/throw (send() used to act as
# next()). type() stays "generator" for all of them - Nython's dict is the
# type "map" already - and isinstance(x, "generator") is true for every lazy
# iterator (it read false even for a generator).
def three():
    yield 1
    yield 2
    yield 3
var lz = zip(three(), [4, 5, 6])
check("zip prints as zip", string_find(str(lz), "<zip object at ") == 0, true)
check("map prints as map", string_find(str(map(lambda v: v, three())), "<map object at ") == 0, true)
check("a generator prints as one", string_find(str(three()), "<generator object three at ") == 0, true)
def send_to(it):
    try:
        it.send(1)
    except AttributeError as e:
        return str(e)
    return "no error"
check("no send on zip", send_to(lz), "'zip' object has no attribute 'send'")
check("no send on filter", send_to(filter(lambda v: v, three())), "'filter' object has no attribute 'send'")
check("send to a generator still works", three().send(none), 1)
check("zip still iterates", list(lz), [(1, 4), (2, 5), (3, 6)])
check("isinstance of a generator", isinstance(three(), "generator"), true)
check("isinstance of a lazy zip", isinstance(zip(three()), "generator"), true)
check("a list is not one", isinstance([1], "generator"), false)
check("type of each", [type(three()), type(zip(three())), type(enumerate(three()))], ["generator", "generator", "generator"])

# ── sys.maxsize ──────────────────────────────────────────────────────────
import sys
check("sys.maxsize is Python's", sys.maxsize == 2 ** 31 - 1 or sys.maxsize == 2 ** 63 - 1, true)

# ── import nytorch leaves the builtins alone ─────────────────────────────
# On the VM it registered an older block of 171 general builtins again, over
# the current ones: repr of a string with a newline came out unescaped,
# ord() read one byte of UTF-8, sorted() of a generator...
import nytorch
check("repr after import nytorch", repr("a\nb"), "'a\\nb'")
check("ord after import nytorch", ord("\u00e9"), 233)
check("chr after import nytorch", chr(233), "\u00e9")
check("sorted after import nytorch", sorted(x for x in [3, 1, 2]), [1, 2, 3])
check("sum after import nytorch", sum(x for x in [1, 2, 3]), 6)

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT63 PASSED ===")
