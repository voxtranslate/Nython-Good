# vm_audit53.ny - classes and objects, identical on both engines.
#
#   Lexical scoping (a function never sees its caller's locals); class
#   bodies run (class attributes, decorators, @property with a setter,
#   @staticmethod / @classmethod); C3 method resolution over every base;
#   super() walking the MRO with keyword arguments; defaults evaluated once,
#   at definition; the operator protocol (__eq__/__ne__, ordering, __hash__,
#   reflected arithmetic, unary, __bool__/__len__, __contains__, __iter__,
#   __getitem__, __call__, __getattr__, __delitem__, @); introspection
#   (type(x).__name__, x.__class__, f.__name__, issubclass, callable,
#   hasattr/getattr). Every expected value is what python3 gives.
#
#     ./build/nython-cli examples/vm_audit53.ny
#     ./build/nython-cli --vm examples/vm_audit53.ny

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

# ── scoping ─────────────────────────────────────────────────────────────────
def helper():
    i = 99
    return i
def main_scope():
    i = 1
    helper()
    return i
check("a callee's local does not touch the caller's", main_scope(), 1)

def reader():
    try:
        return secret_local
    except NameError:
        return "NameError"
def caller():
    secret_local = "leaked"
    return reader()
check("a callee cannot read the caller's locals", caller(), "NameError")

def counter():
    count = 0
    def inc():
        nonlocal count
        count = count + 1
        return count
    inc()
    inc()
    return count
check("nonlocal writes the enclosing variable", counter(), 2)

def loop_local():
    for q in range(3):
        pass
    return q
q = "module"
check("a loop variable is local", [loop_local(), q], [2, "module"])

def expression_statements(n):
    "a docstring"
    out = []
    for i in range(n):
        "a string statement"
        out.append(i)
    return out
check("expression statements are discarded", expression_statements(4), [0, 1, 2, 3])

# ── class bodies ────────────────────────────────────────────────────────────
class Config:
    base = 10
    derived = base * 2
    names = ["a", "b"]
    def get(self):
        return self.derived
check("class attributes computed in the body", [Config.base, Config.derived, Config().get()], [10, 20, 20])
check("a class attribute list", Config.names, ["a", "b"])

class Temperature:
    def __init__(self, c):
        self._c = c
    @property
    def celsius(self):
        return self._c
    @celsius.setter
    def celsius(self, v):
        self._c = v
    @property
    def fahrenheit(self):
        return self._c * 9 / 5 + 32
    @staticmethod
    def unit():
        return "C"
    @classmethod
    def freezing(cls):
        return cls(0)
t = Temperature(100)
check("property getter", t.celsius, 100)
t.celsius = 25
check("property setter", t.celsius, 25)
check("derived property", t.fahrenheit, 77.0)
check("staticmethod through the class", Temperature.unit(), "C")
check("staticmethod through an instance", t.unit(), "C")
check("classmethod constructs", Temperature.freezing().celsius, 0)
def set_readonly():
    try:
        t.fahrenheit = 1
        return "set"
    except AttributeError:
        return "AttributeError"
check("a read-only property refuses", set_readonly(), "AttributeError")

def deco(tag):
    def wrap(f):
        def inner(*args):
            return tag + str(f(*args))
        return inner
    return wrap
class Decorated:
    @deco("<")
    def value(self):
        return 5
check("a decorated method", Decorated().value(), "<5")

# ── inheritance, MRO, super ─────────────────────────────────────────────────
class Base:
    def __init__(self, name):
        self.name = name
    def who(self):
        return "Base"
class Left(Base):
    def who(self):
        return "Left>" + super().who()
class Right(Base):
    def who(self):
        return "Right>" + super().who()
class Diamond(Left, Right):
    def who(self):
        return "Diamond>" + super().who()
check("C3 through a diamond", Diamond("d").who(), "Diamond>Left>Right>Base")
check("__mro__ names", [c.__name__ for c in Diamond.__mro__][:4], ["Diamond", "Left", "Right", "Base"])
check("inherited constructor", Diamond("x").name, "x")

class Fly:
    def fly(self):
        return "flies"
class Swim:
    def swim(self):
        return "swims"
class Duck(Fly, Swim):
    pass
var dk = Duck()
check("methods of every base", [dk.fly(), dk.swim()], ["flies", "swims"])
check("isinstance with the second base", isinstance(dk, Swim), true)
check("issubclass", [issubclass(Duck, Fly), issubclass(Fly, Duck)], [true, false])

class KwBase:
    def __init__(self, a, b=2):
        self.total = a + b
class KwChild(KwBase):
    def __init__(self, a):
        super().__init__(a, b=10)
check("super().__init__ with a keyword", KwChild(1).total, 11)

class Skip(Base):
    pass
class Deep(Skip):
    def __init__(self):
        super().__init__("deep")
check("super() through a class without __init__", Deep().name, "deep")

# ── defaults ────────────────────────────────────────────────────────────────
n_default = 5
def at_definition(x=n_default):
    return x
n_default = 10
check("defaults are evaluated at definition", at_definition(), 5)
def fresh(item, acc=none):
    if acc == none:
        acc = []
    acc.append(item)
    return acc
check("none default idiom", [fresh(1), fresh(2)], [[1], [2]])
var lam = lambda x, y=2: x * y
check("lambda defaults", [lam(3), lam(3, 4)], [6, 12])
class Defaults:
    def m(self, a=-1, b=[]):
        return [a, b]
check("negative and list method defaults", Defaults().m(), [-1, []])
def spread(a, b=2, c=3):
    return [a, b, c]
check("f(**d)", spread(1, **{"c": 30}), [1, 2, 30])
check("f(*xs, **d)", spread(*[7, 8], **{"c": 9}), [7, 8, 9])
def collect(a, **kw):
    return sorted(kw.keys())
check("named parameters are not in **kw", collect(1, x=2, y=3), ["x", "y"])

# ── the operator protocol ───────────────────────────────────────────────────
class P:
    def __init__(self, x):
        self.x = x
    def __eq__(self, o):
        return isinstance(o, P) and self.x == o.x
    def __lt__(self, o):
        return self.x < o.x
    def __hash__(self):
        return hash(self.x)
    def __repr__(self):
        return "P(" + str(self.x) + ")"
check("__eq__ and derived __ne__", [P(1) == P(1), P(1) != P(1), P(1) != P(2)], [true, false, true])
check("sorted uses __lt__", sorted([P(3), P(1), P(2)]), [P(1), P(2), P(3)])
check("min/max use __lt__", [min([P(3), P(1)]).x, max([P(3), P(1)]).x], [1, 3])
check("> reflects to __lt__", P(5) > P(2), true)
check("set dedupes by __hash__/__eq__", len(set([P(1), P(1), P(2)])), 2)
check("__repr__ inside a list", str([P(1), P(2)]), "[P(1), P(2)]")

class V:
    def __init__(self, v):
        self.v = v
    def __add__(self, o):
        return V(self.v + (o.v if isinstance(o, V) else o))
    def __radd__(self, o):
        return V(o + self.v)
    def __rmul__(self, o):
        return V(o * self.v)
    def __neg__(self):
        return V(-self.v)
    def __invert__(self):
        return V(~self.v)
    def __matmul__(self, o):
        return self.v * o.v
check("__add__", (V(1) + V(2)).v, 3)
check("__radd__", (5 + V(2)).v, 7)
check("sum() of objects", sum([V(1), V(2), V(3)]).v, 6)
check("__rmul__", (3 * V(2)).v, 6)
check("unary dunders", [(-V(4)).v, (~V(0)).v], [-4, -1])
check("@", V(3) @ V(4), 12)

class Box:
    def __init__(self, items):
        self.items = items
    def __len__(self):
        return len(self.items)
    def __contains__(self, x):
        return x in self.items
    def __getitem__(self, i):
        return self.items[i]
    def __delitem__(self, i):
        del self.items[i]
    def __iter__(self):
        return iter(self.items)
b = Box([1, 2, 3])
check("__len__ and truthiness", [len(b), bool(b), bool(Box([]))], [3, true, false])
check("__contains__", [2 in b, 9 in b, 9 not in b], [true, false, true])
check("__getitem__", b[1], 2)
del b[0]
check("__delitem__", b.items, [2, 3])
check("for over __iter__", [x * 10 for x in b], [20, 30])

class Seq:
    def __getitem__(self, i):
        if i >= 3:
            raise IndexError(i)
        return i * i
check("iteration over a __getitem__ sequence", list(Seq()), [0, 1, 4])

class Flag:
    def __init__(self, on):
        self.on = on
    def __bool__(self):
        return self.on
check("__bool__", ["yes" if Flag(true) else "no", "yes" if Flag(false) else "no"], ["yes", "no"])

class Dyn:
    def __getattr__(self, name):
        return "dyn:" + name
check("__getattr__ supplies missing attributes", Dyn().anything, "dyn:anything")

class Adder:
    def __call__(self, x, k=1):
        return x + 100 * k
class Holder:
    def __init__(self):
        self.fn = Adder()
check("an object with __call__", Adder()(1), 101)
check("a callable object in an attribute, with a keyword", Holder().fn(1, k=2), 201)

# ── introspection ───────────────────────────────────────────────────────────
def named():
    return 1
check("type(x).__name__", [type(P(1)).__name__, type(3).__name__], ["P", "int"])
check("x.__class__ is the class", P(1).__class__ == P, true)
check("f.__name__", named.__name__, "named")
check("callable", [callable(named), callable(P), callable(Adder()), callable(3)], [true, true, true, false])
check("hasattr sees methods and class attributes", [hasattr(P(1), "x"), hasattr(P(1), "__repr__"), hasattr(Config, "base"), hasattr(P(1), "nope")], [true, true, true, false])
check("getattr with a default", [getattr(P(4), "x"), getattr(P(4), "nope", "d")], [4, "d"])
var L1 = [1]
var L2 = [1]
check("is: identity, not equality", [L1 is L1, L1 is L2, L1 == L2], [true, false, true])

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT53 PASSED ===")
