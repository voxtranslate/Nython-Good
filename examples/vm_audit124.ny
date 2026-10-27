# vm_audit124.ny - Python-language source behaves as CPython where Nython is
# lenient, both engines (round 86).
#
# A Python-language source - a .py file, a file whose leading comments
# carry the marker (nython, a colon, python: this file must not), code
# compile() / exec() / eval() compile there, a def that opts in with the
# marker on its def line - is marked by the static
# scope pass (Node::py_src, src/NyScope.cpp) and both engines take
# CPython's path for it: `is` is identity (`1 is int` is False), + joins no
# str with a non-str and no list with a tuple, an int is not iterable,
# a dict's keys are not its attributes (d.a, getattr, hasattr, setattr),
# list.sort()/reverse() return None, an assignment past a list's end is an
# IndexError, sum(["a", "b"]) adds as + does, and Nython's literal spellings
# (true, false, none, null, undefined) and `elseif` are ordinary names.
#
# Part 1 writes one probe as a .py module (imported through sys.path from a
# per-pid directory), as a .ny module with the marker, and runs it with
# exec(compile(src, "probe.py", "exec")); every value is CPython's. Part 2
# checks the defects fixed for every file (sorted/min/max/list.sort order
# mixed types as CPython: TypeError; [1, 2]["0"]; the TypeError messages of
# seq * non-int, list + int, "abc"[1.0], a, b = 2). Part 3 (Nython only)
# shows Nython-language code unchanged ("a" + 1 == "a1", `for x in 3`,
# {"a": 1}.a, `1 is int`; an int iterated wherever Nython iterates: list(3),
# iter(3), sorted(3), enumerate(3) ...) and the `--python-compat-report`
# portability lint.
#
# Parts 1 and 2 run under python3 unchanged (`python3 examples/vm_audit124.ny`).
#
#     ./build/nython-cli examples/vm_audit124.ny
#     ./build/nython-cli --vm examples/vm_audit124.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import os
import sys
import shutil
import tempfile

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(f, *a):
    try:
        f(*a)
        return "no error"
    except BaseException as e:
        return type(e).__name__ + ": " + str(e)

# ── 1. a Python-language probe, three ways ───────────────────────────────────
PROBE = '''def _r(f):
    try:
        return f()
    except Exception as e:
        return type(e).__name__ + ": " + str(e)

class Obj:
    pass

def for_int():
    out = []
    for x in 5:
        out.append(x)
    return out

def aug_str():
    s = "a"
    s += 1
    return s

def aug_tuple_list():
    t = (1,)
    t += [2]
    return t

def dict_store():
    d = {}
    d.a = 1
    return d

def dict_setattr():
    d = {}
    setattr(d, "a", 1)
    return d

def unpack_int():
    a, b = 2
    return a

def list_grow():
    xs = [1]
    xs[3] = 4
    return xs

def gen_int():
    return list(x for x in 3)

def yield_from_int():
    def g():
        yield from 3
    return list(g())

def exec_concat():
    ns = {}
    exec("r = 'a' + 1", ns)
    return ns["r"]

def nested_comp():
    return [x + y for x in [1] for y in 2]

true = 3
none = 4
undefined = 5
null = 6
false = 7

def kw(elseif=1, unless=2, var=3, let=4, const=5, loop=6, new=7, fn=8):
    return elseif + unless + var + let + const + loop + new + fn

RESULTS = [
    ["1 is int", 1 is int],
    ["'a' is str", "a" is str],
    ["Obj() is Obj", Obj() is Obj],
    ["1 is not int", 1 is not int],
    ["type(1) is int", type(1) is int],
    ["str + int", _r(lambda: "a" + 1)],
    ["int + str", _r(lambda: 1 + "a")],
    ["str + list", _r(lambda: "a" + [1])],
    ["str + None", _r(lambda: "a" + None)],
    ["str + float", _r(lambda: "a" + 1.5)],
    ["list + str", _r(lambda: [1] + "a")],
    ["bool + str", _r(lambda: True + "a")],
    ["str + object", _r(lambda: "a" + object())],
    ["list + tuple", _r(lambda: [1] + (2,))],
    ["tuple + list", _r(lambda: (1,) + [2])],
    ["s += 1", _r(aug_str)],
    ["t += [2]", _r(aug_tuple_list)],
    ["str + str", "a" + "b"],
    ["sum of strs", _r(lambda: sum(["a", "b"]))],
    ["for x in 5", _r(for_int)],
    ["list(5)", _r(lambda: list(5))],
    ["iter(5)", _r(lambda: iter(5))],
    ["tuple(5)", _r(lambda: tuple(5))],
    ["set(5)", _r(lambda: set(5))],
    ["sorted(5)", _r(lambda: sorted(5))],
    ["sum(5)", _r(lambda: sum(5))],
    ["max(5)", _r(lambda: max(5))],
    ["any(5)", _r(lambda: any(5))],
    ["enumerate(5)", _r(lambda: enumerate(5))],
    ["zip(5, 5)", _r(lambda: zip(5, 5))],
    ["map(str, 5)", _r(lambda: map(str, 5))],
    ["[x for x in 5]", _r(lambda: [x for x in 5])],
    ["{x for x in 5}", _r(lambda: {x for x in 5})],
    ["nested comprehension over 2", _r(nested_comp)],
    ["(x for x in 3)", _r(gen_int)],
    ["yield from 3", _r(yield_from_int)],
    ["[].extend(5)", _r(lambda: [].extend(5))],
    ["a, b = 2", _r(unpack_int)],
    ["1 in 5", _r(lambda: 1 in 5)],
    ["literal words as names", [true, none, undefined, null, false]],
    ["Nython keywords as parameters", kw()],
    ["f-string of a name true", f"{true}-{none}"],
    ["{'a': 1}.a", _r(lambda: {"a": 1}.a)],
    ["getattr(dict, key, default)", getattr({"a": 1}, "a", "default")],
    ["hasattr(dict, key)", hasattr({"a": 1}, "a")],
    ["d.a = 1", _r(dict_store)],
    ["setattr(dict, ...)", _r(dict_setattr)],
    ["a dict's method", {"get": 1}.get("get")],
    ["list.sort()", [3, 1].sort()],
    ["list.reverse()", [3, 1].reverse()],
    ["xs[3] = 4 past the end", _r(list_grow)],
    ["exec'd code: str + int", _r(exec_concat)],
    ["eval'd code: 1 is int", eval("1 is int")],
    ["eval'd code: the name true", eval("true")],
]
'''

NOT_ITER = "TypeError: 'int' object is not iterable"
WANT = [
    ["1 is int", False],
    ["'a' is str", False],
    ["Obj() is Obj", False],
    ["1 is not int", True],
    ["type(1) is int", True],
    ["str + int", 'TypeError: can only concatenate str (not "int") to str'],
    ["int + str", "TypeError: unsupported operand type(s) for +: 'int' and 'str'"],
    ["str + list", 'TypeError: can only concatenate str (not "list") to str'],
    ["str + None", 'TypeError: can only concatenate str (not "NoneType") to str'],
    ["str + float", 'TypeError: can only concatenate str (not "float") to str'],
    ["list + str", 'TypeError: can only concatenate list (not "str") to list'],
    ["bool + str", "TypeError: unsupported operand type(s) for +: 'bool' and 'str'"],
    ["str + object", 'TypeError: can only concatenate str (not "object") to str'],
    ["list + tuple", 'TypeError: can only concatenate list (not "tuple") to list'],
    ["tuple + list", 'TypeError: can only concatenate tuple (not "list") to tuple'],
    ["s += 1", 'TypeError: can only concatenate str (not "int") to str'],
    ["t += [2]", 'TypeError: can only concatenate tuple (not "list") to tuple'],
    ["str + str", "ab"],
    ["sum of strs", "TypeError: unsupported operand type(s) for +: 'int' and 'str'"],
    ["for x in 5", NOT_ITER],
    ["list(5)", NOT_ITER],
    ["iter(5)", NOT_ITER],
    ["tuple(5)", NOT_ITER],
    ["set(5)", NOT_ITER],
    ["sorted(5)", NOT_ITER],
    ["sum(5)", NOT_ITER],
    ["max(5)", NOT_ITER],
    ["any(5)", NOT_ITER],
    ["enumerate(5)", NOT_ITER],
    ["zip(5, 5)", NOT_ITER],
    ["map(str, 5)", NOT_ITER],
    ["[x for x in 5]", NOT_ITER],
    ["{x for x in 5}", NOT_ITER],
    ["nested comprehension over 2", NOT_ITER],
    ["(x for x in 3)", NOT_ITER],
    ["yield from 3", NOT_ITER],
    ["[].extend(5)", NOT_ITER],
    ["a, b = 2", "TypeError: cannot unpack non-iterable int object"],
    ["1 in 5", "TypeError: argument of type 'int' is not iterable"],
    ["literal words as names", [3, 4, 5, 6, 7]],
    ["Nython keywords as parameters", 36],
    ["f-string of a name true", "3-4"],
    ["{'a': 1}.a", "AttributeError: 'dict' object has no attribute 'a'"],
    ["getattr(dict, key, default)", "default"],
    ["hasattr(dict, key)", False],
    ["d.a = 1", "AttributeError: 'dict' object has no attribute 'a'"],
    ["setattr(dict, ...)", "AttributeError: 'dict' object has no attribute 'a'"],
    ["a dict's method", 1],
    ["list.sort()", None],
    ["list.reverse()", None],
    ["xs[3] = 4 past the end", "IndexError: list assignment index out of range"],
    ["exec'd code: str + int", 'TypeError: can only concatenate str (not "int") to str'],
    ["eval'd code: 1 is int", False],
    ["eval'd code: the name true", 3],
]

def check_probe(tag, got):
    want = dict([(w[0], w[1]) for w in WANT])
    names = [g[0] for g in got]
    check(tag + ": every row reported", names, [w[0] for w in WANT])
    for g in got:
        check(tag + ": " + g[0], g[1], want.get(g[0], "(not expected)"))

tmp = tempfile.mkdtemp(prefix="vm124_" + str(os.getpid()) + "_")
sys.path.insert(0, tmp)
try:
    with open(os.path.join(tmp, "pymode124.py"), "w") as f:
        f.write(PROBE)
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")   # CPython's SyntaxWarnings for `1 is int`
        import pymode124
    check_probe("a .py module", pymode124.RESULTS)

    with open(os.path.join(tmp, "nymode124.ny"), "w") as f:
        f.write("# nython: module\n# nython: python\n" + PROBE)
    if nython:
        import nymode124
        check_probe("a # nython: python module", nymode124.RESULTS)

    ns = {"__name__": "probe124"}
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        exec(compile(PROBE, os.path.join(tmp, "probe124.py"), "exec"), ns)
    check_probe("exec(compile(src, 'probe124.py', 'exec'))", ns["RESULTS"])
finally:
    sys.path.remove(tmp)
    shutil.rmtree(tmp, ignore_errors=True)

# A Nython-language function opts in with the comment on its def line (its
# nested functions and lambdas too); python3 reads it as Python anyway.
def opted():  # nython: python
    def inner():
        return err(lambda: "a" + 1)
    one = 1
    return [inner(), one is int, err(lambda: {"k": 2}.k), err(lambda: list(4))]

check("a def opting in with `# nython: python`", opted(),
      ['TypeError: can only concatenate str (not "int") to str', False,
       "AttributeError: 'dict' object has no attribute 'k'", NOT_ITER])

# ast.parse is CPython's parser: `true` is a name to it
import ast
check("ast.parse('true') names true", ast.dump(ast.parse("true")),
      "Module(body=[Expr(value=Name(id='true', ctx=Load()))], type_ignores=[])")

# ── 2. every file: the defects (both engines, as CPython) ───────────────────
check("sorted() of int and str", err(sorted, [1, "a"]), "TypeError: '<' not supported between instances of 'str' and 'int'")
check("sorted() of None and int", err(sorted, [None, 1]), "TypeError: '<' not supported between instances of 'int' and 'NoneType'")
check("sorted(reverse=True) of int and str", err(lambda: sorted([1, "a"], reverse=True)),
      "TypeError: '<' not supported between instances of 'int' and 'str'")
check("sorted() by a key of mixed types", err(lambda: sorted([1, 2], key=lambda x: "a" if x == 1 else 2)),
      "TypeError: '<' not supported between instances of 'int' and 'str'")
def sort_mixed():
    xs = [1, "a"]
    xs.sort()
    return xs
check("list.sort() of int and str", err(sort_mixed), "TypeError: '<' not supported between instances of 'str' and 'int'")
check("max('a', 1)", err(max, "a", 1), "TypeError: '>' not supported between instances of 'int' and 'str'")
check("min('a', 1)", err(min, "a", 1), "TypeError: '<' not supported between instances of 'int' and 'str'")
check("max([1, 'a'])", err(max, [1, "a"]), "TypeError: '>' not supported between instances of 'str' and 'int'")
check("min([1, 'a'])", err(min, [1, "a"]), "TypeError: '<' not supported between instances of 'str' and 'int'")
check("max of dicts", err(max, [{}, {}]), "TypeError: '>' not supported between instances of 'dict' and 'dict'")
check("sorted of a list and a tuple", err(sorted, [[1], (1,)]), "TypeError: '<' not supported between instances of 'tuple' and 'list'")
check("what Python orders still sorts",
      [sorted([3, 1.5, True, 2]), sorted(["b", "a", "C"]), sorted([[2, 1], [1, 9], [1]]), sorted([(2,), (1, 5)]),
       max("ab", "b"), min([3, 1, 2]), max([1, 2], key=lambda x: -x), sorted([b"b", b"a"]), min(["b", "a"], default="z")],
      [[True, 1.5, 2, 3], ["C", "a", "b"], [[1], [1, 9], [2, 1]], [(1, 5), (2,)], "b", 1, 1, [b"a", b"b"], "a"])
nan = float("nan")
check("a NaN compares false, no error", [len(sorted([nan, 1, 2])), max([1, 2]), min([nan]) != min([nan])], [3, 2, True])
check("two sets sort", sorted([{1, 2}, {1}], key=lambda s: s), [{1}, {1, 2}])
class Ord:
    def __init__(self, v):
        self.v = v
    def __lt__(self, o):
        return self.v < o.v
    def __repr__(self):
        return "Ord(%d)" % self.v
check("objects order by __lt__", [sorted([Ord(2), Ord(1)]), max(Ord(1), Ord(3)), min([Ord(4), Ord(2)])],
      [[Ord(1), Ord(2)], Ord(3), Ord(2)])
check("objects without __lt__", err(sorted, [object(), object()]),
      "TypeError: '<' not supported between instances of 'object' and 'object'")

k0, kl, f1, s1, n0 = "0", "__len__", 1.0, "1", None   # (variables: python3 warns about literal indices)
check("[1, 2]['0']", err(lambda: [1, 2][k0]), "TypeError: list indices must be integers or slices, not str")
check("(1, 2)['0']", err(lambda: (1, 2)[k0]), "TypeError: tuple indices must be integers or slices, not str")
check("[1, 2]['__len__']", err(lambda: [1, 2][kl]), "TypeError: list indices must be integers or slices, not str")
check("'abc'[1.0]", err(lambda: "abc"[f1]), "TypeError: string indices must be integers, not 'float'")
check("'abc'['1']", err(lambda: "abc"[s1]), "TypeError: string indices must be integers, not 'str'")
check("'abc'[None]", err(lambda: "abc"[n0]), "TypeError: string indices must be integers, not 'NoneType'")
check("'a' * 'b'", err(lambda: "a" * "b"), "TypeError: can't multiply sequence by non-int of type 'str'")
check("'a' * 1.5", err(lambda: "a" * 1.5), "TypeError: can't multiply sequence by non-int of type 'float'")
check("1.5 * 'a'", err(lambda: 1.5 * "a"), "TypeError: can't multiply sequence by non-int of type 'float'")
check("[1] * 'b'", err(lambda: [1] * "b"), "TypeError: can't multiply sequence by non-int of type 'str'")
check("'a' * [1]", err(lambda: "a" * [1]), "TypeError: can't multiply sequence by non-int of type 'list'")
check("None * 'a'", err(lambda: None * "a"), "TypeError: can't multiply sequence by non-int of type 'NoneType'")
check("(1,) * 2.0", err(lambda: (1,) * 2.0), "TypeError: can't multiply sequence by non-int of type 'float'")
check("{} * 2", err(lambda: {} * 2), "TypeError: unsupported operand type(s) for *: 'dict' and 'int'")
def imul_list():
    xs = [1]
    xs *= "a"
    return xs
check("xs *= 'a'", err(imul_list), "TypeError: can't multiply sequence by non-int of type 'str'")
check("what repeats still repeats", ["ab" * 2, 2 * [0], (1,) * 2, "x" * True, [] * 3, "a" * -1],
      ["abab", [0, 0], (1, 1), "x", [], ""])
check("[1] + 1", err(lambda: [1] + 1), 'TypeError: can only concatenate list (not "int") to list')
check("(1,) + 1", err(lambda: (1,) + 1), 'TypeError: can only concatenate tuple (not "int") to tuple')
check("1 + [1]", err(lambda: 1 + [1]), "TypeError: unsupported operand type(s) for +: 'int' and 'list'")
check("None + 1", err(lambda: None + 1), "TypeError: unsupported operand type(s) for +: 'NoneType' and 'int'")
def unpack2():
    a, b = 2
    return a
def unpack_none():
    a, *b = None
    return a
check("a, b = 2", err(unpack2), "TypeError: cannot unpack non-iterable int object")
check("a, *b = None", err(unpack_none), "TypeError: cannot unpack non-iterable NoneType object")
check("1 in 5", err(lambda: 1 in 5), "TypeError: argument of type 'int' is not iterable")

# ── 3. Nython only: Nython-language code keeps Nython's conveniences ────────
if nython:
    check("Nython: str + non-str concatenates", ["a" + 1, 1 + "a", "a" + [1], "n=" + none, true + "!"],
          ["a1", "1a", "a[1]", "n=none", "true!"])
    check("Nython: a list and a tuple concatenate", [[1] + (2,), (1,) + [2]], [[1, 2], [1, 2]])
    def ny_for():
        out = []
        for x in 3:
            out.append(x)
        return out
    def ny_unp():
        it = iter(3)
        return [next(it), next(it), next(it)]
    def ny_yf():
        def g():
            yield from 2
        return list(g())
    check("Nython: an int iterates as range(n), everywhere it is iterated",
          [ny_for(), [x for x in 3], list(x * 2 for x in 3), list(3), tuple(2), sorted(3), sum(4), max(3), min(3),
           any(2), all(1), list(enumerate(2)), list(zip(2, 2)), list(map(str, 2)), list(filter(none, 3)),
           [*3], ny_unp(), ny_yf(), set(2), frozenset(1)],
          [[0, 1, 2], [0, 1, 2], [0, 2, 4], [0, 1, 2], (0, 1), [0, 1, 2], 6, 2, 0,
           true, false, [(0, 0), (1, 1)], [(0, 0), (1, 1)], ["0", "1"], [1, 2],
           [0, 1, 2], [0, 1, 2], [0, 1], {0, 1}, frozenset({0})])
    def ny_extend():
        xs = []
        xs.extend(2)
        xs += 1
        return xs
    check("Nython: list.extend(n) and xs += n", ny_extend(), [0, 1, 0])
    check("Nython: but `in` and unpacking an int are errors (as CPython)",
          [err(lambda: 1 in 5), err(unpack2)],
          ["TypeError: argument of type 'int' is not iterable", "TypeError: cannot unpack non-iterable int object"])
    one, sa = 1, "a"
    check("Nython: `is` with a type is a type test", [one is int, sa is str, Ord(1) is Ord, one is str, one is not int],
          [true, true, true, false, false])
    check("Nython: a dict's keys read as attributes", [{"a": 1}.a, getattr({"b": 2}, "b"), hasattr({"c": 3}, "c"),
                                                        {"get": 4}.get("get")],
          [1, 2, true, 4])
    def ny_dstore():
        d = {}
        d.k = 5
        setattr(d, "j", 6)
        return d
    check("Nython: d.k = v sets the key", ny_dstore(), {"k": 5, "j": 6})
    check("Nython: list.sort() and reverse() give the list (chaining)", [[3, 1, 2].sort(), [1, 2].reverse()],
          [[1, 2, 3], [2, 1]])
    def ny_grow():
        xs = [1]
        xs[2] = 3
        return xs
    check("Nython: an assignment past the end grows the list", ny_grow(), [1, none, 3])
    check("Nython: sum() adds as + does", sum(["a", "b"]), "0ab")

    # the --python-compat-report portability lint
    import subprocess
    tdir = tempfile.mkdtemp(prefix="vm124r_" + str(os.getpid()) + "_")
    src = os.path.join(tdir, "lint.ny")
    with open(src, "w") as f:
        f.write("total = 0\n"
                "def show(n):\n"
                "    return \"n=\" + len(n)\n"
                "for i in 10:\n"
                "    pass\n"
                "for j in len([1]):\n"
                "    pass\n"
                "conf = {\"port\": 80}\n"
                "p = conf.port\n"
                "if p is int:\n"
                "    x = true\n"
                "y = none\n"
                "s = [2, 1].sort()\n"
                "def add(v):\n"
                "    total += v\n"
                "def fine(v):  # nython: python\n"
                "    return \"n=\" + len(v)\n"
                "label = \"k\" + 5\n"
                "q = [i for i in 3]\n"
                "def ok(n):\n"
                "    return \"n=\" + n\n"
                # classes compared by identity are not reported: a name bound
                # to type(...), a loop over an __mro__, a name held by classes
                "t = type(p)\n"
                "if t is int:\n"
                "    pass\n"
                "def g(cls):\n"
                "    return cls is object\n"
                "for c in int.__mro__:\n"
                "    print(c is object)\n")
    r = subprocess.run([sys.executable, "--python-compat-report", src], capture_output=True, text=True)
    lines = [ln.replace(src, "lint.ny") for ln in r.stdout.splitlines()]
    check("--python-compat-report: status", r.returncode, 0)
    tail = ": Nython counts 0..n-1, Python raises TypeError - write range(...)"
    conc = ": Nython converts it to text, Python raises TypeError - write str(...) or an f-string"
    check("--python-compat-report: the constructs whose meaning differs from Python's", lines,
          ["lint.ny:3:12: concat: str + a non-str value (len(...))" + conc,
           "lint.ny:4:10: int-iter: iterates an int" + tail,
           "lint.ny:6:10: int-iter: iterates an int (len(...))" + tail,
           "lint.ny:9:5: dict-attr: reads the dict's key 'port' as an attribute: Python raises AttributeError - write conf[\"port\"]",
           "lint.ny:10:4: is-type: `is int` of a value is Nython's type test: Python compares identity (False) - write isinstance(...)",
           "lint.ny:11:9: literal: `true` is Nython's spelling: to Python it is an undefined name - write True",
           "lint.ny:12:5: literal: `none` is Nython's spelling: to Python it is an undefined name - write None",
           "lint.ny:13:5: sort-value: list.sort() gives the list in Nython, None in Python - sort, then use the list (or sorted(...))",
           "lint.ny:15:5: binding: function 'add' augments 'total', rebinding the module's 'total' (line 1): Python's rule makes it a local - declare 'global total'",
           "lint.ny:18:9: concat: str + a non-str value (a number)" + conc,
           "lint.ny:19:17: int-iter: iterates an int" + tail])
    shutil.rmtree(tdir, ignore_errors=True)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT124 PASSED ===")
