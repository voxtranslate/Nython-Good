# vm_audit60.ny - Python values and builtins, both engines (round 74).
#
#   truthiness      not/and/or on 0, "", [], {}, none; and/or yield an operand
#   integers        exact at any size: 2**64, big products, //, %, <<, &, ~,
#                   pow(b, e, m), divmod, abs, hex/oct/bin of negatives
#   floats          shortest round-trip repr, round() ties to even, floor % //
#   in place        L += it extends the same list (aliases see it), L *= n
#   dicts           insertion order, typed keys (1 vs "1", 1 == 1.0 == true,
#                   tuple keys), d["__len__"], copy(), dict(a=1), list(d)
#   formatting      f"{x:.2f}", {x!r}, nested specs, str.format fields, %,
#                   format()
#   strings         every str method, by character (UTF-8), Python slices
#   tuples          a type of their own: (1,), immutable, != list, keys
#   builtins        min/max over all arguments with key=/default=, sum start,
#                   sorted/zip/enumerate/list over strings, dicts, generators
#   errors          lst[10], "abc"[10] IndexError; t[0] = x TypeError
#   precedence      -2 ** 2 == -4; keyword arguments on methods and named
#                   like keywords (default=)
#   hash            Python's values for ints, floats, tuples; float dict
#                   keys; del L[a:b]; isinstance with tuple and bool
#
# Every expectation is Python 3's value (the file also runs under python3
# with true/false/none defined), compared by repr so 1, 1.0 and "1" differ.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit60.ny
#     ./build/nython-cli --vm examples/vm_audit60.ny

pass_n = 0
fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

def set0(t):
    t[0] = 5

def delb(d):
    del d["b"]

# Whether fn raises. (The exception's type is not asserted here: telling
# builtin exception types apart in `except` clauses is outside this file.)
def raises(fn):
    try:
        fn()
    except Exception:
        return "error"
    return "no error"

# ── truthiness, and/or ────────────────────────────────────────────────────
check("not 0", not 0, true)
check("not empty str", not "", true)
check("not empty list", not [], true)
check("not empty dict", not {}, true)
check("not none", not none, true)
check("not 1", not 1, false)
check("not str", not "a", false)
check("not list", not [0], false)
check("or operand", 0 or "x", "x")
check("and operand", 1 and "y", "y")
check("none or 0", none or 0, 0)
check("empty and", "" and 1, "")
check("list or", [] or [1], [1])
check("and short", 0 and (1 // 0), 0)
check("or short", 1 or (1 // 0), 1)
check("if 0.0", "t" if 0.0 else "f", "f")

# ── integers ──────────────────────────────────────────────────────────────
check("2**64", 2 ** 64, 18446744073709551616)
check("2**100", 2 ** 100, 1267650600228229401496703205376)
check("min int64", -(2 ** 63), -9223372036854775808)
check("big mul", 123456789012 * 987654321098, 121932631136585886175176)
check("big floordiv", 10 ** 30 // 7, 142857142857142857142857142857)
check("big neg floordiv", -(10 ** 20) // 3, -33333333333333333334)
check("big mod", -(10 ** 20) % 7, 5)
check("floordiv neg", -7 // 2, -4)
check("mod neg", -7 % 3, 2)
check("mod neg divisor", 7 % -3, -2)
check("shift big", 1 << 70, 1180591620717411303424)
check("shift back", (1 << 70) >> 68, 4)
check("and neg", -1 & 255, 255)
check("or", 12 | 3, 15)
check("xor", 255 ^ 15, 240)
check("invert", ~5, -6)
check("invert big", ~(2 ** 64), -18446744073709551617)
check("neg shift", -5 >> 1, -3)
check("pow3", pow(2, 10), 1024)
check("pow mod", pow(2, 10, 1000), 24)
check("pow mod big", pow(3, 200, 10 ** 9 + 7), 136318165)
check("pow neg exp", pow(2, -1), 0.5)
check("divmod neg", divmod(-7, 2), (-4, 1))
check("divmod neg divisor", divmod(7, -2), (-4, -1))
check("divmod float", divmod(7.5, 2), (3.0, 1.5))
check("abs big", abs(-5000000000), 5000000000)
check("abs float", abs(-2.5), 2.5)
check("hex neg", hex(-1), "-0x1")
check("hex big", hex(2 ** 64), "0x10000000000000000")
check("oct", oct(8), "0o10")
check("bin neg", bin(-5), "-0b101")
check("int str spaces", int(" 12 "), 12)
check("int big str", int("123456789012345678901234567890"), 123456789012345678901234567890)
check("int base 16", int("ff", 16), 255)
check("int base 0", int("0b101", 0), 5)
check("int underscores", int("1_000"), 1000)
check("int float", int(3.9), 3)
check("int neg float", int(-3.9), -3)
check("int bad", raises(lambda: int("12a")), "error")
check("true + true", true + true, 2)
check("true * 3", true * 3, 3)
check("zde", raises(lambda: 1 // 0), "error")
check("zde mod", raises(lambda: 1 % 0), "error")
check("int == float", 2 ** 53 == 2.0 ** 53, true)
check("big < float", 2 ** 64 < 1e30, true)

# ── floats ────────────────────────────────────────────────────────────────
check("repr 0.1+0.2", repr(0.1 + 0.2), "0.30000000000000004")
check("repr 1/3", repr(1 / 3), "0.3333333333333333")
check("repr 1e16", repr(1e16), "1e+16")
check("repr 2.0", repr(2.0), "2.0")
check("repr 1e-05", repr(0.00001), "1e-05")
check("str float", str(10 / 4), "2.5")
check("true div", 6 / 3, 2.0)
check("float floordiv", 7.5 // 2, 3.0)
check("float mod neg", -7.5 % 2, 0.5)
check("round half even 2.5", round(2.5), 2)
check("round half even 3.5", round(3.5), 4)
check("round neg", round(-2.5), -2)
check("round ndigits", round(2.675, 2), 2.67)
check("round ndigits 2", round(3.14159, 3), 3.142)
check("round int ndigits", round(1250, -2), 1200)
check("round int ndigits 2", round(1350, -2), 1400)
check("float inf", float("inf") > 10 ** 300, true)
check("float nan", float("nan") == float("nan"), false)
check("float str", float(" 1.5 "), 1.5)

# ── in-place operators ────────────────────────────────────────────────────
a = [1]
b = a
a += [2]
check("L += aliases", b, [1, 2])
a += (3, 4)
check("L += tuple", a, [1, 2, 3, 4])
a += "xy"
check("L += str", a, [1, 2, 3, 4, "x", "y"])
c = [0, 1]
d = c
c *= 2
check("L *= aliases", d, [0, 1, 0, 1])
s = "ab"
s *= 3
check("s *= 3", s, "ababab")
n = 7
n //= 2
check("//=", n, 3)
n **= 70
check("**= big", n, 3 ** 70)
n = 10
n %= -3
check("%= neg", n, -2)
t = (1, 2)
u = t
t += (3,)
check("tuple += new", t, (1, 2, 3))
check("tuple += old", u, (1, 2))

# ── sequences ─────────────────────────────────────────────────────────────
check("3 * str", 3 * "ab", "ababab")
check("str * 3", "ab" * 3, "ababab")
check("list * 3", [0] * 3, [0, 0, 0])
check("int * list", 2 * [1, 2], [1, 2, 1, 2])
check("list + list", [1] + [2], [1, 2])
L = [0, 1, 2, 3, 4]
check("slice rev", L[::-1], [4, 3, 2, 1, 0])
check("slice rev start", L[3::-1], [3, 2, 1, 0])
check("slice rev stop", L[:1:-1], [4, 3, 2])
check("slice neg", L[-3:], [2, 3, 4])
check("slice step", L[::2], [0, 2, 4])
check("slice empty", L[3:1], [])
check("slice oob", L[2:100], [2, 3, 4])
L[1:3] = [9, 9, 9]
check("slice assign grow", L, [0, 9, 9, 9, 3, 4])
L[2:] = []
check("slice assign tail", L, [0, 9])
L[:] = [5]
check("slice assign all", L, [5])
M = [0, 1, 2, 3]
M[::2] = [7, 8]
check("slice assign ext", M, [7, 1, 8, 3])
check("index oob", raises(lambda: [1, 2][10]), "error")
check("index neg oob", raises(lambda: [1, 2][-3]), "error")
check("str index oob", raises(lambda: "abc"[10]), "error")
check("list.sort reverse", sorted([3, 1, 2], reverse=true), [3, 2, 1])
Q = [3, 1, 2]
Q.sort(reverse=true)
check("L.sort(reverse=true)", Q, [3, 2, 1])
Q.sort(key=lambda x: -x)
check("L.sort(key)", Q, [3, 2, 1])
check("sort stable", sorted([(1, "b"), (0, "a"), (1, "a"), (0, "b")], key=lambda p: p[0]), [(0, "a"), (0, "b"), (1, "b"), (1, "a")])
check("sort nested lists", sorted([[2, "b"], [1, "z"], [2, "a"]]), [[1, "z"], [2, "a"], [2, "b"]])
check("pop empty", raises(lambda: [].pop()), "error")
check("remove missing", raises(lambda: [1].remove(5)), "error")
check("index start", [1, 2, 1, 2].index(1, 1), 2)
check("count", [1, 2, 1].count(1), 2)
R = [1, 2]
R.insert(-1, 9)
check("insert neg", R, [1, 9, 2])
check("in nested", [1, 2] in [[1, 2], [3]], true)

# ── tuples ────────────────────────────────────────────────────────────────
check("tuple single", (5,), (5,))
check("tuple len", len((5,)), 1)
check("tuple type", type((1, 2)) is tuple, true)
check("tuple != list", (1, 2) == [1, 2], false)
check("tuple == tuple", (1, 2) == (1, 2), true)
check("tuple repr", repr((1, "a")), "(1, 'a')")
check("tuple concat", (1, 2) + (3,), (1, 2, 3))
check("tuple repeat", (1, 2) * 2, (1, 2, 1, 2))
check("tuple slice", (1, 2, 3)[1:], (2, 3))
check("tuple immutable", raises(lambda: set0((1, 2))), "error")
check("tuple compare", (1, 2) < (1, 3), true)
x, y = (1, 2)
check("tuple unpack", [x, y], [1, 2])
check("divmod tuple", type(divmod(7, 2)) is tuple, true)
check("zip tuples", list(zip([1, 2], "ab")), [(1, "a"), (2, "b")])
check("enumerate tuples", list(enumerate(["a", "b"], 1)), [(1, "a"), (2, "b")])
check("items tuples", list({"k": 1}.items()), [("k", 1)])

# ── dicts ─────────────────────────────────────────────────────────────────
D = {"b": 1, "a": 2, "c": 3}
check("dict order", list(D), ["b", "a", "c"])
check("dict keys", list(D.keys()), ["b", "a", "c"])
check("dict values", list(D.values()), [1, 2, 3])
check("dict repr", repr(D), "{'b': 1, 'a': 2, 'c': 3}")
D["z"] = 0
del D["a"]
check("dict reinsert", list(D), ["b", "c", "z"])
K = {1: "int", "1": "str"}
check("int vs str key", [K[1], K["1"]], ["int", "str"])
check("int key len", len(K), 2)
check("float key", K[1.0], "int")
check("bool key", {true: "t"}[1], "t")
check("tuple key", {(1, 2): "t"}[(1, 2)], "t")
check("key types", list({10: "a", 2: "b"}), [10, 2])
check("int in dict", 1 in {1: 2}, true)
check("str not int", "1" in {1: 2}, false)
E = {}
E["__len__"] = 99
E["x"] = 1
check("dunder key", [E["__len__"], len(E)], [99, 2])
C = {"a": 1}
C2 = C.copy()
C2["b"] = 2
check("copy independent", [C, C2], [{"a": 1}, {"a": 1, "b": 2}])
check("dict kwargs", dict(a=1, b=2), {"a": 1, "b": 2})
check("dict pairs", dict([("x", 1), ("y", 2)]), {"x": 1, "y": 2})
check("sorted dict", sorted({"c": 1, "a": 2}), ["a", "c"])
check("dict comp", {k: v * 2 for k, v in [("a", 1), ("b", 2)]}, {"a": 2, "b": 4})
check("get default", {"a": 1}.get("b", 0), 0)
check("setdefault", {}.setdefault("k", 5), 5)
check("pop default", {"a": 1}.pop("b", 7), 7)
check("pop missing", raises(lambda: {}.pop("b")), "error")
check("del missing", raises(lambda: delb({})), "error")
U = {"a": 1}
U.update({"b": 2})
check("update", U, {"a": 1, "b": 2})

# ── formatting ────────────────────────────────────────────────────────────
v = 3.14159
nm = "bob"
check("fstring .2f", f"{v:.2f}", "3.14")
check("fstring !r", f"{nm!r}", "'bob'")
check("fstring width", f"{v:>10.3f}|", "     3.142|")
check("fstring 05d", f"{42:05d}", "00042")
check("fstring center", f"{nm:*^9}", "***bob***")
check("fstring comma", f"{1000000:,}", "1,000,000")
w = 8
check("fstring nested", f"{nm:>{w}}|", "     bob|")
check("fstring expr", f"{1 + 2}", "3")
check("fstring hex", f"{255:#x}", "0xff")
check("fstring percent", f"{0.25:.1%}", "25.0%")
check("fstring e", f"{12345.678:.2e}", "1.23e+04")
check("format positional", "{} {}".format(1, "a"), "1 a")
check("format indexed", "{0}{1}{0}".format("x", "y"), "xyx")
check("format named", "{name}!".format(name="n"), "n!")
check("format spec", "{:>5}|{:.3f}".format("ab", 2 / 3), "   ab|0.667")
check("format conv", "{!r}".format("q"), "'q'")
check("format item", "{0[1]}".format([5, 6]), "6")
check("format()", format(3.14159, ".2f"), "3.14")
check("format() int", format(42, "5d"), "   42")
check("format() bin", format(10, "08b"), "00001010")
check("percent", "%.2f %5d|%-5d|%x" % (3.14159, 42, 42, 255), "3.14    42|42   |ff")
check("percent s", "%s-%s" % ("a", "b"), "a-b")
check("percent r", "%r" % ("a",), "'a'")
check("percent single", "%d items" % 3, "3 items")
check("percent percent", "100%%" % (), "100%")

# ── strings ───────────────────────────────────────────────────────────────
check("split ws", "  a  b\tc \n".split(), ["a", "b", "c"])
check("split empty", "".split(), [])
check("split sep", "a,b,,c".split(","), ["a", "b", "", "c"])
check("split max", "a b c".split(" ", 1), ["a", "b c"])
check("rsplit", "a,b,c".rsplit(",", 1), ["a,b", "c"])
check("splitlines", "a\nb\r\nc".splitlines(), ["a", "b", "c"])
check("strip chars", "xxaxx".strip("x"), "a")
check("lstrip chars", "abcba".lstrip("ab"), "cba")
check("rstrip ws", "  x  ".rstrip(), "  x")
check("replace count", "aaa".replace("a", "b", 2), "bba")
check("replace empty", "abc".replace("", "-"), "-a-b-c-")
check("startswith tuple", "abc".startswith(("x", "a")), true)
check("endswith start", "abcd".endswith("bc", 0, 3), true)
check("find start", "hello".find("l", 3), 3)
check("rfind", "hello".rfind("l"), 3)
check("index missing", raises(lambda: "abc".index("z")), "error")
check("count sub", "banana".count("an"), 2)
check("partition", "a-b-c".partition("-"), ("a", "-", "b-c"))
check("rpartition", "a-b-c".rpartition("-"), ("a-b", "-", "c"))
check("zfill sign", "-42".zfill(5), "-0042")
check("center fill", "ab".center(6, "*"), "**ab**")
check("ljust", "x".ljust(3, "-"), "x--")
check("title", "hello world's".title(), "Hello World'S")
check("capitalize", "hELLO".capitalize(), "Hello")
check("swapcase", "Hello World".swapcase(), "hELLO wORLD")
check("isdigit", ["12".isdigit(), "1a".isdigit(), "".isdigit()], [true, false, false])
check("isalpha", ["ab".isalpha(), "a1".isalpha()], [true, false])
check("isspace", " \t".isspace(), true)
check("isupper", ["AB1".isupper(), "Ab".isupper()], [true, false])
check("istitle", "Hello World".istitle(), true)
check("join list", "-".join(["a", "b", "c"]), "a-b-c")
check("join tuple", ",".join(("a", "b")), "a,b")
check("join str", ".".join("abc"), "a.b.c")
check("join nonstr", raises(lambda: ",".join([1, 2])), "error")
check("str repr quotes", repr("it's"), "\"it's\"")
check("str in list repr", str([1, "a", [2.5]]), "[1, 'a', [2.5]]")

# ── UTF-8: characters, not bytes ──────────────────────────────────────────
u = "héllo"
check("utf8 len", len(u), 5)
check("utf8 index", u[1], "é")
check("utf8 slice", u[1:3], "él")
check("utf8 reverse", u[::-1], "olléh")
check("utf8 list", list(u), ["h", "é", "l", "l", "o"])
check("utf8 find", u.find("l"), 2)
check("utf8 neg index", u[-4], "é")
check("utf8 center", "é".center(3, "*"), "*é*")
check("utf8 ord", ord("é"), 233)
check("utf8 chr", chr(233), "é")
check("cjk slice", "日本語"[1:], "本語")
check("upper unicode", "école".upper(), "ÉCOLE")
chars = []
for ch in "aé日":
    chars.append(ch)
check("utf8 for", chars, ["a", "é", "日"])

# ── builtins over iterables ───────────────────────────────────────────────
check("max args", max(3, 1, 5), 5)
check("min args", min(3, 1, 0), 0)
check("max iterable", max([1, 5, 2]), 5)
check("min key", min("abc", "a", "ab", key=len), "a")
check("max key", max(["aa", "b"], key=len), "aa")
check("max default", max([], default=7), 7)
check("min empty", raises(lambda: min([])), "error")
check("max str", max("abd", "abc"), "abd")
check("sum start", sum([1, 2, 3], 10), 16)
check("sum floats", sum([0.5, 0.25]), 0.75)
check("sum big", sum([2 ** 64, 2 ** 64]), 2 ** 65)
check("sorted str", sorted("cba"), ["a", "b", "c"])
check("list str", list("abc"), ["a", "b", "c"])
check("reversed str", list(reversed("abc")), ["c", "b", "a"])
check("any", any([0, "", 1]), true)
check("all empty", all([]), true)
check("map", list(map(lambda x: x * 2, [1, 2])), [2, 4])
check("map 2", list(map(lambda a, b: a + b, [1, 2], [3, 4])), [4, 6])
check("filter none", list(filter(none, [0, 1, 2, ""])), [1, 2])
check("zip uneven", list(zip([1, 2, 3], "ab")), [(1, "a"), (2, "b")])

def gen3():
    yield 1
    yield 2
    yield 3

check("sum gen", sum(gen3()), 6)
check("list gen", list(gen3()), [1, 2, 3])
check("sorted gen", sorted(gen3(), reverse=true), [3, 2, 1])
check("zip gen", list(zip(gen3(), "abc")), [(1, "a"), (2, "b"), (3, "c")])
check("max gen", max(gen3()), 3)
check("set dedupe", sorted(set([3, 1, 3, 2])), [1, 2, 3])
check("str of containers", str({"k": [1, "a"]}), "{'k': [1, 'a']}")
check("type int", type(1) is int, true)
check("print is function", print is function, true)

# ── precedence, keyword arguments ─────────────────────────────────────────
nx = 3
check("sign binds looser than **", -2 ** 2, -4)
check("signed exponent", 2 ** -1, 0.5)
check("-x**2", -nx ** 2, -9)
check("~x**2", ~nx ** 2, -10)
check("(-x)**2", (-nx) ** 2, 9)
check("-big", -2 ** 70, -1180591620717411303424)

class KwA:
    def f(self, a, b=2):
        return a * 10 + b

check("method keyword", KwA().f(1, b=5), 15)
check("method default", KwA().f(1), 12)
check("keyword named like a keyword", max([], default=0), 0)

# ── hash, float keys, del on slices ───────────────────────────────────────
check("hash equal values", [hash(1) == hash(1.0), hash(1) == hash(true)], [true, true])
check("hash ints", [hash(1), hash(-1), hash(2 ** 70), hash(-(2 ** 70))], [1, -2, 512, -512])
check("hash floats", [hash(0.5), hash(-2.25), hash(1e300)], [1152921504606846976, -576460752303423490, 1224995262755759164])
check("hash tuples", [hash((1, 2)), hash(()), hash((1, (2.5, -3)))], [-3550055125485641917, 5740354900026072187, 1020499999290328233])
check("hash list", raises(lambda: hash([1])), "error")
fk = {0.5: "a", 2.5: "b"}
check("float keys", list(fk), [0.5, 2.5])
check("float key lookup", fk[0.5], "a")
dl = list(range(6))
del dl[1:3]
check("del slice", dl, [0, 3, 4, 5])
del dl[::2]
check("del extended slice", dl, [3, 5])
del dl[5:]
check("del empty slice", dl, [3, 5])
check("isinstance", [isinstance([1], list), isinstance((1,), tuple), isinstance((1,), list),
                    isinstance([1], tuple), isinstance(true, int), isinstance(1, int), isinstance(1.5, float)],
      [true, true, false, false, true, true, true])

# The most negative 64-bit value: its magnitude only fits unsigned (the
# bigint conversion negated it in the signed type - undefined behaviour).
var i64min = -9223372036854775808
check("-2**63", [i64min, -(2**63), abs(i64min), i64min - 1, i64min // 3, -i64min, int("-9223372036854775808")],
      [-9223372036854775808, -9223372036854775808, 9223372036854775808, -9223372036854775809,
       -3074457345618258603, 9223372036854775808, -9223372036854775808])
check("(-2**63,) tuple", (i64min, 1), (-9223372036854775808, 1))

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT60 PASSED ===")
