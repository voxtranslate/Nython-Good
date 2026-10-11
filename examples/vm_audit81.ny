# vm_audit81.ny - Python's enum and dataclasses modules, both engines (round 77).
#
#   enum         Enum/IntEnum/StrEnum/Flag/IntFlag, EnumType as the metaclass:
#                members from the class body, lookup by value / name, aliases,
#                iteration, __members__, reprs, immutability, auto() and
#                _generate_next_value_, _missing_, _ignore_, member/nonmember,
#                the functional API, @unique, verify, Flag boundaries, members
#                as dict keys, in sets and in match statements; IntEnum as an
#                int (arithmetic, comparisons, indexing, %d, range)
#   dataclasses  @dataclass with and without arguments, field(), the generated
#                __init__ (CPython's messages), __repr__, __eq__, ordering,
#                frozen, the hash table, KW_ONLY/kw_only, InitVar and
#                __post_init__, ClassVar, inheritance, fields/asdict/astuple/
#                replace/is_dataclass/make_dataclass, __match_args__
#
# Written in the subset Nython and Python share, so the same file runs under
# python3 (`python3 examples/vm_audit81.ny` must also pass) - every expected
# value below is what CPython 3.11 computes.
#
#     ./build/nython-cli examples/vm_audit81.ny
#     ./build/nython-cli --vm examples/vm_audit81.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import copy
import enum
from enum import Enum, IntEnum, StrEnum, Flag, IntFlag, EnumMeta, EnumType, auto, unique, verify
from enum import member, nonmember, UNIQUE, CONTINUOUS, NAMED_FLAGS, STRICT, CONFORM, EJECT, KEEP
import dataclasses
from dataclasses import dataclass, field, fields, asdict, astuple, replace, is_dataclass
from dataclasses import make_dataclass, FrozenInstanceError, InitVar, KW_ONLY, MISSING

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def raises(f):
    # "TypeName: message" of what f() raises, or "no error"
    try:
        f()
        return "no error"
    except Exception as e:
        return type(e).__name__ + ": " + str(e)

# ═════════════════════════════════════════════════════════════════════════════
# enum
# ═════════════════════════════════════════════════════════════════════════════
class Color(Enum):
    RED = 1
    GREEN = 2
    BLUE = 3
    CRIMSON = 1
    def describe(self):
        return self.name.lower() + "=" + str(self.value)
    @classmethod
    def favourite(cls):
        return cls.GREEN
    @property
    def warm(self):
        return self is Color.RED

check("reprs and strs", [repr(Color.RED), str(Color.GREEN), repr(Color), str(Color), format(Color.BLUE), f"{Color.BLUE}"],
      ["<Color.RED: 1>", "Color.GREEN", "<enum 'Color'>", "<enum 'Color'>", "Color.BLUE", "Color.BLUE"])
check("name, value, _name_, _value_", [Color.RED.name, Color.RED.value, Color.GREEN._name_, Color.GREEN._value_],
      ["RED", 1, "GREEN", 2])
check("lookups", [Color(2) is Color.GREEN, Color["BLUE"] is Color.BLUE, getattr(Color, "RED") is Color.RED, Color(Color.RED) is Color.RED],
      [True, True, True, True])
check("an alias is the same member", [Color.CRIMSON is Color.RED, Color(1).name, Color["CRIMSON"].name, Color.CRIMSON.name],
      [True, "RED", "RED", "RED"])
check("iteration, len, reversed", [list(Color), len(Color), list(reversed(Color)), [c.name for c in Color]],
      [[Color.RED, Color.GREEN, Color.BLUE], 3, [Color.BLUE, Color.GREEN, Color.RED], ["RED", "GREEN", "BLUE"]])
check("__members__ (aliases too)", [list(Color.__members__), len(Color.__members__), Color.__members__["CRIMSON"] is Color.RED,
                                    [k for k, v in Color.__members__.items() if v.name != k]],
      [["RED", "GREEN", "BLUE", "CRIMSON"], 4, True, ["CRIMSON"]])
def set_members():
    Color.__members__["X"] = 1
check("__members__ is read-only", raises(set_members),
      "TypeError: 'mappingproxy' object does not support item assignment")
check("membership", [Color.RED in Color, Color.CRIMSON in Color], [True, True])
check("types", [type(Color.RED) is Color, isinstance(Color.RED, Color), isinstance(Color.RED, Enum), isinstance(Color, EnumMeta),
                type(Color) is EnumType, EnumMeta is EnumType, issubclass(Color, Enum), Color.RED.__class__ is Color],
      [True, True, True, True, True, True, True, True])
check("methods, classmethods, properties", [Color.RED.describe(), Color.favourite(), Color.RED.warm, Color.BLUE.warm],
      ["red=1", Color.GREEN, True, False])
check("missing values and names", [raises(lambda: Color(7)), raises(lambda: Color["PINK"]), raises(lambda: Color("x"))],
      ["ValueError: 7 is not a valid Color", "KeyError: 'PINK'", "ValueError: 'x' is not a valid Color"])
check("no member by attribute", [hasattr(Color, "PINK"), hasattr(Color, "RED")], [False, True])
check("members cannot be reassigned or deleted", [raises(lambda: setattr(Color, "RED", 5)), raises(lambda: delattr(Color, "RED"))],
      ["AttributeError: cannot reassign member 'RED'", "AttributeError: 'Color' cannot delete member 'RED'."])
check("name and value are read-only", [raises(lambda: setattr(Color.RED, "name", "x")), raises(lambda: setattr(Color.RED, "value", 9)),
                                       Color.RED.name, Color.RED.value],
      ["AttributeError: <enum 'Enum'> cannot set attribute 'name'", "AttributeError: <enum 'Enum'> cannot set attribute 'value'", "RED", 1])
Color.note = "a class attribute"
check("other class attributes can be set", [Color.note, "note" in Color.__members__], ["a class attribute", False])
def extend_color():
    class MoreColor(Color):
        PINK = 4
check("an enum with members cannot be subclassed", raises(extend_color), "TypeError: <enum 'MoreColor'> cannot extend <enum 'Color'>")
check("members are singletons", [copy.copy(Color.RED) is Color.RED, copy.deepcopy(Color.BLUE) is Color.BLUE, Color.RED == Color.RED,
                                 Color.RED != Color.GREEN, Color.RED == 1, Color.RED != 1],
      [True, True, True, True, False, True])
d = {Color.RED: "r", Color.GREEN: "g"}
check("members as dict keys and in sets", [d[Color.RED], d[Color.CRIMSON], Color.BLUE in d, len({Color.RED, Color.CRIMSON, Color.GREEN}),
                                           hash(Color.RED) == hash("RED"), sorted(Color, key=lambda c: -c.value)[0]],
      ["r", "r", False, 2, True, Color.BLUE])
check("bool of members and classes", [bool(Color.RED), bool(Color)], [True, True])

def what(c):
    match c:
        case Color.RED:
            return "red"
        case Color.GREEN | Color.BLUE:
            return "cool"
        case _:
            return "other"
check("members in match statements", [what(Color.RED), what(Color.CRIMSON), what(Color.BLUE), what(3)], ["red", "red", "cool", "other"])

class Planet(Enum):
    MERCURY = (3.303e+23, 2.4397e6)
    EARTH = (5.976e+24, 6.37814e6)
    def __init__(self, mass, radius):
        self.mass = mass
        self.radius = radius
    @property
    def surface_gravity(self):
        return 6.673e-11 * self.mass / (self.radius * self.radius)
check("__init__ receives a tuple value's items", [Planet.EARTH.value, Planet.EARTH.mass, round(Planet.EARTH.surface_gravity, 2), Planet((3.303e+23, 2.4397e6))],
      [(5.976e+24, 6.37814e6), 5.976e+24, 9.8, Planet.MERCURY])

class Coord(Enum):
    def __new__(cls, value, label):
        obj = object.__new__(cls)
        obj._value_ = value
        obj.label = label
        return obj
    X = (1, "ex")
    Y = (2, "why")
check("__new__ setting _value_", [Coord.X.value, Coord.Y.label, Coord(2), repr(Coord.X)], [1, "why", Coord.Y, "<Coord.X: 1>"])

class Shape(Enum):
    SQUARE = auto()
    CIRCLE = auto()
    TRIANGLE = 10
    LINE = auto()
check("auto()", [[s.value for s in Shape], repr(auto())], [[1, 2, 10, 11], "auto(_auto_null)"])

class Named(Enum):
    def _generate_next_value_(name, start, count, last_values):
        return name.lower() + str(count)
    ALPHA = auto()
    BETA = auto()
check("_generate_next_value_", [Named.ALPHA.value, Named.BETA.value], ["alpha0", "beta1"])

class Pair(Enum):
    A = (auto(), "a")
    B = (auto(), "b")
check("auto() in a tuple", [Pair.A.value, Pair.B.value], [(1, "a"), (2, "b")])

class Lenient(Enum):
    ONE = "one"
    TWO = "two"
    @classmethod
    def _missing_(cls, value):
        if isinstance(value, str):
            for m in cls:
                if m.value == value.lower():
                    return m
        return None
check("_missing_", [Lenient("ONE"), Lenient("Two"), raises(lambda: Lenient("three"))],
      [Lenient.ONE, Lenient.TWO, "ValueError: 'three' is not a valid Lenient"])

class BadMissing(Enum):
    A = 1
    @classmethod
    def _missing_(cls, value):
        return 5
check("_missing_ returning a non-member", raises(lambda: BadMissing(2)),
      "TypeError: error in BadMissing._missing_: returned 5 instead of None or a valid member")

class WithIgnore(Enum):
    _ignore_ = ["helper"]
    helper = 99
    A = 1
    B = 2
check("_ignore_", [list(WithIgnore.__members__), hasattr(WithIgnore, "helper"), hasattr(WithIgnore, "_ignore_")], [["A", "B"], False, False])

class WithMembers(Enum):
    A = 1
    B = nonmember(2)
    @member
    def C():
        return 3
    D = 4
check("member / nonmember", [list(WithMembers.__members__), WithMembers.B, WithMembers.C.value(), WithMembers.D.value],
      [["A", "C", "D"], 2, 3, 4])

class NotMembers(Enum):
    A = 1
    _private = 2
    __dunder__ = 3
    fn = lambda self: 4
    def meth(self):
        return 5
check("descriptors and dunders are not members", [list(NotMembers.__members__), NotMembers.A.meth(), NotMembers.A.fn()], [["A", "_private"], 5, 4])

def bad_sunder():
    class BadSunder(Enum):
        _bad_ = 1
check("reserved _sunder_ names", raises(bad_sunder), "ValueError: _sunder_ names, such as '_bad_', are reserved for future Enum use")

def bad_order():
    class Ordered(Enum):
        _order_ = "B A"
        A = 1
        B = 2
check("_order_", raises(bad_order), "TypeError: member order does not match _order_:\n  ['A', 'B']\n  ['B', 'A']")

class Ordered2(Enum):
    _order_ = "A B"
    A = 1
    B = 2
check("_order_ that matches", [m.name for m in Ordered2], ["A", "B"])

check("@unique", raises(lambda: unique(Color)), "ValueError: duplicate values found in <enum 'Color'>: CRIMSON -> RED")
check("@unique passes", unique(Shape) is Shape, True)
check("verify(UNIQUE)", raises(lambda: verify(UNIQUE)(Color)), "ValueError: aliases found in <enum 'Color'>: CRIMSON -> RED")
class Gappy(Enum):
    A = 1
    B = 2
    D = 4
check("verify(CONTINUOUS)", raises(lambda: verify(CONTINUOUS)(Gappy)), "ValueError: invalid enum 'Gappy': missing values 3")

Animal = Enum("Animal", "ANT BEE CAT")
check("functional API: a string", [list(Animal), Animal.BEE.value, repr(Animal), Animal(3)],
      [[Animal.ANT, Animal.BEE, Animal.CAT], 2, "<enum 'Animal'>", Animal.CAT])
check("functional API: commas, list, pairs, dict, start",
      [[m.value for m in Enum("A1", "X, Y, Z")], [m.name for m in Enum("A2", ["P", "Q"])],
       [m.value for m in Enum("A3", [("P", 5), ("Q", 7)])], [m.value for m in Enum("A4", {"P": "p", "Q": "q"})],
       [m.value for m in Enum("A5", "P Q", start=10)]],
      [[1, 2, 3], ["P", "Q"], [5, 7], ["p", "q"], [10, 11]])
Level = IntEnum("Level", "LOW HIGH")
check("functional API: IntEnum", [Level.HIGH + 0, Level.LOW < Level.HIGH, isinstance(Level.LOW, int)], [2, True, True])

# ── IntEnum: an int ──────────────────────────────────────────────────────────
class Num(IntEnum):
    ONE = 1
    TWO = 2
    THREE = 3
check("IntEnum arithmetic", [Num.ONE + 1, Num.TWO * 3, 10 - Num.THREE, Num.TWO ** 3, Num.THREE // 2, Num.THREE % 2, -Num.ONE, Num.ONE + Num.TWO, 7 / Num.TWO],
      [2, 6, 7, 8, 1, 1, -1, 3, 3.5])
check("IntEnum compares as an int", [Num.ONE == 1, 1 == Num.ONE, Num.TWO > 1, Num.ONE < Num.TWO, Num.TWO <= 2, Num.THREE != 3, sorted([Num.THREE, Num.ONE, Num.TWO])],
      [True, True, True, True, True, False, [Num.ONE, Num.TWO, Num.THREE]])
check("IntEnum str/format/repr", [str(Num.TWO), format(Num.TWO, "03d"), f"{Num.THREE}", repr(Num.ONE), "%d items" % Num.THREE, "%s" % Num.TWO],
      ["2", "002", "3", "<Num.ONE: 1>", "3 items", "2"])
check("IntEnum is an int", [isinstance(Num.ONE, int), int(Num.TWO), float(Num.TWO), hash(Num.TWO) == hash(2), Num.THREE.bit_length(), issubclass(Num, int)],
      [True, 2, 2.0, True, 2, True])
check("IntEnum as an index", [["a", "b", "c", "d"][Num.TWO], list(range(Num.THREE)), hex(Num.THREE), "abcd"[Num.ONE], [1, 2, 3, 4][Num.ONE:Num.THREE]],
      ["c", [0, 1, 2], "0x3", "b", [2, 3]])
check("IntEnum bit operations", [Num.ONE | Num.TWO, Num.THREE & 1, Num.ONE << 2, ~Num.ONE], [3, 1, 4, -2])
check("IntEnum lookups", [Num(2) is Num.TWO, Num["THREE"].value, list(Num), max(Num)], [True, 3, [Num.ONE, Num.TWO, Num.THREE], Num.THREE])
class FromStr(IntEnum):
    A = "5"
check("IntEnum converts its values", [FromStr.A.value, FromStr.A + 1], [5, 6])

# ── StrEnum ──────────────────────────────────────────────────────────────────
class Method(StrEnum):
    GET = auto()
    POST = auto()
    CUSTOM = "Custom"
check("StrEnum values and strs", [Method.GET.value, str(Method.POST), repr(Method.CUSTOM), format(Method.GET), f"{Method.GET}!", "%s" % Method.POST],
      ["get", "post", "<Method.CUSTOM: 'Custom'>", "get", "get!", "post"])
check("StrEnum is a str", [Method.GET == "get", "x" + Method.GET, Method.POST + "/", Method.CUSTOM.upper(), len(Method.POST), "os" in Method.POST,
                           isinstance(Method.GET, str), Method("post") is Method.POST, Method.GET < Method.POST, Method.CUSTOM[0]],
      [True, "xget", "post/", "CUSTOM", 4, True, True, True, True, "C"])
def bad_strenum():
    class BadStr(StrEnum):
        X = 1
check("StrEnum refuses a non-str", raises(bad_strenum), "TypeError: 1 is not a string")

# ── a data type mixed in without ReprEnum, members called name / value ───────
class Mixed(str, Enum):
    A = "a"
    B = "b"
check("str mixed into Enum", [repr(Mixed.A), str(Mixed.A), format(Mixed.A), f"{Mixed.A}", Mixed.A == "a", Mixed.A + "!", Mixed.A.upper(),
                             isinstance(Mixed.A, str), repr(Mixed.__members__)],
      ["<Mixed.A: 'a'>", "Mixed.A", "Mixed.A", "Mixed.A", True, "a!", "A", True, "mappingproxy({'A': <Mixed.A: 'a'>, 'B': <Mixed.B: 'b'>})"])
class Odd(Enum):
    name = 1
    value = 2
check("members called name and value", [str(Odd.name), Odd.name.name, Odd.value.value, Odd.name.value, list(Odd)],
      ["Odd.name", "name", 2, 1, [Odd.name, Odd.value]])

# ── Flag ─────────────────────────────────────────────────────────────────────
class Perm(Flag):
    R = 4
    W = 2
    X = 1
    RWX = 7
check("Flag |, &, ^, ~", [repr(Perm.R | Perm.W), repr((Perm.R | Perm.W) & Perm.W), repr(Perm.R ^ Perm.R), repr(~Perm.R), repr(~Perm.RWX)],
      ["<Perm.R|W: 6>", "<Perm.W: 2>", "<Perm: 0>", "<Perm.W|X: 3>", "<Perm: 0>"])
check("Flag strs", [str(Perm.R | Perm.W), str(Perm(0)), str(Perm.RWX), str(Perm.R)], ["Perm.R|W", "Perm(0)", "Perm.RWX", "Perm.R"])
check("Flag membership, iteration, len, bool", [Perm.R in (Perm.R | Perm.W), Perm.X in (Perm.R | Perm.W), list(Perm.R | Perm.X), len(Perm.R | Perm.W),
                                                bool(Perm(0)), bool(Perm.R), list(Perm(0))],
      [True, False, [Perm.R, Perm.X], 2, False, True, []])
check("Flag aliases are not iterated", [list(Perm), len(Perm), list(Perm.__members__), Perm(7) is Perm.RWX, list(Perm.RWX)],
      [[Perm.R, Perm.W, Perm.X], 3, ["R", "W", "X", "RWX"], True, [Perm.R, Perm.W, Perm.X]])
check("Flag pseudo-members are cached", [(Perm.R | Perm.W) is (Perm.W | Perm.R), Perm(6) is (Perm.R | Perm.W)], [True, True])
check("Flag STRICT boundary", raises(lambda: Perm(8)), "ValueError: <flag 'Perm'> invalid value 8\n    given 0b0 1000\n  allowed 0b0 0111")
check("Flag combined with other types", [raises(lambda: Perm.R | 1), raises(lambda: 1 in Perm.R)],
      ["TypeError: unsupported operand type(s) for |: 'Perm' and 'int'", "TypeError: unsupported operand type(s) for 'in': 'int' and 'Perm'"])
class P2(Flag):
    R = auto()
    W = auto()
    RW = R | W
check("a multi-bit alias made in the body", [list(P2), repr(P2.RW), P2(3) is P2.RW, list(P2.__members__)],
      [[P2.R, P2.W], "<P2.RW: 3>", True, ["R", "W", "RW"]])
class Auto2(Flag):
    A = auto()
    B = auto()
    C = auto()
check("Flag auto() gives powers of two", [m.value for m in Auto2], [1, 2, 4])
class Conform(Flag, boundary=CONFORM):
    A = 1
    B = 2
class Eject(Flag, boundary=EJECT):
    A = 1
    B = 2
class Keep(Flag, boundary=KEEP):
    A = 1
    B = 2
check("Flag boundaries CONFORM, EJECT, KEEP", [repr(Conform(7)), Eject(7), repr(Keep(7)), Perm._boundary_ is STRICT, Keep._boundary_ is KEEP],
      ["<Conform.A|B: 3>", 7, "<Keep.A|B|4: 7>", True, True])
check("FlagBoundary", [str(STRICT), repr(KEEP), [b.value for b in enum.FlagBoundary]],
      ["strict", "<FlagBoundary.KEEP: 'keep'>", ["strict", "conform", "eject", "keep"]])
class Sparse(Flag):
    A = 1
    C = 4
    AC = 5
    BAD = 3
check("verify(NAMED_FLAGS)", raises(lambda: verify(NAMED_FLAGS)(Sparse)),
      "ValueError: invalid Flag 'Sparse': alias BAD is missing value 0x2 [use enum.show_flag_values(value) for details]")
check("show_flag_values, enum.bin", [enum.show_flag_values(13), enum.bin(10), enum.bin(~10), enum.bin(5, 8)],
      [[1, 4, 8], "0b0 1010", "0b1 0101", "0b0 00000101"])

class IP(IntFlag):
    R = 4
    W = 2
    X = 1
check("IntFlag", [repr(IP.R | IP.W), repr(IP(9)), str(IP(9)), repr(IP.R | 8), repr(~IP.R), format(IP.R), IP.R + 1, IP.R == 4, isinstance(IP.W, int),
                  repr(IP(0)), list(IP.R | IP.X), IP.W in (IP.R | IP.W), 4 | IP.X],
      ["<IP.R|W: 6>", "<IP.X|8: 9>", "9", "<IP.R|8: 12>", "<IP.W|X: 3>", "4", 5, True, True, "<IP: 0>", [IP.R, IP.X], True, IP.R | IP.X])

check("global_enum_repr / global_str", [enum.global_enum_repr(Color.RED), enum.global_str(Color.RED), enum.global_str(Perm(0))],
      ["__main__.RED", "RED", "Perm(0)"])

# ═════════════════════════════════════════════════════════════════════════════
# dataclasses
# ═════════════════════════════════════════════════════════════════════════════
@dataclass
class Point:
    x: int
    y: int = 0

check("generated __init__/__repr__/__eq__", [repr(Point(1, 2)), repr(Point(3)), Point(1, 2) == Point(1, 2), Point(1, 2) != Point(2, 1),
                                            Point(1) == (1, 0), Point(x=5, y=6).y],
      ["Point(x=1, y=2)", "Point(x=3, y=0)", True, True, False, 6])
check("__init__ errors are CPython's", [raises(lambda: Point()), raises(lambda: Point(1, 2, 3)), raises(lambda: Point(1, z=2)),
                                       raises(lambda: Point(1, x=2))],
      ["TypeError: Point.__init__() missing 1 required positional argument: 'x'",
       "TypeError: Point.__init__() takes from 2 to 3 positional arguments but 4 were given",
       "TypeError: Point.__init__() got an unexpected keyword argument 'z'",
       "TypeError: Point.__init__() got multiple values for argument 'x'"])
check("introspection", [Point.__init__.__qualname__, Point.__repr__.__qualname__, list(Point.__dataclass_fields__), Point.__match_args__,
                        repr(Point.__dataclass_params__), Point.__doc__, Point.y],
      ["Point.__init__", "Point.__repr__", ["x", "y"], ("x", "y"),
       "_DataclassParams(init=" + repr(True) + ",repr=" + repr(True) + ",eq=" + repr(True) + ",order=" + repr(False) +
       ",unsafe_hash=" + repr(False) + ",frozen=" + repr(False) + ")", "Point(x: int, y: int = 0)", 0])
check("eq without frozen is unhashable", raises(lambda: hash(Point(1, 2))), "TypeError: unhashable type: 'Point'")
check("unhashable in sets and as keys", [raises(lambda: {Point(1, 2)}), raises(lambda: {Point(1, 2): 1})],
      ["TypeError: unhashable type: 'Point'", "TypeError: unhashable type: 'Point'"])

@dataclass
class Bag:
    items: list = field(default_factory=list)
    count: int = field(default=0, repr=False)
    tag: str = field(default="t", compare=False)
b1 = Bag()
b2 = Bag()
b1.items.append(1)
check("field(): default_factory, repr=False, compare=False", [b1.items, b2.items, repr(b1), Bag([], 0, "a") == Bag([], 0, "b"), Bag([1]) == Bag([2])],
      [[1], [], "Bag(items=[1], tag='t')", True, False])
check("field() errors", [raises(lambda: field(default=1, default_factory=list))], ["ValueError: cannot specify both default and default_factory"])
def mutable_default():
    @dataclass
    class BadMutable:
        items: list = []
check("the mutable-default ValueError", raises(mutable_default),
      "ValueError: mutable default <class 'list'> for field items is not allowed: use default_factory")
def no_annotation():
    @dataclass
    class BadNoAnn:
        x: int
        y = field(default=1)
check("a field without an annotation", raises(no_annotation), "TypeError: 'y' is a field but has no type annotation")
def default_order():
    @dataclass
    class BadOrder:
        x: int = 1
        y: int
check("non-default after default", raises(default_order), "TypeError: non-default argument 'y' follows default argument")

@dataclass(order=True)
class Version:
    major: int
    minor: int = 0
check("order=True", [Version(1, 2) < Version(1, 3), Version(2) > Version(1, 9), Version(1, 1) <= Version(1, 1), sorted([Version(2), Version(1, 5), Version(1)]),
                     raises(lambda: Version(1) < Point(1))],
      [True, True, True, [Version(1, 0), Version(1, 5), Version(2, 0)], "TypeError: '<' not supported between instances of 'Version' and 'Point'"])
def order_without_eq():
    @dataclass(order=True, eq=False)
    class BadOrderEq:
        x: int
check("order needs eq", raises(order_without_eq), "ValueError: eq must be true if order is true")

@dataclass(frozen=True)
class Frozen:
    x: int
    y: int = 2
fz = Frozen(1)
def set_frozen():
    fz.x = 5
def del_frozen():
    del fz.y
def new_attr():
    fz.z = 1
check("frozen", [raises(set_frozen), raises(del_frozen), raises(new_attr), fz.x, isinstance(FrozenInstanceError(), AttributeError)],
      ["FrozenInstanceError: cannot assign to field 'x'", "FrozenInstanceError: cannot delete field 'y'", "FrozenInstanceError: cannot assign to field 'z'", 1, True])
check("frozen + eq is hashable", [hash(Frozen(1, 2)) == hash(Frozen(1, 2)), len({Frozen(1), Frozen(1), Frozen(2)}), {Frozen(3): "v"}[Frozen(3)]],
      [True, 2, "v"])
def thaw():
    @dataclass
    class Thawed(Frozen):
        z: int = 0
check("frozen inheritance", raises(thaw), "TypeError: cannot inherit non-frozen dataclass from a frozen one")

@dataclass(unsafe_hash=True)
class Hashed:
    a: int
    b: str = field(default="", hash=False)
check("unsafe_hash", [hash(Hashed(1, "x")) == hash(Hashed(1, "y")), len({Hashed(1), Hashed(1)})], [True, 1])

@dataclass(eq=False)
class Plain:
    v: int
p1 = Plain(1)
check("eq=False keeps identity", [Plain(1) == Plain(1), p1 == p1, hash(p1) == hash(p1)], [False, True, True])

@dataclass
class Shown:
    a: int
    def __repr__(self):
        return "custom"
    def __eq__(self, other):
        return "own eq"
check("the class's own methods are kept", [repr(Shown(1)), Shown(1) == Shown(2)], ["custom", "own eq"])

@dataclass(kw_only=True)
class Options:
    verbose: bool = False
    level: int = 1
check("kw_only=True", [repr(Options(level=3)), raises(lambda: Options(True))],
      ["Options(verbose=" + repr(False) + ", level=3)", "TypeError: Options.__init__() takes 1 positional argument but 2 were given"])

@dataclass
class MixedKw:
    a: int
    _: KW_ONLY
    b: int = 2
    c: int = field(default=3, kw_only=False)
check("KW_ONLY and field(kw_only=)", [repr(MixedKw(1, 4, b=5)), MixedKw.__match_args__, raises(lambda: MixedKw(1, 2, 3))],
      ["MixedKw(a=1, b=5, c=4)", ("a", "c"), "TypeError: MixedKw.__init__() takes from 2 to 3 positional arguments but 4 were given"])

@dataclass
class WithPost:
    a: int
    scale: InitVar[int] = 1
    total: int = field(init=False)
    def __post_init__(self, scale):
        self.total = self.a * scale
wp = WithPost(3, 4)
check("InitVar and __post_init__", [wp.total, repr(wp), [f.name for f in fields(wp)], "scale" in WithPost.__dataclass_fields__, repr(InitVar[int]), WithPost(2).total],
      [12, "WithPost(a=3, total=12)", ["a", "total"], True, "dataclasses.InitVar[int]", 2])

# CPython recognises a string annotation as ClassVar when the module binds
# the name to typing.ClassVar; Nython goes by the text (lib/typing.ny may not
# be there)
try:
    from typing import ClassVar
    have_typing = True
except ImportError:
    have_typing = False
@dataclass
class WithClassVar:
    x: int
    count: "ClassVar[int]" = 0
check("ClassVar (a string annotation) is not a field", [[f.name for f in fields(WithClassVar)], WithClassVar.count, repr(WithClassVar(1))],
      [["x"], 0, "WithClassVar(x=1)"])
if have_typing:
    @dataclass
    class TypedCV:
        x: int
        limit: ClassVar[int] = 10
    check("typing.ClassVar is not a field", [[f.name for f in fields(TypedCV)], TypedCV.limit, TypedCV(2).limit], [["x"], 10, 10])

@dataclass
class Base:
    x: int = 0
    y: int = 1
@dataclass
class Derived(Base):
    z: int = 2
    x: int = 5
check("inheritance: base fields first, an override keeps its place", [repr(Derived()), [f.name for f in fields(Derived)], repr(Derived(1, 2, 3)), Derived.__match_args__],
      ["Derived(x=5, y=1, z=2)", ["x", "y", "z"], "Derived(x=1, y=2, z=3)", ("x", "y", "z")])
class NotADataclass(Base):
    w: int = 9
check("a plain subclass keeps the generated methods", [repr(NotADataclass(3)), is_dataclass(NotADataclass)], ["NotADataclass(x=3, y=1)", True])

@dataclass
class Inner:
    v: int
    tags: list = field(default_factory=list)
@dataclass
class Outer:
    name: str
    inner: Inner
    many: list
    by_key: dict
o = Outer("o", Inner(1, ["a"]), [Inner(2), 3], {"k": Inner(4)})
ad = asdict(o)
ad["inner"]["tags"].append("b")
check("asdict: recursive and copying", [ad, o.inner.tags], [{"name": "o", "inner": {"v": 1, "tags": ["a", "b"]}, "many": [{"v": 2, "tags": []}, 3], "by_key": {"k": {"v": 4, "tags": []}}}, ["a"]])
check("astuple", [astuple(o), astuple(Point(1, 2)), astuple(Point(1, 2), tuple_factory=list)],
      [("o", (1, ["a"]), [(2, []), 3], {"k": (4, [])}), (1, 2), [1, 2]])
check("asdict(dict_factory=)", asdict(Point(7, 8), dict_factory=lambda items: [k + "=" + str(v) for k, v in items]), ["x=7", "y=8"])
check("asdict / astuple of a non-dataclass", [raises(lambda: asdict(5)), raises(lambda: astuple(Point))],
      ["TypeError: asdict() should be called on dataclass instances", "TypeError: astuple() should be called on dataclass instances"])

f0 = fields(Point)[0]
check("fields()", [[f.name for f in fields(Point)], f0.type is int, fields(Point)[1].default, f0.default is MISSING, len(fields(Point(1))),
                   raises(lambda: fields(5)), fields(Bag)[0].default_factory is list],
      [["x", "y"], True, 0, True, 2, "TypeError: must be called with a dataclass type or instance", True])
@dataclass
class Meta:
    distance: float = field(default=0.0, metadata={"unit": "km"})
def set_metadata():
    fields(Meta)[0].metadata["x"] = 1
check("field metadata", [fields(Meta)[0].metadata["unit"], len(fields(Point)[0].metadata), raises(set_metadata)],
      ["km", 0, "TypeError: 'mappingproxy' object does not support item assignment"])

check("replace()", [repr(replace(Point(1, 2), y=5)), repr(replace(fz, x=9)), raises(lambda: replace(Point(1), w=1)), raises(lambda: replace(wp, total=1)),
                    raises(lambda: replace(5))],
      ["Point(x=1, y=5)", "Frozen(x=9, y=2)", "TypeError: Point.__init__() got an unexpected keyword argument 'w'",
       "ValueError: field total is declared with init=False, it cannot be specified with replace()",
       "TypeError: replace() should be called on dataclass instances"])
check("is_dataclass", [is_dataclass(Point), is_dataclass(Point(1)), is_dataclass(Color), is_dataclass(5), is_dataclass(dataclass)],
      [True, True, False, False, False])

def area(self):
    return self.w * self.h
Rect = make_dataclass("Rect", [("w", int), "label", ("h", int, field(default=1))], namespace={"area": area})
check("make_dataclass", [repr(Rect(2, "r", 3)), Rect(4, label="s").area(), [f.type for f in fields(Rect)][1], Rect(1, "a") == Rect(1, "a"), Rect.__name__],
      ["Rect(w=2, label='r', h=3)", 4, "typing.Any", True, "Rect"])
Sub3 = make_dataclass("Sub3", [("z", int, field(default=0))], bases=(Base,), frozen=False)
check("make_dataclass with bases and errors", [repr(Sub3(1, 2, 3)), raises(lambda: make_dataclass("X", ["a", "a"])), raises(lambda: make_dataclass("X", ["class"])),
                                                raises(lambda: make_dataclass("X", ["1x"]))],
      ["Sub3(x=1, y=2, z=3)", "TypeError: Field name duplicated: 'a'", "TypeError: Field names must not be keywords: 'class'",
       "TypeError: Field names must be valid identifiers: '1x'"])

def where(p):
    match p:
        case Point(0, 0):
            return "origin"
        case Point(0, y):
            return "y=" + str(y)
        case Point(x, y=0):
            return "x=" + str(x)
        case Point(x=x, y=y):
            return "at " + str(x) + "," + str(y)
    return "?"
check("__match_args__ in match statements", [where(Point(0, 0)), where(Point(0, 4)), where(Point(3)), where(Point(1, 2))],
      ["origin", "y=4", "x=3", "at 1,2"])
@dataclass(match_args=False, repr=False, init=False)
class Bare:
    a: int = 1
check("match_args=False, repr=False, init=False", [hasattr(Bare, "__match_args__"), Bare().a, "Bare(a=" in repr(Bare())], [False, 1, False])

@dataclass
class Node:
    value: int
    children: list = field(default_factory=list)
root = Node(1)
root.children.append(root)
check("a recursive repr", repr(root), "Node(value=1, children=[...])")

@dataclass
class Empty:
    pass
check("a dataclass without fields", [repr(Empty()), Empty() == Empty(), fields(Empty), Empty.__match_args__], ["Empty()", True, (), ()])

@dataclass(slots=True)
class Slotted:
    a: int
    b: int = 0
check("slots=True", [Slotted.__slots__, repr(Slotted(1))], [("a", "b"), "Slotted(a=1, b=0)"])
check("weakref_slot needs slots", raises(lambda: dataclass(weakref_slot=True)(type("W", (), {}))), "TypeError: weakref_slot is True but slots is False")

# a dataclass of enum members, and an enum used as a field's default
@dataclass(frozen=True)
class Pixel:
    color: Color = Color.RED
    alpha: Num = Num.ONE
check("dataclasses and enums together", [repr(Pixel()), Pixel(Color.BLUE) == Pixel(Color.BLUE), asdict(Pixel()), {Pixel(): 1}[Pixel()]],
      ["Pixel(color=<Color.RED: 1>, alpha=<Num.ONE: 1>)", True, {"color": Color.RED, "alpha": Num.ONE}, 1])

# a few thousand instances (the __init__ is generated once, the engines bind it)
many = [Point(i, i + 1) for i in range(3000)]
check("many instances", [len(many), many[2999].y, sum([p.x for p in many])], [3000, 3000, 4498500])

# ── the engine behaviour these modules stand on ───────────────────────────────
names_seen = []
for c in Color:
    names_seen.append(c.name)
check("a for statement over a class with a metaclass __iter__", names_seen, ["RED", "GREEN", "BLUE"])
check("a dataclass field with a factory leaves no class attribute", [hasattr(Bag, "items"), hasattr(Bag, "count"), Bag.count], [False, True, 0])
def init_v(self, v):
    self.v = v
Dyn2 = type("Dyn2", (), {"__init__": init_v, "__doc__": "dynamic"})
check("type() with dunder names in the namespace", [Dyn2(4).v, Dyn2.__doc__], [4, "dynamic"])
check("double quotes inside a triple-quoted string", [len("""x "y" z"""), """say "hi" now"""], [7, 'say "hi" now'])
class ProbeMeta(type):
    def __new__(mcs, name, bases, ns, **kw):
        ProbeMeta.seen = (name, [b.__name__ for b in bases], "probe_attr" in ns)
        return super().__new__(mcs, name, bases, ns)
class ProbeBase(metaclass=ProbeMeta):
    pass
class Probe(int, ProbeBase):
    probe_attr = 1
check("a metaclass sees builtin bases and the class's name", ProbeMeta.seen, ("Probe", ["int", "ProbeBase"], True))

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT81 PASSED ===")
