# vm_audit86.ny - classes and objects, the smaller gaps, both engines (round 77).
#
# - every class statement makes a class of its own: two statements naming
#   the same class (two functions' class P, a redefinition) no longer share
#   one class on the VM, nor a base looked up by name on the interpreter;
# - everything is an object: isinstance(5, object), (None, object), (C, object);
# - a class defining __eq__ without __hash__ is unhashable (__hash__ None in
#   its __dict__), with CPython's inheritance rules;
# - property, staticmethod and classmethod are objects: C.__dict__["p"] is a
#   property (fget/fset/fdel/__doc__, getter/setter/deleter,
#   property(fget, fset, fdel, doc)), C.p is the property, staticmethod and
#   classmethod objects have __func__;
# - dir(obj) / dir(C) list what Python lists, vars(obj) the dunder attributes too;
# - super(C, obj).m() and super(C, C2).m() outside a method;
# - bound methods and builtin methods: type, repr, __name__, __qualname__,
#   __self__, __func__;
# - type objects for None, functions, bound methods, builtins, generators and
#   the lazy iterators (type(None)() is None, type(f) is types.FunctionType);
# - a dict's methods win over its keys (d = {"get": 1}; d.get("x")).
#
# Every expected value is CPython's: `python3 examples/vm_audit86.ny` passes too.
#
#     ./build/nython-cli examples/vm_audit86.ny
#     ./build/nython-cli --vm examples/vm_audit86.ny
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

# ── 1. every class statement makes its own class ─────────────────────────────
def make_first():
    class P:
        tag = 1
        def m(self):
            return "first"
    return P

def make_second():
    class P:
        tag = 2
        def m(self):
            return "second"
    return P

A = make_first()
B = make_second()
check("two statements named P", [A().m(), B().m(), A.tag, B.tag, A is B, A.__name__, B.__name__],
      ["first", "second", 1, 2, False, "P", "P"])
check("their instances", [isinstance(A(), A), isinstance(A(), B), isinstance(B(), B), type(A()) is A, type(B()) is A],
      [True, False, True, True, False])
check("the first class after the second was made", [make_first()().m(), A().m(), A.tag], ["first", "first", 1])

def make_child():
    class Base:
        def who(self):
            return "child's base"
    class Child(Base):
        pass
    return Child

def make_base():
    class Base:
        def who(self):
            return "another base"
    return Base

Child = make_child()
Other = make_base()
check("a base is the class in scope", [Child().who(), Other().who(), issubclass(Child, Other), Child.__mro__[1].__name__],
      ["child's base", "another base", False, "Base"])

class Redef:
    def v(self):
        return 1
r1 = Redef()
class Redef:
    def v(self):
        return 2
r2 = Redef()
check("a redefined class", [r1.v(), r2.v(), type(r1) is type(r2), isinstance(r1, Redef), isinstance(r2, Redef), type(r1).__name__],
      [1, 2, False, False, True, "Redef"])

class Oops(Exception):
    pass
first_oops = Oops
class Oops(Exception):
    pass
def catch_oops(cls):
    try:
        raise cls("x")
    except Oops as e:
        return "caught " + type(e).__name__
    except Exception as e:
        return "other " + type(e).__name__
check("exceptions of one name", [catch_oops(Oops), catch_oops(first_oops), first_oops is Oops, issubclass(first_oops, Exception)],
      ["caught Oops", "other Oops", False, True])

made = []
for i in range(3):
    class Loop:
        n = i
    made.append(Loop)
check("a class statement in a loop", [c.n for c in made] + [made[0] is made[1]], [0, 1, 2, False])

# ── 2. everything is an object ───────────────────────────────────────────────
def plain_function():
    pass
check("isinstance(x, object)",
      [isinstance(5, object), isinstance("s", object), isinstance(None, object), isinstance(A(), object),
       isinstance(int, object), isinstance(A, object), isinstance(len, object), isinstance([], object),
       isinstance(plain_function, object), isinstance({}, object), isinstance(1.5, object), isinstance((1,), object)],
      [True, True, True, True, True, True, True, True, True, True, True, True])
check("issubclass(C, object)", [issubclass(int, object), issubclass(A, object), issubclass(bool, object), issubclass(object, object)],
      [True, True, True, True])
check("isinstance(x, (str, object))", [isinstance(5, (str, object)), isinstance(5, (str, list))], [True, False])

# ── 3. __eq__ without __hash__ ───────────────────────────────────────────────
class Eq:
    def __init__(self, v):
        self.v = v
    def __eq__(self, other):
        return isinstance(other, Eq) and other.v == self.v

class EqHash(Eq):
    def __hash__(self):
        return hash(self.v)

class EqHashChild(EqHash):
    pass

class EqAgain(EqHash):
    def __eq__(self, other):
        return True

class HashOnly:
    def __hash__(self):
        return 7

class NoHash:
    __hash__ = None

class Plain:
    pass

def hashable(x):
    try:
        hash(x)
        return True
    except TypeError:
        return False

check("which classes are hashable",
      [hashable(Eq(1)), hashable(EqHash(1)), hashable(EqHashChild(1)), hashable(EqAgain(1)), hashable(HashOnly()),
       hashable(NoHash()), hashable(Plain())],
      [False, True, True, False, True, False, True])
check("__hash__ is None in the class's __dict__",
      [Eq.__hash__ is None, "__hash__" in Eq.__dict__, Eq.__dict__["__hash__"], "__hash__" in EqHashChild.__dict__,
       EqAgain.__hash__ is None, "__hash__" in Plain.__dict__],
      [True, True, None, False, True, False])
check("the error", [raises(hash, Eq(1)), raises(lambda: {Eq(1)}), raises(lambda: {Eq(1): 1})],
      ["TypeError: unhashable type: 'Eq'", "TypeError: unhashable type: 'Eq'", "TypeError: unhashable type: 'Eq'"])
check("== still works", [Eq(1) == Eq(1), Eq(1) == Eq(2), Eq(1) in [Eq(0), Eq(1)], len({EqHash(1), EqHash(1), EqHash(2)})],
      [True, False, True, 2])
check("hash by the inherited __hash__", [hash(EqHashChild(5)) == hash(5), hash(HashOnly())], [True, 7])

# ── 4. property, staticmethod and classmethod objects ────────────────────────
class Props:
    def __init__(self):
        self._x = 1
        self.log = []
    @property
    def x(self):
        "the x"
        return self._x
    @x.setter
    def x(self, value):
        self.log.append("set")
        self._x = value
    @x.deleter
    def x(self):
        self.log.append("del")
        self._x = None
    def _get_y(self):
        return "y"
    y = property(_get_y, None, None, "doc of y")
    ro = property(lambda self: "read only")
    @staticmethod
    def sm(a, b):
        return a + b
    @classmethod
    def cm(cls, a):
        return cls.__name__ + ":" + str(a)

px = Props.__dict__["x"]
check("a property in __dict__",
      [type(px) is property, isinstance(px, property), px.__doc__, px.fget is not None, px.fset is not None,
       px.fdel is not None, Props.x is px, type(Props.x).__name__],
      [True, True, "the x", True, True, True, True, "property"])
check("property(fget, fset, fdel, doc)",
      [Props.y.__doc__, Props.y.fset, Props.y.fdel, Props().y, Props().ro, Props.ro.__doc__, property().fget],
      ["doc of y", None, None, "y", "read only", None, None])
o = Props()
o.x = 5
got_x = o.x
del o.x
check("getter, setter, deleter run", [got_x, o._x, o.log, px.fget(o), px.__get__(o, Props), px.__get__(None, Props) is px],
      [5, None, ["set", "del"], None, None, True])
q = Props()
px.__set__(q, 9)
px.fset(q, 10)
check("calling __set__ and fset", [q._x, q.log], [10, ["set", "set"]])

class NoGetter:
    z = property()
check("property errors",
      [raises(setattr, Props(), "ro", 1), raises(delattr, Props(), "ro"), raises(getattr, NoGetter(), "z"),
       raises(property().__get__, Props())],
      ["AttributeError: property 'ro' of 'Props' object has no setter",
       "AttributeError: property 'ro' of 'Props' object has no deleter",
       "AttributeError: property 'z' of 'NoGetter' object has no getter",
       "AttributeError: property of 'Props' object has no getter"])

def other_getter(self):
    return "other"
p2 = px.getter(other_getter)
p3 = px.setter(None)
p4 = property(None, None, None, "kept").getter(other_getter)
check("getter() / setter() make a new property",
      [p2 is px, p2.fget is other_getter, p2.fset is px.fset, p2.fdel is px.fdel, p3.fset is px.fset, p3.fget is px.fget,
       p3.__doc__, p2.__doc__, p4.__doc__, p4.fget is other_getter],
      [False, True, True, True, True, True, "the x", None, "kept", True])

class SubProp(property):
    pass
class UsesSub:
    @SubProp
    def a(self):
        return 11
check("a subclass of property", [UsesSub().a, type(UsesSub.__dict__["a"]) is SubProp, isinstance(UsesSub.a, property)],
      [11, True, True])

smo = Props.__dict__["sm"]
cmo = Props.__dict__["cm"]
check("staticmethod / classmethod objects in __dict__",
      [type(smo) is staticmethod, isinstance(smo, staticmethod), smo.__func__(1, 2), type(cmo) is classmethod,
       isinstance(cmo, classmethod), cmo.__func__(Props, 3), smo.__func__.__name__, cmo.__func__.__name__],
      [True, True, 3, True, True, "Props:3", "sm", "cm"])
check("and through the class and an instance",
      [Props.sm(1, 2), Props().sm(3, 4), Props.cm(5), Props().cm(6), smo.__get__(None, Props)(2, 3)],
      [3, 7, "Props:5", "Props:6", 5])

def adder(a, b):
    return a + b
st = staticmethod(adder)
cl = classmethod(adder)
check("made outside a class", [st.__func__ is adder, cl.__func__ is adder, st(1, 2), st.__wrapped__ is adder, isinstance(st, staticmethod)],
      [True, True, 3, True, True])

class Later:
    pass
Later.s = staticmethod(adder)
Later.c = classmethod(lambda cls, v: cls.__name__ + str(v))
Later.p = property(lambda self: "late")
check("put on a class afterwards",
      [Later.s(2, 3), Later().s(4, 5), Later.c(1), Later().c(2), Later().p, type(Later.__dict__["s"]) is staticmethod,
       type(Later.__dict__["p"]) is property],
      [5, 9, "Later1", "Later2", "late", True, True])

class BodyCall:
    @staticmethod
    def helper(v):
        return v * 3
    tripled = helper(5)
check("a staticmethod called in its class body (3.10+)", [BodyCall.tripled, BodyCall.helper(2), BodyCall().helper(3), callable(st)],
      [15, 6, 9, True])
check("vars(C) holds the objects too", [type(vars(Props)["sm"]) is staticmethod, type(vars(Props)["x"]) is property,
                                        isinstance(vars(Props)["sm"].__func__, types.FunctionType)],
      [True, True, True])

class Meta(type):
    @property
    def size(cls):
        return len(cls.__name__)
class WithMeta(metaclass=Meta):
    pass
check("a metaclass's property", [WithMeta.size, isinstance(Meta.__dict__["size"], property)], [8, True])

# ── 5. dir() and vars() ─────────────────────────────────────────────────────
class DirBase:
    cb = 1
    def bm(self):
        pass
class DirChild(DirBase):
    ca = 2
    def __init__(self):
        self.x = 1
        self.__z__ = 3
    def m(self):
        pass
dc = DirChild()
check("dir(instance): its attributes, its class's, its bases'", [n for n in dir(dc) if not n.startswith("__")],
      ["bm", "ca", "cb", "m", "x"])
check("dir(instance) has the dunders",
      ["__z__" in dir(dc), "__init__" in dir(dc), "__class__" in dir(dc), "__dict__" in dir(dc), "__eq__" in dir(dc),
       "__module__" in dir(dc), "__repr__" in dir(dc), dir(dc) == sorted(dir(dc))],
      [True, True, True, True, True, True, True, True])
check("dir(class)", [n for n in dir(DirChild) if not n.startswith("__")], ["bm", "ca", "cb", "m"])
check("dir(class) has no instance attribute", ["x" in dir(DirChild), "__init__" in dir(DirChild), "__name__" in dir(DirChild)],
      [False, True, False])
check("dir() of a plain instance, as Python lists it", dir(Plain()),
      ["__class__", "__delattr__", "__dict__", "__dir__", "__doc__", "__eq__", "__format__", "__ge__",
       "__getattribute__", "__getstate__", "__gt__", "__hash__", "__init__", "__init_subclass__", "__le__", "__lt__",
       "__module__", "__ne__", "__new__", "__reduce__", "__reduce_ex__", "__repr__", "__setattr__", "__sizeof__",
       "__str__", "__subclasshook__", "__weakref__"])
check("dir(object())-like names for a class", dir(Plain) == dir(Plain()), True)
check("vars(obj) has dunder attributes", vars(dc), {"x": 1, "__z__": 3})
check("vars(obj) is what __dict__ holds", [vars(dc) == dc.__dict__, list(vars(Plain()))], [True, []])
check("vars(C)", ["ca" in vars(DirChild), "cb" in vars(DirChild), "m" in vars(DirChild), "__init__" in vars(DirChild)],
      [True, False, True, True])

# ── 6. super() with two arguments ───────────────────────────────────────────
class SA:
    def m(self):
        return "SA.m"
    @classmethod
    def c(cls):
        return "SA.c:" + cls.__name__
class SB(SA):
    def m(self):
        return "SB.m"
    @classmethod
    def c(cls):
        return "SB.c"
class SC(SB):
    def m(self):
        return "SC.m"
class SD(SC):
    def m(self):
        return super(SB, self).m() + "/SD"
sc = SC()
check("super(C, obj) outside a method", [super(SB, sc).m(), super(SC, sc).m(), super(SA, sc).__init__() is None], ["SA.m", "SB.m", True])
check("super(C, C2) with a class", [super(SB, SC).c(), super(SC, SC).c(), super(SB, SB).m(sc), super(SB, sc).c()],
      ["SA.c:SC", "SB.c", "SA.m", "SA.c:SC"])
check("super(C, self) in a method skips classes", SD().m(), "SA.m/SD")
check("super(C, obj) with an obj not of C", raises(lambda: super(SB, 5).m()),
      "TypeError: super(type, obj): obj must be an instance or subtype of type")

class PA:
    kind = "PA kind"
    @property
    def p(self):
        return 1
    def m(self):
        return "PA.m"
    @classmethod
    def made(cls):
        return "made " + cls.__name__
class PB(PA):
    kind = "PB kind"
    @property
    def p(self):
        return super().p + 1
    def get_m(self):
        return super().m
    def get_kind(self):
        return super().kind
    def get_made(self):
        return super().made
check("super().attr without a call: a property, a method, a class attribute",
      [PB().p, PB().get_m()(), PB().get_kind(), PB().get_made()(), super(PB, PB()).kind, super(PB, PB()).p, super(PB, PB).made()],
      [2, "PA.m", "PA kind", "made PB", "PA kind", 1, "made PB"])

# ── 7. bound methods and builtin methods ─────────────────────────────────────
class BM:
    def m(self):
        return 1
bo = BM()
bm = bo.m
check("a bound method",
      [type(bm).__name__, bm.__name__, bm.__qualname__, bm.__self__ is bo, bm.__func__ is BM.m, bm(),
       repr(bm).startswith("<bound method BM.m of "), bo.m == bo.m, type(bm) is types.MethodType],
      ["method", "m", "BM.m", True, True, 1, True, True, True])
lst = [1]
ap = lst.append
ap(2)
check("a builtin method",
      [type(ap).__name__, ap.__name__, ap.__qualname__, ap.__self__ is lst, lst,
       repr(ap).startswith("<built-in method append of list object at 0x"), type(ap) is types.BuiltinMethodType],
      ["builtin_function_or_method", "append", "list.append", True, [1, 2], True, True])
check("other builtin methods", ["s".upper.__qualname__, {}.get.__name__, {}.get.__qualname__, "ab".upper.__self__, [].append.__name__],
      ["str.upper", "get", "dict.get", "ab", "append"])
def with_self(self, v):
    return [self is bo, v]
mt = types.MethodType(with_self, bo)
check("types.MethodType(f, obj)", [mt(5), mt.__self__ is bo, mt.__func__ is with_self, type(mt) is types.MethodType],
      [[True, 5], True, True, True])
check("MethodType errors", [raises(types.MethodType, with_self, None), raises(types.MethodType, 5, bo)],
      ["TypeError: instance must not be None", "TypeError: first argument must be callable"])

# ── 8. type objects for None, functions, builtins, generators ───────────────
def gen():
    yield 1
g = gen()
check("type(None)",
      [type(None) is types.NoneType, type(None)() is None, type(None).__name__, repr(type(None)), isinstance(None, type(None)),
       isinstance(0, type(None)), (None).__class__ is type(None), type(type(None)) is type, type(None).__module__],
      [True, True, "NoneType", "<class 'NoneType'>", True, False, True, True, "builtins"])
check("NoneType() takes no arguments", raises(type(None), 1), "TypeError: NoneType takes no arguments")
check("functions",
      [type(plain_function) is types.FunctionType, type(lambda: 0) is types.FunctionType, type(plain_function).__name__,
       repr(type(plain_function)), isinstance(plain_function, types.FunctionType), isinstance(len, types.FunctionType),
       isinstance(bm, types.FunctionType), plain_function.__class__ is types.FunctionType],
      [True, True, "function", "<class 'function'>", True, False, False, True])
check("builtins",
      [type(len) is types.BuiltinFunctionType, type(len).__name__, repr(type(len)), isinstance(len, types.BuiltinFunctionType),
       isinstance(plain_function, types.BuiltinFunctionType), type(len) is type([].append)],
      [True, "builtin_function_or_method", "<class 'builtin_function_or_method'>", True, False, True])
check("generators",
      [type(g) is types.GeneratorType, type(x for x in [1]) is types.GeneratorType, type(g).__name__, repr(type(g)),
       isinstance(g, types.GeneratorType), isinstance(iter([1]), types.GeneratorType)],
      [True, True, "generator", "<class 'generator'>", True, False])
check("methods", [type(bm).__name__, repr(type(bm)), isinstance(bm, types.MethodType), isinstance(plain_function, types.MethodType)],
      ["method", "<class 'method'>", True, False])
check("the lazy iterators",
      [type(iter([1])).__name__, type(iter("ab")).__name__, type(iter((1,))).__name__, type(iter({1: 2})).__name__,
       type(iter({1})).__name__, type(zip(gen(), gen())).__name__, type(map(str, gen())).__name__,
       type(filter(None, gen())).__name__, type(enumerate(gen())).__name__, repr(type(zip(gen(), gen())))],
      ["list_iterator", "str_ascii_iterator", "tuple_iterator", "dict_keyiterator", "set_iterator", "zip", "map",
       "filter", "enumerate", "<class 'zip'>"])
check("their reprs", [repr(iter([1])).startswith("<list_iterator object at 0x"), repr(zip(gen(), gen())).startswith("<zip object at 0x")],
      [True, True])
check("more iterators", [type(iter(b"ab")).__name__, type(iter(bytearray(b"a"))).__name__, type(iter("é")).__name__,
                         type(iter(frozenset())).__name__],
      ["bytes_iterator", "bytearray_iterator", "str_iterator", "set_iterator"])
check("the type objects' MRO", [type(None).__mro__ == (type(None), object), types.FunctionType.__bases__ == (object,),
                                issubclass(type(None), object), issubclass(types.FunctionType, object),
                                issubclass(type(None), int), isinstance(type(None), type)],
      [True, True, True, True, False, True])
check("calling them", [raises(type(plain_function)), raises(type(g))],
      ["TypeError: function() missing required argument 'code' (pos 1)", "TypeError: cannot create 'generator' instances"])
check("type objects as dict keys and in tuples",
      [{type(None): "n", type(len): "b"}[type(None)], type(g) in (types.GeneratorType, int), type(5) in (types.GeneratorType,)],
      ["n", True, False])

# ── 9. a dict's methods win over its keys ────────────────────────────────────
dk = {"get": 1, "keys": 2, "pop": 3, "items": 4, "values": 5, "x": 6}
check("dict methods with keys of their names",
      [dk.get("x"), dk.get("nope", 0), list(dk.keys()), dk["get"], dk.pop("x"), sorted(dk.values()), len(dk.items())],
      [6, 0, ["get", "keys", "pop", "items", "values", "x"], 1, 6, [1, 2, 3, 4, 5], 5])
getter = dk.get
check("read as values", [getter("keys"), getattr(dk, "keys")() == dk.keys(), callable(dk.pop), hasattr(dk, "update")],
      [2, True, True, True])
dk2 = {"update": lambda: "the key", "copy": 9}
dk2.update({"new": 1})
check("a callable key does not shadow the method", [dk2.copy()["copy"], "new" in dk2, dk2["update"]()], [9, True, "the key"])

# ── Nython only ──────────────────────────────────────────────────────────────
if nython:
    check("legacy names of the new type objects",
          [type(None) == "none", type(plain_function) == "function", type(len) == "builtin", type(g) == "generator",
           type(bm) == "function", type(zip(gen(), gen())) == "generator", typeof(None), typeof(plain_function), typeof(len),
           typeof(g), isinstance(plain_function, "function"), isinstance(g, "generator")],
          [True, True, True, True, True, True, "none", "function", "builtin", "generator", True, True])
    rec = {"name": "n", "count": 2, "id": 7}
    check("d.key still reads other keys", [rec.name, rec.count, rec.id, getattr(rec, "missing", "absent")], ["n", 2, 7, "absent"])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT86 PASSED ===")
