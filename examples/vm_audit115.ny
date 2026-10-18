# vm_audit115.ny - curses without ncurses, and a terminal emulator to test it
# (round 84).
#
# lib/_curses.ny + builtins/nycurses.cpp are Nython's own curses (terminfo,
# tparm, the screen model, an optimizing doupdate, key decoding); the
# programs below run under a pseudo-terminal, in this runtime, and their
# output is fed to lib/_nyvt.ny (a VT100/xterm emulator written in the
# subset CPython runs too). The checks are on the emulated screens' cells -
# characters, colors, attributes, the cursor - after each step of a program,
# compared with CPython + ncurses running the same program in the same
# emulator: live when the container's python3 has _curses, else with the
# screens recorded from it (EXPECTED, written by `python3
# examples/vm_audit115.ny --record`, tools/gen_vm_audit115.py).
#
# Also: terminfo entries read by both against infocmp (the legacy and the
# 32-bit number formats, extended capabilities, the search path, the
# hexadecimal directory layout, the built-in entries), tparm, the emulator's
# own parser, and the bytes doupdate writes for a scrolling and a partial-
# update workload against a naive full repaint (Nython-only numbers, printed).
#
# The shared part runs under python3 too (`python3 examples/vm_audit115.ny`):
# there the programs run under CPython's curses, and every expected value is
# CPython's.
#
#     ./build/nython-cli examples/vm_audit115.ny
#     ./build/nython-cli --vm examples/vm_audit115.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import os
import sys
import time

pass_n = 0
fail_n = 0
skip_n = 0
results = []


def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])


HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

if nython:
    import _nyvt
else:
    import importlib.machinery
    import importlib.util
    _loader = importlib.machinery.SourceFileLoader("_nyvt", os.path.join(ROOT, "lib", "_nyvt.ny"))
    _spec = importlib.util.spec_from_loader("_nyvt", _loader)
    _nyvt = importlib.util.module_from_spec(_spec)
    _loader.exec_module(_nyvt)

RECORD = "--record" in sys.argv
POSIX = os.name == "posix"
ENGINE = []
if nython and "--vm" in getattr(sys, "orig_argv", []):
    ENGINE = ["--vm"]

# ═══════════════════════════════════════════════════════════════════════════
# 1. the emulator on its own
# ═══════════════════════════════════════════════════════════════════════════
T = _nyvt.Terminal


def term(data, rows=5, cols=10):
    t = T(rows, cols)
    t.feed(data)
    return t


def test_emulator():
    # the emulator's parser and screen
    global skip_n
    t = term(b"hello")
    check("vt: text and cursor", [t.line(0), t.cursor()], ["hello     ", (0, 5)])
    t = term(b"abcdefghijXY")
    check("vt: autowrap after the last column", [t.line(0), t.line(1), t.cursor()], ["abcdefghij", "XY        ", (1, 2)])
    t = term(b"abcdefghij")
    check("vt: pending wrap (xenl) keeps the cursor on the margin", [t.cursor(), t.wrap_pending], [(0, 9), True])
    t = term(b"abcdefghij\r\nZ")
    check("vt: CR LF after a pending wrap is one line", [t.line(1)[:1], t.cursor()], ["Z", (1, 1)])
    t = term(b"abcdefghij\x1b[?7lXY")
    check("vt: DECAWM off overwrites the last column", [t.line(0), t.line(1)], ["abcdefghiY", "          "])
    t = term(b"\x1b[1;31mR\x1b[0m\x1b[4;38;5;200;48;2;1;2;3mU\x1b[mN")
    c0 = t.cell(0, 0)
    c1 = t.cell(0, 1)
    c2 = t.cell(0, 2)
    check("vt: SGR bold + 8 colors", [c0.ch, c0.fg, c0.bg, c0.bold], ["R", 1, -1, True])
    check("vt: SGR 256 colors and direct color", [c1.fg, c1.bg, c1.underline, c1.bold], [200, 0x1000000 | 0x010203, True, False])
    check("vt: SGR 0 resets", [c2.fg, c2.bg, c2.flags], [-1, -1, 0])
    t = term(b"\x1b[38:5:9mA\x1b[38:2::4:5:6mB\x1b[91;102mC\x1b[22;3;5;7;8;9mD\x1b[23;25;27;28;29mE")
    check("vt: SGR sub-parameters and bright colors",
          [t.cell(0, 0).fg, t.cell(0, 1).fg, t.cell(0, 2).fg, t.cell(0, 2).bg],
          [9, 0x1000000 | 0x040506, 9, 10])
    check("vt: SGR italic/blink/reverse/invisible/strike and their resets",
          [t.cell(0, 3).attrs(), t.cell(0, 4).attrs()],
          [["italic", "blink", "reverse", "invisible", "strike"], []])
    t = term(b"\x1b[2;3Hx\x1b[Hy\x1b[5;10Hz\x1b[99;99Hw")
    check("vt: CUP, home, clamping", [t.raw(1, 2)[0], t.raw(0, 0)[0], t.raw(4, 9)[0], t.cursor()], ["x", "y", "w", (4, 9)])
    t = term(b"\x1b[3;5H\x1b[2A\x1b[3C\x1b[1B\x1b[2D*")
    check("vt: CUU CUF CUD CUB", t.cursor(), (1, 6))
    t = term(b"\x1b[3G\x1b[2d*\x1b[5`+\x1b[2a-\x1b[e.")
    check("vt: CHA VPA HPA HPR VPR", [t.line(1), t.line(2)], ["  * +  -  ", "        . "])
    t = term(b"0123456789\r\x1b[3@AB")
    check("vt: ICH inserts blanks", t.line(0), "AB 0123456")
    t = term(b"0123456789\r\x1b[2C\x1b[3P")
    check("vt: DCH deletes", t.line(0), "0156789   ")
    t = term(b"0123456789\r\x1b[2C\x1b[3X")
    check("vt: ECH erases in place", [t.line(0), t.cursor()], ["01   56789", (0, 2)])
    t = term(b"0123456789\r\x1b[4h\x1b[2CAB\x1b[4l")
    check("vt: insert mode (IRM)", t.line(0), "01AB234567")
    t = term(b"a\r\nb\r\nc\r\nd\r\ne\x1b[2;4r\x1b[4;1H\n")
    check("vt: DECSTBM: a line feed at the bottom margin scrolls the region", t.display(), ["a         ", "c         ", "d         ", "          ", "e         "])
    t = term(b"a\r\nb\r\nc\r\nd\r\ne\x1b[2;4r\x1b[2;1H\x1bM")
    check("vt: RI at the top margin scrolls down", t.display(), ["a         ", "          ", "b         ", "c         ", "e         "])
    t = term(b"a\r\nb\r\nc\r\nd\r\ne\x1b[2;1H\x1b[2L")
    check("vt: IL", t.display(), ["a         ", "          ", "          ", "b         ", "c         "])
    t = term(b"a\r\nb\r\nc\r\nd\r\ne\x1b[2;1H\x1b[2M")
    check("vt: DL", t.display(), ["a         ", "d         ", "e         ", "          ", "          "])
    t = term(b"a\r\nb\r\nc\r\nd\r\ne\x1b[2S")
    check("vt: SU", t.display()[0:3], ["c         ", "d         ", "e         "])
    t = term(b"0123456789\x1b[1;5H\x1b[K")
    check("vt: EL 0", t.line(0), "0123      ")
    t = term(b"0123456789\x1b[1;5H\x1b[1K")
    check("vt: EL 1", t.line(0), "     56789")
    t = term(b"aaaa\r\nbbbb\r\ncccc\x1b[2;2H\x1b[J")
    check("vt: ED 0", t.display()[0:3], ["aaaa      ", "b         ", "          "])
    t = term(b"aaaa\r\nbbbb\r\ncccc\x1b[2;2H\x1b[1J")
    check("vt: ED 1", t.display()[0:3], ["          ", "  bb      ", "cccc      "])
    t = term(b"\x1b[44m\x1b[2J\x1b[m")
    check("vt: back-color erase", [t.cell(3, 3).bg, t.cell(3, 3).ch], [4, " "])
    t = term(b"\x1b(0lqqk\x1b(Bq\x0e\x1b)0x\x0fx")
    check("vt: DEC special graphics, G0/G1, SI/SO", t.line(0)[:7], "\u250c\u2500\u2500\u2510q\u2502x")
    t = term(b"\x1b[1;31m\x1b[2;3H\x1b7\x1b[m\x1b[5;5H\x1b8X")
    check("vt: DECSC/DECRC restore position and attributes", [t.raw(1, 2), t.cursor()], [("X", 1, -1, 1), (1, 3)])
    t = term(b"main\x1b[?1049h\x1b[Halt\x1b[?1049l")
    check("vt: alternate screen 1049", [t.line(0), t.alt_active, t.cursor()], ["main      ", False, (0, 4)])
    t = term(b"main\x1b[?1049hALT")
    check("vt: the alternate screen starts blank, the cursor stays", [t.line(0), t.alt_active], ["    ALT   ", True])
    t = term("\u4e2d\u6587x".encode("utf-8"))
    check("vt: wide characters take two cells", [t.line(0), t.raw(0, 1)[0], t.cursor()], ["\u4e2d\u6587x     ", "", (0, 5)])
    t = term("abcdefghi\u4e2d".encode("utf-8"))
    check("vt: a wide character that does not fit wraps", [t.line(0), t.line(1)[:1]], ["abcdefghi ", "\u4e2d"])
    t = term("\u4e2d\u6587".encode("utf-8") + b"\x1b[1;2HX")
    check("vt: overwriting half of a wide character", t.line(0), " X\u6587      ")
    t = term("e\u0301x".encode("utf-8"))
    check("vt: combining marks join the cell before", [t.raw(0, 0)[0], t.cursor()], ["e\u0301", (0, 2)])
    t = T(3, 10)
    data = "\u00e9\u4e2d".encode("utf-8")
    for i in range(len(data)):
        t.feed(data[i:i + 1])
    check("vt: UTF-8 split across feeds", t.line(0)[:2], "\u00e9\u4e2d")
    t = term(b"a\x1b[3b")
    check("vt: REP", t.line(0), "aaaa      ")
    t = term(b"\tx\x1b[3g\r\tY\x1bH\r\tZ")
    check("vt: tabs, TBC, HTS", t.line(0), "        xZ")
    t = term(b"\x1b[3;4H\x1b[6n\x1b[5n\x1b[c")
    check("vt: DSR/CPR/DA replies", t.responses, b"\x1b[3;4R\x1b[0n\x1b[?62;22c")
    t = term(b"\x1b]0;my title\x07\x1b]2;second\x1b\\\x1b]777;ready\x07x")
    check("vt: OSC title and strings", [t.title, t.osc, t.line(0)[:1]], ["second", ["0;my title", "2;second", "777;ready"], "x"])
    t = term(b"\x1b[1;3\x18X\x1b[2\x1aY")
    check("vt: CAN and SUB abort a sequence", t.line(0)[:2], "XY")
    t = term(b"\x1b[2\r;3HZ")
    check("vt: C0 controls run inside a CSI", t.cursor(), (1, 3))
    t = term(b"\x1bP1$qm\x1b\\ok")
    check("vt: DCS strings are consumed", t.line(0)[:2], "ok")
    t = term(b"\x1b[?1h\x1b[?1000h\x1b[?1006h\x1b[?25l\x1b[?2004h")
    check("vt: DEC private modes", [t.app_cursor, sorted(t.mouse), t.cursor_visible, t.bracketed_paste], [True, [1000, 1006], False, True])
    check("vt: keys follow DECCKM", [t.key("up"), t.key("f1"), t.key("f5"), t.key("pageup"), t.key("up", ctrl=True),
                                     t.key("a", ctrl=True), t.key("x", alt=True), t.key("tab", shift=True)],
          [b"\x1bOA", b"\x1bOP", b"\x1b[15~", b"\x1b[5~", b"\x1b[1;5A", b"\x01", b"\x1bx", b"\x1b[Z"])
    check("vt: SGR mouse reports", [t.mouse_event(1, 2, 4), t.mouse_event(1, 2, 4, press=False), t.mouse_event(4, 0, 0)],
          [b"\x1b[<0;5;3M", b"\x1b[<0;5;3m", b"\x1b[<64;1;1M"])
    t2 = T(3, 10)
    check("vt: X10 mouse reports", t2.mouse_event(1, 2, 4), b"\x1b[M\x20\x25\x23")
    t = term(b"\x1b#8")
    check("vt: DECALN", t.line(2), "EEEEEEEEEE")
    t = term(b"x\x1b[?5h\x1b[?5l\x07\x07")
    check("vt: flash and bell", [t.flashes, t.bells], [1, 2])
    t = term(b"\x1b[?6h\x1b[2;4r\x1b[1;1HO")
    check("vt: origin mode", t.raw(1, 0)[0], "O")
    t = term(b"abc\x1bc")
    check("vt: RIS", [t.line(0), t.cursor()], ["          ", (0, 0)])
    t = term(b"hello\r\nworld")
    t.resize(3, 4)
    check("vt: resize keeps what fits", [t.display(), t.cursor()], [["hell", "worl", "    "], (1, 3)])
    check("vt: wcwidth", [_nyvt.wcwidth("a"), _nyvt.wcwidth("\u4e2d"), _nyvt.wcwidth("\u0301"), _nyvt.wcwidth("\U0001f600")], [1, 2, 0, 2])
    check("vt: render()", _nyvt.render(b"\x1b[2;2Hhi", 3, 5), ["     ", " hi  ", "     "])
    check("vt: visible() folds what nobody sees", [term(b"\x1b[1;31m \x1b[7m ").visible(0, 0), term(b"\x1b[1;31m \x1b[7m ").visible(0, 1)],
          [(" ", -1, -1, 0), (" ", -1, 1, 0)])


test_emulator()


# ═══════════════════════════════════════════════════════════════════════════
# 2. the module without a screen
# ═══════════════════════════════════════════════════════════════════════════
import curses
import curses.ascii
import curses.panel
import curses.textpad
import curses.has_key


def err(f, *args):
    try:
        f(*args)
        return None
    except Exception as e:
        return [type(e).__name__, str(e)]


def test_module():
    # constants, errors, terminfo and tparm in this process
    global skip_n
    check("constants: attributes", [curses.A_BOLD, curses.A_REVERSE, curses.A_UNDERLINE, curses.A_STANDOUT, curses.A_DIM,
                                    curses.A_BLINK, curses.A_ALTCHARSET, curses.A_INVIS, curses.A_ITALIC, curses.A_CHARTEXT,
                                    curses.A_COLOR, curses.A_ATTRIBUTES, curses.A_NORMAL, curses.A_PROTECT],
          [2097152, 262144, 131072, 65536, 1048576, 524288, 4194304, 8388608, 2147483648, 255, 65280, 4294967040, 0, 16777216])
    check("constants: keys", [curses.KEY_UP, curses.KEY_DOWN, curses.KEY_LEFT, curses.KEY_RIGHT, curses.KEY_F1, curses.KEY_F12,
                              curses.KEY_F63, curses.KEY_BACKSPACE, curses.KEY_ENTER, curses.KEY_MOUSE, curses.KEY_RESIZE,
                              curses.KEY_MIN, curses.KEY_MAX, curses.KEY_NPAGE, curses.KEY_SRIGHT, curses.KEY_UNDO],
          [259, 258, 260, 261, 265, 276, 327, 263, 343, 409, 410, 257, 511, 338, 402, 408])
    check("constants: mouse", [curses.BUTTON1_PRESSED, curses.BUTTON1_RELEASED, curses.BUTTON1_CLICKED, curses.BUTTON2_CLICKED,
                               curses.BUTTON3_PRESSED, curses.BUTTON4_PRESSED, curses.BUTTON5_PRESSED, curses.BUTTON_CTRL,
                               curses.BUTTON_SHIFT, curses.BUTTON_ALT, curses.REPORT_MOUSE_POSITION, curses.ALL_MOUSE_EVENTS],
          [2, 1, 4, 128, 2048, 65536, 2097152, 33554432, 67108864, 134217728, 268435456, 268435455])
    check("constants: colors, OK/ERR", [curses.COLOR_BLACK, curses.COLOR_RED, curses.COLOR_WHITE, curses.OK, curses.ERR], [0, 1, 7, 0, -1])
    check("module: version, error, window type", [curses.version, curses.error.__name__, issubclass(curses.error, Exception),
                                                  curses.window.__name__, len(curses.ncurses_version)],
          [b"2.2", "error", True, "window", 3])
    check("module: windows cannot be made directly", err(curses.window), ["TypeError", "cannot create '_curses.window' instances"])
    check("module: before setupterm", [err(curses.tigetstr, "cup"), err(curses.tigetnum, "cols"), err(curses.tparm, b"x")],
          [["error", "must call (at least) setupterm() first"]] * 3)
    check("module: before initscr", [err(curses.newwin, 1, 1), err(curses.color_pair, 1), err(curses.keyname, 1), err(curses.cbreak),
                                     err(curses.doupdate)],
          [["error", "must call initscr() first"]] * 5)
    check("ascii", [curses.ascii.isprint("a"), curses.ascii.isctrl(1), curses.ascii.unctrl(1), curses.ascii.unctrl("\x7f"),
                    curses.ascii.ctrl("a"), curses.ascii.alt("a"), curses.ascii.ascii(0xe1), curses.ascii.isspace(" "),
                    curses.ascii.ismeta(200), curses.ascii.isblank("\t"), curses.ascii.ispunct("!"), curses.ascii.isxdigit("f"),
                    curses.ascii.NL, curses.ascii.ESC, curses.ascii.controlnames[27]],
          [True, True, "^A", "^?", "\x01", "\xe1", 97, True, True, True, True, True, 10, 27, "ESC"])

    # terminfo in this process: the first setupterm counts (as CPython's)
    out_fd = sys.__stdout__.fileno()
    curses.setupterm("xterm-256color", out_fd)
    curses.setupterm("vt100", out_fd)
    check("tigetstr", [curses.tigetstr("cup"), curses.tigetstr("smcup"), curses.tigetstr("kcuu1"), curses.tigetstr("kUP5"),
                       curses.tigetstr("setaf"), curses.tigetstr("nosuch"), curses.tigetstr("am"), curses.tigetstr("flash")],
          [b"\x1b[%i%p1%d;%p2%dH", b"\x1b[?1049h\x1b[22;0;0t", b"\x1bOA", b"\x1b[1;5A",
           b"\x1b[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m", None, None, b"\x1b[?5h$<100/>\x1b[?5l"])
    check("tigetnum", [curses.tigetnum("colors"), curses.tigetnum("pairs"), curses.tigetnum("it"), curses.tigetnum("cup"),
                       curses.tigetnum("nosuch"), curses.tigetnum("xmc")], [256, 65536, 8, -2, -2, -1])
    check("tigetflag", [curses.tigetflag("am"), curses.tigetflag("bce"), curses.tigetflag("xenl"), curses.tigetflag("hz"),
                        curses.tigetflag("AX"), curses.tigetflag("XT"), curses.tigetflag("cup"), curses.tigetflag("OTbs")],
          [1, 1, 1, 0, 1, 1, -1, 1])
    tp = curses.tparm
    check("tparm: cursor and colors", [tp(curses.tigetstr("cup"), 5, 10), tp(curses.tigetstr("setaf"), 3), tp(curses.tigetstr("setaf"), 12),
                                       tp(curses.tigetstr("setab"), 200), tp(curses.tigetstr("csr"), 0, 23), tp(curses.tigetstr("hpa"), 7)],
          [b"\x1b[6;11H", b"\x1b[33m", b"\x1b[94m", b"\x1b[48;5;200m", b"\x1b[1;24r", b"\x1b[8G"])
    check("tparm: sgr", [tp(curses.tigetstr("sgr"), 1, 0, 1, 0, 0, 1, 0, 0, 1), tp(curses.tigetstr("sgr"), 0, 1, 0, 1, 1, 0, 1, 0, 0),
                         tp(curses.tigetstr("sgr"))],
          [b"\x1b(0\x1b[0;1;7m", b"\x1b(B\x1b[0;2;4;5;8m", b"\x1b(B\x1b[0m"])
    check("tparm: initc scales", tp(curses.tigetstr("initc"), 1, 1000, 500, 0), b"\x1b]4;1;rgb:FF/7F/00\x1b\\")
    check("tparm: rep and %c", [tp(curses.tigetstr("rep"), ord("x"), 5), tp(b"%p1%c", 0), tp(b"%p1%c%p2%c", 65, 66)],
          [b"x\x1b[4b", b"\x80", b"AB"])
    check("tparm: arithmetic", [tp(b"%p1%p2%+%d", 7, 5), tp(b"%p1%p2%-%d", 7, 5), tp(b"%p1%p2%*%d", 7, 5), tp(b"%p1%p2%/%d", 7, 2),
                                tp(b"%p1%p2%m%d", 7, 5), tp(b"%p1%{0}%/%d", 7), tp(b"%{12}%{5}%-%d"), tp(b"%'A'%{1}%+%c")],
          [b"12", b"2", b"35", b"3", b"2", b"0", b"7", b"B"])
    check("tparm: bit and logic", [tp(b"%p1%p2%&%d", 12, 10), tp(b"%p1%p2%|%d", 12, 10), tp(b"%p1%p2%^%d", 12, 10),
                                   tp(b"%p1%p2%=%d", 3, 3), tp(b"%p1%p2%>%d", 3, 2), tp(b"%p1%p2%<%d", 3, 2), tp(b"%p1%p2%A%d", 1, 0),
                                   tp(b"%p1%p2%O%d", 1, 0), tp(b"%p1%!%d", 0), tp(b"%p1%~%d", 0)],
          [b"8", b"14", b"6", b"1", b"1", b"0", b"0", b"1", b"1", b"-1"])
    check("tparm: conditionals", [tp(b"%?%p1%t<yes>%e<no>%;", 1), tp(b"%?%p1%t<yes>%e<no>%;", 0),
                                  tp(b"%?%p1%{1}%=%tone%e%p1%{2}%=%ttwo%eother%;", 2), tp(b"%?%p1%{1}%=%tone%e%p1%{2}%=%ttwo%eother%;", 9),
                                  tp(b"[%?%p1%t%?%p2%tAB%eA%;%e%?%p2%tB%;%;]", 1, 0), tp(b"[%?%p1%t%?%p2%tAB%eA%;%e%?%p2%tB%;%;]", 0, 1)],
          [b"<yes>", b"<no>", b"two", b"other", b"[A]", b"[B]"])
    check("tparm: printf formats", [tp(b"%p1%02d|%p1%3d|%p1%x|%p1%X|%p1%o|%p1%#x|%p1%#X|%p1%.3d|%p1%:-4d.", 42),
                                    tp(b"%p1% d|%p1%#o|%p1%#5x|%p1%05d|%p1%3c|", 42)],
          [b"42| 42|2a|2A|52|0x2a|0X2A|042|42  .", b" 42|052| 0x2a|00042|*|"])
    check("tparm: ncurses' corners", [tp(b"%p1%-3d", 42), tp(b"%p1%:+d", 42, 7), tp(b"%p1%{-1}%d", 42), tp(b"%{2}%{3}%{4}%*%+%d"),
                                    tp(b"%p9%d%p8%d"), tp(b"%a"), err(tp, b"%p1%s", 1), err(tp, b"%p1%l%d", 1)],
          [b"3d", b"d", b"1}0", b"14", b"00", b"", ["error", "tparm() returned NULL"], ["error", "tparm() returned NULL"]])
    check("tparm: %i and dynamic variables", [tp(b"%i%p1%d;%p2%d", 0, 0), tp(b"%p1%Pa%p2%Pb%gb%ga%d%d", 1, 2), tp(b"%ga%d")],
          [b"1;1", b"12", b"0"])
    check("tparm: static variables persist", [tp(b"%p1%PZ", 9), tp(b"%gZ%d")], [b"", b"9"])
    check("tparm: padding is kept", tp(b"\x1b[%p1%dX$<5>", 3), b"\x1b[3X$<5>")
    check("tparm: errors", [err(tp, "x"), err(tp, b"%p1%d", "a")],
          [["TypeError", "a bytes-like object is required, not 'str'"], ["TypeError", "'str' object cannot be interpreted as an integer"]])
    if nython:
        info = curses.nython_terminfo()
        check("nython_terminfo", [info[0].split("|")[0], info[1].endswith("xterm-256color"), "am" in info[3], info[4]["colors"],
                                  info[5]["cup"]], ["xterm-256color", True, True, 256, b"\x1b[%i%p1%d;%p2%dH"])
    check("has_key (Python)", [curses.has_key.has_key(curses.KEY_UP), curses.has_key.has_key(curses.KEY_F1),
                               curses.has_key.has_key(curses.KEY_SUSPEND)], [True, True, False])


test_module()


# ═══════════════════════════════════════════════════════════════════════════
# 3. programs under a pseudo-terminal
# ═══════════════════════════════════════════════════════════════════════════
HAVE_PTY = False
if POSIX:
    try:
        import pty
        import select
        import termios
        import signal
        HAVE_PTY = True
    except ImportError:
        HAVE_PTY = False

HAVE_DB = os.path.exists("/usr/share/terminfo/x/xterm-256color") and os.path.exists("/usr/share/terminfo/v/vt100")

MARK = b"\x1b]777;ready\x07"
HEAD = """import curses, curses.panel, curses.textpad, os, sys
def R():
    os.write(1, b"\\x1b]777;ready\\x07")
def S(scr, y, *vals):
    scr.addstr(y, 0, " ".join(repr(v) for v in vals)[:scr.getmaxyx()[1] - 1])
    scr.clrtoeol()
"""

PROGRAMS = {}
# the keys each terminal sends (a step's keys can depend on the terminal)
PROGRAMS["basic"] = (10, 40, {"xterm-256color": [b"\x1bOA\x1b[B\x1bOP\x1b[15~\x1b[1;5A\x7f\x1b", b"", b"k\xc3\xa9\x1bOB\x1b[6~", b"q"],
                              "vt100": [b"\x1bOA\x1bOB\x1bOP\x1bOt\x1bOx\x08\x7fa\x1b", b"", b"k\xc3\xa9\x1bOB\x1bOl", b"q"]}, """
def main(scr):
    curses.set_escdelay(40)
    color = curses.has_colors()
    if color:
        curses.init_pair(1, curses.COLOR_RED, curses.COLOR_BLACK)
        if curses.COLORS >= 256:
            curses.init_pair(2, 200, 17)
        else:
            curses.init_pair(2, 3, 4)
        curses.init_pair(3, curses.COLOR_WHITE, curses.COLOR_BLUE)
    scr.addstr(0, 0, "attrs:")
    for name in ("A_BOLD", "A_UNDERLINE", "A_REVERSE", "A_DIM", "A_ITALIC", "A_STANDOUT", "A_BLINK"):
        scr.addstr(" " + name[2], getattr(curses, name))
    if color:
        scr.addstr(1, 0, "red", curses.color_pair(1))
        scr.addstr(" 256", curses.color_pair(2) | curses.A_BOLD)
        scr.attron(curses.color_pair(3))
        scr.addstr(2, 0, "blue line")
        scr.attroff(curses.color_pair(3))
    else:
        scr.addstr(1, 0, "mono", curses.A_BOLD | curses.A_UNDERLINE)
    scr.addstr(2, 12, "plain")
    scr.addstr(3, 0, "chgat here")
    scr.chgat(3, 0, 5, curses.A_REVERSE)
    scr.addstr(4, 0, "tab\\tx\\ty")
    scr.addstr(5, 0, "ctl\\x01\\x7fz")
    scr.hline(6, 0, curses.ACS_HLINE, 10)
    scr.vline(7, 0, "|", 2)
    scr.addch(7, 2, curses.ACS_DIAMOND)
    scr.addch(7, 3, curses.ACS_CKBOARD | curses.A_BOLD)
    scr.addch(7, 4, "\\u00e9")
    scr.addstr(7, 6, "e\\u0301x \\u4e2d\\u6587|")
    scr.addstr(6, 12, "%r %r %r" % (scr.inch(3, 1), scr.instr(2, 12, 5), scr.inch(7, 2)))
    scr.move(3, 7)
    scr.refresh()
    R()
    out = []
    for i in range(9):
        out.append(str(scr.getch()))
    scr.addstr(8, 0, " ".join(out))
    scr.refresh()
    R()
    scr.nodelay(True)
    c = scr.getch()
    scr.nodelay(False)
    scr.timeout(50)
    d = scr.getch()
    scr.timeout(-1)
    scr.addstr(9, 0, "nd %d %d" % (c, d))
    scr.refresh()
    R()
    k = scr.getkey()
    w = scr.get_wch()
    w2 = scr.get_wch()
    k2 = scr.getkey()
    scr.addstr(9, 12, "%r %r %r %r" % (k, w, w2, k2))
    scr.refresh()
    R()
    scr.getch()
curses.wrapper(main)
""")

PROGRAMS["windows"] = (10, 40, [b"a", b"b", b"c", b"q"], """
def main(scr):
    for y in range(10):
        scr.addstr(y, 0, ("%d" % y) * 39)
    scr.refresh()
    w = curses.newwin(4, 12, 2, 3)
    w.box()
    w.addstr(1, 1, "newwin")
    w.refresh()
    sub = w.subwin(2, 4, 3, 10)
    sub.addstr(0, 0, "sub")
    der = w.derwin(1, 6, 2, 1)
    der.addstr(0, 0, "der")
    der.refresh()
    sub.refresh()
    R()
    scr.getch()
    S(scr, 0, w.getyx(), w.getbegyx(), w.getmaxyx(), w.getparyx(), sub.getparyx(), der.getbegyx())
    S(scr, 1, w.enclose(3, 5), w.enclose(9, 9), w.is_wintouched(), scr.is_linetouched(0), scr.is_linetouched(5))
    scr.refresh()
    w.mvwin(5, 20)
    w.border("|", "|", "-", "-", "+", "+", "+", "+")
    w.refresh()
    R()
    scr.getch()
    scr.touchwin()
    scr.refresh()
    a = curses.newwin(3, 8, 1, 30)
    a.addstr(0, 0, "AAA  AAA")
    b = curses.newwin(3, 8, 2, 28)
    b.bkgd("#")
    b.addstr(1, 1, "bb")
    a.overlay(b)
    b.refresh()
    c = curses.newwin(3, 8, 2, 33)
    a.overwrite(c)
    a.overwrite(c, 0, 0, 1, 1, 1, 6)
    c.refresh()
    R()
    scr.getch()
    curses.curs_set(0) if curses.tigetstr("civis") else None
    w.leaveok(True)
    w.clear()
    w.addstr(1, 1, "cleared")
    w.refresh()
    scr.erase()
    scr.addstr(9, 0, "erased %r" % (w.getyx(),))
    scr.noutrefresh()
    curses.doupdate()
    R()
    scr.getch()
curses.wrapper(main)
""")

PROGRAMS["pads"] = (10, 40, [b"a", b"b", b"c", b"q"], """
def main(scr):
    color = curses.has_colors()
    if color:
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)
        curses.init_pair(2, -1, curses.COLOR_RED)
    pad = curses.newpad(40, 60)
    for y in range(40):
        pad.addstr(y, 0, ("p%02d " % y) * 14, curses.color_pair(1 + y % 2) if color else curses.A_NORMAL)
    pad.refresh(5, 3, 1, 1, 6, 20)
    R()
    scr.getch()
    pad.noutrefresh(30, 40, 2, 22, 8, 38)
    pad.noutrefresh(10, 0, 1, 1, 6, 20)
    curses.doupdate()
    R()
    scr.getch()
    sp = pad.subpad(5, 10, 2, 2)
    sp.addstr(0, 0, "subpad")
    pad.refresh(0, 0, 0, 0, 0, 15)
    S(scr, 9, sp.getmaxyx(), pad.getmaxyx(), sp.getparyx())
    scr.refresh()
    R()
    scr.getch()
    try:
        pad.refresh()
    except curses.error as e:
        S(scr, 8, str(e))
    try:
        scr.refresh(0, 0, 0, 0, 1, 1)
    except TypeError as e:
        S(scr, 7, str(e))
    scr.refresh()
    R()
    scr.getch()
curses.wrapper(main)
""")

PROGRAMS["panels"] = (10, 30, [b"a", b"b", b"c", b"d", b"e"], """
def main(scr):
    for y in range(10):
        scr.addstr(y, 0, ("%d" % y) * 29)
    scr.refresh()
    pans = []
    for i, (y, x) in enumerate([(1, 2), (3, 6), (5, 10)]):
        w = curses.newwin(4, 12, y, x)
        w.box()
        w.addstr(1, 1, "panel %d" % i)
        p = curses.panel.new_panel(w)
        p.set_userptr("p%d" % i)
        pans.append(p)
    curses.panel.update_panels()
    curses.doupdate()
    R()
    scr.getch()
    pans[0].top()
    curses.panel.update_panels()
    curses.doupdate()
    R()
    scr.getch()
    pans[1].hide()
    curses.panel.update_panels()
    curses.doupdate()
    R()
    scr.getch()
    pans[2].move(0, 15)
    pans[1].show()
    curses.panel.update_panels()
    curses.doupdate()
    R()
    scr.getch()
    pans[0].bottom()
    t = curses.panel.top_panel()
    b = curses.panel.bottom_panel()
    w = curses.newwin(2, 8, 7, 1)
    w.addstr(0, 0, "replaced")
    pans[1].replace(w)
    S(scr, 9, t.userptr(), b.userptr(), pans[2].above().userptr(), pans[2].below().userptr(), pans[1].hidden(), pans[1].window() is w)
    scr.refresh()
    curses.panel.update_panels()
    curses.doupdate()
    R()
    scr.getch()
curses.wrapper(main)
""")

PROGRAMS["scroll"] = (10, 30, [b"a", b"b", b"c", b"d", b"e", b"f", b"g"], """
def main(scr):
    color = curses.has_colors()
    if color:
        curses.init_pair(1, curses.COLOR_YELLOW, curses.COLOR_BLUE)
    hl = curses.color_pair(1) if color else curses.A_BOLD
    scr.scrollok(True)
    scr.idlok(True)
    for i in range(14):
        scr.addstr("line %d\\n" % i)
    scr.refresh()
    R()
    scr.getch()
    scr.setscrreg(2, 6)
    scr.move(6, 0)
    for i in range(3):
        scr.addstr("reg %d\\n" % i, hl)
    scr.refresh()
    R()
    scr.getch()
    scr.setscrreg(0, 9)
    scr.scroll(-2)
    scr.addstr(0, 0, "top0")
    scr.refresh()
    R()
    scr.getch()
    scr.move(4, 0)
    scr.insertln()
    scr.addstr(4, 0, "inserted")
    scr.move(7, 0)
    scr.deleteln()
    scr.move(2, 3)
    scr.insch("X")
    scr.move(3, 0)
    scr.delch()
    scr.insstr(5, 2, "INS")
    scr.insnstr(6, 0, "abcdef", 3)
    scr.move(8, 0)
    scr.insdelln(2)
    scr.refresh()
    R()
    scr.getch()
    win = curses.newwin(5, 20, 3, 5)
    win.bkgd(".", hl)
    win.addstr(1, 1, "bkgd win")
    win.scrollok(True)
    win.refresh()
    R()
    win.getch()
    for i in range(6):
        win.addstr("w%d\\n" % i)
    win.refresh()
    R()
    win.getch()
    scr.erase()
    scr.addstr(0, 0, "erased")
    scr.clrtobot()
    scr.refresh()
    R()
    scr.getch()
curses.wrapper(main)
""")

PROGRAMS["textpad"] = (10, 40, [b"hello\x02\x02XY\x01\x0eline2 long text here\x08\x08\x07", b"\x1b[A", b"bob\x7f\x7fill\x15ann\r",
                               b"one\x01\x0bins\x07", b"z"], """
def main(scr):
    curses.textpad.rectangle(scr, 1, 1, 5, 20)
    tw = curses.newwin(3, 18, 2, 2)
    box = curses.textpad.Textbox(tw)
    scr.refresh()
    R()
    text = box.edit()
    scr.addstr(7, 0, repr(text))
    scr.refresh()
    R()
    scr.getch()
    curses.echo()
    scr.addstr(8, 0, "name: ")
    scr.refresh()
    R()
    s = scr.getstr()
    curses.noecho()
    scr.addstr(9, 0, repr(s))
    t2 = curses.newwin(1, 20, 6, 22)
    b2 = curses.textpad.Textbox(t2, insert_mode=True)
    scr.refresh()
    R()
    text2 = b2.edit()
    scr.addstr(6, 0, repr(text2))
    scr.refresh()
    R()
    scr.getch()
curses.wrapper(main)
""")

PROGRAMS["input"] = (10, 40, {"xterm-256color": [b"\x1bOA", b"ab", b"\x1b[24~", b"xyz", b"", b"q"],
                              "vt100": [b"\x1bOA", b"ab", b"\x1bOx", b"xyz", b"", b"q"]}, """
def main(scr):
    curses.set_escdelay(40)
    scr.keypad(False)
    scr.refresh()
    R()
    a = [scr.getch(), scr.getch(), scr.getch()]
    S(scr, 0, a)
    curses.ungetch("z")
    curses.ungetch(curses.KEY_F5)
    curses.unget_wch("\\u00e9")
    S(scr, 1, scr.get_wch(), scr.getch(), scr.getch())
    curses.echo()
    scr.move(2, 0)
    scr.refresh()
    R()
    b = [scr.getch(), scr.getch()]
    curses.noecho()
    S(scr, 3, b)
    scr.keypad(True)
    scr.refresh()
    R()
    S(scr, 4, scr.getkey(), curses.keyname(curses.KEY_F12), curses.keyname(curses.KEY_UP), curses.keyname(27), curses.keyname(200),
      curses.unctrl(1), curses.unctrl(127), curses.has_key(curses.KEY_F1), curses.has_key(curses.KEY_SUSPEND))
    curses.halfdelay(2)
    scr.refresh()
    R()
    t = [scr.getch(), scr.getch(), scr.getch(), scr.getch()]
    curses.cbreak()
    S(scr, 5, t)
    curses.flushinp()
    S(scr, 6, curses.erasechar(), curses.killchar(), curses.baudrate(), curses.termname(), curses.longname()[:20],
      curses.has_ic(), curses.has_il())
    S(scr, 7, curses.termattrs() & ~curses.A_COLOR, curses.isendwin(), curses.LINES, curses.COLS, curses.get_tabsize())
    curses.beep()
    curses.flash()
    curses.napms(5)
    vis = []
    for v in (0, 2, 1):
        try:
            vis.append(curses.curs_set(v))
        except curses.error as e:
            vis.append(str(e))
    S(scr, 2, vis)
    scr.refresh()
    R()
    scr.nodelay(True)
    S(scr, 8, scr.getch(), [type(e).__name__ for e in (curses.error("x"),)])
    try:
        scr.getkey()
    except curses.error as e:
        S(scr, 9, str(e))
    scr.nodelay(False)
    scr.refresh()
    R()
    scr.getch()
curses.wrapper(main)
""")

PROGRAMS["mouse_resize"] = (10, 30, [b"\x1b[<0;5;3M\x1b[<0;5;3m", b"\x1b[<2;7;2M", ("resize", 12, 36), b"\x1b", b"q"], """
def main(scr):
    curses.set_escdelay(25)
    avail, old = curses.mousemask(curses.ALL_MOUSE_EVENTS)
    S(scr, 0, "mask", avail, old)
    S(scr, 1, "size", scr.getmaxyx())
    scr.refresh()
    R()
    c = scr.getch()
    try:
        ev = curses.getmouse()
    except curses.error as e:
        ev = str(e)
    S(scr, 2, c, ev)
    scr.refresh()
    R()
    c = scr.getch()
    try:
        ev = curses.getmouse()
    except curses.error as e:
        ev = str(e)
    S(scr, 3, c, ev)
    scr.refresh()
    R()
    c = scr.getch()
    S(scr, 4, "key", c, curses.is_term_resized(10, 30))
    curses.update_lines_cols()
    S(scr, 5, "LC", curses.LINES, curses.COLS, scr.getmaxyx())
    scr.box()
    scr.refresh()
    R()
    c = scr.getch()
    scr.addstr(6, 1, "esc %d" % c)
    curses.ungetmouse(0, 3, 4, 0, curses.BUTTON1_PRESSED)
    c = scr.getch()
    S(scr, 7, c, curses.getmouse())
    scr.refresh()
    R()
    scr.getch()
curses.wrapper(main)
""")

PROGRAMS["colors"] = (10, 40, [b"a", b"b", b"q"], """
def main(scr):
    if not curses.has_colors():
        S(scr, 0, "no colors", curses.has_colors(), curses.can_change_color())
        scr.refresh()
        R()
        scr.getch()
        R()
        scr.getch()
        R()
        scr.getch()
        return
    S(scr, 0, curses.COLORS, curses.COLOR_PAIRS, curses.pair_content(0), curses.color_content(1), curses.color_content(9))
    for i in range(1, 17):
        curses.init_pair(i, i - 1, (i + 3) % 16)
        scr.addstr(1 + (i - 1) // 8, ((i - 1) % 8) * 4, " %02d " % i, curses.color_pair(i))
    for i in range(16):
        curses.init_pair(20 + i, 16 + i * 15, 255 - i)
        scr.addstr(3, i * 2, "##", curses.color_pair(20 + i) | (curses.A_BOLD if i % 2 else curses.A_REVERSE))
    curses.init_pair(300, 1, 2)
    S(scr, 4, curses.pair_content(300), curses.pair_number(curses.color_pair(17)), curses.color_pair(3))
    scr.bkgd(" ", curses.color_pair(5))
    scr.addstr(5, 0, "bkgd")
    scr.refresh()
    R()
    scr.getch()
    curses.init_pair(5, curses.COLOR_BLACK, curses.COLOR_GREEN)
    scr.addstr(6, 0, "pair 5 changed")
    if curses.can_change_color():
        curses.init_color(9, 1000, 500, 0)
        S(scr, 7, curses.color_content(9))
    try:
        curses.init_pair(1, 300, 0)
    except ValueError as e:
        S(scr, 8, str(e))
    scr.refresh()
    R()
    scr.getch()
    curses.use_default_colors()
    curses.init_pair(6, -1, -1)
    scr.bkgd(" ", curses.color_pair(6))
    scr.addstr(9, 0, "defaults %r" % (curses.pair_content(6),), curses.color_pair(6) | curses.A_UNDERLINE)
    scr.refresh()
    R()
    scr.getch()
curses.wrapper(main)
""")

PROGRAMS["resume"] = (10, 40, [b"a", b"", b"q"], """
def main(scr):
    scr.addstr(0, 0, "before endwin")
    w = curses.newwin(3, 10, 2, 2)
    w.box()
    w.addstr(1, 1, "saved")
    w.refresh()
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "win_%d.dat" % os.getpid())
    f = open(p, "wb")
    w.putwin(f)
    f.close()
    scr.refresh()
    R()
    scr.getch()
    curses.endwin()
    os.write(1, b"in the shell")
    R()
    S(scr, 1, "after", curses.isendwin())
    scr.refresh()
    f = open(p, "rb")
    w2 = curses.getwin(f)
    f.close()
    os.remove(p)
    w2.mvwin(5, 20)
    w2.refresh()
    S(scr, 9, curses.isendwin(), w2.getmaxyx(), w2.getbegyx(), w2.getyx())
    scr.refresh()
    R()
    scr.getch()
curses.wrapper(main)
""")

# the workload whose bytes are measured (section 5)
PROGRAMS["workload"] = (24, 80, [b"a", b"b", b"c"], """
def main(scr):
    lines, cols = scr.getmaxyx()
    scr.idlok(True)
    data = ["%03d " % i + ("lorem ipsum dolor sit amet " * 4)[i % 7:][:cols - 5] for i in range(200)]
    top = [0]
    def draw():
        for y in range(lines):
            scr.addstr(y, 0, data[top[0] + y][:cols - 1])
            scr.clrtoeol()
        scr.refresh()
    draw()
    R()
    scr.getch()
    for i in range(30):
        top[0] += 1
        draw()
    for i in range(3):
        top[0] += lines - 2
        draw()
    for i in range(10):
        top[0] -= 1
        draw()
    R()
    scr.getch()
    for i in range(40):
        scr.addstr(0, cols - 8, "%6d" % (i * 37))
        scr.addstr(5 + i % 10, (i * 3) % (cols - 2), "*")
        scr.refresh()
    R()
    scr.getch()
curses.wrapper(main)
""")

TERMS = ["xterm-256color", "vt100"]
# a vt100 has no mouse: the reports would be keys, read at the speed they come
SKIP = ["mouse_resize/vt100"]


def encode(t):
    # a screen as text rows plus runs of styled cells: [y, x0, x1, fg, bg, flags]
    rows = t.display()
    runs = []
    for y in range(t.rows):
        x = 0
        while x < t.cols:
            v = t.visible(y, x)
            st = (v[1], v[2], v[3])
            if st == (-1, -1, 0):
                x += 1
                continue
            x0 = x
            while x + 1 < t.cols and (t.visible(y, x + 1)[1], t.visible(y, x + 1)[2], t.visible(y, x + 1)[3]) == st:
                x += 1
            runs.append([y, x0, x, st[0], st[1], st[2]])
            x += 1
    cur = list(t.cursor()) if t.cursor_visible else None
    return [rows, runs, cur, t.alt_active, t.bells, t.flashes]


def drive(argv, termname, rows, cols, keys, env_extra=None, deadline=60.0):
    """Run argv on a pty of rows x cols; at each ready mark take the screen
    and send that step's keys. -> (screens, exit status, bytes per step)"""
    if isinstance(keys, dict):
        keys = keys[termname]
    master, slave = os.openpty()
    termios.tcsetwinsize(master, (rows, cols))
    env = {}
    for k in os.environ:
        if k not in ("LINES", "COLUMNS", "NY_CURSES_UPDATE", "TERMINFO", "TERMINFO_DIRS", "NY_TERMINFO_BUILTIN", "ESCDELAY"):
            env[k] = os.environ[k]
    env["TERM"] = termname
    if env_extra:
        for k in env_extra:
            env[k] = env_extra[k]
    pid = os.fork()
    if pid == 0:
        try:
            os.close(master)
            os.login_tty(slave)
            os.execve(argv[0], argv, env)
        finally:
            os._exit(127)
    os.close(slave)
    t = _nyvt.Terminal(rows, cols)
    screens = []
    counts = []
    total = 0
    ki = 0
    end = time.time() + deadline
    idle = time.time()
    eof = False
    while time.time() < end:
        r = select.select([master], [], [], 0.2)[0]
        if not r:
            # nothing more is coming: every step's keys were sent and the
            # program has been quiet for a while
            if ki >= len(keys) and time.time() - idle > 20:
                break
            continue
        idle = time.time()
        try:
            d = os.read(master, 65536)
        except OSError:
            d = b""
        if not d:
            eof = True
            break
        while d:
            j = d.find(MARK)
            part = d if j < 0 else d[:j + len(MARK)]
            d = b"" if j < 0 else d[j + len(MARK):]
            total += len(part)
            t.feed(part)
            if t.responses:
                os.write(master, t.responses)
                t.responses = b""
            if j >= 0:
                screens.append(encode(t))
                counts.append(total - len(MARK) * len(screens))
                if ki < len(keys):
                    k = keys[ki]
                    ki += 1
                    if isinstance(k, tuple):
                        # let the program block in its read first: ncurses checks for a
                        # SIGWINCH just before it reads, and one landing in between waits
                        # for the next key
                        time.sleep(0.3)
                        t.resize(k[1], k[2])
                        termios.tcsetwinsize(master, (k[1], k[2]))
                    elif k:
                        os.write(master, k)
    screens.append(encode(t))
    counts.append(total - len(MARK) * (len(screens) - 1))
    status = None
    stop = time.time() + 10
    while time.time() < stop:
        p, st = os.waitpid(pid, os.WNOHANG)
        if p == pid:
            status = st
            break
        time.sleep(0.05)
    if status is None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        status = -1
    os.close(master)
    return screens, status, counts


TMP = None


def tmpdir():
    global TMP
    if TMP is None:
        TMP = "/tmp/ny115_%d" % os.getpid()
        if not os.path.isdir(TMP):
            os.mkdir(TMP)
    return TMP


def prog_path(name):
    path = os.path.join(tmpdir(), name + ".py")
    if not os.path.exists(path):
        f = open(path, "w")
        f.write(HEAD + PROGRAMS[name][3])
        f.close()
    return path


def run(argv, env_extra=None):
    # a command's output (stdout and stderr) and exit status
    import subprocess
    env = dict(os.environ)
    if env_extra:
        for k in env_extra:
            env[k] = env_extra[k]
    try:
        r = subprocess.run(argv, capture_output=True, env=env)
    except OSError:
        return ["", 127]
    return [(r.stdout + r.stderr).decode("utf-8", "replace"), r.returncode]


def runtime_argv():
    if nython:
        return [sys.executable] + ENGINE
    return [sys.executable]


def find_cpython():
    # python3 with _curses, to compare with (Nython only)
    if not nython or not HAVE_PTY:
        return None
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, "python3")
        if os.path.isfile(p) and os.access(p, os.X_OK):
            if run([p, "-c", "import _curses"])[1] == 0:
                return p
            return None
    return None


# --- expected (generated) ---
EXPECTED = {
    'basic/vt100': [[[['attrs: B U R D I S B                    ', 'mono                                    ', '            plain                       ', 'chgat here                              ', 'tab     x       y                       ', 'ctl^A^?z                                ', "──────────  262248 b'plain' 4194400     ", '| ◆▒é éx 中文|                          ', '|                                       ', '                                        '], [[0, 7, 7, -1, -1, 1], [0, 8, 9, -1, -1, 8], [0, 11, 11, -1, -1, 32], [0, 17, 17, -1, -1, 33], [0, 19, 19, -1, -1, 16], [1, 0, 3, -1, -1, 9], [3, 0, 4, -1, -1, 32], [7, 3, 3, -1, -1, 1]], [3, 7], False, 0, 0], [['attrs: B U R D I S B                    ', 'mono                                    ', '            plain                       ', 'chgat here                              ', 'tab     x       y                       ', 'ctl^A^?z                                ', "──────────  262248 b'plain' 4194400     ", '| ◆▒é éx 中文|                          ', '259 258 265 269 274 263 127 97 27       ', '                                        '], [[0, 7, 7, -1, -1, 1], [0, 8, 9, -1, -1, 8], [0, 11, 11, -1, -1, 32], [0, 17, 17, -1, -1, 33], [0, 19, 19, -1, -1, 16], [1, 0, 3, -1, -1, 9], [3, 0, 4, -1, -1, 32], [7, 3, 3, -1, -1, 1]], [8, 33], False, 0, 0], [['attrs: B U R D I S B                    ', 'mono                                    ', '            plain                       ', 'chgat here                              ', 'tab     x       y                       ', 'ctl^A^?z                                ', "──────────  262248 b'plain' 4194400     ", '| ◆▒é éx 中文|                          ', '259 258 265 269 274 263 127 97 27       ', 'nd -1 -1                                '], [[0, 7, 7, -1, -1, 1], [0, 8, 9, -1, -1, 8], [0, 11, 11, -1, -1, 32], [0, 17, 17, -1, -1, 33], [0, 19, 19, -1, -1, 16], [1, 0, 3, -1, -1, 9], [3, 0, 4, -1, -1, 32], [7, 3, 3, -1, -1, 1]], [9, 8], False, 0, 0], [['attrs: B U R D I S B                    ', 'mono                                    ', '            plain                       ', 'chgat here                              ', 'tab     x       y                       ', 'ctl^A^?z                                ', "──────────  262248 b'plain' 4194400     ", '| ◆▒é éx 中文|                          ', '259 258 265 269 274 263 127 97 27       ', "nd -1 -1    'k' 'é' 258 'KEY_F(8)'      "], [[0, 7, 7, -1, -1, 1], [0, 8, 9, -1, -1, 8], [0, 11, 11, -1, -1, 32], [0, 17, 17, -1, -1, 33], [0, 19, 19, -1, -1, 16], [1, 0, 3, -1, -1, 9], [3, 0, 4, -1, -1, 32], [7, 3, 3, -1, -1, 1]], [9, 34], False, 0, 0], [['attrs: B U R D I S B                    ', 'mono                                    ', '            plain                       ', 'chgat here                              ', 'tab     x       y                       ', 'ctl^A^?z                                ', "──────────  262248 b'plain' 4194400     ", '| ◆▒é éx 中文|                          ', '259 258 265 269 274 263 127 97 27       ', "nd -1 -1    'k' 'é' 258 'KEY_F(8)'      "], [[0, 7, 7, -1, -1, 1], [0, 8, 9, -1, -1, 8], [0, 11, 11, -1, -1, 32], [0, 17, 17, -1, -1, 33], [0, 19, 19, -1, -1, 16], [1, 0, 3, -1, -1, 9], [3, 0, 4, -1, -1, 32], [7, 3, 3, -1, -1, 1]], [9, 0], False, 0, 0]], 0],
    'basic/xterm-256color': [[[['attrs: B U R D I S B                    ', 'red 256                                 ', 'blue line   plain                       ', 'chgat here                              ', 'tab     x       y                       ', 'ctl^A^?z                                ', "──────────  262248 b'plain' 4194400     ", '| ◆▒é éx 中文|                          ', '|                                       ', '                                        '], [[0, 0, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 7, 7, 0, 1], [0, 8, 9, 7, 0, 8], [0, 10, 10, -1, 7, 0], [0, 11, 11, 7, 0, 32], [0, 12, 12, -1, 0, 0], [0, 13, 13, 7, 0, 2], [0, 14, 14, -1, 0, 0], [0, 15, 15, 7, 0, 4], [0, 16, 16, -1, 7, 0], [0, 17, 17, 7, 0, 32], [0, 18, 18, -1, 0, 0], [0, 19, 19, 7, 0, 16], [0, 20, 39, -1, 0, 0], [1, 0, 2, 1, 0, 0], [1, 3, 3, -1, 17, 0], [1, 4, 6, 200, 17, 1], [1, 7, 39, -1, 0, 0], [2, 0, 3, 7, 4, 0], [2, 4, 4, -1, 4, 0], [2, 5, 8, 7, 4, 0], [2, 9, 11, -1, 0, 0], [2, 12, 16, 7, 0, 0], [2, 17, 39, -1, 0, 0], [3, 0, 4, 7, 0, 32], [3, 5, 5, -1, 0, 0], [3, 6, 9, 7, 0, 0], [3, 10, 39, -1, 0, 0], [4, 0, 2, 7, 0, 0], [4, 3, 7, -1, 0, 0], [4, 8, 8, 7, 0, 0], [4, 9, 15, -1, 0, 0], [4, 16, 16, 7, 0, 0], [4, 17, 39, -1, 0, 0], [5, 0, 7, 7, 0, 0], [5, 8, 39, -1, 0, 0], [6, 0, 9, 7, 0, 0], [6, 10, 11, -1, 0, 0], [6, 12, 17, 7, 0, 0], [6, 18, 18, -1, 0, 0], [6, 19, 26, 7, 0, 0], [6, 27, 27, -1, 0, 0], [6, 28, 34, 7, 0, 0], [6, 35, 39, -1, 0, 0], [7, 0, 0, 7, 0, 0], [7, 1, 1, -1, 0, 0], [7, 2, 2, 7, 0, 0], [7, 3, 3, 7, 0, 1], [7, 4, 4, 7, 0, 0], [7, 5, 5, -1, 0, 0], [7, 6, 7, 7, 0, 0], [7, 8, 8, -1, 0, 0], [7, 9, 13, 7, 0, 0], [7, 14, 39, -1, 0, 0], [8, 0, 0, 7, 0, 0], [8, 1, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [3, 7], True, 0, 0], [['attrs: B U R D I S B                    ', 'red 256                                 ', 'blue line   plain                       ', 'chgat here                              ', 'tab     x       y                       ', 'ctl^A^?z                                ', "──────────  262248 b'plain' 4194400     ", '| ◆▒é éx 中文|                          ', '259 27 91 66 265 269 575 263 27         ', '                                        '], [[0, 0, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 7, 7, 0, 1], [0, 8, 9, 7, 0, 8], [0, 10, 10, -1, 7, 0], [0, 11, 11, 7, 0, 32], [0, 12, 12, -1, 0, 0], [0, 13, 13, 7, 0, 2], [0, 14, 14, -1, 0, 0], [0, 15, 15, 7, 0, 4], [0, 16, 16, -1, 7, 0], [0, 17, 17, 7, 0, 32], [0, 18, 18, -1, 0, 0], [0, 19, 19, 7, 0, 16], [0, 20, 39, -1, 0, 0], [1, 0, 2, 1, 0, 0], [1, 3, 3, -1, 17, 0], [1, 4, 6, 200, 17, 1], [1, 7, 39, -1, 0, 0], [2, 0, 3, 7, 4, 0], [2, 4, 4, -1, 4, 0], [2, 5, 8, 7, 4, 0], [2, 9, 11, -1, 0, 0], [2, 12, 16, 7, 0, 0], [2, 17, 39, -1, 0, 0], [3, 0, 4, 7, 0, 32], [3, 5, 5, -1, 0, 0], [3, 6, 9, 7, 0, 0], [3, 10, 39, -1, 0, 0], [4, 0, 2, 7, 0, 0], [4, 3, 7, -1, 0, 0], [4, 8, 8, 7, 0, 0], [4, 9, 15, -1, 0, 0], [4, 16, 16, 7, 0, 0], [4, 17, 39, -1, 0, 0], [5, 0, 7, 7, 0, 0], [5, 8, 39, -1, 0, 0], [6, 0, 9, 7, 0, 0], [6, 10, 11, -1, 0, 0], [6, 12, 17, 7, 0, 0], [6, 18, 18, -1, 0, 0], [6, 19, 26, 7, 0, 0], [6, 27, 27, -1, 0, 0], [6, 28, 34, 7, 0, 0], [6, 35, 39, -1, 0, 0], [7, 0, 0, 7, 0, 0], [7, 1, 1, -1, 0, 0], [7, 2, 2, 7, 0, 0], [7, 3, 3, 7, 0, 1], [7, 4, 4, 7, 0, 0], [7, 5, 5, -1, 0, 0], [7, 6, 7, 7, 0, 0], [7, 8, 8, -1, 0, 0], [7, 9, 13, 7, 0, 0], [7, 14, 39, -1, 0, 0], [8, 0, 2, 7, 0, 0], [8, 3, 3, -1, 0, 0], [8, 4, 5, 7, 0, 0], [8, 6, 6, -1, 0, 0], [8, 7, 8, 7, 0, 0], [8, 9, 9, -1, 0, 0], [8, 10, 11, 7, 0, 0], [8, 12, 12, -1, 0, 0], [8, 13, 15, 7, 0, 0], [8, 16, 16, -1, 0, 0], [8, 17, 19, 7, 0, 0], [8, 20, 20, -1, 0, 0], [8, 21, 23, 7, 0, 0], [8, 24, 24, -1, 0, 0], [8, 25, 27, 7, 0, 0], [8, 28, 28, -1, 0, 0], [8, 29, 30, 7, 0, 0], [8, 31, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [8, 31], True, 0, 0], [['attrs: B U R D I S B                    ', 'red 256                                 ', 'blue line   plain                       ', 'chgat here                              ', 'tab     x       y                       ', 'ctl^A^?z                                ', "──────────  262248 b'plain' 4194400     ", '| ◆▒é éx 中文|                          ', '259 27 91 66 265 269 575 263 27         ', 'nd -1 -1                                '], [[0, 0, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 7, 7, 0, 1], [0, 8, 9, 7, 0, 8], [0, 10, 10, -1, 7, 0], [0, 11, 11, 7, 0, 32], [0, 12, 12, -1, 0, 0], [0, 13, 13, 7, 0, 2], [0, 14, 14, -1, 0, 0], [0, 15, 15, 7, 0, 4], [0, 16, 16, -1, 7, 0], [0, 17, 17, 7, 0, 32], [0, 18, 18, -1, 0, 0], [0, 19, 19, 7, 0, 16], [0, 20, 39, -1, 0, 0], [1, 0, 2, 1, 0, 0], [1, 3, 3, -1, 17, 0], [1, 4, 6, 200, 17, 1], [1, 7, 39, -1, 0, 0], [2, 0, 3, 7, 4, 0], [2, 4, 4, -1, 4, 0], [2, 5, 8, 7, 4, 0], [2, 9, 11, -1, 0, 0], [2, 12, 16, 7, 0, 0], [2, 17, 39, -1, 0, 0], [3, 0, 4, 7, 0, 32], [3, 5, 5, -1, 0, 0], [3, 6, 9, 7, 0, 0], [3, 10, 39, -1, 0, 0], [4, 0, 2, 7, 0, 0], [4, 3, 7, -1, 0, 0], [4, 8, 8, 7, 0, 0], [4, 9, 15, -1, 0, 0], [4, 16, 16, 7, 0, 0], [4, 17, 39, -1, 0, 0], [5, 0, 7, 7, 0, 0], [5, 8, 39, -1, 0, 0], [6, 0, 9, 7, 0, 0], [6, 10, 11, -1, 0, 0], [6, 12, 17, 7, 0, 0], [6, 18, 18, -1, 0, 0], [6, 19, 26, 7, 0, 0], [6, 27, 27, -1, 0, 0], [6, 28, 34, 7, 0, 0], [6, 35, 39, -1, 0, 0], [7, 0, 0, 7, 0, 0], [7, 1, 1, -1, 0, 0], [7, 2, 2, 7, 0, 0], [7, 3, 3, 7, 0, 1], [7, 4, 4, 7, 0, 0], [7, 5, 5, -1, 0, 0], [7, 6, 7, 7, 0, 0], [7, 8, 8, -1, 0, 0], [7, 9, 13, 7, 0, 0], [7, 14, 39, -1, 0, 0], [8, 0, 2, 7, 0, 0], [8, 3, 3, -1, 0, 0], [8, 4, 5, 7, 0, 0], [8, 6, 6, -1, 0, 0], [8, 7, 8, 7, 0, 0], [8, 9, 9, -1, 0, 0], [8, 10, 11, 7, 0, 0], [8, 12, 12, -1, 0, 0], [8, 13, 15, 7, 0, 0], [8, 16, 16, -1, 0, 0], [8, 17, 19, 7, 0, 0], [8, 20, 20, -1, 0, 0], [8, 21, 23, 7, 0, 0], [8, 24, 24, -1, 0, 0], [8, 25, 27, 7, 0, 0], [8, 28, 28, -1, 0, 0], [8, 29, 30, 7, 0, 0], [8, 31, 39, -1, 0, 0], [9, 0, 1, 7, 0, 0], [9, 2, 2, -1, 0, 0], [9, 3, 4, 7, 0, 0], [9, 5, 5, -1, 0, 0], [9, 6, 7, 7, 0, 0], [9, 8, 39, -1, 0, 0]], [9, 8], True, 0, 0], [['attrs: B U R D I S B                    ', 'red 256                                 ', 'blue line   plain                       ', 'chgat here                              ', 'tab     x       y                       ', 'ctl^A^?z                                ', "──────────  262248 b'plain' 4194400     ", '| ◆▒é éx 中文|                          ', '259 27 91 66 265 269 575 263 27         ', "nd -1 -1    'k' 'é' 258 'KEY_NPAGE'     "], [[0, 0, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 7, 7, 0, 1], [0, 8, 9, 7, 0, 8], [0, 10, 10, -1, 7, 0], [0, 11, 11, 7, 0, 32], [0, 12, 12, -1, 0, 0], [0, 13, 13, 7, 0, 2], [0, 14, 14, -1, 0, 0], [0, 15, 15, 7, 0, 4], [0, 16, 16, -1, 7, 0], [0, 17, 17, 7, 0, 32], [0, 18, 18, -1, 0, 0], [0, 19, 19, 7, 0, 16], [0, 20, 39, -1, 0, 0], [1, 0, 2, 1, 0, 0], [1, 3, 3, -1, 17, 0], [1, 4, 6, 200, 17, 1], [1, 7, 39, -1, 0, 0], [2, 0, 3, 7, 4, 0], [2, 4, 4, -1, 4, 0], [2, 5, 8, 7, 4, 0], [2, 9, 11, -1, 0, 0], [2, 12, 16, 7, 0, 0], [2, 17, 39, -1, 0, 0], [3, 0, 4, 7, 0, 32], [3, 5, 5, -1, 0, 0], [3, 6, 9, 7, 0, 0], [3, 10, 39, -1, 0, 0], [4, 0, 2, 7, 0, 0], [4, 3, 7, -1, 0, 0], [4, 8, 8, 7, 0, 0], [4, 9, 15, -1, 0, 0], [4, 16, 16, 7, 0, 0], [4, 17, 39, -1, 0, 0], [5, 0, 7, 7, 0, 0], [5, 8, 39, -1, 0, 0], [6, 0, 9, 7, 0, 0], [6, 10, 11, -1, 0, 0], [6, 12, 17, 7, 0, 0], [6, 18, 18, -1, 0, 0], [6, 19, 26, 7, 0, 0], [6, 27, 27, -1, 0, 0], [6, 28, 34, 7, 0, 0], [6, 35, 39, -1, 0, 0], [7, 0, 0, 7, 0, 0], [7, 1, 1, -1, 0, 0], [7, 2, 2, 7, 0, 0], [7, 3, 3, 7, 0, 1], [7, 4, 4, 7, 0, 0], [7, 5, 5, -1, 0, 0], [7, 6, 7, 7, 0, 0], [7, 8, 8, -1, 0, 0], [7, 9, 13, 7, 0, 0], [7, 14, 39, -1, 0, 0], [8, 0, 2, 7, 0, 0], [8, 3, 3, -1, 0, 0], [8, 4, 5, 7, 0, 0], [8, 6, 6, -1, 0, 0], [8, 7, 8, 7, 0, 0], [8, 9, 9, -1, 0, 0], [8, 10, 11, 7, 0, 0], [8, 12, 12, -1, 0, 0], [8, 13, 15, 7, 0, 0], [8, 16, 16, -1, 0, 0], [8, 17, 19, 7, 0, 0], [8, 20, 20, -1, 0, 0], [8, 21, 23, 7, 0, 0], [8, 24, 24, -1, 0, 0], [8, 25, 27, 7, 0, 0], [8, 28, 28, -1, 0, 0], [8, 29, 30, 7, 0, 0], [8, 31, 39, -1, 0, 0], [9, 0, 1, 7, 0, 0], [9, 2, 2, -1, 0, 0], [9, 3, 4, 7, 0, 0], [9, 5, 5, -1, 0, 0], [9, 6, 7, 7, 0, 0], [9, 8, 11, -1, 0, 0], [9, 12, 14, 7, 0, 0], [9, 15, 15, -1, 0, 0], [9, 16, 18, 7, 0, 0], [9, 19, 19, -1, 0, 0], [9, 20, 22, 7, 0, 0], [9, 23, 23, -1, 0, 0], [9, 24, 34, 7, 0, 0], [9, 35, 39, -1, 0, 0]], [9, 35], True, 0, 0], [['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 0], False, 0, 0]], 0],
    'colors/vt100': [[[["'no colors' False False                 ", '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 23], False, 0, 0], [["'no colors' False False                 ", '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 23], False, 0, 0], [["'no colors' False False                 ", '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 23], False, 0, 0], [["'no colors' False False                 ", '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [9, 0], False, 0, 0]], 0],
    'colors/xterm-256color': [[[['256 65536 (7, 0) (680, 0, 0) (1000, 0,  ', ' 01  02  03  04  05  06  07  08         ', ' 09  10  11  12  13  14  15  16         ', '################################        ', '(1, 2) 17 768                           ', 'bkgd                                    ', '                                        ', '                                        ', '                                        ', '                                        '], [[0, 0, 2, 4, 8, 0], [0, 3, 3, -1, 8, 0], [0, 4, 8, 4, 8, 0], [0, 9, 9, -1, 8, 0], [0, 10, 12, 4, 8, 0], [0, 13, 13, -1, 8, 0], [0, 14, 15, 4, 8, 0], [0, 16, 16, -1, 8, 0], [0, 17, 21, 4, 8, 0], [0, 22, 22, -1, 8, 0], [0, 23, 24, 4, 8, 0], [0, 25, 25, -1, 8, 0], [0, 26, 27, 4, 8, 0], [0, 28, 28, -1, 8, 0], [0, 29, 34, 4, 8, 0], [0, 35, 35, -1, 8, 0], [0, 36, 37, 4, 8, 0], [0, 38, 39, -1, 8, 0], [1, 0, 0, -1, 4, 0], [1, 1, 2, 0, 4, 0], [1, 3, 3, -1, 4, 0], [1, 4, 4, -1, 5, 0], [1, 5, 6, 1, 5, 0], [1, 7, 7, -1, 5, 0], [1, 8, 8, -1, 6, 0], [1, 9, 10, 2, 6, 0], [1, 11, 11, -1, 6, 0], [1, 12, 12, -1, 7, 0], [1, 13, 14, 3, 7, 0], [1, 15, 15, -1, 7, 0], [1, 16, 16, -1, 8, 0], [1, 17, 18, 4, 8, 0], [1, 19, 19, -1, 8, 0], [1, 20, 20, -1, 9, 0], [1, 21, 22, 5, 9, 0], [1, 23, 23, -1, 9, 0], [1, 24, 24, -1, 10, 0], [1, 25, 26, 6, 10, 0], [1, 27, 27, -1, 10, 0], [1, 28, 28, -1, 11, 0], [1, 29, 30, 7, 11, 0], [1, 31, 31, -1, 11, 0], [1, 32, 39, -1, 8, 0], [2, 0, 0, -1, 12, 0], [2, 1, 2, 8, 12, 0], [2, 3, 3, -1, 12, 0], [2, 4, 4, -1, 13, 0], [2, 5, 6, 9, 13, 0], [2, 7, 7, -1, 13, 0], [2, 8, 8, -1, 14, 0], [2, 9, 10, 10, 14, 0], [2, 11, 11, -1, 14, 0], [2, 12, 12, -1, 15, 0], [2, 13, 14, 11, 15, 0], [2, 15, 15, -1, 15, 0], [2, 16, 16, -1, 0, 0], [2, 17, 18, 12, 0, 0], [2, 19, 19, -1, 0, 0], [2, 20, 20, -1, 1, 0], [2, 21, 22, 13, 1, 0], [2, 23, 23, -1, 1, 0], [2, 24, 24, -1, 2, 0], [2, 25, 26, 14, 2, 0], [2, 27, 27, -1, 2, 0], [2, 28, 28, -1, 3, 0], [2, 29, 30, 15, 3, 0], [2, 31, 31, -1, 3, 0], [2, 32, 39, -1, 8, 0], [3, 0, 1, 16, 255, 32], [3, 2, 3, 31, 254, 1], [3, 4, 5, 46, 253, 32], [3, 6, 7, 61, 252, 1], [3, 8, 9, 76, 251, 32], [3, 10, 11, 91, 250, 1], [3, 12, 13, 106, 249, 32], [3, 14, 15, 121, 248, 1], [3, 16, 17, 136, 247, 32], [3, 18, 19, 151, 246, 1], [3, 20, 21, 166, 245, 32], [3, 22, 23, 181, 244, 1], [3, 24, 25, 196, 243, 32], [3, 26, 27, 211, 242, 1], [3, 28, 29, 226, 241, 32], [3, 30, 31, 241, 240, 1], [3, 32, 39, -1, 8, 0], [4, 0, 2, 4, 8, 0], [4, 3, 3, -1, 8, 0], [4, 4, 5, 4, 8, 0], [4, 6, 6, -1, 8, 0], [4, 7, 8, 4, 8, 0], [4, 9, 9, -1, 8, 0], [4, 10, 12, 4, 8, 0], [4, 13, 39, -1, 8, 0], [5, 0, 3, 4, 8, 0], [5, 4, 39, -1, 8, 0], [6, 0, 39, -1, 8, 0], [7, 0, 39, -1, 8, 0], [8, 0, 39, -1, 8, 0], [9, 0, 39, -1, 8, 0]], [5, 4], True, 0, 0], [['256 65536 (7, 0) (680, 0, 0) (1000, 0,  ', ' 01  02  03  04  05  06  07  08         ', ' 09  10  11  12  13  14  15  16         ', '################################        ', '(1, 2) 17 768                           ', 'bkgd                                    ', 'pair 5 changed                          ', '(1000, 500, 0)                          ', "'Color number is greater than COLORS-1  ", '                                        '], [[0, 0, 2, 0, 2, 0], [0, 3, 3, -1, 2, 0], [0, 4, 8, 0, 2, 0], [0, 9, 9, -1, 2, 0], [0, 10, 12, 0, 2, 0], [0, 13, 13, -1, 2, 0], [0, 14, 15, 0, 2, 0], [0, 16, 16, -1, 2, 0], [0, 17, 21, 0, 2, 0], [0, 22, 22, -1, 2, 0], [0, 23, 24, 0, 2, 0], [0, 25, 25, -1, 2, 0], [0, 26, 27, 0, 2, 0], [0, 28, 28, -1, 2, 0], [0, 29, 34, 0, 2, 0], [0, 35, 35, -1, 2, 0], [0, 36, 37, 0, 2, 0], [0, 38, 39, -1, 2, 0], [1, 0, 0, -1, 4, 0], [1, 1, 2, 0, 4, 0], [1, 3, 3, -1, 4, 0], [1, 4, 4, -1, 5, 0], [1, 5, 6, 1, 5, 0], [1, 7, 7, -1, 5, 0], [1, 8, 8, -1, 6, 0], [1, 9, 10, 2, 6, 0], [1, 11, 11, -1, 6, 0], [1, 12, 12, -1, 7, 0], [1, 13, 14, 3, 7, 0], [1, 15, 15, -1, 7, 0], [1, 16, 16, -1, 2, 0], [1, 17, 18, 0, 2, 0], [1, 19, 19, -1, 2, 0], [1, 20, 20, -1, 9, 0], [1, 21, 22, 5, 9, 0], [1, 23, 23, -1, 9, 0], [1, 24, 24, -1, 10, 0], [1, 25, 26, 6, 10, 0], [1, 27, 27, -1, 10, 0], [1, 28, 28, -1, 11, 0], [1, 29, 30, 7, 11, 0], [1, 31, 31, -1, 11, 0], [1, 32, 39, -1, 2, 0], [2, 0, 0, -1, 12, 0], [2, 1, 2, 8, 12, 0], [2, 3, 3, -1, 12, 0], [2, 4, 4, -1, 13, 0], [2, 5, 6, 9, 13, 0], [2, 7, 7, -1, 13, 0], [2, 8, 8, -1, 14, 0], [2, 9, 10, 10, 14, 0], [2, 11, 11, -1, 14, 0], [2, 12, 12, -1, 15, 0], [2, 13, 14, 11, 15, 0], [2, 15, 15, -1, 15, 0], [2, 16, 16, -1, 0, 0], [2, 17, 18, 12, 0, 0], [2, 19, 19, -1, 0, 0], [2, 20, 20, -1, 1, 0], [2, 21, 22, 13, 1, 0], [2, 23, 23, -1, 1, 0], [2, 24, 24, -1, 2, 0], [2, 25, 26, 14, 2, 0], [2, 27, 27, -1, 2, 0], [2, 28, 28, -1, 3, 0], [2, 29, 30, 15, 3, 0], [2, 31, 31, -1, 3, 0], [2, 32, 39, -1, 2, 0], [3, 0, 1, 16, 255, 32], [3, 2, 3, 31, 254, 1], [3, 4, 5, 46, 253, 32], [3, 6, 7, 61, 252, 1], [3, 8, 9, 76, 251, 32], [3, 10, 11, 91, 250, 1], [3, 12, 13, 106, 249, 32], [3, 14, 15, 121, 248, 1], [3, 16, 17, 136, 247, 32], [3, 18, 19, 151, 246, 1], [3, 20, 21, 166, 245, 32], [3, 22, 23, 181, 244, 1], [3, 24, 25, 196, 243, 32], [3, 26, 27, 211, 242, 1], [3, 28, 29, 226, 241, 32], [3, 30, 31, 241, 240, 1], [3, 32, 39, -1, 2, 0], [4, 0, 2, 0, 2, 0], [4, 3, 3, -1, 2, 0], [4, 4, 5, 0, 2, 0], [4, 6, 6, -1, 2, 0], [4, 7, 8, 0, 2, 0], [4, 9, 9, -1, 2, 0], [4, 10, 12, 0, 2, 0], [4, 13, 39, -1, 2, 0], [5, 0, 3, 0, 2, 0], [5, 4, 39, -1, 2, 0], [6, 0, 3, 0, 2, 0], [6, 4, 4, -1, 2, 0], [6, 5, 5, 0, 2, 0], [6, 6, 6, -1, 2, 0], [6, 7, 13, 0, 2, 0], [6, 14, 39, -1, 2, 0], [7, 0, 5, 0, 2, 0], [7, 6, 6, -1, 2, 0], [7, 7, 10, 0, 2, 0], [7, 11, 11, -1, 2, 0], [7, 12, 13, 0, 2, 0], [7, 14, 39, -1, 2, 0], [8, 0, 5, 0, 2, 0], [8, 6, 6, -1, 2, 0], [8, 7, 12, 0, 2, 0], [8, 13, 13, -1, 2, 0], [8, 14, 15, 0, 2, 0], [8, 16, 16, -1, 2, 0], [8, 17, 23, 0, 2, 0], [8, 24, 24, -1, 2, 0], [8, 25, 28, 0, 2, 0], [8, 29, 29, -1, 2, 0], [8, 30, 37, 0, 2, 0], [8, 38, 39, -1, 2, 0], [9, 0, 39, -1, 2, 0]], [8, 39], True, 0, 0], [['256 65536 (7, 0) (680, 0, 0) (1000, 0,  ', ' 01  02  03  04  05  06  07  08         ', ' 09  10  11  12  13  14  15  16         ', '################################        ', '(1, 2) 17 768                           ', 'bkgd                                    ', 'pair 5 changed                          ', '(1000, 500, 0)                          ', "'Color number is greater than COLORS-1  ", 'defaults (-1, -1)                       '], [[1, 0, 0, -1, 4, 0], [1, 1, 2, 0, 4, 0], [1, 3, 3, -1, 4, 0], [1, 4, 4, -1, 5, 0], [1, 5, 6, 1, 5, 0], [1, 7, 7, -1, 5, 0], [1, 8, 8, -1, 6, 0], [1, 9, 10, 2, 6, 0], [1, 11, 11, -1, 6, 0], [1, 12, 12, -1, 7, 0], [1, 13, 14, 3, 7, 0], [1, 15, 15, -1, 7, 0], [1, 24, 24, -1, 10, 0], [1, 25, 26, 6, 10, 0], [1, 27, 27, -1, 10, 0], [1, 28, 28, -1, 11, 0], [1, 29, 30, 7, 11, 0], [1, 31, 31, -1, 11, 0], [2, 0, 0, -1, 12, 0], [2, 1, 2, 8, 12, 0], [2, 3, 3, -1, 12, 0], [2, 4, 4, -1, 13, 0], [2, 5, 6, 9, 13, 0], [2, 7, 7, -1, 13, 0], [2, 8, 8, -1, 14, 0], [2, 9, 10, 10, 14, 0], [2, 11, 11, -1, 14, 0], [2, 12, 12, -1, 15, 0], [2, 13, 14, 11, 15, 0], [2, 15, 15, -1, 15, 0], [2, 16, 16, -1, 0, 0], [2, 17, 18, 12, 0, 0], [2, 19, 19, -1, 0, 0], [2, 20, 20, -1, 1, 0], [2, 21, 22, 13, 1, 0], [2, 23, 23, -1, 1, 0], [2, 24, 24, -1, 2, 0], [2, 25, 26, 14, 2, 0], [2, 27, 27, -1, 2, 0], [2, 28, 28, -1, 3, 0], [2, 29, 30, 15, 3, 0], [2, 31, 31, -1, 3, 0], [3, 0, 1, 16, 255, 32], [3, 2, 3, 31, 254, 1], [3, 4, 5, 46, 253, 32], [3, 6, 7, 61, 252, 1], [3, 8, 9, 76, 251, 32], [3, 10, 11, 91, 250, 1], [3, 12, 13, 106, 249, 32], [3, 14, 15, 121, 248, 1], [3, 16, 17, 136, 247, 32], [3, 18, 19, 151, 246, 1], [3, 20, 21, 166, 245, 32], [3, 22, 23, 181, 244, 1], [3, 24, 25, 196, 243, 32], [3, 26, 27, 211, 242, 1], [3, 28, 29, 226, 241, 32], [3, 30, 31, 241, 240, 1], [9, 0, 16, -1, -1, 8]], [9, 17], True, 0, 0], [['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 0], False, 0, 0]], 0],
    'input/vt100': [[[['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 0], False, 0, 0], [['[27, 79, 65]                            ', "'é' 269 122                             ", '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [2, 0], False, 0, 0], [['[27, 79, 65]                            ', "'é' 269 122                             ", 'ab                                      ', '[97, 98]                                ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [3, 8], False, 0, 0], [['[27, 79, 65]                            ', "'é' 269 122                             ", 'ab                                      ', '[97, 98]                                ', "'KEY_F(10)' b'KEY_F(12)' b'KEY_UP' b'^[ ", '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [4, 39], False, 0, 0], [['[27, 79, 65]                            ', "'é' 269 122                             ", "['curs_set() returned ERR', 'curs_set() ", '[97, 98]                                ', "'KEY_F(10)' b'KEY_F(12)' b'KEY_UP' b'^[ ", '[120, 121, 122, -1]                     ', "b'\\x7f' b'\\x15' 38400 b'vt100' b'DEC VT ", '7274496 False 10 40 8                   ', '                                        ', '                                        '], [], [2, 39], False, 2, 0], [['[27, 79, 65]                            ', "'é' 269 122                             ", "['curs_set() returned ERR', 'curs_set() ", '[97, 98]                                ', "'KEY_F(10)' b'KEY_F(12)' b'KEY_UP' b'^[ ", '[120, 121, 122, -1]                     ', "b'\\x7f' b'\\x15' 38400 b'vt100' b'DEC VT ", '7274496 False 10 40 8                   ', "-1 ['error']                            ", "'no input'                              "], [], [9, 10], False, 2, 0], [['[27, 79, 65]                            ', "'é' 269 122                             ", "['curs_set() returned ERR', 'curs_set() ", '[97, 98]                                ', "'KEY_F(10)' b'KEY_F(12)' b'KEY_UP' b'^[ ", '[120, 121, 122, -1]                     ', "b'\\x7f' b'\\x15' 38400 b'vt100' b'DEC VT ", '7274496 False 10 40 8                   ', "-1 ['error']                            ", "'no input'                              "], [], [9, 0], False, 2, 0]], 0],
    'input/xterm-256color': [[[['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [[0, 0, 39, -1, 0, 0], [1, 0, 39, -1, 0, 0], [2, 0, 39, -1, 0, 0], [3, 0, 39, -1, 0, 0], [4, 0, 39, -1, 0, 0], [5, 0, 39, -1, 0, 0], [6, 0, 39, -1, 0, 0], [7, 0, 39, -1, 0, 0], [8, 0, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [0, 0], True, 0, 0], [['[27, 79, 65]                            ', "'é' 269 122                             ", '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [[0, 0, 3, 7, 0, 0], [0, 4, 4, -1, 0, 0], [0, 5, 7, 7, 0, 0], [0, 8, 8, -1, 0, 0], [0, 9, 11, 7, 0, 0], [0, 12, 39, -1, 0, 0], [1, 0, 2, 7, 0, 0], [1, 3, 3, -1, 0, 0], [1, 4, 6, 7, 0, 0], [1, 7, 7, -1, 0, 0], [1, 8, 10, 7, 0, 0], [1, 11, 39, -1, 0, 0], [2, 0, 39, -1, 0, 0], [3, 0, 39, -1, 0, 0], [4, 0, 39, -1, 0, 0], [5, 0, 39, -1, 0, 0], [6, 0, 39, -1, 0, 0], [7, 0, 39, -1, 0, 0], [8, 0, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [2, 0], True, 0, 0], [['[27, 79, 65]                            ', "'é' 269 122                             ", 'ab                                      ', '[97, 98]                                ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [[0, 0, 3, 7, 0, 0], [0, 4, 4, -1, 0, 0], [0, 5, 7, 7, 0, 0], [0, 8, 8, -1, 0, 0], [0, 9, 11, 7, 0, 0], [0, 12, 39, -1, 0, 0], [1, 0, 2, 7, 0, 0], [1, 3, 3, -1, 0, 0], [1, 4, 6, 7, 0, 0], [1, 7, 7, -1, 0, 0], [1, 8, 10, 7, 0, 0], [1, 11, 39, -1, 0, 0], [2, 0, 1, 7, 0, 0], [2, 2, 39, -1, 0, 0], [3, 0, 3, 7, 0, 0], [3, 4, 4, -1, 0, 0], [3, 5, 7, 7, 0, 0], [3, 8, 39, -1, 0, 0], [4, 0, 39, -1, 0, 0], [5, 0, 39, -1, 0, 0], [6, 0, 39, -1, 0, 0], [7, 0, 39, -1, 0, 0], [8, 0, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [3, 8], True, 0, 0], [['[27, 79, 65]                            ', "'é' 269 122                             ", 'ab                                      ', '[97, 98]                                ', "'KEY_F(12)' b'KEY_F(12)' b'KEY_UP' b'^[ ", '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [[0, 0, 3, 7, 0, 0], [0, 4, 4, -1, 0, 0], [0, 5, 7, 7, 0, 0], [0, 8, 8, -1, 0, 0], [0, 9, 11, 7, 0, 0], [0, 12, 39, -1, 0, 0], [1, 0, 2, 7, 0, 0], [1, 3, 3, -1, 0, 0], [1, 4, 6, 7, 0, 0], [1, 7, 7, -1, 0, 0], [1, 8, 10, 7, 0, 0], [1, 11, 39, -1, 0, 0], [2, 0, 1, 7, 0, 0], [2, 2, 39, -1, 0, 0], [3, 0, 3, 7, 0, 0], [3, 4, 4, -1, 0, 0], [3, 5, 7, 7, 0, 0], [3, 8, 39, -1, 0, 0], [4, 0, 10, 7, 0, 0], [4, 11, 11, -1, 0, 0], [4, 12, 23, 7, 0, 0], [4, 24, 24, -1, 0, 0], [4, 25, 33, 7, 0, 0], [4, 34, 34, -1, 0, 0], [4, 35, 38, 7, 0, 0], [4, 39, 39, -1, 0, 0], [5, 0, 39, -1, 0, 0], [6, 0, 39, -1, 0, 0], [7, 0, 39, -1, 0, 0], [8, 0, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [4, 39], True, 0, 0], [['[27, 79, 65]                            ', "'é' 269 122                             ", '[1, 0, 2]                               ', '[97, 98]                                ', "'KEY_F(12)' b'KEY_F(12)' b'KEY_UP' b'^[ ", '[120, 121, 122, -1]                     ', "b'\\x7f' b'\\x15' 38400 b'xterm-256color' ", '2164195328 False 10 40 8                ', '                                        ', '                                        '], [[0, 0, 3, 7, 0, 0], [0, 4, 4, -1, 0, 0], [0, 5, 7, 7, 0, 0], [0, 8, 8, -1, 0, 0], [0, 9, 11, 7, 0, 0], [0, 12, 39, -1, 0, 0], [1, 0, 2, 7, 0, 0], [1, 3, 3, -1, 0, 0], [1, 4, 6, 7, 0, 0], [1, 7, 7, -1, 0, 0], [1, 8, 10, 7, 0, 0], [1, 11, 39, -1, 0, 0], [2, 0, 2, 7, 0, 0], [2, 3, 3, -1, 0, 0], [2, 4, 5, 7, 0, 0], [2, 6, 6, -1, 0, 0], [2, 7, 8, 7, 0, 0], [2, 9, 39, -1, 0, 0], [3, 0, 3, 7, 0, 0], [3, 4, 4, -1, 0, 0], [3, 5, 7, 7, 0, 0], [3, 8, 39, -1, 0, 0], [4, 0, 10, 7, 0, 0], [4, 11, 11, -1, 0, 0], [4, 12, 23, 7, 0, 0], [4, 24, 24, -1, 0, 0], [4, 25, 33, 7, 0, 0], [4, 34, 34, -1, 0, 0], [4, 35, 38, 7, 0, 0], [4, 39, 39, -1, 0, 0], [5, 0, 4, 7, 0, 0], [5, 5, 5, -1, 0, 0], [5, 6, 9, 7, 0, 0], [5, 10, 10, -1, 0, 0], [5, 11, 14, 7, 0, 0], [5, 15, 15, -1, 0, 0], [5, 16, 18, 7, 0, 0], [5, 19, 39, -1, 0, 0], [6, 0, 6, 7, 0, 0], [6, 7, 7, -1, 0, 0], [6, 8, 14, 7, 0, 0], [6, 15, 15, -1, 0, 0], [6, 16, 20, 7, 0, 0], [6, 21, 21, -1, 0, 0], [6, 22, 38, 7, 0, 0], [6, 39, 39, -1, 0, 0], [7, 0, 9, 7, 0, 0], [7, 10, 10, -1, 0, 0], [7, 11, 15, 7, 0, 0], [7, 16, 16, -1, 0, 0], [7, 17, 18, 7, 0, 0], [7, 19, 19, -1, 0, 0], [7, 20, 21, 7, 0, 0], [7, 22, 22, -1, 0, 0], [7, 23, 23, 7, 0, 0], [7, 24, 39, -1, 0, 0], [8, 0, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [2, 9], True, 1, 1], [['[27, 79, 65]                            ', "'é' 269 122                             ", '[1, 0, 2]                               ', '[97, 98]                                ', "'KEY_F(12)' b'KEY_F(12)' b'KEY_UP' b'^[ ", '[120, 121, 122, -1]                     ', "b'\\x7f' b'\\x15' 38400 b'xterm-256color' ", '2164195328 False 10 40 8                ', "-1 ['error']                            ", "'no input'                              "], [[0, 0, 3, 7, 0, 0], [0, 4, 4, -1, 0, 0], [0, 5, 7, 7, 0, 0], [0, 8, 8, -1, 0, 0], [0, 9, 11, 7, 0, 0], [0, 12, 39, -1, 0, 0], [1, 0, 2, 7, 0, 0], [1, 3, 3, -1, 0, 0], [1, 4, 6, 7, 0, 0], [1, 7, 7, -1, 0, 0], [1, 8, 10, 7, 0, 0], [1, 11, 39, -1, 0, 0], [2, 0, 2, 7, 0, 0], [2, 3, 3, -1, 0, 0], [2, 4, 5, 7, 0, 0], [2, 6, 6, -1, 0, 0], [2, 7, 8, 7, 0, 0], [2, 9, 39, -1, 0, 0], [3, 0, 3, 7, 0, 0], [3, 4, 4, -1, 0, 0], [3, 5, 7, 7, 0, 0], [3, 8, 39, -1, 0, 0], [4, 0, 10, 7, 0, 0], [4, 11, 11, -1, 0, 0], [4, 12, 23, 7, 0, 0], [4, 24, 24, -1, 0, 0], [4, 25, 33, 7, 0, 0], [4, 34, 34, -1, 0, 0], [4, 35, 38, 7, 0, 0], [4, 39, 39, -1, 0, 0], [5, 0, 4, 7, 0, 0], [5, 5, 5, -1, 0, 0], [5, 6, 9, 7, 0, 0], [5, 10, 10, -1, 0, 0], [5, 11, 14, 7, 0, 0], [5, 15, 15, -1, 0, 0], [5, 16, 18, 7, 0, 0], [5, 19, 39, -1, 0, 0], [6, 0, 6, 7, 0, 0], [6, 7, 7, -1, 0, 0], [6, 8, 14, 7, 0, 0], [6, 15, 15, -1, 0, 0], [6, 16, 20, 7, 0, 0], [6, 21, 21, -1, 0, 0], [6, 22, 38, 7, 0, 0], [6, 39, 39, -1, 0, 0], [7, 0, 9, 7, 0, 0], [7, 10, 10, -1, 0, 0], [7, 11, 15, 7, 0, 0], [7, 16, 16, -1, 0, 0], [7, 17, 18, 7, 0, 0], [7, 19, 19, -1, 0, 0], [7, 20, 21, 7, 0, 0], [7, 22, 22, -1, 0, 0], [7, 23, 23, 7, 0, 0], [7, 24, 39, -1, 0, 0], [8, 0, 1, 7, 0, 0], [8, 2, 2, -1, 0, 0], [8, 3, 11, 7, 0, 0], [8, 12, 39, -1, 0, 0], [9, 0, 2, 7, 0, 0], [9, 3, 3, -1, 0, 0], [9, 4, 9, 7, 0, 0], [9, 10, 39, -1, 0, 0]], [9, 10], True, 1, 1], [['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 0], False, 1, 1]], 0],
    'mouse_resize/xterm-256color': [[[["'mask' 268435455 0            ", "'size' (10, 30)               ", '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              '], [[0, 0, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 15, 7, 0, 0], [0, 16, 16, -1, 0, 0], [0, 17, 17, 7, 0, 0], [0, 18, 29, -1, 0, 0], [1, 0, 5, 7, 0, 0], [1, 6, 6, -1, 0, 0], [1, 7, 10, 7, 0, 0], [1, 11, 11, -1, 0, 0], [1, 12, 14, 7, 0, 0], [1, 15, 29, -1, 0, 0], [2, 0, 29, -1, 0, 0], [3, 0, 29, -1, 0, 0], [4, 0, 29, -1, 0, 0], [5, 0, 29, -1, 0, 0], [6, 0, 29, -1, 0, 0], [7, 0, 29, -1, 0, 0], [8, 0, 29, -1, 0, 0], [9, 0, 29, -1, 0, 0]], [1, 15], True, 0, 0], [["'mask' 268435455 0            ", "'size' (10, 30)               ", '409 (0, 4, 2, 0, 4)           ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              '], [[0, 0, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 15, 7, 0, 0], [0, 16, 16, -1, 0, 0], [0, 17, 17, 7, 0, 0], [0, 18, 29, -1, 0, 0], [1, 0, 5, 7, 0, 0], [1, 6, 6, -1, 0, 0], [1, 7, 10, 7, 0, 0], [1, 11, 11, -1, 0, 0], [1, 12, 14, 7, 0, 0], [1, 15, 29, -1, 0, 0], [2, 0, 2, 7, 0, 0], [2, 3, 3, -1, 0, 0], [2, 4, 6, 7, 0, 0], [2, 7, 7, -1, 0, 0], [2, 8, 9, 7, 0, 0], [2, 10, 10, -1, 0, 0], [2, 11, 12, 7, 0, 0], [2, 13, 13, -1, 0, 0], [2, 14, 15, 7, 0, 0], [2, 16, 16, -1, 0, 0], [2, 17, 18, 7, 0, 0], [2, 19, 29, -1, 0, 0], [3, 0, 29, -1, 0, 0], [4, 0, 29, -1, 0, 0], [5, 0, 29, -1, 0, 0], [6, 0, 29, -1, 0, 0], [7, 0, 29, -1, 0, 0], [8, 0, 29, -1, 0, 0], [9, 0, 29, -1, 0, 0]], [2, 19], True, 0, 0], [["'mask' 268435455 0            ", "'size' (10, 30)               ", '409 (0, 4, 2, 0, 4)           ', '409 (0, 6, 1, 0, 2048)        ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              '], [[0, 0, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 15, 7, 0, 0], [0, 16, 16, -1, 0, 0], [0, 17, 17, 7, 0, 0], [0, 18, 29, -1, 0, 0], [1, 0, 5, 7, 0, 0], [1, 6, 6, -1, 0, 0], [1, 7, 10, 7, 0, 0], [1, 11, 11, -1, 0, 0], [1, 12, 14, 7, 0, 0], [1, 15, 29, -1, 0, 0], [2, 0, 2, 7, 0, 0], [2, 3, 3, -1, 0, 0], [2, 4, 6, 7, 0, 0], [2, 7, 7, -1, 0, 0], [2, 8, 9, 7, 0, 0], [2, 10, 10, -1, 0, 0], [2, 11, 12, 7, 0, 0], [2, 13, 13, -1, 0, 0], [2, 14, 15, 7, 0, 0], [2, 16, 16, -1, 0, 0], [2, 17, 18, 7, 0, 0], [2, 19, 29, -1, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 3, -1, 0, 0], [3, 4, 6, 7, 0, 0], [3, 7, 7, -1, 0, 0], [3, 8, 9, 7, 0, 0], [3, 10, 10, -1, 0, 0], [3, 11, 12, 7, 0, 0], [3, 13, 13, -1, 0, 0], [3, 14, 15, 7, 0, 0], [3, 16, 16, -1, 0, 0], [3, 17, 21, 7, 0, 0], [3, 22, 29, -1, 0, 0], [4, 0, 29, -1, 0, 0], [5, 0, 29, -1, 0, 0], [6, 0, 29, -1, 0, 0], [7, 0, 29, -1, 0, 0], [8, 0, 29, -1, 0, 0], [9, 0, 29, -1, 0, 0]], [3, 22], True, 0, 0], [['┌──────────────────────────────────┐', "│size' (10, 30)                    │", '│09 (0, 4, 2, 0, 4)                │', '│09 (0, 6, 1, 0, 2048)             │', "│key' 410 True                     │", "│LC' 12 36 (12, 36)                │", '│                                  │', '│                                  │', '│                                  │', '│                                  │', '│                                  │', '└──────────────────────────────────┘'], [[0, 0, 35, 7, 0, 0], [1, 0, 5, 7, 0, 0], [1, 6, 6, -1, 0, 0], [1, 7, 10, 7, 0, 0], [1, 11, 11, -1, 0, 0], [1, 12, 14, 7, 0, 0], [1, 15, 34, -1, 0, 0], [1, 35, 35, 7, 0, 0], [2, 0, 2, 7, 0, 0], [2, 3, 3, -1, 0, 0], [2, 4, 6, 7, 0, 0], [2, 7, 7, -1, 0, 0], [2, 8, 9, 7, 0, 0], [2, 10, 10, -1, 0, 0], [2, 11, 12, 7, 0, 0], [2, 13, 13, -1, 0, 0], [2, 14, 15, 7, 0, 0], [2, 16, 16, -1, 0, 0], [2, 17, 18, 7, 0, 0], [2, 19, 34, -1, 0, 0], [2, 35, 35, 7, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 3, -1, 0, 0], [3, 4, 6, 7, 0, 0], [3, 7, 7, -1, 0, 0], [3, 8, 9, 7, 0, 0], [3, 10, 10, -1, 0, 0], [3, 11, 12, 7, 0, 0], [3, 13, 13, -1, 0, 0], [3, 14, 15, 7, 0, 0], [3, 16, 16, -1, 0, 0], [3, 17, 21, 7, 0, 0], [3, 22, 34, -1, 0, 0], [3, 35, 35, 7, 0, 0], [4, 0, 4, 7, 0, 0], [4, 5, 5, -1, 0, 0], [4, 6, 8, 7, 0, 0], [4, 9, 9, -1, 0, 0], [4, 10, 13, 7, 0, 0], [4, 14, 34, -1, 0, 0], [4, 35, 35, 7, 0, 0], [5, 0, 3, 7, 0, 0], [5, 4, 4, -1, 0, 0], [5, 5, 6, 7, 0, 0], [5, 7, 7, -1, 0, 0], [5, 8, 9, 7, 0, 0], [5, 10, 10, -1, 0, 0], [5, 11, 14, 7, 0, 0], [5, 15, 15, -1, 0, 0], [5, 16, 18, 7, 0, 0], [5, 19, 34, -1, 0, 0], [5, 35, 35, 7, 0, 0], [6, 0, 0, 7, 0, 0], [6, 1, 34, -1, 0, 0], [6, 35, 35, 7, 0, 0], [7, 0, 0, 7, 0, 0], [7, 1, 34, -1, 0, 0], [7, 35, 35, 7, 0, 0], [8, 0, 0, 7, 0, 0], [8, 1, 34, -1, 0, 0], [8, 35, 35, 7, 0, 0], [9, 0, 0, 7, 0, 0], [9, 1, 34, -1, 0, 0], [9, 35, 35, 7, 0, 0], [10, 0, 0, 7, 0, 0], [10, 1, 34, -1, 0, 0], [10, 35, 35, 7, 0, 0], [11, 0, 35, 7, 0, 0]], [5, 19], True, 0, 0], [['┌──────────────────────────────────┐', "│size' (10, 30)                    │", '│09 (0, 4, 2, 0, 4)                │', '│09 (0, 6, 1, 0, 2048)             │', "│key' 410 True                     │", "│LC' 12 36 (12, 36)                │", '│esc 27                            │', '409 (0, 3, 4, 0, 2)                 ', '│                                  │', '│                                  │', '│                                  │', '└──────────────────────────────────┘'], [[0, 0, 35, 7, 0, 0], [1, 0, 5, 7, 0, 0], [1, 6, 6, -1, 0, 0], [1, 7, 10, 7, 0, 0], [1, 11, 11, -1, 0, 0], [1, 12, 14, 7, 0, 0], [1, 15, 34, -1, 0, 0], [1, 35, 35, 7, 0, 0], [2, 0, 2, 7, 0, 0], [2, 3, 3, -1, 0, 0], [2, 4, 6, 7, 0, 0], [2, 7, 7, -1, 0, 0], [2, 8, 9, 7, 0, 0], [2, 10, 10, -1, 0, 0], [2, 11, 12, 7, 0, 0], [2, 13, 13, -1, 0, 0], [2, 14, 15, 7, 0, 0], [2, 16, 16, -1, 0, 0], [2, 17, 18, 7, 0, 0], [2, 19, 34, -1, 0, 0], [2, 35, 35, 7, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 3, -1, 0, 0], [3, 4, 6, 7, 0, 0], [3, 7, 7, -1, 0, 0], [3, 8, 9, 7, 0, 0], [3, 10, 10, -1, 0, 0], [3, 11, 12, 7, 0, 0], [3, 13, 13, -1, 0, 0], [3, 14, 15, 7, 0, 0], [3, 16, 16, -1, 0, 0], [3, 17, 21, 7, 0, 0], [3, 22, 34, -1, 0, 0], [3, 35, 35, 7, 0, 0], [4, 0, 4, 7, 0, 0], [4, 5, 5, -1, 0, 0], [4, 6, 8, 7, 0, 0], [4, 9, 9, -1, 0, 0], [4, 10, 13, 7, 0, 0], [4, 14, 34, -1, 0, 0], [4, 35, 35, 7, 0, 0], [5, 0, 3, 7, 0, 0], [5, 4, 4, -1, 0, 0], [5, 5, 6, 7, 0, 0], [5, 7, 7, -1, 0, 0], [5, 8, 9, 7, 0, 0], [5, 10, 10, -1, 0, 0], [5, 11, 14, 7, 0, 0], [5, 15, 15, -1, 0, 0], [5, 16, 18, 7, 0, 0], [5, 19, 34, -1, 0, 0], [5, 35, 35, 7, 0, 0], [6, 0, 3, 7, 0, 0], [6, 4, 4, -1, 0, 0], [6, 5, 6, 7, 0, 0], [6, 7, 34, -1, 0, 0], [6, 35, 35, 7, 0, 0], [7, 0, 2, 7, 0, 0], [7, 3, 3, -1, 0, 0], [7, 4, 6, 7, 0, 0], [7, 7, 7, -1, 0, 0], [7, 8, 9, 7, 0, 0], [7, 10, 10, -1, 0, 0], [7, 11, 12, 7, 0, 0], [7, 13, 13, -1, 0, 0], [7, 14, 15, 7, 0, 0], [7, 16, 16, -1, 0, 0], [7, 17, 18, 7, 0, 0], [7, 19, 35, -1, 0, 0], [8, 0, 0, 7, 0, 0], [8, 1, 34, -1, 0, 0], [8, 35, 35, 7, 0, 0], [9, 0, 0, 7, 0, 0], [9, 1, 34, -1, 0, 0], [9, 35, 35, 7, 0, 0], [10, 0, 0, 7, 0, 0], [10, 1, 34, -1, 0, 0], [10, 35, 35, 7, 0, 0], [11, 0, 35, 7, 0, 0]], [7, 19], True, 0, 0], [['                                    ', '                                    ', '                                    ', '                                    ', '                                    ', '                                    ', '                                    ', '                                    ', '                                    ', '                                    ', '                                    ', '                                    '], [], [0, 0], False, 0, 0]], 0],
    'pads/vt100': [[[['                                        ', '  p05 p05 p05 p05 p05                   ', '  p06 p06 p06 p06 p06                   ', '  p07 p07 p07 p07 p07                   ', '  p08 p08 p08 p08 p08                   ', '  p09 p09 p09 p09 p09                   ', '  p10 p10 p10 p10 p10                   ', '                                        ', '                                        ', '                                        '], [], [0, 0], False, 0, 0], [['                                        ', ' p10 p10 p10 p10 p10                    ', ' p11 p11 p11 p11 p11  p30 p30 p30 p30   ', ' p12 p12 p12 p12 p12  p31 p31 p31 p31   ', ' p13 p13 p13 p13 p13  p32 p32 p32 p32   ', ' p14 p14 p14 p14 p14  p33 p33 p33 p33   ', ' p15 p15 p15 p15 p15  p34 p34 p34 p34   ', '                      p35 p35 p35 p35   ', '                      p36 p36 p36 p36   ', '                                        '], [], [0, 0], False, 0, 0], [['p00 p00 p00 p00                         ', ' p10 p10 p10 p10 p10                    ', ' p11 p11 p11 p11 p11  p30 p30 p30 p30   ', ' p12 p12 p12 p12 p12  p31 p31 p31 p31   ', ' p13 p13 p13 p13 p13  p32 p32 p32 p32   ', ' p14 p14 p14 p14 p14  p33 p33 p33 p33   ', ' p15 p15 p15 p15 p15  p34 p34 p34 p34   ', '                      p35 p35 p35 p35   ', '                      p36 p36 p36 p36   ', '(5, 10) (40, 60) (2, 2)                 '], [], [9, 23], False, 0, 0], [['p00 p00 p00 p00                         ', ' p10 p10 p10 p10 p10                    ', ' p11 p11 p11 p11 p11  p30 p30 p30 p30   ', ' p12 p12 p12 p12 p12  p31 p31 p31 p31   ', ' p13 p13 p13 p13 p13  p32 p32 p32 p32   ', ' p14 p14 p14 p14 p14  p33 p33 p33 p33   ', ' p15 p15 p15 p15 p15  p34 p34 p34 p34   ', "'refresh() takes no arguments (6 given) ", "'refresh() for a pad requires 6 argumen ", '(5, 10) (40, 60) (2, 2)                 '], [], [7, 39], False, 0, 0], [['p00 p00 p00 p00                         ', ' p10 p10 p10 p10 p10                    ', ' p11 p11 p11 p11 p11  p30 p30 p30 p30   ', ' p12 p12 p12 p12 p12  p31 p31 p31 p31   ', ' p13 p13 p13 p13 p13  p32 p32 p32 p32   ', ' p14 p14 p14 p14 p14  p33 p33 p33 p33   ', ' p15 p15 p15 p15 p15  p34 p34 p34 p34   ', "'refresh() takes no arguments (6 given) ", "'refresh() for a pad requires 6 argumen ", '(5, 10) (40, 60) (2, 2)                 '], [], [9, 0], False, 0, 0]], 0],
    'pads/xterm-256color': [[[['                                        ', '  p05 p05 p05 p05 p05                   ', '  p06 p06 p06 p06 p06                   ', '  p07 p07 p07 p07 p07                   ', '  p08 p08 p08 p08 p08                   ', '  p09 p09 p09 p09 p09                   ', '  p10 p10 p10 p10 p10                   ', '                                        ', '                                        ', '                                        '], [[1, 1, 20, -1, 1, 0], [2, 2, 4, 2, -1, 0], [2, 6, 8, 2, -1, 0], [2, 10, 12, 2, -1, 0], [2, 14, 16, 2, -1, 0], [2, 18, 20, 2, -1, 0], [3, 1, 20, -1, 1, 0], [4, 2, 4, 2, -1, 0], [4, 6, 8, 2, -1, 0], [4, 10, 12, 2, -1, 0], [4, 14, 16, 2, -1, 0], [4, 18, 20, 2, -1, 0], [5, 1, 20, -1, 1, 0], [6, 2, 4, 2, -1, 0], [6, 6, 8, 2, -1, 0], [6, 10, 12, 2, -1, 0], [6, 14, 16, 2, -1, 0], [6, 18, 20, 2, -1, 0]], [0, 0], True, 0, 0], [['                                        ', ' p10 p10 p10 p10 p10                    ', ' p11 p11 p11 p11 p11  p30 p30 p30 p30   ', ' p12 p12 p12 p12 p12  p31 p31 p31 p31   ', ' p13 p13 p13 p13 p13  p32 p32 p32 p32   ', ' p14 p14 p14 p14 p14  p33 p33 p33 p33   ', ' p15 p15 p15 p15 p15  p34 p34 p34 p34   ', '                      p35 p35 p35 p35   ', '                      p36 p36 p36 p36   ', '                                        '], [[1, 1, 3, 2, -1, 0], [1, 5, 7, 2, -1, 0], [1, 9, 11, 2, -1, 0], [1, 13, 15, 2, -1, 0], [1, 17, 19, 2, -1, 0], [2, 1, 20, -1, 1, 0], [2, 22, 24, 2, -1, 0], [2, 26, 28, 2, -1, 0], [2, 30, 32, 2, -1, 0], [2, 34, 36, 2, -1, 0], [3, 1, 3, 2, -1, 0], [3, 5, 7, 2, -1, 0], [3, 9, 11, 2, -1, 0], [3, 13, 15, 2, -1, 0], [3, 17, 19, 2, -1, 0], [3, 22, 37, -1, 1, 0], [4, 1, 20, -1, 1, 0], [4, 22, 24, 2, -1, 0], [4, 26, 28, 2, -1, 0], [4, 30, 32, 2, -1, 0], [4, 34, 36, 2, -1, 0], [5, 1, 3, 2, -1, 0], [5, 5, 7, 2, -1, 0], [5, 9, 11, 2, -1, 0], [5, 13, 15, 2, -1, 0], [5, 17, 19, 2, -1, 0], [5, 22, 37, -1, 1, 0], [6, 1, 20, -1, 1, 0], [6, 22, 24, 2, -1, 0], [6, 26, 28, 2, -1, 0], [6, 30, 32, 2, -1, 0], [6, 34, 36, 2, -1, 0], [7, 22, 37, -1, 1, 0], [8, 22, 24, 2, -1, 0], [8, 26, 28, 2, -1, 0], [8, 30, 32, 2, -1, 0], [8, 34, 36, 2, -1, 0]], [0, 0], True, 0, 0], [['p00 p00 p00 p00                         ', ' p10 p10 p10 p10 p10                    ', ' p11 p11 p11 p11 p11  p30 p30 p30 p30   ', ' p12 p12 p12 p12 p12  p31 p31 p31 p31   ', ' p13 p13 p13 p13 p13  p32 p32 p32 p32   ', ' p14 p14 p14 p14 p14  p33 p33 p33 p33   ', ' p15 p15 p15 p15 p15  p34 p34 p34 p34   ', '                      p35 p35 p35 p35   ', '                      p36 p36 p36 p36   ', '(5, 10) (40, 60) (2, 2)                 '], [[0, 0, 2, 2, -1, 0], [0, 4, 6, 2, -1, 0], [0, 8, 10, 2, -1, 0], [0, 12, 14, 2, -1, 0], [1, 1, 3, 2, -1, 0], [1, 5, 7, 2, -1, 0], [1, 9, 11, 2, -1, 0], [1, 13, 15, 2, -1, 0], [1, 17, 19, 2, -1, 0], [2, 1, 20, -1, 1, 0], [2, 22, 24, 2, -1, 0], [2, 26, 28, 2, -1, 0], [2, 30, 32, 2, -1, 0], [2, 34, 36, 2, -1, 0], [3, 1, 3, 2, -1, 0], [3, 5, 7, 2, -1, 0], [3, 9, 11, 2, -1, 0], [3, 13, 15, 2, -1, 0], [3, 17, 19, 2, -1, 0], [3, 22, 37, -1, 1, 0], [4, 1, 20, -1, 1, 0], [4, 22, 24, 2, -1, 0], [4, 26, 28, 2, -1, 0], [4, 30, 32, 2, -1, 0], [4, 34, 36, 2, -1, 0], [5, 1, 3, 2, -1, 0], [5, 5, 7, 2, -1, 0], [5, 9, 11, 2, -1, 0], [5, 13, 15, 2, -1, 0], [5, 17, 19, 2, -1, 0], [5, 22, 37, -1, 1, 0], [6, 1, 20, -1, 1, 0], [6, 22, 24, 2, -1, 0], [6, 26, 28, 2, -1, 0], [6, 30, 32, 2, -1, 0], [6, 34, 36, 2, -1, 0], [7, 22, 37, -1, 1, 0], [8, 22, 24, 2, -1, 0], [8, 26, 28, 2, -1, 0], [8, 30, 32, 2, -1, 0], [8, 34, 36, 2, -1, 0]], [9, 23], True, 0, 0], [['p00 p00 p00 p00                         ', ' p10 p10 p10 p10 p10                    ', ' p11 p11 p11 p11 p11  p30 p30 p30 p30   ', ' p12 p12 p12 p12 p12  p31 p31 p31 p31   ', ' p13 p13 p13 p13 p13  p32 p32 p32 p32   ', ' p14 p14 p14 p14 p14  p33 p33 p33 p33   ', ' p15 p15 p15 p15 p15  p34 p34 p34 p34   ', "'refresh() takes no arguments (6 given) ", "'refresh() for a pad requires 6 argumen ", '(5, 10) (40, 60) (2, 2)                 '], [[0, 0, 2, 2, -1, 0], [0, 4, 6, 2, -1, 0], [0, 8, 10, 2, -1, 0], [0, 12, 14, 2, -1, 0], [1, 1, 3, 2, -1, 0], [1, 5, 7, 2, -1, 0], [1, 9, 11, 2, -1, 0], [1, 13, 15, 2, -1, 0], [1, 17, 19, 2, -1, 0], [2, 1, 20, -1, 1, 0], [2, 22, 24, 2, -1, 0], [2, 26, 28, 2, -1, 0], [2, 30, 32, 2, -1, 0], [2, 34, 36, 2, -1, 0], [3, 1, 3, 2, -1, 0], [3, 5, 7, 2, -1, 0], [3, 9, 11, 2, -1, 0], [3, 13, 15, 2, -1, 0], [3, 17, 19, 2, -1, 0], [3, 22, 37, -1, 1, 0], [4, 1, 20, -1, 1, 0], [4, 22, 24, 2, -1, 0], [4, 26, 28, 2, -1, 0], [4, 30, 32, 2, -1, 0], [4, 34, 36, 2, -1, 0], [5, 1, 3, 2, -1, 0], [5, 5, 7, 2, -1, 0], [5, 9, 11, 2, -1, 0], [5, 13, 15, 2, -1, 0], [5, 17, 19, 2, -1, 0], [5, 22, 37, -1, 1, 0], [6, 1, 20, -1, 1, 0], [6, 22, 24, 2, -1, 0], [6, 26, 28, 2, -1, 0], [6, 30, 32, 2, -1, 0], [6, 34, 36, 2, -1, 0]], [7, 39], True, 0, 0], [['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 0], False, 0, 0]], 0],
    'panels/vt100': [[[['00000000000000000000000000000 ', '11┌──────────┐111111111111111 ', '22│panel 0   │222222222222222 ', '33│   ┌──────────┐33333333333 ', '44└───│panel 1   │44444444444 ', '555555│   ┌──────────┐5555555 ', '666666└───│panel 2   │6666666 ', '7777777777│          │7777777 ', '8888888888└──────────┘8888888 ', '99999999999999999999999999999 '], [], [6, 18], False, 0, 0], [['00000000000000000000000000000 ', '11┌──────────┐111111111111111 ', '22│panel 0   │222222222222222 ', '33│          │───┐33333333333 ', '44└──────────┘   │44444444444 ', '555555│   ┌──────────┐5555555 ', '666666└───│panel 2   │6666666 ', '7777777777│          │7777777 ', '8888888888└──────────┘8888888 ', '99999999999999999999999999999 '], [], [2, 10], False, 0, 0], [['00000000000000000000000000000 ', '11┌──────────┐111111111111111 ', '22│panel 0   │222222222222222 ', '33│          │333333333333333 ', '44└──────────┘444444444444444 ', '5555555555┌──────────┐5555555 ', '6666666666│panel 2   │6666666 ', '7777777777│          │7777777 ', '8888888888└──────────┘8888888 ', '99999999999999999999999999999 '], [], [2, 10], False, 0, 0], [['000000000000000┌──────────┐00 ', '11┌──────────┐1│panel 2   │11 ', '22│panel 0   │2│          │22 ', '33│   ┌──────────┐────────┘33 ', '44└───│panel 1   │44444444444 ', '555555│          │55555555555 ', '666666└──────────┘66666666666 ', '77777777777777777777777777777 ', '88888888888888888888888888888 ', '99999999999999999999999999999 '], [], [4, 14], False, 0, 0], [['000000000000000┌──────────┐00 ', '11┌──────────┐1│panel 2   │11 ', '22│panel 0   │2│          │22 ', '33│          │3└──────────┘33 ', '44└──────────┘444444444444444 ', '55555555555555555555555555555 ', '66666666666666666666666666666 ', '7replaced77777777777777777777 ', '8        88888888888888888888 ', "'p1' 'p0' 'p1' 'p0' False Tru "], [], [8, 1], False, 0, 0], [['000000000000000┌──────────┐00 ', '11┌──────────┐1│panel 2   │11 ', '22│panel 0   │2│          │22 ', '33│          │3└──────────┘33 ', '44└──────────┘444444444444444 ', '55555555555555555555555555555 ', '66666666666666666666666666666 ', '7replaced77777777777777777777 ', '8        88888888888888888888 ', "'p1' 'p0' 'p1' 'p0' False Tru "], [], [9, 0], False, 0, 0]], 0],
    'panels/xterm-256color': [[[['00000000000000000000000000000 ', '11┌──────────┐111111111111111 ', '22│panel 0   │222222222222222 ', '33│   ┌──────────┐33333333333 ', '44└───│panel 1   │44444444444 ', '555555│   ┌──────────┐5555555 ', '666666└───│panel 2   │6666666 ', '7777777777│          │7777777 ', '8888888888└──────────┘8888888 ', '99999999999999999999999999999 '], [[0, 0, 28, 7, 0, 0], [0, 29, 29, -1, 0, 0], [1, 0, 28, 7, 0, 0], [1, 29, 29, -1, 0, 0], [2, 0, 7, 7, 0, 0], [2, 8, 8, -1, 0, 0], [2, 9, 9, 7, 0, 0], [2, 10, 12, -1, 0, 0], [2, 13, 28, 7, 0, 0], [2, 29, 29, -1, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 5, -1, 0, 0], [3, 6, 28, 7, 0, 0], [3, 29, 29, -1, 0, 0], [4, 0, 11, 7, 0, 0], [4, 12, 12, -1, 0, 0], [4, 13, 13, 7, 0, 0], [4, 14, 16, -1, 0, 0], [4, 17, 28, 7, 0, 0], [4, 29, 29, -1, 0, 0], [5, 0, 6, 7, 0, 0], [5, 7, 9, -1, 0, 0], [5, 10, 28, 7, 0, 0], [5, 29, 29, -1, 0, 0], [6, 0, 15, 7, 0, 0], [6, 16, 16, -1, 0, 0], [6, 17, 17, 7, 0, 0], [6, 18, 20, -1, 0, 0], [6, 21, 28, 7, 0, 0], [6, 29, 29, -1, 0, 0], [7, 0, 10, 7, 0, 0], [7, 11, 20, -1, 0, 0], [7, 21, 28, 7, 0, 0], [7, 29, 29, -1, 0, 0], [8, 0, 28, 7, 0, 0], [8, 29, 29, -1, 0, 0], [9, 0, 28, 7, 0, 0], [9, 29, 29, -1, 0, 0]], [6, 18], True, 0, 0], [['00000000000000000000000000000 ', '11┌──────────┐111111111111111 ', '22│panel 0   │222222222222222 ', '33│          │───┐33333333333 ', '44└──────────┘   │44444444444 ', '555555│   ┌──────────┐5555555 ', '666666└───│panel 2   │6666666 ', '7777777777│          │7777777 ', '8888888888└──────────┘8888888 ', '99999999999999999999999999999 '], [[0, 0, 28, 7, 0, 0], [0, 29, 29, -1, 0, 0], [1, 0, 28, 7, 0, 0], [1, 29, 29, -1, 0, 0], [2, 0, 7, 7, 0, 0], [2, 8, 8, -1, 0, 0], [2, 9, 9, 7, 0, 0], [2, 10, 12, -1, 0, 0], [2, 13, 28, 7, 0, 0], [2, 29, 29, -1, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 12, -1, 0, 0], [3, 13, 28, 7, 0, 0], [3, 29, 29, -1, 0, 0], [4, 0, 13, 7, 0, 0], [4, 14, 16, -1, 0, 0], [4, 17, 28, 7, 0, 0], [4, 29, 29, -1, 0, 0], [5, 0, 6, 7, 0, 0], [5, 7, 9, -1, 0, 0], [5, 10, 28, 7, 0, 0], [5, 29, 29, -1, 0, 0], [6, 0, 15, 7, 0, 0], [6, 16, 16, -1, 0, 0], [6, 17, 17, 7, 0, 0], [6, 18, 20, -1, 0, 0], [6, 21, 28, 7, 0, 0], [6, 29, 29, -1, 0, 0], [7, 0, 10, 7, 0, 0], [7, 11, 20, -1, 0, 0], [7, 21, 28, 7, 0, 0], [7, 29, 29, -1, 0, 0], [8, 0, 28, 7, 0, 0], [8, 29, 29, -1, 0, 0], [9, 0, 28, 7, 0, 0], [9, 29, 29, -1, 0, 0]], [2, 10], True, 0, 0], [['00000000000000000000000000000 ', '11┌──────────┐111111111111111 ', '22│panel 0   │222222222222222 ', '33│          │333333333333333 ', '44└──────────┘444444444444444 ', '5555555555┌──────────┐5555555 ', '6666666666│panel 2   │6666666 ', '7777777777│          │7777777 ', '8888888888└──────────┘8888888 ', '99999999999999999999999999999 '], [[0, 0, 28, 7, 0, 0], [0, 29, 29, -1, 0, 0], [1, 0, 28, 7, 0, 0], [1, 29, 29, -1, 0, 0], [2, 0, 7, 7, 0, 0], [2, 8, 8, -1, 0, 0], [2, 9, 9, 7, 0, 0], [2, 10, 12, -1, 0, 0], [2, 13, 28, 7, 0, 0], [2, 29, 29, -1, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 12, -1, 0, 0], [3, 13, 28, 7, 0, 0], [3, 29, 29, -1, 0, 0], [4, 0, 28, 7, 0, 0], [4, 29, 29, -1, 0, 0], [5, 0, 28, 7, 0, 0], [5, 29, 29, -1, 0, 0], [6, 0, 15, 7, 0, 0], [6, 16, 16, -1, 0, 0], [6, 17, 17, 7, 0, 0], [6, 18, 20, -1, 0, 0], [6, 21, 28, 7, 0, 0], [6, 29, 29, -1, 0, 0], [7, 0, 10, 7, 0, 0], [7, 11, 20, -1, 0, 0], [7, 21, 28, 7, 0, 0], [7, 29, 29, -1, 0, 0], [8, 0, 28, 7, 0, 0], [8, 29, 29, -1, 0, 0], [9, 0, 28, 7, 0, 0], [9, 29, 29, -1, 0, 0]], [2, 10], True, 0, 0], [['000000000000000┌──────────┐00 ', '11┌──────────┐1│panel 2   │11 ', '22│panel 0   │2│          │22 ', '33│   ┌──────────┐────────┘33 ', '44└───│panel 1   │44444444444 ', '555555│          │55555555555 ', '666666└──────────┘66666666666 ', '77777777777777777777777777777 ', '88888888888888888888888888888 ', '99999999999999999999999999999 '], [[0, 0, 28, 7, 0, 0], [0, 29, 29, -1, 0, 0], [1, 0, 20, 7, 0, 0], [1, 21, 21, -1, 0, 0], [1, 22, 22, 7, 0, 0], [1, 23, 25, -1, 0, 0], [1, 26, 28, 7, 0, 0], [1, 29, 29, -1, 0, 0], [2, 0, 7, 7, 0, 0], [2, 8, 8, -1, 0, 0], [2, 9, 9, 7, 0, 0], [2, 10, 12, -1, 0, 0], [2, 13, 15, 7, 0, 0], [2, 16, 25, -1, 0, 0], [2, 26, 28, 7, 0, 0], [2, 29, 29, -1, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 5, -1, 0, 0], [3, 6, 28, 7, 0, 0], [3, 29, 29, -1, 0, 0], [4, 0, 11, 7, 0, 0], [4, 12, 12, -1, 0, 0], [4, 13, 13, 7, 0, 0], [4, 14, 16, -1, 0, 0], [4, 17, 28, 7, 0, 0], [4, 29, 29, -1, 0, 0], [5, 0, 6, 7, 0, 0], [5, 7, 16, -1, 0, 0], [5, 17, 28, 7, 0, 0], [5, 29, 29, -1, 0, 0], [6, 0, 28, 7, 0, 0], [6, 29, 29, -1, 0, 0], [7, 0, 28, 7, 0, 0], [7, 29, 29, -1, 0, 0], [8, 0, 28, 7, 0, 0], [8, 29, 29, -1, 0, 0], [9, 0, 28, 7, 0, 0], [9, 29, 29, -1, 0, 0]], [4, 14], True, 0, 0], [['000000000000000┌──────────┐00 ', '11┌──────────┐1│panel 2   │11 ', '22│panel 0   │2│          │22 ', '33│          │3└──────────┘33 ', '44└──────────┘444444444444444 ', '55555555555555555555555555555 ', '66666666666666666666666666666 ', '7replaced77777777777777777777 ', '8        88888888888888888888 ', "'p1' 'p0' 'p1' 'p0' False Tru "], [[0, 0, 28, 7, 0, 0], [0, 29, 29, -1, 0, 0], [1, 0, 20, 7, 0, 0], [1, 21, 21, -1, 0, 0], [1, 22, 22, 7, 0, 0], [1, 23, 25, -1, 0, 0], [1, 26, 28, 7, 0, 0], [1, 29, 29, -1, 0, 0], [2, 0, 7, 7, 0, 0], [2, 8, 8, -1, 0, 0], [2, 9, 9, 7, 0, 0], [2, 10, 12, -1, 0, 0], [2, 13, 15, 7, 0, 0], [2, 16, 25, -1, 0, 0], [2, 26, 28, 7, 0, 0], [2, 29, 29, -1, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 12, -1, 0, 0], [3, 13, 28, 7, 0, 0], [3, 29, 29, -1, 0, 0], [4, 0, 28, 7, 0, 0], [4, 29, 29, -1, 0, 0], [5, 0, 28, 7, 0, 0], [5, 29, 29, -1, 0, 0], [6, 0, 28, 7, 0, 0], [6, 29, 29, -1, 0, 0], [7, 0, 28, 7, 0, 0], [7, 29, 29, -1, 0, 0], [8, 0, 0, 7, 0, 0], [8, 1, 8, -1, 0, 0], [8, 9, 28, 7, 0, 0], [8, 29, 29, -1, 0, 0], [9, 0, 3, 7, 0, 0], [9, 4, 4, -1, 0, 0], [9, 5, 8, 7, 0, 0], [9, 9, 9, -1, 0, 0], [9, 10, 13, 7, 0, 0], [9, 14, 14, -1, 0, 0], [9, 15, 18, 7, 0, 0], [9, 19, 19, -1, 0, 0], [9, 20, 24, 7, 0, 0], [9, 25, 25, -1, 0, 0], [9, 26, 28, 7, 0, 0], [9, 29, 29, -1, 0, 0]], [8, 1], True, 0, 0], [['                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              '], [], [0, 0], False, 0, 0]], 0],
    'resume/vt100': [[[['before endwin                           ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 13], False, 0, 0], [['before endwin                           ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', 'in the shell                            '], [], [9, 12], False, 0, 0], [['before endwin                           ', "'after' True                            ", '                                        ', '                                        ', '                                        ', '                    ┌────────┐          ', '                    │saved   │          ', '                    └────────┘          ', '                                        ', 'False (3, 10) (5, 20) (1, 6)            '], [], [9, 28], False, 0, 0], [['before endwin                           ', "'after' True                            ", '                                        ', '                                        ', '                                        ', '                    ┌────────┐          ', '                    │saved   │          ', '                    └────────┘          ', '                                        ', 'False (3, 10) (5, 20) (1, 6)            '], [], [9, 0], False, 0, 0]], 0],
    'resume/xterm-256color': [[[['before endwin                           ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [[0, 0, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 12, 7, 0, 0], [0, 13, 39, -1, 0, 0], [1, 0, 39, -1, 0, 0], [2, 0, 39, -1, 0, 0], [3, 0, 39, -1, 0, 0], [4, 0, 39, -1, 0, 0], [5, 0, 39, -1, 0, 0], [6, 0, 39, -1, 0, 0], [7, 0, 39, -1, 0, 0], [8, 0, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [0, 13], True, 0, 0], [['in the shell                            ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 12], False, 0, 0], [['before endwin                           ', "'after' True                            ", '                                        ', '                                        ', '                                        ', '                    ┌────────┐          ', '                    │saved   │          ', '                    └────────┘          ', '                                        ', 'False (3, 10) (5, 20) (1, 6)            '], [[0, 0, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 12, 7, 0, 0], [0, 13, 39, -1, 0, 0], [1, 0, 6, 7, 0, 0], [1, 7, 7, -1, 0, 0], [1, 8, 11, 7, 0, 0], [1, 12, 39, -1, 0, 0], [2, 0, 39, -1, 0, 0], [3, 0, 39, -1, 0, 0], [4, 0, 39, -1, 0, 0], [5, 0, 19, -1, 0, 0], [5, 20, 29, 7, 0, 0], [5, 30, 39, -1, 0, 0], [6, 0, 19, -1, 0, 0], [6, 20, 25, 7, 0, 0], [6, 26, 28, -1, 0, 0], [6, 29, 29, 7, 0, 0], [6, 30, 39, -1, 0, 0], [7, 0, 19, -1, 0, 0], [7, 20, 29, 7, 0, 0], [7, 30, 39, -1, 0, 0], [8, 0, 39, -1, 0, 0], [9, 0, 4, 7, 0, 0], [9, 5, 5, -1, 0, 0], [9, 6, 8, 7, 0, 0], [9, 9, 9, -1, 0, 0], [9, 10, 12, 7, 0, 0], [9, 13, 13, -1, 0, 0], [9, 14, 16, 7, 0, 0], [9, 17, 17, -1, 0, 0], [9, 18, 20, 7, 0, 0], [9, 21, 21, -1, 0, 0], [9, 22, 24, 7, 0, 0], [9, 25, 25, -1, 0, 0], [9, 26, 27, 7, 0, 0], [9, 28, 39, -1, 0, 0]], [9, 28], True, 0, 0], [['in the shell                            ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 0], False, 0, 0]], 0],
    'scroll/vt100': [[[['line 5                        ', 'line 6                        ', 'line 7                        ', 'line 8                        ', 'line 9                        ', 'line 10                       ', 'line 11                       ', 'line 12                       ', 'line 13                       ', '                              '], [], [9, 0], False, 0, 0], [['line 5                        ', 'line 6                        ', 'line 10                       ', 'reg 0                         ', 'reg 1                         ', 'reg 2                         ', '                              ', 'line 12                       ', 'line 13                       ', '                              '], [[3, 0, 2, -1, -1, 1], [3, 4, 4, -1, -1, 1], [4, 0, 2, -1, -1, 1], [4, 4, 4, -1, -1, 1], [5, 0, 2, -1, -1, 1], [5, 4, 4, -1, -1, 1]], [6, 0], False, 0, 0], [['top0                          ', '                              ', 'line 5                        ', 'line 6                        ', 'line 10                       ', 'reg 0                         ', 'reg 1                         ', 'reg 2                         ', '                              ', 'line 12                       '], [[5, 0, 2, -1, -1, 1], [5, 4, 4, -1, -1, 1], [6, 0, 2, -1, -1, 1], [6, 4, 4, -1, -1, 1], [7, 0, 2, -1, -1, 1], [7, 4, 4, -1, -1, 1]], [0, 4], False, 0, 0], [['top0                          ', '                              ', 'linXe 5                       ', 'ine 6                         ', 'inserted                      ', 'liINSne 10                    ', 'abcreg 0                      ', 'reg 2                         ', '                              ', '                              '], [[6, 3, 5, -1, -1, 1], [6, 7, 7, -1, -1, 1], [7, 0, 2, -1, -1, 1], [7, 4, 4, -1, -1, 1]], [8, 0], False, 0, 0], [['top0                          ', '                              ', 'linXe 5                       ', 'ine 6....................     ', 'inser.bkgd.win...........     ', 'liINS....................     ', 'abcre....................     ', 'reg 2....................     ', '                              ', '                              '], [[3, 5, 24, -1, -1, 1], [4, 5, 24, -1, -1, 1], [5, 5, 24, -1, -1, 1], [6, 3, 24, -1, -1, 1], [7, 0, 2, -1, -1, 1], [7, 4, 24, -1, -1, 1]], [4, 14], False, 0, 0], [['top0                          ', '                              ', 'linXe 5                       ', 'ine 6w2..................     ', 'inserw3..................     ', 'liINSw4..................     ', 'abcrew5..................     ', 'reg 2....................     ', '                              ', '                              '], [[3, 5, 24, -1, -1, 1], [4, 5, 24, -1, -1, 1], [5, 5, 24, -1, -1, 1], [6, 3, 24, -1, -1, 1], [7, 0, 2, -1, -1, 1], [7, 4, 24, -1, -1, 1]], [7, 5], False, 0, 0], [['erased                        ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              '], [], [0, 6], False, 0, 0], [['erased                        ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              '], [], [9, 0], False, 0, 0]], 0],
    'scroll/xterm-256color': [[[['line 5                        ', 'line 6                        ', 'line 7                        ', 'line 8                        ', 'line 9                        ', 'line 10                       ', 'line 11                       ', 'line 12                       ', 'line 13                       ', '                              '], [[0, 0, 3, 7, 0, 0], [0, 4, 4, -1, 0, 0], [0, 5, 5, 7, 0, 0], [0, 6, 29, -1, 0, 0], [1, 0, 3, 7, 0, 0], [1, 4, 4, -1, 0, 0], [1, 5, 5, 7, 0, 0], [1, 6, 29, -1, 0, 0], [2, 0, 3, 7, 0, 0], [2, 4, 4, -1, 0, 0], [2, 5, 5, 7, 0, 0], [2, 6, 29, -1, 0, 0], [3, 0, 3, 7, 0, 0], [3, 4, 4, -1, 0, 0], [3, 5, 5, 7, 0, 0], [3, 6, 29, -1, 0, 0], [4, 0, 3, 7, 0, 0], [4, 4, 4, -1, 0, 0], [4, 5, 5, 7, 0, 0], [4, 6, 29, -1, 0, 0], [5, 0, 3, 7, 0, 0], [5, 4, 4, -1, 0, 0], [5, 5, 6, 7, 0, 0], [5, 7, 29, -1, 0, 0], [6, 0, 3, 7, 0, 0], [6, 4, 4, -1, 0, 0], [6, 5, 6, 7, 0, 0], [6, 7, 29, -1, 0, 0], [7, 0, 3, 7, 0, 0], [7, 4, 4, -1, 0, 0], [7, 5, 6, 7, 0, 0], [7, 7, 29, -1, 0, 0], [8, 0, 3, 7, 0, 0], [8, 4, 4, -1, 0, 0], [8, 5, 6, 7, 0, 0], [8, 7, 29, -1, 0, 0], [9, 0, 29, -1, 0, 0]], [9, 0], True, 0, 0], [['line 5                        ', 'line 6                        ', 'line 10                       ', 'reg 0                         ', 'reg 1                         ', 'reg 2                         ', '                              ', 'line 12                       ', 'line 13                       ', '                              '], [[0, 0, 3, 7, 0, 0], [0, 4, 4, -1, 0, 0], [0, 5, 5, 7, 0, 0], [0, 6, 29, -1, 0, 0], [1, 0, 3, 7, 0, 0], [1, 4, 4, -1, 0, 0], [1, 5, 5, 7, 0, 0], [1, 6, 29, -1, 0, 0], [2, 0, 3, 7, 0, 0], [2, 4, 4, -1, 0, 0], [2, 5, 6, 7, 0, 0], [2, 7, 29, -1, 0, 0], [3, 0, 2, 3, 4, 0], [3, 3, 3, -1, 4, 0], [3, 4, 4, 3, 4, 0], [3, 5, 29, -1, 0, 0], [4, 0, 2, 3, 4, 0], [4, 3, 3, -1, 4, 0], [4, 4, 4, 3, 4, 0], [4, 5, 29, -1, 0, 0], [5, 0, 2, 3, 4, 0], [5, 3, 3, -1, 4, 0], [5, 4, 4, 3, 4, 0], [5, 5, 29, -1, 0, 0], [6, 0, 29, -1, 0, 0], [7, 0, 3, 7, 0, 0], [7, 4, 4, -1, 0, 0], [7, 5, 6, 7, 0, 0], [7, 7, 29, -1, 0, 0], [8, 0, 3, 7, 0, 0], [8, 4, 4, -1, 0, 0], [8, 5, 6, 7, 0, 0], [8, 7, 29, -1, 0, 0], [9, 0, 29, -1, 0, 0]], [6, 0], True, 0, 0], [['top0                          ', '                              ', 'line 5                        ', 'line 6                        ', 'line 10                       ', 'reg 0                         ', 'reg 1                         ', 'reg 2                         ', '                              ', 'line 12                       '], [[0, 0, 3, 7, 0, 0], [0, 4, 29, -1, 0, 0], [1, 0, 29, -1, 0, 0], [2, 0, 3, 7, 0, 0], [2, 4, 4, -1, 0, 0], [2, 5, 5, 7, 0, 0], [2, 6, 29, -1, 0, 0], [3, 0, 3, 7, 0, 0], [3, 4, 4, -1, 0, 0], [3, 5, 5, 7, 0, 0], [3, 6, 29, -1, 0, 0], [4, 0, 3, 7, 0, 0], [4, 4, 4, -1, 0, 0], [4, 5, 6, 7, 0, 0], [4, 7, 29, -1, 0, 0], [5, 0, 2, 3, 4, 0], [5, 3, 3, -1, 4, 0], [5, 4, 4, 3, 4, 0], [5, 5, 29, -1, 0, 0], [6, 0, 2, 3, 4, 0], [6, 3, 3, -1, 4, 0], [6, 4, 4, 3, 4, 0], [6, 5, 29, -1, 0, 0], [7, 0, 2, 3, 4, 0], [7, 3, 3, -1, 4, 0], [7, 4, 4, 3, 4, 0], [7, 5, 29, -1, 0, 0], [8, 0, 29, -1, 0, 0], [9, 0, 3, 7, 0, 0], [9, 4, 4, -1, 0, 0], [9, 5, 6, 7, 0, 0], [9, 7, 29, -1, 0, 0]], [0, 4], True, 0, 0], [['top0                          ', '                              ', 'linXe 5                       ', 'ine 6                         ', 'inserted                      ', 'liINSne 10                    ', 'abcreg 0                      ', 'reg 2                         ', '                              ', '                              '], [[0, 0, 3, 7, 0, 0], [0, 4, 29, -1, 0, 0], [1, 0, 29, -1, 0, 0], [2, 0, 4, 7, 0, 0], [2, 5, 5, -1, 0, 0], [2, 6, 6, 7, 0, 0], [2, 7, 29, -1, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 3, -1, 0, 0], [3, 4, 4, 7, 0, 0], [3, 5, 29, -1, 0, 0], [4, 0, 7, 7, 0, 0], [4, 8, 29, -1, 0, 0], [5, 0, 6, 7, 0, 0], [5, 7, 7, -1, 0, 0], [5, 8, 9, 7, 0, 0], [5, 10, 29, -1, 0, 0], [6, 0, 2, 7, 0, 0], [6, 3, 5, 3, 4, 0], [6, 6, 6, -1, 4, 0], [6, 7, 7, 3, 4, 0], [6, 8, 29, -1, 0, 0], [7, 0, 2, 3, 4, 0], [7, 3, 3, -1, 4, 0], [7, 4, 4, 3, 4, 0], [7, 5, 29, -1, 0, 0], [8, 0, 29, -1, 0, 0], [9, 0, 29, -1, 0, 0]], [8, 0], True, 0, 0], [['top0                          ', '                              ', 'linXe 5                       ', 'ine 6....................     ', 'inser.bkgd.win...........     ', 'liINS....................     ', 'abcre....................     ', 'reg 2....................     ', '                              ', '                              '], [[0, 0, 3, 7, 0, 0], [0, 4, 29, -1, 0, 0], [1, 0, 29, -1, 0, 0], [2, 0, 4, 7, 0, 0], [2, 5, 5, -1, 0, 0], [2, 6, 6, 7, 0, 0], [2, 7, 29, -1, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 3, -1, 0, 0], [3, 4, 4, 7, 0, 0], [3, 5, 24, 3, 4, 0], [3, 25, 29, -1, 0, 0], [4, 0, 4, 7, 0, 0], [4, 5, 24, 3, 4, 0], [4, 25, 29, -1, 0, 0], [5, 0, 4, 7, 0, 0], [5, 5, 24, 3, 4, 0], [5, 25, 29, -1, 0, 0], [6, 0, 2, 7, 0, 0], [6, 3, 24, 3, 4, 0], [6, 25, 29, -1, 0, 0], [7, 0, 2, 3, 4, 0], [7, 3, 3, -1, 4, 0], [7, 4, 24, 3, 4, 0], [7, 25, 29, -1, 0, 0], [8, 0, 29, -1, 0, 0], [9, 0, 29, -1, 0, 0]], [4, 14], True, 0, 0], [['top0                          ', '                              ', 'linXe 5                       ', 'ine 6w2..................     ', 'inserw3..................     ', 'liINSw4..................     ', 'abcrew5..................     ', 'reg 2....................     ', '                              ', '                              '], [[0, 0, 3, 7, 0, 0], [0, 4, 29, -1, 0, 0], [1, 0, 29, -1, 0, 0], [2, 0, 4, 7, 0, 0], [2, 5, 5, -1, 0, 0], [2, 6, 6, 7, 0, 0], [2, 7, 29, -1, 0, 0], [3, 0, 2, 7, 0, 0], [3, 3, 3, -1, 0, 0], [3, 4, 4, 7, 0, 0], [3, 5, 24, 3, 4, 0], [3, 25, 29, -1, 0, 0], [4, 0, 4, 7, 0, 0], [4, 5, 24, 3, 4, 0], [4, 25, 29, -1, 0, 0], [5, 0, 4, 7, 0, 0], [5, 5, 24, 3, 4, 0], [5, 25, 29, -1, 0, 0], [6, 0, 2, 7, 0, 0], [6, 3, 24, 3, 4, 0], [6, 25, 29, -1, 0, 0], [7, 0, 2, 3, 4, 0], [7, 3, 3, -1, 4, 0], [7, 4, 24, 3, 4, 0], [7, 25, 29, -1, 0, 0], [8, 0, 29, -1, 0, 0], [9, 0, 29, -1, 0, 0]], [7, 5], True, 0, 0], [['erased                        ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              '], [[0, 0, 5, 7, 0, 0], [0, 6, 29, -1, 0, 0], [1, 0, 29, -1, 0, 0], [2, 0, 29, -1, 0, 0], [3, 0, 29, -1, 0, 0], [4, 0, 29, -1, 0, 0], [5, 0, 29, -1, 0, 0], [6, 0, 29, -1, 0, 0], [7, 0, 29, -1, 0, 0], [8, 0, 29, -1, 0, 0], [9, 0, 29, -1, 0, 0]], [0, 6], True, 0, 0], [['                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              ', '                              '], [], [0, 0], False, 0, 0]], 0],
    'textpad/vt100': [[[['                                        ', ' ┌──────────────────┐                   ', ' │                  │                   ', ' │                  │                   ', ' │                  │                   ', ' └──────────────────┘                   ', '                                        ', '                                        ', '                                        ', '                                        '], [], [5, 2], False, 0, 0], [['                                        ', ' ┌──────────────────┐                   ', ' │helXY             │                   ', ' │line2 long text he│                   ', ' │                  │                   ', ' └──────────────────┘                   ', '                                        ', "'helXY \\nline2 long text he\\n'          ", '                                        ', '                                        '], [], [7, 30], False, 0, 0], [['                                        ', ' ┌──────────────────┐                   ', ' │helXY             │                   ', ' │line2 long text he│                   ', ' │                  │                   ', ' └──────────────────┘                   ', '                                        ', "'helXY \\nline2 long text he\\n'          ", 'name:                                   ', '                                        '], [], [8, 6], False, 0, 0], [['                                        ', ' ┌──────────────────┐                   ', ' │helXY             │                   ', ' │line2 long text he│                   ', ' │                  │                   ', ' └──────────────────┘                   ', '                                        ', "'helXY \\nline2 long text he\\n'          ", 'name: ann                               ', "b'ann'                                  "], [], [9, 6], False, 0, 0], [['                                        ', ' ┌──────────────────┐                   ', ' │helXY             │                   ', ' │line2 long text he│                   ', ' │                  │                   ', ' └──────────────────┘                   ', "'ins '                ins               ", "'helXY \\nline2 long text he\\n'          ", 'name: ann                               ', "b'ann'                                  "], [], [6, 6], False, 0, 0], [['                                        ', ' ┌──────────────────┐                   ', ' │helXY             │                   ', ' │line2 long text he│                   ', ' │                  │                   ', ' └──────────────────┘                   ', "'ins '                ins               ", "'helXY \\nline2 long text he\\n'          ", 'name: ann                               ', "b'ann'                                  "], [], [9, 0], False, 0, 0]], 0],
    'textpad/xterm-256color': [[[['                                        ', ' ┌──────────────────┐                   ', ' │                  │                   ', ' │                  │                   ', ' │                  │                   ', ' └──────────────────┘                   ', '                                        ', '                                        ', '                                        ', '                                        '], [[0, 0, 39, -1, 0, 0], [1, 0, 0, -1, 0, 0], [1, 1, 20, 7, 0, 0], [1, 21, 39, -1, 0, 0], [2, 0, 0, -1, 0, 0], [2, 1, 1, 7, 0, 0], [2, 2, 19, -1, 0, 0], [2, 20, 20, 7, 0, 0], [2, 21, 39, -1, 0, 0], [3, 0, 0, -1, 0, 0], [3, 1, 1, 7, 0, 0], [3, 2, 19, -1, 0, 0], [3, 20, 20, 7, 0, 0], [3, 21, 39, -1, 0, 0], [4, 0, 0, -1, 0, 0], [4, 1, 1, 7, 0, 0], [4, 2, 19, -1, 0, 0], [4, 20, 20, 7, 0, 0], [4, 21, 39, -1, 0, 0], [5, 0, 0, -1, 0, 0], [5, 1, 20, 7, 0, 0], [5, 21, 39, -1, 0, 0], [6, 0, 39, -1, 0, 0], [7, 0, 39, -1, 0, 0], [8, 0, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [5, 2], True, 0, 0], [['                                        ', ' ┌──────────────────┐                   ', ' │helXY             │                   ', ' │line2 long text he│                   ', ' │                  │                   ', ' └──────────────────┘                   ', '                                        ', "'helXY \\nline2 long text he\\n'          ", '                                        ', '                                        '], [[0, 0, 39, -1, 0, 0], [1, 0, 0, -1, 0, 0], [1, 1, 20, 7, 0, 0], [1, 21, 39, -1, 0, 0], [2, 0, 0, -1, 0, 0], [2, 1, 6, 7, 0, 0], [2, 7, 19, -1, 0, 0], [2, 20, 20, 7, 0, 0], [2, 21, 39, -1, 0, 0], [3, 0, 0, -1, 0, 0], [3, 1, 6, 7, 0, 0], [3, 7, 7, -1, 0, 0], [3, 8, 11, 7, 0, 0], [3, 12, 12, -1, 0, 0], [3, 13, 16, 7, 0, 0], [3, 17, 17, -1, 0, 0], [3, 18, 20, 7, 0, 0], [3, 21, 39, -1, 0, 0], [4, 0, 0, -1, 0, 0], [4, 1, 1, 7, 0, 0], [4, 2, 19, -1, 0, 0], [4, 20, 20, 7, 0, 0], [4, 21, 39, -1, 0, 0], [5, 0, 0, -1, 0, 0], [5, 1, 20, 7, 0, 0], [5, 21, 39, -1, 0, 0], [6, 0, 39, -1, 0, 0], [7, 0, 5, 7, 0, 0], [7, 6, 6, -1, 0, 0], [7, 7, 13, 7, 0, 0], [7, 14, 14, -1, 0, 0], [7, 15, 18, 7, 0, 0], [7, 19, 19, -1, 0, 0], [7, 20, 23, 7, 0, 0], [7, 24, 24, -1, 0, 0], [7, 25, 29, 7, 0, 0], [7, 30, 39, -1, 0, 0], [8, 0, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [7, 30], True, 0, 0], [['                                        ', ' ┌──────────────────┐                   ', ' │helXY             │                   ', ' │line2 long text he│                   ', ' │                  │                   ', ' └──────────────────┘                   ', '                                        ', "'helXY \\nline2 long text he\\n'          ", 'name:                                   ', '                                        '], [[0, 0, 39, -1, 0, 0], [1, 0, 0, -1, 0, 0], [1, 1, 20, 7, 0, 0], [1, 21, 39, -1, 0, 0], [2, 0, 0, -1, 0, 0], [2, 1, 6, 7, 0, 0], [2, 7, 19, -1, 0, 0], [2, 20, 20, 7, 0, 0], [2, 21, 39, -1, 0, 0], [3, 0, 0, -1, 0, 0], [3, 1, 6, 7, 0, 0], [3, 7, 7, -1, 0, 0], [3, 8, 11, 7, 0, 0], [3, 12, 12, -1, 0, 0], [3, 13, 16, 7, 0, 0], [3, 17, 17, -1, 0, 0], [3, 18, 20, 7, 0, 0], [3, 21, 39, -1, 0, 0], [4, 0, 0, -1, 0, 0], [4, 1, 1, 7, 0, 0], [4, 2, 19, -1, 0, 0], [4, 20, 20, 7, 0, 0], [4, 21, 39, -1, 0, 0], [5, 0, 0, -1, 0, 0], [5, 1, 20, 7, 0, 0], [5, 21, 39, -1, 0, 0], [6, 0, 39, -1, 0, 0], [7, 0, 5, 7, 0, 0], [7, 6, 6, -1, 0, 0], [7, 7, 13, 7, 0, 0], [7, 14, 14, -1, 0, 0], [7, 15, 18, 7, 0, 0], [7, 19, 19, -1, 0, 0], [7, 20, 23, 7, 0, 0], [7, 24, 24, -1, 0, 0], [7, 25, 29, 7, 0, 0], [7, 30, 39, -1, 0, 0], [8, 0, 4, 7, 0, 0], [8, 5, 39, -1, 0, 0], [9, 0, 39, -1, 0, 0]], [8, 6], True, 0, 0], [['                                        ', ' ┌──────────────────┐                   ', ' │helXY             │                   ', ' │line2 long text he│                   ', ' │                  │                   ', ' └──────────────────┘                   ', '                                        ', "'helXY \\nline2 long text he\\n'          ", 'name: ann                               ', "b'ann'                                  "], [[0, 0, 39, -1, 0, 0], [1, 0, 0, -1, 0, 0], [1, 1, 20, 7, 0, 0], [1, 21, 39, -1, 0, 0], [2, 0, 0, -1, 0, 0], [2, 1, 6, 7, 0, 0], [2, 7, 19, -1, 0, 0], [2, 20, 20, 7, 0, 0], [2, 21, 39, -1, 0, 0], [3, 0, 0, -1, 0, 0], [3, 1, 6, 7, 0, 0], [3, 7, 7, -1, 0, 0], [3, 8, 11, 7, 0, 0], [3, 12, 12, -1, 0, 0], [3, 13, 16, 7, 0, 0], [3, 17, 17, -1, 0, 0], [3, 18, 20, 7, 0, 0], [3, 21, 39, -1, 0, 0], [4, 0, 0, -1, 0, 0], [4, 1, 1, 7, 0, 0], [4, 2, 19, -1, 0, 0], [4, 20, 20, 7, 0, 0], [4, 21, 39, -1, 0, 0], [5, 0, 0, -1, 0, 0], [5, 1, 20, 7, 0, 0], [5, 21, 39, -1, 0, 0], [6, 0, 39, -1, 0, 0], [7, 0, 5, 7, 0, 0], [7, 6, 6, -1, 0, 0], [7, 7, 13, 7, 0, 0], [7, 14, 14, -1, 0, 0], [7, 15, 18, 7, 0, 0], [7, 19, 19, -1, 0, 0], [7, 20, 23, 7, 0, 0], [7, 24, 24, -1, 0, 0], [7, 25, 29, 7, 0, 0], [7, 30, 39, -1, 0, 0], [8, 0, 4, 7, 0, 0], [8, 5, 5, -1, 0, 0], [8, 6, 8, 7, 0, 0], [8, 9, 39, -1, 0, 0], [9, 0, 5, 7, 0, 0], [9, 6, 39, -1, 0, 0]], [9, 6], True, 0, 0], [['                                        ', ' ┌──────────────────┐                   ', ' │helXY             │                   ', ' │line2 long text he│                   ', ' │                  │                   ', ' └──────────────────┘                   ', "'ins '                ins               ", "'helXY \\nline2 long text he\\n'          ", 'name: ann                               ', "b'ann'                                  "], [[0, 0, 39, -1, 0, 0], [1, 0, 0, -1, 0, 0], [1, 1, 20, 7, 0, 0], [1, 21, 39, -1, 0, 0], [2, 0, 0, -1, 0, 0], [2, 1, 6, 7, 0, 0], [2, 7, 19, -1, 0, 0], [2, 20, 20, 7, 0, 0], [2, 21, 39, -1, 0, 0], [3, 0, 0, -1, 0, 0], [3, 1, 6, 7, 0, 0], [3, 7, 7, -1, 0, 0], [3, 8, 11, 7, 0, 0], [3, 12, 12, -1, 0, 0], [3, 13, 16, 7, 0, 0], [3, 17, 17, -1, 0, 0], [3, 18, 20, 7, 0, 0], [3, 21, 39, -1, 0, 0], [4, 0, 0, -1, 0, 0], [4, 1, 1, 7, 0, 0], [4, 2, 19, -1, 0, 0], [4, 20, 20, 7, 0, 0], [4, 21, 39, -1, 0, 0], [5, 0, 0, -1, 0, 0], [5, 1, 20, 7, 0, 0], [5, 21, 39, -1, 0, 0], [6, 0, 3, 7, 0, 0], [6, 4, 4, -1, 0, 0], [6, 5, 5, 7, 0, 0], [6, 6, 21, -1, 0, 0], [6, 22, 24, 7, 0, 0], [6, 25, 39, -1, 0, 0], [7, 0, 5, 7, 0, 0], [7, 6, 6, -1, 0, 0], [7, 7, 13, 7, 0, 0], [7, 14, 14, -1, 0, 0], [7, 15, 18, 7, 0, 0], [7, 19, 19, -1, 0, 0], [7, 20, 23, 7, 0, 0], [7, 24, 24, -1, 0, 0], [7, 25, 29, 7, 0, 0], [7, 30, 39, -1, 0, 0], [8, 0, 4, 7, 0, 0], [8, 5, 5, -1, 0, 0], [8, 6, 8, 7, 0, 0], [8, 9, 39, -1, 0, 0], [9, 0, 5, 7, 0, 0], [9, 6, 39, -1, 0, 0]], [6, 6], True, 0, 0], [['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 0], False, 0, 0]], 0],
    'windows/vt100': [[[['000000000000000000000000000000000000000 ', '111111111111111111111111111111111111111 ', '222┌──────────┐222222222222222222222222 ', '333│newwinsub │333333333333333333333333 ', '444│der       │444444444444444444444444 ', '555└──────────┘555555555555555555555555 ', '666666666666666666666666666666666666666 ', '777777777777777777777777777777777777777 ', '888888888888888888888888888888888888888 ', '999999999999999999999999999999999999999 '], [], [3, 13], False, 0, 0], [['(1, 7) (2, 3) (4, 12) (-1, -1) (1, 7) ( ', 'True False False True False             ', '222┌──────────┐222222222222222222222222 ', '333│newwinsub │333333333333333333333333 ', '444│der       │444444444444444444444444 ', '555└──────────┘55555+----------+5555555 ', '66666666666666666666|newwinsub |6666666 ', '77777777777777777777|der       |7777777 ', '88888888888888888888+----------+8888888 ', '999999999999999999999999999999999999999 '], [], [6, 27], False, 0, 0], [['(1, 7) (2, 3) (4, 12) (-1, -1) (1, 7) ( ', 'True False False True False             ', '2222222222222222222222222222#####       ', '3333333333333333333333333333#bb## AAA  A', '4444444444444444444444444444#####       ', '555555555555555555555555555555555555555 ', '666666666666666666666666666666666666666 ', '777777777777777777777777777777777777777 ', '888888888888888888888888888888888888888 ', '999999999999999999999999999999999999999 '], [], [2, 33], False, 0, 0], [['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', 'erased (1, 8)                           '], [], [9, 13], False, 0, 0], [['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', 'erased (1, 8)                           '], [], [9, 0], False, 0, 0]], 0],
    'windows/xterm-256color': [[[['000000000000000000000000000000000000000 ', '111111111111111111111111111111111111111 ', '222┌──────────┐222222222222222222222222 ', '333│newwinsub │333333333333333333333333 ', '444│der       │444444444444444444444444 ', '555└──────────┘555555555555555555555555 ', '666666666666666666666666666666666666666 ', '777777777777777777777777777777777777777 ', '888888888888888888888888888888888888888 ', '999999999999999999999999999999999999999 '], [[0, 0, 38, 7, 0, 0], [0, 39, 39, -1, 0, 0], [1, 0, 38, 7, 0, 0], [1, 39, 39, -1, 0, 0], [2, 0, 38, 7, 0, 0], [2, 39, 39, -1, 0, 0], [3, 0, 12, 7, 0, 0], [3, 13, 13, -1, 0, 0], [3, 14, 38, 7, 0, 0], [3, 39, 39, -1, 0, 0], [4, 0, 6, 7, 0, 0], [4, 7, 13, -1, 0, 0], [4, 14, 38, 7, 0, 0], [4, 39, 39, -1, 0, 0], [5, 0, 38, 7, 0, 0], [5, 39, 39, -1, 0, 0], [6, 0, 38, 7, 0, 0], [6, 39, 39, -1, 0, 0], [7, 0, 38, 7, 0, 0], [7, 39, 39, -1, 0, 0], [8, 0, 38, 7, 0, 0], [8, 39, 39, -1, 0, 0], [9, 0, 38, 7, 0, 0], [9, 39, 39, -1, 0, 0]], [3, 13], True, 0, 0], [['(1, 7) (2, 3) (4, 12) (-1, -1) (1, 7) ( ', 'True False False True False             ', '222┌──────────┐222222222222222222222222 ', '333│newwinsub │333333333333333333333333 ', '444│der       │444444444444444444444444 ', '555└──────────┘55555+----------+5555555 ', '66666666666666666666|newwinsub |6666666 ', '77777777777777777777|der       |7777777 ', '88888888888888888888+----------+8888888 ', '999999999999999999999999999999999999999 '], [[0, 0, 2, 7, 0, 0], [0, 3, 3, -1, 0, 0], [0, 4, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 9, 7, 0, 0], [0, 10, 10, -1, 0, 0], [0, 11, 12, 7, 0, 0], [0, 13, 13, -1, 0, 0], [0, 14, 16, 7, 0, 0], [0, 17, 17, -1, 0, 0], [0, 18, 20, 7, 0, 0], [0, 21, 21, -1, 0, 0], [0, 22, 25, 7, 0, 0], [0, 26, 26, -1, 0, 0], [0, 27, 29, 7, 0, 0], [0, 30, 30, -1, 0, 0], [0, 31, 33, 7, 0, 0], [0, 34, 34, -1, 0, 0], [0, 35, 36, 7, 0, 0], [0, 37, 37, -1, 0, 0], [0, 38, 38, 7, 0, 0], [0, 39, 39, -1, 0, 0], [1, 0, 3, 7, 0, 0], [1, 4, 4, -1, 0, 0], [1, 5, 9, 7, 0, 0], [1, 10, 10, -1, 0, 0], [1, 11, 15, 7, 0, 0], [1, 16, 16, -1, 0, 0], [1, 17, 20, 7, 0, 0], [1, 21, 21, -1, 0, 0], [1, 22, 26, 7, 0, 0], [1, 27, 39, -1, 0, 0], [2, 0, 38, 7, 0, 0], [2, 39, 39, -1, 0, 0], [3, 0, 12, 7, 0, 0], [3, 13, 13, -1, 0, 0], [3, 14, 38, 7, 0, 0], [3, 39, 39, -1, 0, 0], [4, 0, 6, 7, 0, 0], [4, 7, 13, -1, 0, 0], [4, 14, 38, 7, 0, 0], [4, 39, 39, -1, 0, 0], [5, 0, 38, 7, 0, 0], [5, 39, 39, -1, 0, 0], [6, 0, 29, 7, 0, 0], [6, 30, 30, -1, 0, 0], [6, 31, 38, 7, 0, 0], [6, 39, 39, -1, 0, 0], [7, 0, 23, 7, 0, 0], [7, 24, 30, -1, 0, 0], [7, 31, 38, 7, 0, 0], [7, 39, 39, -1, 0, 0], [8, 0, 38, 7, 0, 0], [8, 39, 39, -1, 0, 0], [9, 0, 38, 7, 0, 0], [9, 39, 39, -1, 0, 0]], [6, 27], True, 0, 0], [['(1, 7) (2, 3) (4, 12) (-1, -1) (1, 7) ( ', 'True False False True False             ', '2222222222222222222222222222#####       ', '3333333333333333333333333333#bb## AAA  A', '4444444444444444444444444444#####       ', '555555555555555555555555555555555555555 ', '666666666666666666666666666666666666666 ', '777777777777777777777777777777777777777 ', '888888888888888888888888888888888888888 ', '999999999999999999999999999999999999999 '], [[0, 0, 2, 7, 0, 0], [0, 3, 3, -1, 0, 0], [0, 4, 5, 7, 0, 0], [0, 6, 6, -1, 0, 0], [0, 7, 9, 7, 0, 0], [0, 10, 10, -1, 0, 0], [0, 11, 12, 7, 0, 0], [0, 13, 13, -1, 0, 0], [0, 14, 16, 7, 0, 0], [0, 17, 17, -1, 0, 0], [0, 18, 20, 7, 0, 0], [0, 21, 21, -1, 0, 0], [0, 22, 25, 7, 0, 0], [0, 26, 26, -1, 0, 0], [0, 27, 29, 7, 0, 0], [0, 30, 30, -1, 0, 0], [0, 31, 33, 7, 0, 0], [0, 34, 34, -1, 0, 0], [0, 35, 36, 7, 0, 0], [0, 37, 37, -1, 0, 0], [0, 38, 38, 7, 0, 0], [0, 39, 39, -1, 0, 0], [1, 0, 3, 7, 0, 0], [1, 4, 4, -1, 0, 0], [1, 5, 9, 7, 0, 0], [1, 10, 10, -1, 0, 0], [1, 11, 15, 7, 0, 0], [1, 16, 16, -1, 0, 0], [1, 17, 20, 7, 0, 0], [1, 21, 21, -1, 0, 0], [1, 22, 26, 7, 0, 0], [1, 27, 39, -1, 0, 0], [2, 0, 32, 7, 0, 0], [2, 33, 39, -1, 0, 0], [3, 0, 32, 7, 0, 0], [3, 33, 33, -1, 0, 0], [3, 34, 36, 7, 0, 0], [3, 37, 38, -1, 0, 0], [3, 39, 39, 7, 0, 0], [4, 0, 32, 7, 0, 0], [4, 33, 39, -1, 0, 0], [5, 0, 38, 7, 0, 0], [5, 39, 39, -1, 0, 0], [6, 0, 38, 7, 0, 0], [6, 39, 39, -1, 0, 0], [7, 0, 38, 7, 0, 0], [7, 39, 39, -1, 0, 0], [8, 0, 38, 7, 0, 0], [8, 39, 39, -1, 0, 0], [9, 0, 38, 7, 0, 0], [9, 39, 39, -1, 0, 0]], [2, 33], True, 0, 0], [['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', 'erased (1, 8)                           '], [[0, 0, 39, -1, 0, 0], [1, 0, 39, -1, 0, 0], [2, 0, 39, -1, 0, 0], [3, 0, 39, -1, 0, 0], [4, 0, 39, -1, 0, 0], [5, 0, 39, -1, 0, 0], [6, 0, 39, -1, 0, 0], [7, 0, 39, -1, 0, 0], [8, 0, 39, -1, 0, 0], [9, 0, 5, 7, 0, 0], [9, 6, 6, -1, 0, 0], [9, 7, 9, 7, 0, 0], [9, 10, 10, -1, 0, 0], [9, 11, 12, 7, 0, 0], [9, 13, 39, -1, 0, 0]], None, True, 0, 0], [['                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        ', '                                        '], [], [0, 0], False, 0, 0]], 0],
}
# --- end expected ---

CPY = find_cpython()

def run_programs():
    # each program on each terminal, against CPython
    global skip_n
    if RECORD:
        rec = {}
        for name in PROGRAMS:
            if name == "workload":
                continue
            rows, cols, keys, src = PROGRAMS[name]
            for tn in TERMS:
                if name + "/" + tn in SKIP:
                    continue
                scr, st, cnt = drive([sys.executable, prog_path(name)], tn, rows, cols, keys)
                rec[name + "/" + tn] = [scr, st]
        print("EXPECTED = {")
        for k in sorted(rec):
            print("    %r: %r," % (k, rec[k]))
        print("}")
        sys.exit(0)

    ran_programs = False
    if HAVE_PTY and HAVE_DB:
        ran_programs = True
        totals = [0, 0]
        for name in PROGRAMS:
            if name == "workload":
                continue
            rows, cols, keys, src = PROGRAMS[name]
            for tn in TERMS:
                key = name + "/" + tn
                if key in SKIP:
                    continue
                t0 = time.time()
                mine, st, cnt = drive(runtime_argv() + [prog_path(name)], tn, rows, cols, keys)
                if os.environ.get("NY115_DEBUG"):
                    print("ran", key, round(time.time() - t0, 2), "s,", len(mine), "screens, status", st)
                    for scr_ in mine:
                        print("   ", scr_[2], scr_[3])
                        for row_ in scr_[0]:
                            print("    |" + row_ + "|")
                if CPY is not None:
                    ref, rst, rcnt = drive([CPY, prog_path(name)], tn, rows, cols, keys)
                    origin = "CPython"
                    if not RECORD and nython:
                        totals[0] += cnt[-1]
                        totals[1] += rcnt[-1]
                elif key in EXPECTED:
                    ref, rst = EXPECTED[key]
                    origin = "recorded"
                else:
                    ref = None
                if ref is None:
                    skip_n += 1
                    continue
                check(key + ": steps", len(mine), len(ref))
                for i in range(min(len(mine), len(ref))):
                    check(key + " step %d (%s): text" % (i, origin), mine[i][0], ref[i][0])
                    check(key + " step %d (%s): colors and attributes" % (i, origin), mine[i][1], ref[i][1])
                    check(key + " step %d (%s): cursor" % (i, origin), [mine[i][2], mine[i][3]], [ref[i][2], ref[i][3]])
                    check(key + " step %d (%s): bells and flashes" % (i, origin), mine[i][4:], ref[i][4:])
                check(key + ": exit status", st, 0)
        if totals[1]:
            print("bytes: the programs above, %d written by Nython's curses / %d by ncurses" % (totals[0], totals[1]))
    else:
        skip_n += 1


run_programs()


# ═══════════════════════════════════════════════════════════════════════════
# 4. terminfo entries: both readers against infocmp
# ═══════════════════════════════════════════════════════════════════════════
DUMP = """import curses, sys
curses.setupterm(sys.argv[1], 1)
out = []
for line in open(sys.argv[2]):
    n = line.strip()
    if n:
        out.append((n, curses.tigetflag(n), curses.tigetnum(n), curses.tigetstr(n)))
print(repr(out))
"""


def infocmp(name, env_extra=None):
    # infocmp -1 -x: the capability names and values of an entry
    text = run(["infocmp", "-1", "-x", name], env_extra)[0]
    caps = {}
    for line in text.split("\n"):
        if not line.startswith("\t"):
            continue
        line = line.strip()
        if not line.endswith(","):
            continue
        line = line[:-1]
        if "=" in line:
            k, v = line.split("=", 1)
            caps[k] = ("s", unescape(v))
        elif "#" in line and not line.startswith("#"):
            k, v = line.split("#", 1)
            caps[k] = ("n", int(v, 0))
        elif line.endswith("@"):
            caps[line[:-1]] = ("c", None)
        else:
            caps[line] = ("b", 1)
    return caps


def unescape(v):
    # terminfo(5) escapes as infocmp writes them
    out = []
    i = 0
    while i < len(v):
        c = v[i]
        if c == "\\" and i + 1 < len(v):
            d = v[i + 1]
            i += 2
            m = {"E": 27, "e": 27, "n": 10, "l": 10, "r": 13, "t": 9, "b": 8, "f": 12, "s": 32, "^": 94, "\\": 92,
                 ",": 44, ":": 58, "0": 128}
            if d in "01234567" and i + 1 < len(v) and v[i] in "01234567":
                n = int(v[i - 1:i + 2], 8)
                out.append(n if n else 128)
                i += 2
            elif d in m:
                out.append(m[d])
            else:
                out.append(ord(d))
        elif c == "^" and i + 1 < len(v):
            d = v[i + 1]
            out.append(127 if d == "?" else ord(d) & 0x1f)
            i += 2
        else:
            out.append(ord(c))
            i += 1
    return bytes(out)


HAVE_INFOCMP = POSIX and run(["infocmp", "-V"])[1] == 0


def dump_with(argv, termname, names, env_extra=None):
    d = tmpdir()
    script = os.path.join(d, "dump.py")
    if not os.path.exists(script):
        f = open(script, "w")
        f.write(DUMP)
        f.close()
    lst = os.path.join(d, "names_%s.txt" % termname)
    f = open(lst, "w")
    f.write("\n".join(names) + "\n")
    f.close()
    text = run(argv + [script, termname, lst], env_extra)[0].strip()
    try:
        return eval(text)
    except Exception:
        return text


ENTRIES = ["xterm-256color", "xterm", "vt100", "vt220", "linux", "screen-256color", "tmux-256color",
           "rxvt-unicode-256color", "ansi", "dumb", "xterm-mono", "Eterm-color"]
def terminfo_entries():
    # the container's entries
    global skip_n
    if HAVE_INFOCMP and POSIX:
        for name in ENTRIES:
            caps = infocmp(name)
            if not caps:
                continue
            # infocmp shows acsc sorted, not as the entry holds it
            if "acsc" in caps:
                del caps["acsc"]
            names = sorted(caps) + ["cup", "colors", "am", "nosuchcap"]
            mine = dump_with(runtime_argv(), name, names)
            want = []
            for n in names:
                kind, v = caps.get(n, ("x", None))
                # tigetflag: 1 / 0 (absent, cancelled) / -1 (not a flag); tigetnum: value / -1 / -2; tigetstr: bytes / None
                want.append((n, None, None, v if kind == "s" else None))
            got_s = [(r[0], None, None, r[3]) for r in mine] if isinstance(mine, list) else mine
            check("terminfo %s: strings as infocmp shows them" % name, got_s, want)
            if isinstance(mine, list):
                nums = [(r[0], r[2]) for r in mine if caps.get(r[0], ("x",))[0] == "n"]
                check("terminfo %s: numbers as infocmp shows them" % name, nums, [(n, caps[n][1]) for n in names if caps.get(n, ("x",))[0] == "n"])
                flags = [r[0] for r in mine if r[1] == 1]
                check("terminfo %s: flags as infocmp shows them" % name, sorted(flags), sorted(n for n in names if caps.get(n, ("x",))[0] == "b"))
            if CPY is not None:
                ref = dump_with([CPY], name, names)
                check("terminfo %s: the same as CPython's (every flag, number, string)" % name, mine, ref)
    else:
        skip_n += 1


terminfo_entries()


# compiled entries of our own: the 32-bit number format, extended
# capabilities, cancellations, the search path
HAVE_TIC = POSIX and run(["tic", "-V"])[1] == 0
SRC = """nyterm|Nython test terminal,
\tam, xenl, bce, XT, Zz,
\tcols#100, lines#40, colors#0x1000000, pairs#0x10000, U8#1, Yn#70000,
\tbel=^G, cr=\\r, clear=\\E[H\\E[2J, cup=\\E[%i%p1%d;%p2%dH, el=\\E[K,
\tsetaf=\\E[38;2;%p1%{65536}%/%d;%p1%{256}%/%{255}%&%d;%p1%{255}%&%dm,
\tkcuu1=\\EOA, kUP5=\\E[1;5A, Ms=\\E]52;%p1%s;%p2%s\\007, xm=\\E[<%p1%d;%p2%dM,
"""
SRC16 = """nyold|Nython 16-bit test terminal,
\tam, cols#80, lines#24, colors#8, it#8,
\tcup=\\E[%i%p1%d;%p2%dH, el=\\E[K, kcuu1=\\EOA, smul@,
"""
def terminfo_tic():
    # entries compiled here
    global skip_n
    if HAVE_TIC and HAVE_PTY:
        d = tmpdir()
        db = os.path.join(d, "ti")
        if not os.path.isdir(db):
            os.mkdir(db)
        for i, s in enumerate((SRC, SRC16)):
            p = os.path.join(d, "ent%d.src" % i)
            f = open(p, "w")
            f.write(s)
            f.close()
            run(["tic", "-x", "-o", db, p])
        env = {"TERMINFO": db}
        for name, fmt in (("nyterm", b"\x1e\x02"), ("nyold", b"\x1a\x01")):
            path = os.path.join(db, name[0], name)
            if not os.path.exists(path):
                continue
            f = open(path, "rb")
            magic = f.read(2)
            f.close()
            check("tic %s: the format written" % name, magic, fmt)
            caps = infocmp(name, env)
            names = sorted(caps) + ["smul", "nosuch"]
            mine = dump_with(runtime_argv(), name, names, env)
            want = []
            for n in names:
                kind, v = caps.get(n, ("x", None))
                want.append([n, kind, v])
            got = []
            for r in (mine if isinstance(mine, list) else []):
                kind, v = caps.get(r[0], ("x", None))
                if kind == "s":
                    got.append([r[0], kind, r[3]])
                elif kind == "n":
                    got.append([r[0], kind, r[2]])
                elif kind == "b":
                    got.append([r[0], kind, r[1]])
                else:
                    got.append([r[0], kind, None])
            check("tic %s: every capability as infocmp shows it" % name, got, want)
            if CPY is not None:
                check("tic %s: the same as CPython's" % name, mine, dump_with([CPY], name, names, env))
            if name == "nyterm":
                check("tic nyterm: 32-bit numbers and extended ones",
                      [r[2] for r in mine if r[0] in ("colors", "Yn", "U8")] if isinstance(mine, list) else mine, [1, 70000, 16777216])
                check("tic nyterm: a parameterized %s capability", [r[3] for r in mine if r[0] == "Ms"] if isinstance(mine, list) else mine,
                      [b"\x1b]52;%p1%s;%p2%s\x07"])
        if nython and os.path.exists(os.path.join(db, "n", "nyterm")):
            # the hexadecimal layout (6e/nyterm), TERMINFO_DIRS with an empty
            # element (the system's directories), the built-in entries
            hx = os.path.join(d, "tihex")
            if not os.path.isdir(hx):
                os.mkdir(hx)
                os.mkdir(os.path.join(hx, "6e"))
                f = open(os.path.join(db, "n", "nyterm"), "rb")
                data = f.read()
                f.close()
                f = open(os.path.join(hx, "6e", "nyterm"), "wb")
                f.write(data)
                f.close()
            base = dump_with(runtime_argv(), "nyterm", ["cols", "colors", "kUP5", "Zz"], {"TERMINFO": db})
            check("terminfo: the hexadecimal directory layout", dump_with(runtime_argv(), "nyterm", ["cols", "colors", "kUP5", "Zz"], {"TERMINFO": hx}), base)
            check("terminfo: TERMINFO_DIRS", dump_with(runtime_argv(), "nyterm", ["cols", "colors", "kUP5", "Zz"], {"TERMINFO_DIRS": "/nonexistent:" + hx}), base)
            sysx = dump_with(runtime_argv(), "xterm-256color", ["cup", "colors", "kUP5"], {"TERMINFO_DIRS": hx + ":"})
            check("terminfo: an empty TERMINFO_DIRS element is the system's", sysx[0][3] if isinstance(sysx, list) else sysx, b"\x1b[%i%p1%d;%p2%dH")
            missing = dump_with(runtime_argv(), "nosuchterm", ["cup"])
            check("terminfo: an unknown terminal", "could not find terminal" in str(missing), True)
    else:
        skip_n += 1


terminfo_tic()


def terminfo_builtin():
    # the built-in entries
    global skip_n
    if nython and HAVE_INFOCMP:
        for name in ("xterm-256color", "vt100"):
            caps = infocmp(name)
            names = sorted(caps)
            db_rows = dump_with(runtime_argv(), name, names)
            bi_rows = dump_with(runtime_argv(), name, names, {"NY_TERMINFO_BUILTIN": "1", "TERMINFO_DIRS": "/nonexistent"})
            check("terminfo: the built-in %s is the database's" % name, bi_rows, db_rows)


terminfo_builtin()


# ═══════════════════════════════════════════════════════════════════════════
# 5. what doupdate writes (Nython only): scrolling and partial updates
# ═══════════════════════════════════════════════════════════════════════════
def workload():
    # the bytes of each update mode
    global skip_n
    if nython and HAVE_PTY and HAVE_DB:
        rows, cols, keys, src = PROGRAMS["workload"]
        modes = {}
        for mode in ("optimize", "noscroll", "naive"):
            scr, st, cnt = drive(runtime_argv() + [prog_path("workload")], "xterm-256color", rows, cols, keys, {"NY_CURSES_UPDATE": mode})
            modes[mode] = [scr, cnt]
        ref = None
        if CPY is not None:
            ref = drive([CPY, prog_path("workload")], "xterm-256color", rows, cols, keys)
        opt = modes["optimize"][1]
        nos = modes["noscroll"][1]
        nai = modes["naive"][1]
        sc = [opt[1] - opt[0], nos[1] - nos[0], nai[1] - nai[0]]
        pu = [opt[2] - opt[1], nos[2] - nos[1], nai[2] - nai[1]]
        line = "bytes: scrolling %d optimized / %d without scroll detection / %d naive repaint" % (sc[0], sc[1], sc[2])
        line2 = "bytes: partial updates %d optimized / %d naive repaint" % (pu[0], pu[2])
        if ref is not None:
            rc = ref[2]
            line = line + " / %d ncurses" % (rc[1] - rc[0])
            line2 = line2 + " / %d ncurses" % (rc[2] - rc[1])
            check("workload: the optimized screens are CPython's", modes["optimize"][0], ref[0])
        print(line)
        print(line2)
        check("workload: every mode draws the same screens", [modes["noscroll"][0] == modes["optimize"][0], modes["naive"][0] == modes["optimize"][0]], [True, True])
        check("workload: scroll detection pays (under a fifth of the naive repaint, under half of no detection)",
              [sc[0] * 5 < sc[2], sc[0] * 2 < sc[1]], [True, True])
        check("workload: partial updates send only what changed (under a fifth)", pu[0] * 5 < pu[2], True)
        if ref is not None:
            rc = ref[2]
            check("workload: no more bytes than ncurses (+10%)", [sc[0] * 10 <= (rc[1] - rc[0]) * 11, pu[0] * 10 <= (rc[2] - rc[1]) * 11], [True, True])


workload()


def cleanup():
    # the temporary files
    global skip_n
    if TMP is not None:
        for f in os.listdir(TMP):
            p = os.path.join(TMP, f)
            if os.path.isdir(p):
                for g in os.listdir(p):
                    q = os.path.join(p, g)
                    if os.path.isdir(q):
                        for h in os.listdir(q):
                            os.remove(os.path.join(q, h))
                        os.rmdir(q)
                    else:
                        os.remove(q)
                os.rmdir(p)
            else:
                os.remove(p)
        os.rmdir(TMP)


cleanup()


for res_ in results:
    if res_[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + res_[0] + ": got " + repr(res_[2]) + " want " + repr(res_[3]))
if skip_n:
    print("(%d groups skipped: no pty, terminfo database, infocmp or tic here)" % skip_n)
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT115 PASSED ===")
