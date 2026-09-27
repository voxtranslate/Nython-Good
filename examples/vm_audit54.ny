# vm_audit54.ny - generators, comprehensions, match, syntax and errors,
# identical on both engines.
#
#   Generators nested in generators, yield in match/try/finally/arguments,
#   yield from, empty generators, exceptions out of a generator, send();
#   comprehensions over strings/dicts/generators with tuple targets and
#   several clauses, in their own scope; structural pattern matching;
#   unpacking assignment, keyword-only parameters, raw strings, decorators;
#   iter/next/callable; NameError, AttributeError on a missing method and
#   TypeError for a call that does not fit. Every expected value is what
#   python3 gives.
#
#     ./build/nython-cli examples/vm_audit54.ny
#     ./build/nython-cli --vm examples/vm_audit54.ny

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

def error_of(f):
    try:
        f()
        return "none"
    except NameError:
        return "NameError"
    except AttributeError:
        return "AttributeError"
    except TypeError:
        return "TypeError"

# ── generators ──────────────────────────────────────────────────────────────
def count_to(n):
    for i in range(n):
        yield i
def outer():
    for x in count_to(2):
        yield x * 10
    yield 99
check("a generator inside a generator", list(outer()), [0, 10, 99])

def gen_match(v):
    match v:
        case 1:
            yield "one"
        case _:
            yield "other"
check("yield inside match", [list(gen_match(1)), list(gen_match(5))], [["one"], ["other"]])

def gen_try():
    try:
        yield 1
        raise ValueError("x")
    except ValueError:
        yield 2
    finally:
        yield 3
check("yield in try/except/finally", list(gen_try()), [1, 2, 3])

def delegate():
    yield from [1, 2]
    yield from count_to(2)
check("yield from", list(delegate()), [1, 2, 0, 1])

def never():
    return
    yield 1
check("a generator that yields nothing", list(never()), [])

def failing():
    yield 1
    raise KeyError("k")
def consume_failing():
    try:
        return list(failing())
    except KeyError:
        return "KeyError"
check("an exception leaves the generator", consume_failing(), "KeyError")

var g = count_to(3)
check("next / send(None) / default", [next(g), g.send(none), next(g), next(g, "done")], [0, 1, 2, "done"])
var g2 = count_to(5)
g2.close()
check("close", next(g2, "closed"), "closed")

class Tree:
    def __init__(self, items):
        self.items = items
    def __iter__(self):
        for i in self.items:
            yield i
check("a generator __iter__", [x for x in Tree([3, 4])], [3, 4])

def make(k):
    def g():
        yield k
    return g
check("a factory of generators is not one", list(make(7)()), [7])

# ── comprehensions ──────────────────────────────────────────────────────────
check("over a string", [c for c in "abc"], ["a", "b", "c"])
check("over a dict's keys", sorted([k for k in {"b": 1, "a": 2}]), ["a", "b"])
check("over a generator expression", sum(x * x for x in range(4)), 14)
var pairs = [["a", 1], ["b", 2]]
check("tuple targets", [k + str(v) for k, v in pairs], ["a1", "b2"])
check("several for and if clauses", [x * y for x in range(4) if x > 0 for y in range(3) if y != 1], [0, 2, 0, 4, 0, 6])
check("nested targets", [a + b + c for (a, b), c in [((1, 2), 3), ((4, 5), 6)]], [6, 15])
check("dict comprehension", {k: v * 2 for k, v in [["x", 1], ["y", 2]]}, {"x": 2, "y": 4})
check("set comprehension", sorted({x % 3 for x in range(10)}), [0, 1, 2])
var cx = "outer"
var ignored = [cx for cx in range(3)]
check("the loop variable stays in the comprehension", cx, "outer")

# ── match ───────────────────────────────────────────────────────────────────
class Point:
    __match_args__ = ("x", "y")
    def __init__(self, x, y):
        self.x = x
        self.y = y
def describe(p):
    match p:
        case 0 | 1:
            return "small"
        case int(n) if n > 100:
            return "big " + str(n)
        case "go":
            return "going"
        case [a, b]:
            return "pair " + str(a + b)
        case [first, *rest]:
            return "list " + str(first) + " " + str(rest)
        case Point(x=0, y=0):
            return "origin"
        case Point(0, y):
            return "y-axis " + str(y)
        case Point(x, y) if x == y:
            return "diagonal"
        case {"k": v, **others}:
            return "map " + str(v) + " " + str(sorted(others.keys()))
        case str() as s:
            return "str " + s
        case None:
            return "nothing"
        case _:
            return "other"
check("match literals and |", [describe(0), describe(1), describe(500)], ["small", "small", "big 500"])
check("match strings", [describe("go"), describe("hi")], ["going", "str hi"])
check("match sequences", [describe([1, 2]), describe([1, 2, 3]), describe([9])], ["pair 3", "list 1 [2, 3]", "list 9 []"])
check("match class patterns", [describe(Point(0, 0)), describe(Point(0, 5)), describe(Point(2, 2)), describe(Point(1, 2))], ["origin", "y-axis 5", "diagonal", "other"])
check("match mappings", describe({"k": 1, "z": 2, "a": 3}), "map 1 ['a', 'z']")
check("match None and the wildcard", [describe(None), describe(2.5)], ["nothing", "other"])
def cmd(c):
    match c:
        case ["go", ("north" | "south") as d]:
            return "go " + d
        case ["pick", *items, "now"]:
            return items
    return "no match"
check("match nested or-pattern with as", [cmd(["go", "north"]), cmd(["go", "east"])], ["go north", "no match"])
check("match star in the middle", cmd(["pick", 1, 2, "now"]), [1, 2])

# ── syntax ──────────────────────────────────────────────────────────────────
first, *others = [1, 2, 3]
check("a, *rest = ...", [first, others], [1, [2, 3]])
*init, last = [1, 2, 3]
check("*init, last = ...", [init, last], [[1, 2], 3])
(p1, p2), p3 = [[1, 2], 3]
check("nested unpacking", [p1, p2, p3], [1, 2, 3])
var sx = 1
var sy = 2
sx, sy = sy, sx
check("swap", [sx, sy], [2, 1])
def kwonly(a, *, scale=2):
    return a * scale
check("keyword-only parameter", [kwonly(3), kwonly(3, scale=10)], [6, 30])
check("raw string", r"a\nb", "a" + "\\" + "nb")
def repeat(n):
    def wrap(f):
        def inner(x):
            var out = x
            for i in range(n):
                out = f(out)
            return out
        return inner
    return wrap
@repeat(3)
def double(x):
    return x * 2
check("decorator with arguments", double(1), 8)
var total = 0
def add_all():
    global total
    for total in range(4):
        pass
add_all()
check("a global loop variable", total, 3)

# ── iter / next / callable ──────────────────────────────────────────────────
var it = iter([10, 20])
check("iter and next", [next(it), next(it), next(it, "end")], [10, 20, "end"])
check("callable", [callable(len), callable(count_to), callable(5)], [true, true, false])

# ── errors that are raised ──────────────────────────────────────────────────
check("reading an unbound name", error_of(lambda: undefined_name_here), "NameError")
class Plain:
    def m(self):
        return 1
check("calling a missing method", error_of(lambda: Plain().nope()), "AttributeError")
def two(a, b):
    return a + b
check("too few arguments", error_of(lambda: two(1)), "TypeError")
check("too many arguments", error_of(lambda: two(1, 2, 3)), "TypeError")
check("an unexpected keyword", error_of(lambda: two(1, c=2)), "TypeError")
check("True / False / None", [True, False, None], [true, false, none])

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT54 PASSED ===")
