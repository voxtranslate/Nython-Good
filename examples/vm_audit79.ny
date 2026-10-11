# vm_audit79.ny - the class machinery Python's typing, dataclasses, enum and
# abc are built on, both engines (round 77).
#
# Written in the subset Nython and Python share, so the same file runs under
# python3 (`python3 examples/vm_audit79.ny` must also pass) - every expected
# value below is what CPython computes.
#
#   annotations  function, method, class-body and module __annotations__,
#                evaluated when the def / statement runs, seen by decorators;
#                `from __future__ import annotations` keeps them as text
#   PEP 487      __init_subclass__ with class keywords, __set_name__
#   __new__      singletons, __new__ returning another object, object.__new__
#   PEP 560      __class_getitem__, __mro_entries__, expression bases
#   generics     list[int], dict[str, list[int]], tuple[int, ...], X | Y,
#                isinstance(x, int | str)
#   classes      C.__dict__, Python's class reprs, one-line class bodies,
#                bound method attributes, `...` / Ellipsis
#   metaclasses  __new__/__init__/__call__, dunders and methods through the
#                class, __instancecheck__/__subclasscheck__, type(n, b, ns)
#   operators    NotImplemented and the reflected-method protocol, a
#                subclass's reflected method first, __mro__/__bases__ with
#                builtin bases and object, __subclasses__(), mro()
#   metaclasses  metaclass= with __new__ / __init__ (super() reaching type),
#                the class-object dunders (__iter__, __len__, __contains__,
#                __getitem__, __repr__, __call__, __instancecheck__,
#                __subclasscheck__), metaclass methods and properties,
#                inheritance, type(name, bases, ns), a metaclass called
#
# Must pass on both engines (and python3):
#     ./build/nython-cli examples/vm_audit79.ny
#     ./build/nython-cli --vm examples/vm_audit79.ny
try:
    true
except NameError:
    true = True
    false = False
    none = None

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

# ── annotations ──────────────────────────────────────────────────────────────
def f(a: int, b: "Later" = 2, *args: str, c: list = None, **kw: float) -> dict:
    return a
check("function annotations", f.__annotations__,
      {"a": int, "b": "Later", "args": str, "c": list, "kw": float, "return": dict})
def g(x):
    return x
check("no annotations", g.__annotations__, {})
g.__annotations__["x"] = 5
check("annotations dict kept", g.__annotations__, {"x": 5})

class P:
    x: int = 3
    y: str
    def m(self, q: int) -> None:
        pass
check("class annotations", [P.__annotations__, P.x, hasattr(P, "y")], [{"x": int, "y": str}, 3, False])
check("method annotations", [P.m.__annotations__, P().m.__annotations__], [{"q": int, "return": None}, {"q": int, "return": None}])

top: float = 1.5
other: int
check("module annotations", [__annotations__["top"], __annotations__["other"], top], [float, int, 1.5])

def deco(fn):
    fn.seen = dict(fn.__annotations__)
    return fn
@deco
def h(v: int) -> str:
    return str(v)
check("a decorator sees the annotations", h.seen, {"v": int, "return": str})

ns = {}
exec("from __future__ import annotations\ndef q(x: int, y: list[str]) -> Missing:\n    pass\n", ns)
check("from __future__ import annotations", ns["q"].__annotations__, {"x": "int", "y": "list[str]", "return": "Missing"})

class OneLine: x = 1
class OneAnn: y: int = 2
check("one-line class bodies", [OneLine.x, OneAnn.y, OneAnn.__annotations__], [1, 2, {"y": int}])

# ── __init_subclass__ / __set_name__ (PEP 487) ───────────────────────────────
class Plugin:
    registry = []
    def __init_subclass__(cls, name=None, **kw):
        super().__init_subclass__(**kw)
        Plugin.registry.append((cls.__name__, name))
class A1(Plugin, name="a"):
    pass
class B1(Plugin):
    pass
class C1(A1, name="c"):
    pass
check("__init_subclass__", Plugin.registry, [("A1", "a"), ("B1", None), ("C1", "c")])
try:
    class Bad(flag=1):
        pass
    check("class keywords without __init_subclass__", "no error", "TypeError")
except TypeError as e:
    check("class keywords without __init_subclass__", str(e), "Bad.__init_subclass__() takes no keyword arguments")

class Field:
    def __set_name__(self, owner, name):
        self.owner = owner.__name__
        self.name = name
class Model:
    title = Field()
    count = Field()
check("__set_name__", [Model.title.name, Model.title.owner, Model.count.name], ["title", "Model", "count"])

# ── __new__ ──────────────────────────────────────────────────────────────────
class Singleton:
    _inst = None
    def __new__(cls, *args):
        if cls._inst is None:
            cls._inst = super().__new__(cls)
            cls._inst.made = 0
        cls._inst.made = cls._inst.made + 1
        return cls._inst
    def __init__(self, v):
        self.v = v
s1 = Singleton(1)
s2 = Singleton(2)
check("__new__ singleton", [id(s1) == id(s2), s1.v, s1.made], [True, 2, 2])
class NotInit:
    def __new__(cls):
        return 42
    def __init__(self):
        raise Exception("not called")
check("__new__ returning another object", NotInit(), 42)
class Pt:
    def __new__(cls, x, y):
        obj = object.__new__(cls)
        obj.total = x + y
        return obj
    def __init__(self, x, y):
        self.x = x
pt = Pt(2, 3)
check("object.__new__", [pt.total, pt.x, type(pt).__name__], [5, 2, "Pt"])

# ── __class_getitem__, generics, unions ──────────────────────────────────────
class Box:
    def __class_getitem__(cls, item):
        return (cls.__name__, item)
check("__class_getitem__", [Box[int], Box["x"]], [("Box", int), ("Box", "x")])
check("builtin generics", [repr(list[int]), repr(dict[str, list[int]]), repr(tuple[int, ...]), list[int]([1, 2])],
      ["list[int]", "dict[str, list[int]]", "tuple[int, ...]", [1, 2]])
check("generic alias attributes", [list[int].__origin__ == list, list[int].__args__, dict[str, int].__args__],
      [True, (int,), (str, int)])
check("union repr", [repr(int | None), repr(int | str | None), repr(list[int] | None)], ["int | None", "int | str | None", "list[int] | None"])
check("isinstance with a union", [isinstance(1, int | str), isinstance(1.5, int | str), isinstance("s", int | str)], [True, False, True])

def make_base(tag):
    class Base:
        kind = tag
    return Base
class Child(make_base("dyn")):
    pass
check("a base given by an expression", [Child.kind, Child.__mro__[1].__name__], ["dyn", "Base"])
class Alias:
    def __init__(self, origin):
        self.origin = origin
    def __mro_entries__(self, bases):
        return (self.origin,)
class GB:
    def __class_getitem__(cls, item):
        return Alias(cls)
class UsesAlias(GB[int]):
    pass
check("__mro_entries__", [issubclass(UsesAlias, GB), UsesAlias.__mro__[1].__name__], [True, "GB"])

# ── classes ──────────────────────────────────────────────────────────────────
class D:
    a = 1
    def m(self):
        return 2
check("class __dict__", ["a" in D.__dict__, "m" in D.__dict__, D.__dict__["a"]], [True, True, 1])
class R:
    pass
check("class reprs", [repr(R), repr(int), repr(str), str(list), repr(dict)],
      ["<class '__main__.R'>", "<class 'int'>", "<class 'str'>", "<class 'list'>", "<class 'dict'>"])
class BM:
    def m(self, a: int) -> str:
        "the doc"
        return ""
bm_obj = BM()
bm = bm_obj.m
check("bound method attributes", [bm.__func__ == BM.m, id(bm.__self__) == id(bm_obj), bm.__annotations__, bm.__doc__, bm.__name__],
      [True, True, {"a": int, "return": str}, "the doc", "m"])
def stub():
    ...
check("Ellipsis", [stub(), repr(...), id(...) == id(Ellipsis), repr(Ellipsis)], [None, "Ellipsis", True, "Ellipsis"])

# ── metaclasses ──────────────────────────────────────────────────────────────
class Meta(type):
    def __new__(mcs, name, bases, ns, **kw):
        ns["tag"] = name.lower()
        cls = super().__new__(mcs, name, bases, ns)
        cls.made_by = "Meta"
        return cls
    def __init__(cls, name, bases, ns, **kw):
        super().__init__(name, bases, ns)
        cls.inited = True
    def __iter__(cls):
        return iter(cls.items)
    def __len__(cls):
        return len(cls.items)
    def __contains__(cls, x):
        return x in cls.items
    def __getitem__(cls, k):
        return cls.items[k]
    def __repr__(cls):
        return "<Meta " + cls.__name__ + ">"
    def describe(cls):
        return "class " + cls.__name__
    @property
    def size(cls):
        return len(cls.items)
class Bag(metaclass=Meta):
    items = [1, 2, 3]
check("metaclass __new__ / __init__", [Bag.tag, Bag.made_by, Bag.inited], ["bag", "Meta", True])
check("metaclass dunders", [list(Bag), len(Bag), 2 in Bag, 5 in Bag, Bag[0], repr(Bag), [x * 2 for x in Bag]],
      [[1, 2, 3], 3, True, False, 1, "<Meta Bag>", [2, 4, 6]])
check("metaclass methods and properties", [Bag.describe(), Bag.size], ["class Bag", 3])
check("the type of a class with a metaclass", [type(Bag) == Meta, isinstance(Bag, Meta), isinstance(Bag, type)], [True, True, True])
class SubBag(Bag):
    items = [9]
check("a metaclass is inherited", [SubBag.tag, list(SubBag), SubBag.inited, repr(SubBag)], ["subbag", [9], True, "<Meta SubBag>"])

class SingletonMeta(type):
    instances = {}
    def __call__(cls, *args, **kw):
        if cls not in SingletonMeta.instances:
            SingletonMeta.instances[cls] = super().__call__(*args, **kw)
        return SingletonMeta.instances[cls]
class Config(metaclass=SingletonMeta):
    def __init__(self, v):
        self.v = v
c1 = Config(1)
c2 = Config(2)
check("metaclass __call__", [id(c1) == id(c2), c1.v, type(c1).__name__], [True, 1, "Config"])

class CountMeta(type):
    calls = []
    def __call__(cls, *args, **kw):
        CountMeta.calls.append(cls.__name__)
        return super().__call__(*args, **kw)
class Inner(metaclass=CountMeta):
    pass
class Outer(metaclass=CountMeta):
    def __init__(self):
        self.inner = Inner()
outer = Outer()
check("a metaclass __call__ inside another's __init__", [CountMeta.calls, type(outer.inner).__name__], [["Outer", "Inner"], "Inner"])

class DuckMeta(type):
    def __instancecheck__(cls, obj):
        return hasattr(obj, "quack")
    def __subclasscheck__(cls, sub):
        return hasattr(sub, "quack")
class Duck(metaclass=DuckMeta):
    pass
class Robot:
    def quack(self):
        return "beep"
check("__instancecheck__ / __subclasscheck__", [isinstance(Robot(), Duck), isinstance(5, Duck), issubclass(Robot, Duck), issubclass(int, Duck)],
      [True, False, True, False])

def greet(self):
    return "hi " + self.name
Dyn = type("Dyn", (), {"name": "dyn", "greet": greet})
check("type(name, bases, ns)", [Dyn.__name__, Dyn().greet(), Dyn.name], ["Dyn", "hi dyn", "dyn"])
SubDyn = type("SubDyn", (Dyn,), {"extra": 1})
check("type() with a base", [SubDyn().greet(), SubDyn.extra, issubclass(SubDyn, Dyn)], ["hi dyn", 1, True])
Made = Meta("Made", (), {"items": [7, 8]})
check("a metaclass called", [Made.tag, list(Made), Made.inited, repr(Made)], ["made", [7, 8], True, "<Meta Made>"])

# ── NotImplemented, the reflected-operator protocol, __mro__, __subclasses__ ──
class V:
    def __init__(self, x):
        self.x = x
    def __add__(self, o):
        if isinstance(o, V):
            return V(self.x + o.x)
        return NotImplemented
    def __radd__(self, o):
        if isinstance(o, int):
            return V(self.x + o)
        return NotImplemented
    def __eq__(self, o):
        if not isinstance(o, V):
            return NotImplemented
        return self.x == o.x
    def __lt__(self, o):
        if not isinstance(o, V):
            return NotImplemented
        return self.x < o.x
class W:
    def __radd__(self, o):
        return "W.radd"
    def __eq__(self, o):
        return "W.eq"
check("NotImplemented falls through to the reflected method",
      [repr(NotImplemented), (V(1) + V(2)).x, (3 + V(4)).x, V(1) + W()], ["NotImplemented", 3, 7, "W.radd"])
def raises(f):
    try:
        f()
        return "no error"
    except TypeError as e:
        return str(e)
check("every method declining is a TypeError",
      [raises(lambda: V(1) + "s"), raises(lambda: V(1) < 5)],
      ["unsupported operand type(s) for +: 'V' and 'str'", "'<' not supported between instances of 'V' and 'int'"])
vv = V(1)
check("== falls back to identity; the reflected __eq__ result as it is",
      [V(1) == V(1), V(1) == 1, V(1) != 2, V(1) == W(), 1 == V(1), vv == vv, vv != vv, sorted([V(3), V(1), V(2)])[0].x],
      [True, False, True, "W.eq", False, True, False, 1])
class OpBase:
    def __add__(self, o):
        return "OpBase.add"
    def __radd__(self, o):
        return "OpBase.radd"
class OpDerived(OpBase):
    def __radd__(self, o):
        return "OpDerived.radd"
check("a subclass's reflected method first", [OpBase() + OpDerived(), OpDerived() + OpBase(), OpBase() + OpBase()],
      ["OpDerived.radd", "OpBase.add", "OpBase.add"])
class Acc:
    def __init__(self):
        self.n = 0
    def __iadd__(self, o):
        if isinstance(o, int):
            self.n += o
            return self
        return NotImplemented
    def __add__(self, o):
        return "Acc.add"
acc = Acc()
acc += 5
acc_n = acc.n
acc += "x"
check("__iadd__ declining falls back to __add__", [acc_n, acc], [5, "Acc.add"])
class MA:
    pass
class MB(MA):
    pass
class MC(MA):
    pass
class MD(MB, MC):
    pass
class MM(type):
    pass
class DD(dict):
    pass
check("__subclasses__, __mro__, __bases__, mro()",
      [[k.__name__ for k in MA.__subclasses__()], [k.__name__ for k in MD.__mro__], [k.__name__ for k in MA.__bases__],
       repr(MM.__mro__), repr(DD.__mro__), repr(MM.__bases__), [k.__name__ for k in MD.mro()], Exception.__mro__[-1] is object],
      [["MB", "MC"], ["MD", "MB", "MC", "MA", "object"], ["object"],
       "(<class '__main__.MM'>, <class 'type'>, <class 'object'>)", "(<class '__main__.DD'>, <class 'dict'>, <class 'object'>)",
       "(<class 'type'>,)", ["MD", "MB", "MC", "MA", "object"], True])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT79 PASSED ===")
