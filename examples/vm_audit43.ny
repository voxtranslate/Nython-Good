# vm_audit43.ny - the editor buffer and source control, without a window.
#
#   EditorBuffer (ide_editor.ny): VS Code's final-newline model, undo steps
#     (typing runs, typing over a selection, grouped multi-line operations),
#     newline indentation that keeps tabs, in-place line edits, indentation
#     detection and conversion.
#   LineDiff (lib/ide_scm.ny): the Myers diff behind the gutter's change bars.
#   GitRepo (lib/ide_scm.ny): status, stage, commit and HEAD contents in a
#     throwaway repository - skipped, not failed, when git is not installed.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit43.ny
#     ./build/nython-cli --vm examples/vm_audit43.ny

import "ide_editor.ny"
import "lib/ide_scm.ny"

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

# ── final newline: an empty last line, as in VS Code ────────────────────────
var b = EditorBuffer("t.ny", "a\nb\n")
check("lines with final newline", b.line_count, 3)
check("last line empty", b.get_line(2), "")
check("round trip", b.text_for_save(), "a\nb\n")
var b2 = EditorBuffer("t.ny", "a\nb")
check("no final newline", b2.line_count, 2)
check("round trip no newline", b2.text_for_save(), "a\nb")
var bc = EditorBuffer("t.ny", "x\r\ny\r\n")
check("crlf kept", bc.text_for_save(), "x\r\ny\r\n")
check("crlf lines", bc.line_count, 3)

# ── typing is one undo step; typing over a selection is one step ────────────
var t = EditorBuffer("t.ny", "val = 1\n")
t.coalesce = true
t.cursor_row = 1
t.cursor_col = 0
t.insert_text_typed("x")
t.insert_text_typed("y")
t.insert_text_typed("z")
check("typed", t.get_line(1), "xyz")
t.undo()
check("typing run undone at once", t.get_all_text(), "val = 1\n")
t.redo()
check("redo", t.get_line(1), "xyz")
# Replace "val" by typing, as when a selection is typed over.
t.begin_group()
t.delete_range(0, 0, 0, 3)
t.continue_group()
t.insert_text_typed("n")
t.insert_text_typed("u")
t.insert_text_typed("m")
check("replaced", t.get_line(0), "num = 1")
t.undo()
check("selection + typing undone together", t.get_line(0), "val = 1")

# ── newline keeps the line's own indentation, tabs included ─────────────────
var tb = EditorBuffer("t.ny", "\tif x:")
tb.indent_unit = "\t"
tb.cursor_row = 0
tb.cursor_col = 6
tb.insert_newline()
check("tab indent kept + one level", tb.get_line(1), "\t\t")
check("caret after indent", tb.cursor_col, 2)
tb.undo()
check("newline undone", tb.line_count, 1)
tb.redo()
check("redo restores the tab indent", tb.get_line(1), "\t\t")
var sb = EditorBuffer("t.ny", "  if x:")
sb.indent_unit = "  "
sb.cursor_row = 0
sb.cursor_col = 7
sb.insert_newline()
check("two-space unit", sb.get_line(1), "    ")

# ── multi-line insert / delete edit the line list in place ──────────────────
var m = EditorBuffer("t.ny", "one\ntwo\nthree")
var lines_before = m.lines
m.cursor_row = 1
m.cursor_col = 1
m.insert_text("X\nY\nZ")
check("multi insert", m.get_all_text(), "one\ntX\nY\nZwo\nthree")
check("same list object", m.lines == lines_before, true)
m.delete_range(1, 1, 3, 1)
check("multi delete", m.get_all_text(), "one\ntwo\nthree")
m.undo()
check("undo delete", m.get_all_text(), "one\ntX\nY\nZwo\nthree")
m.undo()
check("undo insert", m.get_all_text(), "one\ntwo\nthree")
check("line count tracked", m.line_count, 3)

# ── grouped operations: open_group / close_group ────────────────────────────
var g = EditorBuffer("t.ny", "a\nb\nc")
var was = g.open_group()
g.insert_at(0, 0, "# ")
g.insert_at(1, 0, "# ")
g.insert_at(2, 0, "# ")
g.close_group(was)
check("grouped edits", g.get_all_text(), "# a\n# b\n# c")
g.undo()
check("one undo for the group", g.get_all_text(), "a\nb\nc")

# ── indentation: detect and convert ─────────────────────────────────────────
var d4 = EditorBuffer("t.ny", "def f():\n    if x:\n        y = 1\n    return 2\n")
var g4 = detect_indentation(d4)
check("detect spaces", g4[0], true)
check("detect size 4", g4[1], 4)
var d2 = EditorBuffer("t.ny", "a:\n  b:\n    c\n  d\n")
check("detect size 2", detect_indentation(d2)[1], 2)
var dt = EditorBuffer("t.ny", "a:\n\tb\n\tc:\n\t\td\n")
check("detect tabs", detect_indentation(dt)[0], false)
check("detect nothing", detect_indentation(EditorBuffer("t.ny", "a\nb\n")), none)
var cv = EditorBuffer("t.ny", "def f():\n    if x:\n        y = 1\n      z\n")
cv.cursor_row = 2
cv.cursor_col = 9
var n = cv.convert_indentation(true, 4)
check("converted lines", n, 3)
check("to tabs", cv.get_line(2), "\t\ty = 1")
check("remainder stays spaces", cv.get_line(3), "\t  z")
check("caret follows the conversion", cv.cursor_col, 3)
cv.undo()
check("conversion is one undo step", cv.get_line(2), "        y = 1")
cv.redo()
cv.convert_indentation(false, 4)
check("back to spaces", cv.get_line(2), "        y = 1")

# ── LineDiff: what the gutter shows ─────────────────────────────────────────
var ld = LineDiff()
check("no change", ld.classify(["a", "b", "c"], ["a", "b", "c"], 3), [0, 0, 0])
check("added line", ld.classify(["a", "c"], ["a", "b", "c"], 3), [0, 1, 0])
check("modified line", ld.classify(["a", "b", "c"], ["a", "B", "c"], 3), [0, 2, 0])
check("deleted below", ld.classify(["a", "b", "c"], ["a", "c"], 2), [3, 0])
check("new file", ld.classify(none, ["x", "y"], 2), [1, 1])
check("only first nb lines used", ld.classify(["a"], ["a", "zzz"], 1), [0])

# ── GitRepo in a throwaway repository ───────────────────────────────────────
var gv = os_exec("git --version 2>&1")
if gv != none and string_startswith(gv, "git version"):
    var dir = "/tmp/ny_audit43_repo"
    os_exec("rm -rf " + dir)
    os_mkdir(dir)
    write_file(dir + "/f.ny", "one\ntwo\n")
    os_exec("cd " + dir + " && git init -q && git -c user.name=t -c user.email=t@t add -A && git -c user.name=t -c user.email=t@t commit -q -m init")
    var repo = GitRepo()
    check("probe", repo.probe(dir), true)
    check("clean", len(repo.changes), 0)
    check("head lines keep the final newline", repo.head_lines(dir + "/f.ny"), ["one", "two", ""])
    write_file(dir + "/f.ny", "one\nTWO\n")
    write_file(dir + "/g.ny", "new\n")
    repo.refresh()
    check("two changes", len(repo.changes), 2)
    check("modified letter", repo.status_of(dir + "/f.ny").letter(false), "M")
    check("untracked letter", repo.status_of(dir + "/g.ny").letter(false), "U")
    repo.stage("f.ny")
    check("staged", len(repo.staged()), 1)
    os_exec("cd " + dir + " && git config user.name t && git config user.email t@t")
    check("commit", repo.commit("change two", dir + "/../ny_audit43_msg.txt"), true)
    check("log", string_find(repo.log(1)[0], "change two") >= 0, true)
    check("unstaged left", len(repo.unstaged()), 1)
    os_exec("rm -rf " + dir)
else:
    print("(git not installed: repository checks skipped)")

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT43 PASSED ===")
else:
    print("=== VM_AUDIT43 FAILED ===")
