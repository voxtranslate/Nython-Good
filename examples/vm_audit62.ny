# vm_audit62.ny - the legacy flat tensor ops follow NumPy's type promotion
# (round 75): the result type depends on the operation. Integers stay
# integers through the operations closed over the integers and become floats
# through the ones that are not; floats stay floats. Every expected value is
# what NumPy gives for the same int64 / float64 arrays.
var passed = 0
var failed = 0
def check(name, got, expected):
    # type and value: 6 and 6.0 are different answers here
    if str(got) == str(expected) and type(got) == type(expected):
        passed += 1
    else:
        failed += 1
        print "FAIL:", name, "| got:", str(got), type(got), "| expected:", str(expected), type(expected)

var a = [1, 2, 3, 4]
var b = [5, 6, 7, 8]
var fa = [1.0, 2.0, 3.0, 4.0]

# closed over the integers: int in, int out
check("add ints", tensor_add(a, b), [6, 8, 10, 12])
check("sub ints", tensor_sub(b, a), [4, 4, 4, 4])
check("mul ints", tensor_mul(a, b), [5, 12, 21, 32])
check("dot ints", tensor_dot(a, b), 70)
check("sum ints", tensor_sum(a), 10)
check("max ints", tensor_max(b), 8)
check("min ints", tensor_min(a), 1)
check("abs ints", tensor_abs([-3, 0, 2]), [3, 0, 2])
check("neg ints", tensor_neg([1, -2]), [-1, 2])
check("sign ints", tensor_sign([-5, 0, 7]), [-1, 0, 1])
check("scale int by int", tensor_scale(a, 3), [3, 6, 9, 12])
check("broadcast length-1 int", tensor_add(a, [10]), [11, 12, 13, 14])
check("relu int negative", relu(-5), 0)
check("relu int positive", relu(3), 3)

# not closed over the integers: always float
check("div ints", tensor_div([6, 9], [3, 2]), [2.0, 4.5])
check("mean ints", tensor_mean(a), 2.5)
check("sqrt ints", tensor_sqrt([4, 9]), [2.0, 3.0])
check("exp int", tensor_exp([0]), [1.0])

# one float operand makes the result float
check("add int+float", tensor_add(a, fa), [2.0, 4.0, 6.0, 8.0])
check("scale int by float", tensor_scale(a, 0.5), [0.5, 1.0, 1.5, 2.0])
check("dot int.float", tensor_dot(a, fa), 30.0)
check("relu float", relu(-2.5), 0.0)
check("relu float positive", relu(2.5), 2.5)

# floats stay floats
check("add floats", tensor_add(fa, fa), [2.0, 4.0, 6.0, 8.0])
check("sum floats", tensor_sum(fa), 10.0)
check("max floats", tensor_max(fa), 4.0)

# exactness: an integer sum or dot accumulates exactly in 64 bits
var big = 4611686018427387904
check("exact int sum", tensor_sum([big, 1, -big]), 1)
check("exact int dot", tensor_dot([3037000499, 1], [3037000499, 1]), 9223372030926249002)
# a result a double cannot hold exactly is not rounded into a wrong integer
var near = 9007199254740993
check("element beyond 2^53 is a float, not a wrong int", type(tensor_add([near], [0])[0]), "float")

print "Results:", passed, "passed,", failed, "failed"
