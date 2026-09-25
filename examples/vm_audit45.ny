# vm_audit45.ny - runtime fixes found while driving the IDE end to end.
#
#   json_encode / json_decode  one RFC 8259 codec for both engines
#                              (include/NyJson.hpp). The interpreter wrote
#                              strings unescaped and decoded only flat objects;
#                              the VM decoded "é" as the letters "u00e9".
#   print(a, b, sep=, end=)    the call form. The interpreter printed
#                              ('total', 6); the VM flattened real tuples.
#   list.pop(i) / insert(i, x) the VM ignored pop's index; the interpreter
#                              wrote insert(-1, x) to a key named "-1".
#   ==, !=                     the interpreter compared list elements by their
#                              printed form (nested lists never equal), called
#                              every two maps equal, and [1, 2] != [1, 2] true.
#   true == 1                  false on the VM only.
#   file_mtime(path)           new: what the IDE's workspace watcher polls.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit45.ny
#     ./build/nython-cli --vm examples/vm_audit45.ny

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

# ── JSON ────────────────────────────────────────────────────────────────────
var d = {}
d["text"] = "say \"hi\"\nnext\tline\\"
d["list"] = [1, 2.5, "x\"y", true, none]
d["nested"] = {"k": [1, {"deep": "v"}]}
var enc = json_encode(d)
check("encode escapes and sorts keys", enc,
      "{\"list\": [1, 2.5, \"x\\\"y\", true, null], \"nested\": {\"k\": [1, {\"deep\": \"v\"}]}, \"text\": \"say \\\"hi\\\"\\nnext\\tline\\\\\"}")
var back = json_decode(enc)
check("round trip string", back["text"], d["text"])
check("round trip list", back["list"], d["list"])
check("round trip nested", back["nested"]["k"][1]["deep"], "v")
check("round trip whole", back, d)
check("decode top-level array", json_decode("[1, \"a\", [2, 3]]"), [1, "a", [2, 3]])
check("decode unicode escape", json_decode("\"caf\\u00e9\""), "café")
check("decode surrogate pair", len(json_decode("\"\\ud83d\\ude00\"")), 1)
check("decode escapes", json_decode("\"a\\/b\\n\""), "a/b\n")
check("decode numbers", json_decode("[-3, 1.5e2, 0.25]"), [-3, 150.0, 0.25])
check("decode big int stays int", json_decode("123456789012"), 123456789012)
check("decode literals", json_decode("[true, false, null]"), [true, false, none])
check("decode whitespace", json_decode("  { \"a\" : 1 }  ")["a"], 1)
check("duplicate key: last wins", json_decode("{\"a\": 1, \"a\": 2}")["a"], 2)
check("invalid is none", json_decode("{\"a\": }"), none)
check("trailing garbage is none", json_decode("[1] x"), none)
check("unterminated is none", json_decode("\"abc"), none)
check("encode float keeps a point", json_encode(3.0), "3.0")
check("encode control char", json_encode("a" + chr(1)), "\"a\\u0001\"")
check("encode none", json_encode(none), "null")
check("stringify is the same codec", json_stringify([1, "a"]), json_encode([1, "a"]))

# ── list.pop(i) / insert(i, x) ──────────────────────────────────────────────
var a = [1, 2, 3, 4]
check("pop(i) returns the item", a.pop(1), 2)
check("pop(i) removes it", a, [1, 3, 4])
check("pop(-1)", a.pop(-1), 4)
check("pop()", a.pop(), 3)
check("left", a, [1])
a.insert(0, 0)
a.insert(-1, 9)
a.insert(100, 7)
check("insert clamps and counts from the end", a, [0, 9, 1, 7])

# ── equality ────────────────────────────────────────────────────────────────
check("nested lists equal", [[1, 2], [3]] == [[1, 2], [3]], true)
check("nested lists differ", [[1, 2]] == [[1, 3]], false)
check("maps with different keys", {"a": 1} == {"b": 2}, false)
check("maps equal", {"a": [1, {"b": 2}]} == {"a": [1, {"b": 2}]}, true)
check("list != equal list", [1, 2] != [1, 2], false)
check("map != equal map", {"a": 1} != {"a": 1}, false)
check("list is not a map", [] == {}, false)
check("int == float inside lists", [1.0, 2] == [1, 2], true)
check("true == 1", true == 1, true)
check("false == 0", false == 0, true)
check("string is not a number", "1" == 1, false)
class P:
    def __init__(self, x):
        self.x = x
var p1 = P(1)
check("instances compare by identity", p1 == P(1), false)
check("same instance", p1 == p1, true)

# ── file_mtime ──────────────────────────────────────────────────────────────
write_file("/tmp/ny_audit45_m.txt", "x")
var m1 = file_mtime("/tmp/ny_audit45_m.txt")
check("mtime of a file", m1 > 0, true)
check("mtime of a missing file", file_mtime("/tmp/ny_audit45_missing"), -1)
check("mtime of a folder", file_mtime("/tmp") > 0, true)

# ── print, both engines, checked through a subprocess ───────────────────────
var exe = "./ny_test"
if not os_exists(exe):
    exe = "./build/nython-cli"
if os_exists(exe):
    write_file("/tmp/ny_audit45_print.ny", "var r = 6\nprint(\"total\", r)\nprint(\"x\", \"y\", sep=\"-\")\nprint(\"no\", end=\"\")\nprint(\"-nl\")\nprint([1, 2], none, 2.5)\nprint()\nprint (1 + 2) * 3\nprint \"b\", 3\n")
    var want = "total 6\nx-y\nno-nl\n[1, 2] none 2.5\n\n9\nb 3"
    check("print on the interpreter", os_exec(exe + " /tmp/ny_audit45_print.ny"), want)
    check("print on the VM", os_exec(exe + " --vm /tmp/ny_audit45_print.ny"), want)
else:
    print("(no nython binary found: print checks skipped)")

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT45 PASSED ===")
else:
    print("=== VM_AUDIT45 FAILED ===")
