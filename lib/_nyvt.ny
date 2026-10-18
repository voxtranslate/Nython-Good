# nython: module    (import it by name: it runs in a module scope of its own)
# lib/_nyvt.ny - a VT100/xterm terminal emulator (round 84).
#
# Usable on its own: feed it what a program writes to a terminal and read
# back the screen as cells (character, foreground, background, attributes),
# the cursor, the modes and the title - the way a test asserts on what the
# user would see rather than on raw bytes. The curses tests (vm_audit115)
# run curses programs, Nython's and CPython's, under a pseudo-terminal and
# compare the screens this emulator builds from their output.
#
#     import _nyvt
#     t = _nyvt.Terminal(24, 80)
#     t.feed(b"\x1b[1;31mred\x1b[m")
#     t.display()[0]          -> "red" + 77 spaces
#     t.cell(0, 0).fg, t.cell(0, 0).bold   -> 1, True
#     t.cursor()              -> (0, 3)
#     t.key("up")             -> b"\x1b[A" (b"\x1bOA" once the program asked
#                                for application cursor keys)
#
# The file is written in the subset of the language CPython also runs, so
# python3 can load it with importlib (SourceFileLoader) and drive the same
# programs through the same emulator.
#
# The parser is Paul Williams' state machine for DEC's ANSI-compatible video
# terminals ("A parser for DEC's ANSI-compatible video terminals",
# vt100.net/emu/dec_ansi_parser): ground, escape, escape intermediate, CSI
# entry/param/intermediate/ignore, DCS entry/param/intermediate/passthrough/
# ignore, OSC string and SOS/PM/APC string, with C0 controls executed inside
# sequences and CAN/SUB/ESC cancelling them. Input is UTF-8 (decoded across
# feed() boundaries); C1 controls given as code points U+0080-U+009F work too.
#
# What the screen does (xterm's behaviour, which ncurses' xterm and vt100
# descriptions rely on):
#   - printing with autowrap and the VT100 "pending wrap" at the right margin
#     (xenl), insert mode (IRM), wide characters taking two cells (widths are
#     glibc's wcwidth, the table curses uses too), combining characters
#     joining the previous cell, a wide character that cannot fit wrapping
#     first, and half of a wide character being erased when the other half is
#     overwritten;
#   - G0/G1 designation (ESC ( 0, ESC ) 0, B, A) with SI/SO, DEC Special
#     Graphics as Unicode line drawing;
#   - CUU CUD CUF CUB CNL CPL CHA HPA HPR VPA VPR CUP HVP CHT CBT, IND RI NEL
#     HTS TBC, DECSTBM scrolling regions and DECOM, IL DL ICH DCH ECH REP,
#     ED EL (and SU/SD), back-color erase (erased cells take the background),
#     DECSC/DECRC and CSI s/u, DECSTR, RIS, DECALN;
#   - SGR: bold, dim, italic, underline (also 4:n and 21), blink, reverse,
#     invisible, strike-through and their resets; 8/16 colors, 256 colors
#     and direct colors (38;5;n, 38;2;r;g;b, with ';' or ':');
#   - modes: IRM, LNM, DECCKM, DECKPAM/DECKPNM, DECAWM, DECTCEM, DECSCNM
#     (counted as flashes), DECOM, the alternate screen (47, 1047, 1048,
#     1049), mouse reporting (9, 1000, 1002, 1003, 1005, 1006, 1015),
#     bracketed paste (2004), focus events (1004);
#   - replies (DA, DA2, DSR 5/6 and DECXCPR) collected in `responses` for
#     the caller to send back; OSC 0/1/2 titles, OSC 4/104 palette changes,
#     every OSC string kept in `osc` (tests use it to synchronise with a
#     program); BEL counted.
#
# Cells are tuples (char, fg, bg, flags): fg/bg are -1 for the default
# color, 0-255 for a palette index, 0x1000000 | 0xRRGGBB for a direct color;
# flags are the BOLD ... STRIKE bits below. The second cell of a wide
# character holds "".
#
# Not here: scrollback, DECLRMM left/right margins, double-width/height
# lines, the VT52 mode, sixel and ReGIS, 8-bit C1 controls as raw bytes
# (they are not UTF-8), DECRQSS and the other DCS requests, rectangular area
# operations (DECCRA, DECFRA...), xterm's window operations (CSI t is read
# and ignored), the title stack.

BOLD = 1
DIM = 2
ITALIC = 4
UNDERLINE = 8
BLINK = 16
REVERSE = 32
INVISIBLE = 64
STRIKE = 128

_ATTR_NAMES = [("bold", BOLD), ("dim", DIM), ("italic", ITALIC), ("underline", UNDERLINE),
               ("blink", BLINK), ("reverse", REVERSE), ("invisible", INVISIBLE), ("strike", STRIKE)]

# DEC Special Graphics, 0x5f-0x7e (what xterm shows after ESC ( 0)
_DEC = [" ", "◆", "▒", "␉", "␌", "␍", "␊", "°", "±",
        "␤", "␋", "┘", "┐", "┌", "└", "┼", "⎺", "⎻",
        "─", "⎼", "⎽", "├", "┤", "┴", "┬", "│", "≤",
        "≥", "π", "≠", "£", "·"]

# --- widths (generated) ---
_ZERO = [
    0x0, 0x0, 0x300, 0x36f, 0x483, 0x489, 0x591, 0x5bd, 0x5bf, 0x5bf, 0x5c1, 0x5c2,
    0x5c4, 0x5c5, 0x5c7, 0x5c7, 0x610, 0x61a, 0x61c, 0x61c, 0x64b, 0x65f, 0x670, 0x670,
    0x6d6, 0x6dc, 0x6df, 0x6e4, 0x6e7, 0x6e8, 0x6ea, 0x6ed, 0x711, 0x711, 0x730, 0x74a,
    0x7a6, 0x7b0, 0x7eb, 0x7f3, 0x7fd, 0x7fd, 0x816, 0x819, 0x81b, 0x823, 0x825, 0x827,
    0x829, 0x82d, 0x859, 0x85b, 0x898, 0x89f, 0x8ca, 0x8e1, 0x8e3, 0x902, 0x93a, 0x93a,
    0x93c, 0x93c, 0x941, 0x948, 0x94d, 0x94d, 0x951, 0x957, 0x962, 0x963, 0x981, 0x981,
    0x9bc, 0x9bc, 0x9c1, 0x9c4, 0x9cd, 0x9cd, 0x9e2, 0x9e3, 0x9fe, 0x9fe, 0xa01, 0xa02,
    0xa3c, 0xa3c, 0xa41, 0xa42, 0xa47, 0xa48, 0xa4b, 0xa4d, 0xa51, 0xa51, 0xa70, 0xa71,
    0xa75, 0xa75, 0xa81, 0xa82, 0xabc, 0xabc, 0xac1, 0xac5, 0xac7, 0xac8, 0xacd, 0xacd,
    0xae2, 0xae3, 0xafa, 0xaff, 0xb01, 0xb01, 0xb3c, 0xb3c, 0xb3f, 0xb3f, 0xb41, 0xb44,
    0xb4d, 0xb4d, 0xb55, 0xb56, 0xb62, 0xb63, 0xb82, 0xb82, 0xbc0, 0xbc0, 0xbcd, 0xbcd,
    0xc00, 0xc00, 0xc04, 0xc04, 0xc3c, 0xc3c, 0xc3e, 0xc40, 0xc46, 0xc48, 0xc4a, 0xc4d,
    0xc55, 0xc56, 0xc62, 0xc63, 0xc81, 0xc81, 0xcbc, 0xcbc, 0xcbf, 0xcbf, 0xcc6, 0xcc6,
    0xccc, 0xccd, 0xce2, 0xce3, 0xd00, 0xd01, 0xd3b, 0xd3c, 0xd41, 0xd44, 0xd4d, 0xd4d,
    0xd62, 0xd63, 0xd81, 0xd81, 0xdca, 0xdca, 0xdd2, 0xdd4, 0xdd6, 0xdd6, 0xe31, 0xe31,
    0xe34, 0xe3a, 0xe47, 0xe4e, 0xeb1, 0xeb1, 0xeb4, 0xebc, 0xec8, 0xece, 0xf18, 0xf19,
    0xf35, 0xf35, 0xf37, 0xf37, 0xf39, 0xf39, 0xf71, 0xf7e, 0xf80, 0xf84, 0xf86, 0xf87,
    0xf8d, 0xf97, 0xf99, 0xfbc, 0xfc6, 0xfc6, 0x102d, 0x1030, 0x1032, 0x1037, 0x1039, 0x103a,
    0x103d, 0x103e, 0x1058, 0x1059, 0x105e, 0x1060, 0x1071, 0x1074, 0x1082, 0x1082, 0x1085, 0x1086,
    0x108d, 0x108d, 0x109d, 0x109d, 0x1160, 0x11ff, 0x135d, 0x135f, 0x1712, 0x1714, 0x1732, 0x1733,
    0x1752, 0x1753, 0x1772, 0x1773, 0x17b4, 0x17b5, 0x17b7, 0x17bd, 0x17c6, 0x17c6, 0x17c9, 0x17d3,
    0x17dd, 0x17dd, 0x180b, 0x180f, 0x1885, 0x1886, 0x18a9, 0x18a9, 0x1920, 0x1922, 0x1927, 0x1928,
    0x1932, 0x1932, 0x1939, 0x193b, 0x1a17, 0x1a18, 0x1a1b, 0x1a1b, 0x1a56, 0x1a56, 0x1a58, 0x1a5e,
    0x1a60, 0x1a60, 0x1a62, 0x1a62, 0x1a65, 0x1a6c, 0x1a73, 0x1a7c, 0x1a7f, 0x1a7f, 0x1ab0, 0x1ace,
    0x1b00, 0x1b03, 0x1b34, 0x1b34, 0x1b36, 0x1b3a, 0x1b3c, 0x1b3c, 0x1b42, 0x1b42, 0x1b6b, 0x1b73,
    0x1b80, 0x1b81, 0x1ba2, 0x1ba5, 0x1ba8, 0x1ba9, 0x1bab, 0x1bad, 0x1be6, 0x1be6, 0x1be8, 0x1be9,
    0x1bed, 0x1bed, 0x1bef, 0x1bf1, 0x1c2c, 0x1c33, 0x1c36, 0x1c37, 0x1cd0, 0x1cd2, 0x1cd4, 0x1ce0,
    0x1ce2, 0x1ce8, 0x1ced, 0x1ced, 0x1cf4, 0x1cf4, 0x1cf8, 0x1cf9, 0x1dc0, 0x1dff, 0x200b, 0x200f,
    0x202a, 0x202e, 0x2060, 0x2064, 0x2066, 0x206f, 0x20d0, 0x20f0, 0x2cef, 0x2cf1, 0x2d7f, 0x2d7f,
    0x2de0, 0x2dff, 0x302a, 0x302d, 0x3099, 0x309a, 0xa66f, 0xa672, 0xa674, 0xa67d, 0xa69e, 0xa69f,
    0xa6f0, 0xa6f1, 0xa802, 0xa802, 0xa806, 0xa806, 0xa80b, 0xa80b, 0xa825, 0xa826, 0xa82c, 0xa82c,
    0xa8c4, 0xa8c5, 0xa8e0, 0xa8f1, 0xa8ff, 0xa8ff, 0xa926, 0xa92d, 0xa947, 0xa951, 0xa980, 0xa982,
    0xa9b3, 0xa9b3, 0xa9b6, 0xa9b9, 0xa9bc, 0xa9bd, 0xa9e5, 0xa9e5, 0xaa29, 0xaa2e, 0xaa31, 0xaa32,
    0xaa35, 0xaa36, 0xaa43, 0xaa43, 0xaa4c, 0xaa4c, 0xaa7c, 0xaa7c, 0xaab0, 0xaab0, 0xaab2, 0xaab4,
    0xaab7, 0xaab8, 0xaabe, 0xaabf, 0xaac1, 0xaac1, 0xaaec, 0xaaed, 0xaaf6, 0xaaf6, 0xabe5, 0xabe5,
    0xabe8, 0xabe8, 0xabed, 0xabed, 0xd7b0, 0xd7c6, 0xd7cb, 0xd7fb, 0xfb1e, 0xfb1e, 0xfe00, 0xfe0f,
    0xfe20, 0xfe2f, 0xfeff, 0xfeff, 0xfff9, 0xfffb, 0x101fd, 0x101fd, 0x102e0, 0x102e0, 0x10376, 0x1037a,
    0x10a01, 0x10a03, 0x10a05, 0x10a06, 0x10a0c, 0x10a0f, 0x10a38, 0x10a3a, 0x10a3f, 0x10a3f, 0x10ae5, 0x10ae6,
    0x10d24, 0x10d27, 0x10eab, 0x10eac, 0x10efd, 0x10eff, 0x10f46, 0x10f50, 0x10f82, 0x10f85, 0x11001, 0x11001,
    0x11038, 0x11046, 0x11070, 0x11070, 0x11073, 0x11074, 0x1107f, 0x11081, 0x110b3, 0x110b6, 0x110b9, 0x110ba,
    0x110c2, 0x110c2, 0x11100, 0x11102, 0x11127, 0x1112b, 0x1112d, 0x11134, 0x11173, 0x11173, 0x11180, 0x11181,
    0x111b6, 0x111be, 0x111c9, 0x111cc, 0x111cf, 0x111cf, 0x1122f, 0x11231, 0x11234, 0x11234, 0x11236, 0x11237,
    0x1123e, 0x1123e, 0x11241, 0x11241, 0x112df, 0x112df, 0x112e3, 0x112ea, 0x11300, 0x11301, 0x1133b, 0x1133c,
    0x11340, 0x11340, 0x11366, 0x1136c, 0x11370, 0x11374, 0x11438, 0x1143f, 0x11442, 0x11444, 0x11446, 0x11446,
    0x1145e, 0x1145e, 0x114b3, 0x114b8, 0x114ba, 0x114ba, 0x114bf, 0x114c0, 0x114c2, 0x114c3, 0x115b2, 0x115b5,
    0x115bc, 0x115bd, 0x115bf, 0x115c0, 0x115dc, 0x115dd, 0x11633, 0x1163a, 0x1163d, 0x1163d, 0x1163f, 0x11640,
    0x116ab, 0x116ab, 0x116ad, 0x116ad, 0x116b0, 0x116b5, 0x116b7, 0x116b7, 0x1171d, 0x1171f, 0x11722, 0x11725,
    0x11727, 0x1172b, 0x1182f, 0x11837, 0x11839, 0x1183a, 0x1193b, 0x1193c, 0x1193e, 0x1193e, 0x11943, 0x11943,
    0x119d4, 0x119d7, 0x119da, 0x119db, 0x119e0, 0x119e0, 0x11a01, 0x11a0a, 0x11a33, 0x11a38, 0x11a3b, 0x11a3e,
    0x11a47, 0x11a47, 0x11a51, 0x11a56, 0x11a59, 0x11a5b, 0x11a8a, 0x11a96, 0x11a98, 0x11a99, 0x11c30, 0x11c36,
    0x11c38, 0x11c3d, 0x11c3f, 0x11c3f, 0x11c92, 0x11ca7, 0x11caa, 0x11cb0, 0x11cb2, 0x11cb3, 0x11cb5, 0x11cb6,
    0x11d31, 0x11d36, 0x11d3a, 0x11d3a, 0x11d3c, 0x11d3d, 0x11d3f, 0x11d45, 0x11d47, 0x11d47, 0x11d90, 0x11d91,
    0x11d95, 0x11d95, 0x11d97, 0x11d97, 0x11ef3, 0x11ef4, 0x11f00, 0x11f01, 0x11f36, 0x11f3a, 0x11f40, 0x11f40,
    0x11f42, 0x11f42, 0x13430, 0x13440, 0x13447, 0x13455, 0x16af0, 0x16af4, 0x16b30, 0x16b36, 0x16f4f, 0x16f4f,
    0x16f8f, 0x16f92, 0x16fe4, 0x16fe4, 0x1bc9d, 0x1bc9e, 0x1bca0, 0x1bca3, 0x1cf00, 0x1cf2d, 0x1cf30, 0x1cf46,
    0x1d167, 0x1d169, 0x1d173, 0x1d182, 0x1d185, 0x1d18b, 0x1d1aa, 0x1d1ad, 0x1d242, 0x1d244, 0x1da00, 0x1da36,
    0x1da3b, 0x1da6c, 0x1da75, 0x1da75, 0x1da84, 0x1da84, 0x1da9b, 0x1da9f, 0x1daa1, 0x1daaf, 0x1e000, 0x1e006,
    0x1e008, 0x1e018, 0x1e01b, 0x1e021, 0x1e023, 0x1e024, 0x1e026, 0x1e02a, 0x1e08f, 0x1e08f, 0x1e130, 0x1e136,
    0x1e2ae, 0x1e2ae, 0x1e2ec, 0x1e2ef, 0x1e4ec, 0x1e4ef, 0x1e8d0, 0x1e8d6, 0x1e944, 0x1e94a, 0xe0001, 0xe0001,
    0xe0020, 0xe007f, 0xe0100, 0xe01ef,
]
_WIDE = [
    0x1100, 0x115f, 0x231a, 0x231b, 0x2329, 0x232a, 0x23e9, 0x23ec, 0x23f0, 0x23f0, 0x23f3, 0x23f3,
    0x25fd, 0x25fe, 0x2614, 0x2615, 0x2648, 0x2653, 0x267f, 0x267f, 0x2693, 0x2693, 0x26a1, 0x26a1,
    0x26aa, 0x26ab, 0x26bd, 0x26be, 0x26c4, 0x26c5, 0x26ce, 0x26ce, 0x26d4, 0x26d4, 0x26ea, 0x26ea,
    0x26f2, 0x26f3, 0x26f5, 0x26f5, 0x26fa, 0x26fa, 0x26fd, 0x26fd, 0x2705, 0x2705, 0x270a, 0x270b,
    0x2728, 0x2728, 0x274c, 0x274c, 0x274e, 0x274e, 0x2753, 0x2755, 0x2757, 0x2757, 0x2795, 0x2797,
    0x27b0, 0x27b0, 0x27bf, 0x27bf, 0x2b1b, 0x2b1c, 0x2b50, 0x2b50, 0x2b55, 0x2b55, 0x2e80, 0x2e99,
    0x2e9b, 0x2ef3, 0x2f00, 0x2fd5, 0x2ff0, 0x3029, 0x302e, 0x303e, 0x3041, 0x3096, 0x309b, 0x30ff,
    0x3105, 0x312f, 0x3131, 0x318e, 0x3190, 0x31e3, 0x31ef, 0x321e, 0x3220, 0xa48c, 0xa490, 0xa4c6,
    0xa960, 0xa97c, 0xac00, 0xd7a3, 0xf900, 0xfa6d, 0xfa70, 0xfad9, 0xfe10, 0xfe19, 0xfe30, 0xfe52,
    0xfe54, 0xfe66, 0xfe68, 0xfe6b, 0xff01, 0xff60, 0xffe0, 0xffe6, 0x16fe0, 0x16fe3, 0x16ff0, 0x16ff1,
    0x17000, 0x187f7, 0x18800, 0x18cd5, 0x18d00, 0x18d08, 0x1aff0, 0x1aff3, 0x1aff5, 0x1affb, 0x1affd, 0x1affe,
    0x1b000, 0x1b122, 0x1b132, 0x1b132, 0x1b150, 0x1b152, 0x1b155, 0x1b155, 0x1b164, 0x1b167, 0x1b170, 0x1b2fb,
    0x1f004, 0x1f004, 0x1f0cf, 0x1f0cf, 0x1f18e, 0x1f18e, 0x1f191, 0x1f19a, 0x1f200, 0x1f202, 0x1f210, 0x1f23b,
    0x1f240, 0x1f248, 0x1f250, 0x1f251, 0x1f260, 0x1f265, 0x1f300, 0x1f320, 0x1f32d, 0x1f335, 0x1f337, 0x1f37c,
    0x1f37e, 0x1f393, 0x1f3a0, 0x1f3ca, 0x1f3cf, 0x1f3d3, 0x1f3e0, 0x1f3f0, 0x1f3f4, 0x1f3f4, 0x1f3f8, 0x1f43e,
    0x1f440, 0x1f440, 0x1f442, 0x1f4fc, 0x1f4ff, 0x1f53d, 0x1f54b, 0x1f54e, 0x1f550, 0x1f567, 0x1f57a, 0x1f57a,
    0x1f595, 0x1f596, 0x1f5a4, 0x1f5a4, 0x1f5fb, 0x1f64f, 0x1f680, 0x1f6c5, 0x1f6cc, 0x1f6cc, 0x1f6d0, 0x1f6d2,
    0x1f6d5, 0x1f6d7, 0x1f6dc, 0x1f6df, 0x1f6eb, 0x1f6ec, 0x1f6f4, 0x1f6fc, 0x1f7e0, 0x1f7eb, 0x1f7f0, 0x1f7f0,
    0x1f90c, 0x1f93a, 0x1f93c, 0x1f945, 0x1f947, 0x1f9ff, 0x1fa70, 0x1fa7c, 0x1fa80, 0x1fa88, 0x1fa90, 0x1fabd,
    0x1fabf, 0x1fac5, 0x1face, 0x1fadb, 0x1fae0, 0x1fae8, 0x1faf0, 0x1faf8, 0x20000, 0x2a6df, 0x2a700, 0x2b739,
    0x2b740, 0x2b81d, 0x2b820, 0x2cea1, 0x2ceb0, 0x2ebe0, 0x2ebf0, 0x2ee5d, 0x2f800, 0x2fa1d, 0x30000, 0x3134a,
    0x31350, 0x323af,
]
# --- end widths ---

_width_cache = {}


def _in_ranges(tab, o):
    lo = 0
    hi = len(tab) // 2 - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        if o < tab[2 * mid]:
            hi = mid - 1
        elif o > tab[2 * mid + 1]:
            lo = mid + 1
        else:
            return True
    return False


def wcwidth(ch):
    """Columns a character takes: 0 (combining), 1 or 2 (wide)."""
    o = ord(ch) if isinstance(ch, str) else ch
    if o < 0x300:
        if o == 0:
            return 0
        return 1
    w = _width_cache.get(o)
    if w is not None:
        return w
    if _in_ranges(_ZERO, o):
        w = 0
    elif _in_ranges(_WIDE, o):
        w = 2
    else:
        w = 1
    _width_cache[o] = w
    return w


class Cell:
    """One cell of the screen, as attributes."""

    def __init__(self, t):
        self.ch = t[0]
        self.fg = t[1]
        self.bg = t[2]
        self.flags = t[3]
        self.bold = (t[3] & BOLD) != 0
        self.dim = (t[3] & DIM) != 0
        self.italic = (t[3] & ITALIC) != 0
        self.underline = (t[3] & UNDERLINE) != 0
        self.blink = (t[3] & BLINK) != 0
        self.reverse = (t[3] & REVERSE) != 0
        self.invisible = (t[3] & INVISIBLE) != 0
        self.strike = (t[3] & STRIKE) != 0

    def attrs(self):
        out = []
        for name, bit in _ATTR_NAMES:
            if self.flags & bit:
                out.append(name)
        return out

    def __eq__(self, other):
        return isinstance(other, Cell) and (self.ch, self.fg, self.bg, self.flags) == (other.ch, other.fg, other.bg, other.flags)

    def __hash__(self):
        return hash((self.ch, self.fg, self.bg, self.flags))

    def __repr__(self):
        return "Cell(%r, fg=%r, bg=%r, %s)" % (self.ch, self.fg, self.bg, "|".join(self.attrs()) or "plain")


class _Buffer:
    def __init__(self, rows, cols, bg):
        blank = (" ", -1, bg, 0)
        self.lines = []
        for _ in range(rows):
            self.lines.append([blank] * cols)


# parser states
_GROUND = 0
_ESC = 1
_ESC_INT = 2
_CSI_ENTRY = 3
_CSI_PARAM = 4
_CSI_INT = 5
_CSI_IGNORE = 6
_DCS_ENTRY = 7
_DCS_PARAM = 8
_DCS_INT = 9
_DCS_PASS = 10
_DCS_IGNORE = 11
_OSC = 12
_SOS = 13


class Terminal:
    """A VT100/xterm screen of rows x cols cells."""

    def __init__(self, rows=24, cols=80):
        self.rows = rows
        self.cols = cols
        self.responses = b""
        self.osc = []
        self.title = ""
        self.icon_title = ""
        self.bells = 0
        self.flashes = 0
        self.palette = {}
        self.bytes_fed = 0
        self.dcs = []
        self._utf8_tail = b""
        self.reset()

    # ── state ─────────────────────────────────────────────────────────────
    def reset(self):
        """RIS: everything back to the power-on state."""
        self.main = _Buffer(self.rows, self.cols, -1)
        self.alt = _Buffer(self.rows, self.cols, -1)
        self.buf = self.main
        self.alt_active = False
        self.y = 0
        self.x = 0
        self.wrap_pending = False
        self.fg = -1
        self.bg = -1
        self.flags = 0
        self.top = 0
        self.bottom = self.rows - 1
        self.g = ["B", "B"]
        self.gl = 0
        self.insert = False
        self.lnm = False
        self.origin = False
        self.autowrap = True
        self.cursor_visible = True
        self.app_cursor = False
        self.app_keypad = False
        self.reverse_screen = False
        self.mouse = set()
        self.bracketed_paste = False
        self.focus_events = False
        self.cursor_style = 0
        self.saved = None
        self.saved_alt = None
        self.tabs = []
        for i in range(self.cols):
            self.tabs.append(i % 8 == 0 and i > 0)
        self.last_char = None
        self.state = _GROUND
        self.params = ""
        self.inter = ""
        self.osc_buf = []
        self.dcs_buf = []

    def resize(self, rows, cols):
        """The window changed size: keep what fits, as xterm does."""
        for b in (self.main, self.alt):
            lines = b.lines
            for i in range(len(lines)):
                row = lines[i]
                if len(row) > cols:
                    del row[cols:]
                    if row and row[-1][0] != "" and cols > 0 and wcwidth(row[-1][0]) == 2:
                        row[-1] = (" ", -1, -1, 0)
                elif len(row) < cols:
                    row.extend([(" ", -1, -1, 0)] * (cols - len(row)))
            if len(lines) > rows:
                if b is self.buf and self.y >= rows:
                    drop = self.y - rows + 1
                    del lines[:drop]
                del lines[rows:]
            while len(lines) < rows:
                lines.append([(" ", -1, -1, 0)] * cols)
        self.rows = rows
        self.cols = cols
        self.top = 0
        self.bottom = rows - 1
        tabs = []
        for i in range(cols):
            if i < len(self.tabs):
                tabs.append(self.tabs[i])
            else:
                tabs.append(i % 8 == 0 and i > 0)
        self.tabs = tabs
        self.y = min(self.y, rows - 1)
        self.x = min(self.x, cols - 1)
        self.wrap_pending = False

    # ── reading the screen ────────────────────────────────────────────────
    def cursor(self):
        return (self.y, self.x)

    def cell(self, y, x):
        return Cell(self.buf.lines[y][x])

    def raw(self, y, x):
        return self.buf.lines[y][x]

    def line(self, y):
        """Row y as text (a wide character once, its second cell skipped)."""
        out = []
        for c in self.buf.lines[y]:
            if c[0] != "":
                out.append(c[0])
        return "".join(out)

    def display(self):
        out = []
        for y in range(self.rows):
            out.append(self.line(y))
        return out

    def text(self):
        out = []
        for y in range(self.rows):
            out.append(self.line(y).rstrip())
        while out and out[-1] == "":
            out.pop()
        return "\n".join(out)

    def visible(self, y, x):
        """What the cell looks like: (char, fg, bg, flags) with the
        differences nobody can see folded away - a space shows only its
        background (its foreground when reversed) and underline/strike/
        reverse; invisible text shows as spaces; blink and bold on a blank
        are invisible."""
        c = self.buf.lines[y][x]
        ch = c[0]
        fg = c[1]
        bg = c[2]
        fl = c[3]
        if fl & INVISIBLE:
            ch = " " if ch != "" else ""
        if ch == " " or ch == " ":
            keep = fl & (UNDERLINE | STRIKE | REVERSE)
            if keep & REVERSE:
                bg = fg
                fg = -1
                keep = keep & ~REVERSE
            if not (keep & (UNDERLINE | STRIKE)):
                fg = -1
            return (" ", fg, bg, keep)
        return (ch, fg, bg, fl & ~INVISIBLE)

    def screen(self):
        """The whole screen as visible() cells, row by row."""
        out = []
        for y in range(self.rows):
            row = []
            for x in range(self.cols):
                row.append(self.visible(y, x))
            out.append(row)
        return out

    def snapshot(self):
        """Everything a user sees: the cells, the cursor (when shown) and
        whether the alternate screen is up."""
        return {"rows": self.rows, "cols": self.cols, "screen": self.screen(),
                "cursor": self.cursor() if self.cursor_visible else None,
                "alt": self.alt_active}

    def diff(self, other):
        """Where two terminals' screens differ, as readable lines."""
        out = []
        a = self.screen()
        b = other.screen()
        for y in range(min(len(a), len(b))):
            for x in range(min(len(a[y]), len(b[y]))):
                if a[y][x] != b[y][x]:
                    out.append("(%d,%d): %r != %r" % (y, x, a[y][x], b[y][x]))
        if self.cursor() != other.cursor():
            out.append("cursor %r != %r" % (self.cursor(), other.cursor()))
        return out

    def osc_count(self, text):
        n = 0
        for s in self.osc:
            if s == text:
                n += 1
        return n

    # ── keys a program reads (what xterm sends) ───────────────────────────
    def key(self, name, shift=False, alt=False, ctrl=False):
        """The bytes xterm sends for a key: "up", "f5", "home", "enter"...
        Cursor and keypad keys follow DECCKM; modifiers use xterm's
        CSI 1;m form."""
        m = 1 + (1 if shift else 0) + (2 if alt else 0) + (4 if ctrl else 0)
        cur = {"up": "A", "down": "B", "right": "C", "left": "D", "home": "H", "end": "F"}
        tilde = {"insert": 2, "delete": 3, "pageup": 5, "pagedown": 6, "f5": 15, "f6": 17, "f7": 18,
                 "f8": 19, "f9": 20, "f10": 21, "f11": 23, "f12": 24}
        ss3 = {"f1": "P", "f2": "Q", "f3": "R", "f4": "S"}
        if name in cur:
            if m > 1:
                return ("\x1b[1;%d%s" % (m, cur[name])).encode()
            return ("\x1bO" if self.app_cursor else "\x1b[").encode() + cur[name].encode()
        if name in ss3:
            if m > 1:
                return ("\x1b[1;%d%s" % (m, ss3[name])).encode()
            return b"\x1bO" + ss3[name].encode()
        if name in tilde:
            if m > 1:
                return ("\x1b[%d;%d~" % (tilde[name], m)).encode()
            return ("\x1b[%d~" % tilde[name]).encode()
        simple = {"enter": b"\r", "tab": b"\t", "escape": b"\x1b", "backspace": b"\x7f", "space": b" "}
        if name == "tab" and shift:
            return b"\x1b[Z"
        if name in simple:
            s = simple[name]
        else:
            s = name.encode("utf-8")
        if ctrl and len(s) == 1 and 0x40 <= (s[0] & 0xdf) <= 0x5f:
            s = bytes([s[0] & 0x1f])
        if alt:
            s = b"\x1b" + s
        return s

    def mouse_event(self, button, y, x, press=True, motion=False, shift=False, alt=False, ctrl=False):
        """The report xterm sends for a mouse event at screen cell (y, x):
        SGR (1006) when the program asked for it, else the X10 form.
        button: 1-3, 4/5 the wheel, 0 no button (motion)."""
        if button in (4, 5):
            b = 64 + (button - 4)
        elif button == 0:
            b = 3
        else:
            b = button - 1
        if motion:
            b += 32
        b += (4 if shift else 0) + (8 if alt else 0) + (16 if ctrl else 0)
        if 1006 in self.mouse:
            return ("\x1b[<%d;%d;%d%s" % (b, x + 1, y + 1, "M" if press else "m")).encode()
        if not press:
            b = 3 + (b & ~3)
        return b"\x1b[M" + bytes([32 + b, 32 + x + 1, 32 + y + 1])

    # ── input ─────────────────────────────────────────────────────────────
    def feed(self, data):
        """Process output: bytes (UTF-8, split anywhere) or str."""
        if isinstance(data, str):
            text = data
        else:
            data = bytes(data)
            self.bytes_fed += len(data)
            if self._utf8_tail:
                data = self._utf8_tail + data
                self._utf8_tail = b""
            # keep an incomplete UTF-8 sequence for the next feed
            n = len(data)
            i = n - 1
            k = 0
            while i >= 0 and k < 3 and (data[i] & 0xC0) == 0x80:
                i -= 1
                k += 1
            if i >= 0 and data[i] >= 0xC0:
                need = 2 if data[i] < 0xE0 else (3 if data[i] < 0xF0 else 4)
                if n - i < need:
                    self._utf8_tail = data[i:]
                    data = data[:i]
            text = data.decode("utf-8", "replace")
        self._run(text)

    def _run(self, text):
        n = len(text)
        i = 0
        while i < n:
            ch = text[i]
            o = ord(ch)
            if self.state == _GROUND and o >= 0x20 and o != 0x7f and not (0x80 <= o < 0xA0):
                self._print(ch, o)
                i += 1
                continue
            self._byte(ch, o)
            i += 1

    def _byte(self, ch, o):
        st = self.state
        # "anywhere" transitions
        if o == 0x1b:
            if st == _OSC:
                self._osc_end()
            elif st == _DCS_PASS:
                self._dcs_end()
            self.state = _ESC
            self.inter = ""
            return
        if o == 0x18 or o == 0x1a:
            if st == _OSC:
                self.osc_buf = []
            self.state = _GROUND
            return
        if 0x80 <= o < 0xA0:
            if st == _OSC:
                if o == 0x9c:
                    self._osc_end()
                    self.state = _GROUND
                    return
            elif st == _DCS_PASS and o == 0x9c:
                self._dcs_end()
                self.state = _GROUND
                return
            self._c1(o)
            return
        if st == _GROUND:
            if o < 0x20 or o == 0x7f:
                self._execute(o)
            else:
                self._print(ch, o)
            return
        if st == _ESC:
            if o < 0x20:
                self._execute(o)
            elif 0x20 <= o <= 0x2f:
                self.inter += ch
                self.state = _ESC_INT
            elif o == 0x5b:
                self._clear()
                self.state = _CSI_ENTRY
            elif o == 0x5d:
                self.osc_buf = []
                self.state = _OSC
            elif o == 0x50:
                self._clear()
                self.state = _DCS_ENTRY
            elif o in (0x58, 0x5e, 0x5f):
                self.state = _SOS
            elif o == 0x7f:
                pass
            else:
                self.state = _GROUND
                self._esc_dispatch(ch)
            return
        if st == _ESC_INT:
            if o < 0x20:
                self._execute(o)
            elif o <= 0x2f:
                self.inter += ch
            elif o != 0x7f:
                self.state = _GROUND
                self._esc_dispatch(ch)
            return
        if st == _CSI_ENTRY or st == _CSI_PARAM:
            if o < 0x20:
                self._execute(o)
            elif 0x30 <= o <= 0x3b:
                self.params += ch
                self.state = _CSI_PARAM
            elif 0x3c <= o <= 0x3f:
                if st == _CSI_ENTRY:
                    self.inter += ch
                    self.state = _CSI_PARAM
                else:
                    self.state = _CSI_IGNORE
            elif 0x20 <= o <= 0x2f:
                self.inter += ch
                self.state = _CSI_INT
            elif 0x40 <= o <= 0x7e:
                self.state = _GROUND
                self._csi_dispatch(ch)
            return
        if st == _CSI_INT:
            if o < 0x20:
                self._execute(o)
            elif 0x20 <= o <= 0x2f:
                self.inter += ch
            elif 0x30 <= o <= 0x3f:
                self.state = _CSI_IGNORE
            elif 0x40 <= o <= 0x7e:
                self.state = _GROUND
                self._csi_dispatch(ch)
            return
        if st == _CSI_IGNORE:
            if o < 0x20:
                self._execute(o)
            elif 0x40 <= o <= 0x7e:
                self.state = _GROUND
            return
        if st == _OSC:
            if o == 0x07:
                self._osc_end()
                self.state = _GROUND
            elif o >= 0x20:
                self.osc_buf.append(ch)
            return
        if st == _DCS_ENTRY or st == _DCS_PARAM or st == _DCS_INT:
            if o < 0x20:
                return
            if 0x30 <= o <= 0x3b and st != _DCS_INT:
                self.params += ch
                self.state = _DCS_PARAM
            elif 0x3c <= o <= 0x3f:
                if st == _DCS_ENTRY:
                    self.inter += ch
                    self.state = _DCS_PARAM
                else:
                    self.state = _DCS_IGNORE
            elif 0x20 <= o <= 0x2f:
                self.inter += ch
                self.state = _DCS_INT
            elif 0x40 <= o <= 0x7e:
                self.dcs_buf = [self.inter + self.params + ch]
                self.state = _DCS_PASS
            return
        if st == _DCS_PASS:
            if o != 0x7f:
                self.dcs_buf.append(ch)
            return
        if st == _DCS_IGNORE or st == _SOS:
            return

    def _clear(self):
        self.params = ""
        self.inter = ""

    def _osc_end(self):
        s = "".join(self.osc_buf)
        self.osc_buf = []
        self.osc.append(s)
        p = s.split(";", 1)
        if len(p) == 2:
            if p[0] in ("0", "2"):
                self.title = p[1]
            if p[0] in ("0", "1"):
                self.icon_title = p[1]
            if p[0] == "4":
                q = p[1].split(";")
                j = 0
                while j + 1 < len(q):
                    try:
                        self.palette[int(q[j])] = q[j + 1]
                    except ValueError:
                        pass
                    j += 2
        if p[0] == "104":
            self.palette = {}

    def _dcs_end(self):
        self.dcs.append("".join(self.dcs_buf))
        self.dcs_buf = []

    def _c1(self, o):
        # 8-bit controls given as code points
        if o == 0x84:
            self._index()
        elif o == 0x85:
            self.x = 0
            self._index()
        elif o == 0x88:
            self.tabs[self.x] = True
        elif o == 0x8d:
            self._reverse_index()
        elif o == 0x9b:
            self._clear()
            self.state = _CSI_ENTRY
        elif o == 0x9d:
            self.osc_buf = []
            self.state = _OSC
        elif o == 0x90:
            self._clear()
            self.state = _DCS_ENTRY
        elif o in (0x98, 0x9e, 0x9f):
            self.state = _SOS
        elif o == 0x9c:
            self.state = _GROUND

    # ── C0 controls ───────────────────────────────────────────────────────
    def _execute(self, o):
        if o == 0x07:
            self.bells += 1
        elif o == 0x08:
            if self.x > 0:
                if self.wrap_pending:
                    self.wrap_pending = False
                else:
                    self.x -= 1
            self.wrap_pending = False
        elif o == 0x09:
            self._tab(1)
        elif o == 0x0a or o == 0x0b or o == 0x0c:
            self._index()
            if self.lnm:
                self.x = 0
        elif o == 0x0d:
            self.x = 0
            self.wrap_pending = False
        elif o == 0x0e:
            self.gl = 1
        elif o == 0x0f:
            self.gl = 0

    def _tab(self, n):
        x = self.x
        while n > 0 and x < self.cols - 1:
            x += 1
            while x < self.cols - 1 and not self.tabs[x]:
                x += 1
            n -= 1
        self.x = x
        self.wrap_pending = False

    def _backtab(self, n):
        x = self.x
        while n > 0 and x > 0:
            x -= 1
            while x > 0 and not self.tabs[x]:
                x -= 1
            n -= 1
        self.x = x
        self.wrap_pending = False

    # ── printing ──────────────────────────────────────────────────────────
    def _blank(self):
        return (" ", -1, self.bg, 0)

    def _unwide(self, row, x):
        # writing over one half of a wide character erases the other half
        if x < 0 or x >= self.cols:
            return
        c = row[x]
        if c[0] == "":
            if x > 0:
                p = row[x - 1]
                row[x - 1] = (" ", -1, p[2], 0)
        elif x + 1 < self.cols and row[x + 1][0] == "":
            n = row[x + 1]
            row[x + 1] = (" ", -1, n[2], 0)

    def _print(self, ch, o):
        if o < 0x80:
            cs = self.g[self.gl]
            if cs == "0":
                if 0x5f <= o <= 0x7e:
                    ch = _DEC[o - 0x5f]
                    o = ord(ch)
            elif cs == "A" and o == 0x23:
                ch = "£"
                o = 0xa3
        w = 1 if o < 0x300 else wcwidth(o)
        lines = self.buf.lines
        if w == 0:
            # a combining character joins the cell before the cursor
            y = self.y
            x = self.x if self.wrap_pending else self.x - 1
            if x >= 0:
                row = lines[y]
                c = row[x]
                if c[0] == "" and x > 0:
                    x -= 1
                    c = row[x]
                row[x] = (c[0] + ch, c[1], c[2], c[3])
            return
        if self.wrap_pending:
            if self.autowrap:
                self.x = 0
                self._index()
            self.wrap_pending = False
        cols = self.cols
        if w == 2 and self.x >= cols - 1:
            if self.autowrap:
                row = lines[self.y]
                self._unwide(row, self.x)
                row[self.x] = (" ", -1, self.bg, 0)
                self.x = 0
                self._index()
            else:
                self.x = cols - 2
                if self.x < 0:
                    return
        row = lines[self.y]
        x = self.x
        if self.insert:
            self._unwide(row, x)
            for _ in range(w):
                row.insert(x, (" ", -1, self.bg, 0))
                row.pop()
            if row[cols - 1][0] != "" and wcwidth(row[cols - 1][0][:1]) == 2:
                row[cols - 1] = (" ", -1, self.bg, 0)
        self._unwide(row, x)
        if w == 2:
            self._unwide(row, x + 1)
        row[x] = (ch, self.fg, self.bg, self.flags)
        if w == 2:
            row[x + 1] = ("", self.fg, self.bg, self.flags)
        self.last_char = ch
        nx = x + w
        if nx >= cols:
            self.x = cols - 1
            if self.autowrap:
                self.wrap_pending = True
        else:
            self.x = nx

    # ── lines and scrolling ───────────────────────────────────────────────
    def _blank_line(self):
        return [(" ", -1, self.bg, 0)] * self.cols

    def _scroll_up(self, top, bottom, n):
        lines = self.buf.lines
        n = min(n, bottom - top + 1)
        for _ in range(n):
            del lines[top]
            lines.insert(bottom, self._blank_line())

    def _scroll_down(self, top, bottom, n):
        lines = self.buf.lines
        n = min(n, bottom - top + 1)
        for _ in range(n):
            del lines[bottom]
            lines.insert(top, self._blank_line())

    def _index(self):
        if self.y == self.bottom:
            self._scroll_up(self.top, self.bottom, 1)
        elif self.y < self.rows - 1:
            self.y += 1
        self.wrap_pending = False

    def _reverse_index(self):
        if self.y == self.top:
            self._scroll_down(self.top, self.bottom, 1)
        elif self.y > 0:
            self.y -= 1
        self.wrap_pending = False

    # ── escape sequences ──────────────────────────────────────────────────
    def _save_cursor(self):
        st = (self.y, self.x, self.fg, self.bg, self.flags, list(self.g), self.gl, self.origin,
              self.autowrap, self.wrap_pending)
        if self.alt_active:
            self.saved_alt = st
        else:
            self.saved = st

    def _restore_cursor(self):
        st = self.saved_alt if self.alt_active else self.saved
        if st is None:
            self.y = 0
            self.x = 0
            self.fg = -1
            self.bg = -1
            self.flags = 0
            self.origin = False
            self.g = ["B", "B"]
            self.gl = 0
        else:
            self.y = min(st[0], self.rows - 1)
            self.x = min(st[1], self.cols - 1)
            self.fg = st[2]
            self.bg = st[3]
            self.flags = st[4]
            self.g = list(st[5])
            self.gl = st[6]
            self.origin = st[7]
            self.autowrap = st[8]
        self.wrap_pending = False

    def _esc_dispatch(self, ch):
        inter = self.inter
        if inter == "":
            if ch == "7":
                self._save_cursor()
            elif ch == "8":
                self._restore_cursor()
            elif ch == "D":
                self._index()
            elif ch == "E":
                self.x = 0
                self._index()
            elif ch == "M":
                self._reverse_index()
            elif ch == "H":
                self.tabs[self.x] = True
            elif ch == "c":
                rows = self.rows
                self.reset()
            elif ch == "=":
                self.app_keypad = True
            elif ch == ">":
                self.app_keypad = False
            return
        if inter in ("(", ")", "*", "+"):
            which = {"(": 0, ")": 1, "*": 0, "+": 1}[inter]
            if inter in ("(", ")"):
                if ch in ("0", "B", "A"):
                    self.g[which] = ch
                else:
                    self.g[which] = "B"
            return
        if inter == "#" and ch == "8":
            for row in self.buf.lines:
                for x in range(self.cols):
                    row[x] = ("E", -1, -1, 0)
            self.top = 0
            self.bottom = self.rows - 1
            self.y = 0
            self.x = 0
            self.wrap_pending = False

    def _nums(self, dflt):
        out = []
        subs = []
        if self.params == "":
            return [dflt], [[]]
        for part in self.params.split(";"):
            pieces = part.split(":")
            head = pieces[0]
            try:
                v = int(head) if head != "" else dflt
            except ValueError:
                v = dflt
            out.append(v)
            sub = []
            for p in pieces[1:]:
                try:
                    sub.append(int(p) if p != "" else 0)
                except ValueError:
                    sub.append(0)
            subs.append(sub)
        return out, subs

    def _csi_dispatch(self, final):
        priv = ""
        inter = self.inter
        if inter and inter[0] in "<=>?":
            priv = inter[0]
            inter = inter[1:]
        if final == "m" and priv == "" and inter == "":
            self._sgr()
            return
        ps, subs = self._nums(0)
        p1 = ps[0] if ps[0] > 0 else 1
        if inter == "":
            if priv == "":
                if final == "@":
                    self._ich(p1)
                elif final == "A":
                    top = self.top if self.y >= self.top else 0
                    self.y = max(top, self.y - p1)
                    self.wrap_pending = False
                elif final == "B" or final == "e":
                    bot = self.bottom if self.y <= self.bottom else self.rows - 1
                    self.y = min(bot, self.y + p1)
                    self.wrap_pending = False
                elif final == "C" or final == "a":
                    self.x = min(self.cols - 1, self.x + p1)
                    self.wrap_pending = False
                elif final == "D":
                    self.x = max(0, self.x - p1)
                    self.wrap_pending = False
                elif final == "E":
                    bot = self.bottom if self.y <= self.bottom else self.rows - 1
                    self.y = min(bot, self.y + p1)
                    self.x = 0
                    self.wrap_pending = False
                elif final == "F":
                    top = self.top if self.y >= self.top else 0
                    self.y = max(top, self.y - p1)
                    self.x = 0
                    self.wrap_pending = False
                elif final == "G" or final == "`":
                    self.x = min(self.cols - 1, p1 - 1)
                    self.wrap_pending = False
                elif final == "H" or final == "f":
                    r = ps[0] if ps[0] > 0 else 1
                    c = ps[1] if len(ps) > 1 and ps[1] > 0 else 1
                    self._goto(r - 1, c - 1)
                elif final == "I":
                    self._tab(p1)
                elif final == "J":
                    self._ed(ps[0])
                elif final == "K":
                    self._el(ps[0])
                elif final == "L":
                    self._il(p1)
                elif final == "M":
                    self._dl(p1)
                elif final == "P":
                    self._dch(p1)
                elif final == "S":
                    self._scroll_up(self.top, self.bottom, p1)
                elif final == "T":
                    if len(ps) <= 1:
                        self._scroll_down(self.top, self.bottom, p1)
                elif final == "X":
                    self._ech(p1)
                elif final == "Z":
                    self._backtab(p1)
                elif final == "b":
                    if self.last_char is not None:
                        for _ in range(p1):
                            self._print(self.last_char, ord(self.last_char[0]))
                elif final == "c":
                    if ps[0] == 0:
                        self.responses += b"\x1b[?62;22c"
                elif final == "d":
                    r = p1 - 1
                    if self.origin:
                        r = min(self.bottom, r + self.top)
                    self.y = min(self.rows - 1, r)
                    self.wrap_pending = False
                elif final == "g":
                    if ps[0] == 0:
                        self.tabs[self.x] = False
                    elif ps[0] == 3:
                        self.tabs = [False] * self.cols
                elif final == "h" or final == "l":
                    on = final == "h"
                    for p in ps:
                        if p == 4:
                            self.insert = on
                        elif p == 20:
                            self.lnm = on
                elif final == "n":
                    if ps[0] == 5:
                        self.responses += b"\x1b[0n"
                    elif ps[0] == 6:
                        r = self.y - (self.top if self.origin else 0)
                        self.responses += ("\x1b[%d;%dR" % (r + 1, self.x + 1)).encode()
                elif final == "r":
                    t = ps[0] if ps[0] > 0 else 1
                    b = ps[1] if len(ps) > 1 and ps[1] > 0 else self.rows
                    b = min(b, self.rows)
                    if t < b:
                        self.top = t - 1
                        self.bottom = b - 1
                        self._goto(0, 0)
                elif final == "s":
                    self._save_cursor()
                elif final == "u":
                    self._restore_cursor()
                elif final == "t":
                    pass
            elif priv == "?":
                if final == "h" or final == "l":
                    for p in ps:
                        self._decmode(p, final == "h")
                elif final == "J":
                    self._ed(ps[0])
                elif final == "K":
                    self._el(ps[0])
                elif final == "n":
                    if ps[0] == 6:
                        r = self.y - (self.top if self.origin else 0)
                        self.responses += ("\x1b[?%d;%d;1R" % (r + 1, self.x + 1)).encode()
            elif priv == ">":
                if final == "c":
                    self.responses += b"\x1b[>41;380;0c"
        elif inter == "!" and final == "p":
            self._soft_reset()
        elif inter == " " and final == "q":
            self.cursor_style = ps[0]

    def _goto(self, r, c):
        if self.origin:
            r = min(self.bottom, r + self.top)
        self.y = max(0, min(self.rows - 1, r))
        self.x = max(0, min(self.cols - 1, c))
        self.wrap_pending = False

    def _soft_reset(self):
        self.insert = False
        self.origin = False
        self.autowrap = True
        self.cursor_visible = True
        self.app_cursor = False
        self.app_keypad = False
        self.top = 0
        self.bottom = self.rows - 1
        self.g = ["B", "B"]
        self.gl = 0
        self.fg = -1
        self.bg = -1
        self.flags = 0
        self.saved = None
        self.wrap_pending = False

    def _decmode(self, p, on):
        if p == 1:
            self.app_cursor = on
        elif p == 5:
            if on and not self.reverse_screen:
                self.flashes += 1
            self.reverse_screen = on
        elif p == 6:
            self.origin = on
            self._goto(0, 0)
        elif p == 7:
            self.autowrap = on
            if not on:
                self.wrap_pending = False
        elif p == 25:
            self.cursor_visible = on
        elif p in (9, 1000, 1001, 1002, 1003, 1005, 1006, 1015):
            if on:
                self.mouse.add(p)
            elif p in self.mouse:
                self.mouse.discard(p)
        elif p == 1004:
            self.focus_events = on
        elif p == 2004:
            self.bracketed_paste = on
        elif p == 1048:
            if on:
                self._save_cursor()
            else:
                self._restore_cursor()
        elif p == 47 or p == 1047 or p == 1049:
            if on and not self.alt_active:
                if p == 1049:
                    self._save_cursor()
                    saved = self.saved
                self.buf = self.alt
                self.alt_active = True
                if p == 1049:
                    self.saved_alt = saved
                    for row in self.buf.lines:
                        for x in range(self.cols):
                            row[x] = (" ", -1, self.bg, 0)
            elif not on and self.alt_active:
                if p == 1047:
                    for row in self.buf.lines:
                        for x in range(self.cols):
                            row[x] = (" ", -1, self.bg, 0)
                self.buf = self.main
                self.alt_active = False
                if p == 1049:
                    self._restore_cursor()
            self.wrap_pending = False

    def _sgr(self):
        ps, subs = self._nums(0)
        i = 0
        n = len(ps)
        while i < n:
            p = ps[i]
            sub = subs[i]
            if p == 0:
                self.fg = -1
                self.bg = -1
                self.flags = 0
            elif p == 1:
                self.flags |= BOLD
            elif p == 2:
                self.flags |= DIM
            elif p == 3:
                self.flags |= ITALIC
            elif p == 4:
                if sub and sub[0] == 0:
                    self.flags &= ~UNDERLINE
                else:
                    self.flags |= UNDERLINE
            elif p == 5 or p == 6:
                self.flags |= BLINK
            elif p == 7:
                self.flags |= REVERSE
            elif p == 8:
                self.flags |= INVISIBLE
            elif p == 9:
                self.flags |= STRIKE
            elif p == 21:
                self.flags |= UNDERLINE
            elif p == 22:
                self.flags &= ~(BOLD | DIM)
            elif p == 23:
                self.flags &= ~ITALIC
            elif p == 24:
                self.flags &= ~UNDERLINE
            elif p == 25:
                self.flags &= ~BLINK
            elif p == 27:
                self.flags &= ~REVERSE
            elif p == 28:
                self.flags &= ~INVISIBLE
            elif p == 29:
                self.flags &= ~STRIKE
            elif 30 <= p <= 37:
                self.fg = p - 30
            elif p == 39:
                self.fg = -1
            elif 40 <= p <= 47:
                self.bg = p - 40
            elif p == 49:
                self.bg = -1
            elif 90 <= p <= 97:
                self.fg = p - 90 + 8
            elif 100 <= p <= 107:
                self.bg = p - 100 + 8
            elif p == 38 or p == 48 or p == 58:
                color = None
                if sub:
                    # 38:5:n / 38:2:[cs]:r:g:b
                    if sub[0] == 5 and len(sub) >= 2:
                        color = sub[1] & 255
                    elif sub[0] == 2 and len(sub) >= 4:
                        rgb = sub[-3:]
                        color = 0x1000000 | ((rgb[0] & 255) << 16) | ((rgb[1] & 255) << 8) | (rgb[2] & 255)
                elif i + 1 < n:
                    if ps[i + 1] == 5 and i + 2 < n:
                        color = ps[i + 2] & 255
                        i += 2
                    elif ps[i + 1] == 2 and i + 4 < n:
                        color = 0x1000000 | ((ps[i + 2] & 255) << 16) | ((ps[i + 3] & 255) << 8) | (ps[i + 4] & 255)
                        i += 4
                    else:
                        i += 1
                if color is not None:
                    if p == 38:
                        self.fg = color
                    elif p == 48:
                        self.bg = color
            i += 1

    # ── erasing and editing ───────────────────────────────────────────────
    def _ed(self, mode):
        lines = self.buf.lines
        blank = self._blank()
        self.wrap_pending = False
        if mode == 0:
            self._el(0)
            for y in range(self.y + 1, self.rows):
                lines[y] = [blank] * self.cols
        elif mode == 1:
            for y in range(0, self.y):
                lines[y] = [blank] * self.cols
            self._el(1)
        elif mode == 2:
            for y in range(self.rows):
                lines[y] = [blank] * self.cols

    def _el(self, mode):
        row = self.buf.lines[self.y]
        blank = self._blank()
        if mode == 0:
            self._unwide(row, self.x)
            for x in range(self.x, self.cols):
                row[x] = blank
        elif mode == 1:
            self._unwide(row, self.x)
            for x in range(0, min(self.x + 1, self.cols)):
                row[x] = blank
        elif mode == 2:
            for x in range(self.cols):
                row[x] = blank
        self.wrap_pending = False

    def _ech(self, n):
        row = self.buf.lines[self.y]
        blank = self._blank()
        end = min(self.cols, self.x + n)
        self._unwide(row, self.x)
        if end < self.cols:
            self._unwide(row, end)
        for x in range(self.x, end):
            row[x] = blank
        self.wrap_pending = False

    def _ich(self, n):
        row = self.buf.lines[self.y]
        n = min(n, self.cols - self.x)
        self._unwide(row, self.x)
        for _ in range(n):
            row.insert(self.x, self._blank())
            row.pop()
        last = row[self.cols - 1]
        if last[0] != "" and wcwidth(last[0][:1]) == 2:
            row[self.cols - 1] = self._blank()
        self.wrap_pending = False

    def _dch(self, n):
        row = self.buf.lines[self.y]
        n = min(n, self.cols - self.x)
        self._unwide(row, self.x)
        if self.x + n < self.cols:
            self._unwide(row, self.x + n)
        for _ in range(n):
            del row[self.x]
            row.append(self._blank())
        self.wrap_pending = False

    def _il(self, n):
        if self.y < self.top or self.y > self.bottom:
            return
        self._scroll_down(self.y, self.bottom, n)
        self.x = 0
        self.wrap_pending = False

    def _dl(self, n):
        if self.y < self.top or self.y > self.bottom:
            return
        self._scroll_up(self.y, self.bottom, n)
        self.x = 0
        self.wrap_pending = False


def render(data, rows=24, cols=80):
    """The screen after `data`, as text lines."""
    t = Terminal(rows, cols)
    t.feed(data)
    return t.display()
