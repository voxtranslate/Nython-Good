# vm_audit84.ny - Python's syntax, both engines (round 77).
#
# A conformance battery over Python 3.11's grammar (CPython's
# Grammar/python.gram is the spec): the forms the parser rejected or
# compiled wrongly, and the rest of the statement and expression grammar
# beside them, so a regression in any of them shows here.
#
#   imports      `import os, sys`, `import a.b as c, d`, `from m import (a,
#                b as c,)`, `from os import path as p`
#   del          `del a, b`, `del x[0], y.z`, `del (a, [b])`
#   classes      dotted bases (`class K(weakref.ref)`, `class E(m.Base,
#                metaclass=m.M)`), `class C(**kw)`
#   lambdas      `lambda *, k:`, `lambda *a, **kw:`, `lambda a, /, b:`,
#                defaults, keyword-only defaults
#   soft words   Nython's extra keywords are names wherever Python has a
#                name: `new = old + 1`, `def f(ref):`, `obj.self`, `match =
#                m.match(...)`, `self` outside a method, `var`/`let`/`const`
#   statements   expression statements evaluated in every form (`{}["x"]`
#                raises KeyError), one-line compound statements and `;`,
#                line continuations, global/nonlocal lists, assert messages,
#                with-items (several, parenthesised, `as` any target),
#                every assignment form (`a = b = c, d = 1, 2`, `*rest`,
#                `x = 1, 2`, unpacking counts checked), every augmented
#                assignment (`@=`, `**=`, ...), for targets (`for a, *b in`,
#                `for (p, q), r in`, `for o.attr in`), try/except/else/
#                finally, raise ... from ..., return/yield tuples, exception
#                groups and `except*` (PEP 654)
#   expressions  chained comparisons, conditional expressions, walrus in
#                comprehensions, nested f-strings with !r/!s/specs, numeric
#                literals (`_`, 0x/0o/0b, complex), string and bytes
#                literals and escapes (\N{...}), slices and tuples of
#                slices, `...`, *args/**kw in calls and displays, decorators
#                with any expression, every match pattern kind, async forms
#
# The shared part runs under python3 too (`python3 examples/vm_audit84.ny`);
# every expected value there is CPython's.
#
#     ./build/nython-cli examples/vm_audit84.ny
#     ./build/nython-cli --vm examples/vm_audit84.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def raises(fn, exc):
    try:
        fn()
    except exc:
        return True
    return False

def syntax_error(src):
    try:
        compile(src, "<vm_audit84>", "exec")
    except SyntaxError:
        return True
    return False

# ── imports ──────────────────────────────────────────────────────────────────
import os, sys
check("import a, b", [os.sep, sys.maxsize > 0], ["/" if os.sep == "/" else os.sep, True])
import os.path as op, sys as s2, json
check("import a.b as c, d as e, f", [op.join("a", "b"), s2 is sys, json.dumps([1])], [os.path.join("a", "b"), True, "[1]"])
from os import path as p, sep
check("from os import path as p, sep", [p.basename("/a/b"), sep], ["b", os.sep])
from collections import (OrderedDict,
                         deque as dq,
                         )
check("from m import (a, b as c,) over lines", [type(OrderedDict()).__name__, list(dq([1, 2]))], ["OrderedDict", [1, 2]])
check("ImportError for a missing module", raises(lambda: __import__("no_such_module_xyz84"), ImportError), True)
def missing_name():
    from json import no_such_name_xyz84
check("ImportError for a missing name", raises(missing_name, ImportError), True)
def local_import():
    import json, os.path
    return [json.loads("[2]"), os.path.basename("/q/r")]
check("import a, b in a function", local_import(), [[2], "r"])

# ── del ──────────────────────────────────────────────────────────────────────
da = 1; db = 2; dc = 3
del da, db
check("del a, b", [raises(lambda: da, NameError), raises(lambda: db, NameError), dc], [True, True, 3])
dl = [1, 2, 3, 4]
class Holder:
    pass
dh = Holder()
dh.z = 5
dh.w = 6
del dl[0], dh.z
check("del x[0], y.z", [dl, hasattr(dh, "z"), dh.w], [[2, 3, 4], False, 6])
de = 1; df = 2; dg = 3
del (de, [df]), dg
check("del (a, [b]), c", [raises(lambda: de, NameError), raises(lambda: df, NameError), raises(lambda: dg, NameError)], [True, True, True])
dd = {"a": 1, "b": 2, "c": 3}
del dd["a"], dd["c"]
check("del d[k1], d[k2]", dd, {"b": 2})
dl2 = list(range(10))
del dl2[::3], dl2[0]
check("del with slices", dl2, [2, 4, 5, 7, 8])
def del_unbound():
    du = 1
    del du, du
check("del of an unbound name is NameError", raises(del_unbound, NameError), True)

# ── classes: dotted bases, class keywords ────────────────────────────────────
import weakref
class K(weakref.ref):
    pass
class Target:
    pass
tgt = Target()
kref = K(tgt)
check("class K(weakref.ref)", [issubclass(K, weakref.ref), kref() is tgt], [True, True])
class Meta(type):
    def __new__(mcs, name, bases, ns, **kw):
        cls = super().__new__(mcs, name, bases, ns)
        cls.kw = kw
        return cls
class NSpace:
    class Inner:
        v = 1
    M = Meta
import collections
class E(collections.OrderedDict, metaclass=NSpace.M):
    pass
check("class E(mod.Base, metaclass=ns.M)", [type(E) is Meta, issubclass(E, collections.OrderedDict), E.kw], [True, True, {}])
class F(NSpace.Inner):
    pass
check("class F(NS.Inner)", [F.v, issubclass(F, NSpace.Inner)], [1, True])
opts = {"metaclass": Meta, "flag": 1}
class CK(**opts):
    pass
check("class C(**kw)", [type(CK) is Meta, CK.kw], [True, {"flag": 1}])
class CK2(object, metaclass=Meta, **{"a": 1}):
    pass
check("class C(base, kw=, **kw)", [CK2.kw, CK2.__bases__ == (object,)], [{"a": 1}, True])

# ── lambda parameters ────────────────────────────────────────────────────────
lk = lambda *, k: k
check("lambda *, k", [lk(k=3), raises(lambda: lk(3), TypeError)], [3, True])
lak = lambda *args, **kw: (args, kw)
check("lambda *args, **kw", lak(1, 2, a=3), ((1, 2), {"a": 3}))
lpo = lambda a, /, b: (a, b)
check("lambda a, /, b", [lpo(1, b=2), lpo(1, 2), raises(lambda: lpo(a=1, b=2), TypeError)], [(1, 2), (1, 2), True])
ld = lambda a, b=2, *c, d=4, **e: (a, b, c, d, e)
check("lambda with every kind", [ld(1), ld(1, 5, 6, 7, d=8, z=9)], [(1, 2, (), 4, {}), (1, 5, (6, 7), 8, {"z": 9})])
lkd = lambda *, a=1, b: (a, b)
check("lambda keyword-only defaults", [lkd(b=2), lkd(a=0, b=2)], [(1, 2), (0, 2)])
lpd = lambda a, b=10, /, c=20: a + b + c
check("lambda positional-only default", [lpd(1), lpd(1, 2), lpd(1, 2, c=3)], [31, 23, 6])
check("lambda unexpected keyword", raises(lambda: (lambda x: x)(y=1), TypeError), True)
check("lambda keyword argument", (lambda x, y: x - y)(y=1, x=5), 4)
check("lambda body is one expression", (lambda: (1, 2))(), (1, 2))
check("nested lambdas", (lambda a: lambda b: a * b)(3)(4), 12)

# ── Nython's extra keywords as ordinary names ────────────────────────────────
new = 5
new = new + 1
def double_ref(ref):
    return ref * 2
class Bag:
    pass
bag = Bag()
bag.new = 1
bag.ref = 2
bag.self = 3
bag.var = 4
bag.this = 5
check("new / ref as variables, parameters, attributes", [new, double_ref(ref=3), double_ref(4), bag.new, bag.ref, bag.self, bag.var, bag.this],
      [6, 6, 8, 1, 2, 3, 4, 5])
check("soft words as keyword arguments", dict(new=1, ref=2, self=3, var=4, let=5, const=6, match=7, case=8),
      {"new": 1, "ref": 2, "self": 3, "var": 4, "let": 5, "const": 6, "match": 7, "case": 8})
var = 1; let = 2; const = 3; ref = 4; this = 7
check("var let const ref this", [var, let, const, ref, this], [1, 2, 3, 4, 7])
fn = 1; func = 2; fun = 3; function = 4; struct = 5; enum = 6
check("fn func fun function struct enum", [fn, func, fun, function, struct, enum], [1, 2, 3, 4, 5, 6])
block = 1; loop = 2; repeat = 3; until = 4; unless = 5; then = 6; do = 7
check("block loop repeat until unless then do", [block, loop, repeat, until, unless, then, do], [1, 2, 3, 4, 5, 6, 7])
default = 1; switch = 2; case = 3; match = 4; end = 5; equals = 6; module = 9
check("default switch case match end equals module", [default, switch, case, match, end, equals, module], [1, 2, 3, 4, 5, 6, 9])
interface = 1; package = 2; namespace = 3; use = 5; abstract = 6; static = 7
check("interface package namespace use abstract static", [interface, package, namespace, use, abstract, static], [1, 2, 3, 5, 6, 7])
extends = 1; inherits = 2; implements = 3; final = 4; public = 6; private = 7; protected = 8
check("extends inherits implements final public private protected", [extends, inherits, implements, final, public, private, protected],
      [1, 2, 3, 4, 6, 7, 8])
def operator_words():
    # in a function: a module-level `typeof = 3` would hide Nython's typeof()
    instanceof = 3; subclassof = 4; parentof = 5; xor = 1; sizeof = 2; typeof = 3; execute = 4; delete = 5
    return [instanceof, subclassof, parentof, xor, sizeof, typeof, execute, delete]
check("instanceof subclassof parentof xor sizeof typeof execute delete", operator_words(), [3, 4, 5, 1, 2, 3, 4, 5])
throw = 6; catch = 7
check("throw catch", [throw, catch], [6, 7])
self = "module self"
check("self outside a method", self, "module self")
def free_self(self, new=1):
    return (self, new)
check("self as a plain function's parameter", free_self(1, new=2), (1, 2))
class Rebind:
    def __init__(self, v):
        self.v = v
    def swap(self, other):
        self = other
        return self.v
    def loop_self(self, items):
        out = []
        for self in items:
            out.append(self.v)
        return out
check("self rebound in a method", [Rebind(1).swap(Rebind(2)), Rebind(0).loop_self([Rebind(3), Rebind(4)])], [2, [3, 4]])
def soft_params(new, ref, var, let, const, match, case, default, end, loop, block, do, then, struct):
    return [new, ref, var, let, const, match, case, default, end, loop, block, do, then, struct]
check("soft words as parameters", soft_params(*range(14)), list(range(14)))
lst = [1, 2]
ref = lst
ref.append(3)
ref[0] = 9
check("ref.append / ref[0] = at a statement start", lst, [9, 2, 3])
import re
match = re.match(r"(\d+)", "42abc")
check("match = re.match(...) and match.group", [match.group(1), match.span()], ["42", (0, 2)])
match = None
case = [1]
case[0] += 1
check("case as a name", case, [2])
class Words:
    def new(self, v):
        return v + 1
    def match(self, s):
        return s * 2
    def print(self):
        return "printed"
    def default(self):
        return "d"
words = Words()
check("soft words as method names", [words.new(1), words.match("a"), words.print(), words.default()], [2, "aa", "printed", "d"])
def uses_nonlocal():
    new = 1
    ref = 2
    def inner():
        nonlocal new, ref
        new += 10
        ref += 20
    inner()
    return new, ref
check("nonlocal new, ref", uses_nonlocal(), (11, 22))
gnew = 0
def uses_global():
    global gnew
    gnew = 3
uses_global()
check("global name", gnew, 3)
end = []
for i in range(2):
    pass
end = end + [1]
check("end = after a block", end, [1])
print_ = print
check("names next to keywords", [print_ is print], [True])
def xor(a, b):
    return a ^ b
check("def xor(a, b): a function named after Nython's operator word", xor(6, 3), 5)

# ── expression statements are evaluated ──────────────────────────────────────
check("{}[k] alone raises KeyError", raises(lambda: exec('{}["x"]'), KeyError), True)
def stmt_subscript():
    {}["x"]
def stmt_attr():
    Holder().missing_attribute
def stmt_index():
    [1][5]
def stmt_div():
    1 / 0
def stmt_call_chain():
    "abc".nosuchmethod()
check("expression statements raise", [raises(stmt_subscript, KeyError), raises(stmt_attr, AttributeError),
                                      raises(stmt_index, IndexError), raises(stmt_div, ZeroDivisionError),
                                      raises(stmt_call_chain, AttributeError)],
      [True, True, True, True, True])
calls = []
def side(v):
    calls.append(v)
    return v
side(1)
[side(2)]
(side(3), side(4))
side(5), side(6)
{side(7): side(8)}
{side(9)}
side(10) if side(11) else side(12)
not side(13)
-side(14)
side(15)[0:0] if False else None
check("discarded values are still computed", calls, [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 10, 13, 14])
check("dict display statement", raises(lambda: exec("{'k': [][0]}"), IndexError), True)
def unary_error(src):
    try:
        eval(src)
    except TypeError as e:
        return str(e)
    return "no error"
check("unary operators on the wrong type raise TypeError",
      [unary_error(s) for s in ["-{}", "-[1, 2]", "~[1]", "+'a'", "-None", "~1.5", "-(1,)", "+[1]"]],
      ["bad operand type for unary -: 'dict'", "bad operand type for unary -: 'list'", "bad operand type for unary ~: 'list'",
       "bad operand type for unary +: 'str'", "bad operand type for unary -: 'NoneType'", "bad operand type for unary ~: 'float'",
       "bad operand type for unary -: 'tuple'", "bad operand type for unary +: 'list'"])
check("unary operators on numbers", [-(-2), +3, ~5, -True, +True, ~False, -2 ** 2, (-2) ** 2, -1.5, +2.5], [2, 3, -6, -1, 1, -1, -4, 4, -1.5, 2.5])

# ── one-line compound statements, ';', continuations ─────────────────────────
if 1: oa = 1; ob = 2
check("if x: a; b", [oa, ob], [1, 2])
oc = 0
if 0: pass; oc = 1
check("if 0: pass; x = 1 runs nothing", oc, 0)
od = 0
if 0: del od; od = 1
check("if 0: del a; b = 1", od, 0)
for oi in range(3): pass
check("for ...: pass", oi, 2)
while False: pass
def one_line(x): return x + 1
check("def f(x): return x + 1", one_line(1), 2)
class OneLine: x = 1; y = 2
check("class C: a = 1; b = 2", [OneLine.x, OneLine.y], [1, 2])
try: oz = 1
except Exception: oz = 2
check("try: x / except: y on one line", oz, 1)
with open(__file__) as fh: first_line = fh.readline()
check("with ...: x on one line", first_line.startswith("#"), True)
total = 1 + \
    2 + \
    3
check("backslash continuation", total, 6)
joined = ("a"
          "b"
          'c')
check("implicit string concatenation", joined, "abc")
if (1 and
        2):
    cont = "ok"
check("continuation inside parentheses", cont, "ok")
nums = [1,
        2,
        3,
        ]
check("list over lines, trailing comma", nums, [1, 2, 3])
semi = 0; semi += 1; semi += 2;
check("statements separated by ;", semi, 3)

# ── global / nonlocal / assert ───────────────────────────────────────────────
ga = 0
gb = 0
def set_globals():
    global ga, gb
    ga, gb = 1, 2
set_globals()
check("global a, b", [ga, gb], [1, 2])
def outer_nonlocal():
    p = 1
    q = 2
    def inner():
        nonlocal p, q
        p, q = 10, 20
    inner()
    return [p, q]
check("nonlocal a, b", outer_nonlocal(), [10, 20])
def assert_msg():
    try:
        assert 1 == 2, "nope " + str(3)
    except AssertionError as e:
        return str(e)
check("assert x, msg", assert_msg(), "nope 3")
check("assert x without a message", raises(lambda: exec("assert 0"), AssertionError), True)

# ── with statements ──────────────────────────────────────────────────────────
class CM:
    def __init__(self, n, log):
        self.n = n
        self.log = log
    def __enter__(self):
        self.log.append("enter" + str(self.n))
        return self.n
    def __exit__(self, *a):
        self.log.append("exit" + str(self.n))
        return False
log = []
with CM(1, log) as x, CM(2, log) as y:
    log.append(x + y)
check("with a as x, b as y", log, ["enter1", "enter2", 3, "exit2", "exit1"])
log = []
with (CM(1, log) as x,
      CM(2, log) as y,):
    log.append(x * 10 + y)
check("with (a as x, b as y,) over lines", log, ["enter1", "enter2", 12, "exit2", "exit1"])
log = []
with (CM(3, log)):
    pass
check("with (a):", log, ["enter3", "exit3"])
log = []
with (CM(4, log), CM(5, log)):
    pass
check("with (a, b): two managers", log, ["enter4", "enter5", "exit5", "exit4"])
log = []
with CM(6, log) as bag.attr, CM(8, log) if True else None as wc:
    pass
check("with ... as obj.attr", [bag.attr, wc, log], [6, 8, ["enter6", "enter8", "exit8", "exit6"]])
class PairCM:
    def __enter__(self):
        return (1, [2, 3])
    def __exit__(self, *a):
        return False
with PairCM() as (wa, [wb, wc]):
    pass
check("with ... as (a, [b, c])", [wa, wb, wc], [1, 2, 3])

# ── assignment forms ─────────────────────────────────────────────────────────
x = 1, 2
check("x = 1, 2", x, (1, 2))
y = 3,
check("y = 3,", y, (3,))
a = b = []
a.append(1)
check("a = b = []", b, [1])
t = *range(2), 5
check("t = *it, x", t, (0, 1, 5))
i, = [9]
check("i, = [9]", i, 9)
[j] = [8]
check("[j] = [8]", j, 8)
(k) = 7
check("(k) = 7", k, 7)
a1, b1 = c1, d1 = 1, 2
check("a, b = c, d = 1, 2", [a1, b1, c1, d1], [1, 2, 1, 2])
e1 = (f1, g1) = [3, 4]
check("e = (f, g) = v", [e1, f1, g1], [[3, 4], 3, 4])
first, *mid, last = range(5)
check("first, *mid, last = range(5)", [first, mid, last], [0, [1, 2, 3], 4])
*h, tl = "abc"
check("*h, t = 'abc' (h is a list)", [h, tl], [["a", "b"], "c"])
*h2, = (1, 2)
check("*h, = tuple", h2, [1, 2])
(a2, b2), c2 = (1, 2), 3
check("(a, b), c = (1, 2), 3", [a2, b2, c2], [1, 2, 3])
[a3, [b3, *c3]] = [1, [2, 3, 4]]
check("[a, [b, *c]] = ...", [a3, b3, c3], [1, 2, [3, 4]])
dct = {}
dct["a"], dct["b"] = 1, 2
check("d[a], d[b] = 1, 2", dct, {"a": 1, "b": 2})
bag.p, bag.q = "pq"
check("o.p, o.q = 'pq'", [bag.p, bag.q], ["p", "q"])
L = [0, 0, 0]
L[0], L[2] = 5, 6
L[1:2] = [7, 7]
check("L[i], L[j] = ...; L[a:b] = ...", L, [5, 7, 7, 6])
L[::2] = [1, 1]
check("L[::2] = ...", L, [1, 7, 1, 6])
sa, sb = sb2, sa2 = {"k": 1, "j": 2}
check("unpacking a dict gives its keys", [sa, sb, sb2, sa2], ["k", "j", "k", "j"])
ua, ub = {5}.union({6}) if False else [5, 6]
check("unpacking a conditional expression", [ua, ub], [5, 6])
check("too many values to unpack", raises(lambda: exec("p1, p2 = [1, 2, 3]"), ValueError), True)
check("not enough values to unpack", raises(lambda: exec("p1, p2 = [1]"), ValueError), True)
check("not enough values around a star", raises(lambda: exec("p1, *p2, p3 = [1]"), ValueError), True)
check("too many values from a string", raises(lambda: exec("p1, p2 = 'abc'"), ValueError), True)
check("unpacking a set", sorted([m for m in [*{3, 4}]]), [3, 4])
def unpack_message():
    try:
        q1, q2 = [1]
    except ValueError as e:
        return str(e)
check("unpacking error message", unpack_message(), "not enough values to unpack (expected 2, got 1)")
def unpack_star_message():
    try:
        q1, *q2, q3 = [1]
    except ValueError as e:
        return str(e)
check("unpacking error message, starred", unpack_star_message(), "not enough values to unpack (expected at least 2, got 1)")
sw1 = 1; sw2 = 2
sw1, sw2 = sw2, sw1
check("a, b = b, a", [sw1, sw2], [2, 1])
def gen3():
    yield 1
    yield 2
    yield 3
g1, *g2 = gen3()
check("unpacking a generator", [g1, g2], [1, [2, 3]])

# ── augmented assignment ─────────────────────────────────────────────────────
n = 10
n += 1; n -= 2; n *= 3
check("+= -= *=", n, 27)
n /= 2
check("/=", n, 13.5)
n = 17
n //= 5
check("//=", n, 3)
n %= 2
check("%=", n, 1)
n = 2
n **= 10
check("**=", n, 1024)
n >>= 3
check(">>=", n, 128)
n <<= 2
check("<<=", n, 512)
n &= 0xF0
check("&=", n, 0)
n |= 5
check("|=", n, 5)
n ^= 3
check("^=", n, 6)
class Mat:
    def __init__(self, v):
        self.v = v
    def __matmul__(self, o):
        return Mat(self.v * o.v)
class IMat(Mat):
    def __imatmul__(self, o):
        self.v = self.v * o.v + 1
        return self
m = Mat(2)
m @= Mat(3)
im = IMat(2)
im_before = im
im @= Mat(3)
check("@= (__matmul__, then __imatmul__ in place)", [m.v, im.v, im is im_before, (Mat(2) @ Mat(5)).v], [6, 7, True, 10])
class IOr:
    def __init__(self):
        self.items = []
    def __ior__(self, o):
        self.items.append(o)
        return self
    def __or__(self, o):
        return "binary"
io_ = IOr()
io_ |= 5
check("|= calls __ior__", [type(io_).__name__, io_.items], ["IOr", [5]])
class IPow:
    def __init__(self, v):
        self.v = v
    def __ipow__(self, o):
        return IPow(self.v ** o + 1)
ip = IPow(2)
ip **= 3
check("**= calls __ipow__", ip.v, 9)
lst2 = [1]
alias = lst2
lst2 += [2]
lst2 *= 2
check("list += / *= in place", [lst2, alias is lst2], [[1, 2, 1, 2], True])
dct2 = {"a": 1}
dct2 |= {"b": 2}
check("dict |=", dct2, {"a": 1, "b": 2})
s = "ab"
s *= 2
s += "!"
check("str *= / +=", s, "abab!")
bag.v = 1
bag.v += 5
L2 = [1, 2]
L2[0] += 10
dct2["a"] -= 1
check("o.x += / L[i] += / d[k] -=", [bag.v, L2, dct2["a"]], [6, [11, 2], 0])
tup = (1,)
tup += (2,)
check("tuple +=", tup, (1, 2))
check("x += 1, 2 has a tuple value", raises(lambda: exec("q = 1\nq += 1, 2"), TypeError), True)
aug_t = (0,)
aug_t += 1, 2
check("t += 1, 2", aug_t, (0, 1, 2))

# ── for targets ──────────────────────────────────────────────────────────────
out = []
for fa, *frest in [(1, 2, 3), (4, 5)]:
    out.append([fa, frest])
check("for a, *rest in", out, [[1, [2, 3]], [4, [5]]])
out = []
for *finit, flast in [[1, 2, 3]]:
    out.append([finit, flast])
check("for *init, last in", out, [[[1, 2], 3]])
out = []
for (fp, fq), fr in [((1, 2), 3), ((4, 5), 6)]:
    out.append(fp + fq + fr)
check("for (p, q), r in", out, [6, 15])
out = []
for [fm, fn2] in [[5, 6]]:
    out.append([fm, fn2])
check("for [m, n] in", out, [[5, 6]])
out = []
for bag.counter in range(3):
    out.append(bag.counter)
check("for o.attr in", [out, bag.counter], [[0, 1, 2], 2])
fd = {}
for fd["k"] in "ab":
    pass
check("for d[k] in", fd, {"k": "b"})
out = []
for fx, in [(1,), (2,)]:
    out.append(fx)
check("for x, in", out, [1, 2])
out = []
for fv in 1, 2, 3:
    out.append(fv)
check("for x in 1, 2, 3", out, [1, 2, 3])
out = []
for fi, (fk, fv) in enumerate({"a": 1}.items()):
    out.append([fi, fk, fv])
check("for i, (k, v) in enumerate(...)", out, [[0, "a", 1]])
for fz in []:
    pass
else:
    fz_else = "else ran"
check("for/else", fz_else, "else ran")
def for_local():
    floc = "outer"
    def inner():
        for floc, *fr2 in [(1, 2)]:
            pass
        return floc
    return [inner(), floc]
check("starred for targets are local", for_local(), [1, "outer"])

# ── chained comparisons, conditional expressions, walrus ─────────────────────
ca = 1; cb = 2; cc = 3
check("chained comparisons", [ca < cb < cc, ca < cb > cc, ca == 1 != 2, 1 < 2 <= 2 < 3, 1 < 3 > 2 == 2, ca is not None is not False],
      [True, False, True, True, True, True])
check("chained in / not in", [1 < 2 in [2], 3 not in [1] == True, 1 in [1] in [[1]]], [True, False, True])
cnt = []
def cv(v):
    cnt.append(v)
    return v
cv(1) < cv(0) < cv(5)
check("chained comparisons evaluate each operand once and short-circuit", cnt, [1, 0])
check("conditional expressions", ["y" if ca else "n", "y" if not ca else "n", 1 if 0 else 2 if 0 else 3, (lambda: 1 if cb > 1 else 0)()],
      ["y", "n", 3, 1])
data = [1, 2, 3, 4]
check("walrus in a comprehension", [[yy for xx in data if (yy := xx * 2) > 4], yy], [[6, 8], 8])
check("walrus in a comprehension condition", [w for v in range(5) if (w := v % 3)], [1, 2, 1])
if (wn := len(data)) > 3:
    wres = wn
check("walrus in if", wres, 4)
wl = []
while (wv := len(wl)) < 3:
    wl.append(wv)
check("walrus in while", wl, [0, 1, 2])
check("walrus value", [(wz := 5), wz], [5, 5])

# ── f-strings ────────────────────────────────────────────────────────────────
fx_ = 3.14159
fname = "bob"
fw = 10
check("f-string specs and conversions", f"{fx_:.2f}|{fname!r}|{fname!s}|{fname:>6}|{fx_:{fw}.{2}f}|",
      "3.14|'bob'|bob|   bob|      3.14|")
check("nested f-strings", [f"{f'{fname}'}", f"{'a' + 'b'}", f"{ {'k': 1}['k'] }", f"{[1, 2][0]}", f'{"n " + f"{1 + 1}"}'],
      ["bob", "ab", "1", "1", "n 2"])
check("f-string = and format specs", [f"{fx_=:.1f}", f"{fname = }", f"{3:03d} {255:#x} {255:b} {1234567:,} {0.5:%}"],
      ["fx_=3.1", "fname = 'bob'", "003 0xff 11111111 1,234,567 50.000000%"])
check("f-string braces", f"{{literal}} {'q'} {{{fname}}}", "{literal} q {bob}")
check("f-string !a and !r of a string with quotes", [f"{'é'!a}", f"{chr(39)!r}"], ["'\\xe9'", '"\'"'])
check("f-string over a dict and method call", f"{dict(a=1)['a']}-{'x'.upper()}-{len([1, 2])}", "1-X-2")

# ── numeric literals ─────────────────────────────────────────────────────────
check("underscores and prefixes", [1_000_000, 0x_ff, 0xff_ff, 0o17, 0o_7, 0b1010, 0b_1_0, 0B11, 0O7, 0XAB, 1_0.5, 1e3, 1E-2, .5, 5., 0.],
      [1000000, 255, 65535, 15, 7, 10, 2, 3, 7, 171, 10.5, 1000.0, 0.01, 0.5, 5.0, 0.0])
check("complex literals", [3j, 1.5j, 2 + 3j, (1+2j).real, 1e2j, 0j, 2J], [3j, 1.5j, (2+3j), 1.0, 100j, 0j, 2j])
check("big and negative numbers", [2 ** 100, -0x10, 1_2_3, 0o777], [1267650600228229401496703205376, -16, 123, 511])
check("integer methods on literals", [(255).bit_length(), 0xff .bit_length(), 1.5.is_integer(), 2.0.is_integer()], [8, 8, False, True])

# ── strings and bytes ────────────────────────────────────────────────────────
check("bytes literals", [b"ab\x00c", rb"\n", br"\t", B"x", Rb"\d", b"a" b"b"], [b"ab\x00c", b"\\n", b"\\t", b"x", b"\\d", b"ab"])
check("raw and escaped strings", [r"\n", R"\t", "\x41B\U00000043\101", "\N{LATIN SMALL LETTER A}", "\N{EM DASH}"],
      ["\\n", "\\t", "ABCA", "a", "—"])
check("escapes", ["\t|\\|\'|\"|\a|\b|\f|\v|\0|".encode(), len("\N{SNOWMAN}"), "\N{snowman}" == "☃"],
      [b"\t|\\|'|\"|\x07|\x08|\x0c|\x0b|\x00|", 1, True])
check("prefixes", [u"unicode", U"x", f"{1}", F"{2}", rf"\{3}", fr"{4}\n"], ["unicode", "x", "1", "2", "\\3", "4\\n"])
check("triple-quoted strings", ['''triple
single''', """triple "double" """], ["triple\nsingle", 'triple "double" '])
check("line continuation inside a string", "ab\
cd", "abcd")
check("\\N{...} names every character Python names",
      ["\N{CJK UNIFIED IDEOGRAPH-4E00}" == "一", "\N{HANGUL SYLLABLE GAG}" == "각", "\N{grinning face}" == "\U0001F600",
       "\N{NO-BREAK SPACE}" == "\xa0", "\N{DEGREE SIGN}C" == "\xb0C", f"\N{BULLET} {1}" == "• 1",
       syntax_error('x = "\\N{NO SUCH CHARACTER NAME}"')],
      [True, True, True, True, True, True, True])
import unicodedata
check("unicodedata.name / lookup (the same table)",
      [unicodedata.name("—"), unicodedata.name("a"), unicodedata.name("一"), unicodedata.name("각"),
       unicodedata.lookup("snowman") == "☃", unicodedata.name("\x00", "none"), raises(lambda: unicodedata.lookup("NO SUCH NAME XYZ"), KeyError),
       raises(lambda: unicodedata.name("\x01"), ValueError)],
      ["EM DASH", "LATIN SMALL LETTER A", "CJK UNIFIED IDEOGRAPH-4E00", "HANGUL SYLLABLE GAG", True, "none", True, True])

# ── slices, tuples of slices, Ellipsis ───────────────────────────────────────
SL = list(range(10))
check("slices with steps", [SL[::2], SL[1:8:3], SL[::-1][:3], SL[-3:], SL[:-7:-2], SL[5:2:-1]],
      [[0, 2, 4, 6, 8], [1, 4, 7], [9, 8, 7], [7, 8, 9], [9, 7, 5], [5, 4, 3]])
class G:
    def __getitem__(self, k):
        return k
g = G()
check("tuples of slices and Ellipsis", [g[1:2, ::3], g[..., 1], g[:, 0], g[1:2:3], g[()], g[1,], g[(1, 2)]],
      [(slice(1, 2, None), slice(None, None, 3)), (Ellipsis, 1), (slice(None, None, None), 0), slice(1, 2, 3), (), (1,), (1, 2)])
check("Ellipsis", [..., Ellipsis is ..., str(...)], [Ellipsis, True, "Ellipsis"])
def stub(): ...
check("def f(): ...", stub(), None)

# ── calls and displays with * and ** ─────────────────────────────────────────
def sf(*a, **k):
    return a, k
check("f(*a, *b, k=, **d, **e)", sf(*[1, 2], *(3,), x=1, **{"y": 2}, **{"z": 3}), ((1, 2, 3), {"x": 1, "y": 2, "z": 3}))
check("f(1, *a, 2, k=1)", sf(1, *[2], 3, k=4), ((1, 2, 3), {"k": 4}))
check("starred displays", [[*range(3), *"ab"], (*[1], 2), {*[1, 1], 2}, {**{"a": 1}, "b": 2, **{"c": 3}}],
      [[0, 1, 2, "a", "b"], (1, 2), {1, 2}, {"a": 1, "b": 2, "c": 3}])
import io
buf = io.StringIO()
print(*[1, 2, 3], sep="", file=buf)
print("a", "b", sep="-", end="!", file=buf)
check("print(*a, sep=, end=, file=)", buf.getvalue(), "123\na-b!")
buf2 = io.StringIO()
pr = [print(*"xy", sep="+", end=";", file=buf2), print("z", file=buf2)]
check("print(...) with keywords inside an expression", [pr, buf2.getvalue()], [[None, None], "x+y;z\n"])
check("keyword argument after *args", sf(*[1], k=2, *[3]), ((1, 3), {"k": 2}))

# ── decorators with any expression ───────────────────────────────────────────
decos = [lambda f: f, lambda f: (lambda: f() + 1)]
@decos[1]
def one():
    return 1
class DecoNS:
    @staticmethod
    def times10(f):
        return lambda: f() * 10
@DecoNS.times10
def two():
    return 2
@(lambda f: lambda: f() + 100)
def three():
    return 3
def deco_factory(n):
    def deco(f):
        return lambda: f() + n
    return deco
@deco_factory(5)
@deco_factory(1)
def four():
    return 4
dmap = {"k": deco_factory(7)}
@dmap["k"]
def five():
    return 5
@deco_factory(1) if True else None
def six():
    return 6
check("decorators: subscript, attribute, lambda, stacked calls, dict item, conditional", [one(), two(), three(), four(), five(), six()],
      [2, 20, 103, 10, 12, 7])

# ── match: every pattern kind ────────────────────────────────────────────────
class Point:
    __match_args__ = ("x", "y")
    def __init__(self, x, y):
        self.x = x
        self.y = y
def classify(v):
    match v:
        case 0 | 1:
            return "small"
        case -1:
            return "neg one"
        case 1.5:
            return "float"
        case "s" | b"b":
            return "str or bytes"
        case None:
            return "none"
        case True:
            return "true"
        case [1, 2, *rest]:
            return "list12 " + str(rest)
        case (a, b):
            return "pair " + str(a) + str(b)
        case {"k": val, **others}:
            return "map " + str(val) + str(others)
        case Point(x=0, y=yy):
            return "on y " + str(yy)
        case Point(xx, 0):
            return "on x " + str(xx)
        case int(n) if n > 100:
            return "big " + str(n)
        case str() as s:
            return "other str " + s
        case [Point(x=px), *_]:
            return "points " + str(px)
        case 2 + 3j:
            return "complex"
        case _:
            return "other"
check("match patterns", [classify(v) for v in [0, 1, -1, 1.5, "s", b"b", None, True, [1, 2, 3, 4], (5, 6), {"k": 1, "z": 2},
                                                Point(0, 9), Point(4, 0), 500, "zz", [Point(7, 7)], 2 + 3j, 42]],
      ["small", "small", "neg one", "float", "str or bytes", "str or bytes", "none", "small", "list12 [3, 4]", "pair 56",
       "map 1{'z': 2}", "on y 9", "on x 4", "big 500", "other str zz", "points 7", "complex", "other"])
def match_more(v):
    match v:
        case (1, x) if x > 1:
            return "guard " + str(x)
        case [x, y, *_] if x == y:
            return "same"
        case {"a": [1, {"b": bb}]}:
            return "deep " + str(bb)
        case (1 | 2) as small:
            return "as " + str(small)
        case [*_, "end"]:
            return "ends"
        case str(x) | bytes(x):
            return "text"
    return "fell through"
check("match guards, nesting, as, |", [match_more(v) for v in [(1, 5), [3, 3, 9], {"a": [1, {"b": 7}]}, 2, ["x", "end"], "t", 9.5]],
      ["guard 5", "same", "deep 7", "as 2", "ends", "text", "fell through"])
import math
def dotted(v):
    match v:
        case math.pi:
            return "pi"
        case os.sep:
            return "sep"
        case _:
            return "no"
check("dotted value patterns", [dotted(math.pi), dotted(os.sep), dotted(1)], ["pi", "sep", "no"])
match_hit = None
match 5:
    case mx:
        match_hit = mx
check("match capture", match_hit, 5)
def match_star_tuple(v):
    match v:
        case (first, *others):
            return [first, others]
check("starred capture is a list", match_star_tuple((1, 2, 3)), [1, [2, 3]])

# ── async ────────────────────────────────────────────────────────────────────
import asyncio
async def coro(x):
    await asyncio.sleep(0)
    return x * 2
async def agen(n):
    for i in range(n):
        yield i
        await asyncio.sleep(0)
class ACM:
    async def __aenter__(self):
        return "in"
    async def __aexit__(self, *a):
        return False
async def amain():
    r = await coro(2)
    out = [r]
    async for v in agen(3):
        out.append(v)
    async with ACM() as s:
        out.append(s)
    out.append([v async for v in agen(2)])
    out.append(await asyncio.gather(coro(1), coro(3)))
    t = asyncio.create_task(coro(5))
    out.append(await t)
    out.append([await coro(v) for v in range(2)])
    return out
check("async def / await / async for / async with / async comprehensions", asyncio.run(amain()), [4, 0, 1, 2, "in", [0, 1], [2, 6], 10, [0, 2]])

# ── try / except / else / finally, raise ... from ... ────────────────────────
def tef(n):
    tlog = []
    try:
        if n == 1:
            raise ValueError("v")
        if n == 2:
            raise KeyError("k")
        tlog.append("body")
    except (ValueError, TypeError) as e:
        tlog.append("VT " + str(e))
    except KeyError:
        tlog.append("K")
    else:
        tlog.append("else")
    finally:
        tlog.append("finally")
    return tlog
check("try/except (A, B) as e/except/else/finally", [tef(0), tef(1), tef(2)],
      [["body", "else", "finally"], ["VT v", "finally"], ["K", "finally"]])
def chained():
    try:
        try:
            raise ValueError("inner")
        except ValueError as e:
            raise RuntimeError("outer") from e
    except RuntimeError as e:
        return [type(e.__cause__).__name__, str(e.__cause__)]
check("raise ... from e", chained(), ["ValueError", "inner"])
def from_none():
    try:
        raise ValueError("x") from None
    except ValueError as e:
        return [e.__cause__, e.__suppress_context__]
check("raise ... from None", from_none(), [None, True])
def bare_class():
    try:
        raise ValueError
    except ValueError as e:
        return [type(e).__name__, e.args]
check("raise Class", bare_class(), ["ValueError", ()])
def try_finally_return():
    try:
        return "try"
    finally:
        pass
check("try/finally return", try_finally_return(), "try")
def except_star_names():
    try:
        raise KeyError("a")
    except (KeyError) as e:
        return repr(e)
check("except (A) as e", except_star_names(), "KeyError('a')")

# ── exception groups and except* (Python 3.11) ───────────────────────────────
def outcome(f):
    try:
        f()
        return "no exception"
    except BaseException as e:
        return repr(e)
star_log = []
def st1():
    try:
        raise ValueError(1)
    except* ValueError as e:
        star_log.append(repr(e))
def st2():
    try:
        raise ExceptionGroup("g", [ValueError(1), TypeError(2), KeyError(3)])
    except* ValueError as e:
        star_log.append(repr(e))
    except* TypeError as e:
        star_log.append(repr(e))
def st3():
    try:
        raise ValueError(1)
    except* TypeError:
        pass
def st4():
    try:
        raise ExceptionGroup("g", [ValueError(1), TypeError(2)])
    except* ValueError:
        raise KeyError("new")
def st5():
    try:
        raise ExceptionGroup("g", [ValueError(1), TypeError(2)])
    except* ValueError:
        raise
def st6():
    try:
        raise ValueError(1)
    except* ValueError:
        raise KeyError("x")
def st7():
    try:
        raise ExceptionGroup("g", [ValueError(1), ExceptionGroup("h", [TypeError(2), ValueError(3)])])
    except* ValueError as e:
        star_log.append(repr(e))
def st8():
    try:
        raise ExceptionGroup("g", [ValueError(1), TypeError(2)])
    except* (ValueError, TypeError) as e:
        star_log.append(repr(e))
def st9():
    try:
        raise ValueError(1)
    except* ValueError:
        raise
def st10():
    log = []
    try:
        raise ExceptionGroup("g", [ValueError(1)])
    except* ValueError:
        log.append("handled")
    else:
        log.append("else")
    finally:
        log.append("finally")
    return log
check("except* outcomes", [outcome(f) for f in [st1, st2, st3, st4, st5, st6, st7, st8, st9]],
      ["no exception", "ExceptionGroup('g', [KeyError(3)])", "ValueError(1)",
       "ExceptionGroup('', [KeyError('new'), ExceptionGroup('g', [TypeError(2)])])",
       "ExceptionGroup('g', [ValueError(1), TypeError(2)])", "KeyError('x')",
       "ExceptionGroup('g', [ExceptionGroup('h', [TypeError(2)])])", "no exception", "ExceptionGroup('', (ValueError(1),))"])
check("except* bindings", star_log,
      ["ExceptionGroup('', (ValueError(1),))", "ExceptionGroup('g', [ValueError(1)])", "ExceptionGroup('g', [TypeError(2)])",
       "ExceptionGroup('g', [ValueError(1), ExceptionGroup('h', [ValueError(3)])])", "ExceptionGroup('g', [ValueError(1), TypeError(2)])"])
check("except* with finally", st10(), ["handled", "finally"])
eg = ExceptionGroup("g", [ValueError(1), TypeError(2)])
check("ExceptionGroup API", [str(eg), repr(eg.split(ValueError)), repr(eg.subgroup(lambda e: isinstance(e, TypeError))),
                             type(BaseExceptionGroup("x", [ValueError()])).__name__, type(BaseExceptionGroup("x", [KeyboardInterrupt()])).__name__,
                             str(ExceptionGroup("one", [ValueError()])), eg.message, len(eg.exceptions), isinstance(eg, Exception)],
      ["g (2 sub-exceptions)", "(ExceptionGroup('g', [ValueError(1)]), ExceptionGroup('g', [TypeError(2)]))",
       "ExceptionGroup('g', [TypeError(2)])", "ExceptionGroup", "BaseExceptionGroup", "one (1 sub-exception)", "g", 2, True])
check("ExceptionGroup errors", [raises(lambda: ExceptionGroup("x", [KeyboardInterrupt()]), TypeError), raises(lambda: ExceptionGroup("x", []), ValueError),
                                syntax_error("try:\n    pass\nexcept* ValueError:\n    pass\nexcept TypeError:\n    pass")],
      [True, True, True])
def star_eg_type():
    try:
        raise ValueError(1)
    except* ExceptionGroup:
        pass
check("except* ExceptionGroup is a TypeError", raises(star_eg_type, TypeError), True)

# ── return / yield forms ─────────────────────────────────────────────────────
def r1():
    return
def r2():
    return 1, 2
def r3():
    return (1, 2)
def r4():
    return *[1, 2], 3
def r5():
    return 1,
check("return forms", [r1(), r2(), type(r2()).__name__, r3(), r4(), r5()], [None, (1, 2), "tuple", (1, 2), (1, 2, 3), (1,)])
def g_forms():
    yield
    yield 1
    yield 1, 2
    x = yield
    yield x
    yield from [7, 8]
    y = yield from g_sub()
    yield y
    yield *[1], 2
def g_sub():
    yield 9
    return "ret"
gen = g_forms()
check("yield forms", [next(gen), next(gen), next(gen), next(gen), gen.send("sent"), next(gen), next(gen), next(gen), next(gen), next(gen)],
      [None, 1, (1, 2), None, "sent", 7, 8, 9, "ret", (1, 2)])
def g_assign():
    got = yield 1, 2
    yield got
ga2 = g_assign()
check("x = yield a, b", [next(ga2), ga2.send("v")], [(1, 2), "v"])

# ── parameters: keyword-only and positional-only with defaults ───────────────
def pk(a, b=2, /, c=3, *, d, e=5, **kw):
    return a, b, c, d, e, kw
check("def f(a, b=2, /, c=3, *, d, e=5, **kw)", [pk(1, d=4), pk(1, 9, c=8, d=7, z=1)], [(1, 2, 3, 4, 5, {}), (1, 9, 8, 7, 5, {"z": 1})])
def pq(a, /, *, b):
    return a, b
check("def f(a, /, *, b)", [pq(1, b=2), raises(lambda: pq(a=1, b=2), TypeError), raises(lambda: pq(1, 2), TypeError)], [(1, 2), True, True])
def kwo(*, a=1, b):
    return a, b
check("def f(*, a=1, b)", kwo(b=2), (1, 2))
def ann(a: int, b: "str" = "x", *args: int, c: float = 1.0, **kw: dict) -> list:
    return [a, b, args, c, kw]
check("annotated parameters", [ann(1), ann(1, "y", 2, 3, c=2.0, d=4), sorted(ann.__annotations__)],
      [[1, "x", (), 1.0, {}], [1, "y", (2, 3), 2.0, {"d": 4}], ["a", "args", "b", "c", "kw", "return"]])

# ── syntax errors stay syntax errors ─────────────────────────────────────────
check("syntax errors", [syntax_error("x = *a"), syntax_error("del"), syntax_error("import"), syntax_error("lambda *: 0"),
                        syntax_error("f(**)"), syntax_error("a, b += 1, 2")],
      [True, True, True, True, True, True])
check("valid sources compile", [syntax_error("import a, b"), syntax_error("del a, b"), syntax_error("lambda *, k: k"),
                                syntax_error("x = *a, b"), syntax_error("for a, *b in c: pass"), syntax_error("new = 1")],
      [False, False, False, False, False, False])

# ── Nython only: the constructs the soft keywords stand for still work ──────
if nython:
    nyns = {}
    exec("class Box:\n    def __init__(self, v=0):\n        self.v = v\nb1 = new Box(3)\nb2 = new Box\nvar vx = 1\nlet lx = 2\nconst cx = 3\nref rx = [4]\n", nyns)
    check("Nython: new A() / new A / var / let / const / ref", [nyns["b1"].v, nyns["b2"].v, nyns["vx"], nyns["lx"], nyns["cx"], nyns["rx"]],
          [3, 0, 1, 2, 3, [4]])
    exec("out = []\nloop:\n    out.append(1)\n    if len(out) == 2:\n        break\nrepeat 3:\n    out.append(2)\nunless len(out) > 9:\n    out.append(3)\n", nyns)
    check("Nython: loop / repeat N / unless", nyns["out"], [1, 1, 2, 2, 2, 3])
    exec("enum Color: RED, GREEN\nstruct Pt: x, y=0\np = Pt(1)\nsw = 0\nswitch 2:\n    case 1:\n        sw = 1\n    case 2:\n        sw = 2\n", nyns)
    check("Nython: enum / struct / switch", [nyns["Color"]["GREEN"], nyns["p"].x, nyns["p"].y, nyns["sw"]], [1, 1, 0, 2])
    exec("class Th:\n    def __init__(self):\n        self.v = 5\n    def get(self):\n        return this.v\nthv = Th().get()\nfn sq(x) { return x * x }\nsqv = sq(4)\n", nyns)
    check("Nython: this / fn", [nyns["thv"], nyns["sqv"]], [5, 16])
    exec("this = 'plain'\nthat = this\nnew = 1\nnew2 = new + 1\n", nyns)
    check("Nython: this / new outside their constructs are names", [nyns["that"], nyns["new2"]], ["plain", 2])
    check("Nython: typeof(x) and sizeof(x)", [typeof(1), sizeof([1, 2])], ["int", 2])
    import keyword
    check("Nython: keyword.nysoftkwlist / nyhardkwlist",
          [keyword.isnysoftkeyword("new"), keyword.isnysoftkeyword("self"), keyword.isnysoftkeyword("var"),
           keyword.isnysoftkeyword("true"), "null" in keyword.nyhardkwlist, keyword.isnykeyword("ref"),
           len(keyword.nysoftkwlist) + len(keyword.nyhardkwlist) == len(keyword.nykwlist)],
          [True, True, True, False, True, True, True])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT84 PASSED ===")
