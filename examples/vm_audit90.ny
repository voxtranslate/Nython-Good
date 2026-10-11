# vm_audit90.ny - lazy range, dict views and lazy builtins, both engines
# (round 78).
#
# range() and d.keys()/values()/items() returned lists, and zip/map/filter/
# enumerate/reversed over lists returned lists. They are Python's types now:
# range is a lazy sequence of ints of any size (CPython's rangeobject.c:
# len, indexing, slicing to a range, O(1) `in`, index/count, == by the values,
# hash, repr, start/stop/step), the views are live (len, iter, in, reversed,
# the set operations of keys and items views, comparisons with sets,
# isdisjoint, .mapping, "dictionary changed size during iteration"), and
# zip/map/filter/enumerate/reversed are lazy iterators over everything.
#
# Everything here runs under python3 too (`python3 examples/vm_audit90.ny`);
# every expected value is CPython's.
#
#     ./build/nython-cli examples/vm_audit90.ny
#     ./build/nython-cli --vm examples/vm_audit90.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import json
import collections.abc

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(f):
    # the exception f() raises, as "Type: message"
    try:
        f()
        return "no error"
    except Exception as e:
        return type(e).__name__ + ": " + str(e)

class Idx:
    def __init__(self, v):
        self.v = v
    def __index__(self):
        return self.v

# ── range: the object ────────────────────────────────────────────────────────
check("range repr", [repr(range(5)), repr(range(1, 5)), repr(range(0, 10, 2)), repr(range(5, 0, -1)), str(range(3))],
      ["range(0, 5)", "range(1, 5)", "range(0, 10, 2)", "range(5, 0, -1)", "range(0, 3)"])
check("range is a type", [type(range(3)) is range, type(range(3)).__name__, isinstance(range(3), range), repr(range),
                          isinstance([0, 1], range)],
      [True, "range", True, "<class 'range'>", False])
check("start, stop, step", [[range(5).start, range(5).stop, range(5).step], [range(2, 9, 3).start, range(2, 9, 3).stop, range(2, 9, 3).step],
                            [range(9, 2, -1).start, range(9, 2, -1).stop, range(9, 2, -1).step]],
      [[0, 5, 1], [2, 9, 3], [9, 2, -1]])
check("range of bools and __index__", [range(True), list(range(Idx(3))), list(range(Idx(1), Idx(7), Idx(2))), range(True).stop],
      [range(0, 1), [0, 1, 2], [1, 3, 5], 1])
check("len", [len(range(10)), len(range(0)), len(range(5, 0, -1)), len(range(0, 10, 3)), len(range(10, 0, -3)),
              len(range(-5, 5)), len(range(2, 2)), len(range(5, 2)), len(range(0, 1, 100))],
      [10, 0, 5, 4, 4, 10, 0, 0, 1])
check("len past sys.maxsize", [err(lambda: len(range(2 ** 64))), err(lambda: len(range(-2 ** 63, 2 ** 63 - 1)))],
      ["OverflowError: Python int too large to convert to C ssize_t", "OverflowError: Python int too large to convert to C ssize_t"])
check("bool", [bool(range(0)), bool(range(1)), bool(range(10 ** 30)), bool(range(5, 5)), bool(range(5, 4, -1))],
      [False, True, True, False, True])

# ── range: errors ───────────────────────────────────────────────────────────
check("range() checks its arguments",
      [err(lambda: range(1, 10, 0)), err(lambda: range(1.5)), err(lambda: range()), err(lambda: range(1, 2, 3, 4)),
       err(lambda: range("a")), err(lambda: range(1, None)), err(lambda: range(0, 10, 2.0))],
      ["ValueError: range() arg 3 must not be zero", "TypeError: 'float' object cannot be interpreted as an integer",
       "TypeError: range expected at least 1 argument, got 0", "TypeError: range expected at most 3 arguments, got 4",
       "TypeError: 'str' object cannot be interpreted as an integer",
       "TypeError: 'NoneType' object cannot be interpreted as an integer",
       "TypeError: 'float' object cannot be interpreted as an integer"])
check("range takes no keywords", err(lambda: range(stop=5)), "TypeError: range() takes no keyword arguments")
def set_start():
    r = range(3)
    r.start = 5
check("start/stop/step are read-only", err(set_start), "AttributeError: readonly attribute")

# ── range: indexing and slicing ──────────────────────────────────────────────
r10 = range(10)
check("indexing", [r10[0], r10[-1], r10[3], range(0, 20, 3)[2], range(10, 0, -2)[-1], r10[True], range(5)[Idx(2)]],
      [0, 9, 3, 6, 2, 1, 2])
check("index errors", [err(lambda: r10[10]), err(lambda: r10[-11]), err(lambda: range(0)[0]), err(lambda: r10["a"]),
                       err(lambda: r10[1.0])],
      ["IndexError: range object index out of range", "IndexError: range object index out of range",
       "IndexError: range object index out of range", "TypeError: range indices must be integers or slices, not str",
       "TypeError: range indices must be integers or slices, not float"])
check("slicing gives a range", [r10[2:5], r10[::2], r10[::-1], range(0, 20, 3)[1:4], r10[-3:], r10[5:2], r10[1:9:3],
                                range(10, 0, -1)[2:6], r10[:], range(1, 50, 7)[::-2]],
      [range(2, 5), range(0, 10, 2), range(9, -1, -1), range(3, 12, 3), range(7, 10), range(5, 2), range(1, 9, 3),
       range(8, 4, -1), range(0, 10), range(43, -6, -14)])
check("slices hold the right values", [list(r10[::-1]), list(r10[8:2:-2]), list(range(0, 20, 3)[1:4]), r10[2:5][0], r10[::2][-1]],
      [[9, 8, 7, 6, 5, 4, 3, 2, 1, 0], [8, 6, 4], [3, 6, 9], 2, 8])

# ── range: in, index, count ──────────────────────────────────────────────────
check("in, for ints in O(1)", [5 in r10, 10 in r10, -1 in r10, 3 in range(0, 10, 3), 4 in range(0, 10, 3),
                               9 in range(10, 0, -1), 10 in range(10, 0, -1), 0 in range(10, 0, -1), True in range(3),
                               False in range(1, 3), 10 ** 25 in range(10 ** 30), 10 ** 25 + 1 in range(0, 10 ** 30, 2)],
      [True, False, False, True, False, True, True, False, True, False, True, False])
check("in, for other values by ==", [5.0 in r10, 5.5 in r10, "a" in range(3), None in range(3), 2.0 not in range(3)],
      [True, False, False, False, False])
check("index", [range(0, 20, 2).index(6), r10.index(0), range(10, 0, -1).index(1), range(5).index(2.0), range(3).index(True)],
      [3, 0, 9, 2, 1])
check("index errors", [err(lambda: r10.index(11)), err(lambda: range(0, 10, 2).index(3)), err(lambda: r10.index("x"))],
      ["ValueError: 11 is not in range", "ValueError: 3 is not in range", "ValueError: sequence.index(x): x not in sequence"])
check("count", [r10.count(3), r10.count(11), range(5).count(1.0), range(5).count("a"), range(0, 10, 2).count(4)],
      [1, 0, 1, 0, 1])

# ── range: equality and hashing ──────────────────────────────────────────────
check("== by the sequence described", [range(0) == range(2, 2), range(0, 10, 2) == range(0, 9, 2), range(1) == range(1, 2, 5),
                                      range(0, 1, 3) == range(0, 1, 7), range(3) == [0, 1, 2], range(3) != range(3),
                                      range(3) != range(4), range(5, 0, -1) == range(5, 0, -1), range(3) == range(0, 3, 1)],
      [True, True, False, True, False, False, True, True, True])
check("hash follows ==", [hash(range(0)) == hash(range(3, 3)), hash(range(0, 10, 2)) == hash(range(0, 9, 2)),
                          hash(range(1, 2)) == hash(range(1, 5, 10)), {range(3): "a"}[range(0, 3)], len({range(0), range(5, 5), range(2)})],
      [True, True, True, "a", 2])
check("ordering is not defined", err(lambda: range(1) < range(2)),
      "TypeError: '<' not supported between instances of 'range' and 'range'")

# ── range: iteration ─────────────────────────────────────────────────────────
check("iter and reversed", [type(iter(range(3))).__name__, next(iter(range(5, 8))), list(iter(range(3))),
                            list(reversed(range(5))), type(reversed(range(3))).__name__, list(reversed(range(0, 10, 3))),
                            list(reversed(range(0))), list(reversed(range(10, 0, -4)))],
      ["range_iterator", 5, [0, 1, 2], [4, 3, 2, 1, 0], "range_iterator", [9, 6, 3, 0], [], [2, 6, 10]])
check("materialized", [list(range(-3, 3)), tuple(range(3)), set(range(3)), sorted(range(5, 0, -1)), min(range(5, 10)),
                       max(range(5, 10)), [x * x for x in range(5)], list(range(10 ** 20, 10 ** 20 + 3))],
      [[-3, -2, -1, 0, 1, 2], (0, 1, 2), {0, 1, 2}, [1, 2, 3, 4, 5], 5, 9, [0, 1, 4, 9, 16],
       [10 ** 20, 10 ** 20 + 1, 10 ** 20 + 2]])
r3 = range(3)
check("a range is re-iterable", [list(r3), list(r3), [x for x in r3 for y in r3][:4]], [[0, 1, 2], [0, 1, 2], [0, 0, 0, 1]])
def loops():
    out = []
    for i in range(3):
        out.append(i)
    else:
        out.append("else")
    for i in range(10, 0, -3):
        if i < 5:
            break
        out.append(i)
    for i in range(0):
        out.append("never")
    out.append(i)
    total = 0
    for j in range(2 ** 62, 2 ** 62 + 3):
        total += j - 2 ** 62
    out.append(total)
    for k in range(2 ** 64, 2 ** 64 + 2):
        out.append(k - 2 ** 64)
    return out
check("for loops", loops(), [0, 1, 2, "else", 10, 7, 4, 3, 0, 1])
a, b, c = range(3)
check("unpacking", [a, b, c, list(map(str, range(3))), [*range(2), *range(5, 7)]], [0, 1, 2, ["0", "1", "2"], [0, 1, 5, 6]])
check("big ranges are lazy", [range(10 ** 12)[10 ** 11], len(range(0, 10 ** 30, 10 ** 20)), range(10 ** 30)[-1],
                              len(range(-10 ** 20, 10 ** 20, 10 ** 19)), range(10 ** 30)[10 ** 29:][:2]],
      [10 ** 11, 10 ** 10, 10 ** 30 - 1, 20, range(10 ** 29, 10 ** 29 + 2)])
check("sum of a range (O(1) here)", [sum(range(10 ** 9)), sum(range(1, 101)), sum(range(10), 5), sum(range(0, -10, -1)),
                                     sum(range(5, 5)), sum(range(1, 10, 2)), sum(range(10 ** 12, 10 ** 12 + 2))],
      [499999999500000000, 5050, 50, -45, 0, 25, 2000000000001])
check("range is a Sequence", [isinstance(range(3), collections.abc.Sequence), isinstance(iter(range(3)), collections.abc.Iterator),
                              isinstance(range(3), collections.abc.Hashable)],
      [True, True, True])

# ── dict views ───────────────────────────────────────────────────────────────
d = {"a": 1, "b": 2}
check("view types", [type(d.keys()).__name__, type(d.values()).__name__, type(d.items()).__name__],
      ["dict_keys", "dict_values", "dict_items"])
check("view repr", [repr(d.keys()), repr(d.values()), repr(d.items()), repr({}.keys()), str({1: "x"}.items())],
      ["dict_keys(['a', 'b'])", "dict_values([1, 2])", "dict_items([('a', 1), ('b', 2)])", "dict_keys([])", "dict_items([(1, 'x')])"])
def live():
    e = {"a": 1}
    k = e.keys()
    v = e.values()
    it = e.items()
    e["b"] = 2
    del e["a"]
    return [list(k), list(v), list(it), len(k), len(v), len(it)]
check("views are live", live(), [["b"], [2], [("b", 2)], 1, 1, 1])
check("len and bool", [len(d.keys()), len(d.values()), len(d.items()), bool({}.keys()), bool(d.items()), bool({}.values())],
      [2, 2, 2, False, True, False])
check("in", ["a" in d.keys(), "z" in d.keys(), "z" not in d.keys(), ("a", 1) in d.items(), ("a", 2) in d.items(),
             ("a",) in d.items(), ["a", 1] in d.items(), 1 in d.values(), 5 in d.values(), ("z", 1) in d.items()],
      [True, False, True, True, False, False, False, True, False, False])
check("unhashable key in a keys view", err(lambda: [1] in d.keys()), "TypeError: unhashable type: 'list'")
# (a set's order is its hashes' in CPython: compared sorted)
check("set operations on keys", [sorted(d.keys() & {"a", "c"}), sorted(d.keys() | {"c"}), sorted(d.keys() - {"a"}),
                                 sorted(d.keys() ^ {"a", "c"}), sorted({"a", "x"} & d.keys()), sorted(["a", "q"] - d.keys()),
                                 sorted(("b", "c") | d.keys()), type(d.keys() & {"a"}).__name__, sorted(d.keys() & ["b", "b"]),
                                 sorted({"a": 0, "c": 0}.keys() - d.keys()), d.keys() & {"a", "c"} == {"a"}],
      [["a"], ["a", "b", "c"], ["b"], ["b", "c"], ["a"], ["q"], ["a", "b", "c"], "set", ["b"], ["c"], True])
check("set operations on items", [sorted(d.items() & {("a", 1)}), sorted(d.items() - {("a", 1)}),
                                  d.items() | {("c", 3)} == {("a", 1), ("b", 2), ("c", 3)},
                                  d.items() ^ {("a", 1), ("z", 0)} == {("b", 2), ("z", 0)}],
      [[("a", 1)], [("b", 2)], True, True])
check("comparisons with sets", [d.keys() == {"a", "b"}, {"a", "b"} == d.keys(), d.keys() <= {"a", "b", "c"}, d.keys() < {"a", "b"},
                                d.keys() >= {"a"}, d.keys() > {"a"}, d.keys() == ["a", "b"], d.keys() != {"a"},
                                d.keys() == {"b": 0, "a": 0}.keys(), d.items() == {("a", 1), ("b", 2)},
                                d.items() == {"a": 1, "b": 3}.items()],
      [True, True, True, False, True, True, False, True, True, True, False])
dv = d.values()
check("values views compare by identity", [d.values() == d.values(), dv == dv, dv != d.values(), isinstance(hash(dv), int)],
      [False, True, True, True])
check("keys and items views are unhashable", [err(lambda: hash(d.keys())), err(lambda: {d.items(): 1})],
      ["TypeError: unhashable type: 'dict_keys'", "TypeError: unhashable type: 'dict_items'"])
check("isdisjoint", [d.keys().isdisjoint({"x"}), d.keys().isdisjoint(["a"]), d.items().isdisjoint([("a", 2)]),
                     d.items().isdisjoint({("b", 2)}), {}.keys().isdisjoint(d)],
      [True, False, True, False, True])
def set_mapping():
    m = d.keys().mapping
    m["a"] = 5
check("mapping", [repr(d.keys().mapping), d.items().mapping["b"], d.values().mapping == d, len(d.keys().mapping),
                  err(set_mapping), type(d.keys().mapping).__name__],
      ["mappingproxy({'a': 1, 'b': 2})", 2, True, 2, "TypeError: 'mappingproxy' object does not support item assignment", "mappingproxy"])
check("reversed views and dicts", [list(reversed(d.keys())), list(reversed(d.values())), list(reversed(d.items())), list(reversed(d)),
                                   type(reversed(d.keys())).__name__, type(reversed(d.values())).__name__,
                                   type(reversed(d.items())).__name__, type(reversed(d)).__name__],
      [["b", "a"], [2, 1], [("b", 2), ("a", 1)], ["b", "a"], "dict_reversekeyiterator", "dict_reversevalueiterator",
       "dict_reverseitemiterator", "dict_reversekeyiterator"])
check("iterator types", [type(iter(d.keys())).__name__, type(iter(d.values())).__name__, type(iter(d.items())).__name__,
                         type(iter(d)).__name__, next(iter(d.items())), next(iter(d.values()))],
      ["dict_keyiterator", "dict_valueiterator", "dict_itemiterator", "dict_keyiterator", ("a", 1), 1])
def changed(kind):
    e = {"a": 1, "b": 2}
    try:
        if kind == 0:
            for k in e:
                e["c" + k] = 0
        elif kind == 1:
            for k in e.keys():
                del e[k]
        elif kind == 2:
            for k, v in e.items():
                e.pop("b")
        elif kind == 3:
            for v in e.values():
                e.clear()
        elif kind == 4:
            for k in e:
                e[k] = 5    # changing values is fine
            return e
        elif kind == 5:
            it = iter(e)
            next(it)
            e["z"] = 1
            try:
                next(it)
            except RuntimeError:
                pass
            return err(lambda: next(it))
        return "no error"
    except RuntimeError as ex:
        return str(ex)
check("dictionary changed size during iteration", [changed(0), changed(1), changed(2), changed(3), changed(4), changed(5)],
      ["dictionary changed size during iteration", "dictionary changed size during iteration",
       "dictionary changed size during iteration", "dictionary changed size during iteration", {"a": 5, "b": 5},
       "RuntimeError: dictionary changed size during iteration"])
def safe_delete():
    e = {"a": 1, "b": 2, "c": 3}
    for k in list(e.keys()):
        if k != "b":
            del e[k]
    return e
check("list(d.keys()) is the safe way to delete while looping", safe_delete(), {"b": 2})
check("views where lists were taken", [sorted(d.items()), sorted(d.items(), key=lambda kv: -kv[1]), dict(d.items()),
                                       list(zip(d.keys(), d.values())), dict.fromkeys(d.keys(), 0), set(d.keys()),
                                       max(d.values()), sum(d.values()), list(d.keys()), list(d.values())[1],
                                       ", ".join(d.keys()), [k + "!" for k in d.keys()], {**dict(d.items())},
                                       sorted({3: 0, 1: 0}.keys())],
      [[("a", 1), ("b", 2)], [("b", 2), ("a", 1)], {"a": 1, "b": 2}, [("a", 1), ("b", 2)], {"a": 0, "b": 0}, {"a", "b"},
       2, 3, ["a", "b"], 2, "a, b", ["a!", "b!"], {"a": 1, "b": 2}, [1, 3]])
check("views are not lists", [err(lambda: d.keys()[0]), err(lambda: d.values()[0]), err(lambda: d.keys().append("c"))],
      ["TypeError: 'dict_keys' object is not subscriptable", "TypeError: 'dict_values' object is not subscriptable",
       "AttributeError: 'dict_keys' object has no attribute 'append'"])
check("views in collections.abc", [isinstance(d.keys(), collections.abc.KeysView), isinstance(d.items(), collections.abc.ItemsView),
                                   isinstance(d.values(), collections.abc.ValuesView), isinstance(d.keys(), collections.abc.Set),
                                   isinstance(d.values(), collections.abc.Set), isinstance(iter(d.keys()), collections.abc.Iterator),
                                   isinstance(d.keys(), collections.abc.MappingView)],
      [True, True, True, True, False, True, True])
check("json.dumps of a view is a TypeError", [err(lambda: json.dumps(d.keys())), json.dumps(list(d.keys()))],
      ["TypeError: Object of type dict_keys is not JSON serializable", '["a", "b"]'])
check("keys of other types keep their type", [list({1: "a", (2, 3): "b", None: "c"}.keys()), list({1.5: 0}.items())],
      [[1, (2, 3), None], [(1.5, 0)]])

# ── zip, map, filter, enumerate, reversed: lazy iterators ────────────────────
check("their types", [type(zip([1], [2])).__name__, type(map(str, [1])).__name__, type(filter(None, [1])).__name__,
                      type(enumerate([1])).__name__, type(reversed([1])).__name__, type(reversed((1,))).__name__,
                      type(reversed("ab")).__name__, type(iter([1])).__name__],
      ["zip", "map", "filter", "enumerate", "list_reverseiterator", "reversed", "reversed", "list_iterator"])
check("next() of them", [next(zip([1, 2], [3, 4])), next(map(str, [1])), next(enumerate("ab")), next(filter(None, [0, 0, 5])),
                         next(reversed([1, 2])), next(enumerate("ab", 10))],
      [(1, 3), "1", (0, "a"), 5, 2, (10, "a")])
def exhausted():
    z = zip([1, 2], [3, 4])
    first = list(z)
    return [first, list(z), next(z, "done")]
check("an iterator is used up", exhausted(), [[(1, 3), (2, 4)], [], "done"])
def lazily():
    log = []
    m = map(lambda x: log.append(x) or x * 10, [1, 2, 3])
    before = len(log)
    one = next(m)
    return [before, one, list(log), list(m), list(log)]
check("map calls its function only when asked", lazily(), [0, 10, [1], [20, 30], [1, 2, 3]])
check("as lists", [list(zip("abc", range(10))), dict(zip(["a", "b"], [1, 2])), list(enumerate(["a", "b"], start=1)),
                   list(enumerate(["a"], 5)), list(filter(lambda x: x > 1, [1, 2, 3])), list(map(lambda a, b: a + b, [1, 2], [10, 20, 30])),
                   list(zip()), list(zip({"a": 1})), "".join(reversed("abc")), "".join(map(str, range(3))),
                   list(reversed((1, 2, 3))), list(enumerate(range(2), 10 ** 20))],
      [[("a", 0), ("b", 1), ("c", 2)], {"a": 1, "b": 2}, [(1, "a"), (2, "b")], [(5, "a")], [2, 3], [11, 22],
       [], [("a",)], "cba", "012", [3, 2, 1], [(10 ** 20, 0), (10 ** 20 + 1, 1)]])
check("zip(strict=True)", [list(zip([1, 2], [3, 4], strict=True)), err(lambda: list(zip([1, 2], [3], strict=True))),
                           err(lambda: list(zip([1], [3, 4], strict=True))), err(lambda: list(zip([1], [1, 2], [1, 2], strict=True))),
                           err(lambda: list(zip([1, 2], [1, 2], [1], strict=True)))],
      [[(1, 3), (2, 4)], "ValueError: zip() argument 2 is shorter than argument 1",
       "ValueError: zip() argument 2 is longer than argument 1", "ValueError: zip() argument 2 is longer than argument 1",
       "ValueError: zip() argument 3 is shorter than arguments 1-2"])
def rev_live():
    xs = [1, 2, 3]
    r = reversed(xs)
    a = next(r)
    xs[0] = 7
    rest = list(r)
    r2 = reversed(xs)
    next(r2)
    xs.pop()
    xs.pop()
    return [a, rest, list(r2)]
check("reversed(list) reads the list as it is", rev_live(), [3, [2, 7], []])
def gen():
    yield 1
check("what cannot be reversed", [err(lambda: reversed({1, 2})), err(lambda: reversed(gen())), err(lambda: reversed(5))],
      ["TypeError: 'set' object is not reversible", "TypeError: 'generator' object is not reversible",
       "TypeError: 'int' object is not reversible"])
check("they are not lists", [err(lambda: len(zip([1], [2]))), err(lambda: zip([1], [2])[0]), err(lambda: map(str, [1])[0]),
                             err(lambda: len(reversed([1])))],
      ["TypeError: object of type 'zip' has no len()", "TypeError: 'zip' object is not subscriptable",
       "TypeError: 'map' object is not subscriptable", "TypeError: object of type 'list_reverseiterator' has no len()"])
m1 = map(str, [1])
check("an iterator is its own iterator", [iter(m1) is m1, err(lambda: map(str)), err(lambda: filter(None))],
      [True, "TypeError: map() must have at least two arguments.", "TypeError: filter expected 2 arguments, got 1"])
check("they are Iterators", [isinstance(zip(), collections.abc.Iterator), isinstance(map(str, []), collections.abc.Iterator),
                             isinstance(reversed([]), collections.abc.Iterator), isinstance(enumerate([]), collections.abc.Iterator)],
      [True, True, True, True])

# ── Nython only ──────────────────────────────────────────────────────────────
if nython:
    check("`a..b` is still a list", [eval("1..4"), eval("4..1"), eval("0..10..3")], [[1, 2, 3], [4, 3, 2], [0, 3, 6, 9]])
    check("d.entries() is still a list of pairs", {"a": 1}.entries(), [("a", 1)])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT90 PASSED ===")
