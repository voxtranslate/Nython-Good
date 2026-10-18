# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/menu.ny - menu and menubutton (round 84), after tkMenu.c,
# tkMenubutton.c and Tk's menu.tcl.
#
# menu        entries command/cascade/checkbutton/radiobutton/separator and
#             the tearoff entry (index 0 when -tearoff is on, as in Tk);
#             add/insert/delete/entrycget/entryconfigure/index (number,
#             active, end, last, none, @x,y, a label pattern)/invoke/type/
#             activate/post/unpost/xposition/yposition; checkbutton entries'
#             -variable defaults to the label and radiobuttons' to
#             selectedButton, as in Tk; -postcommand; accelerators shown.
#             A menu set as a toplevel's -menu is that toplevel's menubar,
#             drawn above its client area (as on X11, where winfo height of
#             the toplevel does not include it).  Posted menus (cascades,
#             post, tk_popup) are drawn over their toplevel and take the
#             pointer and keyboard until unposted (Tk's menu grab): Up/Down
#             move, Return invokes, Escape and a click outside unpost.
# menubutton  a label-like button that posts its -menu (-direction below/
#             above/left/right/flush), the option-menu indicator
#
# Not provided: tear-off windows (invoking the tearoff entry does nothing),
# -columnbreak (entries stay in one column), menus as separate native
# windows (posted menus never extend past their toplevel's window).

from _tkinter.tcl import TclError, tcl_str, split_list, join_list, get_int, get_double, get_boolean, match_prefix, or_list
from _tkinter.util import pixels, parse_color, cdiv, shades, fill, line, text as draw_text, draw_relief, draw_ring, layout_text
from _tkinter.win import TkWin, _norm
from _tkinter import core as C
from _tkinter import bind as B
from _tkinter.widgets import (O, NORMAL_BG, ACTIVE_BG, DISABLED, BLACK, WHITE, _priv, _w, TkLabel, LABEL_OPTS,
                              _replace, TYPE_LABEL, draw_tree)

MENU_OPTS = [
    O("activebackground", "activeBackground", "Foreground", ACTIVE_BG, "color"),
    O("activeborderwidth", "activeBorderWidth", "BorderWidth", 1, "pixels"),
    O("activeforeground", "activeForeground", "Background", BLACK, "color"),
    O("activerelief", "activeRelief", "Relief", "raised", "relief"),
    O("background", "background", "Background", NORMAL_BG, "color"),
    O("borderwidth", "borderWidth", "BorderWidth", 1, "pixels"),
    O("cursor", "cursor", "Cursor", "arrow", "cursor"),
    O("disabledforeground", "disabledForeground", "DisabledForeground", DISABLED, "color_or_empty"),
    O("font", "font", "Font", "TkMenuFont", "font"),
    O("foreground", "foreground", "Foreground", BLACK, "color"),
    O("postcommand", "postCommand", "Command", "", "command"),
    O("relief", "relief", "Relief", "raised", "relief"),
    O("selectcolor", "selectColor", "Background", BLACK, "color_or_empty"),
    O("takefocus", "takeFocus", "TakeFocus", "0", "string"),
    O("tearoff", "tearOff", "TearOff", 1, "boolean"),
    O("tearoffcommand", "tearOffCommand", "TearOffCommand", "", "command"),
    O("title", "title", "Title", "", "string"),
    O("type", "type", "Type", "normal", "enum:menubar|normal|tearoff:menu type"),
]

ENTRY_OPTS = {
    "activebackground": "color_or_empty", "activeforeground": "color_or_empty", "accelerator": "string",
    "background": "color_or_empty", "bitmap": "string", "columnbreak": "boolean", "command": "command",
    "compound": "enum:bottom|center|left|none|right|top:compound", "font": "font_or_empty",
    "foreground": "color_or_empty", "hidemargin": "boolean", "image": "image", "indicatoron": "boolean",
    "label": "string", "menu": "string", "offvalue": "string", "onvalue": "string",
    "selectcolor": "color_or_empty", "selectimage": "image", "state": "enum:active|normal|disabled:state",
    "underline": "int", "value": "string", "variable": "var",
}
TYPE_OPTS = {
    "command": ["activebackground", "activeforeground", "accelerator", "background", "bitmap", "columnbreak",
                "command", "compound", "font", "foreground", "hidemargin", "image", "label", "state", "underline"],
    "cascade": ["activebackground", "activeforeground", "accelerator", "background", "bitmap", "columnbreak",
                "command", "compound", "font", "foreground", "hidemargin", "image", "label", "menu", "state",
                "underline"],
    "checkbutton": ["activebackground", "activeforeground", "accelerator", "background", "bitmap",
                    "columnbreak", "command", "compound", "font", "foreground", "hidemargin", "image",
                    "indicatoron", "label", "offvalue", "onvalue", "selectcolor", "selectimage", "state",
                    "underline", "variable"],
    "radiobutton": ["activebackground", "activeforeground", "accelerator", "background", "bitmap",
                    "columnbreak", "command", "compound", "font", "foreground", "hidemargin", "image",
                    "indicatoron", "label", "selectcolor", "selectimage", "state", "underline", "value",
                    "variable"],
    "separator": ["background", "columnbreak", "hidemargin"],
    "tearoff": ["background", "state"],
}
ENTRY_DEFAULTS = {"state": "normal", "underline": -1, "indicatoron": 1, "onvalue": "1", "offvalue": "0",
                  "columnbreak": 0, "hidemargin": 0, "compound": "none"}


class MenuEntry:
    def __init__(self, kind):
        self.kind = kind
        self.opts = {}
        for k in TYPE_OPTS[kind]:
            self.opts[k] = ENTRY_DEFAULTS.get(k, "")
        self.x = 0
        self.y = 0
        self.w = 0
        self.h = 0
        self.link = None
        self.selected = False


class TkMenu(TkWin):
    CLASS = "Menu"
    OPTS = MENU_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background", "fg": "foreground"}
    CMDS = ["activate", "add", "cget", "clone", "configure", "delete", "entrycget", "entryconfigure", "index",
            "insert", "invoke", "post", "postcascade", "type", "unpost", "xposition", "yposition"]
    IS_TOPLEVEL = True
    IS_MENU = True
    A11Y_ROLE = "menu"

    def __init__(self, app, path, parent, wclass=None):
        TkWin.__init__(self, app, path, parent, wclass)
        self.entries = []
        self.active = -1
        self.host = None          # toplevel this menu is posted over
        self.as_menubar = None    # toplevel whose menubar this is
        self.posted_cascade = None
        self.parent_menu = None
        self.wm = C.WmInfo()
        self.mb_height = 0

    def created(self):
        if self.opts["tearoff"] and self.opts["type"] != "menubar":
            self.entries.append(MenuEntry("tearoff"))
        self.reconfigured(list(self.opts.keys()))

    def reconfigured(self, changed):
        self.compute_geometry()
        self.damage()

    def damage(self):
        for top in (self.host, self.as_menubar):
            if top is not None and not top.destroyed:
                self.app.damage(top)

    def font(self, e=None):
        if e is not None and e.opts.get("font"):
            return self.app.font_of(e.opts["font"])
        return self.app.font_of(self.opts["font"])

    def abs_xy(self):
        top = self.host
        if top is None:
            return (self.x, self.y)
        return (self.x, self.y + top.menubar_height())

    def root_xy(self):
        top = self.host
        if top is None:
            return (self.x, self.y)
        return (top.x + self.x, top.y + top.menubar_height() + self.y)

    # ── entries ──
    def entry_index(self, s, insert=False):
        n = len(self.entries)
        if isinstance(s, int) and not isinstance(s, bool):
            k = s
            if k >= n:
                k = n - 1 if not insert else n
            return k
        s = tcl_str(s)
        if s == "active":
            return self.active if self.active >= 0 else None
        if s == "end" or s == "last":
            return (n - 1 if n > 0 else None) if not insert else n
        if s == "none":
            return None
        if s.startswith("@"):
            body = s[1:]
            if "," in body:
                xs, ys = body.split(",", 1)
                x = pixels(xs)
                y = pixels(ys)
            else:
                x = 0
                y = pixels(body)
            for i in range(n):
                e = self.entries[i]
                if self.is_menubar():
                    if e.x <= x < e.x + e.w:
                        return i
                elif e.y <= y < e.y + e.h:
                    return i
            return None
        try:
            k = get_int(s)
            if k >= n:
                k = n - 1 if not insert else n
            if k < 0:
                k = 0
            return k
        except TclError:
            pass
        import fnmatch
        for i in range(n):
            lab = self.entries[i].opts.get("label", "")
            if lab != "" and fnmatch.fnmatchcase(lab, s):
                return i
        raise TclError("bad menu entry index \"" + s + "\"")

    def is_menubar(self):
        return self.as_menubar is not None or self.opts["type"] == "menubar"

    def _configure_entry(self, e, args, creating=False):
        if len(args) % 2 != 0:
            raise TclError("value for \"" + tcl_str(args[-1]) + "\" missing")
        allowed = TYPE_OPTS[e.kind]
        for i in range(0, len(args), 2):
            k = tcl_str(args[i])
            if not k.startswith("-"):
                raise TclError("unknown option \"" + k + "\"")
            name = k[1:]
            if name not in allowed:
                found = [a for a in allowed if a.startswith(name)]
                if len(found) == 1:
                    name = found[0]
                else:
                    raise TclError("unknown option \"" + k + "\"")
            kind = ENTRY_OPTS[name]
            v = args[i + 1]
            if kind == "font_or_empty":
                v = tcl_str(v) if not isinstance(v, (tuple, list)) else join_list(v)
                if v != "":
                    self.app.font_of(v)
            elif kind == "image":
                v = tcl_str(v)
            else:
                v = _norm(self.app, kind, v, name)
            e.opts[name] = v
        if e.kind == "checkbutton" and e.opts.get("variable", "") == "":
            e.opts["variable"] = e.opts.get("label", "")
        if e.kind == "radiobutton":
            if e.opts.get("variable", "") == "":
                e.opts["variable"] = "selectedButton"
            if e.opts.get("value", "") == "" and creating:
                e.opts["value"] = e.opts.get("label", "")
        if e.kind in ("checkbutton", "radiobutton"):
            self._link_entry(e)

    def _link_entry(self, e):
        if e.link is not None:
            self.app.remove_link(e.link)
            if e.link in self.var_links:
                self.var_links.remove(e.link)
            e.link = None
        name = e.opts.get("variable", "")
        if not name:
            return
        menu = self

        def changed(n, op):
            if op == "unset":
                return
            menu._sync_entry(e)
            menu.damage()

        e.link = self.app.add_link(name, changed)
        self.var_links.append(e.link)
        self._sync_entry(e)

    def _sync_entry(self, e):
        name = e.opts.get("variable", "")
        v = self.app.vars.get(name)
        if v is None:
            e.selected = False
            return
        on = e.opts["onvalue"] if e.kind == "checkbutton" else e.opts["value"]
        e.selected = tcl_str(v) == on

    def w_add(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " add type ?options?\"")
        return self._insert(len(self.entries), args)

    def w_insert(self, args):
        if len(args) < 2:
            raise TclError("wrong # args: should be \"" + self.path + " insert index type ?options?\"")
        k = self.entry_index(args[0], True)
        if k is None:
            k = len(self.entries)
        if self.opts["tearoff"] and k == 0 and self.entries and self.entries[0].kind == "tearoff":
            k = 1
        return self._insert(k, args[1:])

    def _insert(self, k, args):
        kind = tcl_str(args[0])
        try:
            kind = match_prefix(kind, ["cascade", "checkbutton", "command", "radiobutton", "separator"], "menu entry type")
        except TclError:
            raise TclError("bad menu entry type \"" + kind + "\": must be cascade, checkbutton, command, radiobutton, or separator")
        e = MenuEntry(kind)
        self._configure_entry(e, list(args[1:]), True)
        self.entries.insert(k, e)
        if self.active >= k:
            self.active += 1
        self.compute_geometry()
        self.damage()
        if self.as_menubar is not None:
            self.app.relayout()
        return ""

    def w_delete(self, args):
        a = self.entry_index(args[0])
        b = self.entry_index(args[1]) if len(args) > 1 and args[1] is not None else a
        if a is None or b is None:
            return ""
        if b < a:
            return ""
        for e in self.entries[a:b + 1]:
            if e.link is not None:
                self.app.remove_link(e.link)
        del self.entries[a:b + 1]
        if self.active > b:
            self.active -= (b - a + 1)
        elif self.active >= a:
            self.active = -1
        self.compute_geometry()
        self.damage()
        if self.as_menubar is not None:
            self.app.relayout()
        return ""

    def w_entrycget(self, args):
        k = self.entry_index(args[0])
        if k is None:
            raise TclError("bad menu entry index \"" + tcl_str(args[0]) + "\"")
        e = self.entries[k]
        o = tcl_str(args[1])
        name = o[1:] if o.startswith("-") else o
        if name not in e.opts:
            raise TclError("unknown option \"" + o + "\"")
        return e.opts[name]

    def w_entryconfigure(self, args):
        k = self.entry_index(args[0])
        if k is None:
            if len(args) == 1:
                return ""
            raise TclError("bad menu entry index \"" + tcl_str(args[0]) + "\"")
        e = self.entries[k]
        if len(args) == 1:
            out = []
            for name in TYPE_OPTS[e.kind]:
                out.append(("-" + name, "", "", ENTRY_DEFAULTS.get(name, ""), e.opts.get(name, "")))
            return tuple(out)
        if len(args) == 2:
            name = tcl_str(args[1])[1:]
            if name not in e.opts:
                raise TclError("unknown option \"" + tcl_str(args[1]) + "\"")
            return ("-" + name, "", "", ENTRY_DEFAULTS.get(name, ""), e.opts[name])
        self._configure_entry(e, list(args[1:]))
        self.compute_geometry()
        self.damage()
        return ""

    def w_index(self, args):
        k = self.entry_index(args[0])
        return "none" if k is None else k

    def w_type(self, args):
        k = self.entry_index(args[0])
        if k is None:
            return ""
        return self.entries[k].kind

    def w_activate(self, args):
        k = self.entry_index(args[0])
        if k is None or self.entries[k].kind in ("separator",) or self.entries[k].opts.get("state") == "disabled":
            self.active = -1
        else:
            self.active = k
        self.damage()
        return ""

    def w_invoke(self, args):
        k = self.entry_index(args[0])
        if k is None:
            return ""
        return self.invoke(k)

    def invoke(self, k):
        e = self.entries[k]
        if e.opts.get("state") == "disabled":
            return ""
        if e.kind == "tearoff":
            cmd = self.opts.get("tearoffcommand", "")
            if cmd:
                self.app.eval_bg(cmd + " " + self.path + " " + self.path)
            return ""
        if e.kind == "checkbutton":
            name = e.opts["variable"]
            self.app.interp.setvar(name, e.opts["offvalue"] if e.selected else e.opts["onvalue"])
        elif e.kind == "radiobutton":
            self.app.interp.setvar(e.opts["variable"], e.opts["value"])
        cmd = e.opts.get("command", "")
        if cmd and e.kind != "separator":
            return self.app.interp.eval(cmd)
        return ""

    def w_xposition(self, args):
        k = self.entry_index(args[0])
        if k is None:
            return 0
        return self.entries[k].x

    def w_yposition(self, args):
        k = self.entry_index(args[0])
        if k is None:
            return 0
        return self.entries[k].y

    def w_clone(self, args):
        return ""

    def w_post(self, args):
        x = pixels(args[0])
        y = pixels(args[1])
        self.post(x, y, args[2] if len(args) > 2 else None)
        return ""

    def w_postcascade(self, args):
        k = self.entry_index(args[0])
        if k is None:
            self.unpost_cascade()
            return ""
        self.post_cascade(k)
        return ""

    def w_unpost(self, args):
        self.unpost()
        return ""

    # ── geometry ──
    def compute_geometry(self):
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        abw = self.px("activeborderwidth")
        bw = self.px("borderwidth")
        if self.is_menubar():
            x = bw
            h = ls + 2 * abw + 4
            for e in self.entries:
                if e.kind in ("separator", "tearoff"):
                    e.x = x
                    e.y = bw
                    e.w = 0
                    e.h = h
                    continue
                lw = self.font(e).measure(e.opts.get("label", ""))
                e.x = x
                e.y = bw
                e.w = lw + 2 * abw + 10
                e.h = h
                x += e.w
            self.mb_height = h + 2 * bw
            self.request(max(1, x + bw), self.mb_height)
            return
        ind = ls
        maxl = 0
        maxa = 0
        for e in self.entries:
            if e.kind in ("separator", "tearoff"):
                continue
            ef = self.font(e)
            maxl = max(maxl, ef.measure(e.opts.get("label", "")))
            acc = e.opts.get("accelerator", "")
            if acc:
                maxa = max(maxa, ef.measure(acc))
            if e.kind == "cascade":
                maxa = max(maxa, ls)
        width = bw + abw + ind + maxl + (ls + maxa if maxa else 0) + ls // 2 + abw + bw
        y = bw
        for e in self.entries:
            if e.kind == "separator":
                eh = max(4, ls // 2)
            elif e.kind == "tearoff":
                eh = 8
            else:
                eh = ls + 2 * abw + 2
            e.x = bw
            e.y = y
            e.w = width - 2 * bw
            e.h = eh
            y += eh
        self.indicator = ind
        self.accel_x = bw + abw + ind + maxl + ls
        self.request(width, y + bw)

    def menubar_height_px(self):
        if self.mb_height == 0:
            self.compute_geometry()
        return self.mb_height

    # ── posting ──
    def host_for(self, rx, ry):
        # the mapped toplevel under root position (rx, ry), else our parent's
        for t in reversed(self.app.toplevels):
            if t.mapped and t.x <= rx < t.x + t.width and t.y <= ry < t.y + t.height + t.menubar_height():
                return t
        p = self.parent
        while p is not None and not (p.IS_TOPLEVEL and not getattr(p, "IS_MENU", False)):
            p = p.parent
        return p if p is not None else self.app.root

    def post(self, rx, ry, entry=None, host=None):
        pc = self.opts.get("postcommand", "")
        if pc:
            self.app.eval_bg(pc)
        self.compute_geometry()
        top = host if host is not None else self.host_for(rx, ry)
        if top is None:
            return
        self.host = top
        self.width = self.reqw
        self.height = self.reqh
        x = rx - top.x
        y = ry - top.y - top.menubar_height()
        # keep it inside the host window
        if x + self.width > top.width:
            x = max(0, top.width - self.width)
        if y + self.height > top.height:
            y = max(-top.menubar_height(), top.height - self.height)
        self.x = x
        self.y = y
        if self not in top.overlays:
            top.overlays.append(self)
        self.active = -1
        if entry is not None and tcl_str(entry) != "":
            k = self.entry_index(entry)
            if k is not None:
                self.active = k
        self.app.set_mapped(self, True)
        self.app.damage(top)

    def unpost(self):
        self.unpost_cascade()
        top = self.host
        if top is not None and self in top.overlays:
            top.overlays.remove(self)
            self.app.damage(top)
        if self.mapped:
            self.app.set_mapped(self, False)
        self.active = -1
        self.host = None
        if self.app.grab is self:
            self.app.grab = None
        ob = getattr(self, "owner_button", None)
        if ob is not None:
            self.owner_button = None
            if not ob.destroyed and ob.opts.get("relief") == "sunken":
                ob.opts["relief"] = "raised"
                ob.damage()

    def unpost_all(self):
        m = self
        while m.parent_menu is not None:
            m = m.parent_menu
        m.unpost_cascade()
        if m.as_menubar is not None:
            m.active = -1
            m.damage()
        else:
            m.unpost()

    def post_cascade(self, k):
        e = self.entries[k]
        if e.kind != "cascade":
            return
        name = e.opts.get("menu", "")
        sub = self.app.widgets.get(name) if name else None
        if sub is None:
            return
        if self.posted_cascade is sub:
            return
        self.unpost_cascade()
        sub.parent_menu = self
        if self.as_menubar is not None:
            top = self.as_menubar
            rx = top.x + e.x
            ry = top.y + self.mb_height
            sub.post(rx, ry, None, top)
        else:
            rx, ry = self.root_xy()
            sub.post(rx + self.width, ry + e.y, None, self.host)
        self.posted_cascade = sub

    def unpost_cascade(self):
        sub = self.posted_cascade
        if sub is not None:
            self.posted_cascade = None
            sub.unpost()
            sub.parent_menu = None

    # ── overlay protocol (TkToplevel) ──
    def overlay_hit(self, x, y):
        return self

    def overlay_outside(self):
        return self

    def overlay_key(self, ks, down, state):
        if not down:
            return True
        m = self
        while m.posted_cascade is not None and m.posted_cascade.mapped:
            m = m.posted_cascade
        if ks == "Escape":
            if m.parent_menu is not None and m.parent_menu.as_menubar is None:
                m.parent_menu.unpost_cascade()
            else:
                m.unpost_all()
            return True
        if ks in ("Down", "Up"):
            n = len(m.entries)
            if n == 0:
                return True
            k = m.active
            for step in range(n):
                k = (k + (1 if ks == "Down" else -1)) % n
                e = m.entries[k]
                if e.kind not in ("separator", "tearoff") and e.opts.get("state") != "disabled":
                    break
            m.active = k
            m.damage()
            return True
        if ks == "Right":
            if m.active >= 0 and m.entries[m.active].kind == "cascade":
                m.post_cascade(m.active)
            return True
        if ks == "Left":
            if m.parent_menu is not None and m.parent_menu.as_menubar is None:
                m.parent_menu.unpost_cascade()
            return True
        if ks in ("Return", "space", "KP_Enter"):
            if m.active >= 0:
                e = m.entries[m.active]
                if e.kind == "cascade":
                    m.post_cascade(m.active)
                else:
                    k = m.active
                    m.unpost_all()
                    m.invoke(k)
            return True
        return True

    def entry_at(self, x, y):
        for i in range(len(self.entries)):
            e = self.entries[i]
            if e.y <= y < e.y + e.h and 0 <= x < self.width:
                return i
        return -1

    # ── menubar input from the toplevel ──
    def menubar_input(self, top, kind, x, y, button, state):
        k = -1
        for i in range(len(self.entries)):
            e = self.entries[i]
            if e.x <= x < e.x + e.w and 0 <= y < self.mb_height:
                k = i
        if kind == "leave":
            if self.posted_cascade is None:
                self.active = -1
                self.damage()
            return
        if kind == "motion":
            if self.posted_cascade is not None and k >= 0 and k != self.active:
                self.active = k
                if self.entries[k].kind == "cascade":
                    self.post_cascade(k)
                else:
                    self.unpost_cascade()
                self.damage()
            elif self.posted_cascade is None and k != self.active:
                self.active = k
                self.damage()
            return
        if kind == "down" and button == 1:
            if k < 0:
                self.unpost_cascade()
                self.active = -1
                self.damage()
                return
            e = self.entries[k]
            if e.kind == "cascade":
                if self.posted_cascade is not None and self.active == k:
                    self.unpost_cascade()
                else:
                    self.active = k
                    self.post_cascade(k)
            else:
                self.unpost_cascade()
                self.active = -1
                self.invoke(k)
            self.damage()

    # ── drawing ──
    def draw_menubar(self, h, width, mh):
        bg = self.color("background")
        fill(h, 0, 0, width, mh, bg)
        draw_relief(h, 0, 0, width, mh, self.px("borderwidth"), self.opts["relief"], bg)
        for i in range(len(self.entries)):
            e = self.entries[i]
            if e.kind in ("separator", "tearoff"):
                continue
            self._draw_entry_label(h, e, i, e.x, e.y, e.w, e.h, True)

    def draw(self, h, ax, ay):
        bg = self.color("background")
        fill(h, ax, ay, self.width, self.height, bg)
        draw_relief(h, ax, ay, self.width, self.height, self.px("borderwidth"), self.opts["relief"], bg)
        for i in range(len(self.entries)):
            e = self.entries[i]
            if e.kind == "separator":
                light, dark = shades(bg)
                my = ay + e.y + e.h // 2
                fill(h, ax + e.x + 2, my - 1, e.w - 4, 1, dark)
                fill(h, ax + e.x + 2, my, e.w - 4, 1, light)
            elif e.kind == "tearoff":
                fg = self.color("foreground")
                xx = ax + e.x + 2
                while xx < ax + e.x + e.w - 2:
                    fill(h, xx, ay + e.y + e.h // 2, 4, 1, fg)
                    xx += 8
            else:
                self._draw_entry_label(h, e, i, ax + e.x, ay + e.y, e.w, e.h, False)

    def _draw_entry_label(self, h, e, i, x, y, w, hh, menubar):
        st = e.opts.get("state", "normal")
        active = (i == self.active) and st != "disabled"
        if active:
            ab = parse_color(e.opts["activebackground"]) if e.opts.get("activebackground") else self.color("activebackground")
            fill(h, x, y, w, hh, ab)
            draw_relief(h, x, y, w, hh, self.px("activeborderwidth"), self.opts["activerelief"], ab)
            fg = parse_color(e.opts["activeforeground"]) if e.opts.get("activeforeground") else self.color("activeforeground")
        else:
            if e.opts.get("background"):
                fill(h, x, y, w, hh, parse_color(e.opts["background"]))
            fg = parse_color(e.opts["foreground"]) if e.opts.get("foreground") else self.color("foreground")
        if st == "disabled" and self.opts.get("disabledforeground"):
            fg = self.color("disabledforeground")
        f = self.font(e)
        asc, desc, ls, fixed = f.metrics()
        ty = y + (hh - ls) // 2
        lab = e.opts.get("label", "")
        if menubar:
            draw_text(h, lab, x + 5 + self.px("activeborderwidth"), ty, f, fg)
            return
        lx = x + self.px("activeborderwidth") + self.indicator
        draw_text(h, lab, lx, ty, f, fg)
        ul = e.opts.get("underline", -1)
        if isinstance(ul, int) and 0 <= ul < len(lab):
            c0 = f.measure(lab[:ul])
            c1 = f.measure(lab[:ul + 1])
            fill(h, lx + c0, ty + asc + 1, c1 - c0, 1, fg)
        acc = e.opts.get("accelerator", "")
        if acc:
            draw_text(h, acc, self.x * 0 + x - self.px("borderwidth") + self.accel_x, ty, f, fg)
        if e.kind == "cascade":
            cx = x + w - ls // 2 - 4
            cy = y + hh / 2.0
            gui_fill_polygon(h, [cx - 3, cy - 4, cx + 2, cy, cx - 3, cy + 4], 3, (fg >> 16) & 255, (fg >> 8) & 255, fg & 255, 255)
        if e.kind in ("checkbutton", "radiobutton") and e.selected and e.opts.get("indicatoron", 1):
            sc = parse_color(e.opts["selectcolor"]) if e.opts.get("selectcolor") else (self.color("selectcolor") or fg)
            d = max(4, ls // 2)
            ix = x + self.px("activeborderwidth") + (self.indicator - d) // 2
            iy = y + (hh - d) // 2
            if e.kind == "checkbutton":
                line(h, ix, iy + d // 2, ix + d // 2 - 1, iy + d - 1, sc, 2)
                line(h, ix + d // 2 - 1, iy + d - 1, ix + d, iy, sc, 2)
            else:
                r = d / 2.0
                gui_fill_circle(h, ix + r, iy + r, r, (sc >> 16) & 255, (sc >> 8) & 255, sc & 255, 255)

    def a11y_states(self):
        return ["expanded"] if self.mapped else []

    def on_destroy(self):
        self.unpost()
        if self.as_menubar is not None:
            self.as_menubar.menubar = None
            self.app.relayout()


# menu.tcl, reduced to what the overlay menus need

def MenuMotion(app, args):
    m = _w(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    inside = 0 <= x < m.width and 0 <= y < m.height
    if not inside:
        return ""
    k = m.entry_at(x, y)
    if k != m.active:
        if k >= 0 and (m.entries[k].kind in ("separator", "tearoff") or m.entries[k].opts.get("state") == "disabled"):
            k = -1
        m.active = k
        if k >= 0 and m.entries[k].kind == "cascade":
            m.post_cascade(k)
        elif m.posted_cascade is not None:
            m.unpost_cascade()
        m.damage()
    return ""


def MenuButtonDown(app, args):
    m = _w(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    if not (0 <= x < m.width and 0 <= y < m.height):
        # a click outside the posted menus unposts them
        p = m
        while p is not None:
            px, py = p.root_xy()
            rx = x + m.root_xy()[0]
            ry = y + m.root_xy()[1]
            if px <= rx < px + p.width and py <= ry < py + p.height:
                return ""
            p = p.parent_menu
        m.unpost_all()
        app.button_grab = None
        return ""
    MenuMotion(app, args)
    return ""


def MenuInvoke(app, args):
    m = _w(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    if not (0 <= x < m.width and 0 <= y < m.height):
        return ""
    k = m.entry_at(x, y)
    if k < 0:
        return ""
    e = m.entries[k]
    if e.kind == "cascade":
        m.post_cascade(k)
        return ""
    if e.kind == "separator" or e.opts.get("state") == "disabled":
        return ""
    m.unpost_all()
    app.update(True)
    m.invoke(k)
    return ""


def MenuLeave(app, args):
    m = _w(app, args)
    if m.posted_cascade is None:
        m.active = -1
        m.damage()
    return ""


# ── menubutton ───────────────────────────────────────────────────────────────

MENUBUTTON_OPTS = _replace(LABEL_OPTS, {
    "padx": O("padx", "padX", "Pad", "4p", "pixels"),
    "pady": O("pady", "padY", "Pad", "3p", "pixels"),
    "takefocus": O("takefocus", "takeFocus", "TakeFocus", "0", "string"),
}, [
    O("direction", "direction", "Direction", "below", "enum:above|below|flush|left|right:direction"),
    O("indicatoron", "indicatorOn", "IndicatorOn", 0, "boolean"),
    O("menu", "menu", "Menu", "", "string"),
])


class TkMenubutton(TkLabel):
    CLASS = "Menubutton"
    OPTS = MENUBUTTON_OPTS
    CMDS = ["cget", "configure"]
    TYPE = TYPE_LABEL
    TAKES_FOCUS = True
    A11Y_ROLE = "button"

    def compute_geometry(self):
        TkLabel.compute_geometry(self)
        if self.opts.get("indicatoron", 0):
            from _tkinter.util import SCREEN
            mm = SCREEN.dpi / 25.4
            self.ind_h = int(17 * mm / 10)
            self.ind_w = int(40 * mm / 10) + 2 * self.ind_h
            self.request(self.reqw + self.ind_w, self.reqh)
        else:
            self.ind_w = 0
            self.ind_h = 0

    def draw(self, h, ax, ay):
        TkLabel.draw(self, h, ax, ay)
        if self.ind_w > 0:
            bg = self.color("background")
            x = ax + self.width - self.inset - self.ind_w + self.ind_h
            y = ay + (self.height - self.ind_h) // 2
            fill(h, x, y, self.ind_w - 2 * self.ind_h, self.ind_h, bg)
            draw_relief(h, x, y, self.ind_w - 2 * self.ind_h, self.ind_h, 2, "raised", bg)

    def post_menu(self):
        name = self.opts.get("menu", "")
        if not name or self.opts["state"] == "disabled":
            return
        m = self.app.widgets.get(name)
        if m is None:
            return
        rx, ry = self.root_xy()
        d = self.opts["direction"]
        m.compute_geometry()
        if d == "below":
            m.post(rx, ry + self.height)
        elif d == "above":
            m.post(rx, ry - m.reqh)
        elif d == "left":
            m.post(rx - m.reqw, ry)
        elif d == "right":
            m.post(rx + self.width, ry)
        else:
            m.post(rx, ry)
        m.owner_button = self
        self.app.grab = m
        self.app.button_grab = m
        self.opts["relief"] = "sunken" if self.opts["relief"] == "raised" else self.opts["relief"]
        self.damage()


def MbPost(app, args):
    w = _w(app, args)
    w.post_menu()
    return ""


C.WIDGET_TYPES["menu"] = TkMenu
C.WIDGET_TYPES["menubutton"] = TkMenubutton
for _name, _f in (("tk::MenuMotion", MenuMotion), ("tk::MenuButtonDown", MenuButtonDown),
                  ("tk::MenuInvoke", MenuInvoke), ("tk::MenuLeave", MenuLeave), ("tk::MbPost", MbPost)):
    C.TK_COMMANDS[_name] = _f


def _bindings(app):
    b = app.bindings
    b.set("Menu", "<Motion>", "tk::MenuMotion %W %x %y")
    b.set("Menu", "<B1-Motion>", "tk::MenuMotion %W %x %y")
    b.set("Menu", "<ButtonPress>", "tk::MenuButtonDown %W %x %y")
    b.set("Menu", "<ButtonRelease>", "tk::MenuInvoke %W %x %y")
    b.set("Menu", "<Leave>", "tk::MenuLeave %W")
    b.set("Menubutton", "<1>", "tk::MbPost %W")
    b.set("Menubutton", "<space>", "tk::MbPost %W")
    b.set("Menubutton", "<Enter>", "tk::ButtonEnter %W")
    b.set("Menubutton", "<Leave>", "tk::ButtonLeave %W")


C.APP_INIT.append(_bindings)
