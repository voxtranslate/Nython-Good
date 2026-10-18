# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/win.ny - the window record every Tk widget is (round 84).
#
# TkWin holds what Tk's TkWindow and a widget record hold: the path name,
# class, parent and children (in stacking order), the geometry (x, y,
# width, height relative to the parent; the requested size; the internal
# border), the mapped state, the geometry manager managing it and the
# slaves it manages, the bindtags, and the widget's configuration options.
#
# Options are declared per widget class as Tk's Tk_OptionSpec tables are:
#     (name, dbName, dbClass, default, kind)
# with aliases (bd -> borderwidth).  Kinds validate and normalise a value
# as Tk's option types do (int, double, boolean, pixels, color, relief,
# anchor, justify, enum:<a|b|c>, string, font, image, cursor, ...), with
# Tk's error messages.  Creation-time options (-class, -container ...)
# cannot be changed afterwards.
#
# A widget class implements:
#     w_<subcommand>(self, args)   its widget command (`.b invoke` ...);
#                                  CMDS lists them for prefix matching
#     compute_geometry()           its requested size (Tk_GeometryRequest)
#     draw(h, ax, ay)              paint itself at absolute (ax, ay) of the
#                                  backend window h
#     on_event(ev)                 the event handlers Tk widgets register in
#                                  C (focus, configure, destroy ...)
#     reconfigured(changed)        after `configure`

from _tkinter.tcl import TclError, tcl_str, split_list, join_list, get_int, get_double, get_boolean, match_prefix, or_list
from _tkinter.util import pixels, fpixels, parse_color, cround

_RELIEFS = ["flat", "groove", "raised", "ridge", "solid", "sunken"]
_ANCHORS = ["n", "ne", "e", "se", "s", "sw", "w", "nw", "center"]
_JUSTIFY = ["left", "right", "center"]

CREATE_ONLY = set(["class", "container", "visual", "colormap", "screen", "use"])


def _norm(app, kind, v, optname):
    # -> the value stored for the option, or raises TclError
    if kind == "string" or kind == "cursor" or kind == "command" or kind == "var" or kind == "bitmap":
        if isinstance(v, (tuple, list)):
            return join_list(v)
        return tcl_str(v)
    if kind == "int":
        return get_int(v)
    if kind == "double":
        return get_double(v)
    if kind == "boolean":
        return 1 if get_boolean(v) else 0
    if kind == "pixels" or kind == "pixels_or_empty":
        if kind == "pixels_or_empty" and tcl_str(v) == "":
            return ""
        if isinstance(v, int) and not isinstance(v, bool):
            return v
        if isinstance(v, float):
            return v
        s = tcl_str(v).strip()
        fpixels(s)
        try:
            return int(s)
        except ValueError:
            return s
    if kind == "padding":
        s = tcl_str(v)
        for p in split_list(s):
            fpixels(p)
        return v if isinstance(v, (int, tuple, list)) else s
    if kind == "color":
        s = tcl_str(v)
        parse_color(s)
        return s
    if kind == "color_or_empty":
        s = tcl_str(v)
        if s != "":
            parse_color(s)
        return s
    if kind == "relief":
        return match_prefix(tcl_str(v), _RELIEFS, "relief")
    if kind == "relief_or_empty":
        s = tcl_str(v)
        return "" if s == "" else match_prefix(s, _RELIEFS, "relief")
    if kind == "anchor":
        return match_prefix(tcl_str(v), _ANCHORS, "anchor")
    if kind == "justify":
        return match_prefix(tcl_str(v), _JUSTIFY, "justification")
    if kind == "font":
        s = v if isinstance(v, str) else join_list(v) if isinstance(v, (tuple, list)) else tcl_str(v)
        app.font_of(s)
        return s
    if kind == "image":
        s = tcl_str(v)
        if s != "":
            for name in split_list(s)[:1]:
                if name not in app.images:
                    raise TclError("image \"" + name + "\" doesn't exist")
        return s
    if kind == "list":
        if isinstance(v, (tuple, list)):
            return join_list(v)
        s = tcl_str(v)
        split_list(s)
        return s
    if kind == "obj":
        return v
    if kind.startswith("enum:"):
        choices = kind[5:].split("|")
        what = "value"
        if ":" in choices[-1]:
            last, what = choices[-1].split(":")
            choices[-1] = last
        return match_prefix(tcl_str(v), choices, what)
    if kind.startswith("enumx:"):
        # an enum that also accepts "" (Tk's TK_OPTION_NULL_OK)
        s = tcl_str(v)
        if s == "":
            return ""
        choices = kind[6:].split("|")
        what = "value"
        if ":" in choices[-1]:
            last, what = choices[-1].split(":")
            choices[-1] = last
        return match_prefix(s, choices, what)
    return v


class OptionTable:
    def __init__(self, specs, aliases):
        self.specs = specs
        self.aliases = aliases
        self.byname = {}
        for s in specs:
            self.byname[s[0]] = s
        self.names = [s[0] for s in specs]
        self.all = sorted(list(self.byname.keys()) + list(aliases.keys()))

    def resolve(self, name):
        if name in self.byname:
            return name
        a = self.aliases.get(name)
        if a is not None:
            return a
        # Tk accepts unique abbreviations of option names
        found = [n for n in self.all if n.startswith(name)]
        if len(found) == 1 and name != "":
            f = found[0]
            return self.aliases.get(f, f)
        if len(found) > 1:
            # an exact alias/name among them was handled above
            raise TclError("ambiguous option \"-" + name + "\"")
        raise TclError("unknown option \"-" + name + "\"")


_TABLES = {}


def option_table(cls):
    t = _TABLES.get(cls)
    if t is None:
        t = OptionTable(cls.OPTS, cls.ALIASES)
        _TABLES[cls] = t
    return t


class TkWin:
    CLASS = "Frame"
    OPTS = []
    ALIASES = {}
    CMDS = ["cget", "configure"]
    IS_TOPLEVEL = False
    TAKES_FOCUS = False      # has Key/Focus class bindings (tk::FocusOK)

    def __init__(self, app, path, parent, wclass=None):
        self.app = app
        self.path = path
        self.parent = parent
        if path == ".":
            self.name = app.appname
        else:
            self.name = path[path.rfind(".") + 1:]
        self.wclass = wclass if wclass else self.CLASS
        self.children = []
        self.x = 0
        self.y = 0
        self.width = 1
        self.height = 1
        self.reqw = 1
        self.reqh = 1
        self.minreqw = 0
        self.minreqh = 0
        self.ib = [0, 0, 0, 0]
        self.mapped = False
        self.manager = ""
        self.minfo = None
        self.gmaster = None
        self.pack_slaves = []
        self.place_slaves = []
        self.grid_slaves = []
        self.grid = None
        self.pack_prop = True
        self.grid_prop = True
        self.content_manager = ""   # which manager owns this window's slaves
        self.opts = {}
        self.bindtags = None
        self.destroyed = False
        self.top = self if self.IS_TOPLEVEL else (parent.top if parent is not None else self)
        self.var_links = []
        self.cursor_on = True
        self.has_focus = False
        self.native = None
        self.table = option_table(type(self))
        self.cfg_serial = 0

    # ── options ──────────────────────────────────────────────────────────
    def init_options(self):
        app = self.app
        for spec in self.table.specs:
            name, dbname, dbclass, default, kind = spec
            v = None
            if dbname != "":
                v = app.option_lookup(self, dbname, dbclass)
            if v is None:
                v = default
            try:
                self.opts[name] = _norm(app, kind, v, name) if v is not None else None
            except TclError:
                self.opts[name] = _norm(app, kind, default, name) if default is not None else None

    def opt(self, name):
        return self.opts[name]

    def px(self, name):
        v = self.opts[name]
        if v is None or v == "":
            return 0
        return pixels(v)

    def color(self, name):
        v = self.opts[name]
        if v is None or v == "":
            return None
        return parse_color(v)

    def configure_pairs(self, args, creating=False):
        if len(args) % 2 != 0:
            raise TclError("value for \"" + tcl_str(args[-1]) + "\" missing")
        saved = dict(self.opts)
        changed = []
        try:
            for i in range(0, len(args), 2):
                k = tcl_str(args[i])
                if not k.startswith("-"):
                    raise TclError("unknown option \"" + k + "\"")
                name = self.table.resolve(k[1:])
                if name in CREATE_ONLY and not creating:
                    if self.opts.get(name) != tcl_str(args[i + 1]):
                        raise TclError("can't modify -" + name + " option after widget is created")
                    continue
                spec = self.table.byname[name]
                v = args[i + 1]
                self.opts[name] = _norm(self.app, spec[4], v, name) if v is not None else None
                changed.append(name)
            self.validate_options(changed)
        except TclError:
            self.opts = saved
            raise
        self.cfg_serial += 1
        if changed:
            self.reconfigured(changed)
        return ""

    def validate_options(self, changed):
        pass

    def describe(self, name):
        spec = self.table.byname[name]
        return ("-" + name, spec[1], spec[2], spec[3] if spec[3] is not None else "", self.cget_value(name))

    def cget_value(self, name):
        v = self.opts.get(name)
        if v is None:
            return ""
        return v

    def w_configure(self, args):
        if len(args) == 0:
            out = []
            for spec in self.table.specs:
                out.append(self.describe(spec[0]))
            for a in sorted(self.table.aliases.keys()):
                out.append(("-" + a, "-" + self.table.aliases[a]))
            return tuple(out)
        if len(args) == 1:
            k = tcl_str(args[0])
            if not k.startswith("-"):
                raise TclError("unknown option \"" + k + "\"")
            return self.describe(self.table.resolve(k[1:]))
        return self.configure_pairs(args)

    def w_cget(self, args):
        if len(args) != 1:
            raise TclError("wrong # args: should be \"" + self.path + " cget option\"")
        k = tcl_str(args[0])
        if not k.startswith("-"):
            raise TclError("unknown option \"" + k + "\"")
        return self.cget_value(self.table.resolve(k[1:]))

    def command(self, args):
        if len(args) == 0:
            raise TclError("wrong # args: should be \"" + self.path + " option ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), self.CMDS, "option")
        return getattr(self, "w_" + sub)(list(args[1:]))

    # ── hooks for widget classes ─────────────────────────────────────────
    def created(self):
        self.reconfigured(list(self.opts.keys()))

    def reconfigured(self, changed):
        self.compute_geometry()
        self.damage()

    def compute_geometry(self):
        pass

    def draw(self, h, ax, ay):
        pass

    def on_event(self, ev):
        pass

    def on_resize(self):
        # the window's size changed; a widget whose request depends on its
        # size (scrollbar arrows) recomputes it
        pass

    def on_destroy(self):
        pass

    def damage(self):
        if not self.destroyed:
            self.app.damage(self.top)

    # ── geometry ─────────────────────────────────────────────────────────
    def request(self, w, h):
        # Tk_GeometryRequest
        w = int(w)
        h = int(h)
        if w <= 0:
            w = 1
        if h <= 0:
            h = 1
        if w != self.reqw or h != self.reqh:
            self.reqw = w
            self.reqh = h
            self.app.relayout()

    def set_internal_border(self, b):
        self.set_internal_borders(b, b, b, b)

    def set_internal_borders(self, l, t, r, b):
        nb = [l, t, r, b]
        if nb != self.ib:
            self.ib = nb
            self.app.relayout()

    def set_min_request(self, w, h):
        if w != self.minreqw or h != self.minreqh:
            self.minreqw = w
            self.minreqh = h
            self.app.relayout()

    def root_xy(self):
        # winfo rootx/rooty
        x = 0
        y = 0
        w = self
        while w is not None and not w.IS_TOPLEVEL:
            x += w.x
            y += w.y
            w = w.parent
        if w is not None:
            x += w.x
            y += w.y + w.menubar_height()
        return x, y

    def abs_xy(self):
        # position inside its toplevel's backend window
        x = 0
        y = 0
        w = self
        while w is not None and not w.IS_TOPLEVEL:
            x += w.x
            y += w.y
            w = w.parent
        if w is not None:
            y += w.menubar_height()
        return x, y

    def menubar_height(self):
        return 0

    def viewable(self):
        w = self
        while w is not None:
            if not w.mapped:
                return False
            if w.IS_TOPLEVEL:
                return True
            w = w.parent
        return True

    def is_ancestor_of(self, other):
        w = other
        while w is not None:
            if w is self:
                return True
            w = w.parent
        return False

    def contains_point(self, x, y):
        return 0 <= x < self.width and 0 <= y < self.height

    def descendants(self):
        out = []
        for c in self.children:
            out.append(c)
            out.extend(c.descendants())
        return out

    def get_bindtags(self):
        if self.bindtags is not None:
            return self.bindtags
        if self.IS_TOPLEVEL:
            return [self.path, self.wclass, "all"]
        return [self.path, self.wclass, self.top.path, "all"]

    def state_value(self):
        st = self.opts.get("state")
        return st if st is not None else "normal"

    # ── variable links (Tk's internal traces on -variable / -textvariable) ──
    def link_var(self, name, callback):
        if name == "":
            return
        self.var_links.append(self.app.add_link(name, callback))

    def unlink_vars(self):
        for t in self.var_links:
            self.app.remove_link(t)
        self.var_links = []

    def scroll_command(self, optname, first, last):
        cmd = self.opts.get(optname)
        if cmd:
            self.app.eval_bg(cmd + " " + _fmt_frac(first) + " " + _fmt_frac(last))


def _fmt_frac(f):
    # Tk prints scroll fractions with Tcl_PrintDouble
    f = float(f)
    if f == int(f):
        return str(int(f)) + ".0"
    return repr(f)


def fmt_frac(f):
    return _fmt_frac(f)
