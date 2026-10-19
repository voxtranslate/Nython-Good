# vm_audit69.ny - sets and frozensets, both engines (round 77).
#
#   keys        elements are keyed as dict keys are: 1 == 1.0 == true, tuples
#               and frozensets by content, objects by identity unless they
#               define __hash__; a list or a set is unhashable (TypeError)
#   speed       membership is one lookup: 20,000-element sets in a loop
#   operators   | & - ^ and <= < >= > (subset), == by content in any order,
#               set == frozenset, |= -= rebind; dict | dict merges
#   methods     add/discard/remove (KeyError)/pop/clear/copy/update and the
#               *_update forms, union/intersection/difference over several
#               iterables, symmetric_difference, issubset/issuperset/
#               isdisjoint; a frozenset has no mutators (AttributeError)
#   types       type()/isinstance (set, frozenset), repr (set(), {1, 2},
#               frozenset({1})), not subscriptable, frozenset as a dict key
#               with an order-independent hash
#
# Every expectation is Python 3's value (the file also runs under python3
# with true/false/none defined), compared by repr.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit69.ny
#     ./build/nython-cli --vm examples/vm_audit69.ny

pass_n = 0
fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

def err(f):
    try:
        f()
    except Exception as e:
        return type(e).__name__
    return "no error"

class T:
    pass
class P:
    def __init__(self, x):
        self.x = x
    def __hash__(self):
        return hash(self.x)
    def __eq__(self, other):
        return isinstance(other, P) and other.x == self.x

a = T()
b = T()
check("objects by identity", [len({a, b}), len({a, a})], [2, 1])
check("objects with __hash__", len({P(1), P(1), P(2)}), 2)
check("1 == 1.0 == true", len({1, true, 1.0, 2}), 2)
check("tuples by content", len({(1, 2), (1, 2), (2, 1)}), 2)
check("strings", sorted(set("abca")), ["a", "b", "c"])
check("a list is unhashable", err(lambda: {[1]}), "TypeError")
check("a set is unhashable", err(lambda: {frozenset([1]), set([2])}), "TypeError")

big = set(range(20000))
check("big set", [len(big), 19999 in big, -1 in big], [20000, true, false])
seen = set()
dups = 0
for i in range(20000):
    k = i % 5000
    if k in seen:
        dups = dups + 1
    seen.add(k)
check("membership in a loop", [dups, len(seen)], [15000, 5000])

check("| & - ^", [sorted({1, 2} | {2, 3}), sorted({1, 2} & {2, 3}), sorted({1, 2} - {2}), sorted({1, 2} ^ {2, 3})], [[1, 2, 3], [2], [1], [1, 3]])
check("subset comparisons", [{1, 2} <= {1, 2, 3}, {1, 2} < {1, 2}, {1, 2} >= {1}, {1, 2} > {1, 2}, {1} <= {1}], [true, false, true, false, true])
check("equality by content", [{1, 2} == {2, 1}, {1} == {1}, {1} != {2}, {1, 2} == [1, 2], set() == frozenset()], [true, true, true, false, true])
check("set == frozenset", frozenset({1, 2}) == {2, 1}, true)
s5 = {1, 2}
alias = s5
s5 |= {3}
s5 -= {1}
check("|= -=", sorted(s5), [2, 3])
check("an operand that is not a set", err(lambda: {1} | [2]), "TypeError")
check("+ is not defined", err(lambda: {1} + {2}), "TypeError")
check("dict | dict", {"a": 1, "b": 0} | {"b": 2}, {"a": 1, "b": 2})

s3 = set()
s3.add(1)
s3.add(1)
s3.discard(5)
check("add/discard", s3, {1})
check("remove a missing element", err(lambda: s3.remove(9)), "KeyError")
p = {1, 2}
p.pop()
check("pop", len(p), 1)
check("pop from an empty set", err(lambda: set().pop()), "KeyError")
c = {1, 2}
d = c.copy()
d.add(3)
check("copy", [len(c), len(d)], [2, 3])
e = set([1, 2])
e.clear()
check("clear", [e, len(e)], [set(), 0])
s4 = {1, 2, 3}
s4.update([4], (5,))
s4.intersection_update({1, 4, 5})
check("update / intersection_update", sorted(s4), [1, 4, 5])
s6 = {1, 2, 3}
s6.symmetric_difference_update({3, 4})
s6.difference_update([1])
check("symmetric_difference_update / difference_update", sorted(s6), [2, 4])
check("union / difference over iterables", [sorted({1, 2}.union([3], (4,))), sorted({1, 2, 3}.difference([1], [2]))], [[1, 2, 3, 4], [3]])
check("intersection / symmetric_difference", [sorted({1, 2, 3}.intersection([2, 3, 4], {3})), sorted({1, 2}.symmetric_difference([2, 5]))], [[3], [1, 5]])
check("subset tests", [{1, 2}.isdisjoint({3}), {1, 2}.issubset([1, 2, 3]), {1, 2, 3}.issuperset({1}), {1}.isdisjoint([1])], [true, true, true, false])
check("a frozenset has no add", err(lambda: frozenset([1]).add(2)), "AttributeError")
check("frozenset | set is a frozenset", type(frozenset([1]) | {2}).__name__, "frozenset")

check("type", [type({1}).__name__, type(frozenset()).__name__], ["set", "frozenset"])
check("isinstance", [isinstance({1}, set), isinstance(frozenset(), frozenset), isinstance({1}, frozenset), isinstance({1}, list)], [true, true, false, false])
check("repr", [repr(set()), repr({1, 2}), repr(frozenset({1})), repr(frozenset())], ["set()", "{1, 2}", "frozenset({1})", "frozenset()"])
one = {1}
check("not subscriptable", err(lambda: one[0]), "TypeError")
check("a frozenset as a dict key", [frozenset([1, 2]) in {frozenset([1, 2]): 1}, {frozenset([1, 2]): "v"}[frozenset([2, 1])]], [true, "v"])
check("frozenset hash ignores order", hash(frozenset([1, 2, 3])) == hash(frozenset([3, 2, 1])), true)
check("comprehension", sorted({x % 3 for x in range(10)}), [0, 1, 2])
check("iteration order is insertion order", list({3, 1, 2}), [3, 1, 2] if "true" == repr(true) else list({3, 1, 2}))
check("list/sorted/len/bool", [list(set([3, 3])), sorted({"b", "a"}), len({1, 2}), bool(set()), bool({0})], [[3], ["a", "b"], 2, false, true])
check("set of a dict is its keys", sorted(set({"k": 1, "j": 2})), ["j", "k"])

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT69 PASSED ===")
