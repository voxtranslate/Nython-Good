# vm_audit100.ny - the interpreter's self-optimizing nodes (round 81).
#
# The tree-walking interpreter's nodes remember what they saw and take a
# shorter path the next time (NythonExecutor: literal values made once, an
# operator's code, int/float arithmetic and comparisons without the general
# dispatch, a name's hash and the slot it was found in, a field's slot in an
# instance, plain calls of plain functions without the side tables, and a
# polymorphic inline cache per method-call site). Every scenario here first
# runs a site long enough for it to have specialized, then changes what it
# sees - a global, a builtin shadowed, a function replaced by a lambda, a
# class or a builtin at the same call, a method replaced in a class or a
# base, an instance field shadowing a method, __class__ reassigned, a new
# layout of fields, an int overflowing, exec adding a name, tracing switched
# on - and checks that the answers are still Python's. It must give the same
# answers on the VM, under python3 and with NY_ASTSPEC=0 (no specialization):
#
#     ./build/nython-cli examples/vm_audit100.ny
#     ./build/nython-cli --vm examples/vm_audit100.ny
#     NY_ASTSPEC=0 ./build/nython-cli examples/vm_audit100.ny
#     python3 examples/vm_audit100.ny
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

N = 120          # runs of a site before the change
H = 60           # where in a loop of N the change happens

# ── literals: made once per node ─────────────────────────────────────────────
def lits(n):
    out = []
    for i in range(n):
        out.append((7, -7, 2.5, 123456789012345678901234567890, 0x1F, 0b101, 1_000, 1e3, 1e400 > 0))
    return out
ls = lits(5)
check("literals evaluated again and again", [ls[0], ls[4], ls[0] == ls[4]],
      [(7, -7, 2.5, 123456789012345678901234567890, 31, 5, 1000, 1000.0, True),
       (7, -7, 2.5, 123456789012345678901234567890, 31, 5, 1000, 1000.0, True), True])
def lit_mutation():
    x = 5
    x += 1                           # the literal's value is not changed through x
    y = 5
    return [x, y]
check("a literal's value is not shared state", [lit_mutation(), lit_mutation()], [[6, 5], [6, 5]])

# ── arithmetic and comparisons at specialized sites ──────────────────────────
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
check("int - int and int * int overflowing", [sub(-big, 2), sub(big, -1), mul(big, 2), mul(4294967296, 4294967296), mul(-big - 1, -1)],
      [-9223372036854775809, 9223372036854775808, 18446744073709551614, 18446744073709551616, 9223372036854775808])
check("big ints at a site that saw small ones", [add(2 ** 70, 1), sub(2 ** 70, 2 ** 70), mul(2 ** 40, 2 ** 40), add(-(2 ** 64), 2 ** 64)],
      [1180591620717411303425, 0, 1208925819614629174706176, 0])
check("floats and mixes at an int site", [add(1, 2.5), add(2.5, 1), add(0.1, 0.2), sub(1, 0.5), mul(3, 0.5), mul(-0.0, 1), add(1e308, 1e308)],
      [3.5, 3.5, 0.30000000000000004, 0.5, 1.5, -0.0, float("inf")])
check("bools at an int site", [add(True, 1), add(True, True), mul(False, 5), sub(True, False), mul(True, 2.5)], [2, 2, 0, 1, 2.5])
check("strings, lists, tuples at a number site", [add("a", "b"), add([1], [2]), mul("ab", 3), mul(2, [0]), add((1,), (2,))],
      ["ab", [1, 2], "ababab", [0, 0], (1, 2)])
class Money:
    def __init__(self, c):
        self.c = c
    def __add__(self, o):
        return Money(self.c + (o.c if isinstance(o, Money) else o))
    def __radd__(self, o):
        return Money(o + self.c)
    def __lt__(self, o):
        return self.c < o.c
check("objects with __add__ / __radd__ at an int site", [add(Money(1), Money(2)).c, add(Money(1), 5).c, add(5, Money(1)).c], [3, 6, 6])
errs = []
for a, b in [(1, None), (None, 1), ([1], 1), ({}, 2.5)]:
    try:
        add(a, b)
        errs.append("none")
    except TypeError:
        errs.append("TypeError")
check("unsupported operands at an int site", errs, ["TypeError"] * 4)

def band(a, b):
    return a & b
def bor(a, b):
    return a | b
def bxor(a, b):
    return a ^ b
def shl(a, b):
    return a << b
for i in range(N):
    band(i, 7)
    bor(i, 8)
    bxor(i, 5)
    shl(i, 2)
check("bitwise operators: ints, bools, big ints",
      [band(12, 10), bor(12, 3), bxor(12, 10), band(True, False), bor(True, False), bxor(True, True), band(True, 3), bor(-1, 2 ** 70), shl(1, 70), band(-8, 2 ** 65 - 1)],
      [8, 15, 6, False, True, False, 1, -1, 1180591620717411303424, 36893488147419103224])
check("bitwise on bools keeps bool", [type(band(True, True)).__name__, type(band(True, 1)).__name__], ["bool", "int"])

def div(a, b):
    return a / b
def fdiv(a, b):
    return a // b
def mod(a, b):
    return a % b
def pw(a, b):
    return a ** b
for i in range(N):
    div(i, 3)
    fdiv(i, 3)
    mod(i, 7)
    pw(i, 2)
errs = []
for f in [div, fdiv, mod]:
    for z in [0, 0.0]:
        try:
            f(1, z)
            errs.append("none")
        except ZeroDivisionError:
            errs.append("ZeroDivisionError")
check("division by zero at specialized sites", errs, ["ZeroDivisionError"] * 6)
check("true division, floor division, modulo", [div(7, 2), div(-7, 2), div(1, 3), div(2 ** 60, 3), fdiv(-7, 2), fdiv(7, -2), mod(-7, 3), mod(7, -3), fdiv(7.5, 2), mod(7.5, 2), mod("%d!", 5)],
      [3.5, -3.5, 0.3333333333333333, 384307168202282325.3333333333333333, -4, -4, 2, -2, 3.0, 1.5, "5!"])
check("powers", [pw(2, 10), pw(2, 100), pw(2, -1), pw(-2, 3), pw(2.0, 0.5), pw(0, 0)], [1024, 1267650600228229401496703205376, 0.5, -8, 1.4142135623730951, 1])

def lt(a, b):
    return a < b
def le(a, b):
    return a <= b
def gt(a, b):
    return a > b
def eq(a, b):
    return a == b
def ne(a, b):
    return a != b
for i in range(N):
    lt(i, 5)
    le(i, 5)
    gt(i, 5)
    eq(i, 5)
    ne(i, 5)
nan = float("nan")
check("comparisons of ints, floats and NaN", [lt(1, 2), lt(2, 1), le(2, 2), gt(3, 2), eq(3, 3), ne(3, 3), lt(1.5, 2.5), lt(nan, 1.0), le(nan, nan), gt(nan, 0), eq(nan, nan), ne(nan, nan)],
      [True, False, True, True, True, False, True, False, False, False, False, True])
check("comparisons of mixes, big ints, bools", [lt(1, 1.5), eq(1, 1.0), lt(2 ** 64, 2 ** 65), eq(2 ** 64, 2 ** 64), lt(9007199254740993, 9007199254740992.0), eq(True, 1), le(False, 0), eq(-0.0, 0.0), lt(-0.0, 0.0)],
      [True, True, True, True, False, True, True, True, False])
check("comparisons of other values at a number site", [lt("a", "b"), eq([1], [1]), ne((1, 2), (1, 2)), lt(Money(1), Money(2)), eq(None, None), eq(1, "1")],
      [True, True, False, True, True, False])
errs = []
for a, b in [(1, "a"), ("a", 1), (None, 1), ([1], 1)]:
    try:
        lt(a, b)
        errs.append("none")
    except TypeError:
        errs.append("TypeError")
check("unorderable values at a number site", errs, ["TypeError"] * 4)

def acc(n, start, step):
    t = start
    for i in range(n):
        t += step
    return t
check("+= at an int site crossing 2**63, then floats and strings", [acc(4, big - 2, 1), acc(3, 1, 0.5), acc(2, "x", "y"), acc(3, [], [1])],
      [9223372036854775809, 2.5, "xyy", [1, 1, 1]])
def chain(a, b, c):
    return a < b < c
check("chained comparisons", [chain(1, 2, 3), chain(1, 3, 2), chain(1.0, 2, 2.5), chain("a", "b", "c")], [True, False, True, True])

# ── names: globals, builtins, locals, closures, exec ─────────────────────────
G1 = 1
def read_g1():
    return G1
seen = []
for i in range(N):
    if i == H:
        G1 = 2
    seen.append(read_g1())
check("a global rebound at module level", [seen[0], seen[H - 1], seen[H], seen[N - 1]], [1, 1, 2, 2])

def set_g1(v):
    global G1
    G1 = v
seen = []
for i in range(N):
    if i % 40 == 0:
        set_g1(i)
    seen.append(read_g1())
check("a global rebound through `global`", [seen[0], seen[39], seen[40], seen[80], seen[N - 1]], [0, 0, 40, 80, 80])

G2 = "a"
def read_g2():
    return G2
seen = []
for i in range(N):
    if i == H:
        del G2
        G_PAD1 = 0
        G_PAD2 = 0
        G2 = "b"                     # made again, in another slot
    seen.append(read_g2())
check("a global deleted and made again", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["a", "a", "b", "b"])

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
check("a global deleted: NameError", [seen[0], seen[H - 1], seen[H], seen[N - 1]], [5, 5, "NameError", "NameError"])

def read_later():
    return G_LATER
seen = []
for i in range(N):
    if i == H:
        exec("G_LATER = 'made by exec'")   # exec adds a global the site could not find
    try:
        seen.append(read_later())
    except NameError:
        seen.append("NameError")
check("exec adding a global a site looked for", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["NameError", "NameError", "made by exec", "made by exec"])

def use_len(x):
    return len(x)
seen = []
for i in range(N):
    if i == H:
        len = lambda x: -1           # a builtin shadowed by a global later
    if i == H + 30:
        del len                      # and the builtin back
    seen.append(use_len([1, 2, 3]))
check("a builtin shadowed and unshadowed", [seen[0], seen[H - 1], seen[H], seen[H + 29], seen[H + 30], seen[N - 1]], [3, 3, -1, -1, 3, 3])

def local_order(flag):
    if flag:
        a = 1
        b = 2
    else:
        b = 3
        a = 4
    return a * 10 + b
check("locals made in different orders", [local_order(i % 3 == 0) for i in range(12)], [12, 43, 43, 12, 43, 43, 12, 43, 43, 12, 43, 43])

def local_deleted(n):
    out = []
    for i in range(n):
        x = i
        if i % 2:
            del x
            x = -i
        out.append(x)
    return out
check("a local deleted and bound again", local_deleted(8), [0, -1, 2, -3, 4, -5, 6, -7])


def make_counter():
    count = 0
    def inc():
        nonlocal count
        count += 1
        return count
    def peek():
        return count
    return inc, peek
inc1, peek1 = make_counter()
seen = []
for i in range(N):
    inc1()
    seen.append(peek1())
check("a closure variable rebound while another closure reads it", [seen[0], seen[59], seen[N - 1]], [1, 60, N])

def make_reader(k):
    def r():
        return k
    return r
readers = [make_reader(j) for j in range(5)]
check("one closure code, many environments", [f() for f in readers] * 2, [0, 1, 2, 3, 4] * 2)

def outer_rebinds():
    v = "first"
    def inner():
        return v
    out = [inner()]
    v = "second"                     # the enclosing variable rebound after inner read it
    out.append(inner())
    return out
check("an enclosing variable rebound", [outer_rebinds() for i in range(3)], [["first", "second"]] * 3)

def comp_names(n):
    x = "outer"
    ys = [x for x in range(n)]
    return [ys, x]
check("a comprehension variable is its own", [comp_names(3), comp_names(0)], [[[0, 1, 2], "outer"], [[], "outer"]])

class Scoped:
    k = 10
    vals = [k + 1]
    def get(self):
        return self.k
check("a class body's names", [Scoped.vals, Scoped().get(), Scoped.k], [[11], 10, 10])

# ── plain calls ──────────────────────────────────────────────────────────────
def three(a, b, c):
    return a * 100 + b * 10 + c
for i in range(N):
    three(1, 2, 3)
errs = []
for args in [(1, 2), (1, 2, 3, 4), ()]:
    try:
        three(*args)
        errs.append("none")
    except TypeError as e:
        errs.append(str(e))
check("a call with too few or too many arguments", errs,
      ["three() missing 1 required positional argument: 'c'",
       "three() takes 3 positional arguments but 4 were given",
       "three() missing 3 required positional arguments: 'a', 'b', and 'c'"])
def call_three_short():
    return three(1, 2)
errs = []
for i in range(3):
    try:
        call_three_short()
        errs.append("none")
    except TypeError as e:
        errs.append(str(e))
check("a plain call site with the wrong count", errs, ["three() missing 1 required positional argument: 'c'"] * 3)
check("keywords and defaults at a hot site", [three(1, 2, c=3), three(c=1, b=2, a=3), three(*[4, 5, 6])], [123, 321, 456])
def with_default(a, b=7):
    return a + b
for i in range(N):
    with_default(i, 1)
check("defaults used after a site saw them given", [with_default(1), with_default(1, 2), with_default(b=1, a=2)], [8, 3, 3])
def star(*xs):
    return len(xs)
def kw(**k):
    return sorted(k)
check("*args and **kw functions at a plain site", [star(1, 2, 3), star(), kw(a=1, b=2)], [3, 0, ["a", "b"]])

def target_def(x):
    return ("def", x)
class TargetClass:
    def __init__(self, x):
        self.x = x
class Calls:
    def __call__(self, x):
        return ("callable", x)
    def meth(self, x):
        return ("bound", x)
callee = target_def
def call_callee(x):
    return callee(x)
seen = []
for i in range(N):
    if i == 30:
        callee = lambda x: ("lambda", x)
    if i == 50:
        callee = TargetClass
    if i == 70:
        callee = abs
    if i == 80:
        callee = Calls()
    if i == 90:
        callee = Calls().meth
    if i == 100:
        callee = target_def
    r = call_callee(-i)
    seen.append(r.x if isinstance(r, TargetClass) else r)
check("one call site, the callee rebound to a lambda, a class, a builtin, a callable, a bound method",
      [seen[29], seen[30], seen[50], seen[70], seen[80], seen[90], seen[100], seen[N - 1]],
      [("def", -29), ("lambda", -30), -50, 70, ("callable", -80), ("bound", -90), ("def", -100), ("def", -119)])

def redefined(x):
    return x + 1
def call_redefined(x):
    return redefined(x)
seen = []
for i in range(N):
    if i == H:
        def redefined(x, y=10):      # a new function of the same name, another signature
            return x * y
    seen.append(call_redefined(i))
check("a function redefined under a hot call site", [seen[0], seen[H - 1], seen[H], seen[N - 1]], [1, 60, 600, 1190])

def make_adder(k):
    return lambda x: x + k
adders = [make_adder(j) for j in range(50)]
check("many closures through one call site", sum(a(1) for a in adders), sum(range(50)) + 50)

def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
check("recursion through the fast call", [fib(15), fib(20)], [610, 6765])
def down(n):
    return down(n + 1)
try:
    down(0)
    rec = "none"
except RecursionError:
    rec = "RecursionError"
check("RecursionError through fast calls, then calls again", [rec, fib(10)], ["RecursionError", 55])

order = []
def side(tag, v):
    order.append(tag)
    return v
def three_way(a, b, c):
    return [a, b, c]
for i in range(3):
    order = []
    three_way(side("a", 1), side("b", 2), side("c", 3))
check("arguments evaluated left to right", order, ["a", "b", "c"])

dels = []
class Tracked:
    def __init__(self, name):
        self.name = name
    def __del__(self):
        dels.append(self.name)
def take(t):
    dels.append("in " + t.name)
    return t.name
def drop_args():
    for i in range(3):
        take(Tracked("t%d" % i))
        dels.append("after %d" % i)
drop_args()
check("an argument's object dies after the call, before the next statement", dels,
      ["in t0", "t0", "after 0", "in t1", "t1", "after 1", "in t2", "t2", "after 2"])

def gen_fn(n):
    for i in range(n):
        yield i * i
def call_gen(n):
    return list(gen_fn(n))
check("a generator function at a plain call site", [call_gen(4), call_gen(0)], [[0, 1, 4, 9], []])

# ── method calls: the per-site inline cache ──────────────────────────────────
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
check("a call site seeing one, two, four, six classes",
      [total_area(shapes[:1] * 30), total_area(shapes[:2] * 30), total_area(shapes[:4] * 30), total_area(shapes * 30), total_area(shapes[4:] * 10)],
      [30, 90, 300, 600, 100])

class Animal:
    def speak(self):
        return "..."
class Dog(Animal):
    pass
def dog_speaks(d):
    return d.speak()
def bark(self):
    return "woof"
dog = Dog()
seen = []
for i in range(N):
    if i == H:
        Dog.speak = bark             # the subclass gets its own method later
    seen.append(dog_speaks(dog))
check("a method added to the subclass after the site cached the base's", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["...", "...", "woof", "woof"])

def loud(self):
    return "LOUD"
del Dog.speak
seen = []
for i in range(N):
    if i == H:
        Animal.speak = loud          # the base's method replaced
    seen.append(dog_speaks(dog))
check("the base's method replaced", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["...", "...", "LOUD", "LOUD"])

class Lone:
    pass
def lone_m(self):
    return "lone"
Lone.m = lone_m
lone = Lone()
def deleted_call(o):
    try:
        return o.m()
    except AttributeError:
        return "AttributeError"
seen = []
for i in range(N):
    if i == H:
        del Lone.m                   # the method goes
    seen.append(deleted_call(lone))
check("a cached method deleted from its class", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["lone", "lone", "AttributeError", "AttributeError"])

class Greeter:
    def hello(self, name):
        return "hello " + name
gr = Greeter()
seen = []
for i in range(N):
    if i == H:
        gr.hello = lambda name: "hi " + name   # an instance field shadows the method
    if i == H + 30:
        del gr.hello                 # and goes again
    seen.append(gr.hello("x"))
check("an instance field shadows a cached method", [seen[0], seen[H], seen[H + 29], seen[H + 30], seen[N - 1]], ["hello x", "hi x", "hi x", "hello x", "hello x"])

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
ob = Ca()
seen = []
for i in range(N):
    if i == H:
        ob.__class__ = Cb            # the receiver changes class
    seen.append(ob.f() + str(ob.g(i)))
check("__class__ reassigned under a cached site", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["A1", "A60", "B62", "B121"])

class Kinds:
    base = 5
    def plain(self, x):
        return self.base + x
    @staticmethod
    def stat(x):
        return x * 2
    @classmethod
    def cls(cls, x):
        return cls.base * x
    def other_first(s, x):           # the first parameter is not called self
        return s.base - x
    def defaults(self, x, y=100):
        return x + y
    def star(self, *xs):
        return len(xs)
kd = Kinds()
seen = []
for i in range(N):
    seen.append([kd.plain(i), kd.stat(i), kd.cls(i), kd.other_first(i), kd.defaults(i), kd.defaults(i, 1), kd.star(i, i), kd.plain(x=i)])
check("method kinds at hot sites", [seen[0], seen[N - 1]], [[5, 0, 0, 5, 100, 1, 2, 5], [124, 238, 595, -114, 219, 120, 2, 124]])
errs = []
for i in range(3):
    try:
        kd.plain()
        errs.append("none")
    except TypeError as e:
        errs.append(str(e))
check("a method called with too few arguments at a hot site", errs, ["Kinds.plain() missing 1 required positional argument: 'x'"] * 3)

class Base1:
    def __init__(self):
        self.log = []
    def step(self, x):
        self.log.append(("base", x))
        return x
class Mid(Base1):
    def step(self, x):
        self.log.append(("mid", x))
        return super().step(x + 1)
class Leaf(Mid):
    def step(self, x):
        self.log.append(("leaf", x))
        return super().step(x * 2)
lf = Leaf()
outs = [lf.step(i) for i in range(5)]
check("super() inside cached methods", [outs, lf.log[:3], len(lf.log)], [[1, 3, 5, 7, 9], [("leaf", 0), ("mid", 0), ("base", 1)], 15])

class Chain:
    def __init__(self, v):
        self.v = v
    def add(self, k):
        return Chain(self.v + k)
    def get(self):
        return self.v
c0 = Chain(0)
check("methods calling methods, chained", [c0.add(1).add(2).add(3).get(), sum(Chain(i).add(i).get() for i in range(10))], [6, 90])

class Prop:
    def __init__(self):
        self.calls = 0
    def m(self):
        return "method"
pr = Prop()
seen = []
for i in range(N):
    if i == H:
        Prop.m = property(lambda self: lambda: "from the property")   # the name becomes a property
    seen.append(pr.m())
check("a cached method replaced by a property", [seen[0], seen[H - 1], seen[H], seen[N - 1]], ["method", "method", "from the property", "from the property"])

class Watch:
    def __init__(self):
        self.a = 1
    def m(self):
        return self.a
wo = Watch()
seen = []
calls = []
def ga(self, name):
    calls.append(name)
    return object.__getattribute__(self, name)
for i in range(N):
    if i == H:
        Watch.__getattribute__ = ga  # __getattribute__ appears after the site cached m
    seen.append(wo.m())
check("__getattribute__ appearing after a site cached a method", [seen[0], seen[N - 1], calls[:2], len(calls) >= N - H],
      [1, 1, ["m", "a"], True])

def make_class(k):
    class Local:
        def val(self):
            return k
    return Local()
check("classes made by a function, one call site", [make_class(i).val() for i in range(6)], [0, 1, 2, 3, 4, 5])

class WithThis:
    def __init__(self):
        self.x = 3
    def get(this):
        return this.x
wt = WithThis()
check("a method whose first parameter is this", [wt.get() for i in range(4)], [3, 3, 3, 3])

class Slotted:
    __slots__ = ("a", "b")
    def __init__(self, a, b):
        self.a = a
        self.b = b
    def total(self):
        return self.a + self.b
sl = [Slotted(i, i * 2) for i in range(10)]
check("methods and fields of a class with __slots__", [sum(s.total() for s in sl), sl[3].a], [135, 3])

# ── attribute reads: the field's slot ────────────────────────────────────────
class Lay1:
    def __init__(self):
        self.p = 1
        self.q = 2
class Lay2:
    def __init__(self):
        self.q = 20                  # the same fields, in another order (another slot)
        self.p = 10
lays = [Lay1(), Lay2()] * 40
check("field reads with different layouts", [sum(o.p + o.q for o in lays), [o.q for o in lays[:4]]], [1320, [2, 20, 2, 20]])

class Fld:
    def __init__(self):
        self.v = 1
        self.w = 2
fo = Fld()
def read_v(o):
    return o.v
seen = []
for i in range(N):
    if i == 40:
        del fo.v                     # the field goes ...
        fo.x = 0
    if i == 41:
        fo.v = 5                     # ... and comes back in another slot
    try:
        seen.append(read_v(fo))
    except AttributeError:
        seen.append("AttributeError")
check("a field deleted and made again", [seen[0], seen[39], seen[40], seen[41], seen[N - 1]], [1, 1, "AttributeError", 5, 5])

fo2 = Fld()
seen = []
for i in range(N):
    if i == H:
        fo2.__dict__.update({"v": 99})
    seen.append(read_v(fo2))
check("a field changed through __dict__", [seen[0], seen[H], seen[N - 1]], [1, 99, 99])

class Fld2:
    def __init__(self):
        self.v = 1
fo3 = Fld2()
seen = []
for i in range(N):
    if i == H:
        Fld2.v = property(lambda self: 7)   # a property on the class now wins over the field
    seen.append(read_v(fo3))
check("a property set on the class after field reads cached the slot", [seen[0], seen[H - 1], seen[H], seen[N - 1]], [1, 1, 7, 7])

class Getattr:
    def __init__(self):
        self.here = 1
def read_there(o):
    try:
        return o.there
    except AttributeError:
        return "missing"
gt_obj = Getattr()
seen = []
for i in range(N):
    if i == H:
        Getattr.__getattr__ = lambda self, name: "from __getattr__ " + name
    seen.append(read_there(gt_obj))
check("__getattr__ appearing later", [seen[0], seen[H], seen[N - 1], gt_obj.here], ["missing", "from __getattr__ there", "from __getattr__ there", 1])

# ── generators ───────────────────────────────────────────────────────────────
class Acc:
    def __init__(self):
        self.t = 0
    def add(self, x):
        self.t += x
        return self.t
def gen_calls(n):
    a = Acc()
    for i in range(n):
        got = yield a.add(add(i, 1))
        if got is not None:
            a.add(got)
    return a.t
g = gen_calls(5)
vals = [next(g), next(g), g.send(100), next(g), next(g)]
try:
    next(g)
except StopIteration as e:
    vals.append(e.value)
check("fast calls and method calls inside a generator", vals, [1, 3, 106, 110, 115, 115])

# ── threads ──────────────────────────────────────────────────────────────────
import threading
class T1:
    def val(self, k):
        return k
class T2:
    def val(self, k):
        return -k
def poly_sum(objs, n):
    tot = 0                          # (not t: a Nython function rebinds a global it names)
    for k in range(n):
        for o in objs:
            tot += o.val(k)
    return tot
thread_out = []
def work(objs):
    thread_out.append(poly_sum(objs, 2000))
ts = [threading.Thread(target=work, args=([T1()],)), threading.Thread(target=work, args=([T2()],)),
      threading.Thread(target=work, args=([T1(), T2()],))]
for th in ts:
    th.start()
for th in ts:
    th.join()
check("threads sharing a method call site with different classes", sorted(thread_out), [-1999000, 0, 1999000])

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
for th in threads:
    th.start()
for k in range(1, 6):
    SHARED = k
for th in threads:
    th.join()
check("threads read a global another rebinds", [len(thread_seen), all(set(v) <= {0, 1, 2, 3, 4, 5} for v in thread_seen), get_shared()], [3, True, 5])

# ── tracing and profiling switched on mid-loop ───────────────────────────────
def traced(n):
    t = 0
    t = t + n
    t = t * 2
    return t
class TrK:
    def m(self, n):
        return n + 1
first = traced.__code__.co_firstlineno
events = []
def tracer(frame, event, arg):
    if frame.f_code.co_name in ("traced", "m"):
        events.append((frame.f_code.co_name, event, frame.f_lineno - (first if frame.f_code.co_name == "traced" else frame.f_code.co_firstlineno)))
    return tracer
trk = TrK()
outs = []
for k in range(10):
    if k == 6:
        sys.settrace(tracer)         # after both sites specialized
    outs.append(traced(k) + trk.m(k))
sys.settrace(None)
check("tracing switched on mid-loop: results", outs, [1, 4, 7, 10, 13, 16, 19, 22, 25, 28])
check("tracing switched on mid-loop: the events of a fast call",
      events[:6], [("traced", "call", 0), ("traced", "line", 1), ("traced", "line", 2), ("traced", "line", 3), ("traced", "line", 4), ("traced", "return", 4)])
check("tracing switched on mid-loop: the events of a cached method call", events[6:9], [("m", "call", 0), ("m", "line", 1), ("m", "return", 1)])
check("tracing switched on mid-loop: every traced call", len(events), 9 * 4)
prof = []
def profiler(frame, event, arg):
    if event == "call" and frame.f_code.co_name in ("traced", "m"):
        prof.append(frame.f_code.co_name)
for k in range(4):
    if k == 2:
        sys.setprofile(profiler)
    traced(k)
    trk.m(k)
sys.setprofile(None)
check("profiling switched on mid-loop", prof, ["traced", "m", "traced", "m"])

# ── exec namespaces ──────────────────────────────────────────────────────────
ns = {}
exec("def sq(x):\n    return x * x\nclass E:\n    def m(self, x):\n        return sq(x) + 1\n", ns)
e_obj = ns["E"]()
check("functions and methods defined by exec, through hot sites", [sum(ns["sq"](i) for i in range(10)), sum(e_obj.m(i) for i in range(10))], [285, 295])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT100 PASSED ===")
