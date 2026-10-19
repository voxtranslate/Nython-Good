# vm_audit120.ny - exceptions that native code catches are let go (round 85).
#
# An exception that an except clause handles is freed when the clause ends,
# and with it the frames its traceback holds (round 84). One that the
# runtime itself catches and carries on from - a for loop's StopIteration,
# hasattr's AttributeError, getattr's and next()'s defaults, list() and
# unpacking ending an iterator, __getattribute__ falling back to
# __getattr__ - stayed in the interpreter's exception ring until 256 more
# were raised, and every local of the frames it was raised in stayed alive
# with it. A StopIteration a generator raised, and an exception thrown into
# one, were kept by address outside the ring, never let go at all.
#
# Each check makes an object in the frame that raises, keeps a weak
# reference to it, and asks whether it is gone once the runtime is done.
#
# The checks pass under python3 too:
#
#     ./build/nython-cli examples/vm_audit120.ny
#     ./build/nython-cli --vm examples/vm_audit120.ny
#     python3 examples/vm_audit120.ny

import sys, gc, weakref

NYTHON = sys.implementation.name == "nython"
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

class Big:
    pass

refs = {}

def note(name):
    b = Big()
    refs[name] = weakref.ref(b)
    return b

def gone(name):
    gc.collect()
    return refs[name]() is None

# ── loops and consumers ending an iterator ──────────────────────────────────
class Stops:
    def __init__(self, name, n=0):
        self.name = name
        self.n = n
    def __iter__(self):
        return self
    def __next__(self):
        b = note(self.name)
        if self.n > 0:
            self.n -= 1
            return self.n
        raise StopIteration

for _x in Stops("for loop"):
    pass
check("a for loop's StopIteration", gone("for loop"), True)
check("list() ending an iterator", [list(Stops("list()", 2)), gone("list()")], [[1, 0], True])
_a, _b = Stops("unpacking", 2)
check("unpacking ending an iterator", [_a, _b, gone("unpacking")], [1, 0, True])
check("sorted() ending an iterator", [sorted(Stops("sorted()", 3)), gone("sorted()")], [[0, 1, 2], True])
check("next() with a default", [next(Stops("next default"), "d"), gone("next default")], ["d", True])
check("zip() over an iterator", [list(zip(Stops("zip()", 2), "ab")), gone("zip()")], [[(1, "a"), (0, "b")], True])

class Indexed:
    def __getitem__(self, i):
        b = note("getitem iteration")
        if i < 2:
            return i
        raise IndexError(i)

check("iteration by __getitem__ ending in IndexError", [list(Indexed()), gone("getitem iteration")], [[0, 1], True])

# ── attribute lookups with an absent answer ─────────────────────────────────
class Dyn:
    def __getattr__(self, n):
        b = note("hasattr")
        raise AttributeError(n)

check("hasattr through __getattr__", [hasattr(Dyn(), "zz"), gone("hasattr")], [False, True])

class Dyn2:
    def __getattr__(self, n):
        b = note("getattr default")
        raise AttributeError(n)

check("getattr with a default", [getattr(Dyn2(), "zz", 5), gone("getattr default")], [5, True])

class Hooked:
    def __getattribute__(self, n):
        b = note("__getattribute__ to __getattr__")
        raise AttributeError(n)
    def __getattr__(self, n):
        return "fallback " + n

check("__getattribute__ falling back to __getattr__",
      [Hooked().x, gone("__getattribute__ to __getattr__")], ["fallback x", True])

# ── generators ──────────────────────────────────────────────────────────────
def returns_seven():
    b = note("generator return value")
    yield 1
    return 7

g7 = returns_seven()
next(g7)
try:
    next(g7)
    stop_value = None
except StopIteration as e:
    stop_value = e.value
check("StopIteration.value of a generator's return", [stop_value, gone("generator return value")], [7, True])

def catches():
    try:
        yield 1
    except ValueError as e:
        yield e

gt = catches()
next(gt)
class Thrown(ValueError):
    pass

thrown = Thrown("x")
check("an instance thrown into a generator is the one it catches", gt.throw(thrown) is thrown, True)
tw = weakref.ref(thrown)
del thrown
gt.close()
del gt
gc.collect()
check("... and is let go afterwards", tw() is None, True)

class Five:
    def __iter__(self):
        return self
    def __next__(self):
        b = note("yield from an iterator")
        raise StopIteration(5)

def delegating():
    r = yield from Five()
    yield r

check("yield from an iterator: its StopIteration value", [list(delegating()), gone("yield from an iterator")], [[5], True])

# ── an exception an except clause is handling stays itself ─────────────────
# (hasattr swallows the very AttributeError the clause is handling; the
# clause's bare raise still raises it)
class Probe:
    def __getattr__(self, n):
        raise current

def reraiser():
    global current
    try:
        raise AttributeError("orig")
    except AttributeError as e:
        current = e
        h = hasattr(Probe(), "q")
        raise

try:
    reraiser()
except AttributeError as e3:
    got = [str(e3), e3 is current]
check("an exception swallowed while its clause runs", got, ["orig", True])

# ── the exception objects themselves ───────────────────────────────────────
# (the interpreter's ring kept each of these until 256 more were raised)
exc_refs = {}

class Miss(AttributeError):
    pass

class Done(StopIteration):
    pass

class Gone(IndexError):
    pass

class RaisesMiss:
    def __init__(self, name):
        self.name = name
    def __getattr__(self, n):
        e = Miss(n)
        exc_refs[self.name] = weakref.ref(e)
        raise e

class RaisesDone:
    def __init__(self, name):
        self.name = name
    def __iter__(self):
        return self
    def __next__(self):
        e = Done()
        exc_refs[self.name] = weakref.ref(e)
        raise e

class RaisesGone:
    def __getitem__(self, i):
        if i < 1:
            return i
        e = Gone(i)
        exc_refs["getitem"] = weakref.ref(e)
        raise e

hasattr(RaisesMiss("hasattr"), "x")
getattr(RaisesMiss("getattr"), "x", None)
for _x in RaisesDone("for"):
    pass
list(RaisesDone("list"))
next(RaisesDone("next"), None)
_unpacked = [*RaisesDone("star")]
sorted(RaisesDone("sorted"))
list(RaisesGone())

def deleg():
    yield from RaisesDone("yield from")

list(deleg())
gc.collect()
check("swallowed exceptions are freed",
      sorted((k, v() is None) for k, v in exc_refs.items()),
      [("for", True), ("getattr", True), ("getitem", True), ("hasattr", True), ("list", True), ("next", True),
       ("sorted", True), ("star", True), ("yield from", True)])

# GeneratorExit raised inside an except clause the generator was paused in:
# the exception the clause handled is let go once close() swallows it
class Handled(ValueError):
    pass

def paused_in_clause():
    try:
        yield 1
    except ValueError:
        yield 2

def drop(how):
    g = paused_in_clause()
    next(g)
    h = Handled("h")
    w = weakref.ref(h)
    g.throw(h)
    del h
    if how == "close":
        g.close()
    del g
    gc.collect()
    return w() is None

check("a clause's exception after close() / after the generator is dropped", [drop("close"), drop("drop")], [True, True])

# ── weak references to generators (as CPython's) ───────────────────────────
def counter():
    yield 1
    yield 2

gen = counter()
gref = weakref.ref(gen)
same = gref() is gen
next(gen)
del gen
gc.collect()
gone_after = gref() is None
cb_log = []
gen2 = counter()
gref2 = weakref.ref(gen2, lambda r: cb_log.append("called"))
del gen2
gc.collect()
gc.collect()
ws = weakref.WeakSet()
gen3 = counter()
ws.add(gen3)
n_before = len(ws)
del gen3
gc.collect()
check("weakref to a generator", [same, gone_after, cb_log, n_before, len(ws)], [True, True, ["called"], 1, 0])

# ── many of them ────────────────────────────────────────────────────────────
alive = []
class Many:
    def __getattr__(self, n):
        b = Big()
        alive.append(weakref.ref(b))
        raise AttributeError(n)

for _i in range(300):
    hasattr(Many(), "x")
gc.collect()
check("300 hasattr misses leave nothing alive", sum(1 for r in alive if r() is not None), 0)

pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT120 PASSED ===")
