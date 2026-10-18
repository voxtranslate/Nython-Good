# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/entry.ny - entry, spinbox and listbox (round 84), after
# tkEntry.c, tkListbox.c and Tk's entry.tcl / spinbox.tcl / listbox.tcl.
#
# entry     indices (n, end, insert, anchor, sel.first, sel.last, @x),
#           insert/delete/get/icursor/index/bbox, selection adjust/clear/
#           from/present/range/to (exported as the PRIMARY selection),
#           xview (fractions, moveto, scroll units/pages), -show, -state
#           normal/disabled/readonly, -textvariable both ways, and Tk's
#           validation: -validate none/focus/focusin/focusout/key/all,
#           -validatecommand/-invalidcommand with %d %i %P %s %S %v %V %W,
#           a non-boolean result or a loop turning validation off
# spinbox   an entry with arrow buttons: -from/-to/-increment/-format or
#           -values, -wrap, invoke buttonup/buttondown, -command with %W
#           %s %d, identify, set
# listbox   items, the four -selectmode behaviours of listbox.tcl (browse,
#           single, multiple, extended with Shift/Control), active item
#           and -activestyle, curselection, nearest, see (Tk's thirds
#           rule), itemconfigure, -listvariable both ways, yview/xview,
#           <<ListboxSelect>> from the class bindings

from _tkinter.tcl import TclError, tcl_str, split_list, join_list, get_int, get_double, get_boolean, match_prefix, or_list
from _tkinter.util import pixels, parse_color, cdiv, shades, fill, line, text as draw_text, draw_relief, draw_ring
from _tkinter.win import TkWin, fmt_frac
from _tkinter.bind import bs_quote
from _tkinter import core as C
from _tkinter import bind as B
from _tkinter.widgets import O, NORMAL_BG, SELECT_BG, DISABLED, BLACK, WHITE, _priv, _w

XPAD = 1
YPAD = 1

ENTRY_OPTS = [
    O("background", "background", "Background", WHITE, "color"),
    O("borderwidth", "borderWidth", "BorderWidth", 1, "pixels"),
    O("cursor", "cursor", "Cursor", "xterm", "cursor"),
    O("disabledbackground", "disabledBackground", "DisabledBackground", NORMAL_BG, "color_or_empty"),
    O("disabledforeground", "disabledForeground", "DisabledForeground", DISABLED, "color_or_empty"),
    O("exportselection", "exportSelection", "ExportSelection", 1, "boolean"),
    O("font", "font", "Font", "TkTextFont", "font"),
    O("foreground", "foreground", "Foreground", BLACK, "color"),
    O("highlightbackground", "highlightBackground", "HighlightBackground", NORMAL_BG, "color"),
    O("highlightcolor", "highlightColor", "HighlightColor", BLACK, "color"),
    O("highlightthickness", "highlightThickness", "HighlightThickness", 1, "pixels"),
    O("insertbackground", "insertBackground", "Foreground", BLACK, "color"),
    O("insertborderwidth", "insertBorderWidth", "BorderWidth", 0, "pixels"),
    O("insertofftime", "insertOffTime", "OffTime", 300, "int"),
    O("insertontime", "insertOnTime", "OnTime", 600, "int"),
    O("insertwidth", "insertWidth", "InsertWidth", 2, "pixels"),
    O("invalidcommand", "invalidCommand", "InvalidCommand", "", "command"),
    O("justify", "justify", "Justify", "left", "justify"),
    O("readonlybackground", "readonlyBackground", "ReadonlyBackground", NORMAL_BG, "color_or_empty"),
    O("relief", "relief", "Relief", "sunken", "relief"),
    O("selectbackground", "selectBackground", "Foreground", SELECT_BG, "color"),
    O("selectborderwidth", "selectBorderWidth", "BorderWidth", 0, "pixels"),
    O("selectforeground", "selectForeground", "Background", BLACK, "color_or_empty"),
    O("show", "show", "Show", "", "string"),
    O("state", "state", "State", "normal", "enum:disabled|normal|readonly:state"),
    O("takefocus", "takeFocus", "TakeFocus", "", "string"),
    O("textvariable", "textVariable", "Variable", "", "var"),
    O("validate", "validate", "Validate", "none", "enum:all|key|focus|focusin|focusout|none:validate"),
    O("validatecommand", "validateCommand", "ValidateCommand", "", "command"),
    O("width", "width", "Width", 20, "int"),
    O("xscrollcommand", "xScrollCommand", "ScrollCommand", "", "command"),
]

V_INSERT = 1
V_DELETE = 0
V_FORCED = -1


class TkEntry(TkWin):
    CLASS = "Entry"
    OPTS = ENTRY_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background", "fg": "foreground", "invcmd": "invalidcommand",
               "vcmd": "validatecommand"}
    CMDS = ["bbox", "cget", "configure", "delete", "get", "icursor", "index", "insert", "scan", "selection",
            "validate", "xview"]
    TAKES_FOCUS = True
    IS_SPINBOX = False
    A11Y_ROLE = "textbox"

    def __init__(self, app, path, parent, wclass=None):
        TkWin.__init__(self, app, path, parent, wclass)
        self.string = ""
        self.insert_pos = 0
        self.sel_first = -1
        self.sel_last = -1
        self.sel_anchor = 0
        self.left_index = 0
        self.left_x = 0
        self.layout_x = 0
        self.inset = 0
        self.xwidth = 0
        self.avg = 7
        self.validating = False
        self.var_validate = False
        self.validate_abort = False
        self.setting_var = False
        self.links = {}
        self.scan_mark_x = 0
        self.scan_mark_index = 0
        self.deleted = False

    # ── configuration ──
    def reconfigured(self, changed):
        if "textvariable" in changed:
            old = self.links.get("textvariable")
            if old is not None:
                self.app.remove_link(old)
                if old in self.var_links:
                    self.var_links.remove(old)
                del self.links["textvariable"]
            name = self.opts.get("textvariable", "")
            if name:
                if name in self.app.vars:
                    self.set_value(tcl_str(self.app.vars[name]))
                else:
                    self.app.interp.setvar(name, self.string)
                lk = self.app.add_link(name, self._textvar_changed)
                self.links["textvariable"] = lk
                self.var_links.append(lk)
        self.compute_geometry()
        self.update_scroll()
        self.damage()

    def _textvar_changed(self, name, op):
        if self.destroyed or self.setting_var:
            return
        if op == "unset":
            self.app.vars[name] = self.string
            return
        self.set_value(tcl_str(self.app.vars.get(name, "")))

    def font(self):
        return self.app.font_of(self.opts["font"])

    def display_string(self):
        sh = self.opts.get("show", "")
        if sh:
            return sh[0] * len(self.string)
        return self.string

    def compute_geometry(self):
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        self.inset = self.px("highlightthickness") + self.px("borderwidth") + XPAD
        self.avg = f.measure("0")
        if self.avg <= 0:
            self.avg = 1
        if self.IS_SPINBOX:
            self.xwidth = self.avg + 2 * (1 + XPAD)
            if self.xwidth < 11:
                self.xwidth = 11
        else:
            self.xwidth = 0
        h = ls + 2 * self.inset + 2 * (YPAD - XPAD)
        n = self.opts["width"]
        if n > 0:
            w = n * self.avg + 2 * self.inset
        elif len(self.string) == 0:
            w = self.avg + 2 * self.inset
        else:
            w = f.measure(self.display_string()) + 2 * self.inset
        w += self.xwidth
        self.request(w, h)
        self.set_internal_border(self.inset)
        self.compute_left()

    def on_resize(self):
        self.compute_left()
        self.update_scroll()

    def compute_left(self):
        f = self.font()
        ds = self.display_string()
        total = f.measure(ds)
        overflow = total - (self.width - 2 * self.inset - self.xwidth)
        if overflow <= 0:
            self.left_index = 0
            j = self.opts["justify"]
            if j == "left":
                self.left_x = self.inset
            elif j == "right":
                self.left_x = self.width - self.inset - self.xwidth - total
            else:
                self.left_x = (self.width - self.xwidth - total) // 2
            self.layout_x = self.left_x
        else:
            maxoff = self.point_to_char(ds, overflow)
            if f.measure(ds[:maxoff]) < overflow:
                maxoff += 1
            if self.left_index > maxoff:
                self.left_index = maxoff
            self.left_x = self.inset
            self.layout_x = self.left_x - f.measure(ds[:self.left_index])

    def point_to_char(self, ds, x):
        # Tk_PointToChar: the character containing x (len at or past the end)
        if x < 0:
            return 0
        f = self.font()
        lo = 0
        for i in range(len(ds)):
            w = f.measure(ds[:i + 1])
            if x < w:
                return i
        return len(ds)

    # ── indices ──
    def index(self, s, for_sel=False):
        if isinstance(s, int) and not isinstance(s, bool):
            n = s
            if n < 0:
                n = 0
            if n > len(self.string):
                n = len(self.string)
            return n
        s = tcl_str(s)
        n = len(self.string)
        if s == "end":
            return n
        if s == "insert":
            return self.insert_pos
        if s == "anchor":
            return self.sel_anchor
        if s == "sel.first" or s == "sel.last":
            if self.sel_first < 0:
                raise TclError("selection isn't in widget " + self.path)
            return self.sel_first if s == "sel.first" else self.sel_last
        if s.startswith("@"):
            try:
                x = pixels(s[1:])
            except TclError:
                raise TclError("bad entry index \"" + s + "\"")
            round_up = False
            if x < self.inset:
                x = self.inset
            elif x >= self.width - self.inset - self.xwidth:
                x = self.width - self.inset - self.xwidth - 1
                round_up = True
            k = self.point_to_char(self.display_string(), x - self.layout_x)
            if round_up and k < n:
                k += 1
            return k
        try:
            k = get_int(s)
        except TclError:
            raise TclError("bad " + ("spinbox" if self.IS_SPINBOX else "entry") + " index \"" + s + "\"")
        if k < 0:
            k = 0
        if k > n:
            k = n
        return k

    # ── editing ──
    def estate(self):
        # normal / disabled / readonly (ttk entries take it from their state
        # flags)
        return self.opts["state"]

    def can_edit(self):
        return self.estate() == "normal"

    def insert(self, index, s):
        if not self.can_edit() or s == "":
            return
        new = self.string[:index] + s + self.string[index:]
        v = self.opts["validate"]
        if v in ("key", "all"):
            if self.validate_change(s, new, index, V_INSERT) != "ok":
                return
        if self.deleted:
            return
        n = len(s)
        self.string = new
        if self.sel_first >= index:
            self.sel_first += n
        if self.sel_last > index:
            self.sel_last += n
        if self.sel_anchor > index or self.sel_first == index:
            self.sel_anchor += n
        if self.left_index > index:
            self.left_index += n
        if self.insert_pos >= index:
            self.insert_pos += n
        self.value_changed()

    def delete(self, first, count):
        if not self.can_edit():
            return
        if first + count > len(self.string):
            count = len(self.string) - first
        if count <= 0:
            return
        removed = self.string[first:first + count]
        new = self.string[:first] + self.string[first + count:]
        v = self.opts["validate"]
        if v in ("key", "all"):
            if self.validate_change(removed, new, first, V_DELETE) != "ok":
                return
        if self.deleted:
            return
        self.string = new
        last = first + count
        if self.sel_first >= first:
            if self.sel_first >= last:
                self.sel_first -= count
            else:
                self.sel_first = first
        if self.sel_last >= first:
            if self.sel_last >= last:
                self.sel_last -= count
            else:
                self.sel_last = first
        if self.sel_last <= self.sel_first:
            self.sel_first = -1
            self.sel_last = -1
        if self.sel_anchor >= first:
            if self.sel_anchor >= last:
                self.sel_anchor -= count
            else:
                self.sel_anchor = first
        if self.left_index > first:
            if self.left_index >= last:
                self.left_index -= count
            else:
                self.left_index = first
        if self.insert_pos >= first:
            if self.insert_pos >= last:
                self.insert_pos -= count
            else:
                self.insert_pos = first
        self.value_changed()

    def set_value(self, value):
        # EntrySetValue: from the textvariable (or spinbox set)
        if value == self.string:
            return
        if self.var_validate:
            self.validate_abort = True
        else:
            self.var_validate = True
            self.validate_change(None, value, -1, V_FORCED)
            self.var_validate = False
            if self.validate_abort:
                self.validate_abort = False
                return
        self.string = value
        n = len(value)
        if self.sel_first >= 0:
            if self.sel_first >= n:
                self.sel_first = -1
                self.sel_last = -1
            elif self.sel_last > n:
                self.sel_last = n
        if self.left_index >= n:
            self.left_index = max(0, n - 1)
        if self.insert_pos > n:
            self.insert_pos = n
        self.compute_geometry()
        self.update_scroll()
        self.damage()

    def value_changed(self):
        name = self.opts.get("textvariable", "")
        if name:
            self.setting_var = True
            try:
                self.app.interp.setvar(name, self.string)
            finally:
                self.setting_var = False
        if self.destroyed:
            return
        self.compute_geometry()
        self.update_scroll()
        self.damage()

    def validate_change(self, change, new, index, kind, reason=None):
        # EntryValidateChange -> "ok" | "break" | "error"
        cmd = self.opts.get("validatecommand", "")
        if cmd == "" or self.opts["validate"] == "none":
            return "error" if self.var_validate else "ok"
        if self.validating:
            self.opts["validate"] = "none"
            return "error" if self.var_validate else "ok"
        self.validating = True
        varv = self.var_validate
        if reason is None:
            reason = "key" if kind in (V_INSERT, V_DELETE) else "forced"
        try:
            script = self.expand(cmd, change, new, index, kind, reason)
            code = "ok"
            try:
                r = self.app.interp.eval(script)
                try:
                    code = "ok" if get_boolean(r) else "break"
                except TclError:
                    self.app.bgerror("invalid boolean result from validation command")
                    code = "error"
            except TclError as e:
                self.app.bgerror(str(e))
                code = "error"
            if self.opts["validate"] == "none" or (not varv and self.var_validate):
                code = "error"
            if self.deleted or self.destroyed:
                return "error"
            if code == "error":
                self.opts["validate"] = "none"
            elif code == "break":
                if varv:
                    self.opts["validate"] = "none"
                elif self.opts.get("invalidcommand", ""):
                    try:
                        self.app.interp.eval(self.expand(self.opts["invalidcommand"], change, new, index, kind, reason))
                    except TclError as e:
                        self.app.bgerror(str(e))
                        code = "error"
                        self.opts["validate"] = "none"
            return code
        finally:
            self.validating = False

    def expand(self, script, change, new, index, kind, reason):
        out = []
        i = 0
        n = len(script)
        while i < n:
            c = script[i]
            if c != "%" or i + 1 >= n:
                out.append(c)
                i += 1
                continue
            d = script[i + 1]
            i += 2
            if d == "%":
                out.append("%")
                continue
            if d == "d":
                v = str(kind)
            elif d == "i":
                v = str(index)
            elif d == "P":
                v = new if new is not None else self.string
            elif d == "s":
                v = self.string
            elif d == "S":
                v = change if change is not None else ""
            elif d == "v":
                v = self.opts["validate"]
            elif d == "V":
                v = reason
            elif d == "W":
                v = self.path
            else:
                v = "%" + d
                out.append(v)
                continue
            out.append(bs_quote(v))
        return "".join(out)

    def on_event(self, ev):
        if ev.type == B.FocusIn or ev.type == B.FocusOut:
            if ev.detail in ("NotifyAncestor", "NotifyNonlinear", "NotifyInferior"):
                v = self.opts["validate"]
                if ev.type == B.FocusIn and v in ("focus", "focusin", "all"):
                    self.validate_change(None, self.string, -1, V_FORCED, "focusin")
                if ev.type == B.FocusOut and v in ("focus", "focusout", "all"):
                    self.validate_change(None, self.string, -1, V_FORCED, "focusout")
            self.damage()
        elif ev.type == B.DestroyNotify:
            self.deleted = True

    # ── selection ──
    def set_selection(self, a, b):
        if a > b:
            a, b = b, a
        if a == b:
            self.clear_selection()
            return
        self.sel_first = a
        self.sel_last = b
        if self.opts["exportselection"]:
            self.app.own_selection(self)
        self.damage()

    def clear_selection(self):
        if self.sel_first >= 0:
            self.sel_first = -1
            self.sel_last = -1
            self.damage()

    def selection_text(self):
        if self.sel_first < 0 or not self.opts["exportselection"]:
            return None
        return self.display_string()[self.sel_first:self.sel_last]

    def selection_lost(self):
        self.clear_selection()

    # ── widget commands ──
    def w_insert(self, args):
        if len(args) != 2:
            raise TclError("wrong # args: should be \"" + self.path + " insert index text\"")
        self.insert(self.index(args[0]), tcl_str(args[1]))
        return ""

    def w_delete(self, args):
        if len(args) < 1 or len(args) > 2:
            raise TclError("wrong # args: should be \"" + self.path + " delete firstIndex ?lastIndex?\"")
        first = self.index(args[0])
        last = self.index(args[1]) if len(args) == 2 else first + 1
        if last >= first:
            self.delete(first, last - first)
        return ""

    def w_get(self, args):
        return self.string

    def w_icursor(self, args):
        self.insert_pos = self.index(args[0])
        self.damage()
        return ""

    def w_index(self, args):
        return self.index(args[0])

    def w_bbox(self, args):
        k = self.index(args[0])
        f = self.font()
        ds = self.display_string()
        asc, desc, ls, fixed = f.metrics()
        if k >= len(ds):
            x = self.layout_x + f.measure(ds)
            w = 0
        else:
            x = self.layout_x + f.measure(ds[:k])
            w = f.measure(ds[:k + 1]) - f.measure(ds[:k])
        y = (self.height - ls) // 2
        return (x, y, w, ls)

    def w_selection(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " selection option ?index?\"")
        subs = ["adjust", "clear", "from", "present", "range", "to"]
        if self.IS_SPINBOX:
            subs = ["adjust", "clear", "element", "from", "present", "range", "to"]
        sub = match_prefix(tcl_str(args[0]), subs, "selection option")
        if sub == "clear":
            self.clear_selection()
            return ""
        if sub == "present":
            return 1 if self.sel_first >= 0 else 0
        if sub == "element":
            if len(args) > 1:
                self.sel_element = tcl_str(args[1])
                return ""
            return getattr(self, "sel_element", "none")
        if sub == "range":
            a = self.index(args[1])
            b = self.index(args[2])
            if a >= b:
                self.clear_selection()
            else:
                self.sel_anchor = a
                self.set_selection(a, b)
            return ""
        k = self.index(args[1])
        if sub == "from":
            self.sel_anchor = k
            return ""
        if sub == "to":
            if k < self.sel_anchor:
                self.set_selection(k, self.sel_anchor)
            else:
                self.set_selection(self.sel_anchor, k)
            return ""
        # adjust
        if self.sel_first >= 0:
            half = (self.sel_first + self.sel_last) // 2
            if k < half:
                self.sel_anchor = self.sel_last
            else:
                self.sel_anchor = self.sel_first
        a = min(self.sel_anchor, k)
        b = max(self.sel_anchor, k)
        self.set_selection(a, b)
        return ""

    def w_validate(self, args):
        if self.opts["validate"] == "none" or self.opts.get("validatecommand", "") == "":
            return 1
        v = self.opts["validate"]
        self.opts["validate"] = "all"
        code = self.validate_change(None, self.string, -1, V_FORCED, "forced")
        if self.opts["validate"] != "none":
            self.opts["validate"] = v
        return 1 if code == "ok" else 0

    def visible_range(self):
        n = len(self.string)
        if n == 0:
            return 0.0, 1.0
        ds = self.display_string()
        cw = self.point_to_char(ds, self.width - self.inset - self.xwidth - self.layout_x - 1)
        if cw < n:
            cw += 1
        cw -= self.left_index
        if cw == 0:
            cw = 1
        return self.left_index / float(n), (self.left_index + cw) / float(n)

    def update_scroll(self):
        f, l = self.visible_range()
        self.scroll_command("xscrollcommand", f, l)

    def w_xview(self, args):
        if not args:
            return self.visible_range()
        n = len(self.string)
        a0 = tcl_str(args[0])
        if a0 == "moveto":
            fr = get_double(args[1])
            k = int(fr * n + 0.5)
        elif a0 == "scroll":
            cnt = get_int(args[1])
            what = match_prefix(tcl_str(args[2]), ["pages", "units"], "argument")
            if what == "units":
                k = self.left_index + cnt
            else:
                ds = self.display_string()
                per = self.point_to_char(ds, self.width - self.inset - self.xwidth - self.layout_x - 1) - self.left_index
                if per < 2:
                    per = 2
                k = self.left_index + cnt * (per - 2)
        else:
            k = self.index(args[0])
        if k >= n:
            k = n - 1
        if k < 0:
            k = 0
        self.left_index = k
        self.compute_left()
        self.update_scroll()
        self.damage()
        return ""

    def w_scan(self, args):
        sub = match_prefix(tcl_str(args[0]), ["dragto", "mark"], "scan option")
        x = pixels(args[1])
        if sub == "mark":
            self.scan_mark_x = x
            self.scan_mark_index = self.left_index
            return ""
        dx = (self.scan_mark_x - x) * 10 // max(1, self.avg)
        k = self.scan_mark_index + dx
        k = max(0, min(len(self.string) - 1, k))
        self.left_index = k
        self.compute_left()
        self.update_scroll()
        self.damage()
        return ""

    # ── drawing ──
    def background_color(self):
        st = self.estate()
        if st == "disabled" and self.opts.get("disabledbackground", ""):
            return self.color("disabledbackground")
        if st == "readonly" and self.opts.get("readonlybackground", ""):
            return self.color("readonlybackground")
        return self.color("background")

    def draw(self, h, ax, ay):
        bg = self.background_color()
        fill(h, ax, ay, self.width, self.height, bg)
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        ds = self.display_string()
        ty = (self.height - ls) // 2
        st = self.estate()
        fg = self.color("disabledforeground") if (st == "disabled" and self.opts.get("disabledforeground", "")) else self.color("foreground")
        gui_push_clip(h, ax + self.inset, ay, self.width - 2 * self.inset - self.xwidth, self.height)
        if self.sel_first >= 0:
            x0 = self.layout_x + f.measure(ds[:self.sel_first])
            x1 = self.layout_x + f.measure(ds[:self.sel_last])
            fill(h, ax + x0, ay + ty, x1 - x0, ls, self.color("selectbackground"))
            draw_text(h, ds[:self.sel_first], ax + self.layout_x, ay + ty, f, fg)
            sfg = self.color("selectforeground") if self.opts.get("selectforeground", "") else fg
            draw_text(h, ds[self.sel_first:self.sel_last], ax + x0, ay + ty, f, sfg)
            draw_text(h, ds[self.sel_last:], ax + x1, ay + ty, f, fg)
        else:
            draw_text(h, ds, ax + self.layout_x, ay + ty, f, fg)
        if self.has_focus and st == "normal":
            cx = self.layout_x + f.measure(ds[:self.insert_pos])
            iw = max(1, self.px("insertwidth"))
            fill(h, ax + cx - iw // 2, ay + ty, iw, ls, self.color("insertbackground"))
        gui_pop_clip(h)
        hl = self.px("highlightthickness")
        draw_relief(h, ax + hl, ay + hl, self.width - 2 * hl, self.height - 2 * hl, self.px("borderwidth"), self.opts["relief"], bg)
        if hl > 0:
            c = self.color("highlightcolor") if self.has_focus else self.color("highlightbackground")
            draw_ring(h, ax, ay, self.width, self.height, hl, c)
        if self.IS_SPINBOX:
            self.draw_buttons(h, ax, ay)

    def on_destroy(self):
        self.deleted = True


# entry.tcl's procs

def EntryClosestGap(w, x):
    pos = w.index("@" + str(x))
    bx, by, bw, bh = w.w_bbox([pos])
    if x - bx < bw / 2.0:
        return pos
    return pos + 1


def EntryButton1(app, args):
    w = _w(app, args)
    x = get_int(args[1])
    p = _priv(app)
    p["selectMode"] = "char"
    p["mouseMoved"] = 0
    p["pressX"] = x
    w.insert_pos = min(len(w.string), EntryClosestGap(w, x))
    w.sel_anchor = w.insert_pos
    w.damage()
    if w.estate() != "disabled":
        app.set_focus(w)
    return ""


def _word_bounds(s, k):
    if k >= len(s):
        k = len(s) - 1
    if k < 0:
        return 0, 0
    def isw(c):
        return c.isalnum() or c == "_"
    a = k
    b = k
    if isw(s[k]):
        while a > 0 and isw(s[a - 1]):
            a -= 1
        while b < len(s) and isw(s[b]):
            b += 1
    else:
        b = k + 1
    return a, b


def EntryMouseSelect(app, args):
    w = _w(app, args)
    x = get_int(args[1])
    p = _priv(app)
    cur = EntryClosestGap(w, x)
    anchor = w.sel_anchor
    mode = p.get("selectMode", "char")
    if abs(p.get("pressX", x) - x) >= 3:
        p["mouseMoved"] = 1
    if mode == "char":
        if p["mouseMoved"]:
            if cur < anchor:
                w.set_selection(cur, anchor)
            else:
                w.set_selection(anchor, cur)
    elif mode == "word":
        s = w.display_string()
        a1, b1 = _word_bounds(s, min(cur, anchor))
        a2, b2 = _word_bounds(s, max(cur, anchor) - (1 if cur != anchor else 0))
        w.set_selection(min(a1, a2), max(b1, b2))
    elif mode == "line":
        w.set_selection(0, len(w.string))
    if mode != "char" or p["mouseMoved"]:
        w.insert_pos = cur
    w.damage()
    return ""


def EntrySetMode(app, args):
    _priv(app)["selectMode"] = tcl_str(args[0])
    return ""


def EntryInsert(app, args):
    w = _w(app, args)
    s = tcl_str(args[1])
    if s == "":
        return ""
    if w.sel_first >= 0 and w.sel_first <= w.insert_pos <= w.sel_last:
        w.delete(w.sel_first, w.sel_last - w.sel_first)
    w.insert(w.insert_pos, s)
    EntrySeeInsert(app, [w.path])
    return ""


def EntryBackspace(app, args):
    w = _w(app, args)
    if w.sel_first >= 0:
        w.delete(w.sel_first, w.sel_last - w.sel_first)
    else:
        x = w.insert_pos - 1
        if x >= 0:
            w.delete(x, 1)
        if w.index("@0") >= w.insert_pos:
            f, l = w.visible_range()
            w.w_xview(["moveto", f - (l - f) / 2.0])
    return ""


def EntrySeeInsert(app, args):
    w = _w(app, args)
    c = w.insert_pos
    if c < w.index("@0") or c > w.index("@" + str(w.width)):
        w.w_xview([c])
    return ""


def EntrySetCursor(app, args):
    w = _w(app, args)
    w.insert_pos = w.index(args[1]) if not isinstance(args[1], int) else max(0, min(len(w.string), args[1]))
    w.clear_selection()
    EntrySeeInsert(app, [w.path])
    w.damage()
    return ""


def EntryKeySelect(app, args):
    w = _w(app, args)
    new = w.index(args[1])
    if w.sel_first < 0:
        w.sel_anchor = w.insert_pos
        a, b = min(w.sel_anchor, new), max(w.sel_anchor, new)
        w.set_selection(a, b)
    else:
        w.w_selection(["adjust", new])
    w.insert_pos = new
    w.damage()
    return ""


def EntryPreviousWord(app, args):
    w = _w(app, args)
    s = w.string
    k = w.index(args[1]) - 1
    while k > 0 and not (s[k].isalnum() or s[k] == "_"):
        k -= 1
    while k > 0 and (s[k - 1].isalnum() or s[k - 1] == "_"):
        k -= 1
    return max(0, k)


def EntryNextWord(app, args):
    w = _w(app, args)
    s = w.string
    k = w.index(args[1])
    n = len(s)
    while k < n and (s[k].isalnum() or s[k] == "_"):
        k += 1
    while k < n and not (s[k].isalnum() or s[k] == "_"):
        k += 1
    return k


def EntryTranspose(app, args):
    w = _w(app, args)
    i = w.insert_pos
    if i < len(w.string):
        i += 1
    first = i - 2
    if first < 0:
        return ""
    data = w.string[first:i]
    new = data[1] + data[0]
    w.delete(first, 2)
    w.insert(first, new)
    w.insert_pos = i
    return ""


def EntryGetSelection(app, args):
    w = _w(app, args)
    if w.sel_first < 0:
        raise TclError("selection isn't in widget " + w.path)
    return w.display_string()[w.sel_first:w.sel_last]


def EntryCopy(app, args, cut=False):
    w = _w(app, args)
    if w.sel_first < 0 or w.opts.get("show", ""):
        return ""
    data = w.string[w.sel_first:w.sel_last]
    app.c_clipboard(["clear"])
    app.c_clipboard(["append", data])
    if cut:
        w.delete(w.sel_first, w.sel_last - w.sel_first)
    return ""


def EntryCut(app, args):
    return EntryCopy(app, args, True)


def EntryPaste(app, args):
    w = _w(app, args)
    try:
        data = app.c_clipboard(["get"])
    except TclError:
        return ""
    if C.windowing_system() != "x11" and w.sel_first >= 0:
        w.delete(w.sel_first, w.sel_last - w.sel_first)
    w.insert(w.insert_pos, data)
    EntrySeeInsert(app, [w.path])
    return ""


def EntryDeleteKey(app, args):
    w = _w(app, args)
    if w.sel_first >= 0:
        w.delete(w.sel_first, w.sel_last - w.sel_first)
    else:
        w.delete(w.insert_pos, 1)
    return ""


def EntryTraverseIn(app, args):
    w = _w(app, args)
    w.w_selection(["range", 0, "end"])
    w.insert_pos = len(w.string)
    return ""


# ── spinbox ──────────────────────────────────────────────────────────────────

SPINBOX_OPTS = sorted([o for o in ENTRY_OPTS] + [
    O("activebackground", "activeBackground", "Background", "#ececec", "color"),
    O("buttonbackground", "buttonBackground", "Background", NORMAL_BG, "color"),
    O("buttoncursor", "buttonCursor", "Cursor", "", "cursor"),
    O("buttondownrelief", "buttonDownRelief", "Relief", "raised", "relief"),
    O("buttonuprelief", "ButtonUpRelief", "Relief", "raised", "relief"),
    O("command", "command", "Command", "", "command"),
    O("format", "format", "Format", "", "string"),
    O("from", "from", "From", 0.0, "double"),
    O("increment", "increment", "Increment", 1.0, "double"),
    O("repeatdelay", "repeatDelay", "RepeatDelay", 400, "int"),
    O("repeatinterval", "repeatInterval", "RepeatInterval", 100, "int"),
    O("to", "to", "To", 0.0, "double"),
    O("values", "values", "Values", "", "list"),
    O("wrap", "wrap", "Wrap", 0, "boolean"),
], key=lambda o: o[0])


class TkSpinbox(TkEntry):
    CLASS = "Spinbox"
    OPTS = SPINBOX_OPTS
    CMDS = ["bbox", "cget", "configure", "delete", "get", "icursor", "identify", "index", "insert", "invoke",
            "scan", "selection", "set", "validate", "xview"]
    IS_SPINBOX = True
    A11Y_ROLE = "spinbutton"

    def created(self):
        vals = split_list(self.opts.get("values", ""))
        if vals:
            self.string = vals[0]
        else:
            self.string = self.fmt(self.opts["from"])
        self.reconfigured(list(self.opts.keys()))

    def fmt(self, v):
        f = self.opts.get("format", "")
        if f:
            try:
                return f % v
            except (TypeError, ValueError):
                pass
        if v == int(v) and abs(self.opts["increment"]) >= 1 and self.opts["increment"] == int(self.opts["increment"]) and self.opts["from"] == int(self.opts["from"]):
            return str(int(v))
        return repr(float(v))

    def w_identify(self, args):
        x = pixels(args[0])
        y = pixels(args[1])
        return self.identify(x, y)

    def identify(self, x, y):
        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return ""
        if x >= self.width - self.inset - self.xwidth and x < self.width - self.inset:
            return "buttonup" if y < self.height // 2 else "buttondown"
        return "entry"

    def w_invoke(self, args):
        el = match_prefix(tcl_str(args[0]), ["buttondown", "buttonup", "none"], "element")
        if el == "none":
            return ""
        self.spin(el == "buttonup")
        return ""

    def spin(self, up):
        vals = split_list(self.opts.get("values", ""))
        if self.estate() == "disabled":
            return
        if vals:
            try:
                i = vals.index(self.string)
            except ValueError:
                i = -1
            if up:
                i += 1
                if i >= len(vals):
                    i = 0 if self.opts["wrap"] else len(vals) - 1
            else:
                i -= 1
                if i < 0:
                    i = len(vals) - 1 if self.opts["wrap"] else 0
            new = vals[i]
        else:
            lo = self.opts["from"]
            hi = self.opts["to"]
            inc = self.opts["increment"]
            try:
                cur = get_double(self.string)
            except TclError:
                cur = lo
            if up:
                cur += inc
                if cur > hi:
                    cur = lo if self.opts["wrap"] else hi
            else:
                cur -= inc
                if cur < lo:
                    cur = hi if self.opts["wrap"] else lo
            if cur < lo and not self.opts["wrap"]:
                cur = lo
            new = self.fmt(cur)
        old = self.string
        self.set_value(new)
        self.value_changed()
        cmd = self.opts.get("command", "")
        if cmd:
            s = cmd.replace("%W", self.path).replace("%s", bs_quote(self.string)).replace("%d", "up" if up else "down")
            self.app.eval_bg(s)

    def w_set(self, args):
        if args:
            v = tcl_str(args[0])
            if self.estate() != "normal":
                return self.string
            self.set_value(v)
            self.value_changed()
        return self.string

    def draw_buttons(self, h, ax, ay):
        bx = self.width - self.inset - self.xwidth + XPAD
        bw = self.xwidth
        bh = (self.height - 2 * self.inset) // 2
        bg = self.color("buttonbackground")
        fg = self.color("foreground")
        for k in range(2):
            by = self.inset + k * bh
            fill(h, ax + bx, ay + by, bw - XPAD, bh, bg)
            draw_relief(h, ax + bx, ay + by, bw - XPAD, bh, 1, self.opts["buttonuprelief" if k == 0 else "buttondownrelief"], bg)
            cx = ax + bx + (bw - XPAD) / 2.0
            if k == 0:
                pts = [cx, ay + by + 2, cx - 3, ay + by + bh - 3, cx + 3, ay + by + bh - 3]
            else:
                pts = [cx - 3, ay + by + 2, cx + 3, ay + by + 2, cx, ay + by + bh - 3]
            gui_fill_polygon(h, pts, 3, (fg >> 16) & 255, (fg >> 8) & 255, fg & 255, 255)


def SpinboxButtonDown(app, args):
    w = _w(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    el = w.identify(x, y)
    p = _priv(app)
    if el in ("buttonup", "buttondown"):
        w.sel_element = el
        w.spin(el == "buttonup")
        p["spinRepeat"] = el
        return "break"
    EntryButton1(app, [w.path, x])
    w.clear_selection()
    return ""


def SpinboxButtonUp(app, args):
    _priv(app)["spinRepeat"] = None
    return ""


def SpinboxInvoke(app, args):
    w = _w(app, args)
    w.spin(tcl_str(args[1]) == "buttonup")
    return ""


# ── listbox ──────────────────────────────────────────────────────────────────

LISTBOX_OPTS = [
    O("activestyle", "activeStyle", "ActiveStyle", "dotbox", "enum:dotbox|none|underline:activestyle"),
    O("background", "background", "Background", WHITE, "color"),
    O("borderwidth", "borderWidth", "BorderWidth", 1, "pixels"),
    O("cursor", "cursor", "Cursor", "", "cursor"),
    O("disabledforeground", "disabledForeground", "DisabledForeground", DISABLED, "color_or_empty"),
    O("exportselection", "exportSelection", "ExportSelection", 1, "boolean"),
    O("font", "font", "Font", "TkDefaultFont", "font"),
    O("foreground", "foreground", "Foreground", BLACK, "color"),
    O("height", "height", "Height", 10, "int"),
    O("highlightbackground", "highlightBackground", "HighlightBackground", NORMAL_BG, "color"),
    O("highlightcolor", "highlightColor", "HighlightColor", BLACK, "color"),
    O("highlightthickness", "highlightThickness", "HighlightThickness", 1, "pixels"),
    O("justify", "justify", "Justify", "left", "justify"),
    O("listvariable", "listVariable", "Variable", "", "var"),
    O("relief", "relief", "Relief", "sunken", "relief"),
    O("selectbackground", "selectBackground", "Foreground", SELECT_BG, "color"),
    O("selectborderwidth", "selectBorderWidth", "BorderWidth", 0, "pixels"),
    O("selectforeground", "selectForeground", "Background", BLACK, "color_or_empty"),
    O("selectmode", "selectMode", "SelectMode", "browse", "string"),
    O("setgrid", "setGrid", "SetGrid", 0, "boolean"),
    O("state", "state", "State", "normal", "enum:disabled|normal:state"),
    O("takefocus", "takeFocus", "TakeFocus", "", "string"),
    O("width", "width", "Width", 20, "int"),
    O("xscrollcommand", "xScrollCommand", "ScrollCommand", "", "command"),
    O("yscrollcommand", "yScrollCommand", "ScrollCommand", "", "command"),
]

_ITEM_OPTS = ["-background", "-foreground", "-selectbackground", "-selectforeground"]


class TkListbox(TkWin):
    CLASS = "Listbox"
    OPTS = LISTBOX_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background", "fg": "foreground"}
    CMDS = ["activate", "bbox", "cget", "configure", "curselection", "delete", "get", "index", "insert",
            "itemcget", "itemconfigure", "nearest", "scan", "see", "selection", "size", "xview", "yview"]
    TAKES_FOCUS = True
    A11Y_ROLE = "listbox"

    def __init__(self, app, path, parent, wclass=None):
        TkWin.__init__(self, app, path, parent, wclass)
        self.items = []
        self.attrs = []
        self.sel = set()
        self.active = 0
        self.anchor = 0
        self.top_index = 0
        self.xoffset = 0
        self.line_h = 15
        self.inset = 0
        self.links = {}
        self.setting_var = False
        self.max_width = 0
        self.xunit = 7

    def reconfigured(self, changed):
        if "listvariable" in changed:
            old = self.links.get("listvariable")
            if old is not None:
                self.app.remove_link(old)
                del self.links["listvariable"]
            name = self.opts.get("listvariable", "")
            if name:
                if name in self.app.vars:
                    self.items = split_list(self.app.vars[name])
                    self.attrs = [None] * len(self.items)
                    self.sel = set()
                else:
                    self.app.interp.setvar(name, join_list(self.items))
                lk = self.app.add_link(name, self._listvar_changed)
                self.links["listvariable"] = lk
                self.var_links.append(lk)
        self.compute_geometry()
        self.update_scroll()
        self.damage()

    def _listvar_changed(self, name, op):
        if self.destroyed or self.setting_var:
            return
        if op == "unset":
            self.app.vars[name] = join_list(self.items)
            return
        try:
            items = split_list(self.app.vars.get(name, ""))
        except TclError:
            return
        self.items = items
        self.attrs = [None] * len(items)
        self.sel = set([i for i in self.sel if i < len(items)])
        if self.active >= len(items):
            self.active = max(0, len(items) - 1)
        self.compute_geometry()
        self.update_scroll()
        self.damage()

    def sync_var(self):
        name = self.opts.get("listvariable", "")
        if name:
            self.setting_var = True
            try:
                self.app.interp.setvar(name, tuple(self.items))
            finally:
                self.setting_var = False

    def font(self):
        return self.app.font_of(self.opts["font"])

    def compute_geometry(self):
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        sbw = self.px("selectborderwidth")
        self.line_h = ls + 1 + 2 * sbw
        self.inset = self.px("highlightthickness") + self.px("borderwidth")
        self.xunit = max(1, f.measure("0"))
        self.max_width = 0
        for it in self.items:
            w = f.measure(it)
            if w > self.max_width:
                self.max_width = w
        width = self.opts["width"]
        if width <= 0:
            width = (self.max_width + self.xunit - 1) // self.xunit
            if width < 1:
                width = 1
        pw = width * self.xunit + 2 * self.inset + 2 * sbw
        height = self.opts["height"]
        if height <= 0:
            height = len(self.items)
            if height < 1:
                height = 1
        ph = height * self.line_h + 2 * self.inset
        self.request(pw, ph)
        self.set_internal_border(self.inset)

    def full_lines(self):
        return max(0, (self.height - 2 * self.inset) // max(1, self.line_h))

    def on_resize(self):
        self.update_scroll()

    def index(self, s, end_ok=True):
        n = len(self.items)
        if isinstance(s, int) and not isinstance(s, bool):
            return s
        s = tcl_str(s)
        if s == "active":
            return self.active
        if s == "anchor":
            return self.anchor
        if s == "end":
            return n
        if s.startswith("@"):
            try:
                xs, ys = s[1:].split(",")
                y = pixels(ys)
            except (ValueError, TclError):
                raise TclError("bad listbox index \"" + s + "\": must be active, anchor, end, @x,y, or a number")
            return self.nearest(y)
        try:
            return get_int(s)
        except TclError:
            raise TclError("bad listbox index \"" + s + "\": must be active, anchor, end, @x,y, or a number")

    def nearest(self, y):
        n = len(self.items)
        if n == 0:
            return 0
        # NearestListboxElement: C's truncating division, clamped to the lines shown
        lh = max(1, self.line_h)
        d = y - self.inset
        k = d // lh if d >= 0 else -((-d) // lh)
        avail = self.height - 2 * self.inset
        shown = avail // lh + (1 if avail % lh else 0)
        if k >= shown:
            k = shown - 1
        if k < 0:
            k = 0
        k += self.top_index
        return max(0, min(n - 1, k))

    def w_insert(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " insert index ?element ...?\"")
        if self.opts["state"] == "disabled":
            return ""
        k = self.index(args[0])
        n = len(self.items)
        k = max(0, min(n, k))
        new = [tcl_str(a) for a in args[1:]]
        cnt = len(new)
        self.items[k:k] = new
        self.attrs[k:k] = [None] * cnt
        self.sel = set([(i + cnt if i >= k else i) for i in self.sel])
        if self.active >= k and n > 0:
            self.active += cnt
        if self.anchor >= k and n > 0:
            self.anchor += cnt
        if self.top_index > k:
            self.top_index += cnt
        self.sync_var()
        self.compute_geometry()
        self.update_scroll()
        self.damage()
        return ""

    def w_delete(self, args):
        if self.opts["state"] == "disabled":
            return ""
        n = len(self.items)
        a = self.index(args[0])
        b = self.index(args[1]) if len(args) > 1 else a
        if a < 0:
            a = 0
        if b >= n:
            b = n - 1
        if b < a or a >= n:
            return ""
        cnt = b - a + 1
        del self.items[a:b + 1]
        del self.attrs[a:b + 1]
        ns = set()
        for i in self.sel:
            if i < a:
                ns.add(i)
            elif i > b:
                ns.add(i - cnt)
        self.sel = ns
        if self.active > b:
            self.active -= cnt
        elif self.active >= a:
            self.active = a
        if self.active >= len(self.items):
            self.active = max(0, len(self.items) - 1)
        if self.top_index > b:
            self.top_index -= cnt
        elif self.top_index >= a:
            self.top_index = a
        self.top_index = max(0, min(self.top_index, max(0, len(self.items) - self.full_lines())))
        self.sync_var()
        self.compute_geometry()
        self.update_scroll()
        self.damage()
        return ""

    def w_get(self, args):
        n = len(self.items)
        a = self.index(args[0])
        if len(args) == 1:
            if 0 <= a < n:
                return self.items[a]
            return ""
        b = self.index(args[1])
        if a < 0:
            a = 0
        if b >= n:
            b = n - 1
        return tuple(self.items[a:b + 1])

    def w_size(self, args):
        return len(self.items)

    def w_index(self, args):
        return self.index(args[0])

    def w_curselection(self, args):
        return tuple(sorted(self.sel))

    def w_activate(self, args):
        k = self.index(args[0])
        n = len(self.items)
        if k >= n:
            k = n - 1
        if k < 0:
            k = 0
        self.active = k
        self.damage()
        return ""

    def w_nearest(self, args):
        return self.nearest(pixels(args[0]))

    def w_see(self, args):
        k = self.index(args[0])
        n = len(self.items)
        if k >= n:
            k = n - 1
        if k < 0:
            k = 0
        fl = self.full_lines()
        diff = self.top_index - k
        if diff > 0:
            if diff <= fl // 3:
                self.change_view(k)
            else:
                self.change_view(k - (fl - 1) // 2)
        else:
            diff = k - (self.top_index + fl - 1)
            if diff > 0:
                if diff <= fl // 3:
                    self.change_view(self.top_index + diff)
                else:
                    self.change_view(k - (fl - 1) // 2)
        return ""

    def change_view(self, k):
        n = len(self.items)
        fl = self.full_lines()
        if k >= n - fl:
            k = n - fl
        if k < 0:
            k = 0
        if k != self.top_index:
            self.top_index = k
            self.update_scroll()
            self.damage()

    def w_bbox(self, args):
        k = self.index(args[0])
        if k < self.top_index or k >= len(self.items) or k >= self.top_index + self.full_lines() + 1:
            return ""
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        y = self.inset + (k - self.top_index) * self.line_h + self.px("selectborderwidth")
        x = self.inset + self.px("selectborderwidth") - self.xoffset
        return (x, y, f.measure(self.items[k]), ls)

    def w_selection(self, args):
        sub = match_prefix(tcl_str(args[0]), ["anchor", "clear", "includes", "set"], "option")
        n = len(self.items)
        if sub == "anchor":
            k = self.index(args[1])
            self.anchor = max(0, min(n - 1, k)) if n else 0
            return ""
        if sub == "includes":
            return 1 if self.index(args[1]) in self.sel else 0
        a = self.index(args[1])
        b = self.index(args[2]) if len(args) > 2 else a
        if a > b:
            a, b = b, a
        a = max(0, a)
        b = min(n - 1, b)
        if self.opts["state"] == "disabled":
            return ""
        if sub == "set":
            for i in range(a, b + 1):
                self.sel.add(i)
            if self.sel and self.opts["exportselection"]:
                self.app.own_selection(self)
        else:
            for i in range(a, b + 1):
                self.sel.discard(i)
        self.damage()
        return ""

    def selection_text(self):
        if not self.sel or not self.opts["exportselection"]:
            return None
        return "\n".join([self.items[i] for i in sorted(self.sel) if i < len(self.items)])

    def selection_lost(self):
        if self.opts["exportselection"] and self.sel:
            self.sel = set()
            self.damage()
            self.app.event_generate([self.path, "<<ListboxSelect>>"])

    def w_itemcget(self, args):
        k = self.index(args[0])
        if k < 0 or k >= len(self.items):
            raise TclError("item number \"" + tcl_str(args[0]) + "\" out of range")
        o = match_prefix(tcl_str(args[1]), _ITEM_OPTS, "option")
        a = self.attrs[k] or {}
        return a.get(o, "")

    def w_itemconfigure(self, args):
        k = self.index(args[0])
        if k < 0 or k >= len(self.items):
            raise TclError("item number \"" + tcl_str(args[0]) + "\" out of range")
        a = self.attrs[k]
        if a is None:
            a = {}
            self.attrs[k] = a
        if len(args) == 1:
            return tuple([(o, o[1:], o[1:].capitalize(), "", a.get(o, "")) for o in _ITEM_OPTS])
        if len(args) == 2:
            o = match_prefix(tcl_str(args[1]), _ITEM_OPTS, "option")
            return (o, o[1:], o[1:].capitalize(), "", a.get(o, ""))
        for i in range(1, len(args) - 1, 2):
            o = match_prefix(tcl_str(args[i]), _ITEM_OPTS, "option")
            v = tcl_str(args[i + 1])
            if v != "":
                parse_color(v)
            a[o] = v
        self.damage()
        return ""

    def view_fractions(self, vertical):
        n = len(self.items)
        if vertical:
            if n == 0:
                return 0.0, 1.0
            fl = self.full_lines()
            f = self.top_index / float(n)
            l = (self.top_index + fl) / float(n)
            return f, min(1.0, l)
        total = self.max_width + 2 * self.px("selectborderwidth")
        win = self.width - 2 * self.inset
        if total <= 0 or win >= total:
            return 0.0, 1.0
        return self.xoffset / float(total), min(1.0, (self.xoffset + win) / float(total))

    def update_scroll(self):
        f, l = self.view_fractions(True)
        self.scroll_command("yscrollcommand", f, l)
        f, l = self.view_fractions(False)
        self.scroll_command("xscrollcommand", f, l)

    def w_yview(self, args):
        if not args:
            return self.view_fractions(True)
        n = len(self.items)
        a0 = tcl_str(args[0])
        if a0 == "moveto":
            k = int(get_double(args[1]) * n + 0.5)
        elif a0 == "scroll":
            cnt = get_int(args[1])
            what = match_prefix(tcl_str(args[2]), ["pages", "units"], "argument")
            if what == "units":
                k = self.top_index + cnt
            else:
                fl = self.full_lines()
                k = self.top_index + cnt * max(1, fl - 2)
        else:
            k = self.index(args[0])
        self.change_view(k)
        return ""

    def w_xview(self, args):
        if not args:
            return self.view_fractions(False)
        total = self.max_width + 2 * self.px("selectborderwidth")
        win = self.width - 2 * self.inset
        a0 = tcl_str(args[0])
        if a0 == "moveto":
            off = int(get_double(args[1]) * total + 0.5)
        elif a0 == "scroll":
            cnt = get_int(args[1])
            what = match_prefix(tcl_str(args[2]), ["pages", "units"], "argument")
            if what == "units":
                off = self.xoffset + cnt * self.xunit
            else:
                off = self.xoffset + cnt * max(self.xunit, win - 2 * self.xunit)
        else:
            off = get_int(args[0]) * self.xunit
        off = max(0, min(off, max(0, total - win)))
        self.xoffset = off
        self.update_scroll()
        self.damage()
        return ""

    def w_scan(self, args):
        sub = match_prefix(tcl_str(args[0]), ["dragto", "mark"], "scan option")
        x = pixels(args[1])
        y = pixels(args[2])
        if sub == "mark":
            self.scan_mark = (x, y, self.xoffset, self.top_index)
            return ""
        mx, my, xo, ti = getattr(self, "scan_mark", (x, y, self.xoffset, self.top_index))
        self.change_view(ti - (y - my) * 10 // max(1, self.line_h))
        return ""

    def draw(self, h, ax, ay):
        bg = self.color("background")
        fill(h, ax, ay, self.width, self.height, bg)
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        fg = self.color("disabledforeground") if self.opts["state"] == "disabled" and self.opts.get("disabledforeground") else self.color("foreground")
        sbw = self.px("selectborderwidth")
        gui_push_clip(h, ax + self.inset, ay + self.inset, self.width - 2 * self.inset, self.height - 2 * self.inset)
        y = self.inset
        k = self.top_index
        while k < len(self.items) and y < self.height - self.inset:
            a = self.attrs[k] or {}
            ibg = parse_color(a["-background"]) if a.get("-background") else None
            if k in self.sel:
                sb = parse_color(a["-selectbackground"]) if a.get("-selectbackground") else self.color("selectbackground")
                fill(h, ax + self.inset, ay + y, self.width - 2 * self.inset, self.line_h, sb)
                ifg = parse_color(a["-selectforeground"]) if a.get("-selectforeground") else (self.color("selectforeground") if self.opts.get("selectforeground") else fg)
            else:
                if ibg is not None:
                    fill(h, ax + self.inset, ay + y, self.width - 2 * self.inset, self.line_h, ibg)
                ifg = parse_color(a["-foreground"]) if a.get("-foreground") else fg
            s = self.items[k]
            tw = f.measure(s)
            j = self.opts["justify"]
            if j == "left":
                tx = self.inset + sbw - self.xoffset
            elif j == "right":
                tx = self.width - self.inset - sbw - tw - self.xoffset
            else:
                tx = (self.width - tw) // 2 - self.xoffset
            draw_text(h, s, ax + tx, ay + y + sbw, f, ifg)
            if k == self.active and self.has_focus and self.opts["state"] != "disabled":
                st = self.opts["activestyle"]
                if st == "underline":
                    fill(h, ax + tx, ay + y + sbw + asc + 1, tw, 1, ifg)
                elif st == "dotbox":
                    gui_draw_rect(h, ax + self.inset, ay + y, self.width - 2 * self.inset, self.line_h, 0, 0, 0, 255, 1)
            y += self.line_h
            k += 1
        gui_pop_clip(h)
        hl = self.px("highlightthickness")
        draw_relief(h, ax + hl, ay + hl, self.width - 2 * hl, self.height - 2 * hl, self.px("borderwidth"), self.opts["relief"], bg)
        if hl > 0:
            c = self.color("highlightcolor") if self.has_focus else self.color("highlightbackground")
            draw_ring(h, ax, ay, self.width, self.height, hl, c)


# listbox.tcl's procs

def _fire_select(app, w):
    if not w.destroyed and w.opts["state"] != "disabled":
        app.event_generate([w.path, "<<ListboxSelect>>"])


def ListboxBeginSelect(app, args):
    w = _w(app, args)
    el = w.index(args[1])
    focus = get_boolean(args[2]) if len(args) > 2 else True
    p = _priv(app)
    mode = w.opts["selectmode"]
    if mode == "multiple":
        if el in w.sel:
            w.w_selection(["clear", el])
        else:
            w.w_selection(["set", el])
    else:
        w.w_selection(["clear", 0, "end"])
        w.w_selection(["set", el])
        w.w_selection(["anchor", el])
        p["listboxSelection"] = []
        p["listboxPrev"] = el
    _fire_select(app, w)
    if focus and w.opts["state"] == "normal" and (w.opts.get("takefocus") != "0"):
        app.set_focus(w)
    return ""


def ListboxMotion(app, args):
    w = _w(app, args)
    el = w.index(args[1])
    p = _priv(app)
    if el == p.get("listboxPrev"):
        return ""
    anchor = w.anchor
    mode = w.opts["selectmode"]
    if mode == "browse":
        w.w_selection(["clear", 0, "end"])
        w.w_selection(["set", el])
        p["listboxPrev"] = el
        _fire_select(app, w)
    elif mode == "extended":
        i = p.get("listboxPrev")
        if i is None or i == "":
            i = el
            w.w_selection(["set", el])
        if anchor in w.sel:
            w.w_selection(["clear", i, el])
            w.w_selection(["set", anchor, el])
        else:
            w.w_selection(["clear", i, el])
            w.w_selection(["clear", anchor, el])
        sel = p.get("listboxSelection", [])
        while i < el and i < anchor:
            if i in sel:
                w.w_selection(["set", i])
            i += 1
        while i > el and i > anchor:
            if i in sel:
                w.w_selection(["set", i])
            i -= 1
        p["listboxPrev"] = el
        _fire_select(app, w)
    return ""


def ListboxBeginExtend(app, args):
    w = _w(app, args)
    el = w.index(args[1])
    if w.opts["selectmode"] == "extended":
        if w.anchor in w.sel:
            ListboxMotion(app, [w.path, el])
        else:
            ListboxBeginSelect(app, [w.path, el])
    return ""


def ListboxBeginToggle(app, args):
    w = _w(app, args)
    el = w.index(args[1])
    p = _priv(app)
    if w.opts["selectmode"] == "extended":
        p["listboxSelection"] = sorted(w.sel)
        p["listboxPrev"] = el
        w.w_selection(["anchor", el])
        if el in w.sel:
            w.w_selection(["clear", el])
        else:
            w.w_selection(["set", el])
        _fire_select(app, w)
    return ""


def ListboxUpDown(app, args):
    w = _w(app, args)
    amount = get_int(args[1])
    w.w_activate([w.active + amount])
    w.w_see(["active"])
    mode = w.opts["selectmode"]
    if mode == "browse":
        w.w_selection(["clear", 0, "end"])
        w.w_selection(["set", "active"])
        _fire_select(app, w)
    elif mode == "extended":
        w.w_selection(["clear", 0, "end"])
        w.w_selection(["set", "active"])
        w.w_selection(["anchor", "active"])
        p = _priv(app)
        p["listboxPrev"] = w.active
        p["listboxSelection"] = []
        _fire_select(app, w)
    return ""


def ListboxExtendUpDown(app, args):
    w = _w(app, args)
    amount = get_int(args[1])
    if w.opts["selectmode"] != "extended":
        return ""
    w.w_activate([w.active + amount])
    w.w_see(["active"])
    ListboxMotion(app, [w.path, w.active])
    return ""


def ListboxSelectAll(app, args):
    w = _w(app, args)
    mode = w.opts["selectmode"]
    if mode in ("single", "browse"):
        w.w_selection(["clear", 0, "end"])
        w.w_selection(["set", "active"])
    else:
        w.w_selection(["set", 0, "end"])
    _fire_select(app, w)
    return ""


def ListboxCancel(app, args):
    w = _w(app, args)
    if w.opts["selectmode"] != "extended":
        return ""
    p = _priv(app)
    first = w.anchor
    last = p.get("listboxPrev", first)
    if last is None or last == "":
        return ""
    if first > last:
        first, last = last, first
    w.w_selection(["clear", first, last])
    sel = p.get("listboxSelection", [])
    for i in range(first, last + 1):
        if i in sel:
            w.w_selection(["set", i])
    _fire_select(app, w)
    return ""


def ListboxButtonRelease(app, args):
    w = _w(app, args)
    w.w_activate(["@" + tcl_str(args[1]) + "," + tcl_str(args[2])])
    return ""


C.WIDGET_TYPES["entry"] = TkEntry
C.WIDGET_TYPES["spinbox"] = TkSpinbox
C.WIDGET_TYPES["listbox"] = TkListbox

for _name, _f in (("tk::EntryButton1", EntryButton1), ("tk::EntryMouseSelect", EntryMouseSelect),
                  ("tk::EntrySetMode", EntrySetMode), ("tk::EntryInsert", EntryInsert),
                  ("tk::EntryBackspace", EntryBackspace), ("tk::EntrySeeInsert", EntrySeeInsert),
                  ("tk::EntrySetCursor", EntrySetCursor), ("tk::EntryKeySelect", EntryKeySelect),
                  ("tk::EntryPreviousWord", EntryPreviousWord), ("tk::EntryNextWord", EntryNextWord),
                  ("tk::EntryTranspose", EntryTranspose), ("tk::EntryGetSelection", EntryGetSelection),
                  ("tk::EntryCopy", EntryCopy), ("tk::EntryCut", EntryCut), ("tk::EntryPaste", EntryPaste),
                  ("tk::EntryDeleteKey", EntryDeleteKey), ("tk::EntryTraverseIn", EntryTraverseIn),
                  ("tk::SpinboxButtonDown", SpinboxButtonDown), ("tk::SpinboxButtonUp", SpinboxButtonUp),
                  ("tk::SpinboxInvoke", SpinboxInvoke),
                  ("tk::ListboxBeginSelect", ListboxBeginSelect), ("tk::ListboxMotion", ListboxMotion),
                  ("tk::ListboxBeginExtend", ListboxBeginExtend), ("tk::ListboxBeginToggle", ListboxBeginToggle),
                  ("tk::ListboxUpDown", ListboxUpDown), ("tk::ListboxExtendUpDown", ListboxExtendUpDown),
                  ("tk::ListboxSelectAll", ListboxSelectAll), ("tk::ListboxCancel", ListboxCancel),
                  ("tk::ListboxButtonRelease", ListboxButtonRelease)):
    C.TK_COMMANDS[_name] = _f


def _entry_bindings(app, cls):
    b = app.bindings
    b.set(cls, "<<Cut>>", "tk::EntryCut %W")
    b.set(cls, "<<Copy>>", "tk::EntryCopy %W")
    b.set(cls, "<<Paste>>", "tk::EntryPaste %W")
    b.set(cls, "<<Clear>>", "catch {%W delete sel.first sel.last}")
    b.set(cls, "<<TraverseIn>>", "tk::EntryTraverseIn %W")
    b.set(cls, "<1>", "tk::EntryButton1 %W %x; %W selection clear")
    b.set(cls, "<B1-Motion>", "tk::EntryMouseSelect %W %x")
    b.set(cls, "<Double-1>", "tk::EntrySetMode word; tk::EntryMouseSelect %W %x; catch {%W icursor sel.last}")
    b.set(cls, "<Triple-1>", "tk::EntrySetMode line; tk::EntryMouseSelect %W %x; catch {%W icursor sel.last}")
    b.set(cls, "<Shift-1>", "tk::EntrySetMode char; %W selection adjust @%x")
    b.set(cls, "<Control-1>", "%W icursor @%x")
    b.set(cls, "<<PrevChar>>", "tk::EntrySetCursor %W [expr {[%W index insert] - 1}]")
    b.set(cls, "<<NextChar>>", "tk::EntrySetCursor %W [expr {[%W index insert] + 1}]")
    b.set(cls, "<<SelectPrevChar>>", "tk::EntryKeySelect %W [expr {[%W index insert] - 1}]; tk::EntrySeeInsert %W")
    b.set(cls, "<<SelectNextChar>>", "tk::EntryKeySelect %W [expr {[%W index insert] + 1}]; tk::EntrySeeInsert %W")
    b.set(cls, "<<PrevWord>>", "tk::EntrySetCursor %W [tk::EntryPreviousWord %W insert]")
    b.set(cls, "<<NextWord>>", "tk::EntrySetCursor %W [tk::EntryNextWord %W insert]")
    b.set(cls, "<<SelectPrevWord>>", "tk::EntryKeySelect %W [tk::EntryPreviousWord %W insert]; tk::EntrySeeInsert %W")
    b.set(cls, "<<SelectNextWord>>", "tk::EntryKeySelect %W [tk::EntryNextWord %W insert]; tk::EntrySeeInsert %W")
    b.set(cls, "<<LineStart>>", "tk::EntrySetCursor %W 0")
    b.set(cls, "<<SelectLineStart>>", "tk::EntryKeySelect %W 0; tk::EntrySeeInsert %W")
    b.set(cls, "<<LineEnd>>", "tk::EntrySetCursor %W end")
    b.set(cls, "<<SelectLineEnd>>", "tk::EntryKeySelect %W end; tk::EntrySeeInsert %W")
    b.set(cls, "<Delete>", "tk::EntryDeleteKey %W")
    b.set(cls, "<BackSpace>", "tk::EntryBackspace %W")
    b.set(cls, "<Control-space>", "%W selection from insert")
    b.set(cls, "<Select>", "%W selection from insert")
    b.set(cls, "<Control-Shift-space>", "%W selection adjust insert")
    b.set(cls, "<<SelectAll>>", "%W selection range 0 end")
    b.set(cls, "<<SelectNone>>", "%W selection clear")
    b.set(cls, "<KeyPress>", "tk::EntryInsert %W %A")
    b.set(cls, "<Alt-KeyPress>", "# nothing")
    b.set(cls, "<Meta-KeyPress>", "# nothing")
    b.set(cls, "<Control-KeyPress>", "# nothing")
    b.set(cls, "<Escape>", "# nothing")
    b.set(cls, "<Return>", "# nothing")
    b.set(cls, "<KP_Enter>", "# nothing")
    b.set(cls, "<Tab>", "# nothing")
    b.set(cls, "<Prior>", "# nothing")
    b.set(cls, "<Next>", "# nothing")
    b.set(cls, "<<NextLine>>", "# nothing")
    b.set(cls, "<<PrevLine>>", "# nothing")
    b.set(cls, "<Control-d>", "%W delete insert")
    b.set(cls, "<Control-h>", "tk::EntryBackspace %W")
    b.set(cls, "<Control-k>", "%W delete insert end")
    b.set(cls, "<Control-t>", "tk::EntryTranspose %W")


def _listbox_bindings(app):
    b = app.bindings
    L = "Listbox"
    b.set(L, "<1>", "if {[winfo exists %W]} {tk::ListboxBeginSelect %W [%W index @%x,%y] 1}")
    b.set(L, "<Double-1>", "# Empty script")
    b.set(L, "<B1-Motion>", "tk::ListboxMotion %W [%W index @%x,%y]")
    b.set(L, "<ButtonRelease-1>", "tk::ListboxButtonRelease %W %x %y")
    b.set(L, "<Shift-1>", "tk::ListboxBeginExtend %W [%W index @%x,%y]")
    b.set(L, "<Control-1>", "tk::ListboxBeginToggle %W [%W index @%x,%y]")
    b.set(L, "<<PrevLine>>", "tk::ListboxUpDown %W -1")
    b.set(L, "<<SelectPrevLine>>", "tk::ListboxExtendUpDown %W -1")
    b.set(L, "<<NextLine>>", "tk::ListboxUpDown %W 1")
    b.set(L, "<<SelectNextLine>>", "tk::ListboxExtendUpDown %W 1")
    b.set(L, "<<PrevChar>>", "%W xview scroll -1 units")
    b.set(L, "<<NextChar>>", "%W xview scroll 1 units")
    b.set(L, "<<PrevWord>>", "%W xview scroll -1 pages")
    b.set(L, "<<NextWord>>", "%W xview scroll 1 pages")
    b.set(L, "<Prior>", "%W yview scroll -1 pages; %W activate @0,0")
    b.set(L, "<Next>", "%W yview scroll 1 pages; %W activate @0,0")
    b.set(L, "<<LineStart>>", "%W xview moveto 0")
    b.set(L, "<<LineEnd>>", "%W xview moveto 1")
    b.set(L, "<space>", "tk::ListboxBeginSelect %W [%W index active]")
    b.set(L, "<Select>", "tk::ListboxBeginSelect %W [%W index active]")
    b.set(L, "<Escape>", "tk::ListboxCancel %W")
    b.set(L, "<<SelectAll>>", "tk::ListboxSelectAll %W")
    b.set(L, "<2>", "%W scan mark %x %y")
    b.set(L, "<B2-Motion>", "%W scan dragto %x %y")
    b.set(L, "<MouseWheel>", "%W yview scroll [expr {- (%D / 120) * 4}] units")
    b.set(L, "<4>", "%W yview scroll -5 units")
    b.set(L, "<5>", "%W yview scroll 5 units")


def _bindings(app):
    _entry_bindings(app, "Entry")
    _entry_bindings(app, "Spinbox")
    b = app.bindings
    b.set("Spinbox", "<1>", "tk::SpinboxButtonDown %W %x %y")
    b.set("Spinbox", "<ButtonRelease-1>", "tk::SpinboxButtonUp %W")
    b.set("Spinbox", "<<PrevLine>>", "tk::SpinboxInvoke %W buttonup")
    b.set("Spinbox", "<<NextLine>>", "tk::SpinboxInvoke %W buttondown")
    _listbox_bindings(app)


C.APP_INIT.append(_bindings)
