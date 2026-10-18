# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/ttk.ny - Tk's themed widgets (round 84): the style engine
# (ttkTheme.c, ttkLayout.c, ttkState.c), the elements (ttkElements.c,
# ttkLabel.c, ttkDefaultTheme.c), the widget core (ttkWidget.c) and the
# simple widgets (ttkButton.c, ttkFrame.c, ttkSeparator.c ...); the entry
# family, scrollbar, scale, progressbar, notebook, panedwindow and treeview
# are in ttk2.ny.
#
# style       ttk::style configure/map/lookup/layout/element create (image,
#             from)/element names/element options/theme create (-parent,
#             -settings)/theme settings/theme names/theme use/theme styles;
#             ttk::setTheme, ttk::themes, $ttk::currentTheme. Settings and
#             maps follow the style's parent chain ("My.TButton" ->
#             "TButton" -> "."), layouts and elements the theme's parent
#             chain, as in ttkTheme.c; a theme change sends
#             <<ThemeChanged>> to every widget.
# layouts     Tk's template syntax (-side -sticky -expand -border -unit
#             -children) and its packer (Ttk_PlaceNodeList: parcels cut
#             from the cavity, Ttk_StickBox within them); the default
#             theme's layouts for every widget.
# states      active disabled focus pressed selected background alternate
#             invalid readonly hover user1-3, state specs with "!", state
#             maps (first match wins), widget state/instate, the -state
#             compatibility option.
# themes      default (the X11 default), clam, alt and classic. Their
#             settings (colours, paddings, reliefs) are Tk's library ones;
#             clam, alt and classic draw with the default theme's elements
#             (Tk gives each its own drawing code - borders, check marks
#             and arrows look a little different there).
#
# Not provided: the Windows/macOS native themes (winnative, xpnative,
# vista, aqua) and the "vsapi" element factory; element sizes follow the
# default theme of Tk 8.6 with a scaling level of 1.

import math
from _tkinter.tcl import (TclError, tcl_str, tcl_float, split_list, join_list, quote_elem, get_int, get_double,
                          get_boolean, match_prefix, or_list)
from _tkinter.util import (pixels, fpixels, parse_color, cdiv, cround, shades, fill, line, text as draw_text,
                           draw_relief, draw_ring, layout_text)
from _tkinter.win import TkWin, fmt_frac, _norm
from _tkinter import core as C
from _tkinter import bind as B


def O(name, dbname, dbclass, default, kind):
    return (name, dbname, dbclass, default, kind)


# ── states (ttkState.c) ───────────────────────────────────────────────────
STATE_NAMES = ["active", "disabled", "focus", "pressed", "selected", "background", "alternate", "invalid",
               "readonly", "hover", "reserved1", "reserved2", "reserved3", "user3", "user2", "user1"]
SBIT = {}
for _i in range(len(STATE_NAMES)):
    SBIT[STATE_NAMES[_i]] = 1 << _i
S_ACTIVE = 1
S_DISABLED = 2
S_FOCUS = 4
S_PRESSED = 8
S_SELECTED = 16
S_BACKGROUND = 32
S_ALTERNATE = 64
S_INVALID = 128
S_READONLY = 256
S_HOVER = 512

_SPEC_CACHE = {}


def _words(v):
    if isinstance(v, (tuple, list)):
        out = []
        for x in v:
            out.extend(split_list(x) if isinstance(x, str) else _words(x) if isinstance(x, (tuple, list)) else [tcl_str(x)])
        return out
    return split_list(tcl_str(v))


def parse_statespec(v):
    # -> (onbits, offbits); "Invalid state name x" as Ttk_GetStateSpecFromObj
    key = v if isinstance(v, str) else None
    if key is not None:
        r = _SPEC_CACHE.get(key)
        if r is not None:
            return r
    on = 0
    off = 0
    for w in _words(v):
        neg = w.startswith("!")
        n = w[1:] if neg else w
        b = SBIT.get(n)
        if b is None:
            raise TclError("Invalid state name " + n)
        if neg:
            off |= b
        else:
            on |= b
    if key is not None:
        if len(_SPEC_CACHE) > 2000:
            _SPEC_CACHE.clear()
        _SPEC_CACHE[key] = (on, off)
    return (on, off)


def statespec_string(on, off):
    out = []
    for i in range(len(STATE_NAMES)):
        b = 1 << i
        if on & b:
            out.append(STATE_NAMES[i])
        elif off & b:
            out.append("!" + STATE_NAMES[i])
    return " ".join(out)


def state_matches(state, spec):
    on, off = spec
    return (state & on) == on and (state & off) == 0


def parse_statemap(v):
    # a state map: spec value spec value ...; "State map must have an even
    # number of elements"
    items = list(v) if isinstance(v, (tuple, list)) else split_list(tcl_str(v))
    if len(items) % 2 != 0:
        raise TclError("State map must have an even number of elements")
    out = []
    for i in range(0, len(items), 2):
        out.append((parse_statespec(items[i]), items[i + 1]))
    return out


def map_lookup(m, state):
    for spec, value in m:
        if state_matches(state, spec):
            return value
    return None


# ── paddings, stickiness ──────────────────────────────────────────────────
def parse_padding(v):
    # Ttk_GetPaddingFromObj: 1 to 4 lengths (left top right bottom)
    if v is None:
        return (0, 0, 0, 0)
    if isinstance(v, int) and not isinstance(v, bool):
        return (v, v, v, v)
    ws = _words(v)
    if len(ws) > 4:
        raise TclError("Wrong #elements in padding spec '" + tcl_str(v) + "'")
    try:
        p = [pixels(x) for x in ws]
    except TclError:
        raise TclError("Bad padding spec '" + tcl_str(v) + "'")
    if not p:
        return (0, 0, 0, 0)
    if len(p) == 1:
        return (p[0], p[0], p[0], p[0])
    if len(p) == 2:
        return (p[0], p[1], p[0], p[1])
    if len(p) == 3:
        return (p[0], p[1], p[2], p[1])
    return (p[0], p[1], p[2], p[3])


def pad_add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3])


def parse_sticky(v):
    s = tcl_str(v)
    out = ""
    for ch in s.lower():
        if ch in "nswe":
            if ch not in out:
                out += ch
        elif ch not in " ,\t":
            raise TclError("Bad -sticky specification " + s)
    return "".join([c for c in "nswe" if c in out])


def stick_box(px, py, pw, ph, w, h, sticky):
    # Ttk_StickBox
    if w > pw:
        w = pw
    if h > ph:
        h = ph
    dx = pw - w
    dy = ph - h
    we = ("w" in sticky, "e" in sticky)
    if we[0] and we[1]:
        w += dx
    elif we[0]:
        pass
    elif we[1]:
        px += dx
    else:
        px += dx // 2
    ns = ("n" in sticky, "s" in sticky)
    if ns[0] and ns[1]:
        h += dy
    elif ns[0]:
        pass
    elif ns[1]:
        py += dy
    else:
        py += dy // 2
    return (px, py, w, h)


# ── layout templates (ttkLayout.c) ────────────────────────────────────────
class LNode:
    def __init__(self, name, side=None, sticky="nswe", expand=False, border=False, unit=False, children=None):
        self.name = name
        self.side = side
        self.sticky = sticky
        self.expand = expand
        self.border = border
        self.unit = unit
        self.children = children if children is not None else []


_LAYOUT_OPTS = ["-side", "-sticky", "-expand", "-border", "-unit", "-children"]


def parse_layout(spec):
    words = list(spec) if isinstance(spec, (tuple, list)) else split_list(tcl_str(spec))
    nodes = []
    i = 0
    while i < len(words):
        name = tcl_str(words[i])
        i += 1
        if name.startswith("-"):
            raise TclError("Layout element name must not start with -: " + name)
        nd = LNode(name)
        while i < len(words) and tcl_str(words[i]).startswith("-"):
            opt = tcl_str(words[i])
            o = None
            for c in _LAYOUT_OPTS:
                if c == opt:
                    o = c
                    break
            if o is None:
                raise TclError("bad option \"" + opt + "\": must be " + or_list(_LAYOUT_OPTS))
            if i + 1 >= len(words):
                raise TclError("Missing value for option " + opt)
            val = words[i + 1]
            i += 2
            if o == "-side":
                nd.side = match_prefix(tcl_str(val), ["left", "right", "top", "bottom"], "side")
            elif o == "-sticky":
                nd.sticky = parse_sticky(val)
            elif o == "-expand":
                nd.expand = get_boolean(val)
            elif o == "-border":
                nd.border = get_boolean(val)
            elif o == "-unit":
                nd.unit = get_boolean(val)
            else:
                nd.children = parse_layout(val)
        nodes.append(nd)
    return nodes


def unparse_layout(nodes):
    out = []
    for nd in nodes:
        out.append(nd.name)
        if nd.expand:
            out.extend(["-expand", "1"])
        elif nd.side:
            out.extend(["-side", nd.side])
        out.extend(["-sticky", nd.sticky])
        if nd.border:
            out.extend(["-border", "1"])
        if nd.unit:
            out.extend(["-unit", "1"])
        if nd.children:
            out.extend(["-children", unparse_layout(nd.children)])
    return join_list(out)


def L(name, side=None, sticky="", expand=False, children=None):
    # a node of a layout written in C (TTK_NODE / TTK_GROUP flags)
    return LNode(name, side, sticky, expand, False, False, children)


# ── the style database (ttkTheme.c) ───────────────────────────────────────
class StyleRec:
    def __init__(self, name, parent):
        self.name = name
        self.parent = parent
        self.settings = {}
        self.maps = {}
        self.map_src = {}


class Theme:
    def __init__(self, name, parent):
        self.name = name
        self.parent = parent
        self.styles = {".": StyleRec(".", None)}
        self.elements = {}
        self.layouts = {}
        self.settings_script = ""

    def get_style(self, name):
        st = self.styles.get(name)
        if st is None:
            dot = name.find(".")
            if dot >= 0 and dot + 1 < len(name):
                par = self.get_style(name[dot + 1:])
            else:
                par = self.styles["."]
            st = StyleRec(name, par)
            self.styles[name] = st
        return st

    def find_element(self, name):
        th = self
        while th is not None:
            e = th.elements.get(name)
            if e is not None:
                return e
            nm = name
            d = nm.find(".")
            while d >= 0:
                nm = nm[d + 1:]
                e = th.elements.get(nm)
                if e is not None:
                    return e
                d = nm.find(".")
            th = th.parent
        return NULL_ELEMENT

    def find_layout(self, name):
        th = self
        while th is not None:
            t = th.layouts.get(name)
            if t is not None:
                return t
            nm = name
            d = nm.find(".")
            while d >= 0:
                nm = nm[d + 1:]
                t = th.layouts.get(nm)
                if t is not None:
                    return t
                d = nm.find(".")
            th = th.parent
        return None


def style_map(st, opt, state):
    while st is not None:
        m = st.maps.get(opt)
        if m is not None:
            v = map_lookup(m, state)
            if v is not None:
                return v
        st = st.parent
    return None


def style_default(st, opt):
    while st is not None:
        v = st.settings.get(opt)
        if v is not None:
            return v
        st = st.parent
    return None


def style_query(st, opt, state):
    v = style_map(st, opt, state)
    if v is not None:
        return v
    return style_default(st, opt)


class Engine:
    def __init__(self, app):
        self.app = app
        self.themes = {}
        self.order = []
        self.epoch = 0
        self.current = None
        _build_themes(self)
        self.current = self.themes["default"]
        app.interp.setvar("ttk::currentTheme", "default")

    def theme(self, name):
        th = self.themes.get(name)
        if th is None:
            raise TclError("theme \"" + name + "\" doesn't exist")
        return th

    def create_theme(self, name, parent):
        if name in self.themes:
            raise TclError("Theme " + name + " already exists")
        th = Theme(name, parent)
        self.themes[name] = th
        self.order.insert(0, name)
        return th

    def use(self, th):
        self.current = th
        self.changed()
        for w in list(self.app.widgets.values()):
            if isinstance(w, TtkWidget) and not w.destroyed:
                try:
                    self.app.event_generate([w.path, "<<ThemeChanged>>"])
                except TclError:
                    pass

    def changed(self):
        # styles, layouts or the theme changed: every themed widget looks
        # its style up again (ttkTheme.c's ThemeChangedProc)
        self.epoch += 1
        for w in list(self.app.widgets.values()):
            if isinstance(w, TtkWidget) and not w.destroyed:
                w.layout_key = None
                w.compute_geometry()
                w.damage()
        self.app.relayout()


def engine(app):
    e = getattr(app, "ttk_engine", None)
    if e is None:
        e = Engine(app)
        app.ttk_engine = e
    return e


# ── elements ──────────────────────────────────────────────────────────────
DEFAULT_BG = "#d9d9d9"
DEFAULT_FG = "black"
DEFAULT_FONT = "TkDefaultFont"


class Element:
    # an element class: its options (name, default) and its geometry and
    # drawing; `r` is the option record (option name without "-" -> value)
    NAME = "null"
    OPTS = []

    def size(self, r, w, state):
        return (0, 0, (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        pass


def _px(v, default=0):
    if v is None or v == "":
        return default
    try:
        return pixels(v)
    except TclError:
        return default


def _int(v, default=0):
    try:
        return get_int(v)
    except TclError:
        try:
            return int(get_double(v))
        except TclError:
            return default


def _color(v, default=None):
    if v is None or tcl_str(v) == "":
        return default
    try:
        return parse_color(tcl_str(v))
    except TclError:
        return default


def _relief(v):
    s = tcl_str(v) if v is not None else "flat"
    for r in ("flat", "groove", "raised", "ridge", "solid", "sunken"):
        if r.startswith(s) and s:
            return r
    return "flat"


def _image_spec(w, v, state):
    # an image spec: "name ?state name ...?" -> the image for the state
    if v is None:
        return None
    parts = _words(v)
    if not parts:
        return None
    name = parts[0]
    for i in range(1, len(parts) - 1, 2):
        try:
            if state_matches(state, parse_statespec(parts[i])):
                name = parts[i + 1]
                break
        except TclError:
            pass
    return w.app.images.get(name)


class NullElement(Element):
    NAME = ""


NULL_ELEMENT = NullElement()


class BackgroundElement(Element):
    NAME = "background"
    OPTS = [("-background", DEFAULT_BG)]

    def draw(self, r, w, h, box, state):
        c = _color(r["background"])
        if c is not None:
            fill(h, box[0], box[1], box[2], box[3], c)


class BorderElement(Element):
    NAME = "border"
    OPTS = [("-background", DEFAULT_BG), ("-borderwidth", "1"), ("-relief", "flat")]

    def size(self, r, w, state):
        bw = _px(r["borderwidth"])
        return (0, 0, (bw, bw, bw, bw))

    def draw(self, r, w, h, box, state):
        c = _color(r["background"], 0xd9d9d9)
        fill(h, box[0], box[1], box[2], box[3], c)
        draw_relief(h, box[0], box[1], box[2], box[3], _px(r["borderwidth"]), _relief(r["relief"]), c)


class ButtonBorderElement(Element):
    # ttkDefaultTheme.c: room for the default ring unless -default disabled
    NAME = "Button.border"
    OPTS = [("-background", DEFAULT_BG), ("-bordercolor", "#000000"), ("-borderwidth", "1"), ("-relief", "flat"),
            ("-default", "disabled")]

    def size(self, r, w, state):
        bw = _px(r["borderwidth"])
        if tcl_str(r["default"]) != "disabled":
            bw += 5
        return (0, 0, (bw, bw, bw, bw))

    def draw(self, r, w, h, box, state):
        x, y, ww, hh = box
        c = _color(r["background"], 0xd9d9d9)
        bw = _px(r["borderwidth"])
        d = tcl_str(r["default"])
        fill(h, x, y, ww, hh, c)
        if d == "active":
            draw_ring(h, x, y, ww, hh, 1, _color(r["bordercolor"], 0))
        if d != "disabled":
            x += 5
            y += 5
            ww -= 10
            hh -= 10
        draw_relief(h, x, y, ww, hh, bw, _relief(r["relief"]), c)


class FieldElement(Element):
    NAME = "field"
    OPTS = [("-fieldbackground", "white"), ("-borderwidth", "2")]

    def size(self, r, w, state):
        bw = _px(r["borderwidth"])
        return (0, 0, (bw, bw, bw, bw))

    def draw(self, r, w, h, box, state):
        c = _color(r["fieldbackground"], 0xffffff)
        fill(h, box[0], box[1], box[2], box[3], c)
        draw_relief(h, box[0], box[1], box[2], box[3], _px(r["borderwidth"]), "sunken", c)


class PaddingElement(Element):
    NAME = "padding"
    OPTS = [("-padding", "0"), ("-relief", "flat"), ("-shiftrelief", "0")]

    def size(self, r, w, state):
        try:
            p = parse_padding(r["padding"])
        except TclError:
            p = (0, 0, 0, 0)
        n = _int(r["shiftrelief"])
        rel = _relief(r["relief"])
        l, t, rr, b = p
        if rel == "raised":
            rr += n
            b += n
        elif rel == "sunken":
            l += n
            t += n
        else:
            h1 = n // 2
            h2 = h1 + n % 2
            l += h1
            t += h1
            rr += h2
            b += h2
        return (0, 0, (l, t, rr, b))


class FocusElement(Element):
    NAME = "focus"
    OPTS = [("-focuscolor", "black"), ("-focusthickness", "1")]

    def size(self, r, w, state):
        t = _px(r["focusthickness"])
        return (0, 0, (t, t, t, t))

    def draw(self, r, w, h, box, state):
        if not (state & S_FOCUS):
            return
        t = _px(r["focusthickness"])
        if t <= 0:
            return
        c = _color(r["focuscolor"], 0)
        x, y, ww, hh = box
        # TtkDrawFocusRing: a dotted rectangle
        for i in range(0, ww, 2):
            fill(h, x + i, y, 1, t, c)
            fill(h, x + i, y + hh - t, 1, t, c)
        for j in range(0, hh, 2):
            fill(h, x, y + j, t, 1, c)
            fill(h, x + ww - t, y + j, t, 1, c)


class SeparatorElement(Element):
    NAME = "separator"
    OPTS = [("-orient", "horizontal"), ("-background", DEFAULT_BG)]
    ORIENT = None

    def size(self, r, w, state):
        return (2, 2, (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        c = _color(r["background"], 0xd9d9d9)
        light, dark = shades(c)
        x, y, ww, hh = box
        o = self.ORIENT or tcl_str(r["orient"])
        if o.startswith("v"):
            fill(h, x, y, 1, hh, dark)
            fill(h, x + 1, y, 1, hh, light)
        else:
            fill(h, x, y, ww, 1, dark)
            fill(h, x, y + 1, ww, 1, light)


class HSeparatorElement(SeparatorElement):
    NAME = "hseparator"
    ORIENT = "horizontal"


class VSeparatorElement(SeparatorElement):
    NAME = "vseparator"
    ORIENT = "vertical"


class SizegripElement(Element):
    NAME = "sizegrip"
    OPTS = [("-background", DEFAULT_BG)]

    def size(self, r, w, state):
        return (15, 15, (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        c = _color(r["background"], 0xd9d9d9)
        light, dark = shades(c)
        x, y, ww, hh = box
        for k in range(3):
            off = 3 + 5 * k
            for i in range(off):
                fill(h, x + ww - off + i, y + hh - 1 - i, 1, 1, dark)
                fill(h, x + ww - off + i + 1, y + hh - 1 - i, 1, 1, light)


def _arrow_size(hsz, direction):
    # TtkArrowSize
    if direction in ("up", "down"):
        return (2 * hsz + 1, hsz + 1)
    return (hsz + 1, 2 * hsz + 1)


def fill_arrow(h, box, direction, c):
    # TtkFillArrow: a solid triangle centred in box
    x, y, ww, hh = box
    if direction in ("up", "down"):
        hs = max(0, min((ww - 1) // 2, hh - 1))
        aw, ah = _arrow_size(hs, direction)
        ax = x + (ww - aw) // 2
        ay = y + (hh - ah) // 2
        for i in range(ah):
            k = i if direction == "up" else ah - 1 - i
            fill(h, ax + hs - k, ay + i, 2 * k + 1, 1, c)
    else:
        hs = max(0, min((hh - 1) // 2, ww - 1))
        aw, ah = _arrow_size(hs, direction)
        ax = x + (ww - aw) // 2
        ay = y + (hh - ah) // 2
        for i in range(aw):
            k = i if direction == "left" else aw - 1 - i
            fill(h, ax + i, ay + hs - k, 1, 2 * k + 1, c)


_ARROW_PAD = (3, 3, 4, 4)


class ArrowElement(Element):
    # ttkDefaultTheme.c: a triangle in a raised box, asymmetric padding
    NAME = "arrow"
    DIR = "down"
    OPTS = [("-arrowsize", "14"), ("-background", DEFAULT_BG), ("-bordercolor", "black"), ("-relief", "raised"),
            ("-arrowcolor", "black")]

    def size(self, r, w, state):
        width = _px(r["arrowsize"], 14)
        width -= _ARROW_PAD[0] + _ARROW_PAD[2]
        aw, ah = _arrow_size(max(0, width // 2), self.DIR)
        return (aw + _ARROW_PAD[0] + _ARROW_PAD[2], ah + _ARROW_PAD[1] + _ARROW_PAD[3], (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        c = _color(r["background"], 0xd9d9d9)
        x, y, ww, hh = box
        fill(h, x, y, ww, hh, c)
        draw_relief(h, x, y, ww, hh, 1, _relief(r["relief"]), c)
        inner = (x + _ARROW_PAD[0], y + _ARROW_PAD[1], ww - _ARROW_PAD[0] - _ARROW_PAD[2], hh - _ARROW_PAD[1] - _ARROW_PAD[3])
        fill_arrow(h, inner, self.DIR, _color(r["arrowcolor"], 0))


class UpArrowElement(ArrowElement):
    NAME = "uparrow"
    DIR = "up"


class DownArrowElement(ArrowElement):
    NAME = "downarrow"
    DIR = "down"


class LeftArrowElement(ArrowElement):
    NAME = "leftarrow"
    DIR = "left"


class RightArrowElement(ArrowElement):
    NAME = "rightarrow"
    DIR = "right"


class TroughElement(Element):
    NAME = "trough"
    OPTS = [("-borderwidth", "1"), ("-troughcolor", DEFAULT_BG), ("-troughrelief", "sunken")]

    def size(self, r, w, state):
        bw = _px(r["borderwidth"])
        return (0, 0, (bw, bw, bw, bw))

    def draw(self, r, w, h, box, state):
        c = _color(r["troughcolor"], 0xc3c3c3)
        fill(h, box[0], box[1], box[2], box[3], c)
        draw_relief(h, box[0], box[1], box[2], box[3], _px(r["borderwidth"]), _relief(r["troughrelief"]), c)


class ThumbElement(Element):
    NAME = "thumb"
    OPTS = [("-orient", "horizontal"), ("-width", "14"), ("-relief", "raised"), ("-background", DEFAULT_BG),
            ("-borderwidth", "1")]

    def size(self, r, w, state):
        s = _px(r["width"], 14)
        return (s, s, (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        c = _color(r["background"], 0xd9d9d9)
        fill(h, box[0], box[1], box[2], box[3], c)
        draw_relief(h, box[0], box[1], box[2], box[3], _px(r["borderwidth"], 1), _relief(r["relief"]), c)


class SliderElement(Element):
    NAME = "slider"
    OPTS = [("-sliderlength", "30"), ("-sliderthickness", "15"), ("-sliderrelief", "raised"),
            ("-borderwidth", "1"), ("-background", DEFAULT_BG), ("-orient", "horizontal")]

    def size(self, r, w, state):
        ln = _px(r["sliderlength"], 30)
        th = _px(r["sliderthickness"], 15)
        if tcl_str(r["orient"]).startswith("v"):
            return (th, ln, (0, 0, 0, 0))
        return (ln, th, (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        c = _color(r["background"], 0xd9d9d9)
        fill(h, box[0], box[1], box[2], box[3], c)
        draw_relief(h, box[0], box[1], box[2], box[3], _px(r["borderwidth"], 1), _relief(r["sliderrelief"]), c)
        if tcl_str(r["orient"]).startswith("v"):
            mid = box[1] + box[3] // 2
            light, dark = shades(c)
            fill(h, box[0] + 2, mid - 1, box[2] - 4, 1, dark)
            fill(h, box[0] + 2, mid, box[2] - 4, 1, light)
        else:
            mid = box[0] + box[2] // 2
            light, dark = shades(c)
            fill(h, mid - 1, box[1] + 2, 1, box[3] - 4, dark)
            fill(h, mid, box[1] + 2, 1, box[3] - 4, light)


class PbarElement(Element):
    NAME = "pbar"
    OPTS = [("-orient", "horizontal"), ("-thickness", "15"), ("-barsize", "30"), ("-pbarrelief", "raised"),
            ("-borderwidth", "1"), ("-background", "#4a6984")]

    def size(self, r, w, state):
        th = _px(r["thickness"], 15)
        bs = _px(r["barsize"], 30)
        if tcl_str(r["orient"]).startswith("v"):
            return (th, bs, (0, 0, 0, 0))
        return (bs, th, (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        c = _color(r["background"], 0x4a6984)
        fill(h, box[0], box[1], box[2], box[3], c)
        draw_relief(h, box[0], box[1], box[2], box[3], _px(r["borderwidth"], 1), _relief(r["pbarrelief"]), c)


def _text_setup(w, r):
    f = w.app.font_of(r["font"] if r.get("font") not in (None, "") else DEFAULT_FONT)
    t = tcl_str(r.get("text", "")) if r.get("text") is not None else ""
    wrap = _px(r.get("wraplength"), 0)
    just = tcl_str(r.get("justify") or "left")
    if just not in ("left", "center", "right"):
        just = "left"
    lines, tw, th = layout_text(f, t, wrap, just)
    return f, t, lines, tw, th


def _text_reqwidth(f, tw, wv):
    # TextReqWidth: -width in average characters, a minimum when negative
    if wv is None or tcl_str(wv) == "":
        return tw
    try:
        n = get_int(wv)
    except TclError:
        return tw
    avg = f.measure("0")
    if n <= 0:
        spec = avg * -n
        return spec if spec > tw else tw
    return avg * n


def _draw_text_block(h, w, r, f, lines, x, y, ww, hh, tw, th, fg, state):
    # anchored in the box, as ttkLabel.c's TextDraw
    a = tcl_str(r.get("anchor") or "w")
    if a in ("nw", "w", "sw"):
        tx = x
    elif a in ("ne", "e", "se"):
        tx = x + ww - tw
    else:
        tx = x + (ww - tw) // 2
    if a in ("nw", "n", "ne"):
        ty = y
    elif a in ("sw", "s", "se"):
        ty = y + hh - th
    else:
        ty = y + (hh - th) // 2
    ul = _int(r.get("underline", -1), -1)
    k = 0
    gui_push_clip(h, x, y, ww, hh)
    for (s, lx, ly, lw) in lines:
        draw_text(h, s, tx + lx, ty + ly, f, fg)
        if 0 <= ul - k < len(s):
            c0 = f.measure(s[:ul - k])
            c1 = f.measure(s[:ul - k + 1])
            asc = f.metrics()[0]
            fill(h, tx + lx + c0, ty + ly + asc + 1, c1 - c0, 1, fg)
        k += len(s) + 1
    gui_pop_clip(h)


class TextElement(Element):
    NAME = "text"
    OPTS = [("-text", ""), ("-font", DEFAULT_FONT), ("-foreground", "black"), ("-underline", "-1"),
            ("-width", "-1"), ("-anchor", "w"), ("-justify", "left"), ("-wraplength", "0"), ("-embossed", "0")]

    def size(self, r, w, state):
        f, t, lines, tw, th = _text_setup(w, r)
        return (_text_reqwidth(f, tw, r["width"]), th, (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        f, t, lines, tw, th = _text_setup(w, r)
        _draw_text_block(h, w, r, f, lines, box[0], box[1], box[2], box[3], tw, th, _color(r["foreground"], 0), state)


class ImageElement(Element):
    NAME = "image"
    OPTS = [("-image", ""), ("-stipple", "gray50"), ("-background", DEFAULT_BG)]

    def size(self, r, w, state):
        im = _image_spec(w, r["image"], state)
        if im is None:
            return (0, 0, (0, 0, 0, 0))
        return (im.width(), im.height(), (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        im = _image_spec(w, r["image"], state)
        if im is None:
            return
        x = box[0] + (box[2] - im.width()) // 2
        y = box[1] + (box[3] - im.height()) // 2
        im.draw(h, x, y, im.width(), im.height())


class LabelElement(Element):
    # ttkLabel.c: text and image, -compound
    NAME = "label"
    OPTS = [("-compound", "none"), ("-space", "4"), ("-text", ""), ("-font", DEFAULT_FONT),
            ("-foreground", "black"), ("-underline", "-1"), ("-width", ""), ("-anchor", "w"),
            ("-justify", "left"), ("-wraplength", "0"), ("-embossed", "0"), ("-image", ""),
            ("-stipple", "gray50"), ("-background", DEFAULT_BG)]

    def _setup(self, r, w, state):
        im = _image_spec(w, r["image"], state)
        comp = tcl_str(r["compound"] or "none")
        if comp not in ("none", "text", "image", "center", "top", "bottom", "left", "right"):
            comp = "none"
        if comp == "none":
            comp = "image" if im is not None else "text"
        elif im is None:
            comp = "text"
        return im, comp

    def size(self, r, w, state):
        im, comp = self._setup(r, w, state)
        f, t, lines, tw, th = _text_setup(w, r)
        iw = im.width() if im is not None else 0
        ih = im.height() if im is not None else 0
        sp = _px(r["space"], 4)
        if comp == "image":
            return (iw, ih, (0, 0, 0, 0))
        trw = _text_reqwidth(f, tw, r["width"])
        if comp == "text":
            return (trw, th, (0, 0, 0, 0))
        if comp in ("top", "bottom"):
            return (max(iw, trw), ih + th + sp, (0, 0, 0, 0))
        if comp == "center":
            return (max(iw, trw), max(ih, th), (0, 0, 0, 0))
        return (iw + trw + sp, max(ih, th), (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        im, comp = self._setup(r, w, state)
        f, t, lines, tw, th = _text_setup(w, r)
        fg = _color(r["foreground"], 0)
        x, y, ww, hh = box
        iw = im.width() if im is not None else 0
        ih = im.height() if im is not None else 0
        sp = _px(r["space"], 4)
        if comp == "image":
            self._img(h, im, r, x, y, ww, hh, iw, ih)
            return
        if comp == "text":
            _draw_text_block(h, w, r, f, lines, x, y, ww, hh, tw, th, fg, state)
            return
        # LabelElementDraw: the image and text as one block, anchored
        if comp in ("top", "bottom"):
            bw = max(iw, tw)
            bh = ih + th + sp
        elif comp == "center":
            bw = max(iw, tw)
            bh = max(ih, th)
        else:
            bw = iw + tw + sp
            bh = max(ih, th)
        a = tcl_str(r.get("anchor") or "w")
        bx = x if a in ("nw", "w", "sw") else (x + ww - bw if a in ("ne", "e", "se") else x + (ww - bw) // 2)
        by = y if a in ("nw", "n", "ne") else (y + hh - bh if a in ("sw", "s", "se") else y + (hh - bh) // 2)
        rc = dict(r)
        rc["anchor"] = "center"
        if comp == "top":
            self._img(h, im, r, bx, by, bw, ih, iw, ih)
            _draw_text_block(h, w, rc, f, lines, bx, by + ih + sp, bw, th, tw, th, fg, state)
        elif comp == "bottom":
            _draw_text_block(h, w, rc, f, lines, bx, by, bw, th, tw, th, fg, state)
            self._img(h, im, r, bx, by + th + sp, bw, ih, iw, ih)
        elif comp == "left":
            self._img(h, im, r, bx, by, iw, bh, iw, ih)
            _draw_text_block(h, w, rc, f, lines, bx + iw + sp, by, tw, bh, tw, th, fg, state)
        elif comp == "right":
            _draw_text_block(h, w, rc, f, lines, bx, by, tw, bh, tw, th, fg, state)
            self._img(h, im, r, bx + tw + sp, by, iw, bh, iw, ih)
        else:
            self._img(h, im, r, bx, by, bw, bh, iw, ih)
            _draw_text_block(h, w, rc, f, lines, bx, by, bw, bh, tw, th, fg, state)

    def _img(self, h, im, r, x, y, ww, hh, iw, ih):
        if im is None:
            return
        a = tcl_str(r.get("anchor") or "w")
        ix = x if a in ("nw", "w", "sw") else (x + ww - iw if a in ("ne", "e", "se") else x + (ww - iw) // 2)
        iy = y if a in ("nw", "n", "ne") else (y + hh - ih if a in ("sw", "s", "se") else y + (hh - ih) // 2)
        im.draw(h, ix, iy, iw, ih)


class IndicatorElement(Element):
    # ttkDefaultTheme.c: the check box / radio diamond, at Tk 8.6.12's 16
    # pixels and scaling level 1, inside -indicatormargin
    NAME = "indicator"
    KIND = "check"
    OPTS = [("-background", DEFAULT_BG), ("-foreground", DEFAULT_FG), ("-indicatorcolor", "#FFFFFF"),
            ("-lightcolor", "#DDDDDD"), ("-shadecolor", "#888888"), ("-bordercolor", "black"),
            ("-indicatormargin", "0 2 4 2")]
    SIZE = 16

    def size(self, r, w, state):
        try:
            m = parse_padding(r["indicatormargin"])
        except TclError:
            m = (0, 2, 4, 2)
        return (self.SIZE + m[0] + m[2], self.SIZE + m[1] + m[3], (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        try:
            m = parse_padding(r["indicatormargin"])
        except TclError:
            m = (0, 2, 4, 2)
        x = box[0] + m[0]
        y = box[1] + (box[3] - self.SIZE) // 2
        s = self.SIZE
        ic = _color(r["indicatorcolor"], 0xffffff)
        border = _color(r["bordercolor"], 0)
        fg = _color(r["foreground"], 0)
        if self.KIND == "check":
            fill(h, x, y, s, s, ic)
            draw_ring(h, x, y, s, s, 1, border)
            if state & S_SELECTED:
                # a check mark
                for i in range(4):
                    fill(h, x + 3 + i, y + 7 + i, 2, 2, 0xffffff)
                for i in range(6):
                    fill(h, x + 7 + i, y + 9 - i, 2, 2, 0xffffff)
            elif state & S_ALTERNATE:
                fill(h, x + 4, y + 7, s - 8, 2, fg)
        else:
            rad = s // 2
            cx = x + rad
            cy = y + rad
            for j in range(s):
                dy = j - rad + 0.5
                half = int(math.sqrt(max(0.0, rad * rad - dy * dy)))
                fill(h, cx - half, y + j, 2 * half, 1, border)
                if half > 1:
                    fill(h, cx - half + 1, y + j, 2 * half - 2, 1, ic)
            if state & S_SELECTED:
                rr = s // 4
                for j in range(2 * rr):
                    dy = j - rr + 0.5
                    half = int(math.sqrt(max(0.0, rr * rr - dy * dy)))
                    fill(h, cx - half, cy - rr + j, 2 * half, 1, 0xffffff)


class RadioIndicatorElement(IndicatorElement):
    KIND = "radio"


class MenuIndicatorElement(Element):
    NAME = "Menubutton.indicator"
    OPTS = [("-background", DEFAULT_BG), ("-indicatorwidth", "4.0m"), ("-indicatorheight", "1.7m"),
            ("-borderwidth", "1"), ("-indicatorrelief", "raised"), ("-indicatormargin", "5 0")]

    def size(self, r, w, state):
        try:
            m = parse_padding(r["indicatormargin"])
        except TclError:
            m = (5, 0, 5, 0)
        return (_px(r["indicatorwidth"], 15) + m[0] + m[2], _px(r["indicatorheight"], 6) + m[1] + m[3], (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        try:
            m = parse_padding(r["indicatormargin"])
        except TclError:
            m = (5, 0, 5, 0)
        iw = _px(r["indicatorwidth"], 15)
        ih = _px(r["indicatorheight"], 6)
        x = box[0] + m[0]
        y = box[1] + (box[3] - ih) // 2
        c = _color(r["background"], 0xd9d9d9)
        draw_relief(h, x, y, iw, ih, _px(r["borderwidth"], 1), _relief(r["indicatorrelief"]), c)


class TextareaElement(Element):
    NAME = "textarea"
    OPTS = [("-font", DEFAULT_FONT), ("-width", "20")]

    def size(self, r, w, state):
        f = w.app.font_of(r["font"] if r["font"] not in (None, "") else DEFAULT_FONT)
        avg = f.measure("0")
        n = _int(r["width"], 20)
        if n <= 0:
            n = 1
        return (n * avg, f.metrics()[2], (0, 0, 0, 0))


class ClientElement(Element):
    NAME = "client"
    OPTS = [("-background", DEFAULT_BG), ("-borderwidth", "1"), ("-relief", "raised")]

    def size(self, r, w, state):
        bw = _px(r["borderwidth"])
        return (0, 0, (bw, bw, bw, bw))

    def draw(self, r, w, h, box, state):
        c = _color(r["background"], 0xd9d9d9)
        fill(h, box[0], box[1], box[2], box[3], c)
        draw_relief(h, box[0], box[1], box[2], box[3], _px(r["borderwidth"]), _relief(r["relief"]), c)


class TabElement(Element):
    NAME = "tab"
    OPTS = [("-background", DEFAULT_BG), ("-borderwidth", "1")]

    def size(self, r, w, state):
        bw = _px(r["borderwidth"])
        return (0, 0, (bw, bw, bw, 0))

    def draw(self, r, w, h, box, state):
        c = _color(r["background"], 0xd9d9d9)
        light, dark = shades(c)
        x, y, ww, hh = box
        bw = _px(r["borderwidth"])
        fill(h, x, y, ww, hh, c)
        for i in range(bw):
            fill(h, x + i, y + i, ww - 2 * i, 1, light)
            fill(h, x + i, y + i, 1, hh - i, light)
            fill(h, x + ww - 1 - i, y + i, 1, hh - i, dark)


class SashElement(Element):
    NAME = "sash"
    OPTS = [("-background", DEFAULT_BG), ("-sashthickness", "5"), ("-gripcount", "0")]
    ORIENT = "h"

    def size(self, r, w, state):
        t = _px(r["sashthickness"], 5)
        return (t, t, (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        c = _color(r["background"], 0xd9d9d9)
        fill(h, box[0], box[1], box[2], box[3], c)


class HSashElement(SashElement):
    NAME = "hsash"


class VSashElement(SashElement):
    NAME = "vsash"
    ORIENT = "v"


class TreeIndicatorElement(Element):
    # ttkTreeview.c: the open/closed triangle of an item with children
    NAME = "Treeitem.indicator"
    OPTS = [("-foreground", DEFAULT_FG), ("-indicatorsize", "12"), ("-indicatormargins", "2 2 4 2")]

    def size(self, r, w, state):
        s = _px(r["indicatorsize"], 12)
        try:
            m = parse_padding(r["indicatormargins"])
        except TclError:
            m = (2, 2, 4, 2)
        return (s + m[0] + m[2], s + m[1] + m[3], (0, 0, 0, 0))

    def draw(self, r, w, h, box, state):
        if state & S_ALTERNATE:     # a leaf: no indicator (the "leaf" user state)
            return
        if state & SBIT["user2"]:
            return
        s = _px(r["indicatorsize"], 12)
        try:
            m = parse_padding(r["indicatormargins"])
        except TclError:
            m = (2, 2, 4, 2)
        x = box[0] + m[0]
        y = box[1] + (box[3] - s) // 2
        c = _color(r["foreground"], 0)
        hs = (s - 1) // 2 if s > 2 else 1
        if state & SBIT["user1"]:
            fill_arrow(h, (x, y, s, s), "down", c)
        else:
            fill_arrow(h, (x, y, s, s), "right", c)


class RowElement(Element):
    NAME = "Treeitem.row"
    OPTS = [("-background", "white")]

    def draw(self, r, w, h, box, state):
        c = _color(r["background"])
        if c is not None:
            fill(h, box[0], box[1], box[2], box[3], c)


class CellElement(RowElement):
    NAME = "Treeheading.cell"
    OPTS = [("-background", DEFAULT_BG), ("-rownumber", "0")]


class ImageFactoryElement(Element):
    # ttk::style element create name image spec ?-border -height -padding
    # -sticky -width? (ttkImage.c)
    NAME = "image-element"
    OPTS = []

    def __init__(self, name, spec, opts):
        self.NAME = name
        self.spec = spec
        self.opts = opts

    def _image(self, w, state):
        return _image_spec(w, self.spec, state)

    def size(self, r, w, state):
        im = self._image(w, state)
        iw = im.width() if im is not None else 0
        ih = im.height() if im is not None else 0
        if "-width" in self.opts:
            iw = _px(self.opts["-width"])
        if "-height" in self.opts:
            ih = _px(self.opts["-height"])
        pad = parse_padding(self.opts.get("-padding", self.opts.get("-border", "0")))
        return (iw, ih, pad)

    def draw(self, r, w, h, box, state):
        im = self._image(w, state)
        if im is None:
            return
        st = parse_sticky(self.opts.get("-sticky", "nswe"))
        x, y, ww, hh = stick_box(box[0], box[1], box[2], box[3], im.width(), im.height(), st)
        im.draw(h, x, y, im.width(), im.height())


_GENERIC = [NullElement, BackgroundElement, BorderElement, FieldElement, PaddingElement, FocusElement,
            SeparatorElement, HSeparatorElement, VSeparatorElement, SizegripElement, UpArrowElement,
            DownArrowElement, LeftArrowElement, RightArrowElement, TroughElement, ThumbElement, SliderElement,
            PbarElement, TextElement, ImageElement, LabelElement, TextareaElement, ClientElement, TabElement,
            HSashElement, VSashElement]


def _register_default_elements(th):
    for cls in _GENERIC:
        e = cls()
        th.elements[e.NAME] = e
    th.elements["fill"] = BackgroundElement()
    th.elements["arrow"] = DownArrowElement()
    th.elements["indicator"] = IndicatorElement()
    th.elements["Button.border"] = ButtonBorderElement()
    th.elements["Checkbutton.indicator"] = IndicatorElement()
    th.elements["Radiobutton.indicator"] = RadioIndicatorElement()
    th.elements["Menubutton.indicator"] = MenuIndicatorElement()
    th.elements["Treeitem.indicator"] = TreeIndicatorElement()
    th.elements["Treeitem.row"] = RowElement()
    th.elements["Treeheading.cell"] = CellElement()
    th.elements["treearea"] = NullElement()
    th.elements["null"] = NullElement()


# ── the default theme's layouts ───────────────────────────────────────────
def _default_layouts():
    nswe = "nswe"
    lay = {}
    lay["TButton"] = [L("Button.border", sticky=nswe, children=[
        L("Button.focus", sticky=nswe, children=[
            L("Button.padding", sticky=nswe, children=[L("Button.label", sticky=nswe)])])])]
    lay["TButton"][0].border = True
    lay["TLabel"] = [L("Label.border", sticky=nswe, children=[
        L("Label.padding", sticky=nswe, children=[L("Label.label", sticky=nswe)])])]
    lay["TLabel"][0].border = True
    lay["TLabel"][0].children[0].border = True
    for k in ("Checkbutton", "Radiobutton"):
        lay["T" + k] = [L(k + ".padding", sticky=nswe, children=[
            L(k + ".indicator", side="left"),
            L(k + ".focus", side="left", sticky="w", children=[L(k + ".label", sticky=nswe)])])]
    lay["TMenubutton"] = [L("Menubutton.border", sticky=nswe, children=[
        L("Menubutton.focus", sticky=nswe, children=[
            L("Menubutton.indicator", side="right"),
            L("Menubutton.padding", side="left", expand=True, sticky="we", children=[
                L("Menubutton.label", side="left")])])])]
    lay["TFrame"] = [L("Frame.border", sticky=nswe)]
    lay["TLabelframe"] = [L("Labelframe.border", sticky=nswe)]
    lay["TLabelframe.Label"] = [L("Label.fill", sticky=nswe, children=[L("Label.text", sticky=nswe)])]
    lay["TSeparator"] = [L("Separator.separator", sticky=nswe)]
    lay["TSizegrip"] = [L("Sizegrip.sizegrip", side="bottom", sticky="se")]
    lay["TEntry"] = [L("Entry.field", sticky=nswe, children=[
        L("Entry.padding", sticky=nswe, children=[L("Entry.textarea", sticky=nswe)])])]
    lay["TEntry"][0].border = True
    lay["TCombobox"] = [L("Combobox.field", sticky=nswe, children=[
        L("Combobox.downarrow", side="right", sticky="ns"),
        L("Combobox.padding", expand=True, sticky=nswe, children=[L("Combobox.textarea", sticky=nswe)])])]
    lay["TSpinbox"] = [L("Spinbox.field", side="top", sticky="we", children=[
        L("null", side="right", sticky="", children=[
            L("Spinbox.uparrow", side="top", sticky="e"),
            L("Spinbox.downarrow", side="bottom", sticky="e")]),
        L("Spinbox.padding", sticky=nswe, children=[L("Spinbox.textarea", sticky=nswe)])])]
    lay["Vertical.TScrollbar"] = [L("Vertical.Scrollbar.trough", sticky="ns", children=[
        L("Vertical.Scrollbar.uparrow", side="top"),
        L("Vertical.Scrollbar.downarrow", side="bottom"),
        L("Vertical.Scrollbar.thumb", expand=True, sticky=nswe)])]
    lay["Horizontal.TScrollbar"] = [L("Horizontal.Scrollbar.trough", sticky="we", children=[
        L("Horizontal.Scrollbar.leftarrow", side="left"),
        L("Horizontal.Scrollbar.rightarrow", side="right"),
        L("Horizontal.Scrollbar.thumb", expand=True, sticky=nswe)])]
    lay["Vertical.TScale"] = [L("Vertical.Scale.trough", sticky=nswe, children=[
        L("Vertical.Scale.slider", side="top")])]
    lay["Horizontal.TScale"] = [L("Horizontal.Scale.trough", sticky=nswe, children=[
        L("Horizontal.Scale.slider", side="left")])]
    lay["Vertical.TProgressbar"] = [L("Vertical.Progressbar.trough", sticky=nswe, children=[
        L("Vertical.Progressbar.pbar", side="bottom", sticky="we")])]
    lay["Horizontal.TProgressbar"] = [L("Horizontal.Progressbar.trough", sticky=nswe, children=[
        L("Horizontal.Progressbar.pbar", side="left", sticky="ns")])]
    lay["TNotebook"] = [L("Notebook.client", sticky=nswe)]
    lay["TNotebook.Tab"] = [L("Notebook.tab", sticky=nswe, children=[
        L("Notebook.padding", side="top", sticky=nswe, children=[
            L("Notebook.focus", side="top", sticky=nswe, children=[L("Notebook.label", side="top")])])])]
    lay["TPanedwindow"] = [L("Panedwindow.background", sticky="")]
    lay["Horizontal.Sash"] = [L("Sash.hsash", sticky="we")]
    lay["Vertical.Sash"] = [L("Sash.vsash", sticky="ns")]
    lay["Treeview"] = [L("Treeview.field", sticky=nswe, children=[
        L("Treeview.padding", sticky=nswe, children=[L("Treeview.treearea", sticky=nswe)])])]
    lay["Treeview"][0].border = True
    lay["Item"] = [L("Treeitem.padding", sticky=nswe, children=[
        L("Treeitem.indicator", side="left"),
        L("Treeitem.image", side="left"),
        L("Treeitem.focus", side="left", children=[L("Treeitem.text", side="left")])])]
    lay["Cell"] = [L("Treedata.padding", sticky=nswe, children=[L("Treeitem.text", sticky=nswe)])]
    lay["Heading"] = [L("Treeheading.cell", sticky=nswe),
                      L("Treeheading.border", sticky=nswe, children=[
                          L("Treeheading.padding", sticky=nswe, children=[
                              L("Treeheading.image", side="right"),
                              L("Treeheading.text", sticky="we")])])]
    lay["Row"] = [L("Treeitem.row", sticky=nswe)]
    lay["ComboboxPopdownFrame"] = parse_layout("ComboboxPopdownFrame.border -sticky nswe")
    lay["Toolbutton"] = parse_layout("Toolbutton.border -children {Toolbutton.padding -children {Toolbutton.label}}")
    return lay


def _cfg(th, style, **kw):
    st = th.get_style(style)
    for k, v in kw.items():
        st.settings["-" + k.rstrip("_")] = v


def _map(th, style, opt, spec):
    st = th.get_style(style)
    st.maps["-" + opt] = parse_statemap(spec)
    st.map_src["-" + opt] = join_list(spec) if isinstance(spec, (tuple, list)) else spec


def _default_settings(th):
    # tk/library/ttk/defaults.tcl
    colors = {"-frame": "#d9d9d9", "-foreground": "#000000", "-window": "#ffffff", "-alternate": "#e8e8e8",
              "-text": "#000000", "-activebg": "#ececec", "-selectbg": "#4a6984", "-selectfg": "#ffffff",
              "-darker": "#c3c3c3", "-disabledfg": "#a3a3a3", "-indicator": "#4a6984",
              "-disabledindicator": "#a3a3a3", "-pressedindicator": "#5895bc"}
    _cfg(th, ".", borderwidth="1", background=colors["-frame"], foreground=colors["-foreground"],
         troughcolor=colors["-darker"], font="TkDefaultFont", selectborderwidth="1",
         selectbackground=colors["-selectbg"], selectforeground=colors["-selectfg"], insertwidth="1",
         indicatordiameter="10")
    _map(th, ".", "background", ["disabled", colors["-frame"], "active", colors["-activebg"]])
    _map(th, ".", "foreground", ["disabled", colors["-disabledfg"]])
    _cfg(th, "TButton", anchor="center", padding="3 3", width="-9", relief="raised", shiftrelief="1")
    _map(th, "TButton", "relief", ["!disabled pressed", "sunken"])
    for k in ("TCheckbutton", "TRadiobutton"):
        _cfg(th, k, indicatorcolor="#ffffff", indicatorrelief="sunken", padding="1")
        _map(th, k, "indicatorcolor", ["pressed", colors["-activebg"], "selected", colors["-indicator"]])
        _map(th, k, "indicatorrelief", ["alternate", "raised"])
    _cfg(th, "TMenubutton", relief="raised", padding="10 3")
    _cfg(th, "TEntry", relief="sunken", fieldbackground="white", padding="1")
    _map(th, "TEntry", "fieldbackground", ["readonly", colors["-frame"], "disabled", colors["-frame"]])
    _cfg(th, "TCombobox", arrowsize="12", padding="1")
    _map(th, "TCombobox", "fieldbackground", ["readonly", colors["-frame"], "disabled", colors["-frame"]])
    _map(th, "TCombobox", "arrowcolor", ["disabled", colors["-disabledfg"]])
    _cfg(th, "TSpinbox", arrowsize="10", padding="2 0 10 0")
    _map(th, "TSpinbox", "fieldbackground", ["readonly", colors["-frame"], "disabled", colors["-frame"]])
    _map(th, "TSpinbox", "arrowcolor", ["disabled", colors["-disabledfg"]])
    _cfg(th, "TLabelframe", relief="groove", borderwidth="2")
    _cfg(th, "TScrollbar", width="12", arrowsize="12")
    _map(th, "TScrollbar", "arrowcolor", ["disabled", colors["-disabledfg"]])
    _cfg(th, "TScale", sliderrelief="raised")
    _cfg(th, "TProgressbar", background=colors["-selectbg"])
    _cfg(th, "TNotebook.Tab", padding="4 2", background=colors["-darker"])
    _map(th, "TNotebook.Tab", "background", ["selected", colors["-frame"]])
    _cfg(th, "Heading", font="TkHeadingFont", relief="raised")
    _cfg(th, "Treeview", background=colors["-window"], foreground=colors["-text"])
    _map(th, "Treeview", "background", ["disabled", colors["-frame"], "selected", colors["-selectbg"]])
    _map(th, "Treeview", "foreground", ["disabled", colors["-disabledfg"], "selected", colors["-selectfg"]])
    _cfg(th, "ComboboxPopdownFrame", borderwidth="1", relief="solid")
    _cfg(th, "Toolbutton", padding="2", relief="flat")
    _map(th, "Toolbutton", "relief", ["disabled", "flat", "selected", "sunken", "pressed", "sunken", "active", "raised"])
    _map(th, "Toolbutton", "background", ["pressed", colors["-darker"], "active", colors["-activebg"]])


def _clam_settings(th):
    # tk/library/ttk/clamTheme.tcl (the colours and paddings)
    c = {"-disabledfg": "#999999", "-frame": "#dcdad5", "-window": "#ffffff", "-dark": "#cfcdc8",
         "-darker": "#bab5ab", "-darkest": "#9e9a91", "-lighter": "#eeebe7", "-lightest": "#ffffff",
         "-selectbg": "#4a6984", "-selectfg": "#ffffff", "-altindicator": "#5895bc",
         "-disabledaltindicator": "#a0a0a0"}
    _cfg(th, ".", background=c["-frame"], foreground="black", bordercolor=c["-darkest"], darkcolor=c["-dark"],
         lightcolor=c["-lighter"], troughcolor=c["-darker"], selectbackground=c["-selectbg"],
         selectforeground=c["-selectfg"], selectborderwidth="0", font="TkDefaultFont")
    _map(th, ".", "background", ["disabled", c["-frame"], "active", c["-lighter"]])
    _map(th, ".", "foreground", ["disabled", c["-disabledfg"]])
    _map(th, ".", "selectbackground", ["!focus", c["-darkest"]])
    _map(th, ".", "selectforeground", ["!focus", "white"])
    _cfg(th, "TButton", anchor="center", width="-11", padding="5", relief="raised")
    _map(th, "TButton", "background", ["disabled", c["-frame"], "pressed", c["-darker"], "active", c["-lighter"]])
    _map(th, "TButton", "lightcolor", ["pressed", c["-darker"]])
    _map(th, "TButton", "darkcolor", ["pressed", c["-darker"]])
    _map(th, "TButton", "bordercolor", ["alternate", "#000000"])
    _cfg(th, "Toolbutton", anchor="center", padding="2", relief="flat")
    _cfg(th, "TCheckbutton", indicatorbackground="#ffffff", indicatormargin="1 1 4 1", padding="2")
    _cfg(th, "TRadiobutton", indicatorbackground="#ffffff", indicatormargin="1 1 4 1", padding="2")
    _cfg(th, "TMenubutton", width="-11", padding="5", relief="raised")
    _cfg(th, "TEntry", padding="1", insertwidth="1")
    _cfg(th, "TCombobox", padding="1", insertwidth="1")
    _cfg(th, "TSpinbox", arrowsize="10", padding="2 0 10 0")
    _cfg(th, "TNotebook.Tab", padding="6 2 6 2")
    _map(th, "TNotebook.Tab", "padding", ["selected", "6 4 6 2"])
    _map(th, "TNotebook.Tab", "background", ["selected", c["-frame"], "", c["-darker"]])
    _cfg(th, "TLabelframe", labeloutside="true", labelmargins="0 0 0 4", borderwidth="2", relief="raised")
    _cfg(th, "TProgressbar", background=c["-frame"])
    _cfg(th, "Sash", sashthickness="6", gripcount="10")
    _cfg(th, "Treeview", background=c["-window"])
    _map(th, "Treeview", "background", ["disabled", c["-frame"], "selected", c["-selectbg"]])
    _map(th, "Treeview", "foreground", ["disabled", c["-disabledfg"], "selected", c["-selectfg"]])
    _cfg(th, "Heading", font="TkHeadingFont", relief="raised", padding="3")


def _alt_settings(th):
    # tk/library/ttk/altTheme.tcl
    c = {"-frame": "#d9d9d9", "-window": "#ffffff", "-darker": "#c3c3c3", "-border": "#414141",
         "-activebg": "#ececec", "-disabledfg": "#a3a3a3", "-selectbg": "#4a6984", "-selectfg": "#ffffff"}
    _cfg(th, ".", background=c["-frame"], foreground="black", troughcolor=c["-darker"], bordercolor=c["-border"],
         selectbackground=c["-selectbg"], selectforeground=c["-selectfg"], font="TkDefaultFont")
    _map(th, ".", "background", ["disabled", c["-frame"], "active", c["-activebg"]])
    _map(th, ".", "foreground", ["disabled", c["-disabledfg"]])
    _map(th, ".", "embossed", ["disabled", "1"])
    _cfg(th, "TButton", anchor="center", width="-11", padding="1 1", relief="raised", shiftrelief="1",
         highlightthickness="1", highlightcolor=c["-frame"])
    _map(th, "TButton", "relief", ["pressed", "sunken", "", "raised"])
    _map(th, "TButton", "highlightcolor", ["alternate", "black"])
    for k in ("TCheckbutton", "TRadiobutton"):
        _cfg(th, k, indicatorcolor="#ffffff", indicatormargin="0 1 4 1", padding="2")
        _map(th, k, "indicatorcolor", ["pressed", c["-frame"], "alternate", c["-altindicator"] if "-altindicator" in c else "#aaaaaa",
                                       "disabled", c["-frame"]])
    _cfg(th, "TMenubutton", width="-11", padding="3 3", relief="raised")
    _cfg(th, "TEntry", padding="1")
    _map(th, "TEntry", "fieldbackground", ["readonly", c["-frame"], "disabled", c["-frame"]])
    _cfg(th, "TCombobox", padding="1")
    _map(th, "TCombobox", "fieldbackground", ["readonly", c["-frame"], "disabled", c["-frame"]])
    _cfg(th, "TSpinbox", arrowsize="10", padding="2 0 10 0")
    _cfg(th, "Toolbutton", relief="flat", padding="2")
    _map(th, "Toolbutton", "relief", ["disabled", "flat", "selected", "sunken", "pressed", "sunken", "active", "raised"])
    _cfg(th, "TScrollbar", relief="raised")
    _cfg(th, "TLabelframe", relief="groove", borderwidth="2")
    _cfg(th, "TNotebook", tabmargins="2 2 1 0")
    _cfg(th, "TNotebook.Tab", padding="4 2", background=c["-darker"])
    _map(th, "TNotebook.Tab", "background", ["selected", c["-frame"]])
    _map(th, "TNotebook.Tab", "expand", ["selected", "2 2 1 0"])
    _cfg(th, "TScale", groovewidth="4", troughrelief="sunken", borderwidth="2")
    _cfg(th, "TProgressbar", background=c["-selectbg"], borderwidth="0")
    _cfg(th, "Heading", font="TkHeadingFont", relief="raised")
    _cfg(th, "Treeview", background=c["-window"])
    _map(th, "Treeview", "background", ["disabled", c["-frame"], "selected", c["-selectbg"]])
    _map(th, "Treeview", "foreground", ["disabled", c["-disabledfg"], "selected", c["-selectfg"]])


def _classic_settings(th):
    # tk/library/ttk/classicTheme.tcl
    c = {"-frame": "#d9d9d9", "-window": "#ffffff", "-activebg": "#ececec", "-troughbg": "#c3c3c3",
         "-selectbg": "#c3c3c3", "-selectfg": "#000000", "-disabledfg": "#a3a3a3", "-indicator": "#b03060",
         "-altindicator": "#b05e5e"}
    _cfg(th, ".", highlightcolor="black", highlightthickness="1", background=c["-frame"], borderwidth="2",
         font="TkDefaultFont", troughcolor=c["-troughbg"], selectbackground=c["-selectbg"],
         selectforeground=c["-selectfg"])
    _map(th, ".", "background", ["disabled", c["-frame"], "active", c["-activebg"]])
    _map(th, ".", "foreground", ["disabled", c["-disabledfg"]])
    _map(th, ".", "highlightcolor", ["focus", "black"])
    _cfg(th, "TButton", anchor="center", padding="3m 1m", relief="raised", shiftrelief="1")
    _map(th, "TButton", "relief", ["!disabled pressed", "sunken"])
    for k in ("TCheckbutton", "TRadiobutton"):
        _cfg(th, k, indicatorrelief="raised")
        _map(th, k, "indicatorcolor", ["pressed", c["-frame"], "alternate", c["-altindicator"],
                                       "selected", c["-indicator"]])
        _map(th, k, "indicatorrelief", ["alternate", "raised", "selected", "sunken", "pressed", "sunken"])
    _cfg(th, "TMenubutton", relief="raised", indicatormargin="5 0", padding="3m 1m")
    _cfg(th, "TEntry", padding="1")
    _map(th, "TEntry", "fieldbackground", ["readonly", c["-frame"]])
    _cfg(th, "TCombobox", padding="1")
    _map(th, "TCombobox", "fieldbackground", ["readonly", c["-frame"]])
    _cfg(th, "TSpinbox", arrowsize="10", padding="2 0 10 0")
    _cfg(th, "TLabelframe", borderwidth="2", relief="groove")
    _cfg(th, "TScrollbar", relief="raised")
    _map(th, "TScrollbar", "relief", ["pressed !disabled", "sunken"])
    _cfg(th, "TScale", sliderrelief="raised")
    _map(th, "TScale", "sliderrelief", ["pressed !disabled", "sunken"])
    _cfg(th, "TProgressbar", background="SteelBlue")
    _cfg(th, "TNotebook.Tab", background=c["-frame"], padding="3m 1m")
    _cfg(th, "Heading", font="TkHeadingFont", relief="raised")
    _cfg(th, "Treeview", background=c["-window"])
    _map(th, "Treeview", "background", ["disabled", c["-frame"], "selected", c["-selectbg"]])
    _map(th, "Treeview", "foreground", ["disabled", c["-disabledfg"], "selected", c["-selectfg"]])
    _cfg(th, "Toolbutton", relief="flat", padding="2")


def _build_themes(e):
    d = Theme("default", None)
    _register_default_elements(d)
    d.layouts = _default_layouts()
    _default_settings(d)
    alt = Theme("alt", d)
    _alt_settings(alt)
    clam = Theme("clam", alt)
    _clam_settings(clam)
    classic = Theme("classic", d)
    _classic_settings(classic)
    for t in (d, alt, clam, classic):
        e.themes[t.name] = t
    # `ttk::style theme names` lists them as Tk's hash table does on X11
    e.order = ["clam", "alt", "default", "classic"]


# ── laying out (ttkLayout.c) ──────────────────────────────────────────────
class Placed:
    def __init__(self, node, elem, box, rec):
        self.node = node
        self.elem = elem
        self.box = box
        self.rec = rec


class Layout:
    # a layout instantiated for a style: the template's nodes with their
    # element classes; `record` gives the widget's (or item's) options
    def __init__(self, theme, style, template, record_fn, widget):
        self.theme = theme
        self.style = style
        self.template = template
        self.record_fn = record_fn
        self.widget = widget
        self.elems = {}
        self._rec_cache = {}

    def element_of(self, node):
        e = self.elems.get(node.name)
        if e is None:
            e = self.theme.find_element(node.name)
            self.elems[node.name] = e
        return e

    def record(self, elem, state):
        # InitializeElementRecord: widget option, style map, style default,
        # element default
        key = (id(elem), state)
        r = self._rec_cache.get(key)
        if r is not None:
            return r
        wopts = self.record_fn()
        r = {}
        st = self.style
        for name, default in elem.OPTS:
            k = name[1:]
            v = wopts.get(k)
            if v is None:
                v = style_map(st, name, state)
                if v is None:
                    v = style_default(st, name)
                    if v is None:
                        v = default
            r[k] = v
        self._rec_cache[key] = r
        return r

    def invalidate(self):
        self._rec_cache = {}

    def node_size(self, node, state):
        e = self.element_of(node)
        r = self.record(e, state)
        ew, eh, pad = e.size(r, self.widget, state)
        sw, sh = self.list_size(node.children, state)
        sw += pad[0] + pad[2]
        sh += pad[1] + pad[3]
        return (max(ew, sw), max(eh, sh), pad)

    def list_size(self, nodes, state):
        # Ttk_LayoutNodeReqSize, over the siblings from the last
        w = 0
        h = 0
        for node in reversed(nodes):
            nw, nh, pad = self.node_size(node, state)
            if node.side in ("left", "right") and not node.expand:
                w = w + nw
                h = max(h, nh)
            elif node.side in ("top", "bottom") and not node.expand:
                w = max(w, nw)
                h = h + nh
            else:
                w = max(w, nw)
                h = max(h, nh)
        return (w, h)

    def size(self, state):
        return self.list_size(self.template, state)

    def place(self, box, state):
        out = []
        self._place(self.template, list(box), state, out)
        return out

    def _place(self, nodes, cavity, state, out):
        for node in nodes:
            w, h, pad = self.node_size(node, state)
            # Ttk_PositionBox
            cx, cy, cw, ch = cavity
            if node.expand or node.side is None:
                parcel = (cx, cy, cw, ch)
            elif node.side == "top":
                hh = min(h, ch)
                parcel = (cx, cy, cw, hh)
                cavity[1] = cy + hh
                cavity[3] = ch - hh
            elif node.side == "bottom":
                hh = min(h, ch)
                parcel = (cx, cy + ch - hh, cw, hh)
                cavity[3] = ch - hh
            elif node.side == "left":
                ww = min(w, cw)
                parcel = (cx, cy, ww, ch)
                cavity[0] = cx + ww
                cavity[2] = cw - ww
            else:
                ww = min(w, cw)
                parcel = (cx + cw - ww, cy, ww, ch)
                cavity[2] = cw - ww
            b = stick_box(parcel[0], parcel[1], parcel[2], parcel[3], w, h, node.sticky)
            e = self.element_of(node)
            out.append(Placed(node, e, b, self.record(e, state)))
            if node.children:
                inner = [b[0] + pad[0], b[1] + pad[1], max(0, b[2] - pad[0] - pad[2]), max(0, b[3] - pad[1] - pad[3])]
                self._place(node.children, inner, state, out)

    def draw(self, h, ox, oy, placed, state):
        for p in placed:
            b = p.box
            p.elem.draw(p.rec, self.widget, h, (ox + b[0], oy + b[1], b[2], b[3]), state)

    def find(self, placed, suffix):
        # Ttk_FindElement: the first node named suffix or "*.suffix"
        for p in placed:
            n = p.node.name
            if n == suffix or n.endswith("." + suffix):
                return p
        return None

    def find_node(self, suffix):
        def walk(nodes):
            for nd in nodes:
                if nd.name == suffix or nd.name.endswith("." + suffix):
                    return nd
                r = walk(nd.children)
                if r is not None:
                    return r
            return None
        return walk(self.template)

    def internal_padding(self, node, state):
        # Ttk_LayoutNodeInternalPadding: the padding of node's element
        e = self.element_of(node)
        return e.size(self.record(e, state), self.widget, state)[2]

    def identify(self, placed, x, y):
        # the innermost element containing (x, y)
        found = None
        for p in placed:
            b = p.box
            if b[0] <= x < b[0] + b[2] and b[1] <= y < b[1] + b[3]:
                found = p
        return found


def make_layout(app, style_name, record_fn, widget):
    e = engine(app)
    th = e.current
    tpl = th.find_layout(style_name)
    if tpl is None:
        raise TclError("Layout " + style_name + " not found")
    return Layout(th, th.get_style(style_name), tpl, record_fn, widget)


# ── the widget core (ttkWidget.c) ─────────────────────────────────────────
_COMPAT_STATES = ["normal", "readonly", "disabled", "active"]


def core_opts(takefocus=""):
    return [O("class", "", "", "", "string"), O("cursor", "cursor", "Cursor", "", "cursor"),
            O("style", "style", "Style", "", "string"), O("takefocus", "takeFocus", "TakeFocus", takefocus, "string")]


def label_opts():
    # ttkLabel / button "label" options
    return [O("text", "text", "Text", "", "string"), O("textvariable", "textVariable", "Variable", "", "var"),
            O("underline", "underline", "Underline", -1, "int"), O("width", "width", "Width", None, "string"),
            O("image", "image", "Image", None, "ttk_image"), O("compound", "compound", "Compound", None, "ttk_compound"),
            O("padding", "padding", "Pad", None, "ttk_padding")]


class TtkWidget(TkWin):
    CLASS = "TFrame"
    BASE_CMDS = ["cget", "configure", "identify", "instate", "state"]
    CMDS = BASE_CMDS
    ORIENTED = False
    DEFAULT_ORIENT = "horizontal"
    A11Y_ROLE = "generic"

    def __init__(self, app, path, parent, wclass=None):
        TkWin.__init__(self, app, path, parent, wclass)
        engine(app)
        self.tstate = 0
        self.layout = None
        self.layout_key = None
        self.placed = None
        self.placed_key = None
        self.links = {}

    # ── options ──
    def record_opts(self):
        return self.opts

    def style_name(self):
        st = self.opts.get("style") or ""
        base = st if st else self.CLASS
        if self.ORIENTED:
            o = self.opts.get("orient") or self.DEFAULT_ORIENT
            return ("Vertical." if o.startswith("v") else "Horizontal.") + base
        return base

    def get_layout(self):
        e = engine(self.app)
        key = (e.epoch, self.style_name(), self.cfg_serial)
        if self.layout is None or self.layout_key != key:
            self.layout = make_layout(self.app, self.style_name(), self.record_opts, self)
            self.layout_key = key
            self.placed = None
        return self.layout

    def validate_options(self, changed):
        if "style" in changed or "orient" in changed or "class" in changed:
            # a style without a layout is refused (Ttk_CreateLayout)
            make_layout(self.app, self.style_name(), self.record_opts, self)

    def reconfigured(self, changed):
        if "state" in changed:
            s = self.opts.get("state") or "normal"
            k = s if s in _COMPAT_STATES else "normal"
            allb = S_DISABLED | S_READONLY | S_ACTIVE
            f = {"normal": 0, "readonly": S_READONLY, "disabled": S_DISABLED, "active": S_ACTIVE}[k]
            self.change_state(f, allb ^ f)
        if "textvariable" in changed:
            self.relink("textvariable", self._textvar_changed)
            name = self.opts.get("textvariable") or ""
            if name and name in self.app.vars:
                self.opts["text"] = tcl_str(self.app.vars[name])
        if "image" in changed:
            v = self.opts.get("image")
            if v:
                self.app.watch_image(self, _words(v)[0])
        self.layout_key = None
        self.compute_geometry()
        self.damage()

    def relink(self, opt, cb):
        old = self.links.get(opt)
        if old is not None:
            self.app.remove_link(old)
            if old in self.var_links:
                self.var_links.remove(old)
            del self.links[opt]
        name = self.opts.get(opt) or ""
        if name:
            lk = self.app.add_link(name, cb)
            self.links[opt] = lk
            self.var_links.append(lk)

    def _textvar_changed(self, name, op):
        if self.destroyed:
            return
        self.opts["text"] = tcl_str(self.app.vars.get(name, ""))
        self.layout_key = None
        self.compute_geometry()
        self.damage()

    def cget_value(self, name):
        v = self.opts.get(name)
        if v is None:
            return ""
        return v

    # ── state ──
    def change_state(self, on, off):
        old = self.tstate
        self.tstate = (self.tstate | on) & ~off
        if self.tstate != old:
            self.state_changed(old)
            self.damage()

    def state_changed(self, old):
        pass

    def w_state(self, args):
        if not args:
            return statespec_string(self.tstate, 0)
        on, off = parse_statespec(args[0])
        old = self.tstate
        self.change_state(on, off)
        ch = old ^ self.tstate
        return statespec_string(old & ch, ~old & ch)

    def w_instate(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " instate state-spec ?script?\"")
        spec = parse_statespec(args[0])
        ok = state_matches(self.tstate, spec)
        if len(args) > 1:
            if ok:
                return self.app.interp.eval(tcl_str(args[1]))
            return ""
        return 1 if ok else 0

    # ── geometry ──
    def compute_geometry(self):
        lay = self.get_layout()
        w, h = lay.size(self.tstate)
        w, h = self.adjust_size(w, h)
        if w is not None:
            self.request(w, h)

    def adjust_size(self, w, h):
        return w, h

    def placements(self):
        lay = self.get_layout()
        key = (self.layout_key, self.width, self.height, self.tstate)
        if self.placed is None or self.placed_key != key:
            lay.invalidate()
            self.placed = lay.place((0, 0, self.width, self.height), self.tstate)
            self.placed_key = key
        return self.placed

    def draw(self, h, ax, ay):
        lay = self.get_layout()
        pl = self.placements()
        lay.draw(h, ax, ay, pl, self.tstate)
        self.draw_extra(h, ax, ay, pl)

    def draw_extra(self, h, ax, ay, placed):
        pass

    def w_identify(self, args):
        if len(args) == 3 and tcl_str(args[0]) == "element":
            args = args[1:]
        if len(args) != 2:
            raise TclError("wrong # args: should be \"" + self.path + " identify x y\"")
        x = get_int(args[0])
        y = get_int(args[1])
        p = self.get_layout().identify(self.placements(), x, y)
        if p is None:
            return ""
        nm = p.elem.NAME
        return nm if nm else p.node.name

    def on_event(self, ev):
        t = ev.type
        if t == B.FocusIn:
            self.change_state(S_FOCUS, 0)
        elif t == B.FocusOut:
            self.change_state(0, S_FOCUS)
        elif t == B.EnterNotify:
            self.change_state(S_HOVER, 0)
        elif t == B.LeaveNotify:
            self.change_state(0, S_HOVER)

    def on_resize(self):
        self.placed = None

    def a11y_states(self):
        out = []
        if self.tstate & S_DISABLED and "disabled" not in out:
            out.append("disabled")
        if self.tstate & S_SELECTED:
            out.append("checked")
        if self.tstate & S_PRESSED:
            out.append("pressed")
        return out


# ── frame, label, buttons, separator, sizegrip, labelframe, menubutton ───
FRAME_OPTS = [O("borderwidth", "borderWidth", "BorderWidth", None, "pixels_or_none"),
              O("padding", "padding", "Pad", None, "ttk_padding"),
              O("relief", "relief", "Relief", None, "relief_or_none"),
              O("width", "width", "Width", 0, "pixels"),
              O("height", "height", "Height", 0, "pixels")] + core_opts("0")


class TtkFrame(TtkWidget):
    CLASS = "TFrame"
    OPTS = FRAME_OPTS
    A11Y_ROLE = "group"

    def margins(self):
        # FrameMargins: -padding plus -borderwidth or the theme's border
        p = parse_padding(self.opts.get("padding")) if self.opts.get("padding") is not None else (0, 0, 0, 0)
        bw = self.opts.get("borderwidth")
        if bw is not None:
            b = pixels(bw)
            return pad_add(p, (b, b, b, b))
        lay = self.get_layout()
        nd = lay.find_node("border")
        if nd is not None:
            return pad_add(p, lay.internal_padding(nd, self.tstate))
        return p

    def compute_geometry(self):
        m = self.margins()
        self.set_internal_borders(m[0], m[1], m[2], m[3])
        w = self.px("width")
        h = self.px("height")
        if w > 0 or h > 0:
            self.request(w, h)


class TtkLabel(TtkWidget):
    CLASS = "TLabel"
    OPTS = [O("background", "frameColor", "FrameColor", None, "color_or_none"),
            O("foreground", "textColor", "TextColor", None, "color_or_none"),
            O("font", "font", "Font", None, "font_or_none"),
            O("borderwidth", "borderWidth", "BorderWidth", None, "pixels_or_none"),
            O("relief", "relief", "Relief", None, "relief_or_none"),
            O("anchor", "anchor", "Anchor", None, "anchor_or_none"),
            O("justify", "justify", "Justify", None, "justify_or_none"),
            O("wraplength", "wrapLength", "WrapLength", None, "pixels_or_none")] + [
        o for o in label_opts()] + [O("state", "state", "State", "normal", "string")] + core_opts("")
    A11Y_ROLE = "label"


class TtkButton(TtkWidget):
    CLASS = "TButton"
    OPTS = [O("command", "command", "Command", "", "command"),
            O("default", "default", "Default", "normal", "enum:normal|active|disabled:default")] + [
        O("takefocus", "takeFocus", "TakeFocus", "ttk::takefocus", "string")] + label_opts() + [
        O("state", "state", "State", "normal", "string")] + [o for o in core_opts() if o[0] != "takefocus"]
    CMDS = TtkWidget.BASE_CMDS + ["invoke"]
    TAKES_FOCUS = True
    A11Y_ROLE = "button"

    def w_invoke(self, args):
        if self.tstate & S_DISABLED:
            return ""
        cmd = self.opts.get("command") or ""
        if cmd:
            return self.app.interp.eval(cmd)
        return ""


class TtkCheckbutton(TtkButton):
    CLASS = "TCheckbutton"
    OPTS = [O("variable", "variable", "Variable", None, "var_or_none"),
            O("onvalue", "onValue", "OnValue", "1", "string"),
            O("offvalue", "offValue", "OffValue", "0", "string"),
            O("command", "command", "Command", "", "command"),
            O("takefocus", "takeFocus", "TakeFocus", "ttk::takefocus", "string")] + label_opts() + [
        O("state", "state", "State", "normal", "string")] + [o for o in core_opts() if o[0] != "takefocus"]
    A11Y_ROLE = "checkbox"

    def created(self):
        # CheckbuttonInitialize: the variable defaults to the widget's name
        if self.opts.get("variable") is None:
            self.opts["variable"] = self.path
        TtkWidget.created(self)

    def var_name(self):
        return self.opts.get("variable") or ""

    def reconfigured(self, changed):
        if "variable" in changed:
            self.relink("variable", self._var_changed)
        TtkWidget.reconfigured(self, changed)
        if "variable" in changed or "onvalue" in changed or "offvalue" in changed or "value" in changed:
            self.sync_var()

    def _var_changed(self, name, op):
        if not self.destroyed:
            self.sync_var()

    def sync_var(self):
        # CheckbuttonVariableChanged: selected when the value is -onvalue,
        # alternate when the variable does not exist
        name = self.var_name()
        if not name:
            return
        if name not in self.app.vars:
            self.change_state(S_ALTERNATE, S_SELECTED)
            return
        v = tcl_str(self.app.vars[name])
        if v == tcl_str(self.opts.get(self.ON_OPT, "1")):
            self.change_state(S_SELECTED, S_ALTERNATE)
        else:
            self.change_state(0, S_SELECTED | S_ALTERNATE)

    ON_OPT = "onvalue"

    def w_invoke(self, args):
        if self.tstate & S_DISABLED:
            return ""
        name = self.var_name()
        new = self.opts["offvalue"] if self.tstate & S_SELECTED else self.opts["onvalue"]
        if name:
            self.app.interp.setvar(name, new)
        cmd = self.opts.get("command") or ""
        if cmd:
            return self.app.interp.eval(cmd)
        return ""


class TtkRadiobutton(TtkCheckbutton):
    CLASS = "TRadiobutton"
    OPTS = [O("variable", "variable", "Variable", "::selectedButton", "var"),
            O("value", "Value", "Value", "1", "string"),
            O("command", "command", "Command", "", "command"),
            O("takefocus", "takeFocus", "TakeFocus", "ttk::takefocus", "string")] + label_opts() + [
        O("state", "state", "State", "normal", "string")] + [o for o in core_opts() if o[0] != "takefocus"]
    ON_OPT = "value"
    A11Y_ROLE = "radio"

    def created(self):
        TtkWidget.created(self)

    def sync_var(self):
        name = self.var_name()
        if not name:
            return
        if name not in self.app.vars:
            self.change_state(S_ALTERNATE, S_SELECTED)
            return
        if tcl_str(self.app.vars[name]) == tcl_str(self.opts.get("value", "1")):
            self.change_state(S_SELECTED, S_ALTERNATE)
        else:
            self.change_state(0, S_SELECTED | S_ALTERNATE)

    def w_invoke(self, args):
        if self.tstate & S_DISABLED:
            return ""
        name = self.var_name()
        if name:
            self.app.interp.setvar(name, self.opts["value"])
        cmd = self.opts.get("command") or ""
        if cmd:
            return self.app.interp.eval(cmd)
        return ""


class TtkMenubutton(TtkWidget):
    CLASS = "TMenubutton"
    OPTS = [O("menu", "menu", "Menu", "", "string"),
            O("direction", "direction", "Direction", "below", "enum:above|below|left|right|flush:direction")] + [
        O("takefocus", "takeFocus", "TakeFocus", "ttk::takefocus", "string")] + label_opts() + [
        O("state", "state", "State", "normal", "string")] + [o for o in core_opts() if o[0] != "takefocus"]
    TAKES_FOCUS = True
    A11Y_ROLE = "button"


class TtkSeparator(TtkWidget):
    CLASS = "TSeparator"
    OPTS = [O("orient", "orient", "Orient", "horizontal", "enum:horizontal|vertical:orient")] + core_opts("")
    A11Y_ROLE = "separator"


class TtkSizegrip(TtkWidget):
    CLASS = "TSizegrip"
    OPTS = core_opts("")


class TtkLabelframe(TtkFrame):
    CLASS = "TLabelframe"
    OPTS = sorted([o for o in FRAME_OPTS] + [
        O("labelanchor", "labelAnchor", "LabelAnchor", "nw", "enum:nw|n|ne|en|e|es|se|s|sw|ws|w|wn:anchor"),
        O("text", "text", "Text", "", "string"), O("underline", "underline", "Underline", -1, "int"),
        O("labelwidget", "labelWidget", "LabelWidget", "", "string")], key=lambda o: o[0])
    A11Y_ROLE = "group"

    def label_layout(self):
        st = self.opts.get("style") or ""
        name = (st if st else "TLabelframe") + ".Label"
        return make_layout(self.app, name, self._label_rec, self)

    def _label_rec(self):
        return {"text": self.opts.get("text", ""), "underline": self.opts.get("underline", -1)}

    def label_size(self):
        lw = self.opts.get("labelwidget") or ""
        if lw:
            w = self.app.widgets.get(lw)
            if w is not None:
                return w.reqw, w.reqh
            return 0, 0
        if not self.opts.get("text"):
            return 0, 0
        return self.label_layout().size(self.tstate)

    def margins(self):
        m = TtkFrame.margins(self)
        lw, lh = self.label_size()
        a = self.opts.get("labelanchor") or "nw"
        l, t, r, b = m
        if a[0] == "n":
            t = max(t, lh)
        elif a[0] == "s":
            b = max(b, lh)
        elif a[0] == "w":
            l = max(l, lw)
        else:
            r = max(r, lw)
        return (l, t, r, b)

    def compute_geometry(self):
        TtkFrame.compute_geometry(self)
        lw, lh = self.label_size()
        m = self.margins()
        mw = lw + m[0] + m[2]
        self.set_min_request(mw, m[1] + m[3])

    def draw(self, h, ax, ay):
        lw, lh = self.label_size()
        a = self.opts.get("labelanchor") or "nw"
        lay = self.get_layout()
        # the border sits halfway down the label (LabelframeDoLayout)
        top = lh // 2 if a[0] == "n" else 0
        bot = lh // 2 if a[0] == "s" else 0
        lay.invalidate()
        pl = lay.place((0, top, self.width, self.height - top - bot), self.tstate)
        lay.draw(h, ax, ay, pl, self.tstate)
        if lw > 0 and not self.opts.get("labelwidget"):
            ll = self.label_layout()
            if a in ("nw", "sw"):
                lx = 8
            elif a in ("ne", "se"):
                lx = self.width - lw - 8
            else:
                lx = (self.width - lw) // 2
            ly = 0 if a[0] == "n" else self.height - lh
            lp = ll.place((lx, ly, lw, lh), self.tstate)
            ll.draw(h, ax, ay, lp, self.tstate)

    def arrange_label(self):
        lw = self.opts.get("labelwidget") or ""
        if not lw:
            return
        w = self.app.widgets.get(lw)
        if w is None:
            return
        a = self.opts.get("labelanchor") or "nw"
        x = 8 if a in ("nw", "sw") else (self.width - w.reqw - 8 if a in ("ne", "se") else (self.width - w.reqw) // 2)
        y = 0 if a[0] == "n" else self.height - w.reqh
        self.app.place_slave(w, x, y, w.reqw, w.reqh) if hasattr(self.app, "place_slave") else None


# the extra option kinds of ttk widgets ("none" = the style decides)
def _norm_ttk(app, kind, v, optname):
    s = join_list(v) if isinstance(v, (tuple, list)) else tcl_str(v)
    if kind == "ttk_compound":
        if s == "":
            return None
        return match_prefix(s, ["none", "text", "image", "center", "top", "bottom", "left", "right"], "compound")
    if s == "" and kind.endswith("_or_none"):
        return None
    base = kind[:-8] if kind.endswith("_or_none") else kind
    if base == "pixels":
        fpixels(s)
        return v if isinstance(v, (int, float)) and not isinstance(v, bool) else s
    if base == "color":
        parse_color(s)
        return s
    if base == "font":
        app.font_of(s)
        return s
    if base == "relief":
        return match_prefix(s, ["flat", "groove", "raised", "ridge", "solid", "sunken"], "relief")
    if base == "anchor":
        return match_prefix(s, ["n", "ne", "e", "se", "s", "sw", "w", "nw", "center"], "anchor")
    if base == "justify":
        return match_prefix(s, ["left", "right", "center"], "justification")
    if base == "var":
        return s
    if kind == "ttk_padding":
        if s == "":
            return None
        parse_padding(s)
        return s
    if kind == "ttk_image":
        if s == "":
            return None
        nm = _words(s)[0]
        if nm not in app.images:
            raise TclError("image \"" + nm + "\" doesn't exist")
        return s
    if kind == "string_or_none":
        return s
    return _norm(app, kind, v, optname)


_TTK_KINDS = set(["ttk_compound", "ttk_padding", "ttk_image", "pixels_or_none", "color_or_none", "font_or_none",
                  "relief_or_none", "anchor_or_none", "justify_or_none", "var_or_none", "string_or_none"])


def _install_norm():
    # win._norm handles the classic kinds; the ttk ones are added in front
    from _tkinter import win as W
    if getattr(W, "_ttk_installed", False):
        return
    orig = W._norm

    def norm(app, kind, v, optname):
        if kind in _TTK_KINDS:
            return _norm_ttk(app, kind, v, optname)
        return orig(app, kind, v, optname)

    W._norm = norm
    W._ttk_installed = True


_install_norm()


# ── ttk::style ────────────────────────────────────────────────────────────
_STYLE_SUBS = ["configure", "element", "layout", "lookup", "map", "theme"]


def style_command(app, args):
    e = engine(app)
    if not args:
        raise TclError("wrong # args: should be \"ttk::style command ?args?\"")
    sub = match_prefix(tcl_str(args[0]), _STYLE_SUBS, "command")
    rest = list(args[1:])
    th = e.current
    if sub == "configure":
        if not rest:
            raise TclError("wrong # args: should be \"ttk::style configure style ?-option ?value...??\"")
        st = th.get_style(tcl_str(rest[0]))
        opts = rest[1:]
        if not opts:
            out = []
            for k, v in st.settings.items():
                out.extend([k, v])
            return tuple(out)
        if len(opts) == 1:
            v = st.settings.get(tcl_str(opts[0]))
            return v if v is not None else ""
        if len(opts) % 2 != 0:
            raise TclError("wrong # args: should be \"ttk::style configure style ?-option ?value...??\"")
        for i in range(0, len(opts), 2):
            k = tcl_str(opts[i])
            v = opts[i + 1]
            st.settings[k] = join_list(v) if isinstance(v, (tuple, list)) else v
        e.changed()
        return ""
    if sub == "map":
        if not rest:
            raise TclError("wrong # args: should be \"ttk::style map style ?-option ?value...??\"")
        st = th.get_style(tcl_str(rest[0]))
        opts = rest[1:]
        if not opts:
            out = []
            for k in st.maps:
                out.extend([k, st.map_src[k]])
            return tuple(out)
        if len(opts) == 1:
            v = st.map_src.get(tcl_str(opts[0]))
            return v if v is not None else ""
        if len(opts) % 2 != 0:
            raise TclError("wrong # args: should be \"ttk::style map style ?-option ?value...??\"")
        for i in range(0, len(opts), 2):
            k = tcl_str(opts[i])
            v = opts[i + 1]
            m = parse_statemap(v)
            st.maps[k] = m
            st.map_src[k] = v if isinstance(v, str) else join_list([join_list(x) if isinstance(x, (tuple, list)) else x for x in v])
        e.changed()
        return ""
    if sub == "lookup":
        if len(rest) < 2 or len(rest) > 4:
            raise TclError("wrong # args: should be \"ttk::style lookup style -option ?state? ?default?\"")
        st = th.get_style(tcl_str(rest[0]))
        state = 0
        if len(rest) >= 3:
            on, off = parse_statespec(rest[2])
            state = on
        v = style_query(st, tcl_str(rest[1]), state)
        if v is None:
            return rest[3] if len(rest) == 4 else ""
        return v
    if sub == "layout":
        if not rest:
            raise TclError("wrong # args: should be \"ttk::style layout name ?spec?\"")
        name = tcl_str(rest[0])
        if len(rest) == 1:
            tpl = th.find_layout(name)
            if tpl is None:
                raise TclError("Layout " + name + " not found")
            return unparse_layout(tpl)
        tpl = parse_layout(rest[1])
        # each element named must exist with its options (CheckLayout)
        th.layouts[name] = tpl
        e.changed()
        return unparse_layout(tpl)
    if sub == "element":
        if not rest:
            raise TclError("wrong # args: should be \"ttk::style element command ?args?\"")
        es = match_prefix(tcl_str(rest[0]), ["create", "names", "options"], "command")
        if es == "names":
            return tuple(sorted(k for k in th.elements.keys() if k))
        if es == "options":
            if len(rest) != 2:
                raise TclError("wrong # args: should be \"ttk::style element options element\"")
            nm = tcl_str(rest[1])
            el = th.find_element(nm)
            if el is NULL_ELEMENT and nm not in th.elements:
                raise TclError("element " + nm + " not found")
            return tuple(o[0] for o in el.OPTS)
        if len(rest) < 3:
            raise TclError("wrong # args: should be \"ttk::style element create name type ?-option value ...?\"")
        nm = tcl_str(rest[1])
        kind = tcl_str(rest[2])
        if kind == "image":
            if len(rest) < 4:
                raise TclError("wrong # args: should be \"ttk::style element create name image imagespec ?-option value ...?\"")
            spec = rest[3]
            opts = rest[4:]
            if len(opts) % 2 != 0:
                raise TclError("Value for " + tcl_str(opts[-1]) + " missing")
            od = {}
            for i in range(0, len(opts), 2):
                k = match_prefix(tcl_str(opts[i]), ["-border", "-height", "-padding", "-sticky", "-width"], "option")
                od[k] = opts[i + 1]
            for n in _words(spec)[::2] if len(_words(spec)) > 1 else _words(spec)[:1]:
                pass
            first = _words(spec)[0] if _words(spec) else ""
            if first not in app.images:
                raise TclError("image \"" + first + "\" doesn't exist")
            th.elements[nm] = ImageFactoryElement(nm, spec, od)
        elif kind == "from":
            src = e.theme(tcl_str(rest[3])) if len(rest) > 3 else None
            if src is None:
                raise TclError("wrong # args: should be \"ttk::style element create name from theme ?element?\"")
            frm = tcl_str(rest[4]) if len(rest) > 4 else nm
            th.elements[nm] = src.find_element(frm)
        else:
            raise TclError("No such element type " + kind)
        e.changed()
        return ""
    # theme
    if not rest:
        raise TclError("wrong # args: should be \"ttk::style theme command ?args?\"")
    ts = match_prefix(tcl_str(rest[0]), ["create", "names", "settings", "styles", "use"], "command")
    if ts == "names":
        return tuple(e.order)
    if ts == "use":
        if len(rest) == 1:
            return th.name
        e.use(e.theme(tcl_str(rest[1])))
        return ""
    if ts == "styles":
        t = e.theme(tcl_str(rest[1])) if len(rest) > 1 else th
        return tuple(k for k in t.styles.keys())
    if ts == "settings":
        if len(rest) != 3:
            raise TclError("wrong # args: should be \"ttk::style theme settings theme script\"")
        t = e.theme(tcl_str(rest[1]))
        saved = e.current
        e.current = t
        try:
            app.interp.eval(tcl_str(rest[2]))
        finally:
            e.current = saved
        e.changed()
        return ""
    # create
    if len(rest) < 2:
        raise TclError("wrong # args: should be \"ttk::style theme create name ?-option value ...?\"")
    nm = tcl_str(rest[1])
    opts = rest[2:]
    parent = e.themes["default"]
    script = ""
    if len(opts) % 2 != 0:
        raise TclError("value for \"" + tcl_str(opts[-1]) + "\" missing")
    for i in range(0, len(opts), 2):
        k = match_prefix(tcl_str(opts[i]), ["-parent", "-settings"], "option")
        if k == "-parent":
            parent = e.theme(tcl_str(opts[i + 1]))
        else:
            script = tcl_str(opts[i + 1])
    t = e.create_theme(nm, parent)
    if script:
        saved = e.current
        e.current = t
        try:
            app.interp.eval(script)
        finally:
            e.current = saved
    return ""


def c_set_theme(app, args):
    # ttk::setTheme: use it and remember it in $ttk::currentTheme
    if len(args) != 1:
        raise TclError("wrong # args: should be \"ttk::setTheme theme\"")
    e = engine(app)
    nm = tcl_str(args[0])
    e.use(e.theme(nm))
    app.interp.setvar("ttk::currentTheme", nm)
    return ""


def c_themes(app, args):
    return tuple(engine(app).order)


def c_takefocus(app, args):
    # ttk::takefocus: a widget takes focus when enabled and viewable
    w = app.window(args[0])
    if isinstance(w, TtkWidget) and w.tstate & S_DISABLED:
        return 0
    return 1 if w.viewable() else 0


def c_click_to_focus(app, args):
    w = app.window(args[0])
    tf = w.opts.get("takefocus") or ""
    ok = True
    if tf == "0":
        ok = False
    elif tf not in ("", "1"):
        try:
            ok = get_boolean(app.interp.eval(tf + " " + w.path))
        except TclError:
            ok = True
    if ok:
        app.set_focus(w)
    return ""


def c_button_activate(app, args):
    # ttk::button::activate: show the press, then invoke
    w = app.window(args[0])
    if not isinstance(w, TtkWidget) or w.tstate & S_DISABLED:
        return ""
    old = w.w_state(["pressed"])
    app.update(True)
    w.w_state([old] if old else ["!pressed"])
    return w.command(["invoke"])


def c_radio_traverse(app, args):
    w = app.window(args[0])
    d = get_int(args[1])
    var = w.opts.get("variable") or ""
    group = [x for x in w.parent.children if isinstance(x, TtkRadiobutton) and (x.opts.get("variable") or "") == var
             and not (x.tstate & S_DISABLED) and x.viewable()]
    if not group or w not in group:
        return ""
    i = (group.index(w) + d) % len(group)
    app.set_focus(group[i])
    group[i].command(["invoke"])
    return ""


def c_copy_bindings(app, args):
    src = tcl_str(args[0])
    dst = tcl_str(args[1])
    b = app.bindings
    for seq in b.sequences(src):
        b.set(dst, seq, b.get(src, seq))
    return ""


for _name, _f in (("ttk::setTheme", c_set_theme), ("ttk::themes", c_themes), ("ttk::takefocus", c_takefocus),
                  ("ttk::clickToFocus", c_click_to_focus), ("ttk::button::activate", c_button_activate),
                  ("ttk::button::RadioTraverse", c_radio_traverse), ("ttk::copyBindings", c_copy_bindings)):
    C.TK_COMMANDS[_name] = _f

for _name, _cls in (("ttk::frame", TtkFrame), ("ttk::label", TtkLabel), ("ttk::button", TtkButton),
                    ("ttk::checkbutton", TtkCheckbutton), ("ttk::radiobutton", TtkRadiobutton),
                    ("ttk::menubutton", TtkMenubutton), ("ttk::separator", TtkSeparator),
                    ("ttk::sizegrip", TtkSizegrip), ("ttk::labelframe", TtkLabelframe)):
    C.WIDGET_TYPES[_name] = _cls


def _bindings(app):
    # tk/library/ttk/button.tcl
    b = app.bindings
    for cls in ("TButton", "TCheckbutton", "TRadiobutton"):
        b.set(cls, "<Enter>", "%W instate !disabled {%W state active}")
        b.set(cls, "<Leave>", "%W state !active")
        b.set(cls, "<Key-space>", "ttk::button::activate %W")
        b.set(cls, "<<Invoke>>", "ttk::button::activate %W")
        b.set(cls, "<ButtonPress-1>", "%W instate !disabled { ttk::clickToFocus %W; %W state pressed }")
        b.set(cls, "<ButtonRelease-1>", "%W instate pressed { %W state !pressed; %W instate !disabled { %W invoke } }")
        b.set(cls, "<Button1-Leave>", "%W state !pressed")
        b.set(cls, "<Button1-Enter>", "%W instate {active !disabled} { %W state pressed }")
    b.set("TRadiobutton", "<Key-Up>", "ttk::button::RadioTraverse %W -1")
    b.set("TRadiobutton", "<Key-Down>", "ttk::button::RadioTraverse %W +1")
    b.set("TMenubutton", "<Enter>", "%W instate !disabled {%W state active}")
    b.set("TMenubutton", "<Leave>", "%W state !active")
    b.set("TMenubutton", "<Key-space>", "ttk::menubutton::Popdown %W")
    b.set("TMenubutton", "<<Invoke>>", "ttk::menubutton::Popdown %W")
    b.set("TMenubutton", "<ButtonPress-1>", "%W instate !disabled { ttk::clickToFocus %W; ttk::menubutton::Popdown %W }")


C.APP_INIT.append(_bindings)


def c_menubutton_popdown(app, args):
    # ttk::menubutton::Popdown: post -menu by -direction
    w = app.window(args[0])
    if w.tstate & S_DISABLED:
        return ""
    m = w.opts.get("menu") or ""
    if not m or m not in app.widgets:
        return ""
    rx, ry = w.root_xy()
    d = w.opts.get("direction") or "below"
    menu = app.widgets[m]
    if d == "above":
        y = ry - menu.reqh
        x = rx
    elif d == "left":
        x = rx - menu.reqw
        y = ry
    elif d == "right":
        x = rx + w.width
        y = ry
    elif d == "flush":
        x = rx
        y = ry
    else:
        x = rx
        y = ry + w.height
    w.change_state(S_PRESSED, 0)
    try:
        app.interp.invoke(["tk_popup", m, x, y])
    finally:
        w.change_state(0, S_PRESSED)
    return ""


C.TK_COMMANDS["ttk::menubutton::Popdown"] = c_menubutton_popdown
