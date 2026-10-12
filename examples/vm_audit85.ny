# vm_audit85.ny - the class model, both engines (round 77): classes deriving
# from builtin types hold a value of that type; __getattribute__ is
# dispatched; obj.__dict__ is a live view; a metaclass's __prepare__ gets
# the class body's bindings.
#
#  - `class MyInt(int)`, `class Celsius(float)`, `class Name(str)`,
#    `class Stack(list)`, `class Config(dict)`, `class Tags(set)` /
#    frozenset, `class Point(tuple)`, `class Blob(bytes)`, bytearray: an
#    instance is that builtin value plus its own attributes - arithmetic,
#    comparisons, hashing (the same dict key / set element as its value),
#    len, iteration, indexing, the type's methods (returning plain values:
#    MyStr("a").upper() is a str), isinstance, type(x) is MyInt, repr through
#    the subclass's __repr__ or the type's, JSON and formatting, builtins
#    given the value (math.sqrt, int(), ",".join ...), overriding
#    (super().__setitem__, __missing__; the type's own methods do not call a
#    subclass's dunders - dict.update does not call __setitem__, as CPython);
#    int.__new__(cls, v), str.__new__, tuple.__new__, float.__new__ in a
#    user __new__, super().__init__ / super().method() reaching the type's.
#  - __getattribute__: every attribute read and method call on an instance
#    of a class defining it, object.__getattribute__ the normal lookup,
#    AttributeError falling back to __getattr__; the engines' own lookups of
#    special methods (len, +, str) do not go through it, as in CPython.
#  - obj.__dict__ / vars(obj): one live view (writes store and remove
#    attributes, past __setattr__; reads see the attributes as they are).
#  - __prepare__: the mapping receives each binding of the body in order
#    (a name bound twice is seen twice, a decorated def once), the body
#    reads back what it holds, and the metaclass's __new__ gets it as the
#    namespace.
#  - what this needed besides: `self = ...` in a __new__, x |= y calling
#    __ior__, "%s %s" % TupleSubclass(...), a subclass's own __iter__ used by
#    the builtins, f(**DictSubclass(...)), `for a, b in` over tuple-subclass
#    items, sequence patterns matching tuples; and the libraries standing on
#    it - enum (members are values, _EnumDict), namedtuple /
#    typing.NamedTuple (real tuples), copy.
#
# Everything here runs under python3 too (`python3 examples/vm_audit85.ny`),
# with CPython's values as the expected ones.
#
#     ./build/nython-cli examples/vm_audit85.ny
#     ./build/nython-cli --vm examples/vm_audit85.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import json
import math

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def tname(x):
    return type(x).__name__

# ── int ──────────────────────────────────────────────────────────────────────
class MyInt(int):
    pass

x = MyInt(5)
check("int subclass: arithmetic", [x + 1, 1 + x, x * 2, x - 1, 10 - x, x // 2, x % 3, x ** 2, -x, +x, abs(MyInt(-3)), ~x, x / 2, x << 1, x & 4, x | 2, x ^ 1],
      [6, 6, 10, 4, 5, 2, 2, 25, -5, 5, 3, -6, 2.5, 10, 4, 7, 4])
check("int subclass: results are ints", [tname(x + 1), tname(-x), tname(abs(x)), tname(x * x), tname(2 ** x)], ["int", "int", "int", "int", "int"])
check("int subclass: comparisons", [x == 5, x != 5, x < 6, x > 4, 5 == x, x <= 5, x >= MyInt(5), 4 < x, x == 5.0, sorted([MyInt(3), 1, MyInt(2)])],
      [True, False, True, True, True, True, True, True, True, [1, 2, 3]])
check("int subclass: hashing", [hash(x) == hash(5), {5: "a"}[x], {x: "b"}[5], x in {5}, 5 in {x}, len({x, 5}), {x: 1, 5: 2}[5]],
      [True, "a", "b", True, True, 1, 2])
check("int subclass: isinstance / type", [isinstance(x, int), isinstance(x, MyInt), type(x) is MyInt, type(x) is int, issubclass(MyInt, int), x.__class__ is MyInt],
      [True, True, True, False, True, True])
check("int subclass: str / repr / format", [str(x), repr(x), "%d" % x, "%s" % x, "%x" % MyInt(255), f"{x:03d}", format(x, "x"), "{}".format(x), f"{x}"],
      ["5", "5", "5", "5", "ff", "005", "5", "5", "5"])
check("int subclass: as an index and a count", [[10, 20, 30][MyInt(1)], list(range(MyInt(3))), "ab" * MyInt(2), [0] * MyInt(2), bool(MyInt(0)), bool(x)],
      [20, [0, 1, 2], "abab", [0, 0], False, True])
check("int subclass: the type's methods", [x.bit_length(), x.real, x.numerator, x.denominator, x.imag, x.to_bytes(2, "big"), x.conjugate()],
      [3, 5, 5, 1, 0, b"\x00\x05", 5])
check("int subclass: builtins get the value", [int(x), float(x), divmod(MyInt(7), 2), pow(MyInt(2), 3), round(x), math.sqrt(MyInt(16)), hex(x), chr(MyInt(65))],
      [5, 5.0, (3, 1), 8, 5, 4.0, "0x5", "A"])
check("min / max keep the object", [tname(max(MyInt(3), MyInt(1))), max(MyInt(3), 2), min([MyInt(3), MyInt(1)]), tname(min([MyInt(3), MyInt(1)]))],
      ["MyInt", 3, 1, "MyInt"])
check("int subclass: an instance has attributes", [vars(MyInt(1)), hasattr(x, "nope")], [{}, False])
x.label = "five"
check("int subclass: attributes kept", [x.label, x + 0, vars(x)], ["five", 5, {"label": "five"}])
check("int subclass: MyInt() and from a string", [MyInt(), MyInt("12"), MyInt("ff", 16), MyInt(3.9), tname(MyInt("7"))], [0, 12, 255, 3, "MyInt"])

class Meters(int):
    def __new__(cls, v, unit="m"):
        self = super().__new__(cls, v)
        self.unit = unit
        return self
    def __repr__(self):
        return "Meters(" + int.__repr__(self) + ")"
    def double(self):
        return Meters(self * 2, self.unit)

m = Meters(3)
check("int subclass: __new__ through super().__new__", [m + 1, m.unit, Meters(4, "km").unit, repr(m), str(m), f"{m}", "%s" % m, "%d" % m, m.double(), m.double().unit],
      [4, "m", "km", "Meters(3)", "Meters(3)", "Meters(3)", "Meters(3)", "3", Meters(6), "m"])

class Doubled(int):
    def __new__(cls, v):
        return int.__new__(cls, v * 2)

check("int.__new__(cls, v)", [Doubled(3), tname(Doubled(3)), int.__new__(int, 7), tname(int.__new__(MyInt, 7)), int.__new__(MyInt, 7) + 1],
      [6, "Doubled", 7, "MyInt", 8])
check("int.__repr__ / int.__add__ through the type", [int.__repr__(m), int.__add__(m, 1), int.__hash__(x) == hash(5), int.__eq__(x, 5)], ["3", 4, True, True])

# ── float ────────────────────────────────────────────────────────────────────
class Celsius(float):
    def to_f(self):
        return self * 9 / 5 + 32

c = Celsius(100.0)
check("float subclass", [c.to_f(), c + 0.5, round(Celsius(2.567), 1), int(Celsius(3.9)), str(c), c.is_integer(), c > 99, isinstance(c, float), "%.1f" % c, f"{c:.2f}", math.floor(Celsius(2.5)), tname(c * 2)],
      [212.0, 100.5, 2.6, 3, "100.0", True, True, True, "100.0", "100.00", 2, "float"])
check("float subclass: hashing and from text", [{100.0: "boil"}[c], hash(Celsius(1.5)) == hash(1.5), Celsius("2.5"), tname(Celsius("2.5")), float.__new__(Celsius, 1.0) + 1],
      ["boil", True, 2.5, "Celsius", 2.0])

# ── str ──────────────────────────────────────────────────────────────────────
class Name(str):
    def shout(self):
        return self.upper() + "!"

n = Name("bob")
check("str subclass: the str's behaviour", [n, n.shout(), len(n), n[0], n[1:], n.upper(), n + "by", "x" + n, n * 2, "o" in n, n in "bobby", n == "bob", n.startswith("b"), n.replace("b", "c"), n.split("o"), list(n), sorted(Name("cab"))],
      ["bob", "BOB!", 3, "b", "ob", "BOB", "bobby", "xbob", "bobbob", True, True, True, True, "coc", ["b", "b"], ["b", "o", "b"], ["a", "b", "c"]])
check("str subclass: plain strs come back", [tname(n.upper()), tname(n + "x"), tname("x" + n), tname(n[0]), tname(str(n)), tname(n * 2)], ["str", "str", "str", "str", "str", "str"])
check("str subclass: is a str", [isinstance(n, str), type(n) is Name, str(n), repr(n), hash(n) == hash("bob"), {"bob": 1}[n], {n: 2}["bob"], n in {"bob"}],
      [True, True, "bob", "'bob'", True, 1, 2, True])
check("str subclass: formatting", ["%s!" % n, f"<{n}>", "{}".format(n), "{:>5}".format(n), format(n, "^5"), "-".join([Name("a"), Name("b"), "c"]), json.dumps(n)],
      ["bob!", "<bob>", "bob", "  bob", " bob ", "a-b-c", '"bob"'])
check("str subclass: builtins get the str", [int(Name("12")), float(Name("1.5")), ord(Name("a")), "abc".find(Name("c")), "a,b".split(Name(",")), Name("x").join(["1", "2"])],
      [12, 1.5, 97, 2, ["a", "b"], "1x2"])

class Title(str):
    def __new__(cls, value):
        return super().__new__(cls, value.title())
    def upper(self):
        return "UP:" + super().upper()

check("str subclass: __new__ and super().method()", [Title("hello world"), tname(Title("a")), Title("ab").upper(), str.__new__(Title, "zz"), str.upper(Title("q"))],
      ["Hello World", "Title", "UP:AB", "zz", "Q"])

# ── list ─────────────────────────────────────────────────────────────────────
class Stack(list):
    def push(self, v):
        self.append(v)
    def peek(self):
        return self[-1]

s = Stack([1, 2])
s.push(3)
check("list subclass: the list's behaviour", [s, len(s), s[0], s.peek(), s[-2:], 3 in s, list(s), sum(s), sorted(s, reverse=True), s == [1, 2, 3], [1, 2, 3] == s, isinstance(s, list), tname(s)],
      [[1, 2, 3], 3, 1, 3, [2, 3], True, [1, 2, 3], 6, [3, 2, 1], True, True, True, "Stack"])
check("list subclass: plain lists come back", [tname(s[0:2]), tname(s + [4]), tname([0] + s), tname(s * 2), tname(s.copy())], ["list", "list", "list", "list", "list"])
s += [4]
s[0] = 9
del s[1]
check("list subclass: changed in place", [list(s), tname(s), s.pop(), list(s), s.index(3), s.count(9)], [[9, 3, 4], "Stack", 4, [9, 3], 1, 1])
s.extend([5, 1])
s.sort()
s.reverse()
s.insert(0, 7)
check("list subclass: list methods", [s, [v * 2 for v in s], list(enumerate(Stack(["a"]))), list(zip(Stack([1, 2]), "ab")), json.dumps(s), Stack(), Stack("ab"), str(Stack([1]))],
      [[7, 9, 5, 3, 1], [14, 18, 10, 6, 2], [(0, "a")], [(1, "a"), (2, "b")], "[7, 9, 5, 3, 1]", [], ["a", "b"], "[1]"])

class Named(list):
    def __init__(self, name, items=()):
        super().__init__(items)
        self.name = name

nl = Named("xs", [1, 2])
check("list subclass: super().__init__", [nl, nl.name, len(nl), vars(nl), Named("e"), list.__init__ is not None], [[1, 2], "xs", 2, {"name": "xs"}, [], True])
a1, b1 = Stack([10, 20])
check("list subclass: unpacking and hashing", [a1, b1, [*Stack([1, 2]), 3]], [10, 20, [1, 2, 3]])
try:
    hash(Stack())
    check("list subclass: unhashable", "no error", "TypeError")
except TypeError:
    check("list subclass: unhashable", "TypeError", "TypeError")

# ── dict ─────────────────────────────────────────────────────────────────────
class Config(dict):
    def get_int(self, k):
        return int(self[k])

cfg = Config(a="1", b="2")
check("dict subclass: the dict's behaviour", [cfg, cfg["a"], cfg.get_int("b"), len(cfg), sorted(cfg), list(cfg.items()), "a" in cfg, cfg.get("z", 0), isinstance(cfg, dict), tname(cfg)],
      [{"a": "1", "b": "2"}, "1", 2, 2, ["a", "b"], [("a", "1"), ("b", "2")], True, 0, True, "Config"])
check("dict subclass: as a dict", [json.dumps(cfg, sort_keys=True), dict(cfg), {**cfg, "c": 3}, cfg == {"a": "1", "b": "2"}, tname(cfg.copy()), tname(cfg | {"z": 1}), list(Config([("k", 1)]).keys())],
      ['{"a": "1", "b": "2"}', {"a": "1", "b": "2"}, {"a": "1", "b": "2", "c": 3}, True, "dict", "dict", ["k"]])
cfg["c"] = "3"
del cfg["a"]
check("dict subclass: changed in place", [dict(cfg), cfg.pop("b"), cfg.setdefault("d", "4"), dict(cfg), list(cfg.values()), Config.fromkeys("xy", 0), tname(Config.fromkeys("x"))],
      [{"b": "2", "c": "3"}, "2", "4", {"c": "3", "d": "4"}, ["3", "4"], {"x": 0, "y": 0}, "Config"])

class LowerDict(dict):
    def __setitem__(self, k, v):
        super().__setitem__(k.lower(), v)

ld = LowerDict()
ld["A"] = 1
ld.update({"B": 2})
ld.setdefault("C", 3)
check("dict subclass: __setitem__ (the type's own methods do not call it)", [dict(ld), ld["a"], "B" in ld, "b" in ld, "C" in ld], [{"a": 1, "B": 2, "C": 3}, 1, True, False, True])

class Defaulting(dict):
    def __missing__(self, k):
        return k * 2

dm = Defaulting(x=1)
check("dict subclass: __missing__", [dm["x"], dm["ab"], "ab" in dm, dm.get("ab"), len(dm)], [1, "abab", False, None, 1])

# ── set / frozenset ──────────────────────────────────────────────────────────
class Tags(set):
    def tagged(self, t):
        return t in self

t = Tags(["a", "b"])
t.add("c")
check("set subclass", [sorted(t), len(t), t.tagged("a"), "z" in t, sorted(t | {"d"}), tname(t | {"d"}), sorted(t & {"a", "z"}), t == {"a", "b", "c"}, isinstance(t, set), repr(Tags()), sorted(Tags("xy")), t >= {"a"}],
      [["a", "b", "c"], 3, True, False, ["a", "b", "c", "d"], "set", ["a"], True, True, "Tags()", ["x", "y"], True])
t |= {"e"}
t.discard("a")
check("set subclass: changed in place", [sorted(t), tname(t), repr(Tags([1]))], [["b", "c", "e"], "Tags", "Tags({1})"])

class FTags(frozenset):
    pass

ft = FTags([1, 2])
check("frozenset subclass", [ft == frozenset([1, 2]), hash(ft) == hash(frozenset([1, 2])), {frozenset([1, 2]): "f"}[ft], 1 in ft, len(ft), sorted(ft | {3}), repr(FTags([5]))],
      [True, True, "f", True, 2, [1, 2, 3], "FTags({5})"])

# ── tuple ────────────────────────────────────────────────────────────────────
class Point(tuple):
    def __new__(cls, x, y):
        return tuple.__new__(cls, (x, y))
    @property
    def x(self):
        return self[0]
    @property
    def y(self):
        return self[1]
    def __repr__(self):
        return "Point(x=%r, y=%r)" % (self.x, self.y)

p = Point(1, 2)
px, py = p
check("tuple subclass (namedtuple style)", [p.x, p.y, len(p), p == (1, 2), p[0], list(p), repr(p), str(p), isinstance(p, tuple), hash(p) == hash((1, 2)), {(1, 2): "pt"}[p], p + (3,), tname(p + (3,)), px, py, p[:1], max(p)],
      [1, 2, 2, True, 1, [1, 2], "Point(x=1, y=2)", "Point(x=1, y=2)", True, True, "pt", (1, 2, 3), "tuple", 1, 2, (1,), 2])

class Pair(tuple):
    pass

check("tuple subclass: from an iterable, compared, sorted", [Pair([1, 2]), Pair() == (), Pair("ab") < Pair("b"), sorted([Pair((2,)), Pair((1,))]), json.dumps(Pair([1, 2])), Pair([3, 1]).index(1)],
      [(1, 2), True, True, [(1,), (2,)], "[1, 2]", 1])

check("%-formatting: a tuple subclass is the arguments, a dict subclass the mapping, an int subclass one value",
      ["%s-%s" % Pair([1, 2]), "%(a)s" % Config(a=5), "%s|%d|%x" % (Meters(3), Meters(3), MyInt(255)), "%s" % Meters(4), "<%s>" % Name("n")],
      ["1-2", "5", "Meters(3)|3|ff", "Meters(4)", "<n>"])

# ── in-place operators and a subclass's own protocol methods ─────────────────
class Bits(set):
    pass

class Acc:
    def __init__(self):
        self.log = []
    def __ior__(self, o):
        self.log.append(("|=", o))
        return self
    def __ifloordiv__(self, o):
        self.log.append(("//=", o))
        return self
    def __ipow__(self, o):
        self.log.append(("**=", o))
        return self

bits = Bits([1])
bits |= {2}
bits &= {2, 3}
bits ^= {4}
bits -= {4}
acc = Acc()
acc |= 1
acc //= 2
acc **= 3
check("x |= y calls __ior__ (and the other in-place methods)", [tname(bits), sorted(bits), tname(acc), acc.log],
      ["Bits", [2], "Acc", [("|=", 1), ("//=", 2), ("**=", 3)]])

class Countdown(list):
    def __iter__(self):
        return iter(range(len(self) - 1, -1, -1))

cd = Countdown(["a", "b", "c"])
check("a list subclass's own __iter__ is what builtins iterate", [list(cd), tuple(cd), sorted(cd), [x for x in cd], cd[0], len(cd), sum(cd), ",".join(map(str, cd))],
      [[2, 1, 0], (2, 1, 0), [0, 1, 2], [2, 1, 0], "a", 3, 3, "2,1,0"])

def kwnames(**kw):
    return sorted(kw.items())

class Shouty(dict):
    def __getitem__(self, k):
        return "!" + str(super().__getitem__(k))

def shape(x):
    match x:
        case (a, b):
            return "pair %r %r" % (a, b)
        case {"a": v}:
            return "mapping %r" % (v,)
        case _:
            return "other"

pairs = []
for a, b in [Pair([1, 2]), Point(3, 4), (5, 6)]:
    pairs.append(a + b)
check("a dict subclass for **, tuple subclasses unpacked and matched",
      [kwnames(**Config(a=1, b=2)), {**Shouty(a=1)}, Shouty(a=1)["a"], pairs, shape(Point(1, 2)), shape((7, 8)), shape([9, 10]), shape(Config(a=3)), shape("ab")],
      [[("a", 1), ("b", 2)], {"a": 1}, "!1", [3, 7, 11], "pair 1 2", "pair 7 8", "pair 9 10", "mapping 3", "other"])

# ── bytes / bytearray ────────────────────────────────────────────────────────
class Blob(bytes):
    pass

bl = Blob(b"ab")
check("bytes subclass", [bl, bl[0], len(bl), bl.decode(), bl + b"c", bl.upper(), isinstance(bl, bytes), bl == b"ab", hash(bl) == hash(b"ab"), list(bl), bl.hex(), tname(bl[:1]), b"x" + bl],
      [b"ab", 97, 2, "ab", b"abc", b"AB", True, True, True, [97, 98], "6162", "bytes", b"xab"])

class Buffer(bytearray):
    pass

bf = Buffer(b"ab")
bf.append(99)
bf[0] = 65
check("bytearray subclass", [repr(bf), len(bf), bytes(bf), isinstance(bf, bytearray), tname(bf), bf == b"Abc", bf.decode()], ["Buffer(b'Abc')", 3, b"Abc", True, "Buffer", True, "Abc"])

# ── mixing a builtin type with other bases ───────────────────────────────────
class Describe:
    def describe(self):
        return tname(self) + ":" + repr(self)

class Code(Describe, int):
    pass

check("a builtin base after a class", [Code(7).describe(), Code(7) + 1, Code.__mro__ == (Code, Describe, int, object), MyInt.__mro__ == (MyInt, int, object), Point.__bases__ == (tuple,)],
      ["Code:7", 8, True, True, True])

# ── __getattribute__ ─────────────────────────────────────────────────────────
class Logged:
    def __init__(self):
        self.x = 1
        self.log = []
    def __getattribute__(self, name):
        if name != "log":
            object.__getattribute__(self, "log").append(name)
        return object.__getattribute__(self, name)
    def m(self):
        return "m"

lg = Logged()
check("__getattribute__ sees every read and call", [lg.x, lg.m(), getattr(lg, "x"), hasattr(lg, "nope"), lg.log], [1, "m", 1, False, ["x", "m", "x", "nope"]])

class Fallback:
    def __getattribute__(self, name):
        if name.startswith("v_"):
            return name[2:]
        return object.__getattribute__(self, name)
    def __getattr__(self, name):
        return "missing:" + name

fb = Fallback()
check("__getattribute__, then __getattr__ on AttributeError", [fb.v_abc, fb.other, getattr(fb, "zz"), hasattr(fb, "q")], ["abc", "missing:other", "missing:zz", True])

class Raiser:
    def __getattribute__(self, name):
        raise AttributeError(name)
    def __getattr__(self, name):
        return "fb:" + name

check("__getattribute__ raising: __getattr__", [Raiser().q, Raiser().method_name], ["fb:q", "fb:method_name"])

class Upper:
    def __init__(self):
        self.a = 1
    def __getattribute__(self, name):
        return super().__getattribute__(name.lower())

check("super().__getattribute__", [Upper().A, Upper().a], [1, 1])

calls = []
class Spy:
    def __getattribute__(self, name):
        calls.append(name)
        return object.__getattribute__(self, name)
    def __len__(self):
        return 3
    def __add__(self, o):
        return 10 + o
    def __repr__(self):
        return "Spy"

sp = Spy()
check("special methods do not go through __getattribute__", [len(sp), sp + 1, repr(sp), calls], [3, 11, "Spy", []])
try:
    object.__getattribute__(sp, "nothing")
    check("object.__getattribute__ raises", "no error", "AttributeError")
except AttributeError:
    check("object.__getattribute__ raises", "AttributeError", "AttributeError")

class Inherits(Logged):
    pass

il = Inherits()
il.x
check("__getattribute__ is inherited", [il.log], [["x"]])

# ── obj.__dict__ is live ─────────────────────────────────────────────────────
class Obj:
    def __init__(self):
        self.a = 1

o = Obj()
d = o.__dict__
o.__dict__["b"] = 2
o.c = 3
check("__dict__ is a live view", [o.b, d, vars(o) is o.__dict__, d is o.__dict__, "c" in d, len(d), d["a"]], [2, {"a": 1, "b": 2, "c": 3}, True, True, True, 3, 1])
del o.__dict__["a"]
check("del obj.__dict__[k] removes the attribute", [hasattr(o, "a"), sorted(vars(o))], [False, ["b", "c"]])
o.__dict__.update(x=9, y=8)
check("__dict__.update / get / pop", [o.x, o.y, sorted(o.__dict__.keys()), o.__dict__.get("x"), o.__dict__.pop("y"), hasattr(o, "y"), o.__dict__.setdefault("z", 0), o.z],
      [9, 8, ["b", "c", "x", "y"], 9, 8, False, 0, 0])
check("__dict__ is a dict", [isinstance(o.__dict__, dict), json.dumps(vars(o), sort_keys=True), dict(o.__dict__), {**vars(o)}, sorted(o.__dict__.items()), o.__dict__ == {"b": 2, "c": 3, "x": 9, "z": 0}],
      [True, '{"b": 2, "c": 3, "x": 9, "z": 0}', {"b": 2, "c": 3, "x": 9, "z": 0}, {"b": 2, "c": 3, "x": 9, "z": 0}, [("b", 2), ("c", 3), ("x", 9), ("z", 0)], True])
try:
    del o.__dict__["nope"]
    check("del of a missing key", "no error", "KeyError")
except KeyError:
    check("del of a missing key", "KeyError", "KeyError")

class Frozen:
    def __init__(self, v):
        self.__dict__["v"] = v
    def __setattr__(self, k, v):
        raise AttributeError("frozen")

fz = Frozen(4)
check("a __dict__ store bypasses __setattr__", [fz.v, vars(fz)], [4, {"v": 4}])
o2 = Obj()
o2.__dict__ = {"q": 1}
check("__dict__ assignment", [hasattr(o2, "a"), o2.q, vars(o2)], [False, 1, {"q": 1}])
o2.__marked__ = True
check("dunder attributes are in __dict__", ["__marked__" in vars(o2), o2.__dict__["__marked__"]], [True, True])
o2.__dict__.clear()
check("__dict__.clear", [vars(o2), hasattr(o2, "q")], [{}, False])

# ── __prepare__ ──────────────────────────────────────────────────────────────
class RecordingDict(dict):
    def __init__(self):
        super().__init__()
        self.order = []
    def __setitem__(self, k, v):
        if not k.startswith("__"):
            self.order.append(k)
        super().__setitem__(k, v)

class Meta(type):
    @classmethod
    def __prepare__(mcs, name, bases, **kw):
        ns = RecordingDict()
        ns.kw = kw
        ns.args = (name, len(bases))
        return ns
    def __new__(mcs, name, bases, ns, **kw):
        cls = super().__new__(mcs, name, bases, dict(ns))
        cls.order = ns.order
        cls.kw = ns.kw
        cls.args = ns.args
        return cls

class Ordered(metaclass=Meta, flag=1):
    b = 1
    a = 2
    def f(self):
        return 3
    b = 4

check("__prepare__ sees every binding, in order", [Ordered.order, Ordered.b, Ordered().f(), Ordered.kw, Ordered.args], [["b", "a", "f", "b"], 4, 3, {"flag": 1}, ("Ordered", 0)])

def twice(f):
    return lambda self: 2 * f(self)

class Decorated(metaclass=Meta):
    @property
    def p(self):
        return 5
    @twice
    @twice
    def g(self):
        return 1
    @staticmethod
    def s():
        return 7

check("__prepare__ sees a decorated def once, decorated", [Decorated.order, Decorated().p, Decorated().g(), Decorated.s()],
      [["p", "g", "s"], 5, 4, 7])

class NoDupes(dict):
    def __setitem__(self, k, v):
        if k in self and not k.startswith("__"):
            raise TypeError("Attempted to reuse key: %r" % k)
        super().__setitem__(k, v)

class NoDupMeta(type):
    @classmethod
    def __prepare__(mcs, name, bases):
        return NoDupes()

try:
    class Dup(metaclass=NoDupMeta):
        A = 1
        A = 2
    check("a name bound twice", "no error", "TypeError")
except TypeError as e:
    check("a name bound twice", str(e), "Attempted to reuse key: 'A'")

class Fine(metaclass=NoDupMeta):
    A = 1
    B = 2

check("no duplicates: the class is made", [Fine.A, Fine.B, type(Fine).__name__], [1, 2, "NoDupMeta"])

class Numbering(dict):
    def __init__(self):
        super().__init__()
        self.n = 0
    def __setitem__(self, k, v):
        if v is None and not k.startswith("__"):
            self.n += 1
            v = self.n
        super().__setitem__(k, v)

class AutoMeta(type):
    @classmethod
    def __prepare__(mcs, name, bases):
        return Numbering()

class Nums(metaclass=AutoMeta):
    A = None
    B = None
    C = A + B

check("the body reads what the mapping holds", [Nums.A, Nums.B, Nums.C], [1, 2, 3])

class Sub(Nums):
    D = None

check("a subclass's body goes to its metaclass's __prepare__ too", [Sub.D, Sub.A], [1, 1])

# ── the libraries that stand on it ───────────────────────────────────────────
import copy
from enum import Enum, IntEnum, StrEnum, Flag, auto
from collections import namedtuple
from typing import NamedTuple

class Level(IntEnum):
    LOW = 1
    HIGH = 2

class Perm(Flag):
    R = auto()
    W = auto()
    RW = R | W

class Tone(StrEnum):
    UP = "up"

class Coin(int, Enum):
    def __new__(cls, cents, label):
        obj = int.__new__(cls, cents)
        obj._value_ = cents
        obj.label = label
        return obj
    PENNY = (1, "penny")
    DIME = (10, "dime")

try:
    class Twice(Enum):
        A = 1
        A = 2
    twice = "no error"
except TypeError as e:
    twice = str(e)

check("enum: members are values, _EnumDict, int.__new__ in a member __new__",
      [{1: "low"}[Level.LOW], Level.HIGH in {2}, Level.LOW + Level.HIGH, isinstance(Level.LOW, int), Perm.RW.value, Perm.R | Perm.W is Perm.RW,
       Tone.UP.upper(), Tone.UP == "up", {"up": 1}[Tone.UP], Coin.DIME + 1, Coin.DIME.label, Coin(10) is Coin.DIME, twice],
      ["low", True, 3, True, 3, True, "UP", True, 1, 11, "dime", True, "'A' already defined as 1"])

P2 = namedtuple("P2", "x y")

class P3(NamedTuple):
    x: int
    y: int = 0

pn = P2(1, 2)
pt = P3(3)
check("namedtuple and NamedTuple are tuples",
      [isinstance(pn, tuple), pn[1:], pn + (3,), hash(pn) == hash((1, 2)), json.dumps(pn), isinstance(pt, tuple), tuple(pt), pt.y, pt == (3, 0), repr(pt)],
      [True, (2,), (1, 2, 3), True, "[1, 2]", True, (3, 0), 0, True, "P3(x=3, y=0)"])

st = Stack([1, [2]])
st.tag = "t"
sc = copy.copy(st)
sd = copy.deepcopy(st)
mc = copy.copy(Meters(3, "km"))
check("copy and deepcopy make the subclass again", [tname(sc), list(sc), sc.tag, sc[1] is st[1], tname(sd), sd[1] is st[1], sd.tag, tname(mc), mc, mc.unit],
      ["Stack", [1, [2]], "t", True, "Stack", False, "t", "Meters", Meters(3), "km"])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT85 PASSED ===")
