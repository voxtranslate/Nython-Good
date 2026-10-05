# vm_audit72.ny - Python compatibility, both engines (round 77).
#
# Written in the subset Nython and Python share, so the same file runs
# under python3 (tools: `python3 examples/vm_audit72.ny` must also pass) -
# every expected value below is what CPython computes.
#
#   displays     [*a, b], (*a, b), {*a}, {**d, k: v}, [x, *y] = seq
#   annotations  x: int = 5, self.x: T = v, def f(a: int, /, b, *, c) -> T
#   f-strings    f"{x=}", f"{x = }", f"{x=!s}", f"{x*2=:>5}"
#   slices       slice objects, __getitem__/__setitem__/__delitem__ getting
#                them, a slice object indexing lists/str/tuples, indices()
#   eval/exec    eval with and without namespaces, exec writing into a dict,
#                functions defined inside exec, compile() and code objects
#   complex      2j literals, arithmetic, abs, conjugate, ** , parsing, repr
#   classes      a class statement run again makes a new class (factories,
#                closures over the factory's arguments, super() in them)
#   collections  deque, Counter, defaultdict, OrderedDict, namedtuple,
#                ChainMap, dict(mapping)
#   builtins     object, issubclass(bool, int), kwargs order, vars/dir
#
# Must pass on both engines (and python3):
#     ./build/nython-cli examples/vm_audit72.ny
#     ./build/nython-cli --vm examples/vm_audit72.ny
try:
    true
except NameError:
    true = True
    false = False
    none = None

import collections

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, got == want, got, want])

# ── displays and unpacking ───────────────────────────────────────────────────
a = [1, 2]
d = {"a": 1}
check("list display", [*a, 3, *"xy"], [1, 2, 3, "x", "y"])
check("tuple display", (*a, 3), (1, 2, 3))
check("set display", sorted({*a, 5}), [1, 2, 5])
check("dict display", {**d, "b": 2}, {"a": 1, "b": 2})
check("dict display later wins", {"z": 0, **d, "a": 9}, {"z": 0, "a": 9})
[x1, *rest1] = [1, 2, 3]
check("bracketed starred target", [x1, rest1], [1, [2, 3]])
(p1, q1) = (7, 8)
check("parenthesised targets", [p1, q1], [7, 8])
first, *mid, last = range(5)
check("starred middle", [first, mid, last], [0, [1, 2, 3], 4])

def spread(*args, **kw):
    return [list(args), sorted(kw.items())]
check("call spreads", spread(*a, *[9], **d, **{"e": 5}), [[1, 2, 9], [("a", 1), ("e", 5)]])

def kw_order(**kw):
    return list(kw.keys())
check("kwargs keep call order", kw_order(z=1, a=2, m=3), ["z", "a", "m"])

# ── annotations ──────────────────────────────────────────────────────────────
ann_x: int = 5
ann_y: list
def annotated(n: int, m: str = "a", *rest: int, flag: bool = False, **kw: dict) -> str:
    return str(n) + m + str(len(rest)) + ("T" if flag else "F")
check("annotated assignment", ann_x, 5)
check("annotated def", annotated(1, "b", 7, 8, flag=True), "1b2T")

class Annotated:
    count: int = 0
    def __init__(self, v: float) -> None:
        self.v: float = v
check("annotated class", [Annotated.count, Annotated(2.5).v], [0, 2.5])

def markers(a, b, /, c, *, d=4):
    return [a, b, c, d]
check("positional-only and keyword-only", [markers(1, 2, 3), markers(1, 2, c=9, d=0)], [[1, 2, 3, 4], [1, 2, 9, 0]])
def trailing(a, b,):
    return a + b
check("trailing comma", trailing(1, 2,), 3)

# ── f-strings ────────────────────────────────────────────────────────────────
fv = 3
fname = "nython"
check("f-string =", [f"{fv=}", f"{fv = }", f"{fname=!s}", f"{fv*2=:>5}", f"{fv=}{fv}"], ["fv=3", "fv = 3", "fname=nython", "fv*2=    6", "fv=33"])

# ── slices ───────────────────────────────────────────────────────────────────
class Seq:
    def __init__(self, n):
        self.data = list(range(n))
    def __getitem__(self, k):
        if isinstance(k, slice):
            return ["slice", k.start, k.stop, k.step, self.data[k]]
        return ["index", k]
    def __setitem__(self, k, v):
        self.data[k] = v
    def __delitem__(self, k):
        del self.data[k]
sq = Seq(10)
check("__getitem__ gets a slice", [sq[2:5], sq[::3], sq[4]], [["slice", 2, 5, None, [2, 3, 4]], ["slice", None, None, 3, [0, 3, 6, 9]], ["index", 4]])
sq[0:3] = ["a", "b"]
check("__setitem__ gets a slice", sq.data, ["a", "b", 3, 4, 5, 6, 7, 8, 9])
del sq[0:2]
check("__delitem__ gets a slice", sq.data, [3, 4, 5, 6, 7, 8, 9])
sl = slice(1, 8, 2)
check("slice object", [sl.start, sl.stop, sl.step, sl.indices(5), slice(None, None, -1).indices(4)], [1, 8, 2, (1, 5, 2), (3, -1, -1)])
check("slice object as index", [[0, 1, 2, 3, 4, 5, 6, 7, 8][sl], "abcdefgh"[slice(2, 5)], (1, 2, 3, 4)[slice(None, None, -1)]], [[1, 3, 5, 7], "cde", (4, 3, 2, 1)])
check("slice equality", [slice(1, 2) == slice(1, 2), slice(1, 2) == slice(1, 3)], [True, False])

# ── eval / exec / compile ────────────────────────────────────────────────────
ev_x = 41
check("eval", [eval("ev_x + 1"), eval("  [i * i for i in range(4)]"), eval("y * 2", {"y": 21}), eval("a + b", {"a": 1}, {"b": 2})], [42, [0, 1, 4, 9], 42, 3])
exec("ev_z = ev_x * 2")
check("exec defines", ev_z, 82)
ns = {"base": 10}
exec("def f(n):\n    return base + n\nresult = f(5)", ns)
check("exec into a dict", [ns["result"], sorted(k for k in ns if not k.startswith("__"))], [15, ["base", "f", "result"]])
code = compile("p * 3", "<calc>", "eval")
check("compile eval", [eval(code, {"p": 7}), code.co_filename], [21, "<calc>"])
g = {}
exec(compile("q = 1\nq += 4", "<prog>", "exec"), g)
check("compile exec", g["q"], 5)
def eval_in_function():
    k = 3
    return eval("k * 10")
check("eval sees locals", eval_in_function(), 30)
errs = []
for src in ["x = 5"]:
    try:
        eval(src)
        errs.append("no error")
    except SyntaxError:
        errs.append("SyntaxError")
try:
    compile("def (", "<bad>", "exec")
    errs.append("no error")
except SyntaxError:
    errs.append("SyntaxError")
check("syntax errors", errs, ["SyntaxError", "SyntaxError"])

# ── complex ──────────────────────────────────────────────────────────────────
cz = 3 + 4j
check("complex basics", [cz.real, cz.imag, abs(cz), cz.conjugate(), -cz], [3.0, 4.0, 5.0, 3 - 4j, -3 - 4j])
check("complex arithmetic", [1j * 1j, (1 + 2j) * (3 - 1j), (1 + 2j) / (1 - 1j), (1j) ** 2, (1 + 1j) ** 3], [-1 + 0j, 5 + 5j, -0.5 + 1.5j, -1 + 0j, -2 + 2j])
check("complex constructor", [complex(1, 2), complex("1+2j"), complex("-3.5j"), complex(2), complex()], [1 + 2j, 1 + 2j, -3.5j, 2 + 0j, 0j])
check("complex repr", [repr(cz), repr(2j), repr(0j), repr(complex(-1, -1)), str(1.5j)], ["(3+4j)", "2j", "0j", "(-1-1j)", "1.5j"])
check("complex equality", [cz == complex(3, 4), complex(5, 0) == 5, bool(0j), bool(1j)], [True, True, False, True])

# ── classes made per execution ───────────────────────────────────────────────
def make(tag):
    class Base:
        kind = tag
        def hello(self):
            return "base " + self.kind
    class Derived(Base):
        def hello(self):
            return "derived/" + super().hello()
    return Derived
D1 = make("one")
D2 = make("two")
check("class factory", [D1().hello(), D2().hello(), D1().kind, D2().kind, D1.__name__], ["derived/base one", "derived/base two", "one", "two", "Derived"])
check("distinct classes", [D1 == D2, isinstance(D1(), D1), isinstance(D1(), D2)], [False, True, False])

def make_counter(start):
    class Counter0:
        def get(self):
            return start
    return Counter0
check("closure per class", [make_counter(1)().get(), make_counter(2)().get()], [1, 2])

# ── collections ──────────────────────────────────────────────────────────────
dq = collections.deque(range(5))
dq.rotate(2)
dq.appendleft(-1)
check("deque", [list(dq), dq[0], dq[-1], len(dq), dq.popleft(), dq.pop()], [[-1, 3, 4, 0, 1, 2], -1, 2, 6, -1, 2])
dq2 = collections.deque(maxlen=2)
for i in range(5):
    dq2.append(i)
check("deque maxlen", [list(dq2), dq2.maxlen], [[3, 4], 2])
cnt = collections.Counter("mississippi")
check("Counter", [cnt["s"], cnt["z"], cnt.most_common(2), cnt.total()], [4, 0, [("i", 4), ("s", 4)], 11])
check("Counter arithmetic", [dict(collections.Counter(a=3, b=1) + collections.Counter(a=1, c=2)), dict(collections.Counter(a=3, b=1) - collections.Counter(a=1, b=5))], [{"a": 4, "b": 1, "c": 2}, {"a": 2}])
dd = collections.defaultdict(int)
for w in "the cat the dog the".split():
    dd[w] += 1
check("defaultdict", [dict(dd), dd["missing"], len(dd)], [{"the": 3, "cat": 1, "dog": 1}, 0, 4])
od = collections.OrderedDict([("a", 1), ("b", 2), ("c", 3)])
od.move_to_end("a")
check("OrderedDict", [list(od), od.popitem(), od.popitem(last=False)], [["b", "c", "a"], ("a", 1), ("b", 2)])
Point = collections.namedtuple("Point", "x y")
pt = Point(1, y=2)
Q = collections.namedtuple("Q", ["a", "b", "c"], defaults=[0, 1])
check("namedtuple", [pt.x + pt.y, pt[0], pt._asdict(), repr(pt._replace(x=5)), Point._fields, repr(Q(5))], [3, 1, {"x": 1, "y": 2}, "Point(x=5, y=2)", ("x", "y"), "Q(a=5, b=0, c=1)"])
px, py = pt
check("namedtuple unpacks", [px, py, pt == (1, 2)], [1, 2, True])
cm = collections.ChainMap({"a": 1}, {"a": 2, "b": 3})
check("ChainMap", [cm["a"], cm["b"], sorted(cm.keys()), len(cm)], [1, 3, ["a", "b"], 2])

# ── builtins ─────────────────────────────────────────────────────────────────
class Plain(object):
    pass
check("object", [isinstance(Plain(), Plain), issubclass(Plain, object), issubclass(int, object)], [True, True, True])
check("issubclass builtins", [issubclass(bool, int), issubclass(int, bool)], [True, False])

class Thing:
    kind = "t"
    def __init__(self):
        self.a = 1
    def method(self):
        return 1
check("vars/dir", [vars(Thing()), [n for n in dir(Thing()) if not n.startswith("__")]], [{"a": 1}, ["a", "kind", "method"]])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT72 PASSED ===")
