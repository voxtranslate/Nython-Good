# vm_audit42.ny - lib/ide_workbench.ny, the IDE's model with no window:
# CommandRegistry (keys, chords, when-clauses), HitMap, Frecency,
# QuickInput, LineEdit, Notifications and NavHistory.
#
# Every value is asserted; the same file must pass on both engines:
#     ./build/nython-cli examples/vm_audit42.ny
#     ./build/nython-cli --vm examples/vm_audit42.ny

import "lib/ide_workbench.ny"

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

class Ev:
    def __init__(self, key, ctrl, shift, alt):
        self.key = key
        self.ctrl = ctrl
        self.shift = shift
        self.alt = alt

def ev(key):
    return Ev(key, false, false, false)

def cev(key):
    return Ev(key, true, false, false)

# ── CommandRegistry ─────────────────────────────────────────────────────────
var reg = CommandRegistry()
check("normalize order", reg.normalize("Shift+Ctrl+P"), "ctrl+shift+p")
check("normalize alias", reg.normalize("Ctrl+Esc"), "ctrl+escape")
check("normalize plus key", reg.normalize("Ctrl++"), "ctrl++")
check("normalize chord", reg.normalize("Ctrl+K  Ctrl+S"), "ctrl+k ctrl+s")
check("normalize pgdn", reg.normalize("Ctrl+PgDn"), "ctrl+pagedown")

reg.add("workbench.action.showCommands", "View", "Command Palette...", "Ctrl+Shift+P | F1", "")
reg.add("workbench.action.files.save", "File", "Save", "Ctrl+S", "")
reg.add("workbench.action.files.saveAll", "File", "Save All", "Ctrl+K S", "")
reg.add("undo", "Edit", "Undo", "Ctrl+Z", "!inputFocus")
reg.add("editor.action.selectAll", "Selection", "Select All", "Ctrl+A", "editorFocus")
reg.add("workbench.action.debug.start", "Run", "Start Debugging", "F5", "!inDebugMode")
reg.add("workbench.action.debug.continue", "Debug", "Continue", "F5", "inDebugMode")

check("has", reg.has("undo"), true)
check("has not", reg.has("nope"), false)
check("label", reg.label("workbench.action.files.save"), "File: Save")

var ctx = {"editorFocus": true, "inputFocus": false, "inDebugMode": false}
check("resolve simple", reg.resolve(cev("s"), ctx), "workbench.action.files.save")
check("resolve alternative 1", reg.resolve(Ev("p", true, true, false), ctx), "workbench.action.showCommands")
check("resolve alternative 2", reg.resolve(ev("f1"), ctx), "workbench.action.showCommands")
check("unbound key", reg.resolve(cev("q"), ctx), "")
check("when true", reg.resolve(cev("a"), ctx), "editor.action.selectAll")
ctx["editorFocus"] = false
check("when false", reg.resolve(cev("a"), ctx), "")
ctx["inputFocus"] = true
check("negated when blocks", reg.resolve(cev("z"), ctx), "")
ctx["inputFocus"] = false
check("negated when passes", reg.resolve(cev("z"), ctx), "undo")
# Same key, different context (F5 starts or continues)
check("F5 outside debug", reg.resolve(ev("f5"), ctx), "workbench.action.debug.start")
ctx["inDebugMode"] = true
check("F5 in debug", reg.resolve(ev("f5"), ctx), "workbench.action.debug.continue")
# Chords
check("chord start", reg.resolve(cev("k"), ctx), "__chord__")
check("chord complete", reg.resolve(ev("s"), ctx), "workbench.action.files.saveAll")
check("chord start again", reg.resolve(cev("k"), ctx), "__chord__")
check("chord miss", reg.resolve(ev("x"), ctx), "__chord_miss__")
check("chord miss text", reg.pretty(reg.last_miss), "Ctrl+K X")
check("after miss, plain keys work", reg.resolve(cev("s"), ctx), "workbench.action.files.save")
check("pretty", reg.pretty("ctrl+shift+p"), "Ctrl+Shift+P")
check("pretty fkey", reg.pretty("shift+f11"), "Shift+F11")
# Later bindings win
reg.bind("undo", "Ctrl+S", "")
check("later binding wins", reg.resolve(cev("s"), ctx), "undo")

# ── HitMap: topmost (last added) wins ───────────────────────────────────────
var hm = HitMap()
hm.add(0, 0, 100, 100, "@bg", "", "")
hm.add(10, 10, 20, 20, "@button", 7, "tip")
check("hit topmost", hm.at(15, 15).cmd, "@button")
check("hit arg", hm.at(15, 15).arg, 7)
check("hit below", hm.at(50, 50).cmd, "@bg")
check("hit none", hm.at(500, 500), none)
check("hit count", hm.count(), 2)
hm.clear()
check("hit cleared", hm.count(), 0)
hm.add(0, 0, 5, 5, "@a", "", "")
check("pool reuse", hm.at(1, 1).cmd, "@a")

# ── Frecency: recent beats frequent-but-old ─────────────────────────────────
var fr = Frecency(1000)
fr.touch("old", 0)
fr.touch("old", 0)
fr.touch("old", 0)
fr.touch("new", 5000)
check("frecency decays", fr.score("new", 5000) > fr.score("old", 5000), true)
check("frecency unknown", fr.score("zzz", 5000), 0.0)
check("frecency known", fr.known("old"), true)
fr.touch("old", 5000)
check("frecency accumulates", fr.score("old", 5000) > fr.score("new", 5000), true)

# ── QuickInput ──────────────────────────────────────────────────────────────
var qi = QuickInput()
var items = [QuickItem("File: Save", "", "save", ""), QuickItem("File: Save All", "", "saveall", ""),
             QuickItem("View: Toggle Terminal", "", "term", "")]
qi.open("commands", "", "", items, ">")
qi.strip_prefix = ">"
qi.refilter()
check("qi all shown", qi.n, 3)
qi.type_text("sall")
check("qi fuzzy", qi.n, 1)
check("qi current", qi.current().value, "saveall")
qi.backspace()
qi.backspace()
qi.backspace()
qi.backspace()
check("qi back to all", qi.n, 3)
qi.move(1)
check("qi move", qi.sel, 1)
qi.move(0 - 1)
qi.move(0 - 1)
check("qi wraps", qi.sel, 2)
qi.close()
check("qi closed", qi.visible, false)

# ── LineEdit: a VS Code input's caret and selection ─────────────────────────
var le = LineEdit()
var v = "hello world"
le.reset(v, false)
check("le caret at end", le.caret, 11)
v = le.insert(v, "!")
check("le insert", v, "hello world!")
v = le.key(v, ev("home"))
check("le home", le.caret, 0)
v = le.key(v, cev("right"))
check("le ctrl+right", le.caret, 5)
v = le.key(v, Ev("right", true, true, false))
check("le shift extends", le.selected(v), " world")
v = le.insert(v, " there")
check("le typing replaces selection", v, "hello there!")
v = le.key(v, cev("backspace"))
check("le ctrl+backspace deletes word", v, "hello !")
v = le.key(v, cev("a"))
check("le ctrl+a", le.selected(v), "hello !")
v = le.key(v, ev("delete"))
check("le delete selection", v, "")
check("le unknown key", le.key(v, ev("enter")), none)
le.reset("abc.ny", true)
check("le reset selects all", le.selected("abc.ny"), "abc.ny")
le.select("abc.ny", 0, 3)
check("le select range", le.selected("abc.ny"), "abc")
# The owner replacing the value moves the caret to the end
le.sync("something else")
check("le sync external", le.caret, 14)
check("le sync clears selection", le.has_sel(), false)
v = "ab"
le.reset(v, false)
v = le.key(v, ev("left"))
v = le.key(v, ev("backspace"))
check("le backspace mid", v, "b")
check("le caret after", le.caret, 0)
v = le.key(v, ev("delete"))
check("le delete forward", v, "")

# ── Notifications ──────────────────────────────────────────────────────────
var nt = Notifications()
var n1 = nt.push("one", "info", 0)
nt.push("two", "err", 100)
check("notif unread", nt.unread, 2)
check("notif active", len(nt.active(200, 5)), 2)
nt.dismiss(n1.id)
check("notif dismissed", len(nt.active(200, 5)), 1)
check("notif expired", len(nt.active(100000, 5)), 0)
nt.mark_read()
check("notif read", nt.unread, 0)

# ── NavHistory ──────────────────────────────────────────────────────────────
var nav = NavHistory()
nav.push("a.ny", 0, 0)
nav.push("a.ny", 5, 0)
check("nav nearby replaces", len(nav.stack), 1)
nav.push("a.ny", 50, 0)
nav.push("b.ny", 3, 1)
check("nav stacked", len(nav.stack), 3)
check("nav back", nav.back()["row"], 50)
check("nav back 2", nav.back()["path"], "a.ny")
check("nav forward", nav.forward()["row"], 50)
nav.push("c.ny", 0, 0)
check("nav push truncates forward", nav.can_forward(), false)

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT42 PASSED ===")
else:
    print("=== VM_AUDIT42 FAILED ===")
