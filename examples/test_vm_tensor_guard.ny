# test_vm_tensor_guard.ny
#
# The VM's tensor builtins guarded only their first argument and then
# dereferenced the second one's list pointer. Passing none — which happens
# whenever an earlier tensor call returns none — was a null dereference, and
# sentiment_classifier.ny and transformer_demo.ny segfaulted because of it.
#
# Run under both engines:  nython this.ny   and   nython --vm this.ny
import "lib/nytorch.ny"

var failures = 0

def check(label, got, want):
    if str(got) == str(want):
        print "  ok   " + label
    else:
        print "  FAIL " + label + "  got=" + str(got) + "  want=" + str(want)
        failures = failures + 1

var a = [1.0, 2.0, 3.0]
var b = [10.0, 20.0, 30.0]

print "=== tensor results ==="
check("tensor_add",  tensor_add(a, b),  [11.0, 22.0, 33.0])
check("tensor_dot",  tensor_dot(a, b),  140.0)
check("tensor_sum",  tensor_sum(a),     6.0)
check("tensor_mean", tensor_mean(a),    2.0)
check("tensor_max",  tensor_max(a),     3.0)

print "=== bad arguments raise instead of crashing ==="
# Before the guard these took down the process. Since the shared tensor
# kernels (round 74) a missing operand is a catchable TypeError on both
# engines, instead of a crash or a made-up result.
var raised = 0
try:
    tensor_add(a, none)
except e:
    raised = raised + 1
try:
    tensor_dot(none, none)
except e:
    raised = raised + 1
try:
    tensor_sum(none)
except e:
    raised = raised + 1
check("tensor_add(a, none) / tensor_dot(none, none) / tensor_sum(none) raise", raised, 3)
var typed = ""
try:
    tensor_add(a, none)
except TypeError as e:
    typed = "TypeError"
check("the error is a TypeError", typed, "TypeError")

print ""
if failures == 0:
    print "PASS: tensor guard checks passed"
else:
    print "FAIL: " + str(failures) + " check(s) failed"
