# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/widgets.ny - Tk's classic widgets (round 84).
#
# frame, toplevel, labelframe, label, button, checkbutton, radiobutton,
# message, scrollbar, scale, panedwindow - each with Tk 8.6's option table
# and defaults (tkUnixDefault.h), its requested size computed as Tk's C
# code does (tkUnixButton.c TkpComputeButtonGeometry, tkScale.c
# ComputeScaleGeometry, tkUnixScrlbr.c, tkMessage.c ...), its look drawn
# with the SDL backend, its widget command, and its class bindings with
# the behaviour of Tk's library scripts (button.tcl, scrlbar.tcl,
# scale.tcl, panedwindow.tcl), the procs those call implemented here as
# Tcl commands (tk::ButtonDown ...).
#
# entry/spinbox/listbox are in entry.ny, text in text.ny, canvas in
# canvas.ny, menu/menubutton in menu.ny, the ttk widgets in ttk.ny.

import math
from _tkinter.tcl import TclError, tcl_str, tcl_float, split_list, join_list, get_int, get_double, get_boolean, match_prefix, or_list
from _tkinter.util import (pixels, fpixels, parse_color, cdiv, cround, shades, fill, line, text as draw_text, draw_relief,
                           draw_ring, layout_text, anchor_pos, SCREEN)
from _tkinter.win import TkWin, fmt_frac
from _tkinter import core as C
from _tkinter import bind as B

NORMAL_BG = "#d9d9d9"
ACTIVE_BG = "#ececec"
SELECT_BG = "#c3c3c3"
TROUGH = "#b3b3b3"
DISABLED = "#a3a3a3"
BLACK = "#000000"
WHITE = "#ffffff"


def O(name, dbname, dbclass, default, kind):
    return (name, dbname, dbclass, default, kind)


# ── drawing a whole toplevel ─────────────────────────────────────────────────

def draw_tree(h, w, ax, ay):
    w.draw(h, ax, ay)
    kids = w.children
    if kids:
        gui_push_clip(h, ax, ay, w.width, w.height)
        for c in kids:
            if c.mapped and not c.IS_TOPLEVEL and not c.destroyed:
                draw_tree(h, c, ax + c.x, ay + c.y)
        gui_pop_clip(h)


def draw_frame_box(w, h, ax, ay, bgname="background"):
    bg = w.color(bgname)
    if bg is None:
        return
    fill(h, ax, ay, w.width, w.height, bg)
    hl = w.px("highlightthickness") if "highlightthickness" in w.opts else 0
    bd = w.px("borderwidth") if "borderwidth" in w.opts else 0
    draw_relief(h, ax + hl, ay + hl, w.width - 2 * hl, w.height - 2 * hl, bd, w.opts.get("relief", "flat"), bg)
    if hl > 0:
        c = w.color("highlightcolor") if w.has_focus else w.color("highlightbackground")
        draw_ring(h, ax, ay, w.width, w.height, hl, c if c is not None else bg)


# ── frame, toplevel, labelframe ──────────────────────────────────────────────

FRAME_OPTS = [
    O("background", "background", "Background", NORMAL_BG, "color_or_empty"),
    O("borderwidth", "borderWidth", "BorderWidth", 0, "pixels"),
    O("class", "class", "Class", "Frame", "string"),
    O("colormap", "colormap", "Colormap", "", "string"),
    O("container", "container", "Container", 0, "boolean"),
    O("cursor", "cursor", "Cursor", "", "cursor"),
    O("height", "height", "Height", 0, "pixels"),
    O("highlightbackground", "highlightBackground", "HighlightBackground", NORMAL_BG, "color"),
    O("highlightcolor", "highlightColor", "HighlightColor", BLACK, "color"),
    O("highlightthickness", "highlightThickness", "HighlightThickness", 0, "pixels"),
    O("padx", "padX", "Pad", 0, "pixels"),
    O("pady", "padY", "Pad", 0, "pixels"),
    O("relief", "relief", "Relief", "flat", "relief"),
    O("takefocus", "takeFocus", "TakeFocus", "0", "string"),
    O("visual", "visual", "Visual", "", "string"),
    O("width", "width", "Width", 0, "pixels"),
]


class TkFrame(TkWin):
    CLASS = "Frame"
    OPTS = FRAME_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background"}
    A11Y_ROLE = "group"

    def init_options(self):
        TkWin.init_options(self)
        self.opts["class"] = self.wclass

    def reconfigured(self, changed):
        self.frame_geometry()
        self.damage()

    def frame_geometry(self):
        bd = self.px("highlightthickness") + self.px("borderwidth")
        px = self.px("padx")
        py = self.px("pady")
        self.set_internal_borders(bd + px, bd + py, bd + px, bd + py)
        w = self.px("width")
        hh = self.px("height")
        if w > 0 or hh > 0:
            self.request(w if w > 0 else self.reqw, hh if hh > 0 else self.reqh)

    def draw(self, h, ax, ay):
        draw_frame_box(self, h, ax, ay)


TOPLEVEL_OPTS = sorted(FRAME_OPTS + [
    O("menu", "menu", "Menu", "", "string"),
    O("screen", "screen", "Screen", "", "string"),
    O("use", "use", "Use", "", "string"),
], key=lambda o: o[0])


class TkToplevel(TkFrame):
    CLASS = "Toplevel"
    OPTS = TOPLEVEL_OPTS
    IS_TOPLEVEL = True
    A11Y_ROLE = "window"

    def __init__(self, app, path, parent, wclass=None):
        TkFrame.__init__(self, app, path, parent, wclass)
        self.wm = C.WmInfo()
        self.focus_last = None
        self.overlays = []
        self.menubar = None
        self.reqw = 200
        self.reqh = 200

    def created(self):
        self.reconfigured(list(self.opts.keys()))

    def reconfigured(self, changed):
        TkFrame.reconfigured(self, changed)
        if "menu" in changed:
            m = self.opts.get("menu", "")
            old = self.menubar
            self.menubar = None
            if m:
                mw = self.app.window(m)
                self.menubar = mw
                mw.as_menubar = self
            if old is not None and old is not self.menubar:
                old.as_menubar = None
            self.app.relayout()
            self.damage()

    def menubar_height(self):
        mb = self.menubar
        if mb is None or mb.destroyed:
            return 0
        return mb.menubar_height_px()

    def menubar_event(self, kind, x, y, button, state):
        mb = self.menubar
        if mb is not None and not mb.destroyed:
            mb.menubar_input(self, kind, x, y, button, state)

    def key_hook(self, ks, down, state):
        for ov in list(self.overlays):
            hook = getattr(ov, "overlay_key", None)
            if hook is not None and hook(ks, down, state):
                return True
        return False

    def overlay_at(self, x, y):
        for ov in reversed(self.overlays):
            if ov.destroyed or not ov.mapped:
                continue
            if ov.x <= x < ov.x + ov.width and ov.y <= y < ov.y + ov.height:
                return ov.overlay_hit(x - ov.x, y - ov.y)
        if self.overlays and self.app.button_grab is None:
            # a click outside a posted menu: the menu takes it to unpost
            ov = self.overlays[-1]
            return ov.overlay_outside()
        return None

    def paint(self):
        h = self.native
        bg = self.color("background")
        if bg is None:
            bg = 0xd9d9d9
        gui_clear(h, (bg >> 16) & 255, (bg >> 8) & 255, bg & 255, 255)
        mh = self.menubar_height()
        if mh > 0:
            self.menubar.draw_menubar(h, self.width, mh)
        draw_tree(h, self, 0, mh)
        for ov in list(self.overlays):
            if not ov.destroyed and ov.mapped:
                draw_tree(h, ov, ov.x, ov.y + mh)
        gui_present(h)

    def on_destroy(self):
        for ov in list(self.overlays):
            self.overlays.remove(ov)


LABELFRAME_OPTS = sorted([o for o in FRAME_OPTS if o[0] not in ("borderwidth", "relief")] + [
    O("borderwidth", "borderWidth", "BorderWidth", 2, "pixels"),
    O("font", "font", "Font", "TkDefaultFont", "font"),
    O("foreground", "foreground", "Foreground", BLACK, "color"),
    O("labelanchor", "labelAnchor", "LabelAnchor", "nw", "enum:nw|n|ne|en|e|es|se|s|sw|ws|w|wn:labelanchor"),
    O("labelwidget", "labelWidget", "LabelWidget", "", "string"),
    O("relief", "relief", "Relief", "groove", "relief"),
    O("text", "text", "Text", "", "string"),
], key=lambda o: o[0])


class TkLabelframe(TkFrame):
    CLASS = "Labelframe"
    OPTS = LABELFRAME_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background", "fg": "foreground"}

    def frame_geometry(self):
        # tkFrame.c ComputeFrameGeometry for a labelframe: the label sits in
        # the border, the top internal border grows to hold it
        bd = self.px("borderwidth")
        hl = self.px("highlightthickness")
        px = self.px("padx")
        py = self.px("pady")
        lw, lh = self.label_size()
        la = self.opts["labelanchor"]
        top = hl + bd + py
        left = hl + bd + px
        right = hl + bd + px
        bottom = hl + bd + py
        if lw > 0 or lh > 0:
            if la[0] == "n":
                top = hl + max(bd, lh) + py
            elif la[0] == "s":
                bottom = hl + max(bd, lh) + py
            elif la[0] == "w":
                left = hl + max(bd, lw) + px
            elif la[0] == "e":
                right = hl + max(bd, lw) + px
        self.set_internal_borders(left, top, right, bottom)
        self.set_min_request(lw + 2 * (hl + bd) + 2 * 5 if la[0] in "ns" else left + right,
                             lh + 2 * (hl + bd) + 2 * 5 if la[0] in "ew" else top + bottom)
        w = self.px("width")
        hh = self.px("height")
        if w > 0 or hh > 0:
            self.request(w if w > 0 else self.reqw, hh if hh > 0 else self.reqh)

    def label_size(self):
        lw = self.opts.get("labelwidget", "")
        if lw:
            w = self.app.widgets.get(lw)
            if w is not None:
                return w.reqw, w.reqh
        t = self.opts.get("text", "")
        if t == "":
            return 0, 0
        f = self.app.font_of(self.opts["font"])
        lines, tw, th = layout_text(f, t)
        return tw + 4, th

    def label_box(self):
        lw, lh = self.label_size()
        hl = self.px("highlightthickness")
        la = self.opts["labelanchor"]
        if la[0] == "n" or la[0] == "s":
            if la in ("nw", "sw"):
                x = hl + self.px("borderwidth") + 5
            elif la in ("ne", "se"):
                x = self.width - hl - self.px("borderwidth") - 5 - lw
            else:
                x = (self.width - lw) // 2
            y = hl if la[0] == "n" else self.height - hl - lh
        else:
            x = hl if la[0] == "w" else self.width - hl - lw
            y = hl + self.px("borderwidth") + 5
        return x, y, lw, lh

    def arrange_slaves(self):
        lw = self.opts.get("labelwidget", "")
        if lw:
            w = self.app.widgets.get(lw)
            if w is not None and not w.destroyed:
                x, y, ww, hh = self.label_box()
                self.app.place_slave(self, w, x, y, ww, hh, True)

    def draw(self, h, ax, ay):
        bg = self.color("background")
        if bg is None:
            return
        fill(h, ax, ay, self.width, self.height, bg)
        hl = self.px("highlightthickness")
        bd = self.px("borderwidth")
        lx, ly, lw, lh = self.label_box()
        la = self.opts["labelanchor"]
        bx, by, bw, bh = hl, hl, self.width - 2 * hl, self.height - 2 * hl
        if lw > 0 and la[0] == "n":
            by = hl + max(0, (lh - bd) // 2)
            bh = self.height - by - hl
        draw_relief(h, ax + bx, ay + by, bw, bh, bd, self.opts["relief"], bg)
        t = self.opts.get("text", "")
        if t != "" and not self.opts.get("labelwidget"):
            fill(h, ax + lx, ay + ly, lw, lh, bg)
            f = self.app.font_of(self.opts["font"])
            draw_text(h, t, ax + lx + 2, ay + ly, f, self.color("foreground"))


# ── label, button, checkbutton, radiobutton ──────────────────────────────────

_COMPOUND = "enum:bottom|center|left|none|right|top:compound"
_BSTATE = "enum:active|disabled|normal:state"

LABEL_OPTS = [
    O("activebackground", "activeBackground", "Foreground", ACTIVE_BG, "color"),
    O("activeforeground", "activeForeground", "Background", BLACK, "color"),
    O("anchor", "anchor", "Anchor", "center", "anchor"),
    O("background", "background", "Background", NORMAL_BG, "color"),
    O("bitmap", "bitmap", "Bitmap", "", "bitmap"),
    O("borderwidth", "borderWidth", "BorderWidth", 1, "pixels"),
    O("compound", "compound", "Compound", "none", _COMPOUND),
    O("cursor", "cursor", "Cursor", "", "cursor"),
    O("disabledforeground", "disabledForeground", "DisabledForeground", DISABLED, "color_or_empty"),
    O("font", "font", "Font", "TkDefaultFont", "font"),
    O("foreground", "foreground", "Foreground", BLACK, "color"),
    O("height", "height", "Height", 0, "pixels"),
    O("highlightbackground", "highlightBackground", "HighlightBackground", NORMAL_BG, "color"),
    O("highlightcolor", "highlightColor", "HighlightColor", BLACK, "color"),
    O("highlightthickness", "highlightThickness", "HighlightThickness", 0, "pixels"),
    O("image", "image", "Image", "", "image"),
    O("justify", "justify", "Justify", "center", "justify"),
    O("padx", "padX", "Pad", 1, "pixels"),
    O("pady", "padY", "Pad", 1, "pixels"),
    O("relief", "relief", "Relief", "flat", "relief"),
    O("state", "state", "State", "normal", _BSTATE),
    O("takefocus", "takeFocus", "TakeFocus", "0", "string"),
    O("text", "text", "Text", "", "string"),
    O("textvariable", "textVariable", "Variable", "", "var"),
    O("underline", "underline", "Underline", -1, "int"),
    O("width", "width", "Width", 0, "pixels"),
    O("wraplength", "wrapLength", "WrapLength", 0, "pixels"),
]


def _replace(opts, changes, adds):
    out = []
    for o in opts:
        if o[0] in changes:
            out.append(changes[o[0]])
        else:
            out.append(o)
    out = out + adds
    return sorted(out, key=lambda o: o[0])


BUTTON_OPTS = _replace(LABEL_OPTS, {
    "highlightthickness": O("highlightthickness", "highlightThickness", "HighlightThickness", 1, "pixels"),
    "padx": O("padx", "padX", "Pad", "3m", "pixels"),
    "pady": O("pady", "padY", "Pad", "1m", "pixels"),
    "relief": O("relief", "relief", "Relief", "raised", "relief"),
    "takefocus": O("takefocus", "takeFocus", "TakeFocus", "", "string"),
}, [
    O("command", "command", "Command", "", "command"),
    O("default", "default", "Default", "disabled", "enum:active|disabled|normal:default"),
    O("overrelief", "overRelief", "OverRelief", "", "relief_or_empty"),
    O("repeatdelay", "repeatDelay", "RepeatDelay", 0, "int"),
    O("repeatinterval", "repeatInterval", "RepeatInterval", 0, "int"),
])

CHECK_OPTS = _replace(LABEL_OPTS, {
    "highlightthickness": O("highlightthickness", "highlightThickness", "HighlightThickness", 1, "pixels"),
    "anchor": O("anchor", "anchor", "Anchor", "center", "anchor"),
    "takefocus": O("takefocus", "takeFocus", "TakeFocus", "", "string"),
}, [
    O("command", "command", "Command", "", "command"),
    O("indicatoron", "indicatorOn", "IndicatorOn", 1, "boolean"),
    O("offrelief", "offRelief", "OffRelief", "raised", "relief"),
    O("offvalue", "offValue", "Value", "0", "string"),
    O("onvalue", "onValue", "Value", "1", "string"),
    O("overrelief", "overRelief", "OverRelief", "", "relief_or_empty"),
    O("selectcolor", "selectColor", "Background", WHITE, "color_or_empty"),
    O("selectimage", "selectImage", "SelectImage", "", "image"),
    O("tristateimage", "tristateImage", "TristateImage", "", "image"),
    O("tristatevalue", "tristateValue", "TristateValue", "", "string"),
    O("variable", "variable", "Variable", "", "var"),
])

RADIO_OPTS = sorted([o for o in CHECK_OPTS if o[0] not in ("offvalue", "onvalue", "variable")] + [
    O("value", "value", "Value", "", "string"),
    O("variable", "variable", "Variable", "selectedButton", "var"),
], key=lambda o: o[0])

TYPE_LABEL = 0
TYPE_BUTTON = 1
TYPE_CHECK = 2
TYPE_RADIO = 3


class TkLabel(TkWin):
    CLASS = "Label"
    OPTS = LABEL_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background", "fg": "foreground"}
    CMDS = ["cget", "configure"]
    TYPE = TYPE_LABEL
    A11Y_ROLE = "label"

    def __init__(self, app, path, parent, wclass=None):
        TkWin.__init__(self, app, path, parent, wclass)
        self.links = {}
        self.selected = False
        self.tristated = False
        self.inset = 0
        self.indicator_space = 0
        self.indicator_diameter = 0
        self.text_w = 0
        self.text_h = 0
        self.lines = []
        self.pressed = False
        self.hover = False

    def created(self):
        if self.TYPE == TYPE_CHECK and self.opts.get("variable", "") == "":
            self.opts["variable"] = self.name
        self.reconfigured(list(self.opts.keys()))

    def reconfigured(self, changed):
        if "textvariable" in changed:
            self._relink("textvariable", self._textvar_changed)
            name = self.opts.get("textvariable", "")
            if name:
                if name in self.app.vars:
                    self.opts["text"] = tcl_str(self.app.vars[name])
                else:
                    self.app.interp.setvar(name, self.opts.get("text", ""))
        if self.TYPE >= TYPE_CHECK and ("variable" in changed or "onvalue" in changed or "value" in changed
                                        or "tristatevalue" in changed or "offvalue" in changed):
            if "variable" in changed:
                self._relink("variable", self._var_changed)
            self._sync_selected(True)
        if "image" in changed:
            self.app.watch_image(self, self.opts.get("image", ""))
        self.compute_geometry()
        self.damage()

    def _relink(self, opt, cb):
        old = self.links.get(opt)
        if old is not None:
            self.app.remove_link(old)
            if old in self.var_links:
                self.var_links.remove(old)
            del self.links[opt]
        name = self.opts.get(opt, "")
        if name:
            lk = self.app.add_link(name, cb)
            self.links[opt] = lk
            self.var_links.append(lk)

    def _textvar_changed(self, name, op):
        if self.destroyed:
            return
        if op == "unset":
            self.app.vars[name] = self.opts.get("text", "")
            return
        self.opts["text"] = tcl_str(self.app.vars.get(name, ""))
        self.compute_geometry()
        self.damage()

    def _var_changed(self, name, op):
        if self.destroyed:
            return
        if op == "unset":
            v = (self.opts["onvalue"] if self.selected else self.opts["offvalue"]) if self.TYPE == TYPE_CHECK else (self.opts["value"] if self.selected else "")
            self.app.vars[name] = v
            return
        self._sync_selected(False)
        self.damage()

    def _sync_selected(self, create):
        name = self.opts.get("variable", "")
        if not name:
            return
        if name in self.app.vars:
            v = tcl_str(self.app.vars[name])
            on = self.opts["onvalue"] if self.TYPE == TYPE_CHECK else self.opts["value"]
            self.selected = (v == on)
            self.tristated = (not self.selected) and v == self.opts.get("tristatevalue", "")
        elif create:
            if self.TYPE == TYPE_CHECK:
                self.app.vars[name] = self.opts["offvalue"]
                self.selected = False
                self.tristated = self.opts["offvalue"] == self.opts.get("tristatevalue", "")
            else:
                self.app.vars[name] = ""
                self.selected = self.opts["value"] == ""
                self.tristated = False

    def font(self):
        return self.app.font_of(self.opts["font"])

    def image_size(self):
        name = self.opts.get("image", "")
        if self.TYPE >= TYPE_CHECK and self.selected and self.opts.get("selectimage", ""):
            name = self.opts["selectimage"]
        if name and name in self.app.images:
            im = self.app.images[name]
            return im.width(), im.height(), im
        bm = self.opts.get("bitmap", "")
        if bm:
            from _tkinter.image import builtin_bitmap
            b = builtin_bitmap(bm)
            if b is not None:
                return b[0], b[1], None
        return 0, 0, None

    def compute_geometry(self):
        # TkpComputeButtonGeometry (tkUnixButton.c)
        hl = self.px("highlightthickness")
        bd = self.px("borderwidth")
        self.inset = hl + bd
        if self.TYPE == TYPE_BUTTON and self.opts.get("default", "disabled") != "disabled":
            self.inset += 5
        self.indicator_space = 0
        padx = self.px("padx")
        pady = self.px("pady")
        iw, ih, im = self.image_size()
        have_image = iw > 0 or ih > 0 or (self.opts.get("image", "") != "") or (self.opts.get("bitmap", "") != "")
        width = iw
        height = ih
        tw = 0
        th = 0
        avg = 0
        have_text = False
        f = self.font()
        if not have_image or self.opts["compound"] != "none":
            self.lines, tw, th = layout_text(f, self.opts.get("text", ""), self.px("wraplength"), self.opts["justify"])
            self.text_w = tw
            self.text_h = th
            avg = f.measure("0")
            have_text = (tw != 0 and th != 0)
        asc, desc, ls, fixed = f.metrics()
        comp = self.opts["compound"]
        wopt = self.px("width")
        hopt = self.px("height")
        if comp != "none" and have_image and have_text:
            if comp in ("top", "bottom"):
                height += th + pady
                width = max(width, tw)
            elif comp in ("left", "right"):
                width += tw + padx
                height = max(height, th)
            else:
                width = max(width, tw)
                height = max(height, th)
            if wopt > 0:
                width = wopt
            if hopt > 0:
                height = hopt
            if self.TYPE >= TYPE_CHECK and self.opts.get("indicatoron", 0):
                self.indicator_space = height
                self.indicator_diameter = (65 * height) // 100 if self.TYPE == TYPE_CHECK else (75 * height) // 100
            width += 2 * padx
            height += 2 * pady
        elif have_image:
            if wopt > 0:
                width = wopt
            if hopt > 0:
                height = hopt
            if self.TYPE >= TYPE_CHECK and self.opts.get("indicatoron", 0):
                self.indicator_space = height
                self.indicator_diameter = (65 * height) // 100 if self.TYPE == TYPE_CHECK else (75 * height) // 100
        else:
            width = tw
            height = th
            if wopt > 0:
                width = wopt * avg
            if hopt > 0:
                height = hopt * ls
            if self.TYPE >= TYPE_CHECK and self.opts.get("indicatoron", 0):
                d = ls
                if self.TYPE == TYPE_CHECK:
                    d = (80 * d) // 100
                self.indicator_diameter = d
                self.indicator_space = d + avg
        if not have_image:
            width += 2 * padx
            height += 2 * pady
        if self.TYPE == TYPE_BUTTON:
            width += 2
            height += 2
        self.request(width + self.indicator_space + 2 * self.inset, height + 2 * self.inset)
        self.set_internal_border(self.inset)

    def current_relief(self):
        rel = self.opts["relief"]
        if self.TYPE >= TYPE_CHECK and not self.opts.get("indicatoron", 1):
            rel = "sunken" if self.selected else self.opts.get("offrelief", "raised")
        ov = self.opts.get("overrelief", "")
        if ov and self.hover and self.opts["state"] != "disabled" and not self.pressed:
            rel = ov
        return rel

    def draw(self, h, ax, ay):
        st = self.opts["state"]
        bgname = "activebackground" if st == "active" else "background"
        if self.TYPE >= TYPE_CHECK and not self.opts.get("indicatoron", 1) and self.selected and self.opts.get("selectcolor", ""):
            bgname = "selectcolor"
        bg = self.color(bgname)
        fill(h, ax, ay, self.width, self.height, bg)
        if st == "disabled":
            fg = self.color("disabledforeground") or self.color("foreground")
        elif st == "active":
            fg = self.color("activeforeground")
        else:
            fg = self.color("foreground")
        rel = self.current_relief()
        offset = 1 if self.TYPE == TYPE_BUTTON else 0
        padx = self.px("padx")
        pady = self.px("pady")
        iw, ih, im = self.image_size()
        comp = self.opts["compound"]
        have_image = iw > 0 or ih > 0
        f = self.font()
        if comp != "none" and have_image and self.text_w > 0:
            if comp in ("top", "bottom"):
                fw = max(iw, self.text_w)
                fh = ih + self.text_h + pady
            elif comp in ("left", "right"):
                fw = iw + self.text_w + padx
                fh = max(ih, self.text_h)
            else:
                fw = max(iw, self.text_w)
                fh = max(ih, self.text_h)
        elif have_image:
            fw, fh = iw, ih
        else:
            fw, fh = self.text_w, self.text_h
        x, y = self.compute_anchor(padx, pady, self.indicator_space + fw, fh)
        x += self.indicator_space
        x += offset
        y += offset
        if rel == "raised":
            x -= offset
            y -= offset
        elif rel == "sunken":
            x += offset
            y += offset
        tx, ty = x, y
        ix, iy = x, y
        if comp != "none" and have_image and self.text_w > 0:
            if comp == "top":
                ix = x + (fw - iw) // 2
                tx = x + (fw - self.text_w) // 2
                ty = y + ih + pady
            elif comp == "bottom":
                tx = x + (fw - self.text_w) // 2
                iy = y + self.text_h + pady
                ix = x + (fw - iw) // 2
            elif comp == "left":
                tx = x + iw + padx
                ty = y + (fh - self.text_h) // 2
                iy = y + (fh - ih) // 2
            elif comp == "right":
                ix = x + self.text_w + padx
                ty = y + (fh - self.text_h) // 2
                iy = y + (fh - ih) // 2
            else:
                ix = x + (fw - iw) // 2
                iy = y + (fh - ih) // 2
                tx = x + (fw - self.text_w) // 2
                ty = y + (fh - self.text_h) // 2
        if have_image:
            if im is not None:
                im.draw(h, ax + ix, ay + iy, iw, ih)
            else:
                self.draw_bitmap(h, ax + ix, ay + iy, fg)
        if not have_image or comp != "none":
            ul = self.opts.get("underline", -1)
            k = 0
            for (s, lx, lyy, lw) in self.lines:
                draw_text(h, s, ax + tx + lx, ay + ty + lyy, f, fg)
                if 0 <= ul - k < len(s):
                    c0 = f.measure(s[:ul - k])
                    c1 = f.measure(s[:ul - k + 1])
                    asc, desc, ls, fixed = f.metrics()
                    fill(h, ax + tx + lx + c0, ay + ty + lyy + asc + 1, c1 - c0, 1, fg)
                k += len(s) + 1
        if self.TYPE >= TYPE_CHECK and self.opts.get("indicatoron", 1):
            self.draw_indicator(h, ax + x - self.indicator_space, ay + y, fh)
        if rel != "flat":
            inset = self.px("highlightthickness")
            if self.TYPE == TYPE_BUTTON and self.opts.get("default") == "active":
                inset += 2
                draw_relief(h, ax + inset, ay + inset, self.width - 2 * inset, self.height - 2 * inset, 1, "sunken", bg)
                inset += 3
            elif self.TYPE == TYPE_BUTTON and self.opts.get("default") == "normal":
                inset += 5
            draw_relief(h, ax + inset, ay + inset, self.width - 2 * inset, self.height - 2 * inset,
                        self.px("borderwidth"), rel, bg)
        hl = self.px("highlightthickness")
        if hl > 0:
            c = self.color("highlightcolor") if self.has_focus else self.color("highlightbackground")
            draw_ring(h, ax, ay, self.width, self.height, hl, c)

    def compute_anchor(self, padx, pady, iw, ih):
        # TkComputeAnchor
        a = self.opts["anchor"]
        l, t, r, b = self.ib
        if a in ("nw", "w", "sw"):
            x = l + padx
        elif a in ("n", "center", "s"):
            x = (self.width - iw - l - r) // 2 + l
        else:
            x = self.width - r - padx - iw
        if a in ("nw", "n", "ne"):
            y = t + pady
        elif a in ("w", "center", "e"):
            y = (self.height - ih - t - b) // 2 + t
        else:
            y = self.height - b - pady - ih
        return x, y

    def draw_bitmap(self, h, x, y, fg):
        from _tkinter.image import builtin_bitmap
        b = builtin_bitmap(self.opts.get("bitmap", ""))
        if b is None:
            return
        w, hh, rows = b
        for yy in range(hh):
            row = rows[yy]
            xx = 0
            while xx < w:
                if (row >> xx) & 1:
                    x0 = xx
                    while xx < w and (row >> xx) & 1:
                        xx += 1
                    fill(h, x + x0, y + yy, xx - x0, 1, fg)
                else:
                    xx += 1

    def draw_indicator(self, h, x, y, fh):
        d = self.indicator_diameter
        if d <= 0:
            return
        cx = x + (self.indicator_space - d) // 2
        cy = y + (fh - d) // 2
        sel = self.color("selectcolor") if self.opts.get("selectcolor", "") else self.color("background")
        bg = self.color("background")
        light, dark = shades(bg)
        fg = self.color("foreground")
        if self.TYPE == TYPE_CHECK:
            fill(h, cx, cy, d, d, sel if (self.selected or True) else bg)
            draw_relief(h, cx, cy, d, d, max(1, self.px("borderwidth")), "sunken", bg)
            if self.selected:
                m = max(2, d // 4)
                pts = [(cx + m, cy + d // 2), (cx + d // 2 - 1, cy + d - m - 1), (cx + d - m, cy + m)]
                line(h, pts[0][0], pts[0][1], pts[1][0], pts[1][1], fg, 2)
                line(h, pts[1][0], pts[1][1], pts[2][0], pts[2][1], fg, 2)
            elif self.tristated:
                fill(h, cx + 3, cy + d // 2 - 1, d - 6, 2, fg)
        else:
            r = d / 2.0
            gui_fill_circle(h, cx + r, cy + r, r, (dark >> 16) & 255, (dark >> 8) & 255, dark & 255, 255)
            gui_fill_circle(h, cx + r, cy + r, r - 1, (sel >> 16) & 255, (sel >> 8) & 255, sel & 255, 255)
            if self.selected:
                gui_fill_circle(h, cx + r, cy + r, max(1.0, r / 2.5), (fg >> 16) & 255, (fg >> 8) & 255, fg & 255, 255)


class TkButton(TkLabel):
    CLASS = "Button"
    OPTS = BUTTON_OPTS
    CMDS = ["cget", "configure", "flash", "invoke"]
    TYPE = TYPE_BUTTON
    TAKES_FOCUS = True
    A11Y_ROLE = "button"

    def w_invoke(self, args):
        if self.opts["state"] == "disabled":
            return ""
        return self.do_invoke()

    def do_invoke(self):
        cmd = self.opts.get("command", "")
        if cmd:
            return self.app.interp.eval(cmd)
        return ""

    def w_flash(self, args):
        if self.opts["state"] == "disabled":
            return ""
        old = self.opts["state"]
        for k in range(4):
            self.opts["state"] = "normal" if self.opts["state"] == "active" else "active"
            self.damage()
            self.app.update(True)
        self.opts["state"] = old
        self.damage()
        return ""


class TkCheckbutton(TkButton):
    CLASS = "Checkbutton"
    OPTS = CHECK_OPTS
    CMDS = ["cget", "configure", "deselect", "flash", "invoke", "select", "toggle"]
    TYPE = TYPE_CHECK
    A11Y_ROLE = "checkbox"

    def set_var(self, v):
        name = self.opts.get("variable", "")
        if name:
            self.app.interp.setvar(name, v)
        else:
            self.selected = (v == self.opts.get("onvalue"))
            self.damage()

    def w_select(self, args):
        self.set_var(self.opts["onvalue"])
        return ""

    def w_deselect(self, args):
        self.set_var(self.opts["offvalue"])
        return ""

    def w_toggle(self, args):
        self.set_var(self.opts["offvalue"] if self.selected else self.opts["onvalue"])
        return ""

    def do_invoke(self):
        self.set_var(self.opts["offvalue"] if self.selected else self.opts["onvalue"])
        return TkButton.do_invoke(self)


class TkRadiobutton(TkButton):
    CLASS = "Radiobutton"
    OPTS = RADIO_OPTS
    CMDS = ["cget", "configure", "deselect", "flash", "invoke", "select"]
    TYPE = TYPE_RADIO
    A11Y_ROLE = "radio"

    def w_select(self, args):
        self.app.interp.setvar(self.opts["variable"], self.opts["value"])
        return ""

    def w_deselect(self, args):
        if self.selected:
            self.app.interp.setvar(self.opts["variable"], "")
        return ""

    def do_invoke(self):
        if not self.selected:
            self.app.interp.setvar(self.opts["variable"], self.opts["value"])
        return TkButton.do_invoke(self)


# button.tcl's procs, with tk::Priv as module state per application
def _priv(app):
    p = getattr(app, "tkpriv", None)
    if p is None:
        p = {"window": None, "buttonWindow": None, "relief": "", "afterId": "", "x": 0, "y": 0,
             "selectMode": "char", "mouseMoved": 0, "pressX": 0, "initPos": None, "listboxPrev": None,
             "listboxSelection": [], "activeMenu": None}
        app.tkpriv = p
    return p


def _w(app, args):
    return app.window(args[0])


def ButtonEnter(app, args):
    w = _w(app, args)
    p = _priv(app)
    if w.opts["state"] != "disabled":
        w.opts["state"] = "active"
        w.hover = True
        if p["buttonWindow"] is w:
            w.pressed = True
            w.opts["relief"] = "sunken"
        w.damage()
    p["window"] = w
    return ""


def ButtonLeave(app, args):
    w = _w(app, args)
    p = _priv(app)
    if w.opts["state"] != "disabled":
        w.opts["state"] = "normal"
    w.hover = False
    if p["buttonWindow"] is w:
        w.opts["relief"] = p["relief"]
        w.pressed = False
    p["window"] = None
    w.damage()
    return ""


def ButtonDown(app, args):
    w = _w(app, args)
    p = _priv(app)
    p["relief"] = w.opts["relief"]
    if w.opts["state"] != "disabled":
        p["buttonWindow"] = w
        w.pressed = True
        w.opts["relief"] = "sunken"
        w.damage()
        delay = w.opts.get("repeatdelay", 0)
        if delay > 0:
            _repeat(app, w, delay)
    return ""


def _repeat(app, w, ms):
    p = _priv(app)

    def again():
        if p["buttonWindow"] is w and p["window"] is w and not w.destroyed:
            w.do_invoke()
            iv = w.opts.get("repeatinterval", 0)
            if iv > 0:
                _repeat(app, w, iv)

    name = "::tk::repeat" + str(id(w))
    app.interp.commands[name] = lambda it, words: again()
    p["afterId"] = app.c_after([ms, name])


def ButtonUp(app, args):
    w = _w(app, args)
    p = _priv(app)
    if p["buttonWindow"] is w:
        p["buttonWindow"] = None
        w.opts["relief"] = p["relief"]
        w.pressed = False
        w.damage()
        if p["afterId"]:
            app.c_after(["cancel", p["afterId"]])
            p["afterId"] = ""
        if p["window"] is w and w.opts["state"] != "disabled":
            app.interp.invoke([w.path, "invoke"])
    return ""


def ButtonInvoke(app, args):
    w = _w(app, args)
    if w.opts["state"] != "disabled":
        old = w.opts["relief"]
        oldstate = w.opts["state"]
        w.opts["relief"] = "sunken"
        w.opts["state"] = "active"
        w.damage()
        app.update(True)
        if not w.destroyed:
            w.opts["state"] = oldstate
            w.opts["relief"] = old
            w.damage()
            app.interp.invoke([w.path, "invoke"])
    return ""


def CheckInvoke(app, args):
    w = _w(app, args)
    if w.opts["state"] != "disabled":
        app.interp.invoke([w.path, "invoke"])
    return ""


def CheckEnter(app, args):
    w = _w(app, args)
    p = _priv(app)
    if w.opts["state"] != "disabled":
        w.opts["state"] = "active"
        w.hover = True
        w.damage()
    p["window"] = w
    return ""


def CheckLeave(app, args):
    w = _w(app, args)
    p = _priv(app)
    if w.opts["state"] != "disabled":
        w.opts["state"] = "normal"
    w.hover = False
    p["window"] = None
    w.damage()
    return ""


# ── message ──────────────────────────────────────────────────────────────────

MESSAGE_OPTS = [
    O("anchor", "anchor", "Anchor", "center", "anchor"),
    O("aspect", "aspect", "Aspect", 150, "int"),
    O("background", "background", "Background", NORMAL_BG, "color"),
    O("borderwidth", "borderWidth", "BorderWidth", 1, "pixels"),
    O("cursor", "cursor", "Cursor", "", "cursor"),
    O("font", "font", "Font", "TkDefaultFont", "font"),
    O("foreground", "foreground", "Foreground", BLACK, "color"),
    O("highlightbackground", "highlightBackground", "HighlightBackground", NORMAL_BG, "color"),
    O("highlightcolor", "highlightColor", "HighlightColor", BLACK, "color"),
    O("highlightthickness", "highlightThickness", "HighlightThickness", 0, "pixels"),
    O("justify", "justify", "Justify", "left", "justify"),
    O("padx", "padX", "Pad", -1, "pixels"),
    O("pady", "padY", "Pad", -1, "pixels"),
    O("relief", "relief", "Relief", "flat", "relief"),
    O("takefocus", "takeFocus", "TakeFocus", "0", "string"),
    O("text", "text", "Text", "", "string"),
    O("textvariable", "textVariable", "Variable", "", "var"),
    O("width", "width", "Width", 0, "pixels"),
]


class TkMessage(TkLabel):
    CLASS = "Message"
    OPTS = MESSAGE_OPTS
    TYPE = TYPE_LABEL
    A11Y_ROLE = "label"

    def compute_geometry(self):
        # tkMessage.c ComputeMessageGeometry: widen or narrow until the
        # aspect ratio (100 * width / height) is within 10% of -aspect
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        padx = self.px("padx")
        pady = self.px("pady")
        if padx < 0:
            padx = asc // 4
        if pady < 0:
            pady = asc // 4
        self.padx_eff = padx
        self.pady_eff = pady
        inset = self.px("borderwidth") + self.px("highlightthickness")
        aspect = self.opts["aspect"] // 10
        if aspect < 5:
            aspect = 5
        lower = self.opts["aspect"] - aspect
        upper = self.opts["aspect"] + aspect
        if self.px("width") > 0:
            width = self.px("width")
            inc = 0
        else:
            width = SCREEN.width // 2
            inc = width // 2
        t = self.opts.get("text", "")
        while True:
            self.lines, tw, th = layout_text(f, t, width, self.opts["justify"])
            maxw = tw + 2 * (inset + padx)
            height = th + 2 * (inset + pady)
            if inc <= 2:
                break
            asp = (100 * maxw) // height
            if asp < lower:
                width += inc
            elif asp > upper:
                width -= inc
            else:
                break
            inc = inc // 2
        self.text_w = tw
        self.text_h = th
        self.request(maxw, height)
        self.set_internal_border(inset)

    def draw(self, h, ax, ay):
        bg = self.color("background")
        fill(h, ax, ay, self.width, self.height, bg)
        x, y = self.compute_anchor(self.padx_eff, self.pady_eff, self.text_w, self.text_h)
        f = self.font()
        fg = self.color("foreground")
        for (s, lx, ly, lw) in self.lines:
            draw_text(h, s, ax + x + lx, ay + y + ly, f, fg)
        draw_relief(h, ax + self.px("highlightthickness"), ay + self.px("highlightthickness"),
                    self.width - 2 * self.px("highlightthickness"), self.height - 2 * self.px("highlightthickness"),
                    self.px("borderwidth"), self.opts["relief"], bg)


# ── scrollbar ────────────────────────────────────────────────────────────────

SCROLLBAR_OPTS = [
    O("activebackground", "activeBackground", "Foreground", ACTIVE_BG, "color"),
    O("activerelief", "activeRelief", "Relief", "raised", "relief"),
    O("background", "background", "Background", NORMAL_BG, "color"),
    O("borderwidth", "borderWidth", "BorderWidth", 1, "pixels"),
    O("command", "command", "Command", "", "command"),
    O("cursor", "cursor", "Cursor", "", "cursor"),
    O("elementborderwidth", "elementBorderWidth", "BorderWidth", -1, "pixels"),
    O("highlightbackground", "highlightBackground", "HighlightBackground", NORMAL_BG, "color"),
    O("highlightcolor", "highlightColor", "HighlightColor", BLACK, "color"),
    O("highlightthickness", "highlightThickness", "HighlightThickness", 0, "pixels"),
    O("jump", "jump", "Jump", 0, "boolean"),
    O("orient", "orient", "Orient", "vertical", "enum:horizontal|vertical:orientation"),
    O("relief", "relief", "Relief", "sunken", "relief"),
    O("repeatdelay", "repeatDelay", "RepeatDelay", 300, "int"),
    O("repeatinterval", "repeatInterval", "RepeatInterval", 100, "int"),
    O("takefocus", "takeFocus", "TakeFocus", "", "string"),
    O("troughcolor", "troughColor", "Background", TROUGH, "color"),
    O("width", "width", "Width", 11, "pixels"),
]

MIN_SLIDER_LENGTH = 5


class TkScrollbar(TkWin):
    CLASS = "Scrollbar"
    OPTS = SCROLLBAR_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background"}
    CMDS = ["activate", "cget", "configure", "delta", "fraction", "get", "identify", "set"]
    TAKES_FOCUS = True
    A11Y_ROLE = "scrollbar"

    def __init__(self, app, path, parent, wclass=None):
        TkWin.__init__(self, app, path, parent, wclass)
        self.first = 0.0
        self.last = 1.0
        self.new_style = True
        self.total = 0
        self.window_units = 0
        self.first_unit = 0
        self.last_unit = 0
        self.active_field = ""
        self.inset = 0
        self.arrow_length = 0
        self.slider_first = 0
        self.slider_last = 0

    def vertical(self):
        return self.opts["orient"] == "vertical"

    def compute_geometry(self):
        hl = self.px("highlightthickness")
        bd = self.px("borderwidth")
        self.inset = hl + bd
        width = self.width if self.vertical() else self.height
        self.arrow_length = width - 2 * self.inset + 1
        field = (self.height if self.vertical() else self.width) - 2 * (self.arrow_length + self.inset)
        if field < 0:
            field = 0
        sf = int(field * self.first)
        sl = int(field * self.last)
        if sf > field - MIN_SLIDER_LENGTH:
            sf = field - MIN_SLIDER_LENGTH
        if sf < 0:
            sf = 0
        if sl < sf + MIN_SLIDER_LENGTH:
            sl = sf + MIN_SLIDER_LENGTH
        if sl > field:
            sl = field
        self.slider_first = sf + self.arrow_length + self.inset
        self.slider_last = sl + self.arrow_length + self.inset
        w = self.px("width")
        if self.vertical():
            self.request(w + 2 * self.inset, 2 * (self.arrow_length + bd + self.inset))
        else:
            self.request(2 * (self.arrow_length + bd + self.inset), w + 2 * self.inset)
        self.set_internal_border(self.inset)

    def on_resize(self):
        self.compute_geometry()

    def w_set(self, args):
        if len(args) == 2:
            f = get_double(args[0])
            l = get_double(args[1])
            f = max(0.0, min(1.0, f))
            l = max(f, min(1.0, l))
            self.first = f
            self.last = l
            self.new_style = True
        elif len(args) == 4:
            self.total = get_int(args[0])
            self.window_units = get_int(args[1])
            self.first_unit = get_int(args[2])
            self.last_unit = get_int(args[3])
            self.new_style = False
            if self.total > 0:
                self.first = max(0.0, min(1.0, self.first_unit / float(self.total)))
                self.last = max(self.first, min(1.0, (self.last_unit + 1) / float(self.total)))
            else:
                self.first = 0.0
                self.last = 1.0
        else:
            raise TclError("wrong # args: should be \"" + self.path + " set firstFraction lastFraction\" or \"" +
                           self.path + " set totalUnits windowUnits firstUnit lastUnit\"")
        self.compute_geometry()
        self.damage()
        return ""

    def w_get(self, args):
        if self.new_style:
            return (self.first, self.last)
        return (self.total, self.window_units, self.first_unit, self.last_unit)

    def w_activate(self, args):
        if not args:
            return self.active_field
        e = tcl_str(args[0])
        self.active_field = e if e in ("arrow1", "slider", "arrow2") else ""
        self.damage()
        return ""

    def w_identify(self, args):
        x = pixels(args[0])
        y = pixels(args[1])
        return self.identify(x, y)

    def identify(self, x, y):
        if not self.vertical():
            x, y = y, x
            length = self.width
            breadth = self.height
        else:
            length = self.height
            breadth = self.width
        if x < self.inset or x >= breadth - self.inset or y < self.inset or y >= length - self.inset:
            return ""
        if y < self.inset + self.arrow_length:
            return "arrow1"
        if y < self.slider_first:
            return "trough1"
        if y < self.slider_last:
            return "slider"
        if y >= length - (self.arrow_length + self.inset):
            return "arrow2"
        return "trough2"

    def w_fraction(self, args):
        x = pixels(args[0])
        y = pixels(args[1])
        length = (self.height if self.vertical() else self.width) - 1 - 2 * (self.arrow_length + self.inset) - (self.slider_last - self.slider_first)
        if length <= 0:
            return 0.0
        pos = (y if self.vertical() else x) - (self.arrow_length + self.inset)
        f = pos / float(length)
        return max(0.0, min(1.0, f))

    def w_delta(self, args):
        dx = pixels(args[0])
        dy = pixels(args[1])
        length = (self.height if self.vertical() else self.width) - 1 - 2 * (self.arrow_length + self.inset) - (self.slider_last - self.slider_first)
        if length <= 0:
            return 0.0
        return (dy if self.vertical() else dx) / float(length)

    def draw(self, h, ax, ay):
        bg = self.color("background")
        trough = self.color("troughcolor")
        fill(h, ax, ay, self.width, self.height, trough)
        bd = self.px("borderwidth")
        hl = self.px("highlightthickness")
        draw_relief(h, ax + hl, ay + hl, self.width - 2 * hl, self.height - 2 * hl, bd, self.opts["relief"], bg)
        ebd = self.px("elementborderwidth")
        if ebd < 0:
            ebd = bd
        ins = self.inset
        al = self.arrow_length
        v = self.vertical()
        act = self.color("activebackground")
        for which in ("arrow1", "arrow2"):
            col = act if self.active_field == which else bg
            if v:
                bx, by, bw, bh = ins, (ins if which == "arrow1" else self.height - ins - al), self.width - 2 * ins, al
            else:
                bx, by, bw, bh = (ins if which == "arrow1" else self.width - ins - al), ins, al, self.height - 2 * ins
            self._arrow(h, ax + bx, ay + by, bw, bh, which, v, col, ebd)
        col = act if self.active_field == "slider" else bg
        if v:
            fill(h, ax + ins, ay + self.slider_first, self.width - 2 * ins, self.slider_last - self.slider_first, col)
            draw_relief(h, ax + ins, ay + self.slider_first, self.width - 2 * ins, self.slider_last - self.slider_first, ebd, "raised", col)
        else:
            fill(h, ax + self.slider_first, ay + ins, self.slider_last - self.slider_first, self.height - 2 * ins, col)
            draw_relief(h, ax + self.slider_first, ay + ins, self.slider_last - self.slider_first, self.height - 2 * ins, ebd, "raised", col)
        if hl > 0:
            c = self.color("highlightcolor") if self.has_focus else self.color("highlightbackground")
            draw_ring(h, ax, ay, self.width, self.height, hl, c)

    def _arrow(self, h, x, y, w, hh, which, vertical, col, bd):
        if w <= 0 or hh <= 0:
            return
        light, dark = shades(col)
        if vertical:
            if which == "arrow1":
                pts = [x + w / 2.0, y, x, y + hh - 1, x + w - 1, y + hh - 1]
            else:
                pts = [x, y, x + w - 1, y, x + w / 2.0, y + hh - 1]
        else:
            if which == "arrow1":
                pts = [x, y + hh / 2.0, x + w - 1, y, x + w - 1, y + hh - 1]
            else:
                pts = [x, y, x + w - 1, y + hh / 2.0, x, y + hh - 1]
        gui_fill_polygon(h, pts, 3, (col >> 16) & 255, (col >> 8) & 255, col & 255, 255)
        gui_draw_polygon(h, pts, 3, (dark >> 16) & 255, (dark >> 8) & 255, dark & 255, 255)


def _scroll_cmd(app, w, args):
    cmd = w.opts.get("command", "")
    if cmd:
        app.eval_bg(cmd + " " + " ".join([str(a) for a in args]))


def ScrollButtonDown(app, args):
    w = _w(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    p = _priv(app)
    p["relief"] = w.opts["activerelief"]
    el = w.identify(x, y)
    p["scrollElement"] = el
    if el == "arrow1":
        ScrollByUnits(app, [w.path, "hv", -1])
        _scroll_repeat(app, w, -1, "units")
    elif el == "trough1":
        ScrollByPages(app, [w.path, "hv", -1])
        _scroll_repeat(app, w, -1, "pages")
    elif el == "trough2":
        ScrollByPages(app, [w.path, "hv", 1])
        _scroll_repeat(app, w, 1, "pages")
    elif el == "arrow2":
        ScrollByUnits(app, [w.path, "hv", 1])
        _scroll_repeat(app, w, 1, "units")
    elif el == "slider":
        p["initMouse"] = (x, y)
        p["initValue"] = w.first
        p["dragging"] = w
    return ""


def _scroll_repeat(app, w, n, what):
    p = _priv(app)

    def again():
        if p.get("scrollElement") and not w.destroyed and app.buttons & B.Button1Mask:
            if what == "units":
                ScrollByUnits(app, [w.path, "hv", n])
            else:
                ScrollByPages(app, [w.path, "hv", n])
            name2 = "::tk::srepeat" + str(id(w))
            p["afterId"] = app.c_after([w.opts["repeatinterval"], name2])

    name = "::tk::srepeat" + str(id(w))
    app.interp.commands[name] = lambda it, words: again()
    p["afterId"] = app.c_after([w.opts["repeatdelay"], name])


def ScrollDrag(app, args):
    w = _w(app, args)
    p = _priv(app)
    if p.get("dragging") is not w:
        return ""
    x = get_int(args[1])
    y = get_int(args[2])
    x0, y0 = p["initMouse"]
    delta = w.w_delta([x - x0, y - y0])
    if w.new_style:
        _scroll_cmd(app, w, ["moveto", fmt_frac(p["initValue"] + delta)])
    else:
        _scroll_cmd(app, w, [int(round((p["initValue"] + delta) * w.total))])
    return ""


def ScrollButtonUp(app, args):
    w = _w(app, args)
    p = _priv(app)
    p["scrollElement"] = ""
    p["dragging"] = None
    if p.get("afterId"):
        app.c_after(["cancel", p["afterId"]])
        p["afterId"] = ""
    return ""


def ScrollByUnits(app, args):
    w = _w(app, args)
    n = get_int(args[2])
    if w.new_style:
        _scroll_cmd(app, w, ["scroll", n, "units"])
    else:
        _scroll_cmd(app, w, [w.first_unit + n])
    return ""


def ScrollByPages(app, args):
    w = _w(app, args)
    n = get_int(args[2])
    if w.new_style:
        _scroll_cmd(app, w, ["scroll", n, "pages"])
    else:
        _scroll_cmd(app, w, [w.first_unit + n * (w.window_units - 1)])
    return ""


def ScrollToPos(app, args):
    w = _w(app, args)
    _scroll_cmd(app, w, ["moveto", fmt_frac(get_double(args[1]))])
    return ""


def ScrollActivate(app, args):
    w = _w(app, args)
    if len(args) > 1:
        w.w_activate([w.identify(get_int(args[1]), get_int(args[2]))])
    else:
        w.w_activate([""])
    return ""


# ── scale ────────────────────────────────────────────────────────────────────

SCALE_OPTS = [
    O("activebackground", "activeBackground", "Foreground", ACTIVE_BG, "color"),
    O("background", "background", "Background", NORMAL_BG, "color"),
    O("bigincrement", "bigIncrement", "BigIncrement", 0.0, "double"),
    O("borderwidth", "borderWidth", "BorderWidth", 1, "pixels"),
    O("command", "command", "Command", "", "command"),
    O("cursor", "cursor", "Cursor", "", "cursor"),
    O("digits", "digits", "Digits", 0, "int"),
    O("font", "font", "Font", "TkDefaultFont", "font"),
    O("foreground", "foreground", "Foreground", BLACK, "color"),
    O("from", "from", "From", 0.0, "double"),
    O("highlightbackground", "highlightBackground", "HighlightBackground", NORMAL_BG, "color"),
    O("highlightcolor", "highlightColor", "HighlightColor", BLACK, "color"),
    O("highlightthickness", "highlightThickness", "HighlightThickness", 1, "pixels"),
    O("label", "label", "Label", "", "string"),
    O("length", "length", "Length", 100, "pixels"),
    O("orient", "orient", "Orient", "vertical", "enum:horizontal|vertical:orientation"),
    O("relief", "relief", "Relief", "flat", "relief"),
    O("repeatdelay", "repeatDelay", "RepeatDelay", 300, "int"),
    O("repeatinterval", "repeatInterval", "RepeatInterval", 100, "int"),
    O("resolution", "resolution", "Resolution", 1.0, "double"),
    O("showvalue", "showValue", "ShowValue", 1, "boolean"),
    O("sliderlength", "sliderLength", "SliderLength", 30, "pixels"),
    O("sliderrelief", "sliderRelief", "SliderRelief", "raised", "relief"),
    O("state", "state", "State", "normal", _BSTATE),
    O("takefocus", "takeFocus", "TakeFocus", "", "string"),
    O("tickinterval", "tickInterval", "TickInterval", 0.0, "double"),
    O("to", "to", "To", 100.0, "double"),
    O("troughcolor", "troughColor", "Background", TROUGH, "color"),
    O("variable", "variable", "Variable", "", "var"),
    O("width", "width", "Width", 15, "pixels"),
]

SPACING = 2


class TkScale(TkWin):
    CLASS = "Scale"
    OPTS = SCALE_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background", "fg": "foreground"}
    CMDS = ["cget", "configure", "coords", "get", "identify", "set"]
    TAKES_FOCUS = True
    A11Y_ROLE = "slider"

    def __init__(self, app, path, parent, wclass=None):
        TkWin.__init__(self, app, path, parent, wclass)
        self.value = 0.0
        self.fmt = "%.0f"
        self.inset = 0
        self.links = {}
        self.dragging = False
        self.active = False
        self.horiz = {}

    def created(self):
        self.value = self.round_to_res(self.opts["from"])
        self.reconfigured(list(self.opts.keys()))

    def reconfigured(self, changed):
        self.compute_format()
        if "variable" in changed:
            old = self.links.get("variable")
            if old is not None:
                self.app.remove_link(old)
                del self.links["variable"]
            name = self.opts.get("variable", "")
            if name:
                if name in self.app.vars:
                    try:
                        self.value = self.round_to_res(get_double(self.app.vars[name]))
                    except TclError:
                        pass
                lk = self.app.add_link(name, self._var_changed)
                self.links["variable"] = lk
                self.var_links.append(lk)
        self.value = self.constrain(self.value)
        if "from" in changed or "to" in changed or "resolution" in changed or "variable" in changed:
            self.set_var()
        self.compute_geometry()
        self.damage()

    def _var_changed(self, name, op):
        if self.destroyed:
            return
        if op == "unset":
            self.app.vars[name] = self.value
            return
        try:
            v = get_double(self.app.vars[name])
        except TclError:
            return
        self.value = self.constrain(self.round_to_res(v))
        self.damage()

    def set_var(self):
        name = self.opts.get("variable", "")
        if name:
            v = self.formatted_value()
            cur = self.app.vars.get(name)
            if cur is None or tcl_str(cur) != tcl_str(self.value_obj()):
                self.app.interp.setvar(name, self.value_obj())

    def value_obj(self):
        # ScaleSetVariable: the variable gets the value formatted as shown
        return self.fmt % self.value

    def compute_format(self):
        # tkScale.c ComputeFormat
        maxv = max(abs(self.opts["from"]), abs(self.opts["to"]))
        if maxv == 0:
            maxv = 1
        most = int(math.floor(math.log10(maxv)))
        num = self.opts["digits"]
        if num > 17:
            num = 0
        if num <= 0:
            res = self.opts["resolution"]
            if res > 0:
                least = int(math.floor(math.log10(res)))
            else:
                x = abs(self.opts["from"] - self.opts["to"])
                ln = self.px("length")
                if ln > 0:
                    x /= ln
                least = int(math.floor(math.log10(x))) if x > 0 else 0
            num = most - least + 1
            if num < 1:
                num = 1
        edigits = num + 4
        if num > 1:
            edigits += 1
        after = num - most - 1
        if after < 0:
            after = 0
        fdigits = most + after if most >= 0 else after
        if after > 0:
            fdigits += 1
        if most < 0:
            fdigits += 1
        if fdigits <= edigits:
            self.fmt = "%." + str(after) + "f"
        else:
            self.fmt = "%." + str(num - 1) + "e"

    def formatted_value(self):
        return self.fmt % self.value

    def round_to_res(self, value):
        res = self.opts["resolution"]
        if res <= 0:
            return value
        v = value - self.opts["from"]
        tick = math.floor(v / res)
        rounded = res * tick
        rem = v - rounded
        if rem >= res / 2.0:
            rounded += res
        return rounded + self.opts["from"]

    def constrain(self, v):
        f = self.opts["from"]
        t = self.opts["to"]
        if f < t:
            v = max(f, min(t, v))
        else:
            v = max(t, min(f, v))
        return v

    def compute_geometry(self):
        f = self.app.font_of(self.opts["font"])
        asc, desc, ls, fixed = f.metrics()
        hl = self.px("highlightthickness")
        bd = self.px("borderwidth")
        self.inset = hl + bd
        fh = ls + SPACING
        self.font_height = fh
        if self.opts["orient"] == "horizontal":
            y = self.inset
            extra = 0
            lab = self.opts.get("label", "")
            if lab != "":
                self.horiz["labelY"] = y + SPACING
                y += fh
                extra = SPACING
            if self.opts["showvalue"]:
                self.horiz["valueY"] = y + SPACING
                y += fh
                extra = SPACING
            else:
                self.horiz["valueY"] = y
            y += extra
            self.horiz["troughY"] = y
            y += self.px("width") + 2 * bd
            if self.opts["tickinterval"] != 0:
                self.horiz["tickY"] = y + SPACING
                y += fh + SPACING
            self.request(self.px("length") + 2 * self.inset, y + self.inset)
            self.set_internal_border(self.inset)
            return
        vp = f.measure(self.fmt % self.opts["from"])
        vp = max(vp, f.measure(self.fmt % self.opts["to"]))
        x = self.inset
        if self.opts["tickinterval"] != 0 and self.opts["showvalue"]:
            self.horiz["tickRight"] = x + SPACING + vp
            self.horiz["valueRight"] = self.horiz["tickRight"] + vp + asc // 2
            x = self.horiz["valueRight"] + SPACING
        elif self.opts["tickinterval"] != 0:
            self.horiz["tickRight"] = x + SPACING + vp
            self.horiz["valueRight"] = self.horiz["tickRight"]
            x = self.horiz["tickRight"] + SPACING
        elif self.opts["showvalue"]:
            self.horiz["tickRight"] = x
            self.horiz["valueRight"] = x + SPACING + vp
            x = self.horiz["valueRight"] + SPACING
        else:
            self.horiz["tickRight"] = x
            self.horiz["valueRight"] = x
        self.horiz["troughX"] = x
        x += 2 * bd + self.px("width")
        lab = self.opts.get("label", "")
        if lab == "":
            self.horiz["labelX"] = 0
        else:
            self.horiz["labelX"] = x + asc // 2
            x = self.horiz["labelX"] + asc // 2 + f.measure(lab)
        self.request(x + self.inset, self.px("length") + 2 * self.inset)
        self.set_internal_border(self.inset)

    def pixel_range(self):
        bd = self.px("borderwidth")
        n = self.height if self.opts["orient"] == "vertical" else self.width
        return n - self.px("sliderlength") - 2 * self.inset - 2 * bd

    def value_to_pixel(self, value):
        bd = self.px("borderwidth")
        vr = self.opts["to"] - self.opts["from"]
        pr = self.pixel_range()
        if vr == 0:
            y = 0
        else:
            y = int((value - self.opts["from"]) * pr / vr + 0.5)
            if y < 0:
                y = 0
            elif y > pr:
                y = pr
        return y + self.px("sliderlength") // 2 + self.inset + bd

    def pixel_to_value(self, x, y):
        bd = self.px("borderwidth")
        pr = self.pixel_range()
        v = y if self.opts["orient"] == "vertical" else x
        if pr <= 0:
            return self.value
        v -= self.px("sliderlength") // 2 + self.inset + bd
        v = v / float(pr)
        v = max(0.0, min(1.0, v))
        v = self.opts["from"] + v * (self.opts["to"] - self.opts["from"])
        return self.round_to_res(v)

    def set_value(self, v, invoke=True, setvar=True):
        v = self.constrain(self.round_to_res(v))
        changed = (self.fmt % v) != (self.fmt % self.value)
        self.value = v
        if setvar:
            self.set_var()
        self.damage()
        if changed and invoke and self.opts.get("command", ""):
            self.app.after_idle_script(self.opts["command"] + " " + self.formatted_value())

    def w_get(self, args):
        if len(args) == 2:
            v = self.pixel_to_value(pixels(args[0]), pixels(args[1]))
        else:
            v = self.value
        s = self.fmt % v
        try:
            return get_int(s)
        except TclError:
            return float(s)

    def w_set(self, args):
        if self.opts["state"] == "disabled":
            return ""
        self.set_value(get_double(args[0]))
        return ""

    def w_coords(self, args):
        v = get_double(args[0]) if args else self.value
        p = self.value_to_pixel(v)
        if self.opts["orient"] == "vertical":
            return (self.horiz.get("troughX", 0) + self.px("width") // 2 + self.px("borderwidth"), p)
        return (p, self.horiz.get("troughY", 0) + self.px("width") // 2 + self.px("borderwidth"))

    def w_identify(self, args):
        return self.identify(pixels(args[0]), pixels(args[1]))

    def identify(self, x, y):
        bd = self.px("borderwidth")
        sl = self.px("sliderlength")
        if self.opts["orient"] == "vertical":
            tx = self.horiz.get("troughX", 0)
            if x < tx or x >= tx + self.px("width") + 2 * bd or y < self.inset or y >= self.height - self.inset:
                return ""
            sp = self.value_to_pixel(self.value) - sl // 2
            if y < sp:
                return "trough1"
            if y < sp + sl:
                return "slider"
            return "trough2"
        ty = self.horiz.get("troughY", 0)
        if y < ty or y >= ty + self.px("width") + 2 * bd or x < self.inset or x >= self.width - self.inset:
            return ""
        sp = self.value_to_pixel(self.value) - sl // 2
        if x < sp:
            return "trough1"
        if x < sp + sl:
            return "slider"
        return "trough2"

    def draw(self, h, ax, ay):
        bg = self.color("background")
        fill(h, ax, ay, self.width, self.height, bg)
        f = self.app.font_of(self.opts["font"])
        fg = self.color("foreground")
        bd = self.px("borderwidth")
        sl = self.px("sliderlength")
        wd = self.px("width")
        trough = self.color("troughcolor")
        scol = self.color("activebackground") if self.active else bg
        pos = self.value_to_pixel(self.value)
        if self.opts["orient"] == "horizontal":
            ty = self.horiz.get("troughY", 0)
            fill(h, ax + self.inset, ay + ty, self.width - 2 * self.inset, wd + 2 * bd, trough)
            draw_relief(h, ax + self.inset, ay + ty, self.width - 2 * self.inset, wd + 2 * bd, bd, "sunken", bg)
            fill(h, ax + pos - sl // 2, ay + ty + bd, sl, wd, scol)
            draw_relief(h, ax + pos - sl // 2, ay + ty + bd, sl, wd, bd, self.opts["sliderrelief"], scol)
            if self.opts["showvalue"]:
                s = self.formatted_value()
                draw_text(h, s, ax + pos - f.measure(s) // 2, ay + self.horiz["valueY"], f, fg)
            if self.opts.get("label", ""):
                draw_text(h, self.opts["label"], ax + self.inset + 2, ay + self.horiz["labelY"], f, fg)
        else:
            tx = self.horiz.get("troughX", 0)
            fill(h, ax + tx, ay + self.inset, wd + 2 * bd, self.height - 2 * self.inset, trough)
            draw_relief(h, ax + tx, ay + self.inset, wd + 2 * bd, self.height - 2 * self.inset, bd, "sunken", bg)
            fill(h, ax + tx + bd, ay + pos - sl // 2, wd, sl, scol)
            draw_relief(h, ax + tx + bd, ay + pos - sl // 2, wd, sl, bd, self.opts["sliderrelief"], scol)
            if self.opts["showvalue"]:
                s = self.formatted_value()
                asc, desc, ls, fixed = f.metrics()
                draw_text(h, s, ax + self.horiz["valueRight"] - f.measure(s), ay + pos - ls // 2, f, fg)
            if self.opts.get("label", ""):
                draw_text(h, self.opts["label"], ax + self.horiz["labelX"], ay + self.inset, f, fg)
        hl = self.px("highlightthickness")
        if hl > 0:
            c = self.color("highlightcolor") if self.has_focus else self.color("highlightbackground")
            draw_ring(h, ax, ay, self.width, self.height, hl, c)


def ScaleActivate(app, args):
    w = _w(app, args)
    if w.opts["state"] == "disabled":
        return ""
    on = w.identify(get_int(args[1]), get_int(args[2])) == "slider"
    if on != w.active:
        w.active = on
        w.damage()
    return ""


def ScaleButtonDown(app, args):
    w = _w(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    p = _priv(app)
    p["dragging"] = None
    el = w.identify(x, y)
    if el == "trough1":
        ScaleIncrement(app, [w.path, "up", "little", "initial"])
    elif el == "trough2":
        ScaleIncrement(app, [w.path, "down", "little", "initial"])
    elif el == "slider":
        p["dragging"] = w
        sx, sy = w.w_coords([])
        p["deltaX"] = x - sx
        p["deltaY"] = y - sy
        w.active = True
        w.damage()
    return ""


def ScaleDrag(app, args):
    w = _w(app, args)
    p = _priv(app)
    if p.get("dragging") is not w:
        return ""
    x = get_int(args[1]) - p["deltaX"]
    y = get_int(args[2]) - p["deltaY"]
    if w.opts["state"] != "disabled":
        w.set_value(w.pixel_to_value(x, y))
    return ""


def ScaleEndDrag(app, args):
    p = _priv(app)
    p["dragging"] = None
    return ""


def ScaleIncrement(app, args):
    w = _w(app, args)
    direction = tcl_str(args[1])
    big = tcl_str(args[2]) == "big"
    if w.opts["state"] == "disabled":
        return ""
    if big:
        inc = w.opts["bigincrement"]
        if inc == 0:
            inc = abs(w.opts["to"] - w.opts["from"]) / 10.0
            if inc < w.opts["resolution"]:
                inc = w.opts["resolution"]
    else:
        inc = w.opts["resolution"]
    if (w.opts["from"] > w.opts["to"]) != (direction == "up"):
        inc = inc
    if direction == "up":
        inc = -inc
    if w.opts["from"] > w.opts["to"]:
        inc = -inc
    w.set_value(w.value + inc)
    return ""


def ScaleSetTo(app, args):
    w = _w(app, args)
    w.set_value(get_double(w.opts[tcl_str(args[1])]))
    return ""


# ── panedwindow ──────────────────────────────────────────────────────────────

PANED_OPTS = [
    O("background", "background", "Background", NORMAL_BG, "color"),
    O("borderwidth", "borderWidth", "BorderWidth", 1, "pixels"),
    O("cursor", "cursor", "Cursor", "", "cursor"),
    O("handlepad", "handlePad", "HandlePad", 8, "pixels"),
    O("handlesize", "handleSize", "HandleSize", 8, "pixels"),
    O("height", "height", "Height", "", "pixels_or_empty"),
    O("opaqueresize", "opaqueResize", "OpaqueResize", 1, "boolean"),
    O("orient", "orient", "Orient", "horizontal", "enum:horizontal|vertical:orientation"),
    O("proxybackground", "proxyBackground", "ProxyBackground", "", "color_or_empty"),
    O("proxyborderwidth", "proxyBorderWidth", "ProxyBorderWidth", 2, "pixels"),
    O("proxyrelief", "proxyRelief", "Relief", "flat", "relief"),
    O("relief", "relief", "Relief", "flat", "relief"),
    O("sashcursor", "sashCursor", "Cursor", "", "cursor"),
    O("sashpad", "sashPad", "Pad", 0, "pixels"),
    O("sashrelief", "sashRelief", "Relief", "flat", "relief"),
    O("sashwidth", "sashWidth", "Width", 3, "pixels"),
    O("showhandle", "showHandle", "ShowHandle", 0, "boolean"),
    O("width", "width", "Width", "", "pixels_or_empty"),
]

_PANE_OPTS = ["-after", "-before", "-height", "-hide", "-minsize", "-padx", "-pady", "-stretch", "-sticky", "-width"]


class Pane:
    def __init__(self, w):
        self.w = w
        self.minsize = 0
        self.padx = 0
        self.pady = 0
        self.width = None
        self.height = None
        self.sticky = "nsew"
        self.hide = 0
        self.stretch = "last"
        self.x = 0
        self.y = 0
        self.pw = 0
        self.ph = 0
        self.sashx = 0
        self.sashy = 0


class TkPanedwindow(TkWin):
    CLASS = "Panedwindow"
    OPTS = PANED_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background"}
    CMDS = ["add", "cget", "configure", "forget", "identify", "panecget", "paneconfigure", "panes", "proxy", "sash"]
    A11Y_ROLE = "group"

    def __init__(self, app, path, parent, wclass=None):
        TkWin.__init__(self, app, path, parent, wclass)
        self.panes = []
        self.sizes_set = False
        self.proxy = None

    def vertical(self):
        return self.opts["orient"] == "vertical"

    def compute_geometry(self):
        bd = self.px("borderwidth")
        self.set_internal_border(bd)
        self.request_from_slaves()

    def find(self, w):
        for p in self.panes:
            if p.w is w:
                return p
        return None

    def w_add(self, args):
        wins = []
        k = 0
        while k < len(args) and tcl_str(args[k]).startswith("."):
            wins.append(self.app.window(args[k]))
            k += 1
        opts = args[k:]
        idx = len(self.panes)
        for i in range(0, len(opts) - 1, 2):
            o = match_prefix(tcl_str(opts[i]), _PANE_OPTS, "option")
            if o in ("-after", "-before"):
                other = self.find(self.app.window(opts[i + 1]))
                if other is not None:
                    idx = self.panes.index(other) + (1 if o == "-after" else 0)
        for w in wins:
            if w is self:
                raise TclError("can't add " + w.path + " to itself")
            p = self.find(w)
            if p is not None:
                self.panes.remove(p)
            else:
                p = Pane(w)
                if w.manager != "":
                    from _tkinter import geom as G
                    G.unmanage(self.app, w)
            self._pane_config(p, opts)
            self.panes.insert(min(idx, len(self.panes)), p)
            idx = self.panes.index(p) + 1
            w.manager = "panedwindow"
            w.gmaster = self
        self.sizes_set = False
        self.app.relayout()
        return ""

    def _pane_config(self, p, opts):
        for i in range(0, len(opts) - 1, 2):
            o = match_prefix(tcl_str(opts[i]), _PANE_OPTS, "option")
            v = opts[i + 1]
            if o == "-minsize":
                p.minsize = pixels(v)
            elif o == "-padx":
                p.padx = pixels(v)
            elif o == "-pady":
                p.pady = pixels(v)
            elif o == "-width":
                p.width = None if tcl_str(v) == "" else pixels(v)
            elif o == "-height":
                p.height = None if tcl_str(v) == "" else pixels(v)
            elif o == "-sticky":
                from _tkinter.geom import _sticky
                p.sticky = _sticky(v)
            elif o == "-hide":
                p.hide = 1 if get_boolean(v) else 0
            elif o == "-stretch":
                p.stretch = match_prefix(tcl_str(v), ["always", "first", "last", "middle", "never"], "stretch")

    def forget_slave(self, w):
        p = self.find(w)
        if p is not None:
            self.panes.remove(p)
            self.app.relayout()

    def w_forget(self, args):
        for a in args:
            w = self.app.window(a)
            if self.find(w) is not None:
                from _tkinter import geom as G
                G.unmanage(self.app, w)
        return ""

    def w_panes(self, args):
        return tuple([p.w.path for p in self.panes])

    def w_panecget(self, args):
        p = self.find(self.app.window(args[0]))
        if p is None:
            raise TclError("not managed by this window")
        o = match_prefix(tcl_str(args[1]), _PANE_OPTS, "option")
        return self._pane_value(p, o)

    def _pane_value(self, p, o):
        if o == "-minsize":
            return p.minsize
        if o == "-padx":
            return p.padx
        if o == "-pady":
            return p.pady
        if o == "-width":
            return p.width if p.width is not None else ""
        if o == "-height":
            return p.height if p.height is not None else ""
        if o == "-sticky":
            return p.sticky
        if o == "-hide":
            return p.hide
        if o == "-stretch":
            return p.stretch
        return ""

    def w_paneconfigure(self, args):
        p = self.find(self.app.window(args[0]))
        if p is None:
            raise TclError("not managed by this window")
        if len(args) == 1:
            out = []
            for o in ["-after", "-before", "-height", "-hide", "-minsize", "-padx", "-pady", "-sticky", "-stretch", "-width"]:
                out.append((o, "", "", "", self._pane_value(p, o)))
            return tuple(out)
        if len(args) == 2:
            o = match_prefix(tcl_str(args[1]), _PANE_OPTS, "option")
            return (o, "", "", "", self._pane_value(p, o))
        self._pane_config(p, args[1:])
        self.sizes_set = False
        self.app.relayout()
        return ""

    def w_identify(self, args):
        x = pixels(args[0])
        y = pixels(args[1])
        sw = self.px("sashwidth")
        for i in range(len(self.panes) - 1):
            p = self.panes[i]
            if self.vertical():
                if p.sashy <= y < p.sashy + sw:
                    return (i, "sash")
            elif p.sashx <= x < p.sashx + sw:
                return (i, "sash")
        return ""

    def w_sash(self, args):
        sub = match_prefix(tcl_str(args[0]), ["coord", "dragto", "mark", "place"], "option")
        i = get_int(args[1])
        if i < 0 or i >= len(self.panes) - 1:
            raise TclError("invalid sash index")
        p = self.panes[i]
        if sub == "coord":
            return (p.sashx, p.sashy)
        if sub == "mark":
            if len(args) > 2:
                self.mark = (pixels(args[2]), pixels(args[3]))
                return ""
            return getattr(self, "mark", (0, 0))
        x = pixels(args[2])
        y = pixels(args[3])
        if sub == "dragto":
            mx, my = getattr(self, "mark", (p.sashx, p.sashy))
            x = p.sashx + (x - mx)
            y = p.sashy + (y - my)
            self.mark = (pixels(args[2]), pixels(args[3]))
        self._move_sash(i, x, y)
        return ""

    def _move_sash(self, i, x, y):
        a = self.panes[i]
        b = self.panes[i + 1]
        sw = self.px("sashwidth") + 2 * self.px("sashpad")
        if self.vertical():
            total = a.ph + b.ph
            new_a = y - a.y - a.pady
            new_a = max(a.minsize, min(total - b.minsize, new_a))
            a.height = new_a
            b.height = total - new_a
        else:
            total = a.pw + b.pw
            new_a = x - a.x - a.padx
            new_a = max(a.minsize, min(total - b.minsize, new_a))
            a.width = new_a
            b.width = total - new_a
        self.sizes_set = True
        self.app.relayout()

    def w_proxy(self, args):
        sub = match_prefix(tcl_str(args[0]), ["coord", "forget", "place"], "option")
        if sub == "coord":
            return self.proxy if self.proxy is not None else (0, 0)
        if sub == "forget":
            self.proxy = None
            return ""
        self.proxy = (pixels(args[1]), pixels(args[2]))
        return ""

    def pane_req(self, p):
        w = p.width if p.width is not None else p.w.reqw
        h = p.height if p.height is not None else p.w.reqh
        return w, h

    def request_from_slaves(self):
        bd = self.px("borderwidth")
        sw = self.px("sashwidth") + 2 * self.px("sashpad")
        vis = [p for p in self.panes if not p.hide]
        if self.vertical():
            w = 0
            h = 0
            for p in vis:
                pw, ph = self.pane_req(p)
                w = max(w, pw + 2 * p.padx)
                h += ph + 2 * p.pady
            h += sw * max(0, len(vis) - 1)
        else:
            w = 0
            h = 0
            for p in vis:
                pw, ph = self.pane_req(p)
                h = max(h, ph + 2 * p.pady)
                w += pw + 2 * p.padx
            w += sw * max(0, len(vis) - 1)
        if self.opts.get("width", "") != "":
            w = pixels(self.opts["width"]) - 2 * bd
        if self.opts.get("height", "") != "":
            h = pixels(self.opts["height"]) - 2 * bd
        self.request(w + 2 * bd, h + 2 * bd)

    def arrange_slaves(self):
        bd = self.px("borderwidth")
        sw = self.px("sashwidth")
        sp = self.px("sashpad")
        vis = [p for p in self.panes if not p.hide]
        for p in self.panes:
            if p.hide:
                self.app.set_mapped(p.w, False)
        pos = bd
        n = len(vis)
        total = (self.height if self.vertical() else self.width) - 2 * bd - (sw + 2 * sp) * max(0, n - 1)
        sizes = []
        for p in vis:
            pw, ph = self.pane_req(p)
            sizes.append((ph + 2 * p.pady) if self.vertical() else (pw + 2 * p.padx))
        extra = total - sum(sizes)
        if n > 0 and extra != 0:
            k = n - 1
            sizes[k] = max(0, sizes[k] + extra)
        for i in range(n):
            p = vis[i]
            size = sizes[i]
            if self.vertical():
                p.x = bd
                p.y = pos
                p.pw = self.width - 2 * bd - 2 * p.padx
                p.ph = size - 2 * p.pady
                self._place_pane(p, bd + p.padx, pos + p.pady, p.pw, p.ph)
                pos += size
                p.sashx = bd
                p.sashy = pos + sp
                pos += sw + 2 * sp
            else:
                p.x = pos
                p.y = bd
                p.pw = size - 2 * p.padx
                p.ph = self.height - 2 * bd - 2 * p.pady
                self._place_pane(p, pos + p.padx, bd + p.pady, p.pw, p.ph)
                pos += size
                p.sashx = pos + sp
                p.sashy = bd
                pos += sw + 2 * sp

    def _place_pane(self, p, x, y, w, h):
        rw, rh = p.w.reqw, p.w.reqh
        st = p.sticky
        cw, ch = w, h
        if not ("e" in st and "w" in st):
            cw = min(rw, w)
            if "e" in st:
                x += w - cw
            elif "w" not in st:
                x += (w - cw) // 2
        if not ("n" in st and "s" in st):
            ch = min(rh, h)
            if "s" in st:
                y += h - ch
            elif "n" not in st:
                y += (h - ch) // 2
        self.app.place_slave(self, p.w, x, y, cw, ch)

    def forget_all_slaves(self):
        for p in list(self.panes):
            p.w.manager = ""
            p.w.gmaster = None
        self.panes = []

    def draw(self, h, ax, ay):
        bg = self.color("background")
        fill(h, ax, ay, self.width, self.height, bg)
        draw_relief(h, ax, ay, self.width, self.height, self.px("borderwidth"), self.opts["relief"], bg)
        sw = self.px("sashwidth")
        vis = [p for p in self.panes if not p.hide]
        for p in vis[:-1]:
            if self.vertical():
                draw_relief(h, ax + p.sashx, ay + p.sashy, self.width - 2 * self.px("borderwidth"), sw, 1, self.opts["sashrelief"], bg)
            else:
                draw_relief(h, ax + p.sashx, ay + p.sashy, sw, self.height - 2 * self.px("borderwidth"), 1, self.opts["sashrelief"], bg)


def PanedButtonDown(app, args):
    w = _w(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    r = w.w_identify([x, y])
    p = _priv(app)
    if r != "" and r[1] == "sash":
        p["sash"] = (w, r[0])
        w.mark = (x, y)
    else:
        p["sash"] = None
    return ""


def PanedDrag(app, args):
    w = _w(app, args)
    p = _priv(app)
    s = p.get("sash")
    if s is None or s[0] is not w:
        return ""
    w.w_sash(["dragto", s[1], get_int(args[1]), get_int(args[2])])
    return ""


def PanedRelease(app, args):
    _priv(app)["sash"] = None
    return ""


# ── registration ─────────────────────────────────────────────────────────────

C.WIDGET_TYPES["frame"] = TkFrame
C.WIDGET_TYPES["toplevel"] = TkToplevel
C.WIDGET_TYPES["labelframe"] = TkLabelframe
C.WIDGET_TYPES["label"] = TkLabel
C.WIDGET_TYPES["button"] = TkButton
C.WIDGET_TYPES["checkbutton"] = TkCheckbutton
C.WIDGET_TYPES["radiobutton"] = TkRadiobutton
C.WIDGET_TYPES["message"] = TkMessage
C.WIDGET_TYPES["scrollbar"] = TkScrollbar
C.WIDGET_TYPES["scale"] = TkScale
C.WIDGET_TYPES["panedwindow"] = TkPanedwindow

for _name, _f in (("tk::ButtonEnter", ButtonEnter), ("tk::ButtonLeave", ButtonLeave), ("tk::ButtonDown", ButtonDown),
                  ("tk::ButtonUp", ButtonUp), ("tk::ButtonInvoke", ButtonInvoke), ("tk::CheckInvoke", CheckInvoke),
                  ("tk::CheckRadioInvoke", CheckInvoke), ("tk::CheckEnter", CheckEnter), ("tk::CheckLeave", CheckLeave),
                  ("tk::ScrollButtonDown", ScrollButtonDown), ("tk::ScrollDrag", ScrollDrag),
                  ("tk::ScrollButtonUp", ScrollButtonUp), ("tk::ScrollByUnits", ScrollByUnits),
                  ("tk::ScrollByPages", ScrollByPages), ("tk::ScrollToPos", ScrollToPos),
                  ("tk::ScrollActivate", ScrollActivate), ("tk::ScaleActivate", ScaleActivate),
                  ("tk::ScaleButtonDown", ScaleButtonDown), ("tk::ScaleDrag", ScaleDrag),
                  ("tk::ScaleEndDrag", ScaleEndDrag), ("tk::ScaleIncrement", ScaleIncrement),
                  ("tk::ScaleSetTo", ScaleSetTo), ("tk::PanedButtonDown", PanedButtonDown),
                  ("tk::PanedDrag", PanedDrag), ("tk::PanedRelease", PanedRelease)):
    C.TK_COMMANDS[_name] = _f


def _class_bindings(app):
    b = app.bindings
    x11 = C.windowing_system() == "x11"
    for cls in ("Button",):
        b.set(cls, "<Enter>", "tk::ButtonEnter %W")
        b.set(cls, "<Leave>", "tk::ButtonLeave %W")
        b.set(cls, "<1>", "tk::ButtonDown %W")
        b.set(cls, "<ButtonRelease-1>", "tk::ButtonUp %W")
        b.set(cls, "<space>", "tk::ButtonInvoke %W")
        b.set(cls, "<<Invoke>>", "%W invoke")
    for cls in ("Checkbutton", "Radiobutton"):
        inv = "tk::CheckInvoke %W" if cls == "Checkbutton" else "tk::CheckRadioInvoke %W"
        b.set(cls, "<Return>", inv)
        b.set(cls, "<1>", inv)
        b.set(cls, "<space>", inv)
        b.set(cls, "<Enter>", "tk::CheckEnter %W" if cls == "Checkbutton" else "tk::ButtonEnter %W")
        b.set(cls, "<Leave>", "tk::CheckLeave %W" if cls == "Checkbutton" else "tk::ButtonLeave %W")
        b.set(cls, "<<Invoke>>", "%W invoke")
    b.set("Scrollbar", "<Enter>", "tk::ScrollActivate %W %x %y")
    b.set("Scrollbar", "<Motion>", "tk::ScrollActivate %W %x %y")
    b.set("Scrollbar", "<Leave>", "tk::ScrollActivate %W")
    b.set("Scrollbar", "<1>", "tk::ScrollButtonDown %W %x %y")
    b.set("Scrollbar", "<B1-Motion>", "tk::ScrollDrag %W %x %y")
    b.set("Scrollbar", "<ButtonRelease-1>", "tk::ScrollButtonUp %W %x %y")
    b.set("Scrollbar", "<B1-Leave>", "# Prevents <Leave> binding from being invoked.")
    b.set("Scrollbar", "<B1-Enter>", "# Prevents <Enter> binding from being invoked.")
    b.set("Scrollbar", "<Up>", "tk::ScrollByUnits %W v -1")
    b.set("Scrollbar", "<Down>", "tk::ScrollByUnits %W v 1")
    b.set("Scrollbar", "<Left>", "tk::ScrollByUnits %W h -1")
    b.set("Scrollbar", "<Right>", "tk::ScrollByUnits %W h 1")
    b.set("Scrollbar", "<Prior>", "tk::ScrollByPages %W hv -1")
    b.set("Scrollbar", "<Next>", "tk::ScrollByPages %W hv 1")
    b.set("Scrollbar", "<Home>", "tk::ScrollToPos %W 0")
    b.set("Scrollbar", "<End>", "tk::ScrollToPos %W 1")
    b.set("Scale", "<Enter>", "tk::ScaleActivate %W %x %y")
    b.set("Scale", "<Motion>", "tk::ScaleActivate %W %x %y")
    b.set("Scale", "<1>", "tk::ScaleButtonDown %W %x %y")
    b.set("Scale", "<B1-Motion>", "tk::ScaleDrag %W %x %y")
    b.set("Scale", "<B1-Leave>", " ")
    b.set("Scale", "<B1-Enter>", " ")
    b.set("Scale", "<ButtonRelease-1>", "tk::ScaleEndDrag %W; tk::ScaleActivate %W %x %y")
    b.set("Scale", "<<PrevLine>>", "tk::ScaleIncrement %W up little noRepeat")
    b.set("Scale", "<<NextLine>>", "tk::ScaleIncrement %W down little noRepeat")
    b.set("Scale", "<<PrevChar>>", "tk::ScaleIncrement %W up little noRepeat")
    b.set("Scale", "<<NextChar>>", "tk::ScaleIncrement %W down little noRepeat")
    b.set("Scale", "<<PrevPara>>", "tk::ScaleIncrement %W up big noRepeat")
    b.set("Scale", "<<NextPara>>", "tk::ScaleIncrement %W down big noRepeat")
    b.set("Scale", "<<LineStart>>", "tk::ScaleSetTo %W from")
    b.set("Scale", "<<LineEnd>>", "tk::ScaleSetTo %W to")
    b.set("Panedwindow", "<1>", "tk::PanedButtonDown %W %x %y")
    b.set("Panedwindow", "<B1-Motion>", "tk::PanedDrag %W %x %y")
    b.set("Panedwindow", "<ButtonRelease-1>", "tk::PanedRelease %W")


C.APP_INIT.append(_class_bindings)
