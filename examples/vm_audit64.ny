# vm_audit64.ny - round 76: objects used as dict keys are freed.
#
# A dict keyed by an object (an instance, a function) stores the object's
# identity as the key, and the engine keeps the object in a table to give it
# back from keys()/items(). That table kept every object ever used as a key -
# or only looked up as one (`k in d`, a set of objects) - alive until the
# program ended. Now a full collection treats the table's reference as the
# dicts': an object a live dict still uses stays, the rest is freed, cycles
# through a key included.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit64.ny
#     ./build/nython-cli --vm examples/vm_audit64.ny

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

class Key:
    def __init__(self, n):
        self.n = n

# ── a key goes with its dict ─────────────────────────────────────────────
def keyed_dict():
    var k = Key(1)
    var d = {}
    d[k] = "value"
    return [weakref(k), len(d)]
var r = keyed_dict()
check("the dict had the key", r[1], 1)
gc_collect()
check("the key object is freed with its dict", r[0](), none)

# ── a live dict keeps its keys ───────────────────────────────────────────
var keep = {}
def add_key(n):
    var k = Key(n)
    keep[k] = "kept " + str(n)
    return weakref(k)
var w1 = add_key(10)
var w2 = add_key(20)
gc_collect()
gc_collect()
check("a live dict's key stays", w1() is not none, true)
check("its value", keep[w1()], "kept 10")
check("keys() gives the objects", sorted([k.n for k in keep.keys()]), [10, 20])
del keep[w1()]
gc_collect()
check("a deleted key is freed", w1(), none)
check("the other stays", w2().n, 20)

# ── a cycle through a key ────────────────────────────────────────────────
def node_in_own_dict():
    var n = Key(2)
    n.index = {}
    n.index[n] = "me"
    return weakref(n)
var wc = node_in_own_dict()
gc_collect()
check("a node keyed in a dict it holds is collected", wc(), none)

def pair_cycle():
    var a = Key(3)
    var b = Key(4)
    a.d = {b: 1}
    b.d = {a: 2}
    return [weakref(a), weakref(b)]
var wp = pair_cycle()
gc_collect()
check("two objects keyed in each other's dicts", [wp[0](), wp[1]()], [none, none])

# ── keys inside tuples, functions as keys ────────────────────────────────
var tkeep = {}
def tuple_keys():
    var a = Key(5)
    var b = Key(6)
    tkeep[(a, 1)] = "a"
    var d = {(b, 2): "b"}
    return [weakref(a), weakref(b), len(d)]
var wt = tuple_keys()
gc_collect()
check("an object in a live tuple key stays", wt[0]().n, 5)
check("an object in a dead tuple key goes", wt[1](), none)
check("the tuple key gives it back", [k[0].n for k in tkeep.keys()], [5])

def fn_keys():
    def handler():
        return "h"
    var table = {handler: 1}
    return len(table)
check("a function as a key", fn_keys(), 1)

# ── lookups alone keep nothing ───────────────────────────────────────────
def lookups():
    var k = Key(7)
    var d = {}
    var found = k in d
    var s = set([k, k])
    return [weakref(k), found, len(s)]
var wl = lookups()
gc_collect()
check("looked up and put in a set, then freed", [wl[0](), wl[1], wl[2]], [none, false, 1])

# ── a cycle through a suspended generator ────────────────────────────────
# The generator's scope holds the object that holds the generator. The
# collector closes the generator first (its finally block runs, as in
# Python), then frees the cycle. It was never collected on the interpreter
# (a suspended generator's references were invisible), and the VM freed it
# without running the finally block.
var closed = []
class Holder:
    def __init__(self):
        self.g = none
def holder_body(h):
    try:
        yield 1
        yield 2
    finally:
        closed.append("finally ran")
def generator_cycle():
    var h = Holder()
    h.g = holder_body(h)
    next(h.g)
    return weakref(h)
var wg = generator_cycle()
check("not freed by reference counting alone", wg() is not none, true)
gc_collect()
check("a suspended generator's cycle is collected", wg(), none)
check("its finally block ran once", closed, ["finally ran"])

def unstarted_cycle():
    var h = Holder()
    h.g = holder_body(h)
    return weakref(h)
var wu = unstarted_cycle()
gc_collect()
check("a cycle through a generator never started", wu(), none)
check("no finally for it", closed, ["finally ran"])

var kept_holder = none
def live_generator():
    var h = Holder()
    h.g = holder_body(h)
    next(h.g)
    kept_holder = h
    return weakref(h)
var wk = live_generator()
gc_collect()
check("a reachable suspended generator stays", wk() is not none, true)
check("and still runs", next(kept_holder.g), 2)
check("nothing closed it", closed, ["finally ran"])

# ── a builtin value's method read as a value ─────────────────────────────
# `f = xs.append` is a callable holding xs. It, and xs with it, was kept for
# the life of the program on the interpreter.
def bound_append(n):
    var xs = []
    var add = xs.append
    for i in range(n):
        add(i)
    return len(xs)
check("a bound append works", bound_append(5), 5)
def proto_member():
    var k = Key(11)
    var f = k.to_string
    var s = f()
    return weakref(k)
var wm = proto_member()
gc_collect()
check("an object-protocol member lets go of its object", wm(), none)
gc_collect()
var live1 = gc_live_objects()
var j = 0
while j < 2000:
    bound_append(3)
    j = j + 1
gc_collect()
var grown1 = gc_live_objects() - live1
check("2000 bound appends leave nothing (" + str(grown1) + " objects)", grown1 < 100, true)

# ── many: the table does not grow ────────────────────────────────────────
def churn(n):
    var i = 0
    while i < n:
        var d = {}
        d[Key(i)] = i
        i = i + 1
gc_collect()
var live0 = gc_live_objects()
churn(3000)
gc_collect()
var grown = gc_live_objects() - live0
check("3000 keyed dicts leave nothing (" + str(grown) + " objects)", grown < 100, true)

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT64 PASSED ===")
