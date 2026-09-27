# vm_audit57.ny - round 75: strict reads, optional chaining, null
# coalescing, declarations and scope, suffix literals. Identical on both
# engines.
#
#   Reading an attribute an object does not have raises AttributeError and a
#   missing dict key KeyError (they read none); getattr / hasattr / setattr /
#   delattr, d.get / setdefault / `in`, and Nython's `a?.b`, `a?.m(x)`,
#   `a?[k]`, `f?.(x)`, `a ?? b`, `a ??= b` handle absence on purpose. A plain
#   assignment in a function rebinds the nearest existing binding; var / let
#   / const declare a local; `global` names the module's variable. A unit
#   suffix literal is an int when its value is whole (1k == 1000).
#
#     ./build/nython-cli examples/vm_audit57.ny
#     ./build/nython-cli --vm examples/vm_audit57.ny

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if got == want and type(got) == type(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " (" + str(type(got)) + ") want " + repr(want) + " (" + str(type(want)) + ")")

# The error a zero-argument function raises: "Type: message", or "none".
def err(f):
    try:
        f()
        return "none"
    except AttributeError as e:
        return "AttributeError: " + str(e)
    except KeyError as e:
        return "KeyError: " + str(e)
    except TypeError as e:
        return "TypeError: " + str(e)
    except NameError as e:
        return "NameError: " + str(e)
    except IndexError as e:
        return "IndexError: " + str(e)
    except ValueError as e:
        return "ValueError: " + str(e)

class Point:
    kind = "point"
    def __init__(self, x, y):
        self.x = x
        self.y = y
        self.next = none
    def norm1(self):
        return abs(self.x) + abs(self.y)
    @property
    def sum(self):
        return self.x + self.y

class Lazy:
    def __getattr__(self, name):
        if name.startswith("dyn_"):
            return name[4:]
        raise AttributeError("no " + name)

class Boom:
    @property
    def bad(self):
        raise ValueError("boom")
    @property
    def gone(self):
        raise AttributeError("gone")

def f_plain():
    return 1

p = Point(3, -4)
d = {"a": 1, "b": {"c": 2}, 5: "five"}

# ── 1. strict reads ─────────────────────────────────────────────────────────
check("field", p.x, 3)
check("method value", p.norm1(), 7)
check("class attr via instance", p.kind, "point")
check("class attr via class", Point.kind, "point")
check("property", p.sum, -1)
check("__class__", p.__class__ == Point, true)
check("__dict__", sorted(p.__dict__.keys()), ["next", "x", "y"])
check("__name__", Point.__name__, "Point")
check("fn __name__", f_plain.__name__, "f_plain")
check("missing field", err(lambda: p.z), "AttributeError: 'Point' object has no attribute 'z'")
check("missing class attr", err(lambda: Point.z), "AttributeError: type object 'Point' has no attribute 'z'")
check("none attr", err(lambda: none.x), "AttributeError: 'NoneType' object has no attribute 'x'")
check("none field chain", err(lambda: p.next.x), "AttributeError: 'NoneType' object has no attribute 'x'")
check("dict attr", err(lambda: d.zz), "AttributeError: 'dict' object has no attribute 'zz'")
check("dict key as attr", d.a, 1)
check("str attr", err(lambda: "s".nosuch), "AttributeError: 'str' object has no attribute 'nosuch'")
check("int attr", err(lambda: (5).nosuch), "AttributeError: 'int' object has no attribute 'nosuch'")
check("fn attr", err(lambda: f_plain.nosuch), "AttributeError: 'function' object has no attribute 'nosuch'")
check("list method call", err(lambda: [1].nosuch()), "AttributeError: 'list' object has no attribute 'nosuch'")
check("none method call", err(lambda: none.m()), "AttributeError: 'NoneType' object has no attribute 'm'")
check("instance method call", err(lambda: p.nosuch()), "AttributeError: 'Point' object has no attribute 'nosuch'")
check("dict key", d["a"], 1)
check("missing str key", err(lambda: d["zz"]), "KeyError: 'zz'")
check("missing int key", err(lambda: d[7]), "KeyError: 7")
check("nested key", d["b"]["c"], 2)
check("none subscript", err(lambda: none["k"]), "TypeError: 'NoneType' object is not subscriptable")
check("int subscript", err(lambda: (5)[0]), "TypeError: 'int' object is not subscriptable")
check("list index", err(lambda: [1, 2][5])[:10], "IndexError")
check("__getattr__ supplies", Lazy().dyn_abc, "abc")
check("__getattr__ raises", err(lambda: Lazy().other), "AttributeError: no other")
check("store on none", err(lambda: setattr(none, "x", 1)), "AttributeError: 'NoneType' object has no attribute 'x'")
def store_on_int():
    var n = 5
    n.x = 1
check("store on int", err(store_on_int), "AttributeError: 'int' object has no attribute 'x'")

# builtin methods read as values are bound
xs = [1]
push = xs.append
push(2)
check("bound list method", xs, [1, 2])
up = "abc".upper
check("bound str method", up(), "ABC")
dget = d.get
check("bound dict method", dget("a"), 1)
check("callable bound", callable(push), true)
check("bound method of instance", callable(p.norm1), true)

# ── 2. getattr / hasattr / setattr / delattr, dict helpers ──────────────────
check("getattr", getattr(p, "x"), 3)
check("getattr default", getattr(p, "zz", 9), 9)
check("getattr method", getattr(p, "norm1")(), 7)
check("getattr property", getattr(p, "sum"), -1)
check("getattr missing", err(lambda: getattr(p, "zz")), "AttributeError: 'Point' object has no attribute 'zz'")
check("getattr none default", getattr(none, "x", "dflt"), "dflt")
check("getattr __getattr__", getattr(Lazy(), "dyn_q", 0), "q")
check("getattr __getattr__ raising", getattr(Lazy(), "zz", "d"), "d")
check("hasattr field", hasattr(p, "x"), true)
check("hasattr method", hasattr(p, "norm1"), true)
check("hasattr class attr", hasattr(p, "kind"), true)
check("hasattr missing", hasattr(p, "zz"), false)
check("hasattr class", hasattr(Point, "norm1"), true)
check("hasattr none", hasattr(none, "x"), false)
check("hasattr str method", hasattr("s", "upper"), true)
check("hasattr list method", hasattr([], "append"), true)
check("hasattr dict method", hasattr({}, "get"), true)
check("hasattr dict key", hasattr({"k": 1}, "k"), true)
check("hasattr int", hasattr(5, "zz"), false)
check("hasattr property AttributeError", hasattr(Boom(), "gone"), false)
check("hasattr property ValueError", err(lambda: hasattr(Boom(), "bad")), "ValueError: boom")
q = Point(1, 2)
setattr(q, "z", 30)
check("setattr", q.z, 30)
setattr(Point, "tag", "T")
check("setattr class", q.tag, "T")
delattr(q, "z")
check("delattr", hasattr(q, "z"), false)
q.w = 1
del q.w
check("del attr", hasattr(q, "w"), false)
check("delattr missing", err(lambda: delattr(q, "w")), "AttributeError: 'Point' object has no attribute 'w'")
check("getattr name type", err(lambda: getattr(p, 5)), "TypeError: getattr(): attribute name must be string, not 'int'")
e = {"a": 1}
check("get", e.get("a"), 1)
check("get missing", e.get("z"), none)
check("get default", e.get("z", 0), 0)
check("setdefault new", e.setdefault("n", []), [])
e["n"].append(1)
check("setdefault existing", e.setdefault("n", [9]), [1])
check("in", "a" in e, true)
check("not in", "z" not in e, true)
check("pop default", e.pop("z", "none-here"), "none-here")

# ── 3. optional chaining ────────────────────────────────────────────────────
check("?. present", p?.x, 3)
check("?. missing", p?.zz, none)
check("?. none", none?.x, none)
check("?. undefined", undefined?.x, none)
check("?. class", Point?.kind, "point")
check("?. dict key", d?.a, 1)
check("?. dict missing", d?.zz, none)
check("?. rest short-circuits", none?.x.y.z, none)
check("?. missing short-circuits rest", p?.zz.y, none)
check("?. rest is strict", err(lambda: p?.next.x), "AttributeError: 'NoneType' object has no attribute 'x'")
check("?. twice", p?.next?.x, none)
p2 = Point(1, 1)
p2.next = Point(5, 6)
check("?. deep", p2?.next?.x, 5)
check("?.m()", p?.norm1(), 7)
check("?.m() missing", p?.nosuch(), none)
check("?.m() none", none?.norm1(), none)
check("?.m() builtin", [3, 1]?.index(1), 1)
check("?.m() dict", d?.get("a"), 1)
check("?.m() __getattr__", Lazy()?.dyn_x, "x")
calls = []
def side(v):
    calls.append(v)
    return v
check("?.m() skips args when none", none?.m(side(1)), none)
check("?.m() skips args when missing", p?.nosuch(side(2)), none)
check("?[] skips index", none?[side(3)], none)
check("?.m() args evaluated when called", p?.norm1(), 7)
check("side effects", calls, [])
check("?[] dict", d?["a"], 1)
check("?[] dict missing", d?["zz"], none)
check("?[] nested", d?["b"]?["c"], 2)
check("?[] nested missing", d?["q"]?["c"], none)
check("?[] missing short-circuits rest", d?["q"]["c"], none)
check("?[] list", [1, 2]?[1], 2)
check("?[] list negative", [1, 2]?[-1], 2)
check("?[] list out of range", [1, 2]?[5], none)
check("?[] str", "ab"?[1], "b")
check("?[] str out of range", "ab"?[9], none)
check("?[] none", none?["a"], none)
check("?.[] form", d?.["a"], 1)
check("?.[] missing", d?.["zz"], none)
check("?[] slice", [1, 2, 3]?[1:], [2, 3])
check("?[] slice none", none?[1:], none)
check("?[] type error still raises", err(lambda: (5)?[0]), "TypeError: 'int' object is not subscriptable")
class Box:
    def __init__(self, items):
        self.items = items
    def __getitem__(self, k):
        if k == "bad":
            raise ValueError("bad key")
        return self.items[k]
bx = Box({"k": 1})
check("?[] __getitem__", bx?["k"], 1)
check("?[] __getitem__ KeyError", bx?["zz"], none)
check("?[] __getitem__ other error", err(lambda: bx?["bad"]), "ValueError: bad key")
fnone = none
check("?.() none", fnone?.(1), none)
check("?.() call", (lambda v: v + 1)?.(1), 2)
check("?. then call", p?.norm1(), 7)
check("?. method chain", "a,b"?.split(",")?[1]?.upper(), "B")
check("?. with ??", p?.zz ?? "default", "default")
check("?. in f-string", f"{p?.x}-{p?.zz}", "3-none")
multi = p
    ?.next
    ?.x
check("?. across lines", multi, none)
check("assign to ?. is an error", len(ny_check_syntax("a?.b = 1")) > 0, true)
check("formatter keeps ??= and ?.", text_format_nython("x??=1\ny=a??b\nz=a?.b?[1]\n", "    ", {}), "x ??= 1\ny = a ?? b\nz = a?.b?[1]\n")
check("ternary still works", true ? 1 : 2, 1)
check("ternary with list", false ? [1] : [2], [2])
check("ternary with .5", true ? .5 : 1, 0.5)

# ── 4. ?? and ??= ───────────────────────────────────────────────────────────
check("?? none", none ?? 5, 5)
check("?? undefined", undefined ?? 5, 5)
check("?? zero kept", 0 ?? 5, 0)
check("?? false kept", false ?? 5, false)
check("?? empty kept", "" ?? 5, "")
check("?? list kept", [] ?? 5, [])
check("?? chain", none ?? none ?? 3, 3)
check("?? precedence +", none ?? 1 + 2, 3)
check("?? with or", none or 0 ?? 5, 0)
check("?? parenthesised", (none ?? 2) * 3, 6)
check("?? in conditional", 1 if none ?? true else 2, 1)
check("?? in conditional (parens)", 1 if (none ?? false) else 2, 2)
check("?? lazy", 4 ?? side(10), 4)
check("?? lazy side effects", calls, [])
x = none
x ??= 10
x ??= 20
check("??= name", x, 10)
u = undefined
u ??= "was undefined"
check("??= undefined", u, "was undefined")
z0 = 0
z0 ??= 99
check("??= keeps 0", z0, 0)
o = Point(0, 0)
o.cache ??= {}
o.cache["k"] = 1
o.cache ??= {"other": 2}
check("??= missing attr", o.cache, {"k": 1})
o.next ??= Point(7, 7)
check("??= none attr", o.next.x, 7)
g = {}
g["lst"] ??= []
g["lst"].append(1)
g["lst"] ??= [99]
check("??= missing key", g["lst"], [1])
g["n"] = none
g["n"] ??= 5
check("??= none key", g["n"], 5)
counter = [0]
def next_key():
    counter[0] = counter[0] + 1
    return "k"
g[next_key()] ??= 1
g[next_key()] ??= 2
check("??= index evaluated once", [counter[0], g["k"]], [2, 1])
def lazy_rhs():
    var v = 1
    v ??= side(20)
    return v
check("??= rhs not evaluated", [lazy_rhs(), calls], [1, []])
check("??= unbound name", len(ny_check_syntax("y ??= 1")), 0)

# ── 5. undefined ────────────────────────────────────────────────────────────
check("undefined != none", undefined == none, false)
check("undefined == undefined", undefined == undefined, true)
check("undefined str", str(undefined), "undefined")
check("undefined falsy", bool(undefined), false)
def with_default(a, b=undefined):
    return b
check("undefined default", with_default(1) == undefined, true)
o.u = undefined
check("field holding undefined is present", hasattr(o, "u"), true)
check("?? on undefined field", o.u ?? 3, 3)
uu = undefined
check("undefined variable", uu ?? "d", "d")

# ── 6. declarations and scope ───────────────────────────────────────────────
sg = 1
def plain_rebinds():
    sg = 2
plain_rebinds()
check("plain assignment rebinds global", sg, 2)
sv = 1
def var_shadows():
    var sv = 5
    sv = 6
    return sv
check("var shadows", [var_shadows(), sv], [6, 1])
sl = 1
def let_shadows():
    let sl = 7
    return sl
check("let shadows", [let_shadows(), sl], [7, 1])
sc = 1
def const_shadows():
    const sc = 8
    return sc
check("const shadows", [const_shadows(), sc], [8, 1])
def fresh_local():
    brand_new_name = 3
    return brand_new_name
check("fresh name is local", fresh_local(), 3)
check("fresh name not global", err(lambda: brand_new_name), "NameError: name 'brand_new_name' is not defined")
def before_global():
    made_later = "local"
    return made_later
check("before the global exists", before_global(), "local")
made_later = "global"
def after_global():
    made_later = "rebound"
after_global()
check("after the global exists", made_later, "rebound")
def read_then_declare():
    var r = sg
    var sg = 100
    return [r, sg]
check("read before declaration", read_then_declare(), [2, 100])
check("global unchanged", sg, 2)
cv = "g"
def cond_var(c):
    if c:
        var cv = "l"
    cv = "set"
    return cv
check("declaration happens when run (taken)", [cond_var(true), cv], ["set", "g"])
check("declaration happens when run (not taken)", [cond_var(false), cv], ["set", "set"])

def outer_rebind():
    var n = 1
    def inner():
        n = 2
    inner()
    return n
check("inner rebinds enclosing var", outer_rebind(), 2)
def outer_shadow():
    var n = 1
    def inner():
        var n = 2
        return n
    return [inner(), n]
check("inner var shadows enclosing", outer_shadow(), [2, 1])
def outer_nonlocal():
    var n = 1
    def inner():
        nonlocal n
        n = n + 10
    inner()
    return n
check("nonlocal", outer_nonlocal(), 11)
def make_counter():
    var count = 0
    def inc():
        count = count + 1
        return count
    return inc
cnt = make_counter()
cnt()
cnt()
check("closure counter", cnt(), 3)
cnt2 = make_counter()
check("closures are separate", cnt2(), 1)

def create_global():
    global created_by_fn
    created_by_fn = "made"
create_global()
check("global creates", created_by_fn, "made")
gz = "module"
def global_skips_enclosing():
    var gz = "enclosing"
    def inner():
        global gz
        gz = "from inner"
        return gz
    r = inner()
    return [r, gz]
check("global skips enclosing", [global_skips_enclosing(), gz], [["from inner", "enclosing"], "from inner"])
def global_augment():
    global sg
    sg += 40
global_augment()
check("global +=", sg, 42)
def global_loop():
    global gl_loop, gl_a, gl_b
    for gl_loop in range(3):
        pass
    gl_a, gl_b = "a", "b"
global_loop()
check("global for variable and unpacking", [gl_loop, gl_a, gl_b], [2, "a", "b"])

lv = "g"
def loop_local():
    for lv in range(3):
        pass
    return lv
check("for variable is local", [loop_local(), lv], [2, "g"])
def loop_var_decl():
    var acc = []
    for i in range(3):
        var t = i * 10
        acc.append(t)
    return [acc, t]
check("var in loop", loop_var_decl(), [[0, 10, 20], 20])
ck = "g"
comp = [ck for ck in range(3)]
check("comprehension scope", [comp, ck], [[0, 1, 2], "g"])
base = 10
check("comprehension reads outer", [base + i for i in range(2)], [10, 11])

cb = "global"
class ClassBody:
    cb = "class attr"
    def method(self):
        cb = "from method"
        return cb
check("class body binds the class", [ClassBody.cb, cb], ["class attr", "global"])
ClassBody().method()
check("method rebinds global, not class attr", [cb, ClassBody.cb], ["from method", "class attr"])
def caller_locals():
    var cb = "caller"
    ClassBody().method()
    return cb
check("method does not touch caller locals", caller_locals(), "caller")
def recursive(n):
    var mine = n
    if n > 0:
        recursive(n - 1)
    return mine
check("recursion has own locals", recursive(3), 3)
let top_let = 5
check("let at module level", top_let, 5)
xe = "g"
xw = "g"
xdef = "g"
xcls = "g"
xp = "g"
class Ctx:
    def __enter__(self):
        return "cm"
    def __exit__(self, a, b, c):
        return false
def binders(xp):
    try:
        raise ValueError("v")
    except ValueError as xe:
        pass
    with Ctx() as xw:
        pass
    def xdef():
        return 1
    class xcls:
        pass
    xp = "param rebound"
    return [xw, xp]
check("except-as / with-as / def / class / parameter are local", [binders(0), xe, xw, xdef, xcls, xp],
      [["cm", "param rebound"], "g", "g", "g", "g", "g"])

# ── 7. suffix literals ──────────────────────────────────────────────────────
check("1k", 1k, 1000)
check("1K", 1K, 1000)
check("2.5k", 2.5k, 2500)
check("1.1k exact", 1.1k, 1100)
check("1M", 1M, 1000000)
check("1G", 1G, 1000000000)
check("1T", 1T, 1000000000000)
check("1_000k", 1_000k, 1000000)
check("1m", 1m, 0.001)
check("1500m", 1500m, 1.5)
check("2000m", 2000m, 2)
check("1u", 1u, 0.000001)
check("5n", 5n, 0.000000005)
check("1k / 3", 1k / 3, 1000 / 3)
check("1k // 3", 1k // 3, 333)
check("1k * 2", 1k * 2, 2000)
check("1k + 0.5", 1k + 0.5, 1000.5)
check("1k % 7", 1k % 7, 6)
check("1k ** 2", 1k ** 2, 1000000)
check("-1k", -1k, -1000)
check("2k > 1999", 2k > 1999, true)
check("1k == 1000.0", 1k == 1000.0, true)
check("int(1M)", int(1M), 1000000)

print("vm_audit57: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
