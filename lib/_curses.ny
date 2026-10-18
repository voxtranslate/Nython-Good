# nython: module    (import it by name: it runs in a module scope of its own)
# lib/_curses.ny - CPython's _curses module (round 84), over Nython's own
# curses (builtins/nycurses.cpp) rather than ncurses: `import curses` uses it.
#
#     import curses
#     def main(stdscr):
#         stdscr.addstr(0, 0, "hello", curses.A_BOLD)
#         stdscr.refresh()
#         stdscr.getch()
#     curses.wrapper(main)
#
# What CPython 3.12's _curses has: the window type (every method: addch,
# addstr, addnstr, insch, insstr, insnstr, delch, deleteln, insertln,
# insdelln, getch, getkey, get_wch, getstr, instr, inch, move, getyx,
# getbegyx, getmaxyx, getparyx, clear, erase, clrtoeol, clrtobot, border,
# box, hline, vline, attron/attroff/attrset/standout/standend, chgat,
# bkgd/bkgdset/getbkgd, refresh/noutrefresh (pads with their six arguments),
# subwin/derwin/subpad, mvwin, mvderwin, resize, scroll, scrollok,
# setscrreg, idlok, idcok, immedok, leaveok, clearok, keypad, nodelay,
# timeout, notimeout, syncok/syncup/syncdown/cursyncup, touchwin/touchline/
# untouchwin/is_wintouched/is_linetouched, redrawwin/redrawln, overlay,
# overwrite, enclose, echochar, putwin, encoding), the module functions
# (initscr, endwin, isendwin, newwin, newpad, doupdate, the input modes,
# colors with 256 colors and extended pairs, mouse, key names, terminfo:
# setupterm, tigetflag/tigetnum/tigetstr, tparm, putp, ...), the A_*,
# KEY_*, COLOR_*, BUTTON* constants with ncurses' values, and the ACS_*
# constants, LINES and COLS after initscr(), COLORS and COLOR_PAIRS after
# start_color(); `error` with CPython's messages ("addwstr() returned ERR",
# "must call initscr() first", ...).
#
# Nython additions: nython_stats() -> (bytes written to the terminal,
# doupdate calls, update mode) - the update mode is NY_CURSES_UPDATE
# (optimize, noscroll, naive) - and nython_terminfo() -> the loaded entry as
# (names, path, extended_numbers, flags, numbers, strings).
#
# Not here: newterm/set_term/delscreen (CPython has none either), the
# ripoffline/slk soft labels, getwin()/putwin() files in ncurses' format
# (Nython writes its own: "NYCURSESWIN1", the window's numbers, then its
# cells as numbers - read back by getwin), cooked-mode line editing by
# curses in nocbreak mode (the tty's own canonical mode edits the line),
# multibyte input assembled by getch (getch returns the bytes; get_wch and
# getstr decode UTF-8), magic-cookie terminals (xmc), padding by null
# characters at low baud rates (delays are sleeps), the Berkeley-DB hashed
# terminfo databases.

import sys as _sys
import os as _os

version = b"2.2"
__version__ = version


class _NcursesVersion(tuple):
    # curses.ncurses_version: the ncurses behaviour this follows
    def __new__(cls, major, minor, patch):
        return tuple.__new__(cls, (major, minor, patch))

    @property
    def major(self):
        return self[0]

    @property
    def minor(self):
        return self[1]

    @property
    def patch(self):
        return self[2]

    def __repr__(self):
        return "curses.ncurses_version(major=%d, minor=%d, patch=%d)" % (self[0], self[1], self[2])


ncurses_version = _NcursesVersion(6, 4, 20240113)


class error(Exception):
    pass


error.__module__ = "_curses"

OK = 0
ERR = -1

A_ATTRIBUTES = 0xffffff00
A_NORMAL = 0
A_STANDOUT = 1 << 16
A_UNDERLINE = 1 << 17
A_REVERSE = 1 << 18
A_BLINK = 1 << 19
A_DIM = 1 << 20
A_BOLD = 1 << 21
A_ALTCHARSET = 1 << 22
A_INVIS = 1 << 23
A_PROTECT = 1 << 24
A_CHARTEXT = 0xff
A_COLOR = 0xff00
A_HORIZONTAL = 1 << 25
A_LEFT = 1 << 26
A_LOW = 1 << 27
A_RIGHT = 1 << 28
A_TOP = 1 << 29
A_VERTICAL = 1 << 30
A_ITALIC = 1 << 31

COLOR_BLACK = 0
COLOR_RED = 1
COLOR_GREEN = 2
COLOR_YELLOW = 3
COLOR_BLUE = 4
COLOR_MAGENTA = 5
COLOR_CYAN = 6
COLOR_WHITE = 7


def _mouse_mask(b, m):
    return m << ((b - 1) * 5)


def _init_mouse_consts():
    g = globals()
    for b in range(1, 6):
        g["BUTTON%d_RELEASED" % b] = _mouse_mask(b, 1)
        g["BUTTON%d_PRESSED" % b] = _mouse_mask(b, 2)
        g["BUTTON%d_CLICKED" % b] = _mouse_mask(b, 4)
        g["BUTTON%d_DOUBLE_CLICKED" % b] = _mouse_mask(b, 8)
        g["BUTTON%d_TRIPLE_CLICKED" % b] = _mouse_mask(b, 16)


_init_mouse_consts()
BUTTON_CTRL = _mouse_mask(6, 1)
BUTTON_SHIFT = _mouse_mask(6, 2)
BUTTON_ALT = _mouse_mask(6, 4)
REPORT_MOUSE_POSITION = _mouse_mask(6, 8)
ALL_MOUSE_EVENTS = REPORT_MOUSE_POSITION - 1

_KEYS = [("KEY_BREAK", 257), ("KEY_DOWN", 258), ("KEY_UP", 259), ("KEY_LEFT", 260), ("KEY_RIGHT", 261),
         ("KEY_HOME", 262), ("KEY_BACKSPACE", 263), ("KEY_F0", 264), ("KEY_DL", 328), ("KEY_IL", 329),
         ("KEY_DC", 330), ("KEY_IC", 331), ("KEY_EIC", 332), ("KEY_CLEAR", 333), ("KEY_EOS", 334),
         ("KEY_EOL", 335), ("KEY_SF", 336), ("KEY_SR", 337), ("KEY_NPAGE", 338), ("KEY_PPAGE", 339),
         ("KEY_STAB", 340), ("KEY_CTAB", 341), ("KEY_CATAB", 342), ("KEY_ENTER", 343), ("KEY_SRESET", 344),
         ("KEY_RESET", 345), ("KEY_PRINT", 346), ("KEY_LL", 347), ("KEY_A1", 348), ("KEY_A3", 349),
         ("KEY_B2", 350), ("KEY_C1", 351), ("KEY_C3", 352), ("KEY_BTAB", 353), ("KEY_BEG", 354),
         ("KEY_CANCEL", 355), ("KEY_CLOSE", 356), ("KEY_COMMAND", 357), ("KEY_COPY", 358),
         ("KEY_CREATE", 359), ("KEY_END", 360), ("KEY_EXIT", 361), ("KEY_FIND", 362), ("KEY_HELP", 363),
         ("KEY_MARK", 364), ("KEY_MESSAGE", 365), ("KEY_MOVE", 366), ("KEY_NEXT", 367), ("KEY_OPEN", 368),
         ("KEY_OPTIONS", 369), ("KEY_PREVIOUS", 370), ("KEY_REDO", 371), ("KEY_REFERENCE", 372),
         ("KEY_REFRESH", 373), ("KEY_REPLACE", 374), ("KEY_RESTART", 375), ("KEY_RESUME", 376),
         ("KEY_SAVE", 377), ("KEY_SBEG", 378), ("KEY_SCANCEL", 379), ("KEY_SCOMMAND", 380),
         ("KEY_SCOPY", 381), ("KEY_SCREATE", 382), ("KEY_SDC", 383), ("KEY_SDL", 384), ("KEY_SELECT", 385),
         ("KEY_SEND", 386), ("KEY_SEOL", 387), ("KEY_SEXIT", 388), ("KEY_SFIND", 389), ("KEY_SHELP", 390),
         ("KEY_SHOME", 391), ("KEY_SIC", 392), ("KEY_SLEFT", 393), ("KEY_SMESSAGE", 394),
         ("KEY_SMOVE", 395), ("KEY_SNEXT", 396), ("KEY_SOPTIONS", 397), ("KEY_SPREVIOUS", 398),
         ("KEY_SPRINT", 399), ("KEY_SREDO", 400), ("KEY_SREPLACE", 401), ("KEY_SRIGHT", 402),
         ("KEY_SRSUME", 403), ("KEY_SSAVE", 404), ("KEY_SSUSPEND", 405), ("KEY_SUNDO", 406),
         ("KEY_SUSPEND", 407), ("KEY_UNDO", 408), ("KEY_MOUSE", 409), ("KEY_RESIZE", 410)]


def _init_key_consts():
    g = globals()
    for name, value in _KEYS:
        g[name] = value
    for n in range(1, 64):
        g["KEY_F%d" % n] = 264 + n


_init_key_consts()
KEY_MIN = 257
KEY_MAX = 511

# ACS_* names and the VT100 letters they draw (set after initscr)
_ACS = [("ACS_ULCORNER", "l"), ("ACS_LLCORNER", "m"), ("ACS_URCORNER", "k"), ("ACS_LRCORNER", "j"),
        ("ACS_LTEE", "t"), ("ACS_RTEE", "u"), ("ACS_BTEE", "v"), ("ACS_TTEE", "w"), ("ACS_HLINE", "q"),
        ("ACS_VLINE", "x"), ("ACS_PLUS", "n"), ("ACS_S1", "o"), ("ACS_S9", "s"), ("ACS_DIAMOND", "`"),
        ("ACS_CKBOARD", "a"), ("ACS_DEGREE", "f"), ("ACS_PLMINUS", "g"), ("ACS_BULLET", "~"),
        ("ACS_LARROW", ","), ("ACS_RARROW", "+"), ("ACS_DARROW", "."), ("ACS_UARROW", "-"),
        ("ACS_BOARD", "h"), ("ACS_LANTERN", "i"), ("ACS_BLOCK", "0"), ("ACS_BSSB", "l"), ("ACS_SSBB", "m"),
        ("ACS_BBSS", "k"), ("ACS_SBBS", "j"), ("ACS_SBSS", "u"), ("ACS_SSSB", "t"), ("ACS_SSBS", "v"),
        ("ACS_BSSS", "w"), ("ACS_BSBS", "q"), ("ACS_SBSB", "x"), ("ACS_SSSS", "n"), ("ACS_S3", "p"),
        ("ACS_S7", "r"), ("ACS_LEQUAL", "y"), ("ACS_GEQUAL", "z"), ("ACS_PI", "{"), ("ACS_NEQUAL", "|"),
        ("ACS_STERLING", "}")]


# ── checks and conversions (CPython's _cursesmodule.c) ─────────────────────
def _initialised():
    if not _curses_started():
        raise error("must call initscr() first")


def _setupterm_done():
    if not _curses_setup_done():
        raise error("must call (at least) setupterm() first")


def _color_started():
    if not _curses_color_info()[0]:
        raise error("must call start_color() first")


def _ck(code, fname):
    if code == ERR:
        raise error(fname + "() returned ERR")
    return None


def _int(v):
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, int):
        return v
    idx = getattr(type(v), "__index__", None)
    if idx is not None:
        return idx(v)
    raise TypeError("'%s' object cannot be interpreted as an integer" % type(v).__name__)


def _cchar(obj):
    # PyCurses_ConvertToCchar_t: (value, is_char) - a str is a character
    if isinstance(obj, str):
        if len(obj) != 1:
            raise TypeError("expect bytes or str of length 1, or int, got a str of length %d" % len(obj))
        return (ord(obj), True)
    if isinstance(obj, (bytes, bytearray)) and len(obj) == 1:
        return (obj[0], False)
    if isinstance(obj, int) and not isinstance(obj, bool):
        if obj < -0x8000000000000000 or obj > 0x7fffffffffffffff:
            raise OverflowError("int doesn't fit in long")
        if obj < 0 or obj > 0xffffffff:
            raise OverflowError("byte doesn't fit in chtype")
        return (obj, False)
    raise TypeError("expect bytes or str of length 1, or int, got %s" % type(obj).__name__)


def _chtype(obj):
    # PyCurses_ConvertToChtype: a chtype; a str must be one byte in the
    # window's encoding (UTF-8: ASCII)
    if isinstance(obj, str):
        if len(obj) != 1:
            raise TypeError("expect bytes or str of length 1, or int, got a str of length %d" % len(obj))
        v = ord(obj)
        if v > 127:
            raise OverflowError("byte doesn't fit in chtype")
        return v
    if isinstance(obj, (bytes, bytearray)) and len(obj) == 1:
        return obj[0]
    if isinstance(obj, int) and not isinstance(obj, bool):
        if obj < 0 or obj > 0xffffffff:
            raise OverflowError("byte doesn't fit in chtype")
        return obj
    raise TypeError("expect bytes or str of length 1, or int, got %s" % type(obj).__name__)


def _text(obj):
    # PyCurses_ConvertToString: (text, wide)
    if isinstance(obj, str):
        if "\0" in obj:
            raise ValueError("embedded null character")
        return (obj, True)
    if isinstance(obj, (bytes, bytearray)):
        if b"\0" in obj:
            raise ValueError("embedded null character")
        return (bytes(obj), False)
    raise TypeError("expect bytes or str, got %s" % type(obj).__name__)


def _split(name, args, counts, msg=None):
    # the clinic's optional [y, x] group: which form a call takes
    n = len(args)
    if n not in counts:
        if msg is None:
            lo = min(counts)
            hi = max(counts)
            msg = "%s requires %d to %d arguments" % (name, lo, hi)
        raise TypeError(msg)
    return n


_TOKEN = object()


class window:
    """A curses window."""

    def __init__(self, *args):
        if len(args) != 2 or args[0] is not _TOKEN:
            raise TypeError("cannot create '_curses.window' instances")
        self._id = args[1]
        self._parent = None
        self._enc = "utf-8"

    def __del__(self):
        try:
            if self._id > 0 and _curses_started():
                _curses_delwin(self._id)
        except Exception:
            pass

    @property
    def encoding(self):
        return self._enc

    @encoding.setter
    def encoding(self, value):
        if not isinstance(value, str):
            raise TypeError("setting encoding to a non-string")
        self._enc = value

    @encoding.deleter
    def encoding(self):
        raise TypeError("encoding may not be deleted")

    def __repr__(self):
        return "<_curses.window object at 0x%x>" % id(self)

    # ── output ──────────────────────────────────────────────────────────
    def addch(self, *args):
        n = _split("addch", args, (1, 2, 3, 4))
        y = x = -1
        attr = A_NORMAL
        if n >= 3:
            y = _int(args[0])
            x = _int(args[1])
            args = args[2:]
        ch = args[0]
        if len(args) > 1:
            attr = _int(args[1])
        v, wide = _cchar(ch)
        return _ck(_curses_waddch(self._id, y, x, v, wide, attr), "add_wch" if wide else "addch")

    def _str_call(self, name, wname, native, args, with_n):
        counts = (2, 3, 4, 5) if with_n else (1, 2, 3, 4)
        n = _split(name, args, counts)
        y = x = -1
        nn = -1
        attr = 0
        use = 0
        if n >= counts[2]:
            y = _int(args[0])
            x = _int(args[1])
            args = args[2:]
        s = args[0]
        rest = args[1:]
        if with_n:
            nn = _int(rest[0])
            rest = rest[1:]
        if rest:
            attr = _int(rest[0])
            use = 1
        text, wide = _text(s)
        if native == "add":
            r = _curses_waddstr(self._id, y, x, text, nn, attr, use, wide)
        else:
            r = _curses_winsstr(self._id, y, x, text, nn, attr, use)
        return _ck(r, wname if wide else name)

    def addstr(self, *args):
        return self._str_call("addstr", "addwstr", "add", args, False)

    def addnstr(self, *args):
        return self._str_call("addnstr", "addnwstr", "add", args, True)

    def insstr(self, *args):
        return self._str_call("insstr", "inswstr", "ins", args, False)

    def insnstr(self, *args):
        return self._str_call("insnstr", "insn_wstr", "ins", args, True)

    def insch(self, *args):
        n = _split("insch", args, (1, 2, 3, 4))
        y = x = -1
        attr = A_NORMAL
        if n >= 3:
            y = _int(args[0])
            x = _int(args[1])
            args = args[2:]
        v = _chtype(args[0])
        if len(args) > 1:
            attr = _int(args[1])
        return _ck(_curses_winsch(self._id, y, x, v, False, attr), "insch")

    def echochar(self, ch, attr=A_NORMAL):
        v = _chtype(ch)
        return _ck(_curses_wechochar(self._id, v, False, _int(attr)), "echochar")

    def delch(self, *args):
        n = _split("delch", args, (0, 2), "delch requires 0 or 2 arguments")
        if n == 2:
            return _ck(_curses_wdelch(self._id, _int(args[0]), _int(args[1])), "mvwdelch")
        return _ck(_curses_wdelch(self._id, -1, -1), "wdelch")

    def deleteln(self):
        return _ck(_curses_winsdelln(self._id, -1), "wdeleteln")

    def insertln(self):
        return _ck(_curses_winsdelln(self._id, 1), "winsertln")

    def insdelln(self, nlines):
        return _ck(_curses_winsdelln(self._id, _int(nlines)), "winsdelln")

    def clear(self):
        return _ck(_curses_wclear(self._id), "wclear")

    def erase(self):
        return _ck(_curses_werase(self._id), "werase")

    def clrtoeol(self):
        return _ck(_curses_wclrtoeol(self._id), "wclrtoeol")

    def clrtobot(self):
        return _ck(_curses_wclrtobot(self._id), "wclrtobot")

    def border(self, ls=0, rs=0, ts=0, bs=0, tl=0, tr=0, bl=0, br=0):
        _curses_wborder(self._id, _chtype(ls), _chtype(rs), _chtype(ts), _chtype(bs),
                        _chtype(tl), _chtype(tr), _chtype(bl), _chtype(br))
        return None

    def box(self, *args):
        n = _split("box", args, (0, 2), "box requires 0 or 2 arguments")
        v = 0
        h = 0
        if n == 2:
            v = _chtype(args[0])
            h = _chtype(args[1])
        _curses_wborder(self._id, v, v, h, h, 0, 0, 0, 0)
        return None

    def _line(self, name, args):
        n = _split(name, args, (2, 3, 4, 5))
        y = x = -1
        attr = A_NORMAL
        if n >= 4:
            y = _int(args[0])
            x = _int(args[1])
            args = args[2:]
        v = _chtype(args[0])
        cnt = _int(args[1])
        if len(args) > 2:
            attr = _int(args[2])
        return _ck(_curses_whline(self._id, y, x, v, False, attr, cnt) if name == "hline"
                   else _curses_wvline(self._id, y, x, v, False, attr, cnt), name)

    def hline(self, *args):
        return self._line("hline", args)

    def vline(self, *args):
        return self._line("vline", args)

    # ── attributes ──────────────────────────────────────────────────────
    def attron(self, attr):
        return _ck(_curses_wattr(self._id, "on", _int(attr)), "attron")

    def attroff(self, attr):
        return _ck(_curses_wattr(self._id, "off", _int(attr)), "attroff")

    def attrset(self, attr):
        return _ck(_curses_wattr(self._id, "set", _int(attr)), "attrset")

    def standout(self):
        return _ck(_curses_wattr(self._id, "set", A_STANDOUT), "wstandout")

    def standend(self):
        return _ck(_curses_wattr(self._id, "set", A_NORMAL), "wstandend")

    def chgat(self, *args):
        n = len(args)
        if n == 1:
            return _ck(_curses_wchgat(self._id, -1, -1, -1, _int(args[0])), "chgat")
        if n == 2:
            return _ck(_curses_wchgat(self._id, -1, -1, _int(args[0]), _int(args[1])), "chgat")
        if n == 3:
            return _ck(_curses_wchgat(self._id, _int(args[0]), _int(args[1]), -1, _int(args[2])), "mvwchgat")
        if n == 4:
            return _ck(_curses_wchgat(self._id, _int(args[0]), _int(args[1]), _int(args[2]), _int(args[3])), "mvwchgat")
        raise TypeError("chgat requires 1 to 4 arguments")

    def bkgd(self, ch, attr=A_NORMAL):
        return _ck(_curses_wbkgd(self._id, _chtype(ch), False, _int(attr)), "bkgd")

    def bkgdset(self, ch, attr=A_NORMAL):
        _curses_wbkgdset(self._id, _chtype(ch), False, _int(attr))
        return None

    def getbkgd(self):
        return _curses_getbkgd(self._id)

    # ── reading the window ──────────────────────────────────────────────
    def inch(self, *args):
        n = _split("inch", args, (0, 2), "inch requires 0 or 2 arguments")
        if n == 2:
            return _curses_winch(self._id, _int(args[0]), _int(args[1]))
        return _curses_winch(self._id, -1, -1)

    def instr(self, *args):
        n = len(args)
        if n == 0:
            r = _curses_winstr(self._id, -1, -1, 1023)
        elif n == 1:
            k = _int(args[0])
            if k < 0:
                raise ValueError("'n' must be nonnegative")
            r = _curses_winstr(self._id, -1, -1, min(k, 1023))
        elif n == 2:
            r = _curses_winstr(self._id, _int(args[0]), _int(args[1]), 1023)
        elif n == 3:
            k = _int(args[2])
            if k < 0:
                raise ValueError("'n' must be nonnegative")
            r = _curses_winstr(self._id, _int(args[0]), _int(args[1]), min(k, 1023))
        else:
            raise TypeError("instr requires 0 or 3 arguments")
        return b"" if r is None else r

    # ── input ───────────────────────────────────────────────────────────
    def _yx(self, name, args):
        n = _split(name, args, (0, 2), "%s requires 0 or 2 arguments" % name)
        if n == 2:
            return (_int(args[0]), _int(args[1]))
        return (-1, -1)

    def getch(self, *args):
        y, x = self._yx("getch", args)
        return _curses_wgetch(self._id, y, x)

    def getkey(self, *args):
        y, x = self._yx("getkey", args)
        r = _curses_wgetch(self._id, y, x)
        if r == ERR:
            raise error("no input")
        if r <= 255:
            return chr(r)
        return _curses_keyname(r).decode("latin-1")

    def get_wch(self, *args):
        y, x = self._yx("get_wch", args)
        r = _curses_wget_wch(self._id, y, x)
        if r[0] <= 0:
            raise error("no input")
        if r[0] == 2:
            return r[1]
        return chr(r[1])

    def getstr(self, *args):
        n = len(args)
        y = x = -1
        k = 1023
        if n == 1:
            k = _int(args[0])
        elif n == 2:
            y = _int(args[0])
            x = _int(args[1])
        elif n == 3:
            y = _int(args[0])
            x = _int(args[1])
            k = _int(args[2])
        elif n != 0:
            raise TypeError("getstr requires 0 to 3 arguments")
        if k < 0:
            raise ValueError("'n' must be nonnegative")
        r = _curses_wgetstr(self._id, y, x, min(k, 1023))
        return b"" if r is None else r

    # ── position and size ───────────────────────────────────────────────
    def move(self, new_y, new_x):
        return _ck(_curses_wmove(self._id, _int(new_y), _int(new_x)), "wmove")

    def getyx(self):
        return tuple(_curses_wgetyx(self._id, 0))

    def getbegyx(self):
        return tuple(_curses_wgetyx(self._id, 1))

    def getmaxyx(self):
        return tuple(_curses_wgetyx(self._id, 2))

    def getparyx(self):
        return tuple(_curses_wgetyx(self._id, 3))

    def mvwin(self, new_y, new_x):
        return _ck(_curses_mvwin(self._id, _int(new_y), _int(new_x)), "mvwin")

    def mvderwin(self, y, x):
        return _ck(_curses_mvderwin(self._id, _int(y), _int(x)), "mvderwin")

    def resize(self, nlines, ncols):
        return _ck(_curses_wresize(self._id, _int(nlines), _int(ncols)), "wresize")

    def enclose(self, y, x):
        return _curses_wenclose(self._id, _int(y), _int(x))

    # ── subwindows ──────────────────────────────────────────────────────
    def _sub(self, name, args, relative):
        n = _split(name, args, (2, 4), "%s requires 2 or 4 arguments" % name)
        nlines_ = ncols_ = 0
        if n == 4:
            nlines_ = _int(args[0])
            ncols_ = _int(args[1])
            args = args[2:]
        by = _int(args[0])
        bx = _int(args[1])
        wid = _curses_subwin(self._id, nlines_, ncols_, by, bx, relative)
        if wid < 0:
            raise error("curses function returned NULL")
        w = window(_TOKEN, wid)
        w._parent = self
        w._enc = self._enc
        return w

    def subwin(self, *args):
        return self._sub("subwin", args, 1 if _curses_wflag(self._id, "is_pad", -1) else 0)

    def derwin(self, *args):
        return self._sub("derwin", args, 1)

    def subpad(self, *args):
        return self._sub("subpad", args, 1)

    # ── refreshing ──────────────────────────────────────────────────────
    def refresh(self, *args):
        if len(args) not in (0, 6):
            raise TypeError("refresh requires 0 to 6 arguments")
        if _curses_wflag(self._id, "is_pad", -1):
            if len(args) != 6:
                raise error("refresh() for a pad requires 6 arguments")
            a = [_int(v) for v in args]
            return _ck(_curses_prefresh(self._id, a[0], a[1], a[2], a[3], a[4], a[5], 1), "prefresh")
        if args:
            raise TypeError("refresh() takes no arguments (6 given)")
        return _ck(_curses_wrefresh(self._id), "prefresh")

    def noutrefresh(self, *args):
        if len(args) not in (0, 6):
            raise TypeError("noutrefresh requires 0 to 6 arguments")
        if _curses_wflag(self._id, "is_pad", -1):
            if len(args) != 6:
                raise error("noutrefresh() called for a pad requires 6 arguments")
            a = [_int(v) for v in args]
            return _ck(_curses_prefresh(self._id, a[0], a[1], a[2], a[3], a[4], a[5], 0), "pnoutrefresh")
        if args:
            raise TypeError("noutrefresh() takes no arguments (6 given)")
        return _ck(_curses_wnoutrefresh(self._id), "wnoutrefresh")

    def redrawwin(self):
        return _ck(_curses_redrawln(self._id, 0, self.getmaxyx()[0]), "redrawwin")

    def redrawln(self, beg, num):
        return _ck(_curses_redrawln(self._id, _int(beg), _int(num)), "redrawln")

    def touchwin(self):
        return _ck(_curses_touch(self._id, "win"), "touchwin")

    def untouchwin(self):
        return _ck(_curses_touch(self._id, "untouch"), "untouchwin")

    def touchline(self, start, count, changed=True):
        return _ck(_curses_touch(self._id, "line", _int(start), _int(count), 1 if changed else 0), "touchline")

    def is_wintouched(self):
        return bool(_curses_is_touched(self._id, -1))

    def is_linetouched(self, line):
        r = _curses_is_touched(self._id, _int(line))
        if r is ERR or (not isinstance(r, bool) and r == ERR):
            raise error("is_linetouched: line number outside of boundaries")
        return bool(r)

    def syncup(self):
        _curses_sync(self._id, "up")

    def syncdown(self):
        _curses_sync(self._id, "down")

    def cursyncup(self):
        _curses_sync(self._id, "cursor")

    # ── options ─────────────────────────────────────────────────────────
    def _flag(self, name, flag, fname=None):
        r = _curses_wflag(self._id, name, 1 if flag else 0)
        if fname is not None:
            return _ck(r, fname)
        return None

    def scrollok(self, flag):
        return self._flag("scrollok", flag, "scrollok")

    def idlok(self, flag):
        return self._flag("idlok", flag, "idlok")

    def idcok(self, flag):
        return self._flag("idcok", flag)

    def immedok(self, flag):
        return self._flag("immedok", flag)

    def leaveok(self, flag):
        return self._flag("leaveok", flag, "leaveok")

    def clearok(self, flag):
        return self._flag("clearok", flag, "clearok")

    def syncok(self, flag):
        return self._flag("syncok", flag, "syncok")

    def keypad(self, flag):
        return self._flag("keypad", flag, "keypad")

    def nodelay(self, flag):
        return self._flag("nodelay", flag, "nodelay")

    def notimeout(self, flag):
        return self._flag("notimeout", flag, "notimeout")

    def timeout(self, delay):
        _curses_wtimeout(self._id, _int(delay))
        return None

    def setscrreg(self, top, bottom):
        return _ck(_curses_wsetscrreg(self._id, _int(top), _int(bottom)), "wsetscrreg")

    def scroll(self, lines=1):
        return _ck(_curses_wscrl(self._id, _int(lines)), "scroll")

    # ── copying ─────────────────────────────────────────────────────────
    def _copy(self, name, destwin, args, over):
        if not isinstance(destwin, window):
            raise TypeError("%s() argument 1 must be _curses.window, not %s" % (name, type(destwin).__name__))
        if len(args) == 0:
            return _ck(_curses_overlay(self._id, destwin._id, 1 if over else 0), name)
        if len(args) != 6:
            raise TypeError("%s requires 1 to 7 arguments" % name)
        a = [_int(v) for v in args]
        return _ck(_curses_copywin(self._id, destwin._id, a[0], a[1], a[2], a[3], a[4], a[5], 1 if over else 0), "copywin")

    def overlay(self, destwin, *args):
        return self._copy("overlay", destwin, args, True)

    def overwrite(self, destwin, *args):
        return self._copy("overwrite", destwin, args, False)

    def putwin(self, file):
        data = _curses_putwin(self._id)
        if data is None:
            raise error("putwin() returned ERR")
        file.write(data)
        return None


# ── the screen ──────────────────────────────────────────────────────────────
_stdscr = None


def _set_lines_cols():
    lc = _curses_lines_cols()
    g = globals()
    g["LINES"] = lc[0]
    g["COLS"] = lc[1]


def initscr():
    global _stdscr
    if _curses_started():
        if _stdscr is not None:
            _stdscr.refresh()
            return _stdscr
    try:
        _sys.stdout.flush()
    except Exception:
        pass
    r = _curses_initscr()
    if isinstance(r, str):
        raise error(r)
    _stdscr = window(_TOKEN, r)
    g = globals()
    amap = _curses_acs_map()
    for name, letter in _ACS:
        v = amap[ord(letter)]
        if v == 0:
            v = A_ALTCHARSET | ord(letter)
        g[name] = v
    _set_lines_cols()
    return _stdscr


def endwin():
    _initialised()
    return _ck(_curses_endwin(), "endwin")


def isendwin():
    _initialised()
    return _curses_isendwin()


def doupdate():
    _initialised()
    return _ck(_curses_doupdate(), "doupdate")


def newwin(*args):
    _initialised()
    n = _split("newwin", args, (2, 4), "newwin requires 2 to 4 arguments")
    by = bx = 0
    nlines_ = _int(args[0])
    ncols_ = _int(args[1])
    if n == 4:
        by = _int(args[2])
        bx = _int(args[3])
    wid = _curses_newwin(nlines_, ncols_, by, bx)
    if wid < 0:
        raise error("curses function returned NULL")
    return window(_TOKEN, wid)


def newpad(nlines, ncols):
    _initialised()
    wid = _curses_newpad(_int(nlines), _int(ncols))
    if wid < 0:
        raise error("curses function returned NULL")
    return window(_TOKEN, wid)


def getwin(file):
    _initialised()
    data = file.read()
    if not isinstance(data, bytes):
        raise TypeError("f.read() returned %.100s instead of bytes" % type(data).__name__)
    wid = _curses_getwin(data)
    if wid < 0:
        raise error("getwin() returned ERR")
    return window(_TOKEN, wid)


# ── modes ───────────────────────────────────────────────────────────────────
def _mode(name, flag, fname):
    _initialised()
    return _ck(_curses_mode(name, 1 if flag else 0), fname)


def cbreak(flag=True):
    return _mode("cbreak", flag, "cbreak" if flag else "nocbreak")


def nocbreak():
    return _mode("cbreak", False, "nocbreak")


def raw(flag=True):
    return _mode("raw", flag, "raw" if flag else "noraw")


def noraw():
    return _mode("raw", False, "noraw")


def echo(flag=True):
    return _mode("echo", flag, "echo" if flag else "noecho")


def noecho():
    return _mode("echo", False, "noecho")


def nl(flag=True):
    return _mode("nl", flag, "nl" if flag else "nonl")


def nonl():
    return _mode("nl", False, "nonl")


def halfdelay(tenths):
    _initialised()
    return _ck(_curses_mode("halfdelay", _int(tenths)), "halfdelay")


def intrflush(flag):
    _initialised()
    return _ck(_curses_mode("intrflush", 1 if flag else 0), "intrflush")


def qiflush(flag=True):
    _initialised()
    _curses_mode("qiflush", 1 if flag else 0)


def noqiflush():
    _initialised()
    _curses_mode("qiflush", 0)


def meta(yes):
    _initialised()
    return _ck(_curses_mode("meta", 1 if yes else 0), "meta")


def savetty():
    _initialised()
    return _ck(_curses_mode("savetty", 1), "savetty")


def resetty():
    _initialised()
    return _ck(_curses_mode("resetty", 1), "resetty")


def def_prog_mode():
    _initialised()
    return _ck(_curses_mode("def_prog_mode", 1), "def_prog_mode")


def def_shell_mode():
    _initialised()
    return _ck(_curses_mode("def_shell_mode", 1), "def_shell_mode")


def reset_prog_mode():
    _initialised()
    return _ck(_curses_mode("reset_prog_mode", 1), "reset_prog_mode")


def reset_shell_mode():
    _initialised()
    return _ck(_curses_mode("reset_shell_mode", 1), "reset_shell_mode")


def typeahead(fd):
    _initialised()
    return _ck(_curses_mode("typeahead", _int(fd)), "typeahead")


def flushinp():
    _initialised()
    _curses_flushinp()


def beep():
    _initialised()
    return _ck(_curses_beep(), "beep")


def flash():
    _initialised()
    return _ck(_curses_flash(), "flash")


def napms(ms):
    _initialised()
    _curses_napms(_int(ms))
    return 0


def delay_output(ms):
    _initialised()
    return _ck(_curses_napms(_int(ms)), "delay_output")


def curs_set(visibility):
    _initialised()
    r = _curses_curs_set(_int(visibility))
    if r == ERR:
        raise error("curs_set() returned ERR")
    return r


def baudrate():
    _initialised()
    return _curses_baudrate()


def erasechar():
    _initialised()
    return _curses_erasechar()


def killchar():
    _initialised()
    return _curses_killchar()


def termname():
    _initialised()
    return _curses_termname()


def longname():
    _initialised()
    return _curses_longname()


def termattrs():
    _initialised()
    return _curses_termattrs()


def has_ic():
    _initialised()
    return _curses_has_ic()


def has_il():
    _initialised()
    return _curses_has_il()


def has_key(key):
    _initialised()
    return _curses_has_key(_int(key))


def keyname(key):
    _initialised()
    key = _int(key)
    if key < 0:
        raise ValueError("invalid key number")
    return _curses_keyname(key)


def unctrl(ch):
    _initialised()
    return _curses_unctrl(_chtype(ch))


def ungetch(ch):
    _initialised()
    return _ck(_curses_ungetch(_chtype(ch)), "ungetch")


def unget_wch(ch):
    _initialised()
    if isinstance(ch, str):
        if len(ch) != 1:
            raise TypeError("expect str of length 1 or int, got a str of length %d" % len(ch))
        ch = ord(ch)
    elif not isinstance(ch, int) or isinstance(ch, bool):
        raise TypeError("expect str of length 1 or int, got %s" % type(ch).__name__)
    return _ck(_curses_unget_wch(ch), "unget_wch")


def filter():
    _curses_filter()


def use_env(flag):
    _curses_use_env(1 if flag else 0)


def getsyx():
    _initialised()
    return tuple(_curses_getsyx())


def setsyx(y, x):
    _initialised()
    _curses_setsyx(_int(y), _int(x))


def set_escdelay(ms):
    ms = _int(ms)
    if ms <= 0:
        raise ValueError("ms must be > 0")
    _curses_escdelay(ms)


def get_escdelay():
    return _curses_escdelay(-1)


def set_tabsize(size):
    size = _int(size)
    if size <= 0:
        raise ValueError("size must be > 0")
    _curses_tabsize(size)


def get_tabsize():
    return _curses_tabsize(-1)


def update_lines_cols():
    _set_lines_cols()
    m = _sys.modules.get("curses")
    if m is not None:
        m.LINES = LINES
        m.COLS = COLS


def resizeterm(nlines, ncols):
    _initialised()
    r = _ck(_curses_resizeterm(_int(nlines), _int(ncols)), "resizeterm")
    update_lines_cols()
    return r


def resize_term(nlines, ncols):
    _initialised()
    r = _ck(_curses_resizeterm(_int(nlines), _int(ncols)), "resize_term")
    update_lines_cols()
    return r


def is_term_resized(nlines, ncols):
    _initialised()
    return _curses_is_term_resized(_int(nlines), _int(ncols))


# ── mouse ───────────────────────────────────────────────────────────────────
def mousemask(newmask):
    _initialised()
    r = _curses_mousemask(_int(newmask))
    return (r[0], r[1])


def mouseinterval(interval):
    _initialised()
    _curses_mouseinterval(_int(interval))
    return None


def getmouse():
    _initialised()
    r = _curses_getmouse()
    if r is None:
        raise error("getmouse() returned ERR")
    return (r[0], r[1], r[2], r[3], r[4])


def ungetmouse(id, x, y, z, bstate):
    _initialised()
    return _ck(_curses_ungetmouse(_int(id), _int(x), _int(y), _int(z), _int(bstate)), "ungetmouse")


# ── colors ──────────────────────────────────────────────────────────────────
def start_color():
    _initialised()
    if _curses_start_color() == ERR:
        raise error("start_color() returned ERR")
    info = _curses_color_info()
    g = globals()
    g["COLORS"] = info[1]
    g["COLOR_PAIRS"] = info[2]
    return None


def has_colors():
    _initialised()
    return _curses_has_colors()


def can_change_color():
    _initialised()
    return _curses_can_change_color()


def has_extended_color_support():
    return True


def _color_number(c):
    c = _int(c)
    info = _curses_color_info()
    colors = info[1] if info[0] else (info[3] if info[3] > 0 else -1)
    if c < 0:
        raise ValueError("Color number is less than 0.")
    if c > colors - 1:
        raise ValueError("Color number is greater than COLORS-1 (%d)." % (colors - 1))
    return c


def _pair_number(p):
    p = _int(p)
    info = _curses_color_info()
    pairs = info[2] if info[0] else (info[4] if info[4] > 0 else -1)
    if p < 0:
        raise ValueError("Color pair is less than 0.")
    if p > pairs - 1:
        raise ValueError("Color pair is greater than COLOR_PAIRS-1 (%d)." % (pairs - 1))
    return p


def _color_value(c):
    # a color of a pair: -1 allowed (the default color)
    c = _int(c)
    info = _curses_color_info()
    colors = info[1] if info[0] else (info[3] if info[3] > 0 else -1)
    if c < -1:
        raise ValueError("Color number is less than -1.")
    if c > colors - 1:
        raise ValueError("Color number is greater than COLORS-1 (%d)." % (colors - 1))
    return c


def color_pair(pair_number):
    _initialised()
    _color_started()
    return (_int(pair_number) & 0xff) << 8


def pair_number(attr):
    _initialised()
    _color_started()
    return (_int(attr) & A_COLOR) >> 8


def init_pair(pair_number, fg, bg):
    _initialised()
    _color_started()
    p = _pair_number(pair_number)
    f = _color_value(fg)
    b = _color_value(bg)
    return _ck(_curses_init_pair(p, f, b), "init_extended_pair")


def pair_content(pair_number):
    _initialised()
    _color_started()
    p = _pair_number(pair_number)
    r = _curses_pair_content(p)
    if r is None:
        raise error("extended_pair_content() returned ERR")
    return (r[0], r[1])


def init_color(color_number, r, g, b):
    _initialised()
    _color_started()
    c = _color_number(color_number)
    for v in (r, g, b):
        v = _int(v)
        if v < 0:
            raise ValueError("Color component is less than 0")
        if v > 1000:
            raise ValueError("Color component is greater than 1000")
    return _ck(_curses_init_color(c, _int(r), _int(g), _int(b)), "init_extended_color")


def color_content(color_number):
    _initialised()
    _color_started()
    c = _color_number(color_number)
    r = _curses_color_content(c)
    if r is None:
        raise error("extended_color_content() returned ERR")
    return (r[0], r[1], r[2])


def use_default_colors():
    _initialised()
    _color_started()
    return _ck(_curses_use_default_colors(), "use_default_colors")


# ── terminfo ────────────────────────────────────────────────────────────────
def setupterm(term=None, fd=-1):
    if term is not None and not isinstance(term, str):
        raise TypeError("setupterm() argument 'term' must be str or None, not %s" % type(term).__name__)
    if term is not None and "\0" in term:
        raise ValueError("embedded null character")
    fd = _int(fd)
    if fd == -1:
        try:
            fd = _sys.stdout.fileno()
        except Exception:
            raise error("lost sys.stdout")
    if _curses_setup_done():
        return None          # as CPython: only the first call counts
    r = _curses_setupterm(term, fd)
    if r:
        raise error(r)
    return None


def _capname(capname):
    if not isinstance(capname, str):
        raise TypeError("argument must be str, not %s" % type(capname).__name__)
    return capname


def tigetflag(capname):
    _setupterm_done()
    return _curses_tigetflag(_capname(capname))


def tigetnum(capname):
    _setupterm_done()
    return _curses_tigetnum(_capname(capname))


def tigetstr(capname):
    _setupterm_done()
    return _curses_tigetstr(_capname(capname))


def tparm(str, i1=0, i2=0, i3=0, i4=0, i5=0, i6=0, i7=0, i8=0, i9=0):
    _setupterm_done()
    if not isinstance(str, (bytes, bytearray)):
        raise TypeError("a bytes-like object is required, not '%s'" % type(str).__name__)
    args = [_int(v) for v in (i1, i2, i3, i4, i5, i6, i7, i8, i9)]
    r = _curses_tparm(bytes(str), args)
    if r is None:
        raise error("tparm() returned NULL")
    return r


def putp(string):
    _setupterm_done()
    if not isinstance(string, (bytes, bytearray)):
        raise TypeError("putp() argument must be bytes, not %s" % type(string).__name__)
    try:
        _sys.stdout.flush()
    except Exception:
        pass
    return _ck(_curses_putp(bytes(string)), "putp")


# ── Nython additions ────────────────────────────────────────────────────────
def nython_stats():
    """(bytes written to the terminal, doupdate calls, update mode)."""
    r = _curses_stats()
    return (r[0], r[1], r[2])


def nython_terminfo():
    """The terminfo entry setupterm() loaded: (names, path, extended
    numbers, flags, numbers, strings) - path is "" for a built-in entry."""
    _setupterm_done()
    r = _curses_term_info()
    return (r[0], r[1], r[2], list(r[3]), dict((p[0], p[1]) for p in r[4]), dict((p[0], p[1]) for p in r[5]))
