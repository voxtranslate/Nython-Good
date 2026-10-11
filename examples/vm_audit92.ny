# vm_audit92.ny - "Why?" questions in the record-and-replay debugger, both
# engines (round 79; Nython only).
#
# Part 1: text_defuse(source), the static half - each line's reads, writes,
# controlling predicates (with the branch taken to reach the line), its
# function and kind, from the real parser.
# Part 2: the dynamic half - a real program recorded with `nython --trace`
# (os_run), then lib/ide_debugger.ny's DebugSession asked:
#   why_value(name, at)  why a variable has its value there: the dynamic
#       backward slice (Agrawal & Horgan, PLDI 1990; Korel & Laski 1988) -
#       the statements that wrote it, what they read, the predicates they
#       ran under, a parameter's call - and nothing else
#   why_not(file, line)  why a line never ran: the controlling predicate
#       that never went its way, with its last values, or the function
#       nobody called (the Whyline's "why didn't", Ko & Myers, ICSE 2008)
#
#     ./build/nython-cli examples/vm_audit92.ny
#     ./build/nython-cli --vm examples/vm_audit92.ny

import "lib/ide_debugger.ny"
import os

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), repr(got), repr(want)])

def du_of(src, line):
    var d = text_defuse(src)
    var e = d[line - 1]
    if e is None:
        return None
    return [e["kind"], e["reads"], e["writes"], e["ctrl"], e["branch"], e["func"], e["func_line"]]

# ── Part 1: text_defuse ──────────────────────────────────────────────────────
var PROG_LINES = [
    "def scale(v, k):",                      # 1
    "    r = v * k",                           # 2
    "    return r",                            # 3
    "",                                        # 4
    "def classify(xs, limit):",              # 5
    "    big = 0",                             # 6
    "    small = 0",                           # 7
    "    for x in xs:",                        # 8
    "        if x > limit:",                   # 9
    "            big = big + scale(x, 2)",     # 10
    "        else:",                           # 11
    "            small = small + x",           # 12
    "    if big > 100:",                       # 13
    "        print(\"huge\")",                 # 14
    "    return big + small",                  # 15
    "",                                        # 16
    "def never():",                           # 17
    "    return 1",                            # 18
    "",                                        # 19
    "data = [3, 8, 1, 12]",                    # 20
    "lim = 5",                                 # 21
    "total = classify(data, lim)",             # 22
    "print(total)",                            # 23
    "q = 0",                                   # 24
    "while q < 3:",                            # 25
    "    q = q + 1",                           # 26
    "    if q == 7:",                          # 27
    "        break",                           # 28
    "else:",                                   # 29
    "    q = q * 10",                          # 30
    "if q > 100:",                             # 31
    "    print(\"big q\")"]                    # 32
var PROG = "\n".join(PROG_LINES) + "\n"

var DU = text_defuse(PROG)
check("one entry per line (and one past the last newline)", len(DU) >= 32, True)
check("a def line", du_of(PROG, 1)[0:3] + du_of(PROG, 1)[5:], ["def", [], ["scale"], "", 0])
check("an assignment in a function", du_of(PROG, 2), ["assign", ["k", "v"], ["r"], [], [], "scale", 1])
check("a return", du_of(PROG, 3)[0:2], ["return", ["r"]])
check("a blank line", du_of(PROG, 4), None)
check("an if inside a for", du_of(PROG, 9), ["if", ["limit", "x"], [], [8], ["body"], "classify", 5])
check("the then branch: both predicates, innermost first", du_of(PROG, 10),
      ["assign", ["big", "scale", "x"], ["big"], [9, 8], ["then", "body"], "classify", 5])
check("the else branch", du_of(PROG, 12)[3:5], [[9, 8], ["else", "body"]])
check("a for header writes its target", du_of(PROG, 8)[0:3], ["for", ["xs"], ["x"]])
check("a call statement at the top level", du_of(PROG, 14)[3:6], [[13], ["then"], "classify"])
check("a loop's else", du_of(PROG, 30)[3:5], [[25], ["loop-else"]])
check("break under an if in a while", du_of(PROG, 28)[0:1] + du_of(PROG, 28)[3:5], ["break", [27, 25], ["then", "body"]])
check("module level: no function", du_of(PROG, 22)[1:3] + du_of(PROG, 22)[5:], [["classify", "data", "lim"], ["total"], "", 0])

var SRC2 = "\n".join([
    "def outer(xs, b):",                       # 1
    "    \"\"\"Docs.\"\"\"",                    # 2
    "    xs.append(4)",                         # 3
    "    obj.f = b",                            # 4
    "    ys = [y * 2 for y in xs]",             # 5
    "    f = lambda a: a + b",                  # 6
    "    t = 0",                                # 7
    "    t += len(ys)",                         # 8
    "    if (n := len(xs)) > 2:",               # 9
    "        pass",                             # 10
    "    for i, j in pairs:",                   # 11
    "        pass",                             # 12
    "    try:",                                 # 13
    "        risky()",                          # 14
    "    except ValueError as e:",              # 15
    "        log(e)",                           # 16
    "    def inner():",                         # 17
    "        return z",                         # 18
    "    return t"]) + "\n"                     # 19
check("a mutating method call writes its receiver", du_of(SRC2, 3)[1:3], [["xs"], ["xs"]])
check("an attribute assignment writes the object", du_of(SRC2, 4)[1:3], [["b", "obj"], ["obj"]])
check("a comprehension's own variable is not read", du_of(SRC2, 5)[1:3], [["xs"], ["ys"]])
check("a lambda's parameter is not read", du_of(SRC2, 6)[1:3], [["b"], ["f"]])
check("an augmented assignment reads and writes", du_of(SRC2, 8)[1:3], [["len", "t", "ys"], ["t"]])
check("a walrus in a test writes its name", du_of(SRC2, 9)[1:3], [["len", "xs"], ["n"]])
check("a for loop's tuple target", du_of(SRC2, 11)[1:3], [["pairs"], ["i", "j"]])
check("an except clause: its line is a predicate, `as` writes", [du_of(SRC2, 15)[0], du_of(SRC2, 15)[2], du_of(SRC2, 16)[3:5]],
      ["except", ["e"], [[15], ["except"]]])
check("a nested def: its body is its own function", [du_of(SRC2, 17)[0], du_of(SRC2, 17)[2], du_of(SRC2, 17)[5],
                                                    du_of(SRC2, 18)[1], du_of(SRC2, 18)[5:]],
      ["def", ["inner"], "outer", ["z"], ["inner", 17]])
check("a docstring line", [text_defuse(SRC2)[1]["doc"], text_defuse(SRC2)[2]["doc"]], [True, False])
var BAD = text_defuse("x = = 1\n")
check("a syntax error: entry 0 says so", [sorted(BAD[0].keys()), "Unexpected token" in BAD[0]["error"] or "invalid syntax" in BAD[0]["error"]], [["error"], True])

# ── Part 2: a recording, and the questions ───────────────────────────────────
var exe = "./ny_test"
if not os_exists(exe):
    exe = "./build/nython-cli"
var pid = os.getpid()
var prog = "/tmp/ny_audit92_" + str(pid) + "_prog.ny"
var rec_path = "/tmp/ny_audit92_" + str(pid) + ".jsonl"
write_file(prog, PROG)
var run = os_run([exe, "--trace", rec_path, prog])
check("the program ran under --trace", [run["code"] if type(run) == "map" else run.returncode], [0])

var s = DebugSession()
check("the recording loads", s.load(rec_path), True)
check("its output", s.outputs, ["44"])
s.start({})

def step_on(line, nth):
    # the nth step (1-based) on `line`
    var k = 0
    var seen = 0
    while k < s.n:
        if s.lines[k] == line:
            seen = seen + 1
            if seen == nth:
                return k
        k = k + 1
    return -1

def brief(entries):
    return [[e["kind"], e["line"]] for e in entries]

# why is big 40 at `return big + small`?
var at15 = step_on(15, 1)
var wb = s.why_value("big", at15)
check("why_value: the question first, with the value", [wb[0]["kind"], wb[0]["line"], wb[0]["value"]], ["value", 15, "40"])
check("why_value: the statement that last wrote it, and its value", [wb[1]["kind"], wb[1]["line"], wb[1]["value"], wb[1]["level"]],
      ["data", 10, "40", 1])
var lines_in = sorted(set([e["line"] for e in wb]))
check("the slice: big's writes, the loop, the test, the call and the module's data", lines_in, [6, 8, 9, 10, 15, 20, 21, 22])
check("the slice leaves out small's statements", [7 in lines_in, 12 in lines_in], [False, False])
var ctl = [e for e in wb if e["kind"] == "control"]
check("the predicate the write ran under", [ctl[0]["line"], "(then)" in ctl[0]["text"]], [9, True])
check("the earlier write it read (16, when x was 8)", [[e["line"], e["value"]] for e in wb if e["kind"] == "data" and e["line"] == 10],
      [[10, "40"], [10, "16"]])
var calls = [e for e in wb if e["kind"] == "call"]
check("parameters traced to the call", [calls[0]["line"], "passed to classify" in calls[0]["text"]], [22, True])
check("the steps are recording positions", [s.lines[wb[1]["step"]], s._fn_of(wb[1]["step"])], [10, "classify"])

# a parameter's value, inside the callee
var at3 = step_on(3, 2)
var wr = s.why_value("r", at3)
check("why_value in a callee: the write, then the call that passed v and k", brief(wr)[0:3],
      [["value", 3], ["data", 2], ["call", 10]])
check("the value of r on the second call", wr[0]["value"], "24")

# a loop's else
var wq = s.why_value("q", s.n - 1)
check("why_value at the end: the loop's else and its header", [brief(wq)[0:2], [e["line"] for e in wq if e["kind"] == "control"][0:1]],
      [[["value", 31], ["data", 30]], [25]])
check("q's value", wq[0]["value"], "30")

# why didn't line 14 run?
var wn = s.why_not(prog, 14)
check("why_not: the question", [wn[0]["kind"], wn[0]["line"]], ["question", 14])
check("why_not: the predicate that never chose its branch", [wn[1]["kind"], wn[1]["line"], wn[1]["value"]], ["predicate", 13, "false"])
check("why_not: with its last values", "was false each of 1 time (last: big = 40)" in wn[1]["text"], True)
var wn18 = s.why_not(prog, 18)
check("why_not: a function nobody called", [[e["kind"], e["line"]] for e in wn18], [["question", 18], ["never", 17]])
check("... and says so", wn18[1]["text"], "never() was never called")
var wn28 = s.why_not(prog, 28)
check("why_not: a break whose test was false each time", [wn28[1]["kind"], wn28[1]["line"],
                                                           "each of 3 times (last: q = 3)" in wn28[1]["text"]], ["predicate", 27, True])
check("why_not: the earlier evaluations listed too", len([e for e in wn28 if e["level"] == 2]), 2)
var wn32 = s.why_not(prog, 32)
check("why_not: a module-level if", [wn32[1]["line"], "(last: q = 30)" in wn32[1]["text"]], [31, True])
check("why_not on a line that ran", [[e["kind"], e["step"] >= 0] for e in s.why_not(prog, 10)], [["note", True]])
check("why_not on a blank line", s.why_not(prog, 16)[0]["text"], "line 16 is not the start of a statement")

os_remove(prog)
os_remove(rec_path)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + r[2] + " want " + r[3])
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT92 PASSED ===")
else:
    print("=== VM_AUDIT92 FAILED ===")
