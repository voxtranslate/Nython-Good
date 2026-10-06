# vm_audit74.ny - abc, collections.abc, numbers, and functools.singledispatch
# on abstract base classes and annotations, both engines (round 77).
#
#   abc               ABCMeta (__abstractmethods__ from the namespace and the
#                     bases, the instantiation TypeError), abstractmethod
#                     under property / classmethod / staticmethod, register
#                     (virtual subclasses, decorator use, cycles refused),
#                     __subclasshook__, the caches and get_cache_token(),
#                     update_abstractmethods, the deprecated aliases
#   collections.abc   the whole hierarchy, the structural checks, the builtin
#                     registrations, the mixin methods of Sequence,
#                     MutableSequence, Mapping, MutableMapping, Set,
#                     MutableSet, the views, generic aliases
#   numbers           the numeric tower and its registrations (int, float,
#                     complex, bool, fractions.Fraction), abstract methods,
#                     mixins
#   functools         singledispatch on ABCs (CPython's _compose_mro),
#                     register by annotation and by union, cache
#                     invalidation, ambiguous dispatch
#   engines           a class's __dict__ lists its dunder methods (it hid
#                     them on the interpreter), isinstance(int, type),
#                     int.__mro__, issubclass with a tuple of ABCs,
#                     type(name, bases, {"__len__": ...}) and lambda self on
#                     the VM, super() in a classmethod, from a package import
#                     a submodule, a program's names not reaching modules
#
# Written in the subset Nython and Python share: `python3
# examples/vm_audit74.ny` must pass too, and every expected value is what
# CPython computes (the abstract-class message is 3.12's; 3.11's is
# accepted under python3).
#
#     ./build/nython-cli examples/vm_audit74.ny
#     ./build/nython-cli --vm examples/vm_audit74.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import sys
import abc
from abc import ABC, ABCMeta, abstractmethod
import collections
import collections.abc
from collections import abc as cabc
from collections.abc import (Container, Hashable, Iterable, Iterator, Reversible, Generator,
                             Sized, Callable, Collection, Sequence, MutableSequence, ByteString,
                             Set, MutableSet, Mapping, MutableMapping, MappingView, KeysView,
                             ItemsView, ValuesView, Awaitable, Coroutine, AsyncIterable,
                             AsyncIterator, AsyncGenerator)
import numbers
from fractions import Fraction
from functools import singledispatch, singledispatchmethod

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def raises(f, exc):
    # the message of the exc f() raises, or "no error"
    try:
        f()
    except exc as e:
        return str(e)
    return "no error"

def abstract_message(f):
    # CPython 3.12's message for instantiating an abstract class; 3.11
    # words it differently (accepted under python3 only)
    try:
        f()
    except TypeError as e:
        m = str(e)
        if not nython and " with abstract method" in m:
            head = m[0:m.index(" with abstract method")]
            names = m[m.index(" method") + 7:]
            plural = names.startswith("s")
            names = names[2:] if plural else names[1:]
            parts = names.split(", ")
            m = head + " without an implementation for abstract method" + ("s" if plural else "") + " '" + "', '".join(parts) + "'"
        return m
    return "no error"

# ── abc: abstract methods and the instantiation check ───────────────────────
class Shape(ABC):
    @abstractmethod
    def area(self):
        return 0
    def describe(self):
        return "shape of area " + str(self.area())

class Square(Shape):
    def __init__(self, side):
        self.side = side
    def area(self):
        return self.side * self.side

class TwoAbstract(ABC):
    @abstractmethod
    def b(self):
        pass
    @abstractmethod
    def a(self):
        pass

check("an abstract class cannot be instantiated", abstract_message(lambda: Shape()),
      "Can't instantiate abstract class Shape without an implementation for abstract method 'area'")
check("two abstract methods, sorted", abstract_message(lambda: TwoAbstract()),
      "Can't instantiate abstract class TwoAbstract without an implementation for abstract methods 'a', 'b'")
check("a concrete subclass", [Square(3).area(), Square(2).describe(), isinstance(Square(1), Shape)],
      [9, "shape of area 4", True])
check("__abstractmethods__", [sorted(Shape.__abstractmethods__), sorted(Square.__abstractmethods__),
                              sorted(TwoAbstract.__abstractmethods__), type(Shape.__abstractmethods__) is frozenset],
      [["area"], [], ["a", "b"], True])
check("the metaclass", [type(Shape) is ABCMeta, isinstance(Shape, ABCMeta), issubclass(ABCMeta, type),
                        type(ABC) is ABCMeta, isinstance(Square, type)],
      [True, True, True, True, True])
check("ABC itself", [sorted(ABC.__abstractmethods__), type(ABC()).__name__, repr(ABC), repr(ABCMeta)],
      [[], "ABC", "<class 'abc.ABC'>", "<class 'abc.ABCMeta'>"])

class Partial(TwoAbstract):
    def a(self):
        return "a"
class Full(Partial):
    def b(self):
        return "b"
check("abstract methods are inherited until implemented",
      [sorted(Partial.__abstractmethods__), abstract_message(lambda: Partial()), Full().a() + Full().b()],
      [["b"], "Can't instantiate abstract class Partial without an implementation for abstract method 'b'", "ab"])

class Direct(metaclass=ABCMeta):
    @abstractmethod
    def run(self):
        return "base run"
class DirectImpl(Direct):
    def run(self):
        return "impl+" + super().run()
check("metaclass=ABCMeta, and super() reaches the abstract method",
      [abstract_message(lambda: Direct()), DirectImpl().run()],
      ["Can't instantiate abstract class Direct without an implementation for abstract method 'run'", "impl+base run"])

class Reabstract(Square):
    @abstractmethod
    def area(self):
        return -1
check("an override that is abstract again", [sorted(Reabstract.__abstractmethods__), raises(lambda: Reabstract(1), TypeError) != "no error"],
      [["area"], True])

class ByAttribute(Shape):
    area = 7
check("an abstract method implemented by a plain attribute", [sorted(ByAttribute.__abstractmethods__), ByAttribute().area],
      [[], 7])

class Kinds(ABC):
    @property
    @abstractmethod
    def size(self):
        return 0
    @classmethod
    @abstractmethod
    def make(cls):
        return "made " + cls.__name__
    @staticmethod
    @abstractmethod
    def helper():
        return "help"
    @abstractmethod
    def method(self):
        pass

class KindsImpl(Kinds):
    @property
    def size(self):
        return 3
    @classmethod
    def make(cls):
        return "impl " + super().make()
    @staticmethod
    def helper():
        return "impl help"
    def method(self):
        return "m"

check("abstract property, classmethod, staticmethod",
      [sorted(Kinds.__abstractmethods__), sorted(KindsImpl.__abstractmethods__), KindsImpl().size,
       KindsImpl.make(), KindsImpl.helper(), KindsImpl().method(), Kinds.helper()],
      [["helper", "make", "method", "size"], [], 3, "impl made KindsImpl", "impl help", "m", "help"])

class OnlyProp(Kinds):
    @classmethod
    def make(cls):
        return 1
    @staticmethod
    def helper():
        return 2
    def method(self):
        return 3
check("an unimplemented abstract property", abstract_message(lambda: OnlyProp()),
      "Can't instantiate abstract class OnlyProp without an implementation for abstract method 'size'")

class Old(metaclass=ABCMeta):
    @abc.abstractclassmethod
    def cm(cls):
        return "cm"
    @abc.abstractstaticmethod
    def sm():
        return "sm"
    @abc.abstractproperty
    def p(self):
        return "p"
check("the deprecated aliases", [sorted(Old.__abstractmethods__), Old.cm(), Old.sm()], [["cm", "p", "sm"], "cm", "sm"])

class Both(Shape, TwoAbstract):
    def a(self):
        return 1
check("abstract methods from several bases", sorted(Both.__abstractmethods__), ["area", "b"])

class WithKw(ABC):
    seen = []
    def __init_subclass__(cls, tag=None, **kw):
        super().__init_subclass__(**kw)
        WithKw.seen.append((cls.__name__, tag))
class Tagged(WithKw, tag="t1"):
    pass
check("class keywords reach __init_subclass__ through ABCMeta", [WithKw.seen, Tagged().__class__.__name__], [[("Tagged", "t1")], "Tagged"])

class Constructed(ABC):
    def __init__(self, a, b=2, *rest, **kw):
        self.args = (a, b, rest, sorted(kw.items()))
check("instantiation passes the arguments through", Constructed(1, 5, 6, x=7).args, (1, 5, (6,), [("x", 7)]))

# ── abc: register, virtual subclasses, __subclasshook__ ──────────────────────
class Drawable(ABC):
    @abstractmethod
    def draw(self):
        pass

class Point:
    pass
check("before register", [isinstance(Point(), Drawable), issubclass(Point, Drawable)], [False, False])
token0 = abc.get_cache_token()
got = Drawable.register(Point)
check("register returns the class", got is Point, True)
check("after register", [isinstance(Point(), Drawable), issubclass(Point, Drawable), Drawable in Point.__mro__,
                         abc.get_cache_token() != token0],
      [True, True, False, True])
class SubPoint(Point):
    pass
check("a subclass of a virtual subclass", [issubclass(SubPoint, Drawable), isinstance(SubPoint(), Drawable)], [True, True])

@Drawable.register
class Decorated:
    pass
check("register as a class decorator", [Decorated.__name__, issubclass(Decorated, Drawable)], ["Decorated", True])

check("registering builtin types", [Drawable.register(tuple) is tuple, isinstance((1, 2), Drawable), issubclass(tuple, Drawable),
                                    isinstance([1], Drawable), isinstance("s", Drawable)],
      [True, True, True, False, False])
Drawable.register(int)
check("isinstance of builtin values", [isinstance(5, Drawable), isinstance(True, Drawable), isinstance(2.5, Drawable),
                                       issubclass(bool, Drawable), isinstance(None, Drawable)],
      [True, True, False, True, False])
check("tuple of classes", [isinstance(2.5, (Drawable, float)), isinstance("x", (Drawable, float)), issubclass(int, (str, Drawable))],
      [True, False, True])

class Base1(ABC):
    pass
class Derived1(Base1):
    pass
check("register refuses a cycle", raises(lambda: Derived1.register(Base1), RuntimeError), "Refusing to create an inheritance cycle")
check("register of itself or a subclass is a no-op", [Base1.register(Base1) is Base1, Base1.register(Derived1) is Derived1], [True, True])
check("register of a non-class", raises(lambda: Base1.register(5), TypeError), "Can only register classes")
check("issubclass of a non-class", raises(lambda: issubclass(5, Base1), TypeError), "issubclass() arg 1 must be a class")

class Leaf(Derived1):
    pass
class Outside:
    pass
Derived1.register(Outside)
check("a virtual subclass of a subclass (found through __subclasses__)",
      [issubclass(Outside, Base1), issubclass(Outside, Derived1), issubclass(Outside, Leaf), isinstance(Outside(), Base1)],
      [True, True, False, True])

class Later(ABC):
    pass
class Unrelated:
    pass
first = issubclass(Unrelated, Later)
Later.register(Unrelated)
check("the negative cache is invalidated by register", [first, issubclass(Unrelated, Later), isinstance(Unrelated(), Later)], [False, True, True])

class Cleared(ABC):
    pass
class Reg:
    pass
Cleared.register(Reg)
before = issubclass(Reg, Cleared)
Cleared._abc_registry_clear()
Cleared._abc_caches_clear()
check("_abc_registry_clear / _abc_caches_clear", [before, issubclass(Reg, Cleared)], [True, False])

class Quacks(ABC):
    @classmethod
    def __subclasshook__(cls, C):
        if cls is Quacks:
            for B in C.__mro__:
                if "quack" in B.__dict__:
                    return True
            return False
        return NotImplemented
class Duck:
    def quack(self):
        return "quack"
class Mallard(Duck):
    pass
class Dog:
    pass
class RoboDuck(Quacks):
    pass
check("__subclasshook__", [isinstance(Duck(), Quacks), issubclass(Mallard, Quacks), isinstance(Dog(), Quacks),
                           issubclass(RoboDuck, Quacks)],
      [True, True, False, False])
check("object.__subclasshook__ declines", object.__subclasshook__(int) is NotImplemented, True)

class Declines(ABC):
    @classmethod
    def __subclasshook__(cls, C):
        return NotImplemented
class Child(Declines):
    pass
check("a declining hook falls back to the MRO", [issubclass(Child, Declines), issubclass(int, Declines)], [True, False])

class Grows(ABC):
    @abstractmethod
    def f(self):
        pass
class Filled(Grows):
    pass
def f_impl(self):
    return "filled"
Filled.f = f_impl
stale = sorted(Filled.__abstractmethods__)
abc.update_abstractmethods(Filled)
check("update_abstractmethods", [stale, sorted(Filled.__abstractmethods__), Filled().f()], [["f"], [], "filled"])
class Plain:
    pass
check("update_abstractmethods of a plain class", abc.update_abstractmethods(Plain) is Plain, True)

class MyMeta(ABCMeta):
    def kind(cls):
        return "my " + cls.__name__
class WithMyMeta(metaclass=MyMeta):
    @abstractmethod
    def g(self):
        pass
class WithMyMetaImpl(WithMyMeta):
    def g(self):
        return 1
check("a metaclass derived from ABCMeta", [WithMyMeta.kind(), raises(lambda: WithMyMeta(), TypeError) != "no error",
                                          WithMyMetaImpl().g(), type(WithMyMeta) is MyMeta, isinstance(WithMyMeta, ABCMeta)],
      ["my WithMyMeta", True, 1, True, True])

# ── collections.abc: the module ──────────────────────────────────────────────
check("import forms", [cabc.Mapping is Mapping, collections.abc.Sequence is Sequence, cabc is collections.abc],
      [True, True, True])
check("class names", [repr(Mapping), Sequence.__name__, Sequence.__module__, repr(MutableSet)],
      ["<class 'collections.abc.Mapping'>", "Sequence", "collections.abc", "<class 'collections.abc.MutableSet'>"])
check("the hierarchy", [issubclass(Sequence, Reversible), issubclass(Sequence, Collection), issubclass(Collection, Sized),
                        issubclass(Collection, Iterable), issubclass(Collection, Container), issubclass(MutableMapping, Mapping),
                        issubclass(KeysView, Set), issubclass(ItemsView, MappingView), issubclass(ValuesView, Collection),
                        issubclass(Generator, Iterator), issubclass(Coroutine, Awaitable), issubclass(AsyncGenerator, AsyncIterator),
                        issubclass(ByteString, Sequence), issubclass(Set, Collection), issubclass(Mapping, Sequence)],
      [True, True, True, True, True, True, True, True, True, True, True, True, True, True, False])
check("abstract methods of the collections",
      [sorted(Sequence.__abstractmethods__), sorted(MutableSequence.__abstractmethods__), sorted(Mapping.__abstractmethods__),
       sorted(MutableMapping.__abstractmethods__), sorted(Set.__abstractmethods__), sorted(MutableSet.__abstractmethods__),
       sorted(Generator.__abstractmethods__), sorted(Coroutine.__abstractmethods__), sorted(AsyncGenerator.__abstractmethods__),
       sorted(Iterator.__abstractmethods__)],
      [["__getitem__", "__len__"], ["__delitem__", "__getitem__", "__len__", "__setitem__", "insert"],
       ["__getitem__", "__iter__", "__len__"], ["__delitem__", "__getitem__", "__iter__", "__len__", "__setitem__"],
       ["__contains__", "__iter__", "__len__"], ["__contains__", "__iter__", "__len__", "add", "discard"],
       ["send", "throw"], ["__await__", "send", "throw"], ["asend", "athrow"], ["__next__"]])
check("an ABC cannot be instantiated", [abstract_message(lambda: Sequence()), abstract_message(lambda: Sized())],
      ["Can't instantiate abstract class Sequence without an implementation for abstract methods '__getitem__', '__len__'",
       "Can't instantiate abstract class Sized without an implementation for abstract method '__len__'"])

# ── collections.abc: builtin values ──────────────────────────────────────────
def kinds(x):
    out = []
    for name, t in [("Container", Container), ("Hashable", Hashable), ("Iterable", Iterable), ("Iterator", Iterator),
                    ("Reversible", Reversible), ("Sized", Sized), ("Callable", Callable), ("Collection", Collection),
                    ("Sequence", Sequence), ("MutableSequence", MutableSequence), ("Set", Set), ("MutableSet", MutableSet),
                    ("Mapping", Mapping), ("MutableMapping", MutableMapping), ("ByteString", ByteString), ("Generator", Generator)]:
        if isinstance(x, t):
            out.append(name)
    return out

check("a list", kinds([1]), ["Container", "Iterable", "Reversible", "Sized", "Collection", "Sequence", "MutableSequence"])
check("a tuple", kinds((1,)), ["Container", "Hashable", "Iterable", "Reversible", "Sized", "Collection", "Sequence"])
check("a str", kinds("s"), ["Container", "Hashable", "Iterable", "Reversible", "Sized", "Collection", "Sequence"])
check("a dict", kinds({1: 2}), ["Container", "Iterable", "Reversible", "Sized", "Collection", "Mapping", "MutableMapping"])
check("a set", kinds({1}), ["Container", "Iterable", "Sized", "Collection", "Set", "MutableSet"])
check("a frozenset", kinds(frozenset([1])), ["Container", "Hashable", "Iterable", "Sized", "Collection", "Set"])
check("bytes", kinds(b"ab"), ["Container", "Hashable", "Iterable", "Reversible", "Sized", "Collection", "Sequence", "ByteString"])
check("a bytearray", kinds(bytearray(b"ab")),
      ["Container", "Iterable", "Reversible", "Sized", "Collection", "Sequence", "MutableSequence", "ByteString"])
check("numbers and None", [kinds(5), kinds(2.5), kinds(True), kinds(None)], [["Hashable"], ["Hashable"], ["Hashable"], ["Hashable"]])
def gen():
    yield 1
check("a generator", kinds(gen()), ["Hashable", "Iterable", "Iterator", "Generator"])
check("a lazy iterator", [kinds(iter([1, 2])), kinds(iter("ab"))], [["Hashable", "Iterable", "Iterator"], ["Hashable", "Iterable", "Iterator"]])
check("callables", [kinds(len), kinds(lambda: 0), kinds(gen), isinstance(int, Callable), isinstance(Shape, Callable)],
      [["Hashable", "Callable"], ["Hashable", "Callable"], ["Hashable", "Callable"], True, True])
check("range is a Sequence", [isinstance(range(3), Sequence), isinstance(range(3), Sized)], [True, True])
check("issubclass with builtin types",
      [issubclass(list, MutableSequence), issubclass(dict, Mapping), issubclass(str, Sequence), issubclass(tuple, Sequence),
       issubclass(frozenset, Set), issubclass(set, MutableSet), issubclass(int, Hashable), issubclass(list, Hashable),
       issubclass(bytes, ByteString), issubclass(dict, Hashable), issubclass(str, MutableSequence), issubclass(bool, Hashable),
       issubclass(dict, Reversible), issubclass(str, Reversible), issubclass(int, Iterable)],
      [True, True, True, True, True, True, True, False, True, False, False, True, True, True, False])

# ── collections.abc: structural checks on classes ────────────────────────────
class OnlyIter:
    def __iter__(self):
        return iter([1, 2])
class OnlyLen:
    def __len__(self):
        return 0
class OnlyContains:
    def __contains__(self, x):
        return True
class ItNext:
    def __iter__(self):
        return self
    def __next__(self):
        raise StopIteration
class AllThree:
    def __len__(self):
        return 0
    def __iter__(self):
        return iter([])
    def __contains__(self, x):
        return False
class Rev:
    def __iter__(self):
        return iter([])
    def __reversed__(self):
        return iter([])
class NoHash:
    __hash__ = None
class EqOnly:
    def __eq__(self, other):
        return True
class EqHash:
    def __eq__(self, other):
        return True
    def __hash__(self):
        return 1
class Calls:
    def __call__(self):
        return 1
class Waits:
    def __await__(self):
        yield
class AIter:
    def __aiter__(self):
        return self
    def __anext__(self):
        raise StopAsyncIteration
class FakeGen:
    def __iter__(self):
        return self
    def __next__(self):
        return 1
    def send(self, v):
        return 1
    def throw(self, *a):
        pass
    def close(self):
        pass
class SubOfIter(OnlyIter):
    pass
class IterNone(OnlyIter):
    __iter__ = None

check("one-trick ponies by structure",
      [issubclass(OnlyIter, Iterable), issubclass(OnlyLen, Sized), issubclass(OnlyContains, Container),
       issubclass(ItNext, Iterator), issubclass(OnlyIter, Iterator), issubclass(AllThree, Collection),
       issubclass(OnlyIter, Collection), issubclass(Rev, Reversible), issubclass(OnlyIter, Reversible),
       issubclass(Calls, Callable), issubclass(Waits, Awaitable), issubclass(AIter, AsyncIterable),
       issubclass(AIter, AsyncIterator), issubclass(FakeGen, Generator), issubclass(ItNext, Generator),
       issubclass(SubOfIter, Iterable), issubclass(IterNone, Iterable)],
      [True, True, True, True, False, True, False, True, False, True, True, True, True, True, False, True, False])
check("Hashable by structure", [issubclass(NoHash, Hashable), issubclass(EqOnly, Hashable), issubclass(EqHash, Hashable),
                                issubclass(Point, Hashable), isinstance(EqHash(), Hashable)],
      [False, False, True, True, True])
check("instances by structure", [isinstance(OnlyIter(), Iterable), isinstance(OnlyIter(), Sized), isinstance(Calls(), Callable),
                                 isinstance(AllThree(), Collection), isinstance(Waits(), Awaitable)],
      [True, False, True, True, True])
check("structure is not a Sequence", [issubclass(AllThree, Sequence), issubclass(AllThree, Set), issubclass(AllThree, Mapping)],
      [False, False, False])

# ── Sequence / MutableSequence mixins ────────────────────────────────────────
class Squares(Sequence):
    def __init__(self, n):
        self.n = n
    def __getitem__(self, i):
        if i < 0:
            i = i + self.n
        if i < 0 or i >= self.n:
            raise IndexError("out of range")
        return i * i
    def __len__(self):
        return self.n

sq = Squares(5)
check("Sequence mixins", [list(sq), 9 in sq, 10 in sq, list(reversed(sq)), sq.index(9), sq.count(4), sq.index(16, 2), len(sq)],
      [[0, 1, 4, 9, 16], True, False, [16, 9, 4, 1, 0], 3, 1, 4, 5])
check("Sequence.index start/stop and a missing value",
      [sq.index(1, -5), raises(lambda: sq.index(1, 2), ValueError) != "no error", raises(lambda: sq.index(16, 0, 4), ValueError) != "no error",
       sq.index(0, 0, 1)],
      [1, True, True, 0])
check("a Sequence subclass is a Sequence", [isinstance(sq, Sequence), isinstance(sq, Reversible), isinstance(sq, MutableSequence),
                                            isinstance(sq, Hashable), sorted(Squares.__abstractmethods__)],
      [True, True, False, True, []])

class MyList(MutableSequence):
    def __init__(self, items=()):
        self.data = list(items)
    def __getitem__(self, i):
        return self.data[i]
    def __setitem__(self, i, v):
        self.data[i] = v
    def __delitem__(self, i):
        del self.data[i]
    def __len__(self):
        return len(self.data)
    def insert(self, i, v):
        self.data.insert(i, v)

ml = MyList([1, 2, 3])
ml.append(4)
ml.extend([5, 6])
popped = ml.pop()
popped0 = ml.pop(0)
ml.remove(3)
ml.reverse()
step1 = list(ml)
ml += [9]
same = ml
ml.clear()
check("MutableSequence mixins", [step1, popped, popped0, same is ml, list(ml), len(ml), isinstance(ml, MutableSequence)],
      [[5, 4, 2], 6, 1, True, [], 0, True])
ml2 = MyList("ab")
ml2.extend(ml2)
check("extend with itself", list(ml2), ["a", "b", "a", "b"])
check("remove of a missing value", raises(lambda: MyList([1]).remove(5), ValueError) != "no error", True)
class HalfList(MutableSequence):
    def __getitem__(self, i):
        return 0
    def __len__(self):
        return 0
check("MutableSequence needs its abstract methods", abstract_message(lambda: HalfList()),
      "Can't instantiate abstract class HalfList without an implementation for abstract methods '__delitem__', '__setitem__', 'insert'")

# ── Mapping / MutableMapping mixins and the views ────────────────────────────
class Frozen(Mapping):
    def __init__(self, d):
        self._d = dict(d)
    def __getitem__(self, k):
        return self._d[k]
    def __iter__(self):
        return iter(self._d)
    def __len__(self):
        return len(self._d)

fm = Frozen({"a": 1, "b": 2})
check("Mapping mixins", [fm.get("a"), fm.get("z"), fm.get("z", 0), "a" in fm, "z" in fm, list(fm.keys()), list(fm.values()),
                         list(fm.items()), fm == {"a": 1, "b": 2}, fm == {"a": 1}, fm != {"a": 1}],
      [1, None, 0, True, False, ["a", "b"], [1, 2], [("a", 1), ("b", 2)], True, False, True])
check("Mapping views", [isinstance(fm.keys(), KeysView), isinstance(fm.items(), ItemsView), isinstance(fm.values(), ValuesView),
                        len(fm.keys()), "a" in fm.keys(), ("a", 1) in fm.items(), ("a", 2) in fm.items(), 2 in fm.values(),
                        5 in fm.values(), isinstance(fm.keys(), Set), isinstance(fm.values(), Set)],
      [True, True, True, 2, True, True, False, True, False, True, False])
check("KeysView set operations", [sorted(fm.keys() & {"a", "z"}), sorted(fm.keys() | {"z"}), sorted(fm.keys() - {"a"}),
                                  sorted(fm.keys() ^ {"a", "q"}), fm.keys() == {"a", "b"}, fm.keys() <= {"a", "b", "c"},
                                  fm.keys().isdisjoint(["x", "y"]), type(fm.keys() & {"a"}).__name__],
      [["a"], ["a", "b", "z"], ["b"], ["b", "q"], True, True, True, "set"])
check("view reprs", [repr(KeysView({"a": 1})), repr(ValuesView({1: 2})), repr(ItemsView({}))],
      ["KeysView({'a': 1})", "ValuesView({1: 2})", "ItemsView({})"])
check("a Mapping is not Reversible", [issubclass(Frozen, Reversible), Mapping.__reversed__ is None, isinstance(fm, Mapping),
                                      isinstance(fm, MutableMapping)],
      [False, True, True, False])

class Store(MutableMapping):
    def __init__(self, *args, **kw):
        self._d = {}
        self.update(*args, **kw)
    def __getitem__(self, k):
        return self._d[k]
    def __setitem__(self, k, v):
        self._d[k] = v
    def __delitem__(self, k):
        del self._d[k]
    def __iter__(self):
        return iter(self._d)
    def __len__(self):
        return len(self._d)

st = Store({"a": 1}, b=2)
st.update([("c", 3)])
st.update(Frozen({"d": 4}))
st.update(e=5)
p1 = st.pop("a")
p2 = st.pop("zz", "dflt")
p3 = raises(lambda: st.pop("zz"), KeyError)
sd1 = st.setdefault("b", 99)
sd2 = st.setdefault("f", 6)
pi = st.popitem()
check("MutableMapping mixins", [p1, p2, p3, sd1, sd2, pi, sorted(st.items()), len(st)],
      [1, "dflt", "'zz'", 2, 6, ("b", 2), [("c", 3), ("d", 4), ("e", 5), ("f", 6)], 4])
st.clear()
check("clear, popitem of an empty mapping", [len(st), raises(lambda: st.popitem(), KeyError)], [0, ""])
check("a MutableMapping subclass", [isinstance(st, MutableMapping), isinstance(st, Mapping), st == {}, Store(x=1) == {"x": 1}],
      [True, True, True, True])

# ── Set / MutableSet mixins ──────────────────────────────────────────────────
class ListSet(Set):
    def __init__(self, it=()):
        self.items = []
        for x in it:
            if x not in self.items:
                self.items.append(x)
    def __contains__(self, x):
        return x in self.items
    def __iter__(self):
        return iter(self.items)
    def __len__(self):
        return len(self.items)

a = ListSet([1, 2, 3])
b = ListSet([2, 3, 4])
check("Set comparisons", [a == ListSet([3, 2, 1]), a != b, ListSet([2, 3]) <= a, ListSet([2, 3]) < a, a < a, a <= a,
                          a >= ListSet([1]), a > ListSet([1]), a == {1, 2, 3}, a <= {1, 2, 3, 4}],
      [True, True, True, True, False, True, True, True, True, True])
check("Set operators", [sorted(a & b), sorted(a | b), sorted(a - b), sorted(a ^ b), type(a & b).__name__,
                        sorted(a & [3, 9]), sorted([2, 7] & a), sorted(a - [1]), sorted([1, 5] | a), sorted({2, 9} - a)],
      [[2, 3], [1, 2, 3, 4], [1], [1, 4], "ListSet", [3], [2], [2, 3], [1, 2, 3, 5], [9]])
check("isdisjoint, _hash", [a.isdisjoint([7, 8]), a.isdisjoint([3]), a._hash(), ListSet()._hash(), ListSet([5, -7, 100])._hash()],
      [True, False, -272375401224217160, 133146708735736, -3759759131576854860])
check("set and ListSet", [{1, 2, 3} == a, sorted(a | {1, 5}), isinstance(a, Set), isinstance(a, MutableSet)],
      [True, [1, 2, 3, 5], True, False])

class MSet(MutableSet):
    def __init__(self, it=()):
        self.items = []
        for x in it:
            self.add(x)
    def __contains__(self, x):
        return x in self.items
    def __iter__(self):
        return iter(list(self.items))
    def __len__(self):
        return len(self.items)
    def add(self, x):
        if x not in self.items:
            self.items.append(x)
    def discard(self, x):
        if x in self.items:
            self.items.remove(x)

m = MSet([1, 2, 3])
m.remove(2)
miss = raises(lambda: m.remove(42), KeyError)
m |= [7, 8]
m -= [8]
m ^= [1, 9]
s1 = sorted(m)
m &= [3, 9, 100]
s2 = sorted(m)
pv = m.pop()
m.clear()
check("MutableSet mixins", [s1, s2, miss, pv in [3, 9], len(m), isinstance(m, MutableSet)], [[3, 7, 9], [3, 9], "42", True, 0, True])
check("pop of an empty MutableSet", raises(lambda: MSet().pop(), KeyError), "")

# ── Iterator / Generator / Coroutine / async mixins and structure ───────────
class Countdown(Generator):
    def __init__(self, n):
        self.n = n
    def send(self, value):
        if self.n <= 0:
            raise StopIteration
        self.n = self.n - 1
        return self.n
    def throw(self, typ, val=None, tb=None):
        raise typ

cd = Countdown(3)
closed = Countdown(5)
closed.close()
check("Generator mixins", [list(cd), next(Countdown(2)), iter(cd) is cd, isinstance(cd, Iterator), closed.n,
                           sorted(Countdown.__abstractmethods__)],
      [[2, 1, 0], 1, True, True, 5, []])

class Stubborn(Generator):
    def send(self, value):
        return 1
    def throw(self, typ, val=None, tb=None):
        return 1
check("close() of a generator that ignores GeneratorExit", raises(lambda: Stubborn().close(), RuntimeError), "generator ignored GeneratorExit")

class Ticks(Iterator):
    def __init__(self):
        self.i = 0
    def __next__(self):
        self.i = self.i + 1
        if self.i > 3:
            raise StopIteration
        return self.i
t = Ticks()
check("Iterator mixin: __iter__ is self", [iter(t) is t, list(t), isinstance(t, Iterable)], [True, [1, 2, 3], True])

class FakeCoro:
    def __await__(self):
        yield
    def send(self, v):
        pass
    def throw(self, *a):
        pass
    def close(self):
        pass
class AGen:
    def __aiter__(self):
        return self
    def __anext__(self):
        pass
    def asend(self, v):
        pass
    def athrow(self, *a):
        pass
    def aclose(self):
        pass
async def agen_fn():
    yield 1
check("Coroutine / AsyncGenerator by structure",
      [issubclass(FakeCoro, Coroutine), issubclass(FakeCoro, Awaitable), issubclass(Waits, Coroutine),
       issubclass(AGen, AsyncGenerator), issubclass(AGen, AsyncIterator), issubclass(AIter, AsyncGenerator),
       isinstance(agen_fn(), AsyncGenerator), isinstance(agen_fn(), AsyncIterable)],
      [True, True, False, True, True, False, True, True])

class Bare(Iterable):
    def __iter__(self):
        return iter([7])
check("an ABC's concrete method through super()", [list(Bare()), list(Iterable.__iter__(Bare()))], [[7], []])

# ── generic aliases ──────────────────────────────────────────────────────────
check("generic aliases", [repr(Iterable[int]), repr(Mapping[str, int]), Mapping[str, int].__args__, Iterable[int].__origin__ is Iterable],
      ["collections.abc.Iterable[int]", "collections.abc.Mapping[str, int]", (str, int), True])
check("Callable[[...], R]", [repr(Callable[[int, str], float]), Callable[[int, str], float].__args__, repr(Callable[..., int])],
      ["collections.abc.Callable[[int, str], float]", (int, str, float), "collections.abc.Callable[..., int]"])
check("Callable[...] misuse", raises(lambda: Callable[int], TypeError), "Callable must be used as Callable[[arg, ...], result].")

# ── collections' own types ───────────────────────────────────────────────────
Pt = collections.namedtuple("Pt", "x y")
check("collections' types are registered",
      [isinstance(collections.deque([1]), MutableSequence), isinstance(collections.OrderedDict(), MutableMapping),
       isinstance(collections.Counter("ab"), Mapping), isinstance(collections.defaultdict(list), MutableMapping),
       isinstance(collections.ChainMap({}), MutableMapping), isinstance(collections.UserDict(), MutableMapping),
       isinstance(collections.UserList(), MutableSequence), isinstance(Pt(1, 2), Sequence), isinstance(collections.deque(), Hashable)],
      [True, True, True, True, True, True, True, True, False])
check("collections still works", [collections.Counter("abca").most_common(1), list(collections.deque([1, 2], maxlen=1)),
                                  Pt(1, 2).x, collections.OrderedDict([("a", 1)])["a"]],
      [[("a", 2)], [2], 1, 1])

# ── numbers ──────────────────────────────────────────────────────────────────
def tower(x):
    out = []
    for name, t in [("Number", numbers.Number), ("Complex", numbers.Complex), ("Real", numbers.Real),
                    ("Rational", numbers.Rational), ("Integral", numbers.Integral)]:
        if isinstance(x, t):
            out.append(name)
    return out
check("the numeric tower", [tower(5), tower(True), tower(2.5), tower(1j), tower(Fraction(1, 3)), tower("5"), tower(None), tower([1])],
      [["Number", "Complex", "Real", "Rational", "Integral"], ["Number", "Complex", "Real", "Rational", "Integral"],
       ["Number", "Complex", "Real"], ["Number", "Complex"], ["Number", "Complex", "Real", "Rational"], [], [], []])
check("issubclass on the tower", [issubclass(int, numbers.Integral), issubclass(float, numbers.Real), issubclass(float, numbers.Rational),
                                  issubclass(complex, numbers.Complex), issubclass(bool, numbers.Number), issubclass(Fraction, numbers.Rational),
                                  issubclass(numbers.Integral, numbers.Real), issubclass(numbers.Real, numbers.Integral), issubclass(str, numbers.Number)],
      [True, True, False, True, True, True, True, False, False])
check("abstract methods of the tower",
      [sorted(numbers.Number.__abstractmethods__), sorted(numbers.Complex.__abstractmethods__), len(numbers.Real.__abstractmethods__),
       sorted(numbers.Rational.__abstractmethods__ - numbers.Real.__abstractmethods__),
       sorted(numbers.Real.__abstractmethods__ - numbers.Rational.__abstractmethods__), len(numbers.Integral.__abstractmethods__)],
      [[], ["__abs__", "__add__", "__complex__", "__eq__", "__mul__", "__neg__", "__pos__", "__pow__", "__radd__", "__rmul__",
            "__rpow__", "__rtruediv__", "__truediv__", "conjugate", "imag", "real"], 23, ["denominator", "numerator"], ["__float__"], 34])
check("Number.__hash__ is None", [numbers.Number.__hash__ is None, raises(lambda: numbers.Real(), TypeError) != "no error"], [True, True])
check("names", [repr(numbers.Integral), numbers.Real.__module__], ["<class 'numbers.Integral'>", "numbers"])

class Meters(numbers.Real):
    # a Real: everything over a float
    def __init__(self, v):
        self.v = float(v)
    def __float__(self):
        return self.v
    def __trunc__(self):
        return int(self.v)
    def __floor__(self):
        return int(self.v // 1)
    def __ceil__(self):
        return -int((-self.v) // 1)
    def __round__(self, ndigits=None):
        return round(self.v, ndigits)
    def __floordiv__(self, other):
        return Meters(self.v // float(other))
    def __rfloordiv__(self, other):
        return Meters(float(other) // self.v)
    def __mod__(self, other):
        return Meters(self.v % float(other))
    def __rmod__(self, other):
        return Meters(float(other) % self.v)
    def __lt__(self, other):
        return self.v < float(other)
    def __le__(self, other):
        return self.v <= float(other)
    def __add__(self, other):
        return Meters(self.v + float(other))
    def __radd__(self, other):
        return Meters(float(other) + self.v)
    def __neg__(self):
        return Meters(-self.v)
    def __pos__(self):
        return Meters(self.v)
    def __mul__(self, other):
        return Meters(self.v * float(other))
    def __rmul__(self, other):
        return Meters(float(other) * self.v)
    def __truediv__(self, other):
        return Meters(self.v / float(other))
    def __rtruediv__(self, other):
        return Meters(float(other) / self.v)
    def __pow__(self, exponent):
        return Meters(self.v ** float(exponent))
    def __rpow__(self, base):
        return Meters(float(base) ** self.v)
    def __abs__(self):
        return Meters(abs(self.v))
    def __eq__(self, other):
        return self.v == float(other)
    def __hash__(self):
        return hash(self.v)
    def __repr__(self):
        return "Meters(" + repr(self.v) + ")"

m7 = Meters(7)
check("Real mixins", [m7.real, m7.imag, m7.conjugate(), m7.__divmod__(2), m7.__rdivmod__(15), m7.__complex__(),
                      m7 - 2, 10 - m7, bool(Meters(0)), bool(m7), isinstance(m7, numbers.Complex), isinstance(m7, numbers.Rational)],
      [Meters(7.0), 0, Meters(7.0), (Meters(3.0), Meters(1.0)), (Meters(2.0), Meters(1.0)), (7+0j), Meters(5.0), Meters(3.0),
       False, True, True, False])

class Count(numbers.Integral):
    # an Integral over an int, enough of it to use the mixins
    def __init__(self, n):
        self.n = n
    def __int__(self):
        return self.n
    def __pos__(self):
        return Count(self.n)
    def __neg__(self):
        return Count(-self.n)
    def __add__(self, o):
        return Count(self.n + int(o))
    def __radd__(self, o):
        return Count(int(o) + self.n)
    def __eq__(self, o):
        return self.n == int(o)
    def __repr__(self):
        return "Count(" + str(self.n) + ")"
    def __abs__(self): return Count(abs(self.n))
    def __mul__(self, o): return Count(self.n * int(o))
    def __rmul__(self, o): return Count(int(o) * self.n)
    def __truediv__(self, o): return self.n / int(o)
    def __rtruediv__(self, o): return int(o) / self.n
    def __pow__(self, e, mod=None): return Count(pow(self.n, int(e)))
    def __rpow__(self, b): return Count(pow(int(b), self.n))
    def __trunc__(self): return self.n
    def __floor__(self): return self.n
    def __ceil__(self): return self.n
    def __round__(self, nd=None): return self.n
    def __floordiv__(self, o): return Count(self.n // int(o))
    def __rfloordiv__(self, o): return Count(int(o) // self.n)
    def __mod__(self, o): return Count(self.n % int(o))
    def __rmod__(self, o): return Count(int(o) % self.n)
    def __lt__(self, o): return self.n < int(o)
    def __le__(self, o): return self.n <= int(o)
    def __lshift__(self, o): return Count(self.n << int(o))
    def __rlshift__(self, o): return Count(int(o) << self.n)
    def __rshift__(self, o): return Count(self.n >> int(o))
    def __rrshift__(self, o): return Count(int(o) >> self.n)
    def __and__(self, o): return Count(self.n & int(o))
    def __rand__(self, o): return Count(int(o) & self.n)
    def __xor__(self, o): return Count(self.n ^ int(o))
    def __rxor__(self, o): return Count(int(o) ^ self.n)
    def __or__(self, o): return Count(self.n | int(o))
    def __ror__(self, o): return Count(int(o) | self.n)
    def __invert__(self): return Count(~self.n)
    def __hash__(self): return hash(self.n)

c5 = Count(5)
check("Integral mixins", [c5.__index__(), c5.__float__(), c5.numerator, c5.denominator, c5.real, c5.imag, c5.conjugate(),
                          c5 - 2, 7 - c5, c5.__divmod__(2), sorted(Count.__abstractmethods__), isinstance(c5, numbers.Rational)],
      [5, 5.0, Count(5), 1, Count(5), 0, Count(5), Count(3), Count(2), (Count(2), Count(1)), [], True])

class Ratio(numbers.Rational):
    # only what Rational.__float__ needs is real here
    def __init__(self, p, q):
        self._p = p
        self._q = q
    @property
    def numerator(self):
        return self._p
    @property
    def denominator(self):
        return self._q
for name in sorted(numbers.Rational.__abstractmethods__):
    if name not in ("numerator", "denominator"):
        setattr(Ratio, name, lambda self, *a: NotImplemented)
abc.update_abstractmethods(Ratio)
check("Rational.__float__, update_abstractmethods", [Ratio(1, 4).__float__(), Ratio(10 ** 30, 10 ** 29).__float__(),
                                                    sorted(Ratio.__abstractmethods__)],
      [0.25, 10.0, []])

# ── functools.singledispatch with ABCs ───────────────────────────────────────
@singledispatch
def describe(x):
    return "object"
@describe.register(Sequence)
def _(x):
    return "sequence"
@describe.register(Mapping)
def _(x):
    return "mapping"
@describe.register(numbers.Integral)
def _(x):
    return "integral"
@describe.register(str)
def _(x):
    return "str"

check("dispatch on ABCs", [describe([1]), describe((1,)), describe({}), describe(5), describe(True), describe("s"),
                           describe(2.5), describe(Fraction(1, 2)), describe(sq), describe(fm), describe(collections.deque())],
      ["sequence", "sequence", "mapping", "integral", "integral", "str", "object", "object", "sequence", "mapping", "sequence"])
@describe.register(numbers.Real)
def _(x):
    return "real"
check("a later registration clears the cache", [describe(2.5), describe(Fraction(1, 2)), describe(5)], ["real", "real", "integral"])

class Shiny(ABC):
    pass
@describe.register(Shiny)
def _(x):
    return "shiny"
class Gem:
    pass
before_reg = describe(Gem())
Shiny.register(Gem)
check("a virtual subclass registered after dispatching", [before_reg, describe(Gem())], ["object", "shiny"])

@describe.register
def _(x: float):
    return "float by annotation"
@describe.register
def _(x: bytes | bytearray):
    return "binary"
@describe.register(type(None))
def _(x):
    return "none"
def int_impl(x):
    return "int impl"
check("register returns the function; NoneType; the registry", [describe.register(bool, int_impl) is int_impl, describe(True), describe(None),
                                                                 Sequence in describe.registry, object in describe.registry,
                                                                 describe.dispatch(bool) is int_impl, describe.registry[bool] is int_impl],
      [True, "int impl", "none", True, True, True, True])
check("register by annotation and by union", [describe(2.5), describe(b"x"), describe(bytearray(b"x")), describe(7)],
      ["float by annotation", "binary", "binary", "integral"])
def unannotated(x):
    return x
bad_fn = raises(lambda: describe.register(unannotated), TypeError)
def not_a_class(x: 5):
    return x
check("register errors", [raises(lambda: describe.register(5), TypeError),
                          bad_fn.startswith("Invalid first argument to `register()`: <function "),
                          bad_fn.endswith(". Use either `@register(some_class)` or plain `@register` on an annotated function."),
                          raises(lambda: describe.register(5, unannotated), TypeError),
                          raises(lambda: describe.register(not_a_class), TypeError)],
      ["Invalid first argument to `register()`: 5. Use either `@register(some_class)` or plain `@register` on an annotated function.",
       True, True, "Invalid first argument to `register()`. 5 is not a class or union type.",
       "Invalid annotation for 'x'. 5 is not a class."])

@singledispatch
def g(arg):
    return "base"
g.register(Sized, lambda x: "sized")
g.register(Container, lambda x: "container")
class LenContains:
    def __len__(self):
        return 0
    def __contains__(self, x):
        return False
class LenOnly:
    def __len__(self):
        return 0
check("ambiguous dispatch between two implicit ABCs", [raises(lambda: g(LenContains()), RuntimeError), g(LenOnly()), g(5)],
      ["Ambiguous dispatch: <class 'collections.abc.Sized'> or <class 'collections.abc.Container'>", "sized", "base"])
class ExplicitBoth(Sized, Container):
    def __len__(self):
        return 0
    def __contains__(self, x):
        return False
check("explicit bases decide", g(ExplicitBoth()), "sized")
g.register(list, lambda x: "list")
check("a concrete type beats the ABCs", [g([1]), g.dispatch(list)([]), raises(lambda: g((1,)), RuntimeError)],
      ["list", "list", "Ambiguous dispatch: <class 'collections.abc.Sized'> or <class 'collections.abc.Container'>"])

@singledispatch
def h(x):
    return "h-object"
@h.register(Iterable)
def _(x):
    return "iterable"
@h.register(Collection)
def _(x):
    return "collection"
@h.register(MutableSequence)
def _(x):
    return "mutable sequence"
check("the most specific ABC wins", [h([1]), h((1,)), h(OnlyIter()), h(AllThree()), h(5), h(gen())],
      ["mutable sequence", "collection", "iterable", "collection", "h-object", "iterable"])

class Shelf:
    @singledispatchmethod
    def put(self, x):
        return "thing"
    @put.register
    def _(self, x: int):
        return "int " + str(x)
    @put.register(Sequence)
    def _(self, x):
        return "sequence of " + str(len(x))
check("singledispatchmethod by annotation and ABC", [Shelf().put(3), Shelf().put([1, 2]), Shelf().put("abc"), Shelf().put(2.5)],
      ["int 3", "sequence of 2", "sequence of 3", "thing"])

# ── the engines: what the modules stand on ───────────────────────────────────
class Dunders:
    def __init__(self):
        self.__marked__ = 1
        self.plain = 2
    def __iter__(self):
        return iter([])
    def __len__(self):
        return 0
    @property
    def prop(self):
        return 1
    @staticmethod
    def stat():
        return 2
    __hash__ = None
dkeys = list(Dunders.__dict__.keys())
check("a class's __dict__ lists its dunders", ["__iter__" in Dunders.__dict__, "__init__" in dkeys, "__hash__" in dkeys,
                                               Dunders.__dict__["__hash__"] is None, "prop" in dkeys, "stat" in dkeys,
                                               [k for k in dkeys if k.startswith("__dec")]],
      [True, True, True, True, True, True, []])
check("an instance's __dict__ too", sorted(Dunders().__dict__.keys()), ["__marked__", "plain"])
class NsMeta(type):
    seen = []
    def __new__(mcls, name, bases, ns):
        NsMeta.seen = [k for k in ns if not k.startswith("__module") and not k.startswith("__qualname")]
        return super().__new__(mcls, name, bases, ns)
class WithNs(metaclass=NsMeta):
    def __len__(self):
        return 4
    @classmethod
    def c(cls):
        return 1
check("the namespace a metaclass gets", [NsMeta.seen, len(WithNs())], [["__len__", "c"], 4])
Made = type("Made", (), {"__len__": lambda self: 3, "z": 4, "__repr__": lambda self: "<made>"})
check("type(name, bases, ns) with dunders", [len(Made()), Made().z, repr(Made())], [3, 4, "<made>"])
class LL(list):
    pass
check("builtin types' __mro__ / __bases__, issubclass of a builtin base",
      [int.__mro__, bool.__mro__, bool.__bases__, list.__bases__, issubclass(LL, list), issubclass(LL, dict), issubclass(ABCMeta, type),
       issubclass(bool, (str, int)), issubclass(int, (str, Hashable))],
      [(int, object), (bool, int, object), (int,), (object,), True, False, True, True, True])
import urllib
from urllib import parse as _parse
check("from a package import a submodule not loaded yet", _parse.quote("a b"), "a%20b")
class CM:
    @classmethod
    def make(cls):
        return "made " + cls.__name__
class CM2(CM):
    @classmethod
    def make(cls):
        return "2+" + super().make()
check("super() in a classmethod", [CM2.make(), CM2().make()], ["2+made CM2", "2+made CM2"])
check("lambda self", [(lambda self: self + 1)(1), (lambda self, k=2: self * k)(5)], [2, 10])
check("builtin types are types", [isinstance(int, type), isinstance(str, type), isinstance(list, type), isinstance(dict, type),
                                  isinstance(bool, type), isinstance(type, type), isinstance(5, type), isinstance("int", type)],
      [True, True, True, True, True, True, False, False])

# ── Nython only ──────────────────────────────────────────────────────────────
if nython:
    class Other(ABC):
        @abstractmethod
        @classmethod
        def cm(cls):
            return 1
        @abstractmethod
        @property
        def p(self):
            return 2
    check("abstractmethod outermost (Python refuses it)", sorted(Other.__abstractmethods__), ["cm", "p"])
    check("the stand-ins for the kinds without a type object",
          [abc._ny_class_of(None).__name__, abc._ny_class_of(len).__name__, abc._ny_class_of(gen).__name__,
           abc._ny_class_of(gen()).__name__, abc._ny_class_of(iter([])).__name__, abc._ny_class_of(5) is int],
          ["NoneType", "builtin_function_or_method", "function", "generator", "iterator", True])
    import io
    buf = io.StringIO()
    Base1._dump_registry(buf)
    dump = buf.getvalue().split("\n")
    check("_dump_registry", [dump[0], dump[1] == "Inv. counter: " + str(abc.get_cache_token()), dump[2], dump[5].startswith("_abc_negative_cache_version: ")],
          ["Class: __main__.Base1", True, "_abc_registry: set()", True])
    import _collections_abc
    check("_collections_abc is collections.abc's classes", [_collections_abc.Mapping is Mapping, _collections_abc.Sequence is Sequence,
                                                           "Mapping" in _collections_abc.__all__],
          [True, True, True])

# A program's own top-level names do not reach the modules it imports (the
# interpreter's modules saw this `list`, round 77). Last: list stays rebound.
list = "shadowed"
dq = collections.deque([1])
dq.extend([2, 3])
check("a program's names do not reach modules", [len(dq), dq.pop(), isinstance(dq, MutableSequence)], [3, 3, True])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT74 PASSED ===")
