# vm_audit80.ny - type() gives type objects, both engines (round 77).
#
# type(5) is int, type(obj) is its class, type(C) is type (or C's
# metaclass), x.__class__ for every value, `int is int` / `C is C` are
# identity - and, Nython only, a type object still equals the name type()
# used to return (type(x) == "list", "string", "map", "class"), so code
# written against the old strings keeps working; typeof(x) is that name as
# a string.
#
# The shared part runs under python3 too (`python3 examples/vm_audit80.ny`);
# every expected value there is CPython's.
#
#     ./build/nython-cli examples/vm_audit80.ny
#     ./build/nython-cli --vm examples/vm_audit80.ny
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

class P:
    def __init__(self, v=0):
        self.v = v
class Q(P):
    pass
class Meta(type):
    pass
class WithMeta(metaclass=Meta):
    pass

# ── type() of every kind of value ────────────────────────────────────────────
check("type() of builtin values",
      [type(5) is int, type("s") is str, type([]) is list, type(()) is tuple, type({}) is dict,
       type({1}) is set, type(frozenset()) is frozenset, type(1.5) is float, type(True) is bool,
       type(b"") is bytes, type(bytearray()) is bytearray],
      [True, True, True, True, True, True, True, True, True, True, True])
check("type() compared with ==, in, !=",
      [type(5) == int, type(5) != str, type(5) in (int, float), type("s") in [int, float], type(1.5) == float],
      [True, True, True, False, True])
check("the type of an instance is its class",
      [type(P()) is P, type(Q()) is Q, type(Q()) is P, type(P()) == P, type(Q()).__name__],
      [True, True, False, True, "Q"])
check("the type of a class", [type(P) is type, type(int) is type, type(type) is type, type(WithMeta) is Meta],
      [True, True, True, True])
check("calling type(x) makes another",
      [type(5)("7"), type("a")(12), type([1])((1, 2)), type(P(3))(4).v, type(())([3])],
      [7, "12", [1, 2], 4, (3,)])
check("__class__ of every value",
      [(5).__class__ is int, "s".__class__ is str, [].__class__ is list, {}.__class__ is dict,
       P().__class__ is P, P.__class__ is type, (1.5).__class__ is float, WithMeta.__class__ is Meta],
      [True, True, True, True, True, True, True, True])
check("is between types is identity",
      [int is int, P is P, Q is P, P is Q, list is list, type is type, int is float],
      [True, True, False, False, True, True, False])
check("repr of a type", [repr(type(5)), str(type("s")), repr(type(P())), repr(type({}))],
      ["<class 'int'>", "<class 'str'>", "<class '__main__.P'>", "<class 'dict'>"])
check("type objects as dict keys", [{int: "i", str: "s"}[type(3)], {P: 1}[type(P())]], ["i", 1])
check("isinstance with type(x)", [isinstance(5, type(7)), isinstance("s", type(5)), isinstance(Q(), type(P()))],
      [True, False, True])

def kind(x):
    t = type(x)
    if t is int or t is float:
        return "number"
    if t is str:
        return "text"
    if t in (list, tuple):
        return "sequence"
    return t.__name__
check("dispatch on type(x)", [kind(1), kind(2.5), kind("a"), kind([1]), kind((1,)), kind(P())],
      ["number", "number", "text", "sequence", "sequence", "P"])

# ── properties expose fget / fset / __isabstractmethod__ ─────────────────────
def abstract(f):
    f.__isabstractmethod__ = True
    return f
class Props:
    @property
    def x(self):
        return 1
    @x.setter
    def x(self, v):
        pass
    @property
    @abstract
    def y(self):
        return 2
check("property attributes",
      [Props.__dict__["x"].fget(None), Props.__dict__["x"].fset is not None,
       getattr(Props.__dict__["x"], "__isabstractmethod__", False), getattr(Props.__dict__["y"], "__isabstractmethod__", False)],
      [1, True, False, True])

# ── Nython only: the legacy names still compare equal ────────────────────────
if nython:
    check("legacy names", [type(5) == "int", type("s") == "string", type("s") == "str", type({}) == "map",
                           type({}) == "dict", type([]) == "list", type(P()) == "P", type(P) == "class",
                           type(5) != "float", type([]) in ["list", "tuple"]],
          [True, True, True, True, True, True, True, True, True, True])
    check("legacy names stay for the rest", [type(none), type(len), type(kind)], ["none", "builtin", "function"])
    check("typeof(x) is the Nython name, a string",
          [typeof(5), typeof("s"), typeof({}), typeof([]), typeof(P()), typeof(P), typeof(none), isinstance(typeof(5), "str")],
          ["int", "string", "map", "list", "P", "class", "none", True])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT80 PASSED ===")
