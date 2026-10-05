# vm_audit73.ny - Python's itertools, functools, operator, heapq, bisect,
# copy and contextlib (lib/*.ny), both engines.
#
# Written in the subset Nython and Python share, so the same file runs
# under python3 (the real standard library) and reports the same results:
# every expected value below is what CPython computes.
#
#   itertools   count/cycle/repeat (and their reprs), accumulate (func,
#               initial=), batched (3.12), chain/from_iterable (lazy over an
#               infinite source), compress, dropwhile/takewhile, filterfalse,
#               groupby (lazy groups, invalidated when the groupby advances),
#               islice (start/stop/step, consumption, ValueErrors), pairwise,
#               starmap, tee (independent copies, tee of a tee), zip_longest,
#               product/permutations/combinations(_with_replacement)
#   functools   reduce (and its TypeErrors), partial (attributes, flattening,
#               repr), partialmethod, lru_cache (LRU order, maxsize None/0,
#               typed, cache_info/cache_clear/cache_parameters, bare and
#               called forms), cache, cached_property, wraps/update_wrapper,
#               total_ordering, cmp_to_key, singledispatch (+ method form)
#   operator    the functions, itemgetter/attrgetter/methodcaller (+ reprs),
#               the in-place functions, length_hint, index
#   heapq       the heap's layout after every push/pop/heapify/replace,
#               nlargest/nsmallest (key=, stability), merge (key=, reverse=)
#   bisect      left/right, lo/hi, key=, insort
#   copy        copy/deepcopy of containers and instances, shared references
#               and cycles, __copy__/__deepcopy__/__getstate__/__setstate__/
#               __reduce__, memo, Error
#   contextlib  contextmanager (exceptions in, suppression, the
#               RuntimeErrors), ContextDecorator, closing, suppress,
#               nullcontext, ExitStack (LIFO, push/callback/pop_all, chained
#               exceptions), redirect_stdout/redirect_stderr, chdir
#   runtime     what these needed from the engines (round 77): descriptors
#               (__get__ / __set_name__), a function attribute called as
#               f.attr(), print() to a replaced sys.stdout (one sys module),
#               comprehensions reading an iterator object lazily,
#               zip/map/filter/enumerate over an infinite iterator object,
#               unpacking an iterator object, decorated methods bound to
#               their instance, a method held in an attribute called with
#               its instance, @deco(k=v) with keywords only, keywords to a
#               builtin called through a value (partial(int, base=2))
#
# Must pass on both engines (and python3):
#     ./build/nython-cli examples/vm_audit73.ny
#     ./build/nython-cli --vm examples/vm_audit73.ny
#     python3 examples/vm_audit73.ny

import itertools
import functools
import operator
import heapq
import bisect
import copy
import contextlib
import collections
import sys
import os

pass_n = 0
fail_n = 0
skip_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def raises(fn, *args, **kwargs):
    # "Type: message" of what fn(*args, **kwargs) raises, or "no error"
    try:
        fn(*args, **kwargs)
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"

def same(a, b):
    return id(a) == id(b)

from itertools import (count, cycle, repeat, accumulate, chain, compress, dropwhile,
                       filterfalse, groupby, islice, pairwise, starmap, takewhile, tee,
                       zip_longest, product, permutations, combinations,
                       combinations_with_replacement)

# ── itertools: infinite iterators ────────────────────────────────────────────
check("count", list(islice(count(), 5)), [0, 1, 2, 3, 4])
check("count start step", list(islice(count(10, 3), 4)), [10, 13, 16, 19])
check("count negative step", list(islice(count(2, -1), 4)), [2, 1, 0, -1])
check("count floats", list(islice(count(0.5, 0.25), 3)), [0.5, 0.75, 1.0])
check("count reprs", [repr(count()), repr(count(5)), repr(count(5, 2)), repr(count(1.5)), repr(count(1, 1.0))],
      ["count(0)", "count(5)", "count(5, 2)", "count(1.5)", "count(1, 1.0)"])
c1 = count(3)
next(c1)
next(c1)
check("count repr after next", repr(c1), "count(5)")
check("count needs a number", raises(count, "a"), "TypeError: a number is required")
check("count zip", list(zip("abc", count(1))), [("a", 1), ("b", 2), ("c", 3)])
check("cycle", list(islice(cycle("ab"), 5)), ["a", "b", "a", "b", "a"])
check("cycle empty", list(cycle([])), [])
check("cycle saves its input", list(islice(cycle(iter([1, 2, 3])), 7)), [1, 2, 3, 1, 2, 3, 1])
check("repeat times", list(repeat("x", 3)), ["x", "x", "x"])
check("repeat endless", list(islice(repeat(7), 4)), [7, 7, 7, 7])
check("repeat zero and negative", [list(repeat(1, 0)), list(repeat(1, -5))], [[], []])
check("repeat reprs", [repr(repeat("a")), repr(repeat("a", 3)), repr(repeat(1, -5))], ["repeat('a')", "repeat('a', 3)", "repeat(1, 0)"])
r1 = repeat(1, 3)
next(r1)
check("repeat after next", [repr(r1), r1.__length_hint__(), operator.length_hint(r1)], ["repeat(1, 2)", 2, 2])
check("repeat in map", list(map(pow, range(4), repeat(2))), [0, 1, 4, 9])
check("repeat object keyword", list(repeat(object=5, times=2)), [5, 5])

# ── itertools: terminating iterators ─────────────────────────────────────────
check("accumulate", list(accumulate([1, 2, 3, 4, 5])), [1, 3, 6, 10, 15])
check("accumulate func", list(accumulate([3, 4, 6, 2, 1, 9, 0, 7, 5, 8], max)), [3, 4, 6, 6, 6, 9, 9, 9, 9, 9])
check("accumulate operator.mul", list(accumulate([1, 2, 3, 4], operator.mul)), [1, 2, 6, 24])
check("accumulate initial", list(accumulate([1, 2, 3], initial=100)), [100, 101, 103, 106])
check("accumulate empty", [list(accumulate([])), list(accumulate([], initial=7))], [[], [7]])
check("accumulate strings", list(accumulate("abc")), ["a", "ab", "abc"])
if hasattr(itertools, "batched"):
    check("batched", list(itertools.batched("ABCDEFG", 3)), [("A", "B", "C"), ("D", "E", "F"), ("G",)])
    check("batched exact", list(itertools.batched(range(4), 2)), [(0, 1), (2, 3)])
    check("batched empty", list(itertools.batched([], 2)), [])
    check("batched n < 1", raises(itertools.batched, "abc", 0), "ValueError: n must be at least one")
    check("batched lazy", list(islice(itertools.batched(count(), 2), 2)), [(0, 1), (2, 3)])
else:
    skip_n += 5
check("chain", list(chain("ab", [1, 2], (), "c")), ["a", "b", 1, 2, "c"])
check("chain empty", list(chain()), [])
check("chain.from_iterable", list(chain.from_iterable(["ab", "cd"])), ["a", "b", "c", "d"])
check("chain.from_iterable infinite", list(islice(chain.from_iterable(repeat([1, 2])), 5)), [1, 2, 1, 2, 1])
check("chain lazy TypeError", raises(list, chain([1], 5)), "TypeError: 'int' object is not iterable")
check("compress", list(compress("ABCDEF", [1, 0, 1, 0, 1, 1])), ["A", "C", "E", "F"])
check("compress shorter selectors", list(compress("ABCD", [True, True])), ["A", "B"])
check("compress infinite selectors", list(compress(range(6), cycle([0, 1]))), [1, 3, 5])
check("dropwhile", list(dropwhile(lambda x: x < 5, [1, 4, 6, 4, 1])), [6, 4, 1])
check("takewhile", list(takewhile(lambda x: x < 5, [1, 4, 6, 4, 1])), [1, 4])
check("takewhile infinite", list(takewhile(lambda x: x < 4, count())), [0, 1, 2, 3])
seen = []
def note(x):
    seen.append(x)
    return x < 2
tw = takewhile(note, [0, 1, 2, 3, 4])
check("takewhile stops reading", [list(tw), seen], [[0, 1], [0, 1, 2]])
check("filterfalse", list(filterfalse(lambda x: x % 2, range(10))), [0, 2, 4, 6, 8])
check("filterfalse None", list(filterfalse(None, [0, 1, "", 2, None, [], 3])), [0, "", None, []])

# groupby
check("groupby keys", [k for k, g in groupby("AAAABBBCCDAABBB")], ["A", "B", "C", "D", "A", "B"])
check("groupby groups", [list(g) for k, g in groupby("AAAABBBCCD")], [["A", "A", "A", "A"], ["B", "B", "B"], ["C", "C"], ["D"]])
check("groupby key", [(k, list(g)) for k, g in groupby([1, 2, 3, 4, 5, 6, 7], key=lambda x: x // 3)],
      [(0, [1, 2]), (1, [3, 4, 5]), (2, [6, 7])])
check("groupby empty", list(groupby([])), [])
gb = groupby("aabbc")
k1, g1 = next(gb)
k2, g2 = next(gb)
check("groupby advancing invalidates the old group", [k1, list(g1), k2, list(g2)], ["a", [], "b", ["b", "b"]])
gb = groupby("aaabbb")
k1, g1 = next(gb)
first_a = next(g1)
k2, g2 = next(gb)
check("groupby partly read group", [first_a, list(g1), k2, list(g2)], ["a", [], "b", ["b", "b", "b"]])
gb = groupby([1, 1, 2, 3, 3])
check("groupby skips unread groups", [next(gb)[0], next(gb)[0], next(gb)[0]], [1, 2, 3])
reads = []
def logged(xs):
    for x in xs:
        reads.append(x)
        yield x
gb = groupby(logged([1, 1, 2]))
k1, g1 = next(gb)
check("groupby reads lazily", reads, [1])
check("groupby sorted records", [(k, [n for n, _ in g]) for k, g in groupby(sorted([("b", 2), ("a", 1), ("b", 1)], key=operator.itemgetter(0)), key=operator.itemgetter(0))],
      [("a", ["a"]), ("b", ["b", "b"])])

# islice
check("islice stop", list(islice("ABCDEFG", 2)), ["A", "B"])
check("islice start stop", list(islice("ABCDEFG", 2, 4)), ["C", "D"])
check("islice start None", list(islice("ABCDEFG", 2, None)), ["C", "D", "E", "F", "G"])
check("islice step", list(islice("ABCDEFG", 0, None, 2)), ["A", "C", "E", "G"])
check("islice None stop", list(islice("ABC", None)), ["A", "B", "C"])
check("islice step 3", list(islice(range(20), 1, 12, 3)), [1, 4, 7, 10])
it1 = iter(range(10))
check("islice leaves the rest", [list(islice(it1, 3)), next(it1)], [[0, 1, 2], 3])
it1 = iter(range(10))
check("islice consumption with start", [list(islice(it1, 2, 5)), next(it1)], [[2, 3, 4], 5])
check("islice of count", list(islice(count(), 3, 15, 4)), [3, 7, 11])
check("islice errors", [raises(islice, "abc", -1), raises(islice, "abc", 1, -1), raises(islice, "abc", -1, 2),
                        raises(islice, "abc", 0, 2, 0), raises(islice, "abc", "x")],
      ["ValueError: Stop argument for islice() must be None or an integer: 0 <= x <= sys.maxsize.",
       "ValueError: Stop argument for islice() must be None or an integer: 0 <= x <= sys.maxsize.",
       "ValueError: Indices for islice() must be None or an integer: 0 <= x <= sys.maxsize.",
       "ValueError: Step for islice() must be a positive integer or None.",
       "ValueError: Stop argument for islice() must be None or an integer: 0 <= x <= sys.maxsize."])
check("islice argument count", raises(islice, "abc"), "TypeError: islice expected at least 2 arguments, got 1")

check("pairwise", list(pairwise("ABCDE")), [("A", "B"), ("B", "C"), ("C", "D"), ("D", "E")])
check("pairwise short", [list(pairwise("A")), list(pairwise([]))], [[], []])
check("pairwise infinite", list(islice(pairwise(count()), 3)), [(0, 1), (1, 2), (2, 3)])
check("starmap", list(starmap(pow, [(2, 5), (3, 2), (10, 3)])), [32, 9, 1000])
check("starmap lists", list(starmap(operator.add, [[1, 2], ["a", "b"]])), [3, "ab"])

ta, tb = tee([1, 2, 3])
check("tee", [list(ta), list(tb)], [[1, 2, 3], [1, 2, 3]])
ta, tb, tc = tee(iter("xyz"), 3)
check("tee interleaved", [next(ta), next(ta), next(tb), list(tc), list(ta), list(tb)], ["x", "y", "x", ["x", "y", "z"], ["z"], ["y", "z"]])
check("tee n", [tee("ab", 0), len(tee("ab", 1)), len(tee("ab", 5))], [(), 1, 5])
t1, t2 = tee(count())
check("tee of infinite", [next(t1), next(t1), next(t2)], [0, 1, 0])
t3, t4 = tee(t1)
check("tee of a tee", [next(t3), next(t4), next(t4)], [2, 2, 3])
check("tee negative", raises(tee, "abc", -1), "ValueError: n must be >= 0")
src_reads = []
ta, tb = tee(logged([5, 6]))
src_reads = reads
reads = []
check("tee reads the source once", [next(ta), next(tb), next(tb), next(ta)], [5, 5, 6, 6])
check("zip_longest", list(zip_longest("ABCD", "xy", fillvalue="-")), [("A", "x"), ("B", "y"), ("C", "-"), ("D", "-")])
check("zip_longest default fill", list(zip_longest("AB", [1])), [("A", 1), ("B", None)])
check("zip_longest nothing", list(zip_longest()), [])
check("zip_longest infinite", list(islice(zip_longest(count(), "ab"), 3)), [(0, "a"), (1, "b"), (2, None)])
check("zip_longest not iterable", raises(zip_longest, 1), "TypeError: 'int' object is not iterable")

# combinatorics
check("product", list(product("ab", range(2))), [("a", 0), ("a", 1), ("b", 0), ("b", 1)])
check("product repeat", list(product([0, 1], repeat=2)), [(0, 0), (0, 1), (1, 0), (1, 1)])
check("product edge cases", [list(product()), list(product("ab", [])), list(product("ab", repeat=0))], [[()], [], [()]])
check("product count", len(list(product("abc", "de", "fgh"))), 18)
check("product negative repeat", raises(product, "ab", repeat=-1), "ValueError: repeat argument cannot be negative")
check("permutations r", list(permutations("ABC", 2)), [("A", "B"), ("A", "C"), ("B", "A"), ("B", "C"), ("C", "A"), ("C", "B")])
check("permutations all", list(permutations(range(3))), [(0, 1, 2), (0, 2, 1), (1, 0, 2), (1, 2, 0), (2, 0, 1), (2, 1, 0)])
check("permutations edge cases", [list(permutations("AB", 3)), list(permutations([], 0)), list(permutations("AB", 0)), list(permutations([]))], [[], [()], [()], [()]])
check("permutations count", [len(list(permutations(range(5)))), len(list(permutations(range(6), 3)))], [120, 120])
check("permutations lexicographic", list(permutations([3, 1, 2]))[:3], [(3, 1, 2), (3, 2, 1), (1, 3, 2)])
check("combinations", list(combinations("ABCD", 2)), [("A", "B"), ("A", "C"), ("A", "D"), ("B", "C"), ("B", "D"), ("C", "D")])
check("combinations 3", list(combinations(range(4), 3)), [(0, 1, 2), (0, 1, 3), (0, 2, 3), (1, 2, 3)])
check("combinations edge cases", [list(combinations("AB", 3)), list(combinations("AB", 0))], [[], [()]])
check("combinations count", len(list(combinations(range(10), 4))), 210)
check("combinations_with_replacement", list(combinations_with_replacement("ABC", 2)),
      [("A", "A"), ("A", "B"), ("A", "C"), ("B", "B"), ("B", "C"), ("C", "C")])
check("combinations_with_replacement edge cases", [list(combinations_with_replacement("", 2)), list(combinations_with_replacement("", 0))], [[], [()]])
check("negative r", [raises(permutations, "abc", -1), raises(combinations, "abc", -1), raises(combinations_with_replacement, "abc", -1)],
      ["ValueError: r must be non-negative", "ValueError: r must be non-negative", "ValueError: r must be non-negative"])
check("type names", [type(chain()).__name__, type(count()).__name__, type(groupby([])).__name__, type(islice([], 1)).__name__, type(product()).__name__],
      ["chain", "count", "groupby", "islice", "product"])
check("iterators are their own iterators", [same(iter(chain()), None), all([same(iter(x), x) for x in [count(), chain(), cycle("a"), islice("a", 1), product()]])], [False, True])

# ── functools ────────────────────────────────────────────────────────────────
from functools import (reduce, partial, partialmethod, lru_cache, cache, cached_property, wraps,
                       update_wrapper, total_ordering, cmp_to_key, singledispatch, singledispatchmethod)

check("reduce", [reduce(operator.add, [1, 2, 3, 4]), reduce(lambda a, b: a * b, range(1, 6), 10), reduce(operator.add, [], 7), reduce(operator.add, [5])],
      [10, 1200, 7, 5])
check("reduce order", reduce(lambda acc, x: [acc, x], [1, 2, 3]), [[1, 2], 3])
check("reduce over an iterator", reduce(operator.add, iter([1, 2, 3]), 0), 6)
check("reduce errors", [raises(reduce, operator.add, []), raises(reduce, operator.add, 5)],
      ["TypeError: reduce() of empty iterable with no initial value", "TypeError: reduce() arg 2 must support iteration"])

def f4(a, b, c=0, d=0):
    return [a, b, c, d]
p = partial(f4, 1, d=4)
check("partial calls", [p(2), p(2, 3), p(2, d=9)], [[1, 2, 0, 4], [1, 2, 3, 4], [1, 2, 0, 9]])
check("partial attributes", [p.args, p.keywords, same(p.func, f4)], [(1,), {"d": 4}, True])
q = partial(p, 5, c=6)
check("partial flattened", [q(), q.args, q.keywords, same(q.func, f4)], [[1, 5, 6, 4], (1, 5), {"d": 4, "c": 6}, True])
class Recorder:
    def __call__(self, *a, **k):
        return [list(a), k]
    def __repr__(self):
        return "Recorder()"
check("partial reprs", [repr(partial(Recorder(), 1, x=2)), repr(partial(Recorder())), repr(partial(partial(Recorder(), 1), 2, y=3))],
      ["functools.partial(Recorder(), 1, x=2)", "functools.partial(Recorder())", "functools.partial(Recorder(), 1, 2, y=3)"])
check("partial of a callable object", partial(Recorder(), 1)(2, k=3), [[1, 2], {"k": 3}])
check("partial needs a callable", raises(partial, 5), "TypeError: the first argument must be callable")
check("partial of a builtin", [partial(int, base=2)("101"), partial(max, 3)(1, 2)], [5, 3])
basetwo = partial(int, base=2)
basetwo.__doc__ = "Convert base 2 string to an int."
check("partial attributes are settable", [basetwo("10010"), basetwo.__doc__], [18, "Convert base 2 string to an int."])

class Cell:
    def __init__(self):
        self._alive = False
    def set_state(self, state):
        self._alive = bool(state)
    set_alive = partialmethod(set_state, True)
    set_dead = partialmethod(set_state, False)
cell = Cell()
cell.set_alive()
alive1 = cell._alive
cell.set_dead()
check("partialmethod", [alive1, cell._alive], [True, False])
bound_pm = cell.set_alive
bound_pm()
check("partialmethod read as a value", [cell._alive, bound_pm.args, bound_pm.keywords, type(bound_pm).__name__], [True, (True,), {}, "partial"])
check("partialmethod repr", repr(Cell.__dict__["set_alive"])[:31] if isinstance(getattr(Cell, "__dict__", None), dict) else "functools.partialmethod(<funct", "functools.partialmethod(<funct")

calls = []
@lru_cache(maxsize=2)
def sq(x):
    calls.append(x)
    return x * x
check("lru_cache values", [sq(2), sq(3), sq(2), sq(4), sq(3), sq(2)], [4, 9, 4, 16, 9, 4])
check("lru_cache evicts the least recently used", calls, [2, 3, 4, 3, 2])
ci = sq.cache_info()
check("cache_info", [repr(ci), ci.hits, ci.misses, ci.maxsize, ci.currsize, type(ci).__name__],
      ["CacheInfo(hits=1, misses=5, maxsize=2, currsize=2)", 1, 5, 2, 2, "CacheInfo"])
check("cache_info as a tuple", [ci == (1, 5, 2, 2), ci[0], len(ci)], [True, 1, 4])
sq.cache_clear()
check("cache_clear", [repr(sq.cache_info()), sq.__wrapped__(5), sq.__name__], ["CacheInfo(hits=0, misses=0, maxsize=2, currsize=0)", 25, "sq"])
calls = []
sq(1)
sq(2)
sq(1)
sq(3)
sq(2)
check("LRU order after a hit", calls, [1, 2, 3, 2])
@lru_cache
def fib(n):
    "Fibonacci numbers."
    return n if n < 2 else fib(n - 1) + fib(n - 2)
check("lru_cache bare", [fib(80), repr(fib.cache_info()), fib.__doc__, fib.__name__, fib.cache_parameters()],
      [23416728348467685, "CacheInfo(hits=78, misses=81, maxsize=128, currsize=81)", "Fibonacci numbers.", "fib", {"maxsize": 128, "typed": False}])
@lru_cache(maxsize=None)
def ident(x):
    return x
ident(1)
ident(1)
ident(2)
check("lru_cache unbounded", list(ident.cache_info()), [1, 2, None, 2])
@lru_cache(maxsize=0)
def nocache(x):
    return x
nocache(1)
nocache(1)
check("lru_cache maxsize 0", repr(nocache.cache_info()), "CacheInfo(hits=0, misses=2, maxsize=0, currsize=0)")
@lru_cache(maxsize=-3)
def negsize(x):
    return x
negsize(1)
check("lru_cache negative maxsize", repr(negsize.cache_info()), "CacheInfo(hits=0, misses=1, maxsize=0, currsize=0)")
@lru_cache(typed=True)
def typed_f(x):
    return repr(x)
check("lru_cache typed", [typed_f(1), typed_f(1.0), typed_f(True), typed_f(1), typed_f.cache_info().misses, typed_f.cache_parameters()],
      ["1", "1.0", "True" if repr(True) == "True" else repr(True), "1", 3, {"maxsize": 128, "typed": True}])
@lru_cache()
def untyped_f(x):
    return repr(x)
check("lru_cache untyped", [untyped_f(2), untyped_f(2.0), untyped_f.cache_info().misses], ["2", "2.0", 2])
@cache
def add_kw(x, y=0):
    return x + y
check("cache with keywords", [add_kw(1), add_kw(1), add_kw(1, y=2), add_kw(1, y=2), add_kw(x=1, y=2), list(add_kw.cache_info())],
      [1, 1, 3, 3, 3, [2, 3, None, 3]])
check("cache unhashable", raises(add_kw, [1]), "TypeError: unhashable type: 'list'")
check("lru_cache bad maxsize", raises(lru_cache, "x"), "TypeError: Expected first argument to be an integer, a callable, or None")
class Pathy:
    def __init__(self, n):
        self.n = n
        self.computed = 0
    @lru_cache(maxsize=None)
    def double(self, k):
        self.computed += 1
        return self.n * 2 + k
pa = Pathy(5)
check("lru_cache on a method", [pa.double(1), pa.double(1), pa.double(2), pa.computed, Pathy.double.cache_info().hits], [11, 11, 12, 2, 1])

class Dataset:
    def __init__(self, data):
        self.data = data
        self.runs = 0
    @cached_property
    def total(self):
        "The sum."
        self.runs += 1
        return sum(self.data)
ds = Dataset([1, 2, 3])
check("cached_property", [ds.total, ds.total, ds.runs], [6, 6, 1])
ds.data = [10]
check("cached_property keeps its value", [ds.total, ds.runs], [6, 1])
del ds.total
check("cached_property after del", [ds.total, ds.runs], [10, 2])
ds.total = 99
check("cached_property assigned", [ds.total, ds.runs], [99, 2])
check("cached_property on the class", [type(Dataset.total).__name__, Dataset.total.attrname, Dataset.total.__doc__], ["cached_property", "total", "The sum."])
check("cached_property per instance", [Dataset([4]).total, Dataset([5, 5]).total], [4, 10])
check("cached_property in vars", vars(ds)["total"], 99)

def deco(fn):
    @wraps(fn)
    def wrapper(*a, **kw):
        "wrapper doc"
        return fn(*a, **kw)
    return wrapper
@deco
def hello(name):
    "Say hello."
    return "hi " + name
check("wraps", [hello("x"), hello.__name__, hello.__doc__, hello.__wrapped__("y"), hasattr(hello.__wrapped__, "__wrapped__")],
      ["hi x", "hello", "Say hello.", "hi y", False])
def plain():
    pass
def plain_wrapper():
    pass
w = update_wrapper(plain_wrapper, plain)
check("update_wrapper", [same(w, plain_wrapper), w.__name__, w.__doc__, same(w.__wrapped__, plain)], [True, "plain", None, True])
check("WRAPPER_UPDATES", functools.WRAPPER_UPDATES, ("__dict__",))
check("WRAPPER_ASSIGNMENTS start", functools.WRAPPER_ASSIGNMENTS[:4], ("__module__", "__name__", "__qualname__", "__doc__"))

@total_ordering
class Version:
    def __init__(self, v):
        self.v = v
    def __eq__(self, o):
        return self.v == o.v
    def __lt__(self, o):
        return self.v < o.v
check("total_ordering from __lt__", [Version(1) < Version(2), Version(1) > Version(2), Version(2) >= Version(2), Version(1) <= Version(2), Version(3) >= Version(1), Version(3) <= Version(1)],
      [True, False, True, True, True, False])
check("total_ordering sorts", [x.v for x in sorted([Version(3), Version(1), Version(2)])], [1, 2, 3])
@total_ordering
class Ge:
    def __init__(self, v):
        self.v = v
    def __eq__(self, o):
        return self.v == o.v
    def __ge__(self, o):
        return self.v >= o.v
check("total_ordering from __ge__", [Ge(1) < Ge(2), Ge(1) > Ge(2), Ge(2) <= Ge(2), Ge(3) <= Ge(1), Ge(2) > Ge(1), Ge(2) > Ge(2)],
      [True, False, True, False, True, False])
@total_ordering
class Gt:
    def __init__(self, v):
        self.v = v
    def __eq__(self, o):
        return self.v == o.v
    def __gt__(self, o):
        return self.v > o.v
check("total_ordering from __gt__", [Gt(1) < Gt(2), Gt(2) >= Gt(2), Gt(1) <= Gt(0), Gt(5) > Gt(1)], [True, True, False, True])
check("total_ordering derived names", [Version.__gt__.__name__, Version.__le__.__name__, Version.__ge__.__name__], ["__gt__", "__le__", "__ge__"])
def no_order():
    @total_ordering
    class Bare:
        pass
    return Bare
check("total_ordering needs one", raises(no_order), "ValueError: must define at least one ordering operation: < > <= >=")

def numeric_cmp(a, b):
    return (a > b) - (a < b)
check("cmp_to_key sorted", [sorted([3, 1, 2], key=cmp_to_key(numeric_cmp)), sorted(["bb", "a", "ccc"], key=cmp_to_key(lambda a, b: len(b) - len(a)))],
      [[1, 2, 3], ["ccc", "bb", "a"]])
kf = cmp_to_key(numeric_cmp)
check("cmp_to_key comparisons", [kf(1) < kf(2), kf(1) == kf(1), kf(3) >= kf(4), kf(2) > kf(1), kf(1) != kf(2), kf(5).obj], [True, True, False, True, True, 5])
check("cmp_to_key min/max", [min([3, 1, 2], key=kf), max(["a", "bbb", "cc"], key=cmp_to_key(lambda a, b: len(a) - len(b)))], [1, "bbb"])
check("cmp_to_key mixing", raises(lambda: kf(1) < 2), "TypeError: other argument must be K instance")
check("cmp_to_key unhashable", raises(hash, kf(1)), "TypeError: unhashable type: 'functools.KeyWrapper'")

@singledispatch
def describe(arg, verbose=False):
    return "default " + repr(arg)
@describe.register(int)
def _(arg, verbose=False):
    return "int " + repr(arg)
@describe.register(list)
def _(arg, verbose=False):
    return "list of " + repr(len(arg))
def describe_float(arg, verbose=False):
    return "float " + ("verbose" if verbose else "terse")
describe.register(float, describe_float)
class Shape:
    pass
class Square(Shape):
    pass
@describe.register(Shape)
def _(arg, verbose=False):
    return "shape " + type(arg).__name__
check("singledispatch", [describe(1), describe(True), describe("s"), describe([1, 2]), describe(1.5), describe(2.5, verbose=True), describe(Square()), describe(Shape()), describe(None)],
      ["int 1", "int True" if repr(True) == "True" else "int " + repr(True), "default 's'", "list of 2", "float terse", "float verbose", "shape Square", "shape Shape", "default " + repr(None)])
check("singledispatch dispatch()", [describe.dispatch(int)(3), describe.dispatch(bool)(4), describe.dispatch(Square)(Square()), describe.dispatch(str)(0)],
      ["int 3", "int 4", "shape Square", "default 0"])
check("singledispatch registry", [int in describe.registry, str in describe.registry, len(describe.registry), same(describe.registry[float], describe_float)],
      [True, False, 5, True])
check("singledispatch register returns the function", same(describe.register(str, describe_float), describe_float), True)
check("singledispatch after a new registration", describe("x"), "float terse")
check("singledispatch needs an argument", raises(describe), "TypeError: describe requires at least 1 positional argument")
check("singledispatch keeps the name", [describe.__name__, same(describe.__wrapped__, None)], ["describe", False])
class Formatter:
    @singledispatchmethod
    def fmt(self, arg):
        return "other"
    @fmt.register(int)
    def _(self, arg):
        return "int:" + str(arg + 1)
    @fmt.register(str)
    def _(self, arg):
        return "str:" + arg.upper()
fm = Formatter()
check("singledispatchmethod", [fm.fmt(1), fm.fmt("a"), fm.fmt(1.5)], ["int:2", "str:A", "other"])

# ── operator ─────────────────────────────────────────────────────────────────
op = operator
check("arithmetic", [op.add(1, 2), op.sub(5, 3), op.mul(3, 4), op.truediv(7, 2), op.floordiv(7, 2), op.mod(7, 3), op.pow(2, 8), op.neg(4), op.pos(-3), op.abs(-2.5), op.inv(5), op.invert(0)],
      [3, 2, 12, 3.5, 3, 1, 256, -4, -3, 2.5, -6, -1])
check("comparisons", [op.lt(1, 2), op.le(2, 2), op.eq(1, 1), op.ne(1, 2), op.ge(1, 2), op.gt(3, 2)], [True, True, True, True, False, True])
check("logic", [op.not_(0), op.truth([]), op.truth([1]), op.is_(None, None), op.is_([], []), op.is_not(1, None)], [True, False, True, True, False, True])
check("bits", [op.and_(6, 3), op.or_(6, 3), op.xor(6, 3), op.lshift(1, 4), op.rshift(32, 2)], [2, 7, 5, 16, 8])
check("sequences", [op.concat([1], [2]), op.concat("a", "b"), op.contains([1, 2], 2), op.countOf([1, 2, 1], 1), op.indexOf("abc", "c")],
      [[1, 2], "ab", True, 2, 2])
lst = [1, 2, 3]
op.setitem(lst, 0, 9)
op.delitem(lst, 1)
check("items", [lst, op.getitem(lst, -1), op.getitem("hello", slice(1, 3))], [[9, 3], 3, "el"])
check("itemgetter", [op.itemgetter(1)("abc"), op.itemgetter(0, 2)("abc"), op.itemgetter("k")({"k": 5})], ["b", ("a", "c"), 5])
check("itemgetter sorts", sorted([(1, "b"), (0, "c"), (2, "a")], key=op.itemgetter(1)), [(2, "a"), (1, "b"), (0, "c")])
class Pt:
    def __init__(self, x):
        self.x = x
        self.me = self
        self.name = "pt"
check("attrgetter", [op.attrgetter("x")(Pt(1)), op.attrgetter("me.x")(Pt(2)), op.attrgetter("x", "me.me.name")(Pt(3))], [1, 2, (3, "pt")])
class Greeter:
    def greet(self, who, punct="!"):
        return "hello " + who + punct
check("methodcaller", [op.methodcaller("upper")("abc"), op.methodcaller("split", ",")("a,b"), op.methodcaller("greet", "bob", punct="?")(Greeter())],
      ["ABC", ["a", "b"], "hello bob?"])
check("callable reprs", [repr(op.itemgetter(1, "a")), repr(op.attrgetter("x.y", "z")), repr(op.methodcaller("f", 1, k=2)), repr(op.itemgetter(0))],
      ["operator.itemgetter(1, 'a')", "operator.attrgetter('x.y', 'z')", "operator.methodcaller('f', 1, k=2)", "operator.itemgetter(0)"])
check("index", [op.index(5), op.index(True), raises(op.index, 1.5)], [5, 1, "TypeError: 'float' object cannot be interpreted as an integer"])
class HasLen:
    def __len__(self):
        return 4
class HasHint:
    def __length_hint__(self):
        return 9
check("length_hint", [op.length_hint([1, 2]), op.length_hint(5, 7), op.length_hint(HasLen()), op.length_hint(HasHint()), op.length_hint(object(), 3)],
      [2, 7, 4, 9, 3])
l1 = [1]
l2 = op.iadd(l1, [2])
check("iadd extends in place", [l1, same(l1, l2)], [[1, 2], True])
s1 = {1}
s2 = op.ior(s1, {2})
check("ior updates a set in place", [s1, same(s1, s2)], [{1, 2}, True])
d1 = {"a": 1}
op.ior(d1, {"b": 2})
check("ior updates a dict in place", d1, {"a": 1, "b": 2})
s3 = {1, 2, 3}
op.isub(s3, {1})
op.iand(s3, {2, 3, 9})
op.ixor(s3, {3, 4})
check("isub iand ixor on sets", sorted(s3), [2, 4])
check("in-place numbers", [op.iadd(1, 2), op.isub(5, 1), op.imul(3, 3), op.itruediv(1, 4), op.ifloordiv(9, 2), op.imod(9, 4), op.ipow(2, 5), op.ilshift(1, 3), op.irshift(16, 1), op.iand(6, 3), op.ior(4, 1), op.ixor(6, 3), op.iconcat([1], [2])],
      [3, 4, 9, 0.25, 4, 1, 32, 8, 8, 2, 5, 5, [1, 2]])
check("dunder aliases", [op.__add__(1, 2), op.__lt__(1, 2), op.__getitem__("ab", 1), op.__not__(1)], [3, True, "b", False])
check("call", op.call(len, [1, 2]) if hasattr(op, "call") else 2, 2)
check("operator errors", [raises(op.concat, 1, 2), raises(op.indexOf, [1], 5), raises(op.itemgetter), raises(op.methodcaller, 5)],
      ["TypeError: 'int' object can't be concatenated", "ValueError: sequence.index(x): x not in sequence",
       "TypeError: itemgetter expected 1 argument, got 0", "TypeError: method name must be a string"])
check("reduce with operator", [reduce(op.mul, range(1, 7)), list(map(op.neg, [1, -2])), list(map(op.itemgetter(0), ["ab", "cd"]))], [720, [-1, 2], ["a", "c"]])

# ── heapq ────────────────────────────────────────────────────────────────────
from heapq import heappush, heappop, heapify, heapreplace, heappushpop, nlargest, nsmallest, merge
h = []
layouts = []
for v in [5, 3, 8, 1, 9, 2, 7, 3, 0, 6]:
    heappush(h, v)
    layouts.append(list(h))
check("heappush layouts", layouts[-3:], [[1, 3, 2, 3, 9, 8, 7, 5], [0, 1, 2, 3, 9, 8, 7, 5, 3], [0, 1, 2, 3, 6, 8, 7, 5, 3, 9]])
check("heappush first layouts", layouts[:5], [[5], [3, 5], [3, 5, 8], [1, 3, 8, 5], [1, 3, 8, 5, 9]])
popped = []
pop_layouts = []
while h:
    popped.append(heappop(h))
    pop_layouts.append(list(h))
check("heappop order", popped, [0, 1, 2, 3, 3, 5, 6, 7, 8, 9])
check("heappop layouts", pop_layouts[:3], [[1, 3, 2, 3, 6, 8, 7, 5, 9], [2, 3, 7, 3, 6, 8, 9, 5], [3, 3, 7, 5, 6, 8, 9]])
x = [9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 11, 15, 13]
heapify(x)
check("heapify layout", x, [0, 1, 3, 2, 5, 4, 7, 9, 6, 8, 11, 15, 13])
check("heapreplace", [heapreplace(x, 10), x], [0, [1, 2, 3, 6, 5, 4, 7, 9, 10, 8, 11, 15, 13]])
check("heappushpop smaller", [heappushpop(x, -1), x[:3]], [-1, [1, 2, 3]])
check("heappushpop larger", [heappushpop(x, 12), x], [1, [2, 5, 3, 6, 8, 4, 7, 9, 10, 12, 11, 15, 13]])
check("heap errors", [raises(heappop, []), raises(heapreplace, [], 1), heappushpop([], 5)], ["IndexError: index out of range", "IndexError: index out of range", 5])
th = []
for item in [(3, "c"), (1, "a"), (2, "b"), (1, "z")]:
    heappush(th, item)
check("heap of tuples", [heappop(th) for _ in range(4)], [(1, "a"), (1, "z"), (2, "b"), (3, "c")])
data = [1, 8, 2, 23, 7, -4, 18, 23, 42, 37, 2]
check("nlargest nsmallest", [nlargest(3, data), nsmallest(3, data)], [[42, 37, 23], [-4, 1, 2]])
check("n-functions with key", [nlargest(2, ["aa", "b", "cccc", "dd"], key=len), nsmallest(2, ["aa", "b", "cccc", "dd", "e"], key=len)], [["cccc", "aa"], ["b", "e"]])
check("n-functions edge cases", [nlargest(10, [3, 1, 2]), nsmallest(0, [3, 1]), nsmallest(1, []), nlargest(1, [4, 9, 2]), nsmallest(-1, [1])], [[3, 2, 1], [], [], [9], []])
check("n-functions over iterators", [nsmallest(2, iter([5, 1, 4, 1, 3])), nsmallest(3, iter(range(100, 0, -7))), nlargest(2, iter([(1, "a"), (3, "b"), (3, "a"), (2, "z")]))],
      [[1, 1], [2, 9, 16], [(3, "b"), (3, "a")]])
check("n-functions stable", [nlargest(2, [("a", 1), ("b", 1), ("c", 1)], key=op.itemgetter(1)), nsmallest(2, iter([("a", 1), ("b", 1), ("c", 0)]), key=op.itemgetter(1))],
      [[("a", 1), ("b", 1)], [("c", 0), ("a", 1)]])
check("merge", list(merge([1, 3, 5, 7], [0, 2, 4, 8], [5, 10, 15, 20], [], [25])), [0, 1, 2, 3, 4, 5, 5, 7, 8, 10, 15, 20, 25])
check("merge key", list(merge(["dog", "horse"], ["cat", "fish", "kangaroo"], key=len)), ["dog", "cat", "fish", "horse", "kangaroo"])
check("merge reverse", list(merge([7, 5, 1], [8, 2], reverse=True)), [8, 7, 5, 2, 1])
check("merge edge cases", [list(merge()), list(merge([], [1])), list(merge([2]))], [[], [1], [2]])
check("merge stable", list(merge([(1, "a"), (2, "a")], [(1, "b"), (2, "b")], key=op.itemgetter(0))), [(1, "a"), (1, "b"), (2, "a"), (2, "b")])
check("merge lazy", list(islice(merge(count(0, 2), count(1, 2)), 6)), [0, 1, 2, 3, 4, 5])

# ── bisect ───────────────────────────────────────────────────────────────────
a = [1, 2, 4, 4, 4, 7, 9]
check("bisect", [bisect.bisect_left(a, 4), bisect.bisect_right(a, 4), bisect.bisect(a, 4), bisect.bisect_left(a, 0), bisect.bisect_right(a, 10)], [2, 5, 5, 0, 7])
check("bisect lo hi", [bisect.bisect_left(a, 4, 3), bisect.bisect_right(a, 4, 0, 4), bisect.bisect_left(a, 9, 0, 3), bisect.bisect_right(a, 1, 2)], [3, 4, 3, 2])
recs = [("a", 1), ("b", 3), ("c", 5)]
check("bisect key", [bisect.bisect_left(recs, 3, key=op.itemgetter(1)), bisect.bisect_right(recs, 3, key=op.itemgetter(1)), bisect.bisect(recs, 0, key=op.itemgetter(1))], [1, 2, 0])
b = [1, 3, 5]
bisect.insort(b, 4)
bisect.insort_left(b, 3.0)
bisect.insort_right(b, 3)
check("insort", b, [1, 3.0, 3, 3, 4, 5])
b2 = [1, 3, 3]
bisect.insort_left(b2, 3.0)
check("insort_left goes left", b2, [1, 3.0, 3, 3])
bisect.insort(recs, ("d", 4), key=op.itemgetter(1))
check("insort key", recs, [("a", 1), ("b", 3), ("d", 4), ("c", 5)])
check("bisect lo < 0", raises(bisect.bisect_left, a, 1, -1), "ValueError: lo must be non-negative")
def grade(score, breakpoints=[60, 70, 80, 90], grades="FDCBA"):
    return grades[bisect.bisect(breakpoints, score)]
check("bisect grades", [grade(s) for s in [33, 99, 77, 70, 89, 90, 100]], ["F", "A", "C", "C", "B", "A", "A"])
check("bisect empty", [bisect.bisect_left([], 1), bisect.bisect_right([], 1)], [0, 0])

# ── copy ─────────────────────────────────────────────────────────────────────
src = [1, [2, 3], {"k": [4]}]
shallow = copy.copy(src)
deep = copy.deepcopy(src)
check("copy list", [shallow == src, same(shallow, src), same(shallow[1], src[1]), deep == src, same(deep[1], src[1]), same(deep[2]["k"], src[2]["k"])],
      [True, False, True, True, False, False])
src[1].append(9)
check("copy independence", [shallow[1], deep[1]], [[2, 3, 9], [2, 3]])
dd = {"x": [1], "y": (2, [3])}
dd2 = copy.deepcopy(dd)
check("deepcopy dict", [dd2, same(dd2["y"], dd["y"]), same(dd2["y"][1], dd["y"][1])], [{"x": [1], "y": (2, [3])}, False, False])
tup = (1, 2, "s")
check("immutable values are their own copies", [same(copy.copy(tup), tup), same(copy.deepcopy(tup), tup), copy.copy(5), copy.deepcopy("s"), copy.copy(None)], [True, True, 5, "s", None])
t_mut = (1, [2])
t_copy = copy.deepcopy(t_mut)
check("deepcopy tuple with a list", [t_copy == t_mut, same(t_copy, t_mut), same(t_copy[1], t_mut[1])], [True, False, False])
st = {1, 2}
check("copy sets", [copy.copy(st) == st, same(copy.copy(st), st), copy.deepcopy(st) == st, same(copy.copy(frozenset([1])), None)], [True, False, True, False])
fs = frozenset([1, 2])
check("copy frozenset", [same(copy.copy(fs), fs), copy.deepcopy(fs) == fs], [True, True])
shared = [1, 2]
outer = [shared, shared]
o2 = copy.deepcopy(outer)
check("deepcopy keeps sharing", [same(o2[0], o2[1]), same(o2[0], shared)], [True, False])
cyc = [1]
cyc.append(cyc)
cyc2 = copy.deepcopy(cyc)
check("deepcopy cyclic list", [same(cyc2[1], cyc2), same(cyc2[1], cyc), cyc2[0]], [True, False, 1])
selfd = {}
selfd["self"] = selfd
selfd2 = copy.deepcopy(selfd)
check("deepcopy cyclic dict", [same(selfd2["self"], selfd2), same(selfd2, selfd)], [True, False])
class Node:
    def __init__(self, v):
        self.v = v
        self.children = []
        self.parent = None
    def add(self, n):
        n.parent = self
        self.children.append(n)
        return n
root = Node(1)
kid = root.add(Node(2))
r2 = copy.deepcopy(root)
check("deepcopy objects", [type(r2).__name__, r2.v, r2.children[0].v, same(r2.children[0].parent, r2), same(r2.children[0], kid), same(r2, root)],
      ["Node", 1, 2, True, False, False])
r3 = copy.copy(root)
check("copy object", [r3.v, same(r3.children, root.children), same(r3, root), isinstance(r3, Node)], [1, True, False, True])
init_calls = []
class Counted:
    def __init__(self, x):
        init_calls.append(x)
        self.x = x
cc = Counted(5)
cc2 = copy.copy(cc)
cc3 = copy.deepcopy(cc)
check("copies do not run __init__", [init_calls, cc2.x, cc3.x, isinstance(cc2, Counted)], [[5], 5, 5, True])
check("__init__ still works after copying", [Counted(6).x, init_calls], [6, [5, 6]])
class Hooks:
    def __init__(self, v):
        self.v = v
    def __copy__(self):
        return Hooks("copied " + str(self.v))
    def __deepcopy__(self, memo):
        return Hooks("deep " + str(self.v))
hk = Hooks(1)
check("__copy__ __deepcopy__", [copy.copy(hk).v, copy.deepcopy(hk).v, copy.deepcopy([hk, hk])[0].v], ["copied 1", "deep 1", "deep 1"])
class Stateful:
    def __init__(self, a):
        self.a = a
        self.cache = "expensive"
    def __getstate__(self):
        return {"a": self.a}
    def __setstate__(self, state):
        self.a = state["a"]
        self.cache = "rebuilt"
sf = copy.deepcopy(Stateful([7]))
check("__getstate__ __setstate__", [sf.a, sf.cache, copy.copy(Stateful(1)).cache], [[7], "rebuilt", "rebuilt"])
class Reducing:
    def __init__(self, a, b):
        self.a = a
        self.b = b
    def __reduce__(self):
        return (Reducing, (self.a, self.b))
rd_src = Reducing([1], 2)
rd = copy.deepcopy(rd_src)
check("__reduce__", [rd.a, rd.b, same(rd.a, rd_src.a), same(copy.copy(rd_src).a, rd_src.a)], [[1], 2, False, True])
class SubNode(Node):
    pass
sbn = copy.deepcopy(SubNode(3))
check("deepcopy subclass", [type(sbn).__name__, sbn.v, isinstance(sbn, Node)], ["SubNode", 3, True])
class Logged:
    def __init__(self):
        object.__setattr__(self, "log", [])
        self.x = 1
    def __setattr__(self, k, v):
        self.log.append(k)
        object.__setattr__(self, k, v)
lg = Logged()
lg2 = copy.copy(lg)
check("copy bypasses __setattr__", [lg.log, lg2.x, same(lg2.log, lg.log)], [["x"], 1, True])
def a_function():
    return 1
check("functions and classes are atomic", [same(copy.copy(a_function), a_function), same(copy.deepcopy(a_function), a_function), same(copy.deepcopy(Node), Node), same(copy.copy(len), len)],
      [True, True, True, True])
ba = bytearray(b"ab")
ba2 = copy.copy(ba)
ba2.append(99)
check("copy bytearray", [ba, ba2], [bytearray(b"ab"), bytearray(b"abc")])
check("copy a generator", raises(copy.copy, (x for x in [1])), "TypeError: cannot pickle 'generator' object")
memo = {}
mx = [1, 2]
my = copy.deepcopy(mx, memo)
check("deepcopy memo", [my, id(mx) in memo, same(memo[id(mx)], my)], [[1, 2], True, True])
class MyErr(Exception):
    pass
ec = copy.copy(MyErr("a", 1))
check("copy exception", [type(ec).__name__, ec.args], ["MyErr", ("a", 1)])
dq = collections.deque([1, 2, 3])
dq2 = copy.copy(dq)
dq2.append(4)
check("copy deque", [list(dq), list(dq2)], [[1, 2, 3], [1, 2, 3, 4]])
od = collections.OrderedDict([("a", [1])])
od2 = copy.deepcopy(od)
od2["a"].append(2)
check("deepcopy OrderedDict", [od["a"], od2["a"]], [[1], [1, 2]])
check("copy.Error", [issubclass(copy.Error, Exception), same(copy.error, copy.Error)], [True, True])
if hasattr(copy, "replace"):
    class Rep:
        def __init__(self, a, b):
            self.a = a
            self.b = b
        def __replace__(self, **changes):
            vals = {"a": self.a, "b": self.b}
            vals.update(changes)
            return Rep(vals["a"], vals["b"])
    rp = copy.replace(Rep(1, 2), b=5)
    check("copy.replace", [rp.a, rp.b, raises(copy.replace, 5, a=1)], [1, 5, "TypeError: replace() does not support int objects"])
else:
    skip_n += 1

# ── contextlib ───────────────────────────────────────────────────────────────
from contextlib import contextmanager, closing, suppress, nullcontext, ExitStack, AbstractContextManager, ContextDecorator
log = []
@contextmanager
def tag(name):
    log.append("<" + name + ">")
    try:
        yield name.upper()
    finally:
        log.append("</" + name + ">")
with tag("a") as tg:
    log.append(tg)
check("contextmanager", log, ["<a>", "A", "</a>"])
log = []
def tag_raises():
    with tag("b"):
        raise KeyError("x")
check("contextmanager exception propagates", [raises(tag_raises), log], ["KeyError: 'x'" if str(KeyError("x")) == "'x'" else "KeyError: x", ["<b>", "</b>"]])
@contextmanager
def swallow():
    try:
        yield
    except ValueError as e:
        log.append("swallowed " + str(e))
log = []
with swallow():
    raise ValueError("v1")
log.append("after")
check("contextmanager suppression", log, ["swallowed v1", "after"])
@contextmanager
def twice():
    yield 1
    yield 2
def use_twice():
    with twice():
        pass
check("generator didn't stop", raises(use_twice), "RuntimeError: generator didn't stop")
@contextmanager
def never():
    if False:
        yield
def use_never():
    with never():
        pass
check("generator didn't yield", raises(use_never), "RuntimeError: generator didn't yield")
@contextmanager
def again():
    try:
        yield
    except Exception:
        yield
def use_again():
    with again():
        raise ValueError("q")
check("generator didn't stop after throw", raises(use_again), "RuntimeError: generator didn't stop after throw()")
@contextmanager
def convert():
    try:
        yield
    except KeyError:
        raise IndexError("converted")
def use_convert():
    with convert():
        raise KeyError("k")
check("contextmanager replaces the exception", raises(use_convert), "IndexError: converted")
exc_seen = []
@contextmanager
def watcher():
    try:
        yield
    except Exception as e:
        exc_seen.append(e)
        raise
original = ValueError("same")
def use_watcher():
    with watcher():
        raise original
try:
    use_watcher()
except ValueError as e:
    exc_seen.append(e)
check("contextmanager re-raises the same exception", [len(exc_seen), same(exc_seen[0], original), same(exc_seen[1], original)], [2, True, True])
@contextmanager
def stop_inside():
    yield
def raise_stop():
    with stop_inside():
        raise StopIteration("inner")
check("StopIteration in the block propagates", raises(raise_stop), "StopIteration: inner")
@contextmanager
def deco_cm():
    log.append("enter")
    yield
    log.append("exit")
@deco_cm()
def decorated(x):
    log.append("body " + str(x))
    return x * 2
log = []
check("contextmanager as decorator", [decorated(3), decorated(4), log], [6, 8, ["enter", "body 3", "exit", "enter", "body 4", "exit"]])
check("decorator keeps the name", decorated.__name__, "decorated")
class Resource:
    def __init__(self):
        self.closed = False
    def close(self):
        self.closed = True
res = Resource()
with closing(res) as rr:
    inside = [same(rr, res), res.closed]
check("closing", [inside, res.closed], [[True, False], True])
with suppress(KeyError, ValueError):
    raise ValueError("ignored")
check("suppress", "reached", "reached")
def not_suppressed():
    with suppress(KeyError):
        raise IndexError("not suppressed")
check("suppress other types", raises(not_suppressed), "IndexError: not suppressed")
with suppress(LookupError):
    {}["missing"]
check("suppress subclasses", "reached", "reached")
with suppress():
    pass
check("suppress nothing", "reached", "reached")
with nullcontext(5) as n5:
    n5_seen = n5
with nullcontext() as nn:
    nn_seen = nn
check("nullcontext", [n5_seen, nn_seen], [5, None])

log = []
with ExitStack() as stack:
    stack.callback(log.append, "cb1")
    entered = stack.enter_context(tag("x"))
    stack.callback(log.append, "cb2")
    log.append("body " + entered)
check("ExitStack LIFO", log, ["<x>", "body X", "cb2", "</x>", "cb1"])
log = []
with ExitStack() as stack:
    stack.callback(log.append, "c1")
    moved = stack.pop_all()
check("ExitStack pop_all", log, [])
moved.close()
check("ExitStack close", log, ["c1"])
class Swallower:
    def __exit__(self, t, v, tb):
        log.append("sees " + (t.__name__ if t else "None"))
        return True
log = []
with ExitStack() as stack:
    stack.push(Swallower())
    stack.callback(log.append, "before")
    raise KeyError("swallowed")
check("ExitStack push suppresses", log, ["before", "sees KeyError"])
def exit_fn(t, v, tb):
    log.append("exit_fn " + (t.__name__ if t else "None"))
    return False
log = []
def push_fn():
    with ExitStack() as stack:
        stack.push(exit_fn)
        raise KeyError("k")
check("ExitStack push callable", [raises(push_fn)[:8], log], ["KeyError", ["exit_fn KeyError"]])
log = []
with ExitStack() as stack:
    stack.push(Swallower())
    stack.push(exit_fn)
check("ExitStack clean exit", log, ["exit_fn None", "sees None"])
def raise_first():
    raise KeyError("first")
def raise_second():
    raise ValueError("second")
def chained():
    with ExitStack() as st:
        st.callback(raise_second)
        st.callback(raise_first)
        raise IndexError("body")
try:
    chained()
except ValueError as e:
    ctx1 = getattr(e, "__context__", None)
    ctx2 = getattr(ctx1, "__context__", None)
    check("ExitStack chains exceptions", [type(ctx1).__name__, type(ctx2).__name__, getattr(ctx2, "__context__", None)], ["KeyError", "IndexError", None])
def unchained():
    with ExitStack() as st:
        st.callback(raise_second)
        st.callback(raise_first)
try:
    unchained()
except ValueError as e:
    check("ExitStack without a body exception", getattr(e, "__context__", None), None)
def later_suppressed():
    with ExitStack() as st:
        st.push(Swallower())
        st.callback(raise_first)
log = []
check("a later exit suppresses an earlier error", [raises(later_suppressed), log], ["no error", ["sees KeyError"]])
check("ExitStack enter_context type check", raises(ExitStack().enter_context, 5), "TypeError: 'builtins.int' object does not support the context manager protocol")
def a_callback(*args):
    log.append(list(args))
log = []
with ExitStack() as stack:
    returned = stack.callback(a_callback, "x", 1)
check("ExitStack callback returns its callable", [same(returned, a_callback), log], [True, [["x", 1]]])
class MyCM(AbstractContextManager):
    def __exit__(self, *a):
        return None
mcm = MyCM()
with mcm as m2:
    check("AbstractContextManager __enter__", same(m2, mcm), True)
class mycontext(ContextDecorator):
    def __enter__(self):
        log.append("Starting")
        return self
    def __exit__(self, *exc):
        log.append("Finishing")
        return False
log = []
@mycontext()
def function_cd():
    log.append("The bit in the middle")
function_cd()
check("ContextDecorator", log, ["Starting", "The bit in the middle", "Finishing"])

class Buf:
    def __init__(self):
        self.parts = []
    def write(self, s):
        self.parts.append(s)
        return len(s)
    def flush(self):
        pass
out_buf = Buf()
real_stdout = sys.stdout
with contextlib.redirect_stdout(out_buf) as target:
    print("hidden", 1)
    print("a", "b", sep="-", end="!\n")
    sys.stdout.write("direct\n")
    target_ok = same(target, out_buf)
    import sys as sys_again
    from sys import stdout as stdout_now
    one_sys = [same(sys_again.stdout, out_buf), same(stdout_now, out_buf)]
check("redirect_stdout", ["".join(out_buf.parts), target_ok, same(sys.stdout, real_stdout)], ["hidden 1\na-b!\ndirect\n", True, True])
check("one sys module", one_sys, [True, True])
err_buf = Buf()
with contextlib.redirect_stderr(err_buf):
    print("to stderr", file=sys.stderr)
check("redirect_stderr", "".join(err_buf.parts), "to stderr\n")
inner_buf = Buf()
outer_buf = Buf()
with contextlib.redirect_stdout(outer_buf):
    print("outer")
    with contextlib.redirect_stdout(inner_buf):
        print("inner")
    print("outer again")
check("redirect_stdout nests", ["".join(outer_buf.parts), "".join(inner_buf.parts)], ["outer\nouter again\n", "inner\n"])
import asyncio
alog = []
@contextlib.asynccontextmanager
async def atag(name):
    alog.append("<" + name)
    try:
        yield name.upper()
    finally:
        alog.append(name + ">")
@contextlib.asynccontextmanager
async def aswallow():
    try:
        yield
    except ValueError as e:
        alog.append("swallowed " + str(e))
agen_closed = []
async def numbers():
    try:
        yield 1
        yield 2
    finally:
        agen_closed.append(True)
async def acb(x):
    alog.append("async cb " + x)
async def amain():
    async with atag("a") as v:
        alog.append(v)
    try:
        async with atag("b"):
            raise KeyError("x")
    except KeyError:
        alog.append("caught")
    async with aswallow():
        raise ValueError("v")
    async with contextlib.AsyncExitStack() as st:
        st.callback(alog.append, "sync cb")
        r = await st.enter_async_context(atag("c"))
        alog.append(r)
        st.push_async_callback(acb, "y")
    async with contextlib.aclosing(numbers()) as g:
        async for n in g:
            alog.append(n)
            break
    return "done"
check("asyncio.run with async context managers", asyncio.run(amain()), "done")
check("asynccontextmanager / AsyncExitStack / aclosing", alog,
      ["<a", "A", "a>", "<b", "b>", "caught", "swallowed v", "<c", "C", "async cb y", "c>", "sync cb", 1])
check("aclosing closed the generator", agen_closed, [True])

here = os.getcwd()
tmp_dir = os.path.join(here, "ny_audit73_" + str(os.getpid()))
os.mkdir(tmp_dir)
with contextlib.chdir(tmp_dir):
    inside_dir = os.path.basename(os.getcwd())
check("chdir", [inside_dir, os.getcwd() == here], [os.path.basename(tmp_dir), True])
os.rmdir(tmp_dir)
check("temp dir removed", os.path.isdir(tmp_dir), False)

# ── runtime pieces these modules rely on ─────────────────────────────────────
set_names = []
class Desc:
    def __set_name__(self, owner, name):
        self.name = name
        set_names.append([owner.__name__, name])
    def __get__(self, obj, objtype=None):
        if obj is None:
            return "class access " + self.name
        return "got " + self.name + " for " + type(obj).__name__
class UsesDesc:
    attr = Desc()
ud = UsesDesc()
check("descriptor __get__", [ud.attr, UsesDesc.attr, getattr(ud, "attr")], ["got attr for UsesDesc", "class access attr", "got attr for UsesDesc"])
check("descriptor __set_name__", set_names, [["UsesDesc", "attr"]])
class SubUses(UsesDesc):
    pass
check("descriptor inherited", SubUses().attr, "got attr for SubUses")
ud.attr = "own"
check("instance attribute shadows a non-data descriptor", ud.attr, "own")
def holder():
    return 1
def held():
    return 42
holder.held = held
holder.adder = lambda a, b=10: a + b
check("function attribute called", [holder.held(), holder.adder(1), holder.adder(1, b=2)], [42, 11, 3])
class LazyIt:
    def __init__(self, n):
        self.n = n
        self.i = 0
        self.log = []
    def __iter__(self):
        return self
    def __next__(self):
        if self.i >= self.n:
            raise StopIteration
        self.i += 1
        self.log.append("next")
        return self.i
li = LazyIt(2)
made = [li.log.append("body") or v for v in li]
check("comprehension reads an iterator lazily", li.log, ["next", "body", "next", "body"])
u1, u2 = LazyIt(2)
check("unpacking an iterator object", [u1, u2], [1, 2])
def unpack_three():
    w1, w2 = LazyIt(3)
    return [w1, w2]
def unpack_one():
    w1, w2 = LazyIt(1)
    return [w1, w2]
check("unpacking the wrong count", [raises(unpack_three), raises(unpack_one)],
      ["ValueError: too many values to unpack (expected 2)", "ValueError: not enough values to unpack (expected 2, got 1)"])
pr1, pr2 = pairwise("abc")
check("unpacking an itertools object", [pr1, pr2], [("a", "b"), ("b", "c")])
firsts = []
for i, v in enumerate(count(5)):
    if i > 2:
        break
    firsts.append(v)
check("enumerate/map/filter over infinite iterator objects",
      [firsts, list(islice(map(operator.neg, count(1)), 3)), next(filter(lambda x: x > 10, count())), list(zip(repeat(0), "ab"))],
      [[5, 6, 7], [-1, -2, -3], 11, [(0, "a"), (0, "b")]])
def passthrough(fn):
    def wrapper(*args, **kw):
        return fn(*args, **kw)
    return wrapper
class Wrapped:
    def __init__(self):
        self.n = 5
    @passthrough
    def plus(self, k):
        return self.n + k
wo = Wrapped()
bound_plus = wo.plus
check("a decorated method binds", [wo.plus(1), bound_plus(2)], [6, 7])
class HoldsMethod:
    def __init__(self, fn):
        self.fn = fn
    def run(self, obj):
        return self.fn(obj)
class Getter:
    def __init__(self):
        self.n = 3
    def get(self):
        return self.n
check("a method held in an attribute takes its instance", HoldsMethod(Getter.get).run(Getter()), 3)
def factory(a=1, b=2):
    def deco(fn):
        fn.params = [a, b]
        return fn
    return deco
@factory(b=20)
def decorated_kw():
    pass
check("decorator called with keywords only", decorated_kw.params, [1, 20])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
if skip_n > 0:
    print("(" + str(skip_n) + " checks skipped: not in this Python)")
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT73 PASSED ===")
