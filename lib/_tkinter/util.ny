# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/util.ny - units, colours, fonts and drawing helpers for
# Nython's Tk (round 84).
#
#   pixels(v) / fpixels(v)   Tk_GetPixels: "10", 2.5, "1c", "3m", "1i", "2p"
#                            ('bad screen distance "x"'), at the screen's
#                            dots per inch (96, times the display scale)
#   parse_color(s)           Tk_GetColor: names (X11 + TIP 403), #rgb,
#                            #rrggbb, #rrrgggbbb, #rrrrggggbbbb -> 0xRRGGBB
#                            ('unknown color name "x"'); rgb16 for winfo rgb
#   shades(rgb)              Tk's light and dark 3D shadow colours (the
#                            formulas of tkUnix3d.c's TkpGetShadows)
#   Font / parse_font        Tk font descriptions: "Helvetica 12 bold",
#                            {Courier 10}, ("Times", 14, "italic"),
#                            -family X -size N ..., named fonts; sizes > 0
#                            are points, < 0 pixels; measured with the
#                            SDL backend (gui_measure_text_w)
#   draw_* helpers           3D borders and reliefs (raised, sunken, groove,
#                            ridge, solid, flat), highlight rings, text
#                            layouts (wrapping, justify, underline)

import math
import os
from _tkinter.tcl import TclError, tcl_str, split_list, join_list, get_int, get_double, get_boolean, match_prefix, or_list
from _tkinter.colors import COLORS


def cdiv(a, b):
    # C's integer division: truncates toward zero (Tk's algorithms rely on it).
    if b == 0:
        return 0
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def cround(d):
    # (int)(d + 0.5) for d >= 0, (int)(d - 0.5) below: Tk's rounding.
    return int(d + 0.5) if d >= 0 else -int(-d + 0.5)


# ── Screen distances ──────────────────────────────────────────────────────────

class _Screen:
    dpi = 96.0
    width = 1920
    height = 1080


SCREEN = _Screen()


def set_dpi(dpi):
    SCREEN.dpi = float(dpi)


def fpixels(v):
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    s = tcl_str(v).strip()
    if s == "":
        raise TclError("bad screen distance \"\"")
    unit = s[-1]
    num = s
    mult = 1.0
    if unit in "cimp":
        num = s[:-1].strip()
        if unit == "c":
            mult = SCREEN.dpi / 2.54
        elif unit == "i":
            mult = SCREEN.dpi
        elif unit == "m":
            mult = SCREEN.dpi / 25.4
        else:
            mult = SCREEN.dpi / 72.0
    try:
        d = float(num)
    except ValueError:
        raise TclError("bad screen distance \"" + s + "\"")
    return d * mult


def pixels(v):
    if isinstance(v, int) and not isinstance(v, bool):
        return v
    return cround(fpixels(v))


def is_pixels(v):
    try:
        fpixels(v)
        return True
    except TclError:
        return False


# ── Colours ───────────────────────────────────────────────────────────────────

_COLOR_CACHE = {}


def parse_color(s):
    # -> 0xRRGGBB, or raises TclError as Tk_GetColor does
    s = tcl_str(s)
    c = _COLOR_CACHE.get(s)
    if c is not None:
        return c
    v = _parse_color(s)
    if len(_COLOR_CACHE) > 4000:
        _COLOR_CACHE.clear()
    _COLOR_CACHE[s] = v
    return v


def _parse_color(s):
    if s.startswith("#"):
        h = s[1:]
        n = len(h)
        ok = n in (3, 6, 9, 12)
        if ok:
            for ch in h:
                if ch not in "0123456789abcdefABCDEF":
                    ok = False
                    break
        if not ok:
            raise TclError("invalid color name \"" + s + "\"")
        k = n // 3
        comps = [int(h[i * k:(i + 1) * k], 16) for i in range(3)]
        if k == 1:
            comps = [c * 17 for c in comps]
        elif k == 3:
            comps = [c >> 4 for c in comps]
        elif k == 4:
            comps = [c >> 8 for c in comps]
        return (comps[0] << 16) | (comps[1] << 8) | comps[2]
    key = s.replace(" ", "").lower()
    v = COLORS.get(key)
    if v is None:
        raise TclError("unknown color name \"" + s + "\"")
    return v


def rgb16(s):
    # winfo rgb: 16-bit components.  "#rrggbb" gives rr*257, as X does.
    s = tcl_str(s)
    if s.startswith("#") and len(s) == 13:
        try:
            return (int(s[1:5], 16), int(s[5:9], 16), int(s[9:13], 16))
        except ValueError:
            pass
    if s.startswith("#") and len(s) == 10:
        try:
            r, g, b = int(s[1:4], 16), int(s[4:7], 16), int(s[7:10], 16)
            return ((r << 4) | (r >> 8), (g << 4) | (g >> 8), (b << 4) | (b >> 8))
        except ValueError:
            pass
    c = parse_color(s)
    return (((c >> 16) & 255) * 257, ((c >> 8) & 255) * 257, (c & 255) * 257)


def color_hex(c):
    return "#%02x%02x%02x" % ((c >> 16) & 255, (c >> 8) & 255, c & 255)


def comps(c):
    return ((c >> 16) & 255, (c >> 8) & 255, c & 255)


def shades(c):
    # tkUnix3d.c, TkpGetShadows, in 16-bit units as there.
    MAX = 65535
    r = ((c >> 16) & 255) * 257
    g = ((c >> 8) & 255) * 257
    b = (c & 255) * 257
    if r * 0.5 * r + g * 1.0 * g + b * 0.28 * b < MAX * 0.05 * MAX:
        dr = (MAX + 3 * r) // 4
        dg = (MAX + 3 * g) // 4
        db = (MAX + 3 * b) // 4
    else:
        dr = (60 * r) // 100
        dg = (60 * g) // 100
        db = (60 * b) // 100
    if g > MAX * 0.95:
        lr = (90 * r) // 100
        lg = (90 * g) // 100
        lb = (90 * b) // 100
    else:
        t1 = min(MAX, (14 * r) // 10)
        t2 = (MAX + r) // 2
        lr = max(t1, t2)
        t1 = min(MAX, (14 * g) // 10)
        t2 = (MAX + g) // 2
        lg = max(t1, t2)
        t1 = min(MAX, (14 * b) // 10)
        t2 = (MAX + b) // 2
        lb = max(t1, t2)
    dark = ((dr >> 8) << 16) | ((dg >> 8) << 8) | (db >> 8)
    light = ((lr >> 8) << 16) | ((lg >> 8) << 8) | (lb >> 8)
    return light, dark


# ── Fonts ─────────────────────────────────────────────────────────────────────

_FONT_DIRS = ["/usr/share/fonts/truetype/dejavu/", "/usr/share/fonts/TTF/", "/usr/share/fonts/dejavu/",
              "/usr/share/fonts/truetype/liberation/", "/usr/share/fonts/truetype/freefont/"]

# Tk's family aliases (tkFont.c's TkFontGetAliasList, fontconfig's generic
# names) to the files the SDL backend can open.
_FAMILY_FILES = {
    "sans-serif": ["DejaVuSans.ttf", "LiberationSans-Regular.ttf", "FreeSans.ttf"],
    "serif": ["DejaVuSerif.ttf", "LiberationSerif-Regular.ttf", "FreeSerif.ttf"],
    "monospace": ["DejaVuSansMono.ttf", "LiberationMono-Regular.ttf", "FreeMono.ttf"],
}
_FAMILY_ALIASES = {
    "helvetica": "sans-serif", "arial": "sans-serif", "dejavu sans": "sans-serif", "sans": "sans-serif",
    "liberation sans": "sans-serif", "verdana": "sans-serif", "tahoma": "sans-serif", "segoe ui": "sans-serif",
    "lucida grande": "sans-serif", "freesans": "sans-serif", "system": "sans-serif", "tkdefaultfont": "sans-serif",
    "times": "serif", "times new roman": "serif", "dejavu serif": "serif", "liberation serif": "serif",
    "georgia": "serif", "freeserif": "serif",
    "courier": "monospace", "courier new": "monospace", "fixed": "monospace", "dejavu sans mono": "monospace",
    "liberation mono": "monospace", "consolas": "monospace", "menlo": "monospace", "monaco": "monospace",
    "lucida console": "monospace", "terminal": "monospace", "mono": "monospace", "freemono": "monospace",
    "systemfixed": "monospace", "ansifixed": "monospace", "oemfixed": "monospace",
}
_ACTUAL_FAMILY = {"sans-serif": "DejaVu Sans", "serif": "DejaVu Serif", "monospace": "DejaVu Sans Mono"}

_FILE_CACHE = {}


def generic_family(family):
    f = family.lower()
    if f in _FAMILY_FILES:
        return f
    return _FAMILY_ALIASES.get(f, "sans-serif")


def family_file(family, bold, italic):
    # The path handed to gui_load_font: a real file when one is installed (the
    # backend tries the family argument as a path first), else the generic
    # name, which the backend resolves with its own list.
    key = (family.lower(), bold, italic)
    if key in _FILE_CACHE:
        return _FILE_CACHE[key]
    g = generic_family(family)
    path = g
    for fname in _FAMILY_FILES[g]:
        cands = [fname]
        stem = fname[:-4]
        if bold and italic:
            cands = [stem.replace("-Regular", "") + "-BoldOblique.ttf", stem.replace("-Regular", "-BoldItalic") + ".ttf"] + cands
        elif bold:
            cands = [stem.replace("-Regular", "") + "-Bold.ttf", stem.replace("-Regular", "-Bold") + ".ttf"] + cands
        elif italic:
            cands = [stem.replace("-Regular", "") + "-Oblique.ttf", stem.replace("-Regular", "-Italic") + ".ttf"] + cands
        found = None
        for d in _FONT_DIRS:
            for c in cands:
                p = d + c
                if os.path.exists(p):
                    found = p
                    break
            if found:
                break
        if found:
            path = found
            break
    _FILE_CACHE[key] = path
    return path


def installed_families():
    fams = set(["Courier", "Times", "Helvetica", "fixed", "sans-serif", "serif", "monospace"])
    for d in _FONT_DIRS:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if n.lower().endswith(".ttf"):
                stem = n[:-4]
                for suf in ("-BoldOblique", "-BoldItalic", "-Bold", "-Oblique", "-Italic", "-Regular",
                            "-ExtraLight", "-Condensed", "-Light", "Bold", "Oblique"):
                    if stem.endswith(suf) and len(stem) > len(suf):
                        stem = stem[:-len(suf)]
                        break
                fams.add(_split_camel(stem))
    return sorted(fams)


def _split_camel(stem):
    out = ""
    for i in range(len(stem)):
        c = stem[i]
        if i > 0 and c.isupper() and (stem[i - 1].islower()):
            out += " "
        out += c
    return out.replace("Deja Vu", "DejaVu")


class Font:
    # One concrete font: what Tk_GetFont gives.  The backend handle is opened
    # lazily (it needs SDL initialised) and shared by equal descriptions.
    def __init__(self, family, size, weight, slant, underline, overstrike):
        self.family = family
        self.size = size
        self.weight = weight
        self.slant = slant
        self.underline = underline
        self.overstrike = overstrike
        self.handle = None
        self._metrics = None
        self._wcache = {}

    def px(self):
        if self.size < 0:
            return -self.size
        if self.size == 0:
            return 12
        return max(1, cround(self.size * SCREEN.dpi / 72.0))

    def open(self):
        if self.handle is None:
            path = family_file(self.family, self.weight == "bold", self.slant == "italic")
            self.handle = gui_load_font(path, self.px(), 1 if self.weight == "bold" else 0, 1 if self.slant == "italic" else 0)
        return self.handle

    def metrics(self):
        # (ascent, descent, linespace, fixed)
        if self._metrics is None:
            h = self.open()
            m = gui_font_metrics(h) if h is not None else None
            if m is None:
                p = self.px()
                asc = int(p * 0.93 + 0.5)
                hgt = int(p * 1.17 + 0.5)
                m = [hgt, asc, asc - hgt, hgt]
            asc = m[1]
            desc = -m[2] if m[2] < 0 else m[2]
            fixed = 1 if generic_family(self.family) == "monospace" else 0
            if h is not None:
                self._metrics = (asc, desc, asc + desc, fixed)
            else:
                return (asc, desc, asc + desc, fixed)
        return self._metrics

    def measure(self, text):
        w = self._wcache.get(text)
        if w is not None:
            return w
        h = self.open()
        if h is None:
            return int(len(text) * self.px() * 0.6 + 0.5)
        w = gui_measure_text_w(h, text)
        if len(self._wcache) > 2000:
            self._wcache = {}
        self._wcache[text] = w
        return w

    def actual(self):
        g = generic_family(self.family)
        fam = self.family
        if self.family.lower() in _FAMILY_FILES or self.family.lower() in _FAMILY_ALIASES:
            fam = _ACTUAL_FAMILY[g]
        size = self.size
        if size < 0:
            size = cround(-size * 72.0 / SCREEN.dpi)
        return (fam, size, self.weight, self.slant, self.underline, self.overstrike)


_FONT_CACHE = {}


def get_font(family, size, weight="normal", slant="roman", underline=0, overstrike=0):
    key = (family, size, weight, slant, underline, overstrike)
    f = _FONT_CACHE.get(key)
    if f is None:
        f = Font(family, size, weight, slant, underline, overstrike)
        _FONT_CACHE[key] = f
    return f


def reset_fonts():
    # SDL was shut down and brought up again: handles are stale.
    for f in _FONT_CACHE.values():
        f.handle = None
        f._metrics = None
        f._wcache = {}


_FONT_OPTS = ["-family", "-size", "-weight", "-slant", "-underline", "-overstrike"]


def parse_font_spec(desc, named=None):
    # -> dict(family, size, weight, slant, underline, overstrike) or raises.
    # `named` maps named-font names to their attribute dicts.
    if isinstance(desc, (tuple, list)):
        parts = [tcl_str(x) for x in desc]
    else:
        s = tcl_str(desc).strip()
        if named is not None and s in named:
            return dict(named[s])
        if s == "":
            raise TclError("font \"\" doesn't exist")
        if s.startswith("-") and not s.startswith("-*") and (s.split()[0] in _FONT_OPTS or s.split()[0] in ("-family", "-size")):
            parts = split_list(s)
            return parse_font_options(parts, {"family": "sans-serif", "size": 0, "weight": "normal", "slant": "roman", "underline": 0, "overstrike": 0})
        if s.startswith("-"):
            return _parse_xlfd(s)
        try:
            parts = split_list(s)
        except TclError:
            raise TclError("font \"" + s + "\" doesn't exist")
    if not parts:
        raise TclError("font \"\" doesn't exist")
    if parts[0].startswith("-") and parts[0] in _FONT_OPTS:
        return parse_font_options(parts, {"family": "sans-serif", "size": 0, "weight": "normal", "slant": "roman", "underline": 0, "overstrike": 0})
    if named is not None and len(parts) == 1 and parts[0] in named:
        return dict(named[parts[0]])
    fa = {"family": parts[0], "size": 0, "weight": "normal", "slant": "roman", "underline": 0, "overstrike": 0}
    if len(parts) > 1:
        try:
            fa["size"] = get_int(parts[1])
        except TclError:
            try:
                fa["size"] = int(round(get_double(parts[1])))
            except TclError:
                raise TclError("expected integer but got \"" + parts[1] + "\"")
    for st in parts[2:]:
        for w in split_list(st):
            lw = w.lower()
            if lw in ("normal", "bold"):
                fa["weight"] = lw
            elif lw in ("roman", "italic"):
                fa["slant"] = lw
            elif lw == "underline":
                fa["underline"] = 1
            elif lw == "overstrike":
                fa["overstrike"] = 1
            else:
                raise TclError("unknown font style \"" + w + "\"")
    return fa


def parse_font_options(parts, fa):
    if len(parts) % 2 != 0:
        raise TclError("value for \"" + parts[-1] + "\" option missing")
    for i in range(0, len(parts), 2):
        k = match_prefix(parts[i], _FONT_OPTS, "option")
        v = parts[i + 1]
        if k == "-family":
            fa["family"] = tcl_str(v)
        elif k == "-size":
            fa["size"] = int(round(get_double(v)))
        elif k == "-weight":
            fa["weight"] = match_prefix(tcl_str(v).lower(), ["normal", "bold"], "weight")
        elif k == "-slant":
            fa["slant"] = match_prefix(tcl_str(v).lower(), ["roman", "italic"], "slant")
        elif k == "-underline":
            fa["underline"] = 1 if get_boolean(v) else 0
        else:
            fa["overstrike"] = 1 if get_boolean(v) else 0
    return fa


def _parse_xlfd(s):
    # -foundry-family-weight-slant-setwidth-addstyle-pixel-point-...
    f = s.split("-")
    fa = {"family": "sans-serif", "size": 0, "weight": "normal", "slant": "roman", "underline": 0, "overstrike": 0}
    if len(f) > 2 and f[2] not in ("*", ""):
        fa["family"] = f[2]
    if len(f) > 3 and f[3] == "bold":
        fa["weight"] = "bold"
    if len(f) > 4 and f[4] in ("i", "o"):
        fa["slant"] = "italic"
    if len(f) > 7 and f[7].isdigit():
        fa["size"] = -int(f[7])
    elif len(f) > 8 and f[8].isdigit():
        fa["size"] = int(f[8]) // 10
    return fa


def font_from_attrs(fa):
    size = fa["size"]
    if size == 0:
        size = -12
    return get_font(fa["family"], size, fa["weight"], fa["slant"], fa["underline"], fa["overstrike"])


# ── Text layout (Tk_ComputeTextLayout) ────────────────────────────────────────

def layout_text(font, text, wraplength=0, justify="left"):
    # -> (lines, width, height): lines is a list of (string, x, y, width),
    # x and y relative to the layout's top-left.  Empty text still has one
    # line of the font's linespace, as in Tk.
    asc, desc, ls, fixed = font.metrics()
    raw = text.split("\n")
    lines = []
    for para in raw:
        if wraplength > 0 and font.measure(para) > wraplength:
            lines.extend(_wrap(font, para, wraplength))
        else:
            lines.append(para)
    widths = [font.measure(l) for l in lines]
    width = max(widths) if widths else 0
    out = []
    y = 0
    for i in range(len(lines)):
        w = widths[i]
        if justify == "center":
            x = (width - w) // 2
        elif justify == "right":
            x = width - w
        else:
            x = 0
        out.append((lines[i], x, y, w))
        y += ls
    if text == "":
        width = 0
    return out, width, ls * len(lines)


def _wrap(font, para, wraplength):
    words = para.split(" ")
    out = []
    cur = ""
    for w in words:
        cand = w if cur == "" else cur + " " + w
        if font.measure(cand) <= wraplength or cur == "":
            if cur == "" and font.measure(w) > wraplength:
                # a word longer than a line breaks between characters
                piece = ""
                for ch in w:
                    if piece != "" and font.measure(piece + ch) > wraplength:
                        out.append(piece)
                        piece = ""
                    piece += ch
                cur = piece
            else:
                cur = cand
        else:
            out.append(cur)
            cur = w
            if font.measure(w) > wraplength:
                piece = ""
                for ch in w:
                    if piece != "" and font.measure(piece + ch) > wraplength:
                        out.append(piece)
                        piece = ""
                    piece += ch
                cur = piece
    out.append(cur)
    return out


# ── Drawing ───────────────────────────────────────────────────────────────────
# All drawing goes to one backend window handle `h`, at absolute
# coordinates in that window.

def fill(h, x, y, w, ht, c):
    if w <= 0 or ht <= 0:
        return
    gui_fill_rect(h, x, y, w, ht, (c >> 16) & 255, (c >> 8) & 255, c & 255, 255)


def line(h, x1, y1, x2, y2, c, width=1):
    gui_draw_line(h, x1, y1, x2, y2, (c >> 16) & 255, (c >> 8) & 255, c & 255, 255, width)


def text(h, s, x, y, font, c):
    if s == "":
        return
    fh = font.open()
    if fh is None:
        return
    gui_draw_text(h, s, x, y, fh, (c >> 16) & 255, (c >> 8) & 255, c & 255, 255)


def draw_relief(h, x, y, w, ht, bw, relief, bg):
    # Tk_Draw3DRectangle: a border `bw` wide inside (x, y, w, ht).
    if bw <= 0 or w <= 0 or ht <= 0:
        return
    if relief == "flat":
        return
    light, dark = shades(bg)
    if relief == "solid":
        _bevel(h, x, y, w, ht, bw, 0x000000, 0x000000)
        return
    if relief == "raised":
        _bevel(h, x, y, w, ht, bw, light, dark)
    elif relief == "sunken":
        _bevel(h, x, y, w, ht, bw, dark, light)
    elif relief == "groove" or relief == "ridge":
        half = bw // 2
        if half < 1:
            half = 1
        a, b = (dark, light) if relief == "groove" else (light, dark)
        _bevel(h, x, y, w, ht, half, a, b)
        _bevel(h, x + half, y + half, w - 2 * half, ht - 2 * half, bw - half if bw - half > 0 else 1, b, a)


def _bevel(h, x, y, w, ht, bw, top, bottom):
    # top/left in `top`, bottom/right in `bottom`, mitred at the corners
    for i in range(bw):
        fill(h, x + i, y + i, w - 2 * i, 1, top)
        fill(h, x + i, y + i, 1, ht - 2 * i, top)
        fill(h, x + i, y + ht - 1 - i, w - 2 * i, 1, bottom)
        fill(h, x + w - 1 - i, y + i + 1, 1, ht - 2 * i - 1, bottom)


def draw_ring(h, x, y, w, ht, t, c):
    # a highlight ring `t` thick just inside (x, y, w, ht)
    if t <= 0:
        return
    fill(h, x, y, w, t, c)
    fill(h, x, y + ht - t, w, t, c)
    fill(h, x, y + t, t, ht - 2 * t, c)
    fill(h, x + w - t, y + t, t, ht - 2 * t, c)


def anchor_pos(anchor, x, y, w, ht, iw, ih):
    # where an iw x ih box goes in (x, y, w, ht) for an anchor (TkComputeAnchor)
    if anchor in ("nw", "w", "sw"):
        ax = x
    elif anchor in ("ne", "e", "se"):
        ax = x + w - iw
    else:
        ax = x + (w - iw) // 2
    if anchor in ("nw", "n", "ne"):
        ay = y
    elif anchor in ("sw", "s", "se"):
        ay = y + ht - ih
    else:
        ay = y + (ht - ih) // 2
    return ax, ay
