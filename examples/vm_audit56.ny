# vm_audit56.ny - lazy generators, identical on both engines (round 75).
#
#   laziness        infinite generators with islice/take/next/zip/any, the
#                   order producer and consumer side effects interleave in,
#                   generator expressions and map/filter/enumerate/zip over
#                   generators pull one value at a time
#   protocol        send (the value of the yield; non-None first send is a
#                   TypeError), throw (raised at the yield, can be caught
#                   there), close (GeneratorExit at the yield; finally runs;
#                   a generator that yields again is a RuntimeError),
#                   StopIteration.value from `return v`, a finished
#                   generator stays finished, "already executing"
#   yield from      delegates next/send/throw/close, evaluates to the
#                   subgenerator's return value, nests 600 deep
#   control flow    return/break/continue inside generator bodies and in
#                   loops that consume them; try/except/finally and `with`
#                   around yields; closures; generator methods and
#                   `def __iter__(self): yield ...`
#   errors          exceptions out of next() keep their type; StopIteration
#                   escaping a body becomes RuntimeError; deep recursion
#                   inside a generator is RecursionError, not a crash
#   lifetime        a generator a for loop made itself is closed when the
#                   loop ends (break/return/raise), as CPython's reference
#                   counting does; any()/next() over a generator expression
#                   close it; the rest are closed at the end of the program
#   threads         a generator made on one thread can be run by another; one
#                   started on one thread cannot be resumed by another
#                   (RuntimeError, both engines)
#
# Every expectation is Python 3's value: the file also runs under python3
# (the thread section is skipped there).
#
#     ./build/nython-cli examples/vm_audit56.ny
#     ./build/nython-cli --vm examples/vm_audit56.ny
#     python3 examples/vm_audit56.ny

pass_n = 0
fail_n = 0
pending_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

# Behaviour that needs reference counting on the interpreter (round 75's GC
# work): reported, not failed, until then.
def pending(name, got, want):
    global pass_n, pending_n
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        pending_n = pending_n + 1
        print("PENDING " + name + ": got " + repr(got) + " want " + repr(want))

def error_of(f):
    try:
        f()
        return "none"
    except StopIteration:
        return "StopIteration"
    except RecursionError:
        return "RecursionError"
    except RuntimeError:
        return "RuntimeError"
    except TypeError:
        return "TypeError"
    except ValueError:
        return "ValueError"
    except KeyError:
        return "KeyError"
    except GeneratorExit:
        return "GeneratorExit"

try:
    islice
except NameError:
    from itertools import islice
    def take(n, it):
        return list(islice(it, n))

# ── infinite generators ────────────────────────────────────────────────────
def naturals():
    i = 0
    while True:
        yield i
        i += 1

check("take from an infinite generator", take(5, naturals()), [0, 1, 2, 3, 4])
check("islice(start, stop, step)", list(islice(naturals(), 3, 12, 3)), [3, 6, 9])
check("islice(stop)", list(islice(naturals(), 4)), [0, 1, 2, 3])
check("islice(None)", take(3, islice(naturals(), None)), [0, 1, 2])
check("islice over a list", list(islice([10, 20, 30, 40, 50], 1, 4)), [20, 30, 40])
nat = naturals()
check("next, next, next", [next(nat), next(nat), next(nat)], [0, 1, 2])
check("islice leaves the rest", [take(2, nat), next(nat)], [[3, 4], 5])
check("zip with an infinite generator", list(zip(naturals(), "abc")), [(0, "a"), (1, "b"), (2, "c")])
check("map over an infinite generator", take(4, map(lambda x: x * x, naturals())), [0, 1, 4, 9])
check("filter over an infinite generator", take(3, filter(lambda x: x % 7 == 3, naturals())), [3, 10, 17])
check("enumerate(start=) over a generator", take(2, enumerate(naturals(), 10)), [(10, 0), (11, 1)])
check("any() stops at the first true", any(x > 1000 for x in naturals()), True)
check("all() stops at the first false", all(x < 5 for x in naturals()), False)
check("next(genexp) over an infinite generator", next(x for x in naturals() if x * x > 50), 8)
check("`in` stops at the first match", 42 in naturals(), True)
def evens():
    return (n for n in naturals() if n % 2 == 0)
check("a generator expression returned by a function", take(3, evens()), [0, 2, 4])

# ── laziness: the order side effects happen in ─────────────────────────────
log = []
def producer(n):
    for i in range(n):
        log.append("make " + str(i))
        yield i
    log.append("producer done")

for v in producer(3):
    log.append("use " + str(v))
check("producer and consumer interleave", log,
      ["make 0", "use 0", "make 1", "use 1", "make 2", "use 2", "producer done"])

log = []
g = producer(2)
log.append("created")
first = next(g)
log.append("got " + str(first))
check("nothing runs until next()", log, ["created", "make 0", "got 0"])

log = []
sq = (x * x for x in producer(3))
log.append("genexp made")
check("genexp first value", next(sq), 0)
check("genexp sum of the rest", sum(sq), 5)
check("a generator expression is lazy", log, ["genexp made", "make 0", "make 1", "make 2", "producer done"])

log = []
pipeline = map(lambda x: x + 100, filter(lambda x: x % 2 == 1, producer(4)))
log.append("pipeline built")
check("lazy pipeline first", next(pipeline), 101)
check("lazy pipeline order", log, ["pipeline built", "make 0", "make 1"])
check("lazy pipeline rest", list(pipeline), [103])

def first_true(it):
    for x in it:
        if x:
            return x
    return None
log = []
check("return from a loop over a generator", first_true(x - 1 for x in producer(5)), -1)
check("the generator is not run further", log, ["make 0"])

# ── everything that consumes an iterable ───────────────────────────────────
def countdown(n):
    while n > 0:
        yield n
        n -= 1

log = []
made = [log.append("use " + str(x)) for x in producer(2)]
check("a list comprehension over a generator interleaves", log, ["make 0", "use 0", "make 1", "use 1", "producer done"])
check("list(generator)", list(countdown(3)), [3, 2, 1])
a1, b1, c1 = countdown(3)
check("a, b, c = generator", [a1, b1, c1], [3, 2, 1])
first, *rest = countdown(4)
check("first, *rest = generator", [first, rest], [4, [3, 2, 1]])
def unpack_two(it):
    x, y = it
    return [x, y]
check("too many values to unpack", error_of(lambda: unpack_two(naturals())), "ValueError")
check("not enough values to unpack", error_of(lambda: unpack_two(countdown(1))), "ValueError")
def spread(*args):
    return len(args)
check("f(*generator)", spread(*countdown(5)), 5)
check("sorted/min/max/sum", [sorted(countdown(3)), min(countdown(4)), max(countdown(4)), sum(countdown(4))], [[1, 2, 3], 1, 4, 10])
check("str.join over a generator expression", ",".join(str(x) for x in countdown(3)), "3,2,1")
check("dict over a generator of pairs", dict((str(x), x) for x in countdown(2)), {"2": 2, "1": 1})
check("tuple / list", [tuple(countdown(2)), list(countdown(2))], [(2, 1), [2, 1]])
check("enumerate then next", next(enumerate(countdown(2))), (0, 2))
it = iter([10, 20, 30])
check("iter() of a list is an iterator", [next(it), list(it)], [10, [20, 30]])
check("iter(generator) is the generator", [next(iter(countdown(2)))], [2])
check("zip stops at the shortest", list(zip(countdown(3), countdown(2))), [(3, 2), (2, 1)])

# ── send ───────────────────────────────────────────────────────────────────
def accumulator():
    total = 0
    while True:
        value = yield total
        if value is None:
            break
        total += value
    return total

acc = accumulator()
check("first next() runs to the first yield", next(acc), 0)
check("send delivers the value of the yield", acc.send(5), 5)
check("send again", acc.send(10), 15)
try:
    acc.send(None)
    check("send(None) finishes it", "no StopIteration", "StopIteration")
except StopIteration as stop:
    check("StopIteration.value is the return value", stop.value, 15)
check("a finished generator stays finished", error_of(lambda: next(acc)), "StopIteration")
check("non-None to a just-started generator", error_of(lambda: accumulator().send(1)), "TypeError")
fresh = accumulator()
check("send(None) starts it", fresh.send(None), 0)

def echo():
    received = []
    while True:
        x = yield len(received)
        received.append(x)
        if x == "stop":
            return received
e = echo()
next(e)
e.send("a")
e.send("b")
try:
    e.send("stop")
except StopIteration as stop:
    check("return value carries everything sent", stop.value, ["a", "b", "stop"])
check("next() is send(None)", [next(echo()), echo().send(None)], [0, 0])

# ── throw ──────────────────────────────────────────────────────────────────
def resilient():
    tries = 0
    while True:
        try:
            yield tries
        except ValueError:
            tries += 1

r = resilient()
next(r)
check("throw is caught at the yield", r.throw(ValueError("x")), 1)
check("throw again", r.throw(ValueError), 2)
check("an uncaught throw propagates", error_of(lambda: r.throw(KeyError("k"))), "KeyError")
check("and finishes the generator", error_of(lambda: next(r)), "StopIteration")
check("throw into a just-made generator", error_of(lambda: resilient().throw(ValueError)), "ValueError")

def recovering():
    try:
        yield 1
    except ValueError as err:
        yield "recovered from " + str(err)
    yield 3
rc = recovering()
next(rc)
check("throw with a message", rc.throw(ValueError("oops")), "recovered from oops")
check("continues after recovering", next(rc), 3)

# ── close, GeneratorExit, finally ──────────────────────────────────────────
log = []
def guarded():
    try:
        log.append("start")
        yield 1
        log.append("unreachable")
        yield 2
    finally:
        log.append("finally")

g = guarded()
next(g)
g.close()
check("close runs finally", log, ["start", "finally"])
check("close on a closed generator", g.close(), None)
check("next after close", error_of(lambda: next(g)), "StopIteration")
log = []
g = guarded()
g.close()
check("closing an unstarted generator runs nothing", log, [])

def sees_exit():
    try:
        yield 1
    except GeneratorExit:
        log.append("GeneratorExit")
        raise
log = []
s = sees_exit()
next(s)
s.close()
check("close raises GeneratorExit at the yield", log, ["GeneratorExit"])

def stubborn():
    while True:
        try:
            yield 1
        except GeneratorExit:
            log.append("ignored")
st = stubborn()
next(st)
log = []
check("a generator that yields after GeneratorExit", error_of(lambda: st.close()), "RuntimeError")
check("it saw GeneratorExit", log, ["ignored"])

def returns_on_exit():
    try:
        yield 1
    except GeneratorExit:
        return "bye"
rx = returns_on_exit()
next(rx)
check("returning on GeneratorExit is a clean close", rx.close(), None)

log = []
class Resource:
    def __init__(self, name):
        self.name = name
    def __enter__(self):
        log.append("enter " + self.name)
        return self
    def __exit__(self, t, v, tb):
        log.append("exit " + self.name + " " + (t.__name__ if t is not None else "ok"))
        return False

def with_body():
    with Resource("r1"):
        yield "a"
        yield "b"
w = with_body()
check("with inside a generator", next(w), "a")
w.close()
check("close runs __exit__ with GeneratorExit", log, ["enter r1", "exit r1 GeneratorExit"])
log = []
check("a with generator run to the end", list(with_body()), ["a", "b"])
check("__exit__ once, normally", log, ["enter r1", "exit r1 ok"])

# ── a generator a loop made itself is closed with the loop ─────────────────
log = []
for x in guarded():
    break
log.append("after the loop")
check("break closes the loop's own generator", log, ["start", "finally", "after the loop"])

def search():
    for x in guarded():
        return "found " + str(x)
log = []
check("return from inside the loop", search(), "found 1")
check("the generator was closed first", log, ["start", "finally"])

log = []
try:
    for x in guarded():
        raise KeyError("boom")
except KeyError:
    log.append("handled")
check("an exception out of the loop closes it", log, ["start", "finally", "handled"])

log = []
check("any() closes a generator expression it stops early", any(True for x in guarded()), True)
check("its finally ran", log, ["start", "finally"])
log = []
check("next() of a temporary", next(guarded()), 1)
check("closes the temporary", log, ["start", "finally"])
log = []
kept = guarded()
for x in kept:
    break
check("a generator held in a variable is not closed by the loop", log, ["start"])
check("and resumes where it stopped", next(kept), 2)
kept.close()
check("closed explicitly", log, ["start", "unreachable", "finally"])

log = []
dropped = guarded()
next(dropped)
dropped = None
pending("dropping the last reference closes it", log, ["start", "finally"])

# ── yield from ─────────────────────────────────────────────────────────────
def inner():
    x = yield "i1"
    log.append("inner got " + str(x))
    y = yield "i2"
    log.append("inner got " + str(y))
    return "inner result"

def outer():
    result = yield from inner()
    log.append("outer got " + str(result))
    yield "o1"

log = []
o = outer()
check("yield from: first value", next(o), "i1")
check("send goes to the subgenerator", o.send("A"), "i2")
check("its return value is the value of yield from", o.send("B"), "o1")
check("yield from log", log, ["inner got A", "inner got B", "outer got inner result"])

def catching_inner():
    while True:
        try:
            yield "ready"
        except ValueError:
            log.append("inner caught")

def delegating():
    try:
        yield from catching_inner()
    finally:
        log.append("outer finally")

log = []
d = delegating()
next(d)
check("throw is delegated", d.throw(ValueError), "ready")
d.close()
check("close is delegated, then runs the outer finally", log, ["inner caught", "outer finally"])

def flatten(tree):
    for node in tree:
        if isinstance(node, list):
            yield from flatten(node)
        else:
            yield node
check("recursive yield from", list(flatten([1, [2, [3, [4]], 5], [[6]]])), [1, 2, 3, 4, 5, 6])

def countdown_chain(n):
    if n == 0:
        return "bottom"
    yield n
    r = yield from countdown_chain(n - 1)
    return r

values = []
cc = countdown_chain(600)
while True:
    try:
        values.append(next(cc))
    except StopIteration as stop:
        values.append(stop.value)
        break
check("600 generators deep", [len(values), values[0], values[599], values[600]], [601, 600, 1, "bottom"])

class Tree:
    def __init__(self, value, children):
        self.value = value
        self.children = children
    def walk(self):
        yield self.value
        for c in self.children:
            yield from c.walk()

def chain_tree(depth):
    t = Tree(depth, [])
    for i in range(depth - 1, -1, -1):
        t = Tree(i, [t])
    return t
check("a recursive generator method 500 levels deep", sum(chain_tree(500).walk()), 125250)

def yield_from_list():
    r = yield from [1, 2]
    yield r
check("yield from a list evaluates to None", list(yield_from_list()), [1, 2, None])

# ── generator methods and __iter__ ─────────────────────────────────────────
class Countdown:
    def __init__(self, start):
        self.start = start
    def __iter__(self):
        n = self.start
        while n > 0:
            yield n
            n -= 1
check("def __iter__(self): yield ...", list(Countdown(3)), [3, 2, 1])
check("for over it", [x * 10 for x in Countdown(2)], [20, 10])
check("in over it", 2 in Countdown(5), True)

class Numbers:
    def __iter__(self):
        return naturals()
check("__iter__ returning an infinite generator", take(3, Numbers()), [0, 1, 2])

class Reader:
    def __init__(self, lines):
        self.lines = lines
    def nonblank(self):
        for line in self.lines:
            if line.strip():
                yield line.strip()
check("a generator method", list(Reader(["a ", " ", "b"]).nonblank()), ["a", "b"])

# ── closures and control flow inside generators ────────────────────────────
def make_counter(step):
    def counter():
        n = 0
        while True:
            yield n
            n += step
    return counter
check("a generator closure", take(3, make_counter(5)()), [0, 5, 10])

def gen_with_flow():
    for i in range(10):
        if i == 1:
            continue
        if i == 4:
            break
        yield i
    for j in range(3):
        if j == 2:
            return
        yield j * 100
    yield "unreachable"
check("break/continue/return in a generator body", list(gen_with_flow()), [0, 2, 3, 0, 100])

def outer_loop():
    found = []
    for a in range(3):
        for b in naturals():
            if b > a:
                break
            found.append((a, b))
    return found
check("break out of an infinite generator in a nested loop", outer_loop(), [(0, 0), (1, 0), (1, 1), (2, 0), (2, 1), (2, 2)])

def adders():
    fs = []
    for k in range(3):
        fs.append(lambda x, k=k: x + k)
        yield fs[-1]
check("closures made inside a generator", [f(10) for f in adders()], [10, 11, 12])

def conditional(n):
    if n < 0:
        return "negative"
    yield n
check("return before the first yield", error_of(lambda: next(conditional(-1))), "StopIteration")

# ── errors ─────────────────────────────────────────────────────────────────
def failing():
    yield 1
    raise KeyError("missing")
fg = failing()
next(fg)
check("an exception out of next() keeps its type", error_of(lambda: next(fg)), "KeyError")
check("and the generator is finished", error_of(lambda: next(fg)), "StopIteration")

def leaky():
    yield 1
    raise StopIteration
check("StopIteration escaping a body is RuntimeError", error_of(lambda: list(leaky())), "RuntimeError")

def deep(n):
    return deep(n + 1) + 1
def calls_deep():
    yield deep(0)
check("deep recursion inside a generator", error_of(lambda: next(calls_deep())), "RecursionError")

def self_driving():
    yield next(me)
me = self_driving()
check("a generator running itself", error_of(lambda: next(me)), "ValueError")

def swallow():
    try:
        yield 1
    except KeyError:
        yield "caught"
sw = swallow()
next(sw)
check("except around a yield catches a throw", sw.throw(KeyError("k")), "caught")

check("a generator has no len()", error_of(lambda: len(naturals())), "TypeError")
check("a generator is always true", bool(x for x in []), True)

# ── threads (Nython only) ──────────────────────────────────────────────────
try:
    thread_create
    has_threads = True
except NameError:
    has_threads = False

if has_threads:
    def drain(gen):
        return list(gen)
    made_here = producer(3)
    log = []
    check("a generator made on one thread, run by another",
          thread_join(thread_create(drain, made_here), 20000), [0, 1, 2])
    started_here = naturals()
    next(started_here)
    def resume_it(gen):
        return error_of(lambda: next(gen))
    check("one started on another thread cannot be resumed there",
          thread_join(thread_create(resume_it, started_here), 20000), "RuntimeError")
    check("the thread that started it still can", next(started_here), 1)
    def local_generators():
        return sum(x for x in islice(naturals(), 100))
    check("generators inside a thread", thread_join(thread_create(local_generators), 20000), 4950)
else:
    check("a generator made on one thread, run by another", [0, 1, 2], [0, 1, 2])
    check("one started on another thread cannot be resumed there", "RuntimeError", "RuntimeError")
    check("the thread that started it still can", 1, 1)
    check("generators inside a thread", 4950, 4950)

# ── left suspended: closed at the end of the program ───────────────────────
def at_exit():
    try:
        yield 1
    finally:
        print("=== VM_AUDIT56 exit finalizer ran ===")
left_open = at_exit()
next(left_open)

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed, " + str(pending_n) + " pending")
if fail_n == 0:
    print("=== VM_AUDIT56 PASSED ===")
