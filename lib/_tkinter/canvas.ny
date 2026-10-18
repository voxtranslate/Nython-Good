# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/canvas.ny - the canvas widget (round 84), after tkCanvas.c,
# tkCanvLine.c, tkRectOval.c, tkCanvPoly.c, tkCanvArc.c, tkCanvText.c,
# tkCanvWind.c, tkCanvImg.c, tkCanvUtil.c and tkCanvPs.c.
#
# items       arc, bitmap, image, line, oval, polygon, rectangle, text, window,
#             with Tk 8.6's options (active*/disabled* variants, -state,
#             -tags, dash patterns ". - , _" or lists, arrows with
#             -arrowshape, -smooth splines with -splinesteps after
#             TkMakeBezierCurve, -capstyle/-joinstyle, arc -style
#             pieslice/chord/arc with -start/-extent counterclockwise)
# ids & tags  ids from 1; tag expressions with && || ^ ! and parentheses;
#             "all", "current"; addtag/dtag/gettags/find above|all|below|
#             closest|enclosed|overlapping|withtag; raise/lower; delete
# geometry    coords (Tk's coordinate-count errors), move, moveto, scale,
#             bbox with Tk's rounding (a 10,10,50,50 rectangle is 9 9 51 51),
#             find_closest by distance (halo, start), find_overlapping and
#             find_enclosed by item area tests
# view        canvasx/canvasy, -scrollregion, -confine, xview/yview (moveto,
#             scroll units by -x/yscrollincrement or a tenth of the window,
#             pages) reporting fractions as Tk does (%g), scan mark/dragto
# bindings    bind on tags/ids: the current item (topmost under the pointer,
#             -closeenough) gets Enter/Leave, button, motion and key events,
#             tags searched as Tk does ("all", the tags, the item)
# text items  insert/dchars/icursor/index/select/focus, -width wrapping,
#             -justify, -anchor, -angle (kept, drawn unrotated)
# postscript  real PostScript (EPSF-3.0) of the items: paths for lines,
#             polygons, rectangles, ovals and arcs, setrgbcolor/setlinewidth/
#             setdash, text in its font family; -file, -x/-y/-width/-height,
#             -pagewidth/-pageheight, -pagex/-pagey/-pageanchor, -rotate,
#             -colormode color/gray/mono
#
# Not provided: stipples (accepted, drawn solid), -angle rotation of text,
# window items' -create, bitmap items beyond Tk's built-in bitmap names.

import math
import re
from _tkinter.tcl import TclError, tcl_str, tcl_float, split_list, join_list, get_int, get_double, get_boolean, match_prefix, or_list
from _tkinter.util import pixels, fpixels, parse_color, cdiv, cround, shades, fill, line, text as draw_text, draw_relief, draw_ring, layout_text, comps, SCREEN
from _tkinter.win import TkWin, _norm
from _tkinter.bind import BindingTable
from _tkinter import core as C
from _tkinter import bind as B
from _tkinter.widgets import O, NORMAL_BG, SELECT_BG, BLACK, WHITE, _priv, _w

CANVAS_OPTS = [
    O("background", "background", "Background", NORMAL_BG, "color"),
    O("borderwidth", "borderWidth", "BorderWidth", 0, "pixels"),
    O("closeenough", "closeEnough", "CloseEnough", 1.0, "double"),
    O("confine", "confine", "Confine", 1, "boolean"),
    O("cursor", "cursor", "Cursor", "", "cursor"),
    O("height", "height", "Height", "7c", "pixels"),
    O("highlightbackground", "highlightBackground", "HighlightBackground", NORMAL_BG, "color"),
    O("highlightcolor", "highlightColor", "HighlightColor", BLACK, "color"),
    O("highlightthickness", "highlightThickness", "HighlightThickness", 1, "pixels"),
    O("insertbackground", "insertBackground", "Foreground", BLACK, "color"),
    O("insertborderwidth", "insertBorderWidth", "BorderWidth", 0, "pixels"),
    O("insertofftime", "insertOffTime", "OffTime", 300, "int"),
    O("insertontime", "insertOnTime", "OnTime", 600, "int"),
    O("insertwidth", "insertWidth", "InsertWidth", 2, "pixels"),
    O("offset", "offset", "Offset", "0,0", "string"),
    O("relief", "relief", "Relief", "flat", "relief"),
    O("scrollregion", "scrollRegion", "ScrollRegion", "", "list"),
    O("selectbackground", "selectBackground", "Foreground", SELECT_BG, "color"),
    O("selectborderwidth", "selectBorderWidth", "BorderWidth", 1, "pixels"),
    O("selectforeground", "selectForeground", "Background", BLACK, "color_or_empty"),
    O("state", "state", "State", "normal", "enum:disabled|hidden|normal:state"),
    O("takefocus", "takeFocus", "TakeFocus", "", "string"),
    O("width", "width", "Width", "10c", "pixels"),
    O("xscrollcommand", "xScrollCommand", "ScrollCommand", "", "command"),
    O("xscrollincrement", "xScrollIncrement", "ScrollIncrement", 0, "pixels"),
    O("yscrollcommand", "yScrollCommand", "ScrollCommand", "", "command"),
    O("yscrollincrement", "yScrollIncrement", "ScrollIncrement", 0, "pixels"),
]

_COMMON = [("state", "", "istate"), ("tags", "", "tags")]
_OUTLINE = [("activedash", "", "dash"), ("activefill", "", "color_or_empty"), ("activeoutline", "", "color_or_empty"),
            ("activeoutlinestipple", "", "string"), ("activestipple", "", "string"), ("activewidth", 0.0, "dist"),
            ("dash", "", "dash"), ("dashoffset", 0, "pixels"), ("disableddash", "", "dash"),
            ("disabledfill", "", "color_or_empty"), ("disabledoutline", "", "color_or_empty"),
            ("disabledoutlinestipple", "", "string"), ("disabledstipple", "", "string"),
            ("disabledwidth", 0.0, "dist"), ("fill", "", "color_or_empty"), ("offset", "0,0", "string"),
            ("outline", "black", "color_or_empty"), ("outlineoffset", "0,0", "string"),
            ("outlinestipple", "", "string"), ("stipple", "", "string"), ("width", 1.0, "dist")]

ITEM_SPECS = {
    "rectangle": _OUTLINE + _COMMON,
    "oval": _OUTLINE + _COMMON,
    "arc": _OUTLINE + _COMMON + [("extent", 90.0, "double"), ("start", 0.0, "double"),
                                 ("style", "pieslice", "enum:pieslice|chord|arc:style")],
    "polygon": [o for o in _OUTLINE if o[0] not in ("fill", "outline")] + _COMMON + [
        ("fill", "black", "color_or_empty"), ("outline", "", "color_or_empty"),
        ("joinstyle", "round", "enum:bevel|miter|round:joinstyle"), ("smooth", "0", "smooth"),
        ("splinesteps", 12, "int")],
    "line": [("activedash", "", "dash"), ("activefill", "", "color_or_empty"), ("activestipple", "", "string"),
             ("activewidth", 0.0, "dist"), ("arrow", "none", "enum:both|first|last|none:arrow"),
             ("arrowshape", "8 10 3", "arrowshape"), ("capstyle", "butt", "enum:butt|projecting|round:cap style"),
             ("dash", "", "dash"), ("dashoffset", 0, "pixels"), ("disableddash", "", "dash"),
             ("disabledfill", "", "color_or_empty"), ("disabledstipple", "", "string"),
             ("disabledwidth", 0.0, "dist"), ("fill", "black", "color_or_empty"),
             ("joinstyle", "round", "enum:bevel|miter|round:join style"), ("offset", "0,0", "string"),
             ("smooth", "0", "smooth"), ("splinesteps", 12, "int"), ("stipple", "", "string"),
             ("width", 1.0, "dist")] + _COMMON,
    "text": [("activefill", "", "color_or_empty"), ("activestipple", "", "string"),
             ("anchor", "center", "anchor"), ("angle", 0.0, "double"), ("disabledfill", "", "color_or_empty"),
             ("disabledstipple", "", "string"), ("fill", "black", "color_or_empty"),
             ("font", "TkDefaultFont", "font"), ("justify", "left", "justify"), ("offset", "0,0", "string"),
             ("stipple", "", "string"), ("text", "", "string"), ("underline", -1, "int"),
             ("width", 0, "pixels")] + _COMMON,
    "window": [("anchor", "center", "anchor"), ("height", 0, "pixels"), ("width", 0, "pixels"),
               ("window", "", "string")] + _COMMON,
    "image": [("activeimage", "", "image"), ("anchor", "center", "anchor"), ("disabledimage", "", "image"),
              ("image", "", "image")] + _COMMON,
    "bitmap": [("activebackground", "", "color_or_empty"), ("activebitmap", "", "string"),
               ("activeforeground", "", "color_or_empty"), ("anchor", "center", "anchor"),
               ("background", "", "color_or_empty"), ("bitmap", "", "string"),
               ("disabledbackground", "", "color_or_empty"), ("disabledbitmap", "", "string"),
               ("disabledforeground", "", "color_or_empty"), ("foreground", "black", "color")] + _COMMON,
}
for _k in ITEM_SPECS:
    ITEM_SPECS[_k] = sorted(ITEM_SPECS[_k], key=lambda o: o[0])

NCOORDS = {"rectangle": 4, "oval": 4, "arc": 4, "text": 2, "window": 2, "image": 2, "bitmap": 2}


def parse_dash(v, width):
    # Tk_GetDash / DashConvert -> list of ints (on, off, ...), [] for none
    if isinstance(v, (tuple, list)):
        items = [tcl_str(x) for x in v]
    else:
        s = tcl_str(v)
        if s == "":
            return []
        if s[0] in "._-, ":
            out = []
            w = max(1, int(width + 0.5))
            for c in s:
                if c == " ":
                    if out:
                        out[-1] += w
                    continue
                size = {"_": 8, "-": 6, ",": 4, ".": 2}.get(c)
                if size is None:
                    raise TclError("bad dash list \"" + s + "\": must be a list of integers or a format like \"-..\"")
                out.append(size * w)
                out.append(4 * w)
            return out
        items = split_list(s)
    out = []
    for it in items:
        try:
            n = get_int(it)
        except TclError:
            raise TclError("expected integer in the range 1..255 but got \"" + it + "\"")
        if n < 1 or n > 255:
            raise TclError("expected integer in the range 1..255 but got \"" + it + "\"")
        out.append(n)
    return out


class Item:
    def __init__(self, ident, kind):
        self.id = ident
        self.kind = kind
        self.coords = []
        self.opts = {}
        self.tags = []
        for name, default, k in ITEM_SPECS[kind]:
            self.opts[name] = default
        self.bbox = None
        self.text_layout = None
        self.icursor = 0
        self.win = None


class TkCanvas(TkWin):
    CLASS = "Canvas"
    OPTS = CANVAS_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background"}
    CMDS = ["addtag", "bbox", "bind", "canvasx", "canvasy", "cget", "configure", "coords", "create", "dchars",
            "delete", "dtag", "find", "focus", "gettags", "icursor", "imove", "index", "insert", "itemcget",
            "itemconfigure", "lower", "move", "moveto", "postscript", "raise", "rchars", "scale", "scan",
            "select", "type", "xview", "yview"]
    A11Y_ROLE = "img"

    def __init__(self, app, path, parent, wclass=None):
        TkWin.__init__(self, app, path, parent, wclass)
        self.items = {}
        self.order = []
        self.next_id = 1
        self.xorigin = 0
        self.yorigin = 0
        self.inset = 0
        self.item_bindings = BindingTable()
        self.current = None
        self.focus_item = None
        self.sel_item = None
        self.sel_first = -1
        self.sel_last = -1
        self.sel_anchor = 0
        self.scan_mark = (0, 0, 0, 0)

    # ── configuration ──
    def reconfigured(self, changed):
        self.inset = self.px("borderwidth") + self.px("highlightthickness")
        if "scrollregion" in changed:
            sr = split_list(self.opts.get("scrollregion", ""))
            if sr and len(sr) != 4:
                raise TclError("bad scrollRegion \"" + self.opts["scrollregion"] + "\"")
            for v in sr:
                fpixels(v)
        self.compute_geometry()
        self.set_origin(self.xorigin, self.yorigin)
        self.damage()

    def validate_options(self, changed):
        if "scrollregion" in changed:
            sr = split_list(self.opts.get("scrollregion", ""))
            if sr and len(sr) != 4:
                raise TclError("bad scrollRegion \"" + self.opts["scrollregion"] + "\"")
            for v in sr:
                try:
                    fpixels(v)
                except TclError:
                    raise TclError("bad scrollRegion \"" + self.opts["scrollregion"] + "\"")

    def compute_geometry(self):
        self.inset = self.px("borderwidth") + self.px("highlightthickness")
        self.request(self.px("width") + 2 * self.inset, self.px("height") + 2 * self.inset)
        self.set_internal_border(self.inset)

    def on_resize(self):
        self.set_origin(self.xorigin, self.yorigin)

    def scroll_region(self):
        sr = split_list(self.opts.get("scrollregion", ""))
        if len(sr) == 4:
            return [pixels(v) for v in sr]
        return None

    def set_origin(self, xo, yo):
        # CanvasSetOrigin
        xi = self.px("xscrollincrement")
        yi = self.px("yscrollincrement")
        sr = self.scroll_region()
        x1, y1, x2, y2 = sr if sr is not None else (0, 0, 0, 0)
        if xi > 0:
            if xo >= 0:
                xo += xi // 2
                xo -= (xo + self.inset) % xi
            else:
                xo = (-xo) + xi // 2
                xo = -(xo - (xo - self.inset) % xi)
        if yi > 0:
            if yo >= 0:
                yo += yi // 2
                yo -= (yo + self.inset) % yi
            else:
                yo = (-yo) + yi // 2
                yo = -(yo - (yo - self.inset) % yi)
        if self.opts["confine"] and sr is not None:
            left = xo + self.inset - x1
            right = x2 - (xo + self.width - self.inset)
            top = yo + self.inset - y1
            bottom = y2 - (yo + self.height - self.inset)
            if left < 0 and right > 0:
                xo += -left if right > -left else right
            elif right < 0 and left > 0:
                xo += right if left > -right else -left
            if top < 0 and bottom > 0:
                yo += -top if bottom > -top else bottom
            elif bottom < 0 and top > 0:
                yo += bottom if top > -bottom else -top
        changed = (xo != self.xorigin or yo != self.yorigin)
        self.xorigin = xo
        self.yorigin = yo
        if changed:
            self.damage()
            self.app.relayout()
        self.app.after_idle_once(self, "_canvas_scroll", self.update_scroll)

    def fractions(self, horizontal):
        sr = self.scroll_region()
        x1, y1, x2, y2 = sr if sr is not None else (0, 0, 0, 0)
        if horizontal:
            s1, s2, o1, o2 = self.xorigin + self.inset, self.xorigin + self.width - self.inset, x1, x2
        else:
            s1, s2, o1, o2 = self.yorigin + self.inset, self.yorigin + self.height - self.inset, y1, y2
        rng = o2 - o1
        if rng <= 0:
            return 0.0, 1.0
        f1 = (s1 - o1) / float(rng)
        if f1 < 0:
            f1 = 0.0
        f2 = (s2 - o1) / float(rng)
        if f2 > 1.0:
            f2 = 1.0
        if f2 < f1:
            f2 = f1
        return float("%g" % f1), float("%g" % f2)

    def update_scroll(self):
        if self.destroyed:
            return
        for opt, hz in (("xscrollcommand", True), ("yscrollcommand", False)):
            cmd = self.opts.get(opt)
            if cmd:
                f1, f2 = self.fractions(hz)
                self.app.eval_bg(cmd + " " + ("%g" % f1) + " " + ("%g" % f2))

    # ── tags and ids ──
    def resolve(self, spec):
        # tagOrId -> list of items in stacking order
        if isinstance(spec, int) and not isinstance(spec, bool):
            it = self.items.get(spec)
            return [it] if it is not None else []
        s = tcl_str(spec)
        if s == "":
            return []
        if s[0].isdigit() or (s[0] == "-" and s[1:].isdigit()):
            try:
                it = self.items.get(int(s))
            except ValueError:
                return []
            return [it] if it is not None else []
        if s == "all":
            return [self.items[i] for i in self.order]
        if s == "current":
            return [self.current] if self.current is not None and self.current.id in self.items else []
        if any([c in s for c in "&|^!()"]):
            expr = _TagExpr(s)
            return [self.items[i] for i in self.order if expr.match(self.items[i].tags)]
        return [self.items[i] for i in self.order if s in self.items[i].tags]

    def first(self, spec):
        r = self.resolve(spec)
        return r[0] if r else None

    # ── item options ──
    def configure_item(self, it, args):
        if len(args) % 2:
            raise TclError("value for \"" + tcl_str(args[-1]) + "\" missing")
        specs = dict([(o[0], o) for o in ITEM_SPECS[it.kind]])
        names = [o[0] for o in ITEM_SPECS[it.kind]]
        for i in range(0, len(args), 2):
            k = tcl_str(args[i])
            if not k.startswith("-"):
                raise TclError("unknown option \"" + k + "\"")
            name = k[1:]
            if name not in specs:
                found = [n for n in names if n.startswith(name)]
                if len(found) == 1:
                    name = found[0]
                else:
                    raise TclError("unknown option \"" + k + "\"")
            kind = specs[name][2]
            v = args[i + 1]
            if kind == "tags":
                it.tags = split_list(v) if not isinstance(v, (tuple, list)) else [tcl_str(x) for x in v]
                continue
            if kind == "istate":
                s = tcl_str(v)
                v = "" if s == "" else match_prefix(s, ["active", "disabled", "hidden", "normal"], "state")
            elif kind == "dist":
                v = fpixels(v)
            elif kind == "dash":
                parse_dash(v, 1)
                v = v if isinstance(v, str) else join_list(v)
            elif kind == "smooth":
                s = tcl_str(v)
                if s not in ("raw", "bezier", "true"):
                    try:
                        s = "true" if get_boolean(s) else "0"
                    except TclError:
                        raise TclError("bad smooth value \"" + s + "\": must be a boolean, bezier, or raw")
                v = s if s != "0" else "0"
            elif kind == "arrowshape":
                parts = split_list(v) if not isinstance(v, (tuple, list)) else list(v)
                if len(parts) != 3:
                    raise TclError("bad arrow shape \"" + tcl_str(v) + "\": must be list with three numbers")
                v = " ".join([tcl_float(fpixels(p)).rstrip("0").rstrip(".") if False else ("%g" % fpixels(p)) for p in parts])
            else:
                v = _norm(self.app, kind, v, name)
            it.opts[name] = v
        if it.kind == "window":
            self.attach_window(it)
        if it.kind == "image" or it.kind == "bitmap":
            self.app.watch_image(self, it.opts.get("image", ""))
        it.text_layout = None
        it.bbox = None

    def item_value(self, it, name):
        if name == "tags":
            return join_list(it.tags)
        return it.opts.get(name, "")

    def attach_window(self, it):
        name = it.opts.get("window", "")
        old = it.win
        if old is not None and (old.destroyed or old.path != name):
            if not old.destroyed and old.manager == "canvas":
                from _tkinter import geom as G
                G.unmanage(self.app, old)
            it.win = None
        if name:
            w = self.app.window(name)
            if w is self:
                raise TclError("can't put " + name + " in itself")
            p = w.parent
            ok = False
            while p is not None:
                if p is self or p is self.parent:
                    ok = True
                    break
                p = p.parent
            if w.IS_TOPLEVEL:
                raise TclError("can't put " + name + " in a canvas: it's a top-level window")
            from _tkinter import geom as G
            if w.manager != "" and not (w.manager == "canvas" and w.gmaster is self):
                G.unmanage(self.app, w)
            w.manager = "canvas"
            w.gmaster = self
            it.win = w
            self.app.relayout()

    def forget_slave(self, w):
        for it in self.items.values():
            if it.win is w:
                it.win = None

    def arrange_slaves(self):
        for i in self.order:
            it = self.items[i]
            w = it.win
            if it.kind != "window" or w is None or w.destroyed:
                continue
            if self.item_state(it) == "hidden":
                self.app.set_mapped(w, False)
                continue
            ww = self.ipx(it.opts.get("width", 0)) or w.reqw
            hh = self.ipx(it.opts.get("height", 0)) or w.reqh
            x, y = self.anchor_xy(it.opts["anchor"], it.coords[0], it.coords[1], ww, hh)
            self.app.place_slave(self, w, int(x - self.xorigin), int(y - self.yorigin), ww, hh, True)

    def ipx(self, v):
        if v is None or v == "":
            return 0
        return pixels(v)

    def item_state(self, it):
        st = it.opts.get("state", "")
        if st == "":
            st = self.opts["state"]
        return st

    def eff(self, it, name):
        st = self.item_state(it)
        if st == "active" or (self.current is it and st == "normal"):
            v = it.opts.get("active" + name, "")
            if v not in ("", 0.0, 0):
                return v
        elif st == "disabled":
            v = it.opts.get("disabled" + name, "")
            if v not in ("", 0.0, 0):
                return v
        return it.opts.get(name, "")

    # ── coordinates ──
    def parse_coords(self, kind, args):
        if len(args) == 1 and isinstance(args[0], (tuple, list)):
            vals = list(args[0])
        elif len(args) == 1 and isinstance(args[0], str) and " " in args[0].strip():
            vals = split_list(args[0])
        else:
            vals = list(args)
        out = [fpixels(v) for v in vals]
        need = NCOORDS.get(kind)
        if need is not None:
            if len(out) != need:
                if kind in ("rectangle", "oval", "arc"):
                    raise TclError("wrong # coordinates: expected 4, got " + str(len(out)))
                raise TclError("wrong # coordinates: expected 2, got " + str(len(out)))
        elif kind == "line":
            if len(out) % 2:
                raise TclError("wrong # coordinates: expected an even number, got " + str(len(out)))
            if len(out) < 4:
                raise TclError("wrong # coordinates: expected at least 4, got " + str(len(out)))
        elif kind == "polygon":
            if len(out) % 2:
                raise TclError("wrong # coordinates: expected an even number, got " + str(len(out)))
            if len(out) < 6 and len(out) != 0:
                if len(out) < 6:
                    raise TclError("wrong # coordinates: expected at least 6, got " + str(len(out)))
        return out

    def w_create(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " create type coords ?arg ...?\"")
        kind = tcl_str(args[0])
        try:
            kind = match_prefix(kind, ["arc", "bitmap", "image", "line", "oval", "polygon", "rectangle", "text", "window"], "type")
        except TclError:
            raise TclError("unknown or ambiguous item type \"" + kind + "\"")
        rest = list(args[1:])
        k = 0
        while k < len(rest):
            v = rest[k]
            if isinstance(v, str) and v.startswith("-") and len(v) > 1 and not _is_number(v):
                break
            k += 1
        coords = self.parse_coords(kind, rest[:k])
        it = Item(self.next_id, kind)
        it.coords = coords
        self.configure_item(it, rest[k:])
        self.next_id += 1
        self.items[it.id] = it
        self.order.append(it.id)
        self.damage()
        return it.id

    def w_coords(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " coords tagOrId ?x y x y ...?\"")
        it = self.first(args[0])
        if len(args) == 1:
            if it is None:
                return ()
            return tuple(it.coords)
        if it is None:
            return ""
        it.coords = self.parse_coords(it.kind, args[1:])
        it.bbox = None
        it.text_layout = None
        self.damage()
        if it.kind == "window":
            self.app.relayout()
        return ""

    def w_move(self, args):
        dx = fpixels(args[1])
        dy = fpixels(args[2])
        moved = False
        for it in self.resolve(args[0]):
            c = it.coords
            for i in range(0, len(c) - 1, 2):
                c[i] += dx
                c[i + 1] += dy
            it.bbox = None
            moved = True
            if it.kind == "window":
                self.app.relayout()
        if moved:
            self.damage()
        return ""

    def w_moveto(self, args):
        items = self.resolve(args[0])
        if not items:
            return ""
        xs = tcl_str(args[1]) if len(args) > 1 else ""
        ys = tcl_str(args[2]) if len(args) > 2 else ""
        base = items[0]
        bx = base.coords[0] if base.coords else 0
        by = base.coords[1] if len(base.coords) > 1 else 0
        dx = (fpixels(xs) - bx) if xs != "" else 0.0
        dy = (fpixels(ys) - by) if ys != "" else 0.0
        return self.w_move([args[0], dx, dy])

    def w_scale(self, args):
        if len(args) != 5:
            raise TclError("wrong # args: should be \"" + self.path + " scale tagOrId xOrigin yOrigin xScale yScale\"")
        xo = fpixels(args[1])
        yo = fpixels(args[2])
        xs = get_double(args[3])
        ys = get_double(args[4])
        if xs == 0.0 or ys == 0.0:
            raise TclError("scale factor cannot be zero")
        for it in self.resolve(args[0]):
            c = it.coords
            for i in range(0, len(c) - 1, 2):
                c[i] = xo + xs * (c[i] - xo)
                c[i + 1] = yo + ys * (c[i + 1] - yo)
            it.bbox = None
        self.damage()
        return ""

    def w_imove(self, args):
        it = self.first(args[0])
        if it is None:
            return ""
        k = get_int(args[1])
        it.coords[2 * k] = fpixels(args[2])
        it.coords[2 * k + 1] = fpixels(args[3])
        it.bbox = None
        self.damage()
        return ""

    def w_delete(self, args):
        gone = set()
        for a in args:
            for it in self.resolve(a):
                gone.add(it.id)
        if not gone:
            return ""
        for i in gone:
            it = self.items.pop(i)
            if it.win is not None and not it.win.destroyed and it.win.manager == "canvas":
                from _tkinter import geom as G
                G.unmanage(self.app, it.win)
            if self.current is it:
                self.current = None
            if self.focus_item is it:
                self.focus_item = None
            if self.sel_item is it:
                self.sel_item = None
            self.item_bindings.delete_tag(str(i))
        self.order = [i for i in self.order if i not in gone]
        self.damage()
        return ""

    def w_type(self, args):
        it = self.first(args[0])
        return it.kind if it is not None else ""

    def w_itemcget(self, args):
        it = self.first(args[0])
        if it is None:
            return ""
        o = tcl_str(args[1])
        if not o.startswith("-"):
            raise TclError("unknown option \"" + o + "\"")
        name = o[1:]
        if name not in it.opts and name != "tags":
            found = [n for n in it.opts if n.startswith(name)]
            if len(found) == 1:
                name = found[0]
            else:
                raise TclError("unknown option \"" + o + "\"")
        return self.item_value(it, name)

    def w_itemconfigure(self, args):
        items = self.resolve(args[0])
        if len(args) <= 2:
            if not items:
                return ""
            it = items[0]
            if len(args) == 1:
                return tuple([("-" + n, "", "", d if n != "tags" else "", self.item_value(it, n)) for n, d, k in ITEM_SPECS[it.kind]])
            o = tcl_str(args[1])
            name = o[1:]
            for n, d, k in ITEM_SPECS[it.kind]:
                if n == name:
                    return ("-" + n, "", "", d if n != "tags" else "", self.item_value(it, n))
            raise TclError("unknown option \"" + o + "\"")
        for it in items:
            self.configure_item(it, args[1:])
        self.damage()
        return ""

    def w_addtag(self, args):
        if len(args) < 2:
            raise TclError("wrong # args: should be \"" + self.path + " addtag tag searchCommand ?arg ...?\"")
        tag = tcl_str(args[0])
        for it in self.find_items(args[1:]):
            if tag not in it.tags:
                it.tags.append(tag)
        return ""

    def w_dtag(self, args):
        items = self.resolve(args[0])
        tag = tcl_str(args[1]) if len(args) > 1 else tcl_str(args[0])
        for it in items:
            if tag in it.tags:
                it.tags = [t for t in it.tags if t != tag]
        return ""

    def w_gettags(self, args):
        it = self.first(args[0])
        if it is None:
            return ()
        return tuple(it.tags)

    def w_find(self, args):
        return tuple([it.id for it in self.find_items(args)])

    def find_items(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " find searchCommand ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["above", "all", "below", "closest", "enclosed", "overlapping", "withtag"], "search command")
        if sub == "all":
            return [self.items[i] for i in self.order]
        if sub == "withtag":
            return self.resolve(args[1])
        if sub == "above" or sub == "below":
            items = self.resolve(args[1])
            if not items:
                return []
            if sub == "above":
                idx = self.order.index(items[-1].id)
                return [self.items[self.order[idx + 1]]] if idx + 1 < len(self.order) else []
            idx = self.order.index(items[0].id)
            return [self.items[self.order[idx - 1]]] if idx > 0 else []
        if sub == "closest":
            x = fpixels(args[1])
            y = fpixels(args[2])
            halo = fpixels(args[3]) if len(args) > 3 and args[3] is not None and tcl_str(args[3]) != "" else 0.0
            if halo < 0:
                raise TclError("can't have negative halo value \"" + tcl_str(args[3]) + "\"")
            start = args[4] if len(args) > 4 and args[4] is not None and tcl_str(args[4]) != "" else None
            return self.closest(x, y, halo, start)
        x1 = fpixels(args[1])
        y1 = fpixels(args[2])
        x2 = fpixels(args[3])
        y2 = fpixels(args[4])
        if x1 > x2:
            x1, x2 = x2, x1
        if y1 > y2:
            y1, y2 = y2, y1
        rect = (x1, y1, x2, y2)
        enclosed = 1 if sub == "enclosed" else 0
        out = []
        ix1 = int(x1 - 1.0)
        iy1 = int(y1 - 1.0)
        ix2 = int(x2 + 1.0)
        iy2 = int(y2 + 1.0)
        for i in self.order:
            it = self.items[i]
            if self.item_state(it) == "hidden":
                continue
            bb = self.item_bbox(it)
            if bb is None:
                continue
            if bb[0] >= ix2 or bb[2] <= ix1 or bb[1] >= iy2 or bb[3] <= iy1:
                continue
            if self.area(it, rect) >= enclosed:
                out.append(it)
        return out

    def closest(self, x, y, halo, start):
        start_id = None
        if start is not None:
            sit = self.first(start)
            if sit is not None:
                start_id = sit.id
        best = None
        best_d = None
        cands = list(self.order)
        if start_id is not None:
            # items below `start` in the display list are searched first
            k = cands.index(start_id)
            cands = cands[:k]
        for i in cands:
            it = self.items[i]
            if self.item_state(it) == "hidden":
                continue
            d = self.distance(it, x, y)
            if d <= halo:
                d = 0.0
            if best is None or d <= best_d:
                best = it
                best_d = d
        if best is None and start_id is not None:
            return self.closest(x, y, halo, None)
        return [best] if best is not None else []

    def w_raise(self, args):
        items = self.resolve(args[0])
        if not items:
            return ""
        ids = [it.id for it in items]
        rest = [i for i in self.order if i not in ids]
        if len(args) > 1 and args[1] is not None and tcl_str(args[1]) != "":
            above = self.resolve(args[1])
            if not above:
                raise TclError("tagOrId \"" + tcl_str(args[1]) + "\" doesn't match any items")
            ref = above[-1].id
            if ref in ids:
                return ""
            k = rest.index(ref) + 1
            self.order = rest[:k] + ids + rest[k:]
        else:
            self.order = rest + ids
        self.damage()
        return ""

    def w_lower(self, args):
        items = self.resolve(args[0])
        if not items:
            return ""
        ids = [it.id for it in items]
        rest = [i for i in self.order if i not in ids]
        if len(args) > 1 and args[1] is not None and tcl_str(args[1]) != "":
            below = self.resolve(args[1])
            if not below:
                raise TclError("tagOrId \"" + tcl_str(args[1]) + "\" doesn't match any items")
            ref = below[0].id
            if ref in ids:
                return ""
            k = rest.index(ref)
            self.order = rest[:k] + ids + rest[k:]
        else:
            self.order = ids + rest
        self.damage()
        return ""

    def w_bbox(self, args):
        x1 = y1 = x2 = y2 = None
        for a in args:
            for it in self.resolve(a):
                if self.item_state(it) == "hidden":
                    continue
                bb = self.item_bbox(it)
                if bb is None or (bb[0] == -1 and bb[2] == -1):
                    continue
                if x1 is None:
                    x1, y1, x2, y2 = bb
                else:
                    x1 = min(x1, bb[0])
                    y1 = min(y1, bb[1])
                    x2 = max(x2, bb[2])
                    y2 = max(y2, bb[3])
        if x1 is None:
            return ""
        return (x1, y1, x2, y2)

    def w_canvasx(self, args):
        x = fpixels(args[0]) + self.xorigin
        if len(args) > 1 and args[1] is not None and tcl_str(args[1]) != "":
            g = fpixels(args[1])
            if g > 0:
                x = g * math.floor(x / g + 0.5)
        return x

    def w_canvasy(self, args):
        y = fpixels(args[0]) + self.yorigin
        if len(args) > 1 and args[1] is not None and tcl_str(args[1]) != "":
            g = fpixels(args[1])
            if g > 0:
                y = g * math.floor(y / g + 0.5)
        return y

    def w_xview(self, args):
        return self._view(args, True)

    def w_yview(self, args):
        return self._view(args, False)

    def _view(self, args, hz):
        if not args:
            return self.fractions(hz)
        sr = self.scroll_region()
        x1, y1, x2, y2 = sr if sr is not None else (0, 0, 0, 0)
        a0 = tcl_str(args[0])
        if a0 == "moveto":
            f = get_double(args[1])
            if hz:
                newx = x1 - self.inset + int(f * (x2 - x1) + 0.5)
                self.set_origin(newx, self.yorigin)
            else:
                newy = y1 - self.inset + int(f * (y2 - y1) + 0.5)
                self.set_origin(self.xorigin, newy)
            return ""
        if a0 == "scroll":
            n = get_int(args[1])
            what = match_prefix(tcl_str(args[2]), ["pages", "units"], "argument")
            if hz:
                if what == "pages":
                    d = int(n * 0.9 * (self.width - 2 * self.inset))
                else:
                    inc = self.px("xscrollincrement")
                    d = n * (inc if inc > 0 else (self.width - 2 * self.inset) // 10)
                self.set_origin(self.xorigin + d, self.yorigin)
            else:
                if what == "pages":
                    d = int(n * 0.9 * (self.height - 2 * self.inset))
                else:
                    inc = self.px("yscrollincrement")
                    d = n * (inc if inc > 0 else (self.height - 2 * self.inset) // 10)
                self.set_origin(self.xorigin, self.yorigin + d)
            return ""
        raise TclError("bad option \"" + a0 + "\": must be moveto or scroll")

    def w_scan(self, args):
        sub = match_prefix(tcl_str(args[0]), ["dragto", "mark"], "scan option")
        x = pixels(args[1])
        y = pixels(args[2])
        if sub == "mark":
            self.scan_mark = (x, y, self.xorigin, self.yorigin)
            return ""
        gain = get_int(args[3]) if len(args) > 3 else 10
        mx, my, xo, yo = self.scan_mark
        self.set_origin(xo - gain * (x - mx), yo - gain * (y - my))
        return ""

    # ── bind ──
    def w_bind(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " bind tagOrId ?sequence? ?command?\"")
        tag = tcl_str(args[0])
        if len(args) == 1:
            return tuple(self.item_bindings.sequences(tag))
        seq = tcl_str(args[1])
        if len(args) == 2:
            return self.item_bindings.get(tag, seq)
        ps = B.parse_sequence(seq)
        for p in ps.pats:
            if p.type not in (B.KeyPress, B.KeyRelease, B.ButtonPress, B.ButtonRelease, B.MotionNotify,
                              B.EnterNotify, B.LeaveNotify, B.VirtualEvent, B.MouseWheelEvent):
                raise TclError("requested illegal events; only key, button, motion, enter, leave, and virtual events may be used")
        self.item_bindings.set(tag, seq, tcl_str(args[2]))
        return ""

    def pick_current(self, ev):
        x = ev.x + self.xorigin
        y = ev.y + self.yorigin
        ce = self.opts["closeenough"]
        found = None
        for i in reversed(self.order):
            it = self.items[i]
            if self.item_state(it) in ("hidden", "disabled"):
                continue
            bb = self.item_bbox(it)
            if bb is None:
                continue
            if x < bb[0] - ce or x > bb[2] + ce or y < bb[1] - ce or y > bb[3] + ce:
                continue
            if self.distance(it, x, y) <= ce:
                found = it
                break
        if ev.type == B.LeaveNotify:
            found = None
        if found is not self.current:
            old = self.current
            if old is not None and old.id in self.items:
                lev = B.XEvent(B.LeaveNotify, self)
                lev.x = ev.x
                lev.y = ev.y
                lev.state = ev.state
                self.item_event(old, lev)
            self.current = found
            if found is not None:
                eev = B.XEvent(B.EnterNotify, self)
                eev.x = ev.x
                eev.y = ev.y
                eev.state = ev.state
                self.item_event(found, eev)
            self.damage()

    def item_event(self, it, ev):
        tags = ["all"] + list(it.tags) + [str(it.id)]
        ring = self.app.ring
        if ev not in ring:
            ring = ring + [ev]
        scripts = []
        for t in tags:
            s = self.item_bindings.best_match(t, ring, ev)
            if s is not None:
                scripts.append(s)
        for s in scripts:
            if self.destroyed:
                break
            if self.app.run_binding(s, ev) == "break":
                break

    def on_event(self, ev):
        t = ev.type
        if t in (B.MotionNotify, B.EnterNotify, B.LeaveNotify):
            if not (self.app.buttons and t == B.MotionNotify and self.current is not None):
                self.pick_current(ev)
            if t == B.MotionNotify and self.current is not None:
                self.item_event(self.current, ev)
        elif t in (B.ButtonPress, B.ButtonRelease, B.MouseWheelEvent):
            if t == B.ButtonPress:
                self.pick_current(ev)
            if self.current is not None:
                self.item_event(self.current, ev)
            if t == B.ButtonRelease:
                self.pick_current(ev)
        elif t in (B.KeyPress, B.KeyRelease, B.VirtualEvent):
            it = self.focus_item if self.focus_item is not None else self.current
            if it is not None and it.id in self.items:
                self.item_event(it, ev)
        elif t in (B.FocusIn, B.FocusOut):
            self.damage()

    # ── text items ──
    def w_focus(self, args):
        if not args:
            return self.focus_item.id if self.focus_item is not None else ""
        if tcl_str(args[0]) == "":
            self.focus_item = None
            return ""
        for it in self.resolve(args[0]):
            if it.kind == "text":
                self.focus_item = it
                break
        self.damage()
        return ""

    def text_index(self, it, s):
        t = it.opts.get("text", "")
        if isinstance(s, int) and not isinstance(s, bool):
            return max(0, min(len(t), s))
        s = tcl_str(s)
        if s == "end":
            return len(t)
        if s == "insert":
            return it.icursor
        if s == "sel.first" or s == "sel.last":
            if self.sel_item is not it:
                raise TclError("selection isn't in item")
            return self.sel_first if s == "sel.first" else self.sel_last
        if s.startswith("@"):
            xs, ys = s[1:].split(",")
            return self.text_point_index(it, fpixels(xs), fpixels(ys))
        try:
            return max(0, min(len(t), get_int(s)))
        except TclError:
            raise TclError("bad index \"" + s + "\"")

    def text_point_index(self, it, x, y):
        lay = self.text_lines(it)
        f = self.app.font_of(it.opts["font"])
        lines, tw, th, ox, oy = lay
        k = 0
        for (s, lx, ly, lw) in lines:
            if y < oy + ly + f.metrics()[2] or (s, lx, ly, lw) == lines[-1]:
                for j in range(len(s)):
                    if x < ox + lx + f.measure(s[:j + 1]):
                        return k + j
                return k + len(s)
            k += len(s) + 1
        return k

    def w_index(self, args):
        it = None
        for x in self.resolve(args[0]):
            if x.kind == "text":
                it = x
                break
        if it is None:
            raise TclError("can't find an indexable item \"" + tcl_str(args[0]) + "\"")
        return self.text_index(it, args[1])

    def w_icursor(self, args):
        for it in self.resolve(args[0]):
            if it.kind == "text":
                it.icursor = self.text_index(it, args[1])
        self.damage()
        return ""

    def w_insert(self, args):
        for it in self.resolve(args[0]):
            if it.kind == "text":
                k = self.text_index(it, args[1])
                s = tcl_str(args[2])
                t = it.opts["text"]
                it.opts["text"] = t[:k] + s + t[k:]
                if it.icursor >= k:
                    it.icursor += len(s)
                it.text_layout = None
                it.bbox = None
            elif it.kind in ("line", "polygon"):
                k = get_int(args[1]) if tcl_str(args[1]) != "end" else len(it.coords)
                vals = [fpixels(v) for v in split_list(args[2])]
                it.coords[k:k] = vals
                it.bbox = None
        self.damage()
        return ""

    def w_dchars(self, args):
        for it in self.resolve(args[0]):
            if it.kind == "text":
                a = self.text_index(it, args[1])
                b = self.text_index(it, args[2]) if len(args) > 2 else a
                t = it.opts["text"]
                it.opts["text"] = t[:a] + t[b + 1:]
                if it.icursor > b:
                    it.icursor -= (b - a + 1)
                elif it.icursor > a:
                    it.icursor = a
                it.text_layout = None
                it.bbox = None
            elif it.kind in ("line", "polygon"):
                a = get_int(args[1])
                b = get_int(args[2]) if len(args) > 2 else a
                del it.coords[a:b + 1]
                it.bbox = None
        self.damage()
        return ""

    def w_rchars(self, args):
        for it in self.resolve(args[0]):
            if it.kind == "text":
                a = self.text_index(it, args[1])
                b = self.text_index(it, args[2])
                t = it.opts["text"]
                it.opts["text"] = t[:a] + tcl_str(args[3]) + t[b + 1:]
                it.text_layout = None
                it.bbox = None
        self.damage()
        return ""

    def w_select(self, args):
        sub = match_prefix(tcl_str(args[0]), ["adjust", "clear", "from", "item", "to"], "select option")
        if sub == "clear":
            self.sel_item = None
            self.damage()
            return ""
        if sub == "item":
            return self.sel_item.id if self.sel_item is not None else ""
        it = None
        for x in self.resolve(args[1]):
            if x.kind == "text":
                it = x
                break
        if it is None:
            return ""
        k = self.text_index(it, args[2])
        if sub == "from":
            self.sel_anchor = k
            self.sel_item = it
        elif sub == "to" or sub == "adjust":
            if self.sel_item is not it:
                self.sel_item = it
                self.sel_anchor = k
            if sub == "adjust" and self.sel_first >= 0:
                if k < (self.sel_first + self.sel_last) // 2:
                    self.sel_anchor = self.sel_last
                else:
                    self.sel_anchor = self.sel_first
            self.sel_first = min(self.sel_anchor, k)
            self.sel_last = max(self.sel_anchor, k)
            self.app.own_selection(self)
        self.damage()
        return ""

    def selection_text(self):
        if self.sel_item is None or self.sel_first < 0:
            return None
        return self.sel_item.opts["text"][self.sel_first:self.sel_last + 1]

    # ── geometry of items ──
    def anchor_xy(self, anchor, x, y, w, h):
        if anchor in ("n", "center", "s"):
            x -= w / 2.0
        elif anchor in ("ne", "e", "se"):
            x -= w
        if anchor in ("w", "center", "e"):
            y -= h / 2.0
        elif anchor in ("sw", "s", "se"):
            y -= h
        return x, y

    def text_lines(self, it):
        if it.text_layout is None:
            f = self.app.font_of(it.opts["font"])
            lines, tw, th = layout_text(f, it.opts.get("text", ""), self.ipx(it.opts.get("width", 0)), it.opts["justify"])
            x, y = self.anchor_xy(it.opts["anchor"], it.coords[0], it.coords[1], tw, th)
            ox = int(x + (0.5 if x >= 0 else -0.5))
            oy = int(y + (0.5 if y >= 0 else -0.5))
            it.text_layout = (lines, tw, th, ox, oy)
        return it.text_layout

    def item_bbox(self, it):
        if it.bbox is not None:
            return it.bbox
        bb = self._compute_bbox(it)
        it.bbox = bb
        return bb

    def _width(self, it):
        w = self.eff(it, "width")
        try:
            w = float(w)
        except (TypeError, ValueError):
            w = 1.0
        return w

    def _compute_bbox(self, it):
        k = it.kind
        c = it.coords
        if not c:
            return None
        if k in ("rectangle", "oval"):
            x1, y1, x2, y2 = min(c[0], c[2]), min(c[1], c[3]), max(c[0], c[2]), max(c[1], c[3])
            bloat = 0
            if self.eff(it, "outline") != "":
                width = max(1.0, self._width(it))
                bloat = int((width + 1) / 2)
            ix1 = int(x1 + 0.5) if x1 >= 0 else int(x1 - 0.5)
            iy1 = int(y1 + 0.5) if y1 >= 0 else int(y1 - 0.5)
            dx = x2 if x2 >= x1 + 1 else x1 + 1
            dy = y2 if y2 >= y1 + 1 else y1 + 1
            ix2 = int(dx + 0.5) if dx >= 0 else int(dx - 0.5)
            iy2 = int(dy + 0.5) if dy >= 0 else int(dy - 0.5)
            return (ix1 - bloat, iy1 - bloat, ix2 + bloat, iy2 + bloat)
        if k == "arc":
            return self._arc_bbox(it)
        if k == "line":
            pts = self.line_points(it)
            if not pts:
                return (-1, -1, -1, -1)
            x1 = x2 = int(c[0])
            y1 = y2 = int(c[1])
            box = [x1, y1, x2, y2]

            def inc(px, py):
                tx = int(px + 0.5)
                ty = int(py + 0.5)
                if tx < box[0]:
                    box[0] = tx
                if tx > box[2]:
                    box[2] = tx
                if ty < box[1]:
                    box[1] = ty
                if ty > box[3]:
                    box[3] = ty

            for i in range(2, len(pts) - 1, 2):
                inc(pts[i], pts[i + 1])
            width = max(1.0, self._width(it))
            arrow = it.opts.get("arrow", "none")
            if arrow != "none":
                fa, la = self.arrow_polys(it, width)
                if arrow in ("first", "both") and fa:
                    inc(fa[0], fa[1])
                if arrow in ("last", "both") and la:
                    inc(la[0], la[1])
            iw = int(width + 0.5)
            box = [box[0] - iw, box[1] - iw, box[2] + iw, box[3] + iw]
            if len(c) == 2:
                return (box[0] - 1, box[1] - 1, box[2] + 1, box[3] + 1)
            return (box[0] - 1, box[1] - 1, box[2] + 1, box[3] + 1)
        if k == "polygon":
            pts = self.poly_points(it)
            if not pts:
                return (-1, -1, -1, -1)
            xs = [int(pts[i] + 0.5) for i in range(0, len(pts), 2)]
            ys = [int(pts[i] + 0.5) for i in range(1, len(pts), 2)]
            x1, y1, x2, y2 = min(xs), min(ys), max(xs), max(ys)
            if self.eff(it, "outline") != "":
                width = max(1.0, self._width(it))
                iw = int(width + 1.5)
                return (x1 - iw, y1 - iw, x2 + iw, y2 + iw)
            return (x1 - 1, y1 - 1, x2 + 1, y2 + 1)
        if k == "text":
            lines, tw, th, ox, oy = self.text_lines(it)
            return (ox, oy, ox + tw + 1, oy + th + 1) if it.opts.get("text", "") != "" else (ox, oy, ox + 1, oy + th + 1)
        if k in ("window", "image", "bitmap"):
            if k == "window":
                w = it.win
                ww = self.ipx(it.opts.get("width", 0)) or (w.reqw if w is not None else 0)
                hh = self.ipx(it.opts.get("height", 0)) or (w.reqh if w is not None else 0)
            elif k == "image":
                im = self.app.images.get(it.opts.get("image", ""))
                ww = im.width() if im is not None else 0
                hh = im.height() if im is not None else 0
            else:
                from _tkinter.image import builtin_bitmap
                bm = builtin_bitmap(it.opts.get("bitmap", ""))
                ww = bm[0] if bm else 0
                hh = bm[1] if bm else 0
            x, y = self.anchor_xy(it.opts["anchor"], c[0], c[1], ww, hh)
            ix = int(x + 0.5) if x >= 0 else int(x - 0.5)
            iy = int(y + 0.5) if y >= 0 else int(y - 0.5)
            return (ix, iy, ix + ww, iy + hh)
        return None

    def _arc_bbox(self, it):
        c = it.coords
        x1, y1, x2, y2 = min(c[0], c[2]), min(c[1], c[3]), max(c[0], c[2]), max(c[1], c[3])
        cx = (x1 + x2) / 2.0
        cy = (y1 + y2) / 2.0
        rx = (x2 - x1) / 2.0
        ry = (y2 - y1) / 2.0
        start = it.opts["start"]
        extent = it.opts["extent"]
        pts = []

        def pt(deg):
            a = math.radians(deg)
            return (cx + rx * math.cos(a), cy - ry * math.sin(a))

        pts.append(pt(start))
        pts.append(pt(start + extent))
        if it.opts["style"] == "pieslice":
            pts.append((cx, cy))
        a0 = min(start, start + extent)
        a1 = max(start, start + extent)
        for q in range(-720, 721, 90):
            if a0 < q < a1:
                pts.append(pt(q))
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        bloat = 0
        if self.eff(it, "outline") != "":
            bloat = int((max(1.0, self._width(it)) + 1) / 2)
        return (int(min(xs) + 0.5) - bloat - 1, int(min(ys) + 0.5) - bloat - 1, int(max(xs) + 0.5) + bloat + 1, int(max(ys) + 0.5) + bloat + 1)

    def line_points(self, it):
        c = it.coords
        sm = it.opts.get("smooth", "0")
        if sm not in ("0", "", 0) and len(c) > 4:
            return bezier(c, it.opts.get("splinesteps", 12), sm == "raw")
        return list(c)

    def poly_points(self, it):
        c = list(it.coords)
        if len(c) >= 2 and (c[0] != c[-2] or c[1] != c[-1]):
            c = c + [c[0], c[1]]
        sm = it.opts.get("smooth", "0")
        if sm not in ("0", "", 0) and len(c) > 4:
            return bezier(c, it.opts.get("splinesteps", 12), sm == "raw")
        return c

    def arrow_polys(self, it, width):
        # tkCanvLine.c ConfigureArrows: the arrowhead polygons (first, last)
        c = self.line_points(it)
        shape = [float(x) for x in it.opts.get("arrowshape", "8 10 3").split()]
        A = shape[0] + 0.001
        Bs = shape[1] + 0.001
        Cs = shape[2] + width / 2.0 + 0.001
        frac = (width / 2.0) / Cs
        backup = frac * Bs + A * (1.0 - frac) / 2.0
        first = None
        last = None
        arrow = it.opts.get("arrow", "none")
        n = len(c)
        if n < 4:
            return None, None

        def head(px, py, qx, qy):
            dx = px - qx
            dy = py - qy
            length = math.hypot(dx, dy)
            if length == 0:
                st = ct = 0.0
            else:
                st = dy / length
                ct = dx / length
            vx = px - A * ct
            vy = py - A * st
            t = Cs * st
            p2x = px - Bs * ct + t
            p8x = p2x - 2 * t
            t = Cs * ct
            p3y = py - Bs * st - t
            p9y = p3y + 2 * t
            p4x = p2x * frac + vx * (1.0 - frac)
            p5y = p3y * frac + vy * (1.0 - frac)
            p6x = p8x * frac + vx * (1.0 - frac)
            p7y = p9y * frac + vy * (1.0 - frac)
            return [px, py, p2x, p3y, p4x, p5y, p6x, p7y, p8x, p9y], (px - backup * ct, py - backup * st)

        if arrow in ("first", "both"):
            first, nb = head(c[0], c[1], c[2], c[3])
            first.append(nb)
        if arrow in ("last", "both"):
            last, nb = head(c[n - 2], c[n - 1], c[n - 4], c[n - 3])
            last.append(nb)
        return first, last

    def distance(self, it, x, y):
        k = it.kind
        c = it.coords
        if k == "rectangle" or k == "oval":
            x1, y1, x2, y2 = min(c[0], c[2]), min(c[1], c[3]), max(c[0], c[2]), max(c[1], c[3])
            width = self._width(it) if self.eff(it, "outline") != "" else 0.0
            filled = self.eff(it, "fill") != ""
            if k == "rectangle":
                hw = width / 2.0
                if x1 - hw <= x <= x2 + hw and y1 - hw <= y <= y2 + hw:
                    if filled or width == 0:
                        return 0.0
                    inner = min(x - (x1 + hw), (x2 - hw) - x, y - (y1 + hw), (y2 - hw) - y)
                    return max(0.0, inner)
                dx = max(x1 - hw - x, 0, x - x2 - hw)
                dy = max(y1 - hw - y, 0, y - y2 - hw)
                return math.hypot(dx, dy)
            cx = (x1 + x2) / 2.0
            cy = (y1 + y2) / 2.0
            rx = max(0.5, (x2 - x1) / 2.0)
            ry = max(0.5, (y2 - y1) / 2.0)
            nx = (x - cx) / rx
            ny = (y - cy) / ry
            r = math.hypot(nx, ny)
            scale = math.hypot((x - cx), (y - cy)) / r if r > 0 else 0.0
            edge = scale * abs(r - 1.0)
            if r <= 1.0:
                if filled:
                    return 0.0
                return max(0.0, edge - width / 2.0)
            return max(0.0, edge - width / 2.0)
        if k == "line":
            pts = self.line_points(it)
            width = max(1.0, self._width(it))
            best = 1e30
            for i in range(0, len(pts) - 3, 2):
                d = seg_dist(x, y, pts[i], pts[i + 1], pts[i + 2], pts[i + 3])
                if d < best:
                    best = d
            if len(pts) == 2:
                best = math.hypot(x - pts[0], y - pts[1])
            return max(0.0, best - width / 2.0)
        if k == "polygon":
            pts = self.poly_points(it)
            if self.eff(it, "fill") != "" and point_in_poly(x, y, pts):
                return 0.0
            best = 1e30
            for i in range(0, len(pts) - 3, 2):
                d = seg_dist(x, y, pts[i], pts[i + 1], pts[i + 2], pts[i + 3])
                if d < best:
                    best = d
            w = self._width(it) if self.eff(it, "outline") != "" else 0.0
            return max(0.0, best - w / 2.0)
        if k == "arc":
            return self.distance_arc(it, x, y)
        bb = self.item_bbox(it)
        if bb is None:
            return 1e30
        dx = max(bb[0] - x, 0, x - bb[2])
        dy = max(bb[1] - y, 0, y - bb[3])
        return math.hypot(dx, dy)

    def distance_arc(self, it, x, y):
        pts = self.arc_polygon(it)
        if it.opts["style"] != "arc" and self.eff(it, "fill") != "" and point_in_poly(x, y, pts):
            return 0.0
        best = 1e30
        for i in range(0, len(pts) - 3, 2):
            d = seg_dist(x, y, pts[i], pts[i + 1], pts[i + 2], pts[i + 3])
            if d < best:
                best = d
        return max(0.0, best - self._width(it) / 2.0)

    def area(self, it, rect):
        # 1 inside the rectangle, 0 overlapping, -1 outside (item area procs)
        x1, y1, x2, y2 = rect
        bb = self.item_bbox(it)
        k = it.kind
        if k in ("rectangle", "oval"):
            c = it.coords
            hw = (self._width(it) / 2.0) if self.eff(it, "outline") != "" else 0.0
            ix1, iy1, ix2, iy2 = min(c[0], c[2]) - hw, min(c[1], c[3]) - hw, max(c[0], c[2]) + hw, max(c[1], c[3]) + hw
            if ix1 >= x1 and iy1 >= y1 and ix2 <= x2 and iy2 <= y2:
                return 1
            if ix2 < x1 or ix1 > x2 or iy2 < y1 or iy1 > y2:
                return -1
            if k == "rectangle":
                if self.eff(it, "fill") == "" and hw > 0:
                    # an unfilled rectangle overlaps only through its outline
                    if x1 > ix1 + 2 * hw and x2 < ix2 - 2 * hw and y1 > iy1 + 2 * hw and y2 < iy2 - 2 * hw:
                        return -1
                return 0
            cx = (ix1 + ix2) / 2.0
            cy = (iy1 + iy2) / 2.0
            px = max(x1, min(cx, x2))
            py = max(y1, min(cy, y2))
            rx = max(0.5, (ix2 - ix1) / 2.0)
            ry = max(0.5, (iy2 - iy1) / 2.0)
            if ((px - cx) / rx) ** 2 + ((py - cy) / ry) ** 2 <= 1.0:
                return 0
            return -1
        if k in ("line", "polygon", "arc"):
            pts = self.line_points(it) if k == "line" else (self.poly_points(it) if k == "polygon" else self.arc_polygon(it))
            xs = [pts[i] for i in range(0, len(pts), 2)]
            ys = [pts[i] for i in range(1, len(pts), 2)]
            hw = self._width(it) / 2.0
            if min(xs) - hw >= x1 and max(xs) + hw <= x2 and min(ys) - hw >= y1 and max(ys) + hw <= y2:
                return 1
            for i in range(0, len(pts) - 1, 2):
                if x1 - hw <= pts[i] <= x2 + hw and y1 - hw <= pts[i + 1] <= y2 + hw:
                    return 0
            for i in range(0, len(pts) - 3, 2):
                if seg_rect(pts[i], pts[i + 1], pts[i + 2], pts[i + 3], x1 - hw, y1 - hw, x2 + hw, y2 + hw):
                    return 0
            if k == "polygon" and self.eff(it, "fill") != "" and point_in_poly(x1, y1, pts):
                return 0
            return -1
        if bb is None:
            return -1
        if bb[0] >= x1 and bb[1] >= y1 and bb[2] <= x2 and bb[3] <= y2:
            return 1
        if bb[2] < x1 or bb[0] > x2 or bb[3] < y1 or bb[1] > y2:
            return -1
        return 0

    def arc_polygon(self, it):
        c = it.coords
        x1, y1, x2, y2 = min(c[0], c[2]), min(c[1], c[3]), max(c[0], c[2]), max(c[1], c[3])
        cx = (x1 + x2) / 2.0
        cy = (y1 + y2) / 2.0
        rx = (x2 - x1) / 2.0
        ry = (y2 - y1) / 2.0
        start = it.opts["start"]
        extent = it.opts["extent"]
        n = max(4, min(90, int(abs(extent) / 4) + 2))
        pts = []
        for i in range(n + 1):
            a = math.radians(start + extent * i / float(n))
            pts.append(cx + rx * math.cos(a))
            pts.append(cy - ry * math.sin(a))
        st = it.opts["style"]
        if st == "pieslice":
            pts = [cx, cy] + pts + [cx, cy]
        elif st == "chord":
            pts = pts + [pts[0], pts[1]]
        return pts

    def oval_polygon(self, c):
        x1, y1, x2, y2 = min(c[0], c[2]), min(c[1], c[3]), max(c[0], c[2]), max(c[1], c[3])
        cx = (x1 + x2) / 2.0
        cy = (y1 + y2) / 2.0
        rx = (x2 - x1) / 2.0
        ry = (y2 - y1) / 2.0
        n = max(12, min(120, int(max(rx, ry) * 1.5)))
        pts = []
        for i in range(n):
            a = 2 * math.pi * i / n
            pts.append(cx + rx * math.cos(a))
            pts.append(cy + ry * math.sin(a))
        return pts

    # ── drawing ──
    def draw(self, h, ax, ay):
        bg = self.color("background")
        fill(h, ax, ay, self.width, self.height, bg)
        ins = self.inset
        gui_push_clip(h, ax + ins, ay + ins, self.width - 2 * ins, self.height - 2 * ins)
        ox = ax - self.xorigin
        oy = ay - self.yorigin
        for i in self.order:
            it = self.items[i]
            if self.item_state(it) == "hidden":
                continue
            self.draw_item(h, it, ox, oy)
        gui_pop_clip(h)
        hl = self.px("highlightthickness")
        draw_relief(h, ax + hl, ay + hl, self.width - 2 * hl, self.height - 2 * hl, self.px("borderwidth"), self.opts["relief"], bg)
        if hl > 0:
            c = self.color("highlightcolor") if self.has_focus else self.color("highlightbackground")
            draw_ring(h, ax, ay, self.width, self.height, hl, c)

    def _col(self, it, name):
        v = self.eff(it, name)
        if v == "" or v is None:
            return None
        return parse_color(v)

    def _stroke(self, h, pts, col, width, dash, closed=False):
        if col is None or len(pts) < 4:
            return
        w = max(1, int(width + 0.5))
        segs = []
        for i in range(0, len(pts) - 3, 2):
            segs.append((pts[i], pts[i + 1], pts[i + 2], pts[i + 3]))
        if dash:
            out = []
            k = 0
            on = True
            left = dash[0]
            for (x1, y1, x2, y2) in segs:
                L = math.hypot(x2 - x1, y2 - y1)
                pos = 0.0
                while pos < L:
                    step = min(left, L - pos)
                    if on:
                        t0 = pos / L
                        t1 = (pos + step) / L
                        out.append((x1 + (x2 - x1) * t0, y1 + (y2 - y1) * t0, x1 + (x2 - x1) * t1, y1 + (y2 - y1) * t1))
                    pos += step
                    left -= step
                    if left <= 0:
                        k = (k + 1) % len(dash)
                        left = dash[k]
                        on = not on
            segs = out
        for (x1, y1, x2, y2) in segs:
            line(h, x1, y1, x2, y2, col, w)

    def draw_item(self, h, it, ox, oy):
        k = it.kind
        c = it.coords
        if k in ("rectangle", "oval", "arc", "polygon"):
            fc = self._col(it, "fill")
            oc = self._col(it, "outline")
            width = self._width(it)
            dash = parse_dash(self.eff(it, "dash"), width) if self.eff(it, "dash") else []
            if k == "rectangle":
                x1, y1, x2, y2 = min(c[0], c[2]) + ox, min(c[1], c[3]) + oy, max(c[0], c[2]) + ox, max(c[1], c[3]) + oy
                if fc is not None:
                    fill(h, x1, y1, x2 - x1, y2 - y1, fc)
                if oc is not None:
                    self._stroke(h, [x1, y1, x2, y1, x2, y2, x1, y2, x1, y1], oc, width, dash)
                return
            if k == "oval":
                pts = self.oval_polygon(c)
            elif k == "arc":
                pts = self.arc_polygon(it)
            else:
                pts = self.poly_points(it)
            tp = []
            for i in range(0, len(pts), 2):
                tp.append(pts[i] + ox)
                tp.append(pts[i + 1] + oy)
            if fc is not None and len(tp) >= 6 and not (k == "arc" and it.opts["style"] == "arc"):
                gui_fill_polygon(h, tp, len(tp) // 2, (fc >> 16) & 255, (fc >> 8) & 255, fc & 255, 255)
            if oc is not None:
                if k in ("oval",) or (k == "polygon"):
                    tp = tp + [tp[0], tp[1]] if (tp[0], tp[1]) != (tp[-2], tp[-1]) else tp
                self._stroke(h, tp, oc, width, dash)
            return
        if k == "line":
            col = self._col(it, "fill")
            width = max(1.0, self._width(it))
            pts = self.line_points(it)
            arrow = it.opts.get("arrow", "none")
            fa = la = None
            if arrow != "none":
                fa, la = self.arrow_polys(it, width)
                if fa:
                    pts[0], pts[1] = fa[-1]
                if la:
                    pts[-2], pts[-1] = la[-1]
            tp = []
            for i in range(0, len(pts), 2):
                tp.append(pts[i] + ox)
                tp.append(pts[i + 1] + oy)
            dash = parse_dash(self.eff(it, "dash"), width) if self.eff(it, "dash") else []
            self._stroke(h, tp, col, width, dash)
            if col is not None:
                for poly in (fa, la):
                    if poly:
                        pp = []
                        for i in range(0, 10, 2):
                            pp.append(poly[i] + ox)
                            pp.append(poly[i + 1] + oy)
                        gui_fill_polygon(h, pp, 5, (col >> 16) & 255, (col >> 8) & 255, col & 255, 255)
            return
        if k == "text":
            col = self._col(it, "fill")
            if col is None:
                return
            f = self.app.font_of(it.opts["font"])
            lines, tw, th, tx, ty = self.text_lines(it)
            kk = 0
            for (s, lx, ly, lw) in lines:
                if self.sel_item is it and self.sel_first >= 0:
                    a = max(0, self.sel_first - kk)
                    b = min(len(s), self.sel_last - kk + 1)
                    if b > a:
                        x0 = f.measure(s[:a])
                        x1 = f.measure(s[:b])
                        fill(h, tx + lx + x0 + ox, ty + ly + oy, x1 - x0, f.metrics()[2], self.color("selectbackground"))
                draw_text(h, s, tx + lx + ox, ty + ly + oy, f, col)
                kk += len(s) + 1
            if self.focus_item is it and self.has_focus:
                pos = it.icursor
                kk = 0
                for (s, lx, ly, lw) in lines:
                    if pos <= kk + len(s):
                        cx = tx + lx + f.measure(s[:pos - kk])
                        fill(h, cx + ox, ty + ly + oy, max(1, self.px("insertwidth")), f.metrics()[2], self.color("insertbackground"))
                        break
                    kk += len(s) + 1
            return
        if k == "image":
            name = it.opts.get("image", "")
            st = self.item_state(it)
            if st == "active" and it.opts.get("activeimage"):
                name = it.opts["activeimage"]
            elif st == "disabled" and it.opts.get("disabledimage"):
                name = it.opts["disabledimage"]
            im = self.app.images.get(name)
            if im is not None:
                bb = self.item_bbox(it)
                im.draw(h, bb[0] + ox, bb[1] + oy, im.width(), im.height())
            return
        if k == "bitmap":
            from _tkinter.image import builtin_bitmap
            bm = builtin_bitmap(it.opts.get("bitmap", ""))
            if bm is None:
                return
            bb = self.item_bbox(it)
            fg = parse_color(it.opts.get("foreground", "black"))
            w, hh, rows = bm
            for yy in range(hh):
                row = rows[yy]
                for xx in range(w):
                    if (row >> xx) & 1:
                        fill(h, bb[0] + ox + xx, bb[1] + oy + yy, 1, 1, fg)
            return

    # ── postscript ──
    def w_postscript(self, args):
        opts = {}
        for i in range(0, len(args) - 1, 2):
            k = match_prefix(tcl_str(args[i]), ["-channel", "-colormap", "-colormode", "-file", "-fontmap", "-height",
                                                "-pageanchor", "-pageheight", "-pagewidth", "-pagex", "-pagey",
                                                "-rotate", "-width", "-x", "-y"], "option")
            opts[k] = args[i + 1]
        ps = self.make_postscript(opts)
        if "-file" in opts:
            with open(tcl_str(opts["-file"]), "w") as f:
                f.write(ps)
            return ""
        return ps

    def make_postscript(self, opts):
        import time
        x = fpixels(opts["-x"]) if "-x" in opts else float(self.xorigin + self.inset)
        y = fpixels(opts["-y"]) if "-y" in opts else float(self.yorigin + self.inset)
        sr = self.scroll_region()
        defw = self.width - 2 * self.inset if self.mapped else self.px("width")
        defh = self.height - 2 * self.inset if self.mapped else self.px("height")
        if sr is not None and "-x" in opts and "-width" not in opts:
            defw = sr[2] - x
        w = fpixels(opts["-width"]) if "-width" in opts else float(defw)
        hh = fpixels(opts["-height"]) if "-height" in opts else float(defh)
        rotate = get_boolean(opts["-rotate"]) if "-rotate" in opts else False
        mode = tcl_str(opts.get("-colormode", "color"))
        ptpx = 72.0 / SCREEN.dpi
        scale = ptpx
        if "-pagewidth" in opts:
            scale = fpixels(opts["-pagewidth"]) * ptpx / (hh if rotate else w)
        elif "-pageheight" in opts:
            scale = fpixels(opts["-pageheight"]) * ptpx / (w if rotate else hh)
        pagex = fpixels(opts["-pagex"]) * ptpx if "-pagex" in opts else 72 * 8.5 / 2
        pagey = fpixels(opts["-pagey"]) * ptpx if "-pagey" in opts else 72 * 11 / 2
        anchor = tcl_str(opts.get("-pageanchor", "center"))
        pw = (hh if rotate else w) * scale
        ph = (w if rotate else hh) * scale
        lx, ly = pagex, pagey
        if anchor in ("n", "center", "s"):
            lx -= pw / 2
        elif anchor in ("ne", "e", "se"):
            lx -= pw
        if anchor in ("w", "center", "e"):
            ly -= ph / 2
        elif anchor in ("nw", "n", "ne"):
            ly -= ph
        llx = int(math.floor(lx))
        lly = int(math.floor(ly))
        urx = int(math.ceil(lx + pw))
        ury = int(math.ceil(ly + ph))
        out = []
        out.append("%!PS-Adobe-3.0 EPSF-3.0")
        out.append("%%Creator: Tk Canvas Widget (Nython)")
        out.append("%%Title: Window " + self.path)
        out.append("%%CreationDate: " + time.ctime())
        out.append("%%BoundingBox: " + str(llx) + " " + str(lly) + " " + str(urx) + " " + str(ury))
        out.append("%%Pages: 1")
        out.append("%%DocumentData: Clean7Bit")
        out.append("%%Orientation: " + ("Landscape" if rotate else "Portrait"))
        fonts = sorted(set([_ps_font(self.app.font_of(it.opts["font"])) for it in self.items.values() if it.kind == "text"]))
        if fonts:
            out.append("%%DocumentNeededResources: font " + fonts[0])
            for fn in fonts[1:]:
                out.append("%%+ font " + fn)
        out.append("%%EndComments")
        out.append("")
        out.append("%%BeginProlog")
        out.append("/CL 2 def")
        out.append("% Nython Tk: plain path operators, no Tk prolog procedures")
        out.append("%%EndProlog")
        out.append("%%BeginSetup")
        out.append("%%EndSetup")
        out.append("%%Page: 1 1")
        out.append("save")
        out.append("%.1f %.1f translate" % (lx, ly))
        if rotate:
            out.append("90 rotate")
        out.append("%.4g %.4g scale" % (scale, scale))
        out.append("%g %g translate" % (-x, -(y + hh)))
        out.append("0 %g moveto %g %g lineto %g 0 lineto 0 0 lineto closepath clip newpath" % (0, w, 0, 0) if False else
                   "%g %g moveto %g %g lineto %g %g lineto %g %g lineto closepath clip newpath" % (x, y, x + w, y, x + w, y + hh, x, y + hh))
        for i in self.order:
            it = self.items[i]
            if self.item_state(it) == "hidden":
                continue
            out.extend(self.ps_item(it, y, hh, mode))
        out.append("restore showpage")
        out.append("")
        out.append("%%Trailer")
        out.append("end")
        out.append("%%EOF")
        return "\n".join(out) + "\n"

    def ps_color(self, c, mode):
        r, g, b = comps(c)
        if mode == "gray" or mode == "mono":
            v = (0.30 * r + 0.59 * g + 0.11 * b) / 255.0
            if mode == "mono":
                v = 1.0 if v > 0.5 else 0.0
            return "%.3f setgray" % v
        return "%.3f %.3f %.3f setrgbcolor" % (r / 255.0, g / 255.0, b / 255.0)

    def ps_item(self, it, y0, hh, mode):
        # PostScript's y axis goes up: y' = 2*y0 + hh - y keeps the page upright
        flip = 2 * y0 + hh
        k = it.kind
        out = ["% item " + str(it.id) + " (" + k + ")"]

        def path(pts, closed):
            s = "%g %g moveto" % (pts[0], flip - pts[1])
            for i in range(2, len(pts) - 1, 2):
                s += " %g %g lineto" % (pts[i], flip - pts[i + 1])
            if closed:
                s += " closepath"
            return s

        width = self._width(it) if k not in ("text", "window", "image", "bitmap") else 0
        dash = parse_dash(self.eff(it, "dash"), width) if k in ("line", "polygon", "rectangle", "oval", "arc") and self.eff(it, "dash") else []
        ds = "[" + " ".join([str(d) for d in dash]) + "] 0 setdash" if dash else "[] 0 setdash"
        if k in ("rectangle", "oval", "arc", "polygon"):
            c = it.coords
            if k == "rectangle":
                pts = [c[0], c[1], c[2], c[1], c[2], c[3], c[0], c[3]]
                closed = True
            elif k == "oval":
                x1, y1, x2, y2 = min(c[0], c[2]), min(c[1], c[3]), max(c[0], c[2]), max(c[1], c[3])
                fc = self._col(it, "fill")
                oc = self._col(it, "outline")
                ell = "matrix currentmatrix %g %g translate %g %g scale 1 0 moveto 0 0 1 0 360 arc setmatrix" % (
                    (x1 + x2) / 2.0, flip - (y1 + y2) / 2.0, (x2 - x1) / 2.0, (y2 - y1) / 2.0)
                if fc is not None:
                    out.append(ell + " " + self.ps_color(fc, mode) + " fill")
                if oc is not None:
                    out.append(ell + " %g setlinewidth " % width + ds + " " + self.ps_color(oc, mode) + " stroke")
                return out
            elif k == "arc":
                pts = self.arc_polygon(it)
                closed = it.opts["style"] != "arc"
            else:
                pts = self.poly_points(it)
                closed = True
            fc = self._col(it, "fill")
            oc = self._col(it, "outline")
            if fc is not None and not (k == "arc" and it.opts["style"] == "arc"):
                out.append(path(pts, True) + " " + self.ps_color(fc, mode) + " fill")
            if oc is not None:
                out.append(path(pts, closed) + " 1 setlinejoin %g setlinewidth " % width + ds + " " + self.ps_color(oc, mode) + " stroke")
            return out
        if k == "line":
            col = self._col(it, "fill")
            if col is None:
                return out
            pts = self.line_points(it)
            cap = {"butt": 0, "round": 1, "projecting": 2}[it.opts.get("capstyle", "butt")]
            join = {"miter": 0, "round": 1, "bevel": 2}[it.opts.get("joinstyle", "round")]
            out.append(path(pts, False) + " %d setlinecap %d setlinejoin %g setlinewidth " % (cap, join, max(1.0, width)) + ds + " " + self.ps_color(col, mode) + " stroke")
            fa, la = self.arrow_polys(it, max(1.0, width)) if it.opts.get("arrow", "none") != "none" else (None, None)
            for poly in (fa, la):
                if poly:
                    out.append(path(poly[:10], True) + " " + self.ps_color(col, mode) + " fill")
            return out
        if k == "text":
            col = self._col(it, "fill")
            if col is None or it.opts.get("text", "") == "":
                return out
            f = self.app.font_of(it.opts["font"])
            asc, desc, ls, fixed = f.metrics()
            lines, tw, th, tx, ty = self.text_lines(it)
            out.append("/" + _ps_font(f) + " findfont %d scalefont setfont" % f.px())
            out.append(self.ps_color(col, mode))
            for (s, lx, ly, lw) in lines:
                out.append("%g %g moveto (%s) show" % (tx + lx, flip - (ty + ly + asc), _ps_escape(s)))
            return out
        if k in ("window", "image", "bitmap"):
            bb = self.item_bbox(it)
            out.append("%% %s at %d %d (%dx%d) not rendered" % (k, bb[0], bb[1], bb[2] - bb[0], bb[3] - bb[1]))
            return out
        return out

    def forget_all_slaves(self):
        for it in self.items.values():
            if it.win is not None:
                it.win.manager = ""
                it.win.gmaster = None
                it.win = None

    def a11y_states(self):
        return []

    def a11y_value(self):
        return str(len(self.items)) + " items"


def _ps_font(f):
    fam, size, weight, slant, ul, ov = f.actual()
    from _tkinter.util import generic_family
    g = generic_family(f.family)
    base = {"sans-serif": "Helvetica", "serif": "Times", "monospace": "Courier"}[g]
    if base == "Times":
        if weight == "bold" and slant == "italic":
            return "Times-BoldItalic"
        if weight == "bold":
            return "Times-Bold"
        if slant == "italic":
            return "Times-Italic"
        return "Times-Roman"
    suffix = ""
    if weight == "bold":
        suffix = "Bold"
    if slant == "italic":
        suffix += "Oblique"
    return base + ("-" + suffix if suffix else "")


def _ps_escape(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch in "()\\":
            out.append("\\" + ch)
        elif o < 32 or o > 126:
            out.append("\\%03o" % (o & 0xff))
        else:
            out.append(ch)
    return "".join(out)


def _is_number(s):
    try:
        float(s)
        return True
    except ValueError:
        return False


def seg_dist(x, y, x1, y1, x2, y2):
    dx = x2 - x1
    dy = y2 - y1
    L = dx * dx + dy * dy
    if L == 0:
        return math.hypot(x - x1, y - y1)
    t = ((x - x1) * dx + (y - y1) * dy) / L
    if t < 0:
        t = 0.0
    elif t > 1:
        t = 1.0
    return math.hypot(x - (x1 + t * dx), y - (y1 + t * dy))


def point_in_poly(x, y, pts):
    inside = False
    n = len(pts) // 2
    j = n - 1
    for i in range(n):
        xi, yi = pts[2 * i], pts[2 * i + 1]
        xj, yj = pts[2 * j], pts[2 * j + 1]
        if (yi > y) != (yj > y):
            xc = xi + (y - yi) * (xj - xi) / (yj - yi)
            if x < xc:
                inside = not inside
        j = i
    return inside


def seg_rect(x1, y1, x2, y2, rx1, ry1, rx2, ry2):
    # does the segment cross the rectangle? (Liang-Barsky)
    dx = x2 - x1
    dy = y2 - y1
    t0 = 0.0
    t1 = 1.0
    for p, q in ((-dx, x1 - rx1), (dx, rx2 - x1), (-dy, y1 - ry1), (dy, ry2 - y1)):
        if p == 0:
            if q < 0:
                return False
        else:
            r = q / p
            if p < 0:
                if r > t1:
                    return False
                if r > t0:
                    t0 = r
            else:
                if r < t0:
                    return False
                if r < t1:
                    t1 = r
    return True


def bezier(c, steps, raw):
    # TkMakeBezierCurve (smooth true) / TkMakeRawCurve (smooth raw)
    pts = list(c)
    n = len(pts) // 2
    out = []
    if raw:
        out.extend(pts[0:2])
        i = 0
        while i + 3 < n:
            ctl = pts[2 * i:2 * i + 8]
            for s in range(1, steps + 1):
                t = s / float(steps)
                u = 1.0 - t
                a = u * u * u
                b = 3 * t * u * u
                cc = 3 * t * t * u
                d = t * t * t
                out.append(a * ctl[0] + b * ctl[2] + cc * ctl[4] + d * ctl[6])
                out.append(a * ctl[1] + b * ctl[3] + cc * ctl[5] + d * ctl[7])
            i += 3
        return out
    closed = (pts[0] == pts[-2] and pts[1] == pts[-1])
    if closed:
        pts = [pts[-4], pts[-3]] + pts
        n = len(pts) // 2
        out.extend([0.5 * pts[0] + 0.5 * pts[2], 0.5 * pts[1] + 0.5 * pts[3]])
    else:
        out.extend(pts[0:2])
    for i in range(2, n):
        p = pts[2 * (i - 2):2 * (i - 2) + 6]
        if i == 2 and not closed:
            c0, c1 = p[0], p[1]
            c2, c3 = 0.333 * p[0] + 0.667 * p[2], 0.333 * p[1] + 0.667 * p[3]
        else:
            c0, c1 = 0.5 * p[0] + 0.5 * p[2], 0.5 * p[1] + 0.5 * p[3]
            c2, c3 = 0.167 * p[0] + 0.833 * p[2], 0.167 * p[1] + 0.833 * p[3]
        if i == n - 1 and not closed:
            c4, c5 = 0.667 * p[2] + 0.333 * p[4], 0.667 * p[3] + 0.333 * p[5]
            c6, c7 = p[4], p[5]
        else:
            c4, c5 = 0.833 * p[2] + 0.167 * p[4], 0.833 * p[3] + 0.167 * p[5]
            c6, c7 = 0.5 * p[2] + 0.5 * p[4], 0.5 * p[3] + 0.5 * p[5]
        if (p[0] == p[2] and p[1] == p[3]) or (p[2] == p[4] and p[3] == p[5]):
            out.extend([c6, c7])
            continue
        for s in range(1, steps + 1):
            t = s / float(steps)
            u = 1.0 - t
            a = u * u * u
            b = 3 * t * u * u
            cc = 3 * t * t * u
            d = t * t * t
            out.append(a * c0 + b * c2 + cc * c4 + d * c6)
            out.append(a * c1 + b * c3 + cc * c5 + d * c7)
    return out


class _TagExpr:
    # tag expressions: && || ^ ! and parentheses (Tk 8.5's TagSearchScan)
    def __init__(self, s):
        self.toks = self._tok(s)
        self.k = 0
        self.tree = self._or()
        if self.k != len(self.toks):
            raise TclError("Unexpected operator in tag search expression")

    def _tok(self, s):
        out = []
        i = 0
        n = len(s)
        while i < n:
            c = s[i]
            if c in " \t":
                i += 1
                continue
            if s.startswith("&&", i) or s.startswith("||", i):
                out.append(s[i:i + 2])
                i += 2
                continue
            if c in "^!()":
                out.append(c)
                i += 1
                continue
            if c == "\"":
                j = s.find("\"", i + 1)
                out.append(("tag", s[i + 1:j]))
                i = j + 1
                continue
            j = i
            while j < n and s[j] not in " \t&|^!()":
                j += 1
            out.append(("tag", s[i:j]))
            i = j
        return out

    def _or(self):
        a = self._xor()
        while self.k < len(self.toks) and self.toks[self.k] == "||":
            self.k += 1
            a = ("or", a, self._xor())
        return a

    def _xor(self):
        a = self._and()
        while self.k < len(self.toks) and self.toks[self.k] == "^":
            self.k += 1
            a = ("xor", a, self._and())
        return a

    def _and(self):
        a = self._not()
        while self.k < len(self.toks) and self.toks[self.k] == "&&":
            self.k += 1
            a = ("and", a, self._not())
        return a

    def _not(self):
        if self.k < len(self.toks) and self.toks[self.k] == "!":
            self.k += 1
            return ("not", self._not())
        if self.k < len(self.toks) and self.toks[self.k] == "(":
            self.k += 1
            a = self._or()
            if self.k >= len(self.toks) or self.toks[self.k] != ")":
                raise TclError("Missing close-paren in tag search expression")
            self.k += 1
            return a
        if self.k < len(self.toks) and isinstance(self.toks[self.k], tuple):
            t = self.toks[self.k]
            self.k += 1
            return t
        raise TclError("Missing tag in tag search expression")

    def match(self, tags):
        return self._ev(self.tree, tags)

    def _ev(self, n, tags):
        op = n[0]
        if op == "tag":
            return n[1] in tags
        if op == "not":
            return not self._ev(n[1], tags)
        if op == "and":
            return self._ev(n[1], tags) and self._ev(n[2], tags)
        if op == "or":
            return self._ev(n[1], tags) or self._ev(n[2], tags)
        return self._ev(n[1], tags) != self._ev(n[2], tags)


C.WIDGET_TYPES["canvas"] = TkCanvas
