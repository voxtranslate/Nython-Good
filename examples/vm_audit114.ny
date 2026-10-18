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
    # Nython's Tk is Tk 8.6's behaviour; CPython's are whatever it was built with
    check("versions", [tk.TkVersion, tk.TclVersion, getattr(tk, "_nython", False)],
          [8.6, 8.6, True] if nython else [tk.TkVersion, tk.TclVersion, False])
    check("getboolean/getint", [tcl.getboolean("yes"), tcl.getboolean("off"), tcl.getint("0x10"),
                                tcl.getdouble("2.5")], [True, False, 16, 2.5])

    # CPython without a display: Tk() raises TclError, and the parts that
    # need only a Tcl interpreter (the Tcl layer, the variables) run on Tcl()
    try:
        root = tk.Tk()
        root.geometry("+0+0")
        have_display = True
    except TclError:
        root = tcl
        have_display = False

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

    if have_display:
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
        p3 = tk.Frame(top, width=20, height=10)
        p3.place(x=10, y=5, relwidth=0.5, relheight=0.25)
        p4 = tk.Frame(top, width=20, height=10)
        p4.place(relx=1.0, rely=1.0, x=-5, y=-5, anchor="se")
        top.update()
        check("place relwidth / anchor se", [p3.winfo_width(), p3.winfo_height(), p4.winfo_x(), p4.winfo_y()],
              [100, 25, 175, 85])
        # PlaceInfoCommand builds a string: tkinter's place_info gives strings
        pi = p2.place_info()
        check("place_info", [pi["in"] is top, pi["relx"], pi["x"], pi["width"], pi["relwidth"], pi["anchor"],
                             pi["bordermode"]], [True, "0.5", "0", "50", "", "center", "inside"])
        p2.place_configure(relx=0.25)
        top.update()
        check("place_configure moves it", p2.winfo_x(), 25)
        p3.place_forget()
        top.update()
        check("place_forget / place_slaves", [p3.winfo_ismapped(), [str(w) for w in top.place_slaves()]],
              [0, [str(p1), str(p2), str(p4)]])
        bfr = tk.Frame(top, width=100, height=60, bd=5, relief="ridge")
        bfr.place(x=0, y=0, width=100, height=60)
        in1 = tk.Frame(bfr)
        in1.place(x=0, y=0, relwidth=1.0, height=10)
        in2 = tk.Frame(bfr)
        in2.place(x=0, y=0, relwidth=1.0, height=10, bordermode="outside")
        top.update()
        check("bordermode inside/outside", [in1.winfo_x(), in1.winfo_width(), in2.winfo_x(), in2.winfo_width()],
              [5, 90, 0, 100])
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

        # ── timers, waits, the option database, the clipboard, wm ─────────
        import time
        fired = []
        root.after(10, lambda: fired.append("timer"))
        root.after_idle(lambda: fired.append("idle"))
        root.after_cancel(root.after(5, lambda: fired.append("cancelled")))
        root.update_idletasks()
        time.sleep(0.03)
        root.update()
        check("after/after_idle/after_cancel", fired, ["idle", "timer"])
        wv = tk.IntVar(root)
        root.after(10, lambda: wv.set(5))
        root.wait_variable(wv)
        check("wait_variable", wv.get(), 5)
        root.option_add("*Button.background", "red")
        root.option_add("*background", "blue")
        root.option_add("*Label.foreground", "green", 90)
        root.option_add("*foreground", "yellow")
        ob = tk.Button(root)
        ol = tk.Label(root)
        check("option database (most recent wins, then priority)", [ob["background"], ol["foreground"],
                                                                   root.option_get("background", "Button")],
              ["blue", "green", "blue"])
        root.option_clear()
        check("option_clear", tk.Button(root)["background"], "#d9d9d9")
        root.clipboard_clear()
        root.clipboard_append("abc")
        root.clipboard_append("def")
        check("clipboard", root.clipboard_get(), "abcdef")
        root.title("Audit 114")
        root.resizable(False, True)
        check("wm title/resizable/attributes", [root.title(), root.resizable(), root.attributes("-alpha")],
              ["Audit 114", (0, 1), 1.0])
        root.resizable(True, True)
        wt = tk.Toplevel(root)
        wt.geometry("120x80+30+40")
        wt.update()
        check("wm geometry", [wt.geometry(), wt.winfo_width(), wt.winfo_height(), wt.winfo_x(), wt.winfo_y()],
              ["120x80+30+40", 120, 80, 30, 40])
        cfg = []
        wt.bind("<Configure>", lambda e: cfg.append((e.width, e.height)))
        wt.geometry("150x90")
        wt.update()
        check("<Configure> on resize", cfg[-1:], [(150, 90)])
        wt.destroy()

        # ── more classic widgets ──────────────────────────────────────────
        lb = tk.Listbox(root)
        lb.insert("end", "one", "two", "three")
        lb.selection_set(1)
        check("listbox", [lb.get(0, "end"), lb.size(), lb.curselection(), lb.get(1)],
              [("one", "two", "three"), 3, (1,), "two"])
        # tkListbox.c: width chars of "0" + 2*(bd + highlight); lines of
        # linespace + 1 (+ 2*selectborderwidth, 0 on X11)
        check("listbox request", [lb.winfo_reqwidth(), lb.winfo_reqheight()],
              [20 * f12.measure("0") + 4, 10 * (ls + 1) + 4])
        mn = tk.Menu(root)
        mhit = []
        mn.add_command(label="Open", command=lambda: mhit.append("open"))
        mn.add_separator()
        mchk = tk.BooleanVar(root)
        mn.add_checkbutton(label="Flag", variable=mchk)
        check("menu entries", [mn.index("end"), mn.type(0), mn.type(1), mn.type(2), mn.type(3), mn.entrycget(1, "label")],
              [3, "tearoff", "command", "separator", "checkbutton", "Open"])
        mn.invoke(1)
        mn.invoke(3)
        check("menu invoke", [mhit, mchk.get()], [["open"], True])
        omv = tk.StringVar(root, value="a")
        om = tk.OptionMenu(root, omv, "a", "b", "c")
        om["menu"].invoke(1)
        check("OptionMenu", [omv.get(), om["text"] if False else om.cget("textvariable") == str(omv)], ["b", True])
        sbx = tk.Spinbox(root, from_=0, to=5)
        sbx.invoke("buttonup")
        sbx.invoke("buttonup")
        check("spinbox (classic)", sbx.get(), "2")
        scl = tk.Scale(root, from_=0, to=10, orient="horizontal")
        scl.set(7)
        check("scale (classic)", scl.get(), 7)
        from tkinter import scrolledtext, colorchooser
        stx = scrolledtext.ScrolledText(root, width=20, height=5)
        stx.insert("1.0", "line\n" * 20)
        check("ScrolledText", [stx.frame.winfo_class(), stx.vbar.winfo_class(), str(stx) == str(stx.frame),
                               int(float(stx.index("end")))], ["Frame", "Scrollbar", True, 22])

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

        # ── event sequences ───────────────────────────────────────────────
        sq = tk.Frame(root, width=60, height=40)
        sq.pack()
        root.update()
        for seq in ("<Double-Button-1>", "<Control-Shift-KeyPress-a>", "<B1-Motion>", "<Enter>"):
            sq.bind(seq, lambda e: None)
        check("bind() lists the canonical sequences, newest first", sq.bind(),
              ("<Enter>", "<B1-Motion>", "<Control-Shift-Key-a>", "<Double-Button-1>"))
        try:
            sq.bind("<Foo>", lambda e: None)
            check("bad sequence", "no error", "TclError")
        except TclError as e:
            check("bad sequence", str(e), 'bad event type or keysym "Foo"')
        dbl = []
        sq.bind("<Double-Button-1>", lambda e: dbl.append("double"))
        sq.bind("<Button-1>", lambda e: dbl.append("single"))
        x, y = at(sq)
        root._ny_drive(["click %d %d" % (x, y), "click %d %d" % (x, y)])
        check("a double click: Button-1 then Double-Button-1", dbl, ["single", "double"])
        crossing = []
        sq.bind("<Enter>", lambda e: crossing.append("enter"))
        sq.bind("<Leave>", lambda e: crossing.append("leave"))
        root._ny_drive(["move 1 1", "move %d %d" % (x, y), "move 1 1"])
        check("<Enter>/<Leave> from pointer motion", crossing[-2:], ["enter", "leave"])
        sq.destroy()

        # ── pack options ──────────────────────────────────────────────────
        top = tk.Toplevel(root)
        pa = tk.Frame(top, width=50, height=20)
        pb_ = tk.Frame(top, width=50, height=20)
        pc = tk.Frame(top, width=50, height=20)
        pa.pack(side="top", padx=5, pady=3)
        pb_.pack(side="top", ipadx=4, ipady=2)
        pc.pack(side="top", before=pa)
        top.update()
        # widths: a 50 + 2*5, b 50 + 2*4 (internal), c 50; heights 20 + 20+2*3 + 20+2*2
        check("pack: padx/ipadx/before", [top.pack_slaves() == [pc, pa, pb_], top.winfo_reqwidth(), top.winfo_reqheight()],
              [True, 60, 70])
        check("pack: positions", [(pc.winfo_x(), pc.winfo_y()), (pa.winfo_x(), pa.winfo_y()),
                                  (pb_.winfo_x(), pb_.winfo_y(), pb_.winfo_width(), pb_.winfo_height())],
              [(5, 0), (5, 23), (1, 46, 58, 24)])
        top.pack_propagate(False)
        pa.pack_forget()
        top.update()
        check("pack_forget, pack_propagate(False)", [top.pack_slaves() == [pc, pb_], pb_.winfo_y(),
                                                    top.winfo_reqwidth(), top.winfo_reqheight()], [True, 20, 60, 70])
        pd = tk.Frame(top, width=20, height=20)
        pd.pack(side="left", anchor="n", fill="none")
        top.update()
        check("pack anchor", [pd.winfo_x(), pd.winfo_y()], [0, 44])
        top.destroy()

        # ── grid options ──────────────────────────────────────────────────
        top = tk.Toplevel(root)
        g1 = tk.Frame(top, width=30, height=10)
        g2 = tk.Frame(top, width=50, height=10)
        g1.grid(row=0, column=0)
        g2.grid(row=0, column=1)
        top.columnconfigure(0, uniform="u")
        top.columnconfigure(1, uniform="u")
        top.update()
        check("grid uniform columns", [top.winfo_reqwidth(), g1.winfo_x(), g2.winfo_x()], [100, 10, 50])
        check("grid_location", [top.grid_location(60, 5), top.grid_location(10, 5)], [(1, 0), (0, 0)])
        g2.grid_configure(padx=3)
        g2.grid_remove()
        top.update()
        check("grid_remove", [g2.winfo_ismapped(), top.grid_slaves() == [g1]], [0, True])
        g2.grid()
        top.update()
        check("grid() restores the options", [g2.grid_info()["column"], g2.grid_info()["padx"], g2.winfo_ismapped()],
              [1, 3, 1])
        top.columnconfigure(0, minsize=80, uniform="")
        top.columnconfigure(1, uniform="")
        top.update()
        check("grid minsize", [g1.winfo_x(), top.columnconfigure(0)["minsize"]], [25, 80])
        top.destroy()

        # ── entry validation and scrolling ────────────────────────────────
        vlog = []

        def vcmd(P, s, d):
            vlog.append((P, s, d))
            return P.isdigit() or P == ""

        ve = tk.Entry(root, validate="key", validatecommand=(root.register(vcmd), "%P", "%s", "%d"))
        ve.insert(0, "12")
        ve.insert("end", "x")
        ve.delete(0)
        check("entry validation (%P %s %d)", [ve.get(), vlog], ["2", [("12", "", "1"), ("12x", "12", "1"), ("2", "12", "0")]])
        se = tk.Entry(root, show="*")
        se.insert(0, "secret")
        check("entry show=", [se.get(), se.index("end")], ["secret", 6])
        xs = []
        xe = tk.Entry(root, width=5, xscrollcommand=lambda a, b: xs.append((float(a), float(b))))
        xe.pack()
        xe.insert(0, "0123456789" * 3)
        root.update()
        check("entry xscrollcommand", [xs[-1][0], xs[-1][1] < 1.0], [0.0, True])
        xe.xview_moveto(0.5)
        root.update()
        check("entry xview moveto", round(xs[-1][0], 2), 0.5)
        xe.destroy()

        # ── check/radio buttons, keyboard activation ──────────────────────
        rv = tk.StringVar(root, value="x")
        r1 = tk.Radiobutton(root, value="a", variable=rv)
        r2 = tk.Radiobutton(root, value="b", variable=rv)
        r2.select()
        v_after_select = rv.get()
        r1.invoke()
        check("radiobuttons", [v_after_select, rv.get()], ["b", "a"])
        cv2 = tk.IntVar(root)
        c2 = tk.Checkbutton(root, variable=cv2, onvalue=5, offvalue=2)
        c2.select()
        states = [cv2.get()]
        c2.toggle()
        states.append(cv2.get())
        c2.deselect()
        states.append(cv2.get())
        check("checkbutton select/toggle/deselect", states, [5, 2, 2])
        kb = []
        kbtn = tk.Button(root, text="Key", command=lambda: kb.append("space"))
        kbtn.pack()
        root.update()
        kbtn.focus_force()
        root._ny_drive(["key space"])
        kbtn.flash()
        check("space activates the focused button", kb, ["space"])
        kbtn.destroy()

        # ── listbox interaction, scrollbars ───────────────────────────────
        lsel = []
        lb2 = tk.Listbox(root, height=3, selectmode="single")
        sbar = tk.Scrollbar(root, command=lb2.yview)
        lb2.configure(yscrollcommand=sbar.set)
        for i in range(10):
            lb2.insert("end", "item%d" % i)
        lb2.pack()
        sbar.pack()
        lb2.bind("<<ListboxSelect>>", lambda e: lsel.append(lb2.curselection()))
        root.update()
        check("scrollbar follows the listbox", sbar.get(), (0.0, 0.3))
        x, y = at(lb2, 10, 3 + 1)
        root._ny_drive("click %d %d" % (x, y))
        check("a click selects (<<ListboxSelect>>)", [lb2.curselection(), lsel[-1:]], [(0,), [(0,)]])
        lb2.yview_moveto(0.5)
        root.update()
        check("yview moveto", [lb2.nearest(0), sbar.get()], [5, (0.5, 0.8)])
        lb2.see(9)
        lb2.activate(9)
        check("see/activate", [lb2.index("active"), lb2.yview()[1]], [9, 1.0])
        lb2.destroy()
        sbar.destroy()

        # ── text extras ───────────────────────────────────────────────────
        t2 = tk.Text(root)
        t2.insert("1.0", "ab")
        mod = [t2.edit_modified()]
        t2.edit_modified(False)
        mod.append(t2.edit_modified())
        # Tk 8.6 gives the flag as a Tcl boolean object, which _tkinter makes an int
        check("edit_modified", mod, [1, 0])
        # the insert mark (right gravity) sits between "ab" and the newline: Tk's
        # dump reports one item per character segment
        dmp = t2.dump("1.0", "end", text=True)
        check("dump", ["".join([d[1] for d in dmp]), dmp[0][2], [d[0] for d in dmp]], ["ab\n", "1.0", ["text", "text"]])
        t2.tag_configure("big", font=("Helvetica", 20))
        check("tag_cget", t2.tag_cget("big", "font"), "Helvetica 20")

        # ── canvas extras ─────────────────────────────────────────────────
        cv3 = tk.Canvas(root, width=200, height=100)
        cv3.pack()
        pg = cv3.create_polygon(10, 10, 50, 10, 30, 40)
        im_item = cv3.create_image(20, 30, image=img, anchor="nw")
        wf = tk.Frame(cv3, width=30, height=20)
        wi = cv3.create_window(50, 50, window=wf, anchor="nw")
        root.update()
        check("canvas polygon/image/window", [cv3.bbox(pg), cv3.bbox(im_item), cv3.type(wi), wf.winfo_x(), wf.winfo_y()],
              [(9, 9, 51, 41), (20, 30, 24, 33), "window", 50, 50])
        cv3.tag_lower(wi)
        order1 = cv3.find_all()
        cv3.tag_raise(pg)
        check("lift/lower", [order1, cv3.find_all()], [(wi, pg, im_item), (wi, im_item, pg)])
        tb_hits = []
        cv3.tag_bind(pg, "<Button-1>", lambda e: tb_hits.append((e.x, e.y)))
        cv3.event_generate("<Motion>", x=30, y=20)
        cv3.event_generate("<Button-1>", x=30, y=20)
        check("tag_bind", tb_hits, [(30, 20)])
        cv3.configure(scrollregion=(0, 0, 1000, 1000))
        cv3.xview_moveto(0.5)
        # CanvasSetOrigin: scrollX1 - inset + fraction * width of the region
        check("scrollregion and xview", [cv3.canvasx(0), round(cv3.xview()[0], 3)], [499.0, 0.5])
        sm = cv3.create_line(0, 0, 50, 50, 100, 0, smooth=True, arrow="last")
        check("smooth/arrow options", [cv3.itemcget(sm, "smooth"), cv3.itemcget(sm, "arrow")], ["true", "last"])
        cv3.destroy()

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
        fm = myf.metrics()
        check("font metrics", [sorted(fm.keys()), fm["linespace"] == fm["ascent"] + fm["descent"], fm["fixed"],
                               tkfont.nametofont("TkFixedFont").metrics("fixed")],
              [["ascent", "descent", "fixed", "linespace"], True, 0, 1])
        check("font actual()", sorted(myf.actual().keys()),
              ["family", "overstrike", "size", "slant", "underline", "weight"])
        myf.configure(size=14)
        plainf = tkfont.Font(root, family="Helvetica", size=14)
        check("font configure / measure", [myf["size"], myf.actual("size"), myf.measure("abc") < myf.measure("abcd"),
                                           myf.measure("abc") >= plainf.measure("abc")], [14, 14, True, True])
        cpf = myf.copy()
        check("font copy / equality", [cpf.name != myf.name, cpf.actual() == myf.actual(), cpf == myf,
                                       myf == tkfont.Font(root, name=myf.name, exists=True)], [True, True, False, True])
        check("font from a description", [tkfont.Font(root, font=("Courier", 10, "italic")).actual("slant"),
                                           tkfont.Font(root, font="Times 9 underline").actual("underline")],
              ["italic", 1])
        try:
            tkfont.Font(root, name="nosuchfont", exists=True)
            check("font exists=True", "no error", "TclError")
        except TclError as e:
            check("font exists=True", str(e), "named font nosuchfont does not already exist")
        lblf = tkfont.Font(root, name="vm114font", size=9)
        try:
            tkfont.Font(root, name="vm114font")
            check("font name taken", "no error", "TclError")
        except TclError as e:
            check("font name taken", str(e), 'named font "vm114font" already exists')
        flab = tk.Label(root, text="x", font=lblf)
        flab.pack()
        root.update()
        h9 = flab.winfo_reqheight()
        lblf.configure(size=20)
        root.update()
        check("a named font's change reaches its widgets", [flab.cget("font"), flab.winfo_reqheight() > h9],
              ["vm114font", True])
        flab.destroy()
        check("families", [type(tkfont.families(root)).__name__, len(tkfont.families(root)) > 0], ["tuple", True])

        # ── dialogs, answered by scripted input ───────────────────────────
        # (the input is queued once the dialog is up, mapped and has the
        # focus: a timer polling for it in the dialog's own event loop)
        from tkinter import messagebox, simpledialog, filedialog

        def dialog_up(m, title):
            foc = str(m.tk.call("focus"))
            if foc == "":
                return False
            todo = list(m.tk.splitlist(m.tk.call("winfo", "children", ".")))
            while todo:
                p = str(todo.pop())
                if str(m.tk.call("winfo", "toplevel", p)) == p:
                    if str(m.tk.call("wm", "title", p)) == title and str(m.tk.call("winfo", "ismapped", p)) == "1" \
                            and str(m.tk.call("winfo", "toplevel", foc)) == p:
                        return True
                todo.extend(m.tk.splitlist(m.tk.call("winfo", "children", p)))
            return False

        def answer_when(cond, cmds, then=None, m=None):
            m = root if m is None else m
            tries = [0]

            def poll():
                tries[0] += 1
                if cond():
                    m._ny_queue(*cmds)
                    if then is not None:
                        then()
                elif tries[0] < 1500:
                    m.after(20, poll)
            m.after(20, poll)

        def answer(title, *cmds):
            answer_when(lambda: dialog_up(root, title), cmds)

        def answer_native(*cmds):
            answer_when(lambda: getattr(root.tk, "dialog_waiter", None) is not None, cmds)

        answer("Info", "key Return")
        check("messagebox.showinfo (Return)", messagebox.showinfo("Info", "Message", parent=root), "ok")
        answer("YN", "key Escape")
        check("messagebox.askyesno (Escape is No)", messagebox.askyesno("YN", "Sure?", parent=root), False)
        answer("YN2", "key Tab", "key Return")
        check("messagebox.askyesno (Tab to No, Return)", messagebox.askyesno("YN2", "Sure?", parent=root), False)
        answer("OC", "key Return")
        check("messagebox.askokcancel (Return)", messagebox.askokcancel("OC", "Go on?", parent=root), True)
        answer("AQ", "key Return")
        check("messagebox.askquestion", messagebox.askquestion("AQ", "Go?", parent=root), "yes")
        answer("YNC", "key Escape")
        check("messagebox.askyesnocancel (Escape is None)", messagebox.askyesnocancel("YNC", "Save?", parent=root), None)
        answer("RC", "key Return")
        check("messagebox.askretrycancel", messagebox.askretrycancel("RC", "Again?", parent=root), True)
        answer("W", "key Return")
        answer_when(lambda: dialog_up(root, "E"), ["key Return"])
        check("showwarning / showerror", [messagebox.showwarning("W", "Careful", parent=root),
                                          messagebox.showerror("E", "Bad", parent=root)], ["ok", "ok"])
        answer("Q", "text 42", "key Return")
        check("simpledialog.askinteger", simpledialog.askinteger("Q", "Number?", parent=root), 42)
        # out of range: the warning, then a good answer
        answer_when(lambda: dialog_up(root, "R"), ["text 50", "key Return"],
                    then=lambda: answer_when(lambda: dialog_up(root, "Too large"), ["key Return"],
                                             then=lambda: answer("R", "key ctrl+/", "text 5", "key Return")))
        check("askinteger validates against maxvalue",
              simpledialog.askinteger("R", "1..10", minvalue=1, maxvalue=10, parent=root), 5)
        answer("S", "text abc", "key Return")
        check("simpledialog.askstring", simpledialog.askstring("S", "Name?", parent=root), "abc")
        answer("S2", "key Escape")
        check("askstring cancelled", simpledialog.askstring("S2", "Name?", parent=root), None)
        answer("F", "text 2.5", "key Return")
        check("simpledialog.askfloat", simpledialog.askfloat("F", "x?", parent=root), 2.5)
        answer_when(lambda: dialog_up(root, "F2"), ["text abc", "key Return"],
                    then=lambda: answer_when(lambda: dialog_up(root, "Illegal value"), ["key Return"],
                                             then=lambda: answer("F2", "key Escape")))
        check("askfloat: an illegal value warns, then cancel",
              simpledialog.askfloat("F2", "x?", parent=root), None)
        picked_file = os.path.join(tempfile.gettempdir(), "vm_audit114_%d.txt" % os.getpid())
        with open(picked_file, "w") as pf:
            pf.write("picked\n")
        answer_native("dialog " + picked_file)
        check("filedialog.askopenfilename", filedialog.askopenfilename(parent=root), picked_file)
        answer_native("dialog")
        check("filedialog cancelled", filedialog.asksaveasfilename(parent=root), "")
        answer_native("dialog " + picked_file)
        check("askopenfilenames", filedialog.askopenfilenames(parent=root), (picked_file,))
        answer_native("dialog " + picked_file)
        pfo = filedialog.askopenfile(parent=root)
        check("askopenfile opens it", [pfo.name, pfo.read()], [picked_file, "picked\n"])
        pfo.close()
        answer_native("dialog")
        check("askopenfile cancelled", filedialog.askopenfile(parent=root), None)
        answer_native("dialog " + tempfile.gettempdir())
        check("askdirectory", filedialog.askdirectory(parent=root), tempfile.gettempdir())
        os.remove(picked_file)

        answer("Pick", "key Return")
        check("colorchooser.askcolor (Return keeps the colour)",
              colorchooser.askcolor("#ff8000", parent=root, title="Pick"), ((255, 128, 0), "#ff8000"))
        answer("Pick2", "key Escape")
        check("colorchooser cancelled", colorchooser.askcolor("#123456", parent=root, title="Pick2"), (None, None))

        stx.pack()
        root.update()
        check("ScrolledText's geometry methods are its frame's",
              [str(stx.pack_info()["in"]), stx.winfo_parent() == str(stx.frame), stx.vbar.get()[0]], [".", True, 0.0])
        stx.see("end")
        root.update()
        check("ScrolledText scrolls", stx.vbar.get()[1], 1.0)
        stx.pack_forget()

        # ── tkinter.dnd, tkinter.constants ────────────────────────────────
        from tkinter import dnd, constants
        dlog = []

        class DndToken:
            def dnd_end(self, target, event):
                dlog.append(("end", target is dbin))

        class DndBin:
            def dnd_enter(self, source, event):
                dlog.append("enter")

            def dnd_motion(self, source, event):
                if dlog[-1:] != ["motion"]:
                    dlog.append("motion")

            def dnd_leave(self, source, event):
                dlog.append("leave")

            def dnd_commit(self, source, event):
                dlog.append(("commit", source is dtok))

        dtok = DndToken()
        dbin = DndBin()
        dsrc = tk.Label(root, text="drag me", width=10)
        ddst = tk.Frame(root, width=100, height=60)
        dsrc.pack()
        ddst.pack()
        ddst.dnd_accept = lambda source, event: dbin
        dsrc.bind("<ButtonPress-1>", lambda e: dnd.dnd_start(dtok, e))
        root.update()
        x1, y1 = at(dsrc)
        x2, y2 = at(ddst, 50, 30)
        root._ny_drive("drag %d %d %d %d" % (x1, y1, x2, y2))
        check("dnd: a drag onto a target commits", [dlog, dsrc["cursor"]],
              [["enter", "motion", ("commit", True), ("end", True)], ""])
        del dlog[:]
        root._ny_drive("drag %d %d %d %d" % (x1, y1, x2, y2 + 100))
        check("dnd: released outside, the target is left", [dlog[:1], dlog[-2:], ("commit", True) in dlog],
              [["enter"], ["leave", ("end", False)], False])
        dsrc.destroy()
        ddst.destroy()
        check("constants", [constants.N, constants.SE, constants.BOTH, constants.HORIZONTAL, constants.SUNKEN,
                            constants.TRUE, constants.END, constants.SEL_FIRST, constants.WORD, constants.MOVETO],
              ["n", "se", "both", "horizontal", "sunken", 1, "end", "sel.first", "word", "moveto"])

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
        # turtle.py keeps a pen's run of segments in one canvas line item, in
        # canvas coordinates (y down): the square's five points
        tcv = scr.getcanvas()
        sq_item = trt.currentLineItem
        check("the square is one line item, at the turtle's points",
              [tcv.type(sq_item), [round(c) for c in tcv.coords(sq_item)], tcv.itemcget(sq_item, "fill")],
              ["line", [0, 0, 100, 0, 100, -100, 0, -100, 0, 0], "black"])
        v = turtle.Vec2D(3, 4)
        check("Vec2D", [abs(v), tuple(v + v), tuple(v * 2), v * v, repr(v.rotate(90))],
              [5.0, (6, 8), (6, 8), 25, "(-4.00,3.00)"])
        trt.penup()
        trt.goto(10, 20)
        check("goto/towards/distance", [tuple(trt.pos()), round(trt.distance(10, 30)), round(trt.towards(10, 40))],
              [(10, 20), 10, 90])
        trt.pendown()
        trt.color("red", "yellow")
        trt.begin_fill()
        fill_item = trt._fillitem
        for i in range(3):
            trt.forward(50)
            trt.left(120)
        trt.end_fill()
        check("turtle colours", [trt.pencolor(), trt.fillcolor()], ["red", "yellow"])
        check("the filled triangle is a polygon item",
              [tcv.type(fill_item), [round(c) for c in tcv.coords(fill_item)], tcv.itemcget(fill_item, "fill")],
              ["polygon", [10, -20, 60, -20, 35, -63, 10, -20], "yellow"])
        # stamps, writing, undo
        sid = trt.stamp()
        stamped = [tcv.type(sid), sid in tcv.find_all()]
        trt.clearstamp(sid)
        stamped.append(sid in tcv.find_all())
        check("stamp / clearstamp", stamped, ["polygon", True, False])
        trt.penup()
        trt.goto(-50, 50)
        trt.write("Hi", align="center", font=("Arial", 12, "normal"))
        # (the turtle's own shape is raised above everything it draws)
        txt = [i for i in tcv.find_all() if tcv.type(i) == "text"][-1]
        check("write makes a text item anchored at the turtle",
              [tcv.type(txt), tcv.itemcget(txt, "text"), tcv.itemcget(txt, "anchor"), [round(c) for c in tcv.coords(txt)]],
              ["text", "Hi", "s", [-51, -50]])
        trt.pendown()
        trt.forward(30)
        after_fd = tuple([round(c, 6) for c in trt.pos()])
        trt.undo()
        check("undo takes the last move back", [after_fd, tuple(trt.pos())], [(-20.0, 50.0), (-50, 50)])
        scr.tracer(0)
        n_before = len(tcv.find_all())
        trt.circle(20)
        scr.update()
        check("tracer(0) then update", [scr.tracer(), len(tcv.find_all()) >= n_before, round(trt.xcor()), round(trt.ycor())],
              [0, True, -50, 50])
        scr.tracer(1)
        # input through the turtle's own window (a second Tk application)
        clicks = []
        scr.onclick(lambda cx, cy: clicks.append((round(cx), round(cy))))
        inner = tcv._canvas
        ex = 30 - inner.canvasx(0)
        ey = -40 - inner.canvasy(0)
        troot = scr._root
        wx = inner.winfo_rootx() - troot.winfo_rootx() + ex
        wy = inner.winfo_rooty() - troot.winfo_rooty() + ey
        troot._ny_drive("click %d %d" % (wx, wy))
        check("screen.onclick gets turtle coordinates", clicks, [(30, 40)])
        keys = []
        scr.onkey(lambda: keys.append("up"), "Up")
        scr.onkeypress(lambda: keys.append("press a"), "a")
        scr.listen()
        troot._ny_drive("key Up", "key a")
        check("onkey (on release) / onkeypress", keys, ["up", "press a"])
        answer_when(lambda: dialog_up(troot, "Name"), ["text Ada", "key Return"], m=troot)
        check("screen.textinput", scr.textinput("Name", "Who?"), "Ada")
        answer_when(lambda: dialog_up(troot, "Num"), ["text 7.5", "key Return"], m=troot)
        check("screen.numinput", scr.numinput("Num", "How many?", minval=0, maxval=10), 7.5)
        scr.setworldcoordinates(-10, -10, 10, 10)
        check("setworldcoordinates", [scr.mode(), round(scr.xscale * 20) == scr.canvwidth], ["world", True])
        scr.mode("standard")
        check("mode('standard') resets", [scr.mode(), tuple(trt.pos())], ["standard", (0.0, 0.0)])
        check("turtle drew on the canvas", len(scr.getcanvas().find_all()) > 3, True)
        check("screen size (half the screen width, 3/4 of its height)",
              [scr.window_width(), scr.window_height()], [root.winfo_screenwidth() // 2, root.winfo_screenheight() * 3 // 4])
        turtle.bye()

        root.destroy()
    else:
        print("no display: only the Tcl layer and the variables ran")

else:
    print("tkinter is not available here: vm_audit114 skipped")
try:
    os.remove(_ev)
except OSError:
    pass

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT114 PASSED ===")
