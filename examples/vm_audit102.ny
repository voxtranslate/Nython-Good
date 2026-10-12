# vm_audit102.ny - gaps rounds 81's agents found, both engines (round 81
# follow-ups).
#
# A lambda put in a class is bound like a def when read as a value; `del
# C.m` removes a method for good (the interpreter still called its def);
# list.pop takes an integer index (a str/float argument is a TypeError, an
# __index__ object works); reading a name its function binds before it is
# bound is an UnboundLocalError (a NameError subclass) with CPython's
# message; a set iterator driven by hand notices the set changing size.
#
# Every expected value is CPython's; it runs under python3 too:
#
#     ./build/nython-cli examples/vm_audit102.ny
#     ./build/nython-cli --vm examples/vm_audit102.ny
#     python3 examples/vm_audit102.ny

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def raises(f):
    try:
        f()
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"

# ── a lambda in a class binds as a def does ──────────────────────────────
class L1:
    k = 10
    in_body = lambda self, x=1: self.k + x
    def m(self):
        return 0

o1 = L1()
L1.later = lambda self: self.k * 2
b1 = o1.later
check("lambda set on the class, read as a value, bound", b1(), 20)
check("... called through the attribute", o1.later(), 20)
b2 = o1.in_body
check("lambda in the class body, read as a value, bound", b2(), 11)
check("... its default kept", b2(5), 15)
check("... keyword argument", b2(x=7), 17)
check("... the bound method knows its instance", b1.__self__ is o1, True)
L1.st = staticmethod(lambda x: x + 1)
check("staticmethod(lambda) stays unbound", o1.st(1), 2)
L1.cm = classmethod(lambda cls: cls.k)
check("classmethod(lambda) gets the class", o1.cm(), 10)
o1.own = lambda: 42
check("a lambda on the instance is not bound", o1.own(), 42)
lst1 = [o1.later for _ in range(3)]
check("bound lambdas made in a loop", [f() for f in lst1], [20, 20, 20])
check("the class attribute itself stays a plain function", L1.later(o1), 20)

# ── del C.m removes the method ───────────────────────────────────────────
class D1:
    def m(self):
        return "D1.m"
    def keep(self):
        return "keep"

class D2(D1):
    def m(self):
        return "D2.m"

d = D2()
check("override before del", d.m(), "D2.m")
del D2.m
check("del of the override reveals the base method", d.m(), "D1.m")
del D1.m
check("del of the base method: a call raises", raises(lambda: d.m()), "AttributeError: 'D2' object has no attribute 'm'")
check("... a read raises", raises(lambda: d.m), "AttributeError: 'D2' object has no attribute 'm'")
check("... hasattr", hasattr(d, "m"), False)
check("the other methods stay", d.keep(), "keep")
D1.m = lambda self: "new"
check("set again after del", d.m(), "new")
class D3:
    def only(self):
        return 1
d3 = D3()
del D3.only
check("del of a class's only method", raises(lambda: d3.only()), "AttributeError: 'D3' object has no attribute 'only'")
check("del of a missing method", raises(lambda: delattr(D3, "only")), "AttributeError: type object 'D3' has no attribute 'only'")

# ── list.pop takes an integer index ──────────────────────────────────────
class Idx:
    def __index__(self):
        return 0

check("pop()", [1, 2, 3].pop(), 3)
check("pop(0)", [1, 2, 3].pop(0), 1)
check("pop(-1)", [1, 2, 3].pop(-1), 3)
check("pop(True)", [1, 2, 3].pop(True), 2)
check("pop(__index__)", [7, 8].pop(Idx()), 7)
check("pop('x')", raises(lambda: [1, 2].pop("x")), "TypeError: 'str' object cannot be interpreted as an integer")
check("pop(1.0)", raises(lambda: [1, 2].pop(1.0)), "TypeError: 'float' object cannot be interpreted as an integer")
check("pop(None)", raises(lambda: [1, 2].pop(None)), "TypeError: 'NoneType' object cannot be interpreted as an integer")
check("pop from empty", raises(lambda: [].pop()), "IndexError: pop from empty list")
check("pop out of range", raises(lambda: [1].pop(5)), "IndexError: pop index out of range")
lst2 = [1, 2]
raises(lambda: lst2.pop("x"))
check("a failed pop leaves the list", lst2, [1, 2])
check("dict.pop(key) unchanged", {"a": 1}.pop("a"), 1)
check("dict.pop(missing, default)", {"a": 1}.pop("b", 9), 9)

# ── UnboundLocalError ────────────────────────────────────────────────────
def u_read_first():
    r = x_unbound_102
    x_unbound_102 = 1
    return r

def u_after_del():
    y = 1
    del y
    return y

def u_aug():
    z_unbound_102 += 1
    return z_unbound_102

def u_free():
    return w_nowhere_102

def u_loop():
    for i in range(2):
        if i == 1:
            return q_102
        q_102 = i
    return None

def u_loop_ok():
    out = 0
    for i in range(2):
        if i == 1:
            out = q2_102
        q2_102 = i + 10
    return out

def u_global():
    global g_nowhere_102
    return g_nowhere_102

def u_nested():
    def inner():
        return n_102
    r = inner
    n_102 = 5
    return r()

msg = "cannot access local variable 'x_unbound_102' where it is not associated with a value"
check("read before the assignment", raises(u_read_first), "UnboundLocalError: " + msg)
check("read after del", raises(u_after_del), "UnboundLocalError: cannot access local variable 'y' where it is not associated with a value")
check("augmented assignment", raises(u_aug), "UnboundLocalError: cannot access local variable 'z_unbound_102' where it is not associated with a value")
check("a name the function never binds stays a NameError", raises(u_free), "NameError: name 'w_nowhere_102' is not defined")
check("bound later in the loop's previous turn", u_loop(), 0)
check("bound in the previous turn, read in the next", u_loop_ok(), 10)
check("global declared: NameError", raises(u_global), "NameError: name 'g_nowhere_102' is not defined")
check("a closure reading its enclosing function's later binding", u_nested(), 5)
def u_catch():
    try:
        v_102 = v_102 + 1
    except NameError as e:
        return type(e).__name__ + " caught by except NameError"
check("UnboundLocalError is a NameError", u_catch(), "UnboundLocalError caught by except NameError")
check("issubclass", issubclass(UnboundLocalError, NameError), True)

# ── a set iterator notices the set changing size ─────────────────────────
s1 = {1, 2, 3}
it1 = iter(s1)
first = next(it1)
s1.add(99)
check("next after add", raises(lambda: next(it1)), "RuntimeError: Set changed size during iteration")
check("... and again", raises(lambda: next(it1)), "RuntimeError: Set changed size during iteration")
s2 = {1, 2, 3}
it2 = iter(s2)
next(it2)
s2.discard(1)
s2.discard(2)
check("next after discard", raises(lambda: next(it2)), "RuntimeError: Set changed size during iteration")
s3 = {1, 2}
it3 = iter(s3)
check("an unchanged set iterates to the end", sorted([next(it3), next(it3)]), [1, 2])
check("... then StopIteration", raises(lambda: next(it3)), "StopIteration: ")
s4 = {5}
check("list() of a set's iterator", list(iter(s4)), [5])
fs = frozenset([1, 2])
check("a frozenset iterates", sorted(list(iter(fs))), [1, 2])
s5 = {1, 2, 3}
it5 = iter(s5)
next(it5)
s5.add(4)
s5.discard(4)
check("the same size again: not noticed (CPython checks the size only)", len(list(it5)), 2)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT102 PASSED ===")
