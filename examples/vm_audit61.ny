# vm_audit61.ny - Nython-only value rules and the VM's builtin bridge (round 74).
#
#   operator members  1.+(2, 3) is 1 + 2 + 3; a comparison member chains;
#                     class_name / type_name / to_string on plain values
#   bridge            the VM reaches most builtins through the interpreter's;
#                     values cross exactly (big ints, tuples, typed dict keys),
#                     a builtin that changes its argument changes the caller's
#                     object, and a container handed back is the same object
#   json              integers past 64 bits decode exactly
#
# vm_audit60.ny holds the Python-valued checks; these have no Python
# equivalent. Must pass on both engines:
#     ./build/nython-cli examples/vm_audit61.ny
#     ./build/nython-cli --vm examples/vm_audit61.ny

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

def raises(f):
    try:
        f()
    except Exception:
        return "error"
    return "no error"

# ── operator members ─────────────────────────────────────────────────────
check("1.+(2, 3)", 1.+(2, 3), 6)
check("1.+(2)", 1.+(2), 3)
check("10.-(1, 2)", 10.-(1, 2), 7)
check("2.**(3)", 2.**(3), 8)
check("7.//(2)", 7.//(2), 3)
check("str +", "a".+("b", "c"), "abc")
check("list +", [1].+([2], [3]), [1, 2, 3])
check("1.<(2, 3)", 1.<(2, 3), true)
check("1.<(3, 2)", 1.<(3, 2), false)
check("2.==(2)", 2.==(2), true)
check("big +", (2 ** 64).+(1), 18446744073709551617)
check("no operand", raises(lambda: 1.+()), "error")
check("int class_name", 5.class_name(), "int")
check("str type_name", "s".type_name(), "str")
check("float to_string", (2.5).to_string(), "2.5")
check("list class_name", [1, 2].class_name(), "list")
check("tuple class_name", (1, 2).class_name(), "tuple")
check("bool class_name", true.class_name(), "bool")
check("print is function", print is function, true)
check("len is function", len is function, true)

# ── the bridge ───────────────────────────────────────────────────────────
# os_getenv(name, default) hands its default back untouched, so it shows
# exactly what crosses the bridge on the VM (and is a plain call on the
# interpreter).
var big = 2 ** 70
check("big int crosses", os_getenv("NY_AUDIT61_UNSET", big), 1180591620717411303424)
check("negative big crosses", os_getenv("NY_AUDIT61_UNSET", -big), -1180591620717411303424)
check("tuple crosses", os_getenv("NY_AUDIT61_UNSET", (1, "a")), (1, "a"))
check("typed keys cross", os_getenv("NY_AUDIT61_UNSET", {1: "x", "1": "y", (2, 3): "t"}),
      {1: "x", "1": "y", (2, 3): "t"})
var lst = [1, [2]]
check("same list back", os_getenv("NY_AUDIT61_UNSET", lst) is lst, true)
check("nested identity", os_getenv("NY_AUDIT61_UNSET", lst)[1] is lst[1], true)

# tensor2d_set(t, row, col, width, v) writes into t and returns it.
var t = [0.0, 0.0, 0.0, 0.0]
var r = tensor2d_set(t, 1, 0, 2, 5.0)
check("argument changed", t, [0.0, 0.0, 5.0, 0.0])
check("returns the argument", r is t, true)
var inner = [9]
var outer = [inner, [8]]
var sh = random_shuffle(outer)
check("shuffle keeps elements", (sh[0] is inner) or (sh[1] is inner), true)
check("shuffle leaves source", outer[0] is inner, true)

# ── json ─────────────────────────────────────────────────────────────────
check("json big int", json_decode("123456789012345678901234567890") + 1, 123456789012345678901234567891)
check("json negative big", json_decode("-123456789012345678901234567890"), -123456789012345678901234567890)
check("json encode big", json_encode([2 ** 70, -(2 ** 70)]), "[1180591620717411303424, -1180591620717411303424]")

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT61 PASSED ===")
