# vm_audit51 - native text services for editors (src/builtins/text.cpp):
# completion words and the completion index, the symbol outline, syntax
# checking through the real parser, Myers line diff (and its gutter
# classification, checked against lib/ide_scm.ny's LineDiff on random
# edits), workspace listing and search, folding ranges, line statistics,
# TODO scanning and the conservative formatter. Same results on both
# engines.
import "lib/ide_scm.ny"

var pass_n = 0
var fail_n = 0
def check(name, got, want):
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

def check_true(name, cond):
    check(name, cond, true)

var src = "import \"lib/x.ny\"\n\nclass Point(Base, Mixin):\n    count = 0\n    def __init__(self, x, y=0):\n        self.x = x\n        self.y = y\n        self.x = 3\n    def move(self, dx):\n        # TODO(bob): clamp\n        return self.x + dx\n\ndef helper(a, *rest):\n    \"\"\"doc\n    def not_a_function():\n    \"\"\"\n    var s = \"# TODO not a comment\"\n    return a  # FIXME: check\n\nvar total = 1\nconst LIMIT = 10\nMAX_N = 5\n"

print("== ny_symbols ==")
var syms = ny_symbols(src)
check("symbol count", len(syms), 10)
check("class", syms[0], ["Point", "class", 2, 6, "", "Base, Mixin", 0])
check("class var", syms[1][1], "field")
check("method", syms[2], ["__init__", "method", 4, 8, "Point", "(self, x, y=0)", 1])
check("field once", syms[3][0] + syms[4][0], "xy")
check("function", syms[6][0] + " " + syms[6][1] + " " + syms[6][5], "helper function (a, *rest)")
check("not inside docstring", syms[7][0], "total")
check("constant", syms[8][1] + " " + syms[9][1], "constant constant")
check("list input", len(ny_symbols(string_split(src, "\n"))), 10)

print("== text_words ==")
check("words", text_words("alpha beta alpha gamma_1 ab x_y", 3), ["alpha", "beta", "gamma_1", "x_y"])
check("min len 2", text_words("ab c ab", 2), ["ab"])

print("== completion index ==")
var h = ac_index_new()
ac_index_set_base(h, ["while", "print", "len"], ["keyword", "builtin", "builtin"])
var counts = ac_index_scan(h, src, 3)
check("index symbols", counts[0], 10)
check_true("index words", counts[1] > 10)
var r = ac_index_rank(h, "pnt", 5, "")
check("rank best", r[0][0], "Point")
check("rank kind", r[1][0], "class")
var r2 = ac_index_rank(h, "hel", 5, "hel")
check("rank function first", r2[0][0], "helper")
var r3 = ac_index_rank(h, "wh", 5, "")
check("base keyword", r3[0][0], "while")
check("exclude", len(ac_index_rank(h, "helper", 5, "helper")[0]), 0)
check("unknown handle", ac_index_rank(99999, "a", 5, ""), [[], []])

print("== ny_check_syntax ==")
check("clean", ny_check_syntax("def f(x):\n    return x\n"), [])
var bad = ny_check_syntax("var a = 1\nvar b = (2 +\nvar c = 3\n")
check("one error", len(bad), 1)
check_true("has message", string_find(bad[0][2], "Expected") >= 0)
check("lines input", len(ny_check_syntax(["def f(:", "    pass"])), 1)

print("== text_diff ==")
check("replace + append", text_diff(["a", "b", "c", "d"], ["a", "x", "c", "d", "e"]), [[1, 1, 1, 1], [4, 0, 4, 1]])
check("equal", text_diff(["a", "b"], ["a", "b"]), [])
check("insert into empty", text_diff([], ["n"]), [[0, 0, 0, 1]])
check("delete all", text_diff(["a", "b"], []), [[0, 2, 0, 0]])
check("middle delete", text_diff(["a", "b", "c"], ["a", "c"]), [[1, 1, 1, 0]])

print("== text_diff_classify agrees with LineDiff ==")
var ld = LineDiff()
ld.max_d = 100000
random_seed(7)
var words = ["alpha", "beta", "gamma", "delta", "eps"]
var trial = 0
var agree = 0
while trial < 60:
    var a = []
    var n = random_int(0, 12)
    var i = 0
    while i < n:
        a.append(words[random_int(0, 4)])
        i = i + 1
    var b = []
    i = 0
    while i < len(a):
        var op = random_int(0, 5)
        if op == 0:
            i = i + 1
        elif op == 1:
            b.append("new" + str(random_int(0, 3)))
            b.append(a[i])
            i = i + 1
        elif op == 2:
            b.append("chg")
            i = i + 1
        else:
            b.append(a[i])
            i = i + 1
    if random_int(0, 3) == 0:
        b.append("tail")
    var want = ld.classify(a, b, len(b))
    var got = text_diff_classify(a, b, len(b))
    if want == got:
        agree = agree + 1
    else:
        print("  differs: a=" + str(a) + " b=" + str(b) + " LineDiff=" + str(want) + " native=" + str(got))
    trial = trial + 1
check("60 random edits classified identically", agree, 60)
check("no base: all added", text_diff_classify(none, ["x", "y"], 2), [1, 1])
check("deletion marker", text_diff_classify(["a", "b", "c"], ["a", "c"], 2), [3, 0])

print("== workspace listing and search ==")
var root = "/tmp/ny_vm_audit51_" + string_replace(str(time_ms()), ".", "_") + "_" + str(random_int(0, 999999))
fs_mkdirs(root + "/sub/deep")
fs_mkdirs(root + "/build")
fs_mkdirs(root + "/.git")
write_file(root + "/a.ny", "def alpha():\n    # TODO: first\n    return 1\n")
write_file(root + "/sub/b.ny", "class Beta(Base):\n    def run(self):\n        return alpha()\n")
write_file(root + "/sub/deep/c.txt", "alpha and ALPHA and alphabet\n")
write_file(root + "/build/skip.ny", "alpha\n")
write_file(root + "/.git/HEAD", "alpha\n")
var files = fs_list_files(root, {})
check("listing skips build/.git, sorted, files first", files, ["a.ny", "sub/b.ny", "sub/deep/c.txt"])
check("full paths", fs_list_files(root, {"full": true})[0], root + "/a.ny")
check("depth limit", fs_list_files(root, {"depth": 0}), ["a.ny"])
var hits = fs_search(root, "alpha", {})
check("case-insensitive hits", len(hits), 5)
check("hit shape", hits[0], ["a.ny", 0, 4, "def alpha():", 5])
check("case-sensitive", len(fs_search(root, "alpha", {"case": true})), 4)
check("whole word", len(fs_search(root, "alpha", {"word": true})), 4)
check("regex", len(fs_search(root, "al+pha\\(", {"regex": true})), 2)
check("include glob", len(fs_search(root, "alpha", {"include": "*.txt"})), 3)
check("skip_files", len(fs_search(root, "alpha", {"skip_files": ["a.ny"]})), 4)
var ws_syms = fs_symbols(root, {})
check("workspace symbols", len(ws_syms), 3)
check("workspace symbol shape", ws_syms[1], ["sub/b.ny", "Beta", "class", 0, 6, ""])
var todos = fs_todos(root, [], 100)
check("workspace todos", todos, [["a.ny", 1, 6, "TODO", "first", ""]])

print("== folding, statistics, TODOs, formatting ==")
check("fold ranges", text_fold_ranges(src), [[2, 10], [4, 7], [8, 10], [12, 17], [13, 15]])
check("region markers", text_fold_ranges("# region x\na = 1\n# endregion\n"), [[0, 2]])
check("line stats", text_line_stats(src), [23, 15, 1, 4, 3])
check("todos", text_todos(src), [[9, 10, "TODO", "clamp", "bob"], [17, 16, "FIXME", "check", ""]])
check("format", text_format_nython("def f( a,b ):\n  x=a+b\n  if x==3:\n        return x\n\n\n\n  return 0  \n", "    ", {}),
      "def f( a, b ):\n    x = a+b\n    if x == 3:\n        return x\n\n    return 0\n")
check("format keeps kwargs tight", text_format_nython("f(a=1, b = 2)\n", "    ", {}), "f(a=1, b=2)\n")
check("format leaves strings", text_format_nython("s = \"a=b,c\"\n", "    ", {}), "s = \"a=b,c\"\n")
check("format tabs unit", text_format_nython("if x:\n    y = 1\n", "\t", {}), "if x:\n\ty = 1\n")

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT51 PASSED ===")
else:
    print("=== VM_AUDIT51 FAILED ===")
