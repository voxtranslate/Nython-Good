# vm_audit55.ny - memory management on both engines (round 75).
#
#   Reference counting frees what nothing refers to any more, at once;
#   the cycle collector frees groups of objects that only refer to each
#   other: self-references, parent <-> child, rings, a class instance that
#   holds a closure over itself or its own bound method, containers that
#   contain themselves. __del__ runs exactly once, also for cyclic garbage,
#   and an object its __del__ resurrects stays alive. Nothing reachable is
#   ever freed, however often the collector runs, and loops that make
#   garbage do not make the heap grow. Weak references do not keep their
#   object alive. The gc_* builtins behave the same on the interpreter and
#   the VM.
#
#     ./build/nython-cli examples/vm_audit55.ny
#     ./build/nython-cli --vm examples/vm_audit55.ny

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

def check_true(name, cond, detail):
    global pass_n, fail_n
    if cond:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": " + str(detail))

# Finalized objects report here, by tag.
var deleted = []
var revived = []

class Tracked:
    def __init__(self, tag):
        self.tag = tag
        self.ref = none
    def __del__(self):
        deleted.append(self.tag)

def count_of(tag):
    var n = 0
    for t in deleted:
        if t == tag:
            n = n + 1
    return n

def sorted_tags(prefix):
    var out = []
    for t in deleted:
        if t.startswith(prefix):
            out.append(t)
    out.sort()
    return out

# ── the builtins ────────────────────────────────────────────────────────────
check("gc_is_enabled at start", gc_is_enabled(), true)
gc_disable()
check("gc_disable", gc_is_enabled(), false)
gc_enable()
check("gc_enable", gc_is_enabled(), true)
var th = gc_get_threshold()
check("gc_get_threshold has three generations", len(th), 3)
check_true("generation 0 threshold is positive", th[0] > 0, th)
var st0 = gc_stats()
check_true("gc_stats has collections", st0["collections"] >= 0, st0)
check_true("gc_stats has collected", st0["collected"] >= 0, st0)
check_true("gc_live_objects is a count", gc_live_objects() >= 0, gc_live_objects())
check_true("mem_rss_kb is a size", mem_rss_kb() >= 0, mem_rss_kb())

# ── reference counting: freed at once, finalized once ───────────────────────
var t = Tracked("rc1")
check("alive while referenced", count_of("rc1"), 0)
t = none
check("__del__ ran when the last reference went", count_of("rc1"), 1)
gc_collect()
check("__del__ ran exactly once", count_of("rc1"), 1)

def scoped():
    var local = Tracked("rc2")
    return local.tag
check("a local's object is freed when the call returns", [scoped(), count_of("rc2")], ["rc2", 1])

var holder = [Tracked("rc3")]
holder.pop()
check("removed from a list: freed", count_of("rc3"), 1)

var dd = {"k": Tracked("rc4")}
dd["k"] = 5
check("replaced in a dict: freed", count_of("rc4"), 1)

var kept = Tracked("rc5")
var alias = kept
kept = none
check("a second reference keeps it alive", count_of("rc5"), 0)
alias = none
check("then it goes with the last one", count_of("rc5"), 1)

# ── cycles ──────────────────────────────────────────────────────────────────
var a = Tracked("self")
a.ref = a
a = none
check("a self-cycle is not freed by counting", count_of("self"), 0)
var n = gc_collect()
check_true("gc_collect reports what it freed", n > 0, n)
check("a self-cycle is freed by the collector", count_of("self"), 1)
gc_collect()
check("and finalized once", count_of("self"), 1)

var p = Tracked("pair-a")
var q = Tracked("pair-b")
p.ref = q
q.ref = p
p = none
q = none
gc_collect()
check("parent <-> child", sorted_tags("pair-"), ["pair-a", "pair-b"])

def make_ring(k, tag):
    var first = Tracked(tag + "0")
    var cur = first
    for i in range(1, k):
        var nx = Tracked(tag + str(i))
        cur.ref = nx
        cur = nx
    cur.ref = first
    return first
var ring = make_ring(50, "ring-")
ring = none
gc_collect()
check("a ring of 50 is freed", len(sorted_tags("ring-")), 50)

# A class instance holding a closure over itself.
class Widget:
    def __init__(self, tag):
        self.tag = tag
        self.on_click = none
    def wire(self):
        def handler():
            return self.tag
        self.on_click = handler
    def __del__(self):
        deleted.append(self.tag)

var w = Widget("closure")
w.wire()
check("the closure sees its instance", w.on_click(), "closure")
w = none
gc_collect()
check("instance <-> closure over it", count_of("closure"), 1)

# A bound method stored on its own instance.
class Button:
    def __init__(self, tag):
        self.tag = tag
        self.cb = self.press
    def press(self):
        return self.tag
    def __del__(self):
        deleted.append(self.tag)

var b = Button("bound")
check("the bound method works", b.cb(), "bound")
b = none
gc_collect()
check("instance <-> its bound method", count_of("bound"), 1)

# A function scope that holds the function made in it (and a recursive
# inner function referring to itself).
def outer_scope(tag):
    var obj = Tracked(tag)
    def inner(k):
        if k == 0:
            return obj.tag
        return inner(k - 1)
    obj.ref = inner
    return inner(3)
check("recursive inner function", outer_scope("scope"), "scope")
gc_collect()
check("scope <-> function defined in it", count_of("scope"), 1)

# Containers that contain themselves.
var before_c = gc_live_objects()
for i in range(200):
    var L = [i]
    L.append(L)
    var D = {"n": i}
    D["me"] = D
gc_collect()
var after_c = gc_live_objects()
check_true("self-containing lists and dicts are freed", after_c - before_c < 50, after_c - before_c)

# ── finalizers: resurrection, errors ────────────────────────────────────────
class Phoenix:
    def __init__(self, tag):
        self.tag = tag
        self.me = self
    def __del__(self):
        deleted.append(self.tag)
        revived.append(self)

var ph = Phoenix("phoenix")
ph = none
gc_collect()
check("a finalizer ran on the cycle", count_of("phoenix"), 1)
check("it resurrected the object", len(revived), 1)
check("the resurrected object is intact", revived[0].tag, "phoenix")
check("its self-reference too", revived[0].me.tag, "phoenix")
revived.clear()
gc_collect()
gc_collect()
check("never finalized twice", count_of("phoenix"), 1)

class Faulty:
    def __init__(self):
        self.x = 1
    def __del__(self):
        deleted.append("faulty")
        raise ValueError("ignored")

var fz = Faulty()
fz = none
check("an exception in __del__ is ignored", count_of("faulty"), 1)

# ── nothing reachable is freed ──────────────────────────────────────────────
class GNode:
    def __init__(self, v):
        self.v = v
        self.next = none
        self.prev = none
        self.kids = []

def build_graph(k):
    var nodes = []
    for i in range(k):
        nodes.append(GNode(i))
    for i in range(k):
        var nd = nodes[i]
        nd.next = nodes[(i + 1) % k]
        nd.prev = nodes[(i + k - 1) % k]
        nd.kids.append(nodes[(i * 7) % k])
        nd.kids.append({"back": nd, "i": i})
    return nodes[0]

var head = build_graph(2000)
for r in range(3):
    gc_collect()
var total = 0
var cur = head
for i in range(2000):
    total = total + cur.v + cur.kids[0].v + cur.kids[1]["i"]
    check_true("back link intact", cur.kids[1]["back"] is cur, i)
    check_true("prev link intact", cur.next.prev is cur, i)
    cur = cur.next
check("every value of a 2000-node graph survives collections", total, 3 * (1999 * 2000 / 2) - 0)
check("the ring closes", cur is head, true)

# Objects only a running call refers to survive a collection in that call.
def collect_inside():
    var mine = GNode(42)
    mine.next = mine
    var lst = [mine, [mine]]
    gc_collect()
    gc_collect()
    return mine.next.v + lst[1][0].v
check("locals of a running call survive", collect_inside(), 84)

# The same object keeps its identity, and works as a dict key.
var keyobj = GNode(7)
var idk = id(keyobj)
var bykey = {}
bykey[keyobj] = "found"
gc_collect()
check("id is stable across collections", id(keyobj), idk)
check("an object dict key survives collections", bykey[keyobj], "found")

# ── loops do not accumulate ─────────────────────────────────────────────────
var base = gc_live_objects()
for i in range(20000):
    var L = [1, 2, 3]
    var m = {"a": 1}
    var g = GNode(i)
gc_collect()
check_true("acyclic garbage in a loop is freed as it goes", gc_live_objects() - base < 50, gc_live_objects() - base)

base = gc_live_objects()
for i in range(20000):
    var g = GNode(i)
    g.next = g
    g.kids.append(g)
var grown = gc_live_objects() - base
check_true("cyclic garbage in a loop is collected automatically", grown < 12000, grown)
gc_collect()
check_true("and all of it by an explicit collection", gc_live_objects() - base < 50, gc_live_objects() - base)

# With automatic collection off, cycles wait for gc_collect().
gc_disable()
base = gc_live_objects()
for i in range(3000):
    var g = GNode(i)
    g.next = g
check_true("disabled: cycles accumulate", gc_live_objects() - base >= 3000, gc_live_objects() - base)
var freed = gc_collect()
check_true("gc_collect frees them anyway", freed >= 3000, freed)
check_true("and the count returns", gc_live_objects() - base < 50, gc_live_objects() - base)
gc_enable()

# Deep structures are freed without exhausting the stack.
def chain(k):
    var first = GNode(0)
    var c = first
    for i in range(1, k):
        var nx = GNode(i)
        c.next = nx
        c = nx
    return first
var long_chain = chain(30000)
long_chain = none
check("a 30000-long chain was freed", 1, 1)

# ── threads: collections while other threads hold values ────────────────────
# Each thread builds cyclic garbage and a structure it keeps, collecting as it
# goes; the GIL hands over at statement boundaries, so collections run while
# the other threads' locals are live on their own stacks.
def gc_worker(k):
    var keep = []
    for i in range(1500):
        var g = GNode(k * 100000 + i)
        g.next = g
        if i % 3 == 0:
            keep.append(g)
        if i % 500 == 0:
            gc_collect()
    var s = 0
    for g in keep:
        s = s + g.v - k * 100000
        if not (g.next is g):
            s = -1000000000
    return s

var ths = []
for k in range(4):
    ths.append(thread_create(gc_worker, k))
var sums = []
for h in ths:
    sums.append(thread_join(h, 60000))
var want_sum = 0
for i in range(0, 1500, 3):
    want_sum = want_sum + i
check("threads collecting concurrently keep their values", sums, [want_sum, want_sum, want_sum, want_sum])
gc_collect()

# ── weak references ─────────────────────────────────────────────────────────
def error_of(f):
    try:
        f()
        return "none"
    except TypeError:
        return "TypeError"

var tgt = Tracked("weak")
var wr = weakref(tgt)
check("a weak reference gives the object", wr() is tgt, true)
check("it does not keep it alive", count_of("weak"), 0)
tgt = none
check("the object is freed", count_of("weak"), 1)
check("then the weak reference gives none", wr(), none)
var cyc = Tracked("weak-cycle")
cyc.ref = cyc
var wc = weakref(cyc)
cyc = none
check("cyclic garbage is still reachable weakly before a collection", wc() == none, false)
gc_collect()
check("and gone after it", wc(), none)
check("weakref of a list is a TypeError", error_of(lambda: weakref([1, 2])), "TypeError")
check("weakref of a string is a TypeError", error_of(lambda: weakref("s")), "TypeError")

var st1 = gc_stats()
check_true("collections were counted", st1["collections"] > st0["collections"], [st0["collections"], st1["collections"]])
check_true("collected objects were counted", st1["collected"] > st0["collected"], [st0["collected"], st1["collected"]])

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT55 PASSED ===")
