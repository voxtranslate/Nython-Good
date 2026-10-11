# vm_audit98.ny - the VM's specializing adaptive interpreter (round 80).
#
# Generic instructions rewrite themselves into specialized forms after a
# couple of runs (quickening) and back when their guards keep failing
# (deopt). Every scenario here first runs a site long enough for it to
# specialize, then changes what it sees - a class attribute, a method of a
# base class, an object's __class__, a global, a shadowed builtin, an int
# overflowing into a big int, a receiver of another class, a descriptor
# appearing, tracing switched on - and checks that the answers are still
# Python's. The interpreter has no quickening, but the test must give the
# same answers there and under python3 (`python3 examples/vm_audit98.ny`).
#
#     ./build/nython-cli examples/vm_audit98.ny
#     ./build/nython-cli --vm examples/vm_audit98.ny
#     NY_QUICK_STATS=1 ./build/nython-cli --vm examples/vm_audit98.ny   # what specialized
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

N = 120          # runs of a site before the change: past warm-up and many misses' worth
H = 60           # where in a loop of N the change happens

# ── names: locals, module globals, builtins ──────────────────────────────────
G1 = 1
def read_g1():
    return G1
seen = []
for i in range(N):
    if i == H:
        G1 = 2                       # a module global rebound after LOAD_NAME specialized
    seen.append(read_g1())
check("global rebound at module level", [seen[0], seen[H - 1], seen[H], seen[N - 1], seen.count(1), seen.count(2)],
      [1, 1, 2, 2, H, N - H])

def set_g1(v):
    global G1
    G1 = v
seen = []
for i in range(N):
    if i % 40 == 0:
        set_g1(i)                    # rebound through `global` from a function
    seen.append(read_g1())
check("global rebound by a function", [seen[0], seen[39], seen[40], seen[80], seen[N - 1]], [0, 0, 40, 80, 80])

G2 = "a"
def read_g2():
    return G2
seen = []
for i in range(N):
    if i == H:
        del G2                       # the global goes ...
        G3 = 0
        G2 = "b"                     # ... and comes back in another slot
    seen.append(read_g2())
check("global deleted and made again", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["a", "a", "b", "b"])

def read_gone():
    return G_GONE
G_GONE = 5
seen = []
for i in range(N):
    if i == H:
        del G_GONE
    try:
        seen.append(read_gone())
    except NameError:
        seen.append("NameError")
check("global deleted: NameError", [seen[0], seen[H - 1], seen[H], seen[N - 1]], [5, 5, "NameError", "NameError"])

def use_len(x):
    return len(x)
seen = []
for i in range(N):
    if i == H:
        len = lambda x: -1           # a builtin shadowed by a module global later
    seen.append(use_len([1, 2, 3]))
del len
check("builtin shadowed after specializing", [seen[0], seen[H - 1], seen[H], seen[N - 1], use_len("ab")], [3, 3, -1, -1, 2])

def local_order(flag):
    if flag:
        a = 1
        b = 2
    else:
        b = 3
        a = 4
    return a * 10 + b
check("locals made in different orders",
      [local_order(i % 3 == 0) for i in range(30)],
      [local_order(True) if i % 3 == 0 else local_order(False) for i in range(30)])
check("locals made in different orders (values)", [local_order(True), local_order(False)], [12, 43])

def local_deleted(n):
    out = []
    for i in range(n):
        x = i
        if i % 2:
            del x
            x = -i
        y = x
        out.append(y)
    return out
check("a local deleted and bound again", local_deleted(8), [0, -1, 2, -3, 4, -5, 6, -7])

def counter_loop(n):
    t = 0
    for i in range(n):
        t = t + i
    return t
check("store to a local in a loop", [counter_loop(100), counter_loop(5)], [4950, 10])

# ── integers that overflow 64 bits, floats, mixes ────────────────────────────
def add(a, b):
    return a + b
def sub(a, b):
    return a - b
def mul(a, b):
    return a * b
for i in range(N):
    add(i, 1)
    sub(i, 1)
    mul(i, 3)
big = 9223372036854775807
check("int + int overflowing into a big int", [add(big, 1), add(big, big), add(-big, -2)],
      [9223372036854775808, 18446744073709551614, -9223372036854775809])
check("int - int overflowing", [sub(-big, 2), sub(big, -1)], [-9223372036854775809, 9223372036854775808])
check("int * int overflowing", [mul(big, 2), mul(4294967296, 4294967296), mul(-big - 1, -1)],
      [18446744073709551614, 18446744073709551616, 9223372036854775808])
check("a big int at a site specialized for small ints", [add(2 ** 70, 1), sub(2 ** 70, 2 ** 70), mul(2 ** 40, 2 ** 40)],
      [1180591620717411303425, 0, 1208925819614629174706176])
check("floats and mixes at an int site", [add(1, 2.5), add(2.5, 1), add(0.1, 0.2), sub(1, 0.5), mul(3, 0.5), mul(-0.0, 1)],
      [3.5, 3.5, 0.30000000000000004, 0.5, 1.5, -0.0])
check("bools at an int site", [add(True, 1), add(True, True), mul(False, 5), sub(True, False)], [2, 2, 0, 1])
check("strings, lists, tuples at a number site", [add("a", "b"), add([1], [2]), mul("ab", 3), add((1,), (2,))],
      ["ab", [1, 2], "ababab", (1, 2)])

def acc_inplace(n, start, step):
    t = start
    for i in range(n):
        t += step
    return t
check("+= at an int site crossing 2**63", [acc_inplace(4, big - 2, 1), acc_inplace(3, 1, 0.5), acc_inplace(2, "x", "y")],
      [9223372036854775809, 2.5, "xyy"])
def sub_inplace(n, start, step):
    t = start
    for i in range(n):
        t -= step
        t *= 1
    return t
check("-= and *= at an int site", [sub_inplace(50, 0, 1), sub_inplace(3, -big, 1), sub_inplace(2, 1.0, 0.25)],
      [-50, -9223372036854775810, 0.5])

def div(a, b):
    return a / b
def fdiv(a, b):
    return a // b
def mod(a, b):
    return a % b
for i in range(N):
    div(i, 3)
    fdiv(i, 3)
    mod(i, 7)
errs = []
for f in [div, fdiv, mod]:
    try:
        f(1, 0)
        errs.append("none")
    except ZeroDivisionError:
        errs.append("ZeroDivisionError")
check("division by zero after specializing", errs, ["ZeroDivisionError", "ZeroDivisionError", "ZeroDivisionError"])
check("true division at a specialized site", [div(7, 2), div(-7, 2), div(1, 3), div(2 ** 60, 3), div(7.5, 2.5), div(10 ** 20, 10 ** 19)],
      [3.5, -3.5, 0.3333333333333333, 384307168202282325.3333333333333333, 3.0, 10.0])
check("floor division and modulo signs", [fdiv(-7, 2), fdiv(7, -2), mod(-7, 3), mod(7, -3), fdiv(-big - 1, -1), mod(-big - 1, -1)],
      [-4, -4, 2, -2, 9223372036854775808, 0])
check("floor division of floats at an int site", [fdiv(7.5, 2), mod(7.5, 2), mod("%d!", 5)], [3.0, 1.5, "5!"])

def lt(a, b):
    return a < b
def le(a, b):
    return a <= b
def eq(a, b):
    return a == b
def ne(a, b):
    return a != b
for i in range(N):
    lt(i, 5)
    le(i, 5)
    eq(i, 5)
    ne(i, 5)
nan = float("nan")
check("comparisons: ints, floats, NaN", [lt(1, 2), lt(2, 1), le(2, 2), eq(3, 3), ne(3, 3), lt(1.5, 2.5), lt(nan, 1.0), le(nan, nan), eq(nan, nan), ne(nan, nan)],
      [True, False, True, True, False, True, False, False, False, True])
check("comparisons of mixes and big ints at an int site",
      [lt(1, 1.5), eq(1, 1.0), lt(2 ** 64, 2 ** 65), eq(2 ** 64, 2 ** 64), lt(9007199254740993, 9007199254740992.0), eq(True, 1), lt("a", "b"), eq([1], [1])],
      [True, True, True, True, False, True, True, True])
check("-0.0 == 0.0", [eq(-0.0, 0.0), lt(-0.0, 0.0)], [True, False])

# ── class attributes, methods added later, __class__ ─────────────────────────
class K:
    x = 1
def read_kx():
    return K.x
seen = []
for i in range(N):
    if i == H:
        K.x = 2                      # a class attribute changed after LOAD_ATTR specialized
    seen.append(read_kx())
check("class attribute changed", [seen[0], seen[H - 1], seen[H], seen[N - 1]], [1, 1, 2, 2])

class KBase:
    y = "base"
class KSub(KBase):
    pass
def read_ky():
    return KSub.y
seen = []
for i in range(N):
    if i == H:
        KSub.y = "sub"               # shadows the base's attribute
    if i == H + 20:
        del KSub.y                   # and goes again
    if i == H + 40:
        KBase.y = "base2"
    seen.append(read_ky())
check("class attribute shadowed and unshadowed", [seen[0], seen[H], seen[H + 19], seen[H + 20], seen[H + 40], seen[N - 1]],
      ["base", "sub", "sub", "base", "base2", "base2"])

class Animal:
    def speak(self):
        return "..."
class Dog(Animal):
    pass
def dog_speaks(d):
    return d.speak()
def bark(self):
    return "woof"
d = Dog()
seen = []
for i in range(N):
    if i == H:
        Dog.speak = bark             # a method added to the subclass after the call site specialized
    seen.append(dog_speaks(d))
check("method added to the class later", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["...", "...", "woof", "woof"])

def loud(self):
    return "LOUD"
seen = []
del Dog.speak
for i in range(N):
    if i == H:
        Animal.speak = loud          # the base's method replaced
    seen.append(dog_speaks(d))
check("base method replaced later", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["...", "...", "LOUD", "LOUD"])

class Greeter:
    def hello(self, name):
        return "hello " + name
g = Greeter()
seen = []
for i in range(N):
    if i == H:
        g.hello = lambda name: "hi " + name   # an instance attribute shadows the method
    seen.append(g.hello("x"))
check("instance attribute shadows a cached method", [seen[0], seen[H], seen[N - 1]], ["hello x", "hi x", "hi x"])

class Ca:
    def f(self):
        return "A"
    def g(self, k):
        return k + 1
class Cb:
    def f(self):
        return "B"
    def g(self, k):
        return k + 2
o = Ca()
seen = []
for i in range(N):
    if i == H:
        o.__class__ = Cb             # the receiver changes class
    seen.append(o.f() + str(o.g(i)))
check("__class__ reassigned", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["A1", "A60", "B62", "B121"])

class Pt:
    def __init__(self, x, y):
        self.x = x
        self.y = y
def sum_pt(p):
    return p.x + p.y
pts = [Pt(i, 2 * i) for i in range(10)]
seen = []
for i in range(N):
    p = pts[i % 10]
    if i == H:
        class PtProp(object):        # a data descriptor named x appears (a new class)
            @property
            def x(self):
                return 1000
        p2 = Pt(1, 1)
        p2.__class__ = PtProp
        seen.append(("prop", p2.x, p2.y))
    seen.append(sum_pt(p))
check("instance field reads around a new data descriptor", [seen[0], seen[H], seen[H + 1], seen[N]], [0, ("prop", 1000, 1), 0, 27])

class Fld:
    def __init__(self):
        self.v = 1
fo = Fld()
def read_v(o):
    return o.v
seen = []
for i in range(N):
    if i == H:
        Fld.v = property(lambda self: 7)   # a property on the class now wins over the field
    seen.append(read_v(fo))
check("a property set on the class later", [seen[0], seen[H - 1], seen[H], seen[N - 1]], [1, 1, 7, 7])

class Stor:
    def __init__(self):
        self.v = 0
so = Stor()
setlog = []
def store_v(o, x):
    o.v = x
def stor_get(self):
    return -1
def stor_set(self, x):
    setlog.append(x)
for i in range(N):
    if i == H:
        Stor.v = property(stor_get, stor_set)   # stores now go to the setter
    store_v(so, i)
check("a property with a setter set on the class after stores specialized",
      [len(setlog), setlog[0], setlog[-1], so.v], [N - H, H, N - 1, -1])

class Lazy:
    def __init__(self):
        self.here = 1
def read_missing(o):
    try:
        return o.there
    except AttributeError:
        return "missing"
lz = Lazy()
seen = []
for i in range(N):
    if i == H:
        Lazy.__getattr__ = lambda self, name: "from __getattr__ " + name
    seen.append(read_missing(lz))
check("__getattr__ appearing later", [seen[0], seen[H], seen[N - 1], lz.here], ["missing", "from __getattr__ there", "from __getattr__ there", 1])

class Watch:
    def __init__(self):
        self.a = 1
wo = Watch()
def read_a(o):
    return o.a
seen = []
calls = []
def ga(self, name):
    calls.append(name)
    return object.__getattribute__(self, name) * 100
for i in range(N):
    if i == H:
        Watch.__getattribute__ = ga
    seen.append(read_a(wo))
check("__getattribute__ appearing later", [seen[0], seen[H - 1], seen[H], seen[N - 1], len(calls)], [1, 1, 100, 100, N - H])

# ── polymorphic sites ────────────────────────────────────────────────────────
class S1:
    def area(self):
        return 1
class S2:
    def area(self):
        return 2
class S3:
    def area(self):
        return 3
class S4:
    def area(self):
        return 4
class S5:
    def area(self):
        return 5
class S6(S5):
    pass
shapes = [S1(), S2(), S3(), S4(), S5(), S6()]
def total_area(objs):
    t = 0
    for s in objs:
        t += s.area()
    return t
check("a call site seeing two, four, six classes",
      [total_area(shapes[:2] * 30), total_area(shapes[:4] * 30), total_area(shapes * 30), total_area(shapes[4:] * 10)],
      [90, 300, 600, 100])

class Lay1:
    def __init__(self):
        self.p = 1
        self.q = 2
class Lay2:
    def __init__(self):
        self.q = 20                  # the same fields, in another order (another slot)
        self.p = 10
lays = [Lay1(), Lay2()] * 40
check("attribute reads with different field layouts", [sum(o.p + o.q for o in lays), [o.q for o in lays[:4]]],
      [1320, [2, 20, 2, 20]])

def set_field(o, v):
    o.p = v
for i in range(N):
    set_field(lays[i % 2], i)
check("attribute stores with different field layouts", [lays[0].p, lays[1].p, lays[0].q, lays[1].q], [118, 119, 2, 20])

class Dynamic:
    pass
def fill(o, i):
    o.first = i
    o.second = i * 2
    return o.first + o.second
check("fields added at a specialized store site", [fill(Dynamic(), i) for i in range(5)] + [fill(Dynamic(), 100)], [0, 3, 6, 9, 12, 300])

def callee_changes(f, x):
    return f(x)
def plain1(x):
    return x + 1
def gen1(x):
    yield x
class Box:
    def __init__(self, x):
        self.x = x
seen = []
for i in range(N):
    seen.append(callee_changes(plain1, i))
seen.append(list(callee_changes(gen1, 5)))
seen.append(callee_changes(Box, 7).x)
seen.append(callee_changes(len, [1, 2]))
seen.append(callee_changes(lambda x: x * 2, 21))
seen.append(callee_changes(Greeter().hello, "bound"))
check("a call site whose callee changes kind", seen[N - 1:], [N, [5], 7, 2, 42, "hello bound"])

def two_args(a, b):
    return (a, b)
def defaults(a, b=5):
    return (a, b)
def star(*a):
    return a
def via(f, x):
    return f(x)
seen = []
for i in range(N):
    seen.append(via(defaults, i))
seen.append(via(star, 1))
try:
    via(two_args, 1)
    seen.append("no error")
except TypeError:
    seen.append("TypeError")
check("arity differences at a specialized call site", seen[N - 1:], [(N - 1, 5), (1,), "TypeError"])

# ── classmethods, staticmethods, properties, __slots__, dict subclasses ──────
class Meth:
    count = 0
    def __init__(self, v):
        self.v = v
    @classmethod
    def make(cls, v):
        return cls(v)
    @staticmethod
    def twice(v):
        return v * 2
    @property
    def double(self):
        return self.v * 2
    @double.setter
    def double(self, x):
        self.v = x // 2
def meth_loop(n):
    t = 0
    for i in range(n):
        m = Meth.make(i)
        t += Meth.twice(i) + m.double
        m.double = 10
        t += m.v
    return t
check("classmethod, staticmethod, property in a loop", [meth_loop(50), meth_loop(3)], [5150, 27])

class Slotted:
    __slots__ = ("a", "b")
    def __init__(self, a, b):
        self.a = a
        self.b = b
def slot_loop(n):
    objs = [Slotted(i, -i) for i in range(n)]
    t = 0
    for o in objs:
        o.a = o.a + 1
        t += o.a + o.b
    try:
        objs[0].c = 1
        t = "no error"
    except AttributeError:
        pass
    return t
check("__slots__ instances", [slot_loop(80), slot_loop(2)], [80, 2])

class MyDict(dict):
    def total(self):
        return sum(self.values())
def dict_loop(n):
    d = MyDict()
    for i in range(n):
        d[i % 7] = d.get(i % 7, 0) + i
    d.label = "x"
    return [d.total(), len(d), sorted(d.keys())[:3], d.label, isinstance(d, dict)]
check("a dict subclass", dict_loop(100), [4950, 7, [0, 1, 2], "x", True])

# ── generators, recursion ────────────────────────────────────────────────────
def gen_loop(n):
    acc = 0
    for i in range(n):
        acc = acc + i
        if i % 10 == 9:
            yield acc
def drive(n):
    out = []
    for v in gen_loop(n):
        out.append(v)
    return out
check("generators across specialized loops", [drive(50), drive(20)], [[45, 190, 435, 780, 1225], [45, 190]])

def interleave():
    a = gen_loop(40)
    b = gen_loop(40)
    return [next(a), next(b), next(a), next(a), next(b)]
check("two suspended frames of one code object", interleave(), [45, 45, 190, 435, 190])

def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
check("recursion", [fib(20), fib(1), fib(0)], [6765, 1, 0])

def depth(n):
    return 0 if n == 0 else 1 + depth(n - 1)
def bottomless(n):
    return bottomless(n + 1)
check("deep recursion after specializing", depth(400), 400)
try:
    bottomless(0)
    rec = "no error"
except RecursionError:
    rec = "RecursionError"
check("RecursionError at a specialized call site", [rec, depth(100)], ["RecursionError", 100])

def raises_in_loop(n):
    out = []
    for i in range(n):
        try:
            if i % 3 == 0:
                raise ValueError(i)
            out.append(i * 2)
        except ValueError as e:
            out.append(-i)
    return out
check("exceptions inside specialized loops", raises_in_loop(7), [0, 2, 4, -3, 8, 10, -6])

# ── exceptions crossing specialized calls ────────────────────────────────────
def level3(k):
    if k % 2:
        raise KeyError(k)
    return k
def level2(k):
    return level3(k) + 1
def level1(k):
    return level2(k) * 2
caught = []
for i in range(N):
    try:
        level1(i)
    except KeyError as e:
        caught.append(e.args[0])
check("an exception through three specialized calls", [len(caught), caught[:3], caught[-1]], [N // 2, [1, 3, 5], N - 1])

def tb_names(e):
    out = []
    tb = e.__traceback__
    while tb is not None:
        out.append(tb.tb_frame.f_code.co_name)
        tb = tb.tb_next
    return out
def tb_lines(e, base):
    out = []
    tb = e.__traceback__
    while tb is not None:
        out.append(tb.tb_lineno - base)
        tb = tb.tb_next
    return out
def deep_raise(n):
    if n == 0:
        raise ValueError("bottom")
    return deep_raise(n - 1)
def tb_probe():
    try:
        deep_raise(3)
    except ValueError as e:
        return e
base_line = deep_raise.__code__.co_firstlineno
for i in range(N):
    last = tb_probe()
check("the traceback of an exception through specialized calls",
      [tb_names(last), tb_lines(last, base_line)[1:]],
      [["tb_probe", "deep_raise", "deep_raise", "deep_raise", "deep_raise"], [3, 3, 3, 2]])

order = []
def fin_inner(i):
    try:
        if i % 3 == 0:
            raise RuntimeError(i)
        return i
    finally:
        order.append(("inner", i))
def fin_outer(i):
    try:
        return fin_inner(i) * 10
    finally:
        order.append(("outer", i))
got = []
for i in range(9):
    try:
        got.append(fin_outer(i))
    except RuntimeError as e:
        got.append(("err", e.args[0]))
check("finally blocks of specialized frames an exception leaves",
      [got, order[:6]],
      [[("err", 0), 10, 20, ("err", 3), 40, 50, ("err", 6), 70, 80],
       [("inner", 0), ("outer", 0), ("inner", 1), ("outer", 1), ("inner", 2), ("outer", 2)]])

def reraiser(i):
    try:
        raise TypeError("t%d" % i)
    except TypeError:
        if i % 2:
            raise
        raise ValueError("v%d" % i)
def from_raiser(i):
    try:
        reraiser(i)
    except TypeError as e:
        raise LookupError("from") from e
seen = []
for i in range(6):
    try:
        from_raiser(i)
    except LookupError as e:
        seen.append(("lookup", type(e.__cause__).__name__, e.__suppress_context__))
    except ValueError as e:
        seen.append(("value", type(e.__context__).__name__, str(e)))
check("re-raise, raise from, __context__ across specialized calls", seen,
      [("value", "TypeError", "v0"), ("lookup", "TypeError", True), ("value", "TypeError", "v2"),
       ("lookup", "TypeError", True), ("value", "TypeError", "v4"), ("lookup", "TypeError", True)])

def keyerr(d, k):
    return d[k]
dd = {"a": 1, 2: "two", (1, 2): "tuple", 2.5: "float"}
for i in range(N):
    keyerr(dd, "a")
seen = [keyerr(dd, 2), keyerr(dd, (1, 2)), keyerr(dd, 2.5)]
try:
    keyerr(dd, "zz")
    seen.append("no error")
except KeyError as e:
    seen.append(("KeyError", e.args[0]))
seen.append(keyerr([10, 20, 30], -1))
check("dict reads at a specialized site: other keys, a missing key, a list", seen,
      [ "two", "tuple", "float", ("KeyError", "zz"), 30])

def setkey(d, k, v):
    d[k] = v
    return d
for i in range(N):
    setkey({}, "k", i)
check("dict and list stores at a specialized site",
      [setkey({}, "x", 1), setkey({1: 0}, 1, 2), setkey([0, 0], 1, 5), setkey([0, 0], -2, 7)],
      [{"x": 1}, {1: 2}, [0, 5], [7, 0]])

def getitem(seq, i):
    return seq[i]
for i in range(N):
    getitem([1, 2, 3], i % 3)
errs = []
for s in [[1, 2, 3], (4, 5, 6), "abc", range(10, 13)]:
    errs.append(getitem(s, -1))
    try:
        getitem(s, 3)
        errs.append("no error")
    except IndexError:
        errs.append("IndexError")
check("sequence reads at a specialized site", errs, [3, "IndexError", 6, "IndexError", "c", "IndexError", 12, "IndexError"])

def unpack(p):
    a, b = p
    return a - b
for i in range(N):
    unpack((i, 1))
errs = [unpack([5, 2]), unpack("ab" if False else (9, 4))]
for bad in [(1, 2, 3), (1,)]:
    try:
        unpack(bad)
        errs.append("no error")
    except ValueError:
        errs.append("ValueError")
check("unpacking at a specialized site", errs, [3, 5, "ValueError", "ValueError"])

def make_counter2():
    count = 0
    def inc():
        nonlocal count
        count += 1
        return count
    def peek():
        return count
    return inc, peek
inc2, peek2 = make_counter2()
seen = []
for i in range(N):
    inc2()
    seen.append(peek2())
check("a closure variable rebound while another closure reads it", [seen[0], seen[59], seen[N - 1]], [1, 60, N])

def make_readers(k):
    def r():
        return k
    return r
readers = [make_readers(j) for j in range(5)]
check("one closure code, many environments", [f() for f in readers] * 2, [0, 1, 2, 3, 4] * 2)

def gen_method_args(items):
    out = []
    for x in items:
        out.append((yield x))
    return out
g = gen_method_args([1, 2, 3])
vals = [next(g), g.send("a"), g.send("b")]
try:
    g.send("c")
except StopIteration as e:
    vals.append(e.value)
check("a method call suspended between its name and its arguments", vals, [1, 2, 3, ["a", "b", "c"]])

def strs(words):
    out = []
    for w in words:
        out.append(w.strip(".").upper())
    return out
check("str methods at a specialized site", [strs(["a.", ".b", "c"] * 3)[:3], strs([])], [["A", "B", "C"], []])
def lst_ops(n):
    xs = []
    for i in range(n):
        xs.append(i)
        if i % 3 == 0:
            xs.pop()
    xs.insert(0, -1)
    return [xs[:4], xs.count(1), xs.index(2), len(xs)]
check("list methods at a specialized site", lst_ops(30), [[-1, 1, 2, 4], 1, 2, 21])
try:
    "abc".nosuchmethod()
    errs = "no error"
except AttributeError:
    errs = "AttributeError"
check("a missing str method", errs, "AttributeError")

# ── modules ──────────────────────────────────────────────────────────────────
import math
import bisect
def use_sqrt(x):
    return math.sqrt(x)
def use_bisect(x):
    fn = bisect.bisect_left          # (read, then called: the interpreter cannot call a
    return fn([1, 2, 3, 4], x)       # module attribute rebound to a lambda directly)
saved_bisect = bisect.bisect_left
seen = []
for i in range(N):
    if i == H:
        bisect.bisect_left = lambda a, x: -1   # a module attribute rebound after LOAD_ATTR specialized
    seen.append(use_bisect(3))
bisect.bisect_left = saved_bisect
check("module attribute rebound", [seen[0], seen[H - 1], seen[H], seen[N - 1], use_bisect(3)], [2, 2, -1, -1, 2])
check("a module function at a specialized site", [use_sqrt(16), use_sqrt(2.25)], [4.0, 1.5])

# ── threads hammering one function while another rebinds a global ───────────
import threading
SHARED = 0
def get_shared():
    return SHARED
thread_seen = []
def hammer():
    vals = set()
    for i in range(3000):
        vals.add(get_shared())
    thread_seen.append(sorted(vals))
threads = [threading.Thread(target=hammer) for k in range(3)]
for t in threads:
    t.start()
for k in range(1, 6):
    SHARED = k                       # rebound while the threads read it
for t in threads:
    t.join()
check("threads read a global rebound by another", [len(thread_seen), all(set(v) <= {0, 1, 2, 3, 4, 5} for v in thread_seen), get_shared()],
      [3, True, 5])

lock_count = [0]
lock = threading.Lock()
def bump(n):
    for i in range(n):
        with lock:
            lock_count[0] = lock_count[0] + 1
ts = [threading.Thread(target=bump, args=(500,)) for k in range(4)]
for t in ts:
    t.start()
for t in ts:
    t.join()
check("threads running one specialized function", lock_count[0], 2000)

# ── tracing switched on mid-loop ─────────────────────────────────────────────
def traced(n):
    t = 0
    t = t + n
    t = t * 2
    return t
first = traced.__code__.co_firstlineno
events = []
def tracer(frame, event, arg):
    if frame.f_code.co_name == "traced":
        events.append((event, frame.f_lineno - first))
    return tracer
outs = []
for k in range(10):
    if k == 6:
        sys.settrace(tracer)         # after traced() specialized
    outs.append(traced(k))
sys.settrace(None)
check("tracing switched on mid-loop: results", outs, [0, 2, 4, 6, 8, 10, 12, 14, 16, 18])
check("tracing switched on mid-loop: events of the specialized code",
      events[:6], [("call", 0), ("line", 1), ("line", 2), ("line", 3), ("line", 4), ("return", 4)])
check("tracing switched on mid-loop: every traced call", len(events), 4 * 6)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT98 PASSED ===")
