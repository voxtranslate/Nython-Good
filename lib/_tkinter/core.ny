# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/core.ny - the Tk application: one per Tk() / Tcl() (round 84).
#
# App is what _tkinter.create() returns (CPython's tkapp object): the Tcl
# interpreter with its variables and their traces, the commands created
# with createcommand, and - when Tk is loaded - Tk itself over the SDL
# backend (src/builtins/gui.cpp; the headless stub runs it without a
# display):
#
#   windows      "." and every widget, by path; one backend window per
#                mapped toplevel, made when the toplevel is mapped
#   events       backend input -> X-style events: ButtonPress/Release with
#                an implicit pointer grab, Motion, Enter/Leave with X's
#                crossing details along the hierarchy, KeyPress/Release
#                (keysym, char, keycode, state) to the focus window,
#                wheel as Button-4/5 (x11) or MouseWheel (delta 120),
#                FocusIn/Out, Configure, Map/Unmap, Destroy, Expose
#   bindings     bind.ny's table, bindtags (widget, class, toplevel, all),
#                "break"; `event add/delete/info/generate`
#   event loop   Tcl_DoOneEvent: window events, timers (`after`), idle
#                handlers in FIFO order (after idle, geometry, redisplay)
#   geometry     geom.ny's pack/grid/place run at idle: requests propagate
#                up to the toplevels, the window manager sizes them (wm
#                geometry, minsize/maxsize), slaves are arranged top-down;
#                <Configure>/<Map>/<Unmap> are generated as Tk does
#   focus, grab, the option database (priorities, most recent wins), the
#   clipboard and PRIMARY selection, named fonts, images, wm and winfo
#
# The Tcl commands Tk itself provides, as far as tkinter, ttk, turtle and
# the dialogs issue them: after bell bind bindtags clipboard destroy event
# focus font grab grid image lower option pack place raise selection send
# (an error) tk tkwait update vwait winfo wm trace, the widget creation
# commands, tk_focusNext/Prev/FollowsMouse, tk_setPalette, tk_bisque,
# tk_messageBox, tk_getOpenFile/SaveFile/chooseDirectory/chooseColor,
# tk_popup, ttk::style and ttk::* widgets; any other command name raises
# TclError("invalid command name ...").

import math
import os
import sys
import time
from _tkinter.tcl import (TclError, tcl_str, tcl_float, split_list, join_list, quote_elem, get_int, get_double,
                          get_boolean, match_prefix, or_list, Interp, _Break, _Continue, _Return)
from _tkinter.util import (pixels, fpixels, parse_color, rgb16, cdiv, cround, SCREEN, set_dpi, get_font,
                           parse_font_spec, parse_font_options, font_from_attrs, installed_families, reset_fonts)
from _tkinter import bind as B
from _tkinter.bind import XEvent, BindingTable, expand_percents, keysym_number, keysym_name
from _tkinter import geom as G
from _tkinter.win import TkWin, fmt_frac

WIDGET_TYPES = {}      # widget creation command -> TkWin subclass
TK_COMMANDS = {}       # extra Tcl commands widget modules add: name -> f(app, args)
APP_INIT = []          # functions called with each new App once Tk is loaded

TK_VERSION = "8.6"
TCL_VERSION = "8.6"
TK_PATCHLEVEL = "8.6.13"

WINDOW_EVENTS = 4
FILE_EVENTS = 8
TIMER_EVENTS = 16
IDLE_EVENTS = 32
DONT_WAIT = 2
ALL_EVENTS = -3

_APPS = []


def _now_ms():
    return int(time.monotonic() * 1000)


def windowing_system():
    if sys.platform.startswith("win"):
        return "win32"
    if sys.platform == "darwin":
        return "aqua"
    return "x11"


# X11 keycodes (evdev + 8, US layout) for the keysyms the backend reports
_XKEYCODES = {
    "Escape": 9, "1": 10, "2": 11, "3": 12, "4": 13, "5": 14, "6": 15, "7": 16, "8": 17, "9": 18,
    "0": 19, "minus": 20, "equal": 21, "BackSpace": 22, "Tab": 23, "q": 24, "w": 25, "e": 26,
    "r": 27, "t": 28, "y": 29, "u": 30, "i": 31, "o": 32, "p": 33, "bracketleft": 34,
    "bracketright": 35, "Return": 36, "Control_L": 37, "a": 38, "s": 39, "d": 40, "f": 41, "g": 42,
    "h": 43, "j": 44, "k": 45, "l": 46, "semicolon": 47, "apostrophe": 48, "grave": 49,
    "Shift_L": 50, "backslash": 51, "z": 52, "x": 53, "c": 54, "v": 55, "b": 56, "n": 57, "m": 58,
    "comma": 59, "period": 60, "slash": 61, "Shift_R": 62, "Alt_L": 64, "space": 65,
    "Caps_Lock": 66, "F1": 67, "F2": 68, "F3": 69, "F4": 70, "F5": 71, "F6": 72, "F7": 73,
    "F8": 74, "F9": 75, "F10": 76, "F11": 95, "F12": 96, "Control_R": 105, "Alt_R": 108,
    "Home": 110, "Up": 111, "Prior": 112, "Left": 113, "Right": 114, "End": 115, "Down": 116,
    "Next": 117, "Insert": 118, "Delete": 119, "Super_L": 133, "KP_Enter": 104,
}
_SHIFTED = {"!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
            ")": "0", "_": "minus", "+": "equal", "{": "bracketleft", "}": "bracketright",
            ":": "semicolon", "\"": "apostrophe", "~": "grave", "|": "backslash", "<": "comma",
            ">": "period", "?": "slash"}

# the backend's key names -> X keysyms (and the character Tk gives for them)
_KEYNAMES = {
    "enter": ("Return", "\r"), "escape": ("Escape", "\x1b"), "backspace": ("BackSpace", "\b"),
    "tab": ("Tab", "\t"), "space": ("space", " "), "delete": ("Delete", "\x7f"),
    "up": ("Up", ""), "down": ("Down", ""), "left": ("Left", ""), "right": ("Right", ""),
    "home": ("Home", ""), "end": ("End", ""), "pageup": ("Prior", ""), "pagedown": ("Next", ""),
    "insert": ("Insert", ""), "shift": ("Shift_L", ""), "ctrl": ("Control_L", ""),
    "alt": ("Alt_L", ""), "super": ("Super_L", ""), "capslock": ("Caps_Lock", ""),
    "numlock": ("Num_Lock", ""), "menu": ("Menu", ""), "pause": ("Pause", ""),
    "printscreen": ("Print", ""), "scrolllock": ("Scroll_Lock", ""),
}
for _i in range(1, 25):
    _KEYNAMES["f" + str(_i)] = ("F" + str(_i), "")


def keysym_char(ks):
    # the character Tk gives a key event for a keysym (generated events)
    for k in _KEYNAMES:
        if _KEYNAMES[k][0] == ks:
            return _KEYNAMES[k][1]
    n = keysym_number(ks)
    if n is None:
        return ""
    if n < 0x100 and n >= 0x20:
        return chr(n)
    if n >= 0x1000000:
        return chr(n - 0x1000000)
    return ""


def xkeycode(ks):
    k = _XKEYCODES.get(ks)
    if k is not None:
        return k
    if len(ks) == 1:
        low = ks.lower()
        if low in _XKEYCODES:
            return _XKEYCODES[low]
        if ks in _SHIFTED:
            return _XKEYCODES.get(_SHIFTED[ks], 0)
    return 0


class Trace:
    def __init__(self, ops, cmd, func, legacy):
        self.ops = ops
        self.cmd = cmd
        self.func = func
        self.legacy = legacy


class WmInfo:
    def __init__(self):
        self.title = None
        self.user_w = None
        self.user_h = None
        self.ux = None
        self.uy = None
        self.minw = 1
        self.minh = 1
        self.maxw = None
        self.maxh = None
        self.resizable = [1, 1]
        self.state = "normal"
        self.attributes = {"-alpha": 1.0, "-topmost": 0, "-zoomed": 0, "-fullscreen": 0, "-type": ""}
        self.protocols = {}
        self.iconname = ""
        self.group = ""
        self.transient = ""
        self.override = 0
        self.positionfrom = ""
        self.sizefrom = ""
        self.aspect = ""
        self.focusmodel = "passive"
        self.iconphoto = ""
        self.iconbitmap = ""
        self.command = ""
        self.client = ""
        self.native_size = None
        self.map_pending = True
        self.ever_mapped = False


class App:
    def __init__(self, screenName=None, baseName="", className="Tk", interactive=False, wantobjects=1,
                 wantTk=True, sync=False, use=None):
        self.interp = Interp()
        self.interp.var_hook = self._var_hook
        self.vars = {}
        self.traces = {}
        self.tracing = set()
        self.wantobjects = wantobjects
        self.appname = baseName if baseName else "tk"
        cn = className if className else "Tk"
        self.classname = cn[0].upper() + cn[1:]
        self.widgets = {}
        self.root = None
        self.bindings = BindingTable()
        self.ring = []
        self.serial = 0
        self.timers = []
        self.timer_seq = 0
        self.after_info = {}
        self.after_n = 0
        self.idle_q = []
        self.idle_once = set()
        self.frame_images = []
        self.layout_queued = False
        self.in_layout = False
        self.layout_dirty = False
        self.redisplay_queued = False
        self.damaged = []
        self.struct_q = []
        self.quit_flag = False
        self.focus = None
        self.app_has_focus = True
        self.grab = None
        self.grab_global = False
        self.pointer_top = None
        self.pointer_win = None
        self.pointer_root = (0, 0)
        self.button_grab = None
        self.buttons = 0
        self.mods = 0
        self.images = {}
        self.image_n = 0
        self.named_fonts = {}
        self.font_n = 0
        self.option_db = []
        self.option_serial = 0
        self.clipboard = None
        self.clip_buffer = ""
        self.selection = {}
        self.toplevels = []
        self.natives = {}
        self.tk_loaded = False
        self.event_queue = []
        self.dialog_waiter = None
        self.sync_seen = set()
        self.frames_drawn = 0
        self.frame_ops = 0
        self.last_input = _now_ms()
        self.window_ids = 0x1e00000
        self.wid = {}
        self.busy = {}
        self.styles = None
        self.bell_count = 0
        self.dispatch_depth = 0
        self.callbacks_db = {}
        self.vwait_hit = set()
        self.extra_struct = []
        self.palette = None
        self.strict_motif = 0
        self.dead = False
        self._setup_tcl()
        if wantTk:
            self.load_tk()
        _APPS.append(self)

    # ── Tcl ──────────────────────────────────────────────────────────────
    def _setup_tcl(self):
        v = self.vars
        v["tcl_version"] = TCL_VERSION
        v["tcl_patchLevel"] = TK_PATCHLEVEL
        v["tcl_interactive"] = 0
        v["tcl_platform(platform)"] = "windows" if sys.platform.startswith("win") else "unix"
        v["tcl_platform(os)"] = "Linux" if sys.platform.startswith("linux") else sys.platform
        v["tcl_platform(byteOrder)"] = "littleEndian"
        v["tcl_platform(threaded)"] = 1
        v["argv0"] = self.appname
        v["argc"] = 0
        v["argv"] = ""
        v["errorInfo"] = ""
        v["errorCode"] = "NONE"
        c = self.interp.commands
        for name in ("after", "bell", "bind", "bindtags", "clipboard", "destroy", "event", "focus",
                     "font", "grab", "grid", "image", "lower", "option", "pack", "place", "raise",
                     "selection", "send", "tk", "tkwait", "update", "vwait", "winfo", "wm", "trace",
                     "tk_focusNext", "tk_focusPrev", "tk_focusFollowsMouse", "tk_setPalette",
                     "tk_bisque", "tk_popup", "exit", "bgerror", "ttk::style"):
            c[name] = self._cmd_wrapper(name)
        for name in TK_COMMANDS:
            c[name] = self._ext_wrapper(TK_COMMANDS[name])
        for name in WIDGET_TYPES:
            c[name] = self._create_wrapper(name)

    def _cmd_wrapper(self, name):
        f = getattr(self, "c_" + name.replace("::", "_"))
        return lambda it, words: f(words[1:])

    def _ext_wrapper(self, f):
        app = self
        return lambda it, words: f(app, words[1:])

    def _create_wrapper(self, name):
        app = self
        return lambda it, words: app.create_widget(name, words[1:])

    def _var_hook(self, name, op, value):
        if op == "read":
            self._fire(name, "read")
            if name not in self.vars:
                raise TclError("can't read \"" + name + "\": no such variable")
            return self.vars[name]
        if op == "write":
            self.vars[name] = value
            self._fire(name, "write")
            return self.vars.get(name, value)
        if op == "unset":
            if name not in self.vars:
                if value:
                    return ""
                raise TclError("can't unset \"" + name + "\": no such variable")
            del self.vars[name]
            self._fire(name, "unset")
            # traces go with the variable, except the widgets' links, which
            # re-create it (as Tk's widgets do)
            lst = self.traces.get(name)
            if lst:
                keep = [t for t in lst if t.func is not None]
                if keep:
                    self.traces[name] = keep
                else:
                    del self.traces[name]
            return ""
        return name in self.vars

    def _fire(self, name, op):
        lst = self.traces.get(name)
        if not lst or name in self.tracing:
            return
        self.tracing.add(name)
        try:
            for t in list(reversed(lst)):
                if op not in t.ops:
                    continue
                if t.func is not None:
                    t.func(name, op)
                else:
                    words = split_list(t.cmd) + [name, "", op[0] if t.legacy else op]
                    try:
                        self.interp.invoke(words)
                    except TclError as e:
                        what = "read" if op == "read" else ("set" if op == "write" else "unset")
                        raise TclError("can't " + what + " \"" + name + "\": " + str(e))
        finally:
            self.tracing.discard(name)
        if op == "write" and name in self.vwait_hit:
            pass

    def add_link(self, name, callback):
        t = Trace(set(["write", "unset"]), None, callback, False)
        self.traces.setdefault(name, []).append(t)
        return (name, t)

    def remove_link(self, link):
        name, t = link
        lst = self.traces.get(name)
        if lst and t in lst:
            lst.remove(t)
            if not lst:
                del self.traces[name]

    # the tkapp methods tkinter calls
    def call(self, *args):
        if len(args) == 1 and isinstance(args[0], tuple):
            args = args[0]
        # _tkinter's Tkapp_CallArgs: a None ends the argument list
        words = []
        for a in args:
            if a is None:
                break
            words.append(a)
        if not words:
            raise TclError("wrong # args")
        return self.interp.invoke(words)

    def eval(self, script):
        # a `return` at the top level ends the script with its value
        # (Tcl_EvalEx turns TCL_RETURN into TCL_OK at level 0)
        try:
            r = self.interp.eval(script)
        except _Return as ret:
            r = ret.value
        return tcl_str(r)

    def evalfile(self, fileName):
        with open(fileName) as f:
            return self.eval(f.read())

    def getvar(self, name, *rest):
        if rest:
            name = tcl_str(name) + "(" + tcl_str(rest[0]) + ")"
        return self.interp.getvar(tcl_str(name))

    globalgetvar = getvar

    def setvar(self, name, *args):
        if len(args) == 2:
            name = tcl_str(name) + "(" + tcl_str(args[0]) + ")"
            value = args[1]
        elif len(args) == 1:
            value = args[0]
        else:
            raise TypeError("setvar requires 2 or 3 arguments")
        self.interp.setvar(tcl_str(name), value)

    globalsetvar = setvar

    def unsetvar(self, name, *rest):
        if rest:
            name = tcl_str(name) + "(" + tcl_str(rest[0]) + ")"
        self.interp.unsetvar(tcl_str(name))

    globalunsetvar = unsetvar

    def createcommand(self, name, func):
        if not callable(func):
            raise TypeError("command not callable")
        def tclcmd(it, words):
            args = [tcl_str(w) for w in words[1:]]
            r = func(*args)
            if r is None:
                return ""
            return r
        self.interp.commands[name] = tclcmd

    def deletecommand(self, name):
        if name in self.interp.commands:
            del self.interp.commands[name]
            return
        raise TclError("can't delete Tcl command")

    def splitlist(self, s):
        if isinstance(s, tuple):
            return s
        if isinstance(s, list):
            return tuple(s)
        if isinstance(s, str):
            return tuple(split_list(s))
        if isinstance(s, (int, float)):
            return (s,)
        return tuple(split_list(tcl_str(s)))

    def split(self, s):
        if isinstance(s, (tuple, list)):
            return tuple([self.split(x) if isinstance(x, str) and " " in x else x for x in s])
        items = split_list(tcl_str(s))
        if len(items) == 1 and items[0] == tcl_str(s):
            return s
        return tuple([self.split(x) for x in items])

    def getint(self, s):
        if isinstance(s, bool):
            return int(s)
        if isinstance(s, int):
            return s
        if isinstance(s, float):
            raise TclError("expected integer but got \"" + tcl_float(s) + "\"")
        return get_int(s)

    def getdouble(self, s):
        if isinstance(s, (int, float)) and not isinstance(s, bool):
            return float(s)
        return get_double(s)

    def getboolean(self, s):
        if isinstance(s, bool):
            return s
        if isinstance(s, int):
            return s != 0
        return get_boolean(s)

    def exprstring(self, s):
        from _tkinter.tcl import expr
        return tcl_str(expr(self.interp, s))

    def exprlong(self, s):
        from _tkinter.tcl import expr
        return int(expr(self.interp, s))

    def exprdouble(self, s):
        from _tkinter.tcl import expr
        return float(expr(self.interp, s))

    def exprboolean(self, s):
        from _tkinter.tcl import expr, _truth
        return 1 if _truth(expr(self.interp, s)) else 0

    def interpaddr(self):
        return id(self)

    def willdispatch(self):
        pass

    def record(self, script):
        return self.eval(script)

    def adderrorinfo(self, msg):
        self.vars["errorInfo"] = tcl_str(self.vars.get("errorInfo", "")) + msg

    def createfilehandler(self, file, mask, func):
        raise TclError("createfilehandler is not supported by Nython's Tk")

    def deletefilehandler(self, file):
        pass

    def createtimerhandler(self, ms, func):
        name = "::tk::timer" + str(id(func))
        self.createcommand(name, func)
        return self.c_after([ms, name])

    def loadtk(self):
        if not self.tk_loaded:
            self.load_tk()

    # ── Tk start-up ──────────────────────────────────────────────────────
    def load_tk(self):
        drv = gui_video_driver()
        if drv == "":
            raise TclError("no display name and no $DISPLAY environment variable")
        self.tk_loaded = True
        self.vars["tk_version"] = TK_VERSION
        self.vars["tk_patchLevel"] = TK_PATCHLEVEL
        self.vars["tk_library"] = "/nython/lib/tk8.6"
        self.vars["tk_strictMotif"] = 0
        try:
            ds = gui_get_display_size()
            SCREEN.width = ds[0]
            SCREEN.height = ds[1]
        except Exception:
            pass
        try:
            sc = gui_display_scale()
            set_dpi(96.0 * (sc if sc > 0 else 1.0))
        except Exception:
            pass
        self._init_fonts()
        cls = WIDGET_TYPES["toplevel"]
        root = cls(self, ".", None, self.classname)
        self.root = root
        self.widgets["."] = root
        self.interp.commands["."] = lambda it, words: root.command(words[1:])
        root.init_options()
        root.created()
        self.toplevels.append(root)
        self.relayout()
        self._init_bindings()
        for f in APP_INIT:
            f(self)

    def _init_fonts(self):
        fam = "sans-serif"
        fix = "monospace"
        nf = self.named_fonts

        def f(name, family, size, weight="normal"):
            nf[name] = {"family": family, "size": size, "weight": weight, "slant": "roman", "underline": 0, "overstrike": 0}

        f("TkDefaultFont", fam, -12)
        f("TkTextFont", fam, -12)
        f("TkHeadingFont", fam, -12, "bold")
        f("TkCaptionFont", fam, -14, "bold")
        f("TkTooltipFont", fam, -10)
        f("TkFixedFont", fix, -12)
        f("TkIconFont", fam, -12)
        f("TkMenuFont", fam, -12)
        f("TkSmallCaptionFont", fam, -12)

    def _init_bindings(self):
        b = self.bindings
        ws = windowing_system()
        for v, seqs in (("Cut", ["<Control-Key-x>", "<Key-F20>"]), ("Copy", ["<Control-Key-c>", "<Key-F16>"]),
                        ("Paste", ["<Control-Key-v>", "<Key-F18>"]), ("PasteSelection", ["<ButtonRelease-2>"]),
                        ("Undo", ["<Control-Key-z>"]), ("Redo", ["<Control-Key-Z>", "<Control-Key-y>"]),
                        ("ContextMenu", ["<Button-3>"]), ("SelectAll", ["<Control-Key-slash>"]),
                        ("SelectNone", ["<Control-Key-backslash>"]), ("NextChar", ["<Right>", "<Control-Key-f>"]),
                        ("SelectNextChar", ["<Shift-Right>"]), ("PrevChar", ["<Left>", "<Control-Key-b>"]),
                        ("SelectPrevChar", ["<Shift-Left>"]), ("NextWord", ["<Control-Right>"]),
                        ("SelectNextWord", ["<Control-Shift-Right>"]), ("PrevWord", ["<Control-Left>"]),
                        ("SelectPrevWord", ["<Control-Shift-Left>"]), ("LineStart", ["<Home>", "<Control-Key-a>"]),
                        ("SelectLineStart", ["<Shift-Home>"]), ("LineEnd", ["<End>", "<Control-Key-e>"]),
                        ("SelectLineEnd", ["<Shift-End>"]), ("PrevLine", ["<Up>", "<Control-Key-p>"]),
                        ("NextLine", ["<Down>", "<Control-Key-n>"]),
                        ("SelectPrevLine", ["<Shift-Up>"]), ("SelectNextLine", ["<Shift-Down>"]),
                        ("PrevPara", ["<Control-Up>"]), ("NextPara", ["<Control-Down>"]),
                        ("SelectPrevPara", ["<Control-Shift-Up>"]), ("SelectNextPara", ["<Control-Shift-Down>"]),
                        ("ToggleSelection", ["<Control-Button-1>"]), ("PrevWindow", ["<Shift-Tab>", "<ISO_Left_Tab>"])):
            b.event_add(v, seqs)
        b.set("all", "<Tab>", "tk::TabToWindow [tk_focusNext %W]")
        b.set("all", "<<PrevWindow>>", "tk::TabToWindow [tk_focusPrev %W]")
        self.interp.commands["tk::TabToWindow"] = lambda it, w: self.tab_to_window(tcl_str(w[1]))

    def tab_to_window(self, path):
        w = self.widgets.get(path)
        if w is None:
            return ""
        hook = getattr(w, "traverse_in", None)
        if hook is not None:
            hook()
        self.set_focus(w)
        return ""

    # ── windows ──────────────────────────────────────────────────────────
    def window(self, path):
        p = tcl_str(path)
        w = self.widgets.get(p)
        if w is None or w.destroyed:
            raise TclError("bad window path name \"" + p + "\"")
        return w

    def nametowin(self, path):
        return self.widgets.get(tcl_str(path))

    def parent_of(self, path):
        if not path.startswith(".") or path == ".":
            raise TclError("bad window path name \"" + path + "\"")
        k = path.rfind(".")
        ppath = path[:k] if k > 0 else "."
        name = path[k + 1:]
        if name == "":
            raise TclError("bad window path name \"" + path + "\"")
        parent = self.widgets.get(ppath)
        if parent is None:
            raise TclError("bad window path name \"" + path + "\"")
        if path in self.widgets:
            raise TclError("window name \"" + name + "\" already exists in parent")
        if name[0].isupper():
            raise TclError("window name starts with an upper-case letter: \"" + name + "\"")
        return parent

    def create_widget(self, cmdname, args):
        if not self.tk_loaded or self.root is None:
            raise TclError("invalid command name \"" + cmdname + "\"")
        if len(args) < 1:
            raise TclError("wrong # args: should be \"" + cmdname + " pathName ?-option value ...?\"")
        path = tcl_str(args[0])
        cls = WIDGET_TYPES[cmdname]
        parent = self.parent_of(path)
        rest = list(args[1:])
        wclass = None
        k = 0
        while k + 1 < len(rest):
            if tcl_str(rest[k]) == "-class" and "class" in option_names(cls):
                wclass = tcl_str(rest[k + 1])
            k += 2
        w = cls(self, path, parent, wclass)
        self.widgets[path] = w
        parent.children.append(w)
        self.interp.commands[path] = lambda it, words: w.command(words[1:])
        try:
            w.init_options()
            if wclass is not None and "class" in w.opts:
                w.opts["class"] = wclass
            w.configure_pairs(rest, True)
            w.created()
        except TclError:
            self.destroy_window(w)
            raise
        if w.IS_TOPLEVEL and not getattr(w, "IS_MENU", False):
            self.toplevels.append(w)
        self.relayout()
        return path

    def destroy_window(self, w):
        if w.destroyed:
            return
        for c in list(w.children):
            self.destroy_window(c)
        w.dying = True
        ev = XEvent(B.DestroyNotify, w)
        self.handle_event(ev)
        try:
            w.on_destroy()
        except TclError:
            pass
        if w.manager != "":
            G.unmanage(self, w)
        for s in list(w.pack_slaves) + list(w.grid_slaves) + list(w.place_slaves):
            G.unmanage(self, s)
        hook = getattr(w, "forget_all_slaves", None)
        if hook is not None:
            hook()
        w.unlink_vars()
        self.bindings.delete_tag(w.path)
        if w.path in self.interp.commands:
            del self.interp.commands[w.path]
        if w.path in self.widgets:
            del self.widgets[w.path]
        if w.parent is not None and w in w.parent.children:
            w.parent.children.remove(w)
        if self.focus is w or (self.focus is not None and self.focus.destroyed):
            self.focus = None
            if w.top is not w and not w.top.destroyed:
                self.focus = w.top
        if getattr(w.top, "focus_last", None) is w:
            w.top.focus_last = None
        if self.grab is w:
            self.grab = None
        if self.pointer_win is w:
            self.pointer_win = w.parent if w.parent is not None and not w.IS_TOPLEVEL else None
        if self.button_grab is w:
            self.button_grab = None
        for owner in list(self.selection.keys()):
            if self.selection[owner] is w:
                del self.selection[owner]
        w.destroyed = True
        w.mapped = False
        if w.IS_TOPLEVEL:
            if w in self.toplevels:
                self.toplevels.remove(w)
            self.destroy_native(w)
        elif not w.top.destroyed:
            self.damage(w.top)
        if w is self.root:
            for t in list(self.toplevels):
                self.destroy_window(t)
            self.root = None
            self.tk_loaded = False
            for name in list(self.interp.commands.keys()):
                if name.startswith("."):
                    del self.interp.commands[name]

    def destroy_native(self, top):
        if top.native is not None:
            h = top.native
            top.native = None
            if h in self.natives:
                del self.natives[h]
            gui_destroy_window(h)
            # the backend shuts SDL down with its last window: bring it back
            # up for the fonts while this application lives
            if not self.natives and self.root is not None and top is not self.root:
                gui_video_driver()
            if not self.natives:
                still = False
                for a in _APPS:
                    if a.natives:
                        still = True
                if not still:
                    gui_video_driver()

    def ensure_native(self, top):
        if top.native is None:
            wm = top.wm
            flags = 1 if (wm.resizable[0] or wm.resizable[1]) else 0
            if wm.override:
                flags |= 2
            if wm.attributes.get("-topmost"):
                flags |= 4
            mh = top.menubar_height()
            x = wm.ux if wm.ux is not None else -1
            y = wm.uy if wm.uy is not None else -1
            title = self.wm_title(top)
            h = gui_create_window(title, x, y, max(1, top.width), max(1, top.height + mh), flags)
            if h is None:
                raise TclError("couldn't create window: " + gui_get_error())
            top.native = h
            wm.native_size = (max(1, top.width), max(1, top.height + mh))
            self.natives[h] = top
            self.damage(top)

    def wm_title(self, top):
        t = top.wm.title
        if t is None:
            return top.name
        return t

    # ── geometry ─────────────────────────────────────────────────────────
    def relayout(self):
        if self.in_layout:
            self.layout_dirty = True
            return
        if not self.layout_queued:
            self.layout_queued = True
            self.idle_q.append(("layout", None, None))

    def damage(self, top):
        if top is None or top.destroyed:
            return
        if top not in self.damaged:
            self.damaged.append(top)
        if not self.redisplay_queued:
            self.redisplay_queued = True
            self.idle_q.append(("redisplay", None, None))

    def compute_requests(self, w):
        for c in w.children:
            if not c.IS_TOPLEVEL and not c.destroyed:
                self.compute_requests(c)
        if w.pack_slaves and w.pack_prop:
            rw, rh = G.pack_request(w)
            w.request(rw, rh)
        elif w.grid_slaves and w.grid_prop:
            rw, rh = G.grid_request(w)
            if rw > 1 and rh > 1:
                w.request(rw, rh)
            else:
                w.request(rw, rh)
        hook = getattr(w, "request_from_slaves", None)
        if hook is not None:
            hook()

    def arrange(self, w):
        if w.pack_slaves:
            G.pack_arrange(self, w)
        if w.grid_slaves:
            G.grid_arrange(self, w)
        if w.place_slaves:
            G.place_arrange(self, w)
        hook = getattr(w, "arrange_slaves", None)
        if hook is not None:
            hook()
        for c in list(w.children):
            if not c.IS_TOPLEVEL and not c.destroyed:
                self.arrange(c)

    def place_slave(self, master, s, x, y, w, h, placer=False):
        # Tk_MoveResizeWindow / Tk_MaintainGeometry + map/unmap as the
        # managers do it; (x, y) are relative to `master`
        if s.destroyed:
            return
        if master is not s.parent:
            m = master
            while m is not s.parent and m is not None:
                x += m.x
                y += m.y
                m = m.parent
        if (w <= 0 or h <= 0) and not placer:
            self.set_mapped(s, False)
            return
        self.move_resize(s, x, y, w, h)
        if master.mapped and (master is s.parent or self._chain_mapped(master, s.parent)):
            self.set_mapped(s, True)

    def _chain_mapped(self, m, stop):
        while m is not None and m is not stop:
            if not m.mapped:
                return False
            m = m.parent
        return True

    def move_resize(self, s, x, y, w, h):
        if x != s.x or y != s.y or w != s.width or h != s.height:
            resized = (w != s.width or h != s.height)
            s.x = x
            s.y = y
            s.width = w
            s.height = h
            ev = XEvent(B.ConfigureNotify, s)
            ev.x = x
            ev.y = y
            ev.width = w
            ev.height = h
            self.struct_q.append(ev)
            if resized:
                s.on_resize()
            self.damage(s.top)

    def set_mapped(self, w, flag):
        if w.mapped != flag:
            w.mapped = flag
            ev = XEvent(B.MapNotify if flag else B.UnmapNotify, w)
            self.struct_q.append(ev)
            if not w.destroyed:
                self.damage(w.top)

    def do_layout(self):
        self.layout_queued = False
        self.in_layout = True
        try:
            for it in range(40):
                self.layout_dirty = False
                tops = [t for t in self.toplevels if not t.destroyed]
                for top in tops:
                    self.compute_requests(top)
                for top in tops:
                    self.apply_wm(top)
                    if not top.destroyed:
                        self.arrange(top)
                q = self.struct_q
                self.struct_q = []
                self.in_layout = False
                for ev in q:
                    if not ev.window.destroyed:
                        self.handle_event(ev)
                self.in_layout = True
                if not self.layout_dirty and not self.struct_q:
                    break
        finally:
            self.in_layout = False
        if self.layout_dirty:
            self.layout_dirty = False
            self.relayout()

    def apply_wm(self, top):
        wm = top.wm
        w = wm.user_w if wm.user_w is not None else top.reqw
        h = wm.user_h if wm.user_h is not None else top.reqh
        if wm.state == "zoomed" or wm.attributes.get("-fullscreen") or wm.attributes.get("-zoomed"):
            w = SCREEN.width
            h = SCREEN.height - top.menubar_height()
        maxw = wm.maxw if wm.maxw is not None else SCREEN.width
        maxh = wm.maxh if wm.maxh is not None else SCREEN.height
        w = max(wm.minw, min(w, maxw)) if maxw > 0 else max(wm.minw, w)
        h = max(wm.minh, min(h, maxh)) if maxh > 0 else max(wm.minh, h)
        if w <= 0:
            w = 1
        if h <= 0:
            h = 1
        if wm.map_pending and wm.state == "normal":
            wm.map_pending = False
            if top.x == 0 and top.y == 0 and wm.ux is None:
                top.x = max(0, (SCREEN.width - w) // 2)
                top.y = max(0, (SCREEN.height - h) // 2)
            if wm.ux is not None:
                top.x = wm.ux
            if wm.uy is not None:
                top.y = wm.uy
            top.width = w
            top.height = h
            self.ensure_native(top)
            wm.ever_mapped = True
            self.set_mapped(top, True)
            ev = XEvent(B.ConfigureNotify, top)
            ev.x = top.x
            ev.y = top.y
            ev.width = w
            ev.height = h
            self.struct_q.append(ev)
            top.on_resize()
            if self.focus is None and self.app_has_focus:
                self.set_focus(getattr(top, "focus_last", None) or top)
            return
        if w != top.width or h != top.height:
            top.width = w
            top.height = h
            ev = XEvent(B.ConfigureNotify, top)
            ev.x = top.x
            ev.y = top.y
            ev.width = w
            ev.height = h
            self.struct_q.append(ev)
            top.on_resize()
            self.damage(top)
        if top.native is not None:
            want = (max(1, top.width), max(1, top.height + top.menubar_height()))
            if wm.native_size != want:
                wm.native_size = want
                gui_set_window_size(top.native, want[0], want[1])

    def map_toplevel(self, top):
        wm = top.wm
        wm.state = "normal"
        if not top.mapped:
            wm.map_pending = True
            self.relayout()

    def unmap_toplevel(self, top, state):
        wm = top.wm
        wm.state = state
        wm.map_pending = False
        if top.mapped:
            self.set_mapped(top, False)
            self.destroy_native(top)
            if self.focus is not None and self.focus.top is top:
                self.focus = None
        self.relayout()

    # ── idle, timers and the event loop ──────────────────────────────────
    def after_id(self):
        n = self.after_n
        self.after_n += 1
        return "after#" + str(n)

    def run_idle(self):
        if not self.idle_q:
            return False
        q = self.idle_q
        self.idle_q = []
        for kind, ident, script in q:
            if kind == "layout":
                self.do_layout()
            elif kind == "redisplay":
                self.redisplay()
            elif kind == "py":
                self.idle_once.discard(ident)
                script()
            else:
                if ident in self.after_info:
                    del self.after_info[ident]
                    self.eval_bg(script)
        return True

    def run_timers(self):
        if not self.timers:
            return False
        now = _now_ms()
        due = [t for t in self.timers if t[0] <= now]
        if not due:
            return False
        due.sort()
        ran = False
        for t in due:
            if t in self.timers:
                self.timers.remove(t)
            ident = t[2]
            if ident in self.after_info:
                del self.after_info[ident]
                ran = True
                self.eval_bg(t[3])
        return ran

    def next_timer_ms(self):
        if not self.timers:
            return None
        now = _now_ms()
        return max(0, min([t[0] for t in self.timers]) - now)

    def eval_bg(self, script):
        # a script run from the event loop: errors go to bgerror
        try:
            return self.interp.eval(script)
        except TclError as e:
            self.bgerror(str(e))
        except (_Break, _Continue):
            pass
        except _Return as r:
            return r.value
        return ""

    def bgerror(self, msg):
        h = self.interp.commands.get("bgerror")
        if h is not None and h is not self._default_bgerror_cmd():
            try:
                self.interp.invoke(["bgerror", msg])
                return
            except TclError:
                pass
        sys.stderr.write("Tcl/Tk background error: " + msg + "\n")

    def _default_bgerror_cmd(self):
        return None

    def c_bgerror(self, args):
        sys.stderr.write("Tcl/Tk background error: " + (tcl_str(args[0]) if args else "") + "\n")
        return ""

    def has_windows(self):
        return self.root is not None and not self.root.destroyed

    def pump_native(self, wait_ms):
        if not self.natives:
            if wait_ms > 0:
                time.sleep(min(wait_ms, 20) / 1000.0)
            return False
        if wait_ms > 0:
            evs = gui_wait_events(-1, wait_ms)
        else:
            evs = gui_poll_events(-1)
        n = len(evs)
        if n == 0:
            return False
        i = 0
        while i < n:
            e = evs[i]
            nxt = evs[i + 1] if i + 1 < n else None
            consumed = self.native_event(e, nxt)
            i += 2 if consumed else 1
        return True

    def do_one_event(self, flags=0):
        if flags & ~DONT_WAIT == 0:
            flags |= WINDOW_EVENTS | TIMER_EVENTS | IDLE_EVENTS | FILE_EVENTS
        if flags & WINDOW_EVENTS:
            if self.event_queue:
                ev = self.event_queue.pop(0)
                if not ev.window.destroyed:
                    self.handle_event(ev)
                return True
            if self.pump_native(0):
                return True
        if flags & TIMER_EVENTS:
            if self.run_timers():
                return True
        if flags & IDLE_EVENTS:
            if self.run_idle():
                return True
        if flags & DONT_WAIT:
            return False
        wait = self.next_timer_ms()
        if wait is None or wait > 30:
            wait = 30
        if wait <= 0:
            return self.run_timers()
        if flags & WINDOW_EVENTS:
            if self.pump_native(wait):
                return True
            return self.run_timers()
        time.sleep(wait / 1000.0)
        return self.run_timers()

    def update(self, idletasks=False):
        if idletasks:
            guard = 0
            while self.idle_q and guard < 100:
                guard += 1
                self.run_idle()
            return
        guard = 0
        while guard < 10000:
            guard += 1
            if not self.do_one_event(DONT_WAIT):
                break

    def mainloop(self, threshold=0):
        self.quit_flag = False
        while not self.quit_flag and self.has_windows():
            self.do_one_event(0)
        self.quit_flag = False

    def dooneevent(self, flags=0):
        return 1 if self.do_one_event(flags) else 0

    def quit(self):
        self.quit_flag = True

    def wait_until(self, cond):
        # tkwait / vwait: a nested event loop until cond() is true
        while not cond():
            if not self.do_one_event(0) and not self.has_windows():
                if not cond() and not self.timers and not self.idle_q:
                    raise TclError("can't wait: would wait forever")

    # ── events from the backend ──────────────────────────────────────────
    def top_of_event(self, e):
        wid = e.get("window", 0)
        if wid and wid in self.natives:
            return self.natives[wid]
        if len(self.natives) == 1:
            for k in self.natives:
                return self.natives[k]
        if self.root is not None and self.root.native is not None:
            return self.root
        for k in self.natives:
            return self.natives[k]
        return None

    def _state_from(self, e):
        s = 0
        if e.get("shift", False):
            s |= B.ShiftMask
        if e.get("ctrl", False):
            s |= B.ControlMask
        if e.get("alt", False):
            s |= B.ALT_MASK
        if e.get("meta", False):
            s |= B.META_MASK
        self.mods = s
        return s | self.buttons

    def native_event(self, e, nxt):
        # returns True when it consumed `nxt` too (a key press's text)
        t = e["type"]
        top = self.top_of_event(e)
        if t == "textedit":
            txt = e.get("text", "")
            if txt.startswith("__nysync_"):
                self.sync_seen.add(txt)
            return False
        if t == "quit":
            self.last_input = _now_ms()
            target = top if (e.get("window", 0) and top is not None) else self.root
            if target is None and top is not None:
                target = top
            if target is not None:
                self.wm_delete(target)
            return False
        if top is None or top.destroyed:
            return False
        if t == "resize":
            mh = top.menubar_height()
            w = e.get("w", 0)
            h = e.get("h", 0) - mh
            if top.wm.native_size == (e.get("w", 0), e.get("h", 0)):
                return False
            top.wm.native_size = (e.get("w", 0), e.get("h", 0))
            top.wm.user_w = max(1, w)
            top.wm.user_h = max(1, h)
            self.relayout()
            self.damage(top)
            return False
        if t == "expose":
            self.damage(top)
            ev = XEvent(B.Expose, top)
            ev.width = top.width
            ev.height = top.height
            self.handle_event(ev)
            return False
        if t == "focusgained":
            self.app_has_focus = True
            w = getattr(top, "focus_last", None) or top
            self.set_focus(w, True)
            return False
        if t == "focuslost":
            self.app_has_focus = False
            old = self.focus
            if old is not None:
                self.focus = None
                self._focus_events(old, None)
            return False
        if t == "dialog":
            if self.dialog_waiter is not None:
                self.dialog_waiter.append((e.get("button", 0), e.get("text", "")))
            return False
        self.last_input = _now_ms()
        if t == "mousemove":
            self.pointer_motion(top, e["x"], e["y"], self._state_from(e))
            return False
        if t == "mousedown" or t == "mouseup":
            self.pointer_button(top, e["x"], e["y"], e["button"], t == "mousedown", self._state_from(e))
            return False
        if t == "wheel":
            self.pointer_wheel(top, e["x"], e["y"], e.get("delta", 0), e.get("dx", 0.0), e.get("dy", 0.0), self._state_from(e))
            return False
        if t == "mouseleave":
            self.pointer_leave(top)
            return False
        if t == "keydown" or t == "keyup":
            st = self._state_from(e)
            ch = None
            used = False
            if t == "keydown" and nxt is not None and nxt["type"] == "textinput":
                ch = nxt.get("text", "")
                used = True
            self.key_event(top, e.get("key", ""), e.get("keycode", 0), ch, t == "keydown", st)
            return used
        if t == "textinput":
            for c in e.get("text", ""):
                self.key_event(top, "", 0, c, True, self.mods)
                self.key_event(top, "", 0, c, False, self.mods)
            return False
        if t == "dropfile" or t == "droptext":
            w = self.window_at(top, e.get("x", 0), e.get("y", 0) - top.menubar_height())
            ev = XEvent(B.VirtualEvent, w)
            ev.name = "DropFile" if t == "dropfile" else "DropText"
            ev.data = e.get("text", "")
            ev.x, ev.y = e.get("x", 0), e.get("y", 0)
            self.handle_event(ev)
            return False
        if t == "scale":
            return False
        return False

    def window_at(self, top, x, y):
        # deepest mapped window of `top` containing (x, y), toplevel-relative
        hit = top.overlay_at(x, y) if hasattr(top, "overlay_at") else None
        if hit is not None:
            return hit
        w = top
        ox = 0
        oy = 0
        while True:
            found = None
            for c in reversed(w.children):
                if c.IS_TOPLEVEL or not c.mapped or c.destroyed:
                    continue
                cx = x - ox - c.x
                cy = y - oy - c.y
                if 0 <= cx < c.width and 0 <= cy < c.height:
                    found = c
                    break
            if found is None:
                return w
            ox += found.x
            oy += found.y
            w = found

    def _rel(self, w, top, x, y):
        # (x, y) in `top`'s coordinates -> relative to w
        ax, ay = w.abs_xy()
        return x - ax, y - (ay - top.menubar_height())

    def _base_event(self, type, w, top, x, y, state):
        ev = XEvent(type, w)
        rx, ry = self._rel(w, top, x, y)
        ev.x = rx
        ev.y = ry
        ev.x_root = top.x + x
        ev.y_root = top.y + y + top.menubar_height()
        ev.state = state
        ev.time = _now_ms()
        return ev

    def grab_allows(self, w):
        g = self.grab
        if g is None or g.destroyed:
            return True
        return g.is_ancestor_of(w)

    def pointer_motion(self, top, nx, ny, state):
        mh = top.menubar_height()
        x = nx
        y = ny - mh
        self.pointer_root = (top.x + nx, top.y + ny)
        if y < 0 and mh > 0 and self.button_grab is None:
            top.menubar_event("motion", nx, ny, 0, state)
            self.update_pointer(top, None, x, y, state)
            return
        under = self.window_at(top, x, y)
        if self.button_grab is not None:
            g = self.button_grab
            inside = (under is g) or g.is_ancestor_of(under)
            # crossing events for the grab window only
            if inside and self.pointer_win is not g and not (self.pointer_win is not None and g.is_ancestor_of(self.pointer_win)):
                self._crossing(None, g, top, x, y, state, "NotifyNormal")
                self.pointer_win = g
            elif not inside and self.pointer_win is not None and (self.pointer_win is g or g.is_ancestor_of(self.pointer_win)):
                self._crossing(g, None, top, x, y, state, "NotifyNormal")
                self.pointer_win = None
            ev = self._base_event(B.MotionNotify, g, top, x, y, state)
            self.handle_event(ev)
            return
        self.update_pointer(top, under, x, y, state)
        if under is not None and self.grab_allows(under):
            ev = self._base_event(B.MotionNotify, under, top, x, y, state)
            self.handle_event(ev)

    def update_pointer(self, top, under, x, y, state):
        old = self.pointer_win
        if old is under:
            return
        if old is not None and old.destroyed:
            old = None
        self.pointer_win = under
        self.pointer_top = top
        self._crossing(old, under, top, x, y, state, "NotifyNormal")

    def _crossing(self, old, new, top, x, y, state, mode):
        # Leave/Enter along the hierarchy with X's details
        def chain(w):
            out = []
            while w is not None:
                out.append(w)
                if w.IS_TOPLEVEL:
                    break
                w = w.parent
            return out

        oc = chain(old) if old is not None else []
        nc = chain(new) if new is not None else []
        common = None
        for w in oc:
            if w in nc:
                common = w
                break
        evs = []
        if old is not None and old.top is not (new.top if new is not None else None):
            common = None
        if common is old and old is not None and new is not None:
            evs.append((B.LeaveNotify, old, "NotifyInferior"))
            mid = []
            for w in nc[1:]:
                if w is old:
                    break
                mid.append(w)
            for w in reversed(mid):
                evs.append((B.EnterNotify, w, "NotifyVirtual"))
            evs.append((B.EnterNotify, new, "NotifyAncestor"))
        elif common is new and new is not None and old is not None:
            evs.append((B.LeaveNotify, old, "NotifyAncestor"))
            for w in oc[1:]:
                if w is new:
                    break
                evs.append((B.LeaveNotify, w, "NotifyVirtual"))
            evs.append((B.EnterNotify, new, "NotifyInferior"))
        else:
            if old is not None:
                evs.append((B.LeaveNotify, old, "NotifyNonlinear"))
                for w in oc[1:]:
                    if w is common:
                        break
                    evs.append((B.LeaveNotify, w, "NotifyNonlinearVirtual"))
            if new is not None:
                mid = []
                for w in nc[1:]:
                    if w is common:
                        break
                    mid.append(w)
                for w in reversed(mid):
                    evs.append((B.EnterNotify, w, "NotifyNonlinearVirtual"))
                evs.append((B.EnterNotify, new, "NotifyNonlinear"))
        for typ, w, detail in evs:
            if w.destroyed:
                continue
            if not self.grab_allows(w) and self.grab is not None:
                continue
            ev = self._base_event(typ, w, w.top if w.top is not None else top, x, y, state)
            ev.detail = detail
            ev.mode = mode
            ev.focus = 1 if (self.focus is not None and self.focus.top is w.top) else 0
            self.handle_event(ev)

    def pointer_leave(self, top):
        if self.pointer_win is not None and self.button_grab is None:
            old = self.pointer_win
            self.pointer_win = None
            self._crossing(old, None, top, -1, -1, self.mods | self.buttons, "NotifyNormal")
        top.menubar_event("leave", -1, -1, 0, 0)

    def pointer_button(self, top, nx, ny, button, down, state):
        mh = top.menubar_height()
        x = nx
        y = ny - mh
        self.pointer_root = (top.x + nx, top.y + ny)
        mask = B.Button1Mask << (button - 1) if 1 <= button <= 5 else 0
        if self.button_grab is None and y < 0 and mh > 0:
            top.menubar_event("down" if down else "up", nx, ny, button, state)
            return
        if down:
            under = self.window_at(top, x, y)
            if self.button_grab is None:
                if not self.grab_allows(under):
                    self.update_pointer(top, under, x, y, state)
                    return
                self.update_pointer(top, under, x, y, state)
                self.button_grab = under
            target = self.button_grab
            ev = self._base_event(B.ButtonPress, target, top, x, y, state & ~mask)
            ev.button = button
            self.buttons |= mask
            self.handle_event(ev)
        else:
            target = self.button_grab
            if target is None or target.destroyed:
                target = self.window_at(top, x, y)
                if not self.grab_allows(target):
                    self.buttons &= ~mask
                    return
            ev = self._base_event(B.ButtonRelease, target, top, x, y, state | mask)
            ev.button = button
            self.buttons &= ~mask
            self.handle_event(ev)
            if self.buttons == 0:
                self.button_grab = None
                under = self.window_at(top, x, y) if not top.destroyed else None
                if under is not self.pointer_win:
                    old = self.pointer_win
                    self.pointer_win = under
                    if old is not None and old.destroyed:
                        old = None
                    self._crossing(old, under, top, x, y, state & ~mask, "NotifyUngrab")

    def pointer_wheel(self, top, nx, ny, delta, dx, dy, state):
        mh = top.menubar_height()
        x = nx
        y = ny - mh
        under = self.button_grab if self.button_grab is not None else self.window_at(top, x, y)
        if not self.grab_allows(under):
            return
        steps = delta if delta != 0 else (1 if dy > 0 else (-1 if dy < 0 else 0))
        if windowing_system() == "x11":
            btn = 4 if steps > 0 else 5
            if state & B.ShiftMask:
                btn = 6 if steps > 0 else 7
            for k in range(abs(steps)):
                ev = self._base_event(B.ButtonPress, under, top, x, y, state)
                ev.button = btn
                self.handle_event(ev)
                ev = self._base_event(B.ButtonRelease, under, top, x, y, state | (B.Button1Mask << (btn - 1) if btn <= 5 else 0))
                ev.button = btn
                self.handle_event(ev)
        else:
            ev = self._base_event(B.MouseWheelEvent, under, top, x, y, state)
            ev.delta = 120 * steps
            self.handle_event(ev)

    def key_event(self, top, key, keycode, ch, down, state):
        if key in _KEYNAMES:
            ks, kch = _KEYNAMES[key]
            if not ch:
                ch = kch
        elif key != "" and not ch:
            c = key if len(key) == 1 else ""
            if c != "" and (state & B.ShiftMask):
                if c.isalpha():
                    c = c.upper()
                else:
                    c = _UNSHIFTED.get(c, c)
            ch = c
            ks = _char_keysym(c) if c != "" else key
        else:
            if ch is None:
                ch = ""
            ks = _char_keysym(ch) if len(ch) == 1 else (key if key != "" else "")
        if ch is None:
            ch = ""
        if state & B.ControlMask and len(ch) == 1 and ch.isalpha() and ord(ch) < 128:
            ch = chr(ord(ch.lower()) - 96)
        target = self.focus if (self.focus is not None and not self.focus.destroyed and self.focus.top is top) else None
        if target is None:
            target = getattr(top, "focus_last", None)
            if target is None or target.destroyed:
                target = top
        if self.grab is not None and not self.grab.destroyed and not self.grab.is_ancestor_of(target):
            target = self.grab
        if hasattr(top, "key_hook") and top.key_hook(ks, down, state):
            return
        ev = XEvent(B.KeyPress if down else B.KeyRelease, target)
        ax, ay = target.abs_xy()
        ev.x = self.pointer_root[0] - top.x - ax
        ev.y = self.pointer_root[1] - top.y - ay
        ev.x_root = self.pointer_root[0]
        ev.y_root = self.pointer_root[1]
        ev.state = state
        ev.keysym = ks
        n = keysym_number(ks)
        ev.keysym_num = n if n is not None else 0
        ev.char = ch
        ev.keycode = xkeycode(ks)
        ev.time = _now_ms()
        self.handle_event(ev)

    # ── focus ────────────────────────────────────────────────────────────
    def set_focus(self, w, force=False):
        if w is None or w.destroyed:
            return
        w.top.focus_last = w
        old = self.focus
        if old is w:
            return
        if not self.app_has_focus and not force:
            return
        self.focus = w
        self._focus_events(old, w)

    def _focus_events(self, old, new):
        def chain(w):
            out = []
            while w is not None:
                out.append(w)
                if w.IS_TOPLEVEL:
                    break
                w = w.parent
            return out

        oc = chain(old) if old is not None and not old.destroyed else []
        nc = chain(new) if new is not None else []
        common = None
        for w in oc:
            if w in nc:
                common = w
                break
        evs = []
        if oc and nc and common is old:
            evs.append((B.FocusOut, old, "NotifyInferior"))
            mid = []
            for w in nc[1:]:
                if w is old:
                    break
                mid.append(w)
            for w in reversed(mid):
                evs.append((B.FocusIn, w, "NotifyVirtual"))
            evs.append((B.FocusIn, new, "NotifyAncestor"))
        elif oc and nc and common is new:
            evs.append((B.FocusOut, old, "NotifyAncestor"))
            for w in oc[1:]:
                if w is new:
                    break
                evs.append((B.FocusOut, w, "NotifyVirtual"))
            evs.append((B.FocusIn, new, "NotifyInferior"))
        else:
            if oc:
                evs.append((B.FocusOut, old, "NotifyNonlinear"))
                for w in oc[1:]:
                    if w is common:
                        break
                    evs.append((B.FocusOut, w, "NotifyNonlinearVirtual"))
            if nc:
                mid = []
                for w in nc[1:]:
                    if w is common:
                        break
                    mid.append(w)
                for w in reversed(mid):
                    evs.append((B.FocusIn, w, "NotifyNonlinearVirtual"))
                evs.append((B.FocusIn, new, "NotifyNonlinear"))
        if old is not None:
            old.has_focus = False
            if not old.destroyed:
                old.damage()
        if new is not None:
            new.has_focus = True
            new.damage()
        for typ, w, detail in evs:
            if w.destroyed:
                continue
            ev = XEvent(typ, w)
            ev.detail = detail
            ev.mode = "NotifyNormal"
            ev.time = _now_ms()
            self.handle_event(ev)

    # ── dispatch ─────────────────────────────────────────────────────────
    def handle_event(self, ev):
        w = ev.window
        if w is None:
            return
        self.serial += 1
        ev.serial = self.serial
        if ev.type != B.VirtualEvent:
            self.ring.append(ev)
            if len(self.ring) > 30:
                self.ring = self.ring[-30:]
        if w.destroyed and ev.type != B.DestroyNotify:
            return
        w.on_event(ev)
        if w.destroyed and ev.type != B.DestroyNotify:
            return
        if self.busy.get(w.top.path if w.top is not None else "") and ev.type in (B.KeyPress, B.KeyRelease, B.ButtonPress, B.ButtonRelease, B.MotionNotify):
            return
        tags = w.get_bindtags()
        scripts = []
        for tag in tags:
            s = self.bindings.best_match(tag, self.ring, ev)
            if s is not None:
                scripts.append(s)
        for s in scripts:
            if w.destroyed and ev.type != B.DestroyNotify:
                break
            code = self.run_binding(s, ev)
            if code == "break":
                break

    def run_binding(self, script, ev):
        # tkinter's bindings are lines `if {"[funcid %# %b ...]" == "break"} break`:
        # those call the command directly with the substituted fields; any
        # other script is %-substituted and evaluated, as Tk does
        lines = script.split("\n")
        fast = []
        for ln in lines:
            if ln.strip() == "":
                continue
            m = _FAST_RE.match(ln)
            if m is None:
                fast = None
                break
            fast.append(m)
        if fast is None:
            try:
                self.interp.eval(expand_percents(script, ev))
            except _Break:
                return "break"
            except (_Continue, _Return):
                pass
            except TclError as e:
                self.bgerror(str(e))
            return ""
        for m in fast:
            name = m.group(1)
            cmd = self.interp.commands.get(name)
            if cmd is None:
                self.bgerror("invalid command name \"" + name + "\"")
                continue
            args = [name]
            for f in m.group(2).split(" "):
                if len(f) == 2 and f[0] == "%":
                    v = B.percent_value(f[1], ev)
                    args.append(v if isinstance(v, str) else str(v))
                elif f != "":
                    args.append(f)
            try:
                r = cmd(self.interp, args)
            except TclError as e:
                self.bgerror(str(e))
                continue
            if isinstance(r, str) and r == "break":
                return "break"
            if ev.window.destroyed and ev.type != B.DestroyNotify:
                break
        return ""

    # ── the option database ──────────────────────────────────────────────
    def option_add(self, pattern, value, priority=80):
        self.option_serial += 1
        elems = _parse_option_pattern(pattern)
        self.option_db.append((priority, self.option_serial, elems, value, pattern))

    def option_lookup(self, w, name, cls):
        if not self.option_db:
            return None
        chain = []
        x = w
        while x is not None:
            chain.append((x.name if x.path != "." else self.appname, x.wclass if x.path != "." else self.classname))
            x = x.parent
        chain.reverse()
        best = None
        for entry in self.option_db:
            prio, serial, elems, value, pat = entry
            if _option_match(elems, chain, name, cls):
                if best is None or (prio, serial) > (best[0], best[1]):
                    best = entry
        return best[3] if best is not None else None

    # ── fonts ────────────────────────────────────────────────────────────
    def font_of(self, desc):
        fa = parse_font_spec(desc, self.named_fonts)
        return font_from_attrs(fa)

    def all_widgets_changed(self, what):
        for w in list(self.widgets.values()):
            if not w.destroyed:
                w.reconfigured([what])
        self.relayout()

    # ── Tk commands ──────────────────────────────────────────────────────
    def c_exit(self, args):
        code = get_int(args[0]) if args else 0
        raise SystemExit(code)

    def c_after(self, args):
        if not args:
            raise TclError("wrong # args: should be \"after option ?arg ...?\"")
        a0 = tcl_str(args[0])
        try:
            ms = get_int(a0)
            if ms < 0:
                ms = 0
            if len(args) == 1:
                time.sleep(ms / 1000.0)
                return ""
            script = _concat(args[1:])
            ident = self.after_id()
            self.timer_seq += 1
            self.timers.append((_now_ms() + ms, self.timer_seq, ident, script))
            self.after_info[ident] = ("timer", script)
            return ident
        except TclError:
            pass
        sub = match_prefix(a0, ["cancel", "idle", "info"], "argument")
        if sub == "idle":
            script = _concat(args[1:])
            ident = self.after_id()
            self.after_info[ident] = ("idle", script)
            self.idle_q.append(("script", ident, script))
            return ident
        if sub == "cancel":
            if len(args) < 2:
                raise TclError("wrong # args: should be \"after cancel id|command\"")
            key = tcl_str(args[1]) if len(args) == 2 else _concat(args[1:])
            if key in self.after_info:
                self._cancel(key)
                return ""
            for ident in list(self.after_info.keys()):
                if self.after_info[ident][1] == key:
                    self._cancel(ident)
                    break
            return ""
        if len(args) == 1:
            return tuple(self.after_info.keys())
        ident = tcl_str(args[1])
        if ident not in self.after_info:
            raise TclError("event \"" + ident + "\" doesn't exist")
        kind, script = self.after_info[ident]
        return (script, kind)

    def _cancel(self, ident):
        del self.after_info[ident]
        self.timers = [t for t in self.timers if t[2] != ident]

    def c_update(self, args):
        if args and tcl_str(args[0]) == "idletasks":
            self.update(True)
        elif args:
            raise TclError("bad option \"" + tcl_str(args[0]) + "\": must be idletasks")
        else:
            self.update()
        return ""

    def c_vwait(self, args):
        name = tcl_str(args[-1])
        hit = [False]
        def watch(n, op):
            hit[0] = True
        link = self.add_link(name, watch)
        try:
            self.wait_until(lambda: hit[0])
        finally:
            self.remove_link(link)
        return ""

    def c_tkwait(self, args):
        if len(args) != 2:
            raise TclError("wrong # args: should be \"tkwait variable|visibility|window name\"")
        sub = match_prefix(tcl_str(args[0]), ["variable", "visibility", "window"], "option")
        if sub == "variable":
            return self.c_vwait([args[1]])
        w = self.window(args[1])
        if sub == "window":
            self.wait_until(lambda: w.destroyed)
        else:
            def vis():
                if w.destroyed:
                    raise TclError("window \"" + w.path + "\" was deleted before its visibility changed")
                return w.viewable()
            self.wait_until(vis)
        return ""

    def c_destroy(self, args):
        # Tk ignores names that are not (or no longer) windows
        for a in args:
            w = self.widgets.get(tcl_str(a))
            if w is not None and not w.destroyed:
                self.destroy_window(w)
        return ""

    def c_bell(self, args):
        self.bell_count += 1
        return ""

    def c_send(self, args):
        raise TclError("no application named \"" + (tcl_str(args[0]) if args else "") + "\"")

    def c_bind(self, args):
        if len(args) < 1 or len(args) > 3:
            raise TclError("wrong # args: should be \"bind window ?pattern? ?command?\"")
        tag = tcl_str(args[0])
        if tag.startswith("."):
            self.window(tag)
        if len(args) == 1:
            return tuple(self.bindings.sequences(tag))
        if len(args) == 2:
            return self.bindings.get(tag, tcl_str(args[1]))
        self.bindings.set(tag, tcl_str(args[1]), tcl_str(args[2]))
        return ""

    def c_bindtags(self, args):
        if len(args) < 1 or len(args) > 2:
            raise TclError("wrong # args: should be \"bindtags window ?taglist?\"")
        w = self.window(args[0])
        if len(args) == 1:
            return tuple(w.get_bindtags())
        tags = split_list(args[1]) if not isinstance(args[1], (tuple, list)) else [tcl_str(x) for x in args[1]]
        w.bindtags = tags if tags else None
        return ""

    def c_event(self, args):
        if not args:
            raise TclError("wrong # args: should be \"event option ?arg?\"")
        sub = match_prefix(tcl_str(args[0]), ["add", "delete", "generate", "info"], "option")
        if sub == "add":
            if len(args) < 3:
                raise TclError("wrong # args: should be \"event add virtual sequence ?sequence ...?\"")
            self.bindings.event_add(_virtual_name(args[1]), [tcl_str(a) for a in args[2:]])
            return ""
        if sub == "delete":
            if len(args) < 2:
                raise TclError("wrong # args: should be \"event delete virtual ?sequence ...?\"")
            self.bindings.event_delete(_virtual_name(args[1]), [tcl_str(a) for a in args[2:]])
            return ""
        if sub == "info":
            if len(args) == 1:
                return tuple(self.bindings.event_info())
            return tuple(self.bindings.event_info(_virtual_name(args[1])))
        return self.event_generate(args[1:])

    def event_generate(self, args):
        if len(args) < 2:
            raise TclError("wrong # args: should be \"event generate window event ?-option value ...?\"")
        w = self.window(args[0])
        seq = tcl_str(args[1])
        ps = B.parse_sequence(seq)
        if len(ps.pats) != 1 and not ps.nearby:
            raise TclError("Double, Triple, or Quadruple modifier not allowed")
        p = ps.pats[-1]
        ev = XEvent(p.type, w)
        ev.state = p.mods
        if p.type in (B.ButtonPress, B.ButtonRelease):
            ev.button = p.detail
        elif p.type in (B.KeyPress, B.KeyRelease):
            if p.detail:
                ev.keysym_num = p.detail
                ev.keysym = keysym_name(p.detail)
                ev.char = keysym_char(ev.keysym)
                ev.keycode = xkeycode(ev.keysym)
        elif p.type == B.VirtualEvent:
            ev.name = p.detail
        ev.time = _now_ms()
        ev.send_event = 0
        when = "now"
        warp = False
        rest = args[2:]
        if len(rest) % 2 != 0:
            raise TclError("value for \"" + tcl_str(rest[-1]) + "\" missing")
        rootx = None
        rooty = None
        for i in range(0, len(rest), 2):
            k = tcl_str(rest[i])
            v = rest[i + 1]
            k = match_prefix(k, ["-above", "-borderwidth", "-button", "-count", "-data", "-delta", "-detail",
                                 "-focus", "-height", "-keycode", "-keysym", "-mode", "-override", "-place",
                                 "-root", "-rootx", "-rooty", "-sendevent", "-serial", "-state", "-subwindow",
                                 "-time", "-warp", "-width", "-when", "-x", "-y"], "option")
            if k == "-when":
                when = match_prefix(tcl_str(v), ["now", "tail", "head", "mark"], "position")
            elif k == "-x":
                ev.x = pixels(v)
            elif k == "-y":
                ev.y = pixels(v)
            elif k == "-rootx":
                rootx = pixels(v)
            elif k == "-rooty":
                rooty = pixels(v)
            elif k == "-button":
                ev.button = get_int(v)
            elif k == "-keysym":
                ks = tcl_str(v)
                n = keysym_number(ks)
                if n is None:
                    raise TclError("unknown keysym \"" + ks + "\"")
                ev.keysym = ks
                ev.keysym_num = n
                ev.char = keysym_char(ks)
                ev.keycode = xkeycode(ks)
            elif k == "-keycode":
                ev.keycode = get_int(v)
            elif k == "-state":
                try:
                    ev.state = get_int(v)
                except TclError:
                    ev.state = tcl_str(v)
            elif k == "-delta":
                ev.delta = get_int(v)
            elif k == "-width":
                ev.width = pixels(v)
            elif k == "-height":
                ev.height = pixels(v)
            elif k == "-data":
                ev.data = tcl_str(v)
            elif k == "-detail":
                ev.detail = tcl_str(v)
            elif k == "-mode":
                ev.mode = tcl_str(v)
            elif k == "-focus":
                ev.focus = 1 if get_boolean(v) else 0
            elif k == "-time":
                ev.time = get_int(v)
            elif k == "-sendevent":
                ev.send_event = 1 if get_boolean(v) else 0
            elif k == "-serial":
                pass
            elif k == "-warp":
                warp = get_boolean(v)
            elif k == "-count":
                ev.count = get_int(v)
            elif k == "-above":
                ev.above = tcl_str(v)
            elif k == "-borderwidth":
                ev.border = pixels(v)
            elif k == "-override":
                ev.override = 1 if get_boolean(v) else 0
            elif k == "-place":
                ev.place = tcl_str(v)
        rx, ry = w.root_xy()
        ev.x_root = rootx if rootx is not None else rx + ev.x
        ev.y_root = rooty if rooty is not None else ry + ev.y
        if warp and w.top is not None:
            self.pointer_root = (ev.x_root, ev.y_root)
        if p.type in (B.KeyPress, B.KeyRelease) and ev.keysym == "":
            raise TclError("only one event specification allowed" if False else "keysym required for key events" if False else "")
        if when == "now":
            self.handle_event(ev)
        elif when == "head":
            self.event_queue.insert(0, ev)
        else:
            self.event_queue.append(ev)
        return ""

    def c_focus(self, args):
        if not args:
            f = self.focus
            return f.path if (f is not None and not f.destroyed and self.app_has_focus) else ""
        a0 = tcl_str(args[0])
        if a0 == "-displayof":
            self.window(args[1])
            f = self.focus
            return f.path if (f is not None and not f.destroyed) else ""
        if a0 == "-force":
            w = self.window(args[1])
            self.app_has_focus = True
            self.set_focus(w, True)
            return ""
        if a0 == "-lastfor":
            w = self.window(args[1])
            fl = getattr(w.top, "focus_last", None)
            return fl.path if (fl is not None and not fl.destroyed) else w.top.path
        if a0 == "":
            return ""
        w = self.window(a0)
        self.set_focus(w)
        return ""

    def c_tk_focusNext(self, args):
        w = self.window(args[0])
        return self.focus_traverse(w, True)

    def c_tk_focusPrev(self, args):
        w = self.window(args[0])
        return self.focus_traverse(w, False)

    def c_tk_focusFollowsMouse(self, args):
        self.focus_follows_mouse = True
        return ""

    def focus_ok(self, w):
        tf = w.opts.get("takefocus")
        if tf is not None and tcl_str(tf) != "":
            s = tcl_str(tf)
            if s == "0":
                return False
            if s == "1":
                return w.viewable()
            try:
                r = self.interp.eval(s + " " + w.path)
                if tcl_str(r) != "":
                    return get_boolean(r)
            except TclError:
                pass
        if not w.viewable():
            return False
        st = w.opts.get("state")
        if st == "disabled":
            return False
        if w.TAKES_FOCUS:
            return True
        for seq in self.bindings.sequences(w.path) + self.bindings.sequences(w.wclass):
            if "Key" in seq or "Focus" in seq:
                return True
        return False

    def focus_traverse(self, w, forward):
        # tk_focusNext / tk_focusPrev of focus.tcl
        cur = w
        guard = 0
        while guard < 100000:
            guard += 1
            if forward:
                parent = cur
                kids = list(cur.children)
                i = -1
                while True:
                    i += 1
                    if i < len(kids):
                        cur = kids[i]
                        if cur.IS_TOPLEVEL:
                            continue
                        break
                    cur = parent
                    if cur.IS_TOPLEVEL:
                        break
                    parent = parent.parent
                    kids = list(parent.children)
                    i = kids.index(cur)
            else:
                if cur.IS_TOPLEVEL:
                    parent = cur
                    kids = list(cur.children)
                    i = len(kids)
                else:
                    parent = cur.parent
                    kids = list(parent.children)
                    i = kids.index(cur)
                while i > 0:
                    i -= 1
                    cur = kids[i]
                    if cur.IS_TOPLEVEL:
                        continue
                    parent = cur
                    kids = list(parent.children)
                    i = len(kids)
                cur = parent
            if cur is w or self.focus_ok(cur):
                return cur.path
        return w.path

    def c_grab(self, args):
        if not args:
            raise TclError("wrong # args: should be \"grab ?-global? window\" or \"grab option ?arg ...?\"")
        a0 = tcl_str(args[0])
        if a0.startswith("."):
            self._grab_set(self.window(a0), False)
            return ""
        if a0 == "-global":
            self._grab_set(self.window(args[1]), True)
            return ""
        sub = match_prefix(a0, ["current", "release", "set", "status"], "option")
        if sub == "current":
            if self.grab is None or self.grab.destroyed:
                return ()
            return (self.grab.path,)
        if sub == "release":
            w = self.window(args[1])
            if self.grab is w:
                self.grab = None
            return ""
        if sub == "set":
            if tcl_str(args[1]) == "-global":
                self._grab_set(self.window(args[2]), True)
            else:
                self._grab_set(self.window(args[1]), False)
            return ""
        w = self.window(args[1])
        if self.grab is w:
            return "global" if self.grab_global else "local"
        return "none"

    def _grab_set(self, w, glob):
        if not w.viewable() and not (w.IS_TOPLEVEL and w.wm.map_pending):
            if not w.viewable():
                self.update(True)
        self.grab = w
        self.grab_global = glob

    def c_raise(self, args):
        w = self.window(args[0])
        above = self.window(args[1]) if len(args) > 1 else None
        if w.IS_TOPLEVEL:
            return ""
        sib = w.parent.children
        sib.remove(w)
        if above is None:
            sib.append(w)
        else:
            if above.parent is not w.parent:
                raise TclError("can't raise \"" + w.path + "\" above \"" + above.path + "\"")
            sib.insert(sib.index(above) + 1, w)
        self.damage(w.top)
        return ""

    def c_lower(self, args):
        w = self.window(args[0])
        below = self.window(args[1]) if len(args) > 1 else None
        if w.IS_TOPLEVEL:
            return ""
        sib = w.parent.children
        sib.remove(w)
        if below is None:
            sib.insert(0, w)
        else:
            if below.parent is not w.parent:
                raise TclError("can't lower \"" + w.path + "\" below \"" + below.path + "\"")
            sib.insert(sib.index(below), w)
        self.damage(w.top)
        return ""

    def c_option(self, args):
        if not args:
            raise TclError("wrong # args: should be \"option cmd arg ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["add", "clear", "get", "readfile"], "option")
        if sub == "add":
            if len(args) < 3 or len(args) > 4:
                raise TclError("wrong # args: should be \"option add pattern value ?priority?\"")
            prio = _priority(args[3]) if len(args) == 4 else 80
            self.option_add(tcl_str(args[1]), tcl_str(args[2]), prio)
            return ""
        if sub == "clear":
            self.option_db = []
            return ""
        if sub == "get":
            if len(args) != 4:
                raise TclError("wrong # args: should be \"option get window name class\"")
            w = self.window(args[1])
            v = self.option_lookup(w, tcl_str(args[2]), tcl_str(args[3]))
            return v if v is not None else ""
        if len(args) < 2:
            raise TclError("wrong # args: should be \"option readfile fileName ?priority?\"")
        prio = _priority(args[2]) if len(args) > 2 else 80
        try:
            with open(tcl_str(args[1])) as f:
                data = f.read()
        except OSError:
            raise TclError("couldn't read file \"" + tcl_str(args[1]) + "\": no such file or directory")
        cont = ""
        for raw in data.split("\n"):
            ln = cont + raw
            cont = ""
            if ln.endswith("\\"):
                cont = ln[:-1]
                continue
            s = ln.strip()
            if s == "" or s.startswith("!") or s.startswith("#"):
                continue
            k = s.find(":")
            if k < 0:
                raise TclError("missing colon on line")
            self.option_add(s[:k].strip(), s[k + 1:].strip(), prio)
        return ""

    def c_clipboard(self, args):
        if not args:
            raise TclError("wrong # args: should be \"clipboard option ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["append", "clear", "get"], "option")
        rest = list(args[1:])
        opts = {}
        while rest and tcl_str(rest[0]).startswith("-"):
            k = tcl_str(rest[0])
            if k == "--":
                rest = rest[1:]
                break
            if len(rest) < 2:
                break
            opts[k] = rest[1]
            rest = rest[2:]
        if sub == "clear":
            self.clipboard = ""
            self.clip_buffer = ""
            gui_set_clipboard("")
            return ""
        if sub == "append":
            if len(rest) != 1:
                raise TclError("wrong # args: should be \"clipboard append ?-option value ...? data\"")
            if self.clipboard is None:
                self.clipboard = ""
            self.clipboard += tcl_str(rest[0])
            gui_set_clipboard(self.clipboard)
            return ""
        txt = self.clipboard
        if txt is None or txt == "":
            sys_txt = gui_get_clipboard()
            if sys_txt is not None and sys_txt != "":
                return sys_txt
            if txt is None:
                raise TclError("CLIPBOARD selection doesn't exist or form \"STRING\" not defined")
        return txt

    def c_selection(self, args):
        if not args:
            raise TclError("wrong # args: should be \"selection option ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["clear", "get", "handle", "own"], "option")
        rest = list(args[1:])
        sel = "PRIMARY"
        typ = "STRING"
        win = None
        while len(rest) >= 2 and tcl_str(rest[0]).startswith("-"):
            k = match_prefix(tcl_str(rest[0]), ["-displayof", "-selection", "-type", "-format", "-command"], "option")
            if k == "-selection":
                sel = tcl_str(rest[1])
            elif k == "-type":
                typ = tcl_str(rest[1])
            elif k == "-displayof":
                win = self.window(rest[1])
            rest = rest[2:]
        if sub == "get":
            if sel == "CLIPBOARD":
                return self.c_clipboard(["get"])
            owner = self.selection.get(sel)
            if owner is None or owner.destroyed:
                raise TclError(sel + " selection doesn't exist or form \"" + typ + "\" not defined")
            txt = owner.selection_text() if hasattr(owner, "selection_text") else None
            if txt is None:
                raise TclError(sel + " selection doesn't exist or form \"" + typ + "\" not defined")
            return txt
        if sub == "clear":
            owner = self.selection.get(sel)
            if owner is not None:
                del self.selection[sel]
                if hasattr(owner, "selection_lost"):
                    owner.selection_lost()
            return ""
        if sub == "own":
            if not rest:
                owner = self.selection.get(sel)
                return owner.path if owner is not None and not owner.destroyed else ""
            self.own_selection(self.window(rest[-1]), sel)
            return ""
        return ""

    def own_selection(self, w, sel="PRIMARY"):
        old = self.selection.get(sel)
        self.selection[sel] = w
        if old is not None and old is not w and hasattr(old, "selection_lost"):
            old.selection_lost()

    def c_tk(self, args):
        if not args:
            raise TclError("wrong # args: should be \"tk subcommand ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["appname", "busy", "caret", "fontchooser", "inactive",
                                              "scaling", "useinputmethods", "windowingsystem"], "option")
        rest = list(args[1:])
        if rest and tcl_str(rest[0]) == "-displayof":
            rest = rest[2:]
        if sub == "appname":
            if rest:
                self.appname = tcl_str(rest[0])
            return self.appname
        if sub == "windowingsystem":
            return windowing_system()
        if sub == "scaling":
            if rest:
                set_dpi(get_double(rest[0]) * 72.0)
                reset_fonts()
                self.all_widgets_changed("font")
                return ""
            return SCREEN.dpi / 72.0
        if sub == "inactive":
            if rest and tcl_str(rest[0]) == "reset":
                self.last_input = _now_ms()
                return ""
            return _now_ms() - self.last_input
        if sub == "useinputmethods":
            return 0
        if sub == "caret":
            return ("-height", 0, "-x", 0, "-y", 0)
        if sub == "busy":
            return self._busy(rest)
        raise TclError("tk fontchooser is not supported by Nython's Tk")

    def _busy(self, rest):
        if not rest:
            raise TclError("wrong # args: should be \"tk busy options ?arg ...?\"")
        a0 = tcl_str(rest[0])
        if a0.startswith("."):
            self.busy[self.window(a0).path] = True
            return ""
        sub = match_prefix(a0, ["cget", "configure", "current", "forget", "hold", "status"], "option")
        if sub == "hold":
            self.busy[self.window(rest[1]).path] = True
            return ""
        if sub == "forget":
            p = self.window(rest[1]).path
            if p in self.busy:
                del self.busy[p]
            return ""
        if sub == "status":
            return 1 if self.busy.get(self.window(rest[1]).path) else 0
        if sub == "current":
            return tuple(self.busy.keys())
        if sub == "cget":
            return "watch"
        return ""

    def c_tk_setPalette(self, args):
        if len(args) == 1:
            bg = tcl_str(args[0])
            self.palette = {"background": bg}
        else:
            self.palette = {}
            for i in range(0, len(args) - 1, 2):
                self.palette[tcl_str(args[i])] = tcl_str(args[i + 1])
        for name in self.palette:
            parse_color(self.palette[name])
        for w in list(self.widgets.values()):
            changed = []
            for k in self.palette:
                if k in w.opts:
                    w.opts[k] = self.palette[k]
                    changed.append(k)
            if "background" in self.palette:
                for k in ("highlightbackground",):
                    if k in w.opts:
                        w.opts[k] = self.palette["background"]
            if changed:
                w.reconfigured(changed)
        for k in self.palette:
            self.option_add("*" + k, self.palette[k], 60)
        return ""

    def c_tk_bisque(self, args):
        return self.c_tk_setPalette(["activeBackground", "#e6ceb1", "activeForeground", "black",
                                     "background", "#ffe4c4", "disabledForeground", "#b0b0b0",
                                     "foreground", "black", "highlightBackground", "#ffe4c4",
                                     "highlightColor", "black", "insertBackground", "black",
                                     "selectColor", "#b03060", "selectBackground", "#e6ceb1",
                                     "selectForeground", "black", "troughColor", "#cdb79e"])

    def c_tk_popup(self, args):
        m = self.window(args[0])
        x = pixels(args[1])
        y = pixels(args[2])
        entry = args[3] if len(args) > 3 else None
        m.post(x, y, entry)
        return ""

    def c_trace(self, args):
        if len(args) < 1:
            raise TclError("wrong # args: should be \"trace option ?arg ...?\"")
        sub = tcl_str(args[0])
        if sub in ("variable", "vdelete", "vinfo"):
            # the legacy forms: trace variable name ops cmd
            name = tcl_str(args[1])
            if sub == "variable":
                ops = set()
                for c in tcl_str(args[2]):
                    ops.add({"r": "read", "w": "write", "u": "unset", "a": "array"}.get(c, ""))
                self.traces.setdefault(name, []).append(Trace(ops, tcl_str(args[3]), None, True))
                return ""
            if sub == "vdelete":
                ops = set()
                for c in tcl_str(args[2]):
                    ops.add({"r": "read", "w": "write", "u": "unset", "a": "array"}.get(c, ""))
                return self._trace_remove(name, ops, tcl_str(args[3]))
            out = []
            for t in reversed(self.traces.get(name, [])):
                if t.cmd is not None:
                    letters = "".join([o[0] for o in ("read", "write", "unset", "array") if o in t.ops])
                    out.append((letters, t.cmd))
            return tuple(out)
        sub = match_prefix(sub, ["add", "info", "remove"], "option")
        kind = match_prefix(tcl_str(args[1]), ["command", "execution", "variable"], "option")
        if kind != "variable":
            raise TclError("trace " + sub + " " + kind + " is not supported by Nython's Tcl")
        name = tcl_str(args[2])
        if sub == "info":
            out = []
            for t in reversed(self.traces.get(name, [])):
                if t.cmd is not None:
                    out.append((tuple([o for o in ("array", "read", "write", "unset") if o in t.ops]), t.cmd))
            return tuple(out)
        ops = set()
        for o in split_list(args[3]) if not isinstance(args[3], (tuple, list)) else [tcl_str(x) for x in args[3]]:
            ops.add(match_prefix(o, ["array", "read", "unset", "write"], "operation"))
        if not ops:
            raise TclError("bad operation list \"\": must be one or more of array, read, unset, or write")
        cmd = tcl_str(args[4])
        if sub == "add":
            self.traces.setdefault(name, []).append(Trace(ops, cmd, None, False))
            return ""
        return self._trace_remove(name, ops, cmd)

    def _trace_remove(self, name, ops, cmd):
        lst = self.traces.get(name)
        if not lst:
            return ""
        for t in reversed(lst):
            if t.cmd == cmd and t.ops == ops:
                lst.remove(t)
                break
        if not lst:
            del self.traces[name]
        return ""

    def c_pack(self, args):
        if not args:
            raise TclError("wrong # args: should be \"pack option arg ?arg ...?\"")
        a0 = tcl_str(args[0])
        if a0.startswith("."):
            return self._pack_configure(args)
        sub = match_prefix(a0, ["configure", "forget", "info", "propagate", "slaves"], "option")
        if sub == "configure":
            return self._pack_configure(args[1:])
        if sub == "forget":
            for a in args[1:]:
                w = self.window(a)
                if w.manager == "pack":
                    G.unmanage(self, w)
            return ""
        if sub == "info":
            return G.pack_info(self, self.window(args[1]))
        if sub == "propagate":
            w = self.window(args[1])
            if len(args) == 2:
                return 1 if w.pack_prop else 0
            w.pack_prop = get_boolean(args[2])
            self.relayout()
            return ""
        w = self.window(args[1])
        return tuple([s.path for s in w.pack_slaves])

    def _pack_configure(self, args):
        slaves = []
        k = 0
        while k < len(args) and tcl_str(args[k]).startswith("."):
            slaves.append(self.window(args[k]))
            k += 1
        if not slaves:
            raise TclError("wrong # args: should be \"pack configure window ?window ...? ?-option value ...?\"")
        return G.pack_configure(self, slaves, list(args[k:]))

    def c_grid(self, args):
        if not args:
            raise TclError("wrong # args: should be \"grid option arg ?arg ...?\"")
        a0 = tcl_str(args[0])
        if a0.startswith(".") or a0 in ("x", "-", "^"):
            return self._grid_configure(args)
        sub = match_prefix(a0, ["anchor", "bbox", "columnconfigure", "configure", "content", "forget", "info",
                                "location", "propagate", "remove", "rowconfigure", "size", "slaves"], "option")
        if sub == "configure":
            return self._grid_configure(args[1:])
        if sub == "forget" or sub == "remove":
            for a in args[1:]:
                w = self.window(a)
                if w.manager == "grid":
                    if sub == "remove":
                        w.grid_saved = w.minfo
                    G.unmanage(self, w)
            return ""
        if sub == "info":
            return G.grid_info(self, self.window(args[1]))
        if sub == "propagate":
            w = self.window(args[1])
            if len(args) == 2:
                return 1 if w.grid_prop else 0
            w.grid_prop = get_boolean(args[2])
            self.relayout()
            return ""
        if sub == "slaves" or sub == "content":
            w = self.window(args[1])
            row = None
            col = None
            rest = args[2:]
            for i in range(0, len(rest) - 1, 2):
                k = match_prefix(tcl_str(rest[i]), ["-column", "-row"], "option")
                if k == "-row":
                    row = get_int(rest[i + 1])
                else:
                    col = get_int(rest[i + 1])
            out = []
            for s in reversed(w.grid_slaves):
                i = s.minfo
                if row is not None and not (i.row <= row < i.row + i.rowspan):
                    continue
                if col is not None and not (i.column <= col < i.column + i.columnspan):
                    continue
                out.append(s.path)
            return tuple(out)
        if sub == "size":
            return G.grid_size(self.window(args[1]))
        if sub == "bbox":
            w = self.window(args[1])
            self._layout_now()
            return G.grid_bbox(w, args[2:])
        if sub == "location":
            w = self.window(args[1])
            self._layout_now()
            return G.grid_location(w, pixels(args[2]), pixels(args[3]))
        if sub == "anchor":
            w = self.window(args[1])
            gm = G.grid_master(w)
            if len(args) == 2:
                return gm.anchor
            gm.anchor = match_prefix(tcl_str(args[2]), ["n", "ne", "e", "se", "s", "sw", "w", "nw", "center"], "anchor")
            self.relayout()
            return ""
        w = self.window(args[1])
        if len(args) < 3:
            raise TclError("wrong # args: should be \"grid " + sub + " master index ?-option value ...?\"")
        return G.grid_rowcol_configure(self, w, "column" if sub == "columnconfigure" else "row", args[2], args[3:])

    def _layout_now(self):
        if self.layout_queued:
            self.idle_q = [q for q in self.idle_q if q[0] != "layout"]
            self.do_layout()

    def _grid_configure(self, args):
        items = []
        k = 0
        while k < len(args):
            a = tcl_str(args[k])
            if a.startswith(".") or a in ("x", "-", "^"):
                items.append(a)
                k += 1
            else:
                break
        return G.grid_configure(self, items, list(args[k:]))

    def c_place(self, args):
        if not args:
            raise TclError("wrong # args: should be \"place option|pathName args\"")
        a0 = tcl_str(args[0])
        if a0.startswith("."):
            return G.place_configure(self, self.window(a0), list(args[1:]))
        sub = match_prefix(a0, ["configure", "content", "forget", "info", "slaves"], "option")
        if sub == "configure":
            w = self.window(args[1])
            if len(args) == 2:
                info = G.place_info(self, w)
                return info
            return G.place_configure(self, w, list(args[2:]))
        if sub == "forget":
            w = self.window(args[1])
            if w.manager == "place":
                G.unmanage(self, w)
            return ""
        if sub == "info":
            return G.place_info(self, self.window(args[1]))
        w = self.window(args[1])
        return tuple([s.path for s in w.place_slaves])

    # winfo
    def c_winfo(self, args):
        if not args:
            raise TclError("wrong # args: should be \"winfo option ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["atom", "atomname", "cells", "children", "class", "colormapfull",
                                              "containing", "depth", "exists", "fpixels", "geometry", "height",
                                              "id", "interps", "ismapped", "manager", "name", "parent", "pathname",
                                              "pixels", "pointerx", "pointerxy", "pointery", "reqheight",
                                              "reqwidth", "rgb", "rootx", "rooty", "screen", "screencells",
                                              "screendepth", "screenheight", "screenmmheight", "screenmmwidth",
                                              "screenvisual", "screenwidth", "server", "toplevel", "viewable",
                                              "visual", "visualid", "visualsavailable", "vrootheight",
                                              "vrootwidth", "vrootx", "vrooty", "width", "x", "y"], "option")
        rest = list(args[1:])
        if sub in ("atom", "atomname", "containing", "interps", "pathname") and rest and tcl_str(rest[0]) == "-displayof":
            rest = rest[2:]
        if sub == "exists":
            w = self.widgets.get(tcl_str(rest[0]))
            return 1 if (w is not None and not w.destroyed) else 0
        if sub == "atom":
            return self._atom(tcl_str(rest[0]))
        if sub == "atomname":
            n = get_int(rest[0])
            for k in self.wid:
                if self.wid[k] == n and isinstance(k, str):
                    return k
            raise TclError("no atom exists with id \"" + str(n) + "\"")
        if sub == "interps":
            return (self.appname,)
        if sub == "containing":
            x = pixels(rest[0])
            y = pixels(rest[1])
            for top in reversed(self.toplevels):
                if not top.mapped:
                    continue
                lx = x - top.x
                ly = y - top.y - top.menubar_height()
                if 0 <= lx < top.width and 0 <= ly < top.height:
                    return self.window_at(top, lx, ly).path
            return ""
        if sub == "pathname":
            n = get_int(rest[0])
            for w in self.widgets.values():
                if self._window_id(w) == n:
                    return w.path
            raise TclError("window id \"" + tcl_str(rest[0]) + "\" doesn't exist in this application")
        w = self.window(rest[0])
        if sub == "children":
            return tuple([c.path for c in w.children if not c.destroyed])
        if sub == "class":
            return w.wclass
        if sub == "width":
            return w.width
        if sub == "height":
            return w.height
        if sub == "reqwidth":
            return w.reqw
        if sub == "reqheight":
            return w.reqh
        if sub == "x":
            return w.x
        if sub == "y":
            return w.y + (0 if not w.IS_TOPLEVEL else 0)
        if sub == "rootx":
            return w.root_xy()[0]
        if sub == "rooty":
            return w.root_xy()[1]
        if sub == "geometry":
            return "%dx%d+%d+%d" % (w.width, w.height, w.x, w.y)
        if sub == "ismapped":
            return 1 if w.mapped else 0
        if sub == "viewable":
            return 1 if w.viewable() else 0
        if sub == "manager":
            if w.IS_TOPLEVEL:
                return "wm"
            return w.manager
        if sub == "name":
            return w.name
        if sub == "parent":
            return w.parent.path if w.parent is not None else ""
        if sub == "toplevel":
            return w.top.path
        if sub == "id":
            return self._window_id(w)
        if sub == "fpixels":
            return fpixels(rest[1])
        if sub == "pixels":
            return pixels(rest[1])
        if sub == "rgb":
            return rgb16(rest[1])
        if sub == "screen":
            return ":0.0"
        if sub == "screenwidth":
            return SCREEN.width
        if sub == "screenheight":
            return SCREEN.height
        if sub == "screenmmwidth":
            return cround(SCREEN.width * 25.4 / SCREEN.dpi)
        if sub == "screenmmheight":
            return cround(SCREEN.height * 25.4 / SCREEN.dpi)
        if sub in ("depth", "screendepth"):
            return 24
        if sub in ("cells", "screencells"):
            return 256
        if sub in ("visual", "screenvisual"):
            return "truecolor"
        if sub == "visualid":
            return 0x21
        if sub == "visualsavailable":
            return (("truecolor", 24),)
        if sub == "colormapfull":
            return 0
        if sub == "server":
            return "X11R6 Nython Tk over SDL " + gui_sdl_version()
        if sub == "pointerx":
            return self.pointer_root[0]
        if sub == "pointery":
            return self.pointer_root[1]
        if sub == "pointerxy":
            return (self.pointer_root[0], self.pointer_root[1])
        if sub == "vrootwidth":
            return SCREEN.width
        if sub == "vrootheight":
            return SCREEN.height
        if sub in ("vrootx", "vrooty"):
            return 0
        raise TclError("bad option \"" + sub + "\"")

    def _window_id(self, w):
        k = id(w)
        if k not in self.wid:
            self.window_ids += 4
            self.wid[k] = self.window_ids
        return self.wid[k]

    def _atom(self, name):
        if name not in self.wid:
            self.window_ids += 1
            self.wid[name] = 1000 + len(self.wid)
        return self.wid[name]

    # wm
    def c_wm(self, args):
        if len(args) < 2:
            raise TclError("wrong # args: should be \"wm option window ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["aspect", "attributes", "client", "colormapwindows", "command",
                                              "deiconify", "focusmodel", "forget", "frame", "geometry", "grid",
                                              "group", "iconbitmap", "iconify", "iconmask", "iconname",
                                              "iconphoto", "iconposition", "iconwindow", "manage", "maxsize",
                                              "minsize", "overrideredirect", "positionfrom", "protocol",
                                              "resizable", "sizefrom", "stackorder", "state", "title",
                                              "transient", "withdraw"], "option")
        w = self.window(args[1])
        rest = list(args[2:])
        if sub in ("manage", "forget"):
            raise TclError("wm " + sub + " is not supported by Nython's Tk")
        if not w.IS_TOPLEVEL:
            raise TclError("window \"" + w.path + "\" isn't a top-level window")
        wm = w.wm
        if sub == "title":
            if rest:
                wm.title = tcl_str(rest[0])
                if w.native is not None:
                    gui_set_window_title(w.native, wm.title)
                return ""
            return self.wm_title(w)
        if sub == "geometry":
            if not rest:
                return "%dx%d+%d+%d" % (w.width, w.height, w.x, w.y)
            g = tcl_str(rest[0])
            if g == "":
                wm.user_w = None
                wm.user_h = None
                self.relayout()
                return ""
            m = _GEOM_RE.match(g)
            if m is None:
                raise TclError("bad geometry specifier \"" + g + "\"")
            if m.group(1) is not None:
                wm.user_w = int(m.group(1))
                wm.user_h = int(m.group(2))
            if m.group(3) is not None:
                x = int(m.group(4))
                y = int(m.group(6))
                if m.group(3) == "-":
                    x = SCREEN.width - x - (wm.user_w if wm.user_w is not None else w.width)
                if m.group(5) == "-":
                    y = SCREEN.height - y - (wm.user_h if wm.user_h is not None else w.height)
                wm.ux = x
                wm.uy = y
                w.x = x
                w.y = y
                ev = XEvent(B.ConfigureNotify, w)
                ev.x, ev.y, ev.width, ev.height = w.x, w.y, w.width, w.height
                if w.mapped:
                    self.struct_q.append(ev)
            self.relayout()
            return ""
        if sub == "state":
            if not rest:
                if wm.map_pending and wm.state == "normal":
                    return "normal"
                return wm.state
            st = match_prefix(tcl_str(rest[0]), ["normal", "iconic", "withdrawn", "zoomed"], "argument")
            if st == "normal":
                self.map_toplevel(w)
            elif st == "zoomed":
                wm.attributes["-zoomed"] = 1
                self.map_toplevel(w)
                wm.state = "zoomed"
            else:
                self.unmap_toplevel(w, st)
            return ""
        if sub == "withdraw":
            self.unmap_toplevel(w, "withdrawn")
            return ""
        if sub == "iconify":
            if wm.override:
                raise TclError("can't iconify \"" + w.path + "\": override-redirect flag is set")
            if wm.transient:
                raise TclError("can't iconify \"" + w.path + "\": it is a transient")
            self.unmap_toplevel(w, "iconic")
            return ""
        if sub == "deiconify":
            self.map_toplevel(w)
            return ""
        if sub == "protocol":
            if not rest:
                return tuple(wm.protocols.keys())
            name = tcl_str(rest[0])
            if len(rest) == 1:
                return wm.protocols.get(name, "")
            cmd = tcl_str(rest[1])
            if cmd == "":
                if name in wm.protocols:
                    del wm.protocols[name]
            else:
                wm.protocols[name] = cmd
            return ""
        if sub == "attributes":
            return self._wm_attributes(w, rest)
        if sub == "minsize" or sub == "maxsize":
            if not rest:
                if sub == "minsize":
                    return (wm.minw, wm.minh)
                return (wm.maxw if wm.maxw is not None else SCREEN.width, wm.maxh if wm.maxh is not None else SCREEN.height)
            a = pixels(rest[0])
            b = pixels(rest[1])
            if sub == "minsize":
                wm.minw = max(1, a)
                wm.minh = max(1, b)
                if w.native is not None:
                    gui_set_min_size(w.native, wm.minw, wm.minh)
            else:
                wm.maxw = max(1, a)
                wm.maxh = max(1, b)
            self.relayout()
            return ""
        if sub == "resizable":
            if not rest:
                return (wm.resizable[0], wm.resizable[1])
            wm.resizable = [1 if get_boolean(rest[0]) else 0, 1 if get_boolean(rest[1]) else 0]
            return ""
        if sub == "overrideredirect":
            if not rest:
                return wm.override
            wm.override = 1 if get_boolean(rest[0]) else 0
            return ""
        if sub == "transient":
            if not rest:
                return wm.transient
            m = tcl_str(rest[0])
            if m != "":
                self.window(m)
            wm.transient = m
            return ""
        if sub == "iconname":
            if rest:
                wm.iconname = tcl_str(rest[0])
                return ""
            return wm.iconname
        if sub == "group":
            if rest:
                wm.group = tcl_str(rest[0])
                return ""
            return wm.group
        if sub == "iconphoto":
            names = [tcl_str(x) for x in rest if tcl_str(x) != "-default"]
            for n in names:
                if n not in self.images:
                    raise TclError("can't use \"" + n + "\" as iconphoto: not a photo image")
            wm.iconphoto = " ".join(names)
            return ""
        if sub == "iconbitmap":
            if rest:
                wm.iconbitmap = tcl_str(rest[-1])
                return ""
            return wm.iconbitmap
        if sub == "positionfrom" or sub == "sizefrom":
            if rest:
                setattr(wm, sub, tcl_str(rest[0]))
                return ""
            return getattr(wm, sub)
        if sub == "aspect":
            if rest:
                wm.aspect = " ".join([tcl_str(x) for x in rest])
                return ""
            return wm.aspect
        if sub == "focusmodel":
            if rest:
                wm.focusmodel = match_prefix(tcl_str(rest[0]), ["active", "passive"], "argument")
                return ""
            return wm.focusmodel
        if sub == "frame":
            return "0x%x" % self._window_id(w)
        if sub == "stackorder":
            return tuple([t.path for t in self.toplevels if t.mapped])
        if sub == "command":
            if rest:
                wm.command = tcl_str(rest[0])
                return ""
            return wm.command
        if sub == "client":
            if rest:
                wm.client = tcl_str(rest[0])
                return ""
            return wm.client
        return ""

    def _wm_attributes(self, w, rest):
        wm = w.wm
        names = ["-alpha", "-fullscreen", "-topmost", "-type", "-zoomed"]
        if not rest:
            out = []
            for k in ("-alpha", "-topmost", "-zoomed", "-fullscreen", "-type"):
                out.append(k)
                out.append(wm.attributes[k])
            return tuple(out)
        if len(rest) == 1:
            k = match_prefix(tcl_str(rest[0]), names, "attribute")
            return wm.attributes[k]
        for i in range(0, len(rest) - 1, 2):
            k = match_prefix(tcl_str(rest[i]), names, "attribute")
            v = rest[i + 1]
            if k == "-alpha":
                a = get_double(v)
                wm.attributes[k] = max(0.0, min(1.0, a))
            elif k == "-type":
                wm.attributes[k] = tcl_str(v)
            else:
                wm.attributes[k] = 1 if get_boolean(v) else 0
                if k == "-fullscreen" and w.native is not None:
                    gui_set_fullscreen(w.native, wm.attributes[k])
                if k in ("-fullscreen", "-zoomed"):
                    self.relayout()
        return ""

    def wm_delete(self, top):
        cmd = top.wm.protocols.get("WM_DELETE_WINDOW")
        if cmd:
            self.eval_bg(cmd)
        else:
            self.destroy_window(top)

    # fonts
    def c_font(self, args):
        if not args:
            raise TclError("wrong # args: should be \"font option ?arg?\"")
        sub = match_prefix(tcl_str(args[0]), ["actual", "configure", "create", "delete", "families", "measure",
                                              "metrics", "names"], "option")
        rest = list(args[1:])
        if sub == "names":
            return tuple(self.named_fonts.keys())
        if sub == "families":
            return tuple(installed_families())
        if sub == "create":
            if rest and not tcl_str(rest[0]).startswith("-"):
                name = tcl_str(rest[0])
                rest = rest[1:]
                if name in self.named_fonts:
                    raise TclError("named font \"" + name + "\" already exists")
            else:
                self.font_n += 1
                name = "font" + str(self.font_n)
                while name in self.named_fonts:
                    self.font_n += 1
                    name = "font" + str(self.font_n)
            fa = {"family": "sans-serif", "size": 0, "weight": "normal", "slant": "roman", "underline": 0, "overstrike": 0}
            fa = parse_font_options([tcl_str(x) for x in rest], fa) if rest else fa
            self.named_fonts[name] = fa
            return name
        if sub == "delete":
            for n in rest:
                n = tcl_str(n)
                if n not in self.named_fonts:
                    raise TclError("named font \"" + n + "\" doesn't exist")
                del self.named_fonts[n]
            return ""
        if sub == "configure":
            name = tcl_str(rest[0])
            if name not in self.named_fonts:
                raise TclError("named font \"" + name + "\" doesn't exist")
            fa = self.named_fonts[name]
            if len(rest) == 1:
                return ("-family", fa["family"], "-size", fa["size"], "-weight", fa["weight"], "-slant", fa["slant"],
                        "-underline", fa["underline"], "-overstrike", fa["overstrike"])
            if len(rest) == 2:
                k = match_prefix(tcl_str(rest[1]), ["-family", "-size", "-weight", "-slant", "-underline", "-overstrike"], "option")
                return fa[k[1:]]
            parse_font_options([tcl_str(x) for x in rest[1:]], fa)
            self.all_widgets_changed("font")
            return ""
        if rest and tcl_str(rest[0]) == "-displayof":
            pass
        if not rest:
            raise TclError("wrong # args: should be \"font " + sub + " font ?-displayof window? ...\"")
        font = self.font_of(rest[0])
        rest = rest[1:]
        if rest and tcl_str(rest[0]) == "-displayof":
            rest = rest[2:]
        if sub == "measure":
            if len(rest) != 1:
                raise TclError("wrong # args: should be \"font measure font ?-displayof window? text\"")
            return font.measure(tcl_str(rest[0]))
        if sub == "metrics":
            asc, desc, ls, fixed = font.metrics()
            vals = {"-ascent": asc, "-descent": desc, "-linespace": ls, "-fixed": fixed}
            if not rest:
                return ("-ascent", asc, "-descent", desc, "-linespace", ls, "-fixed", fixed)
            k = match_prefix(tcl_str(rest[0]), ["-ascent", "-descent", "-fixed", "-linespace"], "metric")
            return vals[k]
        fam, size, weight, slant, ul, ov = font.actual()
        vals = {"-family": fam, "-size": size, "-weight": weight, "-slant": slant, "-underline": ul, "-overstrike": ov}
        if rest and tcl_str(rest[0]) == "--":
            rest = rest[2:]
        if not rest:
            return ("-family", fam, "-size", size, "-weight", weight, "-slant", slant, "-underline", ul, "-overstrike", ov)
        k = match_prefix(tcl_str(rest[0]), ["-family", "-size", "-weight", "-slant", "-underline", "-overstrike"], "option")
        return vals[k]

    def c_image(self, args):
        from _tkinter.image import image_command
        return image_command(self, args)

    def c_ttk_style(self, args):
        from _tkinter.ttk import style_command
        return style_command(self, args)

    # the harness (Nython only): scripted input through the SDL stub
    def ny_drive(self, commands, max_loops=2000):
        path = os.environ.get("NY_STUB_EVENTS", "")
        if path == "":
            raise TclError("the scripted-input harness is not active (set NY_STUB_EVENTS before Tk starts)")
        _SYNC[0] += 1
        tag = "__nysync_" + str(os.getpid()) + "_" + str(_SYNC[0]) + "__"
        with open(path, "a") as f:
            for c in commands:
                f.write(c + "\n")
            f.write("textedit " + tag + "\n")
        loops = 0
        while tag not in self.sync_seen and loops < max_loops:
            loops += 1
            if not self.do_one_event(DONT_WAIT):
                self.pump_native(1)
        self.update()
        return 1 if tag in self.sync_seen else 0

    def after_idle_once(self, w, key, func):
        # a widget's own idle handler (Tk_DoWhenIdle with a "pending" flag,
        # as tkText.c's and tkCanvas.c's redisplay/update callbacks)
        k = (id(w), key)
        if k in self.idle_once:
            return
        self.idle_once.add(k)
        self.idle_q.append(("py", k, func))

    def after_idle_script(self, script):
        ident = self.after_id()
        self.after_info[ident] = ("idle", script)
        self.idle_q.append(("script", ident, script))
        return ident

    def watch_image(self, w, name):
        # widgets showing an image are told when it changes (Tk's
        # ImageChangedProc): the image keeps a set of its users (a widget
        # that stopped using it is told once more, harmlessly)
        for n in split_list(name)[:1] if name else []:
            im = self.images.get(n)
            if im is not None:
                im.users.add(w)

    def image_changed(self, im):
        for w in list(im.users):
            if w.destroyed:
                im.users.discard(w)
                continue
            hook = getattr(w, "on_image_changed", None)
            if hook is not None:
                hook(im)
                continue
            w.compute_geometry()
            w.damage()

    def image_ops(self, path):
        # the images the last frame of path's toplevel drew (for the harness)
        w = self.window(path)
        return list(getattr(w.top, "image_ops", []))

    def accessibility(self, path):
        # Nython: an accessibility tree (WAI-ARIA roles) of viewable widgets
        w = self.window(path)
        return _a11y(self, w)

    def redisplay(self):
        self.redisplay_queued = False
        tops = self.damaged
        self.damaged = []
        for top in tops:
            if top.destroyed or not top.mapped or top.native is None:
                continue
            self.frame_images = []
            top.paint()
            top.image_ops = self.frame_images
            self.frame_images = []
            self.frames_drawn += 1


_SYNC = [0]


def _a11y(app, w):
    role = getattr(w, "A11Y_ROLE", "generic")
    if w.IS_TOPLEVEL:
        name = app.wm_title(w)
    else:
        name = ""
        for k in ("text", "label"):
            v = w.opts.get(k)
            if v:
                name = tcl_str(v)
                break
        hook = getattr(w, "a11y_name", None)
        if hook is not None:
            name = hook()
    states = []
    st = w.opts.get("state")
    if st == "disabled":
        states.append("disabled")
    if w.has_focus:
        states.append("focused")
    if getattr(w, "selected", False):
        states.append("checked")
    if w.TAKES_FOCUS and st != "disabled":
        states.append("focusable")
    hook = getattr(w, "a11y_states", None)
    if hook is not None:
        states.extend(hook())
    rx, ry = w.root_xy()
    node = {"role": role, "name": name, "path": w.path, "class": w.wclass, "states": states,
            "bounds": (rx, ry, w.width, w.height), "children": []}
    val = getattr(w, "a11y_value", None)
    if val is not None:
        node["value"] = val()
    for c in w.children:
        if c.destroyed or not c.mapped:
            continue
        node["children"].append(_a11y(app, c))
    return node

import re as _re
_FAST_RE = _re.compile(r'^if \{"\[(\S+) ((?:%[#a-zA-Z] ?)+)\]" == "break"\} break$')
_GEOM_RE = _re.compile(r"^=?(?:(\d+)x(\d+))?(?:([+-])(-?\d+)([+-])(-?\d+))?$")


_UNSHIFTED = {"1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(",
              "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", ";": ":", "'": "\"", "`": "~", "\\": "|",
              ",": "<", ".": ">", "/": "?"}


def _char_keysym(c):
    o = ord(c)
    if o < 0x100:
        return keysym_name(o)
    return keysym_name(0x1000000 + o)


def _concat(words):
    if len(words) == 1:
        return tcl_str(words[0])
    parts = []
    for w in words:
        s = tcl_str(w).strip()
        if s != "":
            parts.append(s)
    return " ".join(parts)


def _virtual_name(s):
    s = tcl_str(s)
    if not (s.startswith("<<") and s.endswith(">>")) or len(s) <= 4:
        raise TclError("virtual event \"" + s + "\" is badly formed")
    return s[2:-2]


def _priority(v):
    s = tcl_str(v)
    names = {"widgetDefault": 20, "startupFile": 40, "userDefault": 60, "interactive": 80}
    for k in names:
        if k.startswith(s) and s != "":
            return names[k]
    try:
        n = get_int(s)
    except TclError:
        raise TclError("bad priority level \"" + s + "\": must be widgetDefault, startupFile, userDefault, interactive, or a number between 0 and 100")
    if n < 0 or n > 100:
        raise TclError("bad priority level \"" + s + "\": must be widgetDefault, startupFile, userDefault, interactive, or a number between 0 and 100")
    return n


def _parse_option_pattern(pat):
    # "*Button.background" -> [("*", "Button"), (".", "background")]
    elems = []
    i = 0
    n = len(pat)
    bind = "."
    first = True
    while i < n:
        c = pat[i]
        if c == "*" or c == ".":
            if c == "*":
                bind = "*"
            elif bind != "*":
                bind = "."
            i += 1
            continue
        j = i
        while j < n and pat[j] not in "*.":
            j += 1
        elems.append((bind if not (first and bind == ".") else "^", pat[i:j]))
        first = False
        bind = "."
        i = j
    return elems


def _option_match(elems, chain, name, cls):
    # chain: [(name, class)] from the application down to the widget; the
    # last element must match the option's name or class
    if not elems:
        return False
    last = elems[-1][1]
    if last != name and last != cls and last != "?":
        return False
    body = elems[:-1]
    if elems[-1][0] == "." or elems[-1][0] == "^":
        return _match_levels(body, 0, chain, len(chain) - 1, True)
    return _match_levels(body, 0, chain, len(chain) - 1, False)


def _match_levels(body, bi, chain, ci_last, tight_end):
    # does body[bi:] match chain[0..ci_last] (the levels above the option)?
    def rec(bi, ci):
        if bi == len(body):
            # every level consumed: for a tight end the widget level must be
            # the last one matched
            if tight_end:
                return ci == ci_last + 1
            return ci <= ci_last + 1
        b, pat = body[bi]
        if b == "^" or b == ".":
            if ci > ci_last:
                return False
            if bi == 0 and b == "^" and ci != 0:
                return False
            if pat == chain[ci][0] or pat == chain[ci][1] or pat == "?":
                return rec(bi + 1, ci + 1)
            return False
        # loose: skip any number of levels
        k = ci
        while k <= ci_last:
            if pat == chain[k][0] or pat == chain[k][1] or pat == "?":
                if rec(bi + 1, k + 1):
                    return True
            k += 1
        return False

    return rec(bi, 0)


def option_names(cls):
    return [s[0] for s in cls.OPTS]
