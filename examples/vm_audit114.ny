# vm_audit114.ny - tkinter, tkinter.ttk and turtle over Nython's own Tk
# (round 84): the Tcl layer, variables and traces, widgets and their option
# tables, pack/grid/place with Tk's algorithms (the expected geometry is
# worked out by hand from tkPack.c/tkGrid.c/tkPlace.c and Tk's widget size
# rules, with the text widths measured through the font), events and
# bindings, the text and canvas widgets, images, ttk's style engine and
# widgets, the dialogs, turtle - driven headlessly through the SDL stub's
# scripted input, and checked on its display list.
#
# python3 here has no tkinter: there the test only reports that it is
# skipped (every expected value is Tk 8.6's / CPython 3.12's behaviour).
#
#     ./build/nython-cli examples/vm_audit114.ny
#     ./build/nython-cli --vm examples/vm_audit114.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import os
import sys
import tempfile

pass_n = 0
fail_n = 0
results = []


_trace = os.environ.get("VM_AUDIT114_TRACE", "") != ""


def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])
    if _trace:
        print(("ok   " if repr(got) == repr(want) else "FAIL ") + name + ("" if repr(got) == repr(want) else ": got " + repr(got) + " want " + repr(want)), flush=True)


# the scripted-input harness: a per-process event script, no autoquit
_ev = os.path.join(tempfile.gettempdir(), "vm_audit114_" + str(os.getpid()) + ".events")
open(_ev, "w").close()
os.environ["NY_STUB_EVENTS"] = _ev
os.environ["NY_STUB_EVENT_GAP"] = "0"
if "NY_STUB_AUTOQUIT" in os.environ:
    del os.environ["NY_STUB_AUTOQUIT"]

try:
    import tkinter as tk
    from tkinter import ttk
    have_tk = True
except ImportError:
    have_tk = False

if have_tk:
    from tkinter import font as tkfont
    TclError = tk.TclError

    # ── the Tcl layer ─────────────────────────────────────────────────
    tcl = tk.Tcl()
    check("Tcl eval and expr", [tcl.eval("set x 5; expr {$x * 2}"), tcl.eval("string length hello"),
                                tcl.eval("lindex {a {b c} d} 1"), tcl.eval("llength {a {b c} d}")],
          ["10", "5", "b c", "3"])
    check("splitlist and quoting", [tcl.splitlist("a {b c} d"), tcl.eval("list {a b} c {}"),
                                    tcl.eval("join [list x y z] -")],
          [("a", "b c", "d"), "{a b} c {}", "x-y-z"])
    check("procs, if, foreach", tcl.eval("proc sq {n} {return [expr {$n*$n}]}; set s 0; "
                                         "foreach i {1 2 3} {incr s [sq $i]}; if {$s > 10} {set r big} else {set r small}; "
                                         "list $s $r"), "14 big")
    try:
        tcl.eval("nosuchcommand 1")
        check("unknown command", "no error", "TclError")
    except TclError as e:
        check("unknown command", str(e), 'invalid command name "nosuchcommand"')
    check("versions", [tk.TkVersion, tk.TclVersion, tk._nython], [8.6, 8.6, True])
    check("getboolean/getint", [tcl.getboolean("yes"), tcl.getboolean("off"), tcl.getint("0x10"),
                                tcl.getdouble("2.5")], [True, False, 16, 2.5])

    root = tk.Tk()
    root.geometry("+0+0")

    # ── variables and traces ──────────────────────────────────────────
    sv = tk.StringVar(root, value="abc")
    iv = tk.IntVar(root, value=3)
    dv = tk.DoubleVar(root, value=1.5)
    bv = tk.BooleanVar(root, value=True)
    check("variables", [sv.get(), iv.get(), dv.get(), bv.get()], ["abc", 3, 1.5, True])
    log = []
    tid = sv.trace_add("write", lambda n, i, m: log.append((n == str(sv), i, m, sv.get())))
    sv.set("x")
    sv.set("y")
    check("trace_add write", log, [(True, "", "write", "x"), (True, "", "write", "y")])
    check("trace_info", [m for (m, cb) in sv.trace_info()], [("write",)])
    sv.trace_remove("write", tid)
    sv.set("z")
    check("trace_remove", len(log), 2)
    bv.set("no")
    iv.set("7")
    check("conversions", [bv.get(), iv.get(), root.getvar(str(iv))], [False, 7, "7"])
    root.setvar("plain", "hello")
    check("setvar/getvar", root.getvar("plain"), "hello")

    # ── classic widgets: options and sizes ────────────────────────────
    f12 = tkfont.nametofont("TkDefaultFont")
    ls = f12.metrics("linespace")
    b = tk.Button(root, text="OK")
    check("cget/configure", [b.cget("text"), b["relief"], b.configure("text"), "command" in b.keys()],
          ["OK", "raised", ("text", "text", "Text", "", "OK"), True])
    try:
        b.configure(bogus=1)
        check("unknown option", "no error", "TclError")
    except TclError as e:
        check("unknown option", str(e), 'unknown option "-bogus"')
    # TkpComputeButtonGeometry: text + 2*padx (3m) + 2*(bd + highlight) + 2
    pad = root.winfo_pixels("3m")
    padv = root.winfo_pixels("1m")
    check("button request (tkUnixButton.c)", [b.winfo_reqwidth(), b.winfo_reqheight()],
          [f12.measure("OK") + 2 * pad + 2 * 2 + 2, ls + 2 * padv + 2 * 2 + 2])
    lab = tk.Label(root, text="hello there")
    check("label request (padx 1, bd 1)", [lab.winfo_reqwidth(), lab.winfo_reqheight()],
          [f12.measure("hello there") + 2 * 1 + 2 * 1, ls + 2 * 1 + 2 * 1])
    hits = []
    b.configure(command=lambda: hits.append("b"))
    b.invoke()
    check("invoke", hits, ["b"])

    # ── pack (tkPack.c ArrangePacking) ────────────────────────────────
    top = tk.Toplevel(root)
    f1 = tk.Frame(top, width=100, height=50)
    f2 = tk.Frame(top, width=80, height=30)
    f1.pack(side="left")
    f2.pack(side="left")
    top.update()
    check("pack: request is the sum along the side", [top.winfo_reqwidth(), top.winfo_reqheight()], [180, 50])
    check("pack: slaves in their parcels", [f1.winfo_x(), f1.winfo_y(), f2.winfo_x(), f2.winfo_y()],
          [0, 0, 100, 10])
    top.geometry("300x200")
    f2.pack_configure(fill="y", expand=True)
    top.update()
    # f1 keeps its 100 wide parcel; f2's parcel takes the remaining 200,
    # it fills y (200 high) and is centred in x: (200 - 80) / 2 = 60
    check("pack: expand and fill", [f2.winfo_x(), f2.winfo_y(), f2.winfo_width(), f2.winfo_height(), f1.winfo_y()],
          [160, 0, 80, 200, 75])
    check("pack_info", [f2.pack_info()["side"], f2.pack_info()["fill"], f2.pack_info()["expand"]], ["left", "y", 1])
    top.destroy()

    # ── grid (tkGrid.c) ───────────────────────────────────────────────
    top = tk.Toplevel(root)
    a = tk.Frame(top, width=40, height=20)
    bb = tk.Frame(top, width=60, height=10)
    c = tk.Frame(top, width=30, height=30)
    a.grid(row=0, column=0)
    bb.grid(row=0, column=1)
    c.grid(row=1, column=0)
    top.update()
    check("grid: column widths and row heights", [top.winfo_reqwidth(), top.winfo_reqheight()], [100, 50])
    check("grid: centred in cells", [bb.winfo_x(), bb.winfo_y(), c.winfo_x(), c.winfo_y()], [40, 5, 5, 20])
    top.geometry("200x100")
    top.columnconfigure(1, weight=1)
    bb.grid_configure(sticky="ew")
    top.update()
    # extra space goes to the weighted column; the unweighted rows keep
    # their size and the grid sits at its -anchor, nw by default
    check("grid: weights and sticky", [bb.winfo_x(), bb.winfo_width(), a.winfo_y(), c.winfo_y()],
          [40, 160, 0, 20])
    check("grid_size/bbox", [top.grid_size(), top.grid_bbox(0, 0)], [(2, 2), (0, 0, 40, 20)])
    check("grid_info", [bb.grid_info()["row"], bb.grid_info()["column"], bb.grid_info()["sticky"]], [0, 1, "ew"])
    top.destroy()

    # ── place (tkPlace.c) ─────────────────────────────────────────────
    top = tk.Toplevel(root)
    top.geometry("200x100")
    p1 = tk.Frame(top)
    p1.place(x=10, y=20, width=50, height=30)
    p2 = tk.Frame(top)
    p2.place(relx=0.5, rely=0.5, anchor="center", width=50, height=30)
    top.update()
    check("place", [p1.winfo_x(), p1.winfo_y(), p1.winfo_width(), p2.winfo_x(), p2.winfo_y()],
          [10, 20, 50, 75, 35])
    top.destroy()

    # ── events and bindings ───────────────────────────────────────────
    ev_log = []
    fr = tk.Frame(root, width=50, height=50)
    fr.pack()
    root.update()
    fid = fr.bind("<<Custom>>", lambda e: ev_log.append(("custom", e.widget is fr)))
    fr.event_generate("<<Custom>>")
    check("virtual event", ev_log, [("custom", True)])
    check("bindtags", fr.bindtags(), (str(fr), "Frame", ".", "all"))
    order = []
    fr.bind("<Key-a>", lambda e: order.append(("w", e.keysym, e.char)))
    root.bind_class("Frame", "<Key-a>", lambda e: order.append("class"))
    root.bind_all("<Key-a>", lambda e: order.append("all"))
    fr.focus_force()
    fr.event_generate("<Key-a>")
    check("binding order: widget, class, toplevel, all", order, [("w", "a", "a"), "class", "all"])
    order.clear()
    fr.bind("<Key-a>", lambda e: (order.append("w2"), "break")[1])
    fr.event_generate("<Key-a>")
    check("break stops the bindtags", order, ["w2"])
    root.unbind_class("Frame", "<Key-a>")
    root.unbind_all("<Key-a>")
    root.event_add("<<Go>>", "<Control-g>")
    check("event_info", root.event_info("<<Go>>"), ("<Control-Key-g>",))
    got = []
    fr.bind("<<Go>>", lambda e: got.append("go"))
    fr.event_generate("<Control-g>")
    check("virtual event from its physical sequence", got, ["go"])
    clicks = []
    fr.bind("<Button-1>", lambda e: clicks.append((e.x, e.y, e.num)))
    fr.event_generate("<Button-1>", x=7, y=9)
    check("button event fields", clicks, [(7, 9, 1)])
    fr.destroy()

    # ── scripted input through the backend ────────────────────────────
    hits.clear()
    b.pack()
    e1 = tk.Entry(root)
    e1.pack()
    root.update()

    def at(w, dx=5, dy=5):
        return (w.winfo_rootx() - root.winfo_rootx() + dx, w.winfo_rooty() - root.winfo_rooty() + dy)

    x, y = at(b)
    root._ny_drive("click %d %d" % (x, y))
    check("a click invokes the button", hits, ["b"])
    x, y = at(e1)
    root._ny_drive(["click %d %d" % (x, y), "text hi there", "key BackSpace", "key Home", "text >"])
    check("typing into an entry", [e1.get(), e1.index("insert")], [">hi ther", 1])
    root._ny_drive(["key ctrl+/"])
    check("<<SelectAll>> (Control-slash)", [e1.selection_present(), e1.index("sel.first"), e1.index("sel.last")],
          [True, 0, 8])
    cb_var = tk.IntVar(root)
    chk = tk.Checkbutton(root, text="check", variable=cb_var)
    chk.pack()
    root.update()
    x, y = at(chk)
    root._ny_drive("click %d %d" % (x, y))
    check("a click toggles the checkbutton", cb_var.get(), 1)
    root._ny_drive(["key Tab"])
    check("Tab traversal (tk_focusNext from the entry)", str(root.focus_get()), str(chk))

    # ── the display list ──────────────────────────────────────────────
    ops = root._ny_snapshot()
    texts = [o for o in ops if o["op"] == "text"]
    check("the button's text is drawn", [o["text"] for o in texts if o["text"] == "OK"], ["OK"])
    n0 = root._ny_frames()
    root.update()
    root.update()
    check("no change, no new frame", root._ny_frames(), n0)
    lab2 = tk.Label(root, text="later")
    lab2.pack()
    root.update()
    check("a change draws a frame", root._ny_frames() > n0, True)
    acc = b._ny_accessibility()
    check("accessibility", [acc["role"], acc["name"], "focusable" in acc["states"]], ["button", "OK", True])

    # ── the text widget ───────────────────────────────────────────────
    t = tk.Text(root, width=40, height=10, undo=True)
    t.insert("1.0", "hello world\nsecond line\nthird")
    check("text get/index", [t.get("1.0", "1.end"), t.index("end"), t.index("2.3 lineend"), t.index("1.0 + 5c"),
                             t.index("1.2 wordend")], ["hello world", "4.0", "2.11", "1.5", "1.5"])
    t.tag_add("x", "1.0", "1.5")
    t.tag_add("x", "2.0", "2.6")
    check("text tags", [t.tag_ranges("x"), t.tag_names("1.2"), t.tag_nextrange("x", "1.3")],
          [("1.0", "1.5", "2.0", "2.6"), ("x",), ("2.0", "2.6")])
    cnt = tk.IntVar(root)
    check("text search", [t.search("line", "1.0"), t.search("LINE", "1.0", nocase=True),
                          t.search("w.r", "1.0", regexp=True, count=cnt), cnt.get()], ["2.7", "2.7", "1.6", 3])
    t.mark_set("m1", "2.4")
    t.delete("1.0", "1.6")
    check("text marks move with edits", [t.get("1.0", "1.end"), t.index("m1")], ["world", "2.4"])
    t.edit_separator()
    t.insert("end", "\nfourth")
    t.edit_undo()
    check("text undo", t.get("1.0", "end"), "world\nsecond line\nthird\n")
    t.edit_undo()
    check("text undo (2)", t.get("1.0", "1.end"), "hello world")
    t.edit_redo()
    check("text redo", t.get("1.0", "1.end"), "world")
    tf = tkfont.Font(font=t["font"])
    # width chars of "0" plus 2*(bd 1 + highlight 1 + padx 1)
    check("text request", [t.winfo_reqwidth(), t.winfo_reqheight()],
          [40 * tf.measure("0") + 6, 10 * tf.metrics("linespace") + 6])

    # ── the canvas ────────────────────────────────────────────────────
    cv = tk.Canvas(root, width=200, height=100)
    r = cv.create_rectangle(10, 10, 50, 50, fill="red", tags=("a", "box"))
    ln = cv.create_line(0, 0, 100, 100, width=3)
    ov = cv.create_oval(60, 10, 90, 40, outline="blue")
    tx = cv.create_text(100, 50, text="Hi", anchor="nw")
    hf = tkfont.nametofont("TkDefaultFont")
    check("canvas ids and types", [r, ln, ov, tx, cv.type(r), cv.type(ln)], [1, 2, 3, 4, "rectangle", "line"])
    # tkRectOval.c: outline width 1 -> 1 pixel of bloat; tkCanvLine.c: the
    # width (3) plus one of fudge; tkCanvText.c: the cursor's half width
    check("canvas bboxes", [cv.bbox(r), cv.bbox(ln), cv.bbox(ov), cv.bbox(tx)],
          [(9, 9, 51, 51), (-4, -4, 104, 104), (59, 9, 91, 41),
           (99, 50, 101 + hf.measure("Hi"), 50 + hf.metrics("linespace"))])
    cv.move(r, 5, 5)
    check("canvas move/coords", cv.coords(r), [15.0, 15.0, 55.0, 55.0])
    check("canvas find", [cv.find_withtag("a"), cv.find_all(), cv.find_overlapping(0, 0, 20, 20),
                          cv.find_enclosed(0, 0, 100, 100), cv.find_closest(70, 25)],
          [(1,), (1, 2, 3, 4), (1, 2), (1, 3), (3,)])
    cv.addtag_withtag("q", "box")
    check("canvas tag expressions", [cv.gettags(r), cv.find_withtag("a&&q"), cv.find_withtag("!a")],
          [("a", "box", "q"), (1,), (2, 3, 4)])
    cv.itemconfigure(r, fill="green")
    cv.scale(r, 0, 0, 2, 2)
    check("canvas itemcget/scale", [cv.itemcget(r, "fill"), cv.coords(r)], ["green", [30.0, 30.0, 110.0, 110.0]])
    cv.delete(ov)
    check("canvas delete", cv.find_all(), (1, 2, 4))
    check("canvas request (width + 2*highlight)", [cv.winfo_reqwidth(), cv.winfo_reqheight()], [202, 102])
    check("canvas postscript", cv.postscript()[:23], "%!PS-Adobe-3.0 EPSF-3.0")

    # ── images ────────────────────────────────────────────────────────
    img = tk.PhotoImage(width=4, height=3)
    img.put("{red green} {blue yellow}", to=(1, 1))
    check("photo put/get", [img.get(1, 1), img.get(2, 1), img.get(1, 2), img.get(2, 2)],
          [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)])
    check("photo transparency", [img.transparency_get(0, 0), img.transparency_get(1, 1)], [True, False])
    check("photo size options", [img.width(), img.height(), img["width"], img.type()], [4, 3, "4", "photo"])
    check("photo data", img.data()[1], "#000000 #ff0000 #00ff00 #000000")
    png = img.data(format="png")
    img2 = tk.PhotoImage(data=png)
    check("png round trip", [png[:8], img2.width(), img2.get(2, 2), img2.transparency_get(0, 0)],
          [b"\x89PNG\r\n\x1a\n", 4, (255, 255, 0), True])
    img3 = tk.PhotoImage(data=img.data(format="gif"), format="gif")
    check("gif round trip", [img3.get(1, 2), img3.transparency_get(0, 0)], [(0, 0, 255), True])
    z = img.zoom(2)
    s2 = img.subsample(2)
    check("zoom/subsample", [z.width(), z.height(), z.get(3, 3), s2.width(), s2.get(1, 1)],
          [8, 6, (255, 0, 0), 2, (255, 255, 0)])
    ppm = os.path.join(tempfile.gettempdir(), "vm_audit114_" + str(os.getpid()) + ".ppm")
    img.write(ppm)
    with open(ppm, "rb") as fh:
        head = fh.read(11)
    os.remove(ppm)
    check("write (PPM by default, Tk's header)", head, b"P6\n4 3\n255\n")
    bm = tk.BitmapImage(data="#define t_width 3\n#define t_height 2\nstatic char t_bits[] = {0x05, 0x02};")
    check("bitmap image", [bm.width(), bm.height(), bm.type()], [3, 2, "bitmap"])
    il = tk.Label(root, image=img)
    check("label with an image (image + 2*bd)", [il.winfo_reqwidth(), il.winfo_reqheight()], [6, 5])
    try:
        img.get(10, 10)
        check("photo get out of range", "no error", "TclError")
    except TclError as e:
        check("photo get out of range", str(e), str(img) + " get: coordinates out of range")
    n_before = len(tk.image_names())
    tmp_img = tk.PhotoImage(width=2, height=2)
    tmp_img.put("red")
    del tmp_img
    check("an image goes with its last reference", len(tk.image_names()), n_before)

    # ── ttk: the style engine ─────────────────────────────────────────
    st = ttk.Style(root)
    check("themes", [st.theme_names(), st.theme_use()], [("clam", "alt", "default", "classic"), "default"])
    check("lookup", [st.lookup("TButton", "padding"), st.lookup("TButton", "relief", ["pressed"]),
                     st.lookup("TButton", "font"), st.lookup("Nope.TButton", "anchor"), st.lookup("TButton", "nope")],
          ["3 3", "sunken", "TkDefaultFont", "center", ""])
    st.configure("My.TButton", foreground="red")
    check("configure", [st.configure("My.TButton"), st.configure("My.TButton", "foreground")],
          [{"foreground": "red"}, "red"])
    st.map("My.TButton", background=[("active", "white"), ("pressed", "!disabled", "black")])
    check("map", st.map("My.TButton", "background"), [("active", "white"), ("pressed", "!disabled", "black")])
    check("layout", st.layout("TButton"),
          [("Button.border", {"sticky": "nswe", "border": "1", "children": [
              ("Button.focus", {"sticky": "nswe", "children": [
                  ("Button.padding", {"sticky": "nswe", "children": [("Button.label", {"sticky": "nswe"})]})]})]})])
    st.layout("Empty.TButton", "")
    check("layout turned off", st.layout("Empty.TButton"), [("null", {"sticky": "nswe"})])
    try:
        st.layout("NotALayout")
        check("unknown layout", "no error", "TclError")
    except TclError as e:
        check("unknown layout", str(e), "Layout NotALayout not found")

    # ── ttk widgets ───────────────────────────────────────────────────
    tb = ttk.Button(root, text="OK")
    avg = hf.measure("0")
    # Button.border (bd 1, +5 for -default normal) > focus (1) > padding
    # (3 3 + shiftrelief 1 when raised: 3 3 4 4) > label (at least 9 chars)
    check("ttk button request", [tb.winfo_reqwidth(), tb.winfo_reqheight()],
          [max(9 * avg, hf.measure("OK")) + 7 + 2 + 12, ls + 7 + 2 + 12])
    check("ttk state", [tb.state(), tb.state(["disabled"]), tb.instate(["disabled"]), tb.state(["!disabled"]),
                        tb.state()], [(), ("!disabled",), True, ("disabled",), ()])
    try:
        tb.state(["bogus"])
        check("bad state", "no error", "TclError")
    except TclError as e:
        check("bad state", str(e), "Invalid state name bogus")
    tl = ttk.Label(root, text="hello")
    check("ttk label (border 1 from the theme)", [tl.winfo_reqwidth(), tl.winfo_reqheight(), tl["foreground"]],
          [hf.measure("hello") + 2, ls + 2, ""])
    tc = ttk.Checkbutton(root, text="Check")
    check("ttk checkbutton variable", [str(tc["variable"]) == str(tc), tc.state()], [True, ("alternate",)])
    tc.invoke()
    check("ttk checkbutton invoke", [tc.state(), root.getvar(str(tc))], [("selected",), "1"])
    te = ttk.Entry(root)
    te.insert(0, "hello")
    check("ttk entry", [te.get(), te.winfo_reqwidth(), te.winfo_reqheight()],
          ["hello", 20 * tkfont.nametofont("TkTextFont").measure("0") + 4,
           tkfont.nametofont("TkTextFont").metrics("linespace") + 4])
    te.state(["readonly"])
    te.insert("end", "X")
    check("ttk entry readonly", te.get(), "hello")
    tvv = tk.StringVar(root, value="abc")
    te2 = ttk.Entry(root, textvariable=tvv)
    tvv.set("xyz")
    check("ttk entry textvariable", te2.get(), "xyz")
    cbx = ttk.Combobox(root, values=["one", "two", "three"])
    cbx.pack()
    root.update()
    check("combobox current", [cbx.current()], [-1])
    cbx.current(1)
    check("combobox current(1)", [cbx.get(), cbx.current()], ["two", 1])
    cbx.set("three")
    check("combobox set", cbx.current(), 2)
    try:
        cbx.current(9)
        check("combobox out of range", "no error", "TclError")
    except TclError as e:
        check("combobox out of range", str(e), 'index "9" out of range')
    picked = []
    cbx.bind("<<ComboboxSelected>>", lambda e: picked.append(cbx.get()))
    cbx.current(0)
    cbx.focus_force()
    root.update()
    root._ny_drive(["key Down", "key Down", "key Return"])
    root.update()
    check("the popdown list by keyboard", [cbx.get(), picked], ["two", ["two"]])
    sp = ttk.Spinbox(root, from_=0, to=10, increment=2)
    sp.set(4)
    root.tk.call("ttk::spinbox::Spin", sp, 1)
    check("spinbox", sp.get(), "6")
    sb = ttk.Scrollbar(root)
    sb.set(0.2, 0.5)
    check("ttk scrollbar", sb.get(), (0.2, 0.5))
    sc = ttk.Scale(root, from_=0, to=100)
    sc.set(50)
    check("ttk scale", [sc.get(), sc["value"]], [50.0, 50.0])
    pb = ttk.Progressbar(root, maximum=50)
    pb.step(10)
    check("progressbar", [pb["value"], pb.winfo_reqwidth()], [10.0, 100])
    nb = ttk.Notebook(root)
    nf1 = ttk.Frame(nb, width=100, height=50)
    nf2 = ttk.Frame(nb, width=80, height=60)
    nb.add(nf1, text="First")
    nb.add(nf2, text="Second")
    nb.pack()
    changed = []
    nb.bind("<<NotebookTabChanged>>", lambda e: changed.append(nb.index("current")))
    root.update()
    check("notebook tabs", [nb.tabs() == (str(nf1), str(nf2)), nb.index("end"), nb.select() == str(nf1),
                            nb.tab(0, "text"), nb.tab(1)["text"]], [True, 2, True, "First", "Second"])
    nb.select(1)
    root.update()
    check("notebook select", [nb.index("current"), changed[-1], nf2.winfo_ismapped(), nf1.winfo_ismapped()],
          [1, 1, 1, 0])
    tv = ttk.Treeview(root, columns=("size", "kind"))
    ia = tv.insert("", "end", text="A", values=(10, "dir"))
    ib = tv.insert(ia, "end", text="B", values=(3, "file"))
    ic = tv.insert("", 0, iid="top", text="C")
    check("treeview insert", [ia, ib, ic, tv.get_children(), tv.get_children(ia), tv.parent(ib), tv.index(ia)],
          ["I001", "I002", "top", ("top", "I001"), ("I002",), "I001", 1])
    check("treeview item", tv.item(ia), {"text": "A", "image": "", "values": [10, "dir"], "open": 0, "tags": ""})
    check("treeview set/column/heading", [tv.set(ib), tv.set(ib, "size"), tv.column("size"), tv.heading("#0")],
          [{"size": "3", "kind": "file"}, "3", {"width": 200, "minwidth": 20, "stretch": 1, "anchor": "w", "id": "size"},
           {"text": "", "image": "", "anchor": "center", "command": ""}])
    sel = []
    tv.bind("<<TreeviewSelect>>", lambda e: sel.append(tv.selection()))
    tv.selection_set(ib)
    root.update()
    check("treeview selection", [tv.selection(), sel], [("I002",), [("I002",)]])
    tv.see(ib)
    check("treeview see opens the parents", tv.item(ia, "open"), 1)
    tv.move(ib, "", "end")
    tv.delete(ia)
    check("treeview move/delete", [tv.get_children(), tv.exists(ia)], [("top", "I002"), False])
    pw = ttk.Panedwindow(root, orient="horizontal")
    pl1 = ttk.Label(pw, text="left")
    pl2 = ttk.Label(pw, text="right")
    pw.add(pl1)
    pw.add(pl2, weight=1)
    pw.pack(fill="x")
    root.update()
    check("ttk panedwindow", [pw.panes() == (str(pl1), str(pl2)), pw.sashpos(0), pw.pane(pl2)],
          [True, hf.measure("left") + 2, {"weight": 1}])
    st.theme_use("clam")
    check("theme_use", st.theme_use(), "clam")
    st.theme_use("default")

    # ── fonts ─────────────────────────────────────────────────────────
    myf = tkfont.Font(root, family="Helvetica", size=12, weight="bold")
    check("font", [myf.actual("weight"), myf.cget("size"), myf.measure("") , myf.metrics("linespace") > 0,
                   str(myf) in tkfont.names(root)], ["bold", 12, 0, True, True])

    # ── dialogs, answered by scripted input ───────────────────────────
    # (the input is queued once the dialog is up: a timer that fires in
    # the dialog's own event loop)
    from tkinter import messagebox, simpledialog, filedialog

    def answer_later(*cmds):
        root.after(150, lambda: root._ny_queue(*cmds))

    answer_later("key Return")
    check("messagebox.showinfo (Return)", messagebox.showinfo("Title", "Message", parent=root), "ok")
    answer_later("key Escape")
    check("messagebox.askyesno (Escape is No)", messagebox.askyesno("Q", "Sure?", parent=root), False)
    answer_later("key Return")
    check("messagebox.askokcancel (Return)", messagebox.askokcancel("Q", "Go on?", parent=root), True)
    answer_later("text 42", "key Return")
    check("simpledialog.askinteger", simpledialog.askinteger("Q", "Number?", parent=root), 42)
    answer_later("text abc", "key Return")
    check("simpledialog.askstring", simpledialog.askstring("Q", "Name?", parent=root), "abc")
    picked_file = os.path.join(tempfile.gettempdir(), "picked.txt")
    answer_later("dialog " + picked_file)
    check("filedialog.askopenfilename", filedialog.askopenfilename(parent=root), picked_file)
    answer_later("dialog")
    check("filedialog cancelled", filedialog.asksaveasfilename(parent=root), "")

    # ── turtle ────────────────────────────────────────────────────────
    import turtle
    scr = turtle.Screen()
    trt = turtle.Turtle()
    trt.speed(0)
    corners = []
    for i in range(4):
        trt.forward(100)
        trt.left(90)
        corners.append((round(trt.xcor()), round(trt.ycor())))
    check("turtle square", [corners, trt.heading(), trt.isdown()],
          [[(100, 0), (100, 100), (0, 100), (0, 0)], 0.0, True])
    v = turtle.Vec2D(3, 4)
    check("Vec2D", [abs(v), tuple(v + v), tuple(v * 2), v * v, repr(v.rotate(90))],
          [5.0, (6, 8), (6, 8), 25, "(-4.00,3.00)"])
    trt.penup()
    trt.goto(10, 20)
    check("goto/towards/distance", [tuple(trt.pos()), round(trt.distance(10, 30)), round(trt.towards(10, 40))],
          [(10.0, 20.0), 10, 90])
    trt.pendown()
    trt.color("red", "yellow")
    trt.begin_fill()
    for i in range(3):
        trt.forward(50)
        trt.left(120)
    trt.end_fill()
    check("turtle colours", [trt.pencolor(), trt.fillcolor()], ["red", "yellow"])
    check("turtle drew on the canvas", len(scr.getcanvas().find_all()) > 3, True)
    check("screen size (half the screen width, 3/4 of its height)",
          [scr.window_width(), scr.window_height()], [root.winfo_screenwidth() // 2, root.winfo_screenheight() * 3 // 4])
    turtle.bye()

    root.destroy()
    try:
        os.remove(_ev)
    except OSError:
        pass
else:
    print("tkinter is not available here: vm_audit114 skipped")

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT114 PASSED ===")
