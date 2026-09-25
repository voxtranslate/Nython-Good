# vm_audit44.ny - lib/ide_debugger.ny, the record-and-replay debugger.
#
# Part 1 replays a hand-written recording, so every expected position is
# known exactly. Part 2 records a real program with `ny_test --trace` (the
# IDE's F5) and checks the recording itself: every statement, the frame's
# variables, the program's output and the uncaught exception with its line.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit44.ny
#     ./build/nython-cli --vm examples/vm_audit44.ny

import "lib/ide_debugger.ny"

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

# ── Part 1: a known recording ───────────────────────────────────────────────
# main.ny:  1 def f(n):   2   var a = n * 2   3   return a
#           5 var x = f(4)   6 print(x)   7 var y = f(1)
var F = "/w/main.ny"
def step(line, depth, fn, vars):
    return "{\"f\":\"" + F + "\",\"l\":" + str(line) + ",\"d\":" + str(depth) + ",\"fn\":\"" + fn + "\",\"v\":" + vars + "}"

var rec = [step(5, 0, "<module>", "{}"),
           step(2, 1, "f", "{\"n\":\"4\"}"),
           step(3, 1, "f", "{\"a\":\"8\",\"n\":\"4\"}"),
           step(6, 0, "<module>", "{\"x\":\"8\"}"),
           "{\"o\":\"8\"}",
           step(7, 0, "<module>", "{\"x\":\"8\"}"),
           step(2, 1, "f", "{\"n\":\"1\"}"),
           step(3, 1, "f", "{\"a\":\"2\",\"n\":\"1\"}"),
           "{\"x\":\"ValueError: boom \\\"quoted\\\"\",\"at\":\"/w/main.ny:3\"}"]
write_file("/tmp/ny_audit44.jsonl", string_join(rec, "\n") + "\n")

var s = DebugSession()
check("load", s.load("/tmp/ny_audit44.jsonl"), true)
check("steps", s.n, 7)
check("outputs", s.outputs, ["8"])
check("exception text (escaped quotes decoded)", s.exception, "ValueError: boom \"quoted\"")
check("exception location", s.exception_at, "/w/main.ny:3")

var no_breaks = {}
s.start(no_breaks)
check("starts at first step", s.line_at(s.pos), 5)
check("state paused", s.state, "paused")
s.step_into()
check("step into enters f", s.line_at(s.pos), 2)
check("function", s.function(), "f")
check("variables decoded", s.variables(), [["n", "4"]])
check("value_of", s.value_of("n"), "4")
check("value_of missing", s.value_of("zz"), none)
check("stack depth", len(s.stack()), 2)
check("stack caller line", s.stack()[1][2], 5)
s.step_out()
check("step out returns to caller", s.line_at(s.pos), 6)
check("output before print", s.output_so_far(), 0)
s.step_over()
check("step over stays in frame", s.line_at(s.pos), 7)
check("output after print", s.output_so_far(), 1)
s.step_over()
check("stepping past the end ends", s.state, "ended")
check("and lands on the last recorded step", s.pos, 6)
s.step_back()
check("step back", s.pos, 5)
check("step back resumes", s.state, "paused")

var breaks = {}
breaks[F + ":3"] = true
s.start(breaks)
check("start stops at first breakpoint", s.pos, 2)
s.continue_fwd(breaks)
check("continue to next hit", s.pos, 6)
check("second hit variables", s.value_of("a"), "2")
check("continue past last hit ends", s.continue_fwd(breaks), false)
check("ended", s.state, "ended")
check("ends on the last step", s.pos, 6)
check("reverse continue", s.continue_back(breaks), true)
check("reverse continue lands on the previous hit", s.pos, 2)
check("reverse continue with no earlier hit", s.continue_back(breaks), false)
check("goes to the start", s.pos, 0)
s.seek(0)
check("seek", s.line_at(s.pos), 5)
s.seek(99)
check("seek clamps", s.pos, 6)
s.stop()
check("stop", s.active, false)

# ── Part 2: record a real program ───────────────────────────────────────────
var prog = "/tmp/ny_audit44_prog.ny"
write_file(prog, "def total(n):\n    var t = 0\n    var i = 0\n    while i < n:\n        t = t + i\n        i = i + 1\n    return t\n\nvar r = total(3)\nprint(\"total\", r)\nvar z = [1, 2]\nprint(z[5])\n")
var exe = "./ny_test"
if not os_exists(exe):
    exe = "./build/nython-cli"
if os_exists(exe):
    os_exec(exe + " --trace /tmp/ny_audit44_real.jsonl " + prog + " > /dev/null 2>&1")
    var real = DebugSession()
    check("real load", real.load("/tmp/ny_audit44_real.jsonl"), true)
    check("real steps", real.n, 15)
    check("real output (print with two arguments)", real.outputs, ["total 3"])
    check("real exception", real.exception, "IndexError: index 5 out of range (length 2)")
    check("real exception line", real.exception_at, prog + ":12")
    real.start({})
    real.seek(real.n - 1)
    check("last step is the failing line", real.line_at(real.pos), 12)
    check("module variables at the end", real.value_of("r"), "3")
    var b2 = {}
    b2[prog + ":5"] = true
    real.start(b2)
    real.continue_fwd(b2)
    check("loop breakpoint, 2nd iteration", real.value_of("i"), "1")
    check("frame variable t", real.value_of("t"), "0")
    real.continue_fwd(b2)
    check("3rd iteration", real.value_of("t"), "1")
    check("in function total", real.function(), "total")
else:
    print("(no nython binary found: recording checks skipped)")

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT44 PASSED ===")
else:
    print("=== VM_AUDIT44 FAILED ===")
