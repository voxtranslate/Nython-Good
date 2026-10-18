# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/text.ny - the text widget (round 84), after tkText.c,
# tkTextIndex.c, tkTextTag.c, tkTextMark.c and Tk's text.tcl.
#
# The contents are one string that always ends in the final newline Tk
# keeps (an empty widget holds "\n" and `end` is 2.0); embedded windows
# and images take one index position each (U+FFFC in the string, left out
# of `get`).
#
# indices     line.char, line.end, end, insert, current, marks, tag.first,
#             tag.last, @x,y, embedded window/image names, then any number
#             of modifiers: +/- N chars|indices|lines|displaychars|
#             displayindices|displaylines (abbreviations and "+3c" forms),
#             linestart, lineend, wordstart, wordend, display linestart/
#             lineend; 'bad text index "x"'
# editing     insert (tags from both neighbours unless a tag list is given),
#             delete (several ranges; the final newline survives, and a range
#             from a line start to end takes the newline before it, as in
#             Tk), replace, get (-displaychars), compare, count (all the
#             counting options), index
# marks       set/unset/names/gravity (left/right)/next/previous; insert and
#             current always exist
# tags        add/remove/delete/names/ranges/nextrange/prevrange/raise/lower/
#             cget/configure (every Tk 8.6 tag option) and bind (Enter/Leave
#             as the current mark crosses tagged text, button and key events
#             for the tags under it); "sel" is tied to -selectbackground/
#             -selectforeground and exported as the PRIMARY selection
# undo        -undo/-maxundo/-autoseparators: insert/delete atoms grouped by
#             separators (made automatically when the kind of edit changes or
#             the cursor moved), edit undo/redo/separator/reset/canundo/
#             canredo ("nothing to undo"), edit modified with Tk's dirty
#             counter (undoing back to the last save clears it), <<Modified>>,
#             <<Selection>>, <<UndoStack>>
# search      -forwards/-backwards/-exact/-regexp/-nocase/-all/-overlap/
#             -nolinestop/-strictlimits/-elide/-count, wrapping at the end
#             unless a stop index is given
# dump        -all/-text/-mark/-tag/-image/-window/-command; text reported a
#             line at a time
# display     wrap char/word/none, tag fonts/colours/underline/overstrike/
#             elide/lmargins/spacing, the insert cursor, see, yview/xview
#             (fractions, moveto, scroll units/pages/pixels), bbox, dlineinfo
# windows     window create/cget/configure/names (-window -create -align
#             -padx -pady -stretch), image create/cget/configure/names
#
# Not provided: peers (`peer create` raises TclError), -tabs stops beyond
# plain tab expansion to 8 average characters, -tabstyle, -blockcursor
# drawing, -startline/-endline, Tcl's regexp syntax beyond Python's re.

import re
from _tkinter.tcl import TclError, tcl_str, split_list, join_list, get_int, get_double, get_boolean, match_prefix, or_list
from _tkinter.util import pixels, parse_color, cdiv, shades, fill, line, text as draw_text, draw_relief, draw_ring
from _tkinter.win import TkWin, _norm
from _tkinter.bind import BindingTable, expand_percents
from _tkinter import core as C
from _tkinter import bind as B
from _tkinter.widgets import O, NORMAL_BG, SELECT_BG, DISABLED, BLACK, WHITE, _priv, _w

OBJ = "￼"

TEXT_OPTS = [
    O("autoseparators", "autoSeparators", "AutoSeparators", 1, "boolean"),
    O("background", "background", "Background", WHITE, "color"),
    O("blockcursor", "blockCursor", "BlockCursor", 0, "boolean"),
    O("borderwidth", "borderWidth", "BorderWidth", 1, "pixels"),
    O("cursor", "cursor", "Cursor", "xterm", "cursor"),
    O("endline", "", "", "", "string"),
    O("exportselection", "exportSelection", "ExportSelection", 1, "boolean"),
    O("font", "font", "Font", "TkFixedFont", "font"),
    O("foreground", "foreground", "Foreground", BLACK, "color"),
    O("height", "height", "Height", 24, "pixels"),
    O("highlightbackground", "highlightBackground", "HighlightBackground", NORMAL_BG, "color"),
    O("highlightcolor", "highlightColor", "HighlightColor", BLACK, "color"),
    O("highlightthickness", "highlightThickness", "HighlightThickness", 1, "pixels"),
    O("inactiveselectbackground", "inactiveSelectBackground", "Foreground", SELECT_BG, "color_or_empty"),
    O("insertbackground", "insertBackground", "Foreground", BLACK, "color"),
    O("insertborderwidth", "insertBorderWidth", "BorderWidth", 0, "pixels"),
    O("insertofftime", "insertOffTime", "OffTime", 300, "int"),
    O("insertontime", "insertOnTime", "OnTime", 600, "int"),
    O("insertunfocussed", "insertUnfocussed", "InsertUnfocussed", "none", "enum:hollow|none|solid:insertunfocussed"),
    O("insertwidth", "insertWidth", "InsertWidth", 2, "pixels"),
    O("maxundo", "maxUndo", "MaxUndo", 0, "int"),
    O("padx", "padX", "Pad", 1, "pixels"),
    O("pady", "padY", "Pad", 1, "pixels"),
    O("relief", "relief", "Relief", "sunken", "relief"),
    O("selectbackground", "selectBackground", "Foreground", SELECT_BG, "color"),
    O("selectborderwidth", "selectBorderWidth", "BorderWidth", 0, "pixels"),
    O("selectforeground", "selectForeground", "Background", BLACK, "color_or_empty"),
    O("setgrid", "setGrid", "SetGrid", 0, "boolean"),
    O("spacing1", "spacing1", "Spacing", 0, "pixels"),
    O("spacing2", "spacing2", "Spacing", 0, "pixels"),
    O("spacing3", "spacing3", "Spacing", 0, "pixels"),
    O("startline", "", "", "", "string"),
    O("state", "state", "State", "normal", "enum:disabled|normal:state"),
    O("tabs", "tabs", "Tabs", "", "list"),
    O("tabstyle", "tabStyle", "TabStyle", "tabular", "enum:tabular|wordprocessor:tabstyle"),
    O("takefocus", "takeFocus", "TakeFocus", "", "string"),
    O("undo", "undo", "Undo", 0, "boolean"),
    O("width", "width", "Width", 80, "int"),
    O("wrap", "wrap", "Wrap", "char", "enum:char|none|word:wrap"),
    O("xscrollcommand", "xScrollCommand", "ScrollCommand", "", "command"),
    O("yscrollcommand", "yScrollCommand", "ScrollCommand", "", "command"),
]

TAG_OPTS = ["background", "bgstipple", "borderwidth", "elide", "fgstipple", "font", "foreground", "justify",
            "lmargin1", "lmargin2", "lmargincolor", "offset", "overstrike", "overstrikefg", "relief", "rmargin",
            "rmargincolor", "selectbackground", "selectforeground", "spacing1", "spacing2", "spacing3", "tabs",
            "tabstyle", "underline", "underlinefg", "wrap"]
TAG_KINDS = {"background": "color_or_empty", "borderwidth": "pixels_or_empty", "elide": "boolean_or_empty",
             "font": "font_or_empty", "foreground": "color_or_empty", "justify": "enumx:center|left|right:justification",
             "lmargin1": "pixels_or_empty", "lmargin2": "pixels_or_empty", "lmargincolor": "color_or_empty",
             "offset": "pixels_or_empty", "overstrike": "boolean_or_empty", "overstrikefg": "color_or_empty",
             "relief": "relief_or_empty", "rmargin": "pixels_or_empty", "rmargincolor": "color_or_empty",
             "selectbackground": "color_or_empty", "selectforeground": "color_or_empty",
             "spacing1": "pixels_or_empty", "spacing2": "pixels_or_empty", "spacing3": "pixels_or_empty",
             "tabs": "list", "tabstyle": "enumx:tabular|wordprocessor:tabstyle", "underline": "boolean_or_empty",
             "underlinefg": "color_or_empty", "wrap": "enumx:char|none|word:wrap", "bgstipple": "string",
             "fgstipple": "string"}

ALIASES_TAG = {"bg": "background", "fg": "foreground", "bd": "borderwidth"}


class Tag:
    def __init__(self, name, prio):
        self.name = name
        self.prio = prio
        self.ranges = []        # sorted [start, end) offsets, disjoint, not touching
        self.opts = {}
        for k in TAG_OPTS:
            self.opts[k] = ""

    def covers(self, p):
        for a, b in self.ranges:
            if a <= p < b:
                return True
            if a > p:
                break
        return False

    def add(self, a, b):
        if b <= a:
            return False
        out = []
        changed = True
        for r in self.ranges:
            if r[1] < a or r[0] > b:
                out.append(r)
            else:
                if r[0] <= a and r[1] >= b:
                    changed = False
                a = min(a, r[0])
                b = max(b, r[1])
        out.append([a, b])
        out.sort()
        self.ranges = out
        return changed

    def remove(self, a, b):
        if b <= a:
            return False
        out = []
        changed = False
        for r in self.ranges:
            if r[1] <= a or r[0] >= b:
                out.append(r)
                continue
            changed = True
            if r[0] < a:
                out.append([r[0], a])
            if r[1] > b:
                out.append([b, r[1]])
        self.ranges = out
        return changed


class Embedded:
    def __init__(self, kind, name):
        self.kind = kind     # "window" or "image"
        self.name = name
        self.opts = {"align": "center", "padx": 0, "pady": 0}
        self.win = None
        self.w = 0
        self.h = 0


class DLine:
    def __init__(self, start, end, y, h, asc):
        self.start = start     # offset of the first char
        self.end = end         # offset after the last char shown (incl. the newline)
        self.y = y
        self.h = h
        self.asc = asc
        self.xs = None         # x of each char start (len end-start+1)


class TkText(TkWin):
    CLASS = "Text"
    OPTS = TEXT_OPTS
    ALIASES = {"bd": "borderwidth", "bg": "background", "fg": "foreground"}
    CMDS = ["bbox", "cget", "compare", "configure", "count", "debug", "delete", "dlineinfo", "dump", "edit",
            "get", "image", "index", "insert", "mark", "peer", "pendingsync", "replace", "scan", "search", "see",
            "sync", "tag", "window", "xview", "yview"]
    TAKES_FOCUS = True
    A11Y_ROLE = "textbox"

    def __init__(self, app, path, parent, wclass=None):
        TkWin.__init__(self, app, path, parent, wclass)
        self.s = "\n"
        self.starts = None
        self.marks = {"insert": [0, "right"], "current": [0, "right"]}
        self.mark_order = ["insert", "current"]
        self.tags = {}
        self.tag_n = 0
        self.tags["sel"] = Tag("sel", 0)
        self.tag_n = 1
        self.tag_bindings = BindingTable()
        self.embedded = {}      # offset -> Embedded (kept in sync with OBJ chars)
        self.undo_stack = []
        self.redo_stack = []
        self.last_edit = "other"
        self.dirty = 0
        self.dirty_mode = "normal"
        self.top_offset = 0
        self.top_dline = 0
        self.xoff = 0
        self.layout = None
        self.layout_w = -1
        self.cur_tags = []
        self.anchor_n = 0
        self.scan_mark = (0, 0, 0, 0)

    # ── configuration ──
    def created(self):
        self.sync_sel_tag()
        self.reconfigured(list(self.opts.keys()))

    def reconfigured(self, changed):
        if "selectbackground" in changed or "selectforeground" in changed:
            self.sync_sel_tag()
        if "maxundo" in changed:
            self.trim_undo()
        self.compute_geometry()
        self.invalidate()

    def sync_sel_tag(self):
        t = self.tags["sel"]
        t.opts["background"] = self.opts.get("selectbackground", SELECT_BG)
        t.opts["foreground"] = self.opts.get("selectforeground", "")

    def font(self):
        return self.app.font_of(self.opts["font"])

    def compute_geometry(self):
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        cw = max(1, f.measure("0"))
        bd = self.px("borderwidth")
        hl = self.px("highlightthickness")
        px = self.px("padx")
        py = self.px("pady")
        h = pixels(self.opts["height"])
        self.request(self.opts["width"] * cw + 2 * bd + 2 * px + 2 * hl,
                     h * (ls + self.px("spacing1") + self.px("spacing3")) + 2 * bd + 2 * py + 2 * hl)
        self.set_internal_border(bd + hl)

    def on_resize(self):
        self.invalidate()

    def invalidate(self):
        self.layout = None
        self.damage()
        self.app.after_idle_once(self, "_text_scroll", self.update_scroll)

    # ── offsets and lines ──
    def line_starts(self):
        if self.starts is None:
            st = [0]
            s = self.s
            i = s.find("\n")
            while i >= 0:
                st.append(i + 1)
                i = s.find("\n", i + 1)
            self.starts = st     # the last entry is len(s): the start of `end`
        return self.starts

    def nlines(self):
        return len(self.line_starts()) - 1

    def line_of(self, off):
        st = self.line_starts()
        lo = 0
        hi = len(st) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if st[mid] <= off:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def to_index(self, off):
        st = self.line_starts()
        if off >= len(self.s):
            return str(len(st)) + ".0"
        ln = self.line_of(off)
        return str(ln) + "." + str(off - st[ln - 1])

    def line_start(self, ln):
        st = self.line_starts()
        if ln < 1:
            return 0
        if ln > len(st) - 1:
            return len(self.s)
        return st[ln - 1]

    def line_end(self, ln):
        # offset of the newline ending line ln
        st = self.line_starts()
        if ln > len(st) - 1:
            return len(self.s)
        return st[ln] - 1

    # ── index parsing ──
    def offset(self, idx):
        if isinstance(idx, int) and not isinstance(idx, bool):
            # Tk accepts a plain number as a line.char without char? no
            raise TclError("bad text index \"" + str(idx) + "\"")
        if isinstance(idx, float):
            s = repr(idx)
        else:
            s = tcl_str(idx)
        base, rest = self._base(s)
        off = base
        while rest:
            rest = rest.lstrip()
            if not rest:
                break
            off, rest = self._modifier(off, rest, s)
        return off

    def _base(self, s):
        m = _LINECHAR.match(s)
        if m is not None:
            ln = int(m.group(1))
            ch = m.group(2)
            rest = s[m.end():]
            if ln < 1:
                ln = 1
                if ch != "end":
                    ch = "0"
            nl = self.nlines()
            if ln > nl:
                return len(self.s), rest
            start = self.line_start(ln)
            lend = self.line_end(ln)
            if ch == "end":
                return lend, rest
            c = int(ch)
            return min(start + c, lend), rest
        if s.startswith("@"):
            m = _ATXY.match(s)
            if m is None:
                raise TclError("bad text index \"" + s + "\"")
            return self.offset_at(int(m.group(1)), int(m.group(2))), s[m.end():]
        if s.startswith("end"):
            return len(self.s), s[3:]
        # marks, tag.first/tag.last, embedded names: the longest leading word
        m = _WORD.match(s)
        if m is None:
            raise TclError("bad text index \"" + s + "\"")
        word = m.group(0)
        rest = s[m.end():]
        if word in self.marks:
            return self.marks[word][0], rest
        if word.endswith(".first") or word.endswith(".last"):
            tname = word[:word.rfind(".")]
            t = self.tags.get(tname)
            if t is not None:
                if not t.ranges:
                    raise TclError("text doesn't contain any characters tagged with \"" + tname + "\"")
                return (t.ranges[0][0] if word.endswith(".first") else t.ranges[-1][1]), rest
            raise TclError("bad text index \"" + s + "\"")
        for off in self.embedded:
            if self.embedded[off].name == word:
                return off, rest
        raise TclError("bad text index \"" + s + "\"")

    def _modifier(self, off, rest, whole):
        c = rest[0]
        if c == "+" or c == "-":
            m = _COUNT.match(rest)
            if m is None:
                raise TclError("bad text index \"" + whole + "\"")
            n = int(m.group(2))
            if c == "-":
                n = -n
            unit = m.group(3) or "chars"
            after = rest[m.end():]
            try:
                unit = match_prefix(unit, ["chars", "displaychars", "displayindices", "displaylines", "indices", "lines"], "count unit")
            except TclError:
                raise TclError("bad text index \"" + whole + "\"")
            return self._count_move(off, n, unit), after
        m = _WORDMOD.match(rest)
        if m is None:
            raise TclError("bad text index \"" + whole + "\"")
        word = m.group(1)
        after = rest[m.end():]
        disp = False
        if word in ("display", "any"):
            disp = word == "display"
            m2 = _WORDMOD.match(after.lstrip())
            if m2 is None:
                raise TclError("bad text index \"" + whole + "\"")
            word = m2.group(1)
            after = after.lstrip()[m2.end():]
        try:
            word = match_prefix(word, ["lineend", "linestart", "wordend", "wordstart"], "modifier")
        except TclError:
            raise TclError("bad text index \"" + whole + "\"")
        if word == "linestart":
            if disp:
                d = self.dline_of(off)
                return (d.start if d is not None else self.line_start(self.line_of(off))), after
            return self.line_start(self.line_of(off)) if off < len(self.s) else self.line_start(self.nlines() + 1), after
        if word == "lineend":
            if disp:
                d = self.dline_of(off)
                if d is not None:
                    return max(d.start, d.end - 1), after
            if off >= len(self.s):
                return len(self.s), after
            return self.line_end(self.line_of(off)), after
        if word == "wordstart":
            return self._wordstart(off), after
        return self._wordend(off), after

    def _isword(self, ch):
        return ch.isalnum() or ch == "_"

    def _wordstart(self, off):
        s = self.s
        if off >= len(s):
            off = len(s) - 1
        if off < 0:
            return 0
        if not self._isword(s[off]):
            return off
        while off > 0 and self._isword(s[off - 1]):
            off -= 1
        return off

    def _wordend(self, off):
        s = self.s
        n = len(s) - 1
        if off >= n:
            return n
        if not self._isword(s[off]):
            return off + 1
        while off < n and self._isword(s[off]):
            off += 1
        return off

    def _count_move(self, off, n, unit):
        if unit in ("chars", "indices", "displaychars", "displayindices"):
            if unit == "chars" or unit == "displaychars":
                # chars skips embedded objects (they are indices, not chars)
                s = self.s
                if n >= 0:
                    k = 0
                    while k < n and off < len(s):
                        if s[off] != OBJ:
                            k += 1
                        off += 1
                    while off < len(s) and s[off] == OBJ and k > 0 and False:
                        off += 1
                    return min(off, len(s))
                k = 0
                while k < -n and off > 0:
                    off -= 1
                    if s[off] != OBJ:
                        k += 1
                return off
            return max(0, min(len(self.s), off + n))
        if unit == "lines":
            ln = self.line_of(off) if off < len(self.s) else self.nlines() + 1
            col = off - self.line_start(ln) if off < len(self.s) else 0
            tl = ln + n
            if tl < 1:
                return min(col, self.line_end(1) - self.line_start(1))
            if tl > self.nlines():
                return len(self.s)
            return min(self.line_start(tl) + col, self.line_end(tl))
        # displaylines
        lay = self.get_layout()
        di = self.dline_index(off)
        if di is None:
            return off
        d = lay[di]
        col = off - d.start
        ti = max(0, min(len(lay) - 1, di + n))
        t = lay[ti]
        return min(t.start + col, max(t.start, t.end - 1))

    def index_str(self, idx):
        return self.to_index(self.offset(idx))

    # ── layout ──
    def text_area(self):
        bd = self.px("borderwidth")
        hl = self.px("highlightthickness")
        px = self.px("padx")
        py = self.px("pady")
        x0 = bd + hl + px
        y0 = bd + hl + py
        return x0, y0, max(1, self.width - 2 * x0), max(1, self.height - 2 * y0)

    def char_tags(self, off):
        out = []
        for t in self.tags.values():
            if t.covers(off):
                out.append(t)
        out.sort(key=lambda t: t.prio)
        return out

    def tag_attr(self, tags, name, default):
        v = default
        for t in tags:
            x = t.opts.get(name, "")
            if x != "" and x is not None:
                v = x
        return v

    def get_layout(self):
        if self.layout is not None and self.layout_w == self.width:
            return self.layout
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        x0, y0, aw, ah = self.text_area()
        wrap = self.opts["wrap"]
        s = self.s
        lay = []
        y = 0
        sp1 = self.px("spacing1")
        sp2 = self.px("spacing2")
        sp3 = self.px("spacing3")
        tabw = 8 * max(1, f.measure("0"))
        has_tags = any([t.ranges for t in self.tags.values() if t.name != "sel"])
        elide_tags = [t for t in self.tags.values() if t.opts.get("elide") not in ("", None, 0)]
        for ln in range(1, self.nlines() + 1):
            a = self.line_start(ln)
            b = self.line_end(ln)
            # the characters of this logical line, with their x positions
            xs = []
            x = 0
            fonts = []
            for off in range(a, b + 1):
                xs.append(x)
                ch = s[off]
                if elide_tags and any([t.covers(off) for t in elide_tags]):
                    continue
                if ch == "\n":
                    continue
                if ch == "\t":
                    x = (x // tabw + 1) * tabw
                    continue
                if ch == OBJ:
                    e = self.embedded.get(off)
                    x += (e.w + 2 * pixels(e.opts.get("padx", 0))) if e is not None else 0
                    continue
                cf = f
                if has_tags:
                    tg = self.char_tags(off)
                    fo = self.tag_attr(tg, "font", "")
                    if fo:
                        cf = self.app.font_of(fo)
                x += cf.measure(ch)
            xs.append(x)
            # break into display lines
            first = True
            k = 0
            n = b - a + 1
            while True:
                lm = 0
                if wrap == "none" or x - xs[k] <= aw:
                    end = n
                else:
                    end = k + 1
                    while end < n and xs[end + 1] - xs[k] <= aw:
                        end += 1
                    if wrap == "word":
                        j = end
                        while j > k + 1 and s[a + j - 1] not in " \t":
                            j -= 1
                        if j > k + 1:
                            end = j
                hh = ls + (sp1 if first else sp2) + sp3
                d = DLine(a + k, a + end, y, hh, asc + (sp1 if first else sp2))
                d.xs = [xx - xs[k] for xx in xs[k:end + 1]]
                lay.append(d)
                y += hh
                first = False
                k = end
                if k >= n:
                    break
        self.layout = lay
        self.layout_w = self.width
        self.total_h = y
        return lay

    def dline_index(self, off):
        lay = self.get_layout()
        if not lay:
            return None
        if off >= len(self.s):
            return len(lay) - 1
        lo = 0
        hi = len(lay) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if lay[mid].start <= off:
                lo = mid
            else:
                hi = mid - 1
        return lo

    def dline_of(self, off):
        i = self.dline_index(off)
        return self.get_layout()[i] if i is not None else None

    def top_y(self):
        lay = self.get_layout()
        if not lay:
            return 0
        i = self.dline_index(self.top_offset)
        return lay[i].y if i is not None else 0

    def offset_at(self, x, y):
        lay = self.get_layout()
        x0, y0, aw, ah = self.text_area()
        ty = self.top_y()
        yy = y - y0 + ty
        d = None
        for dl in lay:
            if dl.y <= yy < dl.y + dl.h:
                d = dl
                break
        if d is None:
            if not lay:
                return 0
            d = lay[0] if yy < 0 else lay[-1]
        xx = x - x0 + self.xoff
        n = d.end - d.start
        for k in range(n):
            if xx < d.xs[k + 1]:
                return d.start + k
        return max(d.start, d.end - 1) if d.end > d.start else d.start

    def char_box(self, off):
        lay = self.get_layout()
        i = self.dline_index(off)
        if i is None:
            return None
        d = lay[i]
        x0, y0, aw, ah = self.text_area()
        k = off - d.start
        if k < 0 or k > len(d.xs) - 1:
            return None
        if k >= len(d.xs) - 1:
            w = 0
            x = d.xs[-1]
        else:
            x = d.xs[k]
            w = d.xs[k + 1] - d.xs[k]
            if self.s[off] == "\n":
                w = max(0, aw - x)
        return (x0 + x - self.xoff, y0 + d.y - self.top_y(), w, d.h)

    def visible_dlines(self):
        lay = self.get_layout()
        x0, y0, aw, ah = self.text_area()
        ti = self.dline_index(self.top_offset) or 0
        out = []
        top = lay[ti].y if lay else 0
        for i in range(ti, len(lay)):
            d = lay[i]
            if d.y - top >= ah:
                break
            out.append(i)
        return out

    def yview_fractions(self):
        lay = self.get_layout()
        if not lay:
            return 0.0, 1.0
        total = self.total_h
        x0, y0, aw, ah = self.text_area()
        top = self.top_y()
        if total <= 0:
            return 0.0, 1.0
        f = top / float(total)
        l = min(1.0, (top + ah) / float(total))
        return f, l

    def xview_fractions(self):
        if self.opts["wrap"] != "none":
            return 0.0, 1.0
        lay = self.get_layout()
        widest = max([d.xs[-1] for d in lay]) if lay else 0
        x0, y0, aw, ah = self.text_area()
        if widest <= aw:
            return 0.0, 1.0
        return self.xoff / float(widest), min(1.0, (self.xoff + aw) / float(widest))

    def update_scroll(self):
        if self.destroyed:
            return
        f, l = self.yview_fractions()
        self.scroll_command("yscrollcommand", f, l)
        f, l = self.xview_fractions()
        self.scroll_command("xscrollcommand", f, l)

    def set_top_dline(self, i):
        lay = self.get_layout()
        if not lay:
            self.top_offset = 0
            return
        i = max(0, min(len(lay) - 1, i))
        self.top_offset = lay[i].start
        self.damage()
        self.app.after_idle_once(self, "_text_scroll", self.update_scroll)

    def see(self, off):
        lay = self.get_layout()
        if not lay:
            return
        vis = self.visible_dlines()
        di = self.dline_index(off)
        if di is None:
            return
        x0, y0, aw, ah = self.text_area()
        if vis and vis[0] <= di <= vis[-1]:
            d = lay[di]
            if d.y + d.h - lay[vis[0]].y <= ah or di == vis[0]:
                pass
            else:
                self.set_top_dline(vis[0] + 1)
        else:
            nvis = max(1, len(vis))
            if vis and di < vis[0]:
                if vis[0] - di <= nvis // 3:
                    self.set_top_dline(di)
                else:
                    self.set_top_dline(di - nvis // 2)
            else:
                last = vis[-1] if vis else 0
                if di - last <= nvis // 3:
                    self.set_top_dline(di - nvis + 1)
                else:
                    self.set_top_dline(di - nvis // 2)
        if self.opts["wrap"] == "none":
            b = self.char_box(off)
            if b is not None:
                cx = b[0] - x0 + self.xoff
                if cx < self.xoff:
                    self.xoff = max(0, cx - aw // 3)
                elif cx > self.xoff + aw - 2:
                    self.xoff = cx - aw + aw // 3
                self.damage()

    # ── editing ──
    def editable(self):
        return self.opts["state"] == "normal"

    def push_undo(self, atom):
        if not self.opts["undo"]:
            return
        self.undo_stack.append(atom)
        self.redo_stack = []
        self.trim_undo()

    def push_separator(self, stack=None):
        st = self.undo_stack if stack is None else stack
        if st and st[-1] != "sep":
            st.append("sep")

    def trim_undo(self):
        mx = self.opts.get("maxundo", 0)
        if mx <= 0:
            return
        groups = 0
        for a in self.undo_stack:
            if a == "sep":
                groups += 1
        while groups > mx and self.undo_stack:
            a = self.undo_stack.pop(0)
            if a == "sep":
                groups -= 1

    def update_dirty(self):
        if self.dirty_mode == "fixed":
            return
        if self.dirty < 0 and self.dirty_mode == "normal":
            self.dirty_mode = "fixed"
            return
        old = self.dirty
        if self.dirty_mode == "undo":
            self.dirty -= 1
        else:
            self.dirty += 1
        if self.dirty == 0 or old == 0:
            self.app.event_generate([self.path, "<<Modified>>"])

    def raw_insert(self, off, s, tags=None, record=True):
        n = len(s)
        if n == 0:
            return
        if self.opts["undo"] and record:
            if self.opts["autoseparators"] and self.last_edit != "insert":
                self.push_separator()
            self.last_edit = "insert"
        before = self.char_tags(off - 1) if off > 0 else []
        after = self.char_tags(off)
        self.s = self.s[:off] + s + self.s[off:]
        self.starts = None
        # marks
        for name in self.marks:
            m = self.marks[name]
            if m[0] > off or (m[0] == off and m[1] == "right"):
                m[0] += n
        # tags: ranges after shift; ranges strictly around the point extend
        for t in self.tags.values():
            nr = []
            for r in t.ranges:
                a, b = r
                if a >= off:
                    nr.append([a + n, b + n])
                elif b > off:
                    nr.append([a, b + n])
                else:
                    nr.append([a, b])
            t.ranges = nr
        if tags is not None:
            for t in self.tags.values():
                t.remove(off, off + n)
            for tn in tags:
                t = self.tag(tn)
                t.add(off, off + n)
        # embedded objects shift
        if self.embedded:
            ne = {}
            for k in self.embedded:
                ne[k + n if k >= off else k] = self.embedded[k]
            self.embedded = ne
        if record:
            self.push_undo(("insert", off, s))
            self.update_dirty()
        self.invalidate()

    def raw_delete(self, a, b, record=True):
        if b <= a:
            return
        removed = self.s[a:b]
        if self.opts["undo"] and record:
            if self.opts["autoseparators"] and self.last_edit != "delete":
                self.push_separator()
            self.last_edit = "delete"
        # remember the tags of the removed text for undo
        tagspans = []
        if record and self.opts["undo"]:
            for t in self.tags.values():
                for r in t.ranges:
                    x = max(a, r[0])
                    y = min(b, r[1])
                    if x < y:
                        tagspans.append((t.name, x - a, y - a))
        self.s = self.s[:a] + self.s[b:]
        self.starts = None
        n = b - a
        for name in self.marks:
            m = self.marks[name]
            if m[0] >= b:
                m[0] -= n
            elif m[0] > a:
                m[0] = a
        for t in self.tags.values():
            nr = []
            for r in t.ranges:
                x, y = r
                if y <= a:
                    nr.append([x, y])
                    continue
                if x >= b:
                    nr.append([x - n, y - n])
                    continue
                nx = x if x < a else a
                ny = a if y <= b else y - n
                if ny > nx:
                    nr.append([nx, ny])
            merged = []
            for r in nr:
                if merged and merged[-1][1] >= r[0]:
                    merged[-1][1] = max(merged[-1][1], r[1])
                else:
                    merged.append(r)
            t.ranges = merged
        if self.embedded:
            ne = {}
            for k in self.embedded:
                e = self.embedded[k]
                if a <= k < b:
                    if e.kind == "window" and e.win is not None and not e.win.destroyed:
                        from _tkinter import geom as G
                        G.unmanage(self.app, e.win)
                    continue
                ne[k - n if k >= b else k] = e
            self.embedded = ne
        if record:
            self.push_undo(("delete", a, removed, tagspans))
            self.update_dirty()
        self.invalidate()

    def tag(self, name):
        t = self.tags.get(name)
        if t is None:
            t = Tag(name, self.tag_n)
            self.tag_n += 1
            self.tags[name] = t
        return t

    def clamp_insert(self, off):
        if off >= len(self.s):
            return len(self.s) - 1
        return off

    def insert_cmd(self, off, pieces):
        # pieces: [chars, tagList, chars, tagList ...]
        off = self.clamp_insert(off)
        start = off
        i = 0
        while i < len(pieces):
            chars = tcl_str(pieces[i])
            tags = None
            if i + 1 < len(pieces):
                tl = pieces[i + 1]
                tags = split_list(tl) if not isinstance(tl, (tuple, list)) else [tcl_str(x) for x in tl]
            self.raw_insert(off, chars, tags)
            off += len(chars)
            i += 2
        if self.tags["sel"].ranges and off > start:
            self.sel_changed()
        return ""

    def delete_range(self, a, b):
        n = len(self.s)
        if b > n:
            b = n
        if a >= b:
            return
        if b == n:
            # the final newline survives; a range from a line start takes the
            # newline before it instead
            b -= 1
            if a > 0 and (self.s[a - 1] == "\n") and a == self.line_start(self.line_of(a)):
                a -= 1
        if a >= b:
            return
        had_sel = any([r[0] < b and r[1] > a for r in self.tags["sel"].ranges])
        self.raw_delete(a, b)
        if had_sel:
            self.sel_changed()

    def sel_changed(self):
        if self.tags["sel"].ranges and self.opts["exportselection"]:
            self.app.own_selection(self)
        self.app.event_generate([self.path, "<<Selection>>"])

    def selection_text(self):
        t = self.tags["sel"]
        if not t.ranges or not self.opts["exportselection"]:
            return None
        return "".join([self.s[a:b] for a, b in t.ranges]).replace(OBJ, "")

    def selection_lost(self):
        t = self.tags["sel"]
        if t.ranges:
            t.ranges = []
            self.damage()
            self.app.event_generate([self.path, "<<Selection>>"])

    # ── widget commands ──
    def w_index(self, args):
        if len(args) != 1:
            raise TclError("wrong # args: should be \"" + self.path + " index index\"")
        return self.index_str(args[0])

    def w_insert(self, args):
        if len(args) < 2:
            raise TclError("wrong # args: should be \"" + self.path + " insert index chars ?tagList chars tagList ...?\"")
        if not self.editable():
            return ""
        off = self.offset(args[0])
        return self.insert_cmd(off, list(args[1:]))

    def w_delete(self, args):
        if len(args) < 1:
            raise TclError("wrong # args: should be \"" + self.path + " delete index1 ?index2 ...?\"")
        if not self.editable():
            return ""
        ranges = []
        i = 0
        while i < len(args):
            a = self.offset(args[i])
            if i + 1 < len(args) and args[i + 1] is not None and tcl_str(args[i + 1]) != "":
                b = self.offset(args[i + 1])
                i += 2
            else:
                b = min(a + 1, len(self.s))
                i += 1
            if b > a:
                ranges.append((a, b))
        for a, b in sorted(ranges, reverse=True):
            self.delete_range(a, b)
        return ""

    def w_replace(self, args):
        if len(args) < 3:
            raise TclError("wrong # args: should be \"" + self.path + " replace index1 index2 chars ?tagList chars tagList ...?\"")
        if not self.editable():
            return ""
        a = self.offset(args[0])
        b = self.offset(args[1])
        if b < a:
            raise TclError("Index \"" + tcl_str(args[1]) + "\" before \"" + tcl_str(args[0]) + "\" in the text")
        auto = self.opts["autoseparators"]
        if self.opts["undo"] and auto:
            self.push_separator()
        self.opts["autoseparators"] = 0
        try:
            ins = self.marks["insert"][0]
            self.delete_range(a, b)
            self.insert_cmd(a, list(args[2:]))
            if a <= ins <= b:
                self.marks["insert"][0] = ins if ins <= len(self.s) - 1 else len(self.s) - 1
        finally:
            self.opts["autoseparators"] = auto
        if self.opts["undo"] and auto:
            self.push_separator()
        return ""

    def w_get(self, args):
        disp = False
        if args and tcl_str(args[0]) == "-displaychars":
            disp = True
            args = args[1:]
        if args and tcl_str(args[0]) == "--":
            args = args[1:]
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " get ?-displaychars? ?--? index1 ?index2 ...?\"")
        out = []
        i = 0
        while i < len(args):
            a = self.offset(args[i])
            if i + 1 < len(args) and args[i + 1] is not None:
                b = self.offset(args[i + 1])
                i += 2
            else:
                b = min(a + 1, len(self.s))
                i += 1
            seg = self.s[a:b] if b > a else ""
            seg = seg.replace(OBJ, "")
            if disp:
                el = [t for t in self.tags.values() if t.opts.get("elide") not in ("", None, 0)]
                if el:
                    seg = "".join([self.s[k] for k in range(a, b) if self.s[k] != OBJ and not any([t.covers(k) for t in el])])
            out.append(seg)
        if len(out) == 1:
            return out[0]
        return tuple(out)

    def w_compare(self, args):
        if len(args) != 3:
            raise TclError("wrong # args: should be \"" + self.path + " compare index1 op index2\"")
        a = self.offset(args[0])
        op = tcl_str(args[1])
        b = self.offset(args[2])
        if op == "<":
            r = a < b
        elif op == "<=":
            r = a <= b
        elif op == "==":
            r = a == b
        elif op == ">=":
            r = a >= b
        elif op == ">":
            r = a > b
        elif op == "!=":
            r = a != b
        else:
            raise TclError("bad comparison operator \"" + op + "\": must be <, <=, ==, >=, >, or !=")
        return 1 if r else 0

    def w_count(self, args):
        opts = []
        k = 0
        while k < len(args) and tcl_str(args[k]).startswith("-"):
            opts.append(match_prefix(tcl_str(args[k]), ["-chars", "-displaychars", "-displayindices", "-displaylines",
                                                        "-indices", "-lines", "-update", "-xpixels", "-ypixels"], "option"))
            k += 1
        if len(args) - k != 2:
            raise TclError("wrong # args: should be \"" + self.path + " count ?-option value ...? index1 index2\"")
        a = self.offset(args[k])
        b = self.offset(args[k + 1])
        sign = 1
        if b < a:
            a, b = b, a
            sign = -1
        res = []
        for o in [x for x in opts if x != "-update"] or ["-indices"]:
            if o == "-indices" or o == "-displayindices":
                v = b - a
            elif o == "-chars" or o == "-displaychars":
                v = len(self.s[a:b].replace(OBJ, ""))
            elif o == "-lines":
                v = (self.line_of(b) if b < len(self.s) else self.nlines() + 1) - self.line_of(a)
            elif o == "-displaylines":
                v = (self.dline_index(b) or 0) - (self.dline_index(a) or 0)
            elif o == "-xpixels":
                ba = self.char_box(a)
                bb = self.char_box(b)
                v = (bb[0] if bb else 0) - (ba[0] if ba else 0)
            else:
                da = self.dline_of(a)
                db = self.dline_of(b)
                v = (db.y if db else 0) - (da.y if da else 0)
            res.append(sign * v)
        if len(res) == 1:
            return res[0]
        return tuple(res)

    def w_see(self, args):
        self.see(self.offset(args[0]))
        return ""

    def w_bbox(self, args):
        off = self.offset(args[0])
        b = self.char_box(off)
        if b is None:
            return ""
        x0, y0, aw, ah = self.text_area()
        vis = self.visible_dlines()
        di = self.dline_index(off)
        if not vis or di is None or di < vis[0] or di > vis[-1]:
            return ""
        if b[0] + b[2] < x0 or b[0] > x0 + aw:
            return ""
        return b

    def w_dlineinfo(self, args):
        off = self.offset(args[0])
        di = self.dline_index(off)
        vis = self.visible_dlines()
        if di is None or not vis or di < vis[0] or di > vis[-1]:
            return ""
        d = self.get_layout()[di]
        x0, y0, aw, ah = self.text_area()
        return (x0 - self.xoff, y0 + d.y - self.top_y(), d.xs[-1], d.h, d.asc)

    def w_debug(self, args):
        if args:
            return ""
        return 0

    def w_peer(self, args):
        if args and tcl_str(args[0]) == "names":
            return ()
        raise TclError("text peers are not supported by Nython's Tk")

    def w_sync(self, args):
        return ""

    def w_pendingsync(self, args):
        return 0

    def w_scan(self, args):
        sub = match_prefix(tcl_str(args[0]), ["dragto", "mark"], "scan option")
        x = pixels(args[1])
        y = pixels(args[2])
        if sub == "mark":
            self.scan_mark = (x, y, self.xoff, self.dline_index(self.top_offset) or 0)
            return ""
        mx, my, xo, ti = self.scan_mark
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        self.set_top_dline(ti - (y - my) * 10 // max(1, ls))
        if self.opts["wrap"] == "none":
            self.xoff = max(0, xo - (x - mx) * 10)
            self.damage()
        return ""

    def w_yview(self, args):
        if not args:
            return self.yview_fractions()
        a0 = tcl_str(args[0])
        lay = self.get_layout()
        if a0 == "-pickplace":
            self.see(self.offset(args[1]))
            return ""
        if a0 == "moveto":
            f = get_double(args[1])
            target = f * self.total_h
            i = 0
            for k in range(len(lay)):
                if lay[k].y <= target:
                    i = k
            if lay and target - lay[i].y > lay[i].h / 2.0 and i + 1 < len(lay):
                i += 1
            self.set_top_dline(i)
            return ""
        if a0 == "scroll":
            n = get_int(args[1])
            what = match_prefix(tcl_str(args[2]), ["pages", "pixels", "units"], "argument")
            ti = self.dline_index(self.top_offset) or 0
            if what == "units":
                self.set_top_dline(ti + n)
            elif what == "pages":
                nvis = max(1, len(self.visible_dlines()))
                self.set_top_dline(ti + n * max(1, nvis - 2))
            else:
                f = self.font()
                asc, desc, ls, fixed = f.metrics()
                self.set_top_dline(ti + int(n / max(1, ls)))
            return ""
        # yview index: that line at the top
        try:
            ln = get_int(a0)
            off = self.line_start(ln)
        except TclError:
            off = self.offset(args[0])
        di = self.dline_index(off)
        self.set_top_dline(di or 0)
        return ""

    def w_xview(self, args):
        if not args:
            return self.xview_fractions()
        lay = self.get_layout()
        widest = max([d.xs[-1] for d in lay]) if lay else 0
        x0, y0, aw, ah = self.text_area()
        a0 = tcl_str(args[0])
        f = self.font()
        cw = max(1, f.measure("0"))
        if a0 == "moveto":
            self.xoff = int(get_double(args[1]) * widest)
        elif a0 == "scroll":
            n = get_int(args[1])
            what = match_prefix(tcl_str(args[2]), ["pages", "pixels", "units"], "argument")
            if what == "units":
                self.xoff += n * cw
            elif what == "pages":
                self.xoff += n * max(cw, aw - 2 * cw)
            else:
                self.xoff += n
        else:
            self.xoff = get_int(args[0]) * cw
        self.xoff = max(0, min(self.xoff, max(0, widest - aw)))
        self.damage()
        self.app.after_idle_once(self, "_text_scroll", self.update_scroll)
        return ""

    # marks
    def w_mark(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " mark option ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["gravity", "names", "next", "previous", "set", "unset"], "mark option")
        if sub == "names":
            return tuple(self.mark_order)
        if sub == "set":
            if len(args) != 3:
                raise TclError("wrong # args: should be \"" + self.path + " mark set markName index\"")
            name = tcl_str(args[1])
            off = self.offset(args[2])
            self.set_mark(name, off)
            return ""
        if sub == "unset":
            for a in args[1:]:
                name = tcl_str(a)
                if name in ("insert", "current"):
                    continue
                if name in self.marks:
                    del self.marks[name]
                    self.mark_order.remove(name)
            return ""
        if sub == "gravity":
            name = tcl_str(args[1])
            if name not in self.marks:
                raise TclError("there is no mark named \"" + name + "\"")
            if len(args) == 2:
                return self.marks[name][1]
            g = match_prefix(tcl_str(args[2]), ["left", "right"], "mark gravity")
            self.marks[name][1] = g
            return ""
        if sub == "next" or sub == "previous":
            idx = tcl_str(args[1])
            if idx in self.marks:
                off = self.marks[idx][0]
                # marks after this one at the same position count as next
                same = [m for m in self.mark_order if self.marks[m][0] == off]
                pos = same.index(idx)
                if sub == "next":
                    if pos + 1 < len(same):
                        return same[pos + 1]
                    cands = [m for m in self.mark_order if self.marks[m][0] > off]
                    if not cands:
                        return ""
                    best = min([self.marks[m][0] for m in cands])
                    return [m for m in self.mark_order if self.marks[m][0] == best][0]
                if pos > 0:
                    return same[pos - 1]
                cands = [m for m in self.mark_order if self.marks[m][0] < off]
                if not cands:
                    return ""
                best = max([self.marks[m][0] for m in cands])
                return [m for m in self.mark_order if self.marks[m][0] == best][-1]
            off = self.offset(args[1])
            if sub == "next":
                cands = [m for m in self.mark_order if self.marks[m][0] >= off]
                if not cands:
                    return ""
                best = min([self.marks[m][0] for m in cands])
                return [m for m in self.mark_order if self.marks[m][0] == best][0]
            cands = [m for m in self.mark_order if self.marks[m][0] < off]
            if not cands:
                return ""
            best = max([self.marks[m][0] for m in cands])
            return [m for m in self.mark_order if self.marks[m][0] == best][-1]
        return ""

    def set_mark(self, name, off):
        if off >= len(self.s) and name == "insert":
            off = len(self.s) - 1
        if name not in self.marks:
            self.marks[name] = [off, "right"]
            self.mark_order.append(name)
        else:
            if name == "insert" and self.marks[name][0] != off:
                self.last_edit = "other"
            self.marks[name][0] = off
        if name == "insert":
            self.damage()

    # tags
    def w_tag(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " tag option ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["add", "bind", "cget", "configure", "delete", "lower", "names",
                                              "nextrange", "prevrange", "raise", "ranges", "remove"], "tag option")
        if sub == "names":
            if len(args) > 1 and args[1] is not None:
                off = self.offset(args[1])
                return tuple([t.name for t in self.char_tags(off)])
            return tuple([t.name for t in sorted(self.tags.values(), key=lambda t: t.prio)])
        if len(args) < 2:
            raise TclError("wrong # args: should be \"" + self.path + " tag " + sub + " tagName ...\"")
        name = tcl_str(args[1])
        if sub == "add" or sub == "remove":
            t = self.tag(name) if sub == "add" else self.tags.get(name)
            if t is None:
                return ""
            rest = list(args[2:])
            if not rest:
                raise TclError("wrong # args: should be \"" + self.path + " tag " + sub + " tagName index1 ?index2 index1 index2 ...?\"")
            changed = False
            i = 0
            while i < len(rest):
                a = self.offset(rest[i])
                if i + 1 < len(rest) and rest[i + 1] is not None:
                    b = self.offset(rest[i + 1])
                    i += 2
                else:
                    b = min(a + 1, len(self.s))
                    i += 1
                if b <= a:
                    continue
                if sub == "add":
                    changed = t.add(a, b) or changed
                else:
                    changed = t.remove(a, b) or changed
            if changed:
                self.invalidate()
                if name == "sel":
                    self.sel_changed()
            return ""
        if sub == "delete":
            for a in args[1:]:
                n = tcl_str(a)
                if n in self.tags:
                    if n == "sel":
                        self.tags["sel"].ranges = []
                        continue
                    del self.tags[n]
                    self.tag_bindings.delete_tag(n)
            self.invalidate()
            return ""
        if sub == "ranges":
            t = self.tags.get(name)
            if t is None:
                return ()
            out = []
            for a, b in t.ranges:
                out.append(self.to_index(a))
                out.append(self.to_index(b))
            return tuple(out)
        if sub == "nextrange":
            t = self.tags.get(name)
            if t is None:
                return ()
            a = self.offset(args[2])
            b = self.offset(args[3]) if len(args) > 3 and args[3] is not None else len(self.s)
            for r in t.ranges:
                if r[0] >= a and r[0] < b:
                    return (self.to_index(r[0]), self.to_index(r[1]))
                if r[0] < a < r[1] and False:
                    pass
            return ()
        if sub == "prevrange":
            t = self.tags.get(name)
            if t is None:
                return ()
            a = self.offset(args[2])
            b = self.offset(args[3]) if len(args) > 3 and args[3] is not None else 0
            for r in reversed(t.ranges):
                if r[0] < a and r[0] >= b:
                    return (self.to_index(r[0]), self.to_index(min(r[1], a) if False else r[1]))
            return ()
        if sub == "raise" or sub == "lower":
            t = self.tags.get(name)
            if t is None:
                raise TclError("tag \"" + name + "\" isn't defined in text widget " + self.path)
            order = sorted(self.tags.values(), key=lambda q: q.prio)
            order.remove(t)
            if len(args) > 2 and args[2] is not None:
                other = self.tags.get(tcl_str(args[2]))
                if other is None:
                    raise TclError("tag \"" + tcl_str(args[2]) + "\" isn't defined in text widget " + self.path)
                k = order.index(other)
                order.insert(k + 1 if sub == "raise" else k, t)
            elif sub == "raise":
                order.append(t)
            else:
                order.insert(0, t)
            for i in range(len(order)):
                order[i].prio = i
            self.invalidate()
            return ""
        if sub == "cget":
            t = self.tags.get(name)
            if t is None:
                raise TclError("tag \"" + name + "\" isn't defined in text widget " + self.path)
            o = tcl_str(args[2])
            k = self._tag_opt(o)
            return t.opts[k]
        if sub == "configure":
            t = self.tag(name)
            rest = list(args[2:])
            if not rest:
                return tuple([("-" + k, "", "", "", t.opts[k]) for k in TAG_OPTS])
            if len(rest) == 1:
                k = self._tag_opt(tcl_str(rest[0]))
                return ("-" + k, "", "", "", t.opts[k])
            if len(rest) % 2:
                raise TclError("value for \"" + tcl_str(rest[-1]) + "\" missing")
            for i in range(0, len(rest), 2):
                k = self._tag_opt(tcl_str(rest[i]))
                v = rest[i + 1]
                kind = TAG_KINDS.get(k, "string")
                if kind == "boolean_or_empty":
                    v = "" if tcl_str(v) == "" else (1 if get_boolean(v) else 0)
                elif kind == "font_or_empty":
                    v = tcl_str(v) if not isinstance(v, (tuple, list)) else join_list(v)
                    if v != "":
                        self.app.font_of(v)
                else:
                    v = _norm(self.app, kind, v, k)
                t.opts[k] = v
                if name == "sel":
                    if k == "background":
                        self.opts["selectbackground"] = v if v != "" else self.opts["selectbackground"]
                    elif k == "foreground":
                        self.opts["selectforeground"] = v
            self.invalidate()
            return ""
        if sub == "bind":
            if len(args) == 2:
                return tuple(self.tag_bindings.sequences(name))
            seq = tcl_str(args[2])
            if len(args) == 3:
                return self.tag_bindings.get(name, seq)
            ps = B.parse_sequence(seq)
            for p in ps.pats:
                if p.type not in (B.KeyPress, B.KeyRelease, B.ButtonPress, B.ButtonRelease, B.MotionNotify,
                                  B.EnterNotify, B.LeaveNotify, B.VirtualEvent, B.MouseWheelEvent):
                    raise TclError("requested illegal events; only key, button, motion, enter, leave, and virtual events may be used")
            self.tag_bindings.set(name, seq, tcl_str(args[3]))
            return ""
        return ""

    def _tag_opt(self, o):
        if not o.startswith("-"):
            raise TclError("unknown option \"" + o + "\"")
        k = o[1:]
        if k in ALIASES_TAG:
            return ALIASES_TAG[k]
        if k in TAG_OPTS:
            return k
        found = [x for x in TAG_OPTS if x.startswith(k)]
        if len(found) == 1:
            return found[0]
        raise TclError("unknown option \"" + o + "\"")

    # edit
    def w_edit(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.path + " edit option ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["canredo", "canundo", "modified", "redo", "reset", "separator", "undo"], "edit option")
        if sub == "modified":
            if len(args) == 1 or args[1] is None:
                return 1 if self.dirty != 0 or self.dirty_mode == "fixed" else 0
            flag = get_boolean(args[1])
            old = 1 if (self.dirty != 0 or self.dirty_mode == "fixed") else 0
            if flag:
                self.dirty_mode = "fixed"
                self.dirty = 1
            else:
                self.dirty = 0
                self.dirty_mode = "normal"
            if (1 if flag else 0) != old:
                self.app.event_generate([self.path, "<<Modified>>"])
            return ""
        if sub == "separator":
            if self.opts["undo"]:
                self.push_separator()
            return ""
        if sub == "reset":
            self.undo_stack = []
            self.redo_stack = []
            return ""
        if sub == "canundo":
            return 1 if (self.opts["undo"] and any([a != "sep" for a in self.undo_stack])) else 0
        if sub == "canredo":
            return 1 if (self.opts["undo"] and any([a != "sep" for a in self.redo_stack])) else 0
        if sub == "undo":
            if not self.opts["undo"]:
                return ""
            if not self.do_undo(self.undo_stack, self.redo_stack, "undo"):
                raise TclError("nothing to undo")
            return ""
        if not self.opts["undo"]:
            return ""
        if not self.do_undo(self.redo_stack, self.undo_stack, "redo"):
            raise TclError("nothing to redo")
        return ""

    def do_undo(self, src, dst, mode):
        while src and src[-1] == "sep":
            src.pop()
        if not src:
            return False
        group = []
        while src and src[-1] != "sep":
            group.append(src.pop())
        self.dirty_mode = "undo" if mode == "undo" else "redo"
        self.push_separator(dst)
        saved_redo = self.redo_stack
        for atom in group:
            if atom[0] == "insert":
                off, s = atom[1], atom[2]
                self.raw_delete(off, off + len(s), False)
                self.update_dirty()
                dst.append(("delete", off, s, []))
                self.marks["insert"][0] = off
            else:
                off, s, spans = atom[1], atom[2], atom[3]
                self.raw_insert(off, s, None, False)
                for tn, a, b in spans:
                    self.tag(tn).add(off + a, off + b)
                self.update_dirty()
                dst.append(("insert", off, s))
                self.marks["insert"][0] = off + len(s)
        self.push_separator(dst)
        self.dirty_mode = "normal"
        self.last_edit = "other"
        self.see(self.marks["insert"][0])
        self.app.event_generate([self.path, "<<UndoStack>>"])
        return True

    # search
    def w_search(self, args):
        sw = {"forwards": True, "exact": True, "regexp": False, "nocase": False, "all": False, "overlap": False,
              "nolinestop": False, "strictlimits": False, "elide": False, "count": None}
        k = 0
        while k < len(args):
            a = tcl_str(args[k])
            if not a.startswith("-") or a == "-":
                break
            if a == "--":
                k += 1
                break
            name = match_prefix(a, ["-all", "-backwards", "-count", "-elide", "-exact", "-forwards", "-hidden",
                                    "-nocase", "-nolinestop", "-overlap", "-regexp", "-strictlimits"], "switch")
            if name == "-count":
                sw["count"] = tcl_str(args[k + 1])
                k += 2
                continue
            if name == "-backwards":
                sw["forwards"] = False
            elif name == "-forwards":
                sw["forwards"] = True
            elif name == "-regexp":
                sw["regexp"] = True
            elif name == "-exact":
                sw["regexp"] = False
            else:
                sw[name[1:]] = True
            k += 1
        rest = args[k:]
        if len(rest) < 2 or len(rest) > 3:
            raise TclError("wrong # args: should be \"" + self.path + " search ?switches? pattern index ?stopIndex?\"")
        pat = tcl_str(rest[0])
        start = self.offset(rest[1])
        stop = self.offset(rest[2]) if len(rest) == 3 and rest[2] is not None and tcl_str(rest[2]) != "" else None
        hay = self.s[:-1] if len(self.s) > 0 else ""
        if sw["regexp"]:
            flags = re.MULTILINE
            if sw["nocase"]:
                flags |= re.IGNORECASE
            if sw["nolinestop"]:
                flags |= re.DOTALL
            try:
                rx = re.compile(_tcl_re(pat), flags)
            except re.error as e:
                raise TclError("couldn't compile regular expression pattern: " + str(e))
            matches = [(m.start(), m.end()) for m in rx.finditer(hay) if m.end() >= m.start()]
            if sw["overlap"] or sw["all"]:
                matches = []
                pos = 0
                while pos <= len(hay):
                    m = rx.search(hay, pos)
                    if m is None:
                        break
                    matches.append((m.start(), m.end()))
                    pos = m.start() + 1 if (sw["overlap"] or m.end() == m.start()) else m.end()
        else:
            if pat == "":
                raise TclError("search pattern can't be empty") if False else None
            h2 = hay.lower() if sw["nocase"] else hay
            p2 = pat.lower() if sw["nocase"] else pat
            matches = []
            if p2 != "":
                pos = h2.find(p2)
                while pos >= 0:
                    matches.append((pos, pos + len(p2)))
                    pos = h2.find(p2, pos + (1 if sw["overlap"] else len(p2)))
        if not sw["elide"]:
            el = [t for t in self.tags.values() if t.opts.get("elide") not in ("", None, 0)]
            if el:
                matches = [m for m in matches if not any([t.covers(m[0]) for t in el])]
        if sw["forwards"]:
            if stop is None:
                order = [m for m in matches if m[0] >= start] + [m for m in matches if m[0] < start]
            else:
                if stop >= start:
                    order = [m for m in matches if start <= m[0] < stop and (not sw["strictlimits"] or m[1] <= stop)]
                else:
                    order = [m for m in matches if m[0] >= start] + [m for m in matches if m[0] < stop]
        else:
            if stop is None:
                order = [m for m in reversed(matches) if m[0] < start] + [m for m in reversed(matches) if m[0] >= start]
            else:
                if stop <= start:
                    order = [m for m in reversed(matches) if stop <= m[0] < start]
                else:
                    order = [m for m in reversed(matches) if m[0] < start] + [m for m in reversed(matches) if m[0] >= stop]
        if sw["all"]:
            if not order:
                if sw["count"]:
                    self.app.interp.setvar(sw["count"], ())
                return ""
            if sw["count"]:
                self.app.interp.setvar(sw["count"], tuple([m[1] - m[0] for m in order]))
            return tuple([self.to_index(m[0]) for m in order])
        if not order:
            return ""
        m = order[0]
        if sw["count"]:
            self.app.interp.setvar(sw["count"], m[1] - m[0])
        return self.to_index(m[0])

    # dump
    def w_dump(self, args):
        what = set()
        cmd = None
        k = 0
        while k < len(args) and tcl_str(args[k]).startswith("-"):
            a = match_prefix(tcl_str(args[k]), ["-all", "-command", "-image", "-mark", "-tag", "-text", "-window"], "switch")
            if a == "-command":
                cmd = tcl_str(args[k + 1])
                k += 2
                continue
            what.add(a[1:])
            k += 1
        if not what or "all" in what:
            what = set(["text", "mark", "tag", "image", "window"])
        rest = args[k:]
        if not rest:
            raise TclError("Usage: " + self.path + " dump ?-all -image -text -mark -tag -window? ?-command script? index ?index2?")
        a = self.offset(rest[0])
        if len(rest) > 1 and rest[1] is not None:
            b = self.offset(rest[1])
        else:
            b = a + 1
        if b > len(self.s):
            b = len(self.s)
        out = []
        tags_sorted = sorted(self.tags.values(), key=lambda t: t.prio)
        pos = a
        # tags already on at the start are reported as tagon at a
        while pos < b or (pos == b and pos == a):
            if "tag" in what:
                for t in tags_sorted:
                    for r in t.ranges:
                        if r[1] == pos and pos > a:
                            out.append(("tagoff", t.name, self.to_index(pos)))
            if "mark" in what:
                for m in self.mark_order:
                    if self.marks[m][0] == pos:
                        out.append(("mark", m, self.to_index(pos)))
            if "tag" in what:
                for t in tags_sorted:
                    for r in t.ranges:
                        if (r[0] == pos or (pos == a and r[0] < a < r[1])) and r[1] > pos:
                            out.append(("tagon", t.name, self.to_index(pos)))
            if pos >= b:
                break
            # the next position where anything happens
            nxt = b
            for t in self.tags.values():
                for r in t.ranges:
                    if pos < r[0] < nxt:
                        nxt = r[0]
                    if pos < r[1] < nxt:
                        nxt = r[1]
            for m in self.marks.values():
                if pos < m[0] < nxt:
                    nxt = m[0]
            nl = self.s.find("\n", pos)
            if 0 <= nl and nl + 1 < nxt:
                nxt = nl + 1
            for off in self.embedded:
                if pos <= off < nxt:
                    if off == pos:
                        nxt = off + 1
                    else:
                        nxt = off
            seg = self.s[pos:nxt]
            if seg == OBJ and pos in self.embedded:
                e = self.embedded[pos]
                if e.kind in what:
                    out.append((e.kind, e.name, self.to_index(pos)))
            elif "text" in what and seg != "":
                out.append(("text", seg, self.to_index(pos)))
            pos = nxt
        if pos == len(self.s) and "mark" in what and b == len(self.s):
            pass
        if cmd is not None:
            for key, value, idx in out:
                self.app.interp.eval(cmd + " " + join_list([key, value, idx]))
            return ""
        flat = []
        for key, value, idx in out:
            flat.extend([key, value, idx])
        return tuple(flat)

    # embedded windows and images
    def w_window(self, args):
        sub = match_prefix(tcl_str(args[0]), ["cget", "configure", "create", "names"], "option")
        if sub == "names":
            return tuple([e.name for e in self.embedded.values() if e.kind == "window"])
        off = self.offset(args[1])
        if sub == "create":
            off = self.clamp_insert(off)
            e = Embedded("window", "")
            self._embed_config(e, args[2:])
            self.raw_insert(off, OBJ, None, True)
            self.embedded[off] = e
            self._embed_window(e)
            self.invalidate()
            return ""
        e = self.embedded.get(off)
        if e is None or e.kind != "window":
            raise TclError("no embedded window at index \"" + tcl_str(args[1]) + "\"")
        if sub == "cget":
            return e.opts.get(tcl_str(args[2])[1:], "")
        if len(args) == 2:
            return tuple([("-" + k, "", "", "", e.opts.get(k, "")) for k in ("align", "create", "padx", "pady", "stretch", "window")])
        self._embed_config(e, args[2:])
        self._embed_window(e)
        self.invalidate()
        return ""

    def _embed_config(self, e, args):
        for i in range(0, len(args) - 1, 2):
            k = tcl_str(args[i])[1:]
            e.opts[k] = tcl_str(args[i + 1])
            if k == "image":
                e.name = e.opts.get("name", "") or e.opts["image"]

    def _embed_window(self, e):
        name = e.opts.get("window", "")
        if not name and e.opts.get("create"):
            name = tcl_str(self.app.interp.eval(e.opts["create"]))
            e.opts["window"] = name
        if not name:
            return
        w = self.app.window(name)
        e.win = w
        e.name = name
        from _tkinter import geom as G
        if w.manager != "" and w.gmaster is not self:
            G.unmanage(self.app, w)
        w.manager = "text"
        w.gmaster = self
        e.w = w.reqw
        e.h = w.reqh

    def w_image(self, args):
        sub = match_prefix(tcl_str(args[0]), ["cget", "configure", "create", "names"], "option")
        if sub == "names":
            return tuple([e.name for e in self.embedded.values() if e.kind == "image"])
        off = self.offset(args[1])
        if sub == "create":
            off = self.clamp_insert(off)
            e = Embedded("image", "")
            self._embed_config(e, args[2:])
            img = e.opts.get("image", "")
            base = e.opts.get("name", "") or img
            name = base
            n = 1
            while any([x.name == name for x in self.embedded.values()]):
                name = base + "#" + str(n)
                n += 1
            e.name = name
            im = self.app.images.get(img)
            if im is not None:
                e.w = im.width()
                e.h = im.height()
            self.raw_insert(off, OBJ, None, True)
            self.embedded[off] = e
            self.invalidate()
            return name
        e = self.embedded.get(off)
        if e is None or e.kind != "image":
            raise TclError("no embedded image at index \"" + tcl_str(args[1]) + "\"")
        if sub == "cget":
            return e.opts.get(tcl_str(args[2])[1:], "")
        if len(args) == 2:
            return tuple([("-" + k, "", "", "", e.opts.get(k, "")) for k in ("align", "image", "name", "padx", "pady")])
        self._embed_config(e, args[2:])
        self.invalidate()
        return ""

    def forget_slave(self, w):
        for off in list(self.embedded.keys()):
            e = self.embedded[off]
            if e.win is w:
                e.win = None

    def arrange_slaves(self):
        x0, y0, aw, ah = self.text_area()
        vis = set(self.visible_dlines())
        lay = self.get_layout()
        for off in self.embedded:
            e = self.embedded[off]
            w = e.win
            if w is None or w.destroyed:
                continue
            di = self.dline_index(off)
            if di is None or di not in vis:
                self.app.set_mapped(w, False)
                continue
            b = self.char_box(off)
            if b is None:
                continue
            self.app.place_slave(self, w, b[0] + pixels(e.opts.get("padx", 0)), b[1], w.reqw, w.reqh, True)

    # ── events: tag bindings and the current mark ──
    def on_event(self, ev):
        t = ev.type
        if t in (B.MotionNotify, B.EnterNotify, B.LeaveNotify, B.ButtonPress, B.ButtonRelease):
            if t == B.LeaveNotify:
                new_tags = []
            else:
                off = self.offset_at(ev.x, ev.y)
                if t != B.ButtonRelease or not (self.app.buttons & ~(B.Button1Mask << (ev.button - 1) if 1 <= ev.button <= 5 else 0)):
                    self.marks["current"][0] = off
                new_tags = [x.name for x in self.char_tags(off)] if off < len(self.s) else []
            old = self.cur_tags
            if new_tags != old:
                gone = [x for x in old if x not in new_tags]
                came = [x for x in new_tags if x not in old]
                self.cur_tags = new_tags
                if gone:
                    lev = B.XEvent(B.LeaveNotify, self)
                    lev.x = ev.x
                    lev.y = ev.y
                    self._tag_dispatch(gone, lev)
                if came:
                    eev = B.XEvent(B.EnterNotify, self)
                    eev.x = ev.x
                    eev.y = ev.y
                    self._tag_dispatch(came, eev)
            if t in (B.ButtonPress, B.ButtonRelease, B.MotionNotify):
                self._tag_dispatch(self.cur_tags, ev)
        elif t in (B.KeyPress, B.KeyRelease, B.VirtualEvent, B.MouseWheelEvent):
            self._tag_dispatch(self.cur_tags, ev)
        elif t in (B.FocusIn, B.FocusOut):
            self.damage()

    def _tag_dispatch(self, tagnames, ev):
        if not tagnames:
            return
        ring = self.app.ring
        scripts = []
        for tn in tagnames:
            s = self.tag_bindings.best_match(tn, ring if ev in ring else ring + [ev], ev)
            if s is not None:
                scripts.append(s)
        for s in scripts:
            if self.destroyed:
                break
            if self.app.run_binding(s, ev) == "break":
                break

    # ── drawing ──
    def draw(self, h, ax, ay):
        bg = self.color("background")
        fill(h, ax, ay, self.width, self.height, bg)
        f = self.font()
        asc, desc, ls, fixed = f.metrics()
        x0, y0, aw, ah = self.text_area()
        lay = self.get_layout()
        fg = self.color("foreground")
        top = self.top_y()
        gui_push_clip(h, ax + x0, ay + y0, aw, ah)
        has_tags = any([t.ranges for t in self.tags.values()])
        s = self.s
        sel = self.tags["sel"]
        isel = self.opts.get("inactiveselectbackground", "")
        for i in self.visible_dlines():
            d = lay[i]
            ly = ay + y0 + d.y - top
            run_start = d.start
            while run_start < d.end:
                tg = self.char_tags(run_start) if has_tags else []
                run_end = run_start + 1
                while run_end < d.end:
                    if has_tags and self.char_tags(run_end) != tg:
                        break
                    if s[run_end] in ("\t", OBJ) or s[run_start] in ("\t", OBJ):
                        break
                    run_end += 1
                txt = s[run_start:run_end]
                x1 = ax + x0 + d.xs[run_start - d.start] - self.xoff
                x2 = ax + x0 + d.xs[run_end - d.start] - self.xoff
                bgc = self.tag_attr(tg, "background", "")
                if sel in tg and not self.has_focus and isel == "" and self.app.focus is not None:
                    bgc = self.tag_attr([t for t in tg if t is not sel], "background", "")
                if bgc:
                    fill(h, x1, ly, max(1, x2 - x1) if txt != "\n" else ax + x0 + aw - x1, d.h, parse_color(bgc))
                fgc = self.tag_attr(tg, "foreground", "")
                cf = f
                fo = self.tag_attr(tg, "font", "")
                if fo:
                    cf = self.app.font_of(fo)
                col = parse_color(fgc) if fgc else fg
                el = self.tag_attr(tg, "elide", "")
                if el not in ("", 0) and el:
                    run_start = run_end
                    continue
                if txt not in ("\n", "\t", OBJ):
                    draw_text(h, txt.replace("\n", ""), x1, ly + d.asc - cf.metrics()[0], cf, col)
                    if self.tag_attr(tg, "underline", "") not in ("", 0):
                        fill(h, x1, ly + d.asc + 1, x2 - x1, 1, col)
                    if self.tag_attr(tg, "overstrike", "") not in ("", 0):
                        fill(h, x1, ly + d.asc - cf.metrics()[0] // 2, x2 - x1, 1, col)
                run_start = run_end
        ins = self.marks["insert"][0]
        if self.has_focus and self.opts["state"] == "normal":
            b = self.char_box(ins)
            if b is not None:
                iw = max(1, self.px("insertwidth"))
                fill(h, ax + b[0] - iw // 2, ay + b[1], iw, b[3], self.color("insertbackground"))
        gui_pop_clip(h)
        hl = self.px("highlightthickness")
        draw_relief(h, ax + hl, ay + hl, self.width - 2 * hl, self.height - 2 * hl, self.px("borderwidth"), self.opts["relief"], bg)
        if hl > 0:
            c = self.color("highlightcolor") if self.has_focus else self.color("highlightbackground")
            draw_ring(h, ax, ay, self.width, self.height, hl, c)

    def a11y_value(self):
        return self.s[:-1].replace(OBJ, "")


_LINECHAR = re.compile(r"^(-?\d+)\.(\d+|end)")
_ATXY = re.compile(r"^@(-?\d+),(-?\d+)")
_WORD = re.compile(r"^[^\s+\-]+")
_COUNT = re.compile(r"^([+-])\s*(\d+)\s*([a-zA-Z]*)")
_WORDMOD = re.compile(r"^([a-zA-Z]+)")


def _tcl_re(p):
    # Tcl's ARE shorthands Python spells differently
    return p.replace("\\m", "\\b").replace("\\M", "\\b").replace("\\y", "\\b").replace("[[:space:]]", "\\s").replace("[[:alpha:]]", "[^\\W\\d_]").replace("[[:digit:]]", "\\d").replace("[[:alnum:]]", "[^\\W_]")


# ── text.tcl's procs ─────────────────────────────────────────────────────────

def _anchor(app, w):
    name = getattr(w, "anchor_mark", None)
    if name is None:
        _priv(app)["anchorN"] = _priv(app).get("anchorN", 0) + 1
        name = "tk::anchor" + str(_priv(app)["anchorN"])
        w.anchor_mark = name
    if name not in w.marks:
        w.set_mark(name, w.marks["insert"][0])
    return name


def TextButton1(app, args):
    w = _w(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    p = _priv(app)
    p["selectMode"] = "char"
    p["mouseMoved"] = 0
    p["pressX"] = x
    off = TextClosestGap(w, x, y)
    w.set_mark("insert", off)
    an = _anchor(app, w)
    w.set_mark(an, off)
    b = w.char_box(off)
    w.marks[an][1] = "right" if (b is not None and x > b[0]) else "left"
    if w.opts["state"] == "normal":
        app.set_focus(w)
    if w.opts["autoseparators"]:
        w.push_separator()
    w.tags["sel"].ranges = []
    w.damage()
    return ""


def TextClosestGap(w, x, y):
    off = w.offset_at(x, y)
    b = w.char_box(off)
    if b is None or off >= len(w.s) - 1:
        return off
    if w.s[off] == "\n":
        return off
    if x - b[0] < b[2] / 2.0:
        return off
    return off + 1


def TextSelectTo(app, args):
    w = _w(app, args)
    x = get_int(args[1])
    y = get_int(args[2])
    p = _priv(app)
    cur = TextClosestGap(w, x, y)
    an = _anchor(app, w)
    anchor = w.marks[an][0]
    mode = p.get("selectMode", "char")
    if abs(p.get("pressX", x) - x) >= 3:
        p["mouseMoved"] = 1
    if mode == "char":
        if cur < anchor:
            first, last = cur, anchor
        else:
            first, last = anchor, cur
    elif mode == "word":
        a, b = (cur, anchor) if cur < anchor else (anchor, cur)
        first = w._wordstart(a)
        last = w._wordend(b - 1 if b > a else b)
    else:
        a, b = (cur, anchor) if cur < anchor else (anchor, cur)
        first = w.line_start(w.line_of(a))
        last = w.line_end(w.line_of(b)) + 1
    if p["mouseMoved"] or mode != "char":
        w.tags["sel"].ranges = []
        if last > first:
            w.tags["sel"].add(first, last)
        w.set_mark("insert", cur if mode == "char" else last if cur >= anchor else first)
        w.sel_changed()
        w.damage()
    return ""


def TextSetMode(app, args):
    _priv(app)["selectMode"] = tcl_str(args[0])
    return ""


def TextInsert(app, args):
    w = _w(app, args)
    s = tcl_str(args[1])
    if s == "" or w.opts["state"] == "disabled":
        return ""
    compound = False
    sel = w.tags["sel"]
    ins = w.marks["insert"][0]
    old_auto = w.opts["autoseparators"]
    if sel.ranges and sel.ranges[0][0] <= ins <= sel.ranges[-1][1]:
        if old_auto:
            w.opts["autoseparators"] = 0
            w.push_separator()
            compound = True
        w.delete_range(sel.ranges[0][0], sel.ranges[-1][1])
    w.insert_cmd(w.marks["insert"][0], [s])
    w.see(w.marks["insert"][0])
    if compound and old_auto:
        w.push_separator()
        w.opts["autoseparators"] = 1
    return ""


def TextSetCursor(app, args):
    w = _w(app, args)
    off = w.offset(args[1])
    if off >= len(w.s):
        off = len(w.s) - 1
    w.set_mark("insert", off)
    if w.tags["sel"].ranges:
        w.tags["sel"].ranges = []
        w.sel_changed()
    w.see(off)
    if w.opts["autoseparators"]:
        w.push_separator()
    w.damage()
    return ""


def TextKeySelect(app, args):
    w = _w(app, args)
    new = w.offset(args[1])
    if new >= len(w.s):
        new = len(w.s) - 1
    an = _anchor(app, w)
    sel = w.tags["sel"]
    ins = w.marks["insert"][0]
    if not sel.ranges:
        if new < ins:
            sel.add(new, ins)
        else:
            sel.add(ins, new)
        w.set_mark(an, ins)
    else:
        anchor = w.marks[an][0]
        first, last = (new, anchor) if new < anchor else (anchor, new)
        sel.ranges = []
        if last > first:
            sel.add(first, last)
    w.set_mark("insert", new)
    w.see(new)
    w.sel_changed()
    w.damage()
    return ""


def TextUpDownLine(app, args):
    w = _w(app, args)
    n = get_int(args[1])
    return w.to_index(w._count_move(w.marks["insert"][0], n, "displaylines"))


def TextDeleteKey(app, args):
    w = _w(app, args)
    sel = w.tags["sel"]
    ins = w.marks["insert"][0]
    if sel.ranges and sel.ranges[0][0] <= ins <= sel.ranges[-1][1]:
        w.delete_range(sel.ranges[0][0], sel.ranges[-1][1])
    else:
        if ins + 1 < len(w.s):
            w.delete_range(ins, ins + 1)
        w.see(w.marks["insert"][0])
    return ""


def TextBackspace(app, args):
    w = _w(app, args)
    sel = w.tags["sel"]
    ins = w.marks["insert"][0]
    if sel.ranges and sel.ranges[0][0] <= ins <= sel.ranges[-1][1]:
        w.delete_range(sel.ranges[0][0], sel.ranges[-1][1])
    else:
        if ins > 0:
            w.delete_range(ins - 1, ins)
        w.see(w.marks["insert"][0])
    return ""


def TextCopy(app, args, cut=False):
    w = _w(app, args)
    sel = w.tags["sel"]
    if not sel.ranges:
        return ""
    data = "".join([w.s[a:b] for a, b in sel.ranges]).replace(OBJ, "")
    app.c_clipboard(["clear"])
    app.c_clipboard(["append", data])
    if cut and w.opts["state"] == "normal":
        w.delete_range(sel.ranges[0][0], sel.ranges[-1][1])
    return ""


def TextCut(app, args):
    return TextCopy(app, args, True)


def TextPaste(app, args):
    w = _w(app, args)
    try:
        data = app.c_clipboard(["get"])
    except TclError:
        return ""
    if w.opts["state"] != "normal":
        return ""
    auto = w.opts["autoseparators"]
    if auto:
        w.opts["autoseparators"] = 0
        w.push_separator()
    sel = w.tags["sel"]
    if C.windowing_system() != "x11" and sel.ranges:
        w.delete_range(sel.ranges[0][0], sel.ranges[-1][1])
    w.insert_cmd(w.marks["insert"][0], [data])
    if auto:
        w.push_separator()
        w.opts["autoseparators"] = 1
    w.see(w.marks["insert"][0])
    return ""


def TextSelectAll(app, args):
    w = _w(app, args)
    w.tags["sel"].ranges = []
    w.tags["sel"].add(0, len(w.s))
    w.sel_changed()
    w.damage()
    return ""


def TextSelectNone(app, args):
    w = _w(app, args)
    if w.tags["sel"].ranges:
        w.tags["sel"].ranges = []
        w.sel_changed()
        w.damage()
    return ""


def TextUndo(app, args):
    w = _w(app, args)
    try:
        w.w_edit(["undo"])
    except TclError:
        pass
    return ""


def TextRedo(app, args):
    w = _w(app, args)
    try:
        w.w_edit(["redo"])
    except TclError:
        pass
    return ""


def TextScrollPages(app, args):
    w = _w(app, args)
    n = get_int(args[1])
    w.w_yview(["scroll", n, "pages"])
    vis = w.visible_dlines()
    if vis:
        d = w.get_layout()[vis[0] if n < 0 else vis[-1]]
        return w.to_index(d.start)
    return w.to_index(w.marks["insert"][0])


C.WIDGET_TYPES["text"] = TkText
for _name, _f in (("tk::TextButton1", TextButton1), ("tk::TextSelectTo", TextSelectTo), ("tk::TextSetMode", TextSetMode),
                  ("tk::TextInsert", TextInsert), ("tk::TextSetCursor", TextSetCursor), ("tk::TextKeySelect", TextKeySelect),
                  ("tk::TextUpDownLine", TextUpDownLine), ("tk::TextDeleteKey", TextDeleteKey),
                  ("tk::TextBackspace", TextBackspace), ("tk::TextCopy", TextCopy), ("tk::TextCut", TextCut),
                  ("tk::TextPaste", TextPaste), ("tk::TextSelectAll", TextSelectAll), ("tk::TextSelectNone", TextSelectNone),
                  ("tk::TextUndo", TextUndo), ("tk::TextRedo", TextRedo), ("tk::TextScrollPages", TextScrollPages)):
    C.TK_COMMANDS[_name] = _f


def _bindings(app):
    b = app.bindings
    T = "Text"
    b.set(T, "<1>", "tk::TextButton1 %W %x %y; %W tag remove sel 0.0 end")
    b.set(T, "<B1-Motion>", "tk::TextSelectTo %W %x %y")
    b.set(T, "<Double-1>", "tk::TextSetMode word; tk::TextSelectTo %W %x %y; catch {%W mark set insert sel.first}")
    b.set(T, "<Triple-1>", "tk::TextSetMode line; tk::TextSelectTo %W %x %y; catch {%W mark set insert sel.first}")
    b.set(T, "<Shift-1>", "tk::TextSelectTo %W %x %y")
    b.set(T, "<Control-1>", "%W mark set insert @%x,%y; if {[%W cget -autoseparators]} {%W edit separator}")
    b.set(T, "<<PrevChar>>", "tk::TextSetCursor %W insert-1displayindices")
    b.set(T, "<<NextChar>>", "tk::TextSetCursor %W insert+1displayindices")
    b.set(T, "<<PrevLine>>", "tk::TextSetCursor %W [tk::TextUpDownLine %W -1]")
    b.set(T, "<<NextLine>>", "tk::TextSetCursor %W [tk::TextUpDownLine %W 1]")
    b.set(T, "<<SelectPrevChar>>", "tk::TextKeySelect %W [%W index {insert - 1displayindices}]")
    b.set(T, "<<SelectNextChar>>", "tk::TextKeySelect %W [%W index {insert + 1displayindices}]")
    b.set(T, "<<SelectPrevLine>>", "tk::TextKeySelect %W [tk::TextUpDownLine %W -1]")
    b.set(T, "<<SelectNextLine>>", "tk::TextKeySelect %W [tk::TextUpDownLine %W 1]")
    b.set(T, "<<PrevWord>>", "tk::TextSetCursor %W {insert -1c wordstart}")
    b.set(T, "<<NextWord>>", "tk::TextSetCursor %W {insert wordend}")
    b.set(T, "<<SelectPrevWord>>", "tk::TextKeySelect %W [%W index {insert -1c wordstart}]")
    b.set(T, "<<SelectNextWord>>", "tk::TextKeySelect %W [%W index {insert wordend}]")
    b.set(T, "<<LineStart>>", "tk::TextSetCursor %W {insert display linestart}")
    b.set(T, "<<SelectLineStart>>", "tk::TextKeySelect %W [%W index {insert display linestart}]")
    b.set(T, "<<LineEnd>>", "tk::TextSetCursor %W {insert display lineend}")
    b.set(T, "<<SelectLineEnd>>", "tk::TextKeySelect %W [%W index {insert display lineend}]")
    b.set(T, "<Prior>", "tk::TextSetCursor %W [tk::TextScrollPages %W -1]")
    b.set(T, "<Next>", "tk::TextSetCursor %W [tk::TextScrollPages %W 1]")
    b.set(T, "<Control-Home>", "tk::TextSetCursor %W 1.0")
    b.set(T, "<Control-End>", "tk::TextSetCursor %W {end - 1 indices}")
    b.set(T, "<Tab>", "if {[%W cget -state] eq \"normal\"} {tk::TextInsert %W \\t; focus %W; break}")
    b.set(T, "<Shift-Tab>", "break")
    b.set(T, "<Control-Tab>", "focus [tk_focusNext %W]")
    b.set(T, "<Control-Shift-Tab>", "focus [tk_focusPrev %W]")
    b.set(T, "<Control-i>", "tk::TextInsert %W \\t")
    b.set(T, "<Return>", "tk::TextInsert %W \\n; if {[%W cget -autoseparators]} {%W edit separator}")
    b.set(T, "<Delete>", "tk::TextDeleteKey %W")
    b.set(T, "<BackSpace>", "tk::TextBackspace %W")
    b.set(T, "<<SelectAll>>", "tk::TextSelectAll %W")
    b.set(T, "<<SelectNone>>", "tk::TextSelectNone %W")
    b.set(T, "<<Cut>>", "tk::TextCut %W")
    b.set(T, "<<Copy>>", "tk::TextCopy %W")
    b.set(T, "<<Paste>>", "tk::TextPaste %W")
    b.set(T, "<<Clear>>", "catch {%W delete sel.first sel.last}")
    b.set(T, "<<Undo>>", "tk::TextUndo %W")
    b.set(T, "<<Redo>>", "tk::TextRedo %W")
    b.set(T, "<KeyPress>", "tk::TextInsert %W %A")
    b.set(T, "<Alt-KeyPress>", "# nothing")
    b.set(T, "<Meta-KeyPress>", "# nothing")
    b.set(T, "<Control-KeyPress>", "# nothing")
    b.set(T, "<Escape>", "# nothing")
    b.set(T, "<KP_Enter>", "# nothing")
    b.set(T, "<Control-d>", "%W delete insert")
    b.set(T, "<Control-k>", "if {[%W compare insert == {insert lineend}]} {%W delete insert} else {%W delete insert {insert lineend}}")
    b.set(T, "<Control-o>", "%W insert insert \\n; %W mark set insert insert-1c")
    b.set(T, "<Control-h>", "tk::TextBackspace %W")
    b.set(T, "<2>", "%W scan mark %x %y")
    b.set(T, "<B2-Motion>", "%W scan dragto %x %y")
    b.set(T, "<MouseWheel>", "%W yview scroll [expr {-(%D/120) * 4}] units")
    b.set(T, "<4>", "%W yview scroll -5 units")
    b.set(T, "<5>", "%W yview scroll 5 units")


C.APP_INIT.append(_bindings)
