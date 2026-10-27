# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/ttk2.ny - the larger themed widgets (round 84): ttk::entry,
# ttk::combobox (with its popdown list), ttk::spinbox (ttkEntry.c and
# entry.tcl/combobox.tcl/spinbox.tcl), ttk::scrollbar (ttkScroll.c,
# scrollbar.tcl), ttk::scale (ttkScale.c, scale.tcl), ttk::progressbar
# (ttkProgress.c, progress.tcl), ttk::notebook (ttkNotebook.c,
# notebook.tcl), ttk::panedwindow (ttkPanedwindow.c, panedwindow.tcl) and
# ttk::treeview (ttkTreeview.c, treeview.tcl). The editing behaviour of the
# entries is the classic entry's (entry.ny), drawn through their layout.
#
# Not provided: the treeview's 8.7 additions (-striped, -selecttype cell,
# cellselection, -titlecolumns), the notebook's -tabplacement sides other
# than the top (tabs are always laid out along the top edge, -tabposition is
# kept), and the panedwindow's sash grips.

import math
from _tkinter.tcl import (TclError, tcl_str, tcl_float, split_list, join_list, quote_elem, get_int, get_double,
                          get_boolean, match_prefix, or_list)
from _tkinter.util import (pixels, fpixels, parse_color, cdiv, cround, shades, fill, line, text as draw_text,
                           draw_relief, draw_ring, layout_text)
from _tkinter.win import TkWin, fmt_frac
from _tkinter import core as C
from _tkinter import bind as B
from _tkinter import geom as G
from _tkinter import entry as E
from _tkinter import widgets as W
from _tkinter import ttk as T
from _tkinter.ttk import (O, TtkWidget, core_opts, label_opts, engine, make_layout, parse_statespec,
                          statespec_string, state_matches, parse_padding, pad_add, parse_sticky, stick_box, _words,
                          S_ACTIVE, S_DISABLED, S_FOCUS, S_PRESSED, S_SELECTED, S_BACKGROUND, S_ALTERNATE, S_INVALID,
                          S_READONLY, S_HOVER, SBIT, style_query)


def _fmtd(v):
    return tcl_float(float(v))


# ── ttk::entry, ttk::combobox, ttk::spinbox ───────────────────────────────
TENTRY_OPTS = [O("exportselection", "exportSelection", "ExportSelection", 1, "boolean"),
               O("font", "font", "Font", "TkTextFont", "font"),
               O("invalidcommand", "invalidCommand", "InvalidCommand", "", "command"),
               O("justify", "justify", "Justify", "left", "justify"),
               O("show", "show", "Show", "", "string"),
               O("state", "state", "State", "normal", "string"),
               O("textvariable", "textVariable", "Variable", "", "var"),
               O("validate", "validate", "Validate", "none",
                 "enum:all|key|focus|focusin|focusout|none:validate"),
               O("validatecommand", "validateCommand", "ValidateCommand", "", "command"),
               O("width", "width", "Width", 20, "int"),
               O("xscrollcommand", "xScrollCommand", "ScrollCommand", "", "command"),
               O("foreground", "textColor", "TextColor", None, "color_or_none"),
               O("background", "windowColor", "WindowColor", None, "color_or_none"),
               O("takefocus", "takeFocus", "TakeFocus", "ttk::takefocus", "string"),
               O("cursor", "cursor", "Cursor", "xterm", "cursor"),
               O("style", "style", "Style", "", "string"),
               O("class", "", "", "", "string")]

_HIDDEN = {"borderwidth": 0, "highlightthickness": 0, "relief": "flat", "insertborderwidth": 0,
           "insertofftime": 300, "insertontime": 600, "selectborderwidth": 0, "disabledbackground": "",
           "readonlybackground": "", "disabledforeground": ""}


class TtkEntry(TtkWidget, E.TkEntry):
    CLASS = "TEntry"
    OPTS = TENTRY_OPTS
    ALIASES = {"invcmd": "invalidcommand", "vcmd": "validatecommand"}
    CMDS = ["bbox", "cget", "configure", "delete", "get", "icursor", "identify", "index", "insert", "instate",
            "selection", "state", "validate", "xview"]
    TAKES_FOCUS = True
    A11Y_ROLE = "textbox"

    def __init__(self, app, path, parent, wclass=None):
        E.TkEntry.__init__(self, app, path, parent, wclass)
        engine(app)
        self.tstate = 0
        self.layout = None
        self.layout_key = None
        self.placed = None
        self.placed_key = None

    def init_options(self):
        TtkWidget.init_options(self)
        for k, v in _HIDDEN.items():
            self.opts[k] = v

    def record_opts(self):
        # the element options the widget supplies
        return {"font": self.opts.get("font"), "width": self.opts.get("width"),
                "foreground": self.opts.get("foreground"), "fieldbackground": self.opts.get("background")}

    # the entry's own textvariable handling, not the label-like one of
    # TtkWidget (both bases define it)
    _textvar_changed = E.TkEntry._textvar_changed

    def estate(self):
        if self.tstate & S_DISABLED:
            return "disabled"
        if self.tstate & S_READONLY:
            return "readonly"
        return "normal"

    def lookup(self, opt, default=None):
        st = self.get_layout().style
        v = style_query(st, "-" + opt, self.tstate)
        return v if v is not None else default

    def sync_hidden(self):
        fg = self.opts.get("foreground") or self.lookup("foreground", "black")
        self.opts["insertbackground"] = self.lookup("insertcolor", fg)
        self.opts["selectbackground"] = self.lookup("selectbackground", "#c3c3c3")
        self.opts["selectforeground"] = self.lookup("selectforeground", "")
        self.opts["insertwidth"] = self.lookup("insertwidth", 1)

    def reconfigured(self, changed):
        if "state" in changed:
            s = self.opts.get("state") or "normal"
            allb = S_DISABLED | S_READONLY | S_ACTIVE
            f = {"normal": 0, "readonly": S_READONLY, "disabled": S_DISABLED, "active": S_ACTIVE}.get(s, 0)
            self.change_state(f, allb ^ f)
        self.layout_key = None
        E.TkEntry.reconfigured(self, changed)

    def compute_geometry(self):
        lay = self.get_layout()
        w, h = lay.size(self.tstate)
        f = self.font()
        self.avg = max(1, f.measure("0"))
        self.request(w, h)
        self.text_box()
        self.compute_left()

    def text_box(self):
        lay = self.get_layout()
        ww = max(self.width, self.reqw) if self.width <= 1 else self.width
        hh = max(self.height, self.reqh) if self.height <= 1 else self.height
        lay.invalidate()
        pl = lay.place((0, 0, ww, hh), self.tstate)
        ta = lay.find(pl, "textarea")
        if ta is None:
            box = (0, 0, ww, hh)
        else:
            box = ta.box
        self.inset = box[0]
        self.xwidth = max(0, ww - (box[0] + box[2]) - self.inset)
        self.ta = box
        return box

    def on_resize(self):
        self.placed = None
        self.text_box()
        E.TkEntry.on_resize(self)

    def validate_change(self, change, new, index, kind, reason=None):
        code = E.TkEntry.validate_change(self, change, new, index, kind, reason)
        if self.opts.get("validatecommand") and self.opts.get("validate") != "none":
            if code == "ok":
                self.change_state(0, S_INVALID)
            elif code == "break":
                self.change_state(S_INVALID, 0)
        return code

    def w_validate(self, args):
        r = E.TkEntry.w_validate(self, args)
        if self.opts.get("validatecommand"):
            if r:
                self.change_state(0, S_INVALID)
            else:
                self.change_state(S_INVALID, 0)
        return r

    def on_event(self, ev):
        TtkWidget.on_event(self, ev)
        E.TkEntry.on_event(self, ev)

    def w_identify(self, args):
        return TtkWidget.w_identify(self, args)

    def draw(self, h, ax, ay):
        self.sync_hidden()
        lay = self.get_layout()
        pl = self.placements()
        lay.draw(h, ax, ay, pl, self.tstate)
        box = self.text_box()
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        ds = self.display_string()
        ty = box[1] + (box[3] - ls) // 2
        fg = self.color("foreground") if self.opts.get("foreground") else T._color(self.lookup("foreground"), 0)
        gui_push_clip(h, ax + box[0], ay + box[1], box[2], box[3])
        if self.sel_first >= 0 and self.sel_last > self.sel_first:
            x0 = self.layout_x + f.measure(ds[:self.sel_first])
            x1 = self.layout_x + f.measure(ds[:self.sel_last])
            fill(h, ax + x0, ay + ty, x1 - x0, ls, T._color(self.opts["selectbackground"], 0xc3c3c3))
            draw_text(h, ds[:self.sel_first], ax + self.layout_x, ay + ty, f, fg)
            sfg = T._color(self.opts.get("selectforeground"), fg)
            draw_text(h, ds[self.sel_first:self.sel_last], ax + x0, ay + ty, f, sfg)
            draw_text(h, ds[self.sel_last:], ax + x1, ay + ty, f, fg)
        else:
            draw_text(h, ds, ax + self.layout_x, ay + ty, f, fg)
        if self.has_focus and self.estate() == "normal":
            cx = self.layout_x + f.measure(ds[:self.insert_pos])
            iw = max(1, T._px(self.opts.get("insertwidth"), 1))
            fill(h, ax + cx - iw // 2, ay + ty, iw, ls, T._color(self.opts["insertbackground"], fg))
        gui_pop_clip(h)

    def w_bbox(self, args):
        x, y, w, hh = E.TkEntry.w_bbox(self, args)
        return (x, self.ta[1] + (self.ta[3] - hh) // 2, w, hh) if getattr(self, "ta", None) else (x, y, w, hh)

    def a11y_value(self):
        return self.display_string()


TCOMBO_OPTS = sorted(TENTRY_OPTS + [O("height", "height", "Height", 10, "int"),
                                    O("postcommand", "postCommand", "PostCommand", "", "command"),
                                    O("values", "values", "Values", "", "list")], key=lambda o: o[0])


class TtkCombobox(TtkEntry):
    CLASS = "TCombobox"
    OPTS = TCOMBO_OPTS
    CMDS = TtkEntry.CMDS + ["current", "set"]
    A11Y_ROLE = "combobox"

    def __init__(self, app, path, parent, wclass=None):
        TtkEntry.__init__(self, app, path, parent, wclass)
        self.current_index = -1

    def values(self):
        return split_list(self.opts.get("values", ""))

    def w_current(self, args):
        vals = self.values()
        if not args:
            ci = self.current_index
            if ci < 0 or ci >= len(vals) or vals[ci] != self.string:
                ci = -1
                for i in range(len(vals)):
                    if vals[i] == self.string:
                        ci = i
                        break
            self.current_index = ci
            return ci
        a = tcl_str(args[0])
        if a == "end":
            k = len(vals) - 1
        else:
            try:
                k = get_int(args[0])
            except TclError:
                raise TclError("Incorrect index " + a)
        if k < 0 or k >= len(vals):
            raise TclError("index \"" + a + "\" out of range")
        self.current_index = k
        self.set_value(vals[k])
        self.value_changed()
        return ""

    def w_set(self, args):
        if len(args) != 1:
            raise TclError("wrong # args: should be \"" + self.path + " set value\"")
        self.set_value(tcl_str(args[0]))
        self.value_changed()
        return ""

    def on_destroy(self):
        pd = getattr(self, "popdown", None)
        if pd is not None:
            pd.unpost()
        E.TkEntry.on_destroy(self)


TSPIN_OPTS = sorted(TENTRY_OPTS + [O("command", "command", "Command", "", "command"),
                                   O("format", "format", "Format", "", "string"),
                                   O("from", "from", "From", 0.0, "double"),
                                   O("increment", "increment", "Increment", 1.0, "double"),
                                   O("to", "to", "To", 0.0, "double"),
                                   O("values", "values", "Values", "", "list"),
                                   O("wrap", "wrap", "Wrap", 0, "boolean")], key=lambda o: o[0])


class TtkSpinbox(TtkEntry):
    CLASS = "TSpinbox"
    OPTS = TSPIN_OPTS
    CMDS = TtkEntry.CMDS + ["set"]
    A11Y_ROLE = "spinbutton"

    def __init__(self, app, path, parent, wclass=None):
        TtkEntry.__init__(self, app, path, parent, wclass)
        self.vindex = -1
        self.vlast = None

    def w_set(self, args):
        if len(args) != 1:
            raise TclError("wrong # args: should be \"" + self.path + " set value\"")
        self.set_value(tcl_str(args[0]))
        self.value_changed()
        return ""

    def fmt(self, v):
        # ttk::spinbox::FormatValue
        f = self.opts.get("format") or ""
        if not f:
            d = abs(self.opts["increment"])
            if 0 < d < 1:
                nsd = int(math.ceil(-math.log10(d)))
                f = "%." + str(nsd) + "f"
            else:
                f = "%.0f"
        try:
            return f % v
        except (TypeError, ValueError):
            return str(v)

    def adjust(self, v, lo, hi):
        if v < lo:
            return hi if self.opts["wrap"] else lo
        if v > hi:
            return lo if self.opts["wrap"] else hi
        return v

    def spin(self, d):
        # ttk::spinbox::Spin
        if self.tstate & S_DISABLED:
            return
        vals = self.values()
        if vals:
            cur = self.vindex
            if self.string != self.vlast:
                cur = vals.index(self.string) if self.string in vals else -1
            self.vindex = self.adjust(cur + d, 0, len(vals) - 1)
            self.vlast = vals[self.vindex]
            self.set_value(self.vlast)
        else:
            try:
                v = float(self.string.split()[0]) + d * self.opts["increment"]
            except (ValueError, IndexError):
                v = self.opts["from"]
            self.set_value(self.fmt(self.adjust(v, self.opts["from"], self.opts["to"])))
        self.value_changed()
        self.set_selection(0, len(self.string))
        self.insert_pos = len(self.string)
        cmd = self.opts.get("command") or ""
        if cmd:
            self.app.eval_bg(cmd)

    def values(self):
        return split_list(self.opts.get("values", ""))


# the combobox's popdown list, drawn over the toplevel like a menu
class ComboboxPopdown(TkWin):
    CLASS = "ComboboxPopdown"
    IS_TOPLEVEL = True
    IS_MENU = True
    OPTS = W.FRAME_OPTS if hasattr(W, "FRAME_OPTS") else []
    A11Y_ROLE = "listbox"

    def __init__(self, app, path, parent, cb):
        TkWin.__init__(self, app, path, parent, "ComboboxPopdown")
        self.cb = cb
        self.host = None
        self.wm = C.WmInfo()

    def abs_xy(self):
        top = self.host
        return (self.x, self.y + (top.menubar_height() if top is not None else 0))

    def root_xy(self):
        top = self.host
        if top is None:
            return (self.x, self.y)
        return (top.x + self.x, top.y + top.menubar_height() + self.y)

    def damage(self):
        if self.host is not None and not self.host.destroyed:
            self.app.damage(self.host)

    def draw(self, h, ax, ay):
        fill(h, ax, ay, self.width, self.height, 0xffffff)
        draw_ring(h, ax, ay, self.width, self.height, 1, 0x000000)

    def listbox(self):
        return self.app.widgets.get(self.path + ".f.l")

    def post(self):
        cb = self.cb
        lb = self.listbox()
        vals = cb.values()
        lb.command(["delete", 0, "end"])
        if vals:
            lb.command(["insert", "end"] + vals)
        n = min(max(1, len(vals)), max(1, cb.opts.get("height", 10)))
        lb.command(["configure", "-height", n])
        lb.compute_geometry()
        top = cb.top
        self.host = top
        ax, ay = cb.abs_xy()
        mh = top.menubar_height()
        self.x = ax
        self.y = ay - mh + cb.height
        self.width = max(cb.width, 1)
        self.height = lb.reqh + 2
        if self.y + self.height > top.height and ay - mh - self.height >= 0:
            self.y = ay - mh - self.height
        f = self.app.widgets.get(self.path + ".f")
        for wdg, x, y, ww, hh in ((f, 1, 1, self.width - 2, self.height - 2), (lb, 0, 0, self.width - 2, self.height - 2)):
            wdg.x = x
            wdg.y = y
            wdg.width = ww
            wdg.height = hh
            wdg.mapped = True
            wdg.on_resize()
        ci = cb.w_current([])
        lb.command(["selection", "clear", 0, "end"])
        if ci >= 0:
            lb.command(["selection", "set", ci])
            lb.command(["activate", ci])
            lb.command(["see", ci])
        else:
            lb.command(["activate", 0])
        if self not in top.overlays:
            top.overlays.append(self)
        self.mapped = True
        cb.change_state(S_PRESSED, 0)
        self.app.damage(top)

    def unpost(self):
        top = self.host
        if top is not None and self in top.overlays:
            top.overlays.remove(self)
            self.app.damage(top)
        self.mapped = False
        self.host = None
        if not self.cb.destroyed:
            self.cb.change_state(0, S_PRESSED)

    def overlay_hit(self, x, y):
        lb = self.listbox()
        if lb is not None and 1 <= x < self.width - 1 and 1 <= y < self.height - 1:
            return lb
        return self

    def overlay_outside(self):
        self.unpost()
        return None

    def overlay_key(self, ks, down, state):
        if not down:
            return True
        lb = self.listbox()
        if ks == "Escape":
            self.unpost()
            return True
        if ks in ("Return", "KP_Enter", "Tab"):
            lb_selected(self.app, self)
            return True
        if ks in ("Down", "Up"):
            n = len(lb.items)
            k = lb.active + (1 if ks == "Down" else -1)
            k = max(0, min(n - 1, k))
            lb.command(["activate", k])
            lb.command(["selection", "clear", 0, "end"])
            lb.command(["selection", "set", k])
            lb.command(["see", k])
            self.damage()
            return True
        return True


def popdown_window(app, cb):
    # ttk::combobox::PopdownWindow: made once, $cb.popdown
    pd = getattr(cb, "popdown", None)
    if pd is not None and not pd.destroyed:
        return pd
    path = cb.path + ".popdown"
    pd = ComboboxPopdown(app, path, cb, cb)
    app.widgets[path] = pd
    cb.children.append(pd)
    app.interp.commands[path] = lambda it, words: pd.command(words[1:])
    pd.init_options()
    app.create_widget("frame", [path + ".f", "-borderwidth", 0])
    app.create_widget("listbox", [path + ".f.l", "-selectmode", "browse", "-activestyle", "none",
                                  "-exportselection", 0, "-borderwidth", 0, "-highlightthickness", 0,
                                  "-relief", "flat"])
    lb = app.widgets[path + ".f.l"]
    lb.bindtags = [lb.path, "ComboboxListbox", "Listbox", "all"]
    cb.popdown = pd
    return pd


def lb_selected(app, pd):
    # ttk::combobox::LBSelected / SelectEntry: the value, the whole text
    # selected, <<ComboboxSelected>>, unposted
    cb = pd.cb
    lb = pd.listbox()
    sel = sorted(lb.sel) if lb is not None else []
    pd.unpost()
    if sel:
        k = sel[0]
        cb.w_current([k])
        cb.set_selection(0, len(cb.string))
        cb.insert_pos = len(cb.string)
        app.event_generate([cb.path, "<<ComboboxSelected>>", "-when", "tail"])
    app.set_focus(cb)


def c_combo_post(app, args):
    cb = app.window(args[0])
    if cb.tstate & S_DISABLED:
        return ""
    pc = cb.opts.get("postcommand") or ""
    if pc:
        app.interp.eval(pc)
    pd = popdown_window(app, cb)
    pd.post()
    return ""


def c_combo_unpost(app, args):
    cb = app.window(args[0])
    pd = getattr(cb, "popdown", None)
    if pd is not None and pd.mapped:
        pd.unpost()
    return ""


def c_combo_press(app, args):
    # ttk::combobox::Press: on the arrow, or anywhere when readonly, the
    # list is toggled; elsewhere the entry takes the click
    mode = tcl_str(args[0])
    cb = app.window(args[1])
    x = get_int(args[2])
    y = get_int(args[3])
    el = cb.w_identify([x, y])
    if cb.tstate & S_DISABLED:
        return ""
    pd = getattr(cb, "popdown", None)
    if (el.endswith("arrow") or cb.tstate & S_READONLY) and mode in ("", "s"):
        if pd is not None and pd.mapped:
            pd.unpost()
        else:
            c_combo_post(app, [cb.path])
        app.set_focus(cb)
        return ""
    if mode == "":
        E.EntryButton1(app, [cb.path, x])
        cb.clear_selection()
    return ""


def c_combo_lbselected(app, args):
    lb = app.window(args[0])
    pd = lb.parent.parent
    if isinstance(pd, ComboboxPopdown):
        lb_selected(app, pd)
    return ""


def c_combo_window(app, args):
    cb = app.window(args[0])
    return popdown_window(app, cb).path


def c_spin(app, args):
    w = app.window(args[0])
    d = get_int(args[1])
    w.spin(d)
    return ""


def c_spin_press(app, args):
    w = app.window(args[0])
    x = get_int(args[1])
    y = get_int(args[2])
    el = w.w_identify([x, y])
    if w.tstate & S_DISABLED:
        return ""
    if el.endswith("uparrow"):
        w.spin(1)
        return ""
    if el.endswith("downarrow"):
        w.spin(-1)
        return ""
    E.EntryButton1(app, [w.path, x])
    w.clear_selection()
    return ""


# ── ttk::scrollbar ─────────────────────────────────────────────────────────
class TtkScrollbar(TtkWidget):
    CLASS = "TScrollbar"
    ORIENTED = True
    DEFAULT_ORIENT = "vertical"
    OPTS = [O("command", "command", "Command", "", "command"),
            O("orient", "orient", "Orient", "vertical", "enum:horizontal|vertical:orient")] + core_opts("")
    CMDS = TtkWidget.BASE_CMDS + ["delta", "fraction", "get", "set"]
    A11Y_ROLE = "scrollbar"

    def __init__(self, app, path, parent, wclass=None):
        TtkWidget.__init__(self, app, path, parent, wclass)
        self.first = 0.0
        self.last = 1.0
        self.trough = (0, 0, 0, 0)
        self.minsize = 0

    def vertical(self):
        return (self.opts.get("orient") or "vertical").startswith("v")

    def placements(self):
        pl = TtkWidget.placements(self)
        # ScrollbarDoLayout: the thumb within its parcel by first/last
        lay = self.get_layout()
        th = lay.find(pl, "thumb")
        if th is None:
            return pl
        nd = th.node
        tw, thh, pad = lay.node_size(nd, self.tstate)
        if getattr(th, "parcel", None) is None:
            th.parcel = th.box
        b = th.parcel
        self.trough = b
        if self.vertical():
            self.minsize = thh
            size = b[3] - self.minsize
            y = b[1] + int(size * self.first)
            hh = int(size * self.last) + self.minsize - int(size * self.first)
            th.box = (b[0], y, b[2], hh)
        else:
            self.minsize = tw
            size = b[2] - self.minsize
            x = b[0] + int(size * self.first)
            ww = int(size * self.last) + self.minsize - int(size * self.first)
            th.box = (x, b[1], ww, b[3])
        return pl

    def w_set(self, args):
        if len(args) != 2:
            raise TclError("wrong # args: should be \"" + self.path + " set first last\"")
        f = get_double(args[0])
        l = get_double(args[1])
        f = max(0.0, min(1.0, f))
        l = max(f, min(1.0, l))
        if (f, l) != (self.first, self.last):
            self.first = f
            self.last = l
            self.placed = None
            self.damage()
        return ""

    def w_get(self, args):
        return (self.first, self.last)

    def w_delta(self, args):
        dx = get_double(args[0])
        dy = get_double(args[1])
        self.placements()
        b = self.trough
        if self.vertical():
            sz = b[3] - self.minsize
            return dy / sz if sz > 0 else 0.0
        sz = b[2] - self.minsize
        return dx / sz if sz > 0 else 0.0

    def w_fraction(self, args):
        x = get_double(args[0])
        y = get_double(args[1])
        self.placements()
        b = self.trough
        if self.vertical():
            sz = b[3] - self.minsize
            f = (y - b[1] - self.minsize / 2.0) / sz if sz > 0 else 0.5
        else:
            sz = b[2] - self.minsize
            f = (x - b[0] - self.minsize / 2.0) / sz if sz > 0 else 0.5
        return max(0.0, min(1.0, f))


def _sb_scroll(app, w, n, what):
    cmd = w.opts.get("command") or ""
    if cmd:
        app.eval_bg(cmd + " scroll " + str(n) + " " + what)


def c_sb_press(app, args):
    # ttk::scrollbar::Press
    w = app.window(args[0])
    x = get_int(args[1])
    y = get_int(args[2])
    el = w.w_identify([x, y])
    p = W._priv(app)
    if el.endswith("uparrow") or el.endswith("leftarrow"):
        _sb_scroll(app, w, -1, "units")
    elif el.endswith("downarrow") or el.endswith("rightarrow"):
        _sb_scroll(app, w, 1, "units")
    elif el.endswith("thumb"):
        p["ttksb"] = (w, x, y, w.first)
        w.change_state(S_PRESSED, 0)
    elif el.endswith("trough"):
        f = w.w_fraction([x, y])
        _sb_scroll(app, w, -1 if f < w.first else 1, "pages")
    return ""


def c_sb_drag(app, args):
    w = app.window(args[0])
    p = W._priv(app)
    d = p.get("ttksb")
    if not d or d[0] is not w:
        return ""
    x = get_int(args[1])
    y = get_int(args[2])
    delta = w.w_delta([x - d[1], y - d[2]])
    cmd = w.opts.get("command") or ""
    if cmd:
        app.eval_bg(cmd + " moveto " + tcl_float(d[3] + delta))
    return ""


def c_sb_release(app, args):
    w = app.window(args[0])
    p = W._priv(app)
    p["ttksb"] = None
    w.change_state(0, S_PRESSED)
    return ""


# ── ttk::scale ─────────────────────────────────────────────────────────────
class TtkScale(TtkWidget):
    CLASS = "TScale"
    ORIENTED = True
    DEFAULT_ORIENT = "horizontal"
    OPTS = [O("command", "command", "Command", "", "command"),
            O("variable", "variable", "Variable", "", "var"),
            O("orient", "orient", "Orient", "horizontal", "enum:horizontal|vertical:orient"),
            O("from", "from", "From", 0.0, "double"),
            O("to", "to", "To", 1.0, "double"),
            O("value", "value", "Value", 0.0, "double"),
            O("length", "length", "Length", 100, "pixels"),
            O("state", "state", "State", "normal", "string"),
            O("takefocus", "takeFocus", "TakeFocus", "ttk::takefocus", "string"),
            O("cursor", "cursor", "Cursor", "", "cursor"), O("style", "style", "Style", "", "string"),
            O("class", "", "", "", "string")]
    CMDS = TtkWidget.BASE_CMDS + ["coords", "get", "set"]
    TAKES_FOCUS = True
    A11Y_ROLE = "slider"

    def record_opts(self):
        return {"orient": self.opts.get("orient")}

    def vertical(self):
        return (self.opts.get("orient") or "horizontal").startswith("v")

    def reconfigured(self, changed):
        if "variable" in changed:
            self.relink("variable", self._var_changed)
            name = self.opts.get("variable") or ""
            if name and name in self.app.vars:
                self._var_changed(name, "write")
        TtkWidget.reconfigured(self, changed)

    def _var_changed(self, name, op):
        if self.destroyed or op == "unset":
            return
        try:
            self.opts["value"] = get_double(self.app.vars.get(name, ""))
        except TclError:
            return
        self.placed = None
        self.damage()

    def adjust_size(self, w, h):
        ln = self.px("length")
        if self.vertical():
            return w, max(h, ln)
        return max(w, ln), h

    def fraction(self, v):
        lo = self.opts["from"]
        hi = self.opts["to"]
        if hi == lo:
            return 1.0
        f = (v - lo) / (hi - lo)
        return max(0.0, min(1.0, f))

    def trough_box(self, pl):
        lay = self.get_layout()
        tr = lay.find(pl, "trough")
        if tr is None:
            return (0, 0, self.width, self.height)
        pad = lay.internal_padding(tr.node, self.tstate)
        b = tr.box
        return (b[0] + pad[0], b[1] + pad[1], b[2] - pad[0] - pad[2], b[3] - pad[1] - pad[3])

    def trough_range(self, pl):
        b = list(self.trough_box(pl))
        sl = self.get_layout().find(pl, "slider")
        if sl is not None:
            if self.vertical():
                b[1] += sl.box[3] // 2
                b[3] -= sl.box[3]
            else:
                b[0] += sl.box[2] // 2
                b[2] -= sl.box[2]
        return b

    def placements(self):
        pl = TtkWidget.placements(self)
        sl = self.get_layout().find(pl, "slider")
        if sl is not None:
            if getattr(sl, "parcel", None) is None:
                sl.parcel = sl.box
            tb = self.trough_box(pl)
            f = self.fraction(self.opts["value"])
            b = sl.parcel
            if self.vertical():
                sl.box = (b[0], b[1] + int(f * (tb[3] - b[3])), b[2], b[3])
            else:
                sl.box = (b[0] + int(f * (tb[2] - b[2])), b[1], b[2], b[3])
        return pl

    def draw(self, h, ax, ay):
        self.placed = None
        TtkWidget.draw(self, h, ax, ay)

    def w_get(self, args):
        if not args:
            return self.opts["value"]
        x = get_int(args[0])
        y = get_int(args[1])
        tb = self.trough_range(self.placements())
        if self.vertical():
            f = (y - tb[1]) / float(tb[3]) if tb[3] else 0.0
        else:
            f = (x - tb[0]) / float(tb[2]) if tb[2] else 0.0
        f = max(0.0, min(1.0, f))
        return self.opts["from"] + f * (self.opts["to"] - self.opts["from"])

    def w_coords(self, args):
        v = get_double(args[0]) if args else self.opts["value"]
        tb = self.trough_range(self.placements())
        f = self.fraction(v)
        if self.vertical():
            return (tb[0] + tb[2] // 2, tb[1] + int(f * tb[3]))
        return (tb[0] + int(f * tb[2]), tb[1] + tb[3] // 2)

    def w_set(self, args):
        if len(args) != 1:
            raise TclError("wrong # args: should be \"" + self.path + " set value\"")
        v = get_double(args[0])
        if self.tstate & S_DISABLED:
            return ""
        lo = min(self.opts["from"], self.opts["to"])
        hi = max(self.opts["from"], self.opts["to"])
        v = max(lo, min(hi, v))
        self.opts["value"] = v
        self.placed = None
        self.damage()
        name = self.opts.get("variable") or ""
        if name:
            self.app.interp.setvar(name, v)
        cmd = self.opts.get("command") or ""
        if cmd:
            return self.app.interp.eval(cmd + " " + tcl_float(v))
        return ""

    def a11y_value(self):
        return tcl_float(self.opts["value"])


def c_scale_press(app, args):
    # ttk::scale::Press
    w = app.window(args[0])
    x = get_int(args[1])
    y = get_int(args[2])
    p = W._priv(app)
    el = w.w_identify([x, y])
    p["ttkscale"] = None
    if w.tstate & S_DISABLED:
        return ""
    if el.endswith("slider"):
        p["ttkscale"] = (w, w.opts["value"])
        w.change_state(S_PRESSED, 0)
    elif el.endswith("trough") or el.endswith("track"):
        cur = w.opts["value"]
        at = w.w_get([x, y])
        inc = -1 if ((at <= cur) != (w.opts["from"] > w.opts["to"])) else 1
        scale_increment(w, inc)
    return ""


def scale_increment(w, d):
    if w.opts["from"] > w.opts["to"]:
        d = -d
    w.w_set([w.opts["value"] + d])


def c_scale_drag(app, args):
    w = app.window(args[0])
    p = W._priv(app)
    d = p.get("ttkscale")
    if d and d[0] is w:
        w.w_set([w.w_get([get_int(args[1]), get_int(args[2])])])
    return ""


def c_scale_release(app, args):
    w = app.window(args[0])
    W._priv(app)["ttkscale"] = None
    w.change_state(0, S_PRESSED)
    return ""


def c_scale_jump(app, args):
    w = app.window(args[0])
    w.w_set([w.w_get([get_int(args[1]), get_int(args[2])])])
    W._priv(app)["ttkscale"] = (w, w.opts["value"])
    return ""


def c_scale_incr(app, args):
    scale_increment(app.window(args[0]), get_double(args[1]))
    return ""


def c_scale_setto(app, args):
    w = app.window(args[0])
    w.w_set([w.opts["from"] if tcl_str(args[1]) == "from" else w.opts["to"]])
    return ""


# ── ttk::progressbar ──────────────────────────────────────────────────────
class TtkProgressbar(TtkWidget):
    CLASS = "TProgressbar"
    ORIENTED = True
    DEFAULT_ORIENT = "horizontal"
    OPTS = [O("orient", "orient", "Orient", "horizontal", "enum:horizontal|vertical:orient"),
            O("length", "length", "Length", 100, "pixels"),
            O("mode", "mode", "ProgressMode", "determinate", "enum:determinate|indeterminate:mode"),
            O("maximum", "maximum", "Maximum", 100.0, "double"),
            O("variable", "variable", "Variable", "", "var"),
            O("value", "value", "Value", 0.0, "double"),
            O("phase", "phase", "Phase", 0, "int")] + core_opts("")
    CMDS = TtkWidget.BASE_CMDS + ["start", "step", "stop"]
    A11Y_ROLE = "progressbar"

    def __init__(self, app, path, parent, wclass=None):
        TtkWidget.__init__(self, app, path, parent, wclass)
        self.timer = None

    def record_opts(self):
        return {"orient": self.opts.get("orient")}

    def vertical(self):
        return (self.opts.get("orient") or "horizontal").startswith("v")

    def reconfigured(self, changed):
        if "variable" in changed:
            self.relink("variable", self._var_changed)
            name = self.opts.get("variable") or ""
            if name and name in self.app.vars:
                self._var_changed(name, "write")
        TtkWidget.reconfigured(self, changed)

    def _var_changed(self, name, op):
        if self.destroyed or op == "unset":
            return
        try:
            self.opts["value"] = get_double(self.app.vars.get(name, ""))
        except TclError:
            self.opts["value"] = 0.0
        self.placed = None
        self.damage()

    def adjust_size(self, w, h):
        # ProgressbarSize: -length overrides the long side
        ln = self.px("length")
        if self.vertical():
            return w, ln
        return ln, h

    def placements(self):
        pl = TtkWidget.placements(self)
        lay = self.get_layout()
        pb = lay.find(pl, "pbar")
        tr = lay.find(pl, "trough")
        if pb is None or tr is None:
            return pl
        pad = lay.internal_padding(tr.node, self.tstate)
        t = tr.box
        tb = (t[0] + pad[0], t[1] + pad[1], t[2] - pad[0] - pad[2], t[3] - pad[1] - pad[3])
        mx = self.opts["maximum"]
        v = self.opts["value"]
        b = pb.box
        if self.opts["mode"] == "determinate":
            f = max(0.0, min(1.0, v / mx)) if mx > 0 else 0.0
            if self.vertical():
                hh = int(f * tb[3])
                pb.box = (b[0], tb[1] + tb[3] - hh, b[2], hh)
            else:
                pb.box = (tb[0], b[1], int(f * tb[2]), b[3])
        else:
            # indeterminate: a block bouncing along the trough
            f = (v % mx) / mx if mx > 0 else 0.0
            if f > 0.5:
                f = 1.0 - f
            f *= 2
            if self.vertical():
                bs = b[3]
                pb.box = (b[0], tb[1] + int(f * (tb[3] - bs)), b[2], bs)
            else:
                bs = b[2]
                pb.box = (tb[0] + int(f * (tb[2] - bs)), b[1], bs, b[3])
        return pl

    def draw(self, h, ax, ay):
        self.placed = None
        TtkWidget.draw(self, h, ax, ay)

    def set_value(self, v):
        name = self.opts.get("variable") or ""
        if name:
            self.app.interp.setvar(name, v)
        else:
            self.opts["value"] = v
        self.placed = None
        self.damage()

    def w_step(self, args):
        amount = get_double(args[0]) if args else 1.0
        self.set_value(self.opts["value"] + amount)
        return ""

    def w_start(self, args):
        iv = get_int(args[0]) if args else 50
        self.w_stop([])
        self._tick(iv)
        return ""

    def _tick(self, iv):
        if self.destroyed:
            return
        name = "::ttk::progressbar::_tick" + str(id(self))
        me = self

        def again():
            me.w_step([])
            me._tick(iv)
            return ""
        self.app.interp.commands[name] = lambda it, words: again()
        self.timer = self.app.c_after([iv, name])

    def w_stop(self, args):
        if self.timer is not None:
            self.app.c_after(["cancel", self.timer])
            self.timer = None
        return ""

    def on_destroy(self):
        self.w_stop([])

    def a11y_value(self):
        return tcl_float(self.opts["value"])


# ── ttk::notebook ─────────────────────────────────────────────────────────
_TAB_OPTS = ["-padding", "-sticky", "-state", "-text", "-image", "-compound", "-underline"]


class Tab:
    def __init__(self, win):
        self.win = win
        self.opts = {"padding": "0", "sticky": "nsew", "state": "normal", "text": "", "image": "",
                     "compound": "none", "underline": -1}
        self.box = (0, 0, 0, 0)


class TtkNotebook(TtkWidget):
    CLASS = "TNotebook"
    OPTS = [O("width", "width", "Width", 0, "pixels"), O("height", "height", "Height", 0, "pixels"),
            O("padding", "padding", "Padding", None, "ttk_padding"),
            O("takefocus", "takeFocus", "TakeFocus", "ttk::takefocus", "string"),
            O("cursor", "cursor", "Cursor", "", "cursor"), O("style", "style", "Style", "", "string"),
            O("class", "", "", "", "string")]
    CMDS = TtkWidget.BASE_CMDS + ["add", "forget", "hide", "index", "insert", "select", "tab", "tabs"]
    TAKES_FOCUS = True
    A11Y_ROLE = "tablist"

    def __init__(self, app, path, parent, wclass=None):
        TtkWidget.__init__(self, app, path, parent, wclass)
        self.tabs = []
        self.current = -1
        self.active_tab = -1
        self.tab_layout = None
        self.tab_key = None

    def get_tab_layout(self):
        e = engine(self.app)
        st = self.opts.get("style") or ""
        name = (st if st else "TNotebook") + ".Tab"
        key = (e.epoch, name)
        if self.tab_layout is None or self.tab_key != key:
            self.tab_rec = {}
            self.tab_layout = make_layout(self.app, name, lambda: self.tab_rec, self)
            self.tab_key = key
        return self.tab_layout

    def tab_state(self, i):
        st = self.tstate & ~(S_SELECTED | S_ACTIVE | S_DISABLED)
        t = self.tabs[i]
        if i == self.current:
            st |= S_SELECTED
        if i == self.active_tab:
            st |= S_ACTIVE
        if t.opts["state"] == "disabled" or self.tstate & S_DISABLED:
            st |= S_DISABLED
        return st

    def tab_size(self, i):
        lay = self.get_tab_layout()
        t = self.tabs[i]
        self.tab_rec = {"text": t.opts["text"], "image": t.opts["image"] or None,
                        "compound": t.opts["compound"], "underline": t.opts["underline"]}
        lay.record_fn = lambda r=self.tab_rec: r
        lay.invalidate()
        return lay.size(self.tab_state(i))

    def nbstyle(self, opt, default):
        st = self.get_layout().style
        v = style_query(st, "-" + opt, self.tstate)
        return v if v is not None else default

    def visible_tabs(self):
        return [i for i in range(len(self.tabs)) if self.tabs[i].opts["state"] != "hidden"]

    def tabrow(self):
        # TabrowSize and the tab boxes along the top (-tabposition n*)
        mintw = T._px(self.nbstyle("mintabwidth", "24"), 24)
        margins = parse_padding(self.nbstyle("tabmargins", "0"))
        x = margins[0]
        hmax = 0
        sizes = []
        for i in self.visible_tabs():
            w, h = self.tab_size(i)
            w = max(w, mintw)
            sizes.append((i, w, h))
            hmax = max(hmax, h)
        for i, w, h in sizes:
            self.tabs[i].box = (x, margins[1], w, hmax)
            x += w
        return x + margins[2] - margins[0] + margins[0], hmax + margins[1] + margins[3]

    def client_padding(self):
        lay = self.get_layout()
        nd = lay.find_node("client")
        p = parse_padding(self.opts.get("padding")) if self.opts.get("padding") is not None else parse_padding(
            self.nbstyle("padding", "0"))
        if nd is not None:
            p = pad_add(p, lay.internal_padding(nd, self.tstate))
        return p

    def compute_geometry(self):
        cw = 0
        ch = 0
        for t in self.tabs:
            tp = parse_padding(t.opts["padding"])
            cw = max(cw, t.win.reqw + tp[0] + tp[2])
            ch = max(ch, t.win.reqh + tp[1] + tp[3])
        if self.px("width") > 0:
            cw = self.px("width")
        if self.px("height") > 0:
            ch = self.px("height")
        tw, th = self.tabrow()
        p = self.client_padding()
        self.request(max(tw, cw) + p[0] + p[2], th + ch + p[1] + p[3])

    def request_from_slaves(self):
        self.compute_geometry()

    def client_box(self):
        tw, th = self.tabrow()
        p = self.client_padding()
        return (p[0], th + p[1], self.width - p[0] - p[2], self.height - th - p[1] - p[3])

    def arrange_slaves(self):
        if not self.mapped:
            return
        cb = self.client_box()
        for i in range(len(self.tabs)):
            t = self.tabs[i]
            w = t.win
            if i != self.current or t.opts["state"] == "hidden":
                if w.mapped:
                    self.app.set_mapped(w, False)
                continue
            tp = parse_padding(t.opts["padding"])
            px, py, pw, ph = cb[0] + tp[0], cb[1] + tp[1], cb[2] - tp[0] - tp[2], cb[3] - tp[1] - tp[3]
            x, y, ww, hh = stick_box(px, py, pw, ph, w.reqw, w.reqh, parse_sticky(t.opts["sticky"]))
            self.app.place_slave(self, w, x, y, ww, hh)

    def forget_slave(self, w):
        for i in range(len(self.tabs)):
            if self.tabs[i].win is w:
                self.remove_tab(i)
                return

    def remove_tab(self, i):
        was = self.current
        del self.tabs[i]
        if was == i:
            self.current = -1
            nxt = None
            for j in list(range(i, len(self.tabs))) + list(range(i - 1, -1, -1)):
                if self.tabs[j].opts["state"] == "normal":
                    nxt = j
                    break
            if nxt is not None:
                self.select_tab(nxt)
        elif was > i:
            self.current = was - 1
        self.compute_geometry()
        self.app.relayout()
        self.damage()

    def tab_index(self, spec, end_ok=False):
        # GetTabIndex: integer, window, current, end, @x,y
        if isinstance(spec, int) and not isinstance(spec, bool):
            if 0 <= spec < len(self.tabs) or (end_ok and spec == len(self.tabs)):
                return spec
            raise TclError("Slave index " + str(spec) + " out of bounds")
        s = tcl_str(spec)
        for i in range(len(self.tabs)):
            if self.tabs[i].win.path == s:
                return i
        if s == "current":
            return self.current
        if s == "end" and end_ok:
            return len(self.tabs)
        if s.startswith("@"):
            try:
                xs, ys = s[1:].split(",")
                x = int(xs)
                y = int(ys)
            except ValueError:
                raise TclError("bad position \"" + s + "\"")
            self.tabrow()
            for i in self.visible_tabs():
                b = self.tabs[i].box
                if b[0] <= x < b[0] + b[2] and b[1] <= y < b[1] + b[3]:
                    return i
            return -1
        try:
            k = int(s)
        except ValueError:
            raise TclError("Invalid slave specification " + s)
        if 0 <= k < len(self.tabs) or (end_ok and k == len(self.tabs)):
            return k
        raise TclError("Slave index " + s + " out of bounds")

    def configure_tab(self, t, args):
        if len(args) % 2 != 0:
            raise TclError("value for \"" + tcl_str(args[-1]) + "\" missing")
        for i in range(0, len(args), 2):
            k = match_prefix(tcl_str(args[i]), _TAB_OPTS, "option")[1:]
            v = args[i + 1]
            if k == "padding":
                parse_padding(v)
                v = join_list(v) if isinstance(v, (tuple, list)) else tcl_str(v)
            elif k == "sticky":
                v = parse_sticky(v)
            elif k == "state":
                v = match_prefix(tcl_str(v), ["normal", "disabled", "hidden"], "state")
            elif k == "underline":
                v = get_int(v)
            elif k == "compound":
                v = match_prefix(tcl_str(v), ["none", "text", "image", "center", "top", "bottom", "left", "right"], "compound")
            elif k == "image":
                v = tcl_str(v)
                if v and _words(v)[0] not in self.app.images:
                    raise TclError("image \"" + v + "\" doesn't exist")
            else:
                v = tcl_str(v)
            t.opts[k] = v

    def w_add(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " add window ?-option value ...?\"")
        w = self.app.window(args[0])
        for i in range(len(self.tabs)):
            if self.tabs[i].win is w:
                t = self.tabs[i]
                if t.opts["state"] == "hidden":
                    t.opts["state"] = "normal"
                self.configure_tab(t, args[1:])
                self.compute_geometry()
                self.damage()
                return ""
        return self.w_insert(["end"] + list(args))

    def w_insert(self, args):
        if len(args) < 2:
            raise TclError("wrong # args: should be \"" + self.path + " insert index window ?-option value ...?\"")
        w = self.app.window(args[1])
        if w.parent is not self:
            raise TclError("can't add " + w.path + " as slave of " + self.path)
        pos = self.tab_index(args[0], True)
        for i in range(len(self.tabs)):
            if self.tabs[i].win is w:
                t = self.tabs.pop(i)
                if pos > i:
                    pos -= 1
                cur = self.tabs[self.current] if 0 <= self.current < len(self.tabs) + 1 and self.current != i else None
                self.tabs.insert(min(pos, len(self.tabs)), t)
                self.configure_tab(t, args[2:])
                if self.current == i:
                    self.current = self.tabs.index(t)
                self.app.relayout()
                self.damage()
                return ""
        t = Tab(w)
        self.configure_tab(t, args[2:])
        if w.manager != "":
            G.unmanage(self.app, w)
        w.manager = "notebook"
        w.gmaster = self
        if pos > len(self.tabs):
            pos = len(self.tabs)
        self.tabs.insert(pos, t)
        if self.current >= pos:
            self.current += 1
        if self.current < 0 and t.opts["state"] == "normal":
            self.select_tab(self.tabs.index(t))
        self.compute_geometry()
        self.app.relayout()
        self.damage()
        return ""

    def select_tab(self, i):
        if i == self.current:
            return
        if self.tabs[i].opts["state"] != "normal":
            return
        old = self.current
        self.current = i
        if 0 <= old < len(self.tabs):
            w = self.tabs[old].win
            if w.mapped:
                self.app.set_mapped(w, False)
        self.app.relayout()
        self.damage()
        self.app.event_generate([self.path, "<<NotebookTabChanged>>", "-when", "tail"])

    def w_select(self, args):
        if not args:
            if 0 <= self.current < len(self.tabs):
                return self.tabs[self.current].win.path
            return ""
        i = self.tab_index(args[0])
        if i < 0:
            return ""
        self.select_tab(i)
        return ""

    def w_forget(self, args):
        i = self.tab_index(args[0])
        if i < 0:
            return ""
        w = self.tabs[i].win
        self.remove_tab(i)
        w.manager = ""
        w.gmaster = None
        self.app.set_mapped(w, False)
        return ""

    def w_hide(self, args):
        i = self.tab_index(args[0])
        if i < 0:
            return ""
        self.tabs[i].opts["state"] = "hidden"
        if i == self.current:
            self.current = -1
            w = self.tabs[i].win
            self.app.set_mapped(w, False)
            for j in list(range(i + 1, len(self.tabs))) + list(range(i - 1, -1, -1)):
                if self.tabs[j].opts["state"] == "normal":
                    self.select_tab(j)
                    break
        self.compute_geometry()
        self.app.relayout()
        self.damage()
        return ""

    def w_index(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " index tab\"")
        s = tcl_str(args[0])
        if s == "end":
            return len(self.tabs)
        i = self.tab_index(args[0])
        return i if i >= 0 else ""

    def w_tab(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " tab tab ?-option ?value??...\"")
        i = self.tab_index(args[0])
        if i < 0:
            raise TclError("Invalid slave specification " + tcl_str(args[0]))
        t = self.tabs[i]
        rest = args[1:]
        if not rest:
            out = []
            for o in _TAB_OPTS:
                out.extend([o, t.opts[o[1:]]])
            return tuple(out)
        if len(rest) == 1:
            o = match_prefix(tcl_str(rest[0]), _TAB_OPTS, "option")
            return t.opts[o[1:]]
        old = t.opts["state"]
        self.configure_tab(t, rest)
        if t.opts["state"] != "normal" and i == self.current and t.opts["state"] == "hidden":
            self.w_hide([i])
        self.compute_geometry()
        self.app.relayout()
        self.damage()
        return ""

    def w_tabs(self, args):
        return tuple(t.win.path for t in self.tabs)

    def w_identify(self, args):
        # identify ?element|tab? x y
        what = "element"
        if len(args) == 3:
            what = match_prefix(tcl_str(args[0]), ["element", "tab"], "option")
            args = args[1:]
        x = get_int(args[0])
        y = get_int(args[1])
        self.tabrow()
        for i in self.visible_tabs():
            b = self.tabs[i].box
            if b[0] <= x < b[0] + b[2] and b[1] <= y < b[1] + b[3]:
                if what == "tab":
                    return i
                lay = self.get_tab_layout()
                self.tab_size(i)
                pl = lay.place(b, self.tab_state(i))
                p = lay.identify(pl, x, y)
                return p.elem.NAME if p is not None and p.elem.NAME else (p.node.name if p else "")
        if what == "tab":
            return ""
        return TtkWidget.w_identify(self, [x, y])

    def placements(self):
        lay = self.get_layout()
        tw, th = self.tabrow()
        lay.invalidate()
        return lay.place((0, th, self.width, self.height - th), self.tstate)

    def draw(self, h, ax, ay):
        lay = self.get_layout()
        pl = self.placements()
        lay.draw(h, ax, ay, pl, self.tstate)
        self.tabrow()
        tl = self.get_tab_layout()
        for i in self.visible_tabs():
            t = self.tabs[i]
            b = t.box
            st = self.tab_state(i)
            self.tab_size(i)
            box = b
            if i == self.current:
                ex = parse_padding(style_query(tl.style, "-expand", st) or "0")
                box = (b[0] - ex[0], b[1] - ex[1], b[2] + ex[0] + ex[2], b[3] + ex[1] + ex[3])
            tpl = tl.place(box, st)
            tl.draw(h, ax, ay, tpl, st)

    def on_destroy(self):
        for t in list(self.tabs):
            t.win.manager = ""
            t.win.gmaster = None

    def a11y_states(self):
        return TtkWidget.a11y_states(self)


def c_nb_press(app, args):
    # ttk::notebook::Press: the tab under the pointer is selected and
    # takes the focus
    w = app.window(args[0])
    x = get_int(args[1])
    y = get_int(args[2])
    i = w.tab_index("@" + str(x) + "," + str(y))
    if i is None or i < 0:
        return ""
    if w.tabs[i].opts["state"] != "normal" or w.tstate & S_DISABLED:
        return ""
    w.select_tab(i)
    tf = w.opts.get("takefocus") or ""
    if tf != "0":
        app.set_focus(w)
    return ""


def c_nb_cycle(app, args):
    # ttk::notebook::CycleTab
    w = app.window(args[0])
    d = get_int(args[1])
    n = len(w.tabs)
    if n == 0:
        return ""
    cur = w.current
    for k in range(1, n + 1):
        j = (cur + d * k) % n
        if w.tabs[j].opts["state"] == "normal":
            w.select_tab(j)
            break
    return ""


def c_nb_traversal(app, args):
    # ttk::notebook::enableTraversal: Control-Tab on the toplevel
    w = app.window(args[0])
    top = w.top.path
    b = app.bindings
    b.set(top, "<Control-Key-Tab>", "ttk::notebook::CycleTab " + w.path + " 1; break")
    b.set(top, "<Control-Shift-Key-Tab>", "ttk::notebook::CycleTab " + w.path + " -1; break")
    w.traversal = True
    return ""


# ── ttk::panedwindow ──────────────────────────────────────────────────────
class Pane:
    def __init__(self, win):
        self.win = win
        self.weight = 0
        self.req = 0
        self.size = 0


class TtkPanedwindow(TtkWidget):
    CLASS = "TPanedwindow"
    OPTS = [O("orient", "orient", "Orient", "vertical", "enum:horizontal|vertical:orient"),
            O("width", "width", "Width", 0, "pixels"), O("height", "height", "Height", 0, "pixels")] + core_opts("")
    CMDS = TtkWidget.BASE_CMDS + ["add", "forget", "insert", "pane", "panes", "sashpos"]
    A11Y_ROLE = "group"

    def __init__(self, app, path, parent, wclass=None):
        TtkWidget.__init__(self, app, path, parent, wclass)
        self.panes = []
        self.sashes = []
        self.last_size = None

    def horizontal(self):
        return (self.opts.get("orient") or "vertical").startswith("h")

    def sash_thickness(self):
        e = engine(self.app)
        st = e.current.get_style(("Horizontal" if self.horizontal() else "Vertical") + ".Sash")
        v = style_query(st, "-sashthickness", 0)
        return T._px(v, 5)

    def compute_geometry(self):
        st = self.sash_thickness()
        total = 0
        other = 0
        for p in self.panes:
            if self.horizontal():
                total += p.win.reqw
                other = max(other, p.win.reqh)
            else:
                total += p.win.reqh
                other = max(other, p.win.reqw)
        total += st * max(0, len(self.panes) - 1)
        w, h = (total, other) if self.horizontal() else (other, total)
        if self.px("width") > 0:
            w = self.px("width")
        if self.px("height") > 0:
            h = self.px("height")
        self.request(w, h)

    def request_from_slaves(self):
        self.compute_geometry()

    def place_sashes(self):
        # ttkPanedwindow.c PlaceSashes: the panes get their requests, the
        # difference is shared out by -weight
        st = self.sash_thickness()
        avail = (self.width if self.horizontal() else self.height) - st * max(0, len(self.panes) - 1)
        if not self.panes:
            self.sashes = []
            return
        if self.last_size is None or len(self.sashes) != len(self.panes) - 1:
            for p in self.panes:
                p.size = p.win.reqw if self.horizontal() else p.win.reqh
        cur = sum(p.size for p in self.panes)
        diff = avail - cur
        tw = sum(p.weight for p in self.panes)
        if diff != 0 and tw > 0:
            share = diff // tw
            rem = diff - share * tw
            for p in self.panes:
                p.size += share * p.weight
            for p in reversed(self.panes):
                if p.weight > 0:
                    p.size += rem
                    break
        elif diff != 0 and self.panes:
            self.panes[-1].size += diff
        for p in self.panes:
            if p.size < 0:
                p.size = 0
        pos = 0
        self.sashes = []
        for p in self.panes[:-1]:
            pos += p.size
            self.sashes.append(pos)
            pos += st
        self.last_size = (self.width, self.height)

    def arrange_slaves(self):
        if not self.mapped:
            return
        self.place_sashes()
        st = self.sash_thickness()
        pos = 0
        for i, p in enumerate(self.panes):
            if self.horizontal():
                self.app.place_slave(self, p.win, pos, 0, p.size, self.height)
            else:
                self.app.place_slave(self, p.win, 0, pos, self.width, p.size)
            pos += p.size + st

    def forget_slave(self, w):
        for i in range(len(self.panes)):
            if self.panes[i].win is w:
                del self.panes[i]
                self.last_size = None
                self.compute_geometry()
                return

    def pane_index(self, spec):
        if isinstance(spec, int) and not isinstance(spec, bool):
            if 0 <= spec < len(self.panes):
                return spec
            raise TclError("Slave index " + str(spec) + " out of bounds")
        s = tcl_str(spec)
        for i in range(len(self.panes)):
            if self.panes[i].win.path == s:
                return i
        try:
            k = int(s)
        except ValueError:
            raise TclError("Invalid slave specification " + s)
        if 0 <= k < len(self.panes):
            return k
        raise TclError("Slave index " + s + " out of bounds")

    def configure_pane(self, p, args):
        if len(args) % 2 != 0:
            raise TclError("value for \"" + tcl_str(args[-1]) + "\" missing")
        for i in range(0, len(args), 2):
            match_prefix(tcl_str(args[i]), ["-weight"], "option")
            w = get_int(args[i + 1])
            if w < 0:
                raise TclError("-weight must be nonnegative")
            p.weight = w

    def w_add(self, args):
        return self.w_insert(["end"] + list(args))

    def w_insert(self, args):
        w = self.app.window(args[1])
        pos = len(self.panes) if tcl_str(args[0]) == "end" else None
        for i in range(len(self.panes)):
            if self.panes[i].win is w:
                p = self.panes.pop(i)
                k = len(self.panes) if pos is not None else min(self.pane_index_or_end(args[0]), len(self.panes))
                self.panes.insert(k, p)
                self.configure_pane(p, args[2:])
                self.last_size = None
                self.app.relayout()
                return ""
        if pos is None:
            pos = self.pane_index_or_end(args[0])
        p = Pane(w)
        self.configure_pane(p, args[2:])
        if w.manager != "":
            G.unmanage(self.app, w)
        w.manager = "panedwindow"
        w.gmaster = self
        self.panes.insert(pos, p)
        self.last_size = None
        self.compute_geometry()
        self.app.relayout()
        return ""

    def pane_index_or_end(self, spec):
        if tcl_str(spec) == "end":
            return len(self.panes)
        try:
            k = get_int(spec)
            return max(0, min(len(self.panes), k))
        except TclError:
            return self.pane_index(spec)

    def w_forget(self, args):
        i = self.pane_index(args[0])
        w = self.panes[i].win
        G.unmanage(self.app, w)
        return ""

    def w_pane(self, args):
        i = self.pane_index(args[0])
        p = self.panes[i]
        if len(args) == 1:
            return ("-weight", p.weight)
        if len(args) == 2:
            match_prefix(tcl_str(args[1]), ["-weight"], "option")
            return p.weight
        self.configure_pane(p, args[1:])
        self.app.relayout()
        return ""

    def w_panes(self, args):
        return tuple(p.win.path for p in self.panes)

    def w_sashpos(self, args):
        k = get_int(args[0])
        if k < 0 or k >= len(self.sashes):
            if len(self.panes) <= 1 or k < 0 or k >= len(self.panes) - 1:
                raise TclError("sash index " + str(k) + " out of range")
            self.place_sashes()
        if len(args) > 1:
            st = self.sash_thickness()
            total = self.width if self.horizontal() else self.height
            newpos = get_int(args[1])
            lo = self.sashes[k - 1] + st if k > 0 else 0
            hi = (self.sashes[k + 1] - st) if k + 1 < len(self.sashes) else total - st
            newpos = max(lo, min(hi, newpos))
            delta = newpos - self.sashes[k]
            self.panes[k].size += delta
            self.panes[k + 1].size -= delta
            self.sashes[k] = newpos
            self.app.relayout()
            self.damage()
        return self.sashes[k]

    def draw(self, h, ax, ay):
        TtkWidget.draw(self, h, ax, ay)
        st = self.sash_thickness()
        c = 0xd9d9d9
        for s in self.sashes:
            if self.horizontal():
                fill(h, ax + s, ay, st, self.height, c)
            else:
                fill(h, ax, ay + s, self.width, st, c)

    def w_identify(self, args):
        what = "element"
        if len(args) == 3:
            what = match_prefix(tcl_str(args[0]), ["element", "sash"], "option")
            args = args[1:]
        x = get_int(args[0])
        y = get_int(args[1])
        st = self.sash_thickness()
        v = x if self.horizontal() else y
        for k, s in enumerate(self.sashes):
            if s <= v < s + st:
                return k if what == "sash" else ("hsash" if self.horizontal() else "vsash")
        return ""


def c_pw_press(app, args):
    w = app.window(args[0])
    x = get_int(args[1])
    y = get_int(args[2])
    k = w.w_identify(["sash", x, y])
    W._priv(app)["ttkpw"] = (w, k) if k != "" else None
    return ""


def c_pw_drag(app, args):
    w = app.window(args[0])
    d = W._priv(app).get("ttkpw")
    if d and d[0] is w:
        x = get_int(args[1])
        y = get_int(args[2])
        w.w_sashpos([d[1], x if w.horizontal() else y])
    return ""


def c_pw_release(app, args):
    W._priv(app)["ttkpw"] = None
    return ""


# ── ttk::treeview ─────────────────────────────────────────────────────────
class TItem:
    def __init__(self, iid, parent):
        self.iid = iid
        self.parent = parent
        self.children = []
        self.opts = {"text": "", "image": "", "values": "", "open": 0, "tags": ""}
        self.detached = False
        self.selected = False


_ITEM_OPTS = ["-text", "-image", "-values", "-open", "-tags"]
_COL_OPTS = ["-width", "-minwidth", "-stretch", "-anchor", "-id"]
_HEAD_OPTS = ["-text", "-image", "-anchor", "-command"]
_TAG_OPTS = ["-foreground", "-background", "-font", "-image"]


class TColumn:
    def __init__(self, cid):
        self.opts = {"width": 200, "minwidth": 20, "stretch": 1, "anchor": "w", "id": cid}
        self.head = {"text": "", "image": "", "anchor": "center", "command": ""}
        self.x = 0


class TtkTreeview(TtkWidget):
    CLASS = "Treeview"
    OPTS = [O("columns", "columns", "Columns", "", "list"),
            O("displaycolumns", "displayColumns", "DisplayColumns", "#all", "list"),
            O("show", "show", "Show", "tree headings", "list"),
            O("selectmode", "selectMode", "SelectMode", "extended", "enum:extended|browse|none:selectmode"),
            O("height", "height", "Height", 10, "int"),
            O("padding", "padding", "Pad", None, "ttk_padding"),
            O("xscrollcommand", "xScrollCommand", "ScrollCommand", "", "command"),
            O("yscrollcommand", "yScrollCommand", "ScrollCommand", "", "command"),
            O("takefocus", "takeFocus", "TakeFocus", "ttk::takefocus", "string"),
            O("cursor", "cursor", "Cursor", "", "cursor"), O("style", "style", "Style", "", "string"),
            O("class", "", "", "", "string")]
    CMDS = TtkWidget.BASE_CMDS + ["bbox", "children", "column", "delete", "detach", "exists", "focus", "heading",
                                  "index", "insert", "item", "move", "next", "parent", "prev", "see", "selection",
                                  "set", "tag", "xview", "yview"]
    TAKES_FOCUS = True
    A11Y_ROLE = "tree"

    def __init__(self, app, path, parent, wclass=None):
        TtkWidget.__init__(self, app, path, parent, wclass)
        self.items = {"": TItem("", None)}
        self.items[""].opts["open"] = 1
        self.serial = 0
        self.columns = {}
        self.tree_col = TColumn("#0")
        self.focus_item = ""
        self.tags = {}
        self.tag_bindings = B.BindingTable()
        self.yoff = 0
        self.xoff = 0
        self.sub = {}
        self.rowheight = 20
        self.headheight = 0
        self.indent = 20
        self.current_item = None
        self.select_pending = False

    # ── configuration ──
    def column_ids(self):
        return split_list(self.opts.get("columns", ""))

    def reconfigured(self, changed):
        if "columns" in changed:
            ids = self.column_ids()
            old = self.columns
            self.columns = {}
            for c in ids:
                self.columns[c] = old.get(c) or TColumn(c)
            if "displaycolumns" not in changed:
                self.opts["displaycolumns"] = "#all"
        if "displaycolumns" in changed:
            dc = split_list(self.opts.get("displaycolumns", "#all"))
            if dc != ["#all"]:
                for c in dc:
                    self.col_by_spec(c, display=False)
        TtkWidget.reconfigured(self, changed)

    def show(self):
        return split_list(self.opts.get("show", ""))

    def display_columns(self):
        dc = split_list(self.opts.get("displaycolumns", "#all"))
        if dc == ["#all"]:
            return [self.columns[c] for c in self.column_ids()]
        out = []
        for c in dc:
            out.append(self.col_by_spec(c, display=False))
        return out

    def col_by_spec(self, spec, display=True):
        # a column: #0, #n (display index), a name or an index into -columns
        s = tcl_str(spec)
        if s == "#0":
            return self.tree_col
        if s.startswith("#"):
            try:
                n = int(s[1:])
            except ValueError:
                raise TclError("Invalid column index " + s)
            dc = self.display_columns()
            if 1 <= n <= len(dc):
                return dc[n - 1]
            raise TclError("Column index " + s + " out of bounds")
        if s in self.columns:
            return self.columns[s]
        try:
            n = int(s)
        except ValueError:
            raise TclError("Invalid column index " + s)
        ids = self.column_ids()
        if 0 <= n < len(ids):
            return self.columns[ids[n]]
        raise TclError("Column index " + s + " out of bounds")

    def sublayout(self, name, rec):
        e = engine(self.app)
        st = self.opts.get("style") or ""
        full = (st if st else "Treeview") + "." + name
        key = (e.epoch, full)
        lay = self.sub.get(name)
        if lay is None or lay[0] != key:
            holder = {"rec": {}}
            lay = (key, make_layout(self.app, full, lambda h=holder: h["rec"], self), holder)
            self.sub[name] = lay
        lay[2]["rec"] = rec
        lay[1].record_fn = lambda r=rec: r
        lay[1].invalidate()
        return lay[1]

    def style_opt(self, opt, default):
        v = style_query(self.get_layout().style, "-" + opt, self.tstate)
        return v if v is not None else default

    def tree_width(self):
        w = 0
        if "tree" in self.show():
            w += self.tree_col.opts["width"]
        for c in self.display_columns():
            w += c.opts["width"]
        return w

    def compute_geometry(self):
        lay = self.get_layout()
        pw, ph = lay.size(self.tstate)
        self.rowheight = T._px(self.style_opt("rowheight", None), 0) or self.default_rowheight()
        self.indent = T._px(self.style_opt("indent", "20"), 20)
        self.headheight = self.heading_height()
        h = ph + self.rowheight * self.opts["height"]
        if "headings" in self.show():
            h += self.headheight
        self.request(pw + self.tree_width(), h)

    def default_rowheight(self):
        # DEFAULT_ROWHEIGHT, or the font's linespace when that is taller
        f = self.app.font_of(self.style_opt("font", "TkDefaultFont"))
        return max(20, f.metrics()[2])

    def heading_height(self):
        hh = 0
        for c in [self.tree_col] + self.display_columns():
            lay = self.sublayout("Heading", {"text": c.head["text"], "image": c.head["image"] or None,
                                             "anchor": c.head["anchor"]})
            w, h = lay.size(self.tstate)
            hh = max(hh, h)
        return hh

    def tree_area(self):
        lay = self.get_layout()
        pl = self.placements()
        ta = lay.find(pl, "treearea")
        if ta is None:
            return (0, 0, self.width, self.height)
        return ta.box

    # ── items ──
    def item(self, spec):
        s = tcl_str(spec)
        it = self.items.get(s)
        if it is None:
            raise TclError("Item " + s + " not found")
        return it

    def configure_item(self, it, args):
        if len(args) % 2 != 0:
            raise TclError("value for \"" + tcl_str(args[-1]) + "\" missing")
        for i in range(0, len(args), 2):
            k = match_prefix(tcl_str(args[i]), _ITEM_OPTS, "option")[1:]
            v = args[i + 1]
            if k == "open":
                v = 1 if get_boolean(v) else 0
            elif k == "values":
                v = v if isinstance(v, (tuple, list)) else (split_list(v) if tcl_str(v) != "" else "")
                if isinstance(v, (tuple, list)):
                    v = tuple(v)
                    if not v:
                        v = ""
            elif k == "tags":
                v = tuple(_words(v)) if tcl_str(v) != "" else ""
                for tg in (v or ()):
                    self.tags.setdefault(tg, {})
            elif k == "image":
                v = tcl_str(v)
                if v and _words(v)[0] not in self.app.images:
                    raise TclError("image \"" + v + "\" doesn't exist")
            else:
                v = tcl_str(v)
            it.opts[k] = v

    def w_insert(self, args):
        if len(args) < 2:
            raise TclError("wrong # args: should be \"" + self.path + " insert parent index ?-id id? -options...\"")
        parent = self.item(args[0])
        idx = self.child_index(parent, args[1])
        rest = list(args[2:])
        iid = None
        if len(rest) >= 2 and tcl_str(rest[0]) == "-id":
            iid = tcl_str(rest[1])
            rest = rest[2:]
            if iid in self.items:
                raise TclError("Item " + iid + " already exists")
        if iid is None:
            while True:
                self.serial += 1
                iid = "I%03X" % self.serial
                if iid not in self.items:
                    break
        it = TItem(iid, parent)
        self.configure_item(it, rest)
        self.items[iid] = it
        parent.children.insert(idx, it)
        self.changed()
        return iid

    def child_index(self, parent, spec):
        s = tcl_str(spec)
        if s == "end":
            return len(parent.children)
        try:
            k = get_int(spec)
        except TclError:
            raise TclError("Unrecognized index " + s)
        return max(0, min(len(parent.children), k))

    def changed(self):
        self.update_scroll()
        self.damage()

    def descendants(self, it):
        out = []
        for c in it.children:
            out.append(c)
            out.extend(self.descendants(c))
        return out

    def items_arg(self, args):
        out = []
        for a in args:
            out.extend(_words(a) if not isinstance(a, (tuple, list)) else [tcl_str(x) for x in a])
        return [self.item(x) for x in out]

    def w_delete(self, args):
        its = self.items_arg(args)
        for it in its:
            if it.iid == "":
                raise TclError("Cannot delete root item")
        sel_changed = False
        for it in its:
            if it.iid not in self.items:
                continue
            for d in [it] + self.descendants(it):
                if d.selected:
                    sel_changed = True
                self.items.pop(d.iid, None)
                if self.focus_item == d.iid:
                    self.focus_item = ""
            if it.parent is not None and it in it.parent.children:
                it.parent.children.remove(it)
        if sel_changed:
            self.select_event()
        self.changed()
        return ""

    def w_detach(self, args):
        its = self.items_arg(args)
        for it in its:
            if it.iid == "":
                raise TclError("Cannot detach root item")
        for it in its:
            if it.parent is not None and it in it.parent.children:
                it.parent.children.remove(it)
            it.detached = True
        self.changed()
        return ""

    def w_move(self, args):
        it = self.item(args[0])
        parent = self.item(args[1])
        p = parent
        while p is not None:
            if p is it:
                raise TclError("Cannot insert " + it.iid + " as descendant of " + parent.iid)
            p = p.parent
        if it.parent is not None and it in it.parent.children:
            old = it.parent.children.index(it)
            it.parent.children.remove(it)
        idx = self.child_index(parent, args[2])
        idx = min(idx, len(parent.children))
        parent.children.insert(idx, it)
        it.parent = parent
        it.detached = False
        self.changed()
        return ""

    def w_children(self, args):
        it = self.item(args[0])
        if len(args) == 1:
            return tuple(c.iid for c in it.children)
        new = self.items_arg(args[1:])
        for n in new:
            p = it
            while p is not None:
                if p is n:
                    raise TclError("Cannot insert " + n.iid + " as descendant of " + it.iid)
                p = p.parent
        for c in it.children:
            if c not in new:
                c.detached = True
        for n in new:
            if n.parent is not None and n in n.parent.children:
                n.parent.children.remove(n)
            n.parent = it
            n.detached = False
        it.children = list(new)
        self.changed()
        return ""

    def w_exists(self, args):
        return 1 if tcl_str(args[0]) in self.items else 0

    def w_focus(self, args):
        if not args:
            return self.focus_item
        it = self.item(args[0])
        self.focus_item = it.iid
        self.damage()
        return ""

    def w_index(self, args):
        it = self.item(args[0])
        if it.parent is None or it not in it.parent.children:
            return 0
        return it.parent.children.index(it)

    def w_next(self, args):
        it = self.item(args[0])
        if it.parent is None or it not in it.parent.children:
            return ""
        sib = it.parent.children
        k = sib.index(it)
        return sib[k + 1].iid if k + 1 < len(sib) else ""

    def w_prev(self, args):
        it = self.item(args[0])
        if it.parent is None or it not in it.parent.children:
            return ""
        sib = it.parent.children
        k = sib.index(it)
        return sib[k - 1].iid if k > 0 else ""

    def w_parent(self, args):
        it = self.item(args[0])
        return it.parent.iid if it.parent is not None else ""

    def w_item(self, args):
        it = self.item(args[0])
        rest = args[1:]
        if not rest:
            out = []
            for o in _ITEM_OPTS:
                out.extend([o, it.opts[o[1:]]])
            return tuple(out)
        if len(rest) == 1:
            return it.opts[match_prefix(tcl_str(rest[0]), _ITEM_OPTS, "option")[1:]]
        self.configure_item(it, rest)
        self.changed()
        return ""

    def w_set(self, args):
        it = self.item(args[0])
        vals = list(it.opts["values"]) if it.opts["values"] != "" else []
        ids = self.column_ids()
        if len(args) == 1:
            out = []
            for i, c in enumerate(ids):
                out.extend([c, vals[i] if i < len(vals) else ""])
            return tuple(out)
        col = self.col_by_spec(args[1])
        if col is self.tree_col:
            raise TclError("Display column #0 cannot be set")
        k = ids.index(col.opts["id"])
        if len(args) == 2:
            return vals[k] if k < len(vals) else ""
        while len(vals) <= k:
            vals.append("")
        vals[k] = args[2]
        it.opts["values"] = tuple(vals)
        self.changed()
        return ""

    def w_column(self, args):
        col = self.col_by_spec(args[0])
        rest = args[1:]
        if not rest:
            out = []
            for o in _COL_OPTS:
                out.extend([o, col.opts[o[1:]]])
            return tuple(out)
        if len(rest) == 1:
            return col.opts[match_prefix(tcl_str(rest[0]), _COL_OPTS, "option")[1:]]
        if len(rest) % 2 != 0:
            raise TclError("value for \"" + tcl_str(rest[-1]) + "\" missing")
        for i in range(0, len(rest), 2):
            k = match_prefix(tcl_str(rest[i]), _COL_OPTS, "option")[1:]
            v = rest[i + 1]
            if k in ("width", "minwidth"):
                v = pixels(v)
            elif k == "stretch":
                v = 1 if get_boolean(v) else 0
            elif k == "anchor":
                v = match_prefix(tcl_str(v), ["n", "ne", "e", "se", "s", "sw", "w", "nw", "center"], "anchor")
            elif k == "id":
                raise TclError("Read-only option -id")
            col.opts[k] = v
        if col.opts["width"] < col.opts["minwidth"]:
            col.opts["width"] = col.opts["minwidth"]
        self.compute_geometry()
        self.changed()
        return ""

    def w_heading(self, args):
        col = self.col_by_spec(args[0])
        rest = args[1:]
        if not rest:
            out = []
            for o in _HEAD_OPTS:
                out.extend([o, col.head[o[1:]]])
            return tuple(out)
        if len(rest) == 1:
            return col.head[match_prefix(tcl_str(rest[0]), _HEAD_OPTS, "option")[1:]]
        if len(rest) % 2 != 0:
            raise TclError("value for \"" + tcl_str(rest[-1]) + "\" missing")
        for i in range(0, len(rest), 2):
            k = match_prefix(tcl_str(rest[i]), _HEAD_OPTS, "option")[1:]
            v = rest[i + 1]
            if k == "anchor":
                v = match_prefix(tcl_str(v), ["n", "ne", "e", "se", "s", "sw", "w", "nw", "center"], "anchor")
            elif k == "image":
                v = tcl_str(v)
                if v and _words(v)[0] not in self.app.images:
                    raise TclError("image \"" + v + "\" doesn't exist")
            else:
                v = tcl_str(v)
            col.head[k] = v
        self.compute_geometry()
        self.damage()
        return ""

    # ── selection ──
    def preorder(self, it=None, visible=False):
        it = it if it is not None else self.items[""]
        out = []
        for c in it.children:
            out.append(c)
            if not visible or c.opts["open"]:
                out.extend(self.preorder(c, visible))
        return out

    def w_selection(self, args):
        if not args:
            return tuple(it.iid for it in self.preorder() if it.selected)
        op = match_prefix(tcl_str(args[0]), ["add", "remove", "set", "toggle"], "selection operation")
        its = self.items_arg(args[1:])
        before = set(i.iid for i in self.items.values() if i.selected)
        if op == "set":
            for it in self.items.values():
                it.selected = False
            for it in its:
                it.selected = True
        elif op == "add":
            for it in its:
                it.selected = True
        elif op == "remove":
            for it in its:
                it.selected = False
        else:
            for it in its:
                it.selected = not it.selected
        after = set(i.iid for i in self.items.values() if i.selected)
        if before != after:
            self.select_event()
        self.damage()
        return ""

    def select_event(self):
        self.app.event_generate([self.path, "<<TreeviewSelect>>", "-when", "tail"])

    # ── tags ──
    def w_tag(self, args):
        sub = match_prefix(tcl_str(args[0]), ["add", "bind", "cget", "configure", "delete", "has", "names", "remove"],
                           "command")
        rest = args[1:]
        if sub == "names":
            return tuple(self.tags.keys())
        tag = tcl_str(rest[0]) if rest else ""
        if sub == "has":
            if len(rest) == 1:
                return tuple(it.iid for it in self.preorder() if tag in (it.opts["tags"] or ()))
            it = self.item(rest[1])
            return 1 if tag in (it.opts["tags"] or ()) else 0
        if sub in ("add", "remove"):
            its = self.items_arg(rest[1:]) if len(rest) > 1 else list(self.items.values())
            for it in its:
                tg = list(it.opts["tags"] or ())
                if sub == "add" and tag not in tg:
                    tg.append(tag)
                elif sub == "remove" and tag in tg:
                    tg.remove(tag)
                it.opts["tags"] = tuple(tg) if tg else ""
            self.tags.setdefault(tag, {})
            self.damage()
            return ""
        if sub == "delete":
            self.tags.pop(tag, None)
            for it in self.items.values():
                tg = list(it.opts["tags"] or ())
                if tag in tg:
                    tg.remove(tag)
                    it.opts["tags"] = tuple(tg) if tg else ""
            self.tag_bindings.delete_tag(tag)
            self.damage()
            return ""
        if sub == "bind":
            if len(rest) == 1:
                return tuple(self.tag_bindings.sequences(tag))
            seq = tcl_str(rest[1])
            if len(rest) == 2:
                return self.tag_bindings.get(tag, seq) or ""
            script = tcl_str(rest[2])
            if script.startswith("+"):
                old = self.tag_bindings.get(tag, seq) or ""
                script = (old + "\n" + script[1:]) if old else script[1:]
            self.tag_bindings.set(tag, seq, script)
            return ""
        t = self.tags.setdefault(tag, {})
        if sub == "cget":
            o = match_prefix(tcl_str(rest[1]), _TAG_OPTS, "option")
            return t.get(o[1:], "")
        opts = rest[1:]
        if not opts:
            out = []
            for o in _TAG_OPTS:
                if o[1:] in t:
                    out.extend([o, t[o[1:]]])
            return tuple(out)
        if len(opts) == 1:
            o = match_prefix(tcl_str(opts[0]), _TAG_OPTS, "option")
            return t.get(o[1:], "")
        for i in range(0, len(opts), 2):
            o = match_prefix(tcl_str(opts[i]), _TAG_OPTS, "option")[1:]
            v = tcl_str(opts[i + 1])
            if o in ("foreground", "background") and v:
                parse_color(v)
            if o == "font" and v:
                self.app.font_of(v)
            t[o] = v
        self.damage()
        return ""

    # ── geometry of rows ──
    def visible_rows(self):
        return self.preorder(None, True)

    def depth(self, it):
        d = 0
        p = it.parent
        while p is not None and p.iid != "":
            d += 1
            p = p.parent
        return d

    def rows_box(self):
        ta = self.tree_area()
        y = ta[1] + (self.headheight if "headings" in self.show() else 0)
        return (ta[0], y, ta[2], ta[1] + ta[3] - y)

    def col_layout(self):
        # x of each displayed column (the tree column first), from the left
        # of the tree area, minus the horizontal scroll
        cols = []
        x = 0
        if "tree" in self.show():
            cols.append((self.tree_col, x))
            x += self.tree_col.opts["width"]
        for c in self.display_columns():
            cols.append((c, x))
            x += c.opts["width"]
        return cols

    def visible_count(self):
        rb = self.rows_box()
        return max(0, rb[3] // self.rowheight) if self.rowheight > 0 else 0

    def w_bbox(self, args):
        it = self.item(args[0])
        rows = self.visible_rows()
        if it not in rows:
            return ""
        r = rows.index(it) - self.yoff
        n = self.visible_count()
        if r < 0 or r >= n:
            return ""
        rb = self.rows_box()
        y = rb[1] + r * self.rowheight
        if len(args) > 1 and args[1] is not None and tcl_str(args[1]) != "":
            col = self.col_by_spec(args[1])
            for c, x in self.col_layout():
                if c is col:
                    return (rb[0] + x - self.xoff, y, c.opts["width"], self.rowheight)
            return ""
        return (rb[0] - self.xoff, y, self.tree_width(), self.rowheight)

    def w_identify(self, args):
        comps = ["region", "item", "column", "row", "element", "cell"]
        if len(args) == 2:
            return TtkWidget.w_identify(self, args)
        what = match_prefix(tcl_str(args[0]), comps, "component")
        x = get_int(args[1])
        y = get_int(args[2])
        ta = self.tree_area()
        rb = self.rows_box()
        hx = x - ta[0] + self.xoff
        col = None
        colx = 0
        for c, cx in self.col_layout():
            if cx <= hx < cx + c.opts["width"]:
                col = c
                colx = cx
        colname = ""
        if col is not None:
            if col is self.tree_col:
                colname = "#0"
            else:
                dc = self.display_columns()
                colname = "#" + str(dc.index(col) + 1)
        row_item = ""
        if rb[1] <= y < rb[1] + rb[3]:
            r = (y - rb[1]) // self.rowheight + self.yoff
            rows = self.visible_rows()
            if 0 <= r < len(rows):
                row_item = rows[r].iid
        if what == "column":
            return colname
        if what in ("item", "row"):
            return row_item
        if what == "cell":
            return (row_item, colname) if row_item else ""
        if what == "region":
            if "headings" in self.show() and ta[1] <= y < ta[1] + self.headheight:
                for c, cx in self.col_layout():
                    edge = cx + c.opts["width"]
                    if abs(hx - edge) <= 4 and hx < edge + 4 and hx > edge - 4:
                        return "separator"
                return "heading" if col is not None else "nothing"
            if row_item:
                if col is None:
                    return "nothing"
                return "tree" if col is self.tree_col else "cell"
            return "nothing"
        # element
        if not row_item or col is None:
            if "headings" in self.show() and ta[1] <= y < ta[1] + self.headheight and col is not None:
                return "text"
            return ""
        it = self.items[row_item]
        if col is self.tree_col:
            lay, box, st = self.item_layout(it, rb, (y - rb[1]) // self.rowheight * self.rowheight + rb[1])
            pl = lay.place(box, st)
            p = lay.identify(pl, x, y)
            if p is None:
                return ""
            n = p.node.name
            return n[n.find(".") + 1:] if "." in n else n
        return "text"

    def item_state(self, it):
        st = self.tstate & ~(S_SELECTED | S_FOCUS | SBIT["user1"] | SBIT["user2"])
        if it.selected:
            st |= S_SELECTED
        if it.opts["open"]:
            st |= SBIT["user1"]
        if not it.children:
            st |= SBIT["user2"]
        if self.focus_item == it.iid and self.tstate & S_FOCUS:
            st |= S_FOCUS
        return st

    def tag_opt(self, it, opt):
        for tg in (it.opts["tags"] or ()):
            v = self.tags.get(tg, {}).get(opt)
            if v:
                return v
        return None

    def item_layout(self, it, rb, y):
        st = self.item_state(it)
        rec = {"text": it.opts["text"], "image": it.opts["image"] or None,
               "foreground": self.tag_opt(it, "foreground"), "font": self.tag_opt(it, "font")}
        lay = self.sublayout("Item", rec)
        indent = self.depth(it) * self.indent
        x = rb[0] - self.xoff + indent
        w = self.tree_col.opts["width"] - indent
        return lay, (x, y, w, self.rowheight), st

    def draw(self, h, ax, ay):
        TtkWidget.draw(self, h, ax, ay)
        ta = self.tree_area()
        rb = self.rows_box()
        gui_push_clip(h, ax + ta[0], ay + ta[1], ta[2], ta[3])
        cols = self.col_layout()
        if "headings" in self.show():
            for c, cx in cols:
                lay = self.sublayout("Heading", {"text": c.head["text"], "image": c.head["image"] or None,
                                                 "anchor": c.head["anchor"]})
                st = self.tstate & ~S_PRESSED
                if getattr(self, "pressed_heading", None) is c:
                    st |= S_PRESSED
                pl = lay.place((ta[0] + cx - self.xoff, ta[1], c.opts["width"], self.headheight), st)
                lay.draw(h, ax, ay, pl, st)
        rows = self.visible_rows()
        n = self.visible_count() + 1
        bgsty = self.get_layout().style
        for r in range(self.yoff, min(len(rows), self.yoff + n)):
            it = rows[r]
            y = rb[1] + (r - self.yoff) * self.rowheight
            st = self.item_state(it)
            bg = self.tag_opt(it, "background") if not it.selected else None
            if bg is None:
                bg = style_query(bgsty, "-background", st) or "white"
            fg = self.tag_opt(it, "foreground") if not it.selected else None
            if fg is None:
                fg = style_query(bgsty, "-foreground", st) or "black"
            row = self.sublayout("Row", {"background": bg})
            rpl = row.place((rb[0] - self.xoff, y, max(self.tree_width(), rb[2] + self.xoff), self.rowheight), st)
            row.draw(h, ax, ay, rpl, st)
            vals = list(it.opts["values"]) if it.opts["values"] != "" else []
            ids = self.column_ids()
            for c, cx in cols:
                if c is self.tree_col:
                    lay, box, ist = self.item_layout(it, rb, y)
                    lay.record_fn = (lambda rr={"text": it.opts["text"], "image": it.opts["image"] or None,
                                                "foreground": fg, "font": self.tag_opt(it, "font")}: rr)
                    lay.invalidate()
                    pl = lay.place(box, ist)
                    lay.draw(h, ax, ay, pl, ist)
                    continue
                k = ids.index(c.opts["id"])
                v = vals[k] if k < len(vals) else ""
                cell = self.sublayout("Cell", {"text": tcl_str(v), "anchor": c.opts["anchor"], "foreground": fg,
                                               "font": self.tag_opt(it, "font")})
                cpl = cell.place((rb[0] + cx - self.xoff, y, c.opts["width"], self.rowheight), st)
                cell.draw(h, ax, ay, cpl, st)
        gui_pop_clip(h)

    # ── scrolling ──
    def fractions_y(self):
        rows = len(self.visible_rows())
        if rows == 0:
            return (0.0, 1.0)
        n = self.visible_count()
        first = self.yoff / float(rows)
        last = min(1.0, (self.yoff + n) / float(rows))
        return (first, last)

    def fractions_x(self):
        tw = self.tree_width()
        if tw <= 0:
            return (0.0, 1.0)
        ta = self.tree_area()
        return (self.xoff / float(tw), min(1.0, (self.xoff + ta[2]) / float(tw)))

    def update_scroll(self):
        f, l = self.fractions_y()
        self.scroll_command("yscrollcommand", f, l)
        f, l = self.fractions_x()
        self.scroll_command("xscrollcommand", f, l)

    def on_resize(self):
        TtkWidget.on_resize(self)
        self.update_scroll()

    def w_yview(self, args):
        if not args:
            return self.fractions_y()
        rows = len(self.visible_rows())
        n = self.visible_count()
        a0 = tcl_str(args[0])
        if a0 == "moveto":
            k = int(get_double(args[1]) * rows + 0.5)
        elif a0 == "scroll":
            cnt = get_int(args[1])
            what = match_prefix(tcl_str(args[2]), ["pages", "units"], "argument")
            k = self.yoff + cnt * (max(1, n) if what == "pages" else 1)
        else:
            raise TclError("bad option \"" + a0 + "\": must be moveto or scroll")
        k = max(0, min(k, max(0, rows - n)))
        self.yoff = k
        self.update_scroll()
        self.damage()
        return ""

    def w_xview(self, args):
        if not args:
            return self.fractions_x()
        tw = self.tree_width()
        ta = self.tree_area()
        a0 = tcl_str(args[0])
        if a0 == "moveto":
            k = int(get_double(args[1]) * tw + 0.5)
        elif a0 == "scroll":
            cnt = get_int(args[1])
            what = match_prefix(tcl_str(args[2]), ["pages", "units"], "argument")
            k = self.xoff + cnt * (ta[2] if what == "pages" else 1)
        else:
            raise TclError("bad option \"" + a0 + "\": must be moveto or scroll")
        self.xoff = max(0, min(k, max(0, tw - ta[2])))
        self.update_scroll()
        self.damage()
        return ""

    def w_see(self, args):
        it = self.item(args[0])
        p = it.parent
        opened = False
        while p is not None and p.iid != "":
            if not p.opts["open"]:
                p.opts["open"] = 1
                opened = True
            p = p.parent
        rows = self.visible_rows()
        if it in rows:
            r = rows.index(it)
            n = max(1, self.visible_count())
            if r < self.yoff:
                self.yoff = r
            elif r >= self.yoff + n:
                self.yoff = r - n + 1
        self.update_scroll()
        self.damage()
        return ""

    # ── item bindings ──
    def on_event(self, ev):
        TtkWidget.on_event(self, ev)
        t = ev.type
        if t in (B.ButtonPress, B.ButtonRelease, B.MotionNotify, B.KeyPress, B.KeyRelease, B.VirtualEvent):
            if t in (B.KeyPress, B.KeyRelease, B.VirtualEvent):
                it = self.items.get(self.focus_item) if self.focus_item else None
            else:
                rid = self.w_identify(["item", ev.x, ev.y])
                it = self.items.get(rid) if rid else None
            if it is not None and it.opts["tags"]:
                self.tag_event(it, ev)

    def tag_event(self, it, ev):
        # TreeviewBindEventProc: the bindings of the item's tags, in order
        ring = self.app.ring
        if ev not in ring:
            ring = ring + [ev]
        for tg in list(it.opts["tags"] or ()):
            sc = self.tag_bindings.best_match(tg, ring, ev)
            if sc is None:
                continue
            if self.app.run_binding(sc, ev) == "break" or self.destroyed:
                break


def _tv(app, args):
    return app.window(args[0])


def c_tv_press(app, args):
    # ttk::treeview::Press
    w = _tv(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    tf = w.opts.get("takefocus") or ""
    if tf != "0":
        app.set_focus(w)
    region = w.w_identify(["region", x, y])
    if region == "heading":
        col = w.w_identify(["column", x, y])
        try:
            w.pressed_heading = w.col_by_spec(col)
        except TclError:
            w.pressed_heading = None
        w.damage()
        return ""
    if region == "separator":
        col = w.w_identify(["column", x - 5, y]) or w.w_identify(["column", x, y])
        try:
            c = w.col_by_spec(col)
        except TclError:
            c = None
        W._priv(app)["ttktvresize"] = (w, c, x, c.opts["width"] if c else 0)
        return ""
    item = w.w_identify(["item", x, y])
    if not item:
        return ""
    if region == "tree" and w.w_identify(["element", x, y]) == "indicator":
        toggle(app, w, item)
        return ""
    select_op(app, w, item, tcl_str(args[3]) if len(args) > 3 else "choose")
    return ""


def select_op(app, w, item, op):
    # ttk::treeview::Select: choose / extend / toggle by -selectmode
    mode = w.opts.get("selectmode") or "extended"
    if mode == "none":
        return
    w.focus_item = item
    if mode == "browse" or op == "choose":
        w.w_selection(["set", item])
        w.anchor_item = item
    elif op == "toggle" and mode == "extended":
        w.w_selection(["toggle", item])
        w.anchor_item = item
    elif op == "extend" and mode == "extended":
        rows = w.visible_rows()
        a = w.items.get(getattr(w, "anchor_item", "") or "")
        b = w.items[item]
        if a is None or a not in rows:
            w.w_selection(["set", item])
        else:
            i, j = sorted([rows.index(a), rows.index(b)])
            w.w_selection(["set", [r.iid for r in rows[i:j + 1]]])
    w.w_see([item])


def toggle(app, w, item):
    it = w.items[item]
    if it.opts["open"]:
        it.opts["open"] = 0
        w.focus_item = item
        app.event_generate([w.path, "<<TreeviewClose>>"])
    else:
        it.opts["open"] = 1
        w.focus_item = item
        app.event_generate([w.path, "<<TreeviewOpen>>"])
    w.changed()


def c_tv_double(app, args):
    w = _tv(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    item = w.w_identify(["item", x, y])
    if item and w.w_identify(["region", x, y]) in ("tree", "cell") and w.items[item].children:
        toggle(app, w, item)
    return ""


def c_tv_release(app, args):
    w = _tv(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    W._priv(app)["ttktvresize"] = None
    c = getattr(w, "pressed_heading", None)
    if c is not None:
        w.pressed_heading = None
        w.damage()
        if w.w_identify(["region", x, y]) == "heading" and c.head["command"]:
            app.eval_bg(c.head["command"])
    return ""


def c_tv_drag(app, args):
    w = _tv(app, args)
    d = W._priv(app).get("ttktvresize")
    if d and d[0] is w and d[1] is not None:
        x = get_int(args[1])
        nw = max(d[1].opts["minwidth"], d[3] + x - d[2])
        w.w_column([d[1].opts["id"] if d[1] is not w.tree_col else "#0", "-width", nw])
    return ""


def c_tv_keynav(app, args):
    # ttk::treeview::Keynav: Up/Down move the focus (and the selection in
    # browse/extended mode), Left closes or goes to the parent, Right opens
    w = _tv(app, args)
    d = tcl_str(args[1])
    rows = w.visible_rows()
    if not rows:
        return ""
    cur = w.items.get(w.focus_item) if w.focus_item else None
    if d in ("up", "down"):
        if cur is None or cur not in rows:
            nxt = rows[0]
        else:
            k = rows.index(cur) + (1 if d == "down" else -1)
            nxt = rows[max(0, min(len(rows) - 1, k))]
        select_op(app, w, nxt.iid, "choose")
    elif d == "left" and cur is not None:
        if cur.opts["open"] and cur.children:
            toggle(app, w, cur.iid)
        elif cur.parent is not None and cur.parent.iid != "":
            select_op(app, w, cur.parent.iid, "choose")
    elif d == "right" and cur is not None:
        if not cur.opts["open"] and cur.children:
            toggle(app, w, cur.iid)
    return ""


def c_tv_toggle_focus(app, args):
    w = _tv(app, args)
    if w.focus_item and w.items[w.focus_item].children:
        toggle(app, w, w.focus_item)
    return ""


for _name, _f in (("ttk::combobox::Post", c_combo_post), ("ttk::combobox::Unpost", c_combo_unpost),
                  ("ttk::combobox::Press", c_combo_press), ("ttk::combobox::LBSelected", c_combo_lbselected),
                  ("ttk::combobox::PopdownWindow", c_combo_window),
                  ("ttk::spinbox::Spin", c_spin), ("ttk::spinbox::Press", c_spin_press),
                  ("ttk::scrollbar::Press", c_sb_press), ("ttk::scrollbar::Drag", c_sb_drag),
                  ("ttk::scrollbar::Release", c_sb_release),
                  ("ttk::scale::Press", c_scale_press), ("ttk::scale::Drag", c_scale_drag),
                  ("ttk::scale::Release", c_scale_release), ("ttk::scale::Jump", c_scale_jump),
                  ("ttk::scale::Increment", c_scale_incr), ("ttk::scale::SetTo", c_scale_setto),
                  ("ttk::notebook::Press", c_nb_press), ("ttk::notebook::CycleTab", c_nb_cycle),
                  ("ttk::notebook::enableTraversal", c_nb_traversal),
                  ("ttk::panedwindow::Press", c_pw_press), ("ttk::panedwindow::Drag", c_pw_drag),
                  ("ttk::panedwindow::Release", c_pw_release),
                  ("ttk::treeview::Press", c_tv_press), ("ttk::treeview::DoubleClick", c_tv_double),
                  ("ttk::treeview::Release", c_tv_release), ("ttk::treeview::Drag", c_tv_drag),
                  ("ttk::treeview::Keynav", c_tv_keynav), ("ttk::treeview::ToggleFocus", c_tv_toggle_focus)):
    C.TK_COMMANDS[_name] = _f

for _name, _cls in (("ttk::entry", TtkEntry), ("ttk::combobox", TtkCombobox), ("ttk::spinbox", TtkSpinbox),
                    ("ttk::scrollbar", TtkScrollbar), ("ttk::scale", TtkScale),
                    ("ttk::progressbar", TtkProgressbar), ("ttk::notebook", TtkNotebook),
                    ("ttk::panedwindow", TtkPanedwindow), ("ttk::treeview", TtkTreeview)):
    C.WIDGET_TYPES[_name] = _cls


def _bindings(app):
    b = app.bindings
    for cls in ("TEntry", "TCombobox", "TSpinbox"):
        E._entry_bindings(app, cls)
    b.set("TCombobox", "<KeyPress-Down>", "ttk::combobox::Post %W")
    b.set("TCombobox", "<KeyPress-Escape>", "ttk::combobox::Unpost %W")
    b.set("TCombobox", "<ButtonPress-1>", "ttk::combobox::Press {} %W %x %y")
    b.set("TCombobox", "<Shift-ButtonPress-1>", "ttk::combobox::Press s %W %x %y")
    b.set("TCombobox", "<Double-ButtonPress-1>", "ttk::combobox::Press 2 %W %x %y")
    b.set("TCombobox", "<Triple-ButtonPress-1>", "ttk::combobox::Press 3 %W %x %y")
    b.set("ComboboxListbox", "<ButtonRelease-1>", "ttk::combobox::LBSelected %W")
    b.set("ComboboxListbox", "<KeyPress-Return>", "ttk::combobox::LBSelected %W")
    b.set("TSpinbox", "<<Increment>>", "ttk::spinbox::Spin %W +1")
    b.set("TSpinbox", "<<Decrement>>", "ttk::spinbox::Spin %W -1")
    b.set("TSpinbox", "<Key-Up>", "ttk::spinbox::Spin %W +1")
    b.set("TSpinbox", "<Key-Down>", "ttk::spinbox::Spin %W -1")
    b.set("TSpinbox", "<ButtonPress-1>", "ttk::spinbox::Press %W %x %y")
    b.set("TScrollbar", "<ButtonPress-1>", "ttk::scrollbar::Press %W %x %y")
    b.set("TScrollbar", "<B1-Motion>", "ttk::scrollbar::Drag %W %x %y")
    b.set("TScrollbar", "<ButtonRelease-1>", "ttk::scrollbar::Release %W %x %y")
    b.set("TScale", "<ButtonPress-1>", "ttk::scale::Press %W %x %y")
    b.set("TScale", "<B1-Motion>", "ttk::scale::Drag %W %x %y")
    b.set("TScale", "<ButtonRelease-1>", "ttk::scale::Release %W %x %y")
    b.set("TScale", "<ButtonPress-2>", "ttk::scale::Jump %W %x %y")
    b.set("TScale", "<ButtonPress-3>", "ttk::scale::Jump %W %x %y")
    b.set("TScale", "<<LineStart>>", "ttk::scale::SetTo %W from")
    b.set("TScale", "<<LineEnd>>", "ttk::scale::SetTo %W to")
    b.set("TScale", "<<PrevChar>>", "ttk::scale::Increment %W -1")
    b.set("TScale", "<<PrevLine>>", "ttk::scale::Increment %W -1")
    b.set("TScale", "<<NextChar>>", "ttk::scale::Increment %W 1")
    b.set("TScale", "<<NextLine>>", "ttk::scale::Increment %W 1")
    b.set("TNotebook", "<ButtonPress-1>", "ttk::notebook::Press %W %x %y")
    b.set("TNotebook", "<Key-Right>", "ttk::notebook::CycleTab %W 1; break")
    b.set("TNotebook", "<Key-Left>", "ttk::notebook::CycleTab %W -1; break")
    b.set("TNotebook", "<Control-Key-Tab>", "ttk::notebook::CycleTab %W 1; break")
    b.set("TNotebook", "<Control-Shift-Key-Tab>", "ttk::notebook::CycleTab %W -1; break")
    b.set("TPanedwindow", "<ButtonPress-1>", "ttk::panedwindow::Press %W %x %y")
    b.set("TPanedwindow", "<B1-Motion>", "ttk::panedwindow::Drag %W %x %y")
    b.set("TPanedwindow", "<ButtonRelease-1>", "ttk::panedwindow::Release %W %x %y")
    b.set("Treeview", "<ButtonPress-1>", "ttk::treeview::Press %W %x %y choose")
    b.set("Treeview", "<Control-ButtonPress-1>", "ttk::treeview::Press %W %x %y toggle")
    b.set("Treeview", "<Shift-ButtonPress-1>", "ttk::treeview::Press %W %x %y extend")
    b.set("Treeview", "<Double-ButtonPress-1>", "ttk::treeview::DoubleClick %W %x %y")
    b.set("Treeview", "<ButtonRelease-1>", "ttk::treeview::Release %W %x %y")
    b.set("Treeview", "<B1-Motion>", "ttk::treeview::Drag %W %x %y")
    b.set("Treeview", "<Key-Up>", "ttk::treeview::Keynav %W up")
    b.set("Treeview", "<Key-Down>", "ttk::treeview::Keynav %W down")
    b.set("Treeview", "<Key-Right>", "ttk::treeview::Keynav %W right")
    b.set("Treeview", "<Key-Left>", "ttk::treeview::Keynav %W left")
    b.set("Treeview", "<Key-space>", "ttk::treeview::ToggleFocus %W")
    b.set("Treeview", "<Key-Return>", "ttk::treeview::ToggleFocus %W")


C.APP_INIT.append(_bindings)
