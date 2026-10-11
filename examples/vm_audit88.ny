# vm_audit88.ny - the remaining correctness gaps of the data model, both
# engines (round 78).
#
# - a walrus is a positional argument (f(x := 1)), and works in subscripts,
#   slices, set/list/dict displays and f-string fields;
# - private name mangling (CPython's _Py_Mangle): __name inside a class body
#   is _Class__name - attributes, class-body names, methods, nested
#   functions, lambdas, comprehensions, f-strings, global declarations,
#   parameters - but not call keywords, dunders or names in strings;
# - calling a value that is not callable is a TypeError;
# - every function of a class body is a method whatever its first parameter
#   is called (def m(this, x), def m(s), def m(cls) on a metaclass);
# - a builtin value's dunder methods ((5).__add__(3), "ab".__len__(),
#   [1].__getitem__(0), {}.__contains__(k)) with Python's NotImplemented,
#   f.__call__, type(module) is the module type;
# - class C(*bases) / class C(*bases, **kw), a set display alone on a line,
#   return/break/continue in an except* block are SyntaxErrors;
# - a data descriptor of the class wins over an instance field, a
#   non-data descriptor loses to it;
# - C.__dict__["__new__"] is a staticmethod, __init_subclass__ and
#   __class_getitem__ classmethods;
# - dict keys and set elements with __hash__ compare with __eq__ among
#   those of the same hash (equal objects of two classes are one key);
# - super() / super(C, obj) as a value is a proxy;
# - what __str__/__repr__/__len__/__bool__/__hash__/__iter__ return is
#   checked as Python checks it; a number's real/imag/numerator/denominator;
#   pow() reaches __pow__ (with a modulus) and __rpow__.
#
# Every expected value is CPython's: `python3 examples/vm_audit88.ny` passes
# too.
#
#     ./build/nython-cli examples/vm_audit88.ny
#     ./build/nython-cli --vm examples/vm_audit88.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import types

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def raises(fn, *args):
    # the exception's type name and message, or "no error"
    try:
        fn(*args)
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"

def syntax_error(src):
    # the SyntaxError's message (without its location), or "no error"
    try:
        exec(src, {})
    except SyntaxError as e:
        return "SyntaxError: " + e.msg
    return "no error"

def show(*args, **kw):
    return [list(args), sorted(kw.items())]

# ── 1. walrus ────────────────────────────────────────────────────────────────
check("f(x := 1) is a positional argument", [show(wa := 1), wa], [[[1], []], 1])
check("f(x=1) stays a keyword", show(wa=2), [[], [("wa", 2)]])
check("walrus among other arguments", [show(1, *[2], wb := 7, k=1), wb], [[[1, 2, 7], [("k", 1)]], 7])
check("walrus in print's arguments", [str(wc := 5), wc], ["5", 5])
lst = [10, 20, 30]
check("walrus as a subscript", [lst[wd := 1], wd, lst[(we := 2)], we], [20, 1, 30, 2])
check("walrus in a slice", [lst[(s0 := 0):(s1 := 2)], s0, s1], [[10, 20], 0, 2])
check("walrus in a set display", [sorted({wf := 3, 4}), wf], [[3, 4], 3])
check("walrus in a list display", [[wg := 4, wg + 1], wg], [[4, 5], 4])
check("walrus in a dict display", [{(wh := "k"): (wi := 9)}, wh, wi], [{"k": 9}, "k", 9])
check("walrus in an f-string field", [f"{(wj := 3)}", wj, f"{(wk := 2) * 10}", wk], ["3", 3, "20", 2])
def walrus_in_call():
    total = sum([n := 5, n * 2])
    return total, n
check("walrus in a call inside a function", walrus_in_call(), (15, 5))

# ── 2. private name mangling ─────────────────────────────────────────────────
class Mangled:
    __count = 1
    def __init__(self):
        self.__secret = 2
        self.__dunder__ = 3
        self.__ = 4
    def total(self):
        return self.__secret + Mangled.__count + self.__count
    def __hidden(self):
        return "hidden"
    def call_hidden(self):
        return self.__hidden()
    def by_lambda(self):
        return (lambda: self.__secret)()
    def by_comprehension(self):
        return [self.__secret * k for k in range(3)]
    def by_nested(self):
        def inner():
            return self.__secret + 10
        return inner()
    def by_fstring(self):
        return f"<{self.__secret}>"
    def by_getattr(self):
        return [getattr(self, "_Mangled__secret"), hasattr(self, "__secret")]
    def param(self, __p=5):
        return __p
    def other(self, o):
        return o.__secret

m = Mangled()
check("self.__x is stored as _Class__x", sorted(vars(m)), ["_Mangled__secret", "__", "__dunder__"])
check("reads through every path", [m.total(), m.call_hidden(), m.by_lambda(), m.by_comprehension(),
                                    m.by_nested(), m.by_fstring(), m.by_getattr()],
      [4, "hidden", 2, [0, 2, 4], 12, "<2>", [2, False]])
check("the mangled names from outside", [m._Mangled__secret, Mangled._Mangled__count, m._Mangled__hidden()],
      [2, 1, "hidden"])
check("the plain name is not there", [hasattr(m, "__secret"), hasattr(Mangled, "__count"), hasattr(Mangled, "__hidden")],
      [False, False, False])
check("obj.__x of another instance", m.other(Mangled()), 2)
check("a method's __name__ and __qualname__ stay as written",
      [Mangled._Mangled__hidden.__name__, Mangled._Mangled__hidden.__qualname__], ["__hidden", "Mangled.__hidden"])
check("a parameter is mangled too", [m.param(), m.param(6), Mangled.param.__code__.co_varnames[:2]],
      [5, 6, ("self", "_Mangled__p")])

def keywords(**kw):
    return sorted(kw)
class KeywordNames:
    def call(self):
        return keywords(__plain=1)
check("a call keyword is not mangled", KeywordNames().call(), ["__plain"])

class _Leading:
    def __init__(self):
        self.__v = 1
class __Both:
    def __init__(self):
        self.__v = 1
class ___:
    def __init__(self):
        self.__v = 1
check("the class name's leading underscores are stripped",
      [list(vars(_Leading())), list(vars(__Both())), list(vars(___()))], [["_Leading__v"], ["_Both__v"], ["__v"]])

class Outer:
    class __Inner:
        kind = "inner"
    def get(self):
        return self.__Inner.kind
check("a nested class's name is mangled, its __name__ is not",
      [Outer().get(), Outer._Outer__Inner.__name__, hasattr(Outer, "__Inner")], ["inner", "__Inner", False])

class Owner:
    def __init__(self):
        self.__p = 9
    def from_inner(self):
        class Inner:
            def get(s, o):
                return o.__p
        return Inner().get(self)
check("the innermost class mangles", raises(Owner().from_inner), "AttributeError: 'Owner' object has no attribute '_Inner__p'")

class Gl:
    def set_it(self):
        global __gl_value
        __gl_value = 5
Gl().set_it()
check("a global declaration is mangled", _Gl__gl_value, 5)

class Base1:
    def __init__(self):
        self.__x = "base"
    def base_x(self):
        return self.__x
class Derived1(Base1):
    def __init__(self):
        Base1.__init__(self)
        self.__x = "derived"
    def derived_x(self):
        return self.__x
d1 = Derived1()
check("each class has its own private names", [d1.base_x(), d1.derived_x(), sorted(vars(d1))],
      ["base", "derived", ["_Base1__x", "_Derived1__x"]])

# ── 3. calling what is not callable ──────────────────────────────────────────
one = 1
text = "s"
nothing = None
items = [1]
mapping = {}
pair = (1,)
real = 1.5
flag = True
check("calling a non-callable is a TypeError",
      [raises(one, "x"), raises(text), raises(nothing), raises(items), raises(mapping), raises(pair),
       raises(real), raises(flag)],
      ["TypeError: 'int' object is not callable", "TypeError: 'str' object is not callable",
       "TypeError: 'NoneType' object is not callable", "TypeError: 'list' object is not callable",
       "TypeError: 'dict' object is not callable", "TypeError: 'tuple' object is not callable",
       "TypeError: 'float' object is not callable", "TypeError: 'bool' object is not callable"])
def call_it(v):
    return v()
check("a call through a variable", [raises(call_it, 3), raises(call_it, b"x")],
      ["TypeError: 'int' object is not callable", "TypeError: 'bytes' object is not callable"])
def returns_none():
    return None
check("calling what a call returned", raises(lambda: returns_none()()), "TypeError: 'NoneType' object is not callable")

# ── 4. methods whatever their first parameter is called ─────────────────────
class Named:
    def __init__(this, v):
        this.v = v
    def with_this(this, x):
        return [type(this).__name__, this.v, x]
    def with_s(s):
        return s.v * 2
    def no_params():
        return "none"
    def star(*args):
        return len(args)
    @staticmethod
    def static(a, b):
        return a + b
    @classmethod
    def klass(k, v):
        return [k.__name__, v]
    @property
    def prop(me):
        return me.v + 100

n = Named(7)
check("a first parameter of any name is the instance",
      [n.with_this(1), n.with_s(), Named.with_this(n, 2), Named.with_s(n)],
      [["Named", 7, 1], 14, ["Named", 7, 2], 14])
check("a bound method value", [n.with_this(3), (n.with_s)()], [["Named", 7, 3], 14])
bound = n.with_this
check("a bound method kept in a variable", [bound(4), bound.__self__ is n], [["Named", 7, 4], True])
check("no parameters: the call has one argument too many", [raises(n.no_params), Named.no_params()],
      ["TypeError: Named.no_params() takes 0 positional arguments but 1 was given", "none"])
check("*args takes the instance", [n.star(1, 2), Named.star(1, 2)], [3, 2])
check("static and class methods", [n.static(1, 2), Named.static(3, 4), n.klass(5), Named.klass(6)],
      [3, 7, ["Named", 5], ["Named", 6]])
check("a property whose parameter is not self", n.prop, 107)

class Meta(type):
    def describe(cls):
        return "class " + cls.__name__
class WithMeta(metaclass=Meta):
    pass
check("a metaclass method's cls", WithMeta.describe(), "class WithMeta")

class Gen:
    def __init__(this):
        this.items = [1, 2, 3]
    def each(this):
        for i in this.items:
            yield i * 10
check("a generator method whose parameter is not self", list(Gen().each()), [10, 20, 30])

class DunderNamed:
    def __init__(o, x):
        o.x = x
    def __eq__(a, b):
        return isinstance(b, DunderNamed) and a.x == b.x
    def __hash__(a):
        return hash(a.x)
    def __repr__(z):
        return "DN(" + str(z.x) + ")"
check("dunders with other first parameters", [DunderNamed(1) == DunderNamed(1), repr(DunderNamed(2)),
                                             len({DunderNamed(1), DunderNamed(1)})], [True, "DN(2)", 1])

# ── 5. dunder methods of builtin values ──────────────────────────────────────
check("int's dunders", [(5).__add__(3), int.__add__(2, 3), (5).__sub__(2), (5).__mul__(2), (7).__floordiv__(2),
                        (7).__mod__(3), (2).__pow__(3), (5).__neg__(), (5).__radd__(1), (5).__lt__(6),
                        (5).__eq__(5), (5).__hash__() == hash(5), (1).__bool__(), (0).__bool__()],
      [8, 5, 3, 10, 3, 1, 8, -5, 6, True, True, True, True, False])
check("an operand the type does not take: NotImplemented",
      [(5).__add__("x"), (5).__eq__("a"), (5).__eq__(5.0), (5).__lt__(None), (1.5).__add__("x"), (5).__and__(1.5)],
      [NotImplemented, NotImplemented, NotImplemented, NotImplemented, NotImplemented, NotImplemented])
check("float's dunders", [(2.5).__mul__(2), (1.5).__round__(), (2.5).__add__(1), float.__add__(1.5, 2.0), (1.5).__eq__(1.5)],
      [5.0, 2, 3.5, 3.5, True])
check("str's dunders", ["ab".__len__(), "ab".__add__("c"), "ab".__contains__("a"), "ab".__getitem__(1),
                        "a".__mul__(3), "ab".__eq__("ab"), str.__len__("abc"), "x".__repr__()],
      [2, "abc", True, "b", "aaa", True, 3, "'x'"])
check("list, tuple and dict dunders", [[1].__getitem__(0), [1, 2].__len__(), [1, 2].__contains__(2),
                                       {}.__contains__("a"), {"a": 1}.__getitem__("a"), (1, 2).__len__(),
                                       list.__len__([1]), dict.__getitem__({"k": 2}, "k")],
      [1, 2, True, False, 1, 2, 1, 2])
f_add = (5).__add__
check("a dunder read as a value", [f_add(10), (3).__str__(), (3).__repr__(), True.__add__(1)], [15, "3", "3", 2])
def plus_one(v):
    return v + 1
check("a function's __call__", [plus_one.__call__(1), (lambda: 5).__call__(), Named(1).with_s.__call__(),
                                 len.__call__([1, 2])], [2, 5, 2, 2])
check("type(module) is the module type",
      [type(types) is types.ModuleType, isinstance(types, types.ModuleType), type(types).__name__,
       repr(type(types)), isinstance({}, types.ModuleType), type(types) is dict],
      [True, True, "module", "<class 'module'>", False, False])
mod = types.ModuleType("made", "doc")
check("ModuleType makes a module", [type(mod) is types.ModuleType, mod.__name__, mod.__doc__], [True, "made", "doc"])

# ── 6. syntax ────────────────────────────────────────────────────────────────
class SB1:
    def a(self):
        return "a"
class SB2:
    def b(self):
        return "b"
bases = (SB1, SB2)
class Starred(*bases):
    pass
check("class C(*bases)", [Starred.__bases__ == (SB1, SB2), Starred().a(), Starred().b()], [True, "a", "b"])
class KwBase:
    def __init_subclass__(cls, **kw):
        cls.got = sorted(kw.items())
kwargs = {"flag": 1}
more = (KwBase,)
class StarredKw(*more, **kwargs):
    pass
check("class C(*bases, **kw)", [StarredKw.got, StarredKw.__bases__ == (KwBase,)], [[("flag", 1)], True])
class StarEmpty(*()):
    pass
check("class C(*()) has object as its base", StarEmpty.__bases__ == (object,), True)

seen = []
def mark(v):
    seen.append(v)
    return v
{mark(1)}
{mark(2), mark(3)}
check("a set display alone on a line is an expression", seen, [1, 2, 3])
check("an unhashable element in it raises", raises(lambda: exec("{[1]}", {})), "TypeError: unhashable type: 'list'")

check("return in an except* block", syntax_error("def f():\n    try:\n        pass\n    except* ValueError:\n        return 1\n"),
      "SyntaxError: 'break', 'continue' and 'return' cannot appear in an except* block")
check("break in an except* block", syntax_error("for i in range(2):\n    try:\n        pass\n    except* ValueError:\n        break\n"),
      "SyntaxError: 'break', 'continue' and 'return' cannot appear in an except* block")
check("continue in an except* block", syntax_error("for i in range(2):\n    try:\n        pass\n    except* ValueError:\n        if i:\n            continue\n"),
      "SyntaxError: 'break', 'continue' and 'return' cannot appear in an except* block")
check("a loop or def inside an except* block owns its flow",
      syntax_error("for i in range(2):\n    try:\n        pass\n    except* ValueError:\n        for j in range(3):\n            break\n        def h():\n            return 2\n"),
      "no error")

# ── 7. attribute lookup order ────────────────────────────────────────────────
class WithProp:
    @property
    def v(self):
        return "property"
wp = WithProp()
wp.__dict__["v"] = "field"
check("a property wins over a field", [wp.v, wp.__dict__["v"]], ["property", "field"])

class NonData:
    def __get__(self, obj, owner):
        return "nondata"
class HasNonData:
    d = NonData()
hn = HasNonData()
check("a non-data descriptor read", hn.d, "nondata")
hn.__dict__["d"] = "field"
check("a non-data descriptor loses to a field", hn.d, "field")

class DataDesc:
    def __get__(self, obj, owner):
        return "data"
    def __set__(self, obj, value):
        raise AttributeError("read-only")
class HasData:
    d = DataDesc()
hd = HasData()
hd.__dict__["d"] = "field"
check("a data descriptor wins over a field", [hd.d, raises(setattr, hd, "d", 1), vars(hd)],
      ["data", "AttributeError: read-only", {"d": "field"}])

class DelOnly:
    def __get__(self, obj, owner):
        return "del-only"
    def __delete__(self, obj):
        pass
class HasDelOnly:
    d = DelOnly()
hdo = HasDelOnly()
hdo.__dict__["d"] = "field"
check("a descriptor with __delete__ only is a data descriptor", hdo.d, "del-only")

# ── 8. implicit static and class methods ─────────────────────────────────────
class Implicit:
    def __new__(cls, *a):
        return super().__new__(cls)
    def __init_subclass__(cls, **kw):
        pass
    def __class_getitem__(cls, item):
        return ("item", item)
check("__new__ is a staticmethod, __init_subclass__ / __class_getitem__ classmethods",
      [type(Implicit.__dict__["__new__"]).__name__, type(Implicit.__dict__["__init_subclass__"]).__name__,
       type(Implicit.__dict__["__class_getitem__"]).__name__],
      ["staticmethod", "classmethod", "classmethod"])
check("they still work", [isinstance(Implicit(), Implicit), Implicit[int]], [True, ("item", int)])

# ── 9. hashing objects into sets and dicts ───────────────────────────────────
class K1:
    def __init__(self, v):
        self.v = v
    def __eq__(self, o):
        return isinstance(o, (K1, K2)) and self.v == o.v
    def __hash__(self):
        return hash(self.v)
class K2:
    def __init__(self, v):
        self.v = v
    def __eq__(self, o):
        return isinstance(o, (K1, K2)) and self.v == o.v
    def __hash__(self):
        return hash(self.v)
check("equal objects of two classes are one element", len({K1(1), K2(1), K1(2)}), 2)
dk = {K1(1): "a"}
check("and one dict key", [dk[K2(1)], K2(1) in dk, K1(3) in dk, 1 in dk], ["a", True, False, False])
dk[K2(1)] = "b"
check("storing through an equal key replaces the value", [len(dk), dk[K1(1)], type(list(dk)[0]).__name__], [1, "b", "K1"])

class SameHash:
    def __init__(self, v):
        self.v = v
    def __eq__(self, o):
        return isinstance(o, SameHash) and self.v == o.v
    def __hash__(self):
        return 7
check("unequal objects of one hash stay apart", [len({SameHash(1), SameHash(2), SameHash(1)}),
                                                 len({SameHash(1): 1, SameHash(2): 2})], [2, 2])

class Num:
    def __init__(self, v):
        self.v = v
    def __eq__(self, o):
        if isinstance(o, Num):
            return self.v == o.v
        if isinstance(o, int):
            return self.v == o
        return NotImplemented
    def __hash__(self):
        return hash(self.v)
check("an object equal to an int is that int's key",
      [{1: "one"}[Num(1)], {Num(2): "two"}[2], 1 in {Num(1)}, len({1, Num(1)}), Num(5) in {5: 0}],
      ["one", "two", True, 1, True])
from fractions import Fraction
check("a Fraction and an int", [len({Fraction(1), 1}), {1: "one"}[Fraction(2, 2)], {Fraction(1, 2): "h"}.get(Fraction(2, 4))],
      [1, "one", "h"])

# ── 10. super() as a value ───────────────────────────────────────────────────
class SBase:
    tag = "base-tag"
    def __init__(self, x=0):
        self.x = x
    def m(self):
        return "base"
    def who(self):
        return "who:" + type(self).__name__
class SMid(SBase):
    def m(self):
        return "mid"
class SLeaf(SMid):
    def m(self):
        return "leaf"
    def via_proxy(self):
        s = super(SMid, self)
        return [s.m(), s.tag, s.who(), type(s).__name__ if not nython else "super"]
    def zero_arg(self):
        s = super()
        return [s.m(), s.tag]
    def init_through(self):
        s = super()
        s.__init__(42)
        return self.x
leaf = SLeaf()
check("super(C, obj) kept in a variable", leaf.via_proxy(), ["base", "base-tag", "who:SLeaf", "super"])
check("super() kept in a variable", leaf.zero_arg(), ["mid", "base-tag"])
check("its __init__", leaf.init_through(), 42)
outside = super(SLeaf, leaf)
check("made outside a method", [outside.m(), outside.__thisclass__ is SLeaf, outside.__self__ is leaf], ["mid", True, True])
check("super() argument errors", [raises(lambda: super(5, leaf)), raises(lambda: super(SLeaf, 5))],
      ["TypeError: super() argument 1 must be a type, not int",
       "TypeError: super(type, obj): obj must be an instance or subtype of type"])
check("a missing attribute", raises(lambda: super(SBase, leaf).nothing), "AttributeError: 'super' object has no attribute 'nothing'")
class InitChain(SBase):
    def __init__(self):
        super().__init__(7)
check("super().__init__ in a constructor", InitChain().x, 7)

# ── 11. what the protocol methods return is checked ─────────────────────────
class BadStr:
    def __str__(self):
        return 5
    def __repr__(self):
        return 6
check("__str__ / __repr__ must return a str", [raises(str, BadStr()), raises(repr, BadStr())],
      ["TypeError: __str__ returned non-string (type int)", "TypeError: __repr__ returned non-string (type int)"])
class NegLen:
    def __len__(self):
        return -1
class StrLen:
    def __len__(self):
        return "x"
class BoolLen:
    def __len__(self):
        return True
check("__len__ must return an int >= 0", [raises(len, NegLen()), raises(len, StrLen()), len(BoolLen()), raises(bool, NegLen())],
      ["ValueError: __len__() should return >= 0", "TypeError: 'str' object cannot be interpreted as an integer", 1,
       "ValueError: __len__() should return >= 0"])
class IntBool:
    def __bool__(self):
        return 1
check("__bool__ must return a bool", [raises(bool, IntBool()), raises(lambda: not IntBool())],
      ["TypeError: __bool__ should return bool, returned int", "TypeError: __bool__ should return bool, returned int"])
class StrHash:
    def __hash__(self):
        return "x"
check("__hash__ must return an int", [raises(hash, StrHash()), raises(lambda: {StrHash(): 1})],
      ["TypeError: __hash__ method should return an integer", "TypeError: __hash__ method should return an integer"])
class BadIter:
    def __iter__(self):
        return 5
check("__iter__ must return an iterator", raises(iter, BadIter()), "TypeError: iter() returned non-iterator of type 'int'")
check("a number's real, imag, numerator, denominator",
      [(5).real, (5).imag, (5).numerator, (5).denominator, (2.5).real, (2.5).imag, True.real, True.numerator],
      [5, 0, 5, 1, 2.5, 0.0, 1, 1])
class P3:
    def __pow__(self, e, m=None):
        return ("pow", e, m)
    def __rpow__(self, b):
        return ("rpow", b)
check("pow() with objects", [pow(P3(), 2), pow(P3(), 2, 5), pow(2, P3())], [("pow", 2, None), ("pow", 2, 5), ("rpow", 2)])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT88 PASSED ===")
