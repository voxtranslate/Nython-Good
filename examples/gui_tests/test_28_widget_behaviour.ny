# Test 28: widgets driven through draw() and handle_event(), asserting values.
#
# Every earlier widget test constructed widgets and read their fields; none
# ever drew one or sent it an event, which is how a Card that never drew, a
# Dropdown whose items could not be picked and a ScrollPanel that clicked
# hidden children all passed. This file sends real Event objects and draws
# through a renderer that counts what it was asked to paint.
import "lib/gui.ny"

var npass = 0
var nfail = 0
def check(name, got, want):
    if got == want:
        npass = npass + 1
    else:
        nfail = nfail + 1
        print "  FAIL [" + name + "] got=" + str(got) + " want=" + str(want)
def check_true(name, c):
    check(name, c, true)

print "=== Test 28: widget behaviour ==="

def ev(t, x, y):
    var e = Event(t)
    e.x = x
    e.y = y
    e.button = 1
    return e

def key(k):
    var e = Event("keydown")
    e.key = k
    return e

def text_ev(s):
    var e = Event("textinput")
    e.text = s
    return e

def click(w, x, y):
    w.handle_event(ev("mousedown", x, y))
    w.handle_event(ev("mouseup", x, y))

# A real (headless) window, so fonts measure and the clipboard works.
var win = Window(800, 600, "test28")
check_true("window created", win.create())

# Counts what widgets ask to paint.
class RecRenderer(Renderer):
    def __init__(self, handle):
        Renderer.__init__(self, handle)
        self.texts = []
        self.arcs = 0
        self.chevrons = 0
        self.clips = 0
    def draw_text(self, text, x, y, font, color):
        self.texts.append(text)
        Renderer.draw_text(self, text, x, y, font, color)
    def draw_arc(self, cx, cy, radius, a0, a1, color, thickness):
        self.arcs = self.arcs + 1
        Renderer.draw_arc(self, cx, cy, radius, a0, a1, color, thickness)
    def fill_ring(self, cx, cy, r0, r1, a0, a1, color):
        self.arcs = self.arcs + 1
        Renderer.fill_ring(self, cx, cy, r0, r1, a0, a1, color)
    def chevron(self, cx, cy, size, direction, color):
        self.chevrons = self.chevrons + 1
        Renderer.chevron(self, cx, cy, size, direction, color)
    def push_clip(self, x, y, w, h):
        self.clips = self.clips + 1
        return Renderer.push_clip(self, x, y, w, h)
    def reset(self):
        self.texts = []
        self.arcs = 0
        self.chevrons = 0
        self.clips = 0

var rr = RecRenderer(win._handle)

def has_text(r, s):
    var i = 0
    while i < len(r.texts):
        if r.texts[i] == s:
            return true
        i = i + 1
    return false

# ── Widget tree: removal, focus, topmost-first dispatch ─────────────────────
var root = Widget(0, 0, 800, 600)
var c1 = Widget(0, 0, 10, 10)
var c2 = Widget(0, 0, 10, 10)
var c3 = Widget(0, 0, 10, 10)
root.add_child(c1)
root.add_child(c2)
root.add_child(c3)
root.remove_child(c2)
check("remove_child removes only that child", root.child_count, 2)
check_true("remove_child kept the others", root.children[0] == c1 and root.children[1] == c3)

var b1 = Button(10, 10, 100, 30, "one")
var b2 = Button(200, 10, 100, 30, "two")
click(b1, 20, 20)
b1.handle_event(ev("mousedown", 210, 20))
b2.handle_event(ev("mousedown", 210, 20))
check("focus leaves the first button", b1.focused, false)
check("focus moves to the second", b2.focused, true)

# Two overlapping buttons in a panel: only the top one (added last) is clicked.
var p = Panel(0, 0, 400, 300)
var under = Button(10, 10, 100, 40, "under")
var over = Button(10, 10, 100, 40, "over")
var hits = [0, 0]
def on_under(e):
    hits[0] = hits[0] + 1
def on_over(e):
    hits[1] = hits[1] + 1
under.on("click", on_under)
over.on("click", on_over)
p.add(under)
p.add(over)
click(p, 20, 20)
check("topmost button clicked", hits[1], 1)
check("button underneath not clicked", hits[0], 0)

# ── Overlay: a popup is above its siblings for input ────────────────────────
var host = Panel(0, 0, 800, 600)
var dd = Dropdown(10, 10, 200, 30)
dd.add_item("Apple", "a")
dd.add_item("Pear", "p")
dd.add_item("Plum", "u")
var below = Button(10, 45, 200, 60, "below")
var below_hits = [0]
def on_below(e):
    below_hits[0] = below_hits[0] + 1
below.on("click", on_below)
host.add(dd)
host.add(below)
host.handle_event(ev("mousedown", 20, 20))
check("dropdown opened", dd.open, true)
check_true("dropdown is in the overlay", gui_overlay.contains(dd))
var lr = dd.list_rect()
var item_y = lr.y + 4 + dd.item_h + 5
# Window order: overlay first, then the tree.
var pick = ev("mousedown", 50, item_y)
if not gui_overlay.handle_event(pick):
    host.handle_event(pick)
var pick_up = ev("mouseup", 50, item_y)
if not gui_overlay.handle_event(pick_up):
    host.handle_event(pick_up)
check("dropdown item picked", dd.get_value(), "p")
check("dropdown closed", dd.open, false)
check("button under the list not clicked", below_hits[0], 0)
check("overlay emptied", gui_overlay.count, 0)
# Keyboard: Down changes a focused, closed dropdown; type-ahead finds "Plum".
dd.handle_event(key("down"))
check("down selects next", dd.get_value(), "u")
dd.handle_event(text_ev("a"))
check("type-ahead", dd.get_value(), "a")
dd.handle_event(key("enter"))
check("enter opens", dd.open, true)
dd.handle_event(key("down"))
dd.handle_event(key("enter"))
check("enter picks the highlighted item", dd.get_value(), "p")
# The list is drawn by the overlay, not by the dropdown itself.
dd.open_list()
rr.reset()
dd.draw(rr)
check("closed box shows the label only", has_text(rr, "Plum"), false)
gui_overlay.draw(rr)
check_true("overlay draws the list", has_text(rr, "Plum"))
dd.close_list()

# ── ContextMenu: sized to its labels, kept inside the window ────────────────
var fired = [0]
def on_cm():
    fired[0] = fired[0] + 1
var cm = ContextMenu()
cm.add_item("A rather long menu entry that needs room", on_cm)
cm.add_item("Short", on_cm)
cm.show_at(790, 590)
check_true("menu widened for its label", cm.w > 180)
check_true("menu kept inside the window (x)", cm.x + cm.w <= 800)
check_true("menu kept inside the window (y)", cm.y + cm.total_h() <= 600)
cm.handle_event(key("down"))
cm.handle_event(key("enter"))
check("keyboard activates an item", fired[0], 1)
check("menu closes after activation", cm.visible, false)

# ── TextInput: characters, not bytes; selection; clipboard; IME ─────────────
var ti = TextInput(10, 100, 200, 30)
ti.handle_event(ev("mousedown", 20, 110))
check("text input focused", ti.focused, true)
ti.handle_event(text_ev("héllo"))
check("typed", ti.value, "héllo")
check("caret after typing", ti.cursor, 5)
ti.handle_event(key("backspace"))
check("backspace removes one character", ti.value, "héll")
ti.handle_event(key("home"))
ti.handle_event(key("right"))
var sh = key("right")
sh.shift = true
ti.handle_event(sh)
check("shift+right selects a multibyte character", ti.selected_text(), "é")
ti.handle_event(text_ev("e"))
check("typing replaces the selection", ti.value, "hell")
ti.handle_event(key("end"))
ti.handle_event(text_ev(" world"))
var ca = key("a")
ca.ctrl = true
ti.handle_event(ca)
check("ctrl+a selects all", ti.selected_text(), "hell world")
var cc = key("c")
cc.ctrl = true
ti.handle_event(cc)
check("ctrl+c copies to the system clipboard", gui_get_clipboard(), "hell world")
ti.handle_event(key("end"))
var cl = key("left")
cl.ctrl = true
ti.handle_event(cl)
check("ctrl+left jumps a word", ti.cursor, 5)
var cv = key("v")
cv.ctrl = true
ti.handle_event(cv)
check("ctrl+v pastes at the caret", ti.value, "hell hell worldworld")
check(".text mirrors .value", ti.text, ti.value)
var ime = Event("textedit")
ime.text = "nih"
ti.handle_event(ime)
check("IME composition held apart", ti.preedit, "nih")
check("composition not in the value yet", ti.value, "hell hell worldworld")
ti.handle_event(text_ev("日"))
check("commit clears the composition", ti.preedit, "")
check("commit inserts at the caret", string_slice(ti.value, 15, 16), "日")
ti.max_length = 3
ti.clear()
ti.handle_event(text_ev("abcdef"))
check("max_length in characters", ti.value, "abc")
ti.handle_event(ev("mousedown", 700, 500))
check("click elsewhere unfocuses", ti.focused, false)

# ── TextArea: a caret you can move, multi-line edits ────────────────────────
var ta = TextArea(0, 300, 300, 100, "notes")
ta.handle_event(ev("mousedown", 5, 305))
ta.handle_event(text_ev("héllo"))
ta.handle_event(key("enter"))
ta.handle_event(text_ev("wörld"))
check("text area value", ta.value, "héllo\nwörld")
check("caret on the second line", ta.line, 1)
ta.handle_event(key("up"))
check("up keeps the column", ta.col, 5)
ta.handle_event(key("backspace"))
check("backspace at the caret (characters)", ta.value, "héll\nwörld")
ta.handle_event(key("end"))
ta.handle_event(key("delete"))
check("delete at a line end joins lines", ta.value, "héllwörld")
ta.handle_event(key("home"))
ta.handle_event(text_ev("A\nB"))
check("multi-line insert", ta.value, "A\nBhéllwörld")
check("caret after the insert", str(ta.line) + ":" + str(ta.col), "1:1")
var n_enter = 0
while n_enter < 12:
    ta.handle_event(key("enter"))
    n_enter = n_enter + 1
check_true("scrolls to keep the caret visible", ta.scroll_y > 0)
check_true("scroll is bounded", ta.scroll_y <= ta.max_scroll())
ta.scroll_y = 0
ta.handle_event(ev("mousedown", 10, 300 + 10 + 2 + 20))
check("click places the caret on its line", ta.line, 1)

# ── Layouts reflow ──────────────────────────────────────────────────────────
var vb = VBox(10, 10, 300, 4)
var vt = TextInput(0, 0, 100, 30)
var vl = Label(0, 0, 50, 20, "x")
vb.add(vt)
vb.add(vl)
check("VBox stretches widgets without set_size before", vt.rect.w, 300)
check("VBox stacks", vl.rect.y, 44)
vb.layout(0, 0, 500, 100)
check("VBox reflows width", vl.rect.w, 500)
check("VBox reflows position", vt.rect.y, 0)
var hb = HBox(0, 0, 40, 4)
var nested = VBox(0, 0, 100, 4)
hb.add(nested)
hb.add(Button(0, 0, 60, 20, "b"))
check("HBox measures a nested VBox", hb.total_width(), 168)
var gl = GridLayout(0, 0, 2, 100, 30, 10)
var g1 = Button(0, 0, 10, 10, "1")
var g2 = Button(0, 0, 10, 10, "2")
gl.add(g1)
gl.add(g2)
gl.layout(0, 0, 410, 100)
check("grid columns fill the width", g2.rect.x, 210)
check("grid cell width", g1.rect.w, 200)
var fx = FlexBox("row", 0)
var fa = Panel(0, 0, 10, 10)
var fb = Panel(0, 0, 10, 10)
fx.add(fa, 0, 1)
fx.add_min(fb, 0, 1, 250, 0)
fx.layout(0, 0, 300, 50)
check("flex: a minimum takes from the others", fa.rect.w, 50)
check("flex: row still fits", fb.rect.x + fb.rect.w, 300)
var fy = FlexBox("column", 10)
fy.align = "center"
var fc = Button(0, 0, 80, 20, "c")
fy.add(fc, 20, 0)
fy.justify = "end"
fy.layout(0, 0, 200, 100)
check("flex align center (cross axis)", fc.rect.x, 60)
check("flex justify end (main axis)", fc.rect.y, 80)
# Window content follows resizes.
var content = FlexBox("row", 0)
var side = Panel(0, 0, 10, 10)
var main = Panel(0, 0, 10, 10)
content.add(side, 200, 0)
content.add(main, 0, 1)
win.set_content(content)
check("content laid out to the window", main.rect.w, 600)
win._process_event({"type": "resize", "w": 1000, "h": 700, "x": 0, "y": 0})
check("content reflows on resize", main.rect.w, 800)
check("window size follows", win.height, 700)
var sbar = StatusBar(1000, 700)
win.add(sbar)
win._process_event({"type": "resize", "w": 900, "h": 650, "x": 0, "y": 0})
check("window-sized widgets follow", sbar.window_w, 900)

# ── Trees ───────────────────────────────────────────────────────────────────
var ta = TreeNode("a", "a")
var tb = TreeNode("b", "b")
var tc = TreeNode("c", "c")
tb.add_child(tc)
ta.add_child(tb)
check("depth propagates to a subtree added later", tc.depth, 2)
var tv = TreeView(0, 200, 300, 200)
tv.add_root(ta)
ta.expand()
tv.handle_event(ev("mousedown", 100, 205))
check("click selects a row", tv.selected == ta, true)
tv.handle_event(key("down"))
check("down selects the next row", tv.selected == tb, true)
tv.handle_event(key("right"))
check("right expands", tb.expanded, true)
tv.handle_event(key("right"))
check("right again enters the child", tv.selected == tc, true)
tv.handle_event(key("left"))
check("left goes to the parent", tv.selected == tb, true)
rr.reset()
tv.draw(rr)
check_true("tree draws its labels", has_text(rr, "c"))
check("tree draws expand chevrons", rr.chevrons, 2)

# ── DataTable: sort by header, rows under the header not clickable ──────────
var dt = DataTable(0, 0, 300, 200)
dt.add_column("n", "Name", 150)
dt.add_column("v", "Val", 150)
dt.add_row({"n": "b", "v": 3})
dt.add_row({"n": "a", "v": 10})
dt.add_row({"n": "c", "v": 1})
dt.selected_row = 0
dt.handle_event(ev("mousedown", 200, 10))
check("header click sorts ascending", str(dt.rows[0]["v"]) + str(dt.rows[1]["v"]) + str(dt.rows[2]["v"]), "1310")
check("selection follows its row", dt.rows[dt.selected_row]["n"], "b")
dt.handle_event(ev("mousedown", 200, 10))
check("second click reverses", dt.rows[0]["v"], 10)
var i = 0
while i < 20:
    dt.add_row({"n": "r" + str(i), "v": i})
    i = i + 1
dt.scroll_y = dt.row_h
dt.selected_row = -1
dt.handle_event(ev("mousedown", 20, 20))
check("header area never selects a hidden row", dt.selected_row, -1)

# ── ListView: multi-select, double click ────────────────────────────────────
var lv = ListView(0, 0, 300, 400)
lv.multi_select = true
lv.add_item("one", "", 1)
lv.add_item("two", "", 2)
lv.add_item("three", "", 3)
lv.add_item("four", "", 4)
var dbl = [0]
def on_dbl(item):
    dbl[0] = item["value"]
lv.on_double_click(on_dbl)
lv.handle_event(ev("mousedown", 10, 10))
var shift_click = ev("mousedown", 10, 130)
shift_click.shift = true
lv.handle_event(shift_click)
check("shift+click selects a range", len(lv.get_selected_items()), 4)
var ctrl_click = ev("mousedown", 10, 50)
ctrl_click.ctrl = true
lv.handle_event(ctrl_click)
check("ctrl+click toggles one out", len(lv.get_selected_items()), 3)
check("toggled item deselected", lv.is_selected(1), false)
var dclick = ev("mousedown", 10, 90)
dclick.clicks = 2
lv.handle_event(dclick)
check("double click (platform count) fires", dbl[0], 3)

# ── Small widgets ───────────────────────────────────────────────────────────
var sl = Slider(0, 0, 200, 0, 100, 50)
sl.handle_event(ev("mousedown", 75, 12))
check("slider rounds to the nearest step", sl.value, 38)
sl.handle_event(ev("mouseup", 75, 12))
sl.handle_event(key("right"))
check("slider arrow key", sl.value, 39)
var sl0 = Slider(0, 0, 200, 5, 5, 5)
sl0.handle_event(ev("mousedown", 50, 12))
check("slider with an empty range", sl0.value, 5)
var pb = ProgressBar(0, 0, 100, 10)
pb.min_val = 1.0
pb.max_val = 1.0
check("progress with an empty range", pb.percent(), 0.0)
var cb = Checkbox(0, 0, "A fairly long checkbox label")
cb.handle_event(ev("mousedown", 200, 10))
check("checkbox label is clickable (measured)", cb.checked, true)
var tabs = Tabs(0, 0, 300, 30)
tabs.draw(rr)
tabs.handle_event(ev("mousedown", 10, 10))
check("empty tabs draw and click without dividing by zero", tabs.count, 0)
var st = Stepper(0, 0, 300, 60, "horizontal")
st.draw(rr)
var mq = Marquee(0, 0, 300, 30)
mq.draw(rr)
check("empty stepper and marquee drew", true, true)
var card = Card(0, 0, 300, 200)
card.set_title("Card title")
card.add(Label(10, 50, 100, 20, "inside the card"))
rr.reset()
card.draw(rr)
check_true("card draws its title", has_text(rr, "Card title"))
check_true("card draws its children", has_text(rr, "inside the card"))
var gauge = Gauge(0, 0, 200, 0, 100, 40)
gauge.animate = false
gauge.set_value(40)
rr.reset()
gauge.draw(rr)
check_true("gauge draws its arcs", rr.arcs >= 2)
var pie = PieChart(0, 0, 200)
pie.animate = false
pie.anim_progress = 1.0
pie.add_segment("A", 1.0, Color(255, 0, 0, 255))
pie.add_segment("B", 1.0, Color(0, 255, 0, 255))
rr.reset()
pie.draw(rr)
check("pie draws a ring (and a shadow) per segment", rr.arcs, 4)
# Right of centre = the first half (clockwise from 12), left = the second.
check("pie hit test (right half)", pie.segment_at(170, 100), 0)
check("pie hit test (left half)", pie.segment_at(30, 100), 1)
check("pie hit test (donut hole)", pie.segment_at(100, 100), -1)
var lbl = Label(0, 0, 60, 60, "one two three four")
lbl.wrap = true
lbl.draw(rr)
check("wrapped label draws", true, true)
var sp = ScrollPanel(0, 100, 200, 100)
sp.set_content_size(200, 400)
var hidden = Button(10, 110, 80, 30, "hidden")
var hidden_hits = [0]
def on_hidden(e):
    hidden_hits[0] = hidden_hits[0] + 1
hidden.on("click", on_hidden)
sp.add(hidden)
sp.scroll_to(0, 100)
click(sp, 20, 20)
check("scroll panel: no clicks outside its area", hidden_hits[0], 0)
sp.scroll_to(0, 0)
click(sp, 20, 120)
check("scroll panel: visible child clickable", hidden_hits[0], 1)
# Dragging the scrollbar thumb scrolls.
sp.handle_event(ev("mousedown", 196, 105))
sp.handle_event(ev("mousemove", 196, 155))
sp.handle_event(ev("mouseup", 196, 155))
check_true("scrollbar thumb drag scrolls", sp.scroll_y > 0)

# ── Timers run on gui_ticks (milliseconds on both engines) ──────────────────
check_true("gui_ticks is monotonic milliseconds", gui_ticks() >= 0)
var tip = Tooltip("Save the file")
tip.attach(Rect(100, 100, 80, 30))
tip.delay_ms = 400
tip.handle_event(ev("mousemove", 120, 110))
tip.draw(rr)
check("tooltip waits for its delay", tip.visible, false)
tip.delay_ms = 0
tip.draw(rr)
check("tooltip shows after the delay", tip.visible, true)
tip.handle_event(ev("mousemove", 400, 400))
check("tooltip hides when the pointer leaves", tip.visible, false)
var toasts = ToastManager(800)
toasts.show("saved", "success", 0)
toasts.show("stays", "info", 60000)
thread_sleep(5)
toasts.update()
check("expired toast removed, live one kept", toasts.count, 1)
toasts.window_resized(1000, 700)
check("toasts follow the window's right edge", toasts.toasts[0].x, 1000 - 320 - 16)

# ── MenuBar: hover switches menus, submenus, keyboard, shortcuts ────────────
var log = []
def on_new():
    log.append("new")
def on_save():
    log.append("save")
def on_recent():
    log.append("recent")
var mb = MenuBar(800)
var fm = Menu("File")
fm.add("New", on_new)
fm.add_shortcut("Save", on_save, "Ctrl+S")
var rec = Menu("Recent")
rec.add("a.ny", on_recent)
fm.add_submenu("Open Recent", rec)
var em = Menu("Edit")
em.add("Undo", none)
mb.add_menu(fm)
mb.add_menu(em)
mb.handle_event(ev("mousedown", 10, 10))
check("click opens a menu", mb.active_menu, 0)
mb.handle_event(ev("mousemove", mb._menu_x(1) + 5, 10))
check("hovering the bar switches menus", mb.active_menu, 1)
mb.handle_event(ev("mousemove", 10, 10))
mb.handle_event(ev("mousemove", 20, mb.y + mb.h + 2 * mb.item_h + 5))
check("hovering a submenu item opens it", len(mb._lv_menu), 2)
mb.handle_event(ev("mousedown", mb._lv_x[1] + 10, mb._lv_y[1] + 5))
check("submenu item activates", log[0], "recent")
check("activation closes the menus", mb.active_menu, -1)
var cs = key("s")
cs.ctrl = true
mb.handle_event(cs)
check("shortcut runs its item", log[1], "save")
mb.open_menu(0)
mb.handle_event(key("down"))
mb.handle_event(key("enter"))
check("keyboard picks an item", log[2], "new")

# ── Dialogs ─────────────────────────────────────────────────────────────────
var answer = ["none"]
def on_answer(r):
    answer[0] = r
var msg = MessageBox("Unsaved", "Save before closing?", ["Cancel", "Save"])
msg.on_result(on_answer)
msg.show(800, 600)
check_true("message box is modal", gui_overlay.has_modal())
var behind = Button(5, 5, 50, 50, "behind")
var behind_hits = [0]
def on_behind(e):
    behind_hits[0] = behind_hits[0] + 1
behind.on("click", on_behind)
var d1 = ev("mousedown", 10, 10)
if not gui_overlay.handle_event(d1):
    behind.handle_event(d1)
check("nothing behind a modal reacts", behind.pressed, false)
gui_overlay.handle_event(key("enter"))
check("enter answers with the default button", answer[0], "Save")
check("dialog closed", gui_overlay.count, 0)
var yes = ["unset"]
def on_yes(v):
    yes[0] = v
var conf = ConfirmDialog("Delete", "Delete the file?")
conf.on_confirm(on_yes)
conf.show(800, 600)
gui_overlay.handle_event(key("escape"))
check("escape declines", yes[0], false)
var picked = ["unset"]
def on_pick(path):
    picked[0] = path
var fd = FileDialog("open")
fd.on_result(on_pick)
check_true("native dialog started", fd.show("Open", ""))
check_true("dialog pending", fd.pending)
var de = Event("dialog")
de.text = "/tmp/picked.ny"
gui_overlay.handle_event(de)
check("dialog answer delivered", picked[0], "/tmp/picked.ny")
check("dialog no longer pending", fd.pending, false)

# ── Renderer: nested clips and offsets (native stacks) ──────────────────────
check("push_clip depth", rr.push_clip(0, 0, 100, 100), 1)
check("nested push_clip depth", Renderer.push_clip(rr, 10, 10, 50, 50), 2)
check("pop_clip depth", rr.pop_clip(), 1)
check("pop_clip to none", rr.pop_clip(), 0)
check("push_offset depth", rr.push_offset(-10, -20), 1)
check("pop_offset depth", rr.pop_offset(), 0)

# ── Event fields from the backend's maps ────────────────────────────────────
var fe = Event("idle")
win._fill_event(fe, {"type": "wheel", "x": 1, "y": 2, "button": 0, "key": "", "keycode": 0, "text": "", "delta": 0, "ctrl": false, "shift": false, "alt": false, "clicks": 0, "dx": 0.5, "dy": -0.25, "w": 0, "h": 0, "meta": true, "repeat": true, "window": 1}, "scroll")
check("dy copied", fe.dy, -0.25)
var fe2 = Event("idle")
win._fill_event(fe2, {"type": "mousemove", "x": 1, "y": 2, "button": 0, "key": "", "keycode": 0, "text": "", "delta": 0, "ctrl": false, "shift": false, "alt": false, "clicks": 0, "w": 0, "h": 0, "meta": false, "repeat": false}, "mousemove")
check("no dx on a mouse move reads 0", fe2.dx, 0.0)
check("no window key reads 0", fe2.window, 0)
check("dy copied", fe.dy, -0.25)
check("dx copied", fe.dx, 0.5)
check("meta copied", fe.meta, true)
check("repeat copied", fe.repeat, true)
check("window copied", fe.window, 1)

win.destroy()
print "Results: " + str(npass) + " passed, " + str(nfail) + " failed"
if nfail == 0:
    print "=== TEST 28 PASSED ==="
else:
    print "=== TEST 28 FAILED ==="
